//! Android's kaya plumbing: the attach entries, the KayaRing natives
//! (the JVM guest tier's transport), and the KayaPresent natives the
//! Compose interpreter pumps through.
//!
//! One backend per platform: presentation is the Compose interpreter
//! in android/kaya/'s Kotlin, an interpreter of resolved apply-ops
//! consumed through the C API — the same pump shape as the SwiftUI
//! backend on Apple. The hosting is inverted here: Android has no
//! native process entry (Zygote forks the process, ActivityThread owns
//! main), so the Activity calls the attach entry on the UI thread
//! during onCreate; kaya spawns the app thread and returns the thread
//! to Android's Looper.
//!
//! The KayaRing natives themselves live in jvm.rs — the ring surface
//! is the JVM tier's transport on EVERY platform with a JVM, and the
//! desktops register the same methods from their own attach.
//!
//! The Kotlin side's native methods are registered here rather than
//! resolved by name, so a guest cdylib's only name-based export is its
//! entry.

use std::sync::mpsc;

use jni::objects::{JByteArray, JString};
use jni::sys::{jint, jlong};
use jni::NativeMethod;

use crate::app::AppCtx;
use crate::protocol::OccSink;

// Public (doc-hidden) because the android_main! expansion names them.
#[doc(hidden)]
pub use jni::JNIEnv;
#[doc(hidden)]
pub use jni::objects::{JClass, JObject};
#[doc(hidden)]
pub use jni::sys::jint as jint_export;

/// attach's return value: the Kotlin side always mounts the Compose
/// interpreter (one backend per platform).
const PRESENT_GUEST: i32 = 1;

/// The JVM this process's kaya was attached from, and dev.kaya.KayaPresent
/// as a GLOBAL REFERENCE — both remembered at attach because a picked
/// file is opened LATER, from a thread the guest made.
///
/// THE GLOBAL REF IS NOT AN OPTIMIZATION. A thread attached with
/// AttachCurrentThread resolves classes through the SYSTEM class loader,
/// which knows the framework and nothing of this app: `FindClass` for
/// dev/kaya/KayaPresent succeeds on the Activity's thread and fails on
/// the guest's. That is precisely the thread hop filedialog.steps exists
/// to exercise, so the by-name spelling would have passed every read
/// done inline and failed the one the scene actually makes.
static JVM: std::sync::OnceLock<jni::JavaVM> = std::sync::OnceLock::new();
static PRESENT_CLASS: std::sync::OnceLock<jni::objects::GlobalRef> =
    std::sync::OnceLock::new();


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
/// One backend per platform: the return value is always PRESENT_GUEST
/// and the Kotlin side mounts the Compose interpreter. Same shape as
/// kaya::run's SwiftUI branch — the Compose pump consumes resolved
/// apply-ops through the C API, and its emissions route into this
/// AppCtx's inbox.
pub fn attach(
    mut env: JNIEnv,
    activity: JObject,
    app_main: impl FnOnce(AppCtx) + Send + 'static,
) -> i32 {
    init_logging();
    let _ = &activity;

    let (occ_tx, occ_rx) = mpsc::channel();
    let ctx = AppCtx::new(occ_rx, crate::capi::presentation_tx_sender(), occ_tx.clone());
    std::thread::Builder::new()
        .name("kaya-app".into())
        .spawn(move || app_main(ctx))
        .expect("failed to spawn the app thread");
    crate::capi::set_presentation_sink(OccSink::Mpsc(occ_tx));
    register_present_natives(&mut env)
        .expect("kaya: registering KayaPresent natives failed");
    PRESENT_GUEST
}

