//! libkaya IS the Node addon (docs/js-plan.md §2). `process.dlopen` on
//! this library finds `napi_register_module_v1` below and gets the
//! function floor bindings/js/kaya/runtime.ts binds — the same calls
//! bindings/python/kaya/runtime.py makes through ctypes. Node's own API
//! is resolved at registration out of the HOST PROCESS's symbol table,
//! so there is no node header, no node-gyp, no link-time dependency and
//! no second artifact: the lane verifies libkaya and that is the addon.
//!
//! THE PUMP (docs/js-plan.md §3): the worker's JS thread is the kaya-app
//! thread, and it cannot block in `kaya_next_occurrence` without
//! freezing its own event loop, so a native thread blocks there for it
//! and hands each record over through a threadsafe function — ONE AT A
//! TIME, waiting for the handler to return before it takes the next.
//! That wait is what keeps the stall watchdog honest: a wedged handler
//! leaves the next click unclaimed in the ring, exactly as a wedged
//! Python app thread does (tools/scenes/stall.steps).

use std::ffi::{CString, c_char, c_int, c_void};
use std::ptr;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Condvar, Mutex, OnceLock};

use crate::capi;

type Env = *mut c_void;
type Value = *mut c_void;
type CbInfo = *mut c_void;
type Tsfn = *mut c_void;
type Status = c_int;
type Callback = unsafe extern "C" fn(Env, CbInfo) -> Value;
type CallJs = unsafe extern "C" fn(Env, Value, *mut c_void, *mut c_void);
type Finalize = unsafe extern "C" fn(Env, *mut c_void, *mut c_void);

const NAPI_OK: Status = 0;
const NAPI_PENDING_EXCEPTION: Status = 10;
const NAPI_UINT8_ARRAY: c_int = 1;
const NAPI_TSFN_RELEASE: c_int = 0;
const NAPI_TSFN_BLOCKING: c_int = 1;

macro_rules! node_api {
    ($($name:ident: fn($($arg:ty),*) -> $ret:ty),* $(,)?) => {
        #[allow(non_snake_case)]
        struct NodeApi { $($name: unsafe extern "C" fn($($arg),*) -> $ret),* }
        impl NodeApi {
            unsafe fn resolve() -> Result<NodeApi, String> {
                Ok(NodeApi { $($name: {
                    let p = unsafe { host_symbol(stringify!($name))? };
                    unsafe { std::mem::transmute::<*mut c_void, unsafe extern "C" fn($($arg),*) -> $ret>(p) }
                }),* })
            }
        }
    };
}

node_api! {
    napi_create_function: fn(Env, *const c_char, usize, Callback, *mut c_void, *mut Value) -> Status,
    napi_set_named_property: fn(Env, Value, *const c_char, Value) -> Status,
    napi_get_cb_info: fn(Env, CbInfo, *mut usize, *mut Value, *mut Value, *mut *mut c_void) -> Status,
    napi_throw_error: fn(Env, *const c_char, *const c_char) -> Status,
    napi_get_value_double: fn(Env, Value, *mut f64) -> Status,
    napi_get_value_string_utf8: fn(Env, Value, *mut c_char, usize, *mut usize) -> Status,
    napi_get_typedarray_info: fn(Env, Value, *mut c_int, *mut usize, *mut *mut c_void, *mut Value, *mut usize) -> Status,
    napi_create_double: fn(Env, f64, *mut Value) -> Status,
    napi_create_int32: fn(Env, i32, *mut Value) -> Status,
    napi_create_bigint_uint64: fn(Env, u64, *mut Value) -> Status,
    napi_create_string_utf8: fn(Env, *const c_char, usize, *mut Value) -> Status,
    napi_create_arraybuffer: fn(Env, usize, *mut *mut c_void, *mut Value) -> Status,
    napi_create_typedarray: fn(Env, c_int, usize, Value, usize, *mut Value) -> Status,
    napi_create_object: fn(Env, *mut Value) -> Status,
    napi_get_null: fn(Env, *mut Value) -> Status,
    napi_get_undefined: fn(Env, *mut Value) -> Status,
    napi_get_boolean: fn(Env, bool, *mut Value) -> Status,
    napi_create_threadsafe_function: fn(Env, Value, Value, Value, usize, usize, *mut c_void, Option<Finalize>, *mut c_void, CallJs, *mut Tsfn) -> Status,
    napi_call_threadsafe_function: fn(Tsfn, *mut c_void, c_int) -> Status,
    napi_release_threadsafe_function: fn(Tsfn, c_int) -> Status,
    napi_call_function: fn(Env, Value, Value, usize, *const Value, *mut Value) -> Status,
    napi_get_and_clear_last_exception: fn(Env, *mut Value) -> Status,
    napi_coerce_to_string: fn(Env, Value, *mut Value) -> Status,
}

