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
    let ctx = AppCtx::new(occ_rx, crate::capi::presentation_tx_sender());
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
    register_ring_natives(&mut env).expect("kaya: registering KayaRing natives failed");
    register_present_natives(&mut env)
        .expect("kaya: registering KayaPresent natives failed");
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

extern "system" fn ring_submit(env: JNIEnv, _class: JClass, records: JByteArray) {
    let bytes = env
        .convert_byte_array(&records)
        .expect("kaya: reading the submitted transaction failed");
    unsafe { crate::capi::kaya_submit(bytes.as_ptr(), bytes.len()) };
}

/// KayaRing.blobRegister: kaya_blob_register's JNI spelling — the JVM
/// guest's bulk-payload entry (one copy into core memory; the handle
/// is consumed by the next submit).
extern "system" fn ring_blob_register(
    env: JNIEnv,
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
            // The same fingerprint the ring exposes: the Compose
            // interpreter asserts it at mount, closing the
            // stale-artifact class on the presentation side (a stale
            // APK against a new libkaya would otherwise decode wire
            // records with old constants).
            NativeMethod {
                name: "specHash".into(),
                sig: "()J".into(),
                fn_ptr: ring_spec_hash as *mut _,
            },
        ],
    )
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
