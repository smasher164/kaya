//! Android's kaya plumbing: the attach entries, the KayaRing natives
//! (the JVM guest tier's transport, whose bodies live in jvm.rs), and
//! the KayaPresent natives the Compose interpreter pumps through.
//!
//! Android has no native process entry, so the Activity calls the attach
//! entry on the UI thread during onCreate; kaya spawns the app thread and
//! returns that thread to Android's Looper.

use std::sync::mpsc;

use jni::objects::JByteArray;
use jni::sys::{jint, jlong};
use jni::NativeMethod;

use crate::app::AppCtx;
use crate::protocol::OccSink;

// Public (doc-hidden) because the android_main! expansion names them.
#[doc(hidden)]
pub use jni::JNIEnv;
#[doc(hidden)]
pub use jni::objects::{JClass, JObject, JString};
#[doc(hidden)]
pub use jni::sys::jint as jint_export;

/// attach's return value: Kotlin always mounts the Compose interpreter.
const PRESENT_GUEST: i32 = 1;

/// The JVM this process's kaya was attached from, and dev.kaya.KayaPresent
/// as a GLOBAL REFERENCE, both taken at attach: a picked file is opened
/// LATER, from a guest thread, and a thread attached with
/// AttachCurrentThread resolves classes through the SYSTEM class loader,
/// where `FindClass("dev/kaya/KayaPresent")` fails (docs/traps.md).
static JVM: std::sync::OnceLock<jni::JavaVM> = std::sync::OnceLock::new();
static PRESENT_CLASS: std::sync::OnceLock<jni::objects::GlobalRef> =
    std::sync::OnceLock::new();

/// dev.kaya.KayaAssets and the Context an asset read needs, taken at
/// attach for the same reason: an asset is read from the APP THREAD.
/// THE APPLICATION CONTEXT AND NOT THE ACTIVITY (docs/deferred.md's mount
/// entry) — a configuration change recreates the Activity while this ref is
/// a `OnceLock`, so the process would hold the first, destroyed one.
static ASSETS_CLASS: std::sync::OnceLock<jni::objects::GlobalRef> =
    std::sync::OnceLock::new();
static APP_CONTEXT: std::sync::OnceLock<jni::objects::GlobalRef> = std::sync::OnceLock::new();

/// dev.kaya.KayaPrefs, resolved beside KayaAssets and for the same reason
/// (docs/tasks-s4-plan.md §4): a preference is read and written from the
/// APP THREAD, which resolves classes through the system class loader.
static PREFS_CLASS: std::sync::OnceLock<jni::objects::GlobalRef> =
    std::sync::OnceLock::new();

/// dev.kaya.KayaFormat, the formatter door's arm (fmt.rs's android
/// module), resolved beside KayaAssets for the same reason: the door is
/// called from the APP THREAD.
static FORMAT_CLASS: std::sync::OnceLock<jni::objects::GlobalRef> =
    std::sync::OnceLock::new();

/// dev.kaya.KayaCompose, taken at attach for the capability query, which the
/// APP THREAD asks (docs/media-plan.md §8 ruling 1).
static COMPOSE_CLASS: std::sync::OnceLock<jni::objects::GlobalRef> =
    std::sync::OnceLock::new();

/// The app's private files directory as the host handed it in
/// (`Kaya.attach(activity, stateRoot)`), which is `app_data_dir()`'s
/// answer here: only a Context knows it, so nothing may guess.
static STATE_ROOT: std::sync::OnceLock<std::path::PathBuf> = std::sync::OnceLock::new();

/// THE BUILD-ONCE LATCH, this side of the JNI boundary
/// (docs/deferred.md's mount entry, ruled 2026-08-27): a second
/// `onCreate` in one process re-attaches the presentation and NEVER
/// spawns a second guest. `KayaCompose.mount` holds the other half.
static ATTACHED: std::sync::atomic::AtomicBool =
    std::sync::atomic::AtomicBool::new(false);

/// True on the FIRST call in this process, false ever after.
fn claim_attach() -> bool {
    !ATTACHED.swap(true, std::sync::atomic::Ordering::SeqCst)
}

fn init_logging() {
    static ONCE: std::sync::Once = std::sync::Once::new();
    ONCE.call_once(|| {
        android_logger::init_once(
            android_logger::Config::default()
                .with_max_level(log::LevelFilter::Info)
                .with_tag("kaya"),
        );
        log_panics::init();
        forward_stderr_to_logcat();
    });
}

/// docs/traps.md 2026-09-11: an app process's stderr is /dev/null, so every
/// `KAYA_DIAG` the core prints reached nobody on five devices. fd 2 becomes a
/// pipe whose reader logs each line under the `kaya` tag; the android lane
/// holds the bridge live (tools/android/run-emulator.py's core-diag census).
fn forward_stderr_to_logcat() {
    let mut fds = [0i32; 2];
    // SAFETY: pipe/dup2/close on descriptors this process owns; the read end
    // is handed to exactly one File below.
    unsafe {
        if libc::pipe(fds.as_mut_ptr()) != 0 || libc::dup2(fds[1], 2) < 0 {
            return;
        }
        libc::close(fds[1]);
    }
    let read_end = fds[0];
    let spawned = std::thread::Builder::new().name("kaya-stderr".into()).spawn(move || {
        use std::io::{BufRead, BufReader};
        use std::os::fd::FromRawFd;
        // SAFETY: the read end is owned here and nowhere else.
        let file = unsafe { std::fs::File::from_raw_fd(read_end) };
        for line in BufReader::new(file).lines().map_while(Result::ok) {
            log::info!(target: "kaya", "{line}");
        }
    });
    if spawned.is_err() {
        log::warn!(target: "kaya", "the stderr bridge thread did not start; core diagnostics stay silent");
    }
}

/// Android's attach: the shell Activity calls Kaya.attach(this) from
/// onCreate on the UI thread.
pub fn attach(
    mut env: JNIEnv,
    activity: JObject,
    state_root: JString,
    app_main: impl FnOnce(AppCtx) + Send + 'static,
) -> i32 {
    init_logging();
    remember_context(&mut env, &activity);
    // A LATER onCreate RE-ATTACHES ONLY: the guest, its thread and the
    // core are the PROCESS's, and the Activity that runs this is only
    // the current window (docs/deferred.md's mount entry).
    if !claim_attach() {
        return PRESENT_GUEST;
    }

    // THE LOCALE KNOB FIRST, before the app thread exists (lib.rs's `run`
    // does the same on the other platforms; docs/compliance-plan.md §2.2).
    crate::fmt::install_locale_knob();

    // BEFORE THE APP THREAD, because a process the tap started has no
    // scene in its environment and the guest reads its scene from
    // KAYA_SELFTEST (docs/tasks-s9-plan.md R6a). Android's state root
    // comes from the platform: HOME is not the app's files directory and
    // only a Context knows it.
    arm_state(&mut env, &state_root);

    grant_measured_capabilities(&mut env, &activity);

    let (occ_tx, occ_rx) = mpsc::channel();
    let ctx = AppCtx::new(occ_rx, crate::capi::presentation_tx_sender(), occ_tx.clone());
    std::thread::Builder::new()
        .name("kaya-app".into())
        .spawn(move || app_main(ctx))
        .expect("failed to spawn the app thread");
    crate::capi::set_presentation_sink(OccSink::Mpsc(occ_tx));
    register_natives(&mut env);
    PRESENT_GUEST
}

/// BOTH CLASSES ON EVERY TIER (docs/traps.md, the Rust tier's copy_asset);
/// tools/check-jni.py holds both attach paths to this one call.
fn register_natives(env: &mut JNIEnv) {
    crate::jvm::register_ring_natives(env).expect("kaya: registering KayaRing natives failed");
    register_present_natives(env).expect("kaya: registering KayaPresent natives failed");
}

/// THE RUNTIME CAPABILITY BITS, MEASURED BEFORE ANY GUEST CAN ASK
/// (docs/tasks-s3-plan.md N6). Here and not in `KayaCompose.mount`: the
/// guest thread is spawned below and reads `capabilities()` in its first
/// build closure, so a grant on the mount path races it. Silent on
/// failure — a process that cannot ask simply posts nothing.
fn grant_measured_capabilities(env: &mut JNIEnv, activity: &JObject) {
    let Ok(class) = env.find_class("dev/kaya/KayaCompose") else {
        if env.exception_check().unwrap_or(false) {
            let _ = env.exception_clear();
        }
        return;
    };
    if let Ok(global) = env.new_global_ref(&class) {
        let _ = COMPOSE_CLASS.set(global);
    }
    let called = env.call_static_method(
        class,
        "measuredCapabilities",
        "(Landroid/content/Context;)J",
        &[activity.into()],
    );
    if env.exception_check().unwrap_or(false) {
        let _ = env.exception_describe();
        let _ = env.exception_clear();
        return;
    }
    if let Ok(bits) = called.and_then(|v| v.j()) {
        crate::capi::kaya_grant_capabilities(bits as u64);
    }
}

/// Attach when the JVM app itself is the guest: the app's own thread
/// consumes the ring through KayaRing and answers with KayaRing.submit.
/// Exported by name; this lives in kaya's own cdylib.
#[unsafe(no_mangle)]
extern "system" fn Java_dev_kaya_KayaRing_attach(
    mut env: JNIEnv,
    _class: JClass,
    activity: JObject,
    state_root: JString,
) {
    init_logging();
    // The JVM and Go tiers attach HERE and never through `attach` above,
    // so an asset read on those tiers has no Context unless this runs.
    remember_context(&mut env, &activity);
    // Nothing below is per-window, and RegisterNatives on a second
    // onCreate would only rewrite the same table (docs/deferred.md's
    // mount entry).
    if !claim_attach() {
        return;
    }
    // The `attach` above's order, one tier over: the locale knob first
    // (docs/compliance-plan.md §2.2; the jvm and go knob legs died at the
    // mount's wall on the first breadth matrix, 2026-09-23).
    crate::fmt::install_locale_knob();
    arm_state(&mut env, &state_root);
    grant_measured_capabilities(&mut env, &activity);
    register_natives(&mut env);
}

/// The second act's state root as the platform handed it in
/// (docs/tasks-s9-plan.md R6a). `None` for a null or unreadable string,
/// which act2::arm answers with its own sentence.
fn read_state_root(env: &mut JNIEnv, state_root: &JString) -> Option<std::path::PathBuf> {
    if state_root.is_null() {
        return None;
    }
    let text = env.get_string(state_root);
    if env.exception_check().unwrap_or(false) {
        let _ = env.exception_describe();
        let _ = env.exception_clear();
        return None;
    }
    let text: String = text.ok()?.into();
    if text.is_empty() {
        return None;
    }
    Some(std::path::PathBuf::from(text))
}

/// Remember what an asset read will need and cannot go and find: the
/// APPLICATION Context (whose AssetManager holds this APK's assets) and
/// dev.kaya.KayaAssets, both resolved HERE on the Activity's own thread.
///
/// Failure is silent on purpose — mounting a window needs no asset — and
/// `apk_assets_reachable` then answers false, so the miss sentence names
/// only where it did look.
fn remember_context(env: &mut JNIEnv, activity: &JObject) {
    if let Ok(vm) = env.get_java_vm() {
        let _ = JVM.set(vm);
    }
    let context = env
        .call_method(activity, "getApplicationContext", "()Landroid/content/Context;", &[])
        .and_then(|v| v.l());
    match context {
        Ok(context) if !context.is_null() => {
            if let Ok(global) = env.new_global_ref(&context) {
                let _ = APP_CONTEXT.set(global);
            }
        }
        _ => {
            if env.exception_check().unwrap_or(false) {
                let _ = env.exception_describe();
                let _ = env.exception_clear();
            }
            log::warn!(
                "kaya: the Activity answered no application Context; this process \
                 cannot read its own APK's assets"
            );
        }
    }
    match env.find_class("dev/kaya/KayaAssets") {
        Ok(class) => {
            if let Ok(global) = env.new_global_ref(&class) {
                let _ = ASSETS_CLASS.set(global);
            }
        }
        Err(e) => {
            // A pending FindClass exception detonates at the next
            // unrelated JNI call, so it is read and cleared here.
            if env.exception_check().unwrap_or(false) {
                let _ = env.exception_describe();
                let _ = env.exception_clear();
            }
            log::warn!("kaya: dev.kaya.KayaAssets did not resolve ({e}); this process cannot read its own APK's assets");
        }
    }
    match env.find_class("dev/kaya/KayaFormat") {
        Ok(class) => {
            if let Ok(global) = env.new_global_ref(&class) {
                let _ = FORMAT_CLASS.set(global);
            }
        }
        Err(e) => {
            if env.exception_check().unwrap_or(false) {
                let _ = env.exception_describe();
                let _ = env.exception_clear();
            }
            log::warn!("kaya: dev.kaya.KayaFormat did not resolve ({e}); the formatter door will refuse");
        }
    }
    match env.find_class("dev/kaya/KayaPrefs") {
        Ok(class) => {
            if let Ok(global) = env.new_global_ref(&class) {
                let _ = PREFS_CLASS.set(global);
            }
        }
        Err(e) => {
            if env.exception_check().unwrap_or(false) {
                let _ = env.exception_describe();
                let _ = env.exception_clear();
            }
            log::warn!(
                "kaya: dev.kaya.KayaPrefs did not resolve ({e}); this process has no \
                 preferences store"
            );
        }
    }
}

/// Whether an asset read can reach this APK at all — the guard on
/// `Place::Apk` (crates/kaya/src/assets.rs). All three refs or none.
pub(crate) fn apk_assets_reachable() -> bool {
    JVM.get().is_some() && APP_CONTEXT.get().is_some() && ASSETS_CLASS.get().is_some()
}

