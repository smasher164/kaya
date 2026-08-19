#!/usr/bin/env bash

kaya_flake="$(cd "$(dirname "$0")/.." && cat flake.nix flake.lock | shasum -a 256 | cut -c1-12)"
if [ "${KAYA_DEV_SHELL:-}" != "$kaya_flake" ]; then
    if [ -z "${KAYA_DEV_SHELL:-}" ]; then
        echo "$0: not inside the dev shell — run this under \`nix develop\`" >&2
    else
        echo "$0: dev shell is stale — the flake changed since it was entered; re-enter \`nix develop\`" >&2
    fi
    exit 1
fi
# THE ROLE VOCABULARY REACHES EVERY BACKEND. `MENU_ROLES`
# (crates/kaya/src/scene.rs) is one line, it is not in the spec hash,
# and adding an entry regenerates nothing, so the four sites are a
# matched set nobody is reminded of:
#
#   crates/kaya/src/gtk.rs        role_enabled / perform_role
#   crates/kaya/src/winui/mod.rs  role_enabled / perform_clipboard_role
#   swift/KayaSwiftUI.swift       kayaRoleEnabled / kayaPerformClipboardRole
#   android/…/KayaCompose.kt      kayaRoleEnabled / kayaPerformClipboardRole
#
# A role a backend does not know enables by default and falls through to
# plain action dispatch: the item looks live, does nothing, and reports
# a menu_activated the app never asked for.
#
# THIRD CLAUSE (docs/undo-plan.md D6): both Rust backends refresh
# enablement through a hard-coded role set, and an item outside it never
# has its enablement recomputed — on GTK that is an item nothing can
# activate. Written about the SETS THAT EXIST, because a backend with no
# such set has nothing to fall behind.
#
# `settings` is a PLACEMENT role — it moves an item into macOS's
# application menu and every other host leaves it alone — so it has no
# enablement question and no command to perform, and is exempt from the
# first two clauses. The exemption is guarded in turn: a placement role
# no backend names AT ALL fails.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1

SCENE=crates/kaya/src/scene.rs
GTK=crates/kaya/src/gtk.rs
WINUI=crates/kaya/src/winui/mod.rs
SWIFTUI=swift/KayaSwiftUI.swift
COMPOSE=android/kaya/src/main/kotlin/dev/kaya/KayaCompose.kt

