"""What FEATURES does a scene's script need, and which backend refuses them.

THE FAILURE THIS EXISTS FOR (2026-08-05, scratchpad/derive-pin-depth.md
§8). check-steps and check-stubs state one rule between them — a scene's
legs are wired on a runner IF AND ONLY IF that runner's backend has the
feature — and for four milestones they stated it KEYED ON THE SCENE
NAME. That was right by luck. `clipboard.steps` was the only scene that
ever touched the clipboard, so "the scene that needs the feature" and
"the scene named after it" were the same set.

The luck ran out when `todos.steps` grew `menu_activate "Edit>Undo"`.
The Compose backend still declared `depthStub("undo")`; the Android
runner wired no `undo` legs, so check-stubs was green; the runner DID
wire `todos` legs and `todos` is not a stubbed scene name, so check-steps
was green. Both gates passed on a tree where the android lane was about
to walk into `error("...not yet materialized...")` on its first
Edit>Undo. Nothing structural stood between the reshape and the matrix.

So the rule moves one level down, off the scene NAME and onto the scene's
VERBS. A .steps script is a list of demands on a backend; this module
reads those demands and answers two questions with one derivation:

    --check    which runners run a scene whose features their backend
               refuses (check-steps' new cross-check)
    --exempt   which (runner, scene) pairs a stub legitimately holds
               open, so check-steps stops DEMANDING those legs

They are complements of one predicate, and they must stay complements:
if the cross-check fails a pair the exemption does not cover, no tree can
satisfy both gates at once and the next agent deletes a clause to get
green. Mid-slice, a Compose stub on `undo` holds BOTH the `undo` legs and
the `todos` legs off the android runner, and the JNI landing hands both
back the same day.

--dump prints the derivation itself, which is the only honest way to
review it.
"""

import argparse
import pathlib
import re
import sys

# Each runner, the backend it presents through, and the platform token
# the Swift declaration carries (one file serves mac AND iOS, so the
# declaration there names its platform and nothing else does).
RUNNERS = [
    ("tools/validate-mac.sh", "swift/KayaSwiftUI.swift", "macos"),
    ("tools/linux/run-suites.sh", "crates/kaya/src/gtk.rs", ""),
    ("tools/deploy-win.sh", "crates/kaya/src/winui/mod.rs", ""),
    ("tools/ios/run-sim.sh", "swift/KayaSwiftUI.swift", "ios"),
    ("tools/android/run-emulator.sh",
     "android/kaya/src/main/kotlin/dev/kaya/KayaCompose.kt", ""),
]

# A menu item's LEAF LABEL, lowercased, against the closed role
# vocabulary — and then the role against the feature that implements it.
#
# The key set is PINNED to MENU_ROLES in crates/kaya/src/scene.rs
# (see check_roles_table below), so a role cannot join the vocabulary
# without this table saying which feature it belongs to. `None` is a
# real answer and has to be spelled: `settings` is a role every backend
# has carried since the commands milestone and there is no `settings`
# feature anyone could stub.
ROLE_FEATURE = {
    "undo": "undo",
    "redo": "undo",
    "cut": "clipboard",
    "copy": "clipboard",
    "paste": "clipboard",
    "settings": None,
}

# Verbs that name a feature outright, with no menu item in between.
VERB_FEATURE = {
    "expect_clipboard": "clipboard",
    "clipboard_seed": "clipboard",
    # The save dialog's three verbs. Keyed on the VERB and not on the
    # scene name for the reason the module note gives: tools/scenes are
    # shared verbatim, so the day an editor scene saves a document it
    # demands this feature without being called `save`, and a backend
    # still declaring depth_stub("save") must hold those legs off too.
    "expect_save_dialog": "save",
    "file_dialog_name": "save",
    "file_save": "save",
}

# The verbs that take a menu PATH as their first argument. `shortcut` is
# deliberately NOT here: its argument is a chord ("primary+z"), which
# names no role, so a scene reaching undo by keystroke instead of by menu
# is a hole in this derivation. No scene does today (measured: the four
# `shortcut` lines are primary+backslash, primary+2, primary+comma and
# primary+s), and the honest fix if one ever does is a role argument on
# the verb, not a chord table here that guesses at platform conventions.
MENU_VERBS = ("menu_activate", "expect_menu", "expect_menu_presentation")

# Every language's spelling of the depth-stub declaration. Suffix-matched
# because each keeps its own casing and prefix: `depth_stub` in Rust,
# `depthStub` in Kotlin, `kayaDepthStub` in Swift (whose file-scope
# functions are all kaya-prefixed to stay out of the host's symbol
# space). check-stubs and check-steps grep the same three shapes.
def stub_spellings(feature: str, platform: str) -> list[str]:
    out = [f'epth_stub("{feature}")', f'epthStub("{feature}")']
    if platform:
        out.append(f'epthStub("{feature}", on: "{platform}")')
    return out


