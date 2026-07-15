//! GTK4 backend, milestone 1: an interpreter of resolved apply-ops.
//!
//! Same architecture as the AppKit backend: the core owns the main
//! thread and the GLib main loop; transactions resolve through the scene
//! core into Create/SetProp/AddChild/Mount ops mapped onto gtk4::Box,
//! Button, and Label. The clicked signal pushes an occurrence carrying
//! the widget id and never calls app code; glib::idle_add (g_idle_add)
//! is the doorbell, carrying no data.

use std::cell::RefCell;
use std::collections::HashMap;
use std::rc::Rc;
use std::sync::atomic::{AtomicI32, Ordering};
use std::sync::mpsc::Receiver;

use gtk4::glib;
use gtk4::prelude::*;

use crate::protocol::{
    ApplyOp, OccSink, Occurrence, Prop, Transaction, Value, WidgetId, WidgetKind,
};
use crate::scene::Scene;

enum NativeWidget {
    Column(gtk4::Box),
    Button(gtk4::Button),
    Label(gtk4::Label),
}

impl NativeWidget {
    fn widget(&self) -> gtk4::Widget {
        match self {
            NativeWidget::Column(w) => w.clone().upcast(),
            NativeWidget::Button(w) => w.clone().upcast(),
            NativeWidget::Label(w) => w.clone().upcast(),
        }
    }
}

