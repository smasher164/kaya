#!/usr/bin/env bash

# Everything runs inside the dev shell: the flake pins every toolchain
# (rust + cross targets, swiftc, ffmpeg, the android sdk). Running
# against anything else is an error, not something to paper over — and
# a shell entered before the flake last changed is just as much a
# bystander toolchain, so the marker carries the fingerprint of
# flake.nix+flake.lock the shell was actually built from.
kaya_flake="$(cd "$(dirname "$0")/.." && cat flake.nix flake.lock | shasum -a 256 | cut -c1-12)"
if [ "${KAYA_DEV_SHELL:-}" != "$kaya_flake" ]; then
    if [ -z "${KAYA_DEV_SHELL:-}" ]; then
        echo "$0: not inside the dev shell — run this under \`nix develop\`" >&2
    else
        echo "$0: dev shell is stale — the flake changed since it was entered; re-enter \`nix develop\`" >&2
    fi
    exit 1
fi
# THE ROLE VOCABULARY REACHES EVERY BACKEND, or the role is a menu item
# that does nothing and says nothing.
#
# `MENU_ROLES` (crates/kaya/src/scene.rs) is the closed vocabulary the
# root validates an authored role against. It is ONE LINE, it is not in
# the spec hash, and adding an entry to it regenerates nothing — so
# before this gate existed a new role could ship with the root accepting
# it and all four backends ignoring it. The four sites are a matched set
# nobody is reminded of:
#
#   crates/kaya/src/gtk.rs        role_enabled / perform_role
#   crates/kaya/src/winui/mod.rs  role_enabled / perform_clipboard_role
#   swift/KayaSwiftUI.swift       kayaRoleEnabled / kayaPerformClipboardRole
#   android/…/KayaCompose.kt      kayaRoleEnabled / kayaPerformClipboardRole
#
# AND THE FAILURE IS SILENT IN THE WORST WAY. A role a backend does not
# know answers `true` from its enablement default and falls through its
# perform switch to ordinary action dispatch: the item looks live, the
# user picks it, the platform command never runs, and the guest gets a
# `menu_activated` for a command it never wrote a handler for. That is
# the exact shape the clipboard slice hit from the other side — a paste
# leg failing SILENTLY because `performActionForItem` leaves a disabled
# item inert (docs/traps.md) — so the rule is stated once, here, for
# every role that will ever exist.
#
# THE THIRD CLAUSE IS THE ONE D6 NAMED (docs/undo-plan.md): both Rust
# backends refresh role enablement through a HARD-CODED role set —
# `matches!(item.role.as_str(), "cut" | "copy" | "paste")` — and an item
# whose role is not in that set never has its enablement recomputed at
# all. On GTK the GAction's enabled flag is also what refuses a harness
# activation, so a missing role there is a menu item that cannot be
# activated by anything. Any such set must therefore name EVERY role.
# The two interpreters carry no such set (their refresh loops are
# role-agnostic and delegate to kayaRoleEnabled), which is why the
# clause is written about the SETS THAT EXIST rather than about a site
# each backend must have: a backend with no hard-coded set has nothing
# to fall behind.
#
# `settings` is EXEMPT from the first two clauses, and the exemption is
# a statement rather than a hole: it is a PLACEMENT role — it moves an
# item into macOS's application menu (KayaSwiftUI.swift's catalog build)
# and every other host leaves the item where the app put it — so it has
# no enablement question and no command to perform. The exemption is
# guarded in turn: a placement role no backend names AT ALL is an
# unimplemented role wearing an exemption, and fails.
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
# Brace matching, with comments and string literals skipped so a `{` in
# either cannot end a body early. Returns None when the anchor is gone,
# which is a FAILURE rather than a pass: a gate that stops finding what
# it reads reports a clean bill about nothing.
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
# The anchors are regexes rather than literal names for two reasons. A
# rename that keeps the shape (perform_role -> perform_clipboard_role,
# both spellings already in the tree) must not read as a missing site,
# while a rename that loses the shape must — and a backend is free to
# SPLIT either half across several functions, which is not a hedge but
# the tree as it is: the mac arm answers cut/copy/paste in
# kayaPerformClipboardRole and undo/redo in kayaPerformUndoRole, because
# an undo is not a clipboard command. So each half is the UNION of the
# functions matching its anchor, and a role has to be named somewhere in
# that union.
#
# What the union does NOT prove is that the arm is reached — a perform
# function nobody calls satisfies this. That is the SCENE's job
# (tools/scenes/undo.steps drives Edit>Undo through the real chrome);
# this gate's job is the vocabulary, which is what silently falls behind.
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