/// The three refs plus an attached env, or `None`. None of this may
/// panic: an asset read runs on the app thread inside a guest's build
/// closure, where a panic is an abort with no diagnostic at all.
fn assets_env() -> Option<(
    jni::AttachGuard<'static>,
    &'static jni::objects::GlobalRef,
    &'static jni::objects::GlobalRef,
)> {
    let vm = JVM.get()?;
    let class = ASSETS_CLASS.get()?;
    let context = APP_CONTEXT.get()?;
    let env = vm.attach_current_thread().ok()?;
    Some((env, class, context))
}

/// Read one asset out of this APK. `None` covers absent AND unreadable:
/// an entry inside an APK has no `ENOENT` to tell them apart.
pub(crate) fn apk_asset_read(name: &str) -> Option<Vec<u8>> {
    let (mut env, class, context) = assets_env()?;
    let name_arg = env.new_string(name).ok()?;
    let called = env.call_static_method(
        class,
        "read",
        "(Landroid/content/Context;Ljava/lang/String;)[B",
        &[(context.as_obj()).into(), (&name_arg).into()],
    );
    if env.exception_check().unwrap_or(false) {
        let _ = env.exception_describe();
        let _ = env.exception_clear();
        return None;
    }
    let obj = called.and_then(|v| v.l()).ok()?;
    if obj.is_null() {
        return None;
    }
    let array = jni::objects::JByteArray::from(obj);
    env.convert_byte_array(&array).ok()
}

/// Every asset this APK carries, as asset names (docs/assets-plan.md A2).
/// The platform does the walking, because `AssetManager.list` answers one
/// directory at a time and says nothing about which entries are files.
/// An empty list is also what a process that could not ask answers with,
/// which is what the miss sentence's wording upstream turns on.
pub(crate) fn apk_asset_list() -> Vec<String> {
    let Some((mut env, class, context)) = assets_env() else {
        return Vec::new();
    };
    let called = env.call_static_method(
        class,
        "list",
        "(Landroid/content/Context;)[Ljava/lang/String;",
        &[(context.as_obj()).into()],
    );
    if env.exception_check().unwrap_or(false) {
        let _ = env.exception_describe();
        let _ = env.exception_clear();
        return Vec::new();
    }
    let Ok(obj) = called.and_then(|v| v.l()) else {
        return Vec::new();
    };
    if obj.is_null() {
        return Vec::new();
    }
    let array = jni::objects::JObjectArray::from(obj);
    let Ok(len) = env.get_array_length(&array) else {
        return Vec::new();
    };
    let mut out = Vec::with_capacity(len as usize);
    for i in 0..len {
        let Ok(item) = env.get_object_array_element(&array, i) else {
            continue;
        };
        let name: jni::objects::JString = item.into();
        if let Ok(text) = env.get_string(&name) {
            out.push(text.into());
        }
    }
    out
}

// ---- the preferences store's backing (docs/tasks-s4-plan.md P2, §4) ----
// dev.kaya.KayaPrefs answers; the type discipline and the tagged strings
// are documented there. This side owns the DOMAIN, which is the core's
// word and is exported so the Compose harness's `expect_pref` opens the
// same store without spelling the rule (act2.rs's KAYA_ACT2_DIR shape).

/// The app's private files directory, as handed in at attach.
pub(crate) fn state_root() -> Option<&'static std::path::Path> {
    STATE_ROOT.get().map(std::path::PathBuf::as_path)
}

/// THE STATE ROOT FIRST: `act2::arm` adopts a marker from it, and both the
/// scratch data directory and the pref domain it exports read the
/// KAYA_SELFTEST that adoption may have set.
fn arm_state(env: &mut JNIEnv, state_root: &JString) {
    let root = read_state_root(env, state_root);
    if let Some(root) = root.as_deref() {
        let _ = STATE_ROOT.set(root.to_path_buf());
    }
    crate::act2::arm(root.as_deref());
}

fn prefs_env() -> Option<(
    jni::AttachGuard<'static>,
    &'static jni::objects::GlobalRef,
    &'static jni::objects::GlobalRef,
)> {
    let vm = JVM.get()?;
    let class = PREFS_CLASS.get()?;
    let context = APP_CONTEXT.get()?;
    let env = vm.attach_current_thread().ok()?;
    Some((env, class, context))
}

/// KayaPrefs.get: `<tag><text>`, or `None` for absent and for anything
/// this store holds that kaya did not write.
pub(crate) fn pref_get(key: &str) -> Option<String> {
    let domain = crate::prefs::domain()?;
    let (mut env, class, context) = prefs_env()?;
    let domain = env.new_string(domain).ok()?;
    let key = env.new_string(key).ok()?;
    let called = env.call_static_method(
        class,
        "get",
        "(Landroid/content/Context;Ljava/lang/String;Ljava/lang/String;)Ljava/lang/String;",
        &[
            (context.as_obj()).into(),
            (&domain).into(),
            (&key).into(),
        ],
    );
    if pref_threw(&mut env, "get") {
        return None;
    }
    let obj = called.and_then(|v| v.l()).ok()?;
    if obj.is_null() {
        return None;
    }
    let text: jni::objects::JString = obj.into();
    env.get_string(&text).ok().map(Into::into)
}

/// KayaPrefs.set, durable when it returns (`commit()`).
pub(crate) fn pref_set(key: &str, tag: char, value: &str) {
    let Some(domain) = crate::prefs::domain() else { return };
    let Some((mut env, class, context)) = prefs_env() else {
        return;
    };
    let name = key;
    let (Ok(domain), Ok(key), Ok(tag), Ok(value)) = (
        env.new_string(domain),
        env.new_string(name),
        env.new_string(tag.to_string()),
        env.new_string(value),
    ) else {
        return;
    };
    let called = env.call_static_method(
        class,
        "set",
        "(Landroid/content/Context;Ljava/lang/String;Ljava/lang/String;\
         Ljava/lang/String;Ljava/lang/String;)Z",
        &[
            (context.as_obj()).into(),
            (&domain).into(),
            (&key).into(),
            (&tag).into(),
            (&value).into(),
        ],
    );
    if pref_threw(&mut env, "set") {
        return;
    }
    if !matches!(called.and_then(|v| v.z()), Ok(true)) {
        log::warn!("kaya: the preferences store refused a write to \"{name}\"");
    }
}

pub(crate) fn pref_remove(key: &str) {
    let Some(domain) = crate::prefs::domain() else { return };
    let Some((mut env, class, context)) = prefs_env() else {
        return;
    };
    let (Ok(domain), Ok(key)) = (env.new_string(domain), env.new_string(key)) else {
        return;
    };
    let _ = env.call_static_method(
        class,
        "remove",
        "(Landroid/content/Context;Ljava/lang/String;Ljava/lang/String;)Z",
        &[
            (context.as_obj()).into(),
            (&domain).into(),
            (&key).into(),
        ],
    );
    pref_threw(&mut env, "remove");
}

/// Empties the domain — the SELFTEST one, and the arm refuses any other:
/// act one clears the scratch store (docs/tasks-s4-plan.md §4), and a
/// process that reached here with the real domain open would wipe the
/// user's settings.
pub(crate) fn pref_clear() {
    let Some(domain) = crate::prefs::domain() else { return };
    if !domain.ends_with(".selftest") {
        log::warn!(
            "kaya: refusing to empty the preferences domain \"{domain}\" — clear() is \
             the harness's scratch reset and this process is not under KAYA_SELFTEST"
        );
        return;
    }
    let Some((mut env, class, context)) = prefs_env() else {
        return;
    };
    let Ok(domain) = env.new_string(domain) else {
        return;
    };
    let _ = env.call_static_method(
        class,
        "clear",
        "(Landroid/content/Context;Ljava/lang/String;)Z",
        &[(context.as_obj()).into(), (&domain).into()],
    );
    pref_threw(&mut env, "clear");
}

/// One call into dev.kaya.KayaFormat (fmt.rs's android module): the
/// application Context first when `with_context`, then `args`, then `text`
/// as a String when given; the answer is the method's String. THE DOOR
/// REFUSES OUT LOUD — a formatter that answered "" for a missing class
/// would ship an empty date label with every lane green.
pub(crate) fn format_call(
    name: &str,
    sig: &str,
    with_context: bool,
    args: &[jni::objects::JValue<'_, '_>],
    text: Option<&str>,
) -> String {
    let (Some(vm), Some(class), Some(context)) = (JVM.get(), FORMAT_CLASS.get(), APP_CONTEXT.get())
    else {
        panic!(
            "kaya: fmt::{name} before dev.kaya.KayaFormat was resolved — the formatter door \
             is reachable only after Kaya.attach (crates/kaya/src/android.rs)"
        );
    };
    let mut env = vm.attach_current_thread().expect("kaya: attaching the formatter's thread to the JVM");
    let mut all: Vec<jni::objects::JValue<'_, '_>> = Vec::with_capacity(args.len() + 2);
    if with_context {
        all.push(context.as_obj().into());
    }
    all.extend_from_slice(args);
    let string_arg = text.map(|s| env.new_string(s).expect("kaya: a formatter argument as a Java string"));
    if let Some(s) = string_arg.as_ref() {
        all.push(s.into());
    }
    let called = env.call_static_method(class, name, sig, &all);
    if env.exception_check().unwrap_or(false) {
        let _ = env.exception_describe();
        let _ = env.exception_clear();
        panic!("kaya: dev.kaya.KayaFormat.{name} threw (the exception is in logcat above)");
    }
    let obj = called
        .and_then(|v| v.l())
        .unwrap_or_else(|e| panic!("kaya: dev.kaya.KayaFormat.{name} answered no object ({e})"));
    assert!(!obj.is_null(), "kaya: dev.kaya.KayaFormat.{name} answered null");
    let text: jni::objects::JString = obj.into();
    env.get_string(&text)
        .map(Into::into)
        .unwrap_or_else(|e| panic!("kaya: dev.kaya.KayaFormat.{name}'s answer did not read ({e})"))
}

/// A pending exception is read, described and cleared HERE: left standing
/// it detonates at the next unrelated JNI call, on a thread that has
/// nothing to do with preferences.
fn pref_threw(env: &mut JNIEnv, what: &str) -> bool {
    if !env.exception_check().unwrap_or(false) {
        return false;
    }
    let _ = env.exception_describe();
    let _ = env.exception_clear();
    log::warn!("kaya: dev.kaya.KayaPrefs.{what} threw; the store answers as if empty");
    true
}

/// What to print for `Place::Apk` in the miss sentence's second line,
/// asked of the platform. When the platform will not answer, this says so
/// rather than naming a path it does not have.
pub(crate) fn apk_assets_shown() -> String {
    let Some((mut env, class, activity)) = assets_env() else {
        return "this APK's assets/ (the platform was not reachable to name the package)"
            .to_owned();
    };
    let called = env.call_static_method(
        class,
        "sourceDir",
        "(Landroid/content/Context;)Ljava/lang/String;",
        &[(activity.as_obj()).into()],
    );
    if env.exception_check().unwrap_or(false) {
        let _ = env.exception_describe();
        let _ = env.exception_clear();
        return "this APK's assets/ (the platform refused to name the package)".to_owned();
    }
    match called.and_then(|v| v.l()) {
        Ok(obj) if !obj.is_null() => {
            let path: jni::objects::JString = obj.into();
            match env.get_string(&path) {
                Ok(text) => {
                    let text: String = text.into();
                    format!("assets/ inside the APK at {text}")
                }
                Err(e) => format!("this APK's assets/ (its path would not cross: {e})"),
            }
        }
        Ok(_) => "this APK's assets/ (the platform answered no package path)".to_owned(),
        Err(e) => format!("this APK's assets/ (the platform would not name the package: {e})"),
    }
}

