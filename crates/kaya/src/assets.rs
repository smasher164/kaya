//! Assets: one root, one resolver, one sentence. The walls on a name,
//! the per-platform root table and the reasoning live in
//! docs/assets-plan.md.

use std::path::PathBuf;

/// The environment override, one variable for the whole root
/// (docs/assets-plan.md A5.5).
pub(crate) const ENV_VAR: &str = "KAYA_ASSET_DIR";

const REPO_DEFAULT: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/../../guests/assets");

/// Where this process's asset root is, and which route said so — the
/// failure sentence names the route, so it is carried rather than
/// recomputed.
pub(crate) struct Root {
    pub(crate) place: Place,
    pub(crate) route: &'static str,
}

pub(crate) enum Place {
    Dir(PathBuf),
    /// The APK's own `assets/`, read through the platform's
    /// AssetManager: an entry inside an APK has no path, so
    /// `std::fs::read` cannot reach it. The entries sit under `kaya/`
    /// inside the APK and the prefix is stripped on the Kotlin side
    /// (docs/assets-plan.md A4).
    #[cfg(target_os = "android")]
    Apk,
}

impl Place {
    fn shown(&self) -> String {
        match self {
            Place::Dir(p) => p.display().to_string(),
            // Asked of the platform on the failure path only.
            #[cfg(target_os = "android")]
            Place::Apk => crate::android::apk_assets_shown(),
        }
    }
}

/// Resolve the asset root for this process, in order: `KAYA_ASSET_DIR`,
/// the Apple main bundle's Resources, the APK's own `assets/`, beside
/// the executable, then the repo-relative compile-time default
/// (docs/assets-plan.md A4).
///
/// Do not reorder. "Beside the executable" must stay below the bundle
/// route, and it is the weakest step: for a DLL-hosted guest — python,
/// go, csharp, java — `current_exe()` names the HOST interpreter's
/// binary, not the app's (docs/deferred.md, "DLL-hosted guest").
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
    // Gated on the JNI glue having been attached: a host-side unit test
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

/// Asked of the platform rather than computed from the executable's
/// path, so a bundle layout this code does not know still resolves.
#[cfg(any(target_os = "macos", target_os = "ios"))]
fn apple_resource_dir() -> Option<PathBuf> {
    use objc2_foundation::NSBundle;
    let bundle = NSBundle::mainBundle();
    let path = bundle.resourcePath()?;
    Some(PathBuf::from(path.to_string()))
}

