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
    Entry(gtk4::Entry),
    Row(gtk4::Box),
    Checkbox(gtk4::CheckButton),
    Slider(gtk4::Scale),
}

impl NativeWidget {
    fn widget(&self) -> gtk4::Widget {
        match self {
            NativeWidget::Column(w) => w.clone().upcast(),
            NativeWidget::Button(w) => w.clone().upcast(),
            NativeWidget::Label(w) => w.clone().upcast(),
            NativeWidget::Entry(w) => w.clone().upcast(),
            NativeWidget::Row(w) => w.clone().upcast(),
            NativeWidget::Checkbox(w) => w.clone().upcast(),
            NativeWidget::Slider(w) => w.clone().upcast(),
        }
    }
}

struct CoreState {
    transactions: Receiver<Transaction>,
    scene: Scene,
    occurrences: OccSink,
    widgets: HashMap<WidgetId, NativeWidget>,
    // Per-kind registries in creation order (stamped copies included):
    // the harness names targets as kind#index. GTK fires the real
    // signals for programmatic set_text/set_active/set_value, so the
    // stage drives each control exactly as a user would.
    buttons: Vec<gtk4::Button>,
    checkboxes: Vec<gtk4::CheckButton>,
    labels: Vec<gtk4::Label>,
    entries: Vec<gtk4::Entry>,
    sliders: Vec<gtk4::Scale>,
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
                WidgetKind::Entry => {
                    // Uncontrolled: the widget owns its text; each edit
                    // goes up with the entry's identity tag, and the
                    // app folds it into its own model. (GTK fires
                    // `changed` for programmatic set_text too, which is
                    // what lets the selftest type like a user.)
                    let entry = gtk4::Entry::new();
                    let sink = core.occurrences.clone();
                    let tag = tag.expect("entries carry a tag");
                    entry.connect_changed(move |e| {
                        sink.send_text_tag(&tag, e.text().as_str());
                    });
                    core.entries.push(entry.clone());
                    NativeWidget::Entry(entry)
                }
                WidgetKind::Column => {
                    let column = gtk4::Box::new(gtk4::Orientation::Vertical, 8);
                    column.set_valign(gtk4::Align::Center);
                    column.set_halign(gtk4::Align::Center);
                    NativeWidget::Column(column)
                }
                WidgetKind::Row => {
                    let row = gtk4::Box::new(gtk4::Orientation::Horizontal, 8);
                    row.set_valign(gtk4::Align::Center);
                    row.set_halign(gtk4::Align::Center);
                    NativeWidget::Row(row)
                }
                WidgetKind::Checkbox => {
                    // The box owns its checked bit; each flip goes up
                    // with the box's identity tag. (GTK fires `toggled`
                    // for programmatic set_active too, which is what
                    // lets the selftest click like a user.)
                    let check = gtk4::CheckButton::new();
                    let sink = core.occurrences.clone();
                    let tag = tag.expect("checkboxes carry a tag");
                    check.connect_toggled(move |c| {
                        sink.send_toggle_tag(&tag, c.is_active());
                    });
                    core.checkboxes.push(check.clone());
                    NativeWidget::Checkbox(check)
                }
                WidgetKind::Slider => {
                    // Uncontrolled, like the entry: the slider owns its
                    // position; each change goes up with its identity
                    // tag. (GTK fires `value-changed` for programmatic
                    // set_value too, which is what lets the selftest
                    // drag like a user.)
                    let scale =
                        gtk4::Scale::with_range(gtk4::Orientation::Horizontal, 0.0, 1.0, 0.01);
                    scale.set_size_request(160, -1);
                    let sink = core.occurrences.clone();
                    let tag = tag.expect("sliders carry a tag");
                    scale.connect_value_changed(move |sc| {
                        sink.send_value_tag(&tag, sc.value());
                    });
                    core.sliders.push(scale.clone());
                    NativeWidget::Slider(scale)
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
                    core.buttons.push(button.clone());
                    NativeWidget::Button(button)
                }
                WidgetKind::Label => {
                    let label = gtk4::Label::new(None);
                    core.labels.push(label.clone());
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
                (NativeWidget::Entry(entry), Prop::Text, Value::Str(s)) => {
                    entry.set_text(&s);
                }
                (NativeWidget::Checkbox(check), Prop::Text, Value::Str(s)) => {
                    check.set_label(Some(&s));
                }
                (NativeWidget::Checkbox(check), Prop::Checked, Value::Bool(b)) => {
                    check.set_active(b);
                }
                (NativeWidget::Slider(scale), Prop::Value, Value::F64(v)) => {
                    scale.set_value(v);
                }
                (NativeWidget::Slider(scale), Prop::Min, Value::F64(v)) => {
                    scale.adjustment().set_lower(v);
                }
                (NativeWidget::Slider(scale), Prop::Max, Value::F64(v)) => {
                    scale.adjustment().set_upper(v);
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
                NativeWidget::Row(row) => row.append(&child_widget),
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
        .application_id("dev.kaya.Milestone2")
        .build();

    // activate can fire more than once; the core is set up once.
    let ends = Rc::new(RefCell::new(Some((occ_tx, tx_rx))));
    app.connect_activate(move |app| {
        let Some((occ_tx, tx_rx)) = ends.borrow_mut().take() else {
            return;
        };
        let window = gtk4::ApplicationWindow::builder()
            .application(app)
            .title("kaya milestone 2")
            .default_width(320)
            .default_height(160)
            .build();
        window.present();

        if let Ok(scene) = std::env::var("KAYA_SELFTEST") {
            crate::harness::spawn(&scene, GtkStage, |line| println!("{line}"));
        }

        CORE.with_borrow_mut(|core| {
            *core = Some(CoreState {
                transactions: tx_rx,
                scene: Scene::new(),
                occurrences: occ_tx,
                widgets: HashMap::new(),
                buttons: Vec::new(),
                checkboxes: Vec::new(),
                labels: Vec::new(),
                entries: Vec::new(),
                sliders: Vec::new(),
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

/// The harness stage: GTK's native calls, each hopping to the main
/// context. Programmatic set_text/set_active/set_value fire the real
/// signals, so every step travels the path a user's gesture would.
struct GtkStage;

impl GtkStage {
    fn on_main<T: Send + 'static>(
        f: impl FnOnce(&CoreState) -> T + Send + 'static,
    ) -> T {
        let (tx, rx) = std::sync::mpsc::channel();
        let cell = std::cell::Cell::new(Some((f, tx)));
        glib::idle_add(move || {
            if let Some((f, tx)) = cell.take() {
                CORE.with_borrow(|core| {
                    let core = core.as_ref().expect("core state initialized");
                    let _ = tx.send(f(core));
                });
            }
            glib::ControlFlow::Break
        });
        rx.recv().expect("the main context applied the step")
    }
}

impl crate::harness::Stage for GtkStage {
    fn click(&self, t: crate::harness::Target) {
        Self::on_main(move |core| {
            let i = crate::harness::resolve(t.index, core.buttons.len());
            core.buttons[i].emit_clicked();
        });
    }

    fn toggle(&self, t: crate::harness::Target, on: bool) {
        Self::on_main(move |core| {
            let i = crate::harness::resolve(t.index, core.checkboxes.len());
            core.checkboxes[i].set_active(on);
        });
    }

    fn set_value(&self, t: crate::harness::Target, value: f64) {
        Self::on_main(move |core| {
            let i = crate::harness::resolve(t.index, core.sliders.len());
            core.sliders[i].set_value(value);
        });
    }

    fn set_text(&self, t: crate::harness::Target, text: &str) {
        let text = text.to_owned();
        Self::on_main(move |core| {
            let i = crate::harness::resolve(t.index, core.entries.len());
            core.entries[i].set_text(&text);
        });
    }

    fn read_label(&self, t: crate::harness::Target) -> String {
        Self::on_main(move |core| {
            let i = crate::harness::resolve(t.index, core.labels.len());
            core.labels[i].text().to_string()
        })
    }

    fn finish(&self, code: i32, verdict: &str) {
        if code == 0 {
            println!("{verdict}");
        } else {
            eprintln!("{verdict}");
        }
        // request_exit reads the main thread's CORE; hop before asking.
        Self::on_main(move |_| request_exit(code));
    }
}
