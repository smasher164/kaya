//! The preference store's Linux and Windows backing (docs/tasks-s4-plan.md
//! P2, §4): those two platforms have no canonical settings store, so kaya
//! writes the GLib key-file shape a GTK app already reads —
//! `$XDG_CONFIG_HOME/<domain>/preferences` and
//! `%LOCALAPPDATA%\<domain>\preferences`.
//!
//! TWO GROUPS. `[preferences]` holds the value in the key file's own
//! textual form, so `g_key_file_get_boolean` and friends read it; `[types]`
//! holds one letter per key (`s` `i` `f` `b`), which is what makes the
//! typed-mismatch-is-absent rule (§4, the uniform semantics) decidable —
//! nothing in the text of `1` says whether the app stored an integer, a
//! float or a boolean, and a store that guessed would answer a `get_bool`
//! on an integer key.
//!
//! Compiled on every target: the desktops USE it, and the core's unit
//! tests exercise it everywhere (a round trip nobody runs on the two
//! platforms that ship it is a round trip nobody runs).

use std::collections::BTreeMap;
use std::io::Write as _;
use std::path::{Path, PathBuf};

use crate::prefs::PrefValue;

const GROUP_VALUES: &str = "[preferences]";
const GROUP_TYPES: &str = "[types]";

/// GLib's own escape set for a key file's values.
fn escape(text: &str, escape_equals: bool) -> String {
    let mut out = String::with_capacity(text.len());
    for c in text.chars() {
        match c {
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            // A key file forbids `=` in a KEY, so escaping it there costs
            // a normal key nothing and keeps an odd one round-tripping.
            '=' if escape_equals => out.push_str("\\="),
            _ => out.push(c),
        }
    }
    out
}

fn unescape(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut chars = text.chars();
    while let Some(c) = chars.next() {
        if c != '\\' {
            out.push(c);
            continue;
        }
        match chars.next() {
            Some('n') => out.push('\n'),
            Some('r') => out.push('\r'),
            Some('t') => out.push('\t'),
            Some(other) => out.push(other),
            None => out.push('\\'),
        }
    }
    out
}

fn type_letter(value: &PrefValue) -> char {
    match value {
        PrefValue::Str(_) => 's',
        PrefValue::I64(_) => 'i',
        PrefValue::F64(_) => 'f',
        PrefValue::Bool(_) => 'b',
    }
}

fn text_of(value: &PrefValue) -> String {
    match value {
        PrefValue::Str(s) => s.clone(),
        PrefValue::I64(n) => n.to_string(),
        PrefValue::F64(n) => n.to_string(),
        PrefValue::Bool(b) => b.to_string(),
    }
}

fn typed(letter: char, text: &str) -> Option<PrefValue> {
    match letter {
        's' => Some(PrefValue::Str(text.to_owned())),
        'i' => text.parse().ok().map(PrefValue::I64),
        'f' => text.parse().ok().map(PrefValue::F64),
        'b' => match text {
            "true" => Some(PrefValue::Bool(true)),
            "false" => Some(PrefValue::Bool(false)),
            _ => None,
        },
        _ => None,
    }
}

/// The line's `key=value` split, at the first UNESCAPED `=`: a key
/// containing one is written `\=` (a key file forbids it outright, so
/// escaping costs a normal key nothing), and splitting at the first `=`
/// would cut that key in half.
fn split_at_separator(line: &str) -> Option<(&str, &str)> {
    let bytes = line.as_bytes();
    let mut escaped = false;
    for (i, &b) in bytes.iter().enumerate() {
        if escaped {
            escaped = false;
            continue;
        }
        match b {
            b'\\' => escaped = true,
            b'=' => return Some((&line[..i], &line[i + 1..])),
            _ => {}
        }
    }
    None
}

/// The whole store, as the file holds it. Order is the map's, so a
/// rewritten file is stable and a diff of two runs is the change.
pub(crate) type Store = BTreeMap<String, PrefValue>;

pub(crate) fn parse(text: &str) -> Store {
    let mut values: BTreeMap<String, String> = BTreeMap::new();
    let mut types: BTreeMap<String, char> = BTreeMap::new();
    let mut group = String::new();
    for raw in text.lines() {
        let line = raw.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        if line.starts_with('[') {
            group = line.to_owned();
            continue;
        }
        let Some((lhs, rhs)) = split_at_separator(line) else { continue };
        let key = unescape(lhs.trim());
        if group == GROUP_VALUES {
            values.insert(key, unescape(rhs.trim()));
        } else if group == GROUP_TYPES {
            types.insert(key, rhs.trim().chars().next().unwrap_or('s'));
        }
    }
    values
        .into_iter()
        .filter_map(|(key, text)| {
            let letter = types.get(&key).copied().unwrap_or('s');
            typed(letter, &text).map(|value| (key, value))
        })
        .collect()
}

