#!/usr/bin/env python3
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent / "lib"))
from kaya_gate import ROOT, dev_shell_or_die, scratch_dir

dev_shell_or_die()

# Lint every tools/ shell script with shellcheck at warning level, plus
# the repo's own shell rules (--locked, $?, no sed/awk, ffmpeg -nostdin,
# no exec out of a build directory).
#
# ITS SCOPE DID NOT SHRINK, ITS POPULATION DID (docs/deferred.md's
# 2026-08-27 ruling). A converted gate is a two-line `exec python3` shim
# over a tools/check-*.py, so it is still walked here and passes every
# clause vacuously — there is no shell in it to get wrong. The rules
# that DO apply to its body are check-python.sh's, and the shim's exact
# bytes are pinned there too, so it can never grow logic this file would
# then have to hold. What stays here is what shell is still for: the
# runners, keyed.sh, the generators and tools/lib/*.sh. The four
# per-command rules (--locked, javac -encoding, sed/awk, ffmpeg
# -nostdin) follow the commands into the converted bodies as
# check-python's rule 11 — for four days after the conversion they
# policed nothing there (audit 2026-08-31).

import re
import shutil
import subprocess

# Line-buffered stdout: shellcheck writes to the same fd, and
# block-buffered prints would land AFTER output they preceded.
sys.stdout.reconfigure(line_buffering=True)

if shutil.which("shellcheck") is None:
    print("check-shell: shellcheck not found — run inside nix develop")
    sys.exit(1)

# Self-test: a script with a known defect must produce findings.
with scratch_dir("check-shell-") as tmp:
    bad_script = tmp / "bad.sh"
    bad_script.write_text("#!/bin/sh\ncd /nowhere\n"
                          "echo $undefined_word_splits\n", encoding="utf-8")
    probe = subprocess.run(["shellcheck", "-S", "warning",
                            str(bad_script)],
                           stdout=subprocess.DEVNULL,
                           stderr=subprocess.DEVNULL, check=False)
    if probe.returncode == 0:
        print("check-shell: self-test failed (shellcheck found nothing in "
              "a bad script)")
        sys.exit(1)

status = 0

# EVERY .sh under tools/, found rather than enumerated: a script in a
# new subdirectory must not be linted by nothing. The floor is the
# census rule: shims hold the .sh count roughly constant through the
# python conversion, so a walk that finds almost none read nothing.
scripts = sorted(p for p in (ROOT / "tools").rglob("*.sh") if p.is_file())
if len(scripts) < 40:
    print(f"check-shell: walked only {len(scripts)} .sh files under "
          f"tools/ — a census that reads nothing agrees with everything",
          file=sys.stderr)
    sys.exit(1)
for f in scripts:
    rel = f.relative_to(ROOT)
    if subprocess.run(["shellcheck", "-S", "warning", str(rel)], cwd=ROOT,
                      check=False).returncode != 0:
        status = 1


def logical_lines(text):
    """Continuations joined, numbered by their first physical line: a
    flag on the next line is still a flag on the same command."""
    out, start, buf = [], None, []
    for n, line in enumerate(text.splitlines(), 1):
        if start is None:
            start = n
        if line.endswith("\\"):
            buf.append(line[:-1])
            continue
        buf.append(line)
        out.append((start, " ".join(p.strip() for p in buf)))
        start, buf = None, []
    if buf:
        out.append((start, " ".join(p.strip() for p in buf)))
    return out


# javac takes the PLATFORM charset and the hosts disagree, so every
# invocation pins it (docs/traps.md).
JAVAC = re.compile(r"(javac|run_javac) .*(-d |-proc:only)")
unpinned = []
for f in scripts:
    rel = f.relative_to(ROOT)
    for n, line in enumerate(f.read_text(encoding="utf-8").splitlines(),
                             1):
        if JAVAC.search(line) and "encoding UTF-8" not in line:
            unpinned.append(f"{rel}:{n}:{line}")
if unpinned:
    print("check-shell: javac without -encoding UTF-8 (the host charset "
          "differs per platform):", file=sys.stderr)
    print("\n".join(unpinned), file=sys.stderr)
    status = 1

