//! Android backend, milestone 1: an interpreter of resolved apply-ops,
//! built on android.widget through JNI.
//!
//! Same protocol as every other backend — transactions resolve through
//! the scene core into Create/SetProp/AddChild/Mount ops mapped onto
//! LinearLayout, Button, and TextView; a button's click pushes an
//! occurrence carrying its widget id and never calls app code; a posted
//! Runnable is the doorbell, carrying no data. The hosting is inverted:
//! Android has no native process entry (Zygote forks the process,
//! ActivityThread owns main), so the Activity calls the attach entry on
//! the UI thread during onCreate; it sets up, spawns the app thread, and
//! returns the thread to Android's Looper.
//!
//! The Kotlin side is small classes under android/kaya/ whose native
//! methods are registered here rather than resolved by name, so a guest
//! cdylib's only name-based export is its entry.

use std::collections::HashMap;
use std::sync::mpsc::{self, Receiver};
use std::sync::{Mutex, OnceLock};

use jni::objects::{GlobalRef, JByteArray, JString, JValue};
use jni::sys::{jint, jlong};
use jni::{JavaVM, NativeMethod};

use crate::app::AppCtx;
use crate::protocol::{
    ApplyOp, CommandKind, OccSink, Prop, Transaction, Value, WidgetId, WidgetKind,
};
use crate::scene::Scene;

// Public (doc-hidden) because the android_main! expansion names them.
#[doc(hidden)]
pub use jni::JNIEnv;
#[doc(hidden)]
pub use jni::objects::{JClass, JObject};
#[doc(hidden)]
pub use jni::sys::jint as jint_export;

/// attach return values: who plays the presentation role.
const PRESENT_CORE: i32 = 0;
const PRESENT_GUEST: i32 = 1;

/// Ops for KayaRunnable: which native step a posted hop performs.
const OP_DRAIN: jlong = 0;
const OP_HARNESS: jlong = 1;

/// Shared with the app thread (doorbell) and the selftest thread.
struct Globals {
    vm: JavaVM,
    activity: GlobalRef,
    drain: GlobalRef,
    harness_hop: GlobalRef,
}

static GLOBALS: OnceLock<Globals> = OnceLock::new();

struct NativeWidget {
    view: GlobalRef,
    kind: WidgetKind,
    /// Key into TAGS for a button's click identity.
    tag_key: Option<u64>,
}

/// Click tags by registry key. The Kotlin listener carries an opaque
/// long — this key — and nativeClick emits the tag it finds here. Its
/// own lock (never CORE's): clicks dispatch synchronously on the UI
/// thread from under performClick.
static TAGS: Mutex<Option<HashMap<u64, Vec<u8>>>> = Mutex::new(None);

/// Slider ranges by the same registry key. SeekBar is integer-valued
/// (a fixed 0..SEEK_SCALE progress range); the wire is f64 — this map
/// owns the conversion both ways. Same lock discipline as TAGS:
/// setProgress dispatches onProgressChanged synchronously.
static RANGES: Mutex<Option<HashMap<u64, (f64, f64)>>> = Mutex::new(None);
const SEEK_SCALE: f64 = 10000.0;

/// Steps posted by the harness thread, drained on the UI thread by the
/// OP_HARNESS runnable (closures need the UI thread's JNIEnv, which
/// only native_run holds).
type HarnessStep = Box<dyn FnOnce(&mut JNIEnv) + Send>;
static HARNESS_STEPS: Mutex<Vec<HarnessStep>> = Mutex::new(Vec::new());
static NEXT_TAG_KEY: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(1);

/// Touched only from the UI thread, but a Mutex keeps the types honest
/// (Receiver is Send, not Sync). Never hold this lock across a JNI call
/// that can dispatch back into native code (performClick reaches
/// native_click synchronously): clone the GlobalRef out first.
struct CoreState {
    transactions: Receiver<Transaction>,
    scene: Scene,
    widgets: HashMap<WidgetId, NativeWidget>,
    // Per-kind registries in creation order (stamped copies included):
    // the harness names targets as kind#index and drives each view
    // through its own listener path (performClick, setText,
    // setChecked, setProgress all fire the real listeners). Sliders
    // carry their tag key: the f64 range mapping lives in RANGES.
    buttons: Vec<GlobalRef>,
    checkboxes: Vec<GlobalRef>,
    labels: Vec<GlobalRef>,
    entries: Vec<GlobalRef>,
    sliders: Vec<(GlobalRef, u64)>,
    images: Vec<GlobalRef>,
    columns: Vec<GlobalRef>,
    rows: Vec<GlobalRef>,
    /// Grow weights by widget, so AddChild can re-stamp a weight that
    /// arrived before the child had a parent (addView installs fresh
    /// layout params and would otherwise drop it).
    grow: HashMap<WidgetId, f64>,
    /// The mounted root's view, for the root-fills observation.
    root: Option<GlobalRef>,
}

static CORE: Mutex<Option<CoreState>> = Mutex::new(None);

/// The click handler's copy of the occurrence sink; lock-free so a click
/// dispatched from under any lock cannot deadlock.
static OCC_SINK: OnceLock<OccSink> = OnceLock::new();

/// Wake the UI thread so it drains pending transactions. Safe to call
/// from any thread; the Runnable carries no data.
pub(crate) fn ring_doorbell() {
    let Some(g) = GLOBALS.get() else { return };
    let Ok(mut env) = g.vm.attach_current_thread_permanently() else {
        return;
    };
    let _ = env.call_method(
        g.activity.as_obj(),
        "runOnUiThread",
        "(Ljava/lang/Runnable;)V",
        &[JValue::Object(g.drain.as_obj())],
    );
}

/// Present for capi symmetry with the other backends; unreachable on
/// Android, where the OS owns the process entry.
pub(crate) fn run_core(_occurrences: OccSink, _transactions: Receiver<Transaction>) -> i32 {
    panic!("Android owns the process entry; start the core from an Activity via kaya::android_main!")
}

fn init_logging() {
    android_logger::init_once(
        android_logger::Config::default()
            .with_max_level(log::LevelFilter::Info)
            .with_tag("kaya"),
    );
    log_panics::init();
}

/// Android's attach, with the platform anchor explicit: the shell
/// Activity calls Kaya.attach(this) from onCreate on the UI thread, kaya
/// spawns the app thread, sets up the interpreter, and returns the
/// thread to the Looper — the host-owns-the-loop shape every Android app
/// has by construction.
///
/// Runtime backend selection lives inside the entry, as it does in
/// kaya::run: the return value says who presents. PRESENT_CORE means the
/// Views interpreter runs here; under KAYA_BACKEND=compose the
/// presentation-side plumbing is wired instead and PRESENT_GUEST tells
/// the Kotlin side to mount the Compose interpreter.
pub fn attach(
    mut env: JNIEnv,
    activity: JObject,
    app_main: impl FnOnce(AppCtx) + Send + 'static,
) -> i32 {
    init_logging();

    // Same shape as kaya::run's SwiftUI branch: the Compose pump consumes
    // resolved apply-ops through the C API, and its emissions route into
    // this AppCtx's inbox. (The environment is mapped from intent extras
    // by the Activity.)
    if std::env::var("KAYA_BACKEND").as_deref() == Ok("compose") {
        let (occ_tx, occ_rx) = mpsc::channel();
        let ctx = AppCtx::new(occ_rx, crate::capi::presentation_tx_sender());
        std::thread::Builder::new()
            .name("kaya-app".into())
            .spawn(move || app_main(ctx))
            .expect("failed to spawn the app thread");
        crate::capi::set_presentation_sink(OccSink::Mpsc(occ_tx));
        register_present_natives(&mut env)
            .expect("kaya: registering KayaPresent natives failed");
        return PRESENT_GUEST;
    }

    let (occ_tx, occ_rx) = mpsc::channel();
    let (tx_tx, tx_rx) = mpsc::channel();
    let ctx = AppCtx::new(occ_rx, tx_tx);
    std::thread::Builder::new()
        .name("kaya-app".into())
        .spawn(move || app_main(ctx))
        .expect("failed to spawn the app thread");

    setup(&mut env, &activity, OccSink::Mpsc(occ_tx), tx_rx)
        .expect("kaya: setting up the interpreter failed");
    PRESENT_CORE
}

