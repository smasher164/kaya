#!/usr/bin/env python3
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent / "lib"))
from kaya_gate import ROOT, Gate, dev_shell_or_die, scratch_dir

dev_shell_or_die()

# Cross-target compile check: per-platform Rust breakage in seconds,
# before any emulator, simulator or VM is involved.
#
# Usage: check-targets.py [native|ios|android|windows|all]   (default all)
#
# The Linux/GTK backend is the one absentee — gtk-sys needs the distro's
# pkg-config world — so tools/check-gtk.py is what to run after touching
# gtk.rs. Do not read a green here as "every backend compiles".

import glob
import os
import re
import subprocess

want = sys.argv[1] if len(sys.argv) > 1 else "all"
status = 0


def cargo(*args):
    return subprocess.run(
        ["cargo", "check", "--locked", "-p", "kaya", "--lib", "--quiet",
         *args],
        cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
        text=True, check=False)


def check(name, *target_args):
    global status
    if want not in ("all", name):
        return
    # BOTH feature configurations: the harness is off by default, so a
    # default-only check compiles neither Stage impl nor any
    # harness-gated backend code, and the lanes build WITH the feature.
    first = cargo(*target_args)
    out = first.stdout
    ok = first.returncode == 0
    if ok:
        second = cargo("--features", "harness", *target_args)
        out += second.stdout
        ok = second.returncode == 0
    if ok:
        print(f"check-targets: {name} OK")
    else:
        print(out.rstrip("\n"))
        print(f"check-targets: {name} FAIL")
        status = 1


check("native")
check("ios", "--target", "aarch64-apple-ios")
check("android", "--target", "aarch64-linux-android")
check("windows", "--target", "aarch64-pc-windows-msvc")