pub(crate) fn render(store: &Store) -> String {
    let mut out = String::from("# kaya's preference store (docs/tasks-s4-plan.md P2).\n");
    out.push_str(GROUP_VALUES);
    out.push('\n');
    for (key, value) in store {
        out.push_str(&format!("{}={}\n", escape(key, true), escape(&text_of(value), false)));
    }
    out.push('\n');
    out.push_str(GROUP_TYPES);
    out.push('\n');
    for (key, value) in store {
        out.push_str(&format!("{}={}\n", escape(key, true), type_letter(value)));
    }
    out
}

/// A fresh read of the file, never a cache: `expect_pref`'s read-back and
/// the first use of the store both take this route.
pub(crate) fn read(path: &Path) -> Store {
    match std::fs::read_to_string(path) {
        Ok(text) => parse(&text),
        Err(_) => Store::new(),
    }
}

/// ATOMIC AND DURABLE (§2 unknown 1): a set is on disk when it returns, so
/// a process killed a millisecond later loses nothing. Temp file, fsync,
/// rename, fsync the directory.
pub(crate) fn write(path: &Path, store: &Store) -> std::io::Result<()> {
    let dir = path.parent().unwrap_or(Path::new("."));
    std::fs::create_dir_all(dir)?;
    let tmp: PathBuf = dir.join(format!(
        "preferences.{}.tmp",
        std::process::id()
    ));
    {
        let mut file = std::fs::File::create(&tmp)?;
        file.write_all(render(store).as_bytes())?;
        file.sync_all()?;
    }
    std::fs::rename(&tmp, path)?;
    // The rename itself is only durable once the DIRECTORY is synced; a
    // Windows open of a directory fails, and NTFS's rename is journalled,
    // so the failure is ignored rather than made a refusal.
    if let Ok(handle) = std::fs::File::open(dir) {
        let _ = handle.sync_all();
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn round_trip(store: &Store) -> Store {
        parse(&render(store))
    }

    #[test]
    fn all_four_types_survive_the_key_file() {
        let mut store = Store::new();
        store.insert("week_start".into(), PrefValue::I64(1));
        store.insert("scale".into(), PrefValue::F64(1.25));
        store.insert("hide_badge".into(), PrefValue::Bool(true));
        store.insert("keep_done".into(), PrefValue::Bool(false));
        store.insert("greeting".into(), PrefValue::Str("a = b\nc\td\\e".into()));
        let back = round_trip(&store);
        assert_eq!(back, store);
        // AND THE FILE IS THE SHAPE A GTK APP READS: the plain textual
        // form under one group, so `g_key_file_get_boolean` answers.
        let text = render(&store);
        assert!(text.contains("[preferences]"), "{text}");
        assert!(text.contains("hide_badge=true"), "{text}");
        assert!(text.contains("week_start=1"), "{text}");
        assert!(text.contains("scale=1.25"), "{text}");
    }

    #[test]
    fn a_key_with_an_equals_sign_round_trips() {
        let mut store = Store::new();
        store.insert("a=b".into(), PrefValue::Str("v".into()));
        assert_eq!(round_trip(&store), store);
    }

    #[test]
    fn the_type_group_is_what_tells_one_1_from_another() {
        // WITHOUT `[types]` these three are the same four bytes on disk.
        let mut store = Store::new();
        store.insert("i".into(), PrefValue::I64(1));
        store.insert("f".into(), PrefValue::F64(1.0));
        store.insert("b".into(), PrefValue::Bool(true));
        let back = round_trip(&store);
        assert_eq!(back.get("i"), Some(&PrefValue::I64(1)));
        assert_eq!(back.get("f"), Some(&PrefValue::F64(1.0)));
        assert_eq!(back.get("b"), Some(&PrefValue::Bool(true)));
    }

    #[test]
    fn the_write_is_atomic_and_reads_back_from_disk() {
        let dir = std::env::temp_dir().join(format!("kaya-prefs-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let path = dir.join("preferences");
        let mut store = Store::new();
        store.insert("week_start".into(), PrefValue::I64(1));
        write(&path, &store).expect("the key file");
        assert_eq!(read(&path), store);
        // No temp file survives a finished write.
        let leftovers: Vec<_> = std::fs::read_dir(&dir)
            .expect("the directory")
            .filter_map(|e| e.ok())
            .map(|e| e.file_name().to_string_lossy().into_owned())
            .filter(|n| n.ends_with(".tmp"))
            .collect();
        assert!(leftovers.is_empty(), "{leftovers:?}");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_missing_file_is_an_empty_store_rather_than_an_error() {
        assert!(read(Path::new("/nonexistent/kaya/preferences")).is_empty());
    }
}
