//! The safe save through a picked file (docs/rich-document-plan.md §4.1):
//! the desktops' temporary file and rename, Android's five steps over a
//! [`Document`], and the next launch's classification of what a crash left.
//! tools/check-safe-save.py holds the order of each arm.
// The five steps and the sweep run on Android; elsewhere only the tests do.
#![cfg_attr(not(target_os = "android"), allow(dead_code))]

use std::io::{self, Read, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

static NEXT: AtomicU64 = AtomicU64::new(1);

fn unique() -> String {
    let n = NEXT.fetch_add(1, Ordering::Relaxed);
    let millis = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis())
        .unwrap_or(0);
    format!("{millis}-{}-{n}", std::process::id())
}

fn with_context(e: io::Error, what: String) -> io::Error {
    io::Error::new(e.kind(), format!("{what}: {e}"))
}

#[cfg(unix)]
fn sync_dir(dir: &Path) -> io::Result<()> {
    std::fs::File::open(dir)?.sync_all()
}

/// Windows has no directory handle to flush; MOVEFILE_WRITE_THROUGH is
/// what makes the rename durable there.
#[cfg(not(unix))]
fn sync_dir(_dir: &Path) -> io::Result<()> {
    Ok(())
}

#[cfg(not(windows))]
fn rename_over(from: &Path, to: &Path) -> io::Result<()> {
    std::fs::rename(from, to)
}

#[cfg(windows)]
fn rename_over(from: &Path, to: &Path) -> io::Result<()> {
    use std::os::windows::ffi::OsStrExt;
    use windows::Win32::Storage::FileSystem::{
        MoveFileExW, MOVEFILE_REPLACE_EXISTING, MOVEFILE_WRITE_THROUGH,
    };
    let wide = |p: &Path| -> Vec<u16> { p.as_os_str().encode_wide().chain(Some(0)).collect() };
    let (from_w, to_w) = (wide(from), wide(to));
    unsafe {
        MoveFileExW(
            windows::core::PCWSTR(from_w.as_ptr()),
            windows::core::PCWSTR(to_w.as_ptr()),
            MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH,
        )
    }
    .map_err(|e| io::Error::from_raw_os_error((e.code().0 & 0xFFFF) as i32))
}

/// THE DESKTOPS' ARM (RD14 A): the new bytes in a file beside the old
/// one, fsync, then a rename over the name. A failure at any point leaves
/// the old file and removes the temporary one.
pub(crate) fn replace_path(path: &Path, bytes: &[u8]) -> io::Result<()> {
    let name = path.file_name().ok_or_else(|| {
        io::Error::new(
            io::ErrorKind::InvalidInput,
            format!("kaya: {} names no file to save over", path.display()),
        )
    })?;
    let dir = match path.parent() {
        Some(p) if !p.as_os_str().is_empty() => p.to_path_buf(),
        _ => PathBuf::from("."),
    };
    let temp = dir.join(format!(".{}.kaya-save-{}", name.to_string_lossy(), unique()));
    let written = (|| -> io::Result<()> {
        let mut file = std::fs::OpenOptions::new().write(true).create_new(true).open(&temp)?;
        if let Ok(meta) = std::fs::metadata(path) {
            let _ = file.set_permissions(meta.permissions());
        }
        file.write_all(bytes)?;
        file.sync_all()?;
        drop(file);
        rename_over(&temp, path)?;
        sync_dir(&dir)
    })();
    if written.is_err() {
        let _ = std::fs::remove_file(&temp);
    }
    written.map_err(|e| with_context(e, format!("kaya: saving {}", path.display())))
}

/// Whether the app held a persistable grant on the document before the
/// save (step 1), so step 5 releases only the one kaya took.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Grant {
    Held,
    Taken,
    /// The provider offers no persistable grant (a pasted or dropped
    /// URI): the save still runs, and a leftover backup whose document
    /// stops opening is reported as one.
    Unavailable,
}

impl Grant {
    fn word(self) -> &'static str {
        match self {
            Grant::Held => "held",
            Grant::Taken => "taken",
            Grant::Unavailable => "none",
        }
    }

    fn from_word(word: &str) -> Grant {
        match word {
            "held" => Grant::Held,
            "taken" => Grant::Taken,
            _ => Grant::Unavailable,
        }
    }
}

