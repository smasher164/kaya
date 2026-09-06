#!/usr/bin/env python3
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent / "lib"))
from kaya_gate import ROOT, Gate, dev_shell_or_die

dev_shell_or_die()

# A LEG'S ARTIFACT MUST BE IN THE STAGING DERIVATION (ruled 2026-08-25):
# a leg whose binary the same runner never stages fails ten minutes into a
# matrix with "No such file". Every finding names the leg AND the list to
# extend.

import importlib.util
import re
import shutil

gate = Gate("check-staging")


def load_win_lane(path):
    """The windows lane's tables, imported from a PATH so this census and
    the runner cannot disagree. Loaded per call under a throwaway name
    (never through sys.modules) so the shadow negatives can perturb a copy
    and see their perturbation."""
    spec = importlib.util.spec_from_file_location("kaya_lane_shadow", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def load_mac_lane(path):
    """The mac lane's tables, the same discipline."""
    spec = importlib.util.spec_from_file_location("kaya_mac_lane_shadow",
                                                 path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


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

    # --- validate-mac: rust legs vs SCENES + DEPTH_SCENES ------------
    # The staging loop copies SCENES ∪ DEPTH_SCENES out of
    # target/debug/examples, so every rust leg's guest stem must be in that
    # union. The census imports what the runner imports.
    mac_lane = load_mac_lane(root / "tools/lib/lanes/mac.py")
    mac_staged = set(mac_lane.SCENES) | set(mac_lane.DEPTH_SCENES)
    mac_rust = {(name, mac_lane.guest_stem(scene))
                for name, scene, mac_l in mac_lane.legs()
                if mac_l == "rust"}
    if not mac_rust:
        fail("tools/lib/lanes/mac.py queues no rust legs at all — this "
             "census read nothing and would agree with anything")
    for name, stem in sorted(mac_rust):
        if stem not in mac_staged:
            fail(f"tools/lib/lanes/mac.py queues {name} running "
                 f"$RUST_GUESTS/{stem} but {stem} is in neither SCENES "
                 f"nor DEPTH_SCENES, so the staging loop never copies "
                 f"it and the leg dies at run time with 'No such file' "
                 f"— add {stem} to DEPTH_SCENES (or SCENES if every "
                 f"language has the guest)")
    # ...and every python and js leg's guest file exists: the runner
    # derives the path from the module, so the module is what to hold.
    SOURCE_LEGS = {"python": ("python", ".py"), "js": ("js", ".ts")}
    for name, scene, mac_l in mac_lane.legs():
        if mac_l not in SOURCE_LEGS:
            continue
        folder, ext = SOURCE_LEGS[mac_l]
        stem = mac_lane.guest_stem(scene)
        if not (root / "guests" / folder / f"{stem}{ext}").is_file():
            fail(f"tools/lib/lanes/mac.py queues {name} running "
                 f"guests/{folder}/{stem}{ext}, which does not exist")

    # --- deploy-win: the lane module's roster vs its build lists -----
    # This census imports what the runner imports. The DEFAULT depth list
    # is read on purpose: the census must not follow
    # KAYA_WIN_DEPTH_SCENES.
    win_lane = load_win_lane(root / "tools/lib/lanes/win.py")
    exes = (set(win_lane.SCENES) | set(win_lane.DEPTH_SCENES)
            | set(win_lane.GO_ONLY_SCENES))
    pys = set(win_lane.SCENES) | set(win_lane.PY_ONLY_SCENES)
    # A suite's ARTIFACT is what its checked-in launcher names, not the
    # suite's own word: listdetail runs split.exe (two scenes, one guest),
    # so the launcher is the only honest derivation source.
    for suite in [leg for block in win_lane.ORDER for leg in block]:
        launcher = root / "tools" / "guest" / win_lane.launcher(suite)
        if not launcher.is_file():
            fail(f"tools/lib/lanes/win.py wires leg {suite} but "
                 f"tools/guest/{win_lane.launcher(suite)} does not exist — "
                 f"the scheduled task would start nothing and the leg "
                 f"waits out its whole deadline")
            continue
        body = launcher.read_text(encoding="utf-8", errors="replace")
        for e in re.finditer(r"(?:^|[\s\\])([a-z0-9_]+)\.exe\b", body,
                             re.M):
            base = e.group(1)
            # Runtimes are not guest artifacts: what python.exe RUNS is
            # the .py clause's business, and dotnet/java ship their own
            # guest trees whole.
            if base in ("python", "pythonw", "java", "dotnet", "cmd",
                        "wscript", "cscript", "schtasks", "taskkill"):
                continue
            scene = base[:-3] if base.endswith("_go") else base
            if scene not in exes:
                fail(f"tools/guest/{win_lane.launcher(suite)} runs "
                     f"{base}.exe but {scene} is in none of the win lane "
                     f"module's SCENES / DEPTH_SCENES / GO_ONLY_SCENES, "
                     f"so the deploy never builds or ships it — add "
                     f"{scene} to the matching list in "
                     f"tools/lib/lanes/win.py")
        for p in re.finditer(r"C:\\kaya\\([a-z0-9_]+)\.py\b", body):
            name = p.group(1)
            if name not in pys or not (
                root / "guests" / "python" / f"{name}.py"
            ).is_file():
                fail(f"tools/guest/{win_lane.launcher(suite)} runs "
                     f"{name}.py but {name} is not a shipped python guest "
                     f"(SCENES / PY_ONLY_SCENES with "
                     f"guests/python/{name}.py) — the deploy never stages "
                     f"it")
        # The JS guests ship flat from SCENES alone (deploy-win's
        # SCENE_TSS): a launcher naming any other .ts runs a file the
        # deploy never put there.
        for p in re.finditer(r"C:\\kaya\\([a-z0-9_]+)\.ts\b", body):
            name = p.group(1)
            if name not in set(win_lane.SCENES) or not (
                root / "guests" / "js" / f"{name}.ts"
            ).is_file():
                fail(f"tools/guest/{win_lane.launcher(suite)} runs "
                     f"{name}.ts but {name} is not a shipped JS guest "
                     f"(SCENES with guests/js/{name}.ts) — the deploy "
                     f"never stages it")

    # --- every runner: a wired scene has its .steps, a python leg its
    # file
    runners = [
        "tools/deploy-win.py",
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
    # An app declaring no supported orientations inherits the DEVICE's
    # (docs/traps.md: "A leg whose premise is the window's WIDTH, on a
    # device nothing pinned the orientation of"). The pool's device TYPE is
    # pinned in run-sim.py; this is its geometry.
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

    # --- every guest .ps1 is in the windows deploy list --------------
    # The .cmd and .vbs families ride GLOBS, so a new one ships itself; a
    # .ps1 is named individually, and deploy_artifacts() is the ONE list
    # feeding both the artifact ship and the deploy stamp.
    def block(text, opener, closer):
        start = text.find(opener)
        if start < 0:
            return None
        end = text.find(closer, start + len(opener))
        return text[start:end] if end > 0 else None

    win = (root / "tools" / "deploy-win.py").read_text(encoding="utf-8")
    deploy_block = block(win, "def deploy_artifacts():", "\ndef ")
    guest_dir = root / "tools" / "guest"
    ps1s = (sorted(p.name for p in guest_dir.glob("*.ps1"))
            if guest_dir.is_dir() else [])
    if deploy_block is None:
        fail("tools/deploy-win.py no longer spells deploy_artifacts() "
             "where this census reads it — re-point the clause")
    elif not ps1s:
        fail("tools/guest holds no .ps1 at all — a census that reads "
             "nothing agrees with everything")
    elif 'glob("*.ps1")' not in deploy_block:
        for name in ps1s:
            if f"tools/guest/{name}" not in deploy_block:
                fail(f"tools/guest/{name} is staged to the Windows guest "
                     f"by neither glob nor name in deploy_artifacts() — "
                     f"that one list feeds BOTH the artifact ship and the "
                     f"deploy stamp, so missing it means the file never "
                     f"rides the wire AND an edit to it never busts the "
                     f"stamp")

    return findings


# --- self-tests: each perturbation applied to a COPY, count printed --

SHADOW_RELS = ["tools/deploy-win.py",
               "tools/lib/lanes/win.py", "tools/lib/lanes/mac.py",
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
    "N1", "wired an unstaged mac rust leg", "tools/lib/lanes/mac.py",
    r'    \("windowed", \("rust",\)\),',
    '    ("windowed", ("rust",)),\n    ("ghost", ("rust",)),',
    "ghost is in neither SCENES nor DEPTH_SCENES",
    "N1 (a mac leg whose binary the staging loop never copies)")

negative(
    "N2", "wired a suite with no launcher", "tools/lib/lanes/win.py",
    r'^     "windowed_rust",$',
    '     "windowed_rust",\n     "ghost_python",',
    "run_ghost_python.cmd does not exist",
    "N2 (a windows suite whose scheduled task would start nothing)")

negative(
    "N2b", "pointed a launcher at an unbuilt exe",
    "tools/guest/run_listdetail_rust.cmd",
    r"split\.exe", "ghostexe.exe",
    "ghostexe is in none of",
    "N2b (a launcher naming an exe the deploy never builds)")

negative(
    "N2c", "pointed a JS launcher at an unshipped guest",
    "tools/guest/run_listdetail_js.cmd",
    r"split\.ts", "ghostts.ts",
    "ghostts is not a shipped JS guest",
    "N2c (a JS launcher naming a .ts the deploy never stages)")

negative(
    "N3", "pointed a leg at a missing guest", "tools/lib/lanes/mac.py",
    r'    \("portfolio", \("python",\)\),',
    '    ("ghostledger", ("python",)),',
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

# Both directions of the one-list census: a name dropped from the list,
# and a file appearing on disk that the list does not know.
negative(
    "N6", "dropped a guest .ps1 from the deploy list",
    "tools/deploy-win.py",
    r'^ {15}ROOT / "tools/guest/shot-window\.ps1",\n', "",
    "neither glob nor name in deploy_artifacts",
    "N6 (a guest .ps1 that never rides the wire and never busts the "
    "stamp)")

# N7 plants a NEW .ps1 on the shadow's disk with no list entry — the
# census direction that catches an unlisted helper the day it is written.
_s7 = shadow("n7")
(_s7 / "tools/guest/ghosthelper.ps1").write_text(
    "Write-Output ghost\n", encoding="utf-8")
_f7 = check(_s7)
if not any("tools/guest/ghosthelper.ps1 is staged" in f for f in _f7):
    print("check-staging: SELF-TEST FAIL (N7: a .ps1 on disk that "
          "deploy_artifacts() never names passed)", file=sys.stderr)
    sys.exit(1)
print("check-staging: self-test — N7 (a guest .ps1 the deploy list does "
      "not know) refused")

# --- the STAGED GUEST'S SPEC, every branch watched -------------------
# A compiled guest carries the wire hash its binding was generated from
# and refuses a library speaking another one, so a guest staged before a
# spec move dies at LAUNCH (docs/traps.md 2026-09-06 — the go leg panicked
# `library speaks spec 0x…, this binding was generated from 0x…`). The
# lane's builds stamp the spec they compiled against and tools/run-leg.py
# reads it back. NO CLAUSE OVER DISK CAN HOLD THIS: the stamps live under
# target/, which a clean tree does not have, so the rule is proven here on
# a scratch tree — and all THREE refusals plus both quiet answers are made
# to print, because a diagnostic branch nobody has seen print is a guess
# (CLAUDE.md invariant 3).
mac_lane = load_mac_lane(ROOT / "tools/lib/lanes/mac.py")
SPEC_ROOT = gate.scratch() / "spec"
(SPEC_ROOT / "bindings/c").mkdir(parents=True)
HEADER_TEXT = (ROOT / "bindings/c/kaya_wire.h").read_text(encoding="utf-8")
(SPEC_ROOT / "bindings/c/kaya_wire.h").write_text(HEADER_TEXT,
                                                  encoding="utf-8")
WANT_SPEC = mac_lane.spec_hash(SPEC_ROOT)
if not WANT_SPEC:
    print("check-staging: SELF-TEST FAIL (bindings/c/kaya_wire.h declares no "
          "KAYA_SPEC_HASH, so every spec clause below is vacuous)",
          file=sys.stderr)
    sys.exit(1)
print(f"check-staging: the tree's spec hash reads {WANT_SPEC}")


def spec_case(label, root, lang, stamp, fragment):
    """One state of the stamp, its answer PRINTED. `stamp` is the stamp
    file's text, or None for no stamp at all; `fragment` is the text the
    refusal must carry, or None when the state must be accepted."""
    p = mac_lane.spec_stamp(root, lang)
    p.parent.mkdir(parents=True, exist_ok=True)
    p.unlink(missing_ok=True)
    if stamp is not None:
        p.write_text(stamp, encoding="utf-8")
    got = mac_lane.spec_stamp_problem(root, lang)
    print(f"check-staging: {label} -> {got or 'accepted'}")
    if fragment is None:
        if got is not None:
            print(f"check-staging: SELF-TEST FAIL ({label} was REFUSED — the "
                  f"refusal is unconditional and would fire on a good tree)",
                  file=sys.stderr)
            sys.exit(1)
        return
    if got is None:
        print(f"check-staging: SELF-TEST FAIL ({label} was accepted)",
              file=sys.stderr)
        sys.exit(1)
    if fragment not in got:
        print(f"check-staging: SELF-TEST FAIL ({label} was refused without "
              f"naming '{fragment}')", file=sys.stderr)
        sys.exit(1)


spec_case("S1 (a compiled guest with no stamp at all)", SPEC_ROOT, "go",
          None, "Re-run with --build")
spec_case("S2 (a stamp carrying this tree's own spec)", SPEC_ROOT, "go",
          WANT_SPEC + "\n", None)
spec_case("S3 (a guest staged before the spec moved)", SPEC_ROOT, "go",
          gate.doctor("S3 the stamp doctored to an older spec",
                      WANT_SPEC + "\n", re.escape(WANT_SPEC),
                      "0x0000000000000000"),
          f"was built against spec 0x0000000000000000 and this tree's "
          f"bindings/c/kaya_wire.h says {WANT_SPEC}")
# python runs from source, so its binding is always the tree's: an
# unstamped python leg must be quiet or every hand run of one is refused.
spec_case("S5 (a language with no compiled artifact)", SPEC_ROOT, "python",
          None, None)

BROKEN_ROOT = gate.scratch() / "spec-broken"
(BROKEN_ROOT / "bindings/c").mkdir(parents=True)
(BROKEN_ROOT / "bindings/c/kaya_wire.h").write_text(
    gate.doctor("S4 the generated header's KAYA_SPEC_HASH renamed away",
                HEADER_TEXT, r"^#define KAYA_SPEC_HASH\b",
                "#define KAYA_SPEC_HASH_MOVED", flags=re.M),
    encoding="utf-8")
spec_case("S4 (a header that declares no KAYA_SPEC_HASH)", BROKEN_ROOT, "go",
          WANT_SPEC + "\n", "declares no KAYA_SPEC_HASH")

findings = check(ROOT)
if findings:
    for f in findings:
        print(f, file=sys.stderr)
    print("check-staging: FINDINGS ABOVE", file=sys.stderr)
    sys.exit(1)
print("check-staging: OK (mac rust staging, windows suite lists, scene "
      "scripts and python guests all derive; the iOS bundle pins one "
      "orientation per family; a staged guest from another spec is refused "
      "by name)")
