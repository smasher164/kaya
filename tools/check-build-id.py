#!/usr/bin/env python3
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent / "lib"))
from kaya_gate import ROOT, TARGET, Gate, dev_shell_or_die, scratch_dir

dev_shell_or_die()

# The gate for the stale-artifact guard (tools/build-id.py;
# docs/gates.md). The verify call is one somebody has to write, so a new
# lane starts out unguarded — hence the explicit lane list in clause 2.

import importlib.util
import os
import re
import shutil
import subprocess

import content_fresh

LIB = TARGET / "debug/libkaya.dylib"
if not LIB.is_file():
    print("check-build-id: build libkaya first (cargo build --locked --lib)")
    sys.exit(1)

status = 0


def fail(msg):
    global status
    print(f"check-build-id: {msg}", file=sys.stderr)
    status = 1


def verify(*args):
    """tools/build-id.py --verify ... — quiet; (rc, stderr-text)."""
    run = subprocess.run(
        ["tools/build-id.py", "--verify", *args], cwd=ROOT,
        stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True,
        encoding="utf-8",
        check=False)
    return run.returncode, run.stderr


def doctored_marker(path, dest):
    """Flip one hex digit of the embedded id — the shape a stale
    artifact takes: real, loadable, built from sources no longer here."""
    blob = bytearray(path.read_bytes())
    at = blob.find(b"kaya-build-id:")
    if at == -1:
        return False
    digit = at + len(b"kaya-build-id:")
    blob[digit] = ord("f") if blob[digit] != ord("f") else ord("0")
    dest.write_bytes(blob)
    return True


