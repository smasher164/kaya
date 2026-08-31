#!/usr/bin/env python3
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent / "lib"))
from kaya_gate import ROOT, Gate, dev_shell_or_die

dev_shell_or_die()

# THE C FLOOR REFUSES PAST ITS CAP RATHER THAN SMASHING PAST IT (ruled
# 2026-08-26; DESIGN.md, Binding conventions). KayaTx was {buf, len} —
# a Go slice header missing its third field — and every packer wrote
# through the bare pointer, so a long string was an unchecked memcpy
# into the caller's array. The seven sugar bindings all encode into a
# growable buffer; C was the one surface where overflow was undefined
# behaviour rather than an error (docs/deferred.md, java-record-
# ceiling).
#
# NOTHING ELSE CAN SEE THIS. Every in-tree guest sizes its buffers
# correctly, so the bytes on the wire are identical either way and no
# scene, no lane and no capture is any different — which is how the
# unchecked memcpy shipped from milestone 0 under green lanes. A gate
# is the only wall, exactly as for check-c-ids one file over.
#
# TWO MODES, AND THE GUARD PAGE IS THE PRIMARY ONE: the probe's
# walled() hands back exactly cap writable bytes whose next byte is
# unmapped, so a one-byte overrun is a FAULT and not a redzone
# heuristic, and with no sanitizer runtime in it the linux lane runs it
# unchanged. AddressSanitizer is the COMPANION beside it, on a plain
# malloc — the shape the wall cannot take, and what a guest's buffer
# actually is. It needs the compiler flake.nix names, because every
# nixpkgs clang below 22 has an ASan that hangs before main on this
# host (docs/traps.md); a host without that compiler runs the primary
# alone and SAYS SO.
#
# THE NEGATIVE IS THE SHIPPED BUG, not an imitation of it: the probe is
# built a second time against the PRE-CAP header read out of git, and
# that build must die of a signal where this one prints a sentence —
# and must be REPORTED by ASan where this one refuses.

import os
import re
import shutil
import subprocess

# Line-buffered stdout: compilers and probes write to the same fd, and
# block-buffered prints would land AFTER output they preceded.
sys.stdout.reconfigure(line_buffering=True)

g = Gate("check-c-bounds")

HEADER = "bindings/c/kaya_wire.h"
PROBE = "tools/checks/c-tx-cap.c"
# The revision the cap landed on top of: its kaya_wire.h IS the
# unchecked encode path, and there is no substitute for the real bytes.
PRE_REV = "ee7bc41"

T = g.scratch()

# COUNT IN, COUNT OUT (gates.sh's rule, one gate down): the verdict
# names which modes actually proved the claim. guard-page is not
# skippable; asan is, on a host without the compiler, and the skip is
# printed.
MODES_DECLARED = ["guard-page", "asan"]
modes_ran = []

CC = os.environ.get("CC", "clang")


# --- clause A: every write through tx->buf is guarded -----------------
#
# Read as CODE, not as text: brace depth is tracked and each write is
# tested against the conditions of the `if`s it actually sits inside. A
# generator edit that emits one more raw `memcpy(tx->buf ...)` is the
# failure this exists for, and a line-oriented pattern would miss the
# one whose guard is two lines up — kaya_wire_begin's memset/memcpy
# pair is exactly that shape.
#
# A write THROUGH the transaction buffer: tx->buf as a memcpy/memset
# DESTINATION, or as the target of an assignment. `memcpy(&kind,
# tx->buf + ...)` reads out of it and is not one.
WRITE = re.compile(r"mem(?:cpy|set)\(tx->buf\b|\btx->buf\[[^\]]*\]\s*=[^=]")
IF = re.compile(r"^\s*(?:\}\s*else\s+)?if\s*\((.*)\)\s*\{?\s*$")
GUARD = re.compile(r"kaya_wire_fits\(|tx->len <= tx->cap")


def resolved(path):
    p = pathlib.Path(path)
    return p if p.is_absolute() else ROOT / p