/// Attach when the JVM app itself is the guest: sets up the Views
/// interpreter with the ring as the occurrence sink and returns; the
/// app's own thread consumes the ring through KayaRing (direct tier) and
/// answers with KayaRing.submit — the same core ends kaya_run hands a C
/// guest on the desktop, plus the Activity anchor Android requires.
/// Exported by name; this lives in kaya's own cdylib.
#[unsafe(no_mangle)]
extern "system" fn Java_dev_kaya_KayaRing_attach(
    mut env: JNIEnv,
    _class: JClass,
    activity: JObject,
) {
    init_logging();
    let (occ_sink, tx_rx) =
        crate::capi::take_core_ends().expect("KayaRing.attach may only be called once");
    register_ring_natives(&mut env).expect("kaya: registering KayaRing natives failed");
    setup(&mut env, &activity, occ_sink, tx_rx)
        .expect("kaya: setting up the interpreter failed");
}

fn setup(
    env: &mut JNIEnv,
    activity: &JObject,
    occ_tx: OccSink,
    tx_rx: Receiver<Transaction>,
) -> jni::errors::Result<()> {
    // Native methods are registered, not name-resolved: the guest cdylib
    // then exports only the entry symbol, and Kotlin classes stay free of
    // library-name coupling.
    let runnable_class = env.find_class("dev/kaya/KayaRunnable")?;
    env.register_native_methods(
        &runnable_class,
        &[NativeMethod {
            name: "nativeRun".into(),
            sig: "(J)V".into(),
            fn_ptr: native_run as *mut _,
        }],
    )?;
    let listener_class = env.find_class("dev/kaya/KayaClickListener")?;
    env.register_native_methods(
        &listener_class,
        &[NativeMethod {
            name: "nativeClick".into(),
            sig: "(J)V".into(),
            fn_ptr: native_click as *mut _,
        }],
    )?;
    let watcher_class = env.find_class("dev/kaya/KayaTextWatcher")?;
    env.register_native_methods(
        &watcher_class,
        &[NativeMethod {
            name: "nativeTextChanged".into(),
            sig: "(JLjava/lang/String;)V".into(),
            fn_ptr: native_text_changed as *mut _,
        }],
    )?;
    let check_class = env.find_class("dev/kaya/KayaCheckListener")?;
    env.register_native_methods(
        &check_class,
        &[NativeMethod {
            name: "nativeCheckedChanged".into(),
            sig: "(JZ)V".into(),
            fn_ptr: native_checked_changed as *mut _,
        }],
    )?;
    let seek_class = env.find_class("dev/kaya/KayaSeekListener")?;
    env.register_native_methods(
        &seek_class,
        &[NativeMethod {
            name: "nativeProgressChanged".into(),
            sig: "(JI)V".into(),
            fn_ptr: native_progress_changed as *mut _,
        }],
    )?;

    // The main-thread hops posted from native threads. Instances are made
    // here, on the UI thread, where find_class sees the app class loader;
    // attached native threads do not.
    let make_runnable = |env: &mut JNIEnv, op: jlong| -> jni::errors::Result<GlobalRef> {
        let runnable = env.new_object("dev/kaya/KayaRunnable", "(J)V", &[JValue::Long(op)])?;
        env.new_global_ref(runnable)
    };
    let drain = make_runnable(env, OP_DRAIN)?;
    let harness_hop = make_runnable(env, OP_HARNESS)?;

    let globals = Globals {
        vm: env.get_java_vm()?,
        activity: env.new_global_ref(activity)?,
        drain,
        harness_hop,
    };
    let _ = GLOBALS.set(globals);

    let _ = OCC_SINK.set(occ_tx);
    *TAGS.lock().unwrap() = Some(HashMap::new());
    *RANGES.lock().unwrap() = Some(HashMap::new());
    *CORE.lock().unwrap() = Some(CoreState {
        transactions: tx_rx,
        scene: Scene::new(),
        widgets: HashMap::new(),
        buttons: Vec::new(),
        checkboxes: Vec::new(),
        labels: Vec::new(),
        entries: Vec::new(),
        sliders: Vec::new(),
        images: Vec::new(),
        columns: Vec::new(),
        rows: Vec::new(),
        grow: HashMap::new(),
        root: None,
    });

    if let Ok(scene) = std::env::var("KAYA_SELFTEST") {
        crate::harness::spawn(&scene, AndroidStage, |line| log::info!("{line}"));
    }

    // The first transaction may already be queued; drain now.
    drain_transactions(env)?;
    Ok(())
}

fn drain_transactions(env: &mut JNIEnv) -> jni::errors::Result<()> {
    loop {
        // Take one transaction and resolve it with the lock held, then
        // release before touching JNI (performClick and friends dispatch
        // back into native code on this thread).
        let ops = {
            let mut core = CORE.lock().unwrap();
            let Some(core) = core.as_mut() else {
                return Ok(());
            };
            match core.transactions.try_recv() {
                Ok(tx) => core.scene.apply(tx),
                Err(_) => return Ok(()),
            }
        };
        for op in ops {
            apply(env, op)?;
        }
    }
}

/// The normalized layout default's spacing rung: 8 dp between adjacent
/// children. LinearLayout has no spacing property, so it is synthesized
/// as a transparent divider of that size shown only *between* children
/// (SHOW_DIVIDER_MIDDLE = 2) — no leading gap before the first child,
/// no trailing gap after the last. Applied to both axes: the
/// LinearLayout takes the divider's intrinsic height (vertical column)
/// or width (horizontal row) as the inter-child gap. Cross-axis stays
/// the native TOP|START, so children pack to the leading corner at
/// natural size, matching the AppKit/SwiftUI normalized default.
/// Apply one child's grow weight to its LinearLayout params — Android's
/// half of the `grow` contract, and the cheapest of the seven.
///
/// LinearLayout has real per-child weights, and `layout_weight` with a 0
/// main-axis dimension is exactly [`Prop::Grow`]: the zero makes the
/// child contribute nothing to the natural pass, so the whole leftover
/// is divided among the weighted children in proportion. No constraint
/// arithmetic and no custom layout, unlike AppKit/UIKit and GTK.
///
/// Re-applied from AddChild as well as from the prop write: addView
/// installs fresh default params, which would otherwise discard a weight
/// that arrived before the child was attached.
fn apply_grow(env: &mut JNIEnv, view: &JObject, weight: f64) -> jni::errors::Result<()> {
    let params = env
        .call_method(view, "getLayoutParams", "()Landroid/view/ViewGroup$LayoutParams;", &[])?
        .l()?;
    if params.is_null() {
        // Not attached yet: AddChild will call back here once addView
        // has installed the params.
        return Ok(());
    }
    // The parent decides which axis is the main one; a weight means
    // nothing without it.
    let parent = env
        .call_method(view, "getParent", "()Landroid/view/ViewParent;", &[])?
        .l()?;
    if parent.is_null() {
        return Ok(());
    }
    let vertical = env
        .call_method(&parent, "getOrientation", "()I", &[])?
        .i()?
        == 1;
    env.set_field(&params, "weight", "F", JValue::Float(weight as f32))?;
    // 0 on the main axis for a grower (flex-basis 0), WRAP_CONTENT (-2)
    // when the weight goes back to 0 — or the child would stay collapsed
    // after it stopped growing.
    let main = if weight > 0.0 { 0 } else { -2 };
    if vertical {
        env.set_field(&params, "height", "I", JValue::Int(main))?;
    } else {
        env.set_field(&params, "width", "I", JValue::Int(main))?;
    }
    env.call_method(
        view,
        "setLayoutParams",
        "(Landroid/view/ViewGroup$LayoutParams;)V",
        &[JValue::Object(&params)],
    )?;
    Ok(())
}

