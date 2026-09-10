#!/usr/bin/env python3
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent / "lib"))
from kaya_gate import ROOT, Gate, dev_shell_or_die, scratch_dir

dev_shell_or_die()

# Uniform abort semantics: every binding's negative test that a handler
# abort rolls the model mirror back and ships nothing. Headless.
# Not here: Rust's pin is in `cargo test -p kaya`, Python's in
# kaya_app_checks.py, JS's in bindings/js/kaya_app_checks.ts, and C has
# no mirror to roll back.

import glob
import os
import shutil
import subprocess

g = Gate("check-abort")

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


def step(name, argv, log, *, env=ENV, cwd=ROOT, echo=None):
    """`echo` is a prefix (or a tuple of them) whose lines are printed
    on SUCCESS too: the notification-order and link-route arms each
    publish a verdict, and a run that says nothing cannot be told from
    one that skipped them."""
    with log.open("w", encoding="utf-8") as out:
        run = subprocess.run(argv, cwd=cwd, env=env, stdout=out,
                             stderr=subprocess.STDOUT, check=False)
    if run.returncode != 0:
        fail(name, log)
    if echo:
        for line in log.read_text(encoding="utf-8",
                                  errors="replace").splitlines():
            if line.startswith(echo):
                print(f"check-abort: {name}: {line}")