// The presentation-side C API over JNI for the Compose interpreter:
// emissions in, resolved apply-op records out.
fn register_present_natives(env: &mut JNIEnv) -> jni::errors::Result<()> {
    // THE COMPOSE TIER WINDOWS ROWS (docs/deferred.md, the
    // declares-windowing entry). Declared where the interpreter's own
    // surface is installed, so both attach paths carry it and it beats
    // the pump's first transaction.
    crate::capi::declare_windowing();
    let class = env.find_class("dev/kaya/KayaPresent")?;
    // Remembered HERE, on the thread that can still resolve an app class.
    let _ = JVM.set(env.get_java_vm()?);
    let _ = PRESENT_CLASS.set(env.new_global_ref(&class)?);
    env.register_native_methods(
        &class,
        &[
            NativeMethod {
                name: "emitClicked".into(),
                sig: "([B)V".into(),
                fn_ptr: present_emit as *mut _,
            },
            NativeMethod {
                name: "stalledMs".into(),
                sig: "()J".into(),
                fn_ptr: present_stalled_ms as *mut _,
            },
            NativeMethod {
                name: "fault".into(),
                sig: "()[B".into(),
                fn_ptr: present_fault as *mut _,
            },
            NativeMethod {
                name: "faultWatch".into(),
                sig: "()V".into(),
                fn_ptr: present_fault_watch as *mut _,
            },
            NativeMethod {
                name: "emitTextChanged".into(),
                sig: "([BLjava/lang/String;ZZ)V".into(),
                fn_ptr: present_emit_text as *mut _,
            },
            NativeMethod {
                name: "emitSubmitted".into(),
                sig: "([BLjava/lang/String;)V".into(),
                fn_ptr: present_emit_submitted as *mut _,
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
                name: "emitValueCommitted".into(),
                sig: "([BD)V".into(),
                fn_ptr: present_emit_value_committed as *mut _,
            },
            // The pickers' committed values (docs/datetime-plan.md D7),
            // packed decimal on a jlong.
            NativeMethod {
                name: "emitDateChanged".into(),
                sig: "([BJ)V".into(),
                fn_ptr: present_emit_date_changed as *mut _,
            },
            NativeMethod {
                name: "emitTimeChanged".into(),
                sig: "([BJ)V".into(),
                fn_ptr: present_emit_time_changed as *mut _,
            },
            // The colour picker (docs/color-picker-plan.md §3 rule 1, §6): the
            // settled colour, the core's one quantizer and its one palette.
            NativeMethod {
                name: "emitColorChanged".into(),
                sig: "([BJ)V".into(),
                fn_ptr: present_emit_color_changed as *mut _,
            },
            NativeMethod {
                name: "colorQuantize".into(),
                sig: "(DDDD)J".into(),
                fn_ptr: present_color_quantize as *mut _,
            },
            NativeMethod {
                name: "colorPalette".into(),
                sig: "()[J".into(),
                fn_ptr: present_color_palette as *mut _,
            },
            // The range (docs/range-plan.md §3 rule 2): the core's one clamp
            // and the pair's two occurrences.
            NativeMethod {
                name: "rangeClamp".into(),
                sig: "(DDDDZDD)D".into(),
                fn_ptr: present_range_clamp as *mut _,
            },
            NativeMethod {
                name: "emitRange".into(),
                sig: "([BDDZ)V".into(),
                fn_ptr: present_emit_range as *mut _,
            },
            // The media reports (docs/media-plan.md §2 rule 1): raw facts to
            // the core's one state machine, each answering the state after.
            NativeMethod {
                name: "playerLoaded".into(),
                sig: "(JJIIZLjava/lang/String;)I".into(),
                fn_ptr: present_player_loaded as *mut _,
            },
            NativeMethod {
                name: "playerRate".into(),
                sig: "(JZ)I".into(),
                fn_ptr: present_player_rate as *mut _,
            },
            NativeMethod {
                name: "playerEnded".into(),
                sig: "(J)I".into(),
                fn_ptr: present_player_ended as *mut _,
            },
            NativeMethod {
                name: "playerFailed".into(),
                sig: "(JLjava/lang/String;JJLjava/lang/String;)I".into(),
                fn_ptr: present_player_failed as *mut _,
            },
            NativeMethod {
                name: "playerPosition".into(),
                sig: "(JJ)I".into(),
                fn_ptr: present_player_position as *mut _,
            },
            NativeMethod {
                name: "playerSeeked".into(),
                sig: "(JJ)I".into(),
                fn_ptr: present_player_seeked as *mut _,
            },
            NativeMethod {
                name: "playerOverdue".into(),
                sig: "(J)I".into(),
                fn_ptr: present_player_overdue as *mut _,
            },
            NativeMethod {
                name: "playerTracks".into(),
                sig: "(JLjava/lang/String;Ljava/lang/String;II)I".into(),
                fn_ptr: present_player_tracks as *mut _,
            },
            NativeMethod {
                name: "playerCue".into(),
                sig: "(JLjava/lang/String;)I".into(),
                fn_ptr: present_player_cue as *mut _,
            },
            NativeMethod {
                name: "playerCaptionsText".into(),
                sig: "(JLjava/lang/String;Ljava/lang/String;)I".into(),
                fn_ptr: present_player_captions_text as *mut _,
            },
            NativeMethod {
                name: "playerCaptionsFailed".into(),
                sig: "(JLjava/lang/String;Ljava/lang/String;JJLjava/lang/String;)I".into(),
                fn_ptr: present_player_captions_failed as *mut _,
            },
            NativeMethod {
                name: "readerFrame".into(),
                sig: "(JJIJIIII[B)I".into(),
                fn_ptr: present_reader_frame as *mut _,
            },
            NativeMethod {
                name: "readerPcm".into(),
                sig: "(JJII[FJ)I".into(),
                fn_ptr: present_reader_pcm as *mut _,
            },
            NativeMethod {
                name: "readerFinished".into(),
                sig: "(JJ)V".into(),
                fn_ptr: present_reader_finished as *mut _,
            },
            NativeMethod {
                name: "readerFailed".into(),
                sig: "(JJLjava/lang/String;JJLjava/lang/String;)V".into(),
                fn_ptr: present_reader_failed as *mut _,
            },
            NativeMethod {
                name: "readerNoTrack".into(),
                sig: "(JJLjava/lang/String;)V".into(),
                fn_ptr: present_reader_no_track as *mut _,
            },
            NativeMethod {
                name: "readerOverdue".into(),
                sig: "(JJ)I".into(),
                fn_ptr: present_reader_overdue as *mut _,
            },
            NativeMethod {
                name: "captionAt".into(),
                sig: "(JJ)Ljava/lang/String;".into(),
                fn_ptr: present_caption_at as *mut _,
            },
            NativeMethod {
                name: "videoVisible".into(),
                sig: "(JD)V".into(),
                fn_ptr: present_video_visible as *mut _,
            },
            NativeMethod {
                name: "sessionAction".into(),
                sig: "(IJ)I".into(),
                fn_ptr: present_session_action as *mut _,
            },
            NativeMethod {
                name: "sessionState".into(),
                sig: "()I".into(),
                fn_ptr: present_session_state as *mut _,
            },
            // The capture's reports, frames and samples (docs/capture-plan.md
            // §2, §4), the synthetic devices and the harness's two verbs.
            NativeMethod {
                name: "captureState".into(),
                sig: "(JIIIIILjava/lang/String;)V".into(),
                fn_ptr: present_capture_state as *mut _,
            },
            NativeMethod { name: "captureOverdue".into(), sig: "(J)I".into(), fn_ptr: present_capture_overdue as *mut _ },
            NativeMethod {
                name: "capturePermission".into(),
                sig: "(IILjava/lang/String;)V".into(),
                fn_ptr: present_capture_permission as *mut _,
            },
            NativeMethod {
                name: "captureDevicesBegin".into(),
                sig: "()V".into(),
                fn_ptr: present_capture_devices_begin as *mut _,
            },
            NativeMethod {
                name: "captureDevice".into(),
                sig: "(Ljava/lang/String;Ljava/lang/String;IIZ)V".into(),
                fn_ptr: present_capture_device as *mut _,
            },
            NativeMethod {
                name: "captureDevicesEnd".into(),
                sig: "()V".into(),
                fn_ptr: present_capture_devices_end as *mut _,
            },
            NativeMethod {
                name: "captureFrame".into(),
                sig: "(JIILjava/nio/ByteBuffer;IILjava/nio/ByteBuffer;IILjava/nio/ByteBuffer;IIJI)I".into(),
                fn_ptr: present_capture_frame as *mut _,
            },
            NativeMethod {
                name: "captureSamples".into(),
                sig: "(JII[FIJ)V".into(),
                fn_ptr: present_capture_samples as *mut _,
            },
            NativeMethod {
                name: "captureSynthetic".into(),
                sig: "(I)Ljava/lang/String;".into(),
                fn_ptr: present_capture_synthetic as *mut _,
            },
            NativeMethod {
                name: "captureSyntheticPermission".into(),
                sig: "(IZ)I".into(),
                fn_ptr: present_capture_synthetic_permission as *mut _,
            },
            NativeMethod {
                name: "captureNearestFormat".into(),
                sig: "([IDDD)[I".into(),
                fn_ptr: present_capture_nearest_format as *mut _,
            },
            NativeMethod {
                name: "captureSelfViewBox".into(),
                sig: "(IIIJ)[I".into(),
                fn_ptr: present_capture_self_view_box as *mut _,
            },
            NativeMethod {
                name: "videoViewBox".into(),
                sig: "(IIJ)[I".into(),
                fn_ptr: present_video_view_box as *mut _,
            },
            NativeMethod {
                name: "captureHarness".into(),
                sig: "(IILjava/lang/String;)Ljava/lang/String;".into(),
                fn_ptr: present_capture_harness as *mut _,
            },
            NativeMethod {
                name: "emitSortRequested".into(),
                sig: "([BI)V".into(),
                fn_ptr: present_emit_sort_requested as *mut _,
            },
            NativeMethod {
                name: "emitAlertResult".into(),
                sig: "(JI)V".into(),
                fn_ptr: present_emit_alert_result as *mut _,
            },
            NativeMethod {
                name: "toastAction".into(),
                sig: "(J)V".into(),
                fn_ptr: present_toast_action as *mut _,
            },
            NativeMethod {
                name: "emitToastClosed".into(),
                sig: "(J)V".into(),
                fn_ptr: present_emit_toast_closed as *mut _,
            },
            // Local notifications (docs/tasks-s3-plan.md N1, N6).
            NativeMethod {
                name: "emitNotificationResult".into(),
                sig: "(JI)V".into(),
                fn_ptr: present_emit_notification_result as *mut _,
            },
            NativeMethod {
                name: "emitNotificationReply".into(),
                sig: "(JLjava/lang/String;)V".into(),
                fn_ptr: present_emit_notification_reply as *mut _,
            },
            // App links (docs/app-links-plan.md §4).
            NativeMethod {
                name: "linkOpened".into(),
                sig: "(Ljava/lang/String;)V".into(),
                fn_ptr: present_link_opened as *mut _,
            },
            NativeMethod {
                name: "grantCapabilities".into(),
                sig: "(J)V".into(),
                fn_ptr: present_grant_capabilities as *mut _,
            },
            NativeMethod {
                name: "emitFileDialogResult".into(),
                sig: "(J[Ljava/lang/String;[Ljava/lang/String;)V".into(),
                fn_ptr: present_emit_file_dialog_result as *mut _,
            },
            NativeMethod {
                name: "emitSaveDialogResult".into(),
                sig: "(JLjava/lang/String;Ljava/lang/String;)V".into(),
                fn_ptr: present_emit_save_dialog_result as *mut _,
            },
            NativeMethod {
                name: "emitClipboardResult".into(),
                sig: "(JILjava/lang/String;[B[Ljava/lang/String;[Ljava/lang/String;)V"
                    .into(),
                fn_ptr: present_emit_clipboard_result as *mut _,
            },
            NativeMethod {
                name: "emitPasted".into(),
                sig: "([BILjava/lang/String;[B[Ljava/lang/String;[Ljava/lang/String;)V"
                    .into(),
                fn_ptr: present_emit_pasted as *mut _,
            },
            // Drag and drop (docs/dnd-plan.md D1, D2).
            NativeMethod {
                name: "emitDropped".into(),
                sig: "([BDDI[BZILjava/lang/String;[B[Ljava/lang/String;\
                      [Ljava/lang/String;)V"
                    .into(),
                fn_ptr: present_emit_dropped as *mut _,
            },
            NativeMethod {
                name: "emitDragEnded".into(),
                sig: "([BI)V".into(),
                fn_ptr: present_emit_drag_ended as *mut _,
            },
            NativeMethod {
                name: "dragVerdict".into(),
                sig: "(Ljava/lang/String;IILjava/lang/String;IZ)I".into(),
                fn_ptr: present_drag_verdict as *mut _,
            },
            NativeMethod {
                name: "emitEntryPopped".into(),
                sig: "(J)V".into(),
                fn_ptr: present_emit_entry_popped as *mut _,
            },
            NativeMethod {
                name: "emitBackRequested".into(),
                sig: "(J)V".into(),
                fn_ptr: present_emit_back_requested as *mut _,
            },
            NativeMethod {
                name: "emitSheetDismissed".into(),
                sig: "(J)V".into(),
                fn_ptr: present_emit_sheet_dismissed as *mut _,
            },
            NativeMethod {
                name: "emitDismissRequested".into(),
                sig: "(J)V".into(),
                fn_ptr: present_emit_dismiss_requested as *mut _,
            },
            NativeMethod {
                name: "emitSectionSelected".into(),
                sig: "(JJ)V".into(),
                fn_ptr: present_emit_section_selected as *mut _,
            },
            NativeMethod {
                name: "emitMenuActivated".into(),
                sig: "(J[B)V".into(),
                fn_ptr: present_emit_menu_activated as *mut _,
            },
            NativeMethod {
                name: "emitMenuToggled".into(),
                sig: "(J[BZ)V".into(),
                fn_ptr: present_emit_menu_toggled as *mut _,
            },
            NativeMethod {
                name: "emitMenuValueChanged".into(),
                sig: "(J[BD)V".into(),
                fn_ptr: present_emit_menu_value_changed as *mut _,
            },
            NativeMethod {
                name: "nextCommands".into(),
                sig: "()[B".into(),
                fn_ptr: present_next_commands as *mut _,
            },
            NativeMethod {
                name: "blobData".into(),
                sig: "(J)[B".into(),
                fn_ptr: present_blob_data as *mut _,
            },
            NativeMethod {
                name: "blobCount".into(),
                sig: "()J".into(),
                fn_ptr: present_blob_count as *mut _,
            },
            NativeMethod {
                name: "specHash".into(),
                sig: "()J".into(),
                fn_ptr: crate::jvm::ring_spec_hash as *mut _,
            },
            // Row windowing (docs/virtualization-plan.md §3).
            NativeMethod {
                name: "windowMoved".into(),
                sig: "(JJJ)V".into(),
                fn_ptr: present_window_moved as *mut _,
            },
            NativeMethod {
                name: "rowsMeasured".into(),
                sig: "(JJ[D)V".into(),
                fn_ptr: present_rows_measured as *mut _,
            },
            // The number field's rules (docs/number-field-plan.md §3), the
            // core's one copy: the text at a step, and a commit's answer.
            NativeMethod {
                name: "numberText".into(),
                sig: "(DDLjava/lang/String;)Ljava/lang/String;".into(),
                fn_ptr: present_number_text as *mut _,
            },
            NativeMethod {
                name: "numberCommit".into(),
                sig: "(Ljava/lang/String;DDDDLjava/lang/String;[D)I".into(),
                fn_ptr: present_number_commit as *mut _,
            },
            NativeMethod {
                name: "scrollToRow".into(),
                sig: "(JLjava/lang/String;)J".into(),
                fn_ptr: present_scroll_to_row as *mut _,
            },
            NativeMethod {
                name: "windowGeometry".into(),
                sig: "(J[D)V".into(),
                fn_ptr: present_window_geometry as *mut _,
            },
            NativeMethod {
                name: "rowExtent".into(),
                sig: "(JJ)D".into(),
                fn_ptr: present_row_extent as *mut _,
            },
            // The canvas channels (docs/canvas-plan.md §5, §6, §7.1).
            NativeMethod {
                name: "presentation".into(),
                sig: "(DZ)V".into(),
                fn_ptr: present_presentation as *mut _,
            },
            NativeMethod {
                name: "textScaleReport".into(),
                sig: "(D)V".into(),
                fn_ptr: present_text_scale_report as *mut _,
            },
            NativeMethod {
                name: "canvasProbe".into(),
                sig: "(J)Ljava/lang/String;".into(),
                fn_ptr: present_canvas_probe as *mut _,
            },
            // The size policy's four channels (docs/canvas-plan.md §3.2.1).
            NativeMethod {
                name: "canvasTrack".into(),
                sig: "(JDD)V".into(),
                fn_ptr: present_canvas_track as *mut _,
            },
            NativeMethod {
                name: "windowMetrics".into(),
                sig: "(JDD)V".into(),
                fn_ptr: present_window_metrics as *mut _,
            },
            NativeMethod {
                name: "frame".into(),
                sig: "(D)V".into(),
                fn_ptr: present_frame as *mut _,
            },
            NativeMethod {
                name: "harnessFrame".into(),
                sig: "()V".into(),
                fn_ptr: present_harness_frame as *mut _,
            },
            NativeMethod {
                name: "canvasRasterShape".into(),
                sig: "(J)Ljava/lang/String;".into(),
                fn_ptr: present_canvas_raster_shape as *mut _,
            },
            // The undo tier (docs/undo-plan.md D6/§3).
            NativeMethod {
                name: "undoRoute".into(),
                sig: "(JJZ)I".into(),
                fn_ptr: present_undo_route as *mut _,
            },
            NativeMethod {
                name: "redoRoute".into(),
                sig: "(JJZ)I".into(),
                fn_ptr: present_redo_route as *mut _,
            },
            NativeMethod {
                name: "undo".into(),
                sig: "(J)V".into(),
                fn_ptr: present_undo as *mut _,
            },
            NativeMethod {
                name: "redo".into(),
                sig: "(J)V".into(),
                fn_ptr: present_redo as *mut _,
            },
            NativeMethod {
                name: "noteNativeUndo".into(),
                sig: "(JJLjava/lang/String;Z)V".into(),
                fn_ptr: present_note_native_undo as *mut _,
            },
            // Rich text (docs/rich-text-plan.md R4/R5/R9).
            NativeMethod {
                name: "textComposing".into(),
                sig: "(JZ)V".into(),
                fn_ptr: present_text_composing as *mut _,
            },
            NativeMethod {
                name: "textPending".into(),
                sig: "(JLjava/lang/String;Ljava/lang/String;ZJ)V".into(),
                fn_ptr: present_text_pending as *mut _,
            },
            NativeMethod {
                name: "textEditSource".into(),
                sig: "(JI)V".into(),
                fn_ptr: present_text_edit_source as *mut _,
            },
            NativeMethod {
                name: "textReportedEdit".into(),
                sig: "(JJJJ)V".into(),
                fn_ptr: present_text_reported_edit as *mut _,
            },
            NativeMethod {
                name: "textSelection".into(),
                sig: "(JJJ)V".into(),
                fn_ptr: present_text_selection as *mut _,
            },
            NativeMethod {
                name: "textFormatted".into(),
                sig: "([BJJLjava/lang/String;Ljava/lang/String;Z)V".into(),
                fn_ptr: present_text_formatted as *mut _,
            },
            NativeMethod {
                name: "textRuns".into(),
                sig: "(J)Ljava/lang/String;".into(),
                fn_ptr: present_text_runs as *mut _,
            },
            NativeMethod {
                name: "textLastEdit".into(),
                sig: "(J)Ljava/lang/String;".into(),
                fn_ptr: present_text_last_edit as *mut _,
            },
        ],
    )
}

