#!/usr/bin/env python3
"""Watched negatives for the GTK typeface arm.

Each one: sha256 the file, apply a substitution and PRINT THE COUNT
(zero substitutions is a FAILED test, not a passed one), rebuild, run
both display legs, restore, and check the sha256 back.

Run from the repo root. Every build/run happens in the kaya-linux
container; nothing here writes outside the repo file it names, and every
file is restored before the next case starts.
"""
import hashlib
import pathlib
import subprocess
import sys

ROOT = pathlib.Path("/Users/akhilindurti/Projects/kaya")
SCRATCH = pathlib.Path(
    "/private/tmp/claude-501/-Users-akhilindurti-Projects-kaya/"
    "24aa5ebf-e439-4206-9ba0-de67540e4b06/scratchpad/styling/gtk-arm (gone)")
GTK = ROOT / "crates/kaya/src/gtk.rs"
GUEST = ROOT / "guests/rust/typeface.rs"


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()[:16]


def run(scenes="/probe/scenes-linux"):
    cmd = [
        "docker", "run", "--rm",
        "-v", f"{ROOT}:/work", "-v", f"{SCRATCH}:/probe", "kaya-linux",
        "bash", "-c",
        "cd /work && export CARGO_TARGET_DIR=/work/target-linux && "
        "cargo build --locked --quiet --features harness --example typeface "
        "2>&1 | grep -E '^error' -A 12 | head -30; "
        f"echo BUILD_RC=${{PIPESTATUS[0]}}; "
        f"/probe/leg.sh typeface /work/target-linux/debug/examples/typeface {scenes} "
        "2>&1 | grep -v dbus-daemon",
    ]
    out = subprocess.run(cmd, capture_output=True, text=True, timeout=1800)
    return out.stdout + out.stderr


def negative(name, path, old, new, scenes="/probe/scenes-linux"):
    before = sha(path)
    text = path.read_text()
    count = text.count(old)
    print(f"\n{'='*72}\nNEGATIVE {name}\n  file {path.relative_to(ROOT)} sha256 {before}")
    if count == 0:
        print("  substitutions: 0 — THE PERTURBATION DID NOT APPLY; this is a "
              "FAILED test, not a passed one")
        return
    path.write_text(text.replace(old, new))
    print(f"  substitutions: {count}")
    try:
        log = run(scenes)
        (SCRATCH / f"neg-{name}.log").write_text(log)
        for line in log.splitlines():
            if ("KAYA_SELFTEST" in line or "KAYA_DIAG" in line
                    or "EXIT=" in line or "BUILD_RC" in line
                    or line.startswith("=== ")):
                print("  | " + line)
    finally:
        path.write_text(text)
        after = sha(path)
        print(f"  restored sha256 {after} {'OK' if after == before else 'MISMATCH'}")


CASES = sys.argv[1:] or ["lowering", "nonsense", "lying-read"]

if "lowering" in CASES:
    # THE LOWERING DELETED. The CSS never reaches the widget; the read
    # must report the platform default AND the diagnosis must name THIS
    # cause rather than the not-installed one.
    negative(
        "lowering", GTK,
        """            load_kaya_css(
                &core.typeface_css,
                "brand typeface",
                &typeface_css_for(&family),
                &core.css_error,
            );""",
        """            let _ = typeface_css_for(&family);""")

if "nonsense" in CASES:
    # THE PROBE'S FALLBACK NEGATIVE (§3): a family nothing has. It
    # renders byte-identically to the unbranded window, so ONLY the
    # resolved-family read can see it.
    negative(
        "nonsense", GUEST,
        '&[(kaya::Platform::Linux, "DejaVu Serif")],',
        '&[(kaya::Platform::Linux, "KayaNoSuchFamily-9x")],')

if "lying-read" in CASES:
    # THE READ WIRED TO THE REQUEST (R1) instead of the resolved family.
    # Run with the nonsense family and a script asserting the REQUEST:
    # the lying read reports a perfect swap for a family this image does
    # not have, which is the false green the whole slice exists to
    # prevent. Two files move together, so this one is done by hand
    # below rather than through negative().
    before_gtk, before_guest = sha(GTK), sha(GUEST)
    gtk_text, guest_text = GTK.read_text(), GUEST.read_text()
    old = """    Some((request.family().map(|f| f.to_string()).unwrap_or_default(), resolved))"""
    new = """    let _ = resolved;
    let echo = request.family().map(|f| f.to_string()).unwrap_or_default();
    Some((echo.clone(), echo))"""
    old_g = '&[(kaya::Platform::Linux, "DejaVu Serif")],'
    new_g = '&[(kaya::Platform::Linux, "KayaNoSuchFamily-9x")],'
    n1, n2 = gtk_text.count(old), guest_text.count(old_g)
    print(f"\n{'='*72}\nNEGATIVE lying-read\n  gtk.rs sha256 {before_gtk} "
          f"substitutions: {n1}\n  guest sha256 {before_guest} substitutions: {n2}")
    if n1 and n2:
        GTK.write_text(gtk_text.replace(old, new))
        GUEST.write_text(guest_text.replace(old_g, new_g))
        scenes = SCRATCH / "scenes-echo"
        scenes.mkdir(exist_ok=True)
        steps = (ROOT / "tools/scenes/typeface.steps").read_text()
        (scenes / "typeface.steps").write_text(
            steps.replace('expect_typeface "Georgia"',
                          'expect_typeface "KayaNoSuchFamily-9x"'))
        try:
            log = run("/probe/scenes-echo")
            (SCRATCH / "neg-lying-read.log").write_text(log)
            for line in log.splitlines():
                if ("KAYA_SELFTEST" in line or "KAYA_DIAG" in line
                        or "EXIT=" in line or "BUILD_RC" in line
                        or line.startswith("=== ")):
                    print("  | " + line)
        finally:
            GTK.write_text(gtk_text)
            GUEST.write_text(guest_text)
            print(f"  restored gtk.rs {sha(GTK)} "
                  f"{'OK' if sha(GTK) == before_gtk else 'MISMATCH'}")
            print(f"  restored guest {sha(GUEST)} "
                  f"{'OK' if sha(GUEST) == before_guest else 'MISMATCH'}")
    else:
        print("  A PERTURBATION DID NOT APPLY — failed test, not a passed one")

if "empty-walk" in CASES:
    # THE THIRD DIAGNOSIS BRANCH, MADE TO PRINT. "No widget was there to
    # be asked" is the one arm the two real failures above cannot reach,
    # and a branch nobody has seen print is a guess about a state nobody
    # has reached (invariant 3). Perturbing the WALK to find nothing is
    # the state itself, not a mock of it.
    negative(
        "empty-walk", GTK,
        "    let mut seen = TypefaceSeen::default();\n",
        "    let mut seen = TypefaceSeen::default();\n    if true { return seen; }\n")
