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

# The opening lint: a script must OPEN with an observation. Expects
# are bounded retries (harness.rs POLL_DEADLINE), and the FIRST one
# doubles as the scene-ready wait — a script that opens with an
# action races the mount on every platform at once (scripted settles
# are gone; retries replaced them, 2026-07-22).
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

# WHICH WIDTHS AN expect_split MAY SAMPLE. Each backend defers the
# one-pane/two-pane decision to its platform's own component, and those
# components disagree about where the line falls: GNOME's documented
# breakpoint collapses below 400sp, Material's standard directive wants
# 840dp before it shows two panes, and TwoPaneView's default sits
# between them. A width inside that band is legitimately one pane on one
# platform and two on another.
#
# The scripts are compared byte-for-byte on every lane, so an assertion
# taken in the band cannot be satisfied everywhere at once. What makes
# this worth a gate rather than a comment is how the failure READS: one
# platform disagreeing about pane count looks exactly like a broken
# lowering, and the width that caused it is three lines up the file.
#
# THE TWO FORMS ARE POLICED DIFFERENTLY, and the split is exactly the
# claim each makes. A LITERAL (`expect_split "regular/split"`) names
# WHICH arm ran, which is a statement about the width — so it needs a
# width the file itself set, outside the band. The BARE form asserts
# the invariant (a regular window must not show one pane while its
# stack holds two) and is therefore legal at a width the file never
# names: it is the only spelling a phone or tablet lane can run, since
# those hosts do not command their own window size. A width the file
# DOES name still has to clear the band in either form — the invariant
# is not vacuous in there, it is WRONG in there (kaya calls a window
# regular at 600 while Material waits for 840, so an 800dp Compose
# window honestly reports regular/stacked).
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