def guarded(path):
    """(out_lines, err_lines, ok) for one header's write sites."""
    lines = resolved(path).read_text(encoding="utf-8").splitlines()
    writes = 0
    unguarded = []
    stack = []       # (brace depth the block sits at, condition text)
    pending = None   # an `if (...)` with no brace: guards the NEXT line
    depth = 0

    for n, line in enumerate(lines, 1):
        code = line.split("/*")[0]
        stripped = code.strip()

        # A closing brace that opens an `else` arm ends the arm above
        # it, so the arm's condition must stop applying before this
        # line is read.
        if stripped.startswith("}") and stack \
                and stack[-1][0] == depth - 1:
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

    err = []
    # A reader that found nothing agrees with everything. The encode
    # path has ten write sites today: u32, u64, pad, the four value
    # arms, begin's memset and its kind, and end's size patch.
    if writes < 8:
        err.append(f"check-c-bounds: read only {writes} write(s) "
                   f"through tx->buf in {path} — the reader went "
                   f"blind, and a census that reads nothing agrees "
                   f"with everything")
        return [], err, False

    for n, text in unguarded:
        err.append(f"check-c-bounds: {path}:{n} writes through tx->buf "
                   f"with no cap check around it: {text}")
    if unguarded:
        err.append("check-c-bounds: every packer checks "
                   "kaya_wire_fits() BEFORE it writes and refuses past "
                   "cap — the caller owns and sizes the buffer "
                   "(DESIGN.md, Binding conventions). The header is "
                   "GENERATED: fix tools/kaya-bindgen/src/c.rs and "
                   "re-run tools/gen-bindings.sh.")
        return [], err, False

    return [f"check-c-bounds: {writes} write(s) through tx->buf, "
            f"every one cap-checked"], [], True


# --- clause B: the refusal discriminates ------------------------------
#
# check-diagnostics' rule at a surface it does not walk (it reads
# *WhyNot/*why_not/*Reason by name). The refused record's kind is read
# back out of the header this record wrote, so the branch where even
# those 8 bytes were past cap CANNOT name a kind — and has to say so
# rather than print a number nothing recorded.
def discriminates(path):
    """(out_lines, err_lines, ok) for the refusal's branches."""
    text = resolved(path).read_text(encoding="utf-8")
    m = re.search(r"static inline void kaya_wire_refused\(.*?\n\}\n",
                  text, re.S)
    if m is None:
        return [], ["check-c-bounds: kaya_wire_refused is gone from "
                    "the header — the sentence is what makes a full "
                    "transaction a REFUSAL rather than a silent "
                    "truncation"], False
    body = m.group(0)
    branches = re.findall(r"fprintf\(stderr,(.*?)\);", body, re.S)
    if len(branches) < 2:
        return [], [f"check-c-bounds: kaya_wire_refused prints "
                    f"{len(branches)} sentence(s). It needs two: the "
                    f"kind is read back out of the record header, so "
                    f"when even those 8 bytes were past cap there is "
                    f"no kind to name — and one sentence would then "
                    f"name a kind nothing wrote down, for the cause it "
                    f"cannot see"], False
    for branch in branches:
        if branch.count("%zu") < 2:
            return [], ["check-c-bounds: a kaya_wire_refused branch "
                        "names fewer than two sizes. It must say what "
                        "the record needs AND what the caller sized, "
                        "or the reader cannot tell what to grow to:"
                        + branch], False
    return [f"check-c-bounds: the refusal has {len(branches)} "
            f"branches, each naming both sizes"], [], True


out, err, ok = guarded(HEADER)
print("\n".join(out + err) if not ok else out[0],
      file=sys.stderr if not ok else sys.stdout)
if not ok:
    g.finding("the generated header has an unchecked write (above)")

out, err, ok = discriminates(HEADER)
print("\n".join(out + err) if not ok else out[0],
      file=sys.stderr if not ok else sys.stdout)
if not ok:
    g.finding("the refusal cannot discriminate (above)")