with scratch_dir("check-abort-") as tmp:
    step("go", ["go", "test", "dev.kaya/bindings/go"], tmp / "go.log")

    # Built as ONE module with the bindings: the internal mirrors are
    # assertable only from inside it.
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

    # THE PROCESS-LEVEL NOTIFICATION HANDLER'S DISPATCH ORDER
    # (docs/tasks-s9-plan.md R1, docs/deferred.md's S9 entry): the
    # one-shot handler bound at the show wins, an id this process never
    # showed reaches the process-level one, that one does not retire,
    # and an unclaimed result announces its drop in full. NO LANE CAN
    # SEE ANY OF IT — a scene registers one or the other, never both.
    # ONE MODULE with the binding, like the abort arm above: the ring
    # loop's switch has no seam, so the decision is a method and this
    # drives it.
    step("swift-notify-build",
         [swiftc, *sdk_args, "-o", str(tmp / "swift-notify"),
          *sorted(glob.glob(str(ROOT / "bindings/swift/*.swift"))),
          str(ROOT / "tools/checks/swift-notify/main.swift"),
          "-import-objc-header", "crates/kaya/include/kaya.h",
          "-I", "crates/kaya/include",
          "-L", "target/debug", "-lkaya",
          "-Xlinker", "-rpath", "-Xlinker", str(ROOT / "target/debug")],
         tmp / "swift-notify.log", env=NO_XCODE)
    step("swift-notify", [str(tmp / "swift-notify")],
         tmp / "swift-notify.log", echo=("notify-order:", "link-route:"))

    # ITS WATCHED NEGATIVE: the ORDER SWAPPED in a COPY of the binding —
    # the process-level handler consulted before the one-shot one — with
    # the substitution COUNTED and the exerciser required to say so. Swift
    # is the one of the five whose build is a FILE LIST rather than a
    # project, so its copy costs one compiler invocation and no scaffolding
    # (java-typecheck's notify negative is the other; C#, OCaml and
    # Haskell are rooted in dotnet, dune and cabal projects, and their
    # negatives are recorded hand runs).
    swapped = tmp / "swift-swapped"
    swapped.mkdir()
    for src in sorted(glob.glob(str(ROOT / "bindings/swift/*.swift"))):
        (swapped / os.path.basename(src)).write_bytes(
            pathlib.Path(src).read_bytes())
    doctored = swapped / "KayaApp.swift"
    doctored.write_text(
        g.doctor("swift notify-order negative consulted the process "
                 "handler first", doctored.read_text(encoding="utf-8"),
                 r"        if let handler = notifications\.removeValue"
                 r"\(forKey: id\) \{",
                 "        if notificationActivation == nil, "
                 "let handler = notifications.removeValue(forKey: id) {"),
        encoding="utf-8")
    step("swift-notify-swapped-build",
         [swiftc, *sdk_args, "-o", str(tmp / "swift-notify-swapped"),
          *sorted(glob.glob(str(swapped / "*.swift"))),
          str(ROOT / "tools/checks/swift-notify/main.swift"),
          "-import-objc-header", "crates/kaya/include/kaya.h",
          "-I", "crates/kaya/include",
          "-L", "target/debug", "-lkaya",
          "-Xlinker", "-rpath", "-Xlinker", str(ROOT / "target/debug")],
         tmp / "swift-swapped.log", env=NO_XCODE)
    with (tmp / "swift-swapped-run.log").open("w", encoding="utf-8") as out:
        swapped_run = subprocess.run(
            [str(tmp / "swift-notify-swapped")], cwd=ROOT, env=ENV,
            stdout=out, stderr=subprocess.STDOUT, check=False)
    swapped_said = (tmp / "swift-swapped-run.log").read_text(
        encoding="utf-8", errors="replace")
    if swapped_run.returncode == 0:
        print("check-abort: SELF-TEST FAIL — the swift notify-order "
              "exerciser PASSED against a binding that consults the "
              "process-level handler first, so it is not exercising the "
              "order", file=sys.stderr)
        sys.exit(1)
    if "the one-shot handler did not answer" not in swapped_said:
        print("check-abort: SELF-TEST FAIL — the swapped swift copy failed, "
              "but NOT by misrouting the one-shot result. What it printed:",
              file=sys.stderr)
        print(swapped_said, file=sys.stderr)
        sys.exit(1)

    # THE LINK HALF'S WATCHED NEGATIVE, the same copy trick one rule over:
    # ROUTE 0 MADE TO SPEAK. Two drops with disjoint causes
    # (docs/app-links-plan.md §4) — a route that MATCHED and reached no
    # handler is the binding's to announce, while route 0 is a URL NO
    # ROUTE TOOK, which the core already announced on stderr naming every
    # declared pattern. NO LANE CAN SEE THE SECOND LINE: a scene reads the
    # same screen back either way, and a reader who meets two sentences
    # for one event learns to distrust both. Removing the guard must turn
    # the exerciser red on its OWN sentence, not merely nonzero.
    spoke = tmp / "swift-route-zero-src"
    spoke.mkdir()
    for src in sorted(glob.glob(str(ROOT / "bindings/swift/*.swift"))):
        (spoke / os.path.basename(src)).write_bytes(
            pathlib.Path(src).read_bytes())
    loud = spoke / "KayaApp.swift"
    loud.write_text(
        g.doctor("swift link negative let route 0 announce a drop of its own",
                 loud.read_text(encoding="utf-8"),
                 r"\} else if route != 0 \{", "} else {"),
        encoding="utf-8")
    step("swift-route-zero-build",
         [swiftc, *sdk_args, "-o", str(tmp / "swift-route-zero"),
          *sorted(glob.glob(str(spoke / "*.swift"))),
          str(ROOT / "tools/checks/swift-notify/main.swift"),
          "-import-objc-header", "crates/kaya/include/kaya.h",
          "-I", "crates/kaya/include",
          "-L", "target/debug", "-lkaya",
          "-Xlinker", "-rpath", "-Xlinker", str(ROOT / "target/debug")],
         tmp / "swift-route-zero.log", env=NO_XCODE)
    with (tmp / "swift-route-zero-run.log").open("w", encoding="utf-8") as out:
        zero_run = subprocess.run(
            [str(tmp / "swift-route-zero")], cwd=ROOT, env=ENV,
            stdout=out, stderr=subprocess.STDOUT, check=False)
    zero_said = (tmp / "swift-route-zero-run.log").read_text(
        encoding="utf-8", errors="replace")
    if zero_run.returncode == 0:
        print("check-abort: SELF-TEST FAIL — the swift link-route exerciser "
              "PASSED against a binding that announces route 0 as well, so "
              "it is not exercising the two drops", file=sys.stderr)
        sys.exit(1)
    if "the link drop was announced as" not in zero_said:
        print("check-abort: SELF-TEST FAIL — the route-0 swift copy failed, "
              "but NOT on the drop sentence. What it printed:",
              file=sys.stderr)
        print(zero_said, file=sys.stderr)
        sys.exit(1)
    print("check-abort: self-test swift link-route negative refused, by its "
          "own sentence")

    # Built UNCONDITIONALLY, like every arm here: an `[ -f ]` guard ran a
    # dll older than the edited binding and called it green (2026-08-22,
    # invariant 4). dotnet's incremental build makes it cheap.
    step("csharp-build",
         ["dotnet", "build", "--nologo", "-v", "q",
          "guests/csharp/kaya-guests.csproj"], tmp / "cs.log")
    step("csharp",
         ["dotnet", "exec", "guests/csharp/bin/Debug/net10.0/kaya-guests.dll"],
         tmp / "cs.log", env=dict(ENV, KAYA_CHECK="abort"))
    # The notification dispatch order, same binary, its own KAYA_CHECK.
    step("csharp-notify",
         ["dotnet", "exec", "guests/csharp/bin/Debug/net10.0/kaya-guests.dll"],
         tmp / "cs-notify.log", env=dict(ENV, KAYA_CHECK="notify"),
         echo=("notify-order:", "link-route:"))

    # Pure JVM against the ring stub — no natives, so mutating
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

    step("ocaml-build",
         ["dune", "build", "--root", ".",
          "./bindings/ocaml/checks/abort_check.exe"], tmp / "ml.log")
    step("ocaml",
         ["dune", "exec", "--root", ".",
          "bindings/ocaml/checks/abort_check.exe"], tmp / "ml.log")
    step("ocaml-notify-build",
         ["dune", "build", "--root", ".",
          "./bindings/ocaml/checks/notify_order_check.exe"],
         tmp / "ml-notify.log")
    step("ocaml-notify",
         ["dune", "exec", "--root", ".",
          "bindings/ocaml/checks/notify_order_check.exe"],
         tmp / "ml-notify.log", echo=("notify-order:", "link-route:"))

    # A PRIVATE build tree, never the shared dist-newstyle: the repo is
    # mounted into the linux container, so wiping the shared one destroys
    # the docker lane's Haskell guests mid-run (2026-07-24). The build
    # directory goes every run because cabal trusts its plan cache over
    # the artifact's existence (docs/traps.md: An ad-hoc `cabal build`
    # poisons the shared dist-newstyle for the whole mac lane).
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

    step("haskell-notify-build",
         ["cabal", "build", "kaya-notify-order-check", *cabal_args],
         tmp / "hs-notify.log", cwd=ROOT / "guests/haskell")
    where_notify = subprocess.run(
        ["cabal", "list-bin", "kaya-notify-order-check",
         f"--builddir={hs_dist}", "-v0"], cwd=ROOT / "guests/haskell",
        stdout=subprocess.PIPE, text=True, check=False)
    step("haskell-notify", [where_notify.stdout.strip()],
         tmp / "hs-notify.log", echo=("notify-order:", "link-route:"))

    # The Build/Tpl monad wall, pinned by a must-not-compile fixture. The
    # TYPE error is demanded: a syntax error must not pass as "didn't
    # compile".
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


