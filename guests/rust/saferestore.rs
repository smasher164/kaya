//! The safe save's second act (tools/scenes/saferestore.steps): act one's
//! save is torn by KAYA_SAFE_SAVE_FAULT, and the relaunched process is
//! handed the backup.

use std::io::Read;

#[cfg(target_os = "android")]
fn scene_root() -> std::path::PathBuf {
    let root = std::env::var("EXTERNAL_STORAGE").unwrap_or_else(|_| "/sdcard".into());
    std::path::PathBuf::from(root).join("Documents")
}

#[cfg(not(target_os = "android"))]
fn scene_root() -> std::path::PathBuf {
    std::env::temp_dir()
}

fn read_back(file: &kaya::PickedFile) -> String {
    let mut text = String::new();
    match file.open(kaya::FileMode::Read) {
        Ok(mut opened) => {
            if let Err(e) = opened.file.read_to_string(&mut text) {
                text = format!("read failed: {e}");
            }
        }
        Err(e) => text = format!("open failed: {e}"),
    }
    text
}

pub(crate) fn app(ctx: kaya::AppCtx) {
    #[derive(Clone)]
    enum Msg {
        Open,
        Save,
        Left(kaya::LeftoverBackup),
        Restore,
    }

    let dir = scene_root().join(format!("kaya-saferestore-{}", std::process::id()));
    std::fs::create_dir_all(&dir).expect("failed to make the scene's directory");
    std::fs::write(dir.join("draft"), b"the first draft").expect("failed to write the file");
    std::fs::write(dir.join("decoy"), b"decoy").expect("failed to write the decoy");

    let msgs = kaya::Messages::<Msg>::new();
    // Before the first build: a leftover is the first thing a relaunch reads.
    msgs.on_backup_left(Msg::Left);
    let (status, measured, held) = ctx.apply(|tx| {
        tx.window(kaya::DEFAULT_WINDOW).title("saferestore");
        let status = tx.signal("no file");
        let measured = tx.signal("");
        let held = tx.signal("");
        let root = tx
            .column(|tx| {
                tx.label(status).a11y_id("status"); // label#0
                tx.label(measured).a11y_id("measured"); // label#1
                tx.label(held).a11y_id("held"); // label#2
                let open = tx.button("open").id(); // button#0
                msgs.on_click(open, Msg::Open);
                let save = tx.button("save").id(); // button#1
                msgs.on_click(save, Msg::Save);
                let restore = tx.button("restore").id(); // button#2
                msgs.on_click(restore, Msg::Restore);
            })
            .id();
        tx.mount(root);
        (status, measured, held)
    });

    let source = std::rc::Rc::new(std::cell::RefCell::new(None::<kaya::PickedFile>));
    let left = std::rc::Rc::new(std::cell::RefCell::new(None::<kaya::LeftoverBackup>));
    let work = |job: Box<dyn FnOnce() -> String + Send>, into: kaya::SignalId| {
        let poster = ctx.poster();
        std::thread::spawn(move || {
            let text = job();
            poster.post(move |tx| tx.write(into, text));
        });
    };

    let tasks = ctx.tasks();
    while let Some(msg) = tasks.next(&msgs) {
        match msg {
            Msg::Open => {
                let source = source.clone();
                let work = &work;
                tasks.spawn(async move |app| {
                    let Some(file) = app.pick_file().await.into_iter().next() else {
                        app.apply(|tx| tx.write(status, "open cancelled"));
                        return;
                    };
                    *source.borrow_mut() = Some(file.clone());
                    work(Box::new(move || format!("opened {}", read_back(&file))), status);
                });
            }
            Msg::Save => {
                let Some(file) = source.borrow().clone() else {
                    ctx.apply(|tx| tx.write(status, "nothing open to save"));
                    continue;
                };
                // Under the knob the save never returns, so a second reader
                // says when the torn bytes are on the document.
                let watched = file.clone();
                work(
                    Box::new(move || match file.save(b"torn halfway, never done") {
                        Ok(()) => "saved without the fault".into(),
                        Err(e) => format!("save failed: {e}"),
                    }),
                    held,
                );
                work(
                    Box::new(move || {
                        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(20);
                        loop {
                            let now = read_back(&watched);
                            if !now.is_empty() && now != "the first draft" {
                                return format!("the save stopped at {now}");
                            }
                            if std::time::Instant::now() > deadline {
                                return format!("the document still holds {now}");
                            }
                            std::thread::sleep(std::time::Duration::from_millis(50));
                        }
                    }),
                    status,
                );
            }
            Msg::Left(backup) => {
                ctx.apply(|tx| {
                    tx.write(status, format!("left a backup of {}", backup.name));
                    tx.write(measured, backup.measured.clone());
                });
                let (file, document) = (backup.backup_file.clone(), backup.document.clone());
                *left.borrow_mut() = Some(backup);
                work(
                    Box::new(move || {
                        let now = document.as_ref().map(read_back).unwrap_or_else(|| "nothing".into());
                        format!("backup holds {}; document holds {now}", read_back(&file))
                    }),
                    held,
                );
            }
            Msg::Restore => {
                let Some(backup) = left.borrow_mut().take() else {
                    ctx.apply(|tx| tx.write(status, "no backup to restore"));
                    continue;
                };
                work(
                    Box::new(move || match backup.restore() {
                        Ok(()) => match &backup.document {
                            Some(document) => format!("restored {}", read_back(document)),
                            None => "restored nothing: the document does not open".into(),
                        },
                        Err(e) => format!("restore failed: {e}"),
                    }),
                    status,
                );
            }
        }
    }
}
