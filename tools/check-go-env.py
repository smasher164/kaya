#!/usr/bin/env python3
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent / "lib"))
from kaya_gate import ROOT, Gate, dev_shell_or_die

dev_shell_or_die()

# A GO GUEST READS THE HOST'S ENVIRONMENT, NEVER GO'S COPY OF IT
# (docs/go-mobile-plan.md D2). In a `-buildmode=c-shared` .so Go's view
# of the environment is empty forever while C's getenv(3) reads the
# live `environ`, and the failure is SILENT: an empty KAYA_SELFTEST is
# not an unknown scene name, it is the default arm.
#
# NOTHING AT COMPILE TIME OR RUN TIME CAN TELL THE TWO SPELLINGS APART:
# both compile everywhere, both RETURN on Android, and an empty
# environment is Android's normal state for a c-shared library. That
# leaves the static text. BOTH ROOTS are scanned — guests/go is where
# the defect would be written, bindings/go is where it would be written
# a second time by whoever "fixes" kaya.Env to call os.Getenv.
#
# THE SECOND RULE: A GUEST ASKS KAYA FOR PLATFORM LOCATIONS, NEVER THE
# LANGUAGE RUNTIME'S SNAPSHOT. `os.TempDir` is the same defect wearing
# a different name — on unix it IS `Getenv("TMPDIR")` with a "/tmp"
# fallback, so it answers CONFIDENTLY out of the same empty map with a
# path an Android app may not write. UserHomeDir, UserCacheDir and
# UserConfigDir are here for the same reason.
#
# NOT A FLAT BAN: the desktop arm of a platform switch is the one
# place the call is right. So the rule is STRUCTURAL — a location
# reader must sit inside a function that both branches on runtime.GOOS
# and reaches a location through kaya.Env. A name rule ("call it
# sceneRoot") would be satisfied by renaming; a flat ban would push
# guests toward hardcoding "/tmp".
#
# THE SCAN IS A PARSER, NOT A GREP (tools/checks/goenv.go — an
# in-toolchain Go payload, built and run rather than paraphrased), and
# that is load-bearing: every file this rule protects DOCUMENTS the
# rule, so bindings/go/runtime.go says "os.Getenv" six times in prose.
# go/parser also resolves whatever local name the `os` import was given
# and answers "which function is this call in", which the second rule
# needs.

import re
import shutil
import subprocess

# Line-buffered stdout: the Go toolchain writes to the same fd, and
# block-buffered prints would land AFTER output they preceded.
sys.stdout.reconfigure(line_buffering=True)

g = Gate("check-go-env")

if shutil.which("go") is None:
    print("check-go-env: go not found — run inside nix develop",
          file=sys.stderr)
    raise SystemExit(1)

T = g.scratch()
SCANNER = "tools/checks/goenv.go"

# BUILT ONCE AND RUN, not `go run` six times: `go run` prints its own
# "exit status 1" to stderr when the program exits non-zero, so a
# caller reading stderr cannot tell that from the scanner breaking.
if subprocess.run(["go", "build", "-o", str(T / "goenv"), SCANNER],
                  cwd=ROOT, check=False).returncode != 0:
    print(f"check-go-env: the scanner would not build — fix it in "
          f"{SCANNER}.", file=sys.stderr)
    raise SystemExit(1)


def scan(*args):
    return subprocess.run([str(T / "goenv"), *[str(a) for a in args]],
                          cwd=ROOT, capture_output=True, text=True,
                          check=False)


# doctor: FROM replaced by TO across a real file's bytes, written to
# scratch, THE COUNT PRINTED AND DEMANDED — every self-test below reads
# that number and a zero is a broken test, not a passed one.
def doctor_copy(label, rel, frm, to, out_name, want):
    text = g.doctor(label, (ROOT / rel).read_text(encoding="utf-8"),
                    re.escape(frm), to.replace("\\", "\\\\"), want=want)
    out = T / out_name
    out.write_text(text, encoding="utf-8")
    return out


status = 0


def selftest_fail(msg):
    global status
    print(f"check-go-env: SELF-TEST FAIL — {msg}", file=sys.stderr)
    status = 1


# ---------------------------------------------------------- self-tests
#
# All of these run against the REAL BYTES of REAL FILES, doctored in
# memory, with the substitution count printed. A clause that parsed
# nothing agrees with everything, and this gate's whole job is to
# disagree.

# 1. The scan sees the defect in the BINDING. runtime.go's C.getenv is
#    the one correct spelling in the tree; turned into os.Getenv it is
#    the defect exactly. TWO SITES (Env and LookupEnv), both doctored.
s1 = doctor_copy("1 planted the defect in bindings/go/runtime.go",
                 "bindings/go/runtime.go", "C.getenv(", "os.Getenv(",
                 "s1.go", want=2)
if scan("-file", s1).returncode == 0:
    selftest_fail("the scan passed a file that calls os.Getenv.")

