//! The JVM guest tier's transport, everywhere a JVM runs: the KayaRing
//! natives, shared between Android (android.rs's attach registers them
//! beside the Compose pump) and the desktops (this module's own attach).
//! dev.kaya.KayaRing exists twice — Kotlin in android/kaya, Java in
//! bindings/java-desktop — and registration matches by name+signature
//! against whichever loaded; tools/check-jni.py holds the other direction.

use jni::objects::{JBooleanArray, JByteArray, JClass, JDoubleArray, JLongArray};
use jni::sys::{jboolean, jdouble, jint, jlong};
use jni::NativeMethod;
use jni::JNIEnv;

/// Register the ring natives on dev.kaya.KayaRing — the portable
/// surface both JVMs share.
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
                name: "assetOpen".into(),
                sig: "([B)J".into(),
                fn_ptr: ring_asset_open as *mut _,
            },
            NativeMethod {
                name: "assetBytes".into(),
                sig: "(J)[B".into(),
                fn_ptr: ring_asset_bytes as *mut _,
            },
            NativeMethod {
                name: "assetBlob".into(),
                sig: "(J)J".into(),
                fn_ptr: ring_asset_blob as *mut _,
            },
            NativeMethod {
                name: "assetRelease".into(),
                sig: "(J)V".into(),
                fn_ptr: ring_asset_release as *mut _,
            },
            NativeMethod {
                name: "assetMissSentence".into(),
                sig: "([B)[B".into(),
                fn_ptr: ring_asset_miss_sentence as *mut _,
            },
            // THE PREFERENCE STORE AND THE APP DATA DIRECTORY
            // (docs/tasks-s4-plan.md §4). THE RING LIST, NOT THE DESKTOP
            // ONE: prefs are a floor call on Android too, and
            // tools/check-jni.py is what holds that (docs/deferred.md,
            // KayaRing.openPicked).
            NativeMethod {
                name: "appDataDir".into(),
                sig: "()[B".into(),
                fn_ptr: ring_app_data_dir as *mut _,
            },
            NativeMethod {
                name: "prefGetString".into(),
                sig: "([B)[B".into(),
                fn_ptr: ring_pref_get_string as *mut _,
            },
            NativeMethod {
                name: "prefGetI64".into(),
                sig: "([B)[J".into(),
                fn_ptr: ring_pref_get_i64 as *mut _,
            },
            NativeMethod {
                name: "prefGetF64".into(),
                sig: "([B)[D".into(),
                fn_ptr: ring_pref_get_f64 as *mut _,
            },
            NativeMethod {
                name: "prefGetBool".into(),
                sig: "([B)[Z".into(),
                fn_ptr: ring_pref_get_bool as *mut _,
            },
            NativeMethod {
                name: "prefSetString".into(),
                sig: "([B[B)V".into(),
                fn_ptr: ring_pref_set_string as *mut _,
            },
            NativeMethod {
                name: "prefSetI64".into(),
                sig: "([BJ)V".into(),
                fn_ptr: ring_pref_set_i64 as *mut _,
            },
            NativeMethod {
                name: "prefSetF64".into(),
                sig: "([BD)V".into(),
                fn_ptr: ring_pref_set_f64 as *mut _,
            },
            NativeMethod {
                name: "prefSetBool".into(),
                sig: "([BZ)V".into(),
                fn_ptr: ring_pref_set_bool as *mut _,
            },
            NativeMethod {
                name: "prefRemove".into(),
                sig: "([B)V".into(),
                fn_ptr: ring_pref_remove as *mut _,
            },
            NativeMethod {
                name: "specHash".into(),
                sig: "()J".into(),
                fn_ptr: ring_spec_hash as *mut _,
            },
            NativeMethod {
                name: "capabilities".into(),
                sig: "()J".into(),
                fn_ptr: ring_capabilities as *mut _,
            },
            NativeMethod {
                name: "submit".into(),
                sig: "([B)V".into(),
                fn_ptr: ring_submit as *mut _,
            },
            NativeMethod {
                name: "openPicked".into(),
                sig: "(JI[I)Ljava/io/FileDescriptor;".into(),
                fn_ptr: ring_open_picked as *mut _,
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

// Posted work is not an occurrence and never enters the ring; any
// thread may call this.
extern "system" fn ring_wake(_env: JNIEnv, _class: JClass) {
    crate::capi::kaya_wake()
}

pub(crate) extern "system" fn ring_spec_hash(_env: JNIEnv, _class: JClass) -> jlong {
    crate::spec::hash() as jlong
}

/// KayaRing.capabilities: the host capability word, as a jlong because
/// JNI has no unsigned types; the bits are the same bits.
pub(crate) extern "system" fn ring_capabilities(_env: JNIEnv, _class: JClass) -> jlong {
    crate::capi::kaya_capabilities() as jlong
}

extern "system" fn ring_submit(env: JNIEnv, _class: JClass, records: JByteArray) {
    let bytes = env
        .convert_byte_array(&records)
        .expect("kaya: reading the submitted transaction failed");
    unsafe { crate::capi::kaya_submit(bytes.as_ptr(), bytes.len()) };
}

/// One copy into core memory; the handle is consumed by the next submit.
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

/// Redeem an occurrence blob for its bytes, and release it.
///
/// COPY THEN RELEASE, in that order: the pointer borrows core memory
/// that the release frees.
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

/// 0 is the MISS, carried across as-is; the binding raises with the
/// sentence assetMissSentence hands it.
///
/// THE NAME TRAVELS AS UTF-8 BYTES, never a jstring: JNI's string calls
/// speak MODIFIED UTF-8, so a name outside ASCII would reach the
/// resolver as something other than what the guest typed.
extern "system" fn ring_asset_open(env: JNIEnv, _class: JClass, name: JByteArray) -> jlong {
    let bytes = env
        .convert_byte_array(&name)
        .expect("kaya: reading the asset name failed");
    (unsafe { crate::capi::kaya_asset_open(bytes.as_ptr(), bytes.len()) }) as jlong
}

/// One copy out of core memory: the pointer borrows the core's Arc and
/// is valid only until release. An empty array for a dead handle.
extern "system" fn ring_asset_bytes<'a>(
    env: JNIEnv<'a>,
    _class: JClass<'a>,
    handle: jlong,
) -> JByteArray<'a> {
    let mut len = 0usize;
    let data = unsafe { crate::capi::kaya_asset_bytes(handle as u64, &mut len) };
    let bytes: &[u8] = if data.is_null() || len == 0 {
        &[]
    } else {
        unsafe { std::slice::from_raw_parts(data, len) }
    };
    env.byte_array_from_slice(bytes)
        .expect("kaya: handing over the asset bytes failed")
}

