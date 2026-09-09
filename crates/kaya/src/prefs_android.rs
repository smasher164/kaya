//! The preference store's Android backing (docs/tasks-s4-plan.md P2, §4):
//! a `PrefValue` adapter over crates/kaya/src/android.rs's JNI half, which
//! reaches `dev.kaya.KayaPrefs` and SharedPreferences on the application
//! Context attach remembered.
//!
//! THE TAG IS THE TYPE, one leading character, and this file and
//! KayaPrefs.kt are its two ends. The text beside it is `PrefValue::display`
//! — the same string `expect_pref` compares — so a number crosses as the
//! text Rust wrote and no Kotlin formatter can spell `2.0` where Rust
//! spells `2`.

use std::path::PathBuf;

use crate::prefs::PrefValue;

const TAG_STRING: char = 's';
const TAG_I64: char = 'i';
const TAG_F64: char = 'f';
const TAG_BOOL: char = 'b';

fn tag_of(value: &PrefValue) -> char {
    match value {
        PrefValue::Str(_) => TAG_STRING,
        PrefValue::I64(_) => TAG_I64,
        PrefValue::F64(_) => TAG_F64,
        PrefValue::Bool(_) => TAG_BOOL,
    }
}

pub(crate) fn get(key: &str) -> Option<PrefValue> {
    let held = crate::android::pref_get(key)?;
    let mut chars = held.chars();
    let tag = chars.next()?;
    let text = chars.as_str();
    match tag {
        TAG_STRING => Some(PrefValue::Str(text.to_owned())),
        TAG_I64 => text.parse().ok().map(PrefValue::I64),
        TAG_F64 => text.parse().ok().map(PrefValue::F64),
        // Written by this file, so nothing else is a boolean.
        TAG_BOOL => Some(PrefValue::Bool(text == "true")),
        _ => None,
    }
}

pub(crate) fn set(key: &str, value: PrefValue) {
    crate::android::pref_set(key, tag_of(&value), &value.display());
}

pub(crate) fn remove(key: &str) {
    crate::android::pref_remove(key);
}

pub(crate) fn clear() {
    crate::android::pref_clear();
}

/// The BARE files directory attach was handed — no `<id>` and no selftest
/// suffix, since this directory is already private to this app; prefs.rs
/// lays §4's scratch tree on top of it. `None` before attach.
pub(crate) fn data_dir() -> Option<PathBuf> {
    crate::android::state_root().map(PathBuf::from)
}