# Every cargo invocation carries --locked (CLAUDE.md). The flag is
# per-invocation, so a new callsite starts out unguarded.
# cargo, an optional wrapper (ndk/xwin) with its own flags, then the
# subcommand that can resolve dependencies. `run` joined 2026-08-31:
# it resolves exactly as `build` does, and gen-bindings' bare
# `cargo run` sat outside this alternation for the gate's whole life.
# check-python's SH_CARGO is this pattern's copy for embedded shell —
# the two move together.
CARGO = re.compile(r"(?:^|[^-\w])cargo\s+"
                   r"(?:(?:ndk|xwin)\s+(?:-\S+\s+\S+\s+)*)?"
                   r"(?:build|check|test|run)(?!\S)")
unlocked = []
for f in sorted((ROOT / "tools").rglob("*")):
    if f.suffix not in (".sh", ".cmd") or not f.is_file():
        continue
    rel = f.relative_to(ROOT)
    for n, line in logical_lines(f.read_text(encoding="utf-8")):
        if line.lstrip().startswith("#") or "--locked" in line:
            continue
        if CARGO.search(line):
            unlocked.append(f"{rel}:{n}:{line.strip()[:110]}")
# Self-test: the scan must see an unlocked invocation, in both the
# build and run spellings, and not a locked one.
planted = ["cargo build --lib",
           "KAYA_REGENERATING=1 cargo run --quiet -- root",
           "cargo ndk -t arm64-v8a build --locked --lib"]
seen = sum(1 for ln in planted
           if CARGO.search(ln) and "--locked" not in ln)
if seen != 2:
    print(f"check-shell: self-test failed (--locked scan matched {seen} "
          f"of 2 planted defects)", file=sys.stderr)
    status = 1
if unlocked:
    print("check-shell: cargo invocation without --locked (it may rewrite "
          "Cargo.lock mid-run):", file=sys.stderr)
    print("\n".join(unlocked), file=sys.stderr)
    status = 1

# The `$?` rule and the three shapes it forbids are in CLAUDE.md; none
# of them is reported at -S warning. Allowed: a bare `name=$?` on the
# line after a command, or `cmd || name=$?` on one line. Anything else
# is a finding, including a read after the end of a compound
# (fi/done/esac/}).
#
# `local rc=$?` is a capture too: $? expands before `local` runs.
CAPTURE = re.compile(
    r"^(?:(?:local|declare|typeset|export|readonly)\s+)?"
    r"[A-Za-z_]\w*=\$\?$")                       # name=$? , alone
SAMELINE = re.compile(r"\|\|\s*[A-Za-z_]\w*=\$\?\s*$")  # cmd || name=$?
# A bare `local rc` is a command, so a capture below it reads IT.
BARE_DECL = re.compile(r"^(?:local|declare|typeset)\s+[A-Za-z_]\w*$")
# A backslash-escaped $? in a double-quoted string is literal text.
READ = re.compile(r"(?<!\\)\$\?")
ENDS_COMPOUND = {"fi", "done", "esac", "}", ";;", "else", "then", "do"}
HEREDOC = re.compile(r"<<-?\s*['\"]?([A-Za-z_][A-Za-z0-9_]*)['\"]?")


def without_heredocs(text):
    """Heredoc bodies blanked out, line numbering preserved. The rule
    below is about SHELL semantics, and a heredoc body is data — the
    python the shell gates embedded was full of `$?` in regexes and
    messages, and scanning it flagged this very clause thirteen times.
    Any scanner that reads tools/*.sh has to know where the shell
    stops."""
    out, delim = [], None
    for line in text.splitlines():
        if delim is not None:
            out.append("")
            if line.strip() == delim:
                delim = None
            continue
        out.append(line)
        if not line.lstrip().startswith("#"):
            m = HEREDOC.search(line)
            if m:
                delim = m.group(1)
    return "\n".join(out)


def scan_status(name, text):
    findings, prev = [], None
    for n, line in logical_lines(without_heredocs(text)):
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        if READ.search(stripped):
            if SAMELINE.search(stripped):
                pass
            elif CAPTURE.match(stripped):
                last = prev.split()[-1].rstrip(";") if prev else ""
                if prev and BARE_DECL.match(prev):
                    findings.append(
                        f"{name}:{n}: the line above is a bare "
                        f"declaration, which is a command and resets $?: "
                        f"{stripped}")
                elif last in ENDS_COMPOUND:
                    findings.append(
                        f"{name}:{n}: $? here reads the compound ending "
                        f"in '{last}', not a command: {stripped}")
            else:
                findings.append(
                    f"{name}:{n}: $? read somewhere other than an "
                    f"immediate capture: {stripped}")
        prev = stripped
    return findings