/// What Android's arm needs from a document, so the unit test can drive
/// the same five steps through a source that fails where it is told to.
pub(crate) trait Document {
    fn name(&self) -> &str;
    fn locator(&self) -> &str;
    fn take_grant(&self) -> Grant;
    fn release_grant(&self);
    fn read_all(&self) -> io::Result<Vec<u8>>;
    /// The `wt` open, truncated: the file and whether it seeks (a pipe
    /// cannot fsync, and its close is its commit).
    fn open_overwrite(&self) -> io::Result<(std::fs::File, bool)>;
}

/// A document at a path: what the core's own tests answer a leftover
/// through off Android, where no save leaves one.
#[cfg_attr(target_os = "android", allow(dead_code))]
pub(crate) struct PathDocument(pub String);

impl Document for PathDocument {
    fn name(&self) -> &str {
        &self.0
    }
    fn locator(&self) -> &str {
        &self.0
    }
    fn take_grant(&self) -> Grant {
        Grant::Held
    }
    fn release_grant(&self) {}
    fn read_all(&self) -> io::Result<Vec<u8>> {
        std::fs::read(&self.0)
    }
    fn open_overwrite(&self) -> io::Result<(std::fs::File, bool)> {
        let file = std::fs::OpenOptions::new().write(true).truncate(true).open(&self.0)?;
        Ok((file, true))
    }
}

/// The test's knife, and the second act's (KAYA_SAFE_SAVE_FAULT).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Fault {
    None,
    /// The process dies once step N has finished (unit test only).
    #[cfg_attr(not(test), allow(dead_code))]
    DieAfter(u8),
    /// Step 3 writes half the new bytes, fsyncs, and the process dies
    /// there; `hold` parks the thread forever so a real exit ends it.
    Tear { hold: bool },
}

/// KAYA_SAFE_SAVE_FAULT, read on every save: `tear` is the one value.
pub(crate) fn fault_from_env() -> io::Result<Fault> {
    match std::env::var("KAYA_SAFE_SAVE_FAULT") {
        Err(_) => Ok(Fault::None),
        Ok(v) if v.is_empty() => Ok(Fault::None),
        Ok(v) if v == "tear" => Ok(Fault::Tear { hold: true }),
        Ok(v) => Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            format!("kaya: KAYA_SAFE_SAVE_FAULT={v:?} names no fault; the one knob is \"tear\""),
        )),
    }
}

fn died(step: u8) -> io::Error {
    io::Error::other(format!("kaya: the test's fault ended the save after step {step}"))
}

pub(crate) fn sha256_hex(bytes: &[u8]) -> String {
    use sha2::Digest;
    sha2::Sha256::digest(bytes).iter().map(|b| format!("{b:02x}")).collect()
}

/// The backup's record (`<store>/<n>/record`): enough for the next launch
/// to classify the document without the process that wrote it.
#[derive(Debug, Clone, PartialEq)]
pub(crate) struct Record {
    pub uri: String,
    pub name: String,
    pub old_len: u64,
    pub old_sha256: String,
    pub new_len: u64,
    pub new_sha256: String,
    pub grant: Grant,
    pub pipe: bool,
}

impl Record {
    fn to_json(&self) -> String {
        serde_json::json!({
            "uri": self.uri,
            "name": self.name,
            "old_len": self.old_len,
            "old_sha256": self.old_sha256,
            "new_len": self.new_len,
            "new_sha256": self.new_sha256,
            "grant": self.grant.word(),
            "pipe": self.pipe,
        })
        .to_string()
    }

    fn from_json(text: &str) -> Result<Record, String> {
        let v: serde_json::Value = serde_json::from_str(text).map_err(|e| e.to_string())?;
        let s = |k: &str| -> Result<String, String> {
            v.get(k).and_then(|x| x.as_str()).map(str::to_owned).ok_or(format!("no string {k:?}"))
        };
        let n = |k: &str| -> Result<u64, String> {
            v.get(k).and_then(|x| x.as_u64()).ok_or(format!("no count {k:?}"))
        };
        Ok(Record {
            uri: s("uri")?,
            name: s("name")?,
            old_len: n("old_len")?,
            old_sha256: s("old_sha256")?,
            new_len: n("new_len")?,
            new_sha256: s("new_sha256")?,
            grant: Grant::from_word(&s("grant")?),
            pipe: v.get("pipe").and_then(|x| x.as_bool()).unwrap_or(false),
        })
    }
}