# THE GO BINDING'S ANDROID ARM: the `//go:linkname mainMain main.main`
# pull in bindings/go/mainmain_android.go (docs/go-mobile-plan.md). The
# MATRIX cannot cover it — the validation APK uses the registration
# shape — so this clause cross-builds a single-main fixture for
# android/arm64 as `-buildmode=c-shared` and asks two things: does the
# tagged file compile, and does the linkname RESOLVE. A bodyless func
# compiles whether or not the directive above it is there or spelled
# right; only the link says otherwise.
#
# NO cargo-ndk BUILD IS NEEDED, which is what makes this a fast gate.
# The binding's `#cgo android LDFLAGS` names -lkaya, and a one-symbol
# stub answers for it. CGO_LDFLAGS is searched BEFORE the #cgo
# directive's own -L (measured with `ld -t`), so the stub wins whether
# or not the android lane left a real libkaya.so behind.
def go_android():
    global status
    if want not in ("all", "android"):
        return
    ndk = os.environ.get("ANDROID_NDK_ROOT", "")
    if not ndk:
        print("check-targets: go-android FAIL (ANDROID_NDK_ROOT unset; the "
              "dev shell sets it)")
        status = 1
        return
    bins = sorted(glob.glob(f"{ndk}/toolchains/llvm/prebuilt/*/bin"))
    ndkbin = bins[0] if bins else f"{ndk}/toolchains/llvm/prebuilt/*/bin"
    # THE LOWEST PLATFORM THE NDK CARRIES, not the module's minSdk, and
    # deliberately not coupled to it: this checks Go symbol resolution,
    # which no platform level changes, and reading build.gradle.kts would
    # put the Compose interpreter into this gate's cache key.
    candidates = sorted(glob.glob(f"{ndkbin}/aarch64-linux-android[0-9]*-clang"))
    if not candidates or not os.access(candidates[0], os.X_OK):
        print(f"check-targets: go-android FAIL (no aarch64-linux-android*-"
              f"clang in {ndkbin})")
        status = 1
        return
    cc = candidates[0]
    with scratch_dir("check-targets-go-") as t:
        # A SINGLE main.go WITH NO BUILD TAGS AND NO ANDROID-SPECIFIC
        # LINE — that is the claim, so the fixture must not contain one
        # word more than an app author writes. Its own module with a
        # filesystem replace, because a main package inside dev.kaya
        # would be a guest with no leg and check-steps would rightly say
        # so.
        (t / "go.mod").write_text(
            f"module kayalinknamefixture\n\ngo 1.27\n\n"
            f"require dev.kaya v0.0.0\n\nreplace dev.kaya => {ROOT}\n",
            encoding="utf-8")
        (t / "main.go").write_text(
            'package main\n\nimport (\n\t"os"\n\n'
            '\tkaya "dev.kaya/bindings/go"\n)\n\n'
            "func main() { os.Exit(kaya.NewApp().Run()) }\n",
            encoding="utf-8")
        # THE STUB LIVES IN ITS OWN DIRECTORY, beside the fixture rather
        # than in it: `go build .` refuses a package directory containing
        # a .c file when no file in it imports "C".
        (t / "stub").mkdir()
        (t / "stub/stub.c").write_text("int kaya_link_stub;\n",
                                       encoding="utf-8")
        stub = subprocess.run(
            [cc, "-shared", "-o", str(t / "stub/libkaya.so"),
             str(t / "stub/stub.c")],
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
            check=False)
        if stub.returncode != 0:
            print(stub.stdout.rstrip("\n"))
            print("check-targets: go-android FAIL (could not build the "
                  "-lkaya stub)")
            status = 1
            return
        # -dumpdep MAKES THE LINKER SHOW ITS WORK, for the one mutation a
        # successful link cannot see: if guestMain stopped answering with
        # the app's main, nothing would reference mainMain, dead-code
        # elimination would drop it, and the build would still succeed.
        # The dump is the reachability graph on stderr; the edge asserted
        # below is the attach entry naming the app's own main.
        env = dict(os.environ, CGO_ENABLED="1", GOOS="android",
                   GOARCH="arm64", CC=cc, GOFLAGS="-mod=mod", GOPROXY="off",
                   CGO_LDFLAGS=f"-L{t}/stub")
        with (t / "dep.txt").open("w", encoding="utf-8") as dep:
            build = subprocess.run(
                ["go", "build", "-buildmode=c-shared", "-ldflags=-dumpdep",
                 "-o", str(t / "libfixture.so"), "."],
                cwd=t, env=env, stderr=dep, check=False)
        dep_text = (t / "dep.txt").read_text(encoding="utf-8")
        if build.returncode != 0:
            # Everything the linker said that was not a dependency edge.
            said = [ln for ln in dep_text.splitlines() if " -> " not in ln]
            for line in said[-20:]:
                print(line)
            print("check-targets: go-android FAIL (the single-main fixture "
                  "did not")
            print("  cross-build for android/arm64). A 'relocation target")
            print("  dev.kaya/bindings/go.mainMain not defined' here means "
                  "the")
            print("  //go:linkname in bindings/go/mainmain_android.go is "
                  "gone or")
            print("  misspelled, and with it every app that ships one "
                  "main.go.")
            status = 1
            return
        edges = len(re.findall(
            r"Java_dev_kaya_KayaGo_attach -> dev\.kaya/bindings/go\.mainMain",
            dep_text))
        if edges != 1:
            print("check-targets: go-android FAIL (the attach entry does "
                  "not reference")
            print(f"  the app's own main: {edges} edges, want 1). The "
                  f"linkname resolved but")
            print("  nothing uses it — check that "
                  "bindings/go/mainmain_android.go's")
            print("  guestMain still answers with mainMain, and that")
            print("  bindings/go/android.go still calls guestMain when no "
                  "guest")
            print("  registered one. This is the failure the LINK cannot "
                  "see.")
            status = 1
            return
        # COUNTED, not merely looked for, so a build that produced
        # nothing cannot pass. The leading space matters: cgo emits a
        # `_cgoexp_…` trampoline ending in the same characters, so an
        # end-anchor alone counts two.
        nm = f"{ndkbin}/llvm-nm"
        dyn = subprocess.run([nm, "-D", "--defined-only",
                              str(t / "libfixture.so")],
                             stdout=subprocess.PIPE,
                             stderr=subprocess.DEVNULL, text=True,
                             check=False).stdout
        alln = subprocess.run([nm, str(t / "libfixture.so")],
                              stdout=subprocess.PIPE,
                              stderr=subprocess.DEVNULL, text=True,
                              check=False).stdout
        jni_count = len(re.findall(r" Java_dev_kaya_KayaGo_attach$", dyn,
                                   re.M))
        main_count = len(re.findall(r" main\.main$", alln, re.M))
        if jni_count != 1 or main_count != 1:
            print("check-targets: go-android FAIL (the fixture linked but "
                  "carries")
            print(f"  {jni_count} Java_dev_kaya_KayaGo_attach and "
                  f"{main_count} main.main;")
            print("  both must be exactly 1)")
            status = 1
            return
        print("check-targets: go-android OK")