badstatus = []
for f in scripts:
    rel = f.relative_to(ROOT)
    badstatus += scan_status(str(rel), f.read_text(encoding="utf-8"))


# Self-test: all three bad shapes must be seen, the good ones not.
def flagged_status(prev, line):
    if SAMELINE.search(line):
        return False
    if CAPTURE.match(line):
        if prev and BARE_DECL.match(prev):
            return True
        return (prev.split()[-1].rstrip(";") if prev else "") \
            in ENDS_COMPOUND
    return bool(READ.search(line))


bad_shapes = [flagged_status("fi", "status=$?"),  # after a compound
              flagged_status("cmd", "if [ $? -ne 0 ]; then :; fi"),
              flagged_status("local rc", "rc=$?")]  # bare decl above
good_shapes = [flagged_status('"$@"', "status=$?"),  # the one right way
               flagged_status("cmd", "docker run x || rc=$?"),
               flagged_status("cmd", "local rc=$?"),  # MEASURED fine: $?
               # expands before local runs
               flagged_status("cmd", r'echo "scored \$? here"')]  # literal
score = f"{sum(bad_shapes)}/{sum(good_shapes)}"
if score != "3/0":
    print(f"check-shell: self-test failed ($? scan scored {score}, "
          f"want 3/0)", file=sys.stderr)
    status = 1
if badstatus:
    print("check-shell: $? read where it no longer holds the command's "
          "status:", file=sys.stderr)
    print("\n".join(badstatus), file=sys.stderr)
    status = 1

# No sed, no awk (CLAUDE.md). Matched in COMMAND POSITION only — a
# substring match flags the word "used" inside a comment.
TOOLCMD = re.compile(r"(?:^|[|;&(]|\$\()\s*(?:[A-Za-z_]+=\S+\s+)*"
                     r"(sed|awk)\b")


def shell_lines(text):
    """Lines that are actually SHELL: heredoc bodies dropped. The shell
    gates' own scanners lived in heredocs, so without this the gate
    reported itself — which it did, three times, on the first run."""
    delim = None
    for n, line in enumerate(text.splitlines(), 1):
        if delim is not None:
            if line.strip() == delim:
                delim = None
            continue
        if not line.lstrip().startswith("#"):
            if (m := HEREDOC.search(line)):
                delim = m.group(1)
            yield n, line


badtool = []
for f in scripts:
    rel = f.relative_to(ROOT)
    for n, line in shell_lines(f.read_text(encoding="utf-8")):
        if (m := TOOLCMD.search(line)):
            badtool.append(f"{rel}:{n}: {m.group(1)} is banned — use "
                           f"python3 instead")
# Self-test: a real invocation seen, the word inside another word not.
# Fixtures are BUILT, not written literally: this file is beside the
# scanned tree, and the shell version was inside it, where a literal
# invocation would be reported as a real one.
S, A = "s" + "ed", "a" + "wk"
tool_bad = [f"{S} -n p file", "cat x | " + A + " '{print $1}'",
            f"x=$({S} s/a/b/ f)"]
tool_good = ["# u" + "sed by the thing", "echo unu" + "sed",
             "grep -o par" + "sed file"]
score = (f"{sum(1 for c in tool_bad if TOOLCMD.search(c))}/"
         f"{sum(1 for c in tool_good if TOOLCMD.search(c))}")
if score != "3/0":
    print(f"check-shell: self-test failed — banned-tool scan scored "
          f"{score}, want 3/0", file=sys.stderr)
    status = 1
if badtool:
    print("check-shell: sed/awk in a tools script (repo policy: python3 "
          "instead):", file=sys.stderr)
    print("\n".join(badtool), file=sys.stderr)
    status = 1

# ffmpeg reads stdin when it has one, so inside a `while read` loop it
# eats the loop's input (docs/traps.md). -nostdin is the rule.
FFMPEG = re.compile(r"(?:^|[|;&(]|\$\()\s*(?:[A-Za-z_]+=\S+\s+)*ffmpeg\b")