/// Span a nested container across its parent's breadth — the Android
/// spelling of the rule UIKit pins with a constraint and KayaFlex
/// spells as "offer the full cross extent": a row in a column is as
/// wide as the column, a column in a row as tall as the row.
///
/// On this backend the rule is load-bearing for grow, not merely
/// visual: LinearLayout honors layout_weight only when its own axis
/// extent is definite, and a WRAP_CONTENT row quietly hands weighted
/// children their NATURAL sizes instead — the grow scene's first row
/// assertion here read 28/72, the natural ratio of a label and a
/// button, where the contract said 25/75. Same-axis nesting takes no
/// stamp: the parent's own distribution governs its main axis.
///
/// Re-applied wherever addView runs (AddChild and MoveChild both), for
/// the same reason grow is: addView installs fresh layout params.
fn apply_breadth(
    env: &mut JNIEnv,
    parent: &JObject,
    child: &JObject,
    child_kind: WidgetKind,
) -> jni::errors::Result<()> {
    if !matches!(child_kind, WidgetKind::Row | WidgetKind::Column) {
        return Ok(());
    }
    let vertical_parent = env
        .call_method(parent, "getOrientation", "()I", &[])?
        .i()?
        == 1;
    let horizontal_child = matches!(child_kind, WidgetKind::Row);
    if vertical_parent != horizontal_child {
        return Ok(());
    }
    let params = env
        .call_method(
            child,
            "getLayoutParams",
            "()Landroid/view/ViewGroup$LayoutParams;",
            &[],
        )?
        .l()?;
    if params.is_null() {
        return Ok(());
    }
    // MATCH_PARENT (-1) on the child's own main axis, which is the
    // parent's cross axis.
    if horizontal_child {
        env.set_field(&params, "width", "I", JValue::Int(-1))?;
    } else {
        env.set_field(&params, "height", "I", JValue::Int(-1))?;
    }
    env.call_method(
        child,
        "setLayoutParams",
        "(Landroid/view/ViewGroup$LayoutParams;)V",
        &[JValue::Object(&params)],
    )?;
    Ok(())
}

fn set_child_spacing(
    env: &mut JNIEnv,
    view: &JObject,
    activity: &JObject,
) -> jni::errors::Result<()> {
    // 8 dp -> px through the display metrics density.
    let resources = env
        .call_method(activity, "getResources", "()Landroid/content/res/Resources;", &[])?
        .l()?;
    let metrics = env
        .call_method(&resources, "getDisplayMetrics", "()Landroid/util/DisplayMetrics;", &[])?
        .l()?;
    let density = env.get_field(&metrics, "density", "F")?.f()?;
    let px = (8.0 * density).round() as i32;

    let divider = env.new_object("android/graphics/drawable/GradientDrawable", "()V", &[])?;
    env.call_method(&divider, "setSize", "(II)V", &[JValue::Int(px), JValue::Int(px)])?;
    // Transparent: the gap is space, not a visible rule.
    env.call_method(&divider, "setColor", "(I)V", &[JValue::Int(0)])?;
    env.call_method(
        view,
        "setDividerDrawable",
        "(Landroid/graphics/drawable/Drawable;)V",
        &[JValue::Object(&divider)],
    )?;
    env.call_method(view, "setShowDividers", "(I)V", &[JValue::Int(2)])?;
    Ok(())
}