# 2. The scan sees the defect in a GUEST, the root the trap lands in.
#    The token has to sit in a file that IMPORTS os — the scanner
#    resolves the import's local name and ignores a bare `os` bound to
#    nothing — which is what main_desktop.go is.
s2 = doctor_copy("2 planted the defect in guests/go/cmd/"
                 "main_desktop.go", "guests/go/cmd/main_desktop.go",
                 "os.Exit(", "os.Getenv(", "s2.go", want=1)
if scan("-file", s2).returncode == 0:
    selftest_fail("the scan passed a guest that calls os.Getenv.")

# 2b. AND IT READS A FILE NO MAC EVER COMPILES: the Android arm is
#    behind `//go:build android`, so a scanner honouring build
#    constraints would be blind exactly where the defect can happen.
#    go/parser does not evaluate them.
#
#    THE PLANT CARRIES ITS OWN IMPORT, under an ALIAS, so the scanner
#    must resolve the local name rather than match the text "os.".
#    Keyed on `package main`, the one token every Go file has once.
s2b = doctor_copy("2b planted an aliased-import defect in "
                  "guests/go/cmd/main_android.go",
                  "guests/go/cmd/main_android.go", "package main",
                  'package main\n\nimport osprobe "os"\n\n'
                  'var _ = osprobe.Getenv("KAYA_SELFTEST")',
                  "s2b.go", want=1)
android_lines = (ROOT / "guests" / "go" / "cmd" / "main_android.go") \
    .read_text(encoding="utf-8").splitlines()
if not any(line.startswith("//go:build android")
           for line in android_lines):
    selftest_fail("guests/go/cmd/main_android.go no longer carries "
                  "//go:build android, so clause 2b proves nothing "
                  "about constrained files. Point it at the Android "
                  "arm of a Go guest.")
elif scan("-file", s2b).returncode == 0:
    selftest_fail("the scan passed an ANDROID-TAGGED guest that calls "
                  "os.Getenv under an aliased import. The scanner is "
                  "blind exactly where this rule matters.")

# 3. PROSE IS NOT CODE: every file the rule protects explains the
#    rule, so runtime.go names os.Getenv in its own comments.
#
#    ISOLATED RATHER THAN READ OFF THE REAL FILE: scanning the
#    undoctored runtime.go would MISDIAGNOSE a real defect as "you
#    flagged a comment". The clause is built from the real comment
#    lines alone, lifted into a file that has nothing else in it, so
#    the only thing that can fail it is the property it names.
runtime_text = (ROOT / "bindings" / "go" / "runtime.go").read_text(
    encoding="utf-8")
prose = [ln for ln in runtime_text.splitlines()
         if ln.lstrip().startswith("//") and "os.Getenv" in ln]
print(f"check-go-env: self-test 3 lifted {len(prose)} comment line(s) "
      f"naming os.Getenv")
# A compilable file whose ONLY mention of the banned readers is prose,
# with a legitimate os use so the import is not the thing under test.
# NOT os.TempDir, which the location rule would flag on its own merits
# and which would make this clause pass or fail for the wrong reason.
s3 = T / "s3.go"
s3.write_text('package p\n\nimport "os"\n\n' + "\n".join(prose)
              + "\nvar _ = os.Stdout\n", encoding="utf-8")
if not prose:
    selftest_fail("bindings/go/runtime.go no longer explains the rule "
                  "in prose, so 'comments are not code' is untested "
                  "here.")
elif scan("-file", s3).returncode != 0:
    selftest_fail("the scan flagged os.Getenv inside a COMMENT. It "
                  "must read code, not prose.")

# 4. THE REPLACEMENT MUST EXIST AND MUST GO THROUGH C: a replacement
#    that has quietly become os.Getenv is the same defect wearing
#    kaya's name.
NEED = ["func Env(name string) string",
        "func LookupEnv(name string) (string, bool)",
        "C.getenv("]


def replacement_missing(text):
    return [n for n in NEED if n not in text]


missing = replacement_missing(runtime_text)
if missing:
    print(f"check-go-env: bindings/go/runtime.go is missing the "
          f"replacement this gate points at: {' '.join(missing)}",
          file=sys.stderr)
    status = 1
s4 = doctor_copy("4 planted a deletion of the replacement",
                 "bindings/go/runtime.go",
                 "func Env(name string) string",
                 "func Env2(name string) string", "s4.go", want=1)
if not replacement_missing(s4.read_text(encoding="utf-8")):
    selftest_fail("the replacement clause passed a file with no "
                  "kaya.Env in it.")

# ------------------------------------------- the location rule's four
#
# 5a-5d. EVERY BRANCH OF THE LOCATION VERDICT IS MADE TO PRINT, and
#    the MESSAGE is what each clause reads, not merely the exit status
#    (CLAUDE.md invariant 3: a why-not is believed). All four are
#    reached off the REAL bytes of the file the rule was written for.
def loc_says(doctored, fragment, label):
    r = scan("-file", doctored)
    out = r.stdout + r.stderr
    if r.returncode == 0:
        selftest_fail(f"the location rule passed {label}.")
        return
    if fragment not in out:
        print(f'check-go-env: SELF-TEST FAIL — the location rule went '
              f'red for {label} but did not say why in the words this '
              f'clause expects ("{fragment}"). It said:',
              file=sys.stderr)
        print(out, file=sys.stderr)
        global status
        status = 1