static NAPI: OnceLock<NodeApi> = OnceLock::new();

fn api() -> &'static NodeApi {
    NAPI.get().expect("kaya: node api used before registration")
}

#[cfg(unix)]
unsafe fn host_symbol(name: &str) -> Result<*mut c_void, String> {
    unsafe extern "C" {
        fn dlopen(path: *const c_char, flag: c_int) -> *mut c_void;
        fn dlsym(handle: *mut c_void, symbol: *const c_char) -> *mut c_void;
    }
    const RTLD_LAZY: c_int = 1;
    let cname = CString::new(name).expect("static symbol name");
    let p = unsafe { dlsym(dlopen(ptr::null(), RTLD_LAZY), cname.as_ptr()) };
    if p.is_null() {
        return Err(format!(
            "kaya: the host process exports no {name} — process.dlopen on \
             libkaya must come from Node (or a runtime exporting Node-API)"
        ));
    }
    Ok(p)
}

#[cfg(windows)]
unsafe fn host_symbol(name: &str) -> Result<*mut c_void, String> {
    #[link(name = "kernel32")]
    unsafe extern "system" {
        fn GetModuleHandleW(name: *const u16) -> *mut c_void;
        fn GetProcAddress(module: *mut c_void, name: *const c_char) -> *mut c_void;
    }
    let cname = CString::new(name).expect("static symbol name");
    let p = unsafe { GetProcAddress(GetModuleHandleW(ptr::null()), cname.as_ptr()) };
    if p.is_null() {
        return Err(format!(
            "kaya: the host process exports no {name} — process.dlopen on \
             kaya.dll must come from Node (or a runtime exporting Node-API)"
        ));
    }
    Ok(p)
}

/// The one symbol Node looks for. Excluded from kaya.h by
/// crates/kaya/cbindgen.toml: it is Node's contract, not the C ABI's.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn napi_register_module_v1(env: Env, exports: Value) -> Value {
    if NAPI.get().is_none() {
        match unsafe { NodeApi::resolve() } {
            Ok(table) => {
                let _ = NAPI.set(table);
            }
            Err(why) => {
                eprintln!("{why}");
                return exports;
            }
        }
    }
    let api = api();
    let table: &[(&str, Callback)] = &[
        ("specHash", spec_hash),
        ("capabilities", capabilities),
        ("run", run),
        ("submit", submit),
        ("blobRegister", blob_register),
        ("occurrenceBlob", occurrence_blob),
        ("assetOpen", asset_open),
        ("assetBytes", asset_bytes),
        ("assetLen", asset_len),
        ("assetBlob", asset_blob),
        ("assetRelease", asset_release),
        ("assetWhyNot", asset_why_not),
        ("openPicked", open_picked),
        ("startPump", start_pump),
        ("exit", exit),
    ];
    for (name, cb) in table {
        let cname = CString::new(*name).expect("static name");
        let mut f: Value = ptr::null_mut();
        unsafe {
            (api.napi_create_function)(env, cname.as_ptr(), name.len(), *cb, ptr::null_mut(), &mut f);
            (api.napi_set_named_property)(env, exports, cname.as_ptr(), f);
        }
    }
    exports
}

// ------------------------------------------------------------ helpers

unsafe fn args<const N: usize>(env: Env, info: CbInfo) -> [Value; N] {
    let mut argc = N;
    let mut argv = [ptr::null_mut(); N];
    unsafe {
        (api().napi_get_cb_info)(env, info, &mut argc, argv.as_mut_ptr(), ptr::null_mut(), ptr::null_mut());
    }
    argv
}

unsafe fn throw(env: Env, msg: &str) -> Value {
    let cmsg = CString::new(msg).unwrap_or_else(|_| CString::new("kaya: error").unwrap());
    unsafe { (api().napi_throw_error)(env, ptr::null(), cmsg.as_ptr()) };
    ptr::null_mut()
}