# --- clause C: the compile-time wall for a forgotten cap --------------
#
# `KayaTx tx = {buf, 0}` still COMPILES against a three-field struct:
# cap reads 0 and every record is then refused at RUN time. The
# Makefile turns that into a build error naming `cap`, which is the
# wall someone walks into by doing the basic thing (invariant 3).
makefile = (ROOT / "guests" / "c" / "Makefile").read_text(
    encoding="utf-8")
if "\nCFLAGS += -Werror=missing-field-initializers\n" not in \
        "\n" + makefile:
    g.finding("guests/c/Makefile no longer carries "
              "-Werror=missing-field-initializers,\n  so a KayaTx "
              "written {buf, 0} compiles with cap 0 and fails at RUN "
              "time\n  instead of at the build that wrote it")

# --- the probe, built against both headers ----------------------------
(T / "pre").mkdir()
show = subprocess.run(["git", "show", f"{PRE_REV}:{HEADER}"], cwd=ROOT,
                      capture_output=True, check=False)
if show.returncode != 0:
    print(show.stderr.decode("utf-8", errors="replace"),
          file=sys.stderr)
    print(f"check-c-bounds: cannot read {PRE_REV}:{HEADER} from git — "
          f"the negative's\n  fixture is the real pre-cap encode path "
          f"and there is no substitute. Fetch\n  the history (a "
          f"shallow clone will not do) rather than skipping the test.",
          file=sys.stderr)
    raise SystemExit(1)
(T / "pre" / "kaya_wire.h").write_bytes(show.stdout)
pre_bytes = len(show.stdout)
print(f"check-c-bounds: pre-cap header from {PRE_REV}, {pre_bytes} "
      f"bytes")
if "size_t cap;" in show.stdout.decode("utf-8", errors="replace"):
    print(f"check-c-bounds: {PRE_REV}:{HEADER} already declares cap, "
          f"so the fixture is\n  not the pre-cap header and every "
          f"clause below proves nothing", file=sys.stderr)
    raise SystemExit(1)


def build(out_bin, inc, *extra):
    r = subprocess.run(
        [CC, PROBE, "-I", str(ROOT / "crates" / "kaya" / "include"),
         "-I", str(inc), "-Wall", "-Wextra", "-Werror",
         "-o", str(out_bin), *extra],
        cwd=ROOT, capture_output=True, check=False)
    (T / "build.log").write_bytes(r.stderr)
    return r.returncode == 0


if not build(T / "probe", ROOT / "bindings" / "c"):
    print((T / "build.log").read_text(encoding="utf-8",
                                      errors="replace"),
          file=sys.stderr)
    print(f"check-c-bounds: {PROBE} does not build against {HEADER}",
          file=sys.stderr)
    raise SystemExit(1)
if not build(T / "probe-pre", T / "pre", "-DKAYA_TX_PRE_CAP"):
    print((T / "build.log").read_text(encoding="utf-8",
                                      errors="replace"),
          file=sys.stderr)
    print(f"check-c-bounds: {PROBE} does not build against the "
          f"pre-cap header — the\n  negative cannot run, which is a "
          f"failed test and not a skipped one", file=sys.stderr)
    raise SystemExit(1)


def run(binary, mode, env=None):
    """Writes T/out and T/err; returns the exit code."""
    r = subprocess.run(["timeout", "30", str(binary), mode],
                       capture_output=True, check=False, env=env)
    (T / "out").write_bytes(r.stdout)
    (T / "err").write_bytes(r.stderr)
    return r.returncode


def fault_signal(rc):
    """The BUS/SEGV signal a run died of, or None. GNU timeout re-kills
    itself with the child's signal, so python sees a NEGATIVE code
    where bash saw 128+signal; both spellings are one death."""
    if rc in (138, 139):
        return rc - 128
    if rc in (-10, -11):
        return -rc
    return None


def combined_out():
    return ((T / "out").read_text(encoding="utf-8", errors="replace")
            + (T / "err").read_text(encoding="utf-8", errors="replace"))


