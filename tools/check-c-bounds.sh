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
set -u

# THE C FLOOR REFUSES PAST ITS CAP RATHER THAN SMASHING PAST IT (ruled
# 2026-08-26; DESIGN.md, Binding conventions). KayaTx was {buf, len} — a
# Go slice header missing its third field — and every packer wrote
# through the bare pointer, so a long string was an unchecked memcpy into
# the caller's array. The seven sugar bindings all encode into a growable
# buffer; C was the one surface where overflow was undefined behaviour
# rather than an error (docs/deferred.md, java-record-ceiling).
#
# NOTHING ELSE CAN SEE THIS. Every in-tree guest sizes its buffers
# correctly, so the bytes on the wire are identical either way and no
# scene, no lane and no capture is any different — which is how the
# unchecked memcpy shipped from milestone 0 under green lanes. A gate is
# the only wall, exactly as for check-c-ids one file over.
#
# TWO MODES, AND THE GUARD PAGE IS THE PRIMARY ONE: the probe's walled()
# hands back exactly cap writable bytes whose next byte is unmapped, so a
# one-byte overrun is a FAULT and not a redzone heuristic, and with no
# sanitizer runtime in it the linux lane runs it unchanged.
# AddressSanitizer is the COMPANION beside it, on a plain malloc — the
# shape the wall cannot take, and what a guest's buffer actually is. It
# needs the compiler flake.nix names, because every nixpkgs clang below
# 22 has an ASan that hangs before main on this host (docs/traps.md); a
# host without that compiler runs the primary alone and SAYS SO.
#
# THE NEGATIVE IS THE SHIPPED BUG, not an imitation of it: the probe is
# built a second time against the PRE-CAP header read out of git, and
# that build must die of a signal where this one prints a sentence — and
# must be REPORTED by ASan where this one refuses.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1

HEADER=bindings/c/kaya_wire.h
PROBE=tools/checks/c-tx-cap.c
# The revision the cap landed on top of: its kaya_wire.h IS the unchecked
# encode path, and there is no substitute for the real bytes.
PRE_REV=ee7bc41

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

status=0

# COUNT IN, COUNT OUT (gates.sh's rule, one gate down): the verdict names
# which modes actually proved the claim. guard-page is not skippable;
# asan is, on a host without the compiler, and the skip is printed.
MODES_DECLARED=(guard-page asan)
modes_ran=()

fail() { # <text>
    echo "check-c-bounds: $1" >&2
    status=1
}

# --- clause A: every write through tx->buf is guarded ------------------
#
# Read as CODE, not as text: brace depth is tracked and each write is
# tested against the conditions of the `if`s it actually sits inside. A
# generator edit that emits one more raw `memcpy(tx->buf ...)` is the
# failure this exists for, and a line-oriented pattern would miss the one
# whose guard is two lines up — kaya_wire_begin's memset/memcpy pair is
# exactly that shape.
guarded() { # <header path>
    python3 - "$1" <<'PY'
import pathlib
import re
import sys

path = pathlib.Path(sys.argv[1])
lines = path.read_text(encoding="utf-8").splitlines()

# A write THROUGH the transaction buffer: tx->buf as a memcpy/memset
# DESTINATION, or as the target of an assignment. `memcpy(&kind,
# tx->buf + ...)` reads out of it and is not one.
WRITE = re.compile(r"mem(?:cpy|set)\(tx->buf\b|\btx->buf\[[^\]]*\]\s*=[^=]")
IF = re.compile(r"^\s*(?:\}\s*else\s+)?if\s*\((.*)\)\s*\{?\s*$")
GUARD = re.compile(r"kaya_wire_fits\(|tx->len <= tx->cap")

writes = 0
unguarded = []
stack = []       # (brace depth the block sits at, condition text)
pending = None   # an `if (...)` with no brace: guards the NEXT line only
depth = 0

for n, line in enumerate(lines, 1):
    code = line.split("/*")[0]
    stripped = code.strip()

    # A closing brace that opens an `else` arm ends the arm above it, so
    # the arm's condition must stop applying before this line is read.
    if stripped.startswith("}") and stack and stack[-1][0] == depth - 1:
        stack.pop()

    conds = [c for _, c in stack]
    if pending is not None:
        conds.append(pending)

    if WRITE.search(code):
        writes += 1
        if not any(GUARD.search(c) for c in conds):
            unguarded.append((n, line.strip()))

    m = IF.match(code)
    if m:
        if code.rstrip().endswith("{"):
            stack.append((depth, m.group(1)))
            pending = None
        else:
            pending = m.group(1)
    elif stripped:
        pending = None

    depth += code.count("{") - code.count("}")
    while stack and stack[-1][0] >= depth:
        stack.pop()

# A reader that found nothing agrees with everything. The encode path has
# ten write sites today: u32, u64, pad, the four value arms, begin's
# memset and its kind, and end's size patch.
if writes < 8:
    print(f"check-c-bounds: read only {writes} write(s) through tx->buf in "
          f"{path} — the reader went blind, and a census that reads nothing "
          f"agrees with everything", file=sys.stderr)
    sys.exit(1)

for n, text in unguarded:
    print(f"check-c-bounds: {path}:{n} writes through tx->buf with no cap "
          f"check around it: {text}", file=sys.stderr)
if unguarded:
    print("check-c-bounds: every packer checks kaya_wire_fits() BEFORE it "
          "writes and refuses past cap — the caller owns and sizes the buffer "
          "(DESIGN.md, Binding conventions). The header is GENERATED: fix "
          "tools/kaya-bindgen/src/c.rs and re-run tools/gen-bindings.sh.",
          file=sys.stderr)
    sys.exit(1)

print(f"check-c-bounds: {writes} write(s) through tx->buf, every one cap-checked")
PY
}

