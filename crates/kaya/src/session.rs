//! The session store and its file (docs/restoration-plan.md SR3, SR5, SR6,
//! SR7, SR8, SR14). The values live here in memory; the file is rewritten at
//! an idle or a save point the backend reports, never on a timer.

use crate::prefs::PrefValue;
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::Mutex;

pub(crate) const FORMAT: &str = "kaya-session-1";
pub(crate) const FILE: &str = "session.v1";
pub(crate) const LOCK: &str = "session.lock";
pub(crate) const BOUND: usize = 256 * 1024;

/// What `restored()` answers (SR6).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Restored {
    Fresh,
    Resumed,
    Recovered,
}

impl Restored {
    pub fn as_str(self) -> &'static str {
        match self {
            Restored::Fresh => "fresh",
            Restored::Resumed => "resumed",
            Restored::Recovered => "recovered",
        }
    }
}

/// What the platform said about this launch (SR6). The desktops have no rule.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum Token {
    NoRule,
    Absent,
    Session(String),
}

/// A value's scope (SR3, SR9), spelled in the file as `app`, `window.<id>`,
/// `document.<id>`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Scope {
    App,
    Window(u64),
    Document(u64),
}

impl Scope {
    fn key(self) -> String {
        match self {
            Scope::App => "app".to_owned(),
            Scope::Window(id) => format!("window.{id}"),
            Scope::Document(id) => format!("document.{id}"),
        }
    }
}

pub(crate) type Values = BTreeMap<String, BTreeMap<String, PrefValue>>;

/// A presentation facet kaya restores on its own (SR1 C, spec.rs's facet
/// table): a textarea's caret and selection in UTF-8 offsets, or a For
/// container's top row by key.
#[derive(Clone, Debug, PartialEq)]
pub(crate) enum Facet {
    Caret { start: u64, stop: u64 },
    Row { key: crate::protocol::Value },
}

/// A facet as saved: the kind it was reported on (SR2: a facet whose id now
/// names another kind is dropped) and its value.
#[derive(Clone, Debug, PartialEq)]
pub(crate) struct Saved {
    pub(crate) kind: String,
    pub(crate) facet: Facet,
}

/// Facets by scope, then by a11y_id (SR2).
pub(crate) type Facets = BTreeMap<String, BTreeMap<String, Saved>>;

/// One window as the last launch left it (SR9): its documents in order, the
/// active one, the selected section and the navigation depth.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub(crate) struct WindowShape {
    pub(crate) window: u64,
    pub(crate) documents: Vec<u64>,
    pub(crate) active: Option<u64>,
    pub(crate) section: Option<u64>,
    pub(crate) depth: u32,
}

pub(crate) type Shape = Vec<WindowShape>;

/// The file as read back, and the launch it makes (§4, the file's sweep).
#[derive(Debug, PartialEq)]
pub(crate) struct Swept {
    pub(crate) restored: Restored,
    pub(crate) values: Values,
    pub(crate) facets: Facets,
    pub(crate) shape: Shape,
    /// The one line the sweep prints, or none for an ordinary launch.
    pub(crate) why: Option<String>,
}

pub(crate) fn empty_key_refusal() -> &'static str {
    "kaya: a session key must not be empty"
}

pub(crate) fn reserved_refusal(key: &str) -> String {
    format!("kaya: session key {key:?} is reserved (the kaya. prefix is kaya's own)")
}

pub(crate) fn bound_refusal(key: &str) -> String {
    format!("kaya: the session value for {key:?} would take the session file past its bound of {BOUND} bytes")
}

/// The sweep, pure: the file's text, this app's id and restore version, and
/// the platform's word.
pub(crate) fn sweep(text: Option<&str>, app_id: &str, restore_version: i64, token: &Token) -> Swept {
    let fresh = |why: Option<String>| Swept { restored: Restored::Fresh, values: Values::new(), facets: Facets::new(), shape: Shape::new(), why };
    let Some(text) = text else {
        return fresh(None);
    };
    let doc: serde_json::Value = match serde_json::from_str(text) {
        Ok(doc @ serde_json::Value::Object(_)) => doc,
        Ok(_) => return fresh(Some("kaya: the session file is not a JSON object: starting fresh".to_owned())),
        Err(e) => return fresh(Some(format!("kaya: the session file is not readable JSON ({e}): starting fresh"))),
    };
    let format = doc.get("format").and_then(|v| v.as_str()).unwrap_or("");
    if format != FORMAT {
        return fresh(Some(format!(
            "kaya: the session file is format {format:?}, not {FORMAT:?}: starting fresh"
        )));
    }
    let owner = doc.get("app").and_then(|v| v.as_str()).unwrap_or("");
    if owner != app_id {
        return fresh(Some(format!(
            "kaya: the session file belongs to app {owner:?}, not {app_id:?}: starting fresh"
        )));
    }
    let file_session = doc.get("session").and_then(|v| v.as_str()).unwrap_or("").to_owned();
    if doc.get("first_idle").and_then(|v| v.as_bool()) != Some(true) {
        return Swept {
            restored: Restored::Recovered,
            values: Values::new(),
            facets: Facets::new(),
            shape: Shape::new(),
            why: Some(format!(
                "kaya: the last launch (session {file_session}) ended before its first idle, \
                 so its state is discarded rather than restored into a second crash"
            )),
        };
    }
    match token {
        Token::NoRule => {}
        Token::Absent => return fresh(None),
        Token::Session(id) if *id == file_session => {}
        Token::Session(id) => {
            return Swept {
                restored: Restored::Recovered,
                values: Values::new(),
                facets: Facets::new(),
                shape: Shape::new(),
                why: Some(format!(
                    "kaya: the platform's token names session {id}, and the session file holds \
                     session {file_session}: the file is from a launch the platform's copy never saw"
                )),
            };
        }
    }
    let file_version = doc.get("restore_version").and_then(|v| v.as_i64()).unwrap_or(0);
    if file_version != restore_version {
        return Swept {
            restored: Restored::Resumed,
            values: Values::new(),
            facets: decode_facets(doc.get("facets")),
            shape: decode_shape(doc.get("shape")),
            why: Some(format!(
                "kaya: the app's restore version moved from {file_version} to {restore_version}: \
                 its session values are discarded"
            )),
        };
    }
    Swept {
        restored: Restored::Resumed,
        values: decode_values(doc.get("values")),
        facets: decode_facets(doc.get("facets")),
        shape: decode_shape(doc.get("shape")),
        why: None,
    }
}