def says(fragment, label):
    if fragment not in combined_out():
        g.finding(f"{label} did not say '{fragment}'. It said:\n"
                  + combined_out())


# --- clause D: the refusal, live --------------------------------------
rc = run(T / "probe", "overflow")
if rc != 0:
    g.finding(f"the probe's overflow mode exited {rc} — it must refuse "
              f"and\n  return, not die")
says("overflow ok=0", "overflow mode")
says("kaya: transaction full — record kind 2 needs 224 bytes and this "
     "caller sized 64", "overflow mode")
print("check-c-bounds: an oversized record is refused and the tx "
      "marked not-ok")

# The OTHER branch of the diagnostic, made to print (invariant 3): a
# cap so small the 8-byte record header does not itself fit, so nothing
# recorded the kind.
rc = run(T / "probe", "header")
if rc != 0:
    g.finding(f"the probe's header mode exited {rc}")
says("its 8-byte header was itself past cap, so nothing recorded its "
     "kind", "header mode")
print("check-c-bounds: both refusal branches watched printing")

# The SMALL packers off the end — the u64 and the two u32s, which the
# long-string mode never reaches. Three 24-byte records into 24 bytes.
rc = run(T / "probe", "many")
if rc != 0:
    g.finding(f"the probe's many mode exited {rc}")
says("many len=72", "many mode")
says("many ok=0", "many mode")
print("check-c-bounds: the small packers refuse too, not just the "
      "string arm")

# One sentence per transaction, not one per record: after the first
# refusal every later record starts past cap, and len never comes back
# under it — so the transaction stays refused and stays usable.
rc = run(T / "probe", "sticky")
if rc != 0:
    g.finding(f"the probe's sticky mode exited {rc}")
says("sticky after=224 final=248 ok=0", "sticky mode")
said = (T / "err").read_text(encoding="utf-8", errors="replace") \
    .count("transaction full")
if said != 1:
    g.finding(f"the refusal printed {said} time(s) for one transaction "
              f"— it says itself\n  once, for the FIRST record that "
              f"did not fit")
print("check-c-bounds: one sentence per transaction, and len stays "
      "past cap")

# GROW AND RETRY, which is the whole point of refusing rather than
# smashing: past cap, len is what the transaction WOULD take.
rc = run(T / "probe", "retry")
if rc != 0:
    g.finding(f"the probe's retry mode exited {rc}")
says("retry second=432 ok=1", "retry mode")
print("check-c-bounds: grow-and-retry reaches a complete transaction")

# --- clause E: NO SMASH — the pre-cap header dies where this refuses --
#
# The wall is a real unmapped page, so this is not "a sanitizer thinks
# so": the pre-cap build takes a fault at the byte after cap. 138 is
# SIGBUS and 139 SIGSEGV; which one is the platform's business.
for mode in ("overflow", "header"):
    rc = run(T / "probe-pre", mode)
    sig = fault_signal(rc)
    if sig is not None:
        print(f"check-c-bounds: the pre-cap header died of signal "
              f"{sig} on '{mode}' — the smash")
    else:
        g.finding(f"the PRE-CAP header survived '{mode}' with exit "
                  f"{rc}. The negative\n  must show the old encode "
                  f"path writing past the wall; if it no longer does,"
                  f"\n  this gate is proving nothing.")

# --- clause F: NO OUTPUT BYTE MOVED -----------------------------------
#
# A correctly sized buffer never reaches the check, so every guest's
# wire bytes must be exactly what the pre-cap header wrote. Proven at
# the PACKER level rather than guest by guest: the probe's `repertoire`
# runs begin/end, u32, u64, pad, values, variant_schemas and a value of
# all five tags, and a guest emits nothing but some sequence of those.
new_bytes = {}
for mode in ("bytes", "exact"):
    a = subprocess.run(["timeout", "30", str(T / "probe"), mode],
                       capture_output=True, check=False)
    b = subprocess.run(["timeout", "30", str(T / "probe-pre"), mode],
                       capture_output=True, check=False)
    new_bytes[mode] = a.stdout
    if a.stdout != b.stdout:
        g.finding(f"the '{mode}' repertoire differs from the pre-cap "
                  f"header's bytes")