/// A picked file on Android: the `content://` URI DocumentsUI answered
/// with, opened through the ContentResolver on EVERY redemption. There is
/// no path to hold — a provider need not be a filesystem — so the source
/// pays a JNI call per open to keep a handle redeemable more than once
/// (docs/file-dialogs-plan.md §6d).
pub(crate) struct UriSource {
    pub name: String,
    pub uri: String,
}

impl crate::protocol::PickedSource for UriSource {
    fn open(&self, mode: crate::protocol::FileMode) -> std::io::Result<(i64, bool)> {
        let fd = open_through_resolver(&self.uri, crate::protocol::android_open_mode(mode))?;
        // Seekability rides the open because only the descriptor knows: a
        // document provider may hand back a pipe where the same URI gave a
        // regular file yesterday.
        let file = unsafe { crate::protocol::file_from_raw(fd) };
        let seekable = file.metadata().map(|m| m.is_file()).unwrap_or(false);
        Ok((crate::protocol::raw_handle(file), seekable))
    }

    fn name(&self) -> &str {
        &self.name
    }

    /// EMPTY: `local_path` is a name re-opening actually works through,
    /// and a content URI is not a path any file API accepts.
    fn local_path(&self) -> &str {
        ""
    }

    /// The `content://` URI — what ClipData.newUri carries.
    fn locator(&self) -> &str {
        &self.uri
    }
}

/// KayaPresent.openPickedUri: `openFileDescriptor(uri, mode)` then
/// `detachFd()`, on whatever thread the guest called `open` from.
///
/// The JVM exception is read and cleared rather than left pending: it
/// carries the only description of what went wrong, and a pending one
/// detonates at the next unrelated JNI call.
fn open_through_resolver(uri: &str, mode: &str) -> std::io::Result<i64> {
    let vm = JVM
        .get()
        .ok_or_else(|| std::io::Error::other("kaya: the JVM was never attached"))?;
    let class = PRESENT_CLASS
        .get()
        .ok_or_else(|| std::io::Error::other("kaya: dev.kaya.KayaPresent was never resolved"))?;
    let mut env = vm
        .attach_current_thread()
        .map_err(|e| std::io::Error::other(format!("kaya: attaching to the JVM failed: {e}")))?;
    let uri_arg = env
        .new_string(uri)
        .map_err(|e| std::io::Error::other(format!("kaya: the uri would not cross: {e}")))?;
    let mode_arg = env
        .new_string(mode)
        .map_err(|e| std::io::Error::other(format!("kaya: the mode would not cross: {e}")))?;
    let called = env.call_static_method(
        class,
        "openPickedUri",
        "(Ljava/lang/String;Ljava/lang/String;)I",
        &[(&uri_arg).into(), (&mode_arg).into()],
    );
    let pending = env.exception_check().unwrap_or(false);
    if pending {
        let _ = env.exception_describe();
        let _ = env.exception_clear();
    }
    let fd = called
        .and_then(|v| v.i())
        .map_err(|e| std::io::Error::other(format!("kaya: opening {uri} as {mode} failed: {e}")))?;
    if fd < 0 {
        return Err(std::io::Error::other(format!(
            "kaya: the ContentResolver refused {uri} in mode {mode}"
        )));
    }
    Ok(i64::from(fd))
}

/// The stall watchdog's reading, for the Compose interpreter's
/// `expect_stall`.
extern "system" fn present_stalled_ms(_env: JNIEnv, _class: JClass) -> i64 {
    crate::stall::stalled_for()
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

/// KayaPresent.fault: the core's latched fault as UTF-8, null for none.
/// The Compose harness asks once per step (crates/kaya/src/fault.rs).
extern "system" fn present_fault(env: JNIEnv, _class: JClass) -> jni::sys::jbyteArray {
    let Some(sentence) = crate::fault::latched() else {
        return std::ptr::null_mut();
    };
    match env.byte_array_from_slice(sentence.as_bytes()) {
        Ok(array) => array.into_raw(),
        Err(e) => {
            log::error!("kaya: copying the fault sentence to the JVM failed: {e}");
            std::ptr::null_mut()
        }
    }
}

extern "system" fn present_fault_watch(_env: JNIEnv, _class: JClass) {
    crate::fault::watch();
}

extern "system" fn present_emit(env: JNIEnv, _class: JClass, tag: JByteArray) {
    let bytes = env
        .convert_byte_array(&tag)
        .expect("kaya: reading the click tag failed");
    unsafe { crate::capi::kaya_emit_clicked(bytes.as_ptr(), bytes.len()) };
}

/// KayaPresent.emitTextChanged: the entry edit plus the undo ledger's
/// facts (whether the field is focused, and whether the edit is
/// ledger-quiet because the backend routed a native undo). Android is
/// single-window by construction, so the window is always the primary and
/// Compose does not carry it across the boundary.
extern "system" fn present_emit_text(
    mut env: JNIEnv,
    _class: JClass,
    tag: JByteArray,
    text: JString,
    focused: jni::sys::jboolean,
    quiet: jni::sys::jboolean,
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
            crate::protocol::DEFAULT_WINDOW.0,
            u8::from(focused != 0),
            u8::from(quiet != 0),
        )
    };
}

/// KayaPresent.emitSubmitted: the field's text at the submit gesture
/// (docs/submit-plan.md S1), kaya_emit_submitted's JNI spelling.
extern "system" fn present_emit_submitted(
    mut env: JNIEnv,
    _class: JClass,
    tag: JByteArray,
    text: JString,
) {
    let bytes = env
        .convert_byte_array(&tag)
        .expect("kaya: reading the field tag failed");
    let text: String = env
        .get_string(&text)
        .expect("kaya: reading the submitted text failed")
        .into();
    unsafe { crate::capi::kaya_emit_submitted(bytes.as_ptr(), bytes.len(), text.as_ptr(), text.len()) };
}

/// KayaPresent.undoRoute / redoRoute: kaya_undo_route's and
/// kaya_redo_route's JNI spelling — 0 nowhere, 1 the focused field's own
/// stack, 2 the core's ledger.
extern "system" fn present_undo_route(
    _env: JNIEnv,
    _class: JClass,
    window: jlong,
    focused: jlong,
    can_undo: jni::sys::jboolean,
) -> jint {
    crate::capi::kaya_undo_route(window as u64, focused as u64, u8::from(can_undo != 0)) as jint
}

extern "system" fn present_redo_route(
    _env: JNIEnv,
    _class: JClass,
    window: jlong,
    focused: jlong,
    can_redo: jni::sys::jboolean,
) -> jint {
    crate::capi::kaya_redo_route(window as u64, focused as u64, u8::from(can_redo != 0)) as jint
}

/// KayaPresent.undo / redo. Nothing comes back — the inverse's ops reach
/// this backend through the pump like any other apply.
extern "system" fn present_undo(_env: JNIEnv, _class: JClass, window: jlong) {
    crate::capi::kaya_undo(window as u64);
}

extern "system" fn present_redo(_env: JNIEnv, _class: JClass, window: jlong) {
    crate::capi::kaya_redo(window as u64);
}

/// KayaPresent.noteNativeUndo: the one report of a native undo THIS
/// backend routed (docs/undo-plan.md §3). The text crosses as UTF-8
/// bytes; the local `String` outlives the call.
extern "system" fn present_note_native_undo(
    mut env: JNIEnv,
    _class: JClass,
    window: jlong,
    field: jlong,
    text: JString,
    can_undo: jni::sys::jboolean,
) {
    let text: String = env
        .get_string(&text)
        .expect("kaya: reading the undone field text failed")
        .into();
    unsafe {
        crate::capi::kaya_note_native_undo(
            window as u64,
            field as u64,
            text.as_ptr(),
            text.len(),
            u8::from(can_undo != 0),
        )
    };
}

// --- Rich text, the presentation side and the two harness reads ------
//
// OFFSETS CROSS IN UTF-8 BYTES (docs/rich-text-plan.md R2); the apply
// records go the other way in UTF-16 code units and the Kotlin arm
// converts. Every entry below is one capi call and nothing else.

extern "system" fn present_text_composing(
    _env: JNIEnv,
    _class: JClass,
    widget: jlong,
    live: jni::sys::jboolean,
) {
    crate::capi::kaya_text_composing(widget as u64, u8::from(live != 0));
}

extern "system" fn present_text_pending(
    mut env: JNIEnv,
    _class: JClass,
    widget: jlong,
    name: JString,
    value: JString,
    on: jni::sys::jboolean,
    at: jlong,
) {
    let name: String = env
        .get_string(&name)
        .expect("kaya: reading a pending attribute's name failed")
        .into();
    let value: String = env
        .get_string(&value)
        .expect("kaya: reading a pending attribute's value failed")
        .into();
    unsafe {
        crate::capi::kaya_text_pending(
            widget as u64,
            name.as_ptr(),
            name.len(),
            value.as_ptr(),
            value.len(),
            u8::from(on != 0),
            at as u64,
        )
    };
}

extern "system" fn present_text_edit_source(
    _env: JNIEnv,
    _class: JClass,
    widget: jlong,
    source: jint,
) {
    crate::capi::kaya_text_edit_source(widget as u64, source as u32);
}

extern "system" fn present_text_reported_edit(
    _env: JNIEnv,
    _class: JClass,
    widget: jlong,
    start: jlong,
    end: jlong,
    inserted_len: jlong,
) {
    crate::capi::kaya_text_reported_edit(
        widget as u64,
        start as u64,
        end as u64,
        inserted_len as u64,
    );
}

extern "system" fn present_text_selection(
    _env: JNIEnv,
    _class: JClass,
    widget: jlong,
    start: jlong,
    end: jlong,
) {
    crate::capi::kaya_text_selection(widget as u64, start as u64, end as u64);
}