/// A u64 handle rides as a JS number: ids and handles are counters, and
/// the root refuses anything past 2^53 before it could get here
/// (crates/kaya/src/spec.rs, MAX_SAFE_INTEGER).
unsafe fn u64_arg(env: Env, v: Value, what: &str) -> Result<u64, String> {
    let mut d = 0.0f64;
    if unsafe { (api().napi_get_value_double)(env, v, &mut d) } != NAPI_OK {
        return Err(format!("kaya: {what} takes a number"));
    }
    if d < 0.0 || d.fract() != 0.0 || d > 9_007_199_254_740_991.0 {
        return Err(format!("kaya: {what} is not a safe non-negative integer: {d}"));
    }
    Ok(d as u64)
}

unsafe fn bytes_arg<'a>(env: Env, v: Value, what: &str) -> Result<&'a [u8], String> {
    let mut ty: c_int = -1;
    let mut len = 0usize;
    let mut data: *mut c_void = ptr::null_mut();
    let mut ab: Value = ptr::null_mut();
    let mut off = 0usize;
    let st = unsafe {
        (api().napi_get_typedarray_info)(env, v, &mut ty, &mut len, &mut data, &mut ab, &mut off)
    };
    if st != NAPI_OK || ty != NAPI_UINT8_ARRAY {
        return Err(format!("kaya: {what} takes a Uint8Array"));
    }
    if len == 0 || data.is_null() {
        return Ok(&[]);
    }
    Ok(unsafe { std::slice::from_raw_parts(data as *const u8, len) })
}

unsafe fn string_arg(env: Env, v: Value, what: &str) -> Result<Vec<u8>, String> {
    let mut needed = 0usize;
    if unsafe { (api().napi_get_value_string_utf8)(env, v, ptr::null_mut(), 0, &mut needed) } != NAPI_OK {
        return Err(format!("kaya: {what} takes a string"));
    }
    let mut buf = vec![0u8; needed + 1];
    let mut written = 0usize;
    unsafe {
        (api().napi_get_value_string_utf8)(env, v, buf.as_mut_ptr() as *mut c_char, buf.len(), &mut written);
    }
    buf.truncate(written);
    Ok(buf)
}

unsafe fn number(env: Env, n: f64) -> Value {
    let mut out: Value = ptr::null_mut();
    unsafe { (api().napi_create_double)(env, n, &mut out) };
    out
}

unsafe fn undefined(env: Env) -> Value {
    let mut out: Value = ptr::null_mut();
    unsafe { (api().napi_get_undefined)(env, &mut out) };
    out
}

unsafe fn null(env: Env) -> Value {
    let mut out: Value = ptr::null_mut();
    unsafe { (api().napi_get_null)(env, &mut out) };
    out
}

unsafe fn string(env: Env, s: &[u8]) -> Value {
    let mut out: Value = ptr::null_mut();
    unsafe { (api().napi_create_string_utf8)(env, s.as_ptr() as *const c_char, s.len(), &mut out) };
    out
}

/// One copy into a fresh ArrayBuffer: the core's bytes are borrowed
/// until the next call or a release, and V8's pointer compression
/// forbids an external buffer over native memory anyway.
unsafe fn uint8array(env: Env, bytes: &[u8]) -> Value {
    let api = api();
    let mut data: *mut c_void = ptr::null_mut();
    let mut ab: Value = ptr::null_mut();
    let mut out: Value = ptr::null_mut();
    unsafe {
        (api.napi_create_arraybuffer)(env, bytes.len(), &mut data, &mut ab);
        if !bytes.is_empty() && !data.is_null() {
            ptr::copy_nonoverlapping(bytes.as_ptr(), data as *mut u8, bytes.len());
        }
        (api.napi_create_typedarray)(env, NAPI_UINT8_ARRAY, bytes.len(), ab, 0, &mut out);
    }
    out
}

macro_rules! try_or_throw {
    ($env:expr, $e:expr) => {
        match $e {
            Ok(v) => v,
            Err(why) => return unsafe { throw($env, &why) },
        }
    };
}

// ----------------------------------------------------------- the floor

unsafe extern "C" fn spec_hash(env: Env, _info: CbInfo) -> Value {
    let mut out: Value = ptr::null_mut();
    unsafe { (api().napi_create_bigint_uint64)(env, capi::kaya_spec_hash(), &mut out) };
    out
}