# --- The hard-coded role SETS (D6's four silent-failure sites). ------
# A `matches!` naming at least one gesture role is a role FILTER: the
# enablement refresh skips every item whose role is not in it. Such a
# set must be total. A backend with no such set is not failing this
# clause — it has no set to fall behind — and the two interpreters are
# deliberately in that position.
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

# --- The exemption is guarded too. -----------------------------------
# A placement role that no backend names anywhere is not exempt, it is
# unimplemented — and the exemption above would be hiding it.
for role in roles:
    if role not in PLACEMENT:
        continue
    if any(f'"{role}"' in read(p) for p in (gtk, winui, swiftui, compose)):
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
# than on synthetic samples: a fixture only ever proves the pattern
# matches the fixture, which is how the wayland seat guard passed
# VACUOUSLY TWICE (docs/traps.md). Every perturbation prints its
# substitution count and is refused if it did not apply — an unchanged
# copy is a FAILED self-test, not a passed one — and every refusal is
# checked for its REASON, since an exit code alone is satisfied by any
# unrelated finding.
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

# THE ACCEPT DIRECTION IS ITS OWN SELF-TEST HERE, and deliberately not
# "the live tree passes". This gate is DESIGNED to be red across a
# milestone: a role joins MENU_ROLES first and the four arms follow
# (docs/undo-plan.md D6, the clipboard hold-open pattern), so the live
# tree is legitimately failing while the fan-out is open. A rule that
# refused everything would then be indistinguishable from the hold-open.
#
# So the accept direction runs the REAL backends against a scene.rs
# holding the vocabulary the backends have ALREADY fanned out to. Which
# roles those are is decided BY THIS CHECKER, one role at a time, rather
# than by a second implementation of "is it there": the first cut asked
# whether the file contained the string anywhere, and `depth_stub("undo")`
# answered yes in three backends that implement nothing — a self-test
# that would have called the milestone finished.

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
# Two is the floor: with one role the accept direction would be a rule
# about `settings`, which is exempt from the clauses that matter.
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

# A ROLE THE BACKENDS DO NOT KNOW MUST FAIL IN ALL FOUR — the case this
# gate exists for, proven on a role nobody has ever implemented rather
# than on the milestone's own.
hits="$(perturb "$T/scene-settled.rs" \
    '(MENU_ROLES\s*:\s*&\[&str\]\s*=\s*&\[[^\]]*)\]' '\1, "frobnicate"]' \
    "$T/scene-new-role.rs")"
applied "$hits" "the new-role perturbation"
for backend in "$GTK" "$WINUI" "$SWIFTUI" "$COMPOSE"; do
    refuses "$T/scene-new-role.rs" "$GTK" "$WINUI" "$SWIFTUI" "$COMPOSE" \
        "$backend: " "a role in MENU_ROLES that $backend never names"
done

# A BACKEND THAT LOSES A ROLE FROM ITS ENABLEMENT QUESTION MUST FAIL.
# The arm head is what moves — that is how a role is dropped in
# practice — and every mention inside the function goes with it, since a
# body that still names the role would satisfy the clause honestly.
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

# A HARD-CODED ROLE SET THAT FELL BEHIND MUST FAIL — the recorded site
# (gtk.rs's refresh filter), perturbed by dropping one role from the set
# alone, everything else about the backend intact.
# The set as the FAN-OUT left it (undo/redo joined 2026-08-04); the
# perturbation drops one role from the full set so the shape matches
# the file as it IS — the self-test refused an unchanged copy when
# this pattern lagged the fan-out, which is exactly its job.
hits="$(perturb "$GTK" 'matches!\(item\.role\.as_str\(\), "cut" \| "copy" \| "paste" \| "undo" \| "redo"\)' \
    'matches!(item.role.as_str(), "cut" | "copy" | "paste" | "undo")' "$T/gtk-short-set.rs")"
applied "$hits" "the gtk role-set perturbation"
refuses "$T/scene-settled.rs" "$T/gtk-short-set.rs" "$WINUI" "$SWIFTUI" "$COMPOSE" \
    "a hard-coded role set names" "a GTK enablement filter that lost a role"

# AND A SITE THAT MOVED MUST FAIL RATHER THAN GO QUIET, the vacuity
# half: this gate reads four backends by anchor, and an anchor it stops
# finding would otherwise report a clean bill about nothing.
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
