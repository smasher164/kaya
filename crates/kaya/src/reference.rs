//! Durable file references (docs/restoration-plan.md SR11 to SR13): a picked
//! file mints a bounded text token in kaya's own envelope, redeemed at a later
//! launch for an ordinary picked handle or refused with a sentence.

#[cfg(not(target_os = "android"))]
use std::path::{Path, PathBuf};

pub(crate) const PREFIX: &str = "kaya-ref1";
pub(crate) const BOUND: usize = 8 * 1024;
pub(crate) const CAP: usize = 128;
#[cfg(not(target_os = "android"))]
const LEDGER: &str = "ledger.json";

/// Which of SR12's branches a refusal is.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ReferenceRefusal {
    /// The file the reference names no longer exists.
    Missing,
    /// The platform no longer grants access to it.
    Revoked,
    /// The provider that held it does not answer.
    ProviderGone,
    /// Not a kaya reference for this platform.
    Foreign,
    /// Minting would pass the cap of 128 live references.
    Cap,
}

impl ReferenceRefusal {
    pub fn as_str(self) -> &'static str {
        match self {
            ReferenceRefusal::Missing => "missing",
            ReferenceRefusal::Revoked => "revoked",
            ReferenceRefusal::ProviderGone => "provider",
            ReferenceRefusal::Foreign => "foreign",
            ReferenceRefusal::Cap => "cap",
        }
    }
}

/// A refusal and the sentence that says what kaya measured.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ReferenceError {
    pub refusal: ReferenceRefusal,
    pub message: String,
}

impl std::fmt::Display for ReferenceError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.message)
    }
}

impl std::error::Error for ReferenceError {}

fn refuse(refusal: ReferenceRefusal, message: String) -> ReferenceError {
    ReferenceError { refusal, message }
}

#[cfg(target_os = "macos")]
pub(crate) const TAG: &str = "mac";
#[cfg(target_os = "ios")]
pub(crate) const TAG: &str = "ios";
#[cfg(target_os = "android")]
pub(crate) const TAG: &str = "android";
#[cfg(target_os = "linux")]
pub(crate) const TAG: &str = "gtk";
#[cfg(target_os = "windows")]
pub(crate) const TAG: &str = "win";
#[cfg(not(any(target_os = "macos", target_os = "ios", target_os = "android", target_os = "linux", target_os = "windows")))]
pub(crate) const TAG: &str = "other";

const TAGS: &[&str] = &["mac", "ios", "android", "gtk", "win"];

// ------------------------------------------------------------ the envelope

const B64: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";

pub(crate) fn b64url(bytes: &[u8]) -> String {
    let mut out = String::with_capacity(bytes.len().div_ceil(3) * 4);
    for chunk in bytes.chunks(3) {
        let n = chunk.iter().enumerate().fold(0u32, |n, (i, b)| n | (u32::from(*b) << (16 - 8 * i)));
        for i in 0..=chunk.len() {
            out.push(B64[((n >> (18 - 6 * i)) & 63) as usize] as char);
        }
    }
    out
}

pub(crate) fn un_b64url(text: &str) -> Option<Vec<u8>> {
    let mut out = Vec::with_capacity(text.len() * 3 / 4);
    for chunk in text.as_bytes().chunks(4) {
        if chunk.len() == 1 {
            return None;
        }
        let mut n = 0u32;
        for (i, c) in chunk.iter().enumerate() {
            let v = B64.iter().position(|b| b == c)? as u32;
            n |= v << (18 - 6 * i);
        }
        for i in 0..chunk.len() - 1 {
            out.push((n >> (16 - 8 * i)) as u8);
        }
    }
    Some(out)
}

fn check(body: &str) -> String {
    let mut h: u32 = 0x811c_9dc5;
    for b in body.bytes() {
        h ^= u32::from(b);
        h = h.wrapping_mul(0x0100_0193);
    }
    format!("{h:08x}")
}

pub(crate) fn envelope(tag: &str, payload: &[u8]) -> String {
    let body = format!("{PREFIX}:{tag}:{}", b64url(payload));
    let check = check(&body);
    format!("{body}:{check}")
}

