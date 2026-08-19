//! Assets: one root, one resolver, one sentence (docs/assets-plan.md,
//! ratified 2026-08-18).
//!
//! An asset is a file the guest's own BUILD put where the running
//! program can find it — the vendored typeface, the app's mark, a
//! licence text. `asset(name)` is a core call in all nine guest tiers,
//! and everything about finding the bytes lives here: the root's
//! per-platform route, the walls on a name, and the failure sentence.
//!
//! WHY HERE AND NOT EIGHT TIMES. Before this module the rule and the
//! diagnostic were hand-written once per language
//! (guests/rust/typeface.rs and its seven siblings, each with its own
//! environment variable read, its own repo-relative default and its own
//! prose). Eight copies of one rule is eight chances to disagree, and
//! one of the eight had a language-specific trap severe enough to have
//! earned its own gate: a Go guest reading `os.Getenv` in a c-shared
//! library reads an environment that is empty forever
//! (tools/check-go-env.sh). Moving the read in here does not gate that
//! trap — it makes it unreachable, because no guest reads an
//! environment variable at all.
//!
//! THE WIRE LEARNS NOTHING. No record carries an asset name; a resolved
//! asset hands its bytes to the blob channel the typeface and the icon
//! already ride, and the backend cannot tell them from bytes a guest
//! computed (docs/assets-plan.md A3). This module is one layer BELOW
//! the wire: how bytes reach the guest's process, never what the
//! protocol says about them.
//!
//! FIVE WALLS, from the plan's A3 and mirroring the typeface's own:
//!
//! 1. The name is a relative path under the root. No absolute path, no
//!    `..`, no escape — refused at the call, in the core, in every
//!    language at once.
//! 2. Missing, unreadable or empty is a hard error, in one sentence
//!    naming what the process went and looked at. Empty is refused for
//!    the identity rule's reason: an empty blob sails through a
//!    lowering and is indistinguishable from a default.
//! 3. The bytes are not inspected. Whether a blob is a font or a
//!    picture is a question only the platform's decoder can answer.
//! 4. No caching promise, no watching, no reload. Each call reads.
//! 5. A redeemed handle obeys the blob table's existing lifetime:
//!    valid for exactly one submit, drained whether referenced or not.

use std::path::PathBuf;

/// The environment override, one variable for the whole root rather
/// than one per asset (docs/assets-plan.md A5.5). The typeface and the
/// icon each had a variable of their own, and every new asset cost five
/// more staging lines in five lane scripts; a lane now stages the ROOT
/// and names it once.
///
/// (Their names are deliberately not spelled here.
/// tools/check-app-identity.sh's C3 holds every file that names the
/// icon's variable to also naming the declared path it defaults to —
/// the override needs a default to override — and this module has no
/// business restating the identity declaration. It reads neither
/// variable.)
pub(crate) const ENV_VAR: &str = "KAYA_ASSET_DIR";

/// The repo-relative default, resolved at COMPILE time so a local run
/// and `cargo test` work with no environment at all — the shape
/// harness.rs:94 already uses for the scene corpus, one directory over.
const REPO_DEFAULT: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/../../guests/assets");

/// Where this process's asset root is, and WHICH ROUTE said so. The
/// route is carried rather than recomputed because the failure sentence
/// has to name it: "not under the repo default" and "not in the bundle
/// you were launched from" send a reader to two different places, and a
/// diagnostic that cannot tell them apart must not pretend to
/// (docs/traps.md, "The diagnostic that named a cause nobody had
/// measured").
pub(crate) struct Root {
    pub(crate) place: Place,
    pub(crate) route: &'static str,
}

