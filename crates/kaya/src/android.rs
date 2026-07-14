//! Android backend, milestone 0: one activity, one button, one label,
//! built as android.widget views through JNI.
//!
//! Same protocol as every other backend — the button's click pushes an
//! occurrence and never calls app code; commands come back on their own
//! channel; a posted Runnable is the doorbell, carrying no data. The
//! hosting is inverted, though: Android has no native process entry
//! (Zygote forks the process, ActivityThread owns main), so there is no
//! run_core loop to own. The Activity calls [`native_start`] on the UI
//! thread during onCreate; it builds the scene, spawns the app thread,
//! and returns the thread to Android's Looper.
//!
//! The Kotlin side of this backend is three small classes under
//! android/kaya/ — Kaya (the entry declaration), KayaClickListener, and
//! KayaRunnable — whose native methods are registered here rather than
//! resolved by name, so the guest cdylib's only name-based export is the
//! entry itself.

use std::sync::mpsc::{self, Receiver};
use std::sync::{Mutex, OnceLock};

use jni::objects::{GlobalRef, JString, JValue};
use jni::sys::jlong;
use jni::{JavaVM, NativeMethod};

use crate::app::AppCtx;
use crate::protocol::{Command, OccSink, Occurrence, skeleton};

// Public (doc-hidden) because the android_main! expansion names them.
#[doc(hidden)]
pub use jni::JNIEnv;
#[doc(hidden)]
pub use jni::objects::{JClass, JObject};
#[doc(hidden)]
pub use jni::sys::jint;

/// native_start return values: who plays the presentation role.
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

/// Touched only from the UI thread, but a Mutex keeps the types honest
/// (Receiver is Send, not Sync). Never hold this lock across a JNI call
/// that can dispatch back into native code (performClick reaches
/// native_click synchronously): clone the GlobalRef out first.
struct CoreState {
    commands: Receiver<Command>,
    label: GlobalRef,
    button: GlobalRef,
}

static CORE: Mutex<Option<CoreState>> = Mutex::new(None);

/// The click handler's own copy of the occurrence sink, mirroring the
/// cloned sink a GTK signal closure captures; lock-free so a click
/// dispatched from under any lock cannot deadlock.
static OCC_SINK: OnceLock<OccSink> = OnceLock::new();

/// Wake the UI thread so it drains the command channel. Safe to call
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
pub(crate) fn run_core(_occurrences: OccSink, _commands: Receiver<Command>) -> i32 {
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
/// spawns the app thread, adds its scene, and returns the thread to the
/// Looper — the host-owns-the-loop shape every Android app has by
/// construction. Desktop attach takes no anchor because its anchors are
/// ambient (NSApp, the main context, the thread's dispatcher); Android's
/// Context is an argument by the platform's own design.
///
/// Runtime backend selection lives inside the entry, as it does in
/// kaya::run: the return value says who presents. PRESENT_CORE means
/// kaya built the Views scene; under KAYA_BACKEND=compose the
/// presentation-side plumbing is wired instead and PRESENT_GUEST tells
/// the Kotlin side to mount the Compose scene.
pub fn attach(
    mut env: JNIEnv,
    activity: JObject,
    app_main: impl FnOnce(AppCtx) + Send + 'static,
) -> i32 {
    init_logging();

    // Same shape as kaya::run's SwiftUI branch: the Compose pump consumes
    // commands through the C API's channel, and its emissions route into
    // this AppCtx's inbox. (The environment is mapped from intent extras
    // by the Activity.)
    if std::env::var("KAYA_BACKEND").as_deref() == Ok("compose") {
        let (occ_tx, occ_rx) = mpsc::channel();
        let ctx = AppCtx {
            occurrences: occ_rx,
            commands: crate::capi::presentation_cmd_sender(),
        };
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
    let (cmd_tx, cmd_rx) = mpsc::channel();
    let ctx = AppCtx {
        occurrences: occ_rx,
        commands: cmd_tx,
    };
    std::thread::Builder::new()
        .name("kaya-app".into())
        .spawn(move || app_main(ctx))
        .expect("failed to spawn the app thread");

    setup(&mut env, &activity, OccSink::Mpsc(occ_tx), cmd_rx)
        .expect("kaya: building the milestone-0 scene failed");
    PRESENT_CORE
}

// The presentation-side C API over JNI, for guest-language backends
// (Compose). Thin translations of kaya_emit_button_clicked and
// kaya_next_command; the latter blocks on the pump thread exactly as the
// SwiftUI pump blocks in the C function.
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
                name: "nextCommand".into(),
                sig: "(Ldev/kaya/KayaCommand;)Z".into(),
                fn_ptr: present_next_command as *mut _,
            },
        ],
    )
}