fn write_synced(path: &Path, bytes: &[u8]) -> io::Result<()> {
    let mut file = std::fs::File::create(path)?;
    file.write_all(bytes)?;
    file.sync_all()
}

/// The record lands whole or not at all: a record's presence is what says
/// the backup beside it is complete.
fn write_record(dir: &Path, record: &Record) -> io::Result<()> {
    let temp = dir.join("record.tmp");
    write_synced(&temp, record.to_json().as_bytes())?;
    std::fs::rename(&temp, dir.join("record"))?;
    sync_dir(dir)
}

fn remove_backup(dir: &Path) -> io::Result<()> {
    std::fs::remove_dir_all(dir)?;
    match dir.parent() {
        Some(store) => sync_dir(store),
        None => Ok(()),
    }
}

fn overwrite(doc: &dyn Document, bytes: &[u8], fault: Fault) -> io::Result<bool> {
    let (mut file, seekable) = doc.open_overwrite()?;
    if let Fault::Tear { hold } = fault {
        file.write_all(&bytes[..bytes.len() / 2])?;
        if seekable {
            file.sync_all()?;
        }
        drop(file);
        if hold {
            eprintln!(
                "kaya: KAYA_SAFE_SAVE_FAULT=tear wrote {} of {} bytes to {} and holds this thread \
                 until the process ends",
                bytes.len() / 2,
                bytes.len(),
                doc.name()
            );
            loop {
                std::thread::park();
            }
        }
        return Err(died(3));
    }
    file.write_all(bytes)?;
    if seekable {
        file.sync_all()?;
    }
    drop(file);
    Ok(!seekable)
}

fn verify(doc: &dyn Document, bytes: &[u8]) -> io::Result<()> {
    let back = doc.read_all()?;
    if back.len() == bytes.len() && sha256_hex(&back) == sha256_hex(bytes) {
        return Ok(());
    }
    Err(io::Error::other(format!(
        "the document read back {} bytes with SHA-256 {} where {} bytes with SHA-256 {} were written",
        back.len(),
        sha256_hex(&back),
        bytes.len(),
        sha256_hex(bytes)
    )))
}

/// ANDROID'S ARM, the five steps of §4.1 inside one blocking call.
pub(crate) fn save_document(
    doc: &dyn Document,
    store: &Path,
    bytes: &[u8],
    fault: Fault,
) -> io::Result<()> {
    let name = doc.name().to_owned();
    // 1. The persistable grant, BEFORE the copy.
    let grant = doc.take_grant();
    let release = |grant: Grant| {
        if grant == Grant::Taken {
            doc.release_grant();
        }
    };
    if fault == Fault::DieAfter(1) {
        return Err(died(1));
    }
    // 2. The backup and its record, fsynced with their directories.
    let backed = (|| -> io::Result<(PathBuf, Vec<u8>, Record)> {
        let old = doc
            .read_all()
            .map_err(|e| with_context(e, format!("kaya: reading {name} before the save")))?;
        std::fs::create_dir_all(store)?;
        let dir = store.join(unique());
        std::fs::create_dir(&dir)?;
        let record = Record {
            uri: doc.locator().to_owned(),
            name: name.clone(),
            old_len: old.len() as u64,
            old_sha256: sha256_hex(&old),
            new_len: bytes.len() as u64,
            new_sha256: sha256_hex(bytes),
            grant,
            pipe: false,
        };
        let stored = (|| {
            write_synced(&dir.join("old"), &old)?;
            write_record(&dir, &record)?;
            sync_dir(store)
        })();
        if let Err(e) = stored {
            let _ = std::fs::remove_dir_all(&dir);
            return Err(with_context(e, format!("kaya: backing {name} up before the save")));
        }
        Ok((dir, old, record))
    })();
    let (dir, old, mut record) = match backed {
        Ok(b) => b,
        Err(e) => {
            release(grant);
            return Err(e);
        }
    };
    if fault == Fault::DieAfter(2) {
        return Err(died(2));
    }
    // 3. The overwrite: `wt`, truncate, write, fsync, close.
    let wrote = overwrite(doc, bytes, fault);
    if let Fault::Tear { .. } = fault {
        return wrote.map(|_| ());
    }
    if let Ok(true) = wrote {
        record.pipe = true;
        let _ = write_record(&dir, &record);
    }
    if fault == Fault::DieAfter(3) {
        return Err(died(3));
    }
    // 4. Read back through a fresh open: length and SHA-256 (RD16 A).
    let checked = wrote
        .map_err(|e| with_context(e, format!("kaya: writing {name}")))
        .and_then(|_| {
            verify(doc, bytes).map_err(|e| with_context(e, format!("kaya: checking {name}")))
        });
    if fault == Fault::DieAfter(4) {
        return Err(died(4));
    }
    match checked {
        Ok(()) => {
            // 5. The backup goes, then the grant kaya took.
            if let Err(e) = remove_backup(&dir) {
                eprintln!(
                    "kaya: {name} holds the saved bytes, but removing its backup at {} failed ({e}); \
                     the next launch finds the new bytes there and deletes it",
                    dir.display()
                );
            }
            release(grant);
            if fault == Fault::DieAfter(5) {
                return Err(died(5));
            }
            Ok(())
        }
        Err(e) => {
            let undone = overwrite(doc, &old, Fault::None).and_then(|_| verify(doc, &old));
            match undone {
                Ok(()) => {
                    let _ = remove_backup(&dir);
                    release(grant);
                    Err(io::Error::new(
                        e.kind(),
                        format!("{e}; kaya wrote the old contents back, and {name} holds them"),
                    ))
                }
                Err(again) => Err(io::Error::new(
                    e.kind(),
                    format!(
                        "{e}; writing the old contents back failed too ({again}), so the backup \
                         stays at {} and the next launch reports it",
                        dir.display()
                    ),
                )),
            }
        }
    }
}