pub(crate) enum Place {
    /// A directory on a filesystem: the desktops, and any lane that
    /// staged the root by path.
    Dir(PathBuf),
    /// The APK's own `assets/`, read through the platform's
    /// AssetManager.
    ///
    /// ANDROID IS THE ONE PLATFORM WHOSE PACKAGED ASSETS ARE NOT FILES.
    /// An entry inside an APK has no path — it is a range inside a zip
    /// the framework maps — so `std::fs::read` cannot reach it and the
    /// resolver has to ask the platform. This is the packaging reader
    /// docs/assets-plan.md's A4 table calls "APK resources or `assets/`,
    /// read through `AssetManager`", and the arm is reached on every
    /// android run: one leg of the emulator lane deliberately arrives
    /// with no `KAYA_ASSET_DIR`, so it resolves from inside its own
    /// package with nothing staged beside it. A branch no run reaches is
    /// a guess about a state nobody has been in, which is why this one
    /// waited for a leg that takes it.
    ///
    /// THE ENTRIES SIT UNDER `kaya/` INSIDE THE APK, not at `assets/`'s
    /// root, and the name is stripped of that prefix here so a guest
    /// spells one name on five platforms. Two measured reasons: an app's
    /// AssetManager root listing is NOT exclusively the app's (the
    /// framework's own asset directories are visible there on several
    /// API levels), and every AAR on the classpath merges its `assets/`
    /// into the same namespace — so a census taken at the root would
    /// name entries this app never shipped, and the frozen census in
    /// tools/scenes/assets.steps would be a fact about the toolchain
    /// rather than about kaya.
    #[cfg(target_os = "android")]
    Apk,
}

impl Place {
    fn shown(&self) -> String {
        match self {
            Place::Dir(p) => p.display().to_string(),
            // Asked of the platform ON THE FAILURE PATH ONLY, and it is
            // the app's own installed package path — a value this call
            // went and got. When the platform will not answer, the
            // sentence says that instead of naming a path it does not
            // have.
            #[cfg(target_os = "android")]
            Place::Apk => crate::android::apk_assets_shown(),
        }
    }
}

/// Resolve the asset root for this process. Ordered, and every step
/// after the first is a fact about the platform rather than a
/// preference:
///
/// 1. `KAYA_ASSET_DIR` — a lane that staged the root by path, and the
///    escape hatch for a deployment nothing here anticipates.
/// 2. Apple: the main bundle's resource directory. A `.app` is the
///    packaging every Apple platform actually ships, and its Resources
///    is where a bundled asset root lands (tools/ios/run-sim.sh's
///    `make_bundle`).
/// 3. Beside the executable — the desktop packaging layout (the plan's
///    A4 table: "beside the exe" on Windows, `$datadir/kaya/<app>/` on
///    Linux once a `.desktop` install exists).
/// 4. The repo-relative compile-time default, so a repo run needs no
///    environment. This is why macOS and Linux lanes stage nothing.
///
/// WINDOWS TAKES STEP 1, because that lane's guest cannot see the repo:
/// the deploy copies the root into the VM's repo mirror and names it
/// machine-wide (A5.2). ANDROID TAKES STEP 1 OR STEP 2 DEPENDING ON THE
/// LEG, deliberately: the emulator runner pushes the root and names it
/// in the intent for the legs that prove the staged route (A5.1), and
/// omits it for the leg that proves the PACKAGED one, which then
/// resolves from inside its own APK with nothing staged beside it. The
/// same byte-frozen census passes both ways on the same device, which
/// is the strongest statement available that the two routes agree.
///
/// STEP 3 IS DELIBERATELY BELOW STEP 2 AND ABOVE STEP 4, and it is the
/// weakest of the four: for a DLL-HOSTED guest — python, go, csharp,
/// java — `current_exe()` names the HOST interpreter's binary, not the
/// app's, so `<exe dir>/assets` is `python3`'s directory
/// (crates/kaya/src/winui/mod.rs:8494 records the same limit for the
/// font-cache path). It is kept because for a COMPILED guest it is the
/// right answer and the packaging milestone will need it, and it is
/// kept BELOW the bundle route so no Apple app ever takes it.
pub(crate) fn root() -> Root {
    if let Ok(dir) = std::env::var(ENV_VAR) {
        if !dir.trim().is_empty() {
            return Root { place: Place::Dir(PathBuf::from(dir)), route: ENV_VAR };
        }
    }
    #[cfg(any(target_os = "macos", target_os = "ios"))]
    if let Some(res) = apple_resource_dir() {
        let dir = res.join("assets");
        if dir.is_dir() {
            return Root { place: Place::Dir(dir), route: "the main bundle's Resources" };
        }
    }
    // Android's own step 2, in the same position and for the same
    // reason as Apple's: the packaging every app on the platform
    // actually ships is where its assets are, and asking the platform
    // is the only way to reach entries that are not files. Gated on the
    // JNI glue having been attached, because a host-side unit test
    // compiled for android has no JVM to ask.
    #[cfg(target_os = "android")]
    if crate::android::apk_assets_reachable() {
        return Root { place: Place::Apk, route: "the APK's own assets/" };
    }
    if let Ok(exe) = std::env::current_exe() {
        if let Some(dir) = exe.parent().map(|d| d.join("assets")) {
            if dir.is_dir() {
                return Root { place: Place::Dir(dir), route: "beside the executable" };
            }
        }
    }
    Root { place: Place::Dir(PathBuf::from(REPO_DEFAULT)), route: "the repo-relative default" }
}