/// The envelope read back for THIS platform, or the foreign refusal naming
/// what was wrong with it (SR11, F4).
pub(crate) fn open_envelope(token: &str, ours: &str) -> Result<Vec<u8>, ReferenceError> {
    let foreign = |why: String| refuse(ReferenceRefusal::Foreign, format!("kaya: this is not a kaya reference for this platform: {why}"));
    if token.len() > BOUND {
        return Err(foreign(format!("it is {} bytes, past the {BOUND}-byte bound", token.len())));
    }
    let Some(rest) = token.strip_prefix(&format!("{PREFIX}:")) else {
        let shown: String = token.chars().take(16).collect();
        return Err(foreign(format!("it does not start with {PREFIX}: (it starts {shown:?})")));
    };
    let parts: Vec<&str> = rest.split(':').collect();
    let [tag, payload, sum] = parts.as_slice() else {
        return Err(foreign(format!("it has {} fields after {PREFIX}:, not three", parts.len())));
    };
    let want = check(&format!("{PREFIX}:{tag}:{payload}"));
    if *sum != want {
        return Err(foreign(format!("its checksum {sum} does not match {want}, so it was changed after it was minted")));
    }
    if *tag != ours {
        let known = if TAGS.contains(tag) { "" } else { ", a tag kaya does not know" };
        return Err(foreign(format!("it was minted on {tag}{known}, and this is {ours}")));
    }
    un_b64url(payload).ok_or_else(|| foreign("its payload is not base64url".to_owned()))
}

// --------------------------------------------------------------- the ledger

/// The durable count (SR13, F3): one entry per distinct target, across
/// launches. Android counts its persisted grants instead.
#[cfg(not(target_os = "android"))]
pub(crate) fn ledger_read(dir: &Path) -> Vec<String> {
    std::fs::read_to_string(dir.join(LEDGER))
        .ok()
        .and_then(|t| serde_json::from_str::<Vec<String>>(&t).ok())
        .unwrap_or_default()
}

#[cfg(not(target_os = "android"))]
fn ledger_write(dir: &Path, entries: &[String]) -> std::io::Result<()> {
    use std::io::Write as _;
    std::fs::create_dir_all(dir)?;
    let tmp = dir.join(format!("{LEDGER}.tmp"));
    let mut f = std::fs::File::create(&tmp)?;
    f.write_all(serde_json::to_string(entries).unwrap_or_default().as_bytes())?;
    f.sync_all()?;
    drop(f);
    std::fs::rename(&tmp, dir.join(LEDGER))
}

pub(crate) fn cap_refusal(held: usize) -> ReferenceError {
    refuse(
        ReferenceRefusal::Cap,
        format!("kaya: this app holds {held} live references, and {CAP} is kaya's cap on every platform: forget one before minting another"),
    )
}

/// Count `target` in, unless it is already counted (a re-mint is free).
#[cfg(not(target_os = "android"))]
pub(crate) fn ledger_admit(dir: &Path, target: &str) -> Result<(), ReferenceError> {
    let mut entries = ledger_read(dir);
    if entries.iter().any(|e| e == target) {
        return Ok(());
    }
    if entries.len() >= CAP {
        return Err(cap_refusal(entries.len()));
    }
    entries.push(target.to_owned());
    // An unwritable ledger cannot hold the count, so the mint is not made.
    ledger_write(dir, &entries).map_err(|e| {
        refuse(ReferenceRefusal::Cap, format!("kaya: the reference ledger in {} could not be written ({e}), so no reference was minted", dir.display()))
    })
}

#[cfg(not(target_os = "android"))]
pub(crate) fn ledger_forget(dir: &Path, target: &str) {
    let mut entries = ledger_read(dir);
    let before = entries.len();
    entries.retain(|e| e != target);
    if entries.len() != before {
        let _ = ledger_write(dir, &entries);
    }
}

#[cfg(not(target_os = "android"))]
fn ledger_dir() -> Option<PathBuf> {
    crate::session::store_dir("kaya-references")
}

// ------------------------------------------------------- the platform arms

/// What a payload names on this platform, as the ledger counts it.
#[cfg(not(any(target_os = "ios", target_os = "android")))]
fn target_of(payload: &[u8]) -> Result<PathBuf, ReferenceError> {
    resolve(payload).map(|(path, _)| path)
}

#[cfg(target_os = "macos")]
fn mint_payload(path: &str) -> Result<Vec<u8>, ReferenceError> {
    use objc2_foundation::{NSString, NSURL, NSURLBookmarkCreationOptions};
    let url = NSURL::fileURLWithPath(&NSString::from_str(path));
    url.bookmarkDataWithOptions_includingResourceValuesForKeys_relativeToURL_error(NSURLBookmarkCreationOptions::empty(), None, None)
        .map(|data| data.to_vec())
        .map_err(|e| {
            refuse(
                ReferenceRefusal::Missing,
                format!("kaya: macOS made no bookmark for {path} ({}), so it cannot be referenced", e.localizedDescription()),
            )
        })
}