# THE TYPING VERB'S TWO RULES, both of them about the fact that `type`
# is REAL KEYSTROKES at the FOCUSED widget (harness.rs Step::Type,
# docs/undo-plan.md A8) rather than a write at a named target.
#
# 1. THE PAYLOAD IS PRINTABLE ASCII. A keystroke needs one keycode per
#    character and that mapping is only platform-independent inside
#    0x20..0x7e; a line break is worse than unmappable, because Return
#    is a COMMAND whose meaning depends on the widget it lands in (a
#    newline in a textarea, activation in an entry). harness.rs refuses
#    it at parse — that is the wall — and this is the two-second answer
#    with a file and a line, rather than a leg that boots a window to
#    tell you the script was bad.
# 2. A SCRIPT THAT TYPES MUST HAVE ASSERTED FOCUS FIRST. The verb takes
#    no target: whoever holds focus receives the keys, which is the
#    routing question the undo tier turns on. A script that types
#    without an `expect_focused` above it has no idea where its
#    keystrokes went — and because expects are bounded retries and
#    actions are not, that assertion is also the WAIT for focus to land.
#    Without it the keys race the focus command and the failure surfaces
#    three steps later as a field that never got the text.
typing_lint() {
    python3 -c '
import re
import sys

path = sys.argv[1]
text = sys.stdin.read() if path == "-" else open(path).read()
bad = []
focused = False
for lineno, line in enumerate(text.splitlines(), 1):
    if line.lstrip().startswith("#"):
        continue
    for step in line.split(";"):
        s = step.strip()
        if s.startswith("expect_focused"):
            focused = True
            continue
        m = re.match(r"type\s+\"(.*)\"\s*$", s)
        if not m:
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

for f in tools/scenes/*.steps; do
    out="$(typing_lint "$f")" || {
        echo "check-steps: $f types in a way no keyboard can:" >&2
        echo "$out" >&2
        status=1
    }
done

# Every scene script must be reachable by name from harness::script.
# That match ends in a catch-all returning the milestone2 script, so an
# unregistered scene does not fail — it silently runs a DIFFERENT
# script, and a leg that passes then proves nothing about the scene it
# claims to be. Registration is easy to forget precisely because

# (The former `registered` check lived here: it asserted every scene had
# an arm in harness::script's include_str! match. That match is gone —
# the Rust backends now resolve a scene NAME to
# <KAYA_SCENES_DIR>/<name>.steps, and a missing scene makes spawn fail
# loudly instead of falling through to a catch-all that silently ran
# the milestone2 script. The gate policed a registry that no longer
# exists; the failure it guarded is now structural.)

# Every scene must be WIRED into every platform runner, not merely
# registered: a scene can exist, parse, and be registered, yet run
# nowhere on a platform — the layout scene shipped exactly that way
# (functionally green on mac, absent from every suite), and the iOS
# SwiftUI suite later missed the grow/layout legs the same silent way.
# The grep demands each runner's LEG SIGNATURE, not the bare name: a
# scene listed in SCENES whose leg block is dead (cloned below the
# script's exit, commented out, mangled) satisfies a name check while
# running nowhere — the sections regex-clone near-miss, 2026-07-22.
# (iOS and Android stay name-level: their legs derive mechanically
# from the scene list, so the name IS the wiring — except the scenes
# each platform deliberately skips, carved out below.)
#
# EXCEPT where the backend says it has not got there yet. A depth slice
# lands protocol + one backend + one binding first (CLAUDE.md's
# sequencing), and the backends left behind declare it with
# `depth_stub("<scene>")` — the same call check-stubs reads from the
# other side. The two gates then state one rule between them: a scene's
# legs are wired on a runner IF AND ONLY IF that runner's backend has
# the feature. Neither half can be skipped, and the interim state of a
# depth slice is expressible without turning either off. The exemption
# costs a DECLARATION in the backend source, so the layout class this
# gate was written for — green on mac, absent from every suite, nobody
# having declared anything — is untouched.
#
# THE EXEMPTION IS KEYED ON THE SCENE'S FEATURES, NOT ITS NAME, and it
# has to be, or the two gates contradict each other. tools/scenes are
# shared verbatim, so a scene can demand a feature it is not named after:
# `todos.steps` activates Edit>Undo. If a stub on `undo` held only the
# `undo` legs off a runner, the cross-check below would fail that same
# runner for its `todos` legs while this half demanded them — no tree
# could satisfy both, and the next agent would delete a clause to get
# green. Keyed on features, the interim state stays expressible: a
# Compose stub on `undo` holds `todos` AND `undo` off the android runner,
# and the JNI landing hands both back the same day.
# tools/lib/scene-features.py derives the pairs; it is the SAME predicate
# the cross-check uses, computed once so the two cannot drift.
wired() {
    local runner scene sig status=0 exempt
    exempt="$(python3 tools/lib/scene-features.py --mode exempt)"
    local rc=$?
    if [ "$rc" -ne 0 ]; then
        echo "check-steps: scene-features.py could not derive the depth-stub exemptions" >&2
        return 1
    fi
    # Padded and delimited, so a scene name that is a prefix of another
    # cannot borrow its exemption. (The runner -> backend roster and the
    # three declaration spellings moved into the helper with the
    # predicate; they used to be inlined here, in the third of four
    # copies.)
    #
    # NOT THROUGH A COMMAND SUBSTITUTION, and that is the whole bug this
    # line used to have: `$(printf '\n%s\n' ...)` STRIPS the trailing
    # newline it just added, so the pattern below — which requires one
    # after the pair — could never match the LAST derived exemption.
    # Measured 2026-08-06 on the dirty slice, the first tree in this
    # project's history with any depth stub at all: four pairs derived,
    # three honored, and the android one silently demanded legs its
    # backend had just declared it could not run. An empty exemption
    # list is why nobody saw it sooner.
    exempt=$'\n'"$exempt"$'\n'
    for scene in tools/scenes/*.steps; do
        scene="$(basename "${scene%.steps}")"
        for runner in tools/validate-mac.sh tools/linux/run-suites.sh \
            tools/deploy-win.sh tools/ios/run-sim.sh tools/android/run-emulator.sh; do
            case "$exempt" in
                *$'\n'"$runner"$'\t'"$scene"$'\n'*) continue ;;
            esac
            case "$runner" in
                tools/validate-mac.sh) sig="run $scene-" ;;
                tools/linux/run-suites.sh) sig="run \"\$proto\" $scene-" ;;
                tools/deploy-win.sh) sig="run_suite ${scene}_" ;;
                *) sig="$scene" ;;
            esac
            # milestone2's legs drop the scene prefix (they ARE the
            # unprefixed originals); its name check stays coarse.
            [ "$scene" = milestone2 ] && sig="$scene"
            if ! grep -qF "$sig" "$runner"; then
                echo "check-steps: scene \"$scene\" has no live legs in $runner (wanted \"$sig\")" >&2
                status=1
            fi
        done
    done
    return "$status"
}
wired || status=1

# THE VERB-FEATURE CROSS-CHECK — the other half of the same predicate,
# and the wall the derive-pin slice walked through
# (scratchpad/derive-pin-depth.md §8, 2026-08-05).
#
# wired() above says when a stub HOLDS legs off a runner. This says when
# a runner runs legs it must not: a scene whose verbs demand a feature
# its backend still refuses. Keyed on the scene NAME — which is how both
# gates read for four milestones — that question could not be asked at
# all, because a scene's name is not what a backend has to implement. The
# reshaped `todos.steps` grew `menu_activate "Edit>Undo"` while Compose
# still declared `depthStub("undo")`; the android runner wired no `undo`
# legs so check-stubs was green, and `todos` is not a stubbed name so
# check-steps was green. Both gates passed on a tree whose android lane
# was one Edit>Undo away from `error("...not yet materialized...")`.
#
# tools/lib/scene-features.py holds the derivation (verbs and menu ROLES
# to features, with the role table pinned against MENU_ROLES so a seventh
# role cannot ship without an answer) and every rule about it.
if ! python3 tools/lib/scene-features.py --mode check; then
    status=1
fi

# The guard guards itself, and against a REAL scene corpus rather than a
# toy one: the synthetic root borrows tools/scenes, crates/kaya/src/scene.rs
# and tools/lib/hand-rolled-stubs.py from this tree, and synthesizes only
# the runner and backend files — the two things the rule is about. So the
# derivation under test is the derivation that ships, and a table that
# stopped matching the real scripts fails here too.
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
#    a dead verb row and a live one look identical from outside — the
#    same blindness that let the CALL spelling go unwritten for four
#    milestones. A probe scene carries the verb under a name that implies
#    nothing, and each of the two derivations gets its own run: the VERB
#    row (expect_clipboard) and the ROLE row (a menu item labelled Paste).
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

# The Android per-leg setup has an ORDER, and every step's place is
# load-bearing — enabling the accessibility service before the
# force-stop kills it, and before the logcat clear erases the evidence
# it ever started. None of that is visible at the call site: each line
# is a plausible adb command in a plausible place, and the failure
# surfaces much later as "the picker never appeared". This gate already
# reads every runner, so it is where the order gets stated with its
# reasons instead of living in a comment somebody moves a line past.
if ! python3 tools/lib/android-leg-order.py; then
    status=1
fi

# SCENES MEANS "THE LANGUAGE SWEEP LANDED". Each desktop runner derives
# every mechanical per-scene surface from its SCENES variable — the go
# guest build, the source scp, the taskkill list — so a rust-only scene
# added there sends the runner looking for guests that do not exist.
# DEPTH_SCENES is the variable for that case, in all three runners.
#
# Not hypothetical: `split` went into SCENES on two runners and the
# matrix came back with `no required module provides package
# dev.kaya/guests/go/split` on linux and a failed scp on windows. Loud,
# but a whole matrix run to learn it. This makes it a two-second answer.
sweep_guests() {
    python3 - <<'PY'
import pathlib, re, sys

LANGS = [
    ("go", "guests/go/{s}/main.go"),
    ("python", "guests/python/{s}.py"),
    ("csharp", "guests/csharp/{S}Scene.cs"),
    ("swift", "guests/swift/{s}.swift"),
    ("ocaml", "guests/ocaml/{s}.ml"),
    ("haskell", "guests/haskell/{s}.hs"),
]
# The JVM and CLR guests are NOT one file per scene: they are one
# package plus a selector, with irregular class names (FileDialog,
# GridScene, Milestone2), so a path pattern cannot see them. Check the
# thing that actually decides whether a scene is reachable — that the
# selector dispatches it. A guest class that exists but was never wired
# into the switch is exactly as broken as a missing file, and looks
# fine to every other gate.
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
# A GUEST THAT EXISTS BUT NO LEG RUNS IS INVISIBLE TO EVERY OTHER GATE.
# wired() above demands only that a scene has SOME leg, so one language
# covers for all of them: clipboard shipped with working OCaml and
# Haskell guests that validate-mac never executed, and nothing noticed
# — the sugar gate checks bindings, the sweep above checks that guest
# FILES exist, and `run clipboard-` matched the rust leg.
#
# mac only, deliberately: this runner names every leg
# `<scene>-<lang>-swiftui`, so the expectation is exact. The other
# runners have their own naming and their own backend-stub carve-outs;
# widening this without them would be guesswork, not a guard.
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

# AND THE C FLOOR IS SWEPT LIKE EVERY OTHER LANGUAGE — it was not, for
# as long as it has existed. The sweep above is keyed on `guests/<lang>/`
# path patterns and the C guests are not in it, so the floor's legs were
# demanded by NO gate: `undo-c-swiftui` is the floor's first mac-lane leg
# ever, and if it silently fell out of validate-mac nothing would have
# gone red. Recorded as a gate gap out of the undo fan-out
# (docs/deferred.md), closed here.
#
# IT CANNOT BE A ROW IN THE SWEEP ABOVE, and the reason is the floor's
# shape rather than an exception made for it: that sweep demands a leg on
# the MAC runner for every scene in mac's SCENES whose guest file exists,
# and the C floor deliberately does not carry every scene on every lane —
# it is the documented explicit-tier demonstration, not a breadth guest.
# Adding `("c", "guests/c/{s}.c")` there would demand ten mac legs nobody
# ever intended and turn a gap into a red gate. So the C floor is swept
# on its own terms, from the two declarations it actually has.
#
# THE BINARY PATH IS THE LEG SIGNATURE, because the three runners spell a
# C leg three ways — `run undo-c-swiftui ... target/c-guests/undo` on mac,
# `run "$proto" todos-c ... /tmp/c-guests/todos` on linux, and the a11y
# legs through a helper script with no leg name at all
# (`tools/linux/a11y-leg.sh /tmp/c-guests/a11y`). What all three share is
# the binary they execute, and that is the thing that cannot be present
# while the leg is dead.
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

# EVERY WINDOWS LEG NEEDS ITS LAUNCHER. deploy-win runs a leg by
# scheduling C:\kaya\run_<scene>_<lang>.cmd on the VM, and those .cmd
# files are CHECKED IN under tools/guest. A leg whose launcher does not
# exist does not fail — schtasks starts nothing, no output ever appears,
# and the runner waits out its full 300s timeout before calling it a
# hang. Measured 2026-07-25: a scene joined SCENES with four of its five
# launchers missing and cost four silent 300s timeouts, diagnosed as
# load because the lane's duration anomaly fired first.
# NO LEG RUNS TWICE. deploy-win submits by name, and a name submitted
# twice runs the scene twice against the same output file — the second
# run's verdict silently replaces the first's, so a whole extra leg of
# the slowest lane's wall time buys nothing and reads as normal.
# Measured 2026-07-27: `run_suite split_rust` sat in the pooled block
# AND in the depth block's generated-launcher loop, and had run twice
# per full matrix since the day it was wired. Nothing noticed, because
# a duplicate looks exactly like a leg.
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

launchers() {
    local status=0 leg scene lang
    for leg in $(grep -oE 'run_suite [a-z0-9_]+' tools/deploy-win.sh \
        | cut -d' ' -f2 | sort -u); do
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

# The staged WinUI ruling (docs/traps.md), now covering TWO scene
# families that share one cause: the leg needs the DESKTOP to itself.
#
#   menus_*      shortcut injection is OS-global — the harness
#                foregrounds the guest and puts the real chord on the
#                system input queue.
#   filedialog_* a file dialog is modal, must hold the FOREGROUND to be
#                driven, and the harness finds it by searching the
#                desktop. Two up at once means one sits in the
#                background with its presses swallowed, and BOTH legs
#                fail. Measured 2026-07-31: the rust leg had been green
#                for weeks and broke the moment a python leg joined it
#                in the pool.
#
# So deploy-win must run each of these ALONE, between drains. Pinned
# structurally: every such `run_suite` call must have `drain_suites` as
# its nearest significant neighbor on BOTH sides, so a parallelizing
# refactor — or a sweep adding one more language beside it — cannot
# silently re-pool them.
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
    if not re.match(r"run_suite\s+(menus|filedialog)_", line):
        continue
    seen += 1
    before = significant(lines[:n])
    after = significant(lines[n + 1:])
    if not before or before[-1] != "drain_suites" or not after or after[0] != "drain_suites":
        bad.append(f"{path}:{n + 1}: {line} lacks the drain/run/drain barrier")
if seen == 0:
    bad.append(f"{path}: no run_suite menus_*/filedialog_* leg found "
               "(both scenes must stay wired)")
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