# 5a. The BARE call: a scene directory computed straight from Go's
#     snapshot, in a function that has branched on nothing.
s5a = doctor_copy("5a planted a bare location read in "
                  "guests/go/filedialog/filedialog.go",
                  "guests/go/filedialog/filedialog.go",
                  "filepath.Join(sceneRoot(),",
                  "filepath.Join(os.TempDir(),", "s5a.go", want=1)
loc_says(s5a, "neither reads runtime.GOOS nor asks kaya",
         "a bare os.TempDir in the scene's build")

# 5b. The switch WITHOUT the host channel: platform arms that hardcode
#     paths are guesses, and this is the shape a "simplification" of
#     sceneRoot would produce. TWO SITES (android + ios), both
#     doctored.
s5b = doctor_copy("5b planted unasked locations",
                  "guests/go/filedialog/filedialog.go", "kaya.Env(",
                  "hardcoded(", "s5b.go", want=2)
loc_says(s5b, "reaches no location through kaya.Env",
         "a platform switch whose arms ask nobody")

# 5c. The host channel WITHOUT the switch: the fallback is then the
#     answer on the phones too, which is the defect with extra steps.
#     TWO SITES, both doctored.
s5c = doctor_copy("5c planted unbranched location reads",
                  "guests/go/filedialog/filedialog.go", "runtime.GOOS",
                  "platformName", "s5c.go", want=2)
loc_says(s5c, "never reads runtime.GOOS",
         "a fallback reached on every platform")

# 5d. And PACKAGE LEVEL, where there is no function to have branched
#     at all. Anchored AFTER the import block (Go refuses a
#     declaration before one).
s5d = doctor_copy("5d planted a package-level location read",
                  "guests/go/filedialog/filedialog.go",
                  "func sceneRoot() string {",
                  "var _ = os.TempDir\n\nfunc sceneRoot() string {",
                  "s5d.go", want=1)
loc_says(s5d, "at package level", "a location read outside any "
                                  "function")

if status != 0:
    print("check-go-env: the gate cannot vouch for itself; nothing "
          "below ran.", file=sys.stderr)
    raise SystemExit(1)

# ------------------------------------------------------------ the scan

r = scan("bindings/go", "guests/go")
if r.returncode != 0:
    if r.stderr:
        print(r.stderr, file=sys.stderr)
        raise SystemExit(1)
    # ONE SENTENCE PER RULE: the two failures share a cause but not a
    # fix, so printing both paragraphs would send half the readers to
    # the wrong one.
    env_lines = [ln for ln in r.stdout.splitlines()
                 if ln.startswith("env: ")]
    loc_lines = [ln for ln in r.stdout.splitlines()
                 if ln.startswith("loc: ")]
    if env_lines:
        print("check-go-env: Go's own view of the environment is "
              "EMPTY in an Android guest — the .so is loaded, not "
              "exec'd, so the Go runtime never sees an envp while C's "
              "getenv reads the live one. Use kaya.Env / "
              "kaya.LookupEnv (bindings/go/runtime.go), which read "
              "through C:", file=sys.stderr)
        print("\n".join(env_lines), file=sys.stderr)
        print("check-go-env: the failure this prevents is SILENT — an "
              "empty KAYA_SELFTEST is not an unknown scene name, it "
              "is the default arm, so every Android leg would run "
              "milestone2 against another scene's script. See "
              "docs/go-mobile-plan.md D2.", file=sys.stderr)
    if loc_lines:
        print("check-go-env: a guest asks kaya for platform "
              "locations, never the language runtime's snapshot "
              "(ratified 2026-08-17). These readers answer out of the "
              "same empty copy on Android, and they answer "
              'CONFIDENTLY — os.TempDir returns its hardcoded "/tmp", '
              "which no Android app may write, so the scene's files "
              "go where nothing looks and nothing errors:",
              file=sys.stderr)
        print("\n".join(loc_lines), file=sys.stderr)
        print("check-go-env: the shape that is allowed is the one "
              "guests/go/{filedialog,save,editor,clipboard} carry — a "
              "sceneRoot() switching on runtime.GOOS, asking kaya.Env "
              "for the phone locations (EXTERNAL_STORAGE, HOME), with "
              "os.TempDir as the arm only a desktop reaches.",
              file=sys.stderr)
    raise SystemExit(1)

files = sum(1 for root_ in ("bindings/go", "guests/go")
            for p in (ROOT / root_).rglob("*.go") if p.is_file())
print(f"check-go-env: OK — {files} Go files, no reader of Go's copy "
      f"of the environment and no platform location taken from it")