struct CoreState {
    transactions: Receiver<Transaction>,
    scene: Scene,
    occurrences: OccSink,
    widgets: HashMap<WidgetId, NativeWidget>,
    selftest_button: Option<gtk4::Button>,
    selftest_last_button: Option<gtk4::Button>,
    selftest_label: Option<gtk4::Label>,
    window: gtk4::Window,
    // None when attached... not yet on GTK; the app quits the loop.
    app: Option<gtk4::Application>,
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

/// Wake the main loop so it drains pending transactions. Safe to call
/// from any thread; the idle source carries no data.
pub(crate) fn ring_doorbell() {
    glib::idle_add(|| {
        drain_transactions();
        glib::ControlFlow::Break
    });
}

fn drain_transactions() {
    CORE.with_borrow_mut(|core| {
        let Some(core) = core.as_mut() else { return };
        while let Ok(tx) = core.transactions.try_recv() {
            for op in core.scene.apply(tx) {
                apply(core, op);
            }
        }
    });
}

fn apply(core: &mut CoreState, op: ApplyOp) {
    match op {
        ApplyOp::Create { id, kind, tag } => {
            let native = match kind {
                WidgetKind::Column => {
                    let column = gtk4::Box::new(gtk4::Orientation::Vertical, 8);
                    column.set_valign(gtk4::Align::Center);
                    column.set_halign(gtk4::Align::Center);
                    NativeWidget::Column(column)
                }
                WidgetKind::Button => {
                    let button = gtk4::Button::new();
                    let sink = core.occurrences.clone();
                    // The tag is the click's identity, emitted verbatim;
                    // this backend never learns what it means.
                    let tag = tag.expect("buttons carry a click tag");
                    button.connect_clicked(move |_| {
                        sink.send_click_tag(&tag);
                    });
                    if core.selftest_button.is_none() {
                        core.selftest_button = Some(button.clone());
                    }
                    core.selftest_last_button = Some(button.clone());
                    NativeWidget::Button(button)
                }
                WidgetKind::Label => {
                    let label = gtk4::Label::new(None);
                    if core.selftest_label.is_none() {
                        core.selftest_label = Some(label.clone());
                    }
                    NativeWidget::Label(label)
                }
            };
            core.widgets.insert(id, native);
        }
        ApplyOp::Destroy { id } => {
            let widget = core
                .widgets
                .remove(&id)
                .expect("scene validated the id")
                .widget();
            if let Some(parent) = widget.parent() {
                if let Ok(column) = parent.downcast::<gtk4::Box>() {
                    column.remove(&widget);
                }
            }
        }
        ApplyOp::SetProp { id, prop, value } => {
            let widget = core.widgets.get(&id).expect("scene validated the id");
            match (widget, prop, value) {
                (NativeWidget::Button(button), Prop::Text, Value::Str(s)) => {
                    button.set_label(&s);
                }
                (NativeWidget::Label(label), Prop::Text, Value::Str(s)) => {
                    label.set_text(&s);
                }
                (_, prop, value) => {
                    panic!("kaya: gtk cannot apply {prop:?} = {value:?} here")
                }
            }
        }
        ApplyOp::AddChild { parent, child } => {
            let child_widget = core
                .widgets
                .get(&child)
                .expect("scene validated the id")
                .widget();
            match core.widgets.get(&parent).expect("scene validated the id") {
                NativeWidget::Column(column) => column.append(&child_widget),
                _ => panic!("kaya: add_child parent is not a container"),
            }
        }
        ApplyOp::Mount { window: _, root } => {
            let root_widget = core
                .widgets
                .get(&root)
                .expect("scene validated the id")
                .widget();
            core.window.set_child(Some(&root_widget));
        }
    }
}

fn request_exit(code: i32) {
    EXIT_CODE.store(code, Ordering::Relaxed);
    CORE.with_borrow(|core| {
        let Some(core) = core.as_ref() else { return };
        match &core.app {
            Some(app) => app.quit(),
            None => std::process::exit(code),
        }
    });
}

/// The main-thread half, independent of who owns the app thread. Returns
/// the exit code; the host process decides how to exit.
pub(crate) fn run_core(occ_tx: OccSink, tx_rx: Receiver<Transaction>) -> i32 {
    let app = gtk4::Application::builder()
        .application_id("dev.kaya.Milestone0")
        .build();

    // activate can fire more than once; the core is set up once.
    let ends = Rc::new(RefCell::new(Some((occ_tx, tx_rx))));
    app.connect_activate(move |app| {
        let Some((occ_tx, tx_rx)) = ends.borrow_mut().take() else {
            return;
        };
        let window = gtk4::ApplicationWindow::builder()
            .application(app)
            .title("kaya milestone 0")
            .default_width(320)
            .default_height(160)
            .build();
        window.present();

        if std::env::var_os("KAYA_SELFTEST").is_some() {
            spawn_selftest();
        }

        CORE.with_borrow_mut(|core| {
            *core = Some(CoreState {
                transactions: tx_rx,
                scene: Scene::new(),
                occurrences: occ_tx,
                widgets: HashMap::new(),
                selftest_button: None,
                selftest_last_button: None,
                selftest_label: None,
                window: window.upcast(),
                app: Some(app.clone()),
            });
        });

        // The first transaction may already be queued; drain now.
        drain_transactions();
    });

    let _ = app.run_with_args::<&str>(&[]);

    // GTK teardown is orderly; dropping CoreState here announces shutdown
    // through its Drop impl.
    CORE.with_borrow_mut(|core| {
        core.take();
    });
    EXIT_CODE.load(Ordering::Relaxed)
}

/// Drives the round trip without a human: emit_clicked raises the real
/// clicked signal on the main thread — twice on the scene's driver
/// button (stamping groups, items, and the When), once on the most
/// recently stamped button (whose click travels as a template node plus
/// key path) — and the status label proves the whole loop.
fn spawn_selftest() {
    fn on_main(f: impl Fn() + Send + 'static) {
        glib::idle_add(move || {
            f();
            glib::ControlFlow::Break
        });
    }

    std::thread::spawn(|| {
        let click_first = || {
            on_main(|| {
                CORE.with_borrow(|core| {
                    if let Some(core) = core.as_ref() {
                        core.selftest_button
                            .as_ref()
                            .expect("the scene has a button")
                            .emit_clicked();
                    }
                });
            });
        };
        let click_last = || {
            on_main(|| {
                CORE.with_borrow(|core| {
                    if let Some(core) = core.as_ref() {
                        core.selftest_last_button
                            .as_ref()
                            .expect("the scene has stamped a button")
                            .emit_clicked();
                    }
                });
            });
        };

        std::thread::sleep(std::time::Duration::from_millis(800));
        click_first();
        std::thread::sleep(std::time::Duration::from_millis(300));
        click_first();
        std::thread::sleep(std::time::Duration::from_millis(400));
        click_last();
        std::thread::sleep(std::time::Duration::from_millis(700));

        on_main(|| {
            CORE.with_borrow(|core| {
                let Some(core) = core.as_ref() else { return };
                let text = core
                    .selftest_label
                    .as_ref()
                    .expect("the scene has a label")
                    .text();
                if text == "removed g2/a" {
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