check() {
    # $1..$5: scene.rs, gtk.rs, winui/mod.rs, KayaSwiftUI.swift,
    # KayaCompose.kt. Prints offenders on stdout, returns 1 on any.
    python3 - "$@" <<'PY'
import re
import sys

scene, gtk, winui, swiftui, compose = sys.argv[1:6]
read = lambda p: open(p, encoding="utf-8").read()
bad = []

# --- The vocabulary, from the one line that owns it. -----------------
text = read(scene)
m = re.search(r"MENU_ROLES\s*:\s*&\[&str\]\s*=\s*&\[([^\]]*)\]", text)
if not m:
    print(f"{scene}: no MENU_ROLES const — the vocabulary moved and this gate "
          "went vacuous")
    sys.exit(1)
roles = re.findall(r'"([a-z_]+)"', m.group(1))
if not roles:
    print(f"{scene}: MENU_ROLES is empty — nothing to check, which cannot be right")
    sys.exit(1)

# A PLACEMENT role names where an item goes, not what it does: no
# enablement question, no command to perform. Everything else is a
# GESTURE role — it acts on the focused widget and computes its own
# enablement — and gesture roles are what the four backends must know.
PLACEMENT = {"settings"}
gesture = [r for r in roles if r not in PLACEMENT]

# --- Reading a function body out of a backend. -----------------------
# Returns None when the anchor is gone, which the caller treats as a
# FAILURE: a gate that stops finding what it reads checks nothing.
def body(text, pattern, at=0, opener="{", closer="}"):
    m = re.compile(pattern).search(text, at)
    if not m:
        return None
    i = text.find(opener, m.end() - 1)
    if i < 0:
        return None
    return span(text, i, opener, closer)


def span(text, i, opener="{", closer="}"):
    """From the bracket at `i` to its match, comments and string
    literals skipped so a bracket inside either cannot end it early —
    which is not hypothetical: `matches!(item.role.as_str(), …)` closes
    a paren three tokens in, and a non-greedy regex reads the filter as
    ending there, naming no role and passing vacuously. The self-test
    below is what found that."""
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

# Each backend's PAIR: the enablement question and the perform path.
# Anchors are regexes, not literal names — a backend may SPLIT either
# half across several functions (the mac arm answers cut/copy/paste in
# kayaPerformClipboardRole and undo/redo in kayaPerformUndoRole), so
# each half is the UNION of the functions matching its anchor.
#
# The union does NOT prove the arm is reached; that is the scene's job
# (tools/scenes/undo.steps). This gate's job is the vocabulary.
BACKENDS = [
    (gtk, "role_enabled", r"\bfn +role_enabled\b",
          "perform_role", r"\bfn +perform[a-z_]*_role\b"),
    (winui, "role_enabled", r"\bfn +role_enabled\b",
            "perform_clipboard_role", r"\bfn +perform[a-z_]*_role\b"),
    (swiftui, "kayaRoleEnabled", r"\bfunc +kaya[A-Za-z]*RoleEnabled\b",
              "kayaPerformClipboardRole", r"\bfunc +kayaPerform[A-Za-z]*Role\b"),
    (compose, "kayaRoleEnabled", r"\bfun +kaya[A-Za-z]*RoleEnabled\b",
              "kayaPerformClipboardRole", r"\bfun +kayaPerform[A-Za-z]*Role\b"),
]

for path, ask_name, ask_pat, do_name, do_pat in BACKENDS:
    text = read(path)
    for name, pat, what in ((ask_name, ask_pat, "asks whether a role can act"),
                            (do_name, do_pat, "performs a role")):
        region = [body(text, pat, m.start()) for m in re.finditer(pat, text)]
        found = [fn for fn in region if fn is not None]
        if len(found) != len(region) or not found:
            bad.append(
                f"{path}: the function that {what} ({name}) is not where this gate "
                f"looks — the backend's shape moved and the check went vacuous")
            continue
        blob = "\n".join(found)
        for role in gesture:
            if f'"{role}"' in blob:
                continue
            bad.append(
                f'{path}: {name} never names the role "{role}", which IS in '
                f"MENU_ROLES ({scene}) — an unknown role enables by default and "
                f"falls through to plain action dispatch, so the item looks live, "
                f"does nothing, and reports a menu_activated the app never asked for")

# --- The hard-coded role SETS. ---------------------------------------
# A `matches!` naming at least one gesture role is a role FILTER, and it
# must be total. A backend with no such set is not failing this clause.
for path in (gtk, winui):
    text = read(path)
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
            f"{', '.join(named)} but not {', '.join(missing)} — the enablement "
            f"refresh skips every item whose role is outside that set, so those "
            f"roles' enablement is never recomputed, and where the platform's own "
            f"flag also refuses an activation (GTK's GAction, WinUI's disabled "
            f"item) the item cannot be activated by anything")

# --- The exemption is guarded too: a placement role no backend names
# anywhere is not exempt, it is unimplemented. -------------------------
for role in roles:
    if role not in PLACEMENT:
        continue
    # ROLE-SHAPED LINES ONLY, not a bare substring: the symbol
    # vocabulary put "settings" into every backend's symbol TABLE
    # (2026-08-16), a whole-file search counted those rows as the role
    # being named, and the settings-drop self-test could not fire.
    def names_role(p, role=role):
        for line in read(p).splitlines():
            if f'"{role}"' in line and re.search(r"(?i)role", line):
                return True
        return False
    if any(names_role(p) for p in (gtk, winui, swiftui, compose)):
        continue
    bad.append(
        f'{scene}: the placement role "{role}" is exempt from the enablement and '
        f"perform clauses (it names WHERE an item goes, not what it does) but no "
        f"backend names it at all — an exemption is not an implementation")

print("\n".join(bad))
sys.exit(1 if bad else 0)
PY
}

# THE GUARD GUARDS ITSELF, on DOCTORED COPIES OF THE REAL FILES rather
# than on synthetic samples (docs/traps.md, the wayland seat guard).
# Every perturbation prints its substitution count and is refused if it
# did not apply, and every refusal is checked for its REASON.
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

# <source> <regex> <replacement> <destination> -> substitution count
perturb() {
    python3 -c '
import re
import sys

text = open(sys.argv[1], encoding="utf-8").read()
out, n = re.subn(sys.argv[2], sys.argv[3], text, flags=re.S)
open(sys.argv[4], "w", encoding="utf-8").write(out)
print(n)
' "$@"
}

