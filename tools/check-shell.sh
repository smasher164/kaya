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
# Lint every tools/ shell script with shellcheck at warning level. The
# suites' orchestration is shell, and shell's silent failure modes
# (unquoted words, unchecked cd, masked exit codes) have each cost a
# debugging round — catch them at the gate instead.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1

command -v shellcheck >/dev/null \
    || { echo "check-shell: shellcheck not found — run inside nix develop"; exit 1; }

# Self-test: a script with a known warning-level defect must produce
# findings, or the shellcheck invocation itself is broken and the
# green gate below would be a lie.
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
printf '#!/bin/sh\ncd /nowhere\necho $undefined_word_splits\n' >"$T/bad.sh"
if shellcheck -S warning "$T/bad.sh" >/dev/null 2>&1; then
    echo "check-shell: self-test failed (shellcheck found nothing in a bad script)"
    exit 1
fi

status=0
for f in tools/*.sh tools/ios/*.sh tools/android/*.sh tools/swiftui/*.sh tools/linux/*.sh; do
    [ -f "$f" ] || continue
    if ! shellcheck -S warning "$f"; then
        status=1
    fi
done

# javac takes the PLATFORM charset, and the hosts disagree: UTF-8 on
# mac and linux, a legacy code page on the Windows VM. A scene label
# with a non-ASCII character therefore reached the wire as mojibake
# from one host only, and no gate could see it (docs/traps.md). Every
# invocation must pin the encoding rather than inherit a default.
unpinned=$(grep -rnE "(javac|run_javac) .*(-d |-proc:only)" tools/ --include="*.sh" \
    | grep -v "encoding UTF-8") || true
if [ -n "$unpinned" ]; then
    echo "check-shell: javac without -encoding UTF-8 (the host charset differs per platform):" >&2
    echo "$unpinned" >&2
    status=1
fi

# Cargo.lock is the record of WHICH dependency graph a lane validated.
# A bare `cargo build` is allowed to rewrite it — a drifted Cargo.toml,
# a yanked crate, a `version = "0.62"` that now means something newer —
# and the run goes green against a graph nobody chose, silently, with
# the change landing in a file the run was not supposed to touch.
# `--locked` turns that into a loud failure: resolve or refuse.
#
# The flag is per-invocation (cargo has no config key for it), so a new
# callsite starts out unguarded. That is what this clause is for. The
# scan is python3 rather than grep -E because the word-boundary syntax
# differs between BSD and GNU grep — the same portability trap as sed.
unlocked=$(python3 - <<'PY'
import pathlib, re
# cargo, an optional wrapper (ndk/xwin) with its own flags, then the
# subcommand that can resolve dependencies.
pat = re.compile(r'(?:^|[^-\w])cargo\s+(?:(?:ndk|xwin)\s+(?:-\S+\s+\S+\s+)*)?(?:build|check|test)(?!\S)')


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


for f in sorted(pathlib.Path("tools").rglob("*")):
    if f.suffix not in (".sh", ".cmd") or not f.is_file():
        continue
    for n, line in logical_lines(f.read_text()):
        if line.lstrip().startswith("#") or "--locked" in line:
            continue
        if pat.search(line):
            print(f"{f}:{n}:{line.strip()[:110]}")
PY
) || true
# Self-test: the scan must see an unlocked invocation, or its silence
# below means nothing.
probe=$(printf 'cargo build --lib\ncargo ndk -t arm64-v8a build --locked --lib\n' \
    | python3 -c '
import re, sys
pat = re.compile(r"(?:^|[^-\w])cargo\s+(?:(?:ndk|xwin)\s+(?:-\S+\s+\S+\s+)*)?(?:build|check|test)(?!\S)")
print(sum(1 for l in sys.stdin if pat.search(l) and "--locked" not in l))')
if [ "$probe" != 1 ]; then
    echo "check-shell: self-test failed (--locked scan matched $probe of 1 planted defects)" >&2
    status=1
fi
if [ -n "$unlocked" ]; then
    echo "check-shell: cargo invocation without --locked (it may rewrite Cargo.lock mid-run):" >&2
    echo "$unlocked" >&2
    status=1
fi

# `$?` is readable exactly once, on the line right after the command,
# into a named variable. Everything downstream tests the VARIABLE.
#
# It is not a value you can come back for. Three ways that bites, all
# silent, none of them caught by shellcheck 0.11 at any severity:
#
#   if cmd; then …; fi      an `if` whose condition was false and which
#   status=$?               has no else branch exits 0 ITSELF, so this
#                           reads the `if`, not cmd. Shipped in
#                           tools/keyed.sh; every failing gate passed.
#
#   cmd                     SC2181 knows this one, but only at STYLE
#   if [ $? -ne 0 ]         severity, which -S warning above never sees.
#
#   cmd                     `local rc` is a COMMAND and resets $?, so
#   local rc                the capture reads the declaration. Measured:
#   rc=$?                   rc=0. Note `local rc=$?` on ONE line is
#                           FINE — $? expands before local runs — and
#                           `local rc=$(cmd)` is SC2155 at warning,
#                           already caught above. Only the separated
#                           form is both broken and unreported.
#
# So the rule is spelled here rather than delegated. Allowed: a bare
# `name=$?` on the line after a command, or `cmd || name=$?` on one
# line. Anything else is a finding — including a read that follows the
# end of a compound (fi/done/esac/}), which is the first case above.
badstatus=$(python3 - <<'PY'
import pathlib, re

# `name=$?`, optionally with a declaration prefix — `local rc=$?` is a
# capture too: the expansion happens before `local` runs (measured).
CAPTURE = re.compile(r'^(?:(?:local|declare|typeset|export|readonly)\s+)?[A-Za-z_]\w*=\$\?$')             # name=$? , alone
SAMELINE = re.compile(r'\|\|\s*[A-Za-z_]\w*=\$\?\s*$')   # cmd || name=$?
# A BARE declaration — `local rc` with no `=` — is the last command
# before a capture on the next line, so the capture reads IT.
BARE_DECL = re.compile(r'^(?:local|declare|typeset)\s+[A-Za-z_]\w*$')
# A BACKSLASH-escaped $? in a double-quoted string is literal text: the
# message this gate PRINTS about $? is not itself a read of one.
READ = re.compile(r'(?<!\\)\$\?')
ENDS_COMPOUND = {"fi", "done", "esac", "}", ";;", "else", "then", "do"}


def logical_lines(text):
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


HEREDOC = re.compile(r"<<-?\s*['\"]?([A-Za-z_][A-Za-z0-9_]*)['\"]?")


def without_heredocs(text):
    """Heredoc bodies blanked out, line numbering preserved. The rule
    below is about SHELL semantics, and a heredoc body is data — the
    python this file embeds is full of `$?` in regexes and messages, and
    scanning it flagged this very clause thirteen times. Any scanner
    that reads tools/*.sh has to know where the shell stops."""
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


def scan(name, text):
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
                    findings.append(f"{name}:{n}: the line above is a bare declaration, "
                                    f"which is a command and resets $?: {stripped}")
                elif last in ENDS_COMPOUND:
                    findings.append(f"{name}:{n}: $? here reads the compound ending in "
                                    f"'{last}', not a command: {stripped}")
            else:
                findings.append(f"{name}:{n}: $? read somewhere other than an immediate "
                                f"capture: {stripped}")
        prev = stripped
    return findings


out = []
for f in sorted(pathlib.Path("tools").rglob("*.sh")):
    out += scan(str(f), f.read_text())
print("\n".join(out))
PY
) || true
# Self-test: all three shapes above must be seen, and the correct one
# must not be. A clause about a silent failure mode is worth exactly
# what its negative test proves.
probe=$(python3 - <<'PY'
import re
# `name=$?`, optionally with a declaration prefix — `local rc=$?` is a
# capture too: the expansion happens before `local` runs (measured).
CAPTURE = re.compile(r'^(?:(?:local|declare|typeset|export|readonly)\s+)?[A-Za-z_]\w*=\$\?$')
SAMELINE = re.compile(r'\|\|\s*[A-Za-z_]\w*=\$\?\s*$')
# A BARE declaration — `local rc` with no `=` — is the last command
# before a capture on the next line, so the capture reads IT.
BARE_DECL = re.compile(r'^(?:local|declare|typeset)\s+[A-Za-z_]\w*$')
# A BACKSLASH-escaped $? in a double-quoted string is literal text: the
# message this gate PRINTS about $? is not itself a read of one.
READ = re.compile(r'(?<!\\)\$\?')
ENDS_COMPOUND = {"fi", "done", "esac", "}", ";;", "else", "then", "do"}


def flagged(prev, line):
    if SAMELINE.search(line):
        return False
    if CAPTURE.match(line):
        if prev and BARE_DECL.match(prev):
            return True
        return (prev.split()[-1].rstrip(";") if prev else "") in ENDS_COMPOUND
    return bool(READ.search(line))


bad = [flagged("fi", "status=$?"),                      # after a compound
       flagged("cmd", "if [ $? -ne 0 ]; then :; fi"),   # read in a test
       flagged("local rc", "rc=$?")]                    # bare decl above
good = [flagged('"$@"', "status=$?"),                   # the one right way
        flagged("cmd", "docker run x || rc=$?"),        # captured same line
        flagged("cmd", "local rc=$?"),                  # MEASURED fine: $?
                                                        # expands before local runs
        flagged("cmd", r'echo "scored \$? here"')]      # escaped: literal
print(f"{sum(bad)}/{sum(good)}")
PY
)
if [ "$probe" != "3/0" ]; then
    echo "check-shell: self-test failed (\$? scan scored $probe, want 3/0)" >&2
    status=1
fi
if [ -n "$badstatus" ]; then
    echo "check-shell: \$? read where it no longer holds the command's status:" >&2
    echo "$badstatus" >&2
    status=1
fi

# NO sed, NO awk. Repo policy, and not a style preference: BSD and GNU
# differ in ways that bite silently and per-platform — this tree runs
# the same scripts on macOS, inside a Debian container, and against a
# Windows VM. python3 is available everywhere the scripts are, so the
# rule has no "trivial enough" exception and this clause is what makes
# that true rather than remembered. 27 invocations were converted at
# once when it landed; the point of the gate is the 28th.
#
# Matched in COMMAND POSITION only — start of line, or after a pipe,
# semicolon, ampersand or command substitution. A substring match
# flags the word "used" inside a comment, which is how the first draft
# of this scan reported a false positive on build-id.sh.
badtool=$(python3 - <<'PY'
import pathlib
import re

CMD = re.compile(r"(?:^|[|;&(]|\$\()\s*(?:[A-Za-z_]+=\S+\s+)*(sed|awk)\b")
HEREDOC = re.compile(r"<<-?\s*['\"]?([A-Za-z_][A-Za-z0-9_]*)['\"]?")


def shell_lines(text):
    """Lines that are actually SHELL: heredoc bodies dropped. This file
    is inside the scanned tree and its own scanner lives in a heredoc,
    so without this the gate reports itself — which it did, three
    times, on the first run."""
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


for f in sorted(pathlib.Path("tools").rglob("*.sh")):
    for n, line in shell_lines(f.read_text()):
        if (m := CMD.search(line)):
            print(f"{f}:{n}: {m.group(1)} is banned — use python3 instead")
PY
) || true
# Self-test: the scan must see a real invocation and must NOT see the
# word inside another word.
probe=$(python3 - <<'PY'
import re
CMD = re.compile(r"(?:^|[|;&(]|\$\()\s*(?:[A-Za-z_]+=\S+\s+)*(sed|awk)\b")
# Fixtures are BUILT, not written literally: this file is inside the
# scanned tree, so a literal invocation here would be reported as a
# real one.
S, A = "s" + "ed", "a" + "wk"
bad = [f"{S} -n p file", "cat x | " + A + " '{print $1}'", f"x=$({S} s/a/b/ f)"]
# The word inside another word must NOT match.
good = ["# u" + "sed by the thing", "echo unu" + "sed", "grep -o par" + "sed file"]
print(f"{sum(1 for c in bad if CMD.search(c))}/{sum(1 for c in good if CMD.search(c))}")
PY
)
if [ "$probe" != "3/0" ]; then
    echo "check-shell: self-test failed — banned-tool scan scored $probe, want 3/0" >&2
    status=1
fi
if [ -n "$badtool" ]; then
    echo "check-shell: sed/awk in a tools script (repo policy: python3 instead):" >&2
    echo "$badtool" >&2
    status=1
fi

# ffmpeg READS STDIN when it has one, and it does not ask whose it is.
# Inside `grep … | while read line; do … ffmpeg …; done` the stdin it
# inherits IS the loop's input, so it ate transcript lines and the
# leading bytes of the next one: a step arrived as "AYA_HARNESS: +107ms"
# instead of "KAYA_HARNESS: …", its offset parsed as 0, and the still
# was cut from the wrong moment in the film. Load-dependent — 908 of
# 1790 stills in one 185-leg recording run, none at low concurrency —
# and it survived because a corrupt line still yields A still: the
# gate counted files, and the files were there.
#
# -nostdin is the fix ffmpeg ships for exactly this. The recording path
# also reads its loop from fd 3 so the next stdin-reader is harmless,
# but that is one loop remembering; this is the rule.
badffmpeg=$(python3 - <<'PY'
import pathlib
import re

CMD = re.compile(r"(?:^|[|;&(]|\$\()\s*(?:[A-Za-z_]+=\S+\s+)*ffmpeg\b")
HEREDOC = re.compile(r"<<-?\s*['\"]?([A-Za-z_][A-Za-z0-9_]*)['\"]?")


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


for f in sorted(pathlib.Path("tools").rglob("*.sh")):
    for n, line in commands(f.read_text()):
        if CMD.search(line) and "-nostdin" not in line:
            print(f"{f}:{n}: ffmpeg without -nostdin — it will eat a read loop's input")
PY
) || true
# Self-test: a bare invocation must be seen; -nostdin, a mention inside
# a `command -v` probe, and the word in a list must not be.
probe=$(python3 - <<'PY'
import re
CMD = re.compile(r"(?:^|[|;&(]|\$\()\s*(?:[A-Za-z_]+=\S+\s+)*ffmpeg\b")


def flagged(line):
    return bool(CMD.search(line)) and "-nostdin" not in line


bad = [flagged("ffmpeg -loglevel error -i in.mp4 out.png"),
       flagged("cat x | ffmpeg -i - out.png"),
       flagged("v=$(ffmpeg -i in.mp4 2>&1)")]
good = [flagged("ffmpeg -nostdin -loglevel error -i in.mp4 out.png"),
        flagged("command -v ffmpeg >/dev/null || exit 1"),
        flagged("for tool in cargo ffmpeg python3; do :; done")]
print(f"{sum(bad)}/{sum(good)}")
PY
)
if [ "$probe" != "3/0" ]; then
    echo "check-shell: self-test failed — ffmpeg scan scored $probe, want 3/0" >&2
    status=1
fi
if [ -n "$badffmpeg" ]; then
    echo "check-shell: ffmpeg without -nostdin (it steals a read loop's stdin):" >&2
    echo "$badffmpeg" >&2
    status=1
fi

if [ "$status" = 0 ]; then
    echo "check-shell: OK"
else
    echo "check-shell: FINDINGS ABOVE"
fi
exit "$status"