out="$(menu_serial tools/deploy-win.sh)" || {
    echo "check-steps: deploy-win.sh menus/filedialog legs must run serially between drain_suites calls (docs/traps.md — each needs the desktop to itself):" >&2
    echo "$out" >&2
    status=1
}

# THE CLIPBOARD LEGS ARE MUTUALLY EXCLUSIVE ON EVERY LANE
# (docs/clipboard-plan.md §0d, the 2026-08-02 correction): there is one
# system clipboard per session, and legs writing it concurrently are
# processes assigning one variable — measured, six of eight failed
# concurrently and the same eight passed serially. On wayland the
# serial primer's F24 tap additionally needs the pool EMPTY so it
# lands on the leg's own window (§5b finding 3). Pinned structurally,
# the menus/filedialog precedent: every clipboard leg must have
# `drain` as its nearest significant neighbor on BOTH sides, so a
# parallelizing refactor — or a sweep adding one more language beside
# it — cannot silently re-pool them. Continuation lines are joined
# first, because a leg's command usually wraps.
clipboard_serial() { # path leg_regex barrier_word
    python3 -c '
import re
import sys

path, leg_pattern, barrier = sys.argv[1], sys.argv[2], sys.argv[3]
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
    bad.append(f"{path}: no clipboard leg found (the scene must stay wired)")
print("\n".join(bad))
sys.exit(1 if bad else 0)
' "$1" "$2" "$3"
}

