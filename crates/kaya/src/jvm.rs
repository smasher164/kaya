//! The JVM guest tier's transport, everywhere a JVM runs: the
//! KayaRing natives (dev.kaya.KayaRing's native methods), shared
//! between Android (android.rs's attach registers them alongside the
//! Compose pump) and the desktops (this module's own attach export).
//!
//! On a desktop the JVM guest bootstraps exactly like every C guest:
//! System.load the cdylib, KayaRing.attach() (the one name-resolved
//! export — it registers everything else), build the scene over the
//! ring from a guest-owned thread, and hand the calling thread to
//! KayaRing.run(), which IS kaya_run — the host-owns-the-loop shape.
//! macOS accepts no thread but the process's first for AppKit, so the
//! launcher carries -XstartOnFirstThread; Linux and Windows run the
//! loop on whichever thread calls.
//!
//! dev.kaya.KayaRing exists twice by design — Kotlin in android/kaya
//! (attach takes the Activity anchor Android requires), Java in
//! bindings/java-desktop (attach takes nothing; run exists) — and
//! registration matches by name+signature against whichever class
//! loaded this library, so drift on either side fails loudly at
//! attach, on that platform, not at first use.

use jni::objects::{JByteArray, JClass};
use jni::sys::{jint, jlong};
use jni::NativeMethod;
use jni::JNIEnv;

/// Register the ring natives on dev.kaya.KayaRing — the portable
/// surface KayaApp.java is written against (submit, the ring
/// addresses, waitOccurrences, blobRegister, specHash). Android's
/// attach calls this beside the Compose pump registration; the
/// desktop attach below calls it beside `run`.
pub(crate) fn register_ring_natives(env: &mut JNIEnv) -> jni::errors::Result<()> {
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
                name: "wake".into(),
                sig: "()V".into(),
                fn_ptr: ring_wake as *mut _,
            },
            NativeMethod {
                name: "blobRegister".into(),
                sig: "([B)J".into(),
                fn_ptr: ring_blob_register as *mut _,
            },
            NativeMethod {
                name: "occurrenceBlob".into(),
                sig: "(J)[B".into(),
                fn_ptr: ring_occurrence_blob as *mut _,
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
            // Shared, not desktop-only: the JVM guest tier is ONE tier,
            // and a picked file is redeemable from either JVM. On
            // Android this lands on the source that opens through the
            // ContentResolver; on the desktops, on the path source.
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

// The app thread parks in waitOccurrences; posted work is not an
// occurrence and never enters the ring, so this is how a background
// thread says it has queued something. Safe from any thread.
extern "system" fn ring_wake(_env: JNIEnv, _class: JClass) {
    crate::capi::kaya_wake()
}

pub(crate) extern "system" fn ring_spec_hash(_env: JNIEnv, _class: JClass) -> jlong {
    crate::spec::hash() as jlong
}

/// KayaRing.submit: one transaction as a byte array, kaya_submit's JNI
/// spelling (JVM guests cannot call C directly).
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
) -> jlong {
    let bytes = env
        .convert_byte_array(&data)
        .expect("kaya: reading the blob bytes failed");
    (unsafe { crate::capi::kaya_blob_register(bytes.as_ptr(), bytes.len()) }) as jlong
}

/// KayaRing.occurrenceBlob: redeem an occurrence blob for its bytes,
/// and release it.
///
/// COPY THEN RELEASE, in that order: the pointer borrows core memory
/// that the release frees. A blob arriving in an OCCURRENCE is a handle
/// into a table with no boundary that retires one — unlike the apply
/// channel's batch-local index, which the next batch supersedes — so
/// the decoder is what has to let go of it, while decoding, before any
/// handle can reach an app.
///
/// SHARED, NOT DESKTOP-ONLY, like openPicked: the JVM guest tier is ONE
/// tier, and a pasted image is bytes on either JVM.
extern "system" fn ring_occurrence_blob<'a>(
    env: JNIEnv<'a>,
    _class: JClass<'a>,
    handle: jlong,
) -> JByteArray<'a> {
    let mut len = 0usize;
    let data = unsafe { crate::capi::kaya_occurrence_blob(handle as u64, &mut len) };
    let bytes: &[u8] = if data.is_null() || len == 0 {
        &[]
    } else {
        unsafe { std::slice::from_raw_parts(data, len) }
    };
    let out = env
        .byte_array_from_slice(bytes)
        .expect("kaya: handing over the occurrence blob failed");
    crate::capi::kaya_occurrence_blob_release(handle as u64);
    out
}