/// The main bundle's resource directory, asked of the platform rather
/// than computed from the executable's path: `Bundle.main` is what a
/// shipped Apple app resolves resources with, and it answers correctly
/// for a bundle whose layout this code does not know.
#[cfg(any(target_os = "macos", target_os = "ios"))]
fn apple_resource_dir() -> Option<PathBuf> {
    use objc2_foundation::NSBundle;
    let bundle = NSBundle::mainBundle();
    let path = bundle.resourcePath()?;
    Some(PathBuf::from(path.to_string()))
}

/// Everything the package carries, as asset names, sorted. THE
/// DIRECTORY LISTING IS THE MANIFEST (docs/assets-plan.md A2) — there
/// is no index file to fall out of date, so this walk is the only
/// answer to "what is in here" and the miss sentence prints it.
///
/// Regular files only, `/`-separated, relative to the root, and sorted,
/// so the census is one string on five platforms and a scene can freeze
/// it. A root that cannot be listed answers with an empty list; the
/// caller says so rather than printing "carries nothing" as if it had
/// looked.
pub(crate) fn census() -> Vec<String> {
    match root().place {
        Place::Dir(dir) => {
            let mut out = Vec::new();
            walk(&dir, &dir, &mut out);
            out.sort();
            out
        }
        // The same walk, done by the platform: AssetManager's `list`
        // answers one directory at a time and says nothing about which
        // entries are files, so the recursion lives on the Kotlin side
        // and this receives the leaves already flattened.
        #[cfg(target_os = "android")]
        Place::Apk => {
            let mut out = crate::android::apk_asset_list();
            out.sort();
            out
        }
    }
}

fn walk(base: &std::path::Path, dir: &std::path::Path, out: &mut Vec<String>) {
    let Ok(entries) = std::fs::read_dir(dir) else { return };
    for entry in entries.flatten() {
        let path = entry.path();
        // Symlinks are not followed: wall 1 says a name cannot escape
        // the root, and a link inside it would be the same escape with
        // the filesystem doing the walking.
        let Ok(meta) = std::fs::symlink_metadata(&path) else { continue };
        if meta.is_dir() {
            walk(base, &path, out);
        } else if meta.is_file() {
            if let Ok(rel) = path.strip_prefix(base) {
                out.push(rel.components().map(|c| c.as_os_str().to_string_lossy()).collect::<Vec<_>>().join("/"));
            }
        }
    }
}

