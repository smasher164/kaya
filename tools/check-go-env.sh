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

# A GO GUEST READS THE HOST'S ENVIRONMENT, NEVER GO'S COPY OF IT.
#
# THE DEFECT (measured 2026-08-07 in a real Android app process,
# scratchpad/mobilepkg-go.md §4.4, ratified as docs/go-mobile-plan.md's
# D2). Go fills runtime.envs from the envp handed to the PROCESS ENTRY.
# A library loaded with System.loadLibrary never sees one, so in a
# `-buildmode=c-shared` .so Go's view of the environment is empty
# forever, while C's getenv(3) reads the live `environ` the host wrote:
#
#     os.Getenv("KAYA_SELFTEST") == ""     len(os.Environ()) == 0
#     C.getenv("KAYA_SELFTEST")  == "milestone2"
#
# WHY THAT IS WORSE THAN A CRASH. kaya picks its scene by name from
# KAYA_SELFTEST and the selector's guard is a panic on an UNKNOWN name.
# "" is not an unknown name — it is the DEFAULT ARM — so the idiomatic
# Go spelling runs milestone2 against every other scene's script and
# fails every step for the wrong reason, with no diagnosis anywhere.
# And it works on iOS, where the guest is -buildmode=exe and Go owns
# main, so the natural build order (iOS first, per D3) tests the broken
# call on the platform where it is not broken.
#
# WHY THIS IS A GATE AND NOT A WALL SOMEWHERE BETTER, since CLAUDE.md's
# invariant 3 asks that question first and answers "gate" last.
# NOTHING AT COMPILE TIME OR RUN TIME CAN TELL THE TWO SPELLINGS APART.
# `os.Getenv("X")` and `kaya.Env("X")` both compile on every platform;
# on Android both RETURN — one the host's value, one the empty string —
# and an empty environment is Android's NORMAL state for a c-shared
# library, not an error condition, so an assertion at attach that fired
# on the wrong spelling would fire on the right one too. Go has no
# mechanism to make a standard-library call unavailable to a package.
# That leaves the static text, and the static text is this. So the
# doctrine's stated fallback applies — "when only a gate will do, put it
# in the set the lanes already run": this gate is in tools/gates.sh's
# list, which tools/validate-mac.sh runs whole, and CLAUDE.md's rung 2
# names it, which tools/check-gates.sh's three-way census then holds.
#
# WHAT IT SCANS AND WHY BOTH ROOTS. guests/go is where the defect would
# be written. bindings/go is where it would be written a second time,
# by whoever "fixes" kaya.Env by making it call os.Getenv — the
# replacement is the thing most worth guarding, so the gate also
# requires it to still exist and still go through C (clause 3 below).
#
# THE SCAN IS A PARSER, NOT A GREP, and that is load-bearing here more
# than in most gates: every file this rule protects DOCUMENTS the rule,
# so bindings/go/runtime.go says "os.Getenv" six times in prose. A grep
# would have to be taught to ignore comments and would then be one
# clever regex away from ignoring code too. go/parser knows the
# difference for free, resolves whatever local name the `os` import was
# given, and skips an identifier that is a local variable rather than
# the package.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1

command -v go >/dev/null \
    || { echo "check-go-env: go not found — run inside nix develop" >&2; exit 1; }

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

cat >"$T/goenv.go" <<'GO'
// The scanner behind tools/check-go-env.sh: which Go source reads the
// environment through Go's own copy of it.
package main

import (
	"flag"
	"fmt"
	"go/ast"
	"go/parser"
	"go/token"
	"io/fs"
	"os"
	"path"
	"path/filepath"
	"strconv"
	"strings"
)

// The environment READERS. Every one of them answers out of the Go
// runtime's envs slice, which a c-shared library never fills. The
// writers are not here on purpose: os.Setenv with cgo reaches libc's
// setenv as well, so it is not part of this failure class.
var banned = map[string][]string{
	"os":      {"Getenv", "LookupEnv", "Environ", "ExpandEnv"},
	"syscall": {"Getenv", "Environ"},
}

func isBanned(pkg, sel string) bool {
	for _, s := range banned[pkg] {
		if s == sel {
			return true
		}
	}
	return false
}

