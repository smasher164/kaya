#!/usr/bin/env python3
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent / "lib"))
from kaya_gate import ROOT, dev_shell_or_die, scratch_dir

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
    # verifying looks exactly like one that never needed to.
    for lane in ["tools/validate-mac.sh", "tools/linux/run-suites.sh",
                 "tools/ios/run-sim.sh", "tools/android/run-emulator.sh",
                 "tools/deploy-win.sh", "tools/swiftui/build-dylib.sh"]:
        text = (ROOT / lane).read_text(encoding="utf-8")
        if ('build-id.sh" --verify' not in text
                and "build-id.sh --verify" not in text):
            fail(f"{lane} builds the core but never verifies what it runs "
                 f"(build-id.sh --verify)")

    # 2b. The SwiftUI interpreter is a SECOND artifact with its own id;
    # both places that compile one must bake it in and check it. swiftc
    # failing leaves the previous dylib where a cargo failure leaves the
    # previous libkaya.
    for site in ["tools/swiftui/build-dylib.sh", "tools/ios/run-sim.sh"]:
        text = (ROOT / site).read_text(encoding="utf-8")
        if "component swiftui" not in text:
            fail(f"{site} compiles the SwiftUI interpreter but never "
                 f"verifies it (--component swiftui)")
        if "kaya-build-id:" not in text:
            fail(f"{site} does not bake a build id into the interpreter "
                 f"it compiles")

    # 2b-android. The Compose interpreter, same contract: the lane must
    # WRITE the marker before gradle and ASK the apk afterwards.
    emulator = (ROOT / "tools/android/run-emulator.sh").read_text(
        encoding="utf-8")
    if "kaya_write_compose_marker" not in emulator:
        fail("run-emulator.sh does not bake a build id into the Compose "
             "interpreter")
    if "component compose" not in emulator:
        fail("run-emulator.sh never verifies the apk it installs "
             "(--component compose)")

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