unsafe extern "C" fn capabilities(env: Env, _info: CbInfo) -> Value {
    unsafe { number(env, capi::kaya_capabilities() as f64) }
}

/// Blocks in kaya_run, then WAITS for the pump to leave before handing
/// the code back: the core's shutdown wakes the pump with SHUTDOWN, and
/// a pump still inside a Node-API call while the process tears down is
/// a crash on the exit path (a Bus error after the verdict, linux
/// a11yrows-js 2026-09-01). Bounded, because a wedged app thread (the
/// stall scene) never consumes the pump's last handoff.
unsafe extern "C" fn run(env: Env, _info: CbInfo) -> Value {
    let code = capi::kaya_run();
    let (lock, cv) = &PUMP_DONE;
    let mut done = lock.lock().unwrap();
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(3);
    while !*done && PUMPING.load(Ordering::SeqCst) {
        let now = std::time::Instant::now();
        if now >= deadline {
            break;
        }
        done = cv.wait_timeout(done, deadline - now).unwrap().0;
    }
    drop(done);
    let mut out: Value = ptr::null_mut();
    unsafe { (api().napi_create_int32)(env, code, &mut out) };
    out
}

unsafe extern "C" fn submit(env: Env, info: CbInfo) -> Value {
    let [v] = unsafe { args::<1>(env, info) };
    let bytes = try_or_throw!(env, unsafe { bytes_arg(env, v, "submit") });
    unsafe { capi::kaya_submit(bytes.as_ptr(), bytes.len()) };
    unsafe { undefined(env) }
}

unsafe extern "C" fn blob_register(env: Env, info: CbInfo) -> Value {
    let [v] = unsafe { args::<1>(env, info) };
    let bytes = try_or_throw!(env, unsafe { bytes_arg(env, v, "blobRegister") });
    let handle = unsafe { capi::kaya_blob_register(bytes.as_ptr(), bytes.len()) };
    unsafe { number(env, handle as f64) }
}

/// Copy then release, in that order: the pointer borrows core memory the
/// release frees (bindings/python/kaya/runtime.py, _occurrence_blob).
unsafe extern "C" fn occurrence_blob(env: Env, info: CbInfo) -> Value {
    let [v] = unsafe { args::<1>(env, info) };
    let handle = try_or_throw!(env, unsafe { u64_arg(env, v, "occurrenceBlob") });
    let mut len = 0usize;
    let data = unsafe { capi::kaya_occurrence_blob(handle, &mut len) };
    let out = if data.is_null() {
        unsafe { uint8array(env, &[]) }
    } else {
        unsafe { uint8array(env, std::slice::from_raw_parts(data, len)) }
    };
    capi::kaya_occurrence_blob_release(handle);
    out
}

unsafe extern "C" fn asset_open(env: Env, info: CbInfo) -> Value {
    let [v] = unsafe { args::<1>(env, info) };
    let name = try_or_throw!(env, unsafe { string_arg(env, v, "assetOpen") });
    let handle = unsafe { capi::kaya_asset_open(name.as_ptr(), name.len()) };
    unsafe { number(env, handle as f64) }
}

unsafe extern "C" fn asset_bytes(env: Env, info: CbInfo) -> Value {
    let [v] = unsafe { args::<1>(env, info) };
    let handle = try_or_throw!(env, unsafe { u64_arg(env, v, "assetBytes") });
    let mut len = 0usize;
    let data = unsafe { capi::kaya_asset_bytes(handle, &mut len) };
    if data.is_null() {
        return unsafe { uint8array(env, &[]) };
    }
    unsafe { uint8array(env, std::slice::from_raw_parts(data, len)) }
}

unsafe extern "C" fn asset_len(env: Env, info: CbInfo) -> Value {
    let [v] = unsafe { args::<1>(env, info) };
    let handle = try_or_throw!(env, unsafe { u64_arg(env, v, "assetLen") });
    unsafe { number(env, capi::kaya_asset_len(handle) as f64) }
}

unsafe extern "C" fn asset_blob(env: Env, info: CbInfo) -> Value {
    let [v] = unsafe { args::<1>(env, info) };
    let handle = try_or_throw!(env, unsafe { u64_arg(env, v, "assetBlob") });
    unsafe { number(env, capi::kaya_asset_blob(handle) as f64) }
}

