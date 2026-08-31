#!/usr/bin/env python3
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent / "lib"))
from kaya_gate import ROOT, Gate, dev_shell_or_die

dev_shell_or_die()

# A LEG'S ARTIFACT MUST BE IN THE STAGING DERIVATION (maintainer,
# 2026-08-25): a runner that wires a leg whose binary the same file
# never stages fails ten minutes into a matrix with "No such file",
# when a census over the runner's own text can say it in seconds — the
# windowed-rust mac leg is the measured instance (wired hand-queued,
# absent from the SCENES/DEPTH_SCENES derivation that populates
# $RUST_GUESTS). Every finding names the leg AND the list to extend.

import re
import shutil

gate = Gate("check-staging")


def check(root):
    root = pathlib.Path(root)
    findings = []

    def fail(text):
        findings.append("check-staging: " + text)

    def words(text, name):
        m = re.search(rf'^{name}="([^"]*)"', text, re.M)
        if not m:
            return None
        # ${VAR:-default} spellings keep their default.
        body = re.sub(r"\$\{[A-Z_]+:-([^}]*)\}", r"\1", m.group(1))
        return set(body.split())

    # --- validate-mac: $RUST_GUESTS refs vs SCENES + DEPTH_SCENES ----
    mac = (root / "tools" / "validate-mac.sh").read_text(encoding="utf-8")
    scenes = words(mac, "SCENES")
    depth = words(mac, "DEPTH_SCENES")
    if scenes is None or depth is None:
        fail("tools/validate-mac.sh no longer declares SCENES/DEPTH_SCENES "
             "where this census reads them — the staging derivation is "
             "unreadable")
    else:
        staged = scenes | depth
        for m in re.finditer(r'"\$RUST_GUESTS"/([A-Za-z0-9_-]+)', mac):
            name = m.group(1)
            if name not in staged:
                fail(f"tools/validate-mac.sh runs \"$RUST_GUESTS\"/{name} "
                     f"but {name} is in neither SCENES nor DEPTH_SCENES, so "
                     f"the staging loop never copies it and the leg dies at "
                     f"run time with 'No such file' — add {name} to "
                     f"DEPTH_SCENES (or SCENES if every language has the "
                     f"guest)")

    # --- deploy-win: run_suite scenes vs its build lists -------------
    win = (root / "tools" / "deploy-win.sh").read_text(encoding="utf-8")
    wscenes = words(win, "SCENES")
    wdepth = words(win, "DEPTH_SCENES")
    wgo = words(win, "GO_ONLY_SCENES")
    wpy = words(win, "PY_ONLY_SCENES")
    if None in (wscenes, wdepth, wgo, wpy):
        fail("tools/deploy-win.sh no longer declares its four scene lists "
             "where this census reads them")
    else:
        # A suite's ARTIFACT is what its checked-in launcher names, not
        # the suite's own word: listdetail runs split.exe (two scenes,
        # one guest), so the launcher is the only honest derivation
        # source.
        exes = wscenes | wdepth | wgo
        pys = wscenes | wpy
        for m in re.finditer(r"^\s*run_suite ([a-z0-9]+_[a-z0-9]+)\b", win,
                             re.M):
            suite = m.group(1)
            launcher = root / "tools" / "guest" / f"run_{suite}.cmd"
            if not launcher.is_file():
                fail(f"tools/deploy-win.sh runs run_suite {suite} but "
                     f"tools/guest/run_{suite}.cmd does not exist — the "
                     f"scheduled task would start nothing and the leg "
                     f"waits out its whole deadline")
                continue
            body = launcher.read_text(encoding="utf-8", errors="replace")
            for e in re.finditer(r"(?:^|[\s\\])([a-z0-9_]+)\.exe\b", body,
                                 re.M):
                base = e.group(1)
                # Runtimes are not guest artifacts: what python.exe RUNS
                # is the .py clause's business, and dotnet/java ship
                # their own guest trees whole.
                if base in ("python", "pythonw", "java", "dotnet", "cmd",
                            "wscript", "cscript", "schtasks", "taskkill"):
                    continue
                scene = base[:-3] if base.endswith("_go") else base
                if scene not in exes:
                    fail(f"tools/guest/run_{suite}.cmd runs {base}.exe but "
                         f"{scene} is in none of deploy-win's SCENES / "
                         f"DEPTH_SCENES / GO_ONLY_SCENES, so the deploy "
                         f"never builds or ships it — add {scene} to the "
                         f"matching list")
            for p in re.finditer(r"C:\\kaya\\([a-z0-9_]+)\.py\b", body):
                name = p.group(1)
                if name not in pys or not (
                    root / "guests" / "python" / f"{name}.py"
                ).is_file():
                    fail(f"tools/guest/run_{suite}.cmd runs {name}.py but "
                         f"{name} is not a shipped python guest (SCENES / "
                         f"PY_ONLY_SCENES with guests/python/{name}.py) — "
                         f"the deploy never stages it")

    # --- every runner: a wired scene has its .steps, a python leg its
    # file
    runners = [
        "tools/validate-mac.sh",
        "tools/deploy-win.sh",
        "tools/linux/run-suites.sh",
    ]
    for rel in runners:
        text = (root / rel).read_text(encoding="utf-8")
        for m in re.finditer(r"KAYA_SELFTEST=([a-z0-9_]+)\b", text):
            scene = m.group(1)
            if scene in ("1",):
                continue
            if not (root / "tools" / "scenes" / f"{scene}.steps").is_file():
                fail(f"{rel} wires KAYA_SELFTEST={scene} but "
                     f"tools/scenes/{scene}.steps does not exist — the leg "
                     f"would run against a missing script")
        for m in re.finditer(r"guests/python/([a-z0-9_]+\.py)\b", text):
            if not (root / "guests" / "python" / m.group(1)).is_file():
                fail(f"{rel} runs guests/python/{m.group(1)}, which does "
                     f"not exist")

    # --- the iOS bundle: a leg's WINDOW GEOMETRY is not unpinned state
    # An app declaring no supported orientations inherits the DEVICE's,
    # and the same phone then reports 375x734 or 724x355 depending on
    # how the simulator happens to be turned. `adaptive`'s breakpoint is
    # declared at 520, so one of those two widths makes `expect_axis
    # row@narrow "vertical"` true and the other makes it false — same
    # build, no code in between, and the verdict is CORRECT both times,
    # which is why no rerun could ever explain it (measured 2026-08-29,
    # docs/traps.md). The pool's device TYPE is pinned in run-sim.sh;
    # this is its geometry.
    plist = (root / "tools/ios/Info.plist.in").read_text(encoding="utf-8")
    for key in ("UISupportedInterfaceOrientations",
                "UISupportedInterfaceOrientations~ipad"):
        m = re.search(
            rf"<key>{re.escape(key)}</key>\s*<array>(.*?)</array>", plist,
            re.S)
        if not m:
            fail(f"tools/ios/Info.plist.in declares no <{key}> — every iOS "
                 f"leg's window width would then follow the simulator's "
                 f"orientation, which nothing in the lane sets")
            continue
        orientations = re.findall(r"<string>([^<]+)</string>", m.group(1))
        if len(orientations) != 1:
            fail(f"tools/ios/Info.plist.in lets <{key}> take "
                 f"{orientations} — a leg's width must not depend on how "
                 f"the device is turned, so exactly one orientation is "
                 f"declared")

    # --- every guest .ps1 is in BOTH windows lists -------------------
    # The .cmd and .vbs families ride GLOBS, so a new one ships itself;
    # a .ps1 is named individually in deploy_stamp AND in
    # DEPLOY_ARTIFACTS, and deploy-win.sh's own comment says which half
    # is worse — missing from the STAMP, the stamp does not move, the
    # whole deploy block is skipped, and the lane runs against a file
    # that is not there. That comment was the only thing holding the
    # rule: shot-window.ps1 shipped with its .cmd riding the glob beside
    # it and the .ps1 in NEITHER list, so the launcher was staged and
    # the script it runs was not.
    def block(text, opener, closer):
        start = text.find(opener)
        if start < 0:
            return None
        end = text.find(closer, start + len(opener))
        return text[start:end] if end > 0 else None

    stamp_block = block(win, 'shasum -a 256 "$0"', "\n    }")
    artifacts_block = block(win, "DEPLOY_ARTIFACTS=(", "\n    )")
    guest_dir = root / "tools" / "guest"
    ps1s = (sorted(p.name for p in guest_dir.glob("*.ps1"))
            if guest_dir.is_dir() else [])
    if stamp_block is None or artifacts_block is None:
        fail("tools/deploy-win.sh no longer spells deploy_stamp's shasum "
             "list or DEPLOY_ARTIFACTS where this census reads them — "
             "re-point the clause")
    elif not ps1s:
        fail("tools/guest holds no .ps1 at all — a census that reads "
             "nothing agrees with everything")
    else:
        for where, body in (("deploy_stamp", stamp_block),
                            ("DEPLOY_ARTIFACTS", artifacts_block)):
            if "tools/guest/*.ps1" in body:
                continue  # a glob covers the whole family
            for name in ps1s:
                if f"tools/guest/{name}" not in body:
                    fail(f"tools/guest/{name} is staged to the Windows "
                         f"guest by neither glob nor name in {where} — a "
                         f".ps1 is named individually in BOTH deploy_stamp "
                         f"and DEPLOY_ARTIFACTS, and missing it from the "
                         f"stamp means the deploy block never runs at all")

    return findings