# Each runner spells its pool differently, so the rule is checked in
# each runner's own vocabulary.
MAC_LEG='run .*clipboard-[a-z]'
WIN_LEG='run_suite clipboard_[a-z]'

# The guard guards itself: two clipboard legs sharing the pool must
# fail...
if printf 'drain\nrun clipboard-rust-swiftui env X\nrun clipboard-python-swiftui env X\ndrain\n' \
    | clipboard_serial - "$MAC_LEG" drain >/dev/null; then
    echo "check-steps: SELF-TEST FAIL (pooled clipboard legs passed)" >&2
    exit 1
fi
# ...a clipboard leg entering a pool that still holds another scene's
# leg (on wayland the primer would tap that leg's window)...
if printf 'run layout-java env X\nrun clipboard-rust env X\ndrain\n' \
    | clipboard_serial - "$MAC_LEG" drain >/dev/null; then
    echo "check-steps: SELF-TEST FAIL (undrained-before clipboard leg passed)" >&2
    exit 1
fi
# ...and the deploy-win spelling, which the first cut of this gate
# missed in FOUR independent ways (run_suite vs run, underscore vs
# dash, drain_suites vs drain, and the file not being in the loop) —
# a barrier that exists in one runner's vocabulary silently exempts
# every other runner.
if printf 'run_suite clipboard_rust\nrun_suite clipboard_python\ndrain_suites\n' \
    | clipboard_serial - "$WIN_LEG" drain_suites >/dev/null; then
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
    out="$(clipboard_serial "$runner" "$leg" "$barrier")" || {
        echo "check-steps: $runner clipboard legs must run ALONE between drains (docs/clipboard-plan.md §0d — one system clipboard per session):" >&2
        echo "$out" >&2
        status=1
    }