# ─────────────────────────────────────────────────────────────────────
# THE THREE REMAINING NOTIFY-ORDER NEGATIVES (ruled 2026-09-09). Java's
# lives in tools/java-typecheck.py and Swift's above; C#, OCaml and
# Haskell are rooted in dotnet, dune and cabal projects anchored at the
# repo, so each needs a PROJECT OF ITS OWN around the doctored copy.
# NEVER THE REAL FILE: a gate that perturbs tracked source leaves the
# tree doctored if it is killed, which is why no other gate here does it.
#
# THE PROJECTS LIVE UNDER target/, not in the ephemeral scratch, for the
# reason target/hs-abort-dist exists: a cold GHC build of KayaApp.hs
# every run would cost more than the gate. The SOURCES are rewritten from
# the tree on every run, so a stale copy cannot go green — only the
# compiler's own caching survives, and it re-does the work the moment a
# byte moves.
NEG_ROOT = ROOT / "target/notify-negatives"

# (pattern, replacement): the ORDER SWAPPED — the process-level handler
# consulted before the one-shot one. OCaml and Haskell REORDER THE ARMS
# rather than guarding the first: a `Some handler, None` guard is refused
# by both compilers for non-exhaustiveness, which is a stronger wall but
# proves nothing about the decision at run time.
NOTIFY_SWAPS = {
    "csharp": (r"        if \(notifications\.Remove\(id, out var fn\)\)",
               "        if (notifications.Remove(id, out var fn) "
               "&& notificationActivation is null)"),
    "ocaml": (r"  \| Some handler, _ ->\n"
              r"      Hashtbl\.remove app\.notification_handlers id;\n"
              r"      dispatch app \(fun \(\) -> handler outcome\)\n"
              r"  \| None, Some f -> dispatch app \(fun \(\) -> f id outcome\)",
              "  | _, Some f -> dispatch app (fun () -> f id outcome)\n"
              "  | Some handler, _ ->\n"
              "      Hashtbl.remove app.notification_handlers id;\n"
              "      dispatch app (fun () -> handler outcome)"),
    "haskell": (r"    \(Just handler, _\) -> dispatch \(handler outcome\)\n"
                r"    \(Nothing, Just act\) -> dispatch \(act ident outcome\)",
                "    (_, Just act) -> dispatch (act ident outcome)\n"
                "    (Just handler, _) -> dispatch (handler outcome)"),
}