fn decode_shape(v: Option<&serde_json::Value>) -> Shape {
    let ids = |v: Option<&serde_json::Value>| -> Vec<u64> {
        v.and_then(|v| v.as_array()).map(|a| a.iter().filter_map(|d| d.as_u64()).collect()).unwrap_or_default()
    };
    let Some(windows) = v.and_then(|v| v.as_array()) else { return Shape::new() };
    windows
        .iter()
        .filter_map(|w| {
            Some(WindowShape {
                window: w.get("window")?.as_u64()?,
                documents: ids(w.get("documents")),
                active: w.get("active").and_then(|a| a.as_u64()),
                section: w.get("section").and_then(|a| a.as_u64()),
                depth: w.get("depth").and_then(|a| a.as_u64()).unwrap_or(0) as u32,
            })
        })
        .collect()
}

fn encode_shape(shape: &Shape) -> serde_json::Value {
    shape
        .iter()
        .map(|w| {
            serde_json::json!({
                "window": w.window,
                "documents": w.documents,
                "active": w.active,
                "section": w.section,
                "depth": w.depth,
            })
        })
        .collect()
}

fn decode_facets(v: Option<&serde_json::Value>) -> Facets {
    let mut out = Facets::new();
    let Some(scopes) = v.and_then(|v| v.as_object()) else { return out };
    for (scope, entries) in scopes {
        let Some(entries) = entries.as_object() else { continue };
        let mut map = BTreeMap::new();
        for (id, entry) in entries {
            let Some(kind) = entry.get("kind").and_then(|k| k.as_str()) else { continue };
            let facet = if let Some([start, stop]) = entry.get("caret").and_then(|c| c.as_array()).map(|a| a.as_slice()) {
                match (start.as_u64(), stop.as_u64()) {
                    (Some(start), Some(stop)) => Facet::Caret { start, stop },
                    _ => continue,
                }
            } else {
                match entry.get("row").map(|r| (r.get("t").and_then(|t| t.as_str()), r.get("v"))) {
                    Some((Some("i"), Some(v))) if v.is_i64() => Facet::Row { key: crate::protocol::Value::I64(v.as_i64().unwrap_or(0)) },
                    Some((Some("s"), Some(serde_json::Value::String(s)))) => Facet::Row { key: crate::protocol::Value::Str(s.clone()) },
                    _ => continue,
                }
            };
            map.insert(id.clone(), Saved { kind: kind.to_owned(), facet });
        }
        out.insert(scope.clone(), map);
    }
    out
}

fn encode_facets(facets: &Facets) -> serde_json::Value {
    let mut scopes = serde_json::Map::new();
    for (scope, entries) in facets {
        let mut map = serde_json::Map::new();
        for (id, saved) in entries {
            let entry = match &saved.facet {
                Facet::Caret { start, stop } => serde_json::json!({ "kind": saved.kind, "caret": [start, stop] }),
                Facet::Row { key: crate::protocol::Value::I64(n) } => {
                    serde_json::json!({ "kind": saved.kind, "row": { "t": "i", "v": n } })
                }
                Facet::Row { key: crate::protocol::Value::Str(s) } => {
                    serde_json::json!({ "kind": saved.kind, "row": { "t": "s", "v": s } })
                }
                Facet::Row { .. } => continue,
            };
            map.insert(id.clone(), entry);
        }
        if !map.is_empty() {
            scopes.insert(scope.clone(), serde_json::Value::Object(map));
        }
    }
    serde_json::Value::Object(scopes)
}