/// The path a payload resolves to now, and whether macOS called its bookmark
/// stale (SR11: re-minted on redeem).
#[cfg(target_os = "macos")]
fn resolve(payload: &[u8]) -> Result<(PathBuf, bool), ReferenceError> {
    use objc2::runtime::Bool;
    use objc2_foundation::{NSData, NSURL, NSURLBookmarkResolutionOptions};
    let data = NSData::with_bytes(payload);
    let mut stale = Bool::NO;
    let url = unsafe {
        NSURL::URLByResolvingBookmarkData_options_relativeToURL_bookmarkDataIsStale_error(
            &data,
            NSURLBookmarkResolutionOptions::WithoutUI,
            None,
            &mut stale,
        )
    }
    .map_err(|e| {
        refuse(
            ReferenceRefusal::Missing,
            format!("kaya: the file this reference names no longer exists: macOS resolved no file from its bookmark ({})", e.localizedDescription()),
        )
    })?;
    let path = url.path().map(|p| PathBuf::from(p.to_string())).ok_or_else(|| {
        refuse(ReferenceRefusal::Missing, "kaya: the file this reference names no longer exists: its bookmark resolved to a URL with no path".to_owned())
    })?;
    Ok((path, stale.as_bool()))
}

#[cfg(any(target_os = "linux", target_os = "windows"))]
fn mint_payload(path: &str) -> Result<Vec<u8>, ReferenceError> {
    Ok(path.as_bytes().to_vec())
}

#[cfg(any(target_os = "linux", target_os = "windows"))]
fn resolve(payload: &[u8]) -> Result<(PathBuf, bool), ReferenceError> {
    let path = String::from_utf8(payload.to_vec()).map_err(|_| {
        refuse(ReferenceRefusal::Foreign, "kaya: this is not a kaya reference for this platform: its path is not UTF-8".to_owned())
    })?;
    Ok((PathBuf::from(path), false))
}

/// A path that is there and opens, or the branch that says why not.
#[cfg(not(any(target_os = "ios", target_os = "android")))]
fn reachable(path: &Path) -> Result<(), ReferenceError> {
    match std::fs::metadata(path) {
        Ok(_) => Ok(()),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Err(refuse(
            ReferenceRefusal::Missing,
            format!("kaya: the file this reference names no longer exists ({} is gone)", path.display()),
        )),
        Err(e) if e.kind() == std::io::ErrorKind::PermissionDenied => Err(refuse(
            ReferenceRefusal::Revoked,
            format!("kaya: the grant is gone: {} exists but this process may not read it ({e})", path.display()),
        )),
        Err(e) => Err(refuse(
            ReferenceRefusal::Missing,
            format!("kaya: the file this reference names did not answer ({} read back: {e}); kaya cannot tell a missing file from an unreachable one here", path.display()),
        )),
    }
}

/// SR11: mint a token for a picked file's path.
#[cfg(not(any(target_os = "ios", target_os = "android")))]
pub(crate) fn mint(path: &str) -> Result<String, ReferenceError> {
    let payload = mint_payload(path)?;
    let token = envelope(TAG, &payload);
    if token.len() > BOUND {
        return Err(refuse(
            ReferenceRefusal::Foreign,
            format!("kaya: the platform's reference for {path} is {} bytes in kaya's envelope, past the {BOUND}-byte bound", token.len()),
        ));
    }
    let target = std::fs::canonicalize(path).unwrap_or_else(|_| PathBuf::from(path));
    if let Some(dir) = ledger_dir() {
        ledger_admit(&dir, &target.to_string_lossy())?;
    }
    Ok(token)
}

/// SR11: the path a token names now, and the token to keep (a new one when
/// the platform re-minted a stale bookmark).
#[cfg(not(any(target_os = "ios", target_os = "android")))]
pub(crate) fn redeem(token: &str) -> Result<(String, String), ReferenceError> {
    let payload = open_envelope(token, TAG)?;
    let (path, stale) = resolve(&payload)?;
    reachable(&path)?;
    let path = path.to_string_lossy().into_owned();
    let token = if stale { mint(&path).unwrap_or_else(|_| token.to_owned()) } else { token.to_owned() };
    Ok((path, token))
}

