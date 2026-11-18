//! The references scene (tools/scenes/references.steps,
//! docs/restoration-plan.md SR11, SR12): a picked file's durable reference
//! rides the session store across a relaunch and redeems for its bytes; a
//! foreign token and a deleted file are refused by name.

use std::io::Read;

/// The place the script names as $TMP (guests/rust/filedialog.rs's scene_root).
#[cfg(target_os = "android")]
fn scene_root() -> std::path::PathBuf {
    let root = std::env::var("EXTERNAL_STORAGE").unwrap_or_else(|_| "/sdcard".into());
    std::path::PathBuf::from(root).join("Documents")
}

#[cfg(target_os = "ios")]
fn scene_root() -> std::path::PathBuf {
    let home = std::env::var("HOME").unwrap_or_default();
    std::path::PathBuf::from(home).join("Documents")
}

#[cfg(not(any(target_os = "android", target_os = "ios")))]
fn scene_root() -> std::path::PathBuf {
    std::env::temp_dir()
}

fn picked_dir() -> std::path::PathBuf {
    scene_root().join(format!("kaya-refs-{}", std::process::id()))
}

/// The bytes a token redeems for, or the refusal's branch; the sentence goes
/// to stderr, where the leg log keeps it.
fn read_back(token: &str) -> String {
    match kaya::redeem(token) {
        Ok(redeemed) => match redeemed.file.open(kaya::FileMode::Read) {
            Ok(mut opened) => {
                let mut text = String::new();
                match opened.file.read_to_string(&mut text) {
                    Ok(_) => format!("redeemed: {text}"),
                    Err(e) => format!("read failed: {e}"),
                }
            }
            Err(e) => format!("open failed: {e}"),
        },
        Err(e) => {
            eprintln!("references: {e}");
            e.refusal.as_str().to_owned()
        }
    }
}

pub(crate) fn app(ctx: kaya::AppCtx) {
    #[derive(Clone)]
    enum Msg {
        Pick,
        Foreign,
        Delete,
    }

    let dir = picked_dir();
    std::fs::create_dir_all(&dir).expect("failed to make the scene's directory");
    std::fs::write(dir.join("picked.txt"), b"picked bytes").expect("failed to write the file");
    std::fs::write(dir.join("decoy.txt"), b"decoy").expect("failed to write the decoy");

    let session = kaya::session();
    let saved = session.get_string("doc", "");
    let msgs = kaya::Messages::<Msg>::new();
    let status = ctx.apply(|tx| {
        tx.window(kaya::DEFAULT_WINDOW).title("references");
        let status = tx.signal(if saved.is_empty() { "no reference" } else { "redeeming" }.to_string());
        let root = tx
            .column(|tx| {
                tx.label(status).a11y_id("status");
                let pick = tx.button("pick").a11y_id("pick").id();
                msgs.on_click(pick, Msg::Pick);
                let foreign = tx.button("foreign").a11y_id("foreign").id();
                msgs.on_click(foreign, Msg::Foreign);
                let delete = tx.button("delete").a11y_id("delete").id();
                msgs.on_click(delete, Msg::Delete);
            })
            .id();
        tx.mount(root);
        status
    });

    let reader = |token: String| {
        let poster = ctx.poster();
        std::thread::Builder::new()
            .name("references-reader".into())
            .spawn(move || {
                let said = read_back(&token);
                poster.post(move |tx| tx.write(status, said));
            })
            .expect("failed to spawn the reader");
    };
    if !saved.is_empty() {
        reader(saved.clone());
    }

    let tasks = ctx.tasks();
    while let Some(msg) = tasks.next(&msgs) {
        match msg {
            Msg::Pick => {
                let session = session.clone();
                let dir = dir.to_string_lossy().into_owned();
                tasks.spawn(async move |app| {
                    let files = app.pick_file().filter("Text", "txt").await;
                    let said = match files.first().map(|f| f.reference()) {
                        None => "cancelled".to_string(),
                        Some(Ok(token)) => {
                            session.set_string("doc", &token);
                            session.set_string("dir", &dir);
                            "minted".to_string()
                        }
                        Some(Err(e)) => {
                            eprintln!("references: {e}");
                            e.refusal.as_str().to_owned()
                        }
                    };
                    app.apply(|tx| tx.write(status, said));
                });
            }
            Msg::Foreign => reader("kaya-ref1:beos:AAAA:00000000".to_string()),
            Msg::Delete => {
                let picked = std::path::Path::new(&session.get_string("dir", "")).join("picked.txt");
                let _ = std::fs::remove_file(picked);
                reader(saved.clone());
            }
        }
    }
}

fn main() {
    kaya::run(app)
}