if ! guarded "$HEADER"; then
    fail "the generated header has an unchecked write (above)"
fi

# --- clause B: the refusal discriminates -------------------------------
#
# check-diagnostics' rule at a surface it does not walk (it reads
# *WhyNot/*why_not/*Reason by name). The refused record's kind is read
# back out of the header this record wrote, so the branch where even
# those 8 bytes were past cap CANNOT name a kind — and has to say so
# rather than print a number nothing recorded.
discriminates() { # <header path>
    python3 - "$1" <<'PY'
import pathlib
import re
import sys

text = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
m = re.search(r"static inline void kaya_wire_refused\(.*?\n\}\n", text, re.S)
if m is None:
    print("check-c-bounds: kaya_wire_refused is gone from the header — the "
          "sentence is what makes a full transaction a REFUSAL rather than a "
          "silent truncation", file=sys.stderr)
    sys.exit(1)
body = m.group(0)
branches = re.findall(r"fprintf\(stderr,(.*?)\);", body, re.S)
if len(branches) < 2:
    print(f"check-c-bounds: kaya_wire_refused prints {len(branches)} "
          "sentence(s). It needs two: the kind is read back out of the record "
          "header, so when even those 8 bytes were past cap there is no kind "
          "to name — and one sentence would then name a kind nothing wrote "
          "down, for the cause it cannot see", file=sys.stderr)
    sys.exit(1)
for branch in branches:
    if branch.count("%zu") < 2:
        print("check-c-bounds: a kaya_wire_refused branch names fewer than two "
              "sizes. It must say what the record needs AND what the caller "
              "sized, or the reader cannot tell what to grow to:" + branch,
              file=sys.stderr)
        sys.exit(1)
print(f"check-c-bounds: the refusal has {len(branches)} branches, "
      "each naming both sizes")
PY
}

if ! discriminates "$HEADER"; then
    fail "the refusal cannot discriminate (above)"
fi

# --- clause C: the compile-time wall for a forgotten cap ---------------
#
# `KayaTx tx = {buf, 0}` still COMPILES against a three-field struct: cap
# reads 0 and every record is then refused at RUN time. The Makefile
# turns that into a build error naming `cap`, which is the wall someone
# walks into by doing the basic thing (invariant 3).
if ! grep -q '^CFLAGS += -Werror=missing-field-initializers$' guests/c/Makefile; then
    fail "guests/c/Makefile no longer carries -Werror=missing-field-initializers,
  so a KayaTx written {buf, 0} compiles with cap 0 and fails at RUN time
  instead of at the build that wrote it"
fi

# --- the probe, built against both headers -----------------------------
mkdir -p "$T/pre"
if ! git show "$PRE_REV:$HEADER" >"$T/pre/kaya_wire.h" 2>"$T/git.log"; then
    cat "$T/git.log" >&2
    echo "check-c-bounds: cannot read $PRE_REV:$HEADER from git — the negative's
  fixture is the real pre-cap encode path and there is no substitute. Fetch
  the history (a shallow clone will not do) rather than skipping the test." >&2
    exit 1