/// The bytes never enter the JVM's heap — the core clones an Arc —
/// which is why this is not assetBytes plus blobRegister.
extern "system" fn ring_asset_blob(_env: JNIEnv, _class: JClass, handle: jlong) -> jlong {
    crate::capi::kaya_asset_blob(handle as u64) as jlong
}

/// Idempotent in the core: the Java side's close and its
/// phantom-reference sweep may both fire for one asset.
extern "system" fn ring_asset_release(_env: JNIEnv, _class: JClass, handle: jlong) {
    crate::capi::kaya_asset_release(handle as u64)
}

/// The core's sentence for why a name would miss, CARRIED and not
/// composed, as UTF-8 bytes; empty means the name resolves. The
/// why-not itself is crates/kaya/src/assets.rs's.
///
/// SIZED, THEN READ: a null buffer asks the sentence's true length.
extern "system" fn ring_asset_miss_sentence<'a>(
    env: JNIEnv<'a>,
    _class: JClass<'a>,
    name: JByteArray<'a>,
) -> JByteArray<'a> {
    let name = env
        .convert_byte_array(&name)
        .expect("kaya: reading the asset name failed");
    let len =
        unsafe { crate::capi::kaya_asset_why_not(name.as_ptr(), name.len(), std::ptr::null_mut(), 0) };
    let mut buf = vec![0u8; len];
    if len > 0 {
        unsafe {
            crate::capi::kaya_asset_why_not(name.as_ptr(), name.len(), buf.as_mut_ptr(), len)
        };
    }
    env.byte_array_from_slice(&buf)
        .expect("kaya: handing over the asset diagnostic failed")
}

