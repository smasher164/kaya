#!/usr/bin/env bash

# Dev-shell guard; the marker is the flake fingerprint (CLAUDE.md).
kaya_flake="$(cd "$(dirname "$0")/.." && cat flake.nix flake.lock | shasum -a 256 | cut -c1-12)"
if [ "${KAYA_DEV_SHELL:-}" != "$kaya_flake" ]; then
    if [ -z "${KAYA_DEV_SHELL:-}" ]; then
        echo "$0: not inside the dev shell — run this under \`nix develop\`" >&2
    else
        echo "$0: dev shell is stale — the flake changed since it was entered; re-enter \`nix develop\`" >&2
    fi
    exit 1
fi
# Lint the shared .steps scripts: container-kind targets index widgets
# by CREATION order, which legitimately differs per language
# (statement-shaped construction is parent-first, expression trees are
# children-first — argument evaluation forces it). Leaf kinds are safe
# (body order is screen order everywhere); containers are targetable
# only through the blessed pattern — column#0, the For container that
# the root-is-a-row convention keeps unique. Anything else would name
# different widgets on different platforms, so it dies here, not in
# one platform's leg.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1

lint() {
    # $1: a steps file (or - for stdin). Prints offenders, returns 1 on any.
    python3 -c '
import re
import sys

path = sys.argv[1]
text = sys.stdin.read() if path == "-" else open(path).read()
bad = []
for lineno, line in enumerate(text.splitlines(), 1):
    if line.lstrip().startswith("#"):
        continue
    for kind, index in re.findall(r"\b(row|column|scroll|grid)#(\d+)\b", line):
        # Index 0 of a container kind is the blessed pattern, on one
        # convention: the scene keeps exactly one widget of that
        # kind, so creation order cannot enter. column#0 is the For
        # container in milestone2 (root-is-a-row keeps it unique);
        # row#0 carries the horizontal grow contract in the grow
        # scene; scroll#0 the one scroll viewport in the scroll scene.
        if index == "0":
            continue
        bad.append(f"{path}:{lineno}: {kind}#{index}")
print("\n".join(bad))
sys.exit(1 if bad else 0)
' "$1"
}

# The guard guards itself: a known-bad sample must fail, or the lint
# is a false green.
if printf 'click row#1\nexpect column#2 "x"\n' | lint - >/dev/null; then
    echo "check-steps: SELF-TEST FAIL (bad sample passed)" >&2
    exit 1
fi

