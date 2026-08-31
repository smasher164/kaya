#!/usr/bin/env python3
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent / "lib"))
from kaya_gate import ROOT, dev_shell_or_die, scratch_dir

dev_shell_or_die()

# The uniform-abort gate: every binding's negative test that a handler
# abort rolls the model mirror back, ships nothing, and lets the app
# continue. Headless — the core loop is never entered.
#
# Not here: Rust's pin is in `cargo test -p kaya`, Python's in
# kaya_app_checks.py, and C has no mirror to roll back.

import glob
import os
import shutil
import subprocess

LIB = ROOT / "target/debug/libkaya.dylib"
if not LIB.is_file():
    print("check-abort: build libkaya first (cargo build --locked --lib)")
    sys.exit(1)

ENV = dict(os.environ, KAYA_LIB=str(LIB))
NO_XCODE = {k: v for k, v in ENV.items()
            if k not in ("DEVELOPER_DIR", "SDKROOT")}


def fail(name, log):
    sys.stdout.write(log.read_text(encoding="utf-8"))
    print(f"check-abort: {name} FAILED", file=sys.stderr)
    sys.exit(1)


def step(name, argv, log, *, env=ENV, cwd=ROOT):
    with log.open("w", encoding="utf-8") as out:
        run = subprocess.run(argv, cwd=cwd, env=env, stdout=out,
                             stderr=subprocess.STDOUT, check=False)
    if run.returncode != 0:
        fail(name, log)


with scratch_dir("check-abort-") as tmp:
    # Go: the in-package test (also pins Build-in-Build misuse and the
    # derived-registration non-leak).
    step("go", ["go", "test", "dev.kaya/bindings/go"], tmp / "go.log")

    # Swift: one module with the bindings, so internal mirrors are
    # assertable.
    find = subprocess.run(["xcrun", "--find", "swiftc"], env=NO_XCODE,
                          stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                          text=True, check=False)
    if find.returncode == 0:
        swiftc, sdk_args = find.stdout.strip(), []
    else:
        swiftc = "/usr/bin/swiftc"
        sdk_args = ["-sdk", "/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk"]
    step("swift-build",
         [swiftc, *sdk_args, "-o", str(tmp / "swift-abort"),
          *sorted(glob.glob(str(ROOT / "bindings/swift/*.swift"))),
          str(ROOT / "tools/checks/swift-abort/main.swift"),
          "-import-objc-header", "crates/kaya/include/kaya.h",
          "-I", "crates/kaya/include",
          "-L", "target/debug", "-lkaya",
          "-Xlinker", "-rpath", "-Xlinker", str(ROOT / "target/debug")],
         tmp / "swift.log", env=NO_XCODE)
    step("swift", [str(tmp / "swift-abort")], tmp / "swift.log")

    # C#: the KAYA_CHECK=abort branch of the guest binary. Built
    # UNCONDITIONALLY like every other arm: an [ -f ] guard ran a dll
    # older than the edited binding and called it green (measured
    # 2026-08-22, the TX 45 adaptation — invariant 4's exact shape;
    # dotnet's own incremental build makes the unconditional call cheap).
    step("csharp-build",
         ["dotnet", "build", "--nologo", "-v", "q",
          "guests/csharp/kaya-guests.csproj"], tmp / "cs.log")
    step("csharp",
         ["dotnet", "exec", "guests/csharp/bin/Debug/net10.0/kaya-guests.dll"],
         tmp / "cs.log", env=dict(ENV, KAYA_CHECK="abort"))

    # Java: pure JVM against the ring stub — no natives, so mutating
    # transactions always abort (AbortCheck.java's header has the shape).
    shutil.rmtree(tmp / "java", ignore_errors=True)
    step("java-build",
         ["javac", "-encoding", "UTF-8", "-d", str(tmp / "java"),
          "bindings/java-desktop/dev/kaya/KayaRing.java",
          *sorted(glob.glob(str(ROOT / "bindings/java/dev/kaya/*.java"))),
          "tools/checks/java-abort/dev/kaya/IdSpaceCheck.java",
          "tools/checks/java-abort/AbortCheck.java"], tmp / "java.log")
    step("java", ["java", "-cp", str(tmp / "java"), "AbortCheck"],
         tmp / "java.log")

    # OCaml: the checks/ executable beside the binding.
    step("ocaml-build",
         ["dune", "build", "--root", ".",
          "./bindings/ocaml/checks/abort_check.exe"], tmp / "ml.log")
    step("ocaml",
         ["dune", "exec", "--root", ".",
          "bindings/ocaml/checks/abort_check.exe"], tmp / "ml.log")

    # Haskell: the kaya-abort-check executable beside the scene guests.
    # This gate builds in its OWN build tree, never the shared
    # dist-newstyle: the repo is mounted into the linux container, so
    # wiping the shared one destroys the docker lane's freshly built
    # Haskell guests mid-run (caught by the matrix, 2026-07-24).
    #
    # Inside that private tree the component's build directory goes EVERY
    # run, so the library and the executable genuinely recompile and LINK
    # here: cabal skips a link whose inputs are unchanged and trusts its
    # plan cache over the artifact's existence, so neither deleting the
    # binary nor -fforce-recomp forces it (docs/traps.md).
    hs_dist = ROOT / "target/hs-abort-dist"
    for stale in glob.glob(str(hs_dist / "build/*/*/kaya-guests-0")):
        shutil.rmtree(stale, ignore_errors=True)
    cabal_args = [f"--builddir={hs_dist}",
                  f"--extra-lib-dirs={ROOT}/target/debug",
                  f"--ghc-options=-L{ROOT}/target/debug "
                  f"-optl-Wl,-rpath,{ROOT}/target/debug", "-v0"]
    step("haskell-build",
         ["cabal", "build", "kaya-abort-check", *cabal_args],
         tmp / "hs.log", cwd=ROOT / "guests/haskell")
    where = subprocess.run(
        ["cabal", "list-bin", "kaya-abort-check", f"--builddir={hs_dist}",
         "-v0"], cwd=ROOT / "guests/haskell", stdout=subprocess.PIPE,
        text=True, check=False)
    step("haskell", [where.stdout.strip()], tmp / "hs.log")

    # Haskell's mirror-read guard is the Build/Tpl monad wall itself,
    # pinned by a must-not-compile fixture. The check insists on the TYPE
    # error — a syntax error must not pass as "didn't compile".
    with (tmp / "hs-guard.log").open("w", encoding="utf-8") as out:
        guard = subprocess.run(
            ["ghc", "-fno-code", "-XGHC2021", "-ibindings/haskell",
             "-hidir", str(tmp / "hs-guard"), "-odir", str(tmp / "hs-guard"),
             "tools/checks/haskell-guard-fail/TplRead.hs"],
            cwd=ROOT, env=ENV, stdout=out, stderr=subprocess.STDOUT,
            check=False)
    if guard.returncode == 0:
        print("check-abort: haskell guard fixture COMPILED — the Build/Tpl "
              "wall fell", file=sys.stderr)
        sys.exit(1)
    if "Couldn't match" not in (tmp / "hs-guard.log").read_text(
            encoding="utf-8"):
        fail("haskell-guard-fixture", tmp / "hs-guard.log")

print("check-abort: OK")
