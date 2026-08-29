//! Android's kaya plumbing: the attach entries, the KayaRing natives
//! (the JVM guest tier's transport, whose bodies live in jvm.rs), and
//! the KayaPresent natives the Compose interpreter pumps through.
//!
//! Android has no native process entry, so the Activity calls the attach
//! entry on the UI thread during onCreate; kaya spawns the app thread and
//! returns that thread to Android's Looper.

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
/// attach for the same reason: an asset is read from the APP THREAD,
/// which resolves classes through the system class loader.
///
/// THE APPLICATION CONTEXT AND NOT THE ACTIVITY (docs/deferred.md's
/// mount entry). Both reach the same AssetManager, but a configuration
/// change recreates the Activity while this ref is a `OnceLock` — so the
/// process would hold the FIRST, destroyed one for its whole life. The
/// round trip is paid once, here.
static ASSETS_CLASS: std::sync::OnceLock<jni::objects::GlobalRef> =
    std::sync::OnceLock::new();
static APP_CONTEXT: std::sync::OnceLock<jni::objects::GlobalRef> = std::sync::OnceLock::new();

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
    android_logger::init_once(
        android_logger::Config::default()
            .with_max_level(log::LevelFilter::Info)
            .with_tag("kaya"),
    );
    log_panics::init();
}

/// Android's attach: the shell Activity calls Kaya.attach(this) from
/// onCreate on the UI thread, kaya spawns the app thread and returns that
/// thread to the Looper.
pub fn attach(
    mut env: JNIEnv,
    activity: JObject,
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
/// consumes the ring through KayaRing and answers with KayaRing.submit.
/// The core ends stay in place — the Compose pump takes them through
/// KayaPresent.nextCommands once the Activity mounts KayaCompose.
/// Exported by name; this lives in kaya's own cdylib.
#[unsafe(no_mangle)]
extern "system" fn Java_dev_kaya_KayaRing_attach(
    mut env: JNIEnv,
    _class: JClass,
    activity: JObject,
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
    crate::jvm::register_ring_natives(&mut env)
        .expect("kaya: registering KayaRing natives failed");
    register_present_natives(&mut env)
        .expect("kaya: registering KayaPresent natives failed");
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
/// which is why the sentence upstream says "nothing this process could
/// list" and not "carries nothing".
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
                sig: "()[B".into(),
                fn_ptr: present_next_commands as *mut _,
            },
            NativeMethod {
                name: "blobData".into(),
                sig: "(J)[B".into(),
                fn_ptr: present_blob_data as *mut _,
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
/// The Compose harness asks once per step, so a transaction that died
/// inside `Scene::apply` reddens the leg carrying its sentence instead
/// of aborting the process (crates/kaya/src/fault.rs).
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

/// KayaPresent.undoRoute / redoRoute: kaya_undo_route's and
/// kaya_redo_route's JNI spelling — 0 nowhere, 1 the focused field's own
/// stack, 2 the core's ledger. Crossed on every menu render carrying an
/// Edit>Undo row, so it allocates nothing.
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

// --- Row windowing (docs/virtualization-plan.md §3) ------------------
//
// Straight-through to the C entries, like the undo tier above: the core
// owns the band, the presumption and the arithmetic, and the tier owns
// only the geometry it laid out. A refused target FAULTS rather than
// aborting (crates/kaya/src/fault.rs), so the leg reddens with the
// sentence — which is why the Compose tier asks only about a node it
// knows is a For container.

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

/// KayaPresent.windowGeometry: the record's fields written into the
/// caller's `double[]`, in KayaPresent's GEOMETRY_* order. The counts
/// cross as doubles beside the three lengths because ONE array is one
/// JNI call, and a row index is exact in a double past any collection
/// that fits in memory.
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
/// (docs/adaptive-layout-plan.md D3).
extern "system" fn present_window_metrics(
    _env: JNIEnv,
    _class: JClass,
    window: jlong,
    width: jni::sys::jdouble,
    height: jni::sys::jdouble,
) {
    crate::capi::kaya_window_metrics(window as u64, width, height);
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
/// to the C struct for the length of one call.
///
/// The scalars cross flattened rather than assembled on the JVM side, so
/// there is no second copy of capi.rs's layout to keep in step. `clip` 0
/// crosses as a NULL representation — the universal no.
///
/// ONE STRING ARGUMENT carries text, html AND a custom format's id, so
/// the struct's `text` and `id` name the same buffer and `clip` decides
/// which of them the core reads.
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
    // A files answer WITH NO FILES is a caller bug and not the empty
    // A files answer with no files is a caller bug, not the empty answer:
    // the empty answer is clip 0.
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
        ) -> $crate::android::jint_export {
            $crate::android::attach(env, activity, $app)
        }
    };
}