/// One backup the next launch could not prove redundant (RD15 B).
#[derive(Debug, Clone, PartialEq)]
pub(crate) struct Leftover {
    pub dir: PathBuf,
    pub record: Record,
    pub opens: bool,
    pub measured: String,
}

impl Leftover {
    pub(crate) fn backup_path(&self) -> PathBuf {
        self.dir.join("old")
    }
}

/// What the next launch did with one directory under the store, so the
/// test can read every branch.
#[derive(Debug, Clone, PartialEq)]
pub(crate) enum Classified {
    /// No record: the save died inside step 2, before the document was
    /// touched.
    Incomplete,
    OldBytes,
    NewBytes,
    Left(Leftover),
    /// A record nobody can read: kept, and said once.
    Unreadable(String),
    /// A grant an answered leftover kept for its process, released now.
    GrantReleased(String),
}

fn measure(record: &Record, current: &io::Result<Vec<u8>>) -> String {
    let piped = if record.pipe {
        " (the provider answered a pipe, so the write had no fsync)"
    } else {
        ""
    };
    match current {
        Ok(now) => format!(
            "{} holds neither its contents from before the save ({} bytes) nor the ones the save \
             was writing ({} bytes){piped}; it holds {} bytes. kaya cannot tell a write torn by \
             the crash from another app's edit since, so it overwrote nothing",
            record.name,
            record.old_len,
            record.new_len,
            now.len()
        ),
        Err(e) => format!(
            "{} does not open ({e}): it was deleted, or this app's grant on it was revoked{piped}, \
             and this backup of its contents from before the save ({} bytes) is the only copy kaya \
             holds",
            record.name, record.old_len
        ),
    }
}