done

# THE ANDROID LANE IS NOT IN THAT LOOP, AND THE OMISSION IS THE RULE,
# not a gap somebody should close by reflex. What §0d's correction
# actually requires is that a leg read the clipboard THAT LEG WROTE; the
# desktop lanes get there by emptying the pool, because their legs share
# one session. This lane's pool is separate emulators, each with its own
# ClipboardService, and §7 finding 4 measured the emulator-host clipboard
# bridge severed in both directions — so a session here is a DEVICE, and
# run_apk's slot lock, which holds one emulator for a leg's whole
# duration, is this runner's spelling of the same exclusion.
#
# A drain bracket on top of that would be a barrier that CANNOT FAIL for
# the reason it exists — there is one clipboard leg per suite block, so
# it would exclude nothing, and a gate satisfiable without exercising
# the real thing is a bug in the gate (CLAUDE.md invariant 4). So this
# checks the two things that CAN go wrong instead: a clipboard leg that
# stops riding run_apk (the tablet is the live temptation — one device,
# no lock, and legs on it would share its clipboard), and a run_apk that
# stops claiming a device, which would silently turn the first clause
# into a rule about a word.
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
# rather than the exit code: this gate family has twice passed a
# perturbation vacuously (docs/traps.md), and a negative test whose
# failure comes from somewhere else proves nothing about the clause it
# claims to cover.
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