status=0
for f in tools/scenes/*.steps; do
    out="$(lint "$f")" || {
        echo "check-steps: $f targets a container by creation index — only column#0/row#0 (unique-by-convention containers) are cross-language stable:" >&2
        echo "$out" >&2
        status=1
    }
done

# The opening lint: a script must OPEN with an observation. Expects are
# bounded retries (harness.rs POLL_DEADLINE) and the FIRST one doubles
# as the scene-ready wait, so a script that opens with an action races
# the mount on every platform at once.
opening_lint() {
    python3 -c '
import sys

path = sys.argv[1]
text = sys.stdin.read() if path == "-" else open(path).read()
for line in text.splitlines():
    stripped = line.strip()
    if not stripped or stripped.startswith("#"):
        continue
    first = stripped.split(";")[0].split()
    verb = first[0] if first else ""
    if verb.startswith("expect"):
        sys.exit(0)
    print(f"{path}: opens with {verb!r} — the first step must be an "
          "expect (its bounded retry is the scene-ready wait)")
    sys.exit(1)
sys.exit(0)
' "$1"
}

# The guard guards itself.
if printf 'click button#0\nexpect label#0 "x"\n' | opening_lint - >/dev/null; then
    echo "check-steps: SELF-TEST FAIL (action-first script passed)" >&2
    exit 1
fi

for f in tools/scenes/*.steps; do
    out="$(opening_lint "$f")" || {
        echo "check-steps: $f must open with an expect (the retry is the scene-ready wait):" >&2
        echo "$out" >&2
        status=1
    }
done

# WHICH WIDTHS AN expect_split MAY SAMPLE. The backends' platform
# components disagree about where one pane becomes two — GNOME collapses
# below 400sp, Material wants 840dp, TwoPaneView sits between — so a
# width inside that band is legitimately one pane on one platform and
# two on another, and the scripts are compared byte-for-byte.
#
# THE TWO FORMS ARE POLICED DIFFERENTLY, by the claim each makes. A
# LITERAL (`expect_split "regular/split"`) names WHICH arm ran, so it
# needs a width the file itself set, outside the band. The BARE form
# asserts the invariant and is legal at a width the file never names —
# the only spelling a phone or tablet lane can run. A width the file
# DOES name must clear the band in either form: in there the invariant
# is not vacuous, it is WRONG.
split_width_lint() {
    python3 -c '
import re
import sys

# The band where the platforms legitimately disagree.
LOW, HIGH = 400, 840

path = sys.argv[1]
text = sys.stdin.read() if path == "-" else open(path).read()
width = None
bad = []
for n, line in enumerate(text.splitlines(), 1):
    s = line.strip()
    if not s or s.startswith("#"):
        continue
    parts = s.split()
    if parts[0] == "resize_window" and len(parts) > 1:
        m = re.match(r"([0-9]+)x([0-9]+)$", parts[1])
        width = int(m.group(1)) if m else None
    elif parts[0] == "expect_split":
        bare = len(parts) == 1
        if width is None:
            if not bare:
                bad.append(f"{path}:{n}: expect_split names a presentation with no "
                           "preceding resize_window; a literal is a claim about the "
                           "width, and a default window width is host-dependent. "
                           "The bare form asserts the invariant instead and may run "
                           "at a width the file never names.")
        elif LOW <= width < HIGH:
            bad.append(f"{path}:{n}: expect_split at width {width}, inside the "
                       f"{LOW}..{HIGH} band where platforms disagree "
                       "(GNOME collapses below 400sp, Material wants 840dp). "
                       "Sample a width every platform agrees on.")
for b in bad:
    print(b)
sys.exit(1 if bad else 0)
' "$1"
}

# The guard guards itself, all four directions: a width in the band
# must be caught in either form, a LITERAL at an unnamed width must be
# caught, the widths the split scene actually uses must not be, and the
# bare form at an unnamed width — the whole listdetail scene — must not
# be.
if printf 'expect_entries 0\nresize_window 500x600\nexpect_split "regular/split"\n' \
    | split_width_lint - >/dev/null; then
    echo "check-steps: SELF-TEST FAIL (expect_split inside the band passed)" >&2
    exit 1
fi
if printf 'expect_entries 0\nresize_window 500x600\nexpect_split\n' \
    | split_width_lint - >/dev/null; then
    echo "check-steps: SELF-TEST FAIL (bare expect_split inside the band passed)" >&2
    exit 1
fi
if printf 'expect_entries 0\nexpect_split "regular/split"\n' \
    | split_width_lint - >/dev/null; then
    echo "check-steps: SELF-TEST FAIL (literal expect_split at an unnamed width passed)" >&2
    exit 1
fi
if ! printf 'expect_entries 0\nresize_window 900x600\nexpect_split "regular/split"\nresize_window 360x600\nexpect_split "compact/stacked"\n' \
    | split_width_lint - >/dev/null; then
    echo "check-steps: SELF-TEST FAIL (agreed widths rejected)" >&2
    exit 1
fi
if ! printf 'expect_entries 0\nexpect_split\nclick button#0\nexpect_split\n' \
    | split_width_lint - >/dev/null; then
    echo "check-steps: SELF-TEST FAIL (bare expect_split at an unnamed width rejected)" >&2
    exit 1
fi

for f in tools/scenes/*.steps; do
    out="$(split_width_lint "$f")" || {
        echo "check-steps: $f samples a width where platforms disagree:" >&2
        echo "$out" >&2
        status=1
    }
done

# WHICH WIDTHS AN expect_panes MAY SAMPLE — the split rule with the
# THREE-pane band, which is wider: Material wants 1200dp for three
# panes, GNOME 860sp (1075px at large text), and WinUI's nest needs the
# outer AND the leftover above 641. The two forms are policed exactly
# as expect_split's are, and for the same reasons; the middle rung is
# deliberately unsampleable by a shared scene — each lane's own gate
# holds its ladder (tools/check-pane-ladder.sh on macOS).
panes_width_lint() {
    python3 -c '
import re
import sys

# The band where the platforms legitimately disagree about THREE panes.
LOW, HIGH = 400, 1400

path = sys.argv[1]
text = sys.stdin.read() if path == "-" else open(path).read()
width = None
bad = []
for n, line in enumerate(text.splitlines(), 1):
    s = line.strip()
    if not s or s.startswith("#"):
        continue
    parts = s.split()
    if parts[0] == "resize_window" and len(parts) > 1:
        m = re.match(r"([0-9]+)x([0-9]+)$", parts[1])
        width = int(m.group(1)) if m else None
    elif parts[0] == "expect_panes":
        bare = len(parts) == 1
        if width is None:
            if not bare:
                bad.append(f"{path}:{n}: expect_panes names positions with no "
                           "preceding resize_window; a literal is a claim about the "
                           "width, and a default window width is host-dependent. "
                           "The bare form asserts the invariant instead and may run "
                           "at a width the file never names.")
        elif LOW <= width < HIGH:
            bad.append(f"{path}:{n}: expect_panes at width {width}, inside the "
                       f"{LOW}..{HIGH} band where platforms disagree about "
                       "three panes (Material wants 1200dp, GNOME 1075px at "
                       "large text, the WinUI nest more still). "
                       "Sample a width every platform agrees on.")
for b in bad:
    print(b)
sys.exit(1 if bad else 0)
' "$1"
}

# The guard guards itself, the same four directions as the split lint.
if printf 'expect_entries 0\nresize_window 700x600\nexpect_panes "regular/1,2"\n' \
    | panes_width_lint - >/dev/null; then
    echo "check-steps: SELF-TEST FAIL (expect_panes inside the band passed)" >&2
    exit 1
fi
if printf 'expect_entries 0\nresize_window 700x600\nexpect_panes\n' \
    | panes_width_lint - >/dev/null; then
    echo "check-steps: SELF-TEST FAIL (bare expect_panes inside the band passed)" >&2
    exit 1
fi
if printf 'expect_entries 0\nexpect_panes "regular/0,1,2"\n' \
    | panes_width_lint - >/dev/null; then
    echo "check-steps: SELF-TEST FAIL (literal expect_panes at an unnamed width passed)" >&2
    exit 1
fi
if ! printf 'expect_entries 0\nexpect_panes\nresize_window 1400x800\nexpect_panes "regular/0,1,2"\nresize_window 360x600\nexpect_panes "compact/2"\n' \
    | panes_width_lint - >/dev/null; then
    echo "check-steps: SELF-TEST FAIL (agreed panes widths rejected)" >&2
    exit 1
fi

for f in tools/scenes/*.steps; do
    out="$(panes_width_lint "$f")" || {
        echo "check-steps: $f samples a width where platforms disagree about three panes:" >&2
        echo "$out" >&2
        status=1
    }
done

# THE LINUX STAGES MUST FIT EVERY RESIZE, and the lane's text scale
# must stay pinned. A resize wider than the Xvfb screen or the sway
# output leaves the window at whatever the compositor allowed — the
# breakpoints then legitimately show fewer panes and the leg reads as a
# backend bug rather than a small stage. And libadwaita's sp unit
# scales with the text factor (860sp is 1075px at large text), so a
# byte-frozen width is reproducible only while the factor is 1.0 —
# run-suites.sh unsets the env overrides, and this clause keeps both
# facts from quietly rotting (docs/multicolumn-plan.md D4).
linux_stage_lint() {
    python3 -c '
import re
import sys

runner = open("tools/linux/run-suites.sh").read()
stages = [int(m.group(1)) for m in re.finditer(r"-screen 0 (\d+)x\d+x24", runner)]
stages += [int(m.group(1)) for m in re.finditer(r"output \* resolution (\d+)x\d+", runner)]
bad = []
if len(stages) < 2:
    bad.append("tools/linux/run-suites.sh: could not read both protocol stages "
               "(the Xvfb -screen and sway output lines moved) — this clause is blind")
if "unset GDK_DPI_SCALE GDK_SCALE" not in runner:
    bad.append("tools/linux/run-suites.sh: the text-scale pin (unset GDK_DPI_SCALE "
               "GDK_SCALE) is gone — sp-unit breakpoints are then a different pixel "
               "width per run and no byte-frozen resize is reproducible")
widest = 0
where = ""
for path in sys.argv[1:]:
    for n, line in enumerate(open(path).read().splitlines(), 1):
        s = line.strip()
        if s.startswith("#"):
            continue
        m = re.match(r"resize_window\s+(\d+)x\d+", s)
        if m and int(m.group(1)) > widest:
            widest, where = int(m.group(1)), f"{path}:{n}"
for stage in stages:
    if widest > stage:
        bad.append(f"{where}: resize_window to {widest} exceeds a linux stage of "
                   f"{stage}px — grow the Xvfb screen and the sway output in "
                   f"run-suites.sh, or the window silently stays small")
for b in bad:
    print(b)
sys.exit(1 if bad else 0)
' "$@"
}

# The guard guards itself, both directions: an oversized resize must be
# caught, and the real roster must pass.
STAGE_T="$(mktemp -d)"
printf 'expect_entries 0\nresize_window 9999x800\nexpect_panes\n' > "$STAGE_T/huge.steps"
if linux_stage_lint "$STAGE_T/huge.steps" >/dev/null; then
    echo "check-steps: SELF-TEST FAIL (a resize wider than the linux stages passed)" >&2
    exit 1
fi
rm -rf "$STAGE_T"

# EVERY TwoPaneView KILLS TALL MODE. TwoPaneView has a third mode no
# other backend can produce: at compact width on a window TALLER than
# 641, both panes stack top-over-bottom, the leading pane's WIDTH is
# applied as a HEIGHT, and the back affordance disappears — while
# expect_split reads "compact/split", which the bare invariant cannot
# refuse. Every scene height happens to be 600, so the lane's green
# rests on a 41-DIP coincidence unless every constructed view sets
# MinTallModeHeight to infinity (the platform's own off switch). A
# count, not a proximity match: the two must simply never diverge.
tall_lint() {
    python3 -c '
import sys

text = open(sys.argv[1], encoding="utf-8").read()
made = text.count("TwoPaneView::new")
killed = text.count("SetMinTallModeHeight")
if made == 0:
    print(f"{sys.argv[1]}: no TwoPaneView is constructed at all — the split "
          f"lowering moved and this clause is blind")
    sys.exit(1)
if killed < made:
    print(f"{sys.argv[1]}: {made} TwoPaneView(s) constructed but only {killed} "
          f"SetMinTallModeHeight call(s) — a view without one enters Tall mode "
          f"on any tall-enough compact window (docs/multicolumn-plan.md)")
    sys.exit(1)
' "$1"
}
if ! tall_lint crates/kaya/src/winui/mod.rs >&2; then
    status=1
fi
# The guard guards itself: a doctored copy with one kill removed must
# fail, and the perturbation is PROVEN applied by the printed count.
TALL_T="$(mktemp -d)"
python3 - crates/kaya/src/winui/mod.rs "$TALL_T/doctored.rs" <<'PY'
import sys

text = open(sys.argv[1], encoding="utf-8").read()
needle = "SetMinTallModeHeight"
count = text.count(needle)
print(f"check-steps: tall self-test found {count} kill call(s), removing one")
if count < 1:
    sys.exit(1)
open(sys.argv[2], "w", encoding="utf-8").write(
    text.replace(needle, "XX_removed_XX", 1))
PY
if tall_lint "$TALL_T/doctored.rs" >/dev/null 2>&1; then
    echo "check-steps: SELF-TEST FAIL (a TwoPaneView without the Tall kill passed)" >&2
    exit 1
fi
rm -rf "$TALL_T"
if ! linux_stage_lint tools/scenes/*.steps >/dev/null; then
    linux_stage_lint tools/scenes/*.steps >&2
    echo "check-steps: the linux stages cannot hold the scene roster (above)" >&2
    status=1
fi

# Raw CR bytes: the scripts are LF files by contract. The Swift
# interpreter splits script text on "\n", and Swift's grapheme-based
# split sees CRLF as ONE cluster — a CRLF-ended script would parse as
# a single giant line there while parsing fine everywhere else
# (docs/traps.md, the grapheme family). CR as DATA rides the \r
# escape, never a raw byte.
cr_lint() {
    python3 -c '
import sys

path = sys.argv[1]
data = sys.stdin.buffer.read() if path == "-" else open(path, "rb").read()
if b"\r" in data:
    print(f"{path}: raw CR byte — steps files are LF-only "
          "(use the \\r escape for CR as data)")
    sys.exit(1)
' "$1"
}

# The guard guards itself.
if printf 'expect label#0 "x"\r\n' | cr_lint - >/dev/null; then
    echo "check-steps: SELF-TEST FAIL (CRLF sample passed)" >&2
    exit 1
fi

for f in tools/scenes/*.steps; do
    out="$(cr_lint "$f")" || {
        echo "check-steps: $f contains a raw CR byte:" >&2
        echo "$out" >&2
        status=1
    }
done

# Entries are single-line controls: what a platform does with an
# embedded line break in one is platform-defined input behavior
# (WinUI strips, GTK filters, others vary), so a scene asserting it
# would pin one platform's behavior against the rest. The multi-line
# round trip belongs to the textarea. set_text into an entry must not
# carry \n or \r.
entry_newline_lint() {
    python3 -c '
import re
import sys

path = sys.argv[1]
text = sys.stdin.read() if path == "-" else open(path).read()
bad = []
for lineno, line in enumerate(text.splitlines(), 1):
    if line.lstrip().startswith("#"):
        continue
    for step in line.split(";"):
        s = step.strip()
        if re.match(r"set_text\s+entry#", s) and re.search(r"\\[nr]", s):
            bad.append(f"{path}:{lineno}: {s}")
print("\n".join(bad))
sys.exit(1 if bad else 0)
' "$1"
}

# The guard guards itself.
if printf 'set_text entry#0 "a\\nb"\n' | entry_newline_lint - >/dev/null; then
    echo "check-steps: SELF-TEST FAIL (entry-newline sample passed)" >&2
    exit 1
fi

for f in tools/scenes/*.steps; do
    out="$(entry_newline_lint "$f")" || {
        echo "check-steps: $f drives a line break into a single-line entry (platform-defined; textarea owns the multi-line contract):" >&2
        echo "$out" >&2
        status=1
    }
done

# THE TYPING VERB'S TWO RULES, both about `type` being REAL KEYSTROKES
# at the FOCUSED widget (harness.rs Step::Type, docs/undo-plan.md A8).
#
# 1. THE PAYLOAD IS PRINTABLE ASCII: the keycode mapping is only
#    platform-independent inside 0x20..0x7e, and Return is a COMMAND
#    whose meaning depends on the widget it lands in. harness.rs refuses
#    it at parse; this is the two-second answer with a file and a line.
# 2. A SCRIPT THAT TYPES MUST HAVE ASSERTED FOCUS FIRST. The verb takes
#    no target, and because expects are bounded retries while actions
#    are not, that assertion is also the WAIT for focus to land.
typing_lint() {
    python3 -c '
import re
import sys

path = sys.argv[1]
text = sys.stdin.read() if path == "-" else open(path).read()
bad = []
focused = False
# The most recent `type` that is still the newest thing in the focused
# field native undo history: (lineno, step, payload). Any OTHER action
# pushes its own entry in front of it, which is why a click clears this.
pending = None
for lineno, line in enumerate(text.splitlines(), 1):
    if line.lstrip().startswith("#"):
        continue
    for step in line.split(";"):
        s = step.strip()
        if not s:
            continue
        if s.startswith("expect_focused"):
            focused = True
            continue
        m = re.match(r"type\s+\"(.*)\"\s*$", s)
        if not m:
            # HOW MUCH OF A TYPED RUN ONE UNDO SPENDS IS FRONTIER
            # GRANULARITY, which a shared scene may not assert
            # (docs/undo-plan.md §2, §5.2). One character is the floor
            # every platform agrees on; more than one is a coin toss.
            # Measured: a five-character run undone in one step passed
            # on mac, where AppKit coalesces a burst whole, and failed
            # on linux/x11 where GtkTextHistory spends one per undo.
            if re.match(r"menu_activate\s+\"Edit>Undo\"\s*$", s):
                if pending is not None and len(pending[2]) > 1:
                    bad.append(f"{path}:{pending[0]}: {pending[1]} — then "
                               f"line {lineno} undoes it. How much of a MULTI "
                               "character typed run one Edit>Undo spends is "
                               "frontier granularity, which is platform "
                               "flavored (docs/undo-plan.md §5.2) and which "
                               "invariant 6 forbids a shared scene from "
                               "asserting. Type ONE character before an undo "
                               "that must restore the whole run, or put an app "
                               "action between them so the undo spends THAT")
                pending = None
            elif not s.startswith("expect") and not s.startswith("settle"):
                # Anything else that acts — a click, a set_text, another
                # menu — becomes the newest history entry itself.
                pending = None
            continue
        payload = m.group(1)
        if re.search(r"\\[nrt]", payload) or not payload:
            bad.append(f"{path}:{lineno}: {s} — type carries real keystrokes, and "
                       "a line break is a COMMAND whose meaning depends on the "
                       "widget it lands in (newline in a textarea, activation in "
                       "an entry). Type text, or drive the command with its own verb")
        elif any(not (" " <= c <= "~") for c in payload):
            bad.append(f"{path}:{lineno}: {s} — type carries real keystrokes, and "
                       "one keycode per character is only platform-independent "
                       "inside printable ASCII; composed characters are an input "
                       "method question, not a verb argument")
        if not focused:
            bad.append(f"{path}:{lineno}: {s} — nothing has asserted focus yet. "
                       "type has no target: whoever holds focus takes the keys, so "
                       "a script must expect_focused first (which is also the WAIT "
                       "for focus to land, since actions are not retried)")
        pending = (lineno, s, payload)
print("\n".join(bad))
sys.exit(1 if bad else 0)
' "$1"
}

# The guard guards itself, every direction: a line break must fail, a
# composed character must fail, typing before focus is asserted must
# fail, and the well-formed shape must PASS — or the three above are
# failing for a reason that has nothing to do with what they claim.
if printf 'expect_focused entry#0\ntype "a\\nb"\n' | typing_lint - >/dev/null; then
    echo "check-steps: SELF-TEST FAIL (a line break in a type payload passed)" >&2
    exit 1
fi
if printf 'expect_focused entry#0\ntype "h\xc3\xa9llo"\n' | typing_lint - >/dev/null; then
    echo "check-steps: SELF-TEST FAIL (a composed character in a type payload passed)" >&2
    exit 1
fi
if printf 'expect label#0 "x"\ntype "milk"\n' | typing_lint - >/dev/null; then
    echo "check-steps: SELF-TEST FAIL (typing before focus was asserted passed)" >&2
    exit 1
fi
if ! printf 'expect_focused entry#0\ntype "milk 2"\n' | typing_lint - >/dev/null; then
    echo "check-steps: SELF-TEST FAIL (a well-formed type step was refused)" >&2
    exit 1
fi
# The frontier-granularity clause, all four directions. The two PASSING
# shapes are the ones that make the failing one mean something: a
# one-character run is the floor every platform agrees on, and an app
# action between the typing and the undo makes the undo spend THAT.
if printf 'expect_focused entry#0\ntype "tail"\nexpect_dirty true\nmenu_activate "Edit>Undo"\n' \
    | typing_lint - >/dev/null; then
    echo "check-steps: SELF-TEST FAIL (undoing a multi-character typed run passed)" >&2
    exit 1
fi
if ! printf 'expect_focused entry#0\ntype "z"\nexpect_dirty true\nmenu_activate "Edit>Undo"\n' \
    | typing_lint - >/dev/null; then
    echo "check-steps: SELF-TEST FAIL (undoing a one-character run was refused)" >&2
    exit 1
fi
if ! printf 'expect_focused entry#0\ntype "milk"\nclick button#0\nmenu_activate "Edit>Undo"\n' \
    | typing_lint - >/dev/null; then
    echo "check-steps: SELF-TEST FAIL (an app action between typing and undo was refused)" >&2
    exit 1
fi
# AND THE CLAUSE MUST FIRE ON THE REAL FILE THAT PROVOKED IT: the
# perturbation goes into a COPY of editor.steps, the substitution count
# is printed and asserted, and an unchanged file is a FAILED test.
undo_granularity_selftest() {
    local copy applied
    copy="$(mktemp)"
    applied="$(python3 - "$copy" <<'PY'
import pathlib
import sys

out = pathlib.Path(sys.argv[1])
src = pathlib.Path("tools/scenes/editor.steps").read_text()
# The exact shape the lane caught: a multi-character run undone whole.
patched, n = __import__("re").subn(r"^type \"z\"$", "type \" tail\"", src, flags=8)
out.write_text(patched)
print(n)
PY
    )" || return 1
    if [ "$applied" != 1 ]; then
        echo "check-steps: SELF-TEST FAIL (the undo-granularity perturbation" \
            "applied $applied times, wanted 1 — editor.steps was reshaped and" \
            "this negative test is now vacuous)" >&2
        rm -f "$copy"
        return 1
    fi
    if typing_lint "$copy" >/dev/null; then
        echo "check-steps: SELF-TEST FAIL (editor.steps with a multi-character" \
            "run before Edit>Undo passed the real file)" >&2
        rm -f "$copy"
        return 1
    fi
    rm -f "$copy"
}
undo_granularity_selftest || exit 1

# ── expect_title MAY NOT SIT INSIDE A DIRTY STRETCH ──────────────────
#
# docs/dirty-plan.md §2. The declared title is untouched by `dirty` on
# every backend, but the WinUI arm composes its asterisk into the
# RENDERED CAPTION, which is exactly what expect_title reads there. So a
# title assertion made while the window is dirty reads "notes" on four
# lanes and "*notes" on the fifth.
#
# THE DIRTY STRETCH IS THE SCENE'S OWN CLAIM about itself: from an
# `expect_dirty true` up to the next `expect_dirty false`. A scene that
# never asserts `dirty` has no stretch and is untouched.
#
# `python3 -c` AND NOT A HEREDOC, which is not a style choice: a heredoc
# IS this process's stdin, so the `-` spelling the self-tests pipe into
# would read the program instead of the script and every negative test
# would pass vacuously.
title_dirty_lint() {
    python3 -c '
import re, sys
path = sys.argv[1]
src = sys.stdin.read() if path == "-" else open(path).read()
bad = []
dirty = None
dirty_line = 0
for lineno, step in enumerate(src.split("\n"), start=1):
    s = step.strip()
    if not s or s.startswith("#"):
        continue
    m = re.match(r"expect_dirty\s+(true|false)\s*$", s)
    if m:
        dirty = m.group(1) == "true"
        dirty_line = lineno
        continue
    if s.startswith("expect_title") and dirty:
        bad.append(
            f"{path}:{lineno}: {s} — this window was claimed DIRTY at line "
            f"{dirty_line} and nothing has cleared the claim. The WinUI arm "
            "composes its unsaved-work asterisk into the RENDERED CAPTION, "
            "which is what expect_title reads there, so this line compares "
            "one string on four lanes and a marked one on the fifth "
            "(docs/dirty-plan.md D1 and its open question 2). Put an "
            "`expect_dirty false` in front of it: a title read is a "
            "five-lane byte comparison only once the scene has CLAIMED the "
            "window clean, and that claim is the only record a gate has")
print("\n".join(bad))
sys.exit(1 if bad else 0)
' "$1"
}

# Both directions, because a guard that only ever passes is not a guard:
# a title read inside the stretch must FAIL, and the same read after the
# mark comes down must PASS.
if printf 'expect_dirty true\nexpect_title "notes"\n' | title_dirty_lint - >/dev/null; then
    echo "check-steps: SELF-TEST FAIL (expect_title inside a dirty stretch passed)" >&2
    exit 1
fi
if ! printf 'expect_dirty true\nexpect_dirty false\nexpect_title "notes"\n' \
    | title_dirty_lint - >/dev/null; then
    echo "check-steps: SELF-TEST FAIL (expect_title after the mark cleared was refused)" >&2
    exit 1
fi
if ! printf 'expect_title "window probe"\n' | title_dirty_lint - >/dev/null; then
    echo "check-steps: SELF-TEST FAIL (a scene with no dirty claim at all was refused)" >&2
    exit 1
fi
# AND ON THE REAL FILE THAT NEEDS IT: the perturbation moves
# editor.steps' own launch title read to just after an `expect_dirty
# true`, the substitution count is printed and asserted, and an
# unchanged file is a FAILED test.
title_dirty_selftest() {
    local copy applied
    copy="$(mktemp)"
    applied="$(python3 - "$copy" <<'PY'
import pathlib
import re
import sys

out = pathlib.Path(sys.argv[1])
src = pathlib.Path("tools/scenes/editor.steps").read_text()
# The exact shape the rule forbids: a title read while the mark is up.
patched, n = re.subn(
    r"^expect_dirty true$",
    'expect_dirty true\nexpect_title "notes"',
    src,
    count=1,
    flags=re.M,
)
out.write_text(patched)
print(n)
PY
    )" || return 1
    if [ "$applied" != 1 ]; then
        echo "check-steps: SELF-TEST FAIL (the title/dirty perturbation applied" \
            "$applied times, wanted 1 — editor.steps no longer claims a dirty" \
            "stretch and this negative test is now vacuous)" >&2
        rm -f "$copy"
        return 1
    fi
    if title_dirty_lint "$copy" >/dev/null; then
        echo "check-steps: SELF-TEST FAIL (editor.steps with a title read inside" \
            "a dirty stretch passed the real file)" >&2
        rm -f "$copy"
        return 1
    fi
    rm -f "$copy"
}
title_dirty_selftest || exit 1

# ── TWO ALERTS WITH THE SAME TITLE NEED `expect_alerts 0` BETWEEN ────
#
# MEASURED 2026-08-10 on the iOS lane, with editor.steps. The app guards
# unsaved work at three doors under one alert title, so
# `expect_alert "unsaved changes"` cannot tell a NEW dialog from the one
# still on screen. The stretch that failed:
#
#   alert_choose cancel
#   expect textarea#0 "scratch"   <- already true; passes instantly
#   expect_dirty true             <- already true; passes instantly
#   menu_activate "File>New"
#   expect_alert "unsaved changes" <- matched the OLD alert, +0ms
#
# and the app's second show hit the core's one-alert-per-process
# assertion and ABORTED the guest.
#
# WHAT THIS CLAUSE DELIBERATELY DOES NOT CATCH, because a guard that
# fires on correct scripts gets deleted rather than obeyed. Two
# conditions have to meet for the race to exist:
#
#  1. THE TITLES REPEAT. A stale "delete item?" can never satisfy
#     `expect_alert "eject disk?"`.
#  2. THE ANSWER WAS `cancel`. An ACTION's continuation does something
#     the script can wait on; a CANCEL's continuation is by construction
#     "leave everything as it was", so every assertion after it was
#     already true before the dialog opened.
#
# So the clause fires on a cancel answered into a repeat of its own
# title, the measured case and nothing wider.
alert_wait_lint() {
    python3 -c '
import re, sys
path = sys.argv[1]
src = sys.stdin.read() if path == "-" else open(path).read()
bad = []
cancelled = None         # (line, title) of the last CANCELLED alert
seen = None              # the title expect_alert last matched
for lineno, step in enumerate(src.split("\n"), start=1):
    s = step.strip()
    if not s or s.startswith("#"):
        continue
    m = re.match(r"expect_alert\s+\"(.*)\"\s*$", s)
    if m:
        if cancelled and cancelled[1] == m.group(1):
            bad.append(
                f"{path}:{lineno}: {s} — the alert CANCELLED at line "
                f"{cancelled[0]} carries the SAME title and nothing has "
                "asserted it is gone. expect_alert matches by title, so this "
                "line can be satisfied by the dialog still on screen; the "
                "app then shows its next one into a live slot and the core "
                "aborts the guest (\"alert N is already live — one alert per "
                "process\"). Put `expect_alerts 0` between them: a cancel "
                "changes nothing, so every other assertion here was already "
                "true and only the dialog count can be the wait")
        seen = m.group(1)
        continue
    if re.match(r"expect_alerts\s+0\s*$", s):
        cancelled = None
        seen = None
        continue
    m = re.match(r"alert_choose\s+(\S+)\s*$", s)
    if m:
        cancelled = (lineno, seen) if m.group(1) == "cancel" else None
print("\n".join(bad))
sys.exit(1 if bad else 0)
' "$1"
}

# Every direction. The cancelled repeat must FAIL; the same pair with
# the count assertion between must PASS; a repeat after an ACTION must
# pass (its continuation is waitable — confirm.steps); and two
# DIFFERENT titles must pass.
if printf 'expect_alert "x"\nalert_choose cancel\nexpect_alert "x"\n' \
    | alert_wait_lint - >/dev/null; then
    echo "check-steps: SELF-TEST FAIL (a cancelled same-title repeat with no wait passed)" >&2
    exit 1
fi
if ! printf 'expect_alert "x"\nalert_choose cancel\nexpect_alerts 0\nexpect_alert "x"\n' \
    | alert_wait_lint - >/dev/null; then
    echo "check-steps: SELF-TEST FAIL (a same-title repeat behind expect_alerts 0 was refused)" >&2
    exit 1
fi
if ! printf 'expect_alert "x"\nalert_choose 0\nexpect_alert "x"\n' \
    | alert_wait_lint - >/dev/null; then
    echo "check-steps: SELF-TEST FAIL (a same-title repeat after an ACTION was refused)" >&2
    exit 1
fi
if ! printf 'expect_alert "x"\nalert_choose cancel\nexpect_alert "y"\n' \
    | alert_wait_lint - >/dev/null; then
    echo "check-steps: SELF-TEST FAIL (two DIFFERENT alert titles were refused)" >&2
    exit 1
fi
# AND ON THE REAL FILE THAT PROVOKED IT: delete editor.steps' first
# `expect_alerts 0` and the lint must catch what the iOS lane caught.
alert_wait_selftest() {
    local copy applied
    copy="$(mktemp)"
    applied="$(python3 - "$copy" <<'PY'
import pathlib
import re
import sys

out = pathlib.Path(sys.argv[1])
src = pathlib.Path("tools/scenes/editor.steps").read_text()
patched, n = re.subn(r"^expect_alerts 0\n", "", src, count=1, flags=re.M)
out.write_text(patched)
print(n)
PY
    )" || return 1
    if [ "$applied" != 1 ]; then
        echo "check-steps: SELF-TEST FAIL (the alert-wait perturbation applied" \
            "$applied times, wanted 1 — editor.steps no longer spells the wait" \
            "and this negative test is now vacuous)" >&2
        rm -f "$copy"
        return 1
    fi
    if alert_wait_lint "$copy" >/dev/null; then
        echo "check-steps: SELF-TEST FAIL (editor.steps with its alert wait" \
            "deleted passed the real file)" >&2
        rm -f "$copy"
        return 1
    fi
    rm -f "$copy"
}
alert_wait_selftest || exit 1

for f in tools/scenes/*.steps; do
    out="$(typing_lint "$f")" || {
        echo "check-steps: $f types in a way no keyboard can:" >&2
        echo "$out" >&2
        status=1
    }
    out="$(title_dirty_lint "$f")" || {
        echo "check-steps: $f asserts a window title while the window is dirty:" >&2
        echo "$out" >&2
        status=1
    }
    out="$(alert_wait_lint "$f")" || {
        echo "check-steps: $f reopens a same-titled alert with no wait:" >&2
        echo "$out" >&2
        status=1
    }
done

# Every scene script must be reachable by name. An unregistered scene
# does not fail — it silently runs a DIFFERENT script, and a leg that
# passes then proves nothing about the scene it claims to be.


# Every scene must be WIRED into every platform runner, not merely
# registered: a scene can exist, parse and be registered yet run
# nowhere. EVERY runner is held to a STRUCTURAL signature — mac, linux
# and windows to their leg spellings, android to its `run_apk <scene>-`
# blocks, iOS to membership in the IOS_*_SCENES lists its legs are
# generated from. NEVER the bare name: the name-level check this
# replaced was satisfied by a COMMENT (the only `background` in
# run-sim.sh sat in a sentence about shell jobs) and by unrelated CODE
# (`window` inside resize_window), so four pairs claimed wiring that
# did not exist — found by the 2026-08-19 comment sweep's gate survey.
#
# A runner may DECLARE a scene off instead: *_DESKTOP_ONLY_SCENES for
# platform policy, IOS_UNWIRED_SCENES for ledgered gaps. Declarations
# are checked too — one that names a scene the roster lacks, or a scene
# that is ALSO wired, is a red, so a stale declaration cannot linger.
#
# EXCEPT where the backend says it has not got there yet: a backend left
# behind by a depth slice declares `depth_stub("<scene>")`, the same
# call check-stubs reads from the other side. Between them the two gates
# state one rule: a scene's legs are wired on a runner IF AND ONLY IF
# that runner's backend has the feature.
#
# THE EXEMPTION IS KEYED ON THE SCENE'S FEATURES, NOT ITS NAME, or the
# two gates contradict each other. A scene can demand a feature it is
# not named after — `todos.steps` activates Edit>Undo — so a stub on
# `undo` that held only the `undo` legs off a runner would leave no tree
# able to satisfy both gates. tools/lib/scene-features.py derives the
# pairs and is the SAME predicate the cross-check uses.

# The scene-halves of every word in the VAR="..." assignments matching
# the $2 alternation in file $1, one per line (`listdetail:split`
# yields `listdetail`).
runner_list_scenes() {
    local line entry
    grep -E "^[[:space:]]*($2)=\"" "$1" | while IFS= read -r line; do
        line="${line#*=\"}"
        line="${line%%\"*}"
        for entry in $line; do
            printf '%s\n' "${entry%%:*}"
        done
    done
}

wired() {
    local runner scene status=0 exempt sig decl roster ok
    local ios_wired ios_declared android_declared
    exempt="$(python3 tools/lib/scene-features.py --mode exempt)"
    local rc=$?
    if [ "$rc" -ne 0 ]; then
        echo "check-steps: scene-features.py could not derive the depth-stub exemptions" >&2
        return 1
    fi
    # Padded and delimited, so a scene name that is a prefix of another
    # cannot borrow its exemption.
    #
    # NOT THROUGH A COMMAND SUBSTITUTION: `$(printf '\n%s\n' ...)`
    # STRIPS the trailing newline it just added, so the pattern below —
    # which requires one after the pair — could never match the LAST
    # derived exemption.
    exempt=$'\n'"$exempt"$'\n'

    ios_wired="$(runner_list_scenes tools/ios/run-sim.sh 'IOS_SWIFT_SCENES|IOS_GO_SCENES')"
    ios_declared="$(runner_list_scenes tools/ios/run-sim.sh 'IOS_DESKTOP_ONLY_SCENES|IOS_UNWIRED_SCENES')"
    android_declared="$(runner_list_scenes tools/android/run-emulator.sh 'ANDROID_DESKTOP_ONLY_SCENES')"
    # A reader that reads nothing agrees with everything.
    if [ -z "$ios_wired" ]; then
        echo "check-steps: wired() read NO scenes out of run-sim.sh's IOS_*_SCENES assignments — they moved, and this clause is blind" >&2
        return 1
    fi

    roster=" "
    for scene in tools/scenes/*.steps; do
        roster="$roster$(basename "${scene%.steps}") "
    done
    for decl in $ios_declared; do
        case "$roster" in *" $decl "*) ;; *)
            echo "check-steps: run-sim.sh declares \"$decl\" off, but no such scene exists" >&2
            status=1 ;;
        esac
        if printf '%s\n' "$ios_wired" | grep -qFx "$decl"; then
            echo "check-steps: run-sim.sh declares \"$decl\" off AND lists it in IOS_*_SCENES — one of the two is stale" >&2
            status=1
        fi
    done
    for decl in $android_declared; do
        case "$roster" in *" $decl "*) ;; *)
            echo "check-steps: run-emulator.sh declares \"$decl\" off, but no such scene exists" >&2
            status=1 ;;
        esac
        if grep -qE "run_apk[[:space:]]+$decl-" tools/android/run-emulator.sh; then
            echo "check-steps: run-emulator.sh declares \"$decl\" off AND carries a run_apk leg for it — one of the two is stale" >&2
            status=1
        fi
    done

    for scene in tools/scenes/*.steps; do
        scene="$(basename "${scene%.steps}")"
        for runner in tools/validate-mac.sh tools/linux/run-suites.sh \
            tools/deploy-win.sh tools/ios/run-sim.sh tools/android/run-emulator.sh; do
            case "$exempt" in
                *$'\n'"$runner"$'\t'"$scene"$'\n'*) continue ;;
            esac
            case "$runner" in
                tools/ios/run-sim.sh)
                    # Two wiring forms: the list-driven suites, and the
                    # HAND-QUEUED legs below them (the rust-swiftui
                    # suite and the editor) — a `queue_leg
                    # run_swiftui_on <scene>-...` line is as structural
                    # as a list entry.
                    ok=1
                    if printf '%s\n' "$ios_wired" | grep -qFx "$scene"; then
                        ok=0
                    elif grep -qE "run_swiftui_on[[:space:]]+\"?$scene-" "$runner"; then
                        ok=0
                    elif printf '%s\n' "$ios_declared" | grep -qFx "$scene"; then
                        ok=0
                    fi
                    if [ "$ok" = 1 ]; then
                        echo "check-steps: scene \"$scene\" has no live legs in $runner (not in IOS_*_SCENES, not hand-queued, not declared off)" >&2
                        status=1
                    fi
                    ;;
                tools/android/run-emulator.sh)
                    # milestone2's legs drop the scene prefix (they ARE
                    # the unprefixed originals); its check stays coarse.
                    ok=1
                    if [ "$scene" = milestone2 ]; then
                        if grep -qF "$scene" "$runner"; then ok=0; fi
                    elif grep -qE "run_apk[[:space:]]+$scene-" "$runner"; then
                        ok=0
                    elif printf '%s\n' "$android_declared" | grep -qFx "$scene"; then
                        ok=0
                    fi
                    if [ "$ok" = 1 ]; then
                        echo "check-steps: scene \"$scene\" has no run_apk leg in $runner and is not declared off" >&2
                        status=1
                    fi
                    ;;
                *)
                    case "$runner" in
                        tools/validate-mac.sh) sig="run $scene-" ;;
                        tools/linux/run-suites.sh) sig="run \"\$proto\" $scene-" ;;
                        tools/deploy-win.sh) sig="run_suite ${scene}_" ;;
                    esac
                    [ "$scene" = milestone2 ] && sig="$scene"
                    if ! grep -qF "$sig" "$runner"; then
                        echo "check-steps: scene \"$scene\" has no live legs in $runner (wanted \"$sig\")" >&2
                        status=1
                    fi
                    ;;
            esac
        done
    done
    return "$status"
}
wired || status=1

# THE VERB-FEATURE CROSS-CHECK — the other half of the same predicate.
# wired() above says when a stub HOLDS legs off a runner; this says when
# a runner runs legs it must not, i.e. a scene whose verbs demand a
# feature its backend still refuses. Keyed on the scene NAME that
# question cannot be asked at all: a scene's name is not what a backend
# has to implement.
#
# tools/lib/scene-features.py holds the derivation (verbs and menu ROLES
# to features, with the role table pinned against MENU_ROLES so a
# seventh role cannot ship without an answer).
if ! python3 tools/lib/scene-features.py --mode check; then
    status=1
fi

# The guard guards itself against a REAL scene corpus: the synthetic
# root borrows tools/scenes, scene.rs and hand-rolled-stubs.py from this
# tree and synthesizes only the runner and backend files, so the
# derivation under test is the derivation that ships.
feature_selftest() { # legs stub [extra-scene-body]
    local dir out rc legs stub extra
    legs="$1"; stub="$2"; extra="${3:-}"
    dir="$(mktemp -d)"
    mkdir -p "$dir/tools/lib" "$dir/tools/linux" "$dir/tools/ios" \
        "$dir/tools/android" "$dir/crates/kaya/src" "$dir/swift" \
        "$dir/crates/kaya/src/winui" \
        "$dir/android/kaya/src/main/kotlin/dev/kaya"
    cp -R tools/scenes "$dir/tools/scenes"
    cp crates/kaya/src/scene.rs "$dir/crates/kaya/src/scene.rs"
    cp tools/lib/hand-rolled-stubs.py "$dir/tools/lib/hand-rolled-stubs.py"
    : >"$dir/tools/validate-mac.sh"
    : >"$dir/tools/linux/run-suites.sh"
    : >"$dir/tools/deploy-win.sh"
    : >"$dir/tools/ios/run-sim.sh"
    : >"$dir/crates/kaya/src/gtk.rs"
    : >"$dir/crates/kaya/src/winui/mod.rs"
    : >"$dir/swift/KayaSwiftUI.swift"
    [ -n "$extra" ] && printf 'expect label#0 "x"\n%s\n' "$extra" \
        >"$dir/tools/scenes/zzprobe.steps"
    printf '%s\n' "$legs" >"$dir/tools/android/run-emulator.sh"
    printf '%s\n' "$stub" \
        >"$dir/android/kaya/src/main/kotlin/dev/kaya/KayaCompose.kt"
    out="$(python3 tools/lib/scene-features.py --root "$dir" --mode check 2>&1)"
    rc=$?
    rm -rf "$dir"
    printf '%s' "$out"
    return "$rc"
}

# 1. THE EXACT SHAPE §8 RECORDS: the android runner running todos while
#    Compose stubs undo. It must fail, and it must NAME todos — a message
#    naming only `undo` would send the reader to the scene that is not
#    the problem, and the whole defect was that nobody was looking at
#    todos.
selftest_out="$(feature_selftest 'run_apk todos-compose apk act todos' \
    'internal fun x(): Nothing = depthStub("undo")')"
case "$selftest_out" in
    *'runs "todos" legs'*'stubs "undo"'*'todos.steps:'*) ;;
    *)
        echo "check-steps: SELF-TEST FAIL (a todos leg on a backend stubbing undo was not named):" >&2
        echo "$selftest_out" >&2
        exit 1 ;;
esac
# 2. ...and the SAME stub with the legs pulled must PASS, or the interim
#    state of a depth slice is inexpressible and this clause is a wall
#    across the only road out of it.
if ! feature_selftest 'run_apk menus-compose apk act menus' \
    'internal fun x(): Nothing = depthStub("undo")' >/dev/null; then
    echo "check-steps: SELF-TEST FAIL (a stub with no legs wired was refused)" >&2
    exit 1
fi
# 3. ...and with no stub at all, the same legs must PASS — otherwise 1
#    is failing for some reason that has nothing to do with the stub.
if ! feature_selftest 'run_apk todos-compose apk act todos' '' >/dev/null; then
    echo "check-steps: SELF-TEST FAIL (todos legs on an unstubbed backend were refused)" >&2
    exit 1
fi
# 4/5. THE CLIPBOARD ROWS FIRING CROSS-SCENE, which nothing in the tree
#    can show: `clipboard.steps` is NAMED after the feature it needs, so
#    a dead verb row and a live one look identical from outside. A probe
#    scene carries the verb under a name that implies nothing, and each
#    derivation gets its own run — the VERB row and the ROLE row.
for probe in 'expect_clipboard text "x"' 'menu_activate "Edit>Paste"'; do
    selftest_out="$(feature_selftest 'run_apk zzprobe-compose apk act zzprobe' \
        'internal fun x(): Nothing = depthStub("clipboard")' "$probe")"
    case "$selftest_out" in
        *'runs "zzprobe" legs'*'stubs "clipboard"'*) ;;
        *)
            echo "check-steps: SELF-TEST FAIL (a clipboard rule did not fire for: $probe)" >&2
            echo "$selftest_out" >&2
            exit 1 ;;
    esac
done
unset selftest_out probe

# The Android per-leg setup has an ORDER, and every step's place
# matters — enabling the accessibility service before the force-stop
# kills it, and before the logcat clear erases the evidence it started.
# None of that is visible at the call site, and the failure surfaces
# much later as "the picker never appeared".
if ! python3 tools/lib/android-leg-order.py; then
    status=1
fi

# SCENES MEANS "THE LANGUAGE SWEEP LANDED". Each desktop runner derives
# its mechanical per-scene surfaces from SCENES — the source scp, the
# taskkill list — so a rust-only scene added there sends the runner
# looking for guests that do not exist. DEPTH_SCENES is the variable for
# that case, in all three runners.
sweep_guests() {
    python3 - <<'PY'
import pathlib, re, sys

LANGS = [
    ("go", "guests/go/{s}/{s}.go"),
    ("python", "guests/python/{s}.py"),
    ("csharp", "guests/csharp/{S}Scene.cs"),
    ("swift", "guests/swift/{s}.swift"),
    ("ocaml", "guests/ocaml/{s}.ml"),
    ("haskell", "guests/haskell/{s}.hs"),
]
# The JVM and CLR guests are NOT one file per scene: one package plus a
# selector with irregular class names, so a path pattern cannot see
# them. Check what decides reachability — that the selector dispatches
# it. A class wired into no switch is as broken as a missing file.
SELECTORS = [
    ("java", "guests/java-desktop/dev/kaya/milestone2kt/Main.java"),
    ("csharp", "guests/csharp/Program.cs"),
]
bad = []
for runner in ("tools/validate-mac.sh", "tools/linux/run-suites.sh", "tools/deploy-win.sh"):
    text = pathlib.Path(runner).read_text()
    m = re.search(r'^SCENES="([^"]+)"', text, re.M)
    if not m:
        bad.append(f"{runner}: no SCENES variable")
        continue
    for scene in m.group(1).split():
        for lang, pat in LANGS:
            if not pathlib.Path(pat.format(s=scene, S=scene.capitalize())).exists():
                bad.append(
                    f"{runner}: scene \"{scene}\" is in SCENES but has no {lang} guest "
                    f"({pat.format(s=scene, S=scene.capitalize())}) — a rust-only scene "
                    "belongs in DEPTH_SCENES")
scenes = set()
for runner in ("tools/validate-mac.sh", "tools/linux/run-suites.sh", "tools/deploy-win.sh"):
    text = pathlib.Path(runner).read_text()
    m = re.search(r'^SCENES="([^"]+)"', text, re.M)
    if m:
        scenes.update(m.group(1).split())
for lang, selector in SELECTORS:
    text = pathlib.Path(selector).read_text()
    for scene in sorted(scenes):
        # milestone2 is the DEFAULT arm in both selectors, reachable
        # without a case of its own — verified, not assumed: both files
        # end in `default:` dispatching Milestone2.
        if scene == "milestone2":
            continue
        if f'case "{scene}"' not in text:
            bad.append(
                f'{selector}: scene "{scene}" is in SCENES but the {lang} '
                "selector never dispatches it — the guest is unreachable")
# A GUEST THAT EXISTS BUT NO LEG RUNS IS INVISIBLE TO EVERY OTHER GATE:
# wired() above demands only that a scene has SOME leg, so one language
# covers for all of them.
#
# mac only, deliberately: this runner names every leg
# `<scene>-<lang>-swiftui`, so the expectation is exact. The other
# runners have their own naming and their own backend-stub carve-outs.
mac = pathlib.Path("tools/validate-mac.sh").read_text()
m = re.search(r'^SCENES="([^"]+)"', mac, re.M)
stubbed = pathlib.Path("swift/KayaSwiftUI.swift").read_text()
for scene in (m.group(1).split() if m else []):
    if f'epthStub("{scene}", on: "macos")' in stubbed:
        continue
    for lang, pat in LANGS + [("rust", "guests/rust/{s}.rs")]:
        if not pathlib.Path(pat.format(s=scene, S=scene.capitalize())).exists():
            continue
        # milestone2's legs drop the scene prefix — they ARE the
        # unprefixed originals, the same exception wired() carries.
        leg = f"run {lang}-swiftui" if scene == "milestone2" else \
            f"run {scene}-{lang}-swiftui"
        if leg not in mac:
            bad.append(
                f'tools/validate-mac.sh: scene "{scene}" has a {lang} guest but '
                f'no leg runs it (wanted "{leg}")')

for b in bad:
    print(f"check-steps: {b}", file=sys.stderr)
sys.exit(1 if bad else 0)
PY
}
sweep_guests || status=1

# AND THE C FLOOR IS SWEPT LIKE EVERY OTHER LANGUAGE, but on its own
# terms. It cannot be a row in the sweep above: that sweep demands a mac
# leg for every scene whose guest file exists, and the C floor
# deliberately does not carry every scene on every lane — it is the
# explicit-tier demonstration, not a breadth guest.
#
# THE BINARY PATH IS THE LEG SIGNATURE, because the three runners spell
# a C leg three ways and the binary they execute is what all three
# share — the thing that cannot be present while the leg is dead.
sweep_c_floor() {
    python3 - <<'PY'
import pathlib, re, sys

RUNNERS = ("tools/validate-mac.sh", "tools/linux/run-suites.sh",
           "tools/deploy-win.sh", "tools/ios/run-sim.sh",
           "tools/android/run-emulator.sh")

makefile = pathlib.Path("guests/c/Makefile").read_text()
m = re.search(r"^SCENES\s*:?=\s*(.+)$", makefile, re.M)
if not m:
    print("check-steps: guests/c/Makefile has no SCENES variable", file=sys.stderr)
    sys.exit(1)
built = m.group(1).split()

bad = []
runs = {}   # scene -> the runners that execute its C binary
for runner in RUNNERS:
    text = pathlib.Path(runner).read_text()
    for name in re.findall(r"c-guests/([A-Za-z0-9_]+)", text):
        # A leg pointing at a binary the Makefile never builds runs
        # nothing at all: `make` succeeds, the file is absent, and the
        # leg dies at exec time on whichever lane owns it.
        if name not in built:
            bad.append(f'{runner}: runs c-guests/{name}, which guests/c/Makefile '
                       f'never builds (SCENES has no "{name}")')
            continue
        runs.setdefault(name, []).append(runner)

# 1. EVERY C GUEST THE FLOOR SHIPS IS RUN SOMEWHERE. This is the clause
#    the gap was about: a leg that falls out of a runner leaves a guest
#    that compiles, ships, and is executed by nobody — the exact shape
#    that hid working OCaml and Haskell clipboard guests for a milestone.
for scene in built:
    if scene not in runs:
        bad.append(f'guests/c/{scene}.c is built by guests/c/Makefile but no lane '
                   f'runs it (wanted a leg naming c-guests/{scene} in one of: '
                   + ", ".join(RUNNERS) + ")")

# 2. A RUNNER THAT NAMES THE C SCENES IT BUILDS RUNS THEM. mac compiles
#    exactly one C guest — `make -C guests/c SCENES=undo` — so that line
#    is the mac lane's own declaration of what its C floor is, and a
#    build with no leg is a binary compiled for nothing. Runners that
#    build the whole floor (linux) declare nothing here and are covered
#    by clause 1.
for runner in RUNNERS:
    text = pathlib.Path(runner).read_text()
    for at in (mm.end() for mm in re.finditer(r"make\s+-C\s+guests/c\b", text)):
        # The logical line, continuations joined: the SCENES= assignment
        # and the make it belongs to are routinely split across two.
        line = ""
        for raw in text[at:].splitlines():
            line += raw
            if not raw.rstrip().endswith("\\"):
                break
        named = re.search(r'SCENES=(?:"([^"]*)"|(\S+))', line)
        if not named:
            continue
        for scene in (named.group(1) or named.group(2)).split():
            if f"c-guests/{scene}" not in text:
                bad.append(f'{runner}: builds the C "{scene}" guest (SCENES={scene}) '
                           f"but runs no leg for it — wire the leg, or stop building it")

for b in bad:
    print(f"check-steps: {b}", file=sys.stderr)
sys.exit(1 if bad else 0)
PY
}
sweep_c_floor || status=1

# EVERY WINDOWS LEG NEEDS ITS LAUNCHER. deploy-win schedules
# C:\kaya\run_<scene>_<lang>.cmd on the VM and those .cmd files are
# CHECKED IN under tools/guest. A leg whose launcher does not exist does
# not fail: schtasks starts nothing, no output appears, and the runner
# waits out its full 300s timeout before calling it a hang.
# NO LEG RUNS TWICE. deploy-win submits by name, and a name submitted
# twice runs the scene twice against the same output file — the second
# verdict silently replaces the first, and a duplicate looks exactly
# like a leg.
duplicate_legs() {
    python3 -c '
import collections
import re
import sys

path = sys.argv[1]
text = sys.stdin.read() if path == "-" else open(path).read()
legs = []
for line in text.splitlines():
    s = line.strip()
    if s.startswith("#"):
        continue
    m = re.match(r"run_suite\s+([a-z0-9_]+)\s*$", s)
    if m:
        legs.append(m.group(1))
bad = [f"{path}: leg \"{n}\" is submitted {c} times"
       for n, c in collections.Counter(legs).items() if c > 1]
print("\n".join(bad))
sys.exit(1 if bad else 0)
' "$1"
}

# The guard guards itself, both directions.
if printf 'run_suite nav_rust\ndrain_suites\nrun_suite nav_rust\n' \
    | duplicate_legs - >/dev/null; then
    echo "check-steps: SELF-TEST FAIL (duplicate leg passed)" >&2
    exit 1
fi
if ! printf 'run_suite nav_rust\nrun_suite nav_python\n' \
    | duplicate_legs - >/dev/null; then
    echo "check-steps: SELF-TEST FAIL (distinct legs rejected)" >&2
    exit 1
fi

out="$(duplicate_legs tools/deploy-win.sh)" || {
    echo "check-steps: deploy-win.sh submits the same leg more than once — the" \
        "second run overwrites the first's output file and buys nothing:" >&2
    echo "$out" >&2
    status=1
}

# The legs a runner SUBMITS, which is not the same as the legs its text
# MENTIONS: every file these rules protect DOCUMENTS the rule, so the
# words appear in prose and a grep over the whole file reads a usage
# comment as a call. Comments are skipped here, as in duplicate_legs.
suite_legs() {
    python3 -c '
import re
import sys

path = sys.argv[1]
text = sys.stdin.read() if path == "-" else open(path).read()
out = []
for line in text.splitlines():
    s = line.strip()
    if s.startswith("#"):
        continue
    m = re.match(r"run_suite\s+([a-z0-9_]+)\s*$", s)
    if m:
        out.append(m.group(1))
print("\n".join(sorted(set(out))))
' "$1"
}

# The guard guards itself, both directions: a leg named only in prose is
# not a leg, and a leg on a real line is.
if [ -n "$(printf '# the all case run_suite calls\n' | suite_legs -)" ]; then
    echo "check-steps: SELF-TEST FAIL (a run_suite named in a COMMENT was read as a leg)" >&2
    exit 1
fi
if [ "$(printf 'run_suite zzprobe_rust\n' | suite_legs -)" != "zzprobe_rust" ]; then
    echo "check-steps: SELF-TEST FAIL (a real run_suite line was not read as a leg)" >&2
    exit 1
fi

launchers() {
    local status=0 leg scene lang
    for leg in $(suite_legs tools/deploy-win.sh); do
        case "$leg" in
            # The milestone2 legs are the unprefixed originals
            # (run_rust.cmd, run_python.cmd, ...).
            rust | python | go | csharp | java) continue ;;
        esac
        scene="${leg%_*}"
        lang="${leg##*_}"
        if [ ! -f "tools/guest/run_${scene}_${lang}.cmd" ]; then
            echo "check-steps: deploy-win runs leg \"$leg\" but" \
                "tools/guest/run_${scene}_${lang}.cmd does not exist —" \
                "that leg would wait out its whole timeout in silence" >&2
            status=1
        fi
    done
    return "$status"
}
launchers || status=1

# The staged WinUI ruling (docs/traps.md), covering THREE scene families
# that share one cause: the leg needs the DESKTOP to itself.
#
#   menus_*      shortcut injection is OS-global — the harness puts the
#                real chord on the system input queue.
#   filedialog_* a file dialog is modal, must hold the FOREGROUND to be
#                driven, and the harness finds it by searching the
#                desktop. Two up at once means BOTH legs fail.
#   save_*       the same OS-global modal chrome: `live_dialog` walks
#                the DESKTOP for a visible `#32770` and takes the first,
#                so a picker up beside it eats the typing.
#
# So deploy-win must run each of these ALONE, between drains. Pinned
# structurally: every such `run_suite` call must have `drain_suites` as
# its nearest significant neighbor on BOTH sides, so a parallelizing
# refactor cannot silently re-pool them.
menu_serial() {
    python3 -c '
import re
import sys

path = sys.argv[1]
lines = [l.strip() for l in (sys.stdin.read() if path == "-" else open(path).read()).splitlines()]

def significant(seq):
    return [l for l in seq if l and not l.startswith("#")]

bad = []
seen = 0
for n, line in enumerate(lines):
    if not re.match(r"run_suite\s+(menus|filedialog|save)_", line):
        continue
    seen += 1
    before = significant(lines[:n])
    after = significant(lines[n + 1:])
    if not before or before[-1] != "drain_suites" or not after or after[0] != "drain_suites":
        bad.append(f"{path}:{n + 1}: {line} lacks the drain/run/drain barrier")
if seen == 0:
    bad.append(f"{path}: no run_suite menus_*/filedialog_*/save_* leg found "
               "(all three scenes must stay wired)")