LANGS = ("rust", "python", "go", "csharp", "java", "swift", "ocaml",
         "haskell", "c", "compose", "jvm", "swiftui")


def significant(text: str):
    """The script's real lines, numbered from 1. Comments and blanks are
    not demands on anything."""
    for n, raw in enumerate(text.splitlines(), 1):
        line = raw.strip()
        if line and not line.startswith("#"):
            yield n, line


def features(text: str, scene: str) -> dict:
    """feature -> (line number, the line that demanded it).

    The VERBS are read first and the scene's own NAME is only a fallback,
    which matters for one reason: a scene whose name already equals a
    feature would otherwise MASK the verb rule that derives it, and a
    broken rule would look identical to a working one in --dump. The
    clipboard rows are the ones this keeps honest — `clipboard.steps` is
    named after the feature it needs, so name-first bookkeeping would
    have hidden a dead rule for as long as anyone cared to look.

    The name stays in the set because that is the rule the two gates
    already enforced, restated here so one predicate answers for both
    halves rather than two greps drifting apart.
    """
    out: dict = {}
    for n, line in significant(text):
        verb = line.split()[0]
        feat = VERB_FEATURE.get(verb)
        if feat and feat not in out:
            out[feat] = (n, line)
        if verb in MENU_VERBS:
            m = re.match(r'\S+\s+"([^"]*)"', line)
            if not m:
                continue
            leaf = m.group(1).split(">")[-1].strip()
            # Trailing ellipsis is a macOS label convention ("Settings…"),
            # not part of the role.
            role = leaf.rstrip("….").lower()
            feat = ROLE_FEATURE.get(role)
            if feat and feat not in out:
                out[feat] = (n, line)
    out.setdefault(scene, (0, f"the scene is named {scene}"))
    return out


def runs_scene(runner_text: str, scene: str) -> bool:
    """Does this runner have legs for this scene?

    Every runner names its legs `<scene>-<lang>` or `<scene>_<lang>`.
    milestone2 is the one exception in the tree — its legs ARE the
    unprefixed originals (`run rust-swiftui`), the same carve-out
    check-steps' wired() carries — so it falls back to the bare name.
    """
    if scene == "milestone2":
        return scene in runner_text
    return re.search(rf"\b{re.escape(scene)}[-_](?:{'|'.join(LANGS)})\b",
                     runner_text) is not None


def check_roles_table(root: pathlib.Path, bad: list) -> None:
    """ROLE_FEATURE must cover MENU_ROLES exactly.

    Without this the table is a snapshot that goes stale in silence: a
    seventh role ships, no scene verb maps to a feature, and this whole
    module answers "no features needed" for the scene that needs the new
    one. The pin costs one regex and turns a silent hole into a failure
    at the commit that opens it.
    """
    src = root / "crates/kaya/src/scene.rs"
    if not src.exists():
        return
    m = re.search(r"MENU_ROLES\s*:\s*&\[&str\]\s*=\s*&\[([^\]]*)\]",
                  src.read_text())
    if not m:
        bad.append("crates/kaya/src/scene.rs: no MENU_ROLES const — the role "
                   "vocabulary moved and scene-features.py cannot pin its "
                   "table against it")
        return
    roles = set(re.findall(r'"([^"]+)"', m.group(1)))
    for role in sorted(roles - set(ROLE_FEATURE)):
        bad.append(f'tools/lib/scene-features.py: menu role "{role}" is in '
                   f"MENU_ROLES but not in ROLE_FEATURE — say which feature "
                   f"a scene activating it needs, or None if no backend "
                   f"could ever stub one")
    for role in sorted(set(ROLE_FEATURE) - roles):
        bad.append(f'tools/lib/scene-features.py: ROLE_FEATURE names "{role}", '
                   f"which is no longer in MENU_ROLES — a rule about a role "
                   f"that cannot be authored can only ever pass")


def check_feature_names(root: pathlib.Path, scenes: dict, bad: list) -> None:
    """Every feature this module can derive must BE a scene name.

    A depth stub is spelled `depth_stub("<scene>")` and nothing else, so
    a feature that names no scene can never be stubbed and every rule
    about it is vacuous — the exact shape of the four-milestone false
    green that made the CALL spelling mandatory in the first place
    (tools/lib/hand-rolled-stubs.py). A typo here would be invisible
    otherwise.
    """
    known = set(scenes)
    for feat in sorted({f for f in ROLE_FEATURE.values() if f} |
                       set(VERB_FEATURE.values())):
        if feat not in known:
            bad.append(f'tools/lib/scene-features.py: feature "{feat}" names '
                       f"no scene in tools/scenes/ — no backend can stub it, "
                       f"so every rule about it is vacuous")