fi
pre_bytes="$(wc -c <"$T/pre/kaya_wire.h" | tr -d ' ')"
echo "check-c-bounds: pre-cap header from $PRE_REV, $pre_bytes bytes"
if grep -q "size_t cap;" "$T/pre/kaya_wire.h"; then
    echo "check-c-bounds: $PRE_REV:$HEADER already declares cap, so the fixture is
  not the pre-cap header and every clause below proves nothing" >&2
    exit 1
fi

build() { # <out> <include dir> [extra cflags...]
    local out="$1" inc="$2"
    shift 2
    "${CC:-clang}" "$PROBE" -I"$ROOT/crates/kaya/include" -I"$inc" \
        -Wall -Wextra -Werror -o "$out" "$@" 2>"$T/build.log"
}

if ! build "$T/probe" "$ROOT/bindings/c"; then
    cat "$T/build.log" >&2
    echo "check-c-bounds: $PROBE does not build against $HEADER" >&2
    exit 1
fi
if ! build "$T/probe-pre" "$T/pre" -DKAYA_TX_PRE_CAP; then
    cat "$T/build.log" >&2
    echo "check-c-bounds: $PROBE does not build against the pre-cap header — the
  negative cannot run, which is a failed test and not a skipped one" >&2
    exit 1
fi

run() { # <binary> <mode> -> writes $T/out and $T/err, prints the exit code
    timeout 30 "$1" "$2" >"$T/out" 2>"$T/err"
    local rc=$?
    echo "$rc"
}

says() { # <fragment> <label>
    case "$(cat "$T/out" "$T/err")" in
        *"$1"*) ;;
        *)
            fail "$2 did not say '$1'. It said:
$(cat "$T/out" "$T/err")"
            ;;
    esac
}

# --- clause D: the refusal, live ---------------------------------------
rc="$(run "$T/probe" overflow)"
[ "$rc" = 0 ] || fail "the probe's overflow mode exited $rc — it must refuse and
  return, not die"
says "overflow ok=0" "overflow mode"
says "kaya: transaction full — record kind 2 needs 224 bytes and this caller sized 64" \
    "overflow mode"
echo "check-c-bounds: an oversized record is refused and the tx marked not-ok"

# The OTHER branch of the diagnostic, made to print (invariant 3): a cap
# so small the 8-byte record header does not itself fit, so nothing
# recorded the kind.
rc="$(run "$T/probe" header)"
[ "$rc" = 0 ] || fail "the probe's header mode exited $rc"
says "its 8-byte header was itself past cap, so nothing recorded its kind" \
    "header mode"
echo "check-c-bounds: both refusal branches watched printing"

# The SMALL packers off the end — the u64 and the two u32s, which the
# long-string mode never reaches. Three 24-byte records into 24 bytes.
rc="$(run "$T/probe" many)"
[ "$rc" = 0 ] || fail "the probe's many mode exited $rc"
says "many len=72" "many mode"
says "many ok=0" "many mode"
echo "check-c-bounds: the small packers refuse too, not just the string arm"

# One sentence per transaction, not one per record: after the first
# refusal every later record starts past cap, and len never comes back
# under it — so the transaction stays refused and stays usable.
rc="$(run "$T/probe" sticky)"
[ "$rc" = 0 ] || fail "the probe's sticky mode exited $rc"
says "sticky after=224 final=248 ok=0" "sticky mode"
said="$(grep -c 'transaction full' "$T/err")"
if [ "$said" != 1 ]; then
    fail "the refusal printed $said time(s) for one transaction — it says itself
  once, for the FIRST record that did not fit"
fi
echo "check-c-bounds: one sentence per transaction, and len stays past cap"

# GROW AND RETRY, which is the whole point of refusing rather than
# smashing: past cap, len is what the transaction WOULD take.
rc="$(run "$T/probe" retry)"
[ "$rc" = 0 ] || fail "the probe's retry mode exited $rc"
says "retry second=432 ok=1" "retry mode"
echo "check-c-bounds: grow-and-retry reaches a complete transaction"

