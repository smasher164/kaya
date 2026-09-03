#!/usr/bin/env python3
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent / "lib"))
from kaya_gate import Gate, dev_shell_or_die

dev_shell_or_die()

# THE ROLE VOCABULARY REACHES EVERY BACKEND. `MENU_ROLES`
# (crates/kaya/src/scene.rs) is one line, it is not in the spec hash, and
# adding an entry regenerates nothing, so the four backends are a matched
# set nobody is reminded of. RED BY DESIGN across a fan-out.
#
# THIRD CLAUSE (docs/undo-plan.md D6): both Rust backends refresh
# enablement through a hard-coded role set, and an item outside it never
# has its enablement recomputed. Written about the SETS THAT EXIST — a
# backend with no such set has nothing to fall behind.

import re

SCENE = "crates/kaya/src/scene.rs"
GTK = "crates/kaya/src/gtk.rs"
WINUI = "crates/kaya/src/winui/mod.rs"
SWIFTUI = "swift/KayaSwiftUI.swift"
COMPOSE = "android/kaya/src/main/kotlin/dev/kaya/KayaCompose.kt"

gate = Gate("check-roles")


def span(text, i, opener="{", closer="}"):
    """From the bracket at `i` to its match, comments and string literals
    skipped so a bracket inside either cannot end it early:
    `matches!(item.role.as_str(), …)` closes a paren three tokens in, and a
    non-greedy regex reads the filter as ending there and passes
    vacuously."""
    depth, j, n = 0, i, len(text)
    while j < n:
        c = text[j]
        if c == "/" and j + 1 < n and text[j + 1] == "/":
            j = text.find("\n", j)
            if j < 0:
                break
            continue
        if c == "/" and j + 1 < n and text[j + 1] == "*":
            j = text.find("*/", j)
            if j < 0:
                break
            j += 2
            continue
        if c == '"':
            j += 1
            while j < n and text[j] != '"':
                j += 2 if text[j] == "\\" else 1
            j += 1
            continue
        if c == opener:
            depth += 1
        elif c == closer:
            depth -= 1
            if depth == 0:
                return text[i:j + 1]
        j += 1
    return None


def braced(text, pattern, at=0, opener="{", closer="}"):
    # Returns None when the anchor is gone, which the caller treats as a
    # FAILURE: a gate that stops finding what it reads checks nothing.
    m = re.compile(pattern).search(text, at)
    if not m:
        return None
    i = text.find(opener, m.end() - 1)
    if i < 0:
        return None
    return span(text, i, opener, closer)


# A PLACEMENT role names where an item goes, not what it does: no
# enablement question, no command to perform, so it is exempt from the
# first two clauses (and guarded instead by the last one). Everything else
# is a GESTURE role, which every backend must know.
PLACEMENT = {"settings"}

# Each backend's PAIR: the enablement question and the perform path.
# Anchors are regexes because a backend may SPLIT either half across
# several functions, so each half is the UNION of the functions matching
# its anchor. The union does NOT prove the arm is reached — that is
# tools/scenes/undo.steps' job; this gate's job is the vocabulary.
BACKENDS = [
    (GTK, "role_enabled", r"\bfn +role_enabled\b",
     "perform_role", r"\bfn +perform[a-z_]*_role\b"),
    (WINUI, "role_enabled", r"\bfn +role_enabled\b",
     "perform_clipboard_role", r"\bfn +perform[a-z_]*_role\b"),
    (SWIFTUI, "kayaRoleEnabled", r"\bfunc +kaya[A-Za-z]*RoleEnabled\b",
     "kayaPerformClipboardRole", r"\bfunc +kayaPerform[A-Za-z]*Role\b"),
    (COMPOSE, "kayaRoleEnabled", r"\bfun +kaya[A-Za-z]*RoleEnabled\b",
     "kayaPerformClipboardRole", r"\bfun +kayaPerform[A-Za-z]*Role\b"),
]