def commands(text):
    """Shell lines with continuations joined: -nostdin on the second
    line of a wrapped invocation is still on the same command."""
    delim, start, buf = None, None, []
    for n, line in enumerate(text.splitlines(), 1):
        if delim is not None:
            if line.strip() == delim:
                delim = None
            continue
        if line.lstrip().startswith("#"):
            continue
        if (m := HEREDOC.search(line)):
            delim = m.group(1)
        if start is None:
            start = n
        if line.endswith("\\"):
            buf.append(line[:-1])
            continue
        buf.append(line)
        yield start, " ".join(p.strip() for p in buf)
        start, buf = None, []
    if buf:
        yield start, " ".join(p.strip() for p in buf)


badffmpeg = []
for f in scripts:
    rel = f.relative_to(ROOT)
    for n, line in commands(f.read_text(encoding="utf-8")):
        if FFMPEG.search(line) and "-nostdin" not in line:
            badffmpeg.append(f"{rel}:{n}: ffmpeg without -nostdin — it "
                             f"will eat a read loop's input")


# Self-test: a bare invocation seen; -nostdin, `command -v` and the
# word in a list not.
def flagged_ffmpeg(line):
    return bool(FFMPEG.search(line)) and "-nostdin" not in line


ff_bad = [flagged_ffmpeg("ffmpeg -loglevel error -i in.mp4 out.png"),
          flagged_ffmpeg("cat x | ffmpeg -i - out.png"),
          flagged_ffmpeg("v=$(ffmpeg -i in.mp4 2>&1)")]
ff_good = [flagged_ffmpeg("ffmpeg -nostdin -loglevel error -i in.mp4 "
                          "out.png"),
           flagged_ffmpeg("command -v ffmpeg >/dev/null || exit 1"),
           flagged_ffmpeg("for tool in cargo ffmpeg python3; do :; done")]
score = f"{sum(ff_bad)}/{sum(ff_good)}"
if score != "3/0":
    print(f"check-shell: self-test failed — ffmpeg scan scored {score}, "
          f"want 3/0", file=sys.stderr)
    status = 1
if badffmpeg:
    print("check-shell: ffmpeg without -nostdin (it steals a read loop's "
          "stdin):", file=sys.stderr)
    print("\n".join(badffmpeg), file=sys.stderr)
    status = 1

# A LEG MAY NOT EXEC OUT OF A BUILD DIRECTORY: macOS walks the
# executable's containing directory on every launch, and a build
# directory is huge (docs/deferred.md). Lanes stage guests into a small
# directory and run them from there. The old grep read tools/*.sh and
# tools/*/*.sh — two levels, kept.
EXEC = re.compile(r"^[ \t]*run[ \t].*target/(debug|release)/"
                  r"(examples|deps)/")
badexec = []
exec_pop = sorted(list((ROOT / "tools").glob("*.sh"))
                  + list((ROOT / "tools").glob("*/*.sh")))
for f in exec_pop:
    rel = f.relative_to(ROOT)
    for n, line in enumerate(f.read_text(encoding="utf-8").splitlines(),
                             1):
        if EXEC.search(line):
            badexec.append(f"{rel}:{n}:{line}")
if badexec:
    print("check-shell: a leg execs straight out of a build directory, "
          "whose sibling count macOS walks on every launch (7.7s vs "
          "0.13s, measured). Stage the binary somewhere small and run it "
          "from there:", file=sys.stderr)
    print("\n".join(badexec), file=sys.stderr)
    status = 1
# Self-test: fires on the forbidden shape, quiet on the staging copy.
exec_lines = [
    "    run split-rust-swiftui env KAYA_SELFTEST=split "
    "target/debug/examples/split",
    '    cp "$ROOT/target/debug/examples/$s" "$RUST_GUESTS/$s" || exit 1',
    '    run split-rust-swiftui env KAYA_SELFTEST=split '
    '"$RUST_GUESTS"/split',
]
probe_exec = sum(1 for ln in exec_lines if EXEC.search(ln))
if probe_exec != 1:
    print(f"check-shell: self-test failed — the build-directory exec scan "
          f"matched {probe_exec} of 3 lines, want exactly 1 (the bare "
          f"run)", file=sys.stderr)
    status = 1

if status == 0:
    print("check-shell: OK")
else:
    print("check-shell: FINDINGS ABOVE")
sys.exit(status)
