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
    ApplyOp, OccSink, Occurrence, Prop, Transaction, Value, WidgetId, WidgetKind,
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
const OP_SELFTEST_CLICK: jlong = 1;
const OP_SELFTEST_CHECK: jlong = 2;

/// Shared with the app thread (doorbell) and the selftest thread.
struct Globals {
    vm: JavaVM,
    activity: GlobalRef,
    drain: GlobalRef,
    selftest_click: GlobalRef,
    selftest_check: GlobalRef,
}

static GLOBALS: OnceLock<Globals> = OnceLock::new();

struct NativeWidget {
    view: GlobalRef,
    kind: WidgetKind,
}

/// Touched only from the UI thread, but a Mutex keeps the types honest
/// (Receiver is Send, not Sync). Never hold this lock across a JNI call
/// that can dispatch back into native code (performClick reaches
/// native_click synchronously): clone the GlobalRef out first.
struct CoreState {
    transactions: Receiver<Transaction>,
    scene: Scene,
    widgets: HashMap<WidgetId, NativeWidget>,
    selftest_button: Option<GlobalRef>,
    selftest_label: Option<GlobalRef>,
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

    // The main-thread hops posted from native threads. Instances are made
    // here, on the UI thread, where find_class sees the app class loader;
    // attached native threads do not.
    let make_runnable = |env: &mut JNIEnv, op: jlong| -> jni::errors::Result<GlobalRef> {
        let runnable = env.new_object("dev/kaya/KayaRunnable", "(J)V", &[JValue::Long(op)])?;
        env.new_global_ref(runnable)
    };
    let drain = make_runnable(env, OP_DRAIN)?;
    let selftest_click = make_runnable(env, OP_SELFTEST_CLICK)?;
    let selftest_check = make_runnable(env, OP_SELFTEST_CHECK)?;

    let globals = Globals {
        vm: env.get_java_vm()?,
        activity: env.new_global_ref(activity)?,
        drain,
        selftest_click,
        selftest_check,
    };
    let _ = GLOBALS.set(globals);

    let _ = OCC_SINK.set(occ_tx);
    *CORE.lock().unwrap() = Some(CoreState {
        transactions: tx_rx,
        scene: Scene::new(),
        widgets: HashMap::new(),
        selftest_button: None,
        selftest_label: None,
    });