hex_len = len(new_bytes["bytes"].decode("utf-8", errors="replace")
              .splitlines()[-1].strip()) if new_bytes["bytes"] else 0
if hex_len // 2 < 400:
    g.finding(f"the byte comparison read only {hex_len // 2} bytes of "
              f"records — a\n  comparison of nothing agrees with "
              f"everything")
print(f"check-c-bounds: {hex_len // 2} bytes of records, "
      f"byte-identical to {PRE_REV}'s header")
modes_ran.append("guard-page")

# --- the ASan companion, beside the guard page ------------------------
#
# WHAT IT ADDS: a plain malloc, where the byte after cap belongs to the
# allocator rather than to an unmapped page. That is the shape a
# guest's buffer has, and it is the one nothing else here can see — the
# same pre-cap overrun measured 2026-08-27 exits 0 SILENTLY with no
# sanitizer and no hardening, and dies of a bare SIGTRAP printing zero
# bytes with the dev shell's hardening on. ASan names the write, its
# size and the allocation site. So this mode's negative is also its
# liveness proof: a sanitizer that is not really instrumenting prints
# nothing and fails here rather than passing quietly.
#
# THE COMPILER IS ASKED FOR BY NAME, never `clang`: the dev shell's own
# 21.1.8 compiles -fsanitize=address happily and then hangs before main
# for the whole ceiling, saying nothing (docs/traps.md). flake.nix puts
# llvm 22.1.8 on PATH under the name below.
# >>> asan-skip-branch (cut out verbatim by self-test N5, which doctors
# the name below away; must stand alone, so it reads nothing this file
# sets)
ASAN_CC = "kaya-asan-clang"


def asan_or_skip():
    cc = shutil.which(ASAN_CC)
    if cc:
        print(f"check-c-bounds: ASan companion — {cc}")
        return True
    # ONE LINE PER SENTENCE, not one multi-line string: keyed-inputs
    # reads a quoted string with a space in it as a message rather than
    # a path, and that test is per line — a wrapped string puts
    # `docs/traps.md` on a line with no quote on it and the gate is
    # then asked to declare docs/ as an input it does not read.
    print("check-c-bounds: ASan companion SKIPPED — the guard-page "
          "mode above proved the claim without it.")
    print(f"  The companion needs {ASAN_CC} on PATH, which flake.nix "
          f"puts there: llvm 22.1.8, because every")
    print("  nixpkgs clang below it has an ASan that hangs before "
          "main on macOS 26 (see the ASan entry in")
    print("  the traps file). Nothing is on this PATH under that "
          "name, so either this shell predates that")
    print("  flake change (re-enter `nix develop`) or the host has no "
          "such package. One mode of two ran.")
    return False
# <<< asan-skip-branch


def asan_build(out_bin, inc, *extra):
    # NIX_HARDENING_ENABLE="" BECAUSE FORTIFY PREEMPTS THE SANITIZER,
    # measured 2026-08-27 (docs/traps.md): with the wrapper's default
    # `fortify`, this probe's heap-many overrun dies of SIGTRAP with
    # ZERO bytes of output — __memcpy_chk fires before ASan reports —
    # and a smaller probe lost the instrumentation outright (no
    # __asan_report* symbol at all; an out-of-bounds store exited 0).
    # The wrapper appends its own -D_FORTIFY_SOURCE after the command
    # line, so no -U/-D here can undo it; only the whitelist can. An
    # ASan that cannot report is a gate satisfied without exercising
    # the real thing (invariant 4).
    r = subprocess.run(
        [ASAN_CC, PROBE,
         "-I", str(ROOT / "crates" / "kaya" / "include"),
         "-I", str(inc), "-fsanitize=address",
         "-fno-omit-frame-pointer", "-g", "-Wall", "-Wextra",
         "-Werror", "-o", str(out_bin), *extra],
        cwd=ROOT, capture_output=True, check=False,
        env=dict(os.environ, NIX_HARDENING_ENABLE=""))
    (T / "asan-build.log").write_bytes(r.stderr)
    return r.returncode == 0