def stage(lang, files, doctor_rel):
    """A scratch project's sources, rewritten from the tree every run.
    `files` is (destination, source-relative) pairs; `doctor_rel` names
    the one whose notification_result arm is swapped."""
    root = NEG_ROOT / lang
    shutil.rmtree(root / "src", ignore_errors=True)
    (root / "src").mkdir(parents=True, exist_ok=True)
    for dest, rel in files:
        out = root / "src" / dest
        out.parent.mkdir(parents=True, exist_ok=True)
        if rel == doctor_rel:
            out.write_text(
                g.doctor(f"{lang} notify-order negative consulted the "
                         f"process handler first",
                         (ROOT / rel).read_text(encoding="utf-8"),
                         *NOTIFY_SWAPS[lang]),
                encoding="utf-8")
        else:
            out.write_bytes((ROOT / rel).read_bytes())
    return root


def demand_red(lang, argv, log, *, env=ENV, cwd=ROOT):
    """The doctored build must FAIL BY MISROUTING THE ONE-SHOT RESULT.
    A nonzero exit alone is not the test: a copy that did not compile
    exits nonzero too, and that is how a negative goes vacuous."""
    with log.open("w", encoding="utf-8") as out:
        run = subprocess.run(argv, cwd=cwd, env=env, stdout=out,
                             stderr=subprocess.STDOUT, check=False)
    said = log.read_text(encoding="utf-8", errors="replace")
    if run.returncode == 0:
        print(f"check-abort: SELF-TEST FAIL — the {lang} notify-order "
              f"exerciser PASSED against a binding that consults the "
              f"process-level handler first, so it is not exercising "
              f"the order", file=sys.stderr)
        sys.exit(1)
    if "the one-shot handler did not answer" not in said:
        print(f"check-abort: SELF-TEST FAIL — the swapped {lang} copy "
              f"failed, but NOT by misrouting the one-shot result, so "
              f"the negative did not watch the order. What it printed:",
              file=sys.stderr)
        print(said, file=sys.stderr)
        sys.exit(1)
    print(f"check-abort: self-test {lang} notify-order negative refused, "
          f"by its own sentence")