# --- self-tests: each perturbation applied to a COPY, count printed --

SHADOW_RELS = ["tools/validate-mac.sh", "tools/deploy-win.sh",
               "tools/linux/run-suites.sh", "tools/ios/Info.plist.in",
               "tools/scenes", "tools/guest", "guests/python"]


def shadow(name):
    dest = gate.scratch() / name
    for rel in SHADOW_RELS:
        src = ROOT / rel
        out = dest / rel
        out.parent.mkdir(parents=True, exist_ok=True)
        if src.is_dir():
            shutil.copytree(src, out, symlinks=False, dirs_exist_ok=True)
        else:
            shutil.copy2(src, out)
    return dest


def negative(n, label, rel, pattern, repl, fragment, refusal_label):
    s = shadow(n.lower())
    p = s / rel
    doctored = gate.doctor(f"{n} {label}", p.read_text(encoding="utf-8"),
                           pattern, repl, flags=re.M)
    p.write_text(doctored, encoding="utf-8")
    findings = check(s)
    if not findings:
        print(f"check-staging: SELF-TEST FAIL ({refusal_label} passed)",
              file=sys.stderr)
        sys.exit(1)
    if not any(fragment in f for f in findings):
        print(f"check-staging: SELF-TEST FAIL ({refusal_label} reddened "
              f"without naming '{fragment}'):", file=sys.stderr)
        print("\n".join(findings), file=sys.stderr)
        sys.exit(1)
    print(f"check-staging: self-test — {refusal_label} refused")


