//! GTK4 backend, milestone 0: one window, one button, one label.
//!
//! Same architecture as the AppKit and WinUI backends: the core owns the
//! main thread and the GLib main loop; the button's clicked signal pushes
//! an occurrence and never calls app code; commands come back on their
//! own channel; glib::idle_add (g_idle_add) is the doorbell, carrying no
//! data.

use std::cell::RefCell;
use std::rc::Rc;
use std::sync::atomic::{AtomicI32, Ordering};
use std::sync::mpsc::Receiver;

use gtk4::glib;
use gtk4::prelude::*;

use crate::protocol::{Command, OccSink, Occurrence, skeleton};

struct CoreState {
    commands: Receiver<Command>,
    occurrences: OccSink,
    label: gtk4::Label,
    button: gtk4::Button,
    app: gtk4::Application,
}

impl Drop for CoreState {
    fn drop(&mut self) {
        self.occurrences.send(Occurrence::Shutdown);
    }
}

thread_local! {
    static CORE: RefCell<Option<CoreState>> = const { RefCell::new(None) };
}

static EXIT_CODE: AtomicI32 = AtomicI32::new(0);

/// Wake the main loop so it drains the command ring. Safe to call from
/// any thread; the idle source carries no data.
pub(crate) fn ring_doorbell() {
    glib::idle_add(|| {
        drain_commands();
        glib::ControlFlow::Break
    });
}

fn drain_commands() {
    CORE.with_borrow(|core| {
        let Some(core) = core.as_ref() else { return };
        while let Ok(command) = core.commands.try_recv() {
            match command {
                Command::SetText { id, text } => {
                    if id == skeleton::LABEL {
                        core.label.set_text(&text);
                    }
                }
            }
        }
    });
}

fn request_exit(code: i32) {
    EXIT_CODE.store(code, Ordering::Relaxed);
    CORE.with_borrow(|core| {
        if let Some(core) = core.as_ref() {
            core.app.quit();
        }
    });
}

/// The main-thread half, independent of who owns the app thread. Returns
/// the exit code; the host process decides how to exit.
pub(crate) fn run_core(occ_tx: OccSink, cmd_rx: Receiver<Command>) -> i32 {
    let app = gtk4::Application::builder()
        .application_id("dev.kaya.Milestone0")
        .build();

    // activate can fire more than once; the scene is built once.
    let cmd_rx = Rc::new(RefCell::new(Some(cmd_rx)));
    let occ_tx_for_activate = occ_tx.clone();
    app.connect_activate(move |app| {
        let Some(cmd_rx) = cmd_rx.borrow_mut().take() else {
            return;
        };
        build_scene(app, occ_tx_for_activate.clone(), cmd_rx);
    });

    let _ = app.run_with_args::<&str>(&[]);

    // GTK teardown is orderly; dropping CoreState here announces shutdown
    // through its Drop impl.
    CORE.with_borrow_mut(|core| {
        core.take();
    });
    EXIT_CODE.load(Ordering::Relaxed)
}

fn build_scene(app: &gtk4::Application, occ_tx: OccSink, cmd_rx: Receiver<Command>) {
    let window = gtk4::ApplicationWindow::builder()
        .application(app)
        .title("kaya milestone 0")
        .default_width(320)
        .default_height(160)
        .build();

    let vbox = gtk4::Box::new(gtk4::Orientation::Vertical, 8);
    let button = gtk4::Button::with_label("Click me");
    let label = gtk4::Label::new(Some("Clicked 0 times"));
    vbox.append(&button);
    vbox.append(&label);
    window.set_child(Some(&vbox));

    let click_sink = occ_tx.clone();
    button.connect_clicked(move |_| {
        click_sink.send(Occurrence::ButtonClicked {
            id: skeleton::BUTTON,
        });
    });

    window.present();

    if std::env::var_os("KAYA_SELFTEST").is_some() {
        spawn_selftest();
    }

    CORE.with_borrow_mut(|core| {
        *core = Some(CoreState {
            commands: cmd_rx,
            occurrences: occ_tx,
            label,
            button,
            app: app.clone(),
        });
    });
}

/// Drives the round trip without a human: emit_clicked raises the real
/// clicked signal on the main thread, the app thread answers with a
/// command, and the label text proves both directions worked.
fn spawn_selftest() {
    fn on_main(f: impl Fn() + Send + 'static) {
        glib::idle_add(move || {
            f();
            glib::ControlFlow::Break
        });
    }

    std::thread::spawn(|| {
        let click = || {
            on_main(|| {
                CORE.with_borrow(|core| {
                    if let Some(core) = core.as_ref() {
                        core.button.emit_clicked();
                    }
                });
            });
        };

        std::thread::sleep(std::time::Duration::from_millis(800));
        click();
        std::thread::sleep(std::time::Duration::from_millis(300));
        click();
        std::thread::sleep(std::time::Duration::from_millis(700));

        on_main(|| {
            CORE.with_borrow(|core| {
                let Some(core) = core.as_ref() else { return };
                let text = core.label.text();
                if text == "Clicked 2 times" {
                    println!("KAYA_SELFTEST: OK ({text})");
                    request_exit(0);
                } else {
                    eprintln!("KAYA_SELFTEST: FAILED (label reads {text:?})");
                    request_exit(1);
                }
            });
        });
    });
}