extern "system" fn present_emit(_env: JNIEnv, _class: JClass, widget_id: jlong) {
    crate::capi::kaya_emit_button_clicked(widget_id as u64);
}

extern "system" fn present_next_command(
    mut env: JNIEnv,
    _class: JClass,
    out: JObject,
) -> jni::sys::jboolean {
    let mut command = crate::capi::KayaCommand {
        kind: 0,
        widget_id: 0,
        text_len: 0,
        text: [0; 256],
    };
    if !crate::capi::kaya_next_command(&mut command) {
        return 0;
    }
    let text = String::from_utf8_lossy(&command.text[..command.text_len as usize]);
    let filled = (|| -> jni::errors::Result<()> {
        let text = env.new_string(text)?;
        env.set_field(&out, "kind", "I", JValue::Int(command.kind as i32))?;
        env.set_field(&out, "widgetId", "J", JValue::Long(command.widget_id as i64))?;
        env.set_field(&out, "text", "Ljava/lang/String;", JValue::Object(&text))?;
        Ok(())
    })();
    match filled {
        Ok(()) => 1,
        Err(e) => {
            log::error!("kaya: decoding a command for the Compose pump failed: {e}");
            0
        }
    }
}

/// Attach when the JVM app itself is the guest: builds the scene with
/// the ring as the occurrence sink and returns; the app's own thread
/// consumes the ring through KayaRing (direct tier) and answers with
/// kaya_set_text — the same core ends kaya_attach hands a C host on the
/// desktop, plus the Activity anchor Android requires. Exported by name;
/// this lives in kaya's own cdylib, so there is no macro to route
/// through.
#[unsafe(no_mangle)]
extern "system" fn Java_dev_kaya_KayaRing_attach(
    mut env: JNIEnv,
    _class: JClass,
    activity: JObject,
) {
    init_logging();
    let (occ_sink, cmd_rx) =
        crate::capi::take_core_ends().expect("KayaRing.attach may only be called once");
    register_ring_natives(&mut env).expect("kaya: registering KayaRing natives failed");
    setup(&mut env, &activity, occ_sink, cmd_rx)
        .expect("kaya: building the milestone-0 scene failed");
}

// Raw addresses rather than direct ByteBuffers: ART's interpreter path
// for byte-buffer-view VarHandles truncates a direct buffer's native
// address to 32 bits (var_handle.cc, `static_cast<uint32_t>` on the
// address field), so VarHandle-over-NewDirectByteBuffer faults on any
// real heap address. Unsafe address-based access — the idiom Netty ships
// on Android — takes the address as a jlong and is unaffected.
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
                name: "setText".into(),
                sig: "(JLjava/lang/String;)V".into(),
                fn_ptr: ring_set_text as *mut _,
            },
        ],
    )
}

extern "system" fn ring_data_address(_env: JNIEnv, _class: JClass) -> jlong {
    crate::capi::ring_raw().0 as jlong
}

