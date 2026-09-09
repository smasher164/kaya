//! The preference store and the app's data directory
//! (docs/tasks-s4-plan.md P1-P3, §4). ONE semantics, five backings:
//! Apple's UserDefaults, Android's SharedPreferences, and the core's own
//! GLib-shaped key file on Linux and Windows (prefs_keyfile.rs).
//!
//! THE SEMANTICS, uniform in nine bindings (invariant 1): a key is
//! non-empty UTF-8; a key under the `kaya.` prefix is kaya's own (window
//! memory) and a GUEST write to one is refused at the floor
//! (capi::kaya_pref_set_*); a typed get on a key holding another type
//! answers ABSENT, which is why every backing stores the type beside the
//! value; a set is durable when it returns; any thread may use the store.
//!
//! UNDER `KAYA_SELFTEST` THE STORE IS SCRATCH (§4): the domain is
//! `<id>.selftest` and the data directory `<state>/selftest/<id>/data`, and
//! act one empties both (crates/kaya/src/act2.rs, `arm`). A lane must not
//! write the user's real defaults.

use std::path::PathBuf;

/// The four value types the store holds.
#[derive(Clone, Debug, PartialEq)]
pub(crate) enum PrefValue {
    Str(String),
    I64(i64),
    F64(f64),
    Bool(bool),
}

impl PrefValue {
    /// The string form the harness compares (`expect_pref`): `true`/`false`
    /// for a boolean, `{}` Display for the numbers. ONE spelling — the
    /// three harnesses compare this text byte for byte.
    // Read by harness.rs and prefs_android, neither compiled on a
    // harness-less mac build.
    #[allow(dead_code)]
    pub(crate) fn display(&self) -> String {
        match self {
            PrefValue::Str(s) => s.clone(),
            PrefValue::I64(n) => n.to_string(),
            PrefValue::F64(n) => n.to_string(),
            PrefValue::Bool(b) => b.to_string(),
        }
    }
}

/// kaya's own keys (window memory). A guest write is refused.
pub(crate) const RESERVED_PREFIX: &str = "kaya.";

/// The one sentence, mirrored by every binding's own refusal
/// (docs/tasks-s4-plan.md, the pinned floor API's semantics).
pub(crate) fn reserved_refusal(key: &str) -> String {
    format!("kaya: preference key {key:?} is reserved (the kaya. prefix is kaya's own)")
}

pub(crate) fn is_reserved(key: &str) -> bool {
    key.starts_with(RESERVED_PREFIX)
}

/// Where the SwiftUI and Compose interpreters read the domain rather than
/// spelling the rule a second time (act2::ENV_DIR's shape). Exported by
/// `act2::arm`, before the app thread on every platform that has one.
pub(crate) const ENV_DOMAIN: &str = "KAYA_PREF_DOMAIN";

/// The suite / SharedPreferences file / key-file directory this process
/// writes: `<id>`, or `<id>.selftest` under the harness.
pub(crate) fn domain() -> Option<String> {
    static DOMAIN: std::sync::OnceLock<Option<String>> = std::sync::OnceLock::new();
    DOMAIN
        .get_or_init(|| {
            let id = crate::scene::declared_id()?;
            Some(if selftest() { format!("{id}.selftest{}", leg_tag()) } else { id })
        })
        .clone()
}

/// THE SCRATCH IS PER LEG WHERE THE RUNNER GIVES EACH LEG ITS OWN STATE
/// HOME (docs/traps.md, 2026-09-09: a mac pool ran many legs of one app at
/// once, every act one emptied the one shared tree, and taskspersist's
/// open database went read-only under it). The data directory and the
/// marker already live under `XDG_STATE_HOME`; the preference DOMAIN is a
/// suite name with no directory in it, so it carries a tag derived from
/// that home — empty when the runner set none, so a plain relaunch that
/// inherits the leg's environment lands in the same suite.
fn leg_tag() -> String {
    let Some(home) = std::env::var_os("XDG_STATE_HOME") else { return String::new() };
    let home = home.to_string_lossy();
    if home.is_empty() {
        return String::new();
    }
    let mut h: u64 = 0xcbf2_9ce4_8422_2325;
    for b in home.as_bytes() {
        h ^= u64::from(*b);
        h = h.wrapping_mul(0x0000_0100_0000_01b3);
    }
    format!(".{h:016x}")
}