unsafe extern "C" fn asset_release(env: Env, info: CbInfo) -> Value {
    let [v] = unsafe { args::<1>(env, info) };
    let handle = try_or_throw!(env, unsafe { u64_arg(env, v, "assetRelease") });
    capi::kaya_asset_release(handle);
    unsafe { undefined(env) }
}

/// Asked twice on purpose, like every binding: the first call learns the
/// length, the second fills exactly that (runtime.py, asset_miss_sentence).
unsafe extern "C" fn asset_why_not(env: Env, info: CbInfo) -> Value {
    let [v] = unsafe { args::<1>(env, info) };
    let name = try_or_throw!(env, unsafe { string_arg(env, v, "assetWhyNot") });
    let needed = unsafe { capi::kaya_asset_why_not(name.as_ptr(), name.len(), ptr::null_mut(), 0) };
    if needed == 0 {
        return unsafe { string(env, b"") };
    }
    let mut buf = vec![0u8; needed];
    let written = unsafe { capi::kaya_asset_why_not(name.as_ptr(), name.len(), buf.as_mut_ptr(), needed) };
    buf.truncate(written.min(needed));
    unsafe { string(env, &buf) }
}

/// `{raw, seekable}`: raw is a descriptor on unix and a HANDLE on
/// Windows, the core's own answer handed through untouched — which
/// runtime is entitled to turn a HANDLE into a descriptor is the JS
/// binding's question (docs/js-plan.md §6), not this floor's.
unsafe extern "C" fn open_picked(env: Env, info: CbInfo) -> Value {
    let [h, m] = unsafe { args::<2>(env, info) };
    let handle = try_or_throw!(env, unsafe { u64_arg(env, h, "openPicked handle") });
    let mode = try_or_throw!(env, unsafe { u64_arg(env, m, "openPicked mode") });
    let mut raw: i64 = 0;
    let mut seekable: u32 = 0;
    let rc = capi::kaya_open_picked(handle, mode as u32, &mut raw, &mut seekable);
    if rc != 0 {
        return unsafe { throw(env, &format!("kaya: opening the picked file failed (code {rc})")) };
    }
    let api = api();
    let mut out: Value = ptr::null_mut();
    let mut seek: Value = ptr::null_mut();
    unsafe {
        (api.napi_create_object)(env, &mut out);
        (api.napi_set_named_property)(env, out, c"raw".as_ptr(), number(env, raw as f64));
        (api.napi_get_boolean)(env, seekable != 0, &mut seek);
        (api.napi_set_named_property)(env, out, c"seekable".as_ptr(), seek);
    }
    out
}

/// From the worker, the way to end the PROCESS: `process.exit` there
/// ends only the worker thread, and the main thread is inside kaya_run.
unsafe extern "C" fn exit(env: Env, info: CbInfo) -> Value {
    let [v] = unsafe { args::<1>(env, info) };
    let code = unsafe { u64_arg(env, v, "exit") }.unwrap_or(1);
    // `_exit` on unix: libc's `exit` runs Node's static destructors
    // under a worker still executing the app (docs/traps.md, the Node
    // exit entry).
    crate::exit_hard(code as i32)
}

// ------------------------------------------------------------ the pump

struct Pump {
    tsfn: Tsfn,
    handed: Mutex<bool>,
    cv: Condvar,
}

// A threadsafe function is what its name says: the pump thread calls
// it and the worker's loop consumes it (napi's own contract).
unsafe impl Sync for Pump {}
unsafe impl Send for Pump {}

static PUMPING: AtomicBool = AtomicBool::new(false);
/// Set by the pump thread on its way out; `run` waits on it.
static PUMP_DONE: (Mutex<bool>, Condvar) = (Mutex::new(false), Condvar::new());