# THE iOS LANE IS THE ANDROID SHAPE, FOR THE ANDROID REASON, and it was
# measured rather than argued: two simulators held two different clips at
# the same time while the host's stayed untouched
# (docs/clipboard-plan.md §8 finding 5). A session here is a DEVICE, the
# slot queue_leg claims for a leg's whole duration IS this lane's
# clipboard exclusion, and a drain bracket on top would exclude nothing.
#
# So this checks what CAN go wrong. A clipboard leg must ride queue_leg
# AND run_swiftui_on: the first claims the simulator, the second starts
# the host-side watcher that answers clipboard_seed and expect_clipboard
# — on this platform the guest cannot spawn a child process, so a leg
# without that watcher has neither the exclusion nor a foreign side at
# all. It must not ride kaya-sim-pad, which is ONE lockless device (the
# same live temptation the android tablet is). And queue_leg must still
# claim a device, or the first clause is a rule about a word.
#
# The swift flavor never spells its own leg name — it is queued in a loop
# over IOS_SWIFT_SCENES — so that list is read as a leg too, and the
# block that turns it into legs has to dispatch through queue_leg.
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
# as calls. EVERY such list is read, not the swift one by name: the go
# suite arrived as a second IOS_<LANG>_SCENES list driving its legs
# through the same loop, and a gate that knew only the first name would
# have gone half-vacuous the moment it landed — green, while the
# clipboard leg of a whole suite answered to nobody.
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
# simulator while its Edit > Automatically Sync Pasteboard is on, which
# is the default, so the slot lock above excludes other LEGS and
# excludes nothing else (docs/clipboard-plan.md section 8, finding 7).
# That cost three matrix runs of a different clipboard step reading
# empty each time while the lane passed solo, so the runner MEASURES the
# isolation and refuses. The call is matched with an argument after it:
# a bare name would match the definition too, which is how three clauses
# of check-tx-liveness once passed with the guard deleted.
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

# NO LIVE LINE TOUCHES A HOST OR SHARED PASTEBOARD PATH. The seed once
# transited the macOS pasteboard (pbcopy + pbsync host-><device>), which
# delivers asynchronously — the guest read raced the window and answered
# empty — and which validate-all would race against the mac lane and its
# clipboard legs. The ratified shape is a spawned on-device write
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

# AND THE PICKER MUST BE AIMABLE BEFORE ANY LEG RUNS, which on this
# platform is not a property of the code under test.
#
# The FIRST document picker a simulator shows after a boot opens at the
# app's container root instead of the directory it was aimed at: the
# app's reveal and DocumentManager's own default-location strategy race,
# and on a cold boot the strategy's file-provider resolution takes 708ms
# against a reveal that arrives at ~380ms (measured six ways,
# docs/traps.md). The scene then fails three steps deep, at file_choose,
# on a row that genuinely is not in the list — a failure that reads like
# a harness or guest defect and is neither.
#
# So run-sim.sh warms the document stack per device before the legs, and
# this keeps it there. Matched with an argument after the name so the
# definition line cannot satisfy the clause on its own — a bare name
# matching its own definition is how three clauses of check-tx-liveness
# once passed with the guard deleted.
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

# THE GUARD GUARDS ITSELF, on the REAL runner rather than on a fixture: a
# fixture only ever proves the pattern matches the fixture, which is how
# the wayland seat guard passed VACUOUSLY TWICE (docs/traps.md). Each
# perturbation prints its substitution count and the copy is refused if
# it did not apply — an unchanged file is a FAILED self-test, not a
# passed one — and each refusal is checked for its REASON, since an exit
# code alone is satisfied by any unrelated finding.
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