/// Whether this process's stores are the harness's scratch. `act2::arm`
/// has adopted its marker (and set KAYA_SELFTEST) before the app thread,
/// so one variable answers both acts.
pub(crate) fn selftest() -> bool {
    std::env::var_os("KAYA_SELFTEST").is_some()
}

/// The app's own writable directory (docs/tasks-s4-plan.md §4), created on
/// first ask. `None` before Android's attach has handed the files
/// directory in.
pub(crate) fn app_data_dir() -> Option<PathBuf> {
    let dir = data_dir_path()?;
    std::fs::create_dir_all(&dir).ok()?;
    Some(dir)
}

fn data_dir_path() -> Option<PathBuf> {
    let id = crate::scene::declared_id()?;
    if selftest() {
        // THE SCRATCH DATA DIRECTORY (§4), under the same state home the
        // second act's marker uses.
        return Some(selftest_root()?.join("selftest").join(id).join("data"));
    }
    real_data_dir(&id)
}

#[cfg(target_os = "macos")]
fn real_data_dir(id: &str) -> Option<PathBuf> {
    Some(
        PathBuf::from(std::env::var_os("HOME")?)
            .join("Library/Application Support")
            .join(id),
    )
}

/// iOS: the app container's Documents directory, which is the app's own
/// and the one a runner can read back.
#[cfg(target_os = "ios")]
fn real_data_dir(_id: &str) -> Option<PathBuf> {
    Some(PathBuf::from(std::env::var_os("HOME")?).join("Documents"))
}

#[cfg(target_os = "linux")]
fn real_data_dir(id: &str) -> Option<PathBuf> {
    if let Some(data) = std::env::var_os("XDG_DATA_HOME") {
        if !data.is_empty() {
            return Some(PathBuf::from(data).join(id));
        }
    }
    Some(PathBuf::from(std::env::var_os("HOME")?).join(".local/share").join(id))
}

#[cfg(target_os = "windows")]
fn real_data_dir(id: &str) -> Option<PathBuf> {
    Some(PathBuf::from(std::env::var_os("LOCALAPPDATA")?).join(id))
}

/// Android's is the files directory attach was handed; nothing else may
/// guess it (act2.rs's state root, one directory over).
#[cfg(target_os = "android")]
fn real_data_dir(_id: &str) -> Option<PathBuf> {
    crate::prefs_android::data_dir()
}

/// The state home the harness's scratch lives under — act2.rs's, so the
/// marker and the scratch stores are one tree a runner can clear.
#[cfg(all(
    any(feature = "harness", target_os = "macos", target_os = "ios", target_os = "android"),
    not(target_os = "android")
))]
fn selftest_root() -> Option<PathBuf> {
    crate::act2::state_home()
}

/// Android's scratch root is the same files directory the real store
/// lives in — the only place an app may write, and the one a runner reads
/// back through `run-as`.
#[cfg(target_os = "android")]
fn selftest_root() -> Option<PathBuf> {
    crate::prefs_android::data_dir()
}

/// Where act2 is not compiled there is no harness, so nothing is ever
/// scratch (lib.rs's gate: a shipped GTK or WinUI app has no harness at
/// all).
#[cfg(not(any(feature = "harness", target_os = "macos", target_os = "ios", target_os = "android")))]
fn selftest_root() -> Option<PathBuf> {
    None
}

// ------------------------------------------------------------- the store

pub(crate) fn get(key: &str) -> Option<PrefValue> {
    if key.is_empty() {
        return None;
    }
    backing::get(key)
}