    if std::env::var_os("KAYA_SELFTEST").is_some() {
        spawn_selftest();
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

fn apply(env: &mut JNIEnv, op: ApplyOp) -> jni::errors::Result<()> {
    let activity = GLOBALS.get().expect("attach ran").activity.clone();
    match op {
        ApplyOp::Create { id, kind } => {
            let class = match kind {
                WidgetKind::Column => "android/widget/LinearLayout",
                WidgetKind::Button => "android/widget/Button",
                WidgetKind::Label => "android/widget/TextView",
            };
            let view = env.new_object(
                class,
                "(Landroid/content/Context;)V",
                &[JValue::Object(activity.as_obj())],
            )?;
            match kind {
                WidgetKind::Column => {
                    // LinearLayout.VERTICAL = 1, Gravity.CENTER = 17.
                    env.call_method(&view, "setOrientation", "(I)V", &[JValue::Int(1)])?;
                    env.call_method(&view, "setGravity", "(I)V", &[JValue::Int(17)])?;
                }
                WidgetKind::Button => {
                    let listener = env.new_object(
                        "dev/kaya/KayaClickListener",
                        "(J)V",
                        &[JValue::Long(id.0 as jlong)],
                    )?;
                    env.call_method(
                        &view,
                        "setOnClickListener",
                        "(Landroid/view/View$OnClickListener;)V",
                        &[JValue::Object(&listener)],
                    )?;
                }
                WidgetKind::Label => {}
            }
            let view = env.new_global_ref(view)?;
            let mut core = CORE.lock().unwrap();
            let core = core.as_mut().expect("core set up");
            match kind {
                WidgetKind::Button if core.selftest_button.is_none() => {
                    core.selftest_button = Some(view.clone());
                }
                WidgetKind::Label if core.selftest_label.is_none() => {
                    core.selftest_label = Some(view.clone());
                }
                _ => {}
            }
            core.widgets.insert(id, NativeWidget { view, kind });
        }
        ApplyOp::SetProp { id, prop, value } => {
            let view = with_widget(id, |w| w.view.clone());
            match (prop, value) {
                (Prop::Text, Value::Str(s)) => {
                    let text = env.new_string(s)?;
                    // Button and TextView share setText(CharSequence).
                    env.call_method(
                        view.as_obj(),
                        "setText",
                        "(Ljava/lang/CharSequence;)V",
                        &[JValue::Object(&text)],
                    )?;
                }
                (prop, value) => {
                    panic!("kaya: android cannot apply {prop:?} = {value:?} here")
                }
            }
        }
        ApplyOp::AddChild { parent, child } => {
            let (parent_view, parent_kind) = with_widget(parent, |w| (w.view.clone(), w.kind));
            assert!(
                parent_kind == WidgetKind::Column,
                "kaya: add_child parent is not a container"
            );
            let child_view = with_widget(child, |w| w.view.clone());
            env.call_method(
                parent_view.as_obj(),
                "addView",
                "(Landroid/view/View;)V",
                &[JValue::Object(child_view.as_obj())],
            )?;
        }
        ApplyOp::Mount { window: _, root } => {
            let root_view = with_widget(root, |w| w.view.clone());
            env.call_method(
                activity.as_obj(),
                "setContentView",
                "(Landroid/view/View;)V",
                &[JValue::Object(root_view.as_obj())],
            )?;
        }
    }
    Ok(())
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
        OP_SELFTEST_CLICK => selftest_click(&mut env),
        OP_SELFTEST_CHECK => selftest_check(&mut env),
        _ => Ok(()),
    };
    if let Err(e) = result {
        log::error!("kaya: UI-thread hop failed: {e}");
    }
}

/// KayaClickListener.nativeClick: translate the click into an occurrence.
extern "system" fn native_click(_env: JNIEnv, _this: JObject, widget_id: jlong) {
    if let Some(sink) = OCC_SINK.get() {
        sink.send(Occurrence::ButtonClicked {
            id: WidgetId(widget_id as u64),
        });
    }
}

/// Drives the round trip without a human: performClick raises the real
/// click on the UI thread, the app thread answers with a signal write,
/// and the label text proves the resolution path worked. Results go to
/// logcat; the validation script watches for them.
fn spawn_selftest() {
    fn post(runnable: &GlobalRef) {
        let Some(g) = GLOBALS.get() else { return };
        let mut env = match g.vm.attach_current_thread_permanently() {
            Ok(env) => env,
            Err(e) => {
                log::error!("kaya: selftest attach failed: {e}");
                return;
            }
        };
        if let Err(e) = env.call_method(
            g.activity.as_obj(),
            "runOnUiThread",
            "(Ljava/lang/Runnable;)V",
            &[JValue::Object(runnable.as_obj())],
        ) {
            log::error!("kaya: selftest post failed: {e}");
        }
    }

    std::thread::spawn(|| {
        let Some(g) = GLOBALS.get() else { return };
        std::thread::sleep(std::time::Duration::from_millis(1500));
        post(&g.selftest_click);
        std::thread::sleep(std::time::Duration::from_millis(300));
        post(&g.selftest_click);
        std::thread::sleep(std::time::Duration::from_millis(700));
        post(&g.selftest_check);
    });
}

fn selftest_click(env: &mut JNIEnv) -> jni::errors::Result<()> {
    // Clone the ref and release the lock first: performClick dispatches
    // onClick -> native_click on this same thread.
    let button = {
        let core = CORE.lock().unwrap();
        let Some(core) = core.as_ref() else {
            return Ok(());
        };
        core.selftest_button.clone()
    };
    if let Some(button) = button {
        env.call_method(button.as_obj(), "performClick", "()Z", &[])?;
    }
    Ok(())
}

fn selftest_check(env: &mut JNIEnv) -> jni::errors::Result<()> {
    let label = {
        let core = CORE.lock().unwrap();
        let Some(core) = core.as_ref() else {
            return Ok(());
        };
        core.selftest_label.clone()
    };
    let Some(label) = label else {
        log::error!("KAYA_SELFTEST: FAILED (no label in the scene)");
        unsafe { libc::_exit(1) };
    };
    let chars = env
        .call_method(label.as_obj(), "getText", "()Ljava/lang/CharSequence;", &[])?
        .l()?;
    let string = env
        .call_method(&chars, "toString", "()Ljava/lang/String;", &[])?
        .l()?;
    let text: String = env.get_string(&JString::from(string))?.into();

    let code = if text == "Clicked 2 times" {
        log::info!("KAYA_SELFTEST: OK ({text})");
        0
    } else {
        log::error!("KAYA_SELFTEST: FAILED (label reads {text:?})");
        1
    };

    // A library must not kill its host, but the selftest app is the host;
    // finish the task first so the exit reads as intentional to the OS.
    // _exit rather than exit: libc atexit handlers tear down HWUI mutexes
    // while its render threads still run, and that race aborts.
    if let Some(g) = GLOBALS.get() {
        let _ = env.call_method(g.activity.as_obj(), "finishAndRemoveTask", "()V", &[]);
    }
    unsafe { libc::_exit(code) };
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
extern "system" fn ring_submit(mut env: JNIEnv, _class: JClass, records: JByteArray) {
    let bytes = env
        .convert_byte_array(&records)
        .expect("kaya: reading the submitted transaction failed");
    unsafe { crate::capi::kaya_submit(bytes.as_ptr(), bytes.len()) };
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
                name: "emitButtonClicked".into(),
                sig: "(J)V".into(),
                fn_ptr: present_emit as *mut _,
            },
            NativeMethod {
                name: "nextCommands".into(),
                sig: "([B)I".into(),
                fn_ptr: present_next_commands as *mut _,
            },
        ],
    )
}

extern "system" fn present_emit(_env: JNIEnv, _class: JClass, widget_id: jlong) {
    crate::capi::kaya_emit_button_clicked(widget_id as u64);
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