/// Everything the package carries, as asset names: regular files,
/// `/`-separated, relative to the root, sorted. The directory listing
/// IS the manifest (docs/assets-plan.md A2). A root that cannot be
/// listed answers with an empty list.
pub(crate) fn census() -> Vec<String> {
    match root().place {
        Place::Dir(dir) => {
            let mut out = Vec::new();
            walk(&dir, &dir, &mut out);
            out.sort();
            out
        }
        // AssetManager's `list` answers one directory at a time and
        // says nothing about which entries are files, so the recursion
        // lives on the Kotlin side and this receives flattened leaves.
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
        // Symlinks are not followed: a link inside the root is the same
        // escape wall 1 refuses, with the filesystem doing the walking.
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

/// Wall 1, mechanized. What is wrong with this name, if anything —
/// answered without touching the filesystem, so a malformed name is
/// refused identically whether or not the root exists.
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

/// Why `asset(name)` would fail. The empty string means it would
/// SUCCEED; every other answer is the sentence the guest's own
/// `asset(name)` raises, byte for byte.
///
/// The two-line split is a constraint: line 1 is what
/// tools/scenes/assets.steps freezes and must stay equal on five
/// platforms, line 2 names the resolved place and route, which no
/// cross-platform expectation could hold equal.
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

/// Which branch of `asset_why_not` applies. The prose lives there.
pub(crate) enum Miss {
    Absent,
    Unreadable(String),
}

fn read_raw(place: &Place, name: &str) -> Result<Vec<u8>, Miss> {
    match place {
        // The platform answers with a stream or an IOException, so
        // absent and unreadable are ONE answer on this route.
        #[cfg(target_os = "android")]
        Place::Apk => crate::android::apk_asset_read(name).ok_or(Miss::Absent),
        Place::Dir(dir) => {
            let path = dir.join(name);
            match std::fs::read(&path) {
                Ok(bytes) => Ok(bytes),
                Err(e) if e.kind() == std::io::ErrorKind::NotFound => Err(Miss::Absent),
                // A directory named as an asset answers IsADirectory or
                // PermissionDenied depending on the platform; both are
                // "there and not readable".
                Err(e) => Err(Miss::Unreadable(e.to_string())),
            }
        }
    }
}

/// Read one asset. `Err` carries the whole sentence — the caller does
/// not compose prose. Wall 4: each call reads, no cache, no watch, no
/// reload (docs/assets-plan.md A3).
pub(crate) fn read(name: &str) -> Result<Vec<u8>, String> {
    if name_fault(name).is_some() {
        return Err(asset_why_not(name));
    }
    let root = root();
    match read_raw(&root.place, name) {
        Ok(bytes) if !bytes.is_empty() => Ok(bytes),
        // Empty and missing both route through the diagnostic.
        _ => Err(asset_why_not(name)),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Every test in this module takes this lock: they set, clear and
    /// read the same process-wide `KAYA_ASSET_DIR`, and cargo runs
    /// tests on threads.
    static ENV: std::sync::Mutex<()> = std::sync::Mutex::new(());

    fn serially() -> std::sync::MutexGuard<'static, ()> {
        // A poisoned lock means a sibling test panicked; take the guard
        // rather than cascading the failure.
        ENV.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// Every branch of the diagnostic made to print (invariant 3).
    /// `cargo test -- --nocapture` shows the sentences a reader gets.
    #[test]
    fn why_not_answers_in_facts() {
        let _serial = serially();
        let seen = |name: &str| {
            let s = asset_why_not(name);
            println!("asset_why_not({name:?}) = {s}");
            s
        };

        let s = seen("");
        assert!(s.contains("names nothing"), "{s}");

        let s = seen("fonts\\sora-wght.ttf");
        assert!(s.contains("backslash") && s.contains("fonts\\sora-wght.ttf"), "{s}");

        let s = seen("/etc/passwd");
        assert!(s.contains("absolute path") && s.contains("/etc/passwd"), "{s}");

        let s = seen("C:/Windows/win.ini");
        assert!(s.contains("absolute path"), "{s}");

        let s = seen("../../Cargo.toml");
        assert!(s.contains("climbs out") && s.contains(".."), "{s}");

        let s = seen("fonts/./sora-wght.ttf");
        assert!(s.contains("component"), "{s}");

        let s = seen("fonts/nope.ttf");
        assert!(s.contains("no asset named \"fonts/nope.ttf\""), "{s}");
        assert!(s.contains("fonts/sora-wght.ttf"), "the census must list what IS there: {s}");
        assert!(s.contains(ENV_VAR), "{s}");

        assert_eq!(asset_why_not("fonts/sora-wght.ttf"), "");

        // Empty and unreadable, against a root this test builds: the
        // repo's own root has neither.
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
        assert_eq!(read("fonts/nope.ttf").unwrap_err(), asset_why_not("fonts/nope.ttf"));
    }

    #[test]
    fn read_answers_the_vendored_font() {
        let _serial = serially();
        let bytes = read("fonts/sora-wght.ttf").expect("the repo default root");
        // The byte count is asserted so a truncated read cannot pass.
        assert_eq!(bytes.len(), 111400, "the vendored font's byte count");
    }

    #[test]
    fn census_lists_the_root_and_nothing_else() {
        let _serial = serially();
        let names = census();
        assert!(names.contains(&"fonts/sora-wght.ttf".to_owned()), "{names:?}");
        assert!(names.contains(&"identity.toml".to_owned()), "{names:?}");
        assert!(names.iter().all(|n| !n.starts_with('/')), "{names:?}");
        assert!(names.iter().all(|n| !n.contains("..")), "{names:?}");
        // Sorted: the sentence that prints it is byte-frozen by a scene
        // on five platforms.
        let mut sorted = names.clone();
        sorted.sort();
        assert_eq!(names, sorted);
    }
}