# --- clause E: NO SMASH — the pre-cap header dies where this refuses ----
#
# The wall is a real unmapped page, so this is not "a sanitizer thinks
# so": the pre-cap build takes a fault at the byte after cap. 138 is
# SIGBUS and 139 SIGSEGV; which one is the platform's business.
for mode in overflow header; do
    rc="$(run "$T/probe-pre" "$mode")"
    case "$rc" in
        138|139)
            echo "check-c-bounds: the pre-cap header died of signal $((rc - 128)) on '$mode' — the smash"
            ;;
        *)
            fail "the PRE-CAP header survived '$mode' with exit $rc. The negative
  must show the old encode path writing past the wall; if it no longer does,
  this gate is proving nothing."
            ;;
    esac
done

# --- clause F: NO OUTPUT BYTE MOVED ------------------------------------
#
# A correctly sized buffer never reaches the check, so every guest's wire
# bytes must be exactly what the pre-cap header wrote. Proven at the
# PACKER level rather than guest by guest: the probe's `repertoire` runs
# begin/end, u32, u64, pad, values, variant_schemas and a value of all
# five tags, and a guest emits nothing but some sequence of those.
for mode in bytes exact; do
    timeout 30 "$T/probe" "$mode" >"$T/new.$mode" 2>/dev/null
    timeout 30 "$T/probe-pre" "$mode" >"$T/old.$mode" 2>/dev/null
    if ! cmp -s "$T/new.$mode" "$T/old.$mode"; then
        fail "the '$mode' repertoire differs from the pre-cap header's bytes:
$(diff "$T/old.$mode" "$T/new.$mode" | head -4)"
    fi
done
hex="$(tail -1 "$T/new.bytes" | tr -d '\n' | wc -c | tr -d ' ')"
if [ "$((hex / 2))" -lt 400 ]; then
    fail "the byte comparison read only $((hex / 2)) bytes of records — a
  comparison of nothing agrees with everything"
fi
echo "check-c-bounds: $((hex / 2)) bytes of records, byte-identical to $PRE_REV's header"
modes_ran+=(guard-page)

# --- the ASan companion, beside the guard page -------------------------
#
# WHAT IT ADDS: a plain malloc, where the byte after cap belongs to the
# allocator rather than to an unmapped page. That is the shape a guest's
# buffer has, and it is the one nothing else here can see — the same
# pre-cap overrun measured 2026-08-27 exits 0 SILENTLY with no sanitizer
# and no hardening, and dies of a bare SIGTRAP printing zero bytes with
# the dev shell's hardening on. ASan names the write, its size and the
# allocation site. So this mode's negative is also its liveness proof: a
# sanitizer that is not really instrumenting prints nothing and fails
# here rather than passing quietly.
#
# THE COMPILER IS ASKED FOR BY NAME, never `clang`: the dev shell's own
# 21.1.8 compiles -fsanitize=address happily and then hangs before main
# for the whole ceiling, saying nothing (docs/traps.md). flake.nix puts
# llvm 22.1.8 on PATH under the name below.
# >>> asan-skip-branch (cut out verbatim by self-test N5, which doctors the
# name below away; must stand alone, so it reads nothing this file sets)
ASAN_CC=kaya-asan-clang

asan_cc_path() { # -> prints the sanitizer compiler, or nothing
    command -v "$ASAN_CC" 2>/dev/null
}

asan_or_skip() { # -> 0 and prints the compiler line, or 1 and prints why not
    local cc
    cc="$(asan_cc_path)"
    if [ -n "$cc" ]; then
        echo "check-c-bounds: ASan companion — $cc"
        return 0
    fi
    # ONE LINE PER SENTENCE, not one multi-line string: keyed-inputs reads a
    # quoted string with a space in it as a message rather than a path, and
    # that test is per line — a wrapped string puts `docs/traps.md` on a line
    # with no quote on it and the gate is then asked to declare docs/ as an
    # input it does not read.
    echo "check-c-bounds: ASan companion SKIPPED — the guard-page mode above proved the claim without it."
    echo "  The companion needs $ASAN_CC on PATH, which flake.nix puts there: llvm 22.1.8, because every"
    echo "  nixpkgs clang below it has an ASan that hangs before main on macOS 26 (see the ASan entry in"
    echo "  the traps file). Nothing is on this PATH under that name, so either this shell predates that"
    echo "  flake change (re-enter \`nix develop\`) or the host has no such package. One mode of two ran."
    return 1
}
# <<< asan-skip-branch