def asan_run(binary, mode):
    # abort_on_error=0 so a report is an exit code and not a SIGABRT
    # whose shell noise buries the sentence this clause reads.
    return run(binary, mode,
               env=dict(os.environ, ASAN_OPTIONS="abort_on_error=0"))


def asan_says(fragment, label):
    err_text = (T / "err").read_text(encoding="utf-8",
                                     errors="replace")
    if fragment not in err_text:
        g.finding(f"{label} did not say '{fragment}'. It said:\n"
                  + "\n".join(err_text.splitlines()[:8]))


if asan_or_skip():
    if not asan_build(T / "probe-asan", ROOT / "bindings" / "c"):
        print((T / "asan-build.log").read_text(encoding="utf-8",
                                               errors="replace"),
              file=sys.stderr)
        g.finding(f"{PROBE} does not build under {ASAN_CC}'s "
                  f"-fsanitize=address")
    elif not asan_build(T / "probe-asan-pre", T / "pre",
                        "-DKAYA_TX_PRE_CAP"):
        print((T / "asan-build.log").read_text(encoding="utf-8",
                                               errors="replace"),
              file=sys.stderr)
        g.finding("the pre-cap header does not build under "
                  "-fsanitize=address — the\n  companion's negative "
                  "cannot run, which is a failed test and not a "
                  "skipped one")
    else:
        for mode in ("heap", "heap-many"):
            rc = asan_run(T / "probe-asan", mode)
            if rc != 0:
                g.finding(f"the sanitized probe exited {rc} in "
                          f"'{mode}' — a\n  refused record writes "
                          f"nothing, so there is nothing for ASan to "
                          f"report")
            says(f"{mode} ok=0", f"sanitized {mode}")
            if "AddressSanitizer" in (T / "err").read_text(
                    encoding="utf-8", errors="replace"):
                g.finding(f"ASan reported against the CURRENT header "
                          f"in '{mode}'")
        print("check-c-bounds: sanitized, the refusal writes nothing "
              "ASan can see")

        for mode in ("heap", "heap-many"):
            rc = asan_run(T / "probe-asan-pre", mode)
            if rc == 0:
                g.finding(f"the PRE-CAP header exited 0 in sanitized "
                          f"'{mode}'\n  with no report. Either the "
                          f"guard came back to a header that must not "
                          f"have it,\n  or the sanitizer is not "
                          f"instrumenting — see the hardening note in "
                          f"asan_build")
            asan_says("ERROR: AddressSanitizer: heap-buffer-overflow",
                      f"pre-cap {mode}")
            asan_says("WRITE of size", f"pre-cap {mode}")
            print(f"check-c-bounds: the pre-cap header is a "
                  f"heap-buffer-overflow on '{mode}'")
        modes_ran.append("asan")

# --- the watched negatives, on shadows of the real files --------------
def shadow(name):
    d = T / name
    d.mkdir()
    shutil.copy(ROOT / HEADER, d / "kaya_wire.h")
    return d


def doctor_file(label, path, pattern, repl):
    text = g.doctor(label, path.read_text(encoding="utf-8"), pattern,
                    repl, flags=re.M)
    path.write_text(text, encoding="utf-8")


# The mode has to be one the doctored packer actually runs off the end
# in: `overflow` writes a long string and reaches the string arm alone,
# `many` overruns through the u64 and the two u32s. A negative run in
# the wrong mode exits 0 and looks like a guard that is still there.
def smashes(shadow_dir, mode, label):
    probe_bin = T / f"probe-{shadow_dir.name}"
    if not build(probe_bin, shadow_dir):
        print((T / "build.log").read_text(encoding="utf-8",
                                          errors="replace"),
              file=sys.stderr)
        g.finding(f"SELF-TEST FAIL ({label} did not build)")
        return
    rc = run(probe_bin, mode)
    sig = fault_signal(rc)
    if sig is not None:
        print(f"check-c-bounds: self-test — {label} took the fault in "
              f"'{mode}' (signal {sig})")
    else:
        g.finding(f"SELF-TEST FAIL ({label}: the guard is gone and the "
                  f"walled probe still\n  exited {rc} in '{mode}' — "
                  f"the wall is not where this gate thinks it is)")