/// A read that bypasses every cache — the harness's `expect_pref` on the
/// backends whose harness is the core's (docs/tasks-s4-plan.md §4: the
/// read-back goes through the PLATFORM's store, never kaya's memory of
/// what it wrote).
// harness.rs's `expect_pref` is the only caller, and that module is
// behind `feature = "harness"` on the two Rust backends.
#[allow(dead_code)]
pub(crate) fn read_back(key: &str) -> Option<PrefValue> {
    if key.is_empty() {
        return None;
    }
    backing::read_back(key)
}

pub(crate) fn set(key: &str, value: PrefValue) {
    if key.is_empty() {
        return;
    }
    backing::set(key, value);
}

pub(crate) fn remove(key: &str) {
    if key.is_empty() {
        return;
    }
    backing::remove(key);
}

// ------------------------------------------------- kaya's own window memory

/// `kaya.window.<id>.frame` (docs/tasks-s4-plan.md P4), the ONE spelling.
/// Reserved, so a guest cannot write it and every backend reaches it
/// through the two functions below rather than composing the key.
pub(crate) fn window_frame_key(window: u64) -> String {
    format!("{RESERVED_PREFIX}window.{window}.frame")
}

/// The frame the previous process left: `"<x> <y> <w> <h>"` in the
/// platform's own screen units, or `"- - <w> <h>"` from a backend with no
/// position to give.
pub(crate) fn window_frame(window: u64) -> Option<String> {
    match get(&window_frame_key(window)) {
        Some(PrefValue::Str(text)) => Some(text),
        _ => None,
    }
}

pub(crate) fn set_window_frame(window: u64, frame: &str) {
    set(&window_frame_key(window), PrefValue::Str(frame.to_owned()));
}

/// ACT ONE'S RESET (§4): empty the scratch pref domain and the scratch
/// data directory, so a relaunch scene measures what act one wrote and
/// nothing older. REFUSES OUTSIDE THE HARNESS — a process that reached
/// here with the real domain open would wipe the user's settings.
pub(crate) fn clear_selftest_scratch() {
    if !selftest() {
        return;
    }
    backing::clear();
    if let Some(dir) = data_dir_path() {
        let _ = std::fs::remove_dir_all(&dir);
    }
}

/// Set `KAYA_PREF_DOMAIN` for whichever interpreter is about to run.
/// Called from act2::arm, before the app thread.
pub(crate) fn export_domain() {
    let Some(domain) = domain() else { return };
    // SAFETY: the caller is act2::arm, which runs before the app thread.
    unsafe { std::env::set_var(ENV_DOMAIN, domain) };
}

// ---------------------------------------------------- the five backings

/// Linux and Windows: the core's own key file (prefs_keyfile.rs), read at
/// first use and cached, written through on every set.
#[cfg(any(target_os = "linux", target_os = "windows"))]
mod backing {
    use super::PrefValue;
    use crate::prefs_keyfile as keyfile;
    use std::path::PathBuf;
    use std::sync::Mutex;

    fn path() -> Option<PathBuf> {
        Some(config_home()?.join(super::domain()?).join("preferences"))
    }

    #[cfg(target_os = "linux")]
    fn config_home() -> Option<PathBuf> {
        if let Some(config) = std::env::var_os("XDG_CONFIG_HOME") {
            if !config.is_empty() {
                return Some(PathBuf::from(config));
            }
        }
        Some(PathBuf::from(std::env::var_os("HOME")?).join(".config"))
    }

    #[cfg(target_os = "windows")]
    fn config_home() -> Option<PathBuf> {
        Some(PathBuf::from(std::env::var_os("LOCALAPPDATA")?))
    }

    static STORE: Mutex<Option<keyfile::Store>> = Mutex::new(None);

    fn with<R>(f: impl FnOnce(&mut keyfile::Store) -> R) -> Option<R> {
        let path = path()?;
        let mut guard = STORE.lock().ok()?;
        if guard.is_none() {
            *guard = Some(keyfile::read(&path));
        }
        Some(f(guard.as_mut().expect("filled just above")))
    }

    pub(super) fn get(key: &str) -> Option<PrefValue> {
        with(|store| store.get(key).cloned())?
    }

    pub(super) fn read_back(key: &str) -> Option<PrefValue> {
        keyfile::read(&path()?).get(key).cloned()
    }