fn apply(env: &mut JNIEnv, op: ApplyOp) -> jni::errors::Result<()> {
    let activity = GLOBALS.get().expect("attach ran").activity.clone();
    match op {
        ApplyOp::Create { id, kind, tag } => {
            let class = match kind {
                WidgetKind::Entry => "android/widget/EditText",
                WidgetKind::Column | WidgetKind::Row => "android/widget/LinearLayout",
                WidgetKind::Button => "android/widget/Button",
                WidgetKind::Label => "android/widget/TextView",
                WidgetKind::Checkbox => "android/widget/CheckBox",
                WidgetKind::Slider => "android/widget/SeekBar",
                WidgetKind::Image => "android/widget/ImageView",
            };
            let view = env.new_object(
                class,
                "(Landroid/content/Context;)V",
                &[JValue::Object(activity.as_obj())],
            )?;
            let mut tag_key = None;
            match kind {
                WidgetKind::Column => {
                    // Normalized default: vertical axis (LinearLayout.VERTICAL
                    // = 1), children packed to the top at natural size (native
                    // TOP|START), 8 dp between adjacent children.
                    env.call_method(&view, "setOrientation", "(I)V", &[JValue::Int(1)])?;
                    set_child_spacing(env, &view, activity.as_obj())?;
                }
                WidgetKind::Row => {
                    // Normalized default: horizontal axis
                    // (LinearLayout.HORIZONTAL = 0), children packed to the
                    // leading edge at natural size, 8 dp between them.
                    env.call_method(&view, "setOrientation", "(I)V", &[JValue::Int(0)])?;
                    // Cross-axis = top (START). LinearLayout defaults
                    // baselineAligned=true, which drops shorter children to
                    // the text baseline; turn it off so unequal-height
                    // children align to the row's top edge, matching the
                    // Compose Alignment.Top and the AppKit/SwiftUI default.
                    env.call_method(&view, "setBaselineAligned", "(Z)V", &[JValue::Bool(0)])?;
                    set_child_spacing(env, &view, activity.as_obj())?;
                }
                WidgetKind::Button => {
                    // The tag is the click's identity, emitted verbatim;
                    // the listener carries only a registry key.
                    let tag = tag.expect("buttons carry a click tag");
                    let key = NEXT_TAG_KEY.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
                    TAGS.lock().unwrap().as_mut().expect("attach ran").insert(key, tag);
                    tag_key = Some(key);
                    let listener = env.new_object(
                        "dev/kaya/KayaClickListener",
                        "(J)V",
                        &[JValue::Long(key as jlong)],
                    )?;
                    env.call_method(
                        &view,
                        "setOnClickListener",
                        "(Landroid/view/View$OnClickListener;)V",
                        &[JValue::Object(&listener)],
                    )?;
                }
                WidgetKind::Label => {}
                // Display-only, like Label: no tag, no listener. The
                // source arrives as a SetProp blob and decodes there.
                WidgetKind::Image => {}
                WidgetKind::Entry => {
                    // Uncontrolled: the widget owns its text; the
                    // watcher reports each edit (programmatic setText
                    // included, which is what lets the selftest type
                    // like a user) with the entry's identity tag, and
                    // the app folds it into its own model.
                    let tag = tag.expect("entries carry a tag");
                    let key = NEXT_TAG_KEY.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
                    TAGS.lock().unwrap().as_mut().expect("attach ran").insert(key, tag);
                    tag_key = Some(key);
                    let watcher = env.new_object(
                        "dev/kaya/KayaTextWatcher",
                        "(J)V",
                        &[JValue::Long(key as jlong)],
                    )?;
                    env.call_method(
                        &view,
                        "addTextChangedListener",
                        "(Landroid/text/TextWatcher;)V",
                        &[JValue::Object(&watcher)],
                    )?;
                }
                WidgetKind::Slider => {
                    // The bar owns its position; the listener reports
                    // each change (programmatic setProgress included,
                    // which is what lets the selftest drag like a
                    // user). SeekBar is integer-valued: a fixed
                    // 0..SEEK_SCALE progress range, mapped to the
                    // wire's f64 range through RANGES.
                    let tag = tag.expect("sliders carry a tag");
                    let key = NEXT_TAG_KEY.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
                    TAGS.lock().unwrap().as_mut().expect("attach ran").insert(key, tag);
                    RANGES.lock().unwrap().as_mut().expect("attach ran").insert(key, (0.0, 1.0));
                    tag_key = Some(key);
                    env.call_method(
                        &view,
                        "setMax",
                        "(I)V",
                        &[JValue::Int(SEEK_SCALE as i32)],
                    )?;
                    let listener = env.new_object(
                        "dev/kaya/KayaSeekListener",
                        "(J)V",
                        &[JValue::Long(key as jlong)],
                    )?;
                    env.call_method(
                        &view,
                        "setOnSeekBarChangeListener",
                        "(Landroid/widget/SeekBar$OnSeekBarChangeListener;)V",
                        &[JValue::Object(&listener)],
                    )?;
                }
                WidgetKind::Checkbox => {
                    // The box owns its checked bit; the listener reports
                    // each flip (programmatic setChecked included, which
                    // is what lets the selftest click like a user) with
                    // the box's identity tag.
                    let tag = tag.expect("checkboxes carry a tag");
                    let key = NEXT_TAG_KEY.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
                    TAGS.lock().unwrap().as_mut().expect("attach ran").insert(key, tag);
                    tag_key = Some(key);
                    let listener = env.new_object(
                        "dev/kaya/KayaCheckListener",
                        "(J)V",
                        &[JValue::Long(key as jlong)],
                    )?;
                    env.call_method(
                        &view,
                        "setOnCheckedChangeListener",
                        "(Landroid/widget/CompoundButton$OnCheckedChangeListener;)V",
                        &[JValue::Object(&listener)],
                    )?;
                }
            }
            let view = env.new_global_ref(view)?;
            let mut core = CORE.lock().unwrap();
            let core = core.as_mut().expect("core set up");
            match kind {
                WidgetKind::Button => core.buttons.push(view.clone()),
                WidgetKind::Label => core.labels.push(view.clone()),
                WidgetKind::Entry => core.entries.push(view.clone()),
                WidgetKind::Checkbox => core.checkboxes.push(view.clone()),
                WidgetKind::Slider => core
                    .sliders
                    .push((view.clone(), tag_key.expect("sliders carry a tag"))),
                WidgetKind::Image => core.images.push(view.clone()),
                WidgetKind::Column => core.columns.push(view.clone()),
                WidgetKind::Row => core.rows.push(view.clone()),
                _ => {}
            }
            core.widgets.insert(id, NativeWidget { view, kind, tag_key });
        }
        ApplyOp::MoveChild {
            parent,
            child,
            before,
        } => {
            let (parent_view, parent_kind) = with_widget(parent, |w| (w.view.clone(), w.kind));
            assert!(
                matches!(parent_kind, WidgetKind::Column | WidgetKind::Row),
                "kaya: move_child parent is not a container"
            );
            let child_view = with_widget(child, |w| w.view.clone());
            env.call_method(
                parent_view.as_obj(),
                "removeView",
                "(Landroid/view/View;)V",
                &[(&child_view).into()],
            )
            .expect("removeView");
            match before {
                Some(anchor) => {
                    let anchor_view = with_widget(anchor, |w| w.view.clone());
                    let index = env
                        .call_method(
                            parent_view.as_obj(),
                            "indexOfChild",
                            "(Landroid/view/View;)I",
                            &[(&anchor_view).into()],
                        )
                        .expect("indexOfChild")
                        .i()
                        .expect("int");
                    env.call_method(
                        parent_view.as_obj(),
                        "addView",
                        "(Landroid/view/View;I)V",
                        &[(&child_view).into(), index.into()],
                    )
                    .expect("addView at index");
                }
                None => {
                    env.call_method(
                        parent_view.as_obj(),
                        "addView",
                        "(Landroid/view/View;)V",
                        &[(&child_view).into()],
                    )
                    .expect("addView");
                }
            }
            // The re-add installed fresh params, exactly like AddChild:
            // re-stamp the breadth rule and the weight, or a moved
            // container would arrive de-spanned and a moved grower
            // would arrive weightless.
            let child_kind = with_widget(child, |w| w.kind);
            apply_breadth(env, parent_view.as_obj(), child_view.as_obj(), child_kind)?;
            let weight = with_core(|core| core.grow.get(&child).copied().unwrap_or(0.0));
            if weight > 0.0 {
                apply_grow(env, child_view.as_obj(), weight)?;
            }
        }
        ApplyOp::Destroy { id } => {
            let widget = {
                let mut core = CORE.lock().unwrap();
                let core = core.as_mut().expect("core set up");
                core.widgets.remove(&id).expect("scene validated the id")
            };
            if let Some(key) = widget.tag_key {
                if let Some(tags) = TAGS.lock().unwrap().as_mut() {
                    tags.remove(&key);
                }
            }
            let parent = env
                .call_method(widget.view.as_obj(), "getParent", "()Landroid/view/ViewParent;", &[])?
                .l()?;
            if !parent.is_null() {
                env.call_method(
                    &parent,
                    "removeView",
                    "(Landroid/view/View;)V",
                    &[JValue::Object(widget.view.as_obj())],
                )?;
            }
        }
        ApplyOp::SetProp { id, prop, value } => {
            let view = with_widget(id, |w| w.view.clone());
            match (prop, value) {
                (Prop::Text, Value::Str(s)) => {
                    let text = env.new_string(s)?;
                    // Button, TextView, and CheckBox share
                    // setText(CharSequence).
                    env.call_method(
                        view.as_obj(),
                        "setText",
                        "(Ljava/lang/CharSequence;)V",
                        &[JValue::Object(&text)],
                    )?;
                }
                (Prop::Checked, Value::Bool(b)) => {
                    env.call_method(view.as_obj(), "setChecked", "(Z)V", &[JValue::Bool(b as u8)])?;
                }
                (Prop::Value, Value::F64(v)) => {
                    let key = with_widget(id, |w| w.tag_key).expect("sliders carry a tag");
                    let (min, max) = RANGES
                        .lock()
                        .unwrap()
                        .as_ref()
                        .and_then(|r| r.get(&key).copied())
                        .unwrap_or((0.0, 1.0));
                    let span = if max > min { max - min } else { 1.0 };
                    let progress = (((v - min) / span) * SEEK_SCALE).round() as i32;
                    env.call_method(view.as_obj(), "setProgress", "(I)V", &[JValue::Int(progress)])?;
                }
                (Prop::Min, Value::F64(v)) => {
                    let key = with_widget(id, |w| w.tag_key).expect("sliders carry a tag");
                    if let Some(ranges) = RANGES.lock().unwrap().as_mut() {
                        ranges.entry(key).or_insert((0.0, 1.0)).0 = v;
                    }
                }
                (Prop::Max, Value::F64(v)) => {
                    let key = with_widget(id, |w| w.tag_key).expect("sliders carry a tag");
                    if let Some(ranges) = RANGES.lock().unwrap().as_mut() {
                        ranges.entry(key).or_insert((0.0, 1.0)).1 = v;
                    }
                }
                (Prop::Source, Value::Blob(blob)) => {
                    // Encoded bytes in, native decode:
                    // BitmapFactory.decodeByteArray. A null bitmap is
                    // the placeholder class (setImageBitmap never
                    // called, image_size reads 0x0), never a crash.
                    let bytes = env.byte_array_from_slice(&blob.0)?;
                    let bitmap = env
                        .call_static_method(
                            "android/graphics/BitmapFactory",
                            "decodeByteArray",
                            "([BII)Landroid/graphics/Bitmap;",
                            &[
                                JValue::Object(&bytes),
                                JValue::Int(0),
                                JValue::Int(blob.0.len() as i32),
                            ],
                        )?
                        .l()?;
                    if !bitmap.is_null() {
                        env.call_method(
                            view.as_obj(),
                            "setImageBitmap",
                            "(Landroid/graphics/Bitmap;)V",
                            &[JValue::Object(&bitmap)],
                        )?;
                    }
                }
                // Kind-agnostic, like the prop itself: the weight lands
                // on the child's layout params, which the parent reads.
                (Prop::Grow, Value::F64(weight)) => {
                    with_core(|core| core.grow.insert(id, weight));
                    apply_grow(env, view.as_obj(), weight)?;
                }
                (prop, value) => {
                    panic!("kaya: android cannot apply {prop:?} = {value:?} here")
                }
            }
        }
        ApplyOp::AddChild { parent, child } => {
            let (parent_view, parent_kind) = with_widget(parent, |w| (w.view.clone(), w.kind));
            assert!(
                matches!(parent_kind, WidgetKind::Column | WidgetKind::Row),
                "kaya: add_child parent is not a container"
            );
            let child_view = with_widget(child, |w| w.view.clone());
            env.call_method(
                parent_view.as_obj(),
                "addView",
                "(Landroid/view/View;)V",
                &[JValue::Object(child_view.as_obj())],
            )?;
            // addView installed fresh params; re-stamp the breadth
            // rule and any weight that arrived before the child had a
            // parent to weigh it against.
            let child_kind = with_widget(child, |w| w.kind);
            apply_breadth(env, parent_view.as_obj(), child_view.as_obj(), child_kind)?;
            let weight = with_core(|core| core.grow.get(&child).copied().unwrap_or(0.0));
            if weight > 0.0 {
                apply_grow(env, child_view.as_obj(), weight)?;
            }
        }
        ApplyOp::Mount { window: _, root } => {
            let root_view = with_widget(root, |w| w.view.clone());
            env.call_method(
                activity.as_obj(),
                "setContentView",
                "(Landroid/view/View;)V",
                &[JValue::Object(root_view.as_obj())],
            )?;
            // The normalized root inset: 16dp INSIDE the root (the
            // root still fills the content frame — expect_root_fills
            // holds), matching every other backend. Density-scaled:
            // padding is in pixels.
            let density = {
                let metrics = env
                    .call_method(
                        activity.as_obj(),
                        "getResources",
                        "()Landroid/content/res/Resources;",
                        &[],
                    )?
                    .l()?;
                let metrics = env
                    .call_method(
                        &metrics,
                        "getDisplayMetrics",
                        "()Landroid/util/DisplayMetrics;",
                        &[],
                    )?
                    .l()?;
                env.get_field(&metrics, "density", "F")?.f()?
            };
            let inset = (16.0 * density).round() as i32;
            env.call_method(
                root_view.as_obj(),
                "setPadding",
                "(IIII)V",
                &[
                    JValue::Int(inset),
                    JValue::Int(inset),
                    JValue::Int(inset),
                    JValue::Int(inset),
                ],
            )?;
            // setContentView installs MATCH_PARENT params, so the root
            // fills the content frame by construction — root_fills
            // measures it anyway rather than trusting this comment.
            with_core(|core| core.root = Some(root_view.clone()));
        }
        ApplyOp::Command { id, command } => {
            let view = with_widget(id, |w| w.view.clone());
            match command {
                CommandKind::Clear => {
                    // setText fires the KayaTextWatcher (programmatic
                    // set included — the Create arm's comment), so the
                    // empty edit reaches the app through the entry's
                    // own path — no manual emit.
                    let text = env.new_string("")?;
                    env.call_method(
                        view.as_obj(),
                        "setText",
                        "(Ljava/lang/CharSequence;)V",
                        &[JValue::Object(&text)],
                    )?;
                }
                CommandKind::Focus => {
                    // EditText is focusable in touch mode by default,
                    // so requestFocus lands without a focusability
                    // dance; per-window focus, never global key status.
                    env.call_method(view.as_obj(), "requestFocus", "()Z", &[])?;
                }
            }
        }
    }
    Ok(())
}