# N1 — the guard removed from kaya_wire_u32, which is the shape a
# generator edit takes. The static clause must refuse it, and the
# walled probe built from it must then take the fault: the check is
# what stops the smash, and not something else in the file.
s = shadow("n1")
doctor_file("N1 removed kaya_wire_u32's cap check", s / "kaya_wire.h",
            r"^    if \(kaya_wire_fits\(tx, 4\)\)\n"
            r"        memcpy\(tx->buf \+ tx->len, &v, 4\);$",
            "    memcpy(tx->buf + tx->len, &v, 4);")
_, _, ok = guarded(s / "kaya_wire.h")
if ok:
    g.finding("SELF-TEST FAIL (N1: an unguarded kaya_wire_u32 passed "
              "the static clause)")
else:
    print("check-c-bounds: self-test — N1 refused statically")
smashes(s, "many", "N1")

# N2 — the string arm, which is the site the ledger's measurement
# names: a long string was an unchecked memcpy of arbitrary length.
s = shadow("n2")
doctor_file("N2 removed the string arm's cap check", s / "kaya_wire.h",
            r"^        if \(kaya_wire_fits\(tx, v\.s_len\)\)\n"
            r"            memcpy\(tx->buf \+ tx->len, v\.s, "
            r"v\.s_len\);$",
            "        memcpy(tx->buf + tx->len, v.s, v.s_len);")
_, _, ok = guarded(s / "kaya_wire.h")
if ok:
    g.finding("SELF-TEST FAIL (N2: an unguarded string memcpy passed "
              "the static clause)")
else:
    print("check-c-bounds: self-test — N2 refused statically")
smashes(s, "overflow", "N2")

# N3 — the diagnostic collapsed onto one sentence, which is the shape
# check-diagnostics exists for: a kind read out of bytes nobody wrote,
# printed for the cause it cannot see.
s = shadow("n3")
doctor_file("N3 deleted kaya_wire_refused's second branch",
            s / "kaya_wire.h",
            r"^    \} else \{\n(?:.*\n)*?    \}\n\}$", "    }\n}")
_, _, ok = discriminates(s / "kaya_wire.h")
if ok:
    g.finding("SELF-TEST FAIL (N3: a one-sentence refusal passed the "
              "diagnostic clause)")
else:
    print("check-c-bounds: self-test — N3 refused (a refusal that "
          "cannot discriminate)")

# N4 — the compile wall, watched working in BOTH directions: a file
# that fails with the flag and builds without it is a file the flag
# refused.
(T / "forgot.c").write_text(
    "#include <kaya.h>\n#include <kaya_wire.h>\n"
    "int main(void) {\n    uint8_t buf[64];\n"
    "    KayaTx tx = {buf, 0};\n    kaya_tx_mount(&tx, 0, 1);\n"
    "    return (int)tx.len;\n}\n", encoding="utf-8")
with_flag = subprocess.run(
    [CC, str(T / "forgot.c"),
     "-I", str(ROOT / "crates" / "kaya" / "include"),
     "-I", str(ROOT / "bindings" / "c"),
     "-Werror=missing-field-initializers", "-o", str(T / "forgot")],
    capture_output=True, text=True, check=False)
if with_flag.returncode == 0:
    g.finding("SELF-TEST FAIL (N4: a KayaTx written {buf, 0} compiled "
              "with the flag on)")
elif "missing field 'cap' initializer" in with_flag.stderr:
    print("check-c-bounds: self-test — N4 a two-field KayaTx fails "
          "the build, naming cap")
else:
    g.finding("SELF-TEST FAIL (N4 reddened without naming cap):\n"
              + "\n".join(with_flag.stderr.splitlines()[:3]))