/// The desktop bootstrap: dev.kaya.KayaRing.attach()'s name-resolved
/// export (the only symbol the JVM looks up by name — everything else
/// registers here, the same single-entry doctrine as Android's).
/// No Activity, no interpreter registration: presentation on a
/// desktop is native (kaya_run hosts it), so only the ring surface
/// and `run` exist.
#[cfg(not(target_os = "android"))]
#[unsafe(no_mangle)]
extern "system" fn Java_dev_kaya_KayaRing_attach(mut env: JNIEnv, _class: JClass) {
    register_ring_natives(&mut env).expect("kaya: registering KayaRing natives failed");
    register_desktop_natives(&mut env)
        .expect("kaya: registering KayaRing desktop natives failed");
}

#[cfg(not(target_os = "android"))]
fn register_desktop_natives(env: &mut JNIEnv) -> jni::errors::Result<()> {
    let class = env.find_class("dev/kaya/KayaRing")?;
    env.register_native_methods(
        &class,
        &[
            NativeMethod {
                name: "run".into(),
                sig: "()I".into(),
                fn_ptr: ring_run as *mut _,
            },
            NativeMethod {
                name: "openPicked".into(),
                sig: "(JI[I)Ljava/io/FileDescriptor;".into(),
                fn_ptr: ring_open_picked as *mut _,
            },
        ],
    )
}

/// KayaRing.run: kaya_run's JNI spelling — the calling thread becomes
/// the UI loop and this returns only at quit, with the exit code.
#[cfg(not(target_os = "android"))]
extern "system" fn ring_run(_env: JNIEnv, _class: JClass) -> jint {
    crate::capi::kaya_run()
}

/// KayaRing.openPicked: redeem a picked handle and hand Java a
/// FileDescriptor it owns.
///
/// THE FIELD IS SET FROM NATIVE CODE BECAUSE JAVA CANNOT. There is no
/// public API for wrapping a descriptor, and reflection into
/// `java.io.FileDescriptor`'s private `fd` throws
/// InaccessibleObjectException on JDK 17 — java.base is not open, so
/// the reflective route would force every kaya application to launch
/// with `--add-opens java.base/java.io=ALL-UNNAMED`. JNI is not subject
/// to that check (measured; docs/file-dialogs-plan.md §6f), so the
/// descriptor is built here through the class's public no-arg
/// constructor and populated with SetIntField.
///
/// NO CLEANER IS REGISTERED, deliberately. The JDK attaches one
/// separately from setting the descriptor, and attaching it here would
/// let the collector close a descriptor the GUEST owns — the opposite
/// of what handing over a capability means. The guest closes it, once,
/// with its own stream.
extern "system" fn ring_open_picked(
    mut env: JNIEnv,
    _class: JClass,
    handle: jlong,
    mode: jint,
    seekable_out: jni::objects::JIntArray,
) -> jni::sys::jobject {
    let mut raw: i64 = 0;
    let mut seekable: u32 = 0;
    let rc = crate::capi::kaya_open_picked(handle as u64, mode as u32, &mut raw, &mut seekable);
    if rc != 0 {
        let _ = env.throw_new(
            "java/io/IOException",
            format!("kaya: opening the picked file failed (code {rc})"),
        );
        return std::ptr::null_mut();
    }
    let _ = env.set_int_array_region(&seekable_out, 0, &[seekable as jint]);
    let build = |env: &mut JNIEnv| -> jni::errors::Result<jni::sys::jobject> {
        let class = env.find_class("java/io/FileDescriptor")?;
        let fd = env.new_object(&class, "()V", &[])?;
        // Unix (and sockets on Windows) carry the int `fd`; Windows
        // regular files carry the long `handle` instead. Both fields
        // exist on every platform's FileDescriptor; only one is live.
        if cfg!(windows) {
            env.set_field(&fd, "handle", "J", jni::objects::JValue::Long(raw))?;
        } else {
            env.set_field(&fd, "fd", "I", jni::objects::JValue::Int(raw as jint))?;
        }
        Ok(fd.into_raw())
    };
    match build(&mut env) {
        Ok(obj) => obj,
        Err(e) => {
            let _ = env.throw_new(
                "java/io/IOException",
                format!("kaya: building the FileDescriptor failed: {e}"),
            );
            std::ptr::null_mut()
        }
    }
}