// THE PREFERENCE STORE over the pinned floor (docs/tasks-s4-plan.md §4).
// ABSENT IS A NULL ARRAY, PRESENT IS A ONE-ELEMENT ONE: a boxed
// Long/Double/Boolean would need a class lookup here, and the Java side
// reads `a == null` at one place per type.

/// The app's data directory as UTF-8 bytes; EMPTY means none yet (Android
/// before attach). `ring_asset_miss_sentence`'s size-then-read shape.
extern "system" fn ring_app_data_dir<'a>(env: JNIEnv<'a>, _class: JClass<'a>) -> JByteArray<'a> {
    let len = unsafe { crate::capi::kaya_app_data_dir(std::ptr::null_mut(), 0) };
    let mut buf = vec![0u8; len];
    if len > 0 {
        unsafe { crate::capi::kaya_app_data_dir(buf.as_mut_ptr(), len) };
    }
    env.byte_array_from_slice(&buf)
        .expect("kaya: handing over the data directory failed")
}

/// The null object reference every absent answer below returns.
fn null_ref<T: From<jni::objects::JObject<'static>>>() -> T {
    T::from(unsafe { jni::objects::JObject::from_raw(std::ptr::null_mut()) })
}

extern "system" fn ring_pref_get_string<'a>(
    env: JNIEnv<'a>,
    _class: JClass<'a>,
    key: JByteArray<'a>,
) -> JByteArray<'a> {
    let key = env.convert_byte_array(&key).expect("kaya: reading the pref key failed");
    let mut len = 0usize;
    let present = unsafe {
        crate::capi::kaya_pref_get_string(
            key.as_ptr(),
            key.len(),
            std::ptr::null_mut(),
            0,
            &mut len,
        )
    };
    if present == 0 {
        return null_ref();
    }
    let mut buf = vec![0u8; len];
    let mut got = 0usize;
    unsafe {
        crate::capi::kaya_pref_get_string(key.as_ptr(), key.len(), buf.as_mut_ptr(), len, &mut got)
    };
    buf.truncate(got.min(len));
    env.byte_array_from_slice(&buf)
        .expect("kaya: handing over the pref value failed")
}

extern "system" fn ring_pref_get_i64<'a>(
    env: JNIEnv<'a>,
    _class: JClass<'a>,
    key: JByteArray<'a>,
) -> JLongArray<'a> {
    let key = env.convert_byte_array(&key).expect("kaya: reading the pref key failed");
    let mut out: i64 = 0;
    if unsafe { crate::capi::kaya_pref_get_i64(key.as_ptr(), key.len(), &mut out) } == 0 {
        return null_ref();
    }
    let arr = env.new_long_array(1).expect("kaya: allocating the pref answer failed");
    env.set_long_array_region(&arr, 0, &[out]).expect("kaya: writing the pref answer failed");
    arr
}

extern "system" fn ring_pref_get_f64<'a>(
    env: JNIEnv<'a>,
    _class: JClass<'a>,
    key: JByteArray<'a>,
) -> JDoubleArray<'a> {
    let key = env.convert_byte_array(&key).expect("kaya: reading the pref key failed");
    let mut out: f64 = 0.0;
    if unsafe { crate::capi::kaya_pref_get_f64(key.as_ptr(), key.len(), &mut out) } == 0 {
        return null_ref();
    }
    let arr = env.new_double_array(1).expect("kaya: allocating the pref answer failed");
    env.set_double_array_region(&arr, 0, &[out]).expect("kaya: writing the pref answer failed");
    arr
}