go_android()

# LINUX IS THE HOLE IN THE ABOVE: nothing here compiles the GTK backend,
# so a Stage method missed in gtk.rs alone survives every fast gate and
# dies in the matrix. This text check cannot see a wrong signature, but
# it sees a missing method in a second with no docker.
if subprocess.run([sys.executable, "tools/lib/stage-coverage.py"],
                  cwd=ROOT, check=False).returncode != 0:
    status = 1

# The other thing cross-compiling cannot see: a CORE surface that exists
# on one platform only. A cfg'd-out surface whose only consumer is also
# cfg'd out is invisible to a compiler — nothing is missing until
# something asks.
if subprocess.run([sys.executable, "tools/lib/paired-cfg.py"],
                  cwd=ROOT, check=False).returncode != 0:
    status = 1

# EVERY SPAWN IN THE CORE SETS ITS THREE DESCRIPTORS EXPLICITLY. A host
# runtime may mark its own fds 0-2 close-on-exec — node does — and a
# child left to inherit one starts with it closed: wl-copy refuses by
# design, xclip hangs to the step ceiling (measured on the js legs
# 2026-09-01, docs/traps.md). `Command::output()` sets all three itself;
# a `.spawn()` chain has to say so. Read as text, since the spawn in
# question is cfg'd to a platform no compiler here reaches.
_spawn_gate = Gate("check-targets")


def spawn_findings(sources):
    """(path, first line, missing) per `.spawn()` chain without all three
    of .stdin/.stdout/.stderr; the number of chains read."""
    bad, seen = [], 0
    for rel, text in sources.items():
        for m in re.finditer(r"Command::new\(", text):
            tail = text[m.start():]
            end = tail.find(".spawn()")
            output = tail.find(".output()")
            if end < 0 or (0 <= output < end):
                continue
            chain = tail[:end]
            seen += 1
            missing = [s for s in (".stdin(", ".stdout(", ".stderr(") if s not in chain]
            if missing:
                line = text.count("\n", 0, m.start()) + 1
                bad.append((rel, line, missing))
    return bad, seen


_sources = {}
for _p in sorted((ROOT / "crates/kaya/src").rglob("*.rs")):
    _sources[str(_p.relative_to(ROOT))] = _p.read_text(encoding="utf-8")
_bad, _seen = spawn_findings(_sources)
print(f"check-targets: spawn chains read: {_seen}")
if _seen < 2:
    _spawn_gate.refuse(f"only {_seen} .spawn() chains found in crates/kaya/src — "
                       f"the harness alone has two, so this census read nothing")
for _rel, _line, _missing in _bad:
    print(f"check-targets: {_rel}:{_line}: a Command that .spawn()s without "
          f"{' '.join(_missing)} — a child inheriting a close-on-exec "
          f"descriptor starts with it CLOSED (docs/traps.md, 2026-09-01); set "
          f"all three", file=sys.stderr)
    status = 1
# THE WATCHED NEGATIVE: the seed writer's explicit stdout removed from a
# copy in memory, count printed, the census demanded red.
_gtk = "crates/kaya/src/gtk.rs"
_doctored = _spawn_gate.doctor("spawn-stdio negative removed the seed's stdout",
                               _sources[_gtk], r"\n\s*\.stdout\(Stdio::null\(\)\)", "")
_nbad, _ = spawn_findings({_gtk: _doctored})
if not any(".stdout(" in m for _r, _l, m in _nbad):
    print("check-targets: SELF-TEST FAIL — a spawn without .stdout( passed "
          "the census", file=sys.stderr)
    status = 1
else:
    print("check-targets: self-test — the doctored spawn is refused, naming .stdout(")

if status == 0:
    print("check-targets: ALL OK")
else:
    print("check-targets: FAILURES ABOVE")
sys.exit(status)