fn decode_values(v: Option<&serde_json::Value>) -> Values {
    let mut out = Values::new();
    let Some(scopes) = v.and_then(|v| v.as_object()) else { return out };
    for (scope, entries) in scopes {
        let Some(entries) = entries.as_object() else { continue };
        let mut map = BTreeMap::new();
        for (key, entry) in entries {
            let value = match (entry.get("t").and_then(|t| t.as_str()), entry.get("v")) {
                (Some("s"), Some(serde_json::Value::String(s))) => PrefValue::Str(s.clone()),
                (Some("i"), Some(v)) if v.is_i64() => PrefValue::I64(v.as_i64().unwrap_or(0)),
                (Some("f"), Some(v)) if v.is_number() => PrefValue::F64(v.as_f64().unwrap_or(0.0)),
                (Some("b"), Some(serde_json::Value::Bool(b))) => PrefValue::Bool(*b),
                _ => continue,
            };
            map.insert(key.clone(), value);
        }
        out.insert(scope.clone(), map);
    }
    out
}

fn encode_value(value: &PrefValue) -> serde_json::Value {
    let (t, v) = match value {
        PrefValue::Str(s) => ("s", serde_json::Value::from(s.as_str())),
        PrefValue::I64(n) => ("i", serde_json::Value::from(*n)),
        // A NaN or an infinity has no JSON spelling; it is written as 0.
        PrefValue::F64(n) => ("f", serde_json::Number::from_f64(*n).map(serde_json::Value::Number).unwrap_or(0.into())),
        PrefValue::Bool(b) => ("b", serde_json::Value::from(*b)),
    };
    serde_json::json!({ "t": t, "v": v })
}

/// The header and values as the file holds them.
pub(crate) fn encode(app_id: &str, restore_version: i64, session: &str, first_idle: bool, values: &Values, facets: &Facets, shape: &Shape) -> String {
    let mut scopes = serde_json::Map::new();
    for (scope, entries) in values {
        if entries.is_empty() {
            continue;
        }
        let mut map = serde_json::Map::new();
        for (key, value) in entries {
            map.insert(key.clone(), encode_value(value));
        }
        scopes.insert(scope.clone(), serde_json::Value::Object(map));
    }
    let doc = serde_json::json!({
        "format": FORMAT,
        "app": app_id,
        "restore_version": restore_version,
        "session": session,
        "writer": { "pid": std::process::id() },
        "first_idle": first_idle,
        "values": serde_json::Value::Object(scopes),
        "facets": encode_facets(facets),
        "shape": encode_shape(shape),
    });
    serde_json::to_string_pretty(&doc).unwrap_or_default()
}

// ------------------------------------------------------------ the process's

struct Store {
    values: Values,
    facets: Facets,
    /// The facets the file brought, handed to the scene once (SR4).
    restorable: Option<Facets>,
    restored: Restored,
    /// The current shape, reported by the scene at each batch (SR9).
    shape: Shape,
    /// The shape the file brought, handed to the app as restored_windows().
    restored_shape: Shape,
    /// Window and document scopes the app took back (SR9), and those it
    /// wrote this launch; any other restored surface scope goes at settle.
    adopted: std::collections::BTreeSet<String>,
    written: std::collections::BTreeSet<String>,
    /// Past the first idle after the first build: untaken scopes are gone.
    settled: bool,
    session: String,
    app_id: String,
    restore_version: i64,
    /// False under `restoration(false)` and for a second live process.
    writes: bool,
    first_idle: bool,
    dirty: bool,
    dir: Option<PathBuf>,
    /// Held for the process's life: a second process's try-lock fails.
    _lock: Option<std::fs::File>,
}

static STORE: Mutex<Option<Store>> = Mutex::new(None);

/// The app's declarations (SR6, SR7, SR8), keys of its identity manifest
/// because the store is read before the first build: `restoration = "false"`,
/// `restore_version = "<n>"`, `restore_always = "true"`.
#[derive(Clone, Copy, Debug, PartialEq)]
pub(crate) struct Declared {
    pub(crate) enabled: bool,
    pub(crate) restore_version: i64,
    pub(crate) always: bool,
}

pub(crate) fn parse_declared(value: impl Fn(&str) -> Option<String>) -> (Declared, Vec<String>) {
    let mut out = Declared { enabled: true, restore_version: 0, always: false };
    let mut why = Vec::new();
    let flag = |key: &str, why: &mut Vec<String>| match value(key).as_deref() {
        None => None,
        Some("true") => Some(true),
        Some("false") => Some(false),
        Some(other) => {
            why.push(format!("kaya: the identity manifest's `{key}` is {other:?}, not \"true\" or \"false\": it is ignored"));
            None
        }
    };
    if let Some(enabled) = flag("restoration", &mut why) {
        out.enabled = enabled;
    }
    if let Some(always) = flag("restore_always", &mut why) {
        out.always = always;
    }
    if let Some(v) = value("restore_version") {
        match v.parse::<i64>() {
            Ok(n) => out.restore_version = n,
            Err(_) => why.push(format!("kaya: the identity manifest's `restore_version` is {v:?}, not a whole number: it is ignored")),
        }
    }
    (out, why)
}

/// The platform's word, handed in before the first touch by the phone hosts
/// (Android's Bundle, iOS's activity); the desktops leave it at NoRule.
static TOKEN: Mutex<Token> = Mutex::new(Token::NoRule);

pub(crate) fn set_platform_token(token: Token) {
    if let Ok(mut t) = TOKEN.lock() {
        *t = token;
    }
}