extern "system" fn present_text_formatted(
    mut env: JNIEnv,
    _class: JClass,
    tag: JByteArray,
    start: jlong,
    end: jlong,
    name: JString,
    value: JString,
    removed: jni::sys::jboolean,
) {
    let bytes = env
        .convert_byte_array(&tag)
        .expect("kaya: reading the formatted textarea's tag failed");
    let name: String = env
        .get_string(&name)
        .expect("kaya: reading a formatted attribute's name failed")
        .into();
    let value: String = env
        .get_string(&value)
        .expect("kaya: reading a formatted attribute's value failed")
        .into();
    unsafe {
        crate::capi::kaya_text_formatted(
            bytes.as_ptr(),
            bytes.len(),
            start as u64,
            end as u64,
            name.as_ptr(),
            name.len(),
            value.as_ptr(),
            value.len(),
            u8::from(removed != 0),
        )
    };
}

/// The harness reads answer through a buffer the core fills; 64 KiB is
/// kaya_text_runs' own contract on the other two harnesses.
fn present_text_answer<'a>(
    env: JNIEnv<'a>,
    read: impl FnOnce(&mut [u8]) -> usize,
) -> jni::sys::jstring {
    let mut buf = [0u8; 65536];
    let wrote = read(&mut buf);
    let answer = std::str::from_utf8(&buf[..wrote]).unwrap_or("");
    env.new_string(answer)
        .expect("kaya: handing a rich text read back to the JVM failed")
        .into_raw()
}

extern "system" fn present_text_runs<'a>(
    env: JNIEnv<'a>,
    _class: JClass,
    widget: jlong,
) -> jni::sys::jstring {
    present_text_answer(env, |buf| unsafe {
        crate::capi::kaya_text_runs(widget as u64, buf.as_mut_ptr(), buf.len())
    })
}

extern "system" fn present_text_last_edit<'a>(
    env: JNIEnv<'a>,
    _class: JClass,
    widget: jlong,
) -> jni::sys::jstring {
    present_text_answer(env, |buf| unsafe {
        crate::capi::kaya_text_last_edit(widget as u64, buf.as_mut_ptr(), buf.len())
    })
}

// --- Row windowing (docs/virtualization-plan.md §3) ------------------
//
// A refused target FAULTS rather than aborting
// (crates/kaya/src/fault.rs), which is why the Compose tier asks only
// about a node it knows is a For container.

extern "system" fn present_window_moved(
    _env: JNIEnv,
    _class: JClass,
    container: jlong,
    first: jlong,
    count: jlong,
) {
    crate::capi::kaya_window_moved(container as u64, first.max(0) as u64, count.max(0) as u64);
}

extern "system" fn present_rows_measured(
    env: JNIEnv,
    _class: JClass,
    container: jlong,
    first: jlong,
    heights: jni::objects::JDoubleArray,
) {
    let len = env.get_array_length(&heights).unwrap_or(0).max(0) as usize;
    let mut out = vec![0f64; len];
    if len > 0 && env.get_double_array_region(&heights, 0, &mut out).is_err() {
        return;
    }
    unsafe {
        crate::capi::kaya_rows_measured(container as u64, first.max(0) as u64, out.as_ptr(), len)
    };
}

extern "system" fn present_scroll_to_row(
    mut env: JNIEnv,
    _class: JClass,
    container: jlong,
    key: JString,
) -> jlong {
    let Ok(key) = env.get_string(&key) else {
        return crate::capi::KAYA_ROW_NOT_FOUND as jlong;
    };
    let key: String = key.into();
    unsafe { crate::capi::kaya_scroll_to_row_str(container as u64, key.as_ptr(), key.len()) as jlong }
}

/// docs/number-field-plan.md §10.
extern "system" fn present_number_text<'a>(
    mut env: JNIEnv<'a>,
    _class: JClass,
    value: jni::sys::jdouble,
    step: jni::sys::jdouble,
    format: JString,
) -> jni::sys::jstring {
    let format: String = env.get_string(&format)
        .expect("kaya: reading number field format failed").into();
    let format = crate::fmt::NumberFormat::from_wire(&format)
        .expect("validated number field format");
    env.new_string(crate::number_field::text_for(value, step, format))
        .expect("kaya: handing a number field's text back to the JVM failed")
        .into_raw()
}

/// KayaPresent.numberCommit: `number_field::commit` — 0 revert, 1
/// unchanged, 2 moved with the new value in `out[0]`.
extern "system" fn present_number_commit(
    mut env: JNIEnv,
    _class: JClass,
    text: JString,
    committed: jni::sys::jdouble,
    min: jni::sys::jdouble,
    max: jni::sys::jdouble,
    step: jni::sys::jdouble,
    format: JString,
    out: jni::objects::JDoubleArray,
) -> jint {
    let text: String = env
        .get_string(&text)
        .map(Into::into)
        .expect("kaya: reading a number field's text failed");
    let format: String = env.get_string(&format)
        .expect("kaya: reading number field format failed").into();
    let format = crate::fmt::NumberFormat::from_wire(&format)
        .expect("validated number field format");
    match crate::number_field::commit_for(&text, committed, min, max, step, format) {
        crate::number_field::Commit::Revert => 0,
        crate::number_field::Commit::Unchanged => 1,
        crate::number_field::Commit::Moved(value) => {
            env.set_double_array_region(&out, 0, &[value])
                .expect("kaya: writing a number field's committed value back failed");
            2
        }
    }
}

/// KayaPresent.windowGeometry: the record's fields written into the
/// caller's `double[]`, in KayaPresent's GEOMETRY_* order. The counts
/// cross as doubles beside the three lengths: ONE array is one JNI call,
/// and a row index is exact in a double past any collection that fits in
/// memory.
extern "system" fn present_window_geometry(
    env: JNIEnv,
    _class: JClass,
    container: jlong,
    out: jni::objects::JDoubleArray,
) {
    let mut geometry = crate::capi::KayaWindowGeometry::default();
    unsafe { crate::capi::kaya_window_geometry(container as u64, &mut geometry) };
    let slots = [
        geometry.first as f64,
        geometry.count as f64,
        geometry.total as f64,
        geometry.offset,
        geometry.extent,
        geometry.anchor_shift,
        f64::from(geometry.corrected),
    ];
    if (env.get_array_length(&out).unwrap_or(0) as usize) < slots.len() {
        return;
    }
    let _ = env.set_double_array_region(&out, 0, &slots);
}

extern "system" fn present_row_extent(
    _env: JNIEnv,
    _class: JClass,
    container: jlong,
    index: jlong,
) -> jni::sys::jdouble {
    crate::capi::kaya_row_extent(container as u64, index.max(0) as u64)
}

/// KayaPresent.presentation: the window's scale and appearance, which
/// the core re-rasters every canvas at (docs/canvas-plan.md §5, §6).
extern "system" fn present_presentation(
    _env: JNIEnv,
    _class: JClass,
    scale: jni::sys::jdouble,
    dark: jni::sys::jboolean,
) {
    crate::capi::kaya_presentation(scale, dark != 0);
}

/// KayaPresent.textScaleReport: the toolkit's font scale as the root
/// composition read it (docs/compliance-plan.md §2.1).
extern "system" fn present_text_scale_report(_env: JNIEnv, _class: JClass, factor: jni::sys::jdouble) {
    crate::capi::kaya_text_scale_report(factor);
}

/// KayaPresent.canvasProbe: one canvas's canonical raster, as the ASCII
/// line the harness compares (docs/canvas-plan.md §7.1). An id that names
/// no drawn canvas answers with the empty string, which is what the
/// interpreter reports as `<no canvas …>`.
extern "system" fn present_canvas_probe<'a>(
    env: JNIEnv<'a>,
    _class: JClass,
    widget: jlong,
) -> jni::sys::jstring {
    let mut buf = [0u8; 128];
    let wrote = unsafe {
        crate::capi::kaya_canvas_probe(widget as u64, buf.as_mut_ptr(), buf.len())
    };
    let answer = std::str::from_utf8(&buf[..wrote]).unwrap_or("");
    env.new_string(answer)
        .expect("kaya: handing the canvas probe back to the JVM failed")
        .into_raw()
}

/// KayaPresent.canvasTrack: the box layout assigned one canvas, in
/// device-independent points (docs/canvas-plan.md §3.2.1). Without it
/// the core can only raster at the viewbox and the size policy is inert.
extern "system" fn present_canvas_track(
    _env: JNIEnv,
    _class: JClass,
    widget: jlong,
    width: jni::sys::jdouble,
    height: jni::sys::jdouble,
) {
    crate::capi::kaya_canvas_track(widget as u64, width, height);
}

/// KayaPresent.windowMetrics: the window's content size in dp —
/// breakpoint evaluation's report channel
/// (docs/adaptive-layout-plan.md D3). Android reports NO platform size
/// class by ruling (2026-08-31): the core derives it from the width at
/// the kaya-owned 600dp boundary, which is Material's own compact edge.
extern "system" fn present_window_metrics(
    _env: JNIEnv,
    _class: JClass,
    window: jlong,
    width: jni::sys::jdouble,
    height: jni::sys::jdouble,
) {
    crate::capi::kaya_window_metrics(
        window as u64,
        width,
        height,
        i64::from(crate::wire::SIZE_CLASS_NONE),
    );
}

/// KayaPresent.frame: the platform's own frame time in seconds, which is
/// Choreographer's through `withFrameNanos` (§15.4).
extern "system" fn present_frame(_env: JNIEnv, _class: JClass, time: jni::sys::jdouble) {
    crate::capi::kaya_frame(time);
}

/// KayaPresent.harnessFrame: the deterministic step a scene's `frame`
/// verb drives. No time crosses — the core owns the clock (§15.4).
extern "system" fn present_harness_frame(_env: JNIEnv, _class: JClass) {
    crate::capi::kaya_harness_frame();
}

/// KayaPresent.canvasRasterShape: `expect_raster`'s observation, as the
/// ASCII word or sentence the harness compares (docs/canvas-plan.md
/// §3.2.1). An id that names no drawn canvas answers with the empty
/// string.
extern "system" fn present_canvas_raster_shape<'a>(
    env: JNIEnv<'a>,
    _class: JClass,
    widget: jlong,
) -> jni::sys::jstring {
    let mut buf = [0u8; 160];
    let wrote = unsafe {
        crate::capi::kaya_canvas_raster_shape(widget as u64, buf.as_mut_ptr(), buf.len())
    };
    let answer = std::str::from_utf8(&buf[..wrote]).unwrap_or("");
    env.new_string(answer)
        .expect("kaya: handing the canvas raster shape back to the JVM failed")
        .into_raw()
}

extern "system" fn present_emit_value_changed(
    env: JNIEnv,
    _class: JClass,
    tag: JByteArray,
    value: jni::sys::jdouble,
) {
    let bytes = env
        .convert_byte_array(&tag)
        .expect("kaya: reading the slider tag failed");
    unsafe { crate::capi::kaya_emit_value_changed(bytes.as_ptr(), bytes.len(), value) };
}

extern "system" fn present_emit_value_committed(
    env: JNIEnv,
    _class: JClass,
    tag: JByteArray,
    value: jni::sys::jdouble,
) {
    let bytes = env
        .convert_byte_array(&tag)
        .expect("kaya: reading the slider tag failed");
    unsafe { crate::capi::kaya_emit_value_committed(bytes.as_ptr(), bytes.len(), value) };
}

/// KayaPresent.emitNotificationResult: a notification's one answer
/// (activated 0, refused 1).
extern "system" fn present_emit_notification_result(
    _env: JNIEnv,
    _class: JClass,
    notification: jlong,
    outcome: jint,
) {
    crate::capi::kaya_emit_notification_result(notification as u64, outcome as u32);
}

/// KayaPresent.emitNotificationReply: the text the user sent from a
/// notification's reply field (docs/notification-reply-plan.md).
extern "system" fn present_emit_notification_reply(
    mut env: JNIEnv,
    _class: JClass,
    notification: jlong,
    text: JString,
) {
    let text: String = if text.is_null() {
        String::new()
    } else {
        match env.get_string(&text) {
            Ok(text) => text.into(),
            Err(_) => {
                if env.exception_check().unwrap_or(false) {
                    let _ = env.exception_clear();
                }
                String::new()
            }
        }
    };
    let bytes = text.as_bytes();
    // SAFETY: a live slice of `bytes.len()` bytes.
    unsafe {
        crate::capi::kaya_emit_notification_reply(notification as u64, bytes.as_ptr(), bytes.len())
    };
}

/// KayaPresent.linkOpened: a URL the platform delivered to this app
/// (docs/app-links-plan.md §4) — the activity's own intent on a cold
/// launch, `onNewIntent` warm. THIS ARM PARSES NOTHING: the core matches
/// it against the declared routes, queues it when the app thread does not
/// exist yet, and announces a miss.
extern "system" fn present_link_opened(mut env: JNIEnv, _class: JClass, url: JString) {
    if url.is_null() {
        return;
    }
    let Ok(text) = env.get_string(&url) else {
        if env.exception_check().unwrap_or(false) {
            let _ = env.exception_clear();
        }
        return;
    };
    let text: String = text.into();
    crate::links::opened(&text);
}

/// KayaPresent.grantCapabilities: the runtime bits this host measured,
/// granted again when a permission the user grants mid-run moves them.
extern "system" fn present_grant_capabilities(
    _env: JNIEnv,
    _class: JClass,
    bits: jlong,
) {
    crate::capi::kaya_grant_capabilities(bits as u64);
}

/// KayaPresent.emitAlertResult: the jint choice reinterprets as the wire
/// u32 (the cancel sentinel is -1 in java-int terms).
extern "system" fn present_emit_alert_result(
    _env: JNIEnv,
    _class: JClass,
    alert: jlong,
    choice: jint,
) {
    crate::capi::kaya_emit_alert_result(alert as u64, choice as u32);
}

/// KayaPresent.toastAction: kaya_toast_action (docs/toast-plan.md §3).
extern "system" fn present_toast_action(_env: JNIEnv, _class: JClass, toast: jlong) {
    crate::capi::kaya_toast_action(toast as u64);
}