# ...and an unwired scene must fail, which takes EVERY leg away: the
# rust example names itself, and each guest-language suite spells its
# leg as a word in an IOS_<LANG>_SCENES list. The expected count is the
# number of those lists — 2 today, swift and go — and it is stated
# rather than derived on purpose: a third guest suite lands here as a
# loud "applied 3 times, want 2" rather than as a self-test that quietly
# proves less than it used to.
hits="$(ios_perturb tools/ios/run-sim.sh \
    'queue_leg run_swiftui_on clipboard-swiftui[\s\S]*?clipboard clipboard\n' '' \
    "$IOS_T/half.sh")"
ios_applied "$hits" "the rust-leg removal"
hits="$(ios_perturb "$IOS_T/half.sh" ' clipboard"' '"' "$IOS_T/unwired.sh")"
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
# every scene there, so the leg selects one by name through
# `--es KAYA_SELFTEST <scene>` and the guest matches it. A name the
# match does not carry used to fall through to the milestone-2 scene:
# the leg launched, a scene ran, it drew, and every step of the script
# the runner asked for failed against labels from a scene nobody
# selected. Measured 2026-07-31, wiring the filedialog leg — the verdict
# named eight unrelated widgets and read like a broken interpreter.
#
# The guest now panics on an unknown name, which turns a silent wrong
# scene into a loud one; this makes it a two-second answer instead of an
# emulator boot.
android_scenes() {
    local runner="$1" guest="$2"
    python3 -c '
import re
import sys

runner, guest = sys.argv[1], sys.argv[2]
selected = set(re.findall(r"dev\.kaya\.milestone2/\.MainActivity ([a-z0-9]+)",
                          open(runner).read()))
armed = set(re.findall(r"Ok\(\"([a-z0-9]+)\"\)", open(guest).read()))
missing = sorted(selected - armed)
for name in missing:
    print(f"{runner} selects scene {name!r}, which {guest} has no arm for")
sys.exit(1 if missing else 0)
' "$runner" "$guest"
}

# The guard guards itself, both directions: a selector with no arm must
# fail, and the real pair must pass.
sample="$(mktemp -d)"
echo 'dev.kaya.milestone2/.MainActivity ghostscene' >"$sample/runner.sh"
echo 'Ok("entry") => entry::app(ctx),' >"$sample/guest.rs"
if android_scenes "$sample/runner.sh" "$sample/guest.rs" >/dev/null; then
    echo "check-steps: SELF-TEST FAIL (an unarmed android selector passed)" >&2
    rm -rf "$sample"
    exit 1
fi
rm -rf "$sample"

out="$(android_scenes tools/android/run-emulator.sh guests/rust/milestone2_android.rs)" || {
    echo "check-steps: an android leg selects a scene the APK's guest cannot run:" >&2
    echo "$out" >&2
    status=1
}

# THE iOS PICKER'S THREE SILENT WIRINGS. Each of these fails in a way
# that looks like a backend bug rather than a harness one, which is what
# earns them a gate rather than a comment.
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

# 3. THE OPEN MODES MUST AGREE ACROSS THE ABI. protocol.rs::picked_mode_code
#    names 0/1/2 and a Rust test pins it; the Swift side of that same ABI
#    hardcodes the three cases, and nothing but this holds the two
#    spellings together. Reordering FileMode would turn every guest Read
#    into the backend Write, silently.
swift = pathlib.Path("swift/KayaSwiftUI.swift").read_text()
if "kaya_swiftui_open_picked" in swift:
    for case, flag in (("case 0", "O_RDONLY"), ("case 1", "O_WRONLY"), ("case 2", "O_RDWR")):
        window = swift[swift.index("kaya_swiftui_open_picked"):]
        if case not in window or flag not in window:
            bad.append(f"swift/KayaSwiftUI.swift open_picked does not map {case} to {flag} — "
                       f"the mode numbers protocol.rs pins would not survive the ABI")

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

# THE GENERATOR MUST NOT OUTRUN WHAT IT GENERATED. tools/gen-bindings.sh
# stamps a hash of tools/kaya-bindgen/src/*.rs beside the bindings it
# wrote; if the generator has moved since, the checked-in bindings are
# stale and everything downstream is a lie that COMPILES: the guest
# builds, the scene runs, and the decoder arm you just added is simply
# not there. Measured twice in one afternoon (docs/traps.md) — an OCaml
# and then a Haskell picker decoded every result as cancel, because the
# generator was edited and never rerun.
#
# `gen-bindings.sh --check` is the authoritative answer and regenerates
# to get it. This is the cheap one, so it can be asked constantly.
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