applied() { # count label
    if [ "$1" -ge 1 ]; then
        return 0
    fi
    echo "check-roles: SELF-TEST FAIL ($2 applied $1 times, want at least 1 —" \
        "an unchanged copy cannot prove the rule fires)" >&2
    exit 1
}

# <scene> <gtk> <winui> <swiftui> <compose> <want-fragment> <label>
refuses() {
    local out
    out="$(check "$1" "$2" "$3" "$4" "$5")" && {
        echo "check-roles: SELF-TEST FAIL ($7 passed)" >&2
        exit 1
    }
    case "$out" in
        *"$6"*) ;;
        *)
            echo "check-roles: SELF-TEST FAIL ($7 failed for another reason: $out)" >&2
            exit 1
            ;;
    esac
}

# THE ACCEPT DIRECTION IS ITS OWN SELF-TEST, deliberately not "the live
# tree passes": this gate is DESIGNED to be red across a milestone, with
# a role joining MENU_ROLES first and the four arms following. So it
# runs the REAL backends against a scene.rs holding only the vocabulary
# they have ALREADY fanned out to — decided BY THIS CHECKER, one role at
# a time, never by a second implementation of "is it there".

# Write a scene.rs whose MENU_ROLES holds exactly the named roles.
# <source scene.rs> <destination> <role>...
narrow() {
    python3 -c '
import re
import sys

src, dst, roles = sys.argv[1], sys.argv[2], sys.argv[3:]
text = open(src, encoding="utf-8").read()
m = re.search(r"MENU_ROLES\s*:\s*&\[&str\]\s*=\s*&\[([^\]]*)\]", text)
if not m:
    sys.exit("check-roles: SELF-TEST FAIL (no MENU_ROLES to narrow)")
body = ", ".join(chr(34) + r + chr(34) for r in roles)
open(dst, "w", encoding="utf-8").write(text[:m.start(1)] + body + text[m.end(1):])
' "$@"
}

vocabulary="$(python3 -c '
import re
import sys

text = open(sys.argv[1], encoding="utf-8").read()
m = re.search(r"MENU_ROLES\s*:\s*&\[&str\]\s*=\s*&\[([^\]]*)\]", text)
print(" ".join(re.findall(chr(34) + r"([a-z_]+)" + chr(34), m.group(1))))
' "$SCENE")"
settled="settings"
for role in $vocabulary; do
    [ "$role" = settings ] && continue
    narrow "$SCENE" "$T/scene-one.rs" settings "$role"
    if check "$T/scene-one.rs" "$GTK" "$WINUI" "$SWIFTUI" "$COMPOSE" >/dev/null; then
        settled="$settled $role"
    fi
done
echo "check-roles: fanned out everywhere: $settled" >&2
# Two is the floor: one role would make this a rule about `settings`,
# which is exempt from the clauses that matter.
if [ "$(printf '%s\n' $settled | wc -w)" -lt 3 ]; then
    echo "check-roles: SELF-TEST FAIL (only \"$settled\" have fanned out — the" \
        "accept direction would prove nothing)" >&2
    exit 1
fi
# shellcheck disable=SC2086
narrow "$SCENE" "$T/scene-settled.rs" $settled
if ! check "$T/scene-settled.rs" "$GTK" "$WINUI" "$SWIFTUI" "$COMPOSE" >/dev/null; then
    echo "check-roles: SELF-TEST FAIL (the fanned-out vocabulary was refused —" \
        "the rule refuses even what every backend implements):" >&2
    check "$T/scene-settled.rs" "$GTK" "$WINUI" "$SWIFTUI" "$COMPOSE" >&2
    exit 1
fi

# A ROLE THE BACKENDS DO NOT KNOW MUST FAIL IN ALL FOUR, proven on a
# role nobody has ever implemented.
hits="$(perturb "$T/scene-settled.rs" \
    '(MENU_ROLES\s*:\s*&\[&str\]\s*=\s*&\[[^\]]*)\]' '\1, "frobnicate"]' \
    "$T/scene-new-role.rs")"
applied "$hits" "the new-role perturbation"
for backend in "$GTK" "$WINUI" "$SWIFTUI" "$COMPOSE"; do
    refuses "$T/scene-new-role.rs" "$GTK" "$WINUI" "$SWIFTUI" "$COMPOSE" \
        "$backend: " "a role in MENU_ROLES that $backend never names"