/// KayaPresent.emitToastClosed: kaya_emit_toast_result with `closed`.
extern "system" fn present_emit_toast_closed(_env: JNIEnv, _class: JClass, toast: jlong) {
    crate::capi::kaya_emit_toast_result(toast as u64, crate::wire::TOAST_OUTCOME_CLOSED);
}

/// KayaPresent.emitFileDialogResult: `uris` and `names` are parallel
/// String[]s, and EMPTY is cancel — no platform can confirm an empty
/// selection. The core mints the handles from the locators.
extern "system" fn present_emit_file_dialog_result(
    mut env: JNIEnv,
    _class: JClass,
    dialog: jlong,
    uris: jni::objects::JObjectArray,
    names: jni::objects::JObjectArray,
) {
    let read = |env: &mut JNIEnv, array: &jni::objects::JObjectArray, i: i32| -> String {
        let Ok(item) = env.get_object_array_element(array, i) else {
            return String::new();
        };
        env.get_string(&JString::from(item))
            .map(|s| s.into())
            .unwrap_or_default()
    };
    let count = env.get_array_length(&uris).unwrap_or(0);
    let named = env.get_array_length(&names).unwrap_or(0);
    assert_eq!(
        count, named,
        "kaya: the picker answered with {count} uris and {named} names"
    );
    let mut owned = Vec::with_capacity(count as usize);
    for i in 0..count {
        owned.push((read(&mut env, &uris, i), read(&mut env, &names, i)));
    }
    // The C entry borrows the pointers for the length of the call, so the
    // CStrings must outlive the pointer vectors — hence two passes.
    let cstrings: Vec<(std::ffi::CString, std::ffi::CString)> = owned
        .iter()
        .map(|(u, n)| {
            (
                std::ffi::CString::new(u.as_str()).unwrap_or_default(),
                std::ffi::CString::new(n.as_str()).unwrap_or_default(),
            )
        })
        .collect();
    let uri_ptrs: Vec<*const std::os::raw::c_char> =
        cstrings.iter().map(|(u, _)| u.as_ptr()).collect();
    let name_ptrs: Vec<*const std::os::raw::c_char> =
        cstrings.iter().map(|(_, n)| n.as_ptr()).collect();
    unsafe {
        crate::capi::kaya_emit_file_dialog_result(
            dialog as u64,
            uri_ptrs.as_ptr(),
            name_ptrs.as_ptr(),
            cstrings.len(),
        )
    };
}

/// KayaPresent.emitSaveDialogResult: ONE locator, not an array, and a
/// NULL one is cancel. It answers on kaya_emit_save_dialog_result, which
/// is what makes the result a SAVE destination rather than a picked file
/// (docs/save-plan.md D1), even though this platform's two sources
/// coincide today.
extern "system" fn present_emit_save_dialog_result(
    mut env: JNIEnv,
    _class: JClass,
    dialog: jlong,
    uri: JString,
    name: JString,
) {
    // A JNI null object is the cancel and reaches the C entry as a null
    // pointer, never as "": that is a locator the core would try to open.
    let read = |env: &mut JNIEnv, s: &JString| -> Option<std::ffi::CString> {
        if s.is_null() {
            return None;
        }
        let text: String = env.get_string(s).ok()?.into();
        std::ffi::CString::new(text).ok()
    };
    let locator = read(&mut env, &uri);
    let display = read(&mut env, &name);
    unsafe {
        crate::capi::kaya_emit_save_dialog_result(
            dialog as u64,
            locator
                .as_ref()
                .map_or(std::ptr::null(), |c| c.as_ptr()),
            display.as_ref().map_or(std::ptr::null(), |c| c.as_ptr()),
        )
    };
}

/// One representation, unpacked from the six scalars Kotlin sent and LENT
/// to the C struct for the length of one call. They cross flattened so
/// there is no second copy of capi.rs's layout to keep in step, and `clip`
/// 0 crosses as a NULL representation. ONE STRING ARGUMENT carries text,
/// html AND a custom format's id: `text` and `id` name the same buffer and
/// `clip` decides which the core reads.
fn with_representation<'local, T>(
    env: &mut JNIEnv<'local>,
    clip: jint,
    text: JString<'local>,
    bytes: JByteArray<'local>,
    locators: jni::objects::JObjectArray<'local>,
    names: jni::objects::JObjectArray<'local>,
    body: impl FnOnce(*const crate::capi::KayaRepresentation) -> T,
) -> T {
    if clip == 0 {
        return body(std::ptr::null());
    }
    let text: String = env
        .get_string(&text)
        .map(|s| s.into())
        .expect("kaya: reading the clipboard answer's text failed");
    let payload = env
        .convert_byte_array(&bytes)
        .expect("kaya: reading the clipboard answer's bytes failed");
    let read = |env: &mut JNIEnv, array: &jni::objects::JObjectArray, i: i32| -> String {
        let Ok(item) = env.get_object_array_element(array, i) else {
            return String::new();
        };
        env.get_string(&JString::from(item))
            .map(|s| s.into())
            .unwrap_or_default()
    };
    let count = env.get_array_length(&locators).unwrap_or(0);
    let named = env.get_array_length(&names).unwrap_or(0);
    assert_eq!(
        count, named,
        "kaya: a clipboard answer carries {count} locators and {named} names"
    );
    // A files answer with no files is a caller bug, not the empty
    // answer: the empty answer is clip 0.
    assert!(
        clip as u32 != crate::wire::CLIP_FILES || count > 0,
        "kaya: a clipboard answer names files and carries none — the empty \
         answer is clip 0"
    );
    let mut owned = Vec::with_capacity(count as usize);
    for i in 0..count {
        owned.push((read(env, &locators, i), read(env, &names, i)));
    }
    let text = std::ffi::CString::new(text).unwrap_or_default();
    let cstrings: Vec<(std::ffi::CString, std::ffi::CString)> = owned
        .iter()
        .map(|(l, n)| {
            (
                std::ffi::CString::new(l.as_str()).unwrap_or_default(),
                std::ffi::CString::new(n.as_str()).unwrap_or_default(),
            )
        })
        .collect();
    let locator_ptrs: Vec<*const std::os::raw::c_char> =
        cstrings.iter().map(|(l, _)| l.as_ptr()).collect();
    let name_ptrs: Vec<*const std::os::raw::c_char> =
        cstrings.iter().map(|(_, n)| n.as_ptr()).collect();
    let rep = crate::capi::KayaRepresentation {
        clip: clip as u32,
        text: text.as_ptr(),
        id: text.as_ptr(),
        bytes: payload.as_ptr(),
        len: payload.len(),
        locators: locator_ptrs.as_ptr(),
        names: name_ptrs.as_ptr(),
        count: cstrings.len(),
    };
    body(&rep)
}

/// KayaPresent.emitClipboardResult: the privileged read's one answer.
/// `clip` 0 is the universal no — denied, unfocused, empty, or nothing
/// the request accepted, which no platform tells apart — and the request
/// retires either way.
extern "system" fn present_emit_clipboard_result<'local>(
    mut env: JNIEnv<'local>,
    _class: JClass<'local>,
    request: jlong,
    clip: jint,
    text: JString<'local>,
    bytes: JByteArray<'local>,
    locators: jni::objects::JObjectArray<'local>,
    names: jni::objects::JObjectArray<'local>,
) {
    with_representation(&mut env, clip, text, bytes, locators, names, |rep| unsafe {
        crate::capi::kaya_emit_clipboard_result(request as u64, rep)
    });
}

/// KayaPresent.emitPasted: content arriving at a widget because the USER
/// pasted; the tag rides verbatim. A 0 `clip` is refused HERE, naming the
/// Kotlin entry, rather than in the C one.
extern "system" fn present_emit_pasted<'local>(
    mut env: JNIEnv<'local>,
    _class: JClass<'local>,
    tag: JByteArray<'local>,
    clip: jint,
    text: JString<'local>,
    bytes: JByteArray<'local>,
    locators: jni::objects::JObjectArray<'local>,
    names: jni::objects::JObjectArray<'local>,
) {
    let tag = env
        .convert_byte_array(&tag)
        .expect("kaya: reading the paste tag failed");
    assert_ne!(
        clip, 0,
        "kaya: KayaPresent.emitPasted was handed no representation — a paste \
         that delivered nothing is not an occurrence"
    );
    with_representation(&mut env, clip, text, bytes, locators, names, |rep| unsafe {
        crate::capi::kaya_emit_pasted(tag.as_ptr(), tag.len(), rep)
    });
}

/// KayaPresent.emitDropped: content DROPPED on a widget. The tag and the
/// anchor ride verbatim; the representation marshals as emitPasted's does,
/// and a 0 `clip` is refused here for the same reason.
extern "system" fn present_emit_dropped<'local>(
    mut env: JNIEnv<'local>,
    _class: JClass<'local>,
    tag: JByteArray<'local>,
    x: jni::sys::jdouble,
    y: jni::sys::jdouble,
    operation: jint,
    anchor: JByteArray<'local>,
    before: jni::sys::jboolean,
    clip: jint,
    text: JString<'local>,
    bytes: JByteArray<'local>,
    locators: jni::objects::JObjectArray<'local>,
    names: jni::objects::JObjectArray<'local>,
) {
    let tag = env
        .convert_byte_array(&tag)
        .expect("kaya: reading the drop tag failed");
    let anchor = env
        .convert_byte_array(&anchor)
        .expect("kaya: reading the drop anchor tag failed");
    assert_ne!(
        clip, 0,
        "kaya: KayaPresent.emitDropped was handed no representation — a drop \
         that delivered nothing is not an occurrence"
    );
    with_representation(&mut env, clip, text, bytes, locators, names, |rep| unsafe {
        crate::capi::kaya_emit_dropped(
            tag.as_ptr(),
            tag.len(),
            x,
            y,
            operation as u32,
            anchor.as_ptr(),
            anchor.len(),
            u32::from(before != 0),
            rep,
        )
    });
}

/// KayaPresent.emitDragEnded: a drag that began on the tagged widget ended.
extern "system" fn present_emit_drag_ended<'local>(
    mut env: JNIEnv<'local>,
    _class: JClass<'local>,
    tag: JByteArray<'local>,
    operation: jint,
) {
    let tag = env
        .convert_byte_array(&tag)
        .expect("kaya: reading the drag-ended tag failed");
    unsafe { crate::capi::kaya_emit_drag_ended(tag.as_ptr(), tag.len(), operation as u32) };
}

/// KayaPresent.dragVerdict: the core's one pure hover/drop answer
/// (docs/dnd-plan.md D2). `custom` is the offered ids space-joined, the
/// spelling kaya_drag_verdict parses.
extern "system" fn present_drag_verdict<'local>(
    mut env: JNIEnv<'local>,
    _class: JClass<'local>,
    accepts: JString<'local>,
    target_ops: jint,
    offered: jint,
    custom: JString<'local>,
    source_ops: jint,
    local: jni::sys::jboolean,
) -> jint {
    let accepts: String = env
        .get_string(&accepts)
        .map(|s| s.into())
        .expect("kaya: reading the drop target's accept list failed");
    let custom: String = env
        .get_string(&custom)
        .map(|s| s.into())
        .expect("kaya: reading the offered custom ids failed");
    let accepts = std::ffi::CString::new(accepts).unwrap_or_default();
    let custom = std::ffi::CString::new(custom).unwrap_or_default();
    unsafe {
        crate::capi::kaya_drag_verdict(
            accepts.as_ptr(),
            target_ops as u32,
            offered as u32,
            custom.as_ptr(),
            source_ops as u32,
            u32::from(local != 0),
        ) as jint
    }
}

/// KayaPresent.emitEntryPopped: a native back gesture popped an entry.
extern "system" fn present_emit_entry_popped(_env: JNIEnv, _class: JClass, entry: jlong) {
    crate::capi::kaya_emit_entry_popped(entry as u64);
}

/// KayaPresent.emitSectionSelected: the user switched sections through
/// the platform switcher. Programmatic selection never comes here.
extern "system" fn present_emit_section_selected(
    _env: JNIEnv,
    _class: JClass,
    window: jlong,
    section: jlong,
) {
    crate::capi::kaya_emit_section_selected(window as u64, section as u64);
}

/// KayaPresent.emitBackRequested: back on an intercept_back-armed
/// entry — nothing popped; the app answers with pop_entry.
extern "system" fn present_emit_back_requested(_env: JNIEnv, _class: JClass, entry: jlong) {
    crate::capi::kaya_emit_back_requested(entry as u64);
}

/// KayaPresent.emitSheetDismissed: the user's cancel path closed a sheet.
extern "system" fn present_emit_sheet_dismissed(_env: JNIEnv, _class: JClass, sheet: jlong) {
    crate::capi::kaya_emit_sheet_dismissed(sheet as u64);
}

/// KayaPresent.emitDismissRequested: cancel on an armed sheet — nothing
/// went; the app answers with dismiss_sheet.
extern "system" fn present_emit_dismiss_requested(_env: JNIEnv, _class: JClass, sheet: jlong) {
    crate::capi::kaya_emit_dismiss_requested(sheet as u64);
}

/// KayaPresent.emitMenuActivated: a bar/overflow row, a context-menu row
/// OR its shortcut — one occurrence, one dispatch path. `noun` is the raw
/// wire key path, empty for a bar or live-widget activation.
extern "system" fn present_emit_menu_activated(
    env: JNIEnv,
    _class: JClass,
    item: jlong,
    noun: JByteArray,
) {
    let bytes = env
        .convert_byte_array(&noun)
        .expect("kaya: reading the menu noun failed");
    unsafe { crate::capi::kaya_emit_menu_activated(item as u64, bytes.as_ptr(), bytes.len()) };
}