/// Run a closure against the core state. Never held across a JNI call
/// that can dispatch back into native code — see CoreState's note.
fn with_core<T>(f: impl FnOnce(&mut CoreState) -> T) -> T {
    let mut core = CORE.lock().unwrap();
    f(core.as_mut().expect("core set up"))
}

fn with_widget<T>(id: WidgetId, f: impl FnOnce(&NativeWidget) -> T) -> T {
    let core = CORE.lock().unwrap();
    let core = core.as_ref().expect("core set up");
    f(core.widgets.get(&id).expect("scene validated the id"))
}

/// KayaRunnable.nativeRun: a posted hop has arrived on the UI thread.
extern "system" fn native_run(mut env: JNIEnv, _this: JObject, op: jlong) {
    let result = match op {
        OP_DRAIN => drain_transactions(&mut env),
        OP_HARNESS => {
            let steps: Vec<HarnessStep> = std::mem::take(&mut HARNESS_STEPS.lock().unwrap());
            for step in steps {
                step(&mut env);
            }
            Ok(())
        }
        _ => Ok(()),
    };
    if let Err(e) = result {
        log::error!("kaya: UI-thread hop failed: {e}");
    }
}

/// KayaTextWatcher.nativeTextChanged: emit the entry's tag plus its new
/// text.
extern "system" fn native_text_changed(
    mut env: JNIEnv,
    _this: JObject,
    tag_key: jlong,
    text: JString,
) {
    let text: String = match env.get_string(&text) {
        Ok(t) => t.into(),
        Err(e) => {
            log::error!("kaya: reading entry text failed: {e}");
            return;
        }
    };
    let tag = TAGS
        .lock()
        .unwrap()
        .as_ref()
        .and_then(|tags| tags.get(&(tag_key as u64)).cloned());
    if let (Some(sink), Some(tag)) = (OCC_SINK.get(), tag) {
        sink.send_text_tag(&tag, &text);
    }
}

/// KayaCheckListener.nativeCheckedChanged: emit the checkbox's tag plus
/// its new state.
extern "system" fn native_checked_changed(
    _env: JNIEnv,
    _this: JObject,
    tag_key: jlong,
    checked: jni::sys::jboolean,
) {
    let tag = TAGS
        .lock()
        .unwrap()
        .as_ref()
        .and_then(|tags| tags.get(&(tag_key as u64)).cloned());
    if let (Some(sink), Some(tag)) = (OCC_SINK.get(), tag) {
        sink.send_toggle_tag(&tag, checked != 0);
    }
}

/// KayaSeekListener.nativeProgressChanged: map the SeekBar's integer
/// progress back to the wire's f64 range and emit it with the bar's
/// tag.
extern "system" fn native_progress_changed(
    _env: JNIEnv,
    _this: JObject,
    tag_key: jlong,
    progress: jni::sys::jint,
) {
    let tag = TAGS
        .lock()
        .unwrap()
        .as_ref()
        .and_then(|tags| tags.get(&(tag_key as u64)).cloned());
    let (min, max) = RANGES
        .lock()
        .unwrap()
        .as_ref()
        .and_then(|r| r.get(&(tag_key as u64)).copied())
        .unwrap_or((0.0, 1.0));
    if let (Some(sink), Some(tag)) = (OCC_SINK.get(), tag) {
        let value = min + (f64::from(progress) / SEEK_SCALE) * (max - min);
        sink.send_value_tag(&tag, value);
    }
}

/// KayaClickListener.nativeClick: emit the click tag the listener's
/// registry key names.
extern "system" fn native_click(_env: JNIEnv, _this: JObject, tag_key: jlong) {
    let tag = TAGS
        .lock()
        .unwrap()
        .as_ref()
        .and_then(|tags| tags.get(&(tag_key as u64)).cloned());
    if let (Some(sink), Some(tag)) = (OCC_SINK.get(), tag) {
        sink.send_click_tag(&tag);
    }
}

/// The harness stage: android.widget's native calls, each posted to
/// the UI thread through the OP_HARNESS runnable (JNI needs the UI
/// thread's env). performClick, setText, setChecked, and setProgress
/// all fire the real listeners, so every step travels the path a
/// user's gesture would. The CORE lock is never held across a JNI call
/// that can dispatch back into native code — refs are cloned out
/// first, the standing rule here.
struct AndroidStage;