print("\n".join(bad))
sys.exit(1 if bad else 0)
' "$1"
}

# The guard guards itself: a pooled menu leg must fail.
if printf 'run_suite layout_java\nrun_suite menus_rust\ndrain_suites\n' | menu_serial - >/dev/null; then
    echo "check-steps: SELF-TEST FAIL (pooled menus leg passed)" >&2
    exit 1
fi
# ...and the filedialog family, the second one this rule now covers.
if printf 'run_suite layout_java\nrun_suite filedialog_python\ndrain_suites\n' \
    | menu_serial - >/dev/null; then
    echo "check-steps: SELF-TEST FAIL (pooled filedialog leg passed)" >&2
    exit 1
fi
# ...and the save family, the third — the one this gate was missing on
# the day validate-mac already imposed the rule by hand.
if printf 'run_suite layout_java\nrun_suite save_rust\ndrain_suites\n' \
    | menu_serial - >/dev/null; then
    echo "check-steps: SELF-TEST FAIL (pooled save leg passed)" >&2
    exit 1
fi

out="$(menu_serial tools/deploy-win.sh)" || {
    echo "check-steps: deploy-win.sh menus/filedialog/save legs must run serially between drain_suites calls (docs/traps.md — each needs the desktop to itself):" >&2
    echo "$out" >&2
    status=1
}