without_flag = subprocess.run(
    [CC, str(T / "forgot.c"),
     "-I", str(ROOT / "crates" / "kaya" / "include"),
     "-I", str(ROOT / "bindings" / "c"), "-o", str(T / "forgot-ok")],
    capture_output=True, check=False)
if without_flag.returncode == 0:
    print("check-c-bounds: self-test — N4 the same file builds "
          "without the flag, so the flag is the wall")
else:
    g.finding("SELF-TEST FAIL (N4: the same file failed WITHOUT the "
              "flag too, so the\n  flag is not what refused it)")

# N5 — THE HONEST SKIP, MADE TO PRINT. The companion's absent-compiler
# branch is the one no run on a wired host ever takes, and a skip
# nobody has watched is how a gate quietly stops running a mode. The
# block is cut out of THIS FILE by its markers and the compiler name
# doctored away, so what runs is the shipped branch and not a copy of
# it.
own = pathlib.Path(__file__).read_text(encoding="utf-8").splitlines()
begin = [n for n, s_ in enumerate(own)
         if s_.startswith("# >>> asan-skip-branch")]
end = [n for n, s_ in enumerate(own)
       if s_.startswith("# <<< asan-skip-branch")]
if len(begin) != 1 or len(end) != 1 or end[0] <= begin[0]:
    g.refuse("the asan-skip-branch markers are gone from this file — "
             "N5 cuts the shipped branch out by them, and a cut that "
             "finds nothing is a self-test that proves nothing")
block = own[begin[0] + 1:end[0]]
# The markers sit inside a comment run; drop the comment continuation
# lines so the block starts at the assignment it exists to doctor.
while block and block[0].startswith("#"):
    block.pop(0)
if not any(s_.startswith("ASAN_CC = ") for s_ in block):
    g.refuse("the cut block no longer sets ASAN_CC, so N5 has nothing "
             "to doctor away")
n5_script = T / "n5.py"
n5_text = g.doctor("N5 doctored the sanitizer compiler off PATH",
                   "import shutil\n\n" + "\n".join(block)
                   + "\n\nraise SystemExit(0 if asan_or_skip() "
                     "else 1)\n",
                   r"^ASAN_CC = .*$",
                   'ASAN_CC = "kaya-asan-clang-absent-by-N5"',
                   flags=re.M)
n5_script.write_text(n5_text, encoding="utf-8")
n5 = subprocess.run(["python3", str(n5_script)], capture_output=True,
                    text=True, check=False)
n5_log = n5.stdout + n5.stderr
if n5.returncode != 1:
    print(n5_log, file=sys.stderr)
    g.finding(f"SELF-TEST FAIL (N5: with no sanitizer compiler the "
              f"branch returned\n  {n5.returncode}, not 1 — a "
              f"companion that cannot tell it was skipped runs one "
              f"mode and\n  reports two)")
elif "ASan companion SKIPPED" in n5_log:
    print("check-c-bounds: self-test — N5 the skip branch printed: "
          + n5_log.splitlines()[0])
else:
    print(n5_log, file=sys.stderr)
    g.finding("SELF-TEST FAIL (N5: the skip was silent. An unprinted "
              "skip is a\n  mode that stopped running with nobody "
              "told)")

if g.status != 0:
    g.verdict()

# The guard page is the primary and is not skippable: it is the clause
# that holds on every host and on the linux lane.
if "guard-page" not in modes_ran:
    print("check-c-bounds: the guard-page mode did not run. It is the "
          "primary\n  proof, not an option — a verdict from the "
          "companion alone is a verdict from\n  the mode that can be "
          "skipped.", file=sys.stderr)
    raise SystemExit(1)
print(f"check-c-bounds: modes declared {len(MODES_DECLARED)} "
      f"({' '.join(MODES_DECLARED)}), ran {len(modes_ran)} "
      f"({' '.join(modes_ran)})")
g.verdict("every packer refuses past cap; the pre-cap header smashes "
          "where this one refuses; no output byte moved")