def check(texts):
    """texts: {site: text}. ('refused', msg) | ('bad', lines) |
    ('ok', None)."""
    bad = []

    # --- The vocabulary, from the one line that owns it. -------------
    text = texts[SCENE]
    m = re.search(r"MENU_ROLES\s*:\s*&\[&str\]\s*=\s*&\[([^\]]*)\]", text)
    if not m:
        return "refused", (f"{SCENE}: no MENU_ROLES const — the vocabulary "
                           f"moved and this gate went vacuous")
    roles = re.findall(r'"([a-z_]+)"', m.group(1))
    if not roles:
        return "refused", (f"{SCENE}: MENU_ROLES is empty — nothing to "
                           f"check, which cannot be right")
    gesture = [r for r in roles if r not in PLACEMENT]

    for path, ask_name, ask_pat, do_name, do_pat in BACKENDS:
        text = texts[path]
        for name, pat, what in (
                (ask_name, ask_pat, "asks whether a role can act"),
                (do_name, do_pat, "performs a role")):
            region = [braced(text, pat, m.start())
                      for m in re.finditer(pat, text)]
            found = [fn for fn in region if fn is not None]
            if len(found) != len(region) or not found:
                bad.append(
                    f"{path}: the function that {what} ({name}) is not "
                    f"where this gate looks — the backend's shape moved "
                    f"and the check went vacuous")
                continue
            blob = "\n".join(found)
            for role in gesture:
                if f'"{role}"' in blob:
                    continue
                bad.append(
                    f'{path}: {name} never names the role "{role}", which '
                    f"IS in MENU_ROLES ({SCENE}) — an unknown role enables "
                    f"by default and falls through to plain action "
                    f"dispatch, so the item looks live, does nothing, and "
                    f"reports a menu_activated the app never asked for")

    # --- The hard-coded role SETS. -----------------------------------
    # A `matches!` naming at least one gesture role is a role FILTER and
    # must be total. A backend with no such set is not failing this clause.
    for path in (GTK, WINUI):
        text = texts[path]
        for m in re.finditer(r"matches!\(", text):
            expr = span(text, m.end() - 1, "(", ")")
            if expr is None:
                continue
            named = [r for r in gesture if f'"{r}"' in expr]
            if not named:
                continue
            missing = [r for r in gesture if f'"{r}"' not in expr]
            if not missing:
                continue
            line = text.count("\n", 0, m.start()) + 1
            bad.append(
                f"{path}:{line}: a hard-coded role set names "
                f"{', '.join(named)} but not {', '.join(missing)} — the "
                f"enablement refresh skips every item whose role is "
                f"outside that set, so those roles' enablement is never "
                f"recomputed, and where the platform's own flag also "
                f"refuses an activation (GTK's GAction, WinUI's disabled "
                f"item) the item cannot be activated by anything")

    # --- The exemption is guarded too: a placement role no backend
    # names anywhere is not exempt, it is unimplemented. ---------------
    for role in roles:
        if role not in PLACEMENT:
            continue
        # ROLE-SHAPED LINES ONLY, not a bare substring: "settings" is
        # also a row in every backend's symbol TABLE, and a whole-file
        # search counted those as the role being named.
        def names_role(p, role=role):
            for line in texts[p].splitlines():
                if f'"{role}"' in line and re.search(r"(?i)role", line):
                    return True
            return False
        if any(names_role(p) for p in (GTK, WINUI, SWIFTUI, COMPOSE)):
            continue
        bad.append(
            f'{SCENE}: the placement role "{role}" is exempt from the '
            f"enablement and perform clauses (it names WHERE an item "
            f"goes, not what it does) but no backend names it at all — "
            f"an exemption is not an implementation")

    if bad:
        return "bad", bad
    return "ok", None


REAL = {p: gate.read(p) for p in (SCENE, GTK, WINUI, SWIFTUI, COMPOSE)}


# The self-tests doctor COPIES OF THE REAL FILES, and each refusal is
# checked for its REASON (CLAUDE.md's watch-the-negative-fail rule).
def refuses(texts, fragment, label):
    verdict, payload = check(texts)
    if verdict == "ok":
        print(f"check-roles: SELF-TEST FAIL ({label} passed)",
              file=sys.stderr)
        sys.exit(1)
    out = payload if verdict == "refused" else "\n".join(payload)
    if fragment not in out:
        print(f"check-roles: SELF-TEST FAIL ({label} failed for another "
              f"reason: {out})", file=sys.stderr)
        sys.exit(1)


def drop_role(label, site_text, role):
    """Every quoted mention goes: a body that still names the role
    elsewhere would satisfy the clause honestly."""
    want = site_text.count(f'"{role}"')
    if want < 1:
        print(f"check-roles: SELF-TEST FAIL ({label} applied 0 times, "
              f"want at least 1 — an unchanged copy cannot prove the rule "
              f"fires)", file=sys.stderr)
        sys.exit(1)
    return gate.doctor(label, site_text, f'"{role}"',
                       f'"{role}-was-dropped"', want=want)


def narrow(scene_text, roles):
    """A scene.rs whose MENU_ROLES holds exactly the named roles."""
    m = re.search(r"MENU_ROLES\s*:\s*&\[&str\]\s*=\s*&\[([^\]]*)\]",
                  scene_text)
    if not m:
        print("check-roles: SELF-TEST FAIL (no MENU_ROLES to narrow)",
              file=sys.stderr)
        sys.exit(1)
    body = ", ".join(f'"{r}"' for r in roles)
    return scene_text[:m.start(1)] + body + scene_text[m.end(1):]