with scratch_dir("check-build-id-") as tmp:
    # 1a. The real artifact, freshly built, carries the id of this tree.
    rc, err = verify(str(LIB))
    if rc != 0:
        fail("a freshly built libkaya does not carry this tree's id")
        sys.stderr.write(err)

    # 1b. One doctored hex digit in a COPY must be rejected.
    stale = tmp / "stale.dylib"
    if not doctored_marker(LIB, stale):
        fail("could not produce a doctored library for the self-test")
    elif verify(str(stale))[0] == 0:
        fail("self-test failed: a library carrying a DIFFERENT id "
             "verified clean")

    # 1c. A file with no marker at all must be rejected too, not skipped.
    (tmp / "empty.bin").write_text("not a library\n", encoding="utf-8")
    if verify(str(tmp / "empty.bin"))[0] == 0:
        fail("self-test failed: a file with no build id verified clean")

    # 1d. A missing file is a failed build, not a pass by absence.
    if verify(str(tmp / "does-not-exist"))[0] == 0:
        fail("self-test failed: a missing artifact verified clean")

    # 2. Coverage. The list is explicit: a runner that silently stopped
    # verifying looks exactly like one that never needed to. Read
    # LINE-wise, since shell and python spell the call differently and a
    # substring pattern went quiet at that crossing once.
    def lane_verifies(text):
        for line in text.splitlines():
            s = line.strip()
            if s.startswith("#"):
                continue
            if "build-id" in s and "--verify" in s:
                return True
        return False

    for lane_rel in ["tools/validate-mac.py", "tools/linux/run-suites.sh",
                     "tools/ios/run-sim.py", "tools/android/run-emulator.py",
                     "tools/deploy-win.py", "tools/swiftui/build-dylib.sh",
                     "tools/linux/shot-gtk.py"]:
        if not lane_verifies((ROOT / lane_rel).read_text(encoding="utf-8")):
            fail(f"{lane_rel} builds the core but never verifies what it "
                 f"runs (build-id.py --verify)")

    # The clause's own negative, watched because this parse has drifted
    # once: the windows runner with its verify flag doctored away must
    # fail the clause.
    g = Gate("check-build-id")
    win_text = (ROOT / "tools/deploy-win.py").read_text(encoding="utf-8")
    unverified = g.doctor("2's verify call deleted from the windows runner",
                          win_text, r'"--verify"', '"--frobnicate"', want=1)
    if not lane_verifies(win_text):
        fail("self-test failed: the windows runner's real verify call is "
             "invisible to the coverage clause")
    if lane_verifies(unverified):
        fail("self-test failed: a runner with no verify call passed the "
             "coverage clause")

    # 2b. The SwiftUI interpreter is a SECOND artifact with its own id;
    # both places that compile one must bake it in and check it. swiftc
    # failing leaves the previous dylib where a cargo failure leaves the
    # previous libkaya. Line-wise, like clause 2.
    def verifies_swiftui(text):
        for line in text.splitlines():
            s = line.strip()
            if s.startswith("#"):
                continue
            if "--component" in s and "swiftui" in s:
                return True
        return False

    for site in ["tools/swiftui/build-dylib.sh", "tools/ios/run-sim.py"]:
        text = (ROOT / site).read_text(encoding="utf-8")
        if not verifies_swiftui(text):
            fail(f"{site} compiles the SwiftUI interpreter but never "
                 f"verifies it (--component swiftui)")
        if "kaya-build-id:" not in text:
            fail(f"{site} does not bake a build id into the interpreter "
                 f"it compiles")
    # The mac lane VERIFIES the interpreter without compiling it (the
    # matrix-handshake skip path builds via build-dylib.sh and must
    # still ask the dylib for this tree's id) — verify only, no bake.
    mac_lane_text = (ROOT / "tools/validate-mac.py").read_text(
        encoding="utf-8")
    if not verifies_swiftui(mac_lane_text):
        fail("tools/validate-mac.py runs the SwiftUI interpreter but "
             "never verifies it on the gates-skip path (--component "
             "swiftui)")
    unverified_mac = g.doctor(
        "2b's swiftui verify deleted from the mac lane", mac_lane_text,
        r'"--component", "swiftui",', '"--frobnicate", "swiftui",',
        want=1)
    if verifies_swiftui(unverified_mac):
        fail("self-test failed: a mac lane with no swiftui verify "
             "passed the clause")

    # 2b-android. The Compose interpreter, same contract: the lane must
    # WRITE the marker before gradle and ASK the apk afterwards. Both
    # halves are watched red below.
    def verifies_compose(text):
        for line in text.splitlines():
            s = line.strip()
            if s.startswith("#"):
                continue
            if "--component" in s and "compose" in s:
                return True
        return False

    emulator = (ROOT / "tools/android/run-emulator.py").read_text(
        encoding="utf-8")
    if "kaya_write_compose_marker" not in emulator:
        fail("run-emulator.py does not bake a build id into the Compose "
             "interpreter")
    if not verifies_compose(emulator):
        fail("run-emulator.py never verifies the apk it installs "
             "(--component compose)")
    unmarked = g.doctor("2b-android's marker writes deleted", emulator,
                        r"kaya_write_compose_marker", "kaya_write_nothing",
                        want=5)
    if "kaya_write_compose_marker" in unmarked:
        fail("self-test failed: the marker-write removal left a call "
             "behind")
    # Two sites: the build's own verify and the quiet tail's reuse
    # (run-emulator.py's reuse_built).
    uncomposed = g.doctor("2b-android's compose verify deleted", emulator,
                          r'"--component", "compose"',
                          '"--frobnicate", "compose"', want=2)
    if not verifies_compose(emulator):
        fail("self-test failed: the runner's real compose verify is "
             "invisible to the clause")
    if verifies_compose(uncomposed):
        fail("self-test failed: a runner with no compose verify passed "
             "the clause")

    # 2c. The built interpreter itself, when one is present.
    dylib = ROOT / "target/swiftui/libkaya_swiftui.dylib"
    if dylib.is_file():
        rc, err = verify("--component", "swiftui", str(dylib))
        if rc != 0:
            fail("the built SwiftUI interpreter does not carry this "
                 "tree's id")
            sys.stderr.write(err)
        if not doctored_marker(dylib, stale):
            fail("check-build-id: no marker in the interpreter to doctor")
        elif verify("--component", "swiftui", str(stale))[0] == 0:
            fail("self-test failed: an interpreter carrying a DIFFERENT id "
                 "verified clean")

    # 3. The core id reads every file rustc compiled into libkaya. The two
    # build.rs-only inputs feed its generator refusal, never the bytes.
    BUILD_RS_ONLY = {"bindings/.generator-id", "tools/kaya-bindgen/src"}
    spec = importlib.util.spec_from_file_location("kaya_build_id", ROOT / "tools/build-id.py")
    build_id_mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(build_id_mod)
    core_roots = build_id_mod.COMPONENTS["core"]

    def uncovered(dep_text):
        out = []
        for raw in content_fresh.dep_files(dep_text):
            rel = os.path.relpath(os.path.normpath(raw), ROOT)
            if rel in BUILD_RS_ONLY or any(rel == r or rel.startswith(r + "/") for r in core_roots):
                continue
            out.append(rel)
        return out

    dep_text = (TARGET / "debug/libkaya.d").read_text(encoding="utf-8")
    for rel in uncovered(dep_text):
        fail(f"libkaya was compiled from {rel}, which the core id does not read: add it to "
             f"tools/build-id.py's COMPONENTS['core'] and crates/kaya/build.rs's rerun list")
    planted = dep_text.replace(": ", f": {ROOT}/guests/assets/l10n/tasks.en.ftl ", 1)
    if uncovered(planted) != ["guests/assets/l10n/tasks.en.ftl"]:
        fail("self-test failed: an include_bytes! of a file outside the core id passed clause 3")
    def rerun_list_is_core(text):
        m = re.search(r"for input in \[([^\]]*)\]", text)
        return bool(m) and re.findall(r'"([^"]+)"', m.group(1)) == core_roots

    build_rs = (ROOT / "crates/kaya/build.rs").read_text(encoding="utf-8")
    if rerun_list_is_core(g.doctor("3's font cut from build.rs's rerun list", build_rs,
                                   r', "guests/assets/fonts/sora-wght.ttf"', "", want=1)):
        fail("self-test failed: a build.rs rerun list missing a core input passed clause 3")
    if not rerun_list_is_core(build_rs):
        fail("crates/kaya/build.rs's rerun-if-changed list is not tools/build-id.py's "
             "COMPONENTS['core']: the baked id then misses an edit to what the list leaves out")

    # 4. Every runner's cargo build of kaya, the mac lane's make and MSBuild
    # guests, the nested workspaces and the hand probes go through tools/lib/content_fresh.py
    # (docs/traps.md, cargo keeps an artifact a restore with an old mtime made stale).
    FRESH_SITES = {"tools/validate-mac.py": 1, "tools/run-leg.py": 2,
                   "tools/linux/run-suites.sh": 1, "tools/ios/run-sim.py": 1,
                   "tools/android/run-emulator.py": 1, "tools/deploy-win.py": 2,
                   "tools/swiftui/build-dylib.sh": 1, "tools/gates.py": 1,
                   "tools/lib/lanes/mac.py": 2,
                   "tools/win/clipprobe/build.sh": 1, "tools/win/dialogprobe/build.sh": 1,
                   "tools/win/sheetprobe/build.sh": 1, "tools/win/undoprobe/build.sh": 1,
                   "tools/win/undoarmprobe/run.sh": 1, "tools/win/keyprobe/run.py": 1,
                   "tools/linux/shot-gtk.py": 1, "tools/ios/gpuprobe/build.py": 1,
                   "tools/bench-tables.sh": 1}

    def fresh_calls(text):
        return sum(1 for line in text.splitlines() if not line.strip().startswith("#")
                   and re.search(r"content_fresh\.(cargo|by_content|nested)\("
                                 r"|lib/content_fresh\.py", line))

    for rel, want in FRESH_SITES.items():
        got = fresh_calls((ROOT / rel).read_text(encoding="utf-8"))
        if got != want:
            fail(f"{rel} routes {got} build(s) through tools/lib/content_fresh.py, "
                 f"wanted {want}: a bare cargo call keeps an example or a library cargo judged "
                 f"by mtime alone")
    unrouted = g.doctor("4's content_fresh call deleted from the windows runner", win_text,
                        r"content_fresh\.cargo\(", "run_cargo(", want=1)
    if fresh_calls(unrouted) != FRESH_SITES["tools/deploy-win.py"] - 1:
        fail("self-test failed: a runner with its content_fresh call deleted passed clause 4")

    # 5. The mechanism itself, on a scratch crate: an example and a library
    # restored with an old mtime come back rebuilt, and with the aging cut
    # the example is refused.
    probe = tmp / "probe"
    (probe / "src").mkdir(parents=True)
    (probe / "examples").mkdir()
    (probe / "Cargo.toml").write_text(
        '[package]\nname = "kaya"\nversion = "0.0.0"\nedition = "2021"\n\n'
        '[[example]]\nname = "ex"\npath = "examples/ex.rs"\n', encoding="utf-8")
    (probe / "build.rs").write_text(
        'fn main() {\n    println!("cargo::rerun-if-changed=src");\n'
        '    let s = std::fs::read_to_string("src/lib.rs").unwrap();\n'
        '    println!("cargo::rustc-env=KAYA_BUILD_ID={:016x}", s.len());\n}\n', encoding="utf-8")
    lib, ex = probe / "src/lib.rs", probe / "examples/ex.rs"
    lib.write_text('pub fn id() -> &\'static str { env!("KAYA_BUILD_ID") }\n', encoding="utf-8")
    ex.write_text('fn main() { println!("v1 {}", kaya::id()); }\n', encoding="utf-8")
    profile = probe / "target/debug"
    (probe / "Cargo.lock").write_text(
        'version = 4\n\n[[package]]\nname = "kaya"\nversion = "0.0.0"\n', encoding="utf-8")
    cmd = ["cargo", "build", "--locked", "--quiet", "--offline",
           "--target-dir", str(probe / "target"), "--example", "ex"]

    def cargo():
        return subprocess.run(cmd, cwd=probe, check=False).returncode

    def said():
        return subprocess.run([str(profile / "examples/ex")], stdout=subprocess.PIPE, text=True,
                              check=False).stdout.strip()

    def lib_id():
        return f"{len(lib.read_text(encoding='utf-8')):016x}"

    def fresh():
        return content_fresh.cargo(cargo, profile, ["ex"], core_id=lib_id(),
                                   who="check-build-id probe")

    def restored(path, old, new):
        saved = tmp / f"{path.name}.saved"
        shutil.copy2(path, saved)
        path.write_text(path.read_text(encoding="utf-8").replace(old, new), encoding="utf-8")
        rc = fresh()
        shutil.copy2(saved, path)
        return rc

    if fresh() != 0:
        fail("the probe crate did not build")
    elif restored(ex, "v1", "v2") != 0 or said() != f"v2 {lib_id()}":
        fail("the probe's perturbed example did not build")
    elif cargo() != 0 or said() != f"v2 {lib_id()}":
        fail("self-test broken: cargo rebuilt the example restored with an old mtime by itself, "
             "so the probe no longer shows the trap")
    elif fresh() != 0 \
            or said() != f"v1 {lib_id()}":
        fail(f"content_fresh kept an example restored with an old mtime: it prints {said()!r}")
    elif restored(lib, "id()", "id( )") != 0 or cargo() != 0 or said() == f"v1 {lib_id()}":
        fail("self-test broken: the probe's library restored with an old mtime was not stale")
    elif fresh() != 0 \
            or said() != f"v1 {lib_id()}":
        fail(f"content_fresh kept a core whose build script baked another id: it prints {said()!r}")
    else:
        restored(ex, "v1", "v3")
        real_age = content_fresh._age
        content_fresh._age = lambda path: None
        print("check-build-id: self-test 5 with content_fresh's aging cut")
        try:
            if fresh() == 0:
                fail("self-test failed: with the aging cut, content_fresh passed an example "
                     "built from other bytes")
        finally:
            content_fresh._age = real_age

    # 5b. by_content on a make probe: a prerequisite restored with an old
    # mtime gets a full build.
    mk = tmp / "make-probe"
    mk.mkdir()
    (mk / "Makefile").write_text("out.txt: in.txt\n\tcp in.txt out.txt\n", encoding="utf-8")
    src, out = mk / "in.txt", mk / "out.txt"
    src.write_text("A\n", encoding="utf-8")

    def make(full):
        return subprocess.run(["make", "-s", "-C", str(mk), *(["-B"] if full else [])],
                              check=False).returncode

    def made():
        return out.read_text(encoding="utf-8") if out.is_file() else None

    def by_content():
        return content_fresh.by_content(make, [str(mk)], [out], tmp / "make-probe.json",
                                        skip={"out.txt"}, who="check-build-id make probe")

    shutil.copy2(src, tmp / "in.saved")
    if by_content() != 0 or made() != "A\n":
        fail("the make probe did not build")
    else:
        os.utime(src, (src.stat().st_atime, src.stat().st_mtime - 60))
        shutil.copy2(src, tmp / "in.saved")
        src.write_text("B\n", encoding="utf-8")
        by_content()
        shutil.copy2(tmp / "in.saved", src)
        if make(False) != 0 or made() != "B\n":
            fail("self-test broken: make rebuilt a prerequisite restored with an old mtime by "
                 "itself, so the probe no longer shows the trap")
        elif by_content() != 0 or made() != "A\n":
            fail(f"content_fresh.by_content kept a make output built from other bytes: {made()!r}")

    # 5c. nested on a crate in a workspace of its own (winvcam's, the probes'): a
    # source restored with an old mtime gets its package cleaned and built again.
    nest = tmp / "nested-probe"
    (nest / "src").mkdir(parents=True)
    (nest / "Cargo.toml").write_text(
        '[package]\nname = "nestprobe"\nversion = "0.0.0"\nedition = "2021"\n\n[workspace]\n',
        encoding="utf-8")
    (nest / "Cargo.lock").write_text(
        'version = 4\n\n[[package]]\nname = "nestprobe"\nversion = "0.0.0"\n', encoding="utf-8")
    main_rs = nest / "src/main.rs"
    main_rs.write_text('fn main() { println!("n1"); }\n', encoding="utf-8")
    nest_cmd = ["cargo", "build", "--locked", "--quiet", "--offline",
                "--target-dir", str(nest / "target")]
    nest_bin = nest / "target/debug/nestprobe"

    def nest_said():
        return subprocess.run([str(nest_bin)], stdout=subprocess.PIPE, text=True,
                              check=False).stdout.strip()

    def nested():
        return content_fresh.nested(nest_cmd, nest, [nest_bin], "check-build-id nested probe")

    if content_fresh.clean_for(nest_cmd, "p") != ["cargo", "clean", "--locked", "-p", "p",
                                                    "--target-dir", str(nest / "target")]:
        fail("content_fresh.clean_for dropped the target dir: "
             f"{content_fresh.clean_for(nest_cmd, 'p')}")
    if nested() != 0 or nest_said() != "n1":
        fail("the nested probe did not build")
    else:
        shutil.copy2(main_rs, tmp / "main.saved")
        main_rs.write_text('fn main() { println!("n2"); }\n', encoding="utf-8")
        nested()
        shutil.copy2(tmp / "main.saved", main_rs)
        if subprocess.run(nest_cmd, cwd=nest, check=False).returncode != 0 or nest_said() != "n2":
            fail("self-test broken: cargo rebuilt a nested crate restored with an old mtime by "
                 "itself, so the probe no longer shows the trap")
        elif nested() != 0 or nest_said() != "n1":
            fail("content_fresh.nested kept a binary built from other bytes: "
                 f"it prints {nest_said()!r}")

if subprocess.run(["python3", "tools/checks/gtk-capture.py"], cwd=ROOT, check=False).returncode:
    fail("GTK capture execution checks failed")

if status == 0:
    print("check-build-id: OK")
else:
    print("check-build-id: FINDINGS ABOVE")
sys.exit(status)