    pub(super) fn set(key: &str, value: PrefValue) {
        let Some(path) = path() else { return };
        with(|store| {
            store.insert(key.to_owned(), value);
            // DURABLE WHEN IT RETURNS (P3): written through, fsync'd,
            // renamed into place.
            if let Err(e) = keyfile::write(&path, store) {
                use std::io::Write as _;
                let line = format!("kaya: the preference store could not be written to {}: {e}\n", path.display());
                let _ = std::io::stderr().write_all(line.as_bytes());
            }
        });
    }

    pub(super) fn remove(key: &str) {
        let Some(path) = path() else { return };
        with(|store| {
            if store.remove(key).is_some() {
                let _ = keyfile::write(&path, store);
            }
        });
    }

    pub(super) fn clear() {
        let Some(path) = path() else { return };
        let _ = std::fs::remove_file(&path);
        if let Ok(mut guard) = STORE.lock() {
            *guard = Some(keyfile::Store::new());
        }
    }
}

/// macOS and iOS: `UserDefaults(suiteName:)` — the platform's own store,
/// which `defaults read <domain>` and every backup tool already know
/// (P2). NSUserDefaults is documented thread-safe and answers before the
/// interpreter dylib is loaded, which is what act one's reset and a
/// guest's startup read both need.
#[cfg(any(target_os = "macos", target_os = "ios"))]
mod backing {
    use super::PrefValue;
    use objc2::AnyThread as _;
    use objc2::encode::Encoding;
    use objc2::rc::Retained;
    use objc2::runtime::AnyObject;
    use objc2_foundation::{NSNumber, NSString, NSUserDefaults};

    fn suite() -> Option<Retained<NSUserDefaults>> {
        let name = NSString::from_str(&super::domain()?);
        NSUserDefaults::initWithSuiteName(NSUserDefaults::alloc(), Some(&name))
    }

    /// The stored object's own type decides, so a `get_i64` on a key
    /// holding a string answers absent instead of UserDefaults' coercion
    /// (the semantics, §4).
    fn decode(object: &AnyObject) -> Option<PrefValue> {
        if let Some(text) = object.downcast_ref::<NSString>() {
            return Some(PrefValue::Str(text.to_string()));
        }
        let number = object.downcast_ref::<NSNumber>()?;
        Some(match number.encoding() {
            // A CFBoolean bridges to an NSNumber encoded `c`, and kaya
            // writes no other char-sized number.
            Encoding::Char | Encoding::UChar => PrefValue::Bool(number.as_bool()),
            Encoding::Float | Encoding::Double => PrefValue::F64(number.as_f64()),
            _ => PrefValue::I64(number.as_i64()),
        })
    }

    fn read(defaults: &NSUserDefaults, key: &str) -> Option<PrefValue> {
        let object = defaults.objectForKey(&NSString::from_str(key))?;
        decode(&object)
    }

    pub(super) fn get(key: &str) -> Option<PrefValue> {
        let defaults = suite()?;
        read(&defaults, key)
    }

    /// A FRESH SUITE, which is the platform's own read: UserDefaults
    /// caches per instance, so `expect_pref` re-opening it is the read the
    /// plan asks for (§4).
    #[allow(dead_code)]
    pub(super) fn read_back(key: &str) -> Option<PrefValue> {
        let defaults = suite()?;
        defaults.synchronize();
        read(&defaults, key)
    }

    pub(super) fn set(key: &str, value: PrefValue) {
        let Some(defaults) = suite() else { return };
        let key = NSString::from_str(key);
        match value {
            PrefValue::Str(s) => {
                let text = NSString::from_str(&s);
                unsafe { defaults.setObject_forKey(Some(&text), &key) };
            }
            PrefValue::I64(n) => {
                let number = NSNumber::new_i64(n);
                unsafe { defaults.setObject_forKey(Some(&number), &key) };
            }
            PrefValue::F64(n) => {
                let number = NSNumber::new_f64(n);
                unsafe { defaults.setObject_forKey(Some(&number), &key) };
            }
            PrefValue::Bool(b) => defaults.setBool_forKey(b, &key),
        }
        // DURABLE WHEN IT RETURNS (P3, §2 unknown 1): UserDefaults
        // synchronizes on its own schedule, and a lane kills the process a
        // step later.
        defaults.synchronize();
    }