/// Attach when the JVM app itself is the guest: the app's own thread
/// consumes the ring through KayaRing (direct tier) and answers with
/// KayaRing.submit — the same core ends kaya_run hands a C guest on
/// the desktop, plus the Activity anchor Android requires. The core
/// ends STAY in place: the Compose pump takes them through
/// KayaPresent.nextCommands, exactly as the SwiftUI host takes them
/// for a desktop C guest — the Activity mounts KayaCompose after this
/// returns. Exported by name; this lives in kaya's own cdylib.
#[unsafe(no_mangle)]
extern "system" fn Java_dev_kaya_KayaRing_attach(
    mut env: JNIEnv,
    _class: JClass,
    _activity: JObject,
) {
    init_logging();
    crate::jvm::register_ring_natives(&mut env)
        .expect("kaya: registering KayaRing natives failed");
    register_present_natives(&mut env)
        .expect("kaya: registering KayaPresent natives failed");
}

// The presentation-side C API over JNI, for guest-language backends
// (Compose): emissions in, resolved apply-op records out, mirroring
// KayaHostApi on the Apple side.
fn register_present_natives(env: &mut JNIEnv) -> jni::errors::Result<()> {
    let class = env.find_class("dev/kaya/KayaPresent")?;
    // Remembered HERE, on the thread that can still resolve an app class
    // (see JVM/PRESENT_CLASS above).
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
                name: "emitAlertResult".into(),
                sig: "(JI)V".into(),
                fn_ptr: present_emit_alert_result as *mut _,
            },
            NativeMethod {
                name: "emitFileDialogResult".into(),
                sig: "(J[Ljava/lang/String;[Ljava/lang/String;)V".into(),
                fn_ptr: present_emit_file_dialog_result as *mut _,
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
                sig: "([B)I".into(),
                fn_ptr: present_next_commands as *mut _,
            },
            NativeMethod {
                name: "blobData".into(),
                sig: "(J)[B".into(),
                fn_ptr: present_blob_data as *mut _,
            },
            // The same fingerprint the ring exposes: the Compose
            // interpreter asserts it at mount, closing the
            // stale-artifact class on the presentation side (a stale
            // APK against a new libkaya would otherwise decode wire
            // records with old constants).
            NativeMethod {
                name: "specHash".into(),
                sig: "()J".into(),
                fn_ptr: crate::jvm::ring_spec_hash as *mut _,
            },
        ],
    )
}

/// A picked file on Android: the `content://` URI DocumentsUI answered
/// with, opened through the ContentResolver on EVERY redemption.
///
/// The other four platforms hold a path and `PathSource` opens it. There
/// is no path here at all — DocumentsUI answers with a URI into a
/// provider, and the provider may not be a filesystem — so the source
/// holds the URI and pays a JNI call per open. That is the price of the
/// property the vocabulary promises: a handle is redeemable more than
/// once, which an already-open descriptor cannot be. Measured on the
/// emulator: three redemptions, one of them from a thread that did not
/// do the picking, each a fresh descriptor carrying the whole file.
pub(crate) struct UriSource {
    pub name: String,
    pub uri: String,
}

impl crate::protocol::PickedSource for UriSource {
    fn open(&self, mode: crate::protocol::FileMode) -> std::io::Result<(i64, bool)> {
        let fd = open_through_resolver(&self.uri, crate::protocol::android_open_mode(mode))?;
        // Seekability RIDES THE OPEN because only the descriptor knows:
        // a document provider may hand back a pipe (a cloud file being
        // streamed) where the same URI gave a regular file yesterday.
        let file = unsafe { crate::protocol::file_from_raw(fd) };
        let seekable = file.metadata().map(|m| m.is_file()).unwrap_or(false);
        Ok((crate::protocol::raw_handle(file), seekable))
    }

    fn name(&self) -> &str {
        &self.name
    }

    /// EMPTY, and the doc-comment's condition is why: `local_path` is a
    /// name re-opening actually works through, and a content URI is not
    /// a path any file API on any language accepts. The guest gets the
    /// handle, which is the capability, and nothing that looks like a
    /// path but is not one.
    fn local_path(&self) -> &str {
        ""
    }