/// SR11, SR13: the token leaves the durable count. A foreign or unresolvable
/// token holds nothing kaya counts.
#[cfg(not(any(target_os = "ios", target_os = "android")))]
pub(crate) fn forget(token: &str) {
    let Ok(payload) = open_envelope(token, TAG) else { return };
    let Ok(path) = target_of(&payload) else { return };
    let target = std::fs::canonicalize(&path).unwrap_or(path);
    if let Some(dir) = ledger_dir() {
        ledger_forget(&dir, &target.to_string_lossy());
    }
}

/// iOS's row (SR11): a plain bookmark made by the backend while the picked
/// URL's scope is held; the ledger counts the URL it names.
#[cfg(target_os = "ios")]
pub(crate) fn mint(locator: &str) -> Result<String, ReferenceError> {
    let payload = crate::swiftui_host::bookmark(locator).map_err(|why| {
        refuse(ReferenceRefusal::Missing, format!("kaya: iOS made no bookmark for {locator} ({why}), so it cannot be referenced"))
    })?;
    let token = envelope(TAG, &payload);
    if token.len() > BOUND {
        return Err(refuse(
            ReferenceRefusal::Foreign,
            format!("kaya: the platform's reference for {locator} is {} bytes in kaya's envelope, past the {BOUND}-byte bound", token.len()),
        ));
    }
    if let Some(dir) = ledger_dir() {
        ledger_admit(&dir, locator)?;
    }
    Ok(token)
}

#[cfg(target_os = "ios")]
fn resolve_ios(payload: &[u8]) -> Result<(String, bool), ReferenceError> {
    use crate::swiftui_host::Resolved;
    match crate::swiftui_host::resolve_bookmark(payload) {
        Resolved::Found { locator, stale } => Ok((locator, stale)),
        Resolved::Gone(why) => Err(refuse(ReferenceRefusal::Missing, format!("kaya: the file this reference names no longer exists: {why}"))),
        Resolved::Unknown(why) => Err(refuse(
            ReferenceRefusal::Missing,
            format!("kaya: the file this reference names did not answer ({why}); kaya cannot tell a missing file from an unreachable one here"),
        )),
    }
}

/// SR11 on iOS: the locator the bookmark resolves to now (registered with
/// the backend), and the token to keep.
#[cfg(target_os = "ios")]
pub(crate) fn redeem(token: &str) -> Result<(String, String), ReferenceError> {
    let payload = open_envelope(token, TAG)?;
    let (locator, stale) = resolve_ios(&payload)?;
    let token = if stale { mint(&locator).unwrap_or_else(|_| token.to_owned()) } else { token.to_owned() };
    Ok((locator, token))
}

#[cfg(target_os = "ios")]
pub(crate) fn forget(token: &str) {
    let Ok(payload) = open_envelope(token, TAG) else { return };
    let Ok((locator, _)) = resolve_ios(&payload) else { return };
    if let Some(dir) = ledger_dir() {
        ledger_forget(&dir, &locator);
    }
}

/// Android's row (SR11, SR13): the platform's persisted grant on the
/// document's URI, which is the payload; the cap is the platform's own count
/// of persisted grants (dev.kaya.KayaReferences).
#[cfg(target_os = "android")]
fn grant_refusal(branch: &str, text: String) -> ReferenceError {
    let refusal = match branch {
        "missing" => ReferenceRefusal::Missing,
        "revoked" => ReferenceRefusal::Revoked,
        "gone" => ReferenceRefusal::ProviderGone,
        _ => ReferenceRefusal::Revoked,
    };
    refuse(refusal, format!("kaya: {text}"))
}

#[cfg(target_os = "android")]
pub(crate) fn mint(uri: &str) -> Result<String, ReferenceError> {
    let (branch, text) = crate::android::reference_grant("mint", uri).map_err(|why| refuse(ReferenceRefusal::Revoked, why))?;
    match branch.as_str() {
        "ok" => {}
        "cap" => return Err(cap_refusal(text.parse().unwrap_or(CAP))),
        _ => return Err(grant_refusal(&branch, text)),
    }
    let token = envelope(TAG, uri.as_bytes());
    if token.len() > BOUND {
        return Err(refuse(
            ReferenceRefusal::Foreign,
            format!("kaya: the platform's reference for {uri} is {} bytes in kaya's envelope, past the {BOUND}-byte bound", token.len()),
        ));
    }
    Ok(token)
}

/// SR11 on Android: the URI, the document's display name, and the token to keep.
#[cfg(target_os = "android")]
pub(crate) fn redeem_named(token: &str) -> Result<(String, String, String), ReferenceError> {
    let payload = open_envelope(token, TAG)?;
    let uri = String::from_utf8(payload).map_err(|_| refuse(ReferenceRefusal::Foreign, "kaya: this reference's payload is not a URI".to_owned()))?;
    let (branch, text) = crate::android::reference_grant("redeem", &uri).map_err(|why| refuse(ReferenceRefusal::Missing, why))?;
    if branch != "ok" {
        return Err(grant_refusal(&branch, text));
    }
    Ok((uri, text, token.to_owned()))
}