# THE CLIPBOARD LEGS ARE MUTUALLY EXCLUSIVE ON EVERY LANE
# (docs/clipboard-plan.md §0d): one system clipboard per session, and
# concurrent legs are processes assigning one variable. On wayland the
# serial primer's F24 tap additionally needs the pool EMPTY (§5b finding
# 3). Pinned structurally: every clipboard leg must have `drain` as its
# nearest significant neighbor on BOTH sides. Continuation lines are
# joined first, because a leg's command usually wraps.
# The family NAME is a parameter because this helper serves two families
# with two different reasons, and a barrier gate whose "nothing matched"
# message names the wrong scene cannot have measured what it prints.
family_serial() { # path leg_regex barrier_word family
    python3 -c '
import re
import sys

path, leg_pattern, barrier, family = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
raw = (sys.stdin.read() if path == "-" else open(path).read()).splitlines()
lines = []
buf = ""
for l in raw:
    s = l.strip()
    if buf:
        s = buf + " " + s
        buf = ""
    if s.endswith("\\"):
        buf = s[:-1].rstrip()
        continue
    lines.append(s)

def significant(seq):
    return [l for l in seq if l and not l.startswith("#")]

bad = []
seen = 0
for n, line in enumerate(lines):
    if not re.match(leg_pattern, line):
        continue
    seen += 1
    before = significant(lines[:n])
    after = significant(lines[n + 1:])
    if not before or before[-1] != barrier or not after or after[0] != barrier:
        bad.append(f"{path}:{n + 1}: {line[:60]} lacks the {barrier}/run/{barrier} barrier")
if seen == 0:
    bad.append(f"{path}: no {family} leg found (the scene must stay wired)")
print("\n".join(bad))
sys.exit(1 if bad else 0)
' "$1" "$2" "$3" "$4"
}