asan_build() { # <out> <include dir> [extra cflags...]
    local out="$1" inc="$2"
    shift 2
    # NIX_HARDENING_ENABLE="" BECAUSE FORTIFY PREEMPTS THE SANITIZER,
    # measured 2026-08-27 (docs/traps.md): with the wrapper's default
    # `fortify`, this probe's heap-many overrun dies of SIGTRAP with ZERO
    # bytes of output — __memcpy_chk fires before ASan reports — and a
    # smaller probe lost the instrumentation outright (no __asan_report*
    # symbol at all; an out-of-bounds store exited 0). The wrapper appends
    # its own -D_FORTIFY_SOURCE after the command line, so no -U/-D here
    # can undo it; only the whitelist can. An ASan that cannot report is a
    # gate satisfied without exercising the real thing (invariant 4).
    NIX_HARDENING_ENABLE="" "$ASAN_CC" "$PROBE" \
        -I"$ROOT/crates/kaya/include" -I"$inc" \
        -fsanitize=address -fno-omit-frame-pointer -g \
        -Wall -Wextra -Werror -o "$out" "$@" 2>"$T/asan-build.log"
}

asan_run() { # <binary> <mode> -> writes $T/out and $T/err, prints the exit code
    # abort_on_error=0 so a report is an exit code and not a SIGABRT whose
    # shell noise buries the sentence this clause reads.
    ASAN_OPTIONS=abort_on_error=0 timeout 30 "$1" "$2" >"$T/out" 2>"$T/err"
    local rc=$?
    echo "$rc"
}

asan_says() { # <fragment> <label>
    grep -q -- "$1" "$T/err" || fail "$2 did not say '$1'. It said:
$(head -8 "$T/err")"
}

if asan_or_skip; then
    if ! asan_build "$T/probe-asan" "$ROOT/bindings/c"; then
        cat "$T/asan-build.log" >&2
        fail "$PROBE does not build under $ASAN_CC's -fsanitize=address"
    elif ! asan_build "$T/probe-asan-pre" "$T/pre" -DKAYA_TX_PRE_CAP; then
        cat "$T/asan-build.log" >&2
        fail "the pre-cap header does not build under -fsanitize=address — the
  companion's negative cannot run, which is a failed test and not a skipped one"
    else
        for mode in heap heap-many; do
            rc="$(asan_run "$T/probe-asan" "$mode")"
            [ "$rc" = 0 ] || fail "the sanitized probe exited $rc in '$mode' — a
  refused record writes nothing, so there is nothing for ASan to report"
            says "$mode ok=0" "sanitized $mode"
            if grep -q "AddressSanitizer" "$T/err"; then
                fail "ASan reported against the CURRENT header in '$mode':
$(head -4 "$T/err")"
            fi
        done
        echo "check-c-bounds: sanitized, the refusal writes nothing ASan can see"

        for mode in heap heap-many; do
            rc="$(asan_run "$T/probe-asan-pre" "$mode")"
            [ "$rc" != 0 ] || fail "the PRE-CAP header exited 0 in sanitized '$mode'
  with no report. Either the guard came back to a header that must not have it,
  or the sanitizer is not instrumenting — see the hardening note in asan_build"
            asan_says "ERROR: AddressSanitizer: heap-buffer-overflow" "pre-cap $mode"
            asan_says "WRITE of size" "pre-cap $mode"
            echo "check-c-bounds: the pre-cap header is a heap-buffer-overflow on '$mode'"
        done
        modes_ran+=(asan)
    fi
fi

# --- the watched negatives, on shadows of the real files ---------------
applied() { # <count> <label>
    echo "check-c-bounds: self-test $2, $1 substitution(s)"
    [ "$1" = 1 ] || {
        echo "check-c-bounds: SELF-TEST BROKEN ($2 applied $1) — a perturbation" \
            "that changed nothing is a passed test that proves nothing" >&2
        exit 1
    }
}

doctor() { # <file> <pattern> <replacement> -> prints the count
    python3 - "$@" <<'PY'
import pathlib
import re
import sys
path, pattern, repl = sys.argv[1:4]
p = pathlib.Path(path)
text = p.read_text(encoding="utf-8")
out, n = re.subn(pattern, repl, text, count=1, flags=re.M)
p.write_text(out, encoding="utf-8")
print(n)
PY
}