// checkFile parses one file and reports every banned read in it.
// Comments are not nodes, so prose ABOUT the rule costs nothing.
func checkFile(name string) ([]string, error) {
	fset := token.NewFileSet()
	f, err := parser.ParseFile(fset, name, nil, parser.ParseComments)
	if err != nil {
		return nil, err
	}

	// Whatever local name each banned import was given here.
	locals := map[string]string{}
	var found []string
	for _, imp := range f.Imports {
		p, err := strconv.Unquote(imp.Path.Value)
		if err != nil {
			continue
		}
		if _, ok := banned[p]; !ok {
			continue
		}
		local := path.Base(p)
		if imp.Name != nil {
			local = imp.Name.Name
		}
		switch local {
		case "_":
			continue
		case ".":
			// A dot-import puts Getenv in this file's own scope, where
			// no selector expression names it. Refused rather than
			// analysed: it is not a spelling anything in this tree
			// uses, and a rule that quietly cannot see a construct is
			// the failure this whole gate exists for.
			pos := fset.Position(imp.Pos())
			found = append(found, fmt.Sprintf(
				"%s:%d:%d: dot-import of %q hides the environment readers from this scan",
				name, pos.Line, pos.Column, p))
			continue
		}
		locals[local] = p
	}

	ast.Inspect(f, func(n ast.Node) bool {
		sel, ok := n.(*ast.SelectorExpr)
		if !ok {
			return true
		}
		id, ok := sel.X.(*ast.Ident)
		// Obj != nil means the parser resolved this identifier to a
		// declaration in the file — a local variable that happens to be
		// called os, not the package.
		if !ok || id.Obj != nil {
			return true
		}
		pkg, ok := locals[id.Name]
		if !ok || !isBanned(pkg, sel.Sel.Name) {
			return true
		}
		pos := fset.Position(sel.Pos())
		found = append(found, fmt.Sprintf("%s:%d:%d: %s.%s",
			name, pos.Line, pos.Column, id.Name, sel.Sel.Name))
		return true
	})
	return found, nil
}

func main() {
	one := flag.String("file", "", "check exactly this file")
	flag.Parse()

	var files []string
	if *one != "" {
		files = []string{*one}
	} else {
		for _, root := range flag.Args() {
			err := filepath.WalkDir(root, func(p string, d fs.DirEntry, err error) error {
				if err != nil {
					return err
				}
				if !d.IsDir() && strings.HasSuffix(p, ".go") {
					files = append(files, p)
				}
				return nil
			})
			if err != nil {
				fmt.Fprintf(os.Stderr, "goenv: %v\n", err)
				os.Exit(2)
			}
		}
		if len(files) == 0 {
			fmt.Fprintf(os.Stderr, "goenv: the roots hold no .go files — a scan of nothing is not a pass\n")
			os.Exit(2)
		}
	}

	var all []string
	for _, f := range files {
		found, err := checkFile(f)
		if err != nil {
			fmt.Fprintf(os.Stderr, "goenv: %v\n", err)
			os.Exit(2)
		}
		all = append(all, found...)
	}
	for _, line := range all {
		fmt.Println(line)
	}
	if len(all) > 0 {
		os.Exit(1)
	}
}
GO

# doctor SRC FROM TO OUT — write SRC with FROM replaced by TO, and print
# how many times that happened. THE COUNT IS THE POINT: a negative test
# whose perturbation did not apply passes for the wrong reason, which
# has misfired twice in this tree (check-tx-liveness, the wayland seat
# guard), so every self-test below reads this number and refuses a zero.
doctor() {
    python3 - "$1" "$2" "$3" "$4" <<'PY'
import sys

src, frm, to, out = sys.argv[1:5]
text = open(src, encoding="utf-8").read()
print(text.count(frm))
open(out, "w", encoding="utf-8").write(text.replace(frm, to))
PY
}

# BUILT ONCE AND RUN, rather than `go run` six times. Not only for the
# speed: `go run` prints its own "exit status 1" to stderr when the
# program it ran exits non-zero, so a caller that treats a non-empty
# stderr as "the scanner itself broke" can never tell the two apart.
if ! go build -o "$T/goenv" "$T/goenv.go"; then
    echo "check-go-env: the scanner would not build — fix it here, in this file." >&2
    exit 1
fi

scan() {
    "$T/goenv" "$@"
}

status=0

# ---------------------------------------------------------- self-tests
#
# All four run against the REAL BYTES of REAL FILES, doctored in memory,
# with the substitution count printed. A clause that parsed nothing
# agrees with everything, and this gate's whole job is to disagree.