# Each runner spells its pool differently, so the rule is checked in
# each runner's own vocabulary.
MAC_LEG='run .*clipboard-[a-z]'
WIN_LEG='run_suite clipboard_[a-z]'

# The guard guards itself: two clipboard legs sharing the pool must
# fail...
if printf 'drain\nrun clipboard-rust-swiftui env X\nrun clipboard-python-swiftui env X\ndrain\n' \
    | family_serial - "$MAC_LEG" drain clipboard >/dev/null; then
    echo "check-steps: SELF-TEST FAIL (pooled clipboard legs passed)" >&2
    exit 1
fi
# ...a clipboard leg entering a pool that still holds another scene's
# leg (on wayland the primer would tap that leg's window)...
if printf 'run layout-java env X\nrun clipboard-rust env X\ndrain\n' \
    | family_serial - "$MAC_LEG" drain clipboard >/dev/null; then
    echo "check-steps: SELF-TEST FAIL (undrained-before clipboard leg passed)" >&2
    exit 1
fi
# ...and the deploy-win spelling (run_suite vs run, underscore vs dash,
# drain_suites vs drain): a barrier that exists in one runner's
# vocabulary silently exempts every other runner.
if printf 'run_suite clipboard_rust\nrun_suite clipboard_python\ndrain_suites\n' \
    | family_serial - "$WIN_LEG" drain_suites clipboard >/dev/null; then
    echo "check-steps: SELF-TEST FAIL (pooled deploy-win clipboard legs passed)" >&2
    exit 1