impl AndroidStage {
    fn on_ui<T: Send + 'static>(f: impl FnOnce(&mut JNIEnv) -> T + Send + 'static) -> T {
        let (tx, rx) = std::sync::mpsc::channel();
        HARNESS_STEPS.lock().unwrap().push(Box::new(move |env| {
            let _ = tx.send(f(env));
        }));
        let g = GLOBALS.get().expect("attach ran");
        let mut env = g
            .vm
            .attach_current_thread_permanently()
            .expect("kaya: harness attach failed");
        env.call_method(
            g.activity.as_obj(),
            "runOnUiThread",
            "(Ljava/lang/Runnable;)V",
            &[JValue::Object(g.harness_hop.as_obj())],
        )
        .expect("kaya: harness post failed");
        rx.recv().expect("the UI thread applied the step")
    }

    fn view(f: impl FnOnce(&CoreState) -> GlobalRef) -> GlobalRef {
        let core = CORE.lock().unwrap();
        f(core.as_ref().expect("core set up"))
    }
}

impl crate::harness::Stage for AndroidStage {
    fn click(&self, t: crate::harness::Target) {
        let button = Self::view(|core| {
            core.buttons[crate::harness::resolve(t.index, core.buttons.len())].clone()
        });
        Self::on_ui(move |env| {
            let _ = env.call_method(button.as_obj(), "performClick", "()Z", &[]);
        });
    }

    fn toggle(&self, t: crate::harness::Target, on: bool) {
        let checkbox = Self::view(|core| {
            core.checkboxes[crate::harness::resolve(t.index, core.checkboxes.len())].clone()
        });
        Self::on_ui(move |env| {
            let _ = env.call_method(
                checkbox.as_obj(),
                "setChecked",
                "(Z)V",
                &[JValue::Bool(on as u8)],
            );
        });
    }

    fn set_value(&self, t: crate::harness::Target, value: f64) {
        let (slider, key) = {
            let core = CORE.lock().unwrap();
            let core = core.as_ref().expect("core set up");
            core.sliders[crate::harness::resolve(t.index, core.sliders.len())].clone()
        };
        let (min, max) = RANGES
            .lock()
            .unwrap()
            .as_ref()
            .and_then(|r| r.get(&key).copied())
            .unwrap_or((0.0, 1.0));
        let span = if max > min { max - min } else { 1.0 };
        let progress = (((value - min) / span) * SEEK_SCALE).round() as i32;
        Self::on_ui(move |env| {
            let _ = env.call_method(
                slider.as_obj(),
                "setProgress",
                "(I)V",
                &[JValue::Int(progress)],
            );
        });
    }

    fn set_text(&self, t: crate::harness::Target, text: &str) {
        let entry = Self::view(|core| {
            core.entries[crate::harness::resolve(t.index, core.entries.len())].clone()
        });
        let text = text.to_owned();
        Self::on_ui(move |env| {
            let s = env.new_string(&text).expect("kaya: text alloc failed");
            let _ = env.call_method(
                entry.as_obj(),
                "setText",
                "(Ljava/lang/CharSequence;)V",
                &[JValue::Object(&s)],
            );
        });
    }

    fn read_label(&self, t: crate::harness::Target) -> String {
        let label = Self::view(|core| {
            core.labels[crate::harness::resolve(t.index, core.labels.len())].clone()
        });
        Self::on_ui(move |env| {
            let chars = env
                .call_method(label.as_obj(), "getText", "()Ljava/lang/CharSequence;", &[])
                .and_then(|v| v.l())
                .expect("kaya: label read failed");
            let string = env
                .call_method(&chars, "toString", "()Ljava/lang/String;", &[])
                .and_then(|v| v.l())
                .expect("kaya: label toString failed");
            env.get_string(&JString::from(string))
                .expect("kaya: label decode failed")
                .into()
        })
    }

    fn read_text(&self, t: crate::harness::Target) -> String {
        let entry = Self::view(|core| {
            core.entries[crate::harness::resolve(t.index, core.entries.len())].clone()
        });
        Self::on_ui(move |env| {
            // getText through the TextView bridge signature: EditText's
            // covariant Editable override keeps a CharSequence bridge,
            // the same shape read_label uses.
            let chars = env
                .call_method(entry.as_obj(), "getText", "()Ljava/lang/CharSequence;", &[])
                .and_then(|v| v.l())
                .expect("kaya: entry read failed");
            let string = env
                .call_method(&chars, "toString", "()Ljava/lang/String;", &[])
                .and_then(|v| v.l())
                .expect("kaya: entry toString failed");
            env.get_string(&JString::from(string))
                .expect("kaya: entry decode failed")
                .into()
        })
    }

    fn image_size(&self, t: crate::harness::Target) -> String {
        let image = Self::view(|core| {
            core.images[crate::harness::resolve(t.index, core.images.len())].clone()
        });
        Self::on_ui(move |env| {
            // Read the bitmap's own pixel dimensions, not the
            // drawable's intrinsic size: BitmapDrawable scales
            // intrinsic sizes by display density, and the harness pins
            // decoded pixels. A null drawable is the placeholder class
            // (decode failed or no source yet): "0x0".
            let drawable = env
                .call_method(
                    image.as_obj(),
                    "getDrawable",
                    "()Landroid/graphics/drawable/Drawable;",
                    &[],
                )
                .and_then(|v| v.l())
                .expect("kaya: drawable read failed");
            if drawable.is_null() {
                return "0x0".into();
            }
            let bitmap = env
                .call_method(&drawable, "getBitmap", "()Landroid/graphics/Bitmap;", &[])
                .and_then(|v| v.l())
                .expect("kaya: bitmap read failed");
            if bitmap.is_null() {
                return "0x0".into();
            }
            let width = env
                .call_method(&bitmap, "getWidth", "()I", &[])
                .and_then(|v| v.i())
                .expect("kaya: bitmap width read failed");
            let height = env
                .call_method(&bitmap, "getHeight", "()I", &[])
                .and_then(|v| v.i())
                .expect("kaya: bitmap height read failed");
            format!("{width}x{height}")
        })
    }

    fn is_focused(&self, t: crate::harness::Target) -> bool {
        // Per-window focus (the view hierarchy's focused view), never
        // global key status — parallel legs must not steal each
        // other's assertion.
        let entry = match t.kind {
            crate::harness::TargetKind::Entry => Self::view(|core| {
                core.entries[crate::harness::resolve(t.index, core.entries.len())].clone()
            }),
            other => panic!("kaya: is_focused not wired for {other:?} on android"),
        };
        Self::on_ui(move |env| {
            env.call_method(entry.as_obj(), "isFocused", "()Z", &[])
                .and_then(|v| v.z())
                .expect("kaya: focus read failed")
        })
    }

    fn child_texts(&self, t: crate::harness::Target) -> String {
        let (column, labels) = {
            let core = CORE.lock().unwrap();
            let core = core.as_ref().expect("core set up");
            let registry = if matches!(t.kind, crate::harness::TargetKind::Column) {
                &core.columns
            } else {
                &core.rows
            };
            let i = crate::harness::resolve(t.index, registry.len());
            (registry[i].clone(), core.labels.clone())
        };
        Self::on_ui(move |env| {
            // Child order as the toolkit holds it — the registries are
            // creation-ordered and cannot observe a move.
            let count = env
                .call_method(column.as_obj(), "getChildCount", "()I", &[])
                .and_then(|v| v.i())
                .expect("kaya: child count read failed");
            let mut texts = Vec::new();
            for at in 0..count {
                let child = env
                    .call_method(
                        column.as_obj(),
                        "getChildAt",
                        "(I)Landroid/view/View;",
                        &[JValue::Int(at)],
                    )
                    .and_then(|v| v.l())
                    .expect("kaya: child read failed");
                let is_label = labels.iter().any(|l| {
                    env.is_same_object(&child, l.as_obj()).unwrap_or(false)
                });
                if !is_label {
                    continue;
                }
                let chars = env
                    .call_method(&child, "getText", "()Ljava/lang/CharSequence;", &[])
                    .and_then(|v| v.l())
                    .expect("kaya: child text read failed");
                let string = env
                    .call_method(&chars, "toString", "()Ljava/lang/String;", &[])
                    .and_then(|v| v.l())
                    .expect("kaya: child text toString failed");
                texts.push(String::from(
                    env.get_string(&JString::from(string))
                        .expect("kaya: child text decode failed"),
                ));
            }
            texts.join("|")
        })
    }