fn session_dir() -> Option<PathBuf> {
    // The unit tests never touch a real directory; they hand load_with theirs.
    if cfg!(test) {
        return None;
    }
    let id = crate::scene::declared_id()?;
    if crate::prefs::selftest() {
        return Some(crate::prefs::selftest_session_root()?.join("selftest").join(&id).join("session"));
    }
    real_dir(&id)
}

/// A sibling of the session directory for another of kaya's cross-launch
/// notes (the reference ledger, SR13), scratch under the harness like it.
pub(crate) fn store_dir(leaf: &str) -> Option<PathBuf> {
    if cfg!(test) {
        return None;
    }
    let id = crate::scene::declared_id()?;
    if crate::prefs::selftest() {
        return Some(crate::prefs::selftest_session_root()?.join("selftest").join(&id).join(leaf));
    }
    Some(real_dir(&id)?.parent()?.join(leaf))
}

#[cfg(target_os = "macos")]
fn real_dir(id: &str) -> Option<PathBuf> {
    Some(PathBuf::from(std::env::var_os("HOME")?).join("Library/Application Support").join(id).join("kaya-session"))
}

#[cfg(target_os = "ios")]
fn real_dir(_id: &str) -> Option<PathBuf> {
    Some(PathBuf::from(std::env::var_os("HOME")?).join("Library/Application Support/kaya-session"))
}

#[cfg(target_os = "android")]
fn real_dir(_id: &str) -> Option<PathBuf> {
    Some(crate::prefs_android::no_backup_dir()?.join("kaya-session"))
}

#[cfg(target_os = "linux")]
fn real_dir(id: &str) -> Option<PathBuf> {
    if let Some(state) = std::env::var_os("XDG_STATE_HOME") {
        if !state.is_empty() {
            return Some(PathBuf::from(state).join(id).join("kaya-session"));
        }
    }
    Some(PathBuf::from(std::env::var_os("HOME")?).join(".local/state").join(id).join("kaya-session"))
}

#[cfg(target_os = "windows")]
fn real_dir(id: &str) -> Option<PathBuf> {
    Some(PathBuf::from(std::env::var_os("LOCALAPPDATA")?).join(id).join("kaya-session"))
}

/// The Mac's rule (SR6): the user's "close windows when quitting", read as
/// `NSQuitAlwaysKeepsWindows`; true resumes, false or absent is fresh
/// (docs/traps.md, SwiftUI reopens an aux window after a quit).
#[cfg(target_os = "macos")]
fn mac_rule(token: Token) -> Token {
    use objc2_foundation::{NSString, NSUserDefaults};
    let keeps = NSUserDefaults::standardUserDefaults().boolForKey(&NSString::from_str("NSQuitAlwaysKeepsWindows"));
    if keeps { token } else { Token::Absent }
}

#[cfg(not(target_os = "macos"))]
fn mac_rule(token: Token) -> Token {
    token
}

fn say(line: &str) {
    use std::io::Write as _;
    let _ = std::io::stderr().write_all(format!("{line}\n").as_bytes());
}

fn new_session_id() -> String {
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    format!("{:x}-{:x}", std::process::id(), nanos)
}

fn load() -> Store {
    let (declared, why) = parse_declared(crate::scene::declared_value);
    for line in &why {
        say(line);
    }
    let token = TOKEN.lock().map(|t| t.clone()).unwrap_or(Token::NoRule);
    let token = mac_rule(token);
    let token = if declared.always && token == Token::Absent { Token::NoRule } else { token };
    load_with(declared, token, crate::scene::declared_id().unwrap_or_default(), session_dir())
}

fn load_with(declared: Declared, token: Token, app_id: String, dir: Option<PathBuf>) -> Store {
    let session = new_session_id();
    let mut store = Store {
        values: Values::new(),
        facets: Facets::new(),
        restorable: None,
        restored: Restored::Fresh,
        shape: Shape::new(),
        restored_shape: Shape::new(),
        adopted: Default::default(),
        written: Default::default(),
        settled: false,
        session,
        app_id: app_id.clone(),
        restore_version: declared.restore_version,
        writes: declared.enabled,
        first_idle: false,
        dirty: false,
        dir: dir.clone(),
        _lock: None,
    };
    if !declared.enabled {
        return store;
    }
    let Some(dir) = dir else { return store };
    if std::fs::create_dir_all(&dir).is_err() {
        store.writes = false;
        return store;
    }
    match claim(&dir) {
        Ok(lock) => store._lock = Some(lock),
        Err(why) => {
            say(&why);
            store.writes = false;
            return store;
        }
    }
    let text = std::fs::read_to_string(dir.join(FILE)).ok();
    let swept = sweep(text.as_deref(), &app_id, declared.restore_version, &token);
    if let Some(why) = &swept.why {
        say(why);
    }
    store.restored = swept.restored;
    store.values = swept.values;
    store.restorable = Some(swept.facets.clone());
    store.facets = swept.facets;
    store.restored_shape = swept.shape.clone();
    store.shape = swept.shape;
    // THE CRASH-AT-LAUNCH MARK (SR6): written now, cleared at the first idle.
    store.dirty = true;
    flush_locked(&mut store);
    store
}

