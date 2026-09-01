#!/usr/bin/env python3
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent / "lib"))
from kaya_gate import ROOT, Gate, dev_shell_or_die, scratch_dir

dev_shell_or_die()

# The gate for the stale-artifact guard (tools/build-id.sh). Two
# questions: does a BUILT artifact carry the current id and does the
# verifier reject one that does not, and does every lane verify what it
# runs or ships? The verify call is one somebody has to write, so a new
# lane starts out unguarded.

import subprocess

LIB = ROOT / "target/debug/libkaya.dylib"
if not LIB.is_file():
    print("check-build-id: build libkaya first (cargo build --locked --lib)")
    sys.exit(1)

status = 0


def fail(msg):
    global status
    print(f"check-build-id: {msg}", file=sys.stderr)
    status = 1


def verify(*args):
    """tools/build-id.sh --verify ... — quiet; (rc, stderr-text)."""
    run = subprocess.run(
        ["tools/build-id.sh", "--verify", *args], cwd=ROOT,
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

    # 1b. Doctor the marker in a COPY — one hex digit — and the verifier
    # must reject it.
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
    # verifying looks exactly like one that never needed to. The windows
    # runner is python since the runner conversion, and its argv spelling
    # (["…/build-id.sh", "--verify", …]) matched NEITHER of the two shell
    # substrings this clause used to hold — so the call is read as a
    # non-comment LINE naming build-id and --verify together, which both
    # languages spell.
    def lane_verifies(text):
        for line in text.splitlines():
            s = line.strip()
            if s.startswith("#"):
                continue
            if "build-id" in s and "--verify" in s:
                return True
        return False

    for lane_rel in ["tools/validate-mac.sh", "tools/linux/run-suites.sh",
                     "tools/ios/run-sim.py", "tools/android/run-emulator.py",
                     "tools/deploy-win.py", "tools/swiftui/build-dylib.sh"]:
        if not lane_verifies((ROOT / lane_rel).read_text(encoding="utf-8")):
            fail(f"{lane_rel} builds the core but never verifies what it "
                 f"runs (build-id.sh --verify)")

    # The clause's own negative, watched because this parse already
    # drifted once (the argv spelling above): the windows runner with
    # its one verify flag doctored away must fail the clause, and the
    # perturbation count is printed by the prelude.
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
    # previous libkaya. Line-wise like clause 2: the shell spells
    # `--component swiftui` and the python runner spells the argv pair
    # on one line, and both name the two tokens together.
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

    # 2b-android. The Compose interpreter, same contract: the lane must
    # WRITE the marker before gradle and ASK the apk afterwards. The
    # runner is python since the runner conversion; the verify is read
    # line-wise like clause 2, and both halves are watched red below —
    # this pair had no negative while it read the shell body, and the
    # crossing is exactly when a bare-substring clause goes quiet.
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
    uncomposed = g.doctor("2b-android's compose verify deleted", emulator,
                          r'"--component", "compose"',
                          '"--frobnicate", "compose"', want=1)
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

if status == 0:
    print("check-build-id: OK")
else:
    print("check-build-id: FINDINGS ABOVE")
sys.exit(status)