def check_rules_fire(scenes: dict, bad: list) -> None:
    """Every feature in the tables must be DERIVED FROM A VERB by some
    scene in the tree.

    A rule nobody has watched fire is the failure this whole module was
    written for, one level up: the CALL spelling became mandatory only
    after four milestones in which check-stubs could not possibly fail.
    If the clipboard rows stop matching anything — a verb renamed, a menu
    label re-cased, a scene retired — this says so at the commit that did
    it instead of going quiet and passing forever.
    """
    derived = {feat for feats in scenes.values()
               for feat, (n, _) in feats.items() if n > 0}
    for feat in sorted({f for f in ROLE_FEATURE.values() if f} |
                       set(VERB_FEATURE.values())):
        if feat not in derived:
            bad.append(f'tools/lib/scene-features.py: no scene\'s verbs derive '
                       f'"{feat}" — the rules for it match nothing in '
                       f"tools/scenes/, so they can only ever pass. Either a "
                       f"verb or label moved, or the feature is retired and "
                       f"the rows should go with it")


def check_backend_table(root: pathlib.Path, bad: list) -> None:
    """The backend roster here and in the two sibling helpers must agree.

    Five copies of this table now exist (check() in check-stubs.sh,
    the runner list in check-steps.sh, BACKENDS in hand-rolled-stubs.py,
    BACKENDS in stub-ledger.py, RUNNERS here). A sixth backend joining
    one and not the others is a hole nobody would see, so the three
    python copies at least pin each other.
    """
    for name in ("tools/lib/hand-rolled-stubs.py", "tools/lib/stub-ledger.py"):
        other = root / name
        if not other.exists():
            continue
        text = other.read_text()
        for _, backend, _ in RUNNERS:
            if f'"{backend}"' not in text:
                bad.append(f"{name}: {backend} is a backend scene-features.py "
                           f"checks but that file's BACKENDS never names — one "
                           f"roster grew and the other did not")


def load(root: pathlib.Path):
    scenes = {}
    for path in sorted((root / "tools/scenes").glob("*.steps")):
        scene = path.stem
        scenes[scene] = features(path.read_text(), scene)
    return scenes


def stubbed(root: pathlib.Path, backend: str, feature: str,
            platform: str) -> bool:
    path = root / backend
    if not path.exists():
        return False
    text = path.read_text()
    return any(s in text for s in stub_spellings(feature, platform))


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default=".")
    ap.add_argument("--mode", choices=("check", "exempt", "dump"),
                    default="check")
    args = ap.parse_args()
    root = pathlib.Path(args.root)

    scenes = load(root)
    bad: list = []
    if not scenes:
        print("check-steps: tools/scenes/ holds no .steps files — the "
              "verb-feature cross-check would pass vacuously", file=sys.stderr)
        return 1

    if args.mode == "dump":
        for scene, feats in scenes.items():
            for feat, (n, line) in sorted(feats.items()):
                print(f"{scene}\t{feat}\t{n}\t{line}")
        return 0

    if args.mode == "exempt":
        # The (runner, scene) pairs a depth stub legitimately holds open.
        for runner, backend, platform in RUNNERS:
            for scene, feats in scenes.items():
                if any(stubbed(root, backend, f, platform) for f in feats):
                    print(f"{runner}\t{scene}")
        return 0

    check_roles_table(root, bad)
    check_feature_names(root, scenes, bad)
    check_rules_fire(scenes, bad)
    check_backend_table(root, bad)

    for runner, backend, platform in RUNNERS:
        path = root / runner
        if not path.exists():
            bad.append(f"{runner}: missing — the cross-check cannot read a "
                       f"runner that is not there")
            continue
        text = path.read_text()
        for scene, feats in scenes.items():
            if not runs_scene(text, scene):
                continue
            for feat, (n, line) in sorted(feats.items()):
                if not stubbed(root, backend, feat, platform):
                    continue
                # The name-keyed pair is reported here TOO, even though
                # check-stubs owns it: when a stub goes back in, one
                # reading has to show the whole blast radius. Half the
                # answer in each of two gates is how the todos leg went
                # unnoticed in the first place.
                where = (f"tools/scenes/{scene}.steps:{n} needs it:\n    {line}"
                         if n else f"tools/scenes/{scene}.steps IS that scene")
                bad.append(
                    f'{runner} runs "{scene}" legs, but {backend} still '
                    f'stubs "{feat}" and {where}\n    Either the backend gets '
                    f'the feature, or this runner stops running "{scene}" '
                    f"until it does — a stubbed feature holds a scene's "
                    f"legs off EVERY runner whose backend refuses it, not "
                    f"just the scene named after it")

    for b in bad:
        print(f"check-steps: {b}", file=sys.stderr)
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