/// The live-writer branch (SR14, F12): the lock is held for the process's
/// life, so a second live process of the app cannot take it.
pub(crate) fn claim(dir: &Path) -> Result<std::fs::File, String> {
    let lock = std::fs::OpenOptions::new()
        .create(true)
        .truncate(false)
        .write(true)
        .open(dir.join(LOCK))
        .map_err(|e| format!("kaya: the session lock {} could not be opened ({e}): this launch writes no session", dir.join(LOCK).display()))?;
    match lock.try_lock() {
        Ok(()) => Ok(lock),
        Err(_) => Err("kaya: another live process of this app holds the session file: \
                       this launch starts fresh and writes nothing"
            .to_owned()),
    }
}

fn with<R>(f: impl FnOnce(&mut Store) -> R) -> R {
    let mut guard = STORE.lock().unwrap_or_else(|e| e.into_inner());
    if guard.is_none() {
        *guard = Some(load());
    }
    f(guard.as_mut().expect("filled just above"))
}

fn flush_locked(store: &mut Store) {
    if !store.writes || !store.dirty {
        return;
    }
    let Some(dir) = store.dir.clone() else { return };
    let text = encode(&store.app_id, store.restore_version, &store.session, store.first_idle, &store.values, &store.facets, &store.shape);
    if let Err(e) = write_atomic(&dir, &text) {
        say(&format!("kaya: the session file could not be written to {}: {e}", dir.display()));
        return;
    }
    store.dirty = false;
}

fn write_atomic(dir: &Path, text: &str) -> std::io::Result<()> {
    use std::io::Write as _;
    let tmp = dir.join(format!("{FILE}.tmp"));
    let mut f = std::fs::File::create(&tmp)?;
    f.write_all(text.as_bytes())?;
    f.sync_all()?;
    drop(f);
    std::fs::rename(&tmp, dir.join(FILE))
}

pub(crate) fn restored() -> Restored {
    with(|s| s.restored)
}

pub(crate) fn session_id() -> String {
    with(|s| s.session.clone())
}

pub(crate) fn get(scope: Scope, key: &str) -> Option<PrefValue> {
    with(|s| s.values.get(&scope.key()).and_then(|m| m.get(key)).cloned())
}

/// `Err` carries the refusal the bindings raise in their idiom (§4's walls).
pub(crate) fn set(scope: Scope, key: &str, value: PrefValue) -> Result<(), String> {
    if key.is_empty() {
        return Err(empty_key_refusal().to_owned());
    }
    if crate::prefs::is_reserved(key) {
        return Err(reserved_refusal(key));
    }
    with(|s| {
        let prior = s.values.entry(scope.key()).or_default().insert(key.to_owned(), value);
        let size = encode(&s.app_id, s.restore_version, &s.session, true, &s.values, &s.facets, &s.shape).len();
        if size > BOUND {
            let entries = s.values.entry(scope.key()).or_default();
            match prior {
                Some(p) => entries.insert(key.to_owned(), p),
                None => entries.remove(key),
            };
            return Err(bound_refusal(key));
        }
        s.written.insert(scope.key());
        s.dirty = true;
        Ok(())
    })
}

pub(crate) fn remove(scope: Scope, key: &str) -> Result<(), String> {
    if key.is_empty() {
        return Err(empty_key_refusal().to_owned());
    }
    if crate::prefs::is_reserved(key) {
        return Err(reserved_refusal(key));
    }
    with(|s| {
        if s.values.get_mut(&scope.key()).and_then(|m| m.remove(key)).is_some() {
            s.dirty = true;
        }
    });
    Ok(())
}

/// A surface's scope goes with the surface (SR9).
pub(crate) fn discard_scope(scope: Scope) {
    with(|s| discard_locked(s, &scope.key()));
}

fn discard_locked(s: &mut Store, key: &str) {
    let values = s.values.remove(key).is_some();
    let facets = s.facets.remove(key).is_some();
    if values || facets {
        s.dirty = true;
    }
}

/// The shape the last launch left (SR9), for the app to recreate from.
pub(crate) fn restored_shape() -> Shape {
    with(|s| s.restored_shape.clone())
}

/// The scene's shape after each batch (SR9); written at the next idle.
pub(crate) fn report_shape(shape: Shape) {
    with(|s| {
        if s.shape != shape {
            s.shape = shape;
            s.dirty = true;
        }
    });
}

/// `create_window(id).restore(saved)` and `add_document(id).restore(saved)`
/// (SR9, F10): the scope comes back only under the id it was saved with.
/// `Err` is the one line the core prints when it does not.
pub(crate) fn adopt(saved: Scope, now: Scope) -> Result<(), String> {
    with(|s| adopt_locked(s, saved, now))
}

fn adopt_locked(s: &mut Store, saved: Scope, now: Scope) -> Result<(), String> {
    let (what, from, to) = match (saved, now) {
        (Scope::Window(a), Scope::Window(b)) => ("window", a, b),
        (Scope::Document(a), Scope::Document(b)) => ("document", a, b),
        _ => return Err(format!("kaya: restore({}) on a {}: a scope comes back on its own kind of surface", saved.key(), now.key())),
    };
    if from != to {
        return Err(format!(
            "kaya: {what} {from} was restored as {what} {to}: its saved state is not carried, \
             since window and document ids are the app's (docs/restoration-plan.md SR9)"
        ));
    }
    if s.settled {
        return Err(format!(
            "kaya: {what} {from}'s saved scope was discarded at the first idle after the first \
             build, before this restore took it back (docs/restoration-plan.md SR9)"
        ));
    }
    s.adopted.insert(saved.key());
    Ok(())
}