done

# A BACKEND THAT LOSES A ROLE FROM ITS ENABLEMENT QUESTION MUST FAIL.
# Every mention goes, since a body that still names the role would
# satisfy the clause honestly.
drop_role() { # source role destination
    python3 -c '
import re
import sys

src, role, dst = sys.argv[1], sys.argv[2], sys.argv[3]
text = open(src, encoding="utf-8").read()
q = chr(34)
out, n = re.subn(q + role + q, q + role + "-was-dropped" + q, text)
open(dst, "w", encoding="utf-8").write(out)
print(n)
' "$1" "$2" "$3"
}

hits="$(drop_role "$GTK" paste "$T/gtk-no-paste.rs")"
applied "$hits" "the gtk paste-drop perturbation"
refuses "$T/scene-settled.rs" "$T/gtk-no-paste.rs" "$WINUI" "$SWIFTUI" "$COMPOSE" \
    'role_enabled never names the role "paste"' "a GTK backend that forgot paste"

hits="$(drop_role "$WINUI" cut "$T/winui-no-cut.rs")"
applied "$hits" "the winui cut-drop perturbation"
refuses "$T/scene-settled.rs" "$GTK" "$T/winui-no-cut.rs" "$SWIFTUI" "$COMPOSE" \
    'never names the role "cut"' "a WinUI backend that forgot cut"

hits="$(drop_role "$SWIFTUI" copy "$T/swiftui-no-copy.swift")"
applied "$hits" "the swiftui copy-drop perturbation"
refuses "$T/scene-settled.rs" "$GTK" "$WINUI" "$T/swiftui-no-copy.swift" "$COMPOSE" \
    'kayaRoleEnabled never names the role "copy"' "a SwiftUI arm that forgot copy"

hits="$(drop_role "$COMPOSE" paste "$T/compose-no-paste.kt")"
applied "$hits" "the compose paste-drop perturbation"
refuses "$T/scene-settled.rs" "$GTK" "$WINUI" "$SWIFTUI" "$T/compose-no-paste.kt" \
    'kayaPerformClipboardRole never names the role "paste"' \
    "a Compose arm that forgot paste"

# A HARD-CODED ROLE SET THAT FELL BEHIND MUST FAIL. The pattern must
# match gtk.rs's filter as it IS — when it lagged the fan-out the
# self-test refused an unchanged copy, which is exactly its job.
hits="$(perturb "$GTK" 'matches!\(item\.role\.as_str\(\), "cut" \| "copy" \| "paste" \| "undo" \| "redo"\)' \
    'matches!(item.role.as_str(), "cut" | "copy" | "paste" | "undo")' "$T/gtk-short-set.rs")"
applied "$hits" "the gtk role-set perturbation"
refuses "$T/scene-settled.rs" "$T/gtk-short-set.rs" "$WINUI" "$SWIFTUI" "$COMPOSE" \
    "a hard-coded role set names" "a GTK enablement filter that lost a role"

# AND A SITE THAT MOVED MUST FAIL RATHER THAN GO QUIET: an anchor this
# gate stops finding would report a clean bill about nothing.
hits="$(perturb "$WINUI" 'fn role_enabled\(core: &CoreState' 'fn role_can_act(core: &CoreState' \
    "$T/winui-moved.rs")"
applied "$hits" "the winui anchor-rename perturbation"
refuses "$T/scene-settled.rs" "$GTK" "$T/winui-moved.rs" "$SWIFTUI" "$COMPOSE" \
    "is not where this gate looks" "a WinUI backend whose enablement site moved"

# AND THE EXEMPTION IS NOT A HOLE: a placement role nobody names must
# fail even though it is exempt from the two per-backend clauses.
hits="$(drop_role "$SWIFTUI" settings "$T/swiftui-no-settings.swift")"
applied "$hits" "the settings-drop perturbation"
refuses "$T/scene-settled.rs" "$GTK" "$WINUI" "$T/swiftui-no-settings.swift" "$COMPOSE" \
    "an exemption is not an implementation" "a placement role no backend names"

if ! offenders="$(check "$SCENE" "$GTK" "$WINUI" "$SWIFTUI" "$COMPOSE")"; then
    echo "$offenders"
    echo "check-roles: FAIL"
    exit 1
fi
echo "check-roles: OK"