    /// The `content://` URI, which IS what Android calls this file —
    /// what ClipData.newUri carries and what a receiving app resolves.
    fn locator(&self) -> &str {
        &self.uri
    }
}

/// KayaPresent.openPickedUri: `openFileDescriptor(uri, mode)` then
/// `detachFd()`, on whatever thread the guest called `open` from.
///
/// The JVM exception is READ AND CLEARED rather than left pending: it
/// carries the only description of what went wrong (a revoked grant, a
/// provider that is gone, a mode the document does not allow), and the
/// guest sees it as the io::Error's message. A pending exception left
/// on the thread would instead detonate at the next unrelated JNI call.
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
/// `expect_stall`. A read rather than an emit, and it comes through the
/// same registered-natives table for the same reason everything else
/// does: the interpreter must ask the one live core.
extern "system" fn present_stalled_ms(_env: JNIEnv, _class: JClass) -> i64 {
    crate::stall::stalled_for()
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

extern "system" fn present_emit(env: JNIEnv, _class: JClass, tag: JByteArray) {
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

/// KayaPresent.emitAlertResult: kaya_emit_alert_result's JNI
/// spelling — the jint choice reinterprets as the wire u32 (the
/// cancel sentinel is -1 in java-int terms).
extern "system" fn present_emit_alert_result(
    _env: JNIEnv,
    _class: JClass,
    alert: jlong,
    choice: jint,
) {
    crate::capi::kaya_emit_alert_result(alert as u64, choice as u32);
}

/// KayaPresent.emitFileDialogResult: the picker's one answer.
/// `uris` and `names` are parallel String[]s; EMPTY is cancel, which is
/// how every platform reports it (none can confirm an empty selection).
///
/// The core mints the handles, so this hands over the locators and lets
/// it — the arrays go over as UTF-8 the same way the desktop backends'
/// `char*` do, and `kaya_emit_file_dialog_result` wraps each in the
/// platform's source.
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
    // The C entry reads borrowed pointers for the length of the call, so
    // the CStrings have to outlive the pointer vectors — hence two
    // passes rather than one clever iterator.
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

/// KayaPresent.emitEntryPopped: the user's back gesture popped an
/// entry natively — the core's stack reconciles inside this call.
extern "system" fn present_emit_entry_popped(_env: JNIEnv, _class: JClass, entry: jlong) {
    crate::capi::kaya_emit_entry_popped(entry as u64);
}

/// KayaPresent.emitSectionSelected: the user switched sections through
/// the platform switcher (post-fact; the core's selection mirror
/// reconciles inside). Programmatic selection never comes here.
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

/// KayaPresent.emitMenuActivated: a menu action fired — a bar/overflow
/// row, a context-menu row, OR its shortcut; ONE occurrence, one
/// dispatch path. `noun` is the raw wire key path CONTEXT_ATTACH_NODE
/// handed the backend, empty for a bar or live-widget activation —
/// kaya_emit_menu_activated's JNI spelling.
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

/// KayaPresent.emitMenuToggled: a toggle item flipped by the user
/// (programmatic checked writes never come here — the echo doctrine).
/// kaya_emit_menu_toggled's JNI spelling.
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

/// KayaPresent.emitMenuValueChanged: a radio group's selection changed
/// by the user, keyed by the GROUP's id (programmatic value writes
/// never come here — the echo doctrine). kaya_emit_menu_value_changed's
/// JNI spelling.
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

/// KayaPresent.blobData: fetch a blob's bytes by the handle an apply
/// record carried — kaya_blob_data's JNI spelling, copied into a fresh
/// byte[] (the JVM cannot borrow core memory safely). Null for a dead
/// handle (a batch already superseded); fetch within the batch.
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
/// fill the byte array with apply-op records, and return the length
/// (0 on shutdown).
extern "system" fn present_next_commands(
    env: JNIEnv,
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