fi

for spec in "tools/validate-mac.sh|$MAC_LEG|drain" \
    "tools/linux/run-suites.sh|$MAC_LEG|drain" \
    "tools/deploy-win.sh|$WIN_LEG|drain_suites"; do
    runner="${spec%%|*}"
    rest="${spec#*|}"
    leg="${rest%%|*}"
    barrier="${rest#*|}"
    out="$(family_serial "$runner" "$leg" "$barrier" clipboard)" || {
        echo "check-steps: $runner clipboard legs must run ALONE between drains (docs/clipboard-plan.md §0d — one system clipboard per session):" >&2
        echo "$out" >&2
        status=1
    }
done

# THE SAVE LEGS ARE MUTUALLY EXCLUSIVE ON THE MAC LANE, and the shared
# thing is the PANEL rather than the scene: macOS remembers a save
# panel's last directory as a USER PREFERENCE shared by every process,
# so guests opening panels in one pool trample it (measured 2026-08-10 —
# a leg asserting its own kaya-save-<pid> directory was shown a
# SIBLING's, and serialising them raised the mac ceiling to 560s).
#
# THE OTHER TWO DESKTOP RUNNERS ARE NOT IN THIS LOOP, and the omission
# is the rule rather than a gap:
#
#   deploy-win  IS covered one clause up: its save legs ride the
#               menus/filedialog barrier, because there the shared thing
#               is the desktop's one modal `#32770`.
#   linux       is DELIBERATELY pooled: GTK's save panel is driven over
#               the PER-LEG accessibility bus, remembers no
#               cross-process directory, and each leg's files live under
#               $TMPDIR/kaya-save-<pid>. A barrier there could not fail
#               for the reason it exists (CLAUDE.md invariant 4).
MAC_SAVE_LEG='run save-[a-z]'

# The guard guards itself: two save legs sharing the pool must fail...
if printf 'drain\nrun save-rust-swiftui env X\nrun save-python-swiftui env X\ndrain\n' \
    | family_serial - "$MAC_SAVE_LEG" drain save >/dev/null; then
    echo "check-steps: SELF-TEST FAIL (pooled save legs passed)" >&2
    exit 1
fi
# ...and a save leg entering a pool that still holds another scene's leg,
# which is the same trample from the other side: the sibling's panel is
# what wrote the preference this leg is about to read.
if printf 'run layout-java env X\nrun save-rust-swiftui env X\ndrain\n' \
    | family_serial - "$MAC_SAVE_LEG" drain save >/dev/null; then
    echo "check-steps: SELF-TEST FAIL (undrained-before save leg passed)" >&2
    exit 1
fi

out="$(family_serial tools/validate-mac.sh "$MAC_SAVE_LEG" drain save)" || {
    echo "check-steps: tools/validate-mac.sh save legs must run ALONE between drains (docs/save-plan.md, measured 2026-08-10 — macOS shares a save panel's last directory as a user preference across every process, so a pooled leg is shown a sibling's):" >&2
    echo "$out" >&2
    status=1
}

# THE ANDROID LANE IS NOT IN THAT LOOP, AND THE OMISSION IS THE RULE.
# §0d requires that a leg read the clipboard THAT LEG WROTE; this lane's
# pool is separate emulators, each with its own ClipboardService and the
# host bridge severed both ways (§7 finding 4), so a session here is a
# DEVICE and run_apk's slot lock IS this runner's exclusion.
#
# A drain bracket on top would exclude nothing, and a gate satisfiable
# without exercising the real thing is a bug in the gate (invariant 4).
# So this checks the two things that CAN go wrong: a clipboard leg that
# stops riding run_apk (the tablet is the live temptation — one device,
# no lock), and a run_apk that stops claiming a device.
clipboard_device() { # path
    python3 -c '
import re
import sys

path = sys.argv[1]
text = sys.stdin.read() if path == "-" else open(path).read()
bad = []

seen = 0
for n, line in enumerate(text.splitlines(), 1):
    m = re.match(r"([A-Za-z_][A-Za-z_0-9]*)\s+(clipboard-[a-z0-9]+)\b", line.strip())
    if m is None:
        continue
    seen += 1
    if m.group(1) != "run_apk":
        bad.append(f"{path}:{n}: {m.group(2)} rides {m.group(1)}, not run_apk — only "
                   f"run_apk claims an emulator for the whole leg, and two clipboard "
                   f"legs on one device share that device clipboard")
if seen == 0:
    bad.append(f"{path}: no clipboard leg found (the scene must stay wired)")

start = text.find("run_apk() {")
end = text.find("run_apk_tablet() {")
if start < 0 or end < start:
    bad.append(f"{path}: run_apk()/run_apk_tablet() are not where this gate looks — "
               f"the runner shape moved and the check went vacuous")
else:
    body = text[start:end]
    for claim in ("mkdir \"$LEGS_DIR/.dev-", "rmdir \"$LEGS_DIR/.dev-"):
        if claim in body:
            continue
        bad.append(f"{path}: run_apk no longer does `{claim}...`, so a leg no longer "
                   f"holds its emulator alone — on this lane that lock IS the "
                   f"clipboard exclusion (docs/clipboard-plan.md §0d, §7 finding 4)")
print("\n".join(bad))
sys.exit(1 if bad else 0)
' "$1"
}

# The guard guards itself in the ANDROID spelling, and on the REASON
# rather than the exit code: a negative test whose failure comes from
# somewhere else proves nothing about the clause it covers.
android_device_selftest() { # sample want-fragment label
    local out
    out="$(printf '%b' "$1" | clipboard_device -)" && {
        echo "check-steps: SELF-TEST FAIL ($3 passed)" >&2
        exit 1
    }
    case "$out" in
        *"$2"*) ;;
        *)
            echo "check-steps: SELF-TEST FAIL ($3 failed for another reason: $out)" >&2
            exit 1
            ;;
    esac
}
ANDROID_POOL='run_apk() {\nif mkdir "$LEGS_DIR/.dev-$i"; then\nfi\nrmdir "$LEGS_DIR/.dev-$slot"\n}\nrun_apk_tablet() {\n'
# A clipboard leg on the lockless tablet must fail...
android_device_selftest "run_apk_tablet clipboard-compose apk act clipboard\n$ANDROID_POOL" \
    "not run_apk" "a clipboard leg on the tablet"
# ...a run_apk that stopped claiming a device must fail...
android_device_selftest 'run_apk clipboard-compose apk act clipboard\nrun_apk() {\nserial="${SERIALS[$i]}"\n}\nrun_apk_tablet() {\n' \
    "holds its emulator alone" "an unlocked run_apk"
# ...an unwired scene must fail...
android_device_selftest "$ANDROID_POOL" "no clipboard leg found" "a runner with no clipboard leg"
# ...and the well-formed shape must PASS, or the three above are failing
# for a reason that has nothing to do with what they claim to test.
if ! printf '%b' "run_apk clipboard-compose apk act clipboard\n$ANDROID_POOL" \
    | clipboard_device - >/dev/null; then
    echo "check-steps: SELF-TEST FAIL (a well-formed android clipboard leg was refused)" >&2
    exit 1
fi

out="$(clipboard_device tools/android/run-emulator.sh)" || {
    echo "check-steps: an android clipboard leg must own its emulator for the whole leg (docs/clipboard-plan.md §0d, §7 finding 4 — one clipboard per emulator session, and the slot lock is this lane's drain):" >&2
    echo "$out" >&2
    status=1
}

# THE iOS LANE IS THE ANDROID SHAPE, FOR THE ANDROID REASON: two
# simulators held two different clips at once while the host's stayed
# untouched (docs/clipboard-plan.md §8 finding 5). A session is a
# DEVICE, and the slot queue_leg claims IS this lane's exclusion.
#
# A clipboard leg must ride queue_leg AND run_swiftui_on: the first
# claims the simulator, the second starts the host-side watcher that
# answers clipboard_seed and expect_clipboard — the guest cannot spawn a
# child process here. It must not ride kaya-sim-pad, ONE lockless
# device. And queue_leg must still claim a device, or the first clause
# is a rule about a word.
#
# The swift flavor never spells its own leg name — it is queued in a
# loop over IOS_SWIFT_SCENES — so that list is read as a leg too.
clipboard_ios() { # path
    python3 -c '
import re
import sys

path = sys.argv[1]
text = sys.stdin.read() if path == "-" else open(path).read()
bad = []

# A leg call usually wraps, so continuations are joined first, each
# keeping the line it started on.
joined = []
first = None
buf = ""
for n, raw in enumerate(text.splitlines(), 1):
    s = raw.strip()
    if first is None:
        first = n
    if s.endswith("\\"):
        buf = (buf + " " + s[:-1]).strip()
        continue
    joined.append((first, (buf + " " + s).strip()))
    first, buf = None, ""

seen = 0
for n, line in joined:
    words = line.split()
    if not words or words[0] not in ("queue_leg", "queue_pad_leg", "run_swiftui_on"):
        continue
    if not any(w == "clipboard" or w.startswith("clipboard-") for w in words[1:]):
        continue
    seen += 1
    verb = words[0]
    fn = words[1] if len(words) > 1 else ""
    if verb == "queue_pad_leg":
        bad.append(f"{path}:{n}: a clipboard leg on the iPad — kaya-sim-pad is a single "
                   f"LOCKLESS device (queue_pad_leg claims no slot), so legs on it would "
                   f"share one pasteboard; the phone pool slot lock IS this lane clipboard "
                   f"exclusion (docs/clipboard-plan.md §8 finding 5)")
    elif verb != "queue_leg":
        bad.append(f"{path}:{n}: a clipboard leg runs outside queue_leg, the only thing "
                   f"that claims a simulator for a whole leg")
    elif fn != "run_swiftui_on":
        bad.append(f"{path}:{n}: the clipboard leg rides {fn or verb}, not run_swiftui_on "
                   f"— the host-side seed/read bridge is started there and nowhere else, "
                   f"and iOS cannot answer either verb in the guest process")

# The guest-language suites are legs too, spelled as a list rather than
# as calls. EVERY such list is read, never one by name: a gate that knew
# only the first IOS_<LANG>_SCENES would go half-vacuous the moment a
# second suite landed.
lists = list(re.finditer("IOS_([A-Z0-9]+)_SCENES=\"([^\"]*)\"", text))
if not lists:
    bad.append(f"{path}: no IOS_<LANG>_SCENES list is where this gate looks — the runner "
               f"shape moved and the guest-suite half of the check went vacuous")
for scenes in lists:
    lang = scenes.group(1)
    if not any(entry.split(":")[0] == "clipboard" for entry in scenes.group(2).split()):
        continue
    seen += 1
    block = text[scenes.end():]
    stop = block.find("\n    drain\n")
    if stop >= 0:
        block = block[:stop]
    if "queue_pad_leg" in block:
        bad.append(f"{path}: clipboard is in IOS_{lang}_SCENES and that block queues with "
                   f"queue_pad_leg — the pad is one lockless device")
    if "queue_leg " not in block:
        bad.append(f"{path}: clipboard is in IOS_{lang}_SCENES but that block no longer "
                   f"queues through queue_leg, so the {lang.lower()} leg claims no device")

if seen == 0:
    bad.append(f"{path}: no clipboard leg found (the scene must stay wired)")

# AND THE BOARD MUST BELONG TO THE DEVICE BEFORE ANY LEG RUNS.
# Simulator.app relays the macOS pasteboard into and out of every booted
# simulator while Edit > Automatically Sync Pasteboard is on, which is
# the default, so the slot lock excludes other LEGS and nothing else
# (docs/clipboard-plan.md §8 finding 7). The runner MEASURES the
# isolation and refuses. Matched with an argument after the name: a bare
# name would match the definition too.
relay_call = None
first_leg = None
for n, raw in enumerate(text.splitlines(), 1):
    s = raw.strip()
    if s.startswith("#"):
        continue
    if relay_call is None and re.match(r"clip_relay_check\s+\S", s):
        relay_call = n
    if first_leg is None and re.match(r"queue_(pad_)?leg\s+\S", s):
        first_leg = n
if relay_call is None:
    bad.append(f"{path}: nothing measures the clipboard isolation — the pasteboard of a "
               f"booted simulator belongs to Simulator.app too whenever it is running, and "
               f"the legs then share one board with the mac lane (docs/clipboard-plan.md "
               f"§8 finding 7). Call clip_relay_check before the legs")
elif first_leg is not None and relay_call > first_leg:
    bad.append(f"{path}:{relay_call}: the clipboard isolation is measured AFTER the first "
               f"leg is queued (line {first_leg}) — a lane that dies at leg 40 teaches "
               f"nothing a lane that dies in five seconds does not")

start = text.find("queue_leg() {")
end = text.find("queue_pad_leg() {")
if start < 0 or end < start:
    bad.append(f"{path}: queue_leg()/queue_pad_leg() are not where this gate looks — the "
               f"runner shape moved and the check went vacuous")
else:
    body = text[start:end]
    for claim in ("mkdir \"$LEGS_DIR/.dev-", "rmdir \"$LEGS_DIR/.dev-"):
        if claim in body:
            continue
        bad.append(f"{path}: queue_leg no longer does `{claim}...`, so a leg no longer "
                   f"holds its simulator alone — on this lane that lock IS the clipboard "
                   f"exclusion (docs/clipboard-plan.md §8 finding 5)")

# NO LIVE LINE TOUCHES A HOST OR SHARED PASTEBOARD PATH: transiting the
# macOS pasteboard delivers asynchronously, so the guest read races the
# window, and under validate-all it would race the clipboard legs of the
# mac lane. The ratified shape is a spawned on-device write
# (tools/ios/clipctl), so the pasteboard tools may appear here only in
# comments explaining exactly this (docs/clipboard-plan.md §8 finding 6).
for n, raw in enumerate(text.splitlines(), 1):
    s = raw.strip()
    if s.startswith("#"):
        continue
    if re.search(r"\bpbcopy\b|\bpbpaste\b|\bpbsync\b|set the clipboard", s):
        bad.append(f"{path}:{n}: a live line touches a pasteboard tool (`{s[:60]}`) — "
                   f"the clipboard seed/read is a spawned on-device process precisely so "
                   f"this lane cannot race the mac lane legs or its own delivery window "
                   f"(docs/clipboard-plan.md §8 finding 6)")
print("\n".join(bad))
sys.exit(1 if bad else 0)
' "$1"
}