# THE ACCEPT DIRECTION IS ITS OWN SELF-TEST, deliberately not "the live
# tree passes": this gate is DESIGNED to be red across a fan-out. So it
# runs the REAL backends against a scene.rs holding only the vocabulary
# they have ALREADY reached — decided BY THIS CHECKER, one role at a time,
# never by a second implementation of "is it there".
m = re.search(r"MENU_ROLES\s*:\s*&\[&str\]\s*=\s*&\[([^\]]*)\]",
              REAL[SCENE])
vocabulary = re.findall(r'"([a-z_]+)"', m.group(1)) if m else []
settled = ["settings"]
for role in vocabulary:
    if role == "settings":
        continue
    one = narrow(REAL[SCENE], ["settings", role])
    if check({**REAL, SCENE: one})[0] == "ok":
        settled.append(role)
print(f"check-roles: fanned out everywhere: {' '.join(settled)}",
      file=sys.stderr)
# Two is the floor: one role would make this a rule about `settings`,
# which is exempt from the clauses that matter.
if len(settled) < 3:
    print(f"check-roles: SELF-TEST FAIL (only \"{' '.join(settled)}\" "
          f"have fanned out — the accept direction would prove nothing)",
          file=sys.stderr)
    sys.exit(1)
scene_settled = narrow(REAL[SCENE], settled)
verdict, payload = check({**REAL, SCENE: scene_settled})
if verdict != "ok":
    print("check-roles: SELF-TEST FAIL (the fanned-out vocabulary was "
          "refused — the rule refuses even what every backend "
          "implements):", file=sys.stderr)
    out = payload if verdict == "refused" else "\n".join(payload)
    print(out, file=sys.stderr)
    sys.exit(1)

SETTLED = {**REAL, SCENE: scene_settled}

# A ROLE THE BACKENDS DO NOT KNOW MUST FAIL IN ALL FOUR, proven on a
# role nobody has ever implemented.
new_role = gate.doctor(
    "the new-role perturbation", scene_settled,
    r"(MENU_ROLES\s*:\s*&\[&str\]\s*=\s*&\[[^\]]*)\]",
    r'\1, "frobnicate"]', flags=re.S)
for backend in (GTK, WINUI, SWIFTUI, COMPOSE):
    refuses({**SETTLED, SCENE: new_role}, f"{backend}: ",
            f"a role in MENU_ROLES that {backend} never names")

# A BACKEND THAT LOSES A ROLE FROM ITS ENABLEMENT QUESTION MUST FAIL.
refuses({**SETTLED, GTK: drop_role("the gtk paste-drop perturbation",
                                   REAL[GTK], "paste")},
        'role_enabled never names the role "paste"',
        "a GTK backend that forgot paste")
refuses({**SETTLED, WINUI: drop_role("the winui cut-drop perturbation",
                                     REAL[WINUI], "cut")},
        'never names the role "cut"', "a WinUI backend that forgot cut")
refuses({**SETTLED, SWIFTUI: drop_role("the swiftui copy-drop perturbation",
                                       REAL[SWIFTUI], "copy")},
        'kayaRoleEnabled never names the role "copy"',
        "a SwiftUI arm that forgot copy")
refuses({**SETTLED, COMPOSE: drop_role("the compose paste-drop "
                                       "perturbation", REAL[COMPOSE],
                                       "paste")},
        'kayaPerformClipboardRole never names the role "paste"',
        "a Compose arm that forgot paste")

# A HARD-CODED ROLE SET THAT FELL BEHIND MUST FAIL. The pattern must
# match gtk.rs's filter as it IS.
short_set = gate.doctor(
    "the gtk role-set perturbation", REAL[GTK],
    r'matches!\(item\.role\.as_str\(\), "cut" \| "copy" \| "paste" \| '
    r'"undo" \| "redo"\)',
    'matches!(item.role.as_str(), "cut" | "copy" | "paste" | "undo")',
    flags=re.S)
refuses({**SETTLED, GTK: short_set}, "a hard-coded role set names",
        "a GTK enablement filter that lost a role")

# AND A SITE THAT MOVED MUST FAIL RATHER THAN GO QUIET: an anchor this
# gate stops finding would report a clean bill about nothing.
moved = gate.doctor(
    "the winui anchor-rename perturbation", REAL[WINUI],
    r"fn role_enabled\(core: &CoreState",
    "fn role_can_act(core: &CoreState", flags=re.S)
refuses({**SETTLED, WINUI: moved}, "is not where this gate looks",
        "a WinUI backend whose enablement site moved")

# AND THE EXEMPTION IS NOT A HOLE: a placement role nobody names must
# fail even though it is exempt from the two per-backend clauses.
refuses({**SETTLED,
         SWIFTUI: drop_role("the settings-drop perturbation",
                            REAL[SWIFTUI], "settings")},
        "an exemption is not an implementation",
        "a placement role no backend names")

verdict, payload = check(REAL)
if verdict != "ok":
    out = payload if verdict == "refused" else "\n".join(payload)
    print(out)
    print("check-roles: FAIL")
    sys.exit(1)
print("check-roles: OK")