extern "system" fn ring_pref_get_bool<'a>(
    env: JNIEnv<'a>,
    _class: JClass<'a>,
    key: JByteArray<'a>,
) -> JBooleanArray<'a> {
    let key = env.convert_byte_array(&key).expect("kaya: reading the pref key failed");
    let mut out: u8 = 0;
    if unsafe { crate::capi::kaya_pref_get_bool(key.as_ptr(), key.len(), &mut out) } == 0 {
        return null_ref();
    }
    let arr = env.new_boolean_array(1).expect("kaya: allocating the pref answer failed");
    env.set_boolean_array_region(&arr, 0, &[jboolean::from(out != 0)])
        .expect("kaya: writing the pref answer failed");
    arr
}

extern "system" fn ring_pref_set_string<'a>(
    env: JNIEnv<'a>,
    _class: JClass<'a>,
    key: JByteArray<'a>,
    value: JByteArray<'a>,
) {
    let key = env.convert_byte_array(&key).expect("kaya: reading the pref key failed");
    let value = env.convert_byte_array(&value).expect("kaya: reading the pref value failed");
    unsafe {
        crate::capi::kaya_pref_set_string(key.as_ptr(), key.len(), value.as_ptr(), value.len())
    };
}

extern "system" fn ring_pref_set_i64<'a>(
    env: JNIEnv<'a>,
    _class: JClass<'a>,
    key: JByteArray<'a>,
    value: jlong,
) {
    let key = env.convert_byte_array(&key).expect("kaya: reading the pref key failed");
    unsafe { crate::capi::kaya_pref_set_i64(key.as_ptr(), key.len(), value) };
}

extern "system" fn ring_pref_set_f64<'a>(
    env: JNIEnv<'a>,
    _class: JClass<'a>,
    key: JByteArray<'a>,
    value: jdouble,
) {
    let key = env.convert_byte_array(&key).expect("kaya: reading the pref key failed");
    unsafe { crate::capi::kaya_pref_set_f64(key.as_ptr(), key.len(), value) };
}

extern "system" fn ring_pref_set_bool<'a>(
    env: JNIEnv<'a>,
    _class: JClass<'a>,
    key: JByteArray<'a>,
    value: jboolean,
) {
    let key = env.convert_byte_array(&key).expect("kaya: reading the pref key failed");
    unsafe { crate::capi::kaya_pref_set_bool(key.as_ptr(), key.len(), u8::from(value != 0)) };
}

extern "system" fn ring_pref_remove<'a>(
    env: JNIEnv<'a>,
    _class: JClass<'a>,
    key: JByteArray<'a>,
) {
    let key = env.convert_byte_array(&key).expect("kaya: reading the pref key failed");
    unsafe { crate::capi::kaya_pref_remove(key.as_ptr(), key.len()) };
}

/// The desktop bootstrap, and the ONLY symbol the JVM looks up by name
/// — everything else registers from here.
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
        &[NativeMethod {
            name: "run".into(),
            sig: "()I".into(),
            fn_ptr: ring_run as *mut _,
        }],
    )
}

/// The calling thread BECOMES the UI loop; returns only at quit.
#[cfg(not(target_os = "android"))]
extern "system" fn ring_run(_env: JNIEnv, _class: JClass) -> jint {
    crate::capi::kaya_run()
}

/// KayaRing.openPicked: redeem a picked handle and hand Java a
/// FileDescriptor it owns.
///
/// THE FIELD IS SET FROM NATIVE CODE BECAUSE JAVA CANNOT — the reflective
/// route needs `--add-opens java.base/java.io` (docs/file-dialogs-plan.md
/// §6f). NO CLEANER IS REGISTERED: one would close the GUEST's descriptor.
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
        // Three spellings of one private field; ART's is a non-SDK
        // member admitted by hidden-API enforcement
        // (docs/clipboard-plan.md §6).
        if cfg!(target_os = "android") {
            env.set_field(&fd, "descriptor", "I", jni::objects::JValue::Int(raw as jint))?;
        } else if cfg!(windows) {
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