/// THE NEXT LAUNCH (§4.1): every directory under the store, classified
/// by the document's current length and SHA-256. A redundant backup goes
/// silently, with the grant kaya took; the rest are handed back.
pub(crate) fn sweep(
    store: &Path,
    open: &dyn Fn(&Record) -> Box<dyn Document>,
) -> Vec<(PathBuf, Classified)> {
    let Ok(entries) = std::fs::read_dir(store) else {
        return Vec::new();
    };
    let mut dirs: Vec<PathBuf> = entries.filter_map(Result::ok).map(|e| e.path()).collect();
    dirs.sort();
    let mut out = Vec::new();
    for dir in dirs {
        if !dir.is_dir() || dir.file_name().is_some_and(|n| n == GRANTS) {
            continue;
        }
        let text = match std::fs::read_to_string(dir.join("record")) {
            Ok(t) => t,
            Err(e) if e.kind() == io::ErrorKind::NotFound => {
                let _ = remove_backup(&dir);
                out.push((dir, Classified::Incomplete));
                continue;
            }
            Err(e) => {
                let why = format!(
                    "kaya: the safe-save record at {} would not read ({e}); its backup stays",
                    dir.display()
                );
                eprintln!("{why}");
                out.push((dir, Classified::Unreadable(why)));
                continue;
            }
        };
        let record = match Record::from_json(&text) {
            Ok(r) => r,
            Err(e) => {
                let why = format!(
                    "kaya: the safe-save record at {} would not parse ({e}); its backup stays",
                    dir.display()
                );
                eprintln!("{why}");
                out.push((dir, Classified::Unreadable(why)));
                continue;
            }
        };
        let doc = open(&record);
        let current = doc.read_all();
        let matches = |len: u64, sha: &str| match &current {
            Ok(now) => now.len() as u64 == len && sha256_hex(now) == sha,
            Err(_) => false,
        };
        let verdict = if matches(record.old_len, &record.old_sha256) {
            Some(Classified::OldBytes)
        } else if matches(record.new_len, &record.new_sha256) {
            Some(Classified::NewBytes)
        } else {
            None
        };
        match verdict {
            Some(v) => {
                let _ = remove_backup(&dir);
                if record.grant == Grant::Taken {
                    doc.release_grant();
                }
                out.push((dir, v));
            }
            None => {
                let left = Leftover {
                    dir: dir.clone(),
                    measured: measure(&record, &current),
                    opens: current.is_ok(),
                    record,
                };
                out.push((dir, Classified::Left(left)));
            }
        }
    }
    let waiting: Vec<&Record> = out
        .iter()
        .filter_map(|(_, c)| match c {
            Classified::Left(l) if l.record.grant == Grant::Taken => Some(&l.record),
            _ => None,
        })
        .collect();
    for uri in release_pending_grants(store, open, &waiting) {
        out.push((store.join(GRANTS), Classified::GrantReleased(uri)));
    }
    out
}

/// The app's answer (RD15 B). RESTORE is a safe save of the backup's
/// bytes over the document, so a failure there leaves the backup for the
/// next launch; DISCARD deletes it.
pub(crate) fn answer(
    left: &Leftover,
    restore: bool,
    doc: &dyn Document,
    store: &Path,
) -> io::Result<()> {
    if restore {
        let mut old = Vec::new();
        std::fs::File::open(left.backup_path())
            .and_then(|mut f| f.read_to_end(&mut old))
            .map_err(|e| with_context(e, format!("kaya: reading the backup of {}", left.record.name)))?;
        save_document(doc, store, &old, Fault::None)?;
    }
    // The grant kaya took outlives the answer: the document's handle is a
    // picked handle, redeemable for the life of the process, and in a
    // relaunched process that grant is the only one. The next launch
    // releases it.
    if left.record.grant == Grant::Taken {
        let pending = store.join(GRANTS);
        std::fs::create_dir_all(&pending)
            .and_then(|_| write_synced(&pending.join(unique()), left.record.uri.as_bytes()))
            .and_then(|_| sync_dir(&pending))
            .map_err(|e| with_context(e, format!("kaya: noting the grant on {} for release", left.record.name)))?;
    }
    remove_backup(&left.dir)
        .map_err(|e| with_context(e, format!("kaya: removing the backup of {}", left.record.name)))?;
    let _ = doc;
    Ok(())
}

/// Grants an answered leftover kept for its process, released at the next
/// launch's sweep.
const GRANTS: &str = "grants";