# AND THE PICKER MUST BE AIMABLE BEFORE ANY LEG RUNS: the FIRST document
# picker a simulator shows after a boot opens at the app's container
# root instead of the directory it was aimed at (docs/traps.md), and the
# scene then fails three steps deep at file_choose on a row that
# genuinely is not in the list. So run-sim.sh warms the document stack
# per device and this keeps it there. Matched with an argument after the
# name, so the definition line cannot satisfy the clause.
picker_ios() { # path
    python3 -c '
import re
import sys

path = sys.argv[1]
text = sys.stdin.read() if path == "-" else open(path).read()
bad = []

warm_call = None
first_leg = None
for n, raw in enumerate(text.splitlines(), 1):
    s = raw.strip()
    if s.startswith("#"):
        continue
    if warm_call is None and re.match(r"picker_warm\s+\S", s):
        warm_call = n
    if first_leg is None and re.match(r"queue_(pad_)?leg\s+\S", s):
        first_leg = n
if warm_call is None:
    bad.append(f"{path}: nothing warms the document picker — the first picker a simulator "
               f"shows after a boot opens at the container root rather than where it was "
               f"aimed, and the filedialog scene then fails at file_choose on a row that is "
               f"really not there (docs/traps.md). Call picker_warm before the legs")
elif first_leg is not None and warm_call > first_leg:
    bad.append(f"{path}:{warm_call}: the picker is warmed AFTER the first leg is queued "
               f"(line {first_leg}) — the leg that needs it may already have run")
print("\n".join(bad))
sys.exit(1 if bad else 0)
' "$1"
}

# THE GUARD GUARDS ITSELF, on the REAL runner rather than a fixture
# (docs/traps.md: the wayland seat guard passed VACUOUSLY TWICE). Each
# perturbation prints its substitution count and the copy is refused if
# it did not apply, and each refusal is checked for its REASON.
IOS_T="$(mktemp -d)"

# <source> <regex> <replacement> <destination> -> substitution count
ios_perturb() {
    python3 -c '
import re
import sys

text = open(sys.argv[1]).read()
out, n = re.subn(sys.argv[2], sys.argv[3], text)
open(sys.argv[4], "w").write(out)
print(n)
' "$@"
}

ios_applied() { # count label [want, default 1]
    local want="${3:-1}"
    if [ "$1" = "$want" ]; then
        return 0
    fi
    echo "check-steps: SELF-TEST FAIL ($2 applied $1 times, want $want — an unchanged copy cannot prove the rule fires)" >&2
    rm -rf "$IOS_T"
    exit 1
}

ios_selftest() { # copy want-fragment label
    local out
    out="$(clipboard_ios "$1")" && {
        echo "check-steps: SELF-TEST FAIL ($3 passed)" >&2
        rm -rf "$IOS_T"
        exit 1
    }
    case "$out" in
        *"$2"*) ;;
        *)
            echo "check-steps: SELF-TEST FAIL ($3 failed for another reason: $out)" >&2
            rm -rf "$IOS_T"
            exit 1
            ;;
    esac
}

# A clipboard leg moved onto the lockless pad must fail...
hits="$(ios_perturb tools/ios/run-sim.sh \
    'queue_leg (run_swiftui_on clipboard-swiftui)' 'queue_pad_leg \1' "$IOS_T/pad.sh")"
ios_applied "$hits" "the pad perturbation"
ios_selftest "$IOS_T/pad.sh" "on the iPad" "a clipboard leg on the pad"

# ...a clipboard leg that claims no device slot at all must fail...
hits="$(ios_perturb tools/ios/run-sim.sh \
    'queue_leg (run_swiftui_on clipboard-swiftui)' '\1' "$IOS_T/bare.sh")"
ios_applied "$hits" "the unqueued-leg perturbation"
ios_selftest "$IOS_T/bare.sh" "outside queue_leg" "a clipboard leg outside queue_leg"

# ...a queue_leg that stopped claiming a device must fail...
hits="$(ios_perturb tools/ios/run-sim.sh \
    'mkdir "\$LEGS_DIR/\.dev-\$i"' 'mkdir "$LEGS_DIR/live-$i"' "$IOS_T/unlocked.sh")"
ios_applied "$hits" "the slot-lock perturbation"
ios_selftest "$IOS_T/unlocked.sh" "holds its simulator alone" "an unlocked queue_leg"

# ...and an unwired scene must fail, which takes EVERY leg away. The
# expected count is the number of IOS_<LANG>_SCENES lists — 2 today —
# and it is STATED rather than derived, so a third guest suite lands as
# a loud "applied 3 times, want 2".
hits="$(ios_perturb tools/ios/run-sim.sh \
    'queue_leg run_swiftui_on clipboard-swiftui[\s\S]*?clipboard clipboard\n' '' \
    "$IOS_T/half.sh")"
ios_applied "$hits" "the rust-leg removal"
# The word is deleted FROM THE TWO LIST ASSIGNMENTS BY NAME, never "the
# word before the closing quote": one more word appended to a list turns
# a tail-anchored pattern into 0 substitutions.
hits="$(ios_perturb "$IOS_T/half.sh" '(IOS_[A-Z]+_SCENES="[^"]*) clipboard' '\1' "$IOS_T/unwired.sh")"
ios_applied "$hits" "the guest-list removal" 2
ios_selftest "$IOS_T/unwired.sh" "no clipboard leg found" "a runner with no clipboard leg"

# ...and a live host-pasteboard line must fail: the seed once rode
# pbcopy+pbsync and raced both its own delivery window and (under
# validate-all) the mac lane's legs.
hits="$(ios_perturb tools/ios/run-sim.sh \
    '(?m)^    echo ok$' '    printf seed | pbcopy\n    echo ok' "$IOS_T/hostboard.sh")"
ios_applied "$hits" "the host-pasteboard perturbation"
ios_selftest "$IOS_T/hostboard.sh" "touches a pasteboard tool" "a live pbcopy in the runner"

# ...and a runner that never asks whether the board is the device's own
# must fail: with Simulator.app running, it is Simulator.app's too.
hits="$(ios_perturb tools/ios/run-sim.sh \
    '(?m)^clip_relay_check .*\n' '' "$IOS_T/norelay.sh")"
ios_applied "$hits" "the relay-check removal"
ios_selftest "$IOS_T/norelay.sh" "nothing measures the clipboard isolation" \
    "a runner that never measures the isolation"

# ...and one that measures it only after the legs are queued must fail.
hits="$(ios_perturb tools/ios/run-sim.sh \
    '(?m)^clip_relay_check (.*)\n' '' "$IOS_T/late.sh")"
ios_applied "$hits" "the late-check removal half"
hits="$(ios_perturb "$IOS_T/late.sh" \
    '(?m)^    drain\n    timing swiftui-build\+legs' \
    'clip_relay_check "${UDIDS[0]}" "$PAD_UDID" || exit 1\n    drain\n    timing swiftui-build+legs' \
    "$IOS_T/late.sh")"
ios_applied "$hits" "the late-check insertion half"
ios_selftest "$IOS_T/late.sh" "measured AFTER the first leg" \
    "a runner that measures the isolation too late"

# ...and the picker half, with its own refusals: a runner that never
# warms the document stack must fail...
picker_selftest() { # copy want-fragment label
    local out
    out="$(picker_ios "$1")" && {
        echo "check-steps: SELF-TEST FAIL ($3 passed)" >&2
        rm -rf "$IOS_T"
        exit 1
    }
    case "$out" in
        *"$2"*) ;;
        *)
            echo "check-steps: SELF-TEST FAIL ($3 failed for another reason: $out)" >&2
            rm -rf "$IOS_T"
            exit 1
            ;;
    esac
}

hits="$(ios_perturb tools/ios/run-sim.sh \
    '(?m)^    picker_warm .*\n' '' "$IOS_T/nowarm.sh")"
ios_applied "$hits" "the picker-warm removal"
picker_selftest "$IOS_T/nowarm.sh" "nothing warms the document picker" \
    "a runner that never warms the picker"

# ...and one that warms it only after the legs are queued must fail.
hits="$(ios_perturb tools/ios/run-sim.sh \
    '(?m)^    picker_warm (.*)\n' '' "$IOS_T/latewarm.sh")"
ios_applied "$hits" "the late-warm removal half"
hits="$(ios_perturb "$IOS_T/latewarm.sh" \
    '(?m)^    drain\n    timing swiftui-build\+legs' \
    'picker_warm "${UDIDS[0]}" || exit 1\n    drain\n    timing swiftui-build+legs' \
    "$IOS_T/latewarm.sh")"
ios_applied "$hits" "the late-warm insertion half"
picker_selftest "$IOS_T/latewarm.sh" "warmed AFTER the first leg" \
    "a runner that warms the picker too late"

rm -rf "$IOS_T"

# The accept direction is the real check itself, immediately below: a
# rule that refused everything would fail here rather than pass quietly.
out="$(clipboard_ios tools/ios/run-sim.sh)" || {
    echo "check-steps: an iOS clipboard leg must own its simulator for the whole leg (docs/clipboard-plan.md §8 finding 5 — one pasteboard per device, and the slot lock is this lane's drain):" >&2
    echo "$out" >&2
    status=1
}

out="$(picker_ios tools/ios/run-sim.sh)" || {
    echo "check-steps: the iOS lane must warm each device's document stack before its legs (docs/traps.md — the first picker after a boot opens at the container root, not where it was aimed):" >&2
    echo "$out" >&2
    status=1
}

# EVERY ANDROID SCENE SELECTOR NEEDS AN ARM IN THE GUEST. One APK hosts
# every scene, so the leg selects one through `--es KAYA_SELFTEST
# <scene>` and the guest matches it. A name the match does not carry
# used to fall through to the default scene: the leg launched, a scene
# ran, and every step failed against labels from a scene nobody
# selected. The guest now panics on an unknown name; this makes it a
# two-second answer instead of an emulator boot.
#
# THREE APKs, EACH WITH ITS OWN SELECTOR, so the pair is an argument
# rather than a constant.
#
# THE EMPTY-SELECTION ARM IS THE ANTI-VACUITY CLAUSE: if the activity
# regex stops matching the runner, `selected` is empty, `missing` is
# empty, and the clause PASSES having compared nothing.
android_scenes() { # runner guest activity-regex arm-regex [exempt...]
    local runner="$1" guest="$2" activity="$3" arm="$4"
    shift 4
    python3 -c '
import re
import sys

runner, guest, activity, arm = sys.argv[1:5]
exempt = set(sys.argv[5:])
selected = set(re.findall(activity + r" ([a-z0-9]+)", open(runner).read()))
armed = set(re.findall(arm, open(guest).read(), re.M))
if not selected:
    print(f"{runner} launches no scene through {activity} — the activity "
          f"pattern matched nothing, so this clause compared nothing")
    sys.exit(1)
missing = sorted(selected - armed - exempt)
for name in missing:
    print(f"{runner} selects scene {name!r}, which {guest} has no arm for")
sys.exit(1 if missing else 0)
' "$runner" "$guest" "$activity" "$arm" "$@"
}