    pub(super) fn remove(key: &str) {
        let Some(defaults) = suite() else { return };
        defaults.removeObjectForKey(&NSString::from_str(key));
        defaults.synchronize();
    }

    pub(super) fn clear() {
        let Some(domain) = super::domain() else { return };
        let Some(defaults) = suite() else { return };
        defaults.removePersistentDomainForName(&NSString::from_str(&domain));
        defaults.synchronize();
    }
}

/// Android: SharedPreferences, through crates/kaya/src/prefs_android.rs
/// (agent ANDROID's, over android.rs's `dev.kaya.KayaPrefs` JNI half).
#[cfg(target_os = "android")]
mod backing {
    use super::PrefValue;

    pub(super) fn get(key: &str) -> Option<PrefValue> {
        crate::prefs_android::get(key)
    }

    /// SharedPreferences IS the platform's read — the arm holds no cache
    /// of its own, so this is `get`.
    pub(super) fn read_back(key: &str) -> Option<PrefValue> {
        crate::prefs_android::get(key)
    }

    pub(super) fn set(key: &str, value: PrefValue) {
        crate::prefs_android::set(key, value);
    }

    pub(super) fn remove(key: &str) {
        crate::prefs_android::remove(key);
    }

    pub(super) fn clear() {
        crate::prefs_android::clear();
    }
}

#[cfg(test)]
mod tests {
    #[test]
    fn the_leg_tag_follows_the_state_home_and_is_empty_without_one() {
        let _serial = crate::assets::serially();
        let before = std::env::var_os("XDG_STATE_HOME");
        unsafe { std::env::remove_var("XDG_STATE_HOME") };
        assert_eq!(super::leg_tag(), "");
        unsafe { std::env::set_var("XDG_STATE_HOME", "/tmp/kaya-leg-a/state") };
        let a = super::leg_tag();
        unsafe { std::env::set_var("XDG_STATE_HOME", "/tmp/kaya-leg-b/state") };
        let b = super::leg_tag();
        match before {
            Some(v) => unsafe { std::env::set_var("XDG_STATE_HOME", v) },
            None => unsafe { std::env::remove_var("XDG_STATE_HOME") },
        }
        assert!(a.starts_with('.') && a.len() == 17, "{a}");
        assert_ne!(a, b, "two legs, two suites");
    }

    use super::*;

    #[test]
    fn the_reserved_prefix_is_the_kaya_dot_one() {
        assert!(is_reserved("kaya.window.0.frame"));
        assert!(!is_reserved("week_start"));
        assert!(!is_reserved("kayak"));
        // THE SENTENCE THE NINE BINDINGS MIRROR, byte for byte.
        assert_eq!(
            reserved_refusal("kaya.window.0.frame"),
            "kaya: preference key \"kaya.window.0.frame\" is reserved \
             (the kaya. prefix is kaya's own)"
        );
    }

    #[test]
    fn the_window_memory_key_is_reserved_and_spelled_once() {
        assert_eq!(window_frame_key(0), "kaya.window.0.frame");
        assert_eq!(window_frame_key(7), "kaya.window.7.frame");
        // The guest floor refuses exactly this shape, which is why the
        // backends reach it through window_frame/set_window_frame.
        assert!(is_reserved(&window_frame_key(0)));
    }

    #[test]
    fn the_string_form_is_what_expect_pref_compares() {
        assert_eq!(PrefValue::Bool(true).display(), "true");
        assert_eq!(PrefValue::Bool(false).display(), "false");
        assert_eq!(PrefValue::I64(1).display(), "1");
        assert_eq!(PrefValue::F64(1.25).display(), "1.25");
        assert_eq!(PrefValue::Str("a b".into()).display(), "a b");
    }
}
