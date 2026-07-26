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
}