# The guard guards itself in every direction: an unarmed selector must
# fail, an activity pattern matching nothing must fail, and each ARM
# SHAPE gets its own negative — a `match` arm and a map key are
# different text.
sample="$(mktemp -d)"
echo 'dev.kaya.milestone2/.MainActivity ghostscene' >"$sample/runner.sh"
echo 'Ok("entry") => entry::app(ctx),' >"$sample/guest.rs"
if android_scenes "$sample/runner.sh" "$sample/guest.rs" \
        'dev\.kaya\.milestone2/\.MainActivity' 'Ok\("([a-z0-9]+)"\)' >/dev/null; then
    echo "check-steps: SELF-TEST FAIL (an unarmed android selector passed)" >&2
    rm -rf "$sample"
    exit 1
fi
if android_scenes "$sample/runner.sh" "$sample/guest.rs" \
        'dev\.kaya\.nosuchmodule/\.MainActivity' 'Ok\("([a-z0-9]+)"\)' >/dev/null; then
    echo "check-steps: SELF-TEST FAIL (an activity pattern matching NOTHING" \
        "passed — the clause compared nothing and said OK)" >&2
    rm -rf "$sample"
    exit 1
fi
printf 'dev.kaya.milestone2go/.MainActivity ghostscene\n' >"$sample/runner-go.sh"
printf 'var scenes = map[string]func() *kaya.App{\n\t"entry": entry.App,\n}\n' \
    >"$sample/guest.go"
if android_scenes "$sample/runner-go.sh" "$sample/guest.go" \
        'dev\.kaya\.milestone2go/\.MainActivity' '^\t"([a-z0-9]+)":' >/dev/null; then
    echo "check-steps: SELF-TEST FAIL (an unarmed GO scene table passed — the" \
        "map-key pattern is not reading the table)" >&2
    rm -rf "$sample"
    exit 1
fi
rm -rf "$sample"

out="$(android_scenes tools/android/run-emulator.sh guests/rust/milestone2_android.rs \
    'dev\.kaya\.milestone2/\.MainActivity' 'Ok\("([a-z0-9]+)"\)')" || {
    echo "check-steps: an android leg selects a scene the APK's guest cannot run:" >&2
    echo "$out" >&2
    status=1
}

# The JVM APK's selector ends in `else -> Milestone2::app`, so an
# unarmed name does not die — it SILENTLY RUNS MILESTONE2. "1" is exempt
# because it IS that default arm, reached deliberately.
out="$(android_scenes tools/android/run-emulator.sh \
    android/milestone2kt/src/main/kotlin/dev/kaya/milestone2kt/MainActivity.kt \
    'dev\.kaya\.milestone2kt/\.MainActivity' '"([a-z0-9]+)" ->' 1)" || {
    echo "check-steps: an android JVM leg selects a scene MainActivity.kt has no" \
        "arm for — it would run milestone2 instead, silently:" >&2
    echo "$out" >&2
    status=1
}

# The Go APK. Its arms are a map literal, one key per line, which is why
# the table in that file is a table and not a switch. THE SAME TABLE
# SERVES THE DESKTOPS since the guests collapsed into one binary, and
# the clause below reads it from the other three runners.
out="$(android_scenes tools/android/run-emulator.sh guests/go/cmd/scenes.go \
    'dev\.kaya\.milestone2go/\.MainActivity' '^\t"([a-z0-9]+)":')" || {
    echo "check-steps: an android Go leg selects a scene the Go guest does not" \
        "carry (guests/go/cmd/scenes.go's table):" >&2
    echo "$out" >&2
    status=1
}

# AND EVERY DESKTOP GO LEG, against the same table: the Go guests are
# one binary now, so the NAME is the only thing that decides what runs,
# and a name the table lacks panics after a build, a launch and a
# window, on three lanes.
#
# THE THREE RUNNERS SPELL THE SELECTION DIFFERENTLY, so each gets its
# own pattern: mac and linux put `KAYA_SELFTEST=<scene>` on the leg line
# (often continued, so continuations are joined first) beside
# go-guests/kaya-go; windows sets it in tools/guest/run_<leg>_go.cmd.
#
# AND THE DEFAULT IS A NAME LIKE ANY OTHER: the bare `run go-swiftui …`
# leg passes nothing, so main_desktop.go falls back to `defaultScene`,
# which has to be a key in this table.
#
# THE EMPTY-SELECTION ARM IS THE ANTI-VACUITY CLAUSE, as above.
go_desktop_scenes() { # table runner-or-cmd-dir...
    python3 -c '
import pathlib
import re
import sys

table, runners = sys.argv[1], sys.argv[2:]
text = pathlib.Path(table).read_text()
armed = set(re.findall(r"^\t\"([a-z0-9]+)\":", text, re.M))
bad = []
if not armed:
    bad.append(f"{table}: no scene table here — the map-key pattern matched "
               f"nothing, so this clause compared nothing")
default = re.search(r"^const defaultScene = \"([a-z0-9]+)\"", text, re.M)
if not default:
    bad.append(f"{table}: no `const defaultScene` — the desktop tail falls "
               f"back to it when KAYA_SELFTEST is empty, and this clause "
               f"cannot check a name it cannot find")
elif armed and default.group(1) not in armed:
    bad.append(f"{table}: defaultScene is {default.group(1)!r}, which the "
               f"table has no key for — the bare Go leg would panic")
for runner in runners:
    path = pathlib.Path(runner)
    if path.is_dir():
        files = sorted(path.glob("*_go.cmd"))
        selected = set()
        for f in files:
            src = f.read_text()
            if "dev.kaya/guests/go/cmd" not in src:
                bad.append(f"{f}: a go launcher that does not build "
                           f"dev.kaya/guests/go/cmd")
                continue
            names = re.findall(r"set KAYA_SELFTEST=([A-Za-z0-9]+)", src)
            if not names:
                bad.append(f"{f}: builds the Go guest and sets no "
                           f"KAYA_SELFTEST, so it runs whatever the default is")
            selected.update(names)
    else:
        src = path.read_text().replace("\\\n", " ")
        selected = set(re.findall(
            r"KAYA_SELFTEST=([a-z0-9]+)[^\n]*go-guests/kaya-go", src))
    if not selected:
        bad.append(f"{runner}: names no Go scene — the selection pattern "
                   f"matched nothing, so this clause compared nothing")
        continue
    for name in sorted(selected - armed):
        bad.append(f"{runner} runs the Go guest with KAYA_SELFTEST={name}, "
                   f"which {table} has no key for")
print("\n".join(bad))
sys.exit(1 if bad else 0)
' "$@"
}

# Watched failing in every direction it can go wrong: an unarmed name, a
# pattern that matches nothing, a default that is not a scene, and the
# windows spelling — which is a different pattern over different files
# and proves nothing about the shell one.
sample="$(mktemp -d)"
printf 'var scenes = map[string]func() *kaya.App{\n\t"entry": entry.App,\n}\nconst defaultScene = "entry"\n' \
    >"$sample/table.go"
printf 'run ghost-go env KAYA_SELFTEST=ghost target/go-guests/kaya-go\n' \
    >"$sample/runner.sh"
printf 'run entry-go env KAYA_SELFTEST=entry target/go-guests/kaya-go\n' \
    >"$sample/runner-ok.sh"
printf 'run rust env target/debug/examples/milestone2\n' >"$sample/runner-none.sh"
printf 'var scenes = map[string]func() *kaya.App{\n\t"entry": entry.App,\n}\nconst defaultScene = "nope"\n' \
    >"$sample/table-bad.go"
mkdir -p "$sample/guest"
printf 'set KAYA_SELFTEST=ghost\ngo build -o C:\\kaya\\ghost_go.exe dev.kaya/guests/go/cmd\n' \
    >"$sample/guest/run_ghost_go.cmd"
if go_desktop_scenes "$sample/table.go" "$sample/runner.sh" >/dev/null; then
    echo "check-steps: SELF-TEST FAIL (a desktop Go leg naming a scene the table" \
        "lacks passed)" >&2
    rm -rf "$sample"
    exit 1
fi
if go_desktop_scenes "$sample/table.go" "$sample/runner-none.sh" >/dev/null; then
    echo "check-steps: SELF-TEST FAIL (a runner selecting NO go scene passed — the" \
        "clause compared nothing and said OK)" >&2
    rm -rf "$sample"
    exit 1
fi
if go_desktop_scenes "$sample/table-bad.go" "$sample/runner-ok.sh" >/dev/null; then
    echo "check-steps: SELF-TEST FAIL (a defaultScene with no key in the table" \
        "passed — the bare Go leg is the one that would die)" >&2
    rm -rf "$sample"
    exit 1
fi
if go_desktop_scenes "$sample/table.go" "$sample/guest" >/dev/null; then
    echo "check-steps: SELF-TEST FAIL (a windows launcher naming a scene the table" \
        "lacks passed — the .cmd pattern is not reading the launchers)" >&2
    rm -rf "$sample"
    exit 1
fi
if ! go_desktop_scenes "$sample/table.go" "$sample/runner-ok.sh" >/dev/null; then
    echo "check-steps: SELF-TEST FAIL (a leg naming an armed scene was refused)" >&2
    rm -rf "$sample"
    exit 1
fi
rm -rf "$sample"

out="$(go_desktop_scenes guests/go/cmd/scenes.go \
    tools/validate-mac.sh tools/linux/run-suites.sh tools/guest)" || {
    echo "check-steps: a desktop Go leg selects a scene the one Go binary does" \
        "not carry (guests/go/cmd/scenes.go's table):" >&2
    echo "$out" >&2
    status=1
}

# THE iOS PICKER'S SILENT WIRINGS. Each of these fails in a way that
# looks like a backend bug rather than a harness one. (The file_mode
# clause lives in tools/check-file-modes.sh, which reads the numbers out
# of crates/kaya/src/spec.rs rather than hard-coding them.)
ios_picker() {
    python3 -c '
import pathlib
import sys

bad = []

# 1. THE ACCESSIBILITY TOKEN MUST BE RETIRED. Every response from
#    sendAccessibilityRequestAsync: goes back through
#    _resetBridgeTokensForResponse:. Drop it and NOTHING looks wrong:
#    the reads keep working and the next TAP is silently ignored, so the
#    call that proves the transport works is the one that hides the bug.
#    Measured 2026-07-31 (docs/traps.md).
simdrive = pathlib.Path("tools/ios/simdrive/main.swift").read_text()
if "sendAccessibilityRequestAsync" in simdrive \
        and "_resetBridgeTokensForResponse" not in simdrive:
    bad.append("tools/ios/simdrive/main.swift reads accessibility but never retires the "
               "token (_resetBridgeTokensForResponse:) — the reads would keep working and "
               "every tap would be silently ignored")

# 2. THE BUNDLE MUST PUBLISH ITS DOCUMENTS. Without both keys the
#    document picker cannot see the app own files at all, and a picker
#    aimed at them opens somewhere else with no error anywhere.
plist = pathlib.Path("tools/ios/Info.plist.in").read_text()
for key in ("UIFileSharingEnabled", "LSSupportsOpeningDocumentsInPlace"):
    if key not in plist:
        bad.append(f"tools/ios/Info.plist.in is missing {key} — the picker could not browse "
                   f"the app own Documents and the filedialog leg would fail as though the "
                   f"backend were wrong")

for line in bad:
    print(line)
sys.exit(1 if bad else 0)
'
}

out="$(ios_picker)" || {
    echo "check-steps: the iOS picker wiring has a silent hole:" >&2
    echo "$out" >&2
    status=1
}

# THE GENERATOR MUST NOT OUTRUN WHAT IT GENERATED. gen-bindings.sh
# stamps a hash of tools/kaya-bindgen/src/*.rs beside the bindings it
# wrote; if the generator moved since, the checked-in bindings are stale
# and everything downstream is a lie that COMPILES (docs/traps.md).
# `gen-bindings.sh --check` is the authoritative answer and regenerates
# to get it; this is the cheap one, so it can be asked constantly.
generator_stamp() {
    local root="${1:-.}"
    local want have
    want=$(cat "$root"/tools/kaya-bindgen/src/*.rs | shasum -a 256 | cut -c1-16)
    have=$(cat "$root/bindings/.generator-id" 2>/dev/null || echo "")
    if [ "$want" != "$have" ]; then
        echo "the binding generator has changed since the bindings were" \
            "generated (generator $want, bindings say ${have:-<no stamp>}) —" \
            "run tools/gen-bindings.sh"
        return 1
    fi
}

# The guard guards itself: a moved generator must be caught.
sample="$(mktemp -d)"
mkdir -p "$sample/tools/kaya-bindgen/src" "$sample/bindings"
echo "// a generator that moved" >"$sample/tools/kaya-bindgen/src/main.rs"
echo "0000000000000000" >"$sample/bindings/.generator-id"
if generator_stamp "$sample" >/dev/null; then
    echo "check-steps: SELF-TEST FAIL (a stale generator stamp passed)" >&2
    rm -rf "$sample"
    exit 1
fi
rm -rf "$sample"

out="$(generator_stamp "$ROOT")" || {
    echo "check-steps: $out" >&2
    status=1
}

[ "$status" = 0 ] && echo "check-steps: OK"
exit "$status"