extern "system" fn ring_capacity(_env: JNIEnv, _class: JClass) -> jni::sys::jint {
    crate::capi::ring_raw().1 as jni::sys::jint
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

extern "system" fn ring_set_text(mut env: JNIEnv, _class: JClass, widget_id: jlong, text: JString) {
    let Ok(text) = env.get_string(&text) else {
        return;
    };
    let text: String = text.into();
    unsafe { crate::capi::kaya_set_text(widget_id as u64, text.as_ptr(), text.len()) };
}

fn setup(
    env: &mut JNIEnv,
    activity: &JObject,
    occ_tx: OccSink,
    cmd_rx: Receiver<Command>,
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

    // The scene: LinearLayout { Button, TextView }, android.widget all the
    // way — the retained toolkit this backend wraps.
    let layout = env.new_object(
        "android/widget/LinearLayout",
        "(Landroid/content/Context;)V",
        &[JValue::Object(activity)],
    )?;
    // LinearLayout.VERTICAL = 1, Gravity.CENTER = 17.
    env.call_method(&layout, "setOrientation", "(I)V", &[JValue::Int(1)])?;
    env.call_method(&layout, "setGravity", "(I)V", &[JValue::Int(17)])?;

    let button = env.new_object(
        "android/widget/Button",
        "(Landroid/content/Context;)V",
        &[JValue::Object(activity)],
    )?;
    let button_text = env.new_string("Click me")?;
    env.call_method(
        &button,
        "setText",
        "(Ljava/lang/CharSequence;)V",
        &[JValue::Object(&button_text)],
    )?;
    let listener = env.new_object(
        listener_class,
        "(J)V",
        &[JValue::Long(skeleton::BUTTON.0 as jlong)],
    )?;
    env.call_method(
        &button,
        "setOnClickListener",
        "(Landroid/view/View$OnClickListener;)V",
        &[JValue::Object(&listener)],
    )?;

    let label = env.new_object(
        "android/widget/TextView",
        "(Landroid/content/Context;)V",
        &[JValue::Object(activity)],
    )?;
    let label_text = env.new_string("Clicked 0 times")?;
    env.call_method(
        &label,
        "setText",
        "(Ljava/lang/CharSequence;)V",
        &[JValue::Object(&label_text)],
    )?;

    env.call_method(
        &layout,
        "addView",
        "(Landroid/view/View;)V",
        &[JValue::Object(&button)],
    )?;
    env.call_method(
        &layout,
        "addView",
        "(Landroid/view/View;)V",
        &[JValue::Object(&label)],
    )?;
    env.call_method(
        activity,
        "setContentView",
        "(Landroid/view/View;)V",
        &[JValue::Object(&layout)],
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
        commands: cmd_rx,
        label: env.new_global_ref(label)?,
        button: env.new_global_ref(button)?,
    });

    if std::env::var_os("KAYA_SELFTEST").is_some() {
        spawn_selftest();
    }
    Ok(())
}

/// KayaRunnable.nativeRun: a posted hop has arrived on the UI thread.
extern "system" fn native_run(mut env: JNIEnv, _this: JObject, op: jlong) {
    let result = match op {
        OP_DRAIN => drain_commands(&mut env),
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
            id: crate::protocol::WidgetId(widget_id as u64),
        });
    }
}

fn drain_commands(env: &mut JNIEnv) -> jni::errors::Result<()> {
    let core = CORE.lock().unwrap();
    let Some(core) = core.as_ref() else {
        return Ok(());
    };
    while let Ok(command) = core.commands.try_recv() {
        match command {
            Command::SetText { id, text } => {
                if id == skeleton::LABEL {
                    let text = env.new_string(text)?;
                    env.call_method(
                        core.label.as_obj(),
                        "setText",
                        "(Ljava/lang/CharSequence;)V",
                        &[JValue::Object(&text)],
                    )?;
                }
            }
        }
    }
    Ok(())
}

/// Drives the round trip without a human: performClick raises the real
/// click on the UI thread, the app thread answers with a command, and the
/// label text proves both directions worked. Results go to logcat; the
/// validation script watches for them.
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
        core.button.clone()
    };
    env.call_method(button.as_obj(), "performClick", "()Z", &[])?;
    Ok(())
}

fn selftest_check(env: &mut JNIEnv) -> jni::errors::Result<()> {
    let label = {
        let core = CORE.lock().unwrap();
        let Some(core) = core.as_ref() else {
            return Ok(());
        };
        core.label.clone()
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
        ) -> $crate::android::jint {
            $crate::android::attach(env, activity, $app)
        }
    };
}