/// WALL 1, mechanized. What is wrong with this name, if anything —
/// answered without touching the filesystem, so a malformed name is
/// refused identically whether or not the root exists.
///
/// Returns the offending piece so the sentence can print it: a
/// diagnostic that says "bad name" and nothing else sends the reader
/// back to guess which rule they broke.
fn name_fault(name: &str) -> Option<(&'static str, String)> {
    if name.is_empty() {
        return Some(("empty", String::new()));
    }
    if name.contains('\\') {
        return Some(("backslash", name.to_owned()));
    }
    if name.starts_with('/') {
        return Some(("absolute", name.to_owned()));
    }
    // A Windows drive prefix is absolute too, and `starts_with('/')`
    // does not see it.
    if name.len() >= 2 && name.as_bytes()[1] == b':' {
        return Some(("absolute", name.to_owned()));
    }
    for part in name.split('/') {
        if part == ".." {
            return Some(("escape", name.to_owned()));
        }
        if part.is_empty() || part == "." {
            return Some(("component", part.to_owned()));
        }
    }
    None
}

/// Why `asset(name)` would fail — the one diagnostic, in the one place
/// that can be unit-tested and whose branches can be watched printing,
/// as invariant 3 requires of any why-not.
///
/// The empty string means it would SUCCEED. Every other answer is the
/// sentence the guest's own `asset(name)` raises, byte for byte: the
/// bindings do not write prose of their own, they carry this one.
///
/// TWO LINES, AND THE SPLIT IS LOAD-BEARING. Line 1 is the part that is
/// the same on five platforms — the name, the rule it broke, and the
/// census of what the package does carry — and it is what the
/// conformance scene freezes. Line 2 names the resolved place and the
/// route that chose it, which is the part a reader chasing a real
/// failure needs and which no cross-platform expectation could hold
/// equal (a bundle path, an APK, and a repo checkout are three
/// different strings).
///
/// A DIAGNOSTIC MAY ONLY PRINT WHAT IT MEASURED. Every branch below
/// names a value this call went and got: the offending component, the
/// io error the filesystem answered with, the byte count that came
/// back, or the listing of what is actually there. There is no branch
/// that guesses.
pub(crate) fn asset_why_not(name: &str) -> String {
    if let Some((fault, shown)) = name_fault(name) {
        let rule = "an asset name is a relative path under the asset root, \
                    spelled with `/`, like \"fonts/sora-wght.ttf\"";
        match fault {
            "empty" => {
                return format!("kaya: asset(\"\") names nothing — {rule}");
            }
            "backslash" => {
                return format!(
                    "kaya: asset(\"{shown}\") is spelled with a backslash — {rule}, \
                     and one name has to mean one asset on five platforms"
                );
            }
            "absolute" => {
                return format!(
                    "kaya: asset(\"{shown}\") is an absolute path — {rule}; kaya \
                     resolves the root, an app does not"
                );
            }
            "escape" => {
                return format!(
                    "kaya: asset(\"{shown}\") climbs out of the asset root with `..` — \
                     {rule}, and a name that can escape its root is a read of anything"
                );
            }
            _ => {
                return format!(
                    "kaya: asset(\"{name}\") has an empty or `.` path component \
                     ({shown:?}) — {rule}"
                );
            }
        }
    }
    let root = root();
    let carried = census();
    let place = root.place.shown();
    let route = root.route;
    let listing = if carried.is_empty() {
        "nothing this process could list".to_owned()
    } else {
        carried.join(", ")
    };
    let where_line = format!(
        "\nresolved under {place}, chosen by {route}; {ENV_VAR} overrides it"
    );
    match read_raw(&root.place, name) {
        Ok(bytes) if bytes.is_empty() => {
            format!(
                "kaya: the asset named \"{name}\" is EMPTY (0 bytes); an empty blob \
                 sails through every lowering and is indistinguishable from a \
                 default, so it is refused here{where_line}"
            )
        }
        Ok(_) => String::new(),
        Err(Miss::Absent) => {
            format!(
                "kaya: no asset named \"{name}\"; the package carries \
                 {listing}{where_line}"
            )
        }
        Err(Miss::Unreadable(e)) => {
            format!(
                "kaya: the asset named \"{name}\" is there and could not be read \
                 ({e}); the package carries {listing}{where_line}"
            )
        }
    }
}