/// The next launch's half of [`answer`]'s grant: released unless a backup
/// still waiting for its answer needs it.
fn release_pending_grants(
    store: &Path,
    open: &dyn Fn(&Record) -> Box<dyn Document>,
    waiting: &[&Record],
) -> Vec<String> {
    let pending = store.join(GRANTS);
    let Ok(entries) = std::fs::read_dir(&pending) else {
        return Vec::new();
    };
    let mut released = Vec::new();
    for entry in entries.filter_map(Result::ok) {
        let Ok(uri) = std::fs::read_to_string(entry.path()) else { continue };
        if !waiting.iter().any(|r| r.uri == uri) {
            let record = Record {
                uri: uri.clone(),
                name: String::new(),
                old_len: 0,
                old_sha256: String::new(),
                new_len: 0,
                new_sha256: String::new(),
                grant: Grant::Taken,
                pipe: false,
            };
            open(&record).release_grant();
            released.push(uri);
        }
        let _ = std::fs::remove_file(entry.path());
    }
    let _ = sync_dir(&pending);
    released
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::{Cell, RefCell};

    /// A document in a real file, with a knife at every call the arm makes.
    struct Fake {
        path: PathBuf,
        held: bool,
        granted: Cell<bool>,
        released: Cell<u32>,
        fail_read: Cell<u32>,
        fail_open: Cell<u32>,
        corrupt_read: Cell<u32>,
        missing: Cell<bool>,
        reads: RefCell<u32>,
    }

    impl Fake {
        fn new(dir: &Path, contents: &[u8]) -> Fake {
            let path = dir.join("doc");
            std::fs::write(&path, contents).unwrap();
            Fake {
                path,
                held: false,
                granted: Cell::new(false),
                released: Cell::new(0),
                fail_read: Cell::new(0),
                fail_open: Cell::new(0),
                corrupt_read: Cell::new(0),
                missing: Cell::new(false),
                reads: RefCell::new(0),
            }
        }
        fn contents(&self) -> Vec<u8> {
            std::fs::read(&self.path).unwrap()
        }
    }

    impl Document for Fake {
        fn name(&self) -> &str {
            "doc"
        }
        fn locator(&self) -> &str {
            "content://fake/doc"
        }
        fn take_grant(&self) -> Grant {
            if self.held || self.granted.get() {
                return Grant::Held;
            }
            self.granted.set(true);
            Grant::Taken
        }
        fn release_grant(&self) {
            self.granted.set(false);
            self.released.set(self.released.get() + 1);
        }
        fn read_all(&self) -> io::Result<Vec<u8>> {
            *self.reads.borrow_mut() += 1;
            if self.missing.get() {
                return Err(io::Error::new(io::ErrorKind::NotFound, "no such document"));
            }
            if self.fail_read.get() > 0 {
                self.fail_read.set(self.fail_read.get() - 1);
                return Err(io::Error::other("the provider refused the read"));
            }
            let mut bytes = std::fs::read(&self.path)?;
            if self.corrupt_read.get() == *self.reads.borrow() {
                if let Some(b) = bytes.first_mut() {
                    *b ^= 0xFF;
                }
            }
            Ok(bytes)
        }
        fn open_overwrite(&self) -> io::Result<(std::fs::File, bool)> {
            if self.fail_open.get() > 0 {
                self.fail_open.set(self.fail_open.get() - 1);
                return Err(io::Error::other("the provider refused wt"));
            }
            let file = std::fs::OpenOptions::new().write(true).truncate(true).open(&self.path)?;
            Ok((file, true))
        }
    }

    fn scratch(tag: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("kaya-safesave-{tag}-{}", unique()));
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn reopen(fake: &Fake) -> impl Fn(&Record) -> Box<dyn Document> + '_ {
        move |_| {
            Box::new(Fake {
                path: fake.path.clone(),
                held: true,
                granted: Cell::new(false),
                released: Cell::new(0),
                fail_read: Cell::new(0),
                fail_open: Cell::new(0),
                corrupt_read: Cell::new(0),
                missing: Cell::new(fake.missing.get()),
                reads: RefCell::new(0),
            })
        }
    }

    const OLD: &[u8] = b"the first draft";
    const NEW: &[u8] = b"the second, longer draft";

    #[test]
    fn a_clean_save_leaves_the_new_bytes_and_nothing_else() {
        let dir = scratch("clean");
        let store = dir.join("store");
        let fake = Fake::new(&dir, OLD);
        save_document(&fake, &store, NEW, Fault::None).unwrap();
        assert_eq!(fake.contents(), NEW);
        assert_eq!(std::fs::read_dir(&store).unwrap().count(), 0);
        assert!(!fake.granted.get());
        assert_eq!(fake.released.get(), 1, "the grant kaya took is released");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_grant_the_app_held_is_not_released() {
        let dir = scratch("held");
        let mut fake = Fake::new(&dir, OLD);
        fake.held = true;
        save_document(&fake, &dir.join("store"), NEW, Fault::None).unwrap();
        assert_eq!(fake.released.get(), 0);
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// A death after each of the five steps, then the next launch.
    #[test]
    fn a_death_after_each_step_is_classified_at_the_next_launch() {
        let expect = [
            (1, None),
            (2, Some("old")),
            (3, Some("new")),
            (4, Some("new")),
            (5, None),
        ];
        for (step, verdict) in expect {
            let dir = scratch(&format!("die{step}"));
            let store = dir.join("store");
            let fake = Fake::new(&dir, OLD);
            let e = save_document(&fake, &store, NEW, Fault::DieAfter(step)).unwrap_err();
            assert!(e.to_string().contains(&format!("after step {step}")), "{e}");
            let found = sweep(&store, &reopen(&fake));
            let got = found.first().map(|(_, c)| match c {
                Classified::OldBytes => "old",
                Classified::NewBytes => "new",
                other => panic!("step {step}: {other:?}"),
            });
            println!("death after step {step}: next launch classified {got:?}");
            assert_eq!(got, verdict, "step {step}");
            assert_eq!(std::fs::read_dir(&store).map(|d| d.count()).unwrap_or(0), 0);
            let _ = std::fs::remove_dir_all(&dir);
        }
    }

    #[test]
    fn a_torn_write_is_handed_to_the_app_and_restore_puts_the_old_bytes_back() {
        let dir = scratch("tear");
        let store = dir.join("store");
        let fake = Fake::new(&dir, OLD);
        save_document(&fake, &store, NEW, Fault::Tear { hold: false }).unwrap_err();
        assert_eq!(fake.contents(), &NEW[..NEW.len() / 2]);
        let found = sweep(&store, &reopen(&fake));
        let Some((_, Classified::Left(left))) = found.first() else { panic!("{found:?}") };
        println!("torn: {}", left.measured);
        assert!(left.opens);
        assert!(left.measured.contains("cannot tell a write torn by the crash from another app's edit"));
        assert!(left.measured.contains("15 bytes") && left.measured.contains("24 bytes"));
        assert_eq!(std::fs::read(left.backup_path()).unwrap(), OLD);
        // Unanswered, it stays for the launch after.
        assert!(matches!(sweep(&store, &reopen(&fake)).first(), Some((_, Classified::Left(_)))));
        answer(left, true, &fake, &store).unwrap();
        assert_eq!(fake.contents(), OLD);
        assert_eq!(std::fs::read_dir(&store).unwrap().count(), 1, "only the grant note is left");
        assert_eq!(fake.released.get(), 0, "the document's handle still opens in this process");
        let next = sweep(&store, &|_| Box::new(PathDocument(fake.path.to_string_lossy().into_owned())));
        assert!(matches!(&next[..], [(_, Classified::GrantReleased(uri))] if uri == "content://fake/doc"), "{next:?}");
        assert_eq!(std::fs::read_dir(store.join(GRANTS)).unwrap().count(), 0);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn discard_deletes_the_backup_and_keeps_the_document() {
        let dir = scratch("discard");
        let store = dir.join("store");
        let fake = Fake::new(&dir, OLD);
        save_document(&fake, &store, NEW, Fault::Tear { hold: false }).unwrap_err();
        let found = sweep(&store, &reopen(&fake));
        let Some((_, Classified::Left(left))) = found.first() else { panic!("{found:?}") };
        answer(left, false, &fake, &store).unwrap();
        assert_eq!(fake.contents(), &NEW[..NEW.len() / 2]);
        assert_eq!(std::fs::read_dir(&store).unwrap().filter(|e| e.as_ref().unwrap().file_name() != GRANTS).count(), 0);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_document_that_no_longer_opens_is_handed_over_with_its_backup() {
        let dir = scratch("gone");
        let store = dir.join("store");
        let fake = Fake::new(&dir, OLD);
        save_document(&fake, &store, NEW, Fault::Tear { hold: false }).unwrap_err();
        fake.missing.set(true);
        let found = sweep(&store, &reopen(&fake));
        let Some((_, Classified::Left(left))) = found.first() else { panic!("{found:?}") };
        println!("gone: {}", left.measured);
        assert!(!left.opens);
        assert!(left.measured.contains("does not open") && left.measured.contains("only copy"));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_pipe_is_named_in_what_kaya_measured() {
        let record = Record {
            uri: "u".into(),
            name: "doc".into(),
            old_len: 1,
            old_sha256: String::new(),
            new_len: 2,
            new_sha256: String::new(),
            grant: Grant::Taken,
            pipe: true,
        };
        let said = measure(&record, &Ok(vec![0; 3]));
        println!("pipe: {said}");
        assert!(said.contains("answered a pipe"));
        assert_eq!(Record::from_json(&record.to_json()).unwrap(), record);
    }

    #[test]
    fn a_backup_without_its_record_is_removed_and_an_unreadable_record_stays() {
        let dir = scratch("partial");
        let store = dir.join("store");
        std::fs::create_dir_all(store.join("a")).unwrap();
        std::fs::write(store.join("a/old"), OLD).unwrap();
        std::fs::create_dir_all(store.join("b")).unwrap();
        std::fs::write(store.join("b/record"), b"{not json").unwrap();
        let fake = Fake::new(&dir, OLD);
        let found = sweep(&store, &reopen(&fake));
        assert_eq!(found[0].1, Classified::Incomplete);
        let Classified::Unreadable(why) = &found[1].1 else { panic!("{found:?}") };
        println!("unreadable: {why}");
        assert!(why.contains("would not parse"));
        assert!(!store.join("a").exists() && store.join("b").exists());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_failed_read_before_the_save_touches_nothing() {
        let dir = scratch("noread");
        let store = dir.join("store");
        let fake = Fake::new(&dir, OLD);
        fake.fail_read.set(1);
        let e = save_document(&fake, &store, NEW, Fault::None).unwrap_err();
        println!("step 2 failed: {e}");
        assert!(e.to_string().contains("before the save"));
        assert_eq!(fake.contents(), OLD);
        assert_eq!(fake.released.get(), 1);
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// Step 3 refused, and step 4 reading back the wrong bytes (the
    /// second read is step 4's; the first is step 2's).
    #[test]
    fn a_failed_write_or_check_is_undone_inside_the_call() {
        for (label, open, corrupt) in [("write", 1, 0), ("check", 0, 2)] {
            let dir = scratch(label);
            let store = dir.join("store");
            let fake = Fake::new(&dir, OLD);
            fake.fail_open.set(open);
            fake.corrupt_read.set(corrupt);
            let e = save_document(&fake, &store, NEW, Fault::None).unwrap_err();
            println!("step {} failed ({label}): {e}", if open > 0 { 3 } else { 4 });
            assert!(e.to_string().contains("wrote the old contents back"), "{e}");
            assert_eq!(fake.contents(), OLD);
            assert_eq!(std::fs::read_dir(&store).unwrap().count(), 0);
            assert_eq!(fake.released.get(), 1);
            let _ = std::fs::remove_dir_all(&dir);
        }
    }

    #[test]
    fn a_failed_undo_keeps_the_backup_for_the_next_launch() {
        let dir = scratch("noundo");
        let store = dir.join("store");
        let fake = Fake::new(&dir, OLD);
        fake.fail_open.set(2);
        let e = save_document(&fake, &store, NEW, Fault::None).unwrap_err();
        println!("undo failed: {e}");
        assert!(e.to_string().contains("the backup stays"), "{e}");
        assert_eq!(std::fs::read_dir(&store).unwrap().count(), 1);
        // The document never changed, so the next launch deletes it.
        let found = sweep(&store, &reopen(&fake));
        assert_eq!(found[0].1, Classified::OldBytes);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn the_desktops_rename_over_the_name_and_leave_no_temporary_file() {
        let dir = scratch("desk");
        let path = dir.join("draft");
        std::fs::write(&path, b"short").unwrap();
        replace_path(&path, b"a much longer draft than before").unwrap();
        assert_eq!(std::fs::read(&path).unwrap(), b"a much longer draft than before");
        replace_path(&path, b"tiny").unwrap();
        assert_eq!(std::fs::read(&path).unwrap(), b"tiny");
        let names: Vec<_> = std::fs::read_dir(&dir)
            .unwrap()
            .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
            .collect();
        assert_eq!(names, ["draft"]);
        let fresh = dir.join("new");
        replace_path(&fresh, b"created").unwrap();
        assert_eq!(std::fs::read(&fresh).unwrap(), b"created");
        let e = replace_path(&dir.join("absent/x"), b"no").unwrap_err();
        println!("desktop failure: {e}");
        assert!(e.to_string().contains("kaya: saving"));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn the_hash_is_sha256() {
        assert_eq!(sha256_hex(b"abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
    }
}