# 1. The scan sees the defect in the BINDING. runtime.go's C.getenv is
#    the one correct spelling in the tree; turned into os.Getenv it is
#    the defect exactly.
n=$(doctor bindings/go/runtime.go 'C.getenv(' 'os.Getenv(' "$T/s1.go")
echo "check-go-env: self-test 1 planted $n defect(s) in bindings/go/runtime.go"
if [ "${n:-0}" -lt 1 ]; then
    echo "check-go-env: SELF-TEST FAIL — nothing to plant: bindings/go/runtime.go" \
        "no longer calls C.getenv, so clause 1 tested nothing." >&2
    status=1
elif scan -file "$T/s1.go" >/dev/null 2>&1; then
    echo "check-go-env: SELF-TEST FAIL — the scan passed a file that calls os.Getenv." >&2
    status=1
fi

# 2. The scan sees the defect in a GUEST, which is the other root and
#    the one the trap actually lands in.
#
#    THE FILE MOVED, 2026-08-07, and the way it moved is worth keeping:
#    this used to plant over `os.Exit(` in guests/go/milestone2/main.go,
#    and the Android composition split that guest into a scene body and
#    two platform tails — so os.Exit went to main_desktop.go, the
#    substitution count came back ZERO, and the gate refused to vouch for
#    itself instead of passing. That is the clause working. The token has
#    to sit in a file that IMPORTS os (the scanner resolves the import's
#    local name and ignores a bare `os` bound to nothing), which is
#    exactly what main_desktop.go is: the tail that owns main and exits.
n=$(doctor guests/go/milestone2/main_desktop.go 'os.Exit(' 'os.Getenv(' "$T/s2.go")
echo "check-go-env: self-test 2 planted $n defect(s) in guests/go/milestone2/main_desktop.go"
if [ "${n:-0}" -lt 1 ]; then
    echo "check-go-env: SELF-TEST FAIL — nothing to plant in guests/go/milestone2/main_desktop.go." >&2
    status=1
elif scan -file "$T/s2.go" >/dev/null 2>&1; then
    echo "check-go-env: SELF-TEST FAIL — the scan passed a guest that calls os.Getenv." >&2
    status=1
fi

# 2b. AND IT READS A FILE NO MAC EVER COMPILES. The rule is about
#    ANDROID, and the Android arm of a Go guest is behind
#    `//go:build android` — so if the scanner honoured build constraints
#    it would be blind in precisely the one place the defect can happen,
#    and every clause above would still pass. go/parser does not evaluate
#    constraints, and this is the clause that says so out loud instead of
#    leaving it as a fact somebody has to know.
#
#    THE PLANT CARRIES ITS OWN IMPORT, and under an ALIAS, which buys a
#    second property for free: the scanner must resolve whatever local
#    name the os import was given, not match the literal text "os.".
#    Keyed on `package main` — the one token every Go file has exactly
#    one of — so a rewrite of the imports or the selector cannot quietly
#    empty it.
n=$(doctor guests/go/milestone2/main_android.go 'package main' \
    $'package main\n\nimport osprobe "os"\n\nvar _ = osprobe.Getenv("KAYA_SELFTEST")' \
    "$T/s2b.go")
echo "check-go-env: self-test 2b planted $n defect(s) in guests/go/milestone2/main_android.go (//go:build android)"
if [ "${n:-0}" -ne 1 ]; then
    echo "check-go-env: SELF-TEST FAIL — expected exactly one 'package main' in" \
        "guests/go/milestone2/main_android.go, planted $n." >&2
    status=1
elif ! grep -q '^//go:build android' guests/go/milestone2/main_android.go; then
    echo "check-go-env: SELF-TEST FAIL — guests/go/milestone2/main_android.go no" \
        "longer carries //go:build android, so clause 2b proves nothing about" \
        "constrained files. Point it at the Android arm of a Go guest." >&2
    status=1
elif scan -file "$T/s2b.go" >/dev/null 2>&1; then
    echo "check-go-env: SELF-TEST FAIL — the scan passed an ANDROID-TAGGED guest" \
        "that calls os.Getenv under an aliased import. The scanner is blind" \
        "exactly where this rule matters." >&2
    status=1
fi