shadow() { # <name> -> prints a directory holding a copy of the real header
    mkdir -p "$T/$1"
    cp "$HEADER" "$T/$1/kaya_wire.h"
    echo "$T/$1"
}

# The mode has to be one the doctored packer actually runs off the end
# in: `overflow` writes a long string and reaches the string arm alone,
# `many` overruns through the u64 and the two u32s. A negative run in
# the wrong mode exits 0 and looks like a guard that is still there.
smashes() { # <shadow dir> <mode> <label>
    if ! build "$T/probe-$(basename "$1")" "$1"; then
        cat "$T/build.log" >&2
        fail "SELF-TEST FAIL ($3 did not build)"
        return
    fi
    local rc
    rc="$(run "$T/probe-$(basename "$1")" "$2")"
    case "$rc" in
        138|139)
            echo "check-c-bounds: self-test — $3 took the fault in '$2' (signal $((rc - 128)))"
            ;;
        *)
            fail "SELF-TEST FAIL ($3: the guard is gone and the walled probe still
  exited $rc in '$2' — the wall is not where this gate thinks it is)"
            ;;
    esac
}

# N1 — the guard removed from kaya_wire_u32, which is the shape a
# generator edit takes. The static clause must refuse it, and the walled
# probe built from it must then take the fault: the check is what stops
# the smash, and not something else in the file.
s="$(shadow n1)"
hits="$(doctor "$s/kaya_wire.h" \
    '^    if \(kaya_wire_fits\(tx, 4\)\)\n        memcpy\(tx->buf \+ tx->len, &v, 4\);$' \
    '    memcpy(tx->buf + tx->len, &v, 4);')"
applied "$hits" "N1 removed kaya_wire_u32's cap check"
if guarded "$s/kaya_wire.h" >"$T/n1.log" 2>&1; then
    cat "$T/n1.log" >&2
    fail "SELF-TEST FAIL (N1: an unguarded kaya_wire_u32 passed the static clause)"
else
    echo "check-c-bounds: self-test — N1 refused statically"
fi
smashes "$s" many N1

# N2 — the string arm, which is the site the ledger's measurement names:
# a long string was an unchecked memcpy of arbitrary length.
s="$(shadow n2)"
hits="$(doctor "$s/kaya_wire.h" \
    '^        if \(kaya_wire_fits\(tx, v\.s_len\)\)\n            memcpy\(tx->buf \+ tx->len, v\.s, v\.s_len\);$' \
    '        memcpy(tx->buf + tx->len, v.s, v.s_len);')"
applied "$hits" "N2 removed the string arm's cap check"
if guarded "$s/kaya_wire.h" >"$T/n2.log" 2>&1; then
    cat "$T/n2.log" >&2
    fail "SELF-TEST FAIL (N2: an unguarded string memcpy passed the static clause)"
else
    echo "check-c-bounds: self-test — N2 refused statically"
fi
smashes "$s" overflow N2

# N3 — the diagnostic collapsed onto one sentence, which is the shape
# check-diagnostics exists for: a kind read out of bytes nobody wrote,
# printed for the cause it cannot see.
s="$(shadow n3)"
hits="$(doctor "$s/kaya_wire.h" '^    \} else \{\n(?:.*\n)*?    \}\n\}$' '    }
}')"
applied "$hits" "N3 deleted kaya_wire_refused's second branch"
if discriminates "$s/kaya_wire.h" >"$T/n3.log" 2>&1; then
    cat "$T/n3.log" >&2
    fail "SELF-TEST FAIL (N3: a one-sentence refusal passed the diagnostic clause)"
else
    echo "check-c-bounds: self-test — N3 refused (a refusal that cannot discriminate)"
fi

# N4 — the compile wall, watched working in BOTH directions: a file that
# fails with the flag and builds without it is a file the flag refused.
cat >"$T/forgot.c" <<'EOF'
#include <kaya.h>
#include <kaya_wire.h>
int main(void) {
    uint8_t buf[64];
    KayaTx tx = {buf, 0};
    kaya_tx_mount(&tx, 0, 1);
    return (int)tx.len;
}
EOF
if "${CC:-clang}" "$T/forgot.c" -I"$ROOT/crates/kaya/include" -I"$ROOT/bindings/c" \
    -Werror=missing-field-initializers -o "$T/forgot" 2>"$T/forgot.err"; then
    fail "SELF-TEST FAIL (N4: a KayaTx written {buf, 0} compiled with the flag on)"