/// What went wrong reading one entry, kept small on purpose: the prose
/// lives in `asset_why_not` and this says only which of its branches
/// applies.
pub(crate) enum Miss {
    Absent,
    Unreadable(String),
}

fn read_raw(place: &Place, name: &str) -> Result<Vec<u8>, Miss> {
    match place {
        // An entry inside an APK has no path, so there is no
        // `ErrorKind::NotFound` to read: the platform answers with a
        // stream or with an IOException, and the Kotlin side turns the
        // two into "here are the bytes" and "no". Absent and unreadable
        // are therefore ONE answer on this route, and the sentence says
        // "no asset named" rather than inventing a cause it did not
        // measure — the census beside it is what tells the reader
        // whether the name is wrong or the packaging is.
        #[cfg(target_os = "android")]
        Place::Apk => crate::android::apk_asset_read(name).ok_or(Miss::Absent),
        Place::Dir(dir) => {
            let path = dir.join(name);
            match std::fs::read(&path) {
                Ok(bytes) => Ok(bytes),
                Err(e) if e.kind() == std::io::ErrorKind::NotFound => Err(Miss::Absent),
                // A directory named as an asset answers with an
                // IsADirectory or a PermissionDenied depending on the
                // platform; both are "there and not readable", which is
                // what the sentence says.
                Err(e) => Err(Miss::Unreadable(e.to_string())),
            }
        }
    }
}