/// `startPump(cb)`: cb(record: Uint8Array) per occurrence, cb(null) at
/// shutdown, each call waited for before the next record is taken.
unsafe extern "C" fn start_pump(env: Env, info: CbInfo) -> Value {
    let [cb] = unsafe { args::<1>(env, info) };
    if PUMPING.swap(true, Ordering::SeqCst) {
        return unsafe { throw(env, "kaya: the occurrence pump is already running — one app thread per process") };
    }
    let api = api();
    let pump: &'static Pump = Box::leak(Box::new(Pump {
        tsfn: ptr::null_mut(),
        handed: Mutex::new(false),
        cv: Condvar::new(),
    }));
    let mut tsfn: Tsfn = ptr::null_mut();
    let st = unsafe {
        (api.napi_create_threadsafe_function)(
            env,
            cb,
            ptr::null_mut(),
            string(env, b"kaya occurrences"),
            0,
            1,
            ptr::null_mut(),
            None,
            pump as *const Pump as *mut c_void,
            on_occurrence,
            &mut tsfn,
        )
    };
    if st != NAPI_OK {
        PUMPING.store(false, Ordering::SeqCst);
        return unsafe { throw(env, "kaya: startPump takes a function") };
    }
    // The context pointer above is the leaked Pump; its tsfn field is
    // read only from the pump thread, which starts after this write.
    let pump_mut = pump as *const Pump as *mut Pump;
    unsafe { (*pump_mut).tsfn = tsfn };
    std::thread::Builder::new()
        .name("kaya-node-pump".into())
        .spawn(move || pump_thread(pump))
        .expect("kaya: could not spawn the occurrence pump");
    unsafe { undefined(env) }
}

fn pump_thread(pump: &'static Pump) {
    loop {
        let mut rec: *const u8 = ptr::null();
        let size = unsafe { capi::kaya_next_occurrence(&mut rec) };
        match size {
            capi::KAYA_OCCURRENCE_SHUTDOWN => {
                // The last handoff is not waited for: nothing comes
                // back from it, and a wedged worker would hold the
                // exit path open forever.
                let data = Box::into_raw(Box::new(None::<Vec<u8>>));
                let st = unsafe {
                    (api().napi_call_threadsafe_function)(pump.tsfn, data as *mut c_void, NAPI_TSFN_BLOCKING)
                };
                if st != NAPI_OK {
                    drop(unsafe { Box::from_raw(data) });
                }
                unsafe { (api().napi_release_threadsafe_function)(pump.tsfn, NAPI_TSFN_RELEASE) };
                let (lock, cv) = &PUMP_DONE;
                *lock.lock().unwrap() = true;
                cv.notify_all();
                return;
            }
            capi::KAYA_OCCURRENCE_WOKEN => continue,
            n => {
                let bytes = unsafe { std::slice::from_raw_parts(rec, n) }.to_vec();
                deliver(pump, Some(bytes));
            }
        }
    }
}

fn deliver(pump: &Pump, payload: Option<Vec<u8>>) {
    let data = Box::into_raw(Box::new(payload));
    let mut done = pump.handed.lock().unwrap();
    *done = false;
    let st = unsafe { (api().napi_call_threadsafe_function)(pump.tsfn, data as *mut c_void, NAPI_TSFN_BLOCKING) };
    if st != NAPI_OK {
        // The worker is gone; nothing will ever run the callback.
        drop(unsafe { Box::from_raw(data) });
        return;
    }
    while !*done {
        done = pump.cv.wait(done).unwrap();
    }
}

unsafe extern "C" fn on_occurrence(env: Env, js_cb: Value, context: *mut c_void, data: *mut c_void) {
    let pump = unsafe { &*(context as *const Pump) };
    let payload = unsafe { Box::from_raw(data as *mut Option<Vec<u8>>) };
    // env is null when the worker tore down with records still queued.
    if !env.is_null() && !js_cb.is_null() {
        let api = api();
        let arg = match payload.as_ref() {
            Some(bytes) => unsafe { uint8array(env, bytes) },
            None => unsafe { null(env) },
        };
        let mut result: Value = ptr::null_mut();
        let st = unsafe { (api.napi_call_function)(env, undefined(env), js_cb, 1, &arg, &mut result) };
        if st == NAPI_PENDING_EXCEPTION {
            unsafe { report_exception(env) };
        }
    }
    let mut done = pump.handed.lock().unwrap();
    *done = true;
    pump.cv.notify_all();
}

/// The binding's dispatch catches every handler error itself; an
/// exception reaching here escaped the occurrence callback, which is a
/// binding defect, so it is printed rather than lost.
unsafe fn report_exception(env: Env) {
    let api = api();
    let mut exc: Value = ptr::null_mut();
    let mut text: Value = ptr::null_mut();
    unsafe {
        (api.napi_get_and_clear_last_exception)(env, &mut exc);
        (api.napi_coerce_to_string)(env, exc, &mut text);
    }
    let sentence = unsafe { string_arg(env, text, "exception") }.unwrap_or_default();
    eprintln!(
        "kaya: the occurrence callback threw: {}",
        String::from_utf8_lossy(&sentence)
    );
}