/// KayaPresent.emitMenuToggled: a toggle flipped by the user
/// (programmatic checked writes never come here).
extern "system" fn present_emit_menu_toggled(
    env: JNIEnv,
    _class: JClass,
    item: jlong,
    noun: JByteArray,
    checked: jni::sys::jboolean,
) {
    let bytes = env
        .convert_byte_array(&noun)
        .expect("kaya: reading the menu noun failed");
    unsafe {
        crate::capi::kaya_emit_menu_toggled(item as u64, bytes.as_ptr(), bytes.len(), checked)
    };
}

/// KayaPresent.emitMenuValueChanged: a radio group's selection changed by
/// the user, keyed by the GROUP's id (programmatic writes never come here).
extern "system" fn present_emit_menu_value_changed(
    env: JNIEnv,
    _class: JClass,
    item: jlong,
    noun: JByteArray,
    index: jni::sys::jdouble,
) {
    let bytes = env
        .convert_byte_array(&noun)
        .expect("kaya: reading the menu noun failed");
    unsafe {
        crate::capi::kaya_emit_menu_value_changed(item as u64, bytes.as_ptr(), bytes.len(), index)
    };
}

extern "system" fn present_emit_toggled(
    env: JNIEnv,
    _class: JClass,
    tag: JByteArray,
    checked: jni::sys::jboolean,
) {
    let bytes = env
        .convert_byte_array(&tag)
        .expect("kaya: reading the checkbox tag failed");
    unsafe { crate::capi::kaya_emit_toggled(bytes.as_ptr(), bytes.len(), checked) };
}

extern "system" fn present_emit_color_changed(
    env: JNIEnv,
    _class: JClass,
    tag: JByteArray,
    packed: jlong,
) {
    let bytes = env
        .convert_byte_array(&tag)
        .expect("kaya: reading the colour picker tag failed");
    unsafe { crate::capi::kaya_emit_color_changed(bytes.as_ptr(), bytes.len(), packed) };
}

extern "system" fn present_color_quantize(
    _env: JNIEnv,
    _class: JClass,
    r: jni::sys::jdouble,
    g: jni::sys::jdouble,
    b: jni::sys::jdouble,
    a: jni::sys::jdouble,
) -> jlong {
    crate::capi::kaya_color_quantize(r, g, b, a) as jlong
}

#[allow(clippy::too_many_arguments)]
extern "system" fn present_range_clamp(
    _env: JNIEnv,
    _class: JClass,
    min: jni::sys::jdouble,
    max: jni::sys::jdouble,
    step: jni::sys::jdouble,
    gap: jni::sys::jdouble,
    low: jni::sys::jboolean,
    other: jni::sys::jdouble,
    raw: jni::sys::jdouble,
) -> jni::sys::jdouble {
    crate::capi::kaya_range_clamp(min, max, step, gap, low, other, raw)
}

extern "system" fn present_emit_range(
    env: JNIEnv,
    _class: JClass,
    tag: JByteArray,
    low: jni::sys::jdouble,
    high: jni::sys::jdouble,
    committed: jni::sys::jboolean,
) {
    let bytes = env
        .convert_byte_array(&tag)
        .expect("kaya: reading the range tag failed");
    unsafe { crate::capi::kaya_emit_range(bytes.as_ptr(), bytes.len(), low, high, committed) };
}

fn jstring_text(env: &mut JNIEnv, s: &JString, what: &str) -> String {
    env.get_string(s)
        .unwrap_or_else(|e| panic!("kaya: reading the {what} string from the JVM failed ({e})"))
        .into()
}

extern "system" fn present_player_loaded(
    mut env: JNIEnv,
    _class: JClass,
    player: jlong,
    duration_ms: jlong,
    width: jint,
    height: jint,
    undecodable: jni::sys::jboolean,
    detail: JString,
) -> jint {
    let detail = jstring_text(&mut env, &detail, "player's decodability");
    (unsafe {
        crate::capi::kaya_player_loaded(
            player as u64,
            duration_ms.max(0) as u64,
            width.max(0) as u32,
            height.max(0) as u32,
            u8::from(undecodable != 0),
            detail.as_ptr(),
            detail.len(),
        )
    }) as jint
}

extern "system" fn present_player_rate(_env: JNIEnv, _class: JClass, player: jlong, playing: jni::sys::jboolean) -> jint {
    crate::capi::kaya_player_rate(player as u64, u8::from(playing != 0)) as jint
}

extern "system" fn present_player_ended(_env: JNIEnv, _class: JClass, player: jlong) -> jint {
    crate::capi::kaya_player_ended(player as u64) as jint
}

extern "system" fn present_player_failed(
    mut env: JNIEnv,
    _class: JClass,
    player: jlong,
    domain: JString,
    code: jlong,
    underlying: jlong,
    detail: JString,
) -> jint {
    let domain = jstring_text(&mut env, &domain, "player failure's domain");
    let detail = jstring_text(&mut env, &detail, "player failure's detail");
    (unsafe {
        crate::capi::kaya_player_failed(
            player as u64,
            domain.as_ptr(),
            domain.len(),
            code,
            underlying,
            detail.as_ptr(),
            detail.len(),
        )
    }) as jint
}

extern "system" fn present_player_position(_env: JNIEnv, _class: JClass, player: jlong, at: jlong) -> jint {
    crate::capi::kaya_player_position(player as u64, at.max(0) as u64) as jint
}

extern "system" fn present_player_seeked(_env: JNIEnv, _class: JClass, player: jlong, at: jlong) -> jint {
    crate::capi::kaya_player_seeked(player as u64, at.max(0) as u64) as jint
}

/// A reader's frame at the platform's full size, fitted to the read's
/// bound by the core's one rule (crate::reader::fit) before it is reported.
#[allow(clippy::too_many_arguments)]
extern "system" fn present_reader_frame(
    env: JNIEnv,
    _class: JClass,
    reader: jlong,
    read: jlong,
    index: jint,
    actual_ms: jlong,
    width: jint,
    height: jint,
    max_width: jint,
    max_height: jint,
    pixels: JByteArray,
) -> jint {
    let Ok(bytes) = env.convert_byte_array(&pixels) else { return 0 };
    let bound = (max_width.max(0) as u32, max_height.max(0) as u32);
    let (w, h, fitted) = crate::reader::fit(width.max(0) as u32, height.max(0) as u32, &bytes, bound);
    (unsafe {
        crate::capi::kaya_reader_frame(
            reader as u64,
            read as u64,
            index.max(0) as u32,
            actual_ms.max(0) as u64,
            w,
            h,
            fitted.as_ptr(),
            fitted.len(),
        )
    }) as jint
}

extern "system" fn present_reader_pcm(
    env: JNIEnv,
    _class: JClass,
    reader: jlong,
    read: jlong,
    channels: jint,
    rate: jint,
    samples: jni::objects::JFloatArray,
    total_ms: jlong,
) -> jint {
    let Ok(n) = env.get_array_length(&samples) else { return 0 };
    let mut floats = vec![0f32; n.max(0) as usize];
    if env.get_float_array_region(&samples, 0, &mut floats).is_err() {
        return 0;
    }
    (unsafe {
        crate::capi::kaya_reader_pcm(
            reader as u64,
            read as u64,
            channels.max(0) as u32,
            rate.max(0) as u32,
            floats.as_ptr(),
            floats.len(),
            total_ms.max(0) as u64,
        )
    }) as jint
}

extern "system" fn present_reader_finished(_env: JNIEnv, _class: JClass, reader: jlong, read: jlong) {
    crate::capi::kaya_reader_finished(reader as u64, read as u64);
}

extern "system" fn present_reader_failed(
    mut env: JNIEnv,
    _class: JClass,
    reader: jlong,
    read: jlong,
    domain: JString,
    code: jlong,
    underlying: jlong,
    detail: JString,
) {
    let domain = jstring_text(&mut env, &domain, "reader failure's domain");
    let detail = jstring_text(&mut env, &detail, "reader failure's detail");
    unsafe {
        crate::capi::kaya_reader_failed(
            reader as u64,
            read as u64,
            domain.as_ptr(),
            domain.len(),
            code,
            underlying,
            detail.as_ptr(),
            detail.len(),
        )
    }
}

extern "system" fn present_reader_no_track(mut env: JNIEnv, _class: JClass, reader: jlong, read: jlong, detail: JString) {
    let detail = jstring_text(&mut env, &detail, "reader's missing track");
    unsafe { crate::capi::kaya_reader_no_track(reader as u64, read as u64, detail.as_ptr(), detail.len()) }
}

extern "system" fn present_reader_overdue(_env: JNIEnv, _class: JClass, reader: jlong, read: jlong) -> jint {
    crate::capi::kaya_reader_overdue(reader as u64, read as u64) as jint
}

extern "system" fn present_player_overdue(_env: JNIEnv, _class: JClass, player: jlong) -> jint {
    crate::capi::kaya_player_overdue(player as u64) as jint
}

extern "system" fn present_player_tracks(
    mut env: JNIEnv,
    _class: JClass,
    player: jlong,
    audio: JString,
    captions: JString,
    audio_selected: jint,
    caption_selected: jint,
) -> jint {
    let audio = jstring_text(&mut env, &audio, "audio track list");
    let captions = jstring_text(&mut env, &captions, "caption track list");
    (unsafe {
        crate::capi::kaya_player_tracks(
            player as u64,
            audio.as_ptr(),
            audio.len(),
            captions.as_ptr(),
            captions.len(),
            audio_selected.max(0) as u32,
            caption_selected.max(0) as u32,
        )
    }) as jint
}

extern "system" fn present_player_cue(mut env: JNIEnv, _class: JClass, player: jlong, text: JString) -> jint {
    let text = jstring_text(&mut env, &text, "platform cue");
    (unsafe { crate::capi::kaya_player_cue(player as u64, text.as_ptr(), text.len()) }) as jint
}

extern "system" fn present_player_captions_text(
    mut env: JNIEnv,
    _class: JClass,
    player: jlong,
    url: JString,
    text: JString,
) -> jint {
    let url = jstring_text(&mut env, &url, "caption file's url");
    let text = jstring_text(&mut env, &text, "caption file's text");
    (unsafe {
        crate::capi::kaya_player_captions_text(player as u64, url.as_ptr(), url.len(), text.as_ptr(), text.len())
    }) as jint
}

extern "system" fn present_player_captions_failed(
    mut env: JNIEnv,
    _class: JClass,
    player: jlong,
    url: JString,
    domain: JString,
    code: jlong,
    underlying: jlong,
    detail: JString,
) -> jint {
    let url = jstring_text(&mut env, &url, "caption file's url");
    let domain = jstring_text(&mut env, &domain, "caption fetch's domain");
    let detail = jstring_text(&mut env, &detail, "caption fetch's detail");
    (unsafe {
        crate::capi::kaya_player_captions_failed(
            player as u64,
            url.as_ptr(),
            url.len(),
            domain.as_ptr(),
            domain.len(),
            code,
            underlying,
            detail.as_ptr(),
            detail.len(),
        )
    }) as jint
}

extern "system" fn present_caption_at<'a>(
    env: JNIEnv<'a>,
    _class: JClass,
    player: jlong,
    t_ms: jlong,
) -> jni::sys::jstring {
    let mut buf = vec![0u8; 256];
    let mut n = unsafe { crate::capi::kaya_caption_at(player as u64, t_ms.max(0) as u64, buf.as_mut_ptr(), buf.len()) };
    if n > buf.len() {
        buf = vec![0u8; n];
        n = unsafe { crate::capi::kaya_caption_at(player as u64, t_ms.max(0) as u64, buf.as_mut_ptr(), buf.len()) };
    }
    let text = String::from_utf8_lossy(&buf[..n.min(buf.len())]).into_owned();
    env.new_string(text)
        .expect("kaya: handing a caption back to the JVM failed")
        .into_raw()
}

extern "system" fn present_video_visible(_env: JNIEnv, _class: JClass, widget: jlong, shown: jni::sys::jdouble) {
    crate::capi::kaya_video_visible(widget as u64, shown)
}

extern "system" fn present_session_action(_env: JNIEnv, _class: JClass, action: jint, at_ms: jlong) -> jint {
    crate::capi::kaya_session_action(action.max(0) as u32, at_ms.max(0) as u64) as jint
}

extern "system" fn present_session_state(_env: JNIEnv, _class: JClass) -> jint {
    crate::capi::kaya_session_state() as jint
}

#[allow(clippy::too_many_arguments)]
extern "system" fn present_capture_state(
    mut env: JNIEnv,
    _class: JClass,
    capture: jlong,
    state: jint,
    reason: jint,
    width: jint,
    height: jint,
    frame_rate: jint,
    detail: JString,
) {
    let detail = jstring_text(&mut env, &detail, "capture detail");
    unsafe {
        crate::capi::kaya_capture_state(
            capture as u64,
            state.max(0) as u32,
            reason.max(0) as u32,
            width.max(0) as u32,
            height.max(0) as u32,
            frame_rate.max(0) as u32,
            detail.as_ptr(),
            detail.len(),
        )
    }
}

extern "system" fn present_capture_overdue(_env: JNIEnv, _class: JClass, capture: jlong) -> jint {
    crate::capi::kaya_capture_overdue(capture as u64) as jint
}

extern "system" fn present_capture_permission(mut env: JNIEnv, _class: JClass, kind: jint, permission: jint, detail: JString) {
    let detail = jstring_text(&mut env, &detail, "permission detail");
    unsafe { crate::capi::kaya_capture_permission(kind.max(0) as u32, permission.max(0) as u32, detail.as_ptr(), detail.len()) }
}

extern "system" fn present_capture_devices_begin(_env: JNIEnv, _class: JClass) {
    crate::capi::kaya_capture_devices_begin();
}

extern "system" fn present_capture_device(
    mut env: JNIEnv,
    _class: JClass,
    id: JString,
    name: JString,
    kind: jint,
    facing: jint,
    preferred: jni::sys::jboolean,
) {
    let id = jstring_text(&mut env, &id, "capture device id");
    let name = jstring_text(&mut env, &name, "capture device name");
    unsafe {
        crate::capi::kaya_capture_device(
            id.as_ptr(),
            id.len(),
            name.as_ptr(),
            name.len(),
            kind.max(0) as u32,
            facing.max(0) as u32,
            u32::from(preferred != 0),
        )
    }
}