/// Whether a window's saved facets may apply yet (SR9): the primary's at
/// once, an aux window's once the app has taken its scope back.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Gate {
    Go,
    Wait,
    Drop,
}

pub(crate) fn facet_gate(window: u64) -> Gate {
    with(|s| gate_locked(s, window))
}

fn gate_locked(s: &Store, window: u64) -> Gate {
    let key = Scope::Window(window).key();
    if window == 0 || s.adopted.contains(&key) {
        Gate::Go
    } else if s.settled {
        Gate::Drop
    } else {
        Gate::Wait
    }
}

/// SR9's settle: a restored surface scope the app neither took back nor
/// wrote is discarded. The primary window's scope is adopted without a call.
fn settle_locked(s: &mut Store) {
    let primary = Scope::Window(0).key();
    let surface = |k: &String| k.starts_with("window.") || k.starts_with("document.");
    let untaken: std::collections::BTreeSet<String> = s
        .values
        .keys()
        .chain(s.facets.keys())
        .filter(|k| surface(k) && **k != primary && !s.adopted.contains(*k) && !s.written.contains(*k))
        .cloned()
        .collect();
    for key in untaken {
        discard_locked(s, &key);
    }
    s.settled = true;
}

/// The facets the file brought, once: the scene restores them after the
/// transaction that mounts each widget (SR4).
pub(crate) fn take_restorable() -> Facets {
    with(|s| s.restorable.take().unwrap_or_default())
}

/// A backend's report of a facet that settled (SR5): latest wins, written at
/// the next idle. A report that would pass the file's bound is dropped.
pub(crate) fn report_facet(scope: Scope, id: &str, saved: Saved) {
    with(|s| {
        let entries = s.facets.entry(scope.key()).or_default();
        if entries.get(id) == Some(&saved) {
            return;
        }
        let prior = entries.insert(id.to_owned(), saved);
        let size = encode(&s.app_id, s.restore_version, &s.session, true, &s.values, &s.facets, &s.shape).len();
        if size > BOUND {
            let entries = s.facets.entry(scope.key()).or_default();
            match prior {
                Some(p) => entries.insert(id.to_owned(), p),
                None => entries.remove(id),
            };
            return;
        }
        s.dirty = true;
    });
}

/// A saved facet the scene found stale (SR2's kind change, SR4's expired hold).
pub(crate) fn drop_facet(scope: Scope, id: &str) {
    with(|s| {
        if s.facets.get_mut(&scope.key()).and_then(|m| m.remove(id)).is_some() {
            s.dirty = true;
        }
    });
}

static FIRST_BUILD: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

/// A root was mounted: an idle after this is past the first build (SR6).
pub(crate) fn note_first_build() {
    FIRST_BUILD.store(true, std::sync::atomic::Ordering::Release);
}

/// The toolkit's idle (SR5): the first one after the first build clears the
/// crash-at-launch mark, and each writes what changed.
pub(crate) fn idle() {
    let built = FIRST_BUILD.load(std::sync::atomic::Ordering::Acquire);
    with(|s| {
        if built && !s.first_idle {
            s.first_idle = true;
            s.dirty = true;
        }
        if built && !s.settled {
            settle_locked(s);
        }
        flush_locked(s);
    });
}

/// A platform save point (SR5): synchronous, never waits on the app thread.
pub(crate) fn save_point() {
    idle();
}