    fn child_shares(&self, t: crate::harness::Target) -> String {
        // Kind picks the registry and the axis: a column's children
        // split its height, a row's its width (the runner rejects any
        // other kind before it gets here).
        let vertical = matches!(t.kind, crate::harness::TargetKind::Column);
        let column = {
            let core = CORE.lock().unwrap();
            let core = core.as_ref().expect("core set up");
            let registry = if vertical { &core.columns } else { &core.rows };
            let i = crate::harness::resolve(t.index, registry.len());
            registry[i].clone()
        };
        Self::on_ui(move |env| {
            let count = env
                .call_method(column.as_obj(), "getChildCount", "()I", &[])
                .and_then(|v| v.i())
                .expect("kaya: child count read failed");
            // The kind picked the registry above; it picks the axis
            // here too. The first Android run of the row assertion
            // caught this loop still hard-wired to getHeight: the row's
            // tracks were a perfect 78/234 (measured live), and the
            // verb read the children's HEIGHTS — 19 and 48, "28,72" —
            // instead. Measured sizes, read after the layout pass the
            // harness's settle has already allowed for.
            let method = if vertical { "getHeight" } else { "getWidth" };
            let mut extents = Vec::new();
            for at in 0..count {
                let child = env
                    .call_method(
                        column.as_obj(),
                        "getChildAt",
                        "(I)Landroid/view/View;",
                        &[JValue::Int(at)],
                    )
                    .and_then(|v| v.l())
                    .expect("kaya: child read failed");
                let extent = env
                    .call_method(&child, method, "()I", &[])
                    .and_then(|v| v.i())
                    .expect("kaya: child extent read failed");
                extents.push(f64::from(extent));
            }
            crate::harness::shares(&extents)
        })
    }

    fn container_fills(&self, t: crate::harness::Target) -> String {
        let vertical = matches!(t.kind, crate::harness::TargetKind::Column);
        let column = {
            let core = CORE.lock().unwrap();
            let core = core.as_ref().expect("core set up");
            let registry = if vertical { &core.columns } else { &core.rows };
            let i = crate::harness::resolve(t.index, registry.len());
            registry[i].clone()
        };
        Self::on_ui(move |env| {
            let read = |env: &mut JNIEnv, obj: &JObject, method: &str| -> i32 {
                env.call_method(obj, method, "()I", &[])
                    .and_then(|v| v.i())
                    .expect("kaya: dimension read failed")
            };
            let obj = column.as_obj();
            // The content box: the container's extent minus its own
            // padding (the normalized root inset arrives as
            // setPadding; child edges are relative to the container).
            let (pad_start, pad_end, extent_m, start_m, end_m) = if vertical {
                ("getPaddingTop", "getPaddingBottom", "getHeight", "getTop", "getBottom")
            } else {
                ("getPaddingLeft", "getPaddingRight", "getWidth", "getLeft", "getRight")
            };
            let inner = read(env, &obj, extent_m)
                - read(env, &obj, pad_start)
                - read(env, &obj, pad_end);
            let count = read(env, &obj, "getChildCount");
            let mut min_start = i32::MAX;
            let mut max_end = i32::MIN;
            for at in 0..count {
                let child = env
                    .call_method(
                        &obj,
                        "getChildAt",
                        "(I)Landroid/view/View;",
                        &[JValue::Int(at)],
                    )
                    .and_then(|v| v.l())
                    .expect("kaya: child read failed");
                min_start = min_start.min(read(env, &child, start_m));
                max_end = max_end.max(read(env, &child, end_m));
            }
            if max_end < min_start {
                return "no children".to_owned();
            }
            let span = max_end - min_start;
            if (span - inner).abs() <= 2 {
                String::new()
            } else {
                format!("children span {span}px of {inner}px")
            }
        })
    }

    fn root_fills(&self) -> String {
        let root = {
            let core = CORE.lock().unwrap();
            let core = core.as_ref().expect("core set up");
            match &core.root {
                Some(view) => view.clone(),
                None => return "nothing mounted".to_owned(),
            }
        };
        Self::on_ui(move |env| {
            // The content frame (android.R.id.content) is what
            // setContentView hands the root; JNI dispatches getWidth on
            // the parent's actual class, so the ViewParent interface
            // type never enters it.
            let parent = env
                .call_method(root.as_obj(), "getParent", "()Landroid/view/ViewParent;", &[])
                .and_then(|v| v.l())
                .expect("kaya: root parent read failed");
            let read = |env: &mut JNIEnv, obj: &JObject, method: &str| -> i32 {
                env.call_method(obj, method, "()I", &[])
                    .and_then(|v| v.i())
                    .expect("kaya: dimension read failed")
            };
            let root_obj = root.as_obj();
            let (rw, rh) = (read(env, &root_obj, "getWidth"), read(env, &root_obj, "getHeight"));
            let (pw, ph) = (read(env, &parent, "getWidth"), read(env, &parent, "getHeight"));
            // Within two pixels: rounding is not a hug.
            if (rw - pw).abs() <= 2 && (rh - ph).abs() <= 2 {
                String::new()
            } else {
                format!("{rw}x{rh}px inside {pw}x{ph}px")
            }
        })
    }

    fn finish(&self, code: i32, verdict: &str) {
        let verdict = verdict.to_owned();
        // A library must not kill its host, but the selftest app is the
        // host; finish the task first so the exit reads as intentional.
        // _exit rather than exit: libc atexit handlers tear down HWUI's
        // mutexes while its render threads still run.
        Self::on_ui(move |env| {
            if code == 0 {
                log::info!("{verdict}");
            } else {
                log::error!("{verdict}");
            }
            if let Some(g) = GLOBALS.get() {
                let _ = env.call_method(g.activity.as_obj(), "finishAndRemoveTask", "()V", &[]);
            }
            unsafe { libc::_exit(code) };
        });
    }
}

// Raw addresses rather than direct ByteBuffers: ART's interpreter path
// for byte-buffer-view VarHandles truncates a direct buffer's native
// address to 32 bits (var_handle.cc, `static_cast<uint32_t>` on the
// address field), so VarHandle-over-NewDirectByteBuffer faults on any
// real heap address. Unsafe address-based access takes the address as a
// jlong and is unaffected.
fn register_ring_natives(env: &mut JNIEnv) -> jni::errors::Result<()> {
    let class = env.find_class("dev/kaya/KayaRing")?;
    env.register_native_methods(
        &class,
        &[
            NativeMethod {
                name: "dataAddress".into(),
                sig: "()J".into(),
                fn_ptr: ring_data_address as *mut _,
            },
            NativeMethod {
                name: "capacity".into(),
                sig: "()I".into(),
                fn_ptr: ring_capacity as *mut _,
            },
            NativeMethod {
                name: "headAddress".into(),
                sig: "()J".into(),
                fn_ptr: ring_head_address as *mut _,
            },
            NativeMethod {
                name: "tailAddress".into(),
                sig: "()J".into(),
                fn_ptr: ring_tail_address as *mut _,
            },
            NativeMethod {
                name: "waitOccurrences".into(),
                sig: "()Z".into(),
                fn_ptr: ring_wait as *mut _,
            },
            NativeMethod {
                name: "blobRegister".into(),
                sig: "([B)J".into(),
                fn_ptr: ring_blob_register as *mut _,
            },
            NativeMethod {
                name: "specHash".into(),
                sig: "()J".into(),
                fn_ptr: ring_spec_hash as *mut _,
            },
            NativeMethod {
                name: "submit".into(),
                sig: "([B)V".into(),
                fn_ptr: ring_submit as *mut _,
            },
        ],
    )
}