extern "system" fn present_capture_devices_end(_env: JNIEnv, _class: JClass) {
    crate::capi::kaya_capture_devices_end();
}

/// A plane as the platform handed it: a direct buffer, its row stride and
/// the distance between two samples of one row.
struct Plane {
    at: *const u8,
    len: usize,
    row: usize,
    pixel: usize,
}

fn plane(env: &JNIEnv, buffer: &jni::objects::JByteBuffer, row: jint, pixel: jint) -> Option<Plane> {
    let at = env.get_direct_buffer_address(buffer).ok()?;
    let len = env.get_direct_buffer_capacity(buffer).ok()?;
    Some(Plane { at: at as *const u8, len, row: row.max(0) as usize, pixel: pixel.max(1) as usize })
}

/// YUV_420_888's three planes as NV12 (docs/capture-plan.md §4): handed
/// over in place when the U plane already IS the interleaved UV plane (U
/// first, V one byte after it, both planes whole), else repacked.
#[allow(clippy::too_many_arguments)]
extern "system" fn present_capture_frame(
    env: JNIEnv,
    _class: JClass,
    capture: jlong,
    width: jint,
    height: jint,
    y: jni::objects::JByteBuffer,
    y_row: jint,
    y_pixel: jint,
    u: jni::objects::JByteBuffer,
    u_row: jint,
    u_pixel: jint,
    v: jni::objects::JByteBuffer,
    v_row: jint,
    v_pixel: jint,
    timestamp_ns: jlong,
    rotation: jint,
) -> jint {
    let (w, h) = (width.max(0) as usize, height.max(0) as usize);
    let (Some(yp), Some(up), Some(vp)) = (plane(&env, &y, y_row, y_pixel), plane(&env, &u, u_row, u_pixel), plane(&env, &v, v_row, v_pixel))
    else {
        return 1;
    };
    if w == 0 || h == 0 || yp.at.is_null() || up.at.is_null() || vp.at.is_null() {
        return 1;
    }
    let rows = h.div_ceil(2);
    let in_place = yp.pixel == 1
        && yp.len >= yp.row * h
        && up.pixel == 2
        && vp.pixel == 2
        && up.row == vp.row
        && vp.at as usize == up.at as usize + 1
        && vp.len + 1 >= up.row * rows;
    let live = if in_place {
        unsafe { crate::capi::kaya_capture_frame(capture as u64, w as u32, h as u32, yp.at, yp.row as u32, up.at, up.row as u32, timestamp_ns as u64, rotation.max(0) as u32) }
    } else {
        let sample = |p: &Plane, x: usize, row: usize| -> u8 {
            let at = row * p.row + x * p.pixel;
            if at < p.len { unsafe { *p.at.add(at) } } else { 0 }
        };
        let mut luma = vec![0u8; w * h];
        for row in 0..h {
            for x in 0..w {
                luma[row * w + x] = sample(&yp, x, row);
            }
        }
        let mut chroma = vec![0u8; w.div_ceil(2) * 2 * rows];
        let stride = w.div_ceil(2) * 2;
        for row in 0..rows {
            for x in 0..w.div_ceil(2) {
                chroma[row * stride + x * 2] = sample(&up, x, row);
                chroma[row * stride + x * 2 + 1] = sample(&vp, x, row);
            }
        }
        unsafe {
            crate::capi::kaya_capture_frame(capture as u64, w as u32, h as u32, luma.as_ptr(), w as u32, chroma.as_ptr(), stride as u32, timestamp_ns as u64, rotation.max(0) as u32)
        }
    };
    // 2 for a frame repacked, so the arm can say once which layout came.
    if live == 0 { 0 } else if in_place { 1 } else { 2 }
}

extern "system" fn present_capture_samples(
    env: JNIEnv,
    _class: JClass,
    capture: jlong,
    channels: jint,
    rate: jint,
    samples: jni::objects::JFloatArray,
    count: jint,
    timestamp_ns: jlong,
) {
    let n = count.max(0) as usize;
    let mut floats = vec![0f32; n];
    if n == 0 || env.get_float_array_region(&samples, 0, &mut floats).is_err() {
        return;
    }
    unsafe {
        crate::capi::kaya_capture_samples(capture as u64, channels.max(1) as u32, rate.max(0) as u32, floats.as_ptr(), n, timestamp_ns as u64)
    }
}

/// The `index`th synthetic device as "id\nname\nkind\nfacing\npreferred\ncontent",
/// or null past the last.
extern "system" fn present_capture_synthetic<'local>(env: JNIEnv<'local>, _class: JClass, index: jint) -> JString<'local> {
    let Some(d) = crate::capture::SYNTHETIC.get(index.max(0) as usize) else { return JString::default() };
    let line = format!(
        "{}\n{}\n{}\n{}\n{}\n{}",
        d.id,
        d.name,
        crate::wire::capture_kind_raw(d.kind),
        crate::wire::camera_facing_raw(d.facing),
        u32::from(d.preferred),
        d.content
    );
    env.new_string(line).unwrap_or_default()
}

extern "system" fn present_capture_synthetic_permission(_env: JNIEnv, _class: JClass, kind: jint, ask: jni::sys::jboolean) -> jint {
    crate::capi::kaya_capture_synthetic_permission(kind.max(0) as u32, u32::from(ask != 0)) as jint
}

extern "system" fn present_capture_nearest_format<'local>(
    env: JNIEnv<'local>,
    _class: JClass,
    offered: jni::objects::JIntArray,
    width: f64,
    height: f64,
    frame_rate: f64,
) -> jni::objects::JIntArray<'local> {
    let n = env.get_array_length(&offered).unwrap_or(0).max(0) as usize;
    let mut raw = vec![0i32; n];
    if env.get_int_array_region(&offered, 0, &mut raw).is_err() {
        return jni::objects::JIntArray::default();
    }
    let formats: Vec<(u32, u32, u32)> =
        raw.chunks_exact(3).map(|t| (t[0].max(0) as u32, t[1].max(0) as u32, t[2].max(0) as u32)).collect();
    let Some((w, h, fps)) = crate::capture::nearest_format(&formats, (width, height, frame_rate)) else {
        return jni::objects::JIntArray::default();
    };
    let Ok(out) = env.new_int_array(3) else { return jni::objects::JIntArray::default() };
    if env.set_int_array_region(&out, 0, &[w as i32, h as i32, fps as i32]).is_err() {
        return jni::objects::JIntArray::default();
    }
    out
}

extern "system" fn present_capture_self_view_box<'local>(
    env: JNIEnv<'local>,
    _class: JClass,
    width: jint,
    height: jint,
    rotation: jint,
    aspect: jni::sys::jlong,
) -> jni::objects::JIntArray<'local> {
    let frames = (width.max(0) as u32, height.max(0) as u32);
    let (w, h) = crate::media::video_view_box(
        crate::media::VideoPicture::SelfView { frames, rotation: rotation.max(0) as u32 },
        aspect,
    );
    let Ok(out) = env.new_int_array(2) else { return jni::objects::JIntArray::default() };
    if env.set_int_array_region(&out, 0, &[w as i32, h as i32]).is_err() {
        return jni::objects::JIntArray::default();
    }
    out
}

extern "system" fn present_video_view_box<'local>(
    env: JNIEnv<'local>,
    _class: JClass,
    width: jint,
    height: jint,
    aspect: jni::sys::jlong,
) -> jni::objects::JIntArray<'local> {
    let picture = crate::media::VideoPicture::Player((width.max(0) as u32, height.max(0) as u32));
    let (w, h) = crate::media::video_view_box(picture, aspect);
    let Ok(out) = env.new_int_array(2) else { return jni::objects::JIntArray::default() };
    if env.set_int_array_region(&out, 0, &[w as i32, h as i32]).is_err() {
        return jni::objects::JIntArray::default();
    }
    out
}

/// The harness's capture verbs: "1" or "0" (recorded or failed), then the sentence.
extern "system" fn present_capture_harness<'local>(
    mut env: JNIEnv<'local>,
    _class: JClass,
    verb: jint,
    index: jint,
    text: JString,
) -> JString<'local> {
    let text = jstring_text(&mut env, &text, "capture verb text");
    let mut out = vec![0u8; 1024];
    let mut ok = 0u8;
    let n = unsafe {
        crate::capi::kaya_capture_harness(verb.max(0) as u32, index as u32, text.as_ptr(), text.len(), out.as_mut_ptr(), out.len(), &mut ok)
    };
    out.truncate(n.min(1024));
    let sentence = String::from_utf8_lossy(&out);
    env.new_string(format!("{ok}{sentence}")).unwrap_or_default()
}

extern "system" fn present_color_palette(env: JNIEnv, _class: JClass) -> jni::sys::jlongArray {
    let packed: Vec<jlong> = crate::protocol::Color::PALETTE.iter().map(|c| c.packed()).collect();
    let out = env
        .new_long_array(packed.len() as jint)
        .expect("kaya: allocating the colour palette for the JVM failed");
    env.set_long_array_region(&out, 0, &packed)
        .expect("kaya: writing the colour palette for the JVM failed");
    out.into_raw()
}

extern "system" fn present_emit_date_changed(
    env: JNIEnv,
    _class: JClass,
    tag: JByteArray,
    packed: jlong,
) {
    let bytes = env
        .convert_byte_array(&tag)
        .expect("kaya: reading the date picker tag failed");
    unsafe { crate::capi::kaya_emit_date_changed(bytes.as_ptr(), bytes.len(), packed) };
}

extern "system" fn present_emit_time_changed(
    env: JNIEnv,
    _class: JClass,
    tag: JByteArray,
    packed: jlong,
) {
    let bytes = env
        .convert_byte_array(&tag)
        .expect("kaya: reading the time picker tag failed");
    unsafe { crate::capi::kaya_emit_time_changed(bytes.as_ptr(), bytes.len(), packed) };
}

extern "system" fn present_emit_sort_requested(
    env: JNIEnv,
    _class: JClass,
    tag: JByteArray,
    column: jni::sys::jint,
) {
    let bytes = env
        .convert_byte_array(&tag)
        .expect("kaya: reading the sort tag failed");
    unsafe {
        crate::capi::kaya_emit_sort_requested(bytes.as_ptr(), bytes.len(), column as u32)
    };
}

/// KayaPresent.blobCount: how many blobs the current batch's table holds
/// (handles 1..=count), so the pump prefetches the whole table.
extern "system" fn present_blob_count(_env: JNIEnv, _class: JClass) -> jlong {
    unsafe { crate::capi::kaya_blob_count() as jlong }
}

/// KayaPresent.blobData: a blob's bytes by the handle an apply record
/// carried, copied into a fresh byte[] (the JVM cannot borrow core
/// memory). Null for a dead handle; fetch within the batch.
extern "system" fn present_blob_data(
    env: JNIEnv,
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
/// copy that batch's apply-op records into a fresh byte[] (the JVM cannot
/// borrow core memory, and the borrow dies at the next call anyway). Null
/// on shutdown. The array is sized by the CORE — a pump that sizes its own
/// aborted the process at 157 rows (docs/deferred.md, the 64 KiB pump wall).
extern "system" fn present_next_commands(env: JNIEnv, _class: JClass) -> jni::sys::jbyteArray {
    let mut bytes: *const u8 = std::ptr::null();
    let n = unsafe { crate::capi::kaya_next_commands(&mut bytes) };
    if n == 0 || bytes.is_null() {
        return std::ptr::null_mut();
    }
    let batch = unsafe { std::slice::from_raw_parts(bytes, n) };
    match env.byte_array_from_slice(batch) {
        Ok(array) => array.into_raw(),
        Err(e) => {
            log::error!(
                "kaya: copying an apply batch of {n} bytes to the JVM failed: {e} — \
                 the pump reads this as shutdown and the surface stops updating"
            );
            std::ptr::null_mut()
        }
    }
}

/// Export the JNI entry `dev.kaya.Kaya.attach` resolves, wiring `$app` as
/// the app-thread logic. Returns who presents.
#[macro_export]
macro_rules! android_main {
    ($app:path) => {
        #[unsafe(no_mangle)]
        extern "system" fn Java_dev_kaya_Kaya_attach<'local>(
            env: $crate::android::JNIEnv<'local>,
            _class: $crate::android::JClass<'local>,
            activity: $crate::android::JObject<'local>,
            state_root: $crate::android::JString<'local>,
        ) -> $crate::android::jint_export {
            $crate::android::attach(env, activity, state_root, $app)
        }
    };
}

/// The capability query's Compose half (docs/media-plan.md §8 ruling 1):
/// KayaCompose.canPlay, whose refusal is the Kotlin side's to state.
pub(crate) fn can_play(mime: &str, codecs: &str) -> bool {
    let (Some(vm), Some(class)) = (JVM.get(), COMPOSE_CLASS.get()) else {
        panic!("kaya: can_play({mime:?}) before the Compose backend attached")
    };
    let mut env = vm.attach_current_thread().expect("kaya: attaching the app thread for can_play");
    let (Ok(mime_arg), Ok(codecs_arg)) = (env.new_string(mime), env.new_string(codecs)) else {
        panic!("kaya: can_play({mime:?}) could not hand its strings to the JVM")
    };
    let called = env.call_static_method(
        class,
        "canPlay",
        "(Ljava/lang/String;Ljava/lang/String;)Z",
        &[(&mime_arg).into(), (&codecs_arg).into()],
    );
    if env.exception_check().unwrap_or(false) {
        let _ = env.exception_describe();
        let _ = env.exception_clear();
        panic!("kaya: KayaCompose.canPlay({mime:?}) threw; its sentence is in the log above");
    }
    called.and_then(|v| v.z()).unwrap_or(false)
}