/// ACT ONE'S RESET: the scratch session goes with the other scratch stores.
pub(crate) fn clear_selftest_scratch() {
    if !crate::prefs::selftest() {
        return;
    }
    if let Some(dir) = session_dir() {
        let _ = std::fs::remove_file(dir.join(FILE));
    }
    if let Some(dir) = store_dir("kaya-references") {
        let _ = std::fs::remove_dir_all(dir);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const APP: &str = "dev.kaya.test";

    fn file(first_idle: bool, session: &str, version: i64) -> String {
        let mut values = Values::new();
        values.entry("app".into()).or_default().insert("draft".into(), PrefValue::Str("half typed".into()));
        values.entry("window.1".into()).or_default().insert("zoom".into(), PrefValue::F64(1.5));
        let text = encode(APP, version, session, first_idle, &values, &Facets::new(), &Shape::new());
        text
    }

    #[test]
    fn an_ordinary_desktop_launch_resumes_every_value() {
        let swept = sweep(Some(&file(true, "s1", 0)), APP, 0, &Token::NoRule);
        assert_eq!(swept.restored, Restored::Resumed);
        assert_eq!(swept.why, None);
        assert_eq!(swept.values["app"]["draft"], PrefValue::Str("half typed".into()));
        assert_eq!(swept.values["window.1"]["zoom"], PrefValue::F64(1.5));
    }

    #[test]
    fn no_file_is_fresh_and_says_nothing() {
        let swept = sweep(None, APP, 0, &Token::NoRule);
        assert_eq!((swept.restored, swept.why), (Restored::Fresh, None));
    }

    // Every discard branch, each made to print (§4, the file's sweep).
    #[test]
    fn each_discard_branch_prints_its_own_sentence() {
        let cases: Vec<(String, &str, i64, Token, Restored, &str)> = vec![
            ("{not json".into(), APP, 0, Token::NoRule, Restored::Fresh, "not readable JSON"),
            ("[1,2]".into(), APP, 0, Token::NoRule, Restored::Fresh, "not a JSON object"),
            (file(true, "s1", 0).replace(FORMAT, "kaya-session-0"), APP, 0, Token::NoRule, Restored::Fresh, "is format \"kaya-session-0\""),
            (file(true, "s1", 0), "dev.kaya.other", 0, Token::NoRule, Restored::Fresh, "belongs to app \"dev.kaya.test\", not \"dev.kaya.other\""),
            (file(false, "s1", 0), APP, 0, Token::NoRule, Restored::Recovered, "ended before its first idle"),
            (file(true, "s1", 0), APP, 0, Token::Session("s9".into()), Restored::Recovered, "names session s9, and the session file holds session s1"),
            (file(true, "s1", 0), APP, 2, Token::NoRule, Restored::Resumed, "restore version moved from 0 to 2"),
        ];
        for (text, app, version, token, want, sentence) in cases {
            let swept = sweep(Some(&text), app, version, &token);
            assert_eq!(swept.restored, want, "{sentence}");
            let why = swept.why.expect(sentence);
            assert!(why.contains(sentence), "{why}");
            assert!(swept.values.is_empty(), "{sentence}: values must be discarded");
            println!("{why}");
        }
    }

    #[test]
    fn the_platform_token_decides_on_a_phone() {
        let swept = sweep(Some(&file(true, "s1", 0)), APP, 0, &Token::Absent);
        assert_eq!((swept.restored, swept.why), (Restored::Fresh, None));
        let swept = sweep(Some(&file(true, "s1", 0)), APP, 0, &Token::Session("s1".into()));
        assert_eq!(swept.restored, Restored::Resumed);
        assert!(!swept.values.is_empty());
    }

    #[test]
    fn the_walls_refuse_by_name() {
        assert_eq!(set(Scope::App, "", PrefValue::Bool(true)), Err(empty_key_refusal().to_owned()));
        assert_eq!(
            set(Scope::App, "kaya.window.0.frame", PrefValue::Bool(true)),
            Err("kaya: session key \"kaya.window.0.frame\" is reserved (the kaya. prefix is kaya's own)".to_owned())
        );
        let big = "x".repeat(BOUND + 1);
        assert_eq!(set(Scope::App, "big", PrefValue::Str(big)), Err(bound_refusal("big")));
        assert_eq!(get(Scope::App, "big"), None, "a refused set leaves nothing behind");
    }

    #[test]
    fn restoration_off_keeps_sets_in_memory_and_writes_no_file() {
        let dir = std::env::temp_dir().join(format!("kaya-session-off-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let off = Declared { enabled: false, restore_version: 0, always: false };
        let mut store = load_with(off, Token::NoRule, APP.into(), Some(dir.clone()));
        store.values.entry("app".into()).or_default().insert("draft".into(), PrefValue::Str("x".into()));
        store.dirty = true;
        store.first_idle = true;
        flush_locked(&mut store);
        assert!(!dir.join(FILE).exists(), "restoration(false) wrote a session file");
        assert_eq!(store.restored, Restored::Fresh);
        let on = Declared { enabled: true, restore_version: 0, always: false };
        let mut store = load_with(on, Token::NoRule, APP.into(), Some(dir.clone()));
        let marked = std::fs::read_to_string(dir.join(FILE)).expect("the launch writes its mark");
        assert!(marked.contains("\"first_idle\": false"), "{marked}");
        store.first_idle = true;
        store.dirty = true;
        flush_locked(&mut store);
        drop(store);
        let text = std::fs::read_to_string(dir.join(FILE)).unwrap();
        assert_eq!(sweep(Some(&text), APP, 0, &Token::NoRule).restored, Restored::Resumed);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_second_live_writer_is_refused_by_name() {
        let dir = std::env::temp_dir().join(format!("kaya-session-claim-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let first = claim(&dir).expect("the first process takes the lock");
        let why = claim(&dir).expect_err("a second live claimant is refused");
        assert!(why.contains("another live process of this app holds the session file"), "{why}");
        println!("{why}");
        drop(first);
        claim(&dir).expect("the lock dies with its holder");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn the_declarations_are_read_from_the_manifest_and_a_bad_one_is_named() {
        let (d, why) = parse_declared(|_| None);
        assert_eq!(d, Declared { enabled: true, restore_version: 0, always: false });
        assert!(why.is_empty());
        let (d, why) = parse_declared(|k| match k {
            "restoration" => Some("false".into()),
            "restore_always" => Some("true".into()),
            "restore_version" => Some("3".into()),
            _ => None,
        });
        assert_eq!(d, Declared { enabled: false, restore_version: 3, always: true });
        assert!(why.is_empty());
        let (_, why) = parse_declared(|k| match k {
            "restoration" => Some("off".into()),
            "restore_version" => Some("two".into()),
            _ => None,
        });
        assert_eq!(why.len(), 2, "{why:?}");
        assert!(why[0].contains("`restoration` is \"off\""));
        assert!(why[1].contains("`restore_version` is \"two\""));
    }

    #[test]
    fn values_round_trip_through_the_file_with_their_types() {
        let mut values = Values::new();
        let app = values.entry("app".into()).or_default();
        app.insert("s".into(), PrefValue::Str("é\"\n".into()));
        app.insert("i".into(), PrefValue::I64(-42));
        app.insert("f".into(), PrefValue::F64(0.25));
        app.insert("b".into(), PrefValue::Bool(false));
        let text = encode(APP, 0, "s1", true, &values, &Facets::new(), &Shape::new());
        assert_eq!(sweep(Some(&text), APP, 0, &Token::NoRule).values, values);
    }

    // SR8: facets are kept per entry across a restore-version move, which
    // discards only the app's values; a fresh launch discards both.
    #[test]
    fn facets_round_trip_and_outlive_a_restore_version_move() {
        let mut facets = Facets::new();
        let w = facets.entry("window.0".into()).or_default();
        w.insert("doc".into(), Saved { kind: "textarea".into(), facet: Facet::Caret { start: 2, stop: 6 } });
        w.insert("rows".into(), Saved { kind: "column".into(), facet: Facet::Row { key: crate::protocol::Value::Str("m10".into()) } });
        w.insert("ids".into(), Saved { kind: "column".into(), facet: Facet::Row { key: crate::protocol::Value::I64(-3) } });
        let text = encode(APP, 0, "s1", true, &Values::new(), &facets, &Shape::new());
        assert_eq!(sweep(Some(&text), APP, 0, &Token::NoRule).facets, facets);
        assert_eq!(sweep(Some(&text), APP, 1, &Token::NoRule).facets, facets);
        assert!(sweep(Some(&text), APP, 0, &Token::Absent).facets.is_empty());
        assert!(sweep(Some(&text), APP, 0, &Token::Session("s9".into())).facets.is_empty());
    }

    fn shaped() -> Shape {
        vec![
            WindowShape { window: 0, documents: vec![7, 9], active: Some(9), section: Some(3), depth: 1 },
            WindowShape { window: 4, documents: vec![], active: None, section: None, depth: 0 },
        ]
    }

    #[test]
    fn the_shape_round_trips_and_is_discarded_with_a_fresh_launch() {
        let text = encode(APP, 0, "s1", true, &Values::new(), &Facets::new(), &shaped());
        assert_eq!(sweep(Some(&text), APP, 0, &Token::NoRule).shape, shaped());
        assert_eq!(sweep(Some(&text), APP, 1, &Token::NoRule).shape, shaped());
        assert!(sweep(Some(&text), APP, 0, &Token::Absent).shape.is_empty());
    }

    fn store_with_scopes() -> Store {
        let mut store = load_with(Declared { enabled: false, restore_version: 0, always: false }, Token::NoRule, APP.into(), None);
        for scope in ["app", "window.0", "window.4", "window.5", "document.7", "document.9"] {
            store.values.entry(scope.into()).or_default().insert("k".into(), PrefValue::I64(1));
        }
        store.facets.entry("window.5".into()).or_default().insert(
            "doc".into(),
            Saved { kind: "textarea".into(), facet: Facet::Caret { start: 1, stop: 1 } },
        );
        store.restored_shape = shaped();
        store
    }

    // SR9, F10: the primary is adopted without a call, a taken scope stays, a
    // moved id loses its state with a line, and the rest go at the settle.
    #[test]
    fn untaken_scopes_go_at_the_settle_and_a_moved_id_is_named() {
        let mut s = store_with_scopes();
        assert_eq!(gate_locked(&s, 0), Gate::Go);
        assert_eq!(gate_locked(&s, 5), Gate::Wait);
        adopt_locked(&mut s, Scope::Window(4), Scope::Window(4)).expect("same id is taken back");
        adopt_locked(&mut s, Scope::Document(9), Scope::Document(9)).expect("same id is taken back");
        let moved = adopt_locked(&mut s, Scope::Window(5), Scope::Window(6)).expect_err("a moved id");
        assert!(moved.contains("window 5 was restored as window 6"), "{moved}");
        println!("{moved}");
        let kind = adopt_locked(&mut s, Scope::Window(5), Scope::Document(5)).expect_err("another kind");
        assert!(kind.contains("on its own kind of surface"), "{kind}");
        println!("{kind}");
        s.written.insert("document.7".into());
        settle_locked(&mut s);
        let left: Vec<&String> = s.values.keys().collect();
        assert_eq!(left, ["app", "document.7", "document.9", "window.0", "window.4"]);
        assert!(s.facets.is_empty(), "window 5's facets went with its scope");
        assert_eq!(gate_locked(&s, 4), Gate::Go);
        assert_eq!(gate_locked(&s, 5), Gate::Drop);
        let late = adopt_locked(&mut s, Scope::Window(5), Scope::Window(5)).expect_err("too late");
        assert!(late.contains("discarded at the first idle after the first build"), "{late}");
        println!("{late}");
    }
}
