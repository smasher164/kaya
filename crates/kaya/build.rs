use std::path::PathBuf;
use std::process::Command;

fn main() {
    // Hybrid CRT on msvc targets: static vcruntime (not an OS contract),
    // dynamic UCRT (OS-shipped and OS-serviced). No-op elsewhere.
    static_vcruntime::metabuild();

    // Bake the identity of the sources this core is being compiled from,
    // so a runner can ask a BUILT FILE where it came from rather than
    // trusting that the build it just asked for actually happened
    // (tools/build-id.sh states the failure this answers).
    //
    // The hash comes from that one script, shelled out to rather than
    // reimplemented here: two implementations of "the id" would agree
    // right up until they didn't, and the disagreement would surface as
    // a lane failing with both sides insisting they are current.
    let root = PathBuf::from(std::env::var("CARGO_MANIFEST_DIR").unwrap())
        .join("../..")
        .canonicalize()
        .expect("kaya build.rs: cannot resolve the workspace root");
    let script = root.join("tools/build-id.sh");
    let id = if script.is_file() {
        // build.rs re-runs only when something it DECLARES changes, and
        // its output here is a function of the whole source set — so the
        // source set is what it declares. Miss this and the baked id
        // silently keeps a value the sources have moved away from, which
        // is worse than carrying no id at all.
        for input in ["crates", "Cargo.toml", "Cargo.lock"] {
            println!("cargo::rerun-if-changed={}", root.join(input).display());
        }
        let out = Command::new("bash")
            .arg(&script)
            .arg("core")
            .current_dir(&root)
            .output()
            .expect("kaya build.rs: could not run tools/build-id.sh");
        assert!(
            out.status.success(),
            "kaya build.rs: tools/build-id.sh failed: {}",
            String::from_utf8_lossy(&out.stderr)
        );
        String::from_utf8(out.stdout)
            .expect("kaya build.rs: build id is not utf-8")
            .trim()
            .to_string()
    } else {
        // No tools/ directory: kaya built as a dependency from a
        // published package, where "which tree did this come from" is
        // answered by the package version. Zeros — and the verifier
        // reports NO build id rather than pretending to know one.
        "0000000000000000".to_string()
    };
    // The marker in capi.rs is a fixed-size array, so a width change
    // here is a compile error there rather than a truncated id.
    assert_eq!(
        id.len(),
        16,
        "kaya build.rs: build id must be 16 hex chars, got {id:?}"
    );
    println!("cargo::rustc-env=KAYA_BUILD_ID={id}");

    refuse_a_stale_generator(&root);
}

/// Fail the BUILD when the binding generator has moved since the
/// bindings it produced were written.
///
/// A gate you have to remember is not a guard. `gen-bindings.sh
/// --check` is the authoritative answer and every lane runs it, but a
/// generator edited and never rerun is invisible until someone does:
/// the checked-in bindings still compile, the guest still runs, and the
/// decoder arm just added is simply absent. That shape cost two
/// debugging rounds in one afternoon (docs/traps.md) — an OCaml and
/// then a Haskell picker decoding every result as cancel. Since
/// EVERYTHING downstream builds this crate first, refusing here is the
/// earliest possible answer and the one nobody can skip.
///
/// Two exemptions, both necessary rather than convenient:
///   - no tools/ directory: kaya built as a published dependency, where
///     there is no generator to be out of date with.
///   - KAYA_REGENERATING: gen-bindings.sh sets it, because the
///     generator DEPENDS on this crate — without the exemption a
///     generator edit would deadlock, failing the build of the very
///     tool that fixes it.
fn refuse_a_stale_generator(root: &std::path::Path) {
    if std::env::var_os("KAYA_REGENERATING").is_some() {
        return;
    }
    let src = root.join("tools/kaya-bindgen/src");
    let stamp = root.join("bindings/.generator-id");
    if !src.is_dir() || !stamp.is_file() {
        return;
    }
    println!("cargo::rerun-if-changed={}", src.display());
    println!("cargo::rerun-if-changed={}", stamp.display());

    let mut sources: Vec<_> = std::fs::read_dir(&src)
        .expect("kaya build.rs: could not read the generator's sources")
        .filter_map(|e| e.ok().map(|e| e.path()))
        .filter(|p| p.extension().is_some_and(|e| e == "rs"))
        .collect();
    // Sorted, and by CONTENT: the shell glob that writes the stamp is
    // sorted too, and a touched file with the same bytes is not a
    // different generator (the mtime-versus-hash lesson, docs/traps.md).
    sources.sort();
    let mut joined = Vec::new();
    for path in &sources {
        joined.extend(std::fs::read(path).expect("kaya build.rs: unreadable generator source"));
    }
    let want = short_sha256(&joined);
    let have = std::fs::read_to_string(&stamp).unwrap_or_default().trim().to_string();
    assert!(
        want == have,
        "kaya build.rs: the binding generator has changed since the bindings \
         were generated (generator {want}, bindings say {have}) — run \
         tools/gen-bindings.sh. Every binding downstream is stale until you do."
    );
}

/// The same 16 hex chars `shasum -a 256 | cut -c1-16` gives, so the
/// stamp writer and this reader cannot disagree.
fn short_sha256(bytes: &[u8]) -> String {
    use std::process::Stdio;
    let mut child = Command::new("shasum")
        .args(["-a", "256"])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()
        .expect("kaya build.rs: could not run shasum");
    std::io::Write::write_all(child.stdin.as_mut().unwrap(), bytes)
        .expect("kaya build.rs: could not feed shasum");
    let out = child.wait_with_output().expect("kaya build.rs: shasum failed");
    String::from_utf8_lossy(&out.stdout).chars().take(16).collect()
}