elif grep -q "missing field 'cap' initializer" "$T/forgot.err"; then
    echo "check-c-bounds: self-test — N4 a two-field KayaTx fails the build, naming cap"
else
    fail "SELF-TEST FAIL (N4 reddened without naming cap):
$(head -3 "$T/forgot.err")"
fi
if "${CC:-clang}" "$T/forgot.c" -I"$ROOT/crates/kaya/include" -I"$ROOT/bindings/c" \
    -o "$T/forgot-ok" 2>/dev/null; then
    echo "check-c-bounds: self-test — N4 the same file builds without the flag, so the flag is the wall"
else
    fail "SELF-TEST FAIL (N4: the same file failed WITHOUT the flag too, so the
  flag is not what refused it)"
fi

# N5 — THE HONEST SKIP, MADE TO PRINT. The companion's absent-compiler
# branch is the one no run on a wired host ever takes, and a skip nobody
# has watched is how a gate quietly stops running a mode. The block is cut
# out of THIS FILE by its markers and the compiler name doctored away, so
# what runs is the shipped branch and not a copy of it.
python3 - "$0" "$T/n5.sh" <<'PY'
import pathlib
import sys

src, out = sys.argv[1:3]
lines = pathlib.Path(src).read_text(encoding="utf-8").splitlines()
begin = [n for n, s in enumerate(lines) if s.startswith("# >>> asan-skip-branch")]
end = [n for n, s in enumerate(lines) if s.startswith("# <<< asan-skip-branch")]
if len(begin) != 1 or len(end) != 1 or end[0] <= begin[0]:
    sys.exit("check-c-bounds: the asan-skip-branch markers are gone from "
             f"{src} — N5 cuts the shipped branch out by them, and a cut that "
             "finds nothing is a self-test that proves nothing")
block = lines[begin[0] + 1:end[0]]
if not any(s.startswith("ASAN_CC=") for s in block):
    sys.exit("check-c-bounds: the cut block no longer sets ASAN_CC, so N5 has "
             "nothing to doctor away")
pathlib.Path(out).write_text(
    "#!/usr/bin/env bash\n"
    + "\n".join(block)
    + "\nasan_or_skip\n", encoding="utf-8")
PY
if [ ! -s "$T/n5.sh" ]; then
    fail "SELF-TEST FAIL (N5: the skip branch could not be cut out — see above)"
else
    hits="$(doctor "$T/n5.sh" '^ASAN_CC=.*$' 'ASAN_CC=kaya-asan-clang-absent-by-N5')"
    applied "$hits" "N5 doctored the sanitizer compiler off PATH"
    bash "$T/n5.sh" >"$T/n5.log" 2>&1
    rc=$?
    if [ "$rc" != 1 ]; then
        cat "$T/n5.log" >&2
        fail "SELF-TEST FAIL (N5: with no sanitizer compiler the branch returned
  $rc, not 1 — a companion that cannot tell it was skipped runs one mode and
  reports two)"
    elif grep -q "ASan companion SKIPPED" "$T/n5.log"; then
        echo "check-c-bounds: self-test — N5 the skip branch printed:" \
            "$(head -1 "$T/n5.log")"
    else
        cat "$T/n5.log" >&2
        fail "SELF-TEST FAIL (N5: the skip was silent. An unprinted skip is a
  mode that stopped running with nobody told)"
    fi
fi

if [ "$status" != 0 ]; then
    echo "check-c-bounds: FINDINGS ABOVE" >&2
    exit 1
fi

# The guard page is the primary and is not skippable: it is the clause that
# holds on every host and on the linux lane.
case " ${modes_ran[*]} " in
    *" guard-page "*) ;;
    *)
        echo "check-c-bounds: the guard-page mode did not run. It is the primary
  proof, not an option — a verdict from the companion alone is a verdict from
  the mode that can be skipped." >&2
        exit 1
        ;;
esac
echo "check-c-bounds: modes declared ${#MODES_DECLARED[@]} (${MODES_DECLARED[*]}), ran ${#modes_ran[@]} (${modes_ran[*]})"
echo "check-c-bounds: OK (every packer refuses past cap; the pre-cap header smashes where this one refuses; no output byte moved)"