# 3. PROSE IS NOT CODE, and this gate would be unusable if it were:
#    every file the rule protects explains the rule, so runtime.go names
#    os.Getenv in its own comments (the count is printed below).
#
#    ISOLATED RATHER THAN READ OFF THE REAL FILE, which is the whole
#    craft of this clause. Scanning the undoctored runtime.go and calling
#    a finding "you flagged a comment" was the first spelling, and it
#    MISDIAGNOSED: with the binding perturbed to call os.Getenv for real,
#    the gate went red — correctly — while printing that the scanner
#    could not tell code from prose, which was false and would have sent
#    the reader into this file instead of theirs. So the clause is built
#    from the real comment lines ALONE, lifted out of the real file into
#    a file that has nothing else in it. Then the only thing that can
#    fail it is the property it names.
mentions=$(python3 - "$T/s3.go" <<'PY'
import sys

out = sys.argv[1]
text = open("bindings/go/runtime.go", encoding="utf-8").read()
prose = [ln for ln in text.splitlines()
         if ln.lstrip().startswith("//") and "os.Getenv" in ln]
print(len(prose))
# A compilable file whose ONLY mention of the banned readers is prose,
# with a legitimate os call so the import is not the thing under test.
open(out, "w", encoding="utf-8").write(
    "package p\n\nimport \"os\"\n\n" + "\n".join(prose)
    + "\nvar _ = os.TempDir\n")
PY
)
echo "check-go-env: self-test 3 lifted $mentions comment line(s) naming os.Getenv"
if [ "${mentions:-0}" -lt 1 ]; then
    echo "check-go-env: SELF-TEST FAIL — bindings/go/runtime.go no longer explains" \
        "the rule in prose, so 'comments are not code' is untested here." >&2
    status=1
elif ! scan -file "$T/s3.go" >/dev/null 2>&1; then
    echo "check-go-env: SELF-TEST FAIL — the scan flagged os.Getenv inside a" \
        "COMMENT. It must read code, not prose." >&2
    status=1
fi

# 4. THE REPLACEMENT MUST EXIST AND MUST GO THROUGH C. A ban with no
#    replacement is a gate that gets deleted the first time someone
#    needs a variable; a replacement that has quietly become os.Getenv
#    is the same defect wearing kaya's name.
replacement() {
    python3 - "$1" <<'PY'
import sys

text = open(sys.argv[1], encoding="utf-8").read()
need = ["func Env(name string) string",
        "func LookupEnv(name string) (string, bool)",
        "C.getenv("]
missing = [n for n in need if n not in text]
print(" ".join(missing))
sys.exit(1 if missing else 0)
PY
}
if ! replacement bindings/go/runtime.go >"$T/repl.txt"; then
    echo "check-go-env: bindings/go/runtime.go is missing the replacement this" \
        "gate points at: $(cat "$T/repl.txt")" >&2
    status=1
fi
n=$(doctor bindings/go/runtime.go 'func Env(name string) string' 'func Env2(name string) string' "$T/s4.go")
echo "check-go-env: self-test 4 planted $n deletion(s) of the replacement"
if [ "${n:-0}" -lt 1 ]; then
    echo "check-go-env: SELF-TEST FAIL — kaya.Env's declaration has been" \
        "respelled; clause 4 tested nothing." >&2
    status=1
elif replacement "$T/s4.go" >/dev/null 2>&1; then
    echo "check-go-env: SELF-TEST FAIL — the replacement clause passed a file" \
        "with no kaya.Env in it." >&2
    status=1
fi

if [ "$status" != 0 ]; then
    echo "check-go-env: the gate cannot vouch for itself; nothing below ran." >&2
    exit 1
fi

# ------------------------------------------------------------ the scan

if ! scan bindings/go guests/go >"$T/found.txt" 2>"$T/err.txt"; then
    if [ -s "$T/err.txt" ]; then
        cat "$T/err.txt" >&2
        exit 1
    fi
    echo "check-go-env: Go's own view of the environment is EMPTY in an" \
        "Android guest — the .so is loaded, not exec'd, so the Go runtime" \
        "never sees an envp while C's getenv reads the live one. Use" \
        "kaya.Env / kaya.LookupEnv (bindings/go/runtime.go), which read" \
        "through C:" >&2
    cat "$T/found.txt" >&2
    echo "check-go-env: the failure this prevents is SILENT — an empty" \
        "KAYA_SELFTEST is not an unknown scene name, it is the default" \
        "arm, so every Android leg would run milestone2 against another" \
        "scene's script. See docs/go-mobile-plan.md D2." >&2
    exit 1
fi

files=$(find bindings/go guests/go -name '*.go' -type f | wc -l | tr -d ' ')
echo "check-go-env: OK — $files Go files, no reader of Go's copy of the environment"