negative(
    "N1", "wired an unstaged mac rust leg", "tools/validate-mac.sh",
    r'run windowed-rust-swiftui env KAYA_SELFTEST=windowed '
    r'"\$RUST_GUESTS"/windowed',
    'run windowed-rust-swiftui env KAYA_SELFTEST=windowed '
    '"$RUST_GUESTS"/windowed\n'
    'run ghost-rust-swiftui env KAYA_SELFTEST=windowed '
    '"$RUST_GUESTS"/ghost',
    "ghost is in neither SCENES nor DEPTH_SCENES",
    "N1 (a mac leg whose binary the staging loop never copies)")

negative(
    "N2", "wired a suite with no launcher", "tools/deploy-win.sh",
    r"^        run_suite windowed_rust$",
    "        run_suite windowed_rust\n        run_suite ghost_python",
    "run_ghost_python.cmd does not exist",
    "N2 (a windows suite whose scheduled task would start nothing)")

negative(
    "N2b", "pointed a launcher at an unbuilt exe",
    "tools/guest/run_listdetail_rust.cmd",
    r"split\.exe", "ghostexe.exe",
    "ghostexe is in none of",
    "N2b (a launcher naming an exe the deploy never builds)")

negative(
    "N3", "pointed a leg at a missing guest", "tools/validate-mac.sh",
    r"KAYA_SELFTEST=portfolio python3 guests/python/portfolio\.py",
    "KAYA_SELFTEST=portfolio python3 guests/python/ghostledger.py",
    "guests/python/ghostledger.py, which does not",
    "N3 (a python leg whose guest file is gone)")

negative(
    "N4", "let the phone bundle turn", "tools/ios/Info.plist.in",
    r"(<key>UISupportedInterfaceOrientations</key>\s*<array>\n)"
    r"        <string>UIInterfaceOrientationPortrait</string>",
    r"\g<1>        <string>UIInterfaceOrientationPortrait</string>\n"
    r"        <string>UIInterfaceOrientationLandscapeLeft</string>",
    "must not depend on how the device is turned",
    "N4 (an iOS bundle whose window width follows the simulator)")

negative(
    "N5", "removed the phone pin", "tools/ios/Info.plist.in",
    r"    <key>UISupportedInterfaceOrientations</key>",
    "    <key>UIGhostOrientations</key>",
    "declares no <UISupportedInterfaceOrientations>",
    "N5 (an iOS bundle that inherits the device's orientation)")

# The two halves separately, because they fail differently: dropped from
# DEPLOY_ARTIFACTS the file simply never ships, dropped from the STAMP
# the whole deploy block is skipped and the lane runs against what the
# VM happened to hold.
negative(
    "N6", "dropped a guest .ps1 from the stamp", "tools/deploy-win.sh",
    r'^ {12}"\$ROOT/tools/guest/shot-window\.ps1" \\\n', "",
    "neither glob nor name in deploy_stamp",
    "N6 (a guest .ps1 the deploy stamp cannot see, so the ship is "
    "skipped)")

negative(
    "N7", "dropped a guest .ps1 from the artifacts", "tools/deploy-win.sh",
    r'^ {8}"\$ROOT/tools/guest/shot-window\.ps1"\n', "",
    "neither glob nor name in DEPLOY_ARTIFACTS",
    "N7 (a guest .ps1 that never rides the wire)")

findings = check(ROOT)
if findings:
    for f in findings:
        print(f, file=sys.stderr)
    print("check-staging: FINDINGS ABOVE", file=sys.stderr)
    sys.exit(1)
print("check-staging: OK (mac rust staging, windows suite lists, scene "
      "scripts and python guests all derive; the iOS bundle pins one "
      "orientation per family)")