with scratch_dir("check-abort-neg-") as tmp:
    # --- C# -----------------------------------------------------------
    cs = stage("csharp",
               [(f"binding/{os.path.basename(f)}", f"bindings/csharp/"
                 f"{os.path.basename(f)}")
                for f in sorted(glob.glob(str(ROOT / "bindings/csharp/*.cs")))]
               + [("NotifyOrderCheck.cs", "guests/csharp/NotifyOrderCheck.cs")],
               "bindings/csharp/KayaApp.cs")
    (cs / "src" / "NotifyMain.cs").write_text(
        "// The scratch project's entry point: the guest binary's own\n"
        "// KAYA_CHECK switch is not copied, so this calls the check.\n"
        "static class NotifyMain\n"
        "{\n"
        "    static void Main() { NotifyOrderCheck.Run(); }\n"
        "}\n", encoding="utf-8")
    (cs / "src" / "kaya-notify.csproj").write_text(
        '<Project Sdk="Microsoft.NET.Sdk">\n'
        "  <PropertyGroup>\n"
        "    <OutputType>Exe</OutputType>\n"
        "    <TargetFramework>net10.0</TargetFramework>\n"
        "    <AllowUnsafeBlocks>true</AllowUnsafeBlocks>\n"
        "    <Nullable>disable</Nullable>\n"
        "    <ImplicitUsings>disable</ImplicitUsings>\n"
        "  </PropertyGroup>\n"
        "</Project>\n", encoding="utf-8")
    step("csharp-notify-swapped-build",
         ["dotnet", "build", "--nologo", "-v", "q",
          str(cs / "src" / "kaya-notify.csproj")], tmp / "cs-neg-build.log")
    demand_red("csharp",
               ["dotnet", "exec",
                str(cs / "src" / "bin/Debug/net10.0/kaya-notify.dll")],
               tmp / "cs-neg.log")

    # --- OCaml --------------------------------------------------------
    ml = stage("ocaml",
               [("kaya_wire.ml", "bindings/ocaml/kaya_wire.ml"),
                ("kaya_runtime.ml", "bindings/ocaml/kaya_runtime.ml"),
                ("kaya_app.ml", "bindings/ocaml/kaya_app.ml"),
                ("kaya_ml_stubs.c", "bindings/ocaml/kaya_ml_stubs.c"),
                ("notify_order_check.ml",
                 "bindings/ocaml/checks/notify_order_check.ml")],
               "bindings/ocaml/kaya_app.ml")
    (ml / "src" / "dune-project").write_text("(lang dune 3.0)\n",
                                             encoding="utf-8")
    (ml / "src" / "dune").write_text(
        "(library\n"
        " (name kaya_guest_binding)\n"
        " (wrapped false)\n"
        " (modules kaya_wire kaya_runtime kaya_app)\n"
        " (libraries ctypes ctypes-foreign threads.posix)\n"
        " (foreign_stubs\n"
        "  (language c)\n"
        "  (names kaya_ml_stubs)))\n"
        "\n"
        "(executable\n"
        " (name notify_order_check)\n"
        " (modules notify_order_check)\n"
        " (libraries kaya_guest_binding unix))\n", encoding="utf-8")
    step("ocaml-notify-swapped-build",
         ["dune", "build", "--root", str(ml / "src"),
          "./notify_order_check.exe"], tmp / "ml-neg-build.log")
    demand_red("ocaml",
               [str(ml / "src" / "_build/default/notify_order_check.exe")],
               tmp / "ml-neg.log")

    # --- Haskell ------------------------------------------------------
    hs = stage("haskell",
               [("binding/KayaApp.hs", "bindings/haskell/KayaApp.hs"),
                ("binding/KayaRuntime.hs", "bindings/haskell/KayaRuntime.hs"),
                ("binding/KayaWire.hs", "bindings/haskell/KayaWire.hs"),
                ("binding/kaya_hs_stubs.c",
                 "bindings/haskell/kaya_hs_stubs.c"),
                ("NotifyOrderCheck.hs", "guests/haskell/NotifyOrderCheck.hs")],
               "bindings/haskell/KayaApp.hs")
    (hs / "src" / "kaya-notify.cabal").write_text(
        "cabal-version: 2.4\n"
        "name: kaya-notify\n"
        "version: 0\n"
        "build-type: Simple\n"
        "\n"
        "executable kaya-notify-order-check\n"
        "  default-language: GHC2021\n"
        "  build-depends: base, bytestring, containers, time, directory\n"
        "  ghc-options: -threaded\n"
        "  main-is: NotifyOrderCheck.hs\n"
        "  other-modules: KayaApp, KayaRuntime, KayaWire\n"
        "  hs-source-dirs: . binding\n"
        "  c-sources: binding/kaya_hs_stubs.c\n"
        "  extra-libraries: kaya\n", encoding="utf-8")
    hs_neg_dist = NEG_ROOT / "haskell/dist"
    hs_neg_args = [f"--builddir={hs_neg_dist}",
                   f"--extra-lib-dirs={ROOT}/target/debug",
                   f"--ghc-options=-L{ROOT}/target/debug "
                   f"-optl-Wl,-rpath,{ROOT}/target/debug", "-v0"]
    step("haskell-notify-swapped-build",
         ["cabal", "build", "kaya-notify-order-check", *hs_neg_args],
         tmp / "hs-neg-build.log", cwd=hs / "src")
    hs_neg_bin = subprocess.run(
        ["cabal", "list-bin", "kaya-notify-order-check",
         f"--builddir={hs_neg_dist}", "-v0"], cwd=hs / "src",
        stdout=subprocess.PIPE, text=True, check=False)
    demand_red("haskell", [hs_neg_bin.stdout.strip()], tmp / "hs-neg.log")

print("check-abort: OK")