/// Read one asset. `Err` carries the whole sentence — the caller does
/// not compose prose, so a guest in any language raises the same words.
///
/// WALL 4: each call reads. There is no cache, no watch and no reload,
/// which is what keeps `asset` from promising a live-reload surface the
/// vocabulary does not have.
pub(crate) fn read(name: &str) -> Result<Vec<u8>, String> {
    if name_fault(name).is_some() {
        return Err(asset_why_not(name));
    }
    let root = root();
    match read_raw(&root.place, name) {
        Ok(bytes) if !bytes.is_empty() => Ok(bytes),
        // Empty and missing both route through the diagnostic so the
        // sentence has exactly one author.
        _ => Err(asset_why_not(name)),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// EVERY TEST IN THIS MODULE TAKES THIS LOCK, and the reason is a
    /// hazard rather than tidiness: `why_not_answers_in_facts` sets and
    /// clears `KAYA_ASSET_DIR` to reach the branches the repo's own root
    /// cannot produce, while the tests beside it read the repo root
    /// through the same process-wide variable. cargo runs tests on
    /// threads, so without this the pair is a live race — green today
    /// and flaky in principle, which is the worst kind of green.
    /// Serializing four tests costs nothing measurable.
    static ENV: std::sync::Mutex<()> = std::sync::Mutex::new(());

    fn serially() -> std::sync::MutexGuard<'static, ()> {
        // A poisoned lock means a sibling test panicked; the state it
        // guards is one environment variable that the next line sets
        // anyway, so take the guard rather than cascading the failure.
        ENV.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// Every branch of the diagnostic MADE TO PRINT. Invariant 3's
    /// rule for a why-not is that a branch nobody has seen print is a
    /// guess about a state nobody has reached, so each one is reached
    /// here and its sentence is asserted to name what it measured.
    ///
    /// The prints are deliberate: `cargo test -- --nocapture` shows the
    /// nine sentences a reader will actually be handed.
    #[test]
    fn why_not_answers_in_facts() {
        let _serial = serially();
        let seen = |name: &str| {
            let s = asset_why_not(name);
            println!("asset_why_not({name:?}) = {s}");
            s
        };

        // 1. the empty name
        let s = seen("");
        assert!(s.contains("names nothing"), "{s}");

        // 2. a backslash
        let s = seen("fonts\\sora-wght.ttf");
        assert!(s.contains("backslash") && s.contains("fonts\\sora-wght.ttf"), "{s}");

        // 3. an absolute path, posix spelling
        let s = seen("/etc/passwd");
        assert!(s.contains("absolute path") && s.contains("/etc/passwd"), "{s}");

        // 4. an absolute path, drive spelling
        let s = seen("C:/Windows/win.ini");
        assert!(s.contains("absolute path"), "{s}");

        // 5. climbing out
        let s = seen("../../Cargo.toml");
        assert!(s.contains("climbs out") && s.contains(".."), "{s}");

        // 6. an empty or `.` component
        let s = seen("fonts/./sora-wght.ttf");
        assert!(s.contains("component"), "{s}");

        // 7. absent, with the census — the sentence the plan names
        let s = seen("fonts/nope.ttf");
        assert!(s.contains("no asset named \"fonts/nope.ttf\""), "{s}");
        assert!(s.contains("fonts/sora-wght.ttf"), "the census must list what IS there: {s}");
        assert!(s.contains(ENV_VAR), "{s}");

        // 8. present and readable — the empty answer
        assert_eq!(asset_why_not("fonts/sora-wght.ttf"), "");

        // 9. empty and 10. unreadable, against a root this test builds,
        //    because the repo's own root has neither.
        let tmp = std::env::temp_dir().join(format!("kaya-assets-{}", std::process::id()));
        let _ = std::fs::create_dir_all(tmp.join("family"));
        std::fs::write(tmp.join("family/hollow.bin"), b"").unwrap();
        std::fs::write(tmp.join("family/real.bin"), b"xy").unwrap();
        // SAFETY: single-threaded test process section; the variable is
        // read by this module alone.
        unsafe { std::env::set_var(ENV_VAR, &tmp) };

        let s = seen("family/hollow.bin");
        assert!(s.contains("EMPTY (0 bytes)"), "{s}");
        // A directory named as an asset is "there and not readable".
        let s = seen("family");
        assert!(
            s.contains("could not be read") || s.contains("no asset named"),
            "a directory must not read as a file: {s}"
        );
        assert_eq!(asset_why_not("family/real.bin"), "");
        // The census follows the root, and it is what the miss prints.
        let s = seen("family/gone.bin");
        assert!(s.contains("family/hollow.bin, family/real.bin"), "{s}");

        unsafe { std::env::remove_var(ENV_VAR) };
        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[test]
    fn read_refuses_what_the_walls_refuse() {
        let _serial = serially();
        assert!(read("").is_err());
        assert!(read("../Cargo.toml").is_err());
        assert!(read("/etc/passwd").is_err());
        assert!(read("fonts/nope.ttf").is_err());
        // And the raise carries the diagnostic's own words, byte for
        // byte: one sentence, one author.
        assert_eq!(read("fonts/nope.ttf").unwrap_err(), asset_why_not("fonts/nope.ttf"));
    }

    #[test]
    fn read_answers_the_vendored_font() {
        let _serial = serially();
        let bytes = read("fonts/sora-wght.ttf").expect("the repo default root");
        assert_eq!(bytes.len(), 111400, "the vendored font's byte count");
        // WALL 3: nothing here inspects the bytes. The length is a
        // property of the FILE, which the byte-equality gate already
        // holds equal everywhere; it is asserted so a truncated read
        // cannot pass.
    }

    #[test]
    fn census_lists_the_root_and_nothing_else() {
        let _serial = serially();
        let names = census();
        assert!(names.contains(&"fonts/sora-wght.ttf".to_owned()), "{names:?}");
        assert!(names.contains(&"identity.toml".to_owned()), "{names:?}");
        assert!(names.iter().all(|n| !n.starts_with('/')), "{names:?}");
        assert!(names.iter().all(|n| !n.contains("..")), "{names:?}");
        // Sorted, because the sentence that prints it is byte-frozen by
        // a scene on five platforms.
        let mut sorted = names.clone();
        sorted.sort();
        assert_eq!(names, sorted);
    }
}