extern "system" fn ring_data_address(_env: JNIEnv, _class: JClass) -> jlong {
    crate::capi::ring_raw().0 as jlong
}

extern "system" fn ring_capacity(_env: JNIEnv, _class: JClass) -> jint {
    crate::capi::ring_raw().1 as jint
}

extern "system" fn ring_head_address(_env: JNIEnv, _class: JClass) -> jlong {
    crate::capi::ring_raw().2 as jlong
}

extern "system" fn ring_tail_address(_env: JNIEnv, _class: JClass) -> jlong {
    crate::capi::ring_raw().3 as jlong
}

extern "system" fn ring_wait(_env: JNIEnv, _class: JClass) -> jni::sys::jboolean {
    crate::capi::kaya_wait_occurrences() as jni::sys::jboolean
}

/// KayaRing.submit: one transaction as a byte array, kaya_submit's JNI
/// spelling (JVM guests cannot call C directly).
extern "system" fn ring_spec_hash(_env: JNIEnv, _class: JClass) -> jni::sys::jlong {
    crate::spec::hash() as jni::sys::jlong
}

extern "system" fn ring_submit(mut env: JNIEnv, _class: JClass, records: JByteArray) {
    let bytes = env
        .convert_byte_array(&records)
        .expect("kaya: reading the submitted transaction failed");
    unsafe { crate::capi::kaya_submit(bytes.as_ptr(), bytes.len()) };
}

/// KayaRing.blobRegister: kaya_blob_register's JNI spelling — the JVM
/// guest's bulk-payload entry (one copy into core memory; the handle
/// is consumed by the next submit).
extern "system" fn ring_blob_register(
    mut env: JNIEnv,
    _class: JClass,
    data: JByteArray,
) -> jni::sys::jlong {
    let bytes = env
        .convert_byte_array(&data)
        .expect("kaya: reading the blob bytes failed");
    (unsafe { crate::capi::kaya_blob_register(bytes.as_ptr(), bytes.len()) }) as jni::sys::jlong
}

// The presentation-side C API over JNI, for guest-language backends
// (Compose): emissions in, resolved apply-op records out, mirroring
// KayaHostApi on the Apple side.
fn register_present_natives(env: &mut JNIEnv) -> jni::errors::Result<()> {
    let class = env.find_class("dev/kaya/KayaPresent")?;
    env.register_native_methods(
        &class,
        &[
            NativeMethod {
                name: "emitClicked".into(),
                sig: "([B)V".into(),
                fn_ptr: present_emit as *mut _,
            },
            NativeMethod {
                name: "emitTextChanged".into(),
                sig: "([BLjava/lang/String;)V".into(),
                fn_ptr: present_emit_text as *mut _,
            },
            NativeMethod {
                name: "emitToggled".into(),
                sig: "([BZ)V".into(),
                fn_ptr: present_emit_toggled as *mut _,
            },
            NativeMethod {
                name: "emitValueChanged".into(),
                sig: "([BD)V".into(),
                fn_ptr: present_emit_value_changed as *mut _,
            },
            NativeMethod {
                name: "nextCommands".into(),
                sig: "([B)I".into(),
                fn_ptr: present_next_commands as *mut _,
            },
            NativeMethod {
                name: "blobData".into(),
                sig: "(J)[B".into(),
                fn_ptr: present_blob_data as *mut _,
            },
        ],
    )
}

extern "system" fn present_emit(mut env: JNIEnv, _class: JClass, tag: JByteArray) {
    let bytes = env
        .convert_byte_array(&tag)
        .expect("kaya: reading the click tag failed");
    unsafe { crate::capi::kaya_emit_clicked(bytes.as_ptr(), bytes.len()) };
}

extern "system" fn present_emit_text(
    mut env: JNIEnv,
    _class: JClass,
    tag: JByteArray,
    text: JString,
) {
    let bytes = env
        .convert_byte_array(&tag)
        .expect("kaya: reading the entry tag failed");
    let text: String = env
        .get_string(&text)
        .expect("kaya: reading the entry text failed")
        .into();
    unsafe {
        crate::capi::kaya_emit_text_changed(
            bytes.as_ptr(),
            bytes.len(),
            text.as_ptr(),
            text.len(),
        )
    };
}

extern "system" fn present_emit_value_changed(
    mut env: JNIEnv,
    _class: JClass,
    tag: JByteArray,
    value: jni::sys::jdouble,
) {
    let bytes = env
        .convert_byte_array(&tag)
        .expect("kaya: reading the slider tag failed");
    unsafe { crate::capi::kaya_emit_value_changed(bytes.as_ptr(), bytes.len(), value) };
}

extern "system" fn present_emit_toggled(
    mut env: JNIEnv,
    _class: JClass,
    tag: JByteArray,
    checked: jni::sys::jboolean,
) {
    let bytes = env
        .convert_byte_array(&tag)
        .expect("kaya: reading the checkbox tag failed");
    unsafe { crate::capi::kaya_emit_toggled(bytes.as_ptr(), bytes.len(), checked) };
}

/// KayaPresent.blobData: fetch a blob's bytes by the handle an apply
/// record carried — kaya_blob_data's JNI spelling, copied into a fresh
/// byte[] (the JVM cannot borrow core memory safely). Null for a dead
/// handle (a batch already superseded); fetch within the batch.
extern "system" fn present_blob_data(
    mut env: JNIEnv,
    _class: JClass,
    handle: jlong,
) -> jni::sys::jbyteArray {
    let mut len: usize = 0;
    let data = unsafe { crate::capi::kaya_blob_data(handle as u64, &mut len) };
    if data.is_null() {
        return std::ptr::null_mut();
    }
    let bytes = unsafe { std::slice::from_raw_parts(data, len) };
    match env.byte_array_from_slice(bytes) {
        Ok(array) => array.into_raw(),
        Err(e) => {
            log::error!("kaya: copying blob bytes to the JVM failed: {e}");
            std::ptr::null_mut()
        }
    }
}

/// KayaPresent.nextCommands: block until the next transaction resolves,
/// fill the byte array with apply-op records, and return the length
/// (0 on shutdown).
extern "system" fn present_next_commands(
    mut env: JNIEnv,
    _class: JClass,
    out: JByteArray,
) -> jint {
    let cap = env
        .get_array_length(&out)
        .expect("kaya: reading the pump buffer length failed") as usize;
    let mut buf = vec![0u8; cap];
    let n = unsafe { crate::capi::kaya_next_commands(buf.as_mut_ptr(), cap) };
    if n == 0 {
        return 0;
    }
    let signed: &[i8] =
        unsafe { std::slice::from_raw_parts(buf.as_ptr() as *const i8, n) };
    env.set_byte_array_region(&out, 0, signed)
        .expect("kaya: filling the pump buffer failed");
    n as jint
}

/// Export the JNI entry that `dev.kaya.Kaya.attach` resolves, wiring
/// `$app` as the app-thread logic. The Android spelling of attach: the
/// shell Activity calls Kaya.attach(this) and this expansion answers it.
/// Returns who presents (Kaya.PRESENT_CORE or PRESENT_GUEST), decided by
/// runtime backend selection.
#[macro_export]
macro_rules! android_main {
    ($app:path) => {
        #[unsafe(no_mangle)]
        extern "system" fn Java_dev_kaya_Kaya_attach<'local>(
            env: $crate::android::JNIEnv<'local>,
            _class: $crate::android::JClass<'local>,
            activity: $crate::android::JObject<'local>,
        ) -> $crate::android::jint_export {
            $crate::android::attach(env, activity, $app)
        }
    };
}
