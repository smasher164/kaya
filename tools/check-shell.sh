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
# Lint every tools/ shell script with shellcheck at warning level, plus
# the repo's own shell rules (--locked, $?, no sed/awk, ffmpeg -nostdin,
# no exec out of a build directory).
#
# ITS SCOPE DID NOT SHRINK, ITS POPULATION DID (docs/deferred.md's
# 2026-08-27 ruling). A converted gate is a two-line `exec python3` shim
# over a tools/check-*.py, so it is still walked here and passes every
# clause vacuously — there is no shell in it to get wrong. The rules that
# DO apply to its body are check-python.sh's, and the shim's exact bytes
# are pinned there too, so it can never grow logic this file would then
# have to hold. What stays here is what shell is still for: the runners,
# keyed.sh, the generators and tools/lib/*.sh.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1

command -v shellcheck >/dev/null \
    || { echo "check-shell: shellcheck not found — run inside nix develop"; exit 1; }

# Self-test: a script with a known defect must produce findings.
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
printf '#!/bin/sh\ncd /nowhere\necho $undefined_word_splits\n' >"$T/bad.sh"
if shellcheck -S warning "$T/bad.sh" >/dev/null 2>&1; then
    echo "check-shell: self-test failed (shellcheck found nothing in a bad script)"
    exit 1
fi

# EVERY .sh under tools/, found rather than enumerated: a script in a
# new subdirectory must not be linted by nothing.
status=0
while IFS= read -r f; do
    if ! shellcheck -S warning "$f"; then
        status=1
    fi
done < <(find tools -name '*.sh' -type f | sort)

# javac takes the PLATFORM charset and the hosts disagree, so every
# invocation pins it (docs/traps.md).
unpinned=$(grep -rnE "(javac|run_javac) .*(-d |-proc:only)" tools/ --include="*.sh" \
    | grep -v "encoding UTF-8") || true
if [ -n "$unpinned" ]; then
    echo "check-shell: javac without -encoding UTF-8 (the host charset differs per platform):" >&2
    echo "$unpinned" >&2
    status=1
fi

# Every cargo invocation carries --locked (CLAUDE.md). The flag is
# per-invocation, so a new callsite starts out unguarded. python3
# rather than grep -E: word-boundary syntax differs BSD vs GNU.
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
# Self-test: the scan must see an unlocked invocation.
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

# The `$?` rule and the three shapes it forbids are in CLAUDE.md; none
# of them is reported at -S warning. Allowed: a bare `name=$?` on the
# line after a command, or `cmd || name=$?` on one line. Anything else
# is a finding, including a read after the end of a compound
# (fi/done/esac/}).
badstatus=$(python3 - <<'PY'
import pathlib, re

# `local rc=$?` is a capture too: $? expands before `local` runs.
CAPTURE = re.compile(r'^(?:(?:local|declare|typeset|export|readonly)\s+)?[A-Za-z_]\w*=\$\?$')             # name=$? , alone
SAMELINE = re.compile(r'\|\|\s*[A-Za-z_]\w*=\$\?\s*$')   # cmd || name=$?
# A bare `local rc` is a command, so a capture below it reads IT.
BARE_DECL = re.compile(r'^(?:local|declare|typeset)\s+[A-Za-z_]\w*$')
# A backslash-escaped $? in a double-quoted string is literal text.
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
# Self-test: all three bad shapes must be seen, the good ones not.
probe=$(python3 - <<'PY'
import re
# `local rc=$?` is a capture too: $? expands before `local` runs.
CAPTURE = re.compile(r'^(?:(?:local|declare|typeset|export|readonly)\s+)?[A-Za-z_]\w*=\$\?$')
SAMELINE = re.compile(r'\|\|\s*[A-Za-z_]\w*=\$\?\s*$')
# A bare `local rc` is a command, so a capture below it reads IT.
BARE_DECL = re.compile(r'^(?:local|declare|typeset)\s+[A-Za-z_]\w*$')
# A backslash-escaped $? in a double-quoted string is literal text.
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

# No sed, no awk (CLAUDE.md). Matched in COMMAND POSITION only — a
# substring match flags the word "used" inside a comment.
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
# Self-test: a real invocation seen, the word inside another word not.
probe=$(python3 - <<'PY'
import re
CMD = re.compile(r"(?:^|[|;&(]|\$\()\s*(?:[A-Za-z_]+=\S+\s+)*(sed|awk)\b")
# Fixtures are BUILT, not written literally: this file is inside the
# scanned tree, so a literal invocation here would be reported as a
# real one.
S, A = "s" + "ed", "a" + "wk"
bad = [f"{S} -n p file", "cat x | " + A + " '{print $1}'", f"x=$({S} s/a/b/ f)"]
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

# ffmpeg reads stdin when it has one, so inside a `while read` loop it
# eats the loop's input (docs/traps.md). -nostdin is the rule.
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
# Self-test: a bare invocation seen; -nostdin, `command -v` and the
# word in a list not.
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

# A LEG MAY NOT EXEC OUT OF A BUILD DIRECTORY: macOS walks the
# executable's containing directory on every launch, and a build
# directory is huge (docs/deferred.md). Lanes stage guests into a small
# directory and run them from there.
badexec=$(grep -nE '^[[:space:]]*run[[:space:]].*target/(debug|release)/(examples|deps)/' \
    tools/*.sh tools/*/*.sh 2>/dev/null) || true
if [ -n "$badexec" ]; then
    echo "check-shell: a leg execs straight out of a build directory," \
        "whose sibling count macOS walks on every launch (7.7s vs 0.13s," \
        "measured). Stage the binary somewhere small and run it from there:" >&2
    echo "$badexec" >&2
    status=1
fi
# Self-test: fires on the forbidden shape, quiet on the staging copy.
probe_exec=$(printf '%s\n' \
    '    run split-rust-swiftui env KAYA_SELFTEST=split target/debug/examples/split' \
    '    cp "$ROOT/target/debug/examples/$s" "$RUST_GUESTS/$s" || exit 1' \
    '    run split-rust-swiftui env KAYA_SELFTEST=split "$RUST_GUESTS"/split' \
    | grep -cE '^[[:space:]]*run[[:space:]].*target/(debug|release)/(examples|deps)/')
if [ "$probe_exec" != "1" ]; then
    echo "check-shell: self-test failed — the build-directory exec scan matched" \
        "$probe_exec of 3 lines, want exactly 1 (the bare run)" >&2
    status=1
fi

if [ "$status" = 0 ]; then
    echo "check-shell: OK"
else
    echo "check-shell: FINDINGS ABOVE"
fi
exit "$status"