#[cfg(target_os = "android")]
pub(crate) fn forget(token: &str) {
    let Ok(payload) = open_envelope(token, TAG) else { return };
    let Ok(uri) = String::from_utf8(payload) else { return };
    let _ = crate::android::reference_grant("forget", &uri);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn base64url_round_trips_every_length() {
        for n in 0..40usize {
            let bytes: Vec<u8> = (0..n).map(|i| (i * 37 + 11) as u8).collect();
            let text = b64url(&bytes);
            assert!(!text.contains('=') && !text.contains('+') && !text.contains('/'));
            assert_eq!(un_b64url(&text), Some(bytes), "length {n}");
        }
        assert_eq!(b64url(b"Man"), "TWFu");
        assert_eq!(un_b64url("T"), None);
        assert_eq!(un_b64url("T*Fu"), None);
    }

    // SR12's foreign branch, every way it is reached, each made to print.
    #[test]
    fn each_foreign_branch_prints_its_own_sentence() {
        let good = envelope("mac", b"/tmp/a.txt");
        assert_eq!(open_envelope(&good, "mac").unwrap(), b"/tmp/a.txt");
        let tampered = good.replacen("kaya-ref1:mac:", "kaya-ref1:mac:A", 1);
        let cases = [
            ("file:///tmp/a.txt".to_owned(), "does not start with kaya-ref1:"),
            ("kaya-ref1:mac:abc".to_owned(), "has 2 fields after kaya-ref1:, not three"),
            (tampered, "does not match"),
            (envelope("gtk", b"/tmp/a.txt"), "it was minted on gtk, and this is mac"),
            (envelope("beos", b"/tmp/a.txt"), "a tag kaya does not know"),
            (format!("{}x", "y".repeat(BOUND)), "past the 8192-byte bound"),
        ];
        for (token, want) in cases {
            let e = open_envelope(&token, "mac").expect_err(want);
            assert_eq!(e.refusal, ReferenceRefusal::Foreign);
            assert!(e.message.contains(want), "{}", e.message);
            println!("{}", e.message);
        }
        let bad_payload = {
            let body = format!("{PREFIX}:mac:T");
            format!("{body}:{}", check(&body))
        };
        let e = open_envelope(&bad_payload, "mac").unwrap_err();
        assert!(e.message.contains("payload is not base64url"), "{}", e.message);
        println!("{}", e.message);
    }

    // SR13: the cap counts the durable set across launches, a re-mint is
    // free, and forget frees a slot.
    #[test]
    fn the_ledger_caps_distinct_targets_across_launches() {
        let dir = std::env::temp_dir().join(format!("kaya-refs-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        for i in 0..CAP {
            ledger_admit(&dir, &format!("/f/{i}")).unwrap();
        }
        // A later launch reads the same file.
        assert_eq!(ledger_read(&dir).len(), CAP);
        ledger_admit(&dir, "/f/7").expect("a re-mint is free");
        let e = ledger_admit(&dir, "/f/new").unwrap_err();
        assert_eq!(e.refusal, ReferenceRefusal::Cap);
        assert!(e.message.contains("holds 128 live references"), "{}", e.message);
        println!("{}", e.message);
        ledger_forget(&dir, "/f/7");
        ledger_admit(&dir, "/f/new").expect("forget frees a slot");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[cfg(not(any(target_os = "ios", target_os = "android")))]
    #[test]
    fn a_path_resolves_and_a_deleted_one_is_missing() {
        let dir = std::env::temp_dir().join(format!("kaya-refs-file-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let file = dir.join("doc.txt");
        std::fs::write(&file, b"x").unwrap();
        let payload = mint_payload(&file.to_string_lossy()).unwrap();
        let (path, _) = resolve(&payload).unwrap();
        assert_eq!(std::fs::canonicalize(&path).unwrap(), std::fs::canonicalize(&file).unwrap());
        reachable(&path).unwrap();
        std::fs::remove_file(&file).unwrap();
        let e = resolve(&payload).and_then(|(p, _)| reachable(&p)).unwrap_err();
        assert_eq!(e.refusal, ReferenceRefusal::Missing);
        println!("{}", e.message);
        let _ = std::fs::remove_dir_all(&dir);
    }
}
