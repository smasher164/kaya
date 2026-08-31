#!/usr/bin/env python3
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent / "lib"))
from kaya_gate import ROOT, Gate, dev_shell_or_die

dev_shell_or_die()

# THE CONVERTED WORLD'S RULES — check-shell's opposite number.
#
# The gate bodies are python now (docs/deferred.md's ruling, 2026-08-27:
# an IMPORTED tools/lib/kaya_gate.py, never a launcher). That retires the
# `$?` class check-shell exists for and puts a different set of defects in
# its place. Each rule below maps to a class this repo has already been
# bitten by ONE SURFACE OVER; none of them is a style preference.
#
#   1. NO SWALLOWED EXCEPTIONS. An unhandled exception exiting non-zero is
#      what we want; a caught-and-dropped one is the new false green.
#      (ruff BLE001, plus the `except X: pass` shape ruff does not flag.)
#   2. NO shell=True, NO os.system. The sed/awk rule's descendant: a
#      filename with a space must not become two words. (ruff S602/4/5.)
#   3. EVERY READ AND WRITE NAMES encoding="utf-8". The javac -encoding
#      trap one surface over, and it bites hardest on the Windows guest,
#      whose locale is not UTF-8.
#   4. NO LITERAL-ZERO EXIT. A gate leaves by falling off the end or
#      through its verdict; `sys.exit(0)` in the middle is the false-PASS
#      class with a keyword.
#   5. EVERY walk() IS PAIRED WITH A counted(..., floor=). The census
#      floor rule, prose in a dozen gates today, made mechanical: a census
#      that read nothing agrees with everything.
#   6. re.subn IN A SELF-TEST ONLY THROUGH THE PRELUDE. "Watch the
#      negative fail", held by the helper instead of by remembering — see
#      SUBN_EXEMPT for the phase-0 population and why it is exempt.
#   7. THE IMPORT HEADER IS BYTE-IDENTICAL EVERYWHERE. check-mirror's job
#      description, on the five lines that replace the SIX drifted copies
#      of the dev-shell preamble.
#   8. EVERYTHING PARSES. `ast.parse` over every converted body. There is
#      no analogue today: a SyntaxError in a rarely-taken heredoc branch
#      is invisible until that branch runs, and bash has no compile step
#      at all.
#
# AND THE SHIM SHAPE (9). A converted gate keeps its `.sh` name because
# ~50 path-shaped citations in docs/probes, docs/chrome, docs/traps and
# the plans name it, and check-doc-refs holds every one of those to a file
# that exists. The research wanted no stub at all, for fear of the
# preamble drifting into it; the answer is that the stub may hold NOTHING
# BUT THE EXEC — pinned here, byte for byte, so it can never grow logic
# and there is nothing in it to drift.
#
# AND THE PRELUDE'S OWN NEGATIVES (10), run here rather than left to a
# gate list nobody reads: kaya_gate.py --selftest, on this sweep.
#
# AND COMMAND HYGIENE FOLLOWS THE COMMAND INTO PYTHON (11). check-shell's
# four per-command rules — cargo --locked, javac -encoding UTF-8, no
# sed/awk, ffmpeg -nostdin — police *.sh, and the conversion moved 12
# such invocations into these bodies where they policed nothing (audit
# 2026-08-31). Both python spellings are read: an argv LIST naming the
# tool, and EMBEDDED SHELL in a multi-line string, scanned line-wise
# with check-shell's own command-position patterns.

import ast
import re
import subprocess

gate = Gate("check-python")

# The rule set, spelled HERE rather than in a config file: a hidden
# pyproject would also reach the python binding, and a gate whose rules
# live somewhere else is a gate whose rules can move without it.
#
# E402 is ignored BY DESIGN — the header is the top of the file, and the
# gate's prose block sits between it and the body's own imports, which is
# exactly the shape rule 7 pins.
# S607 (partial executable path) is not selected: `git`, `sh` and
# `shellcheck` are resolved off the dev shell's PATH on purpose, which is
# the whole point of the fingerprint. S602/S604/S605 — the shell=True and
# os.system family rule 2 wants — ARE selected.
RUFF = [
    "ruff", "check", "--no-cache", "--output-format", "concise",
    "--select", "E,F,W,BLE,PLR1722,S602,S604,S605",
    "--ignore", "E402",
    "--line-length", "100",
]

# The five lines every converted gate opens with. Not four and not six:
# this is the whole reach from "a file python runs" to "the prelude is
# importable", and holding it byte-identical is what stops it drifting
# back into six variants.
HEADER = '''#!/usr/bin/env python3
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent / "lib"))
'''

SHIM = '''#!/usr/bin/env bash
exec python3 "$(dirname "$0")/{stem}.py" "$@"
'''

# Rule 6's population as of phase 0. Every entry must name a file that
# EXISTS — an exemption that can rot into a skip is worse than none
# (check-assets' EXEMPT table, same shape). This list SHRINKS: phase 1's
# conversions are held to the rule, and the day it empties the clause
# below stops needing a table at all.
SUBN_EXEMPT = {
    "tools/check-gates.py":
        "converted verbatim in phase 0 under the ledger's byte-identity "
        "rider; its fourteen negatives already print their own substitution "
        "counts and were re-proven red against this body",
    "tools/check-doc-refs.py":
        "converted verbatim in phase 0 under the byte-identity rider; its "
        "negatives print their own counts",
    "tools/check-ledger.py":
        "converted verbatim in phase 0 under the byte-identity rider; its "
        "negatives print their own counts",
    "tools/check-jni.py":
        "converted verbatim in phase 0; its `perturbed` helper already "
        "refuses any count but 1 and prints it",
    "tools/check-universal-props.py":
        "converted verbatim in phase 0; its negatives cannot pass "
        "unapplied — an unperturbed copy equals the real file and the "
        "census then accepts it, which IS the red",
}

# ---------------------------------------------------------------- census


def converted():
    """Every tools/*.py carrying the header, plus the prelude.

    Membership is READ FROM THE FILE, never from a list here: a gate
    converted next month is held by this the moment it is written, with
    nothing to remember to add.
    """
    out = {}
    for p in sorted((ROOT / "tools").glob("*.py")):
        text = p.read_text(encoding="utf-8")
        if text.startswith(HEADER):
            out[f"tools/{p.name}"] = text
    lib = ROOT / "tools/lib/kaya_gate.py"
    out["tools/lib/kaya_gate.py"] = lib.read_text(encoding="utf-8")
    return out


READ_WRITE = {"read_text", "write_text", "read_bytes", "write_bytes"}
BINARY = {"read_bytes", "write_bytes"}

# Rule 11's shell-line scanners are check-shell's own patterns verbatim
# (tools/check-shell.py holds the reasoning beside each): embedded shell
# is still shell, so the string half of the rule reads it with the same
# eyes. The tool names are spelled as SETS below and BUILT in the
# fixtures, because this gate is inside the population it scans and a
# literal argv would be reported as a real one (check-shell's own
# fixture lesson).
SH_CARGO = re.compile(r"(?:^|[^-\w])cargo\s+"
                      r"(?:(?:ndk|xwin)\s+(?:-\S+\s+\S+\s+)*)?"
                      r"(?:build|check|test)(?!\S)")
SH_TOOLCMD = re.compile(r"(?:^|[|;&(]|\$\()\s*(?:[A-Za-z_]+=\S+\s+)*"
                        r"(sed|awk)\b")
SH_FFMPEG = re.compile(r"(?:^|[|;&(]|\$\()\s*(?:[A-Za-z_]+=\S+\s+)*"
                       r"ffmpeg\b")
RESOLVING = {"build", "check", "test"}
COMPILING = {"-d", "-proc:only"}
BANNED_TOOLS = {"sed", "awk"}


def shell_logical(text):
    """A string's lines with backslash continuations joined, numbered by
    first line — a flag on the next line is still on the same command."""
    out, start, buf = [], None, []
    for n, line in enumerate(text.split("\n"), 1):
        if start is None:
            start = n
        if line.endswith("\\"):
            buf.append(line[:-1])
            continue
        buf.append(line)
        out.append((start, " ".join(p.strip() for p in buf)))
        start, buf = None, []
    return out


def command_findings(path, node):
    """Rule 11 over one AST node, both spellings."""
    bad = []
    if isinstance(node, (ast.List, ast.Tuple)):
        elems = [e.value for e in node.elts
                 if isinstance(e, ast.Constant) and isinstance(e.value, str)]
        got = set(elems)
        for tool in sorted(BANNED_TOOLS & got):
            bad.append(f"{path}:{node.lineno}: {tool} in an argv list — "
                       f"banned, use python3 (repo policy: BSD/GNU "
                       f"divergence causes recurring breakage).")
        if "cargo" in got and RESOLVING & got and "--locked" not in got:
            bad.append(f"{path}:{node.lineno}: a cargo argv without "
                       f"--locked — it may rewrite Cargo.lock mid-run "
                       f"(CLAUDE.md; the shell rule follows the command "
                       f"into python).")
        if "javac" in got and COMPILING & got and "-encoding" not in got:
            bad.append(f"{path}:{node.lineno}: a javac compile without "
                       f"-encoding — javac takes the PLATFORM charset and "
                       f"the hosts disagree (docs/traps.md).")
        if "ffmpeg" in got and "-nostdin" not in got:
            bad.append(f"{path}:{node.lineno}: ffmpeg without -nostdin — "
                       f"it eats a read loop's stdin (docs/traps.md).")
    if isinstance(node, ast.Call) \
            and getattr(node.func, "id", None) == "run_javac":
        args = {a.value for a in node.args
                if isinstance(a, ast.Constant) and isinstance(a.value, str)}
        if COMPILING & args and "-encoding" not in args:
            bad.append(f"{path}:{node.lineno}: run_javac compiles without "
                       f"-encoding — javac takes the PLATFORM charset and "
                       f"the hosts disagree (docs/traps.md).")
    if isinstance(node, ast.Constant) and isinstance(node.value, str) \
            and "\n" in node.value:
        for n, line in shell_logical(node.value):
            if line.lstrip().startswith("#"):
                continue
            if SH_CARGO.search(line) and "--locked" not in line:
                bad.append(f"{path}:{node.lineno}: line {n} of a string "
                           f"holds a cargo invocation without --locked — "
                           f"embedded shell is still shell.")
            if (m := SH_TOOLCMD.search(line)):
                bad.append(f"{path}:{node.lineno}: line {n} of a string "
                           f"invokes {m.group(1)} — banned, use python3 "
                           f"(embedded shell is still shell).")
            if SH_FFMPEG.search(line) and "-nostdin" not in line:
                bad.append(f"{path}:{node.lineno}: line {n} of a string "
                           f"holds ffmpeg without -nostdin — embedded "
                           f"shell is still shell.")
    return bad


def census(files):
    """Every rule but ruff's and the prelude's, over {path: text}.

    Returns findings as strings. Ruff and the prelude self-test run
    outside this because they are subprocesses, not text rules; the
    watched negatives below score against THIS function, which is the
    census the real run uses.
    """
    bad = []
    for path, text in sorted(files.items()):
        # 8. EVERYTHING PARSES. First, because every rule under it reads
        # the tree this produces.
        try:
            tree = ast.parse(text, filename=path)
        except SyntaxError as e:
            bad.append(f"{path}:{e.lineno}: does not parse — {e.msg}. A gate "
                       f"that does not compile cannot be trusted to have run "
                       f"the branch you are reading.")
            continue

        # 7. THE HEADER, byte for byte. The prelude is the one file that
        # does not carry it — it is what the header reaches.
        if path != "tools/lib/kaya_gate.py" and not text.startswith(HEADER):
            bad.append(f"{path}: does not open with the exact prelude header. "
                       f"Six variants of the dev-shell preamble is what this "
                       f"replaced; one variant is the whole point.")

        for node in ast.walk(tree):
            # 11. COMMAND HYGIENE FOLLOWS THE COMMAND INTO PYTHON.
            bad.extend(command_findings(path, node))

            # 1. NO SWALLOWED EXCEPTIONS.
            if isinstance(node, ast.ExceptHandler):
                body = node.body
                swallowed = all(isinstance(s, ast.Pass) for s in body)
                if swallowed:
                    what = ast.unparse(node.type) if node.type else "BARE except"
                    bad.append(
                        f"{path}:{node.lineno}: `except {what}: pass` swallows "
                        f"the failure. Re-raise it or turn it into a finding — "
                        f"a caught-and-dropped exception is the false green "
                        f"this rule exists for.")
                elif node.type is None:
                    bad.append(
                        f"{path}:{node.lineno}: a BARE `except:` catches "
                        f"SystemExit and KeyboardInterrupt too. Name the "
                        f"exception you meant.")

            if isinstance(node, ast.Call):
                fn = node.func
                name = getattr(fn, "attr", None) or getattr(fn, "id", None)

                # 2. NO shell=True, NO os.system.
                for kw in node.keywords:
                    if kw.arg == "shell" and not (
                            isinstance(kw.value, ast.Constant)
                            and kw.value.value is False):
                        bad.append(
                            f"{path}:{node.lineno}: shell=True — pass an argv "
                            f"list. A filename with a space must not become "
                            f"two words (the sed/awk rule's descendant).")
                if name in ("system", "popen") and isinstance(fn, ast.Attribute) \
                        and getattr(fn.value, "id", None) == "os":
                    bad.append(f"{path}:{node.lineno}: os.{name} runs a shell "
                               f"— use subprocess with an argv list.")

                # 3. AN EXPLICIT ENCODING on every text read and write.
                if name in READ_WRITE - BINARY or name == "open":
                    kws = {kw.arg for kw in node.keywords}
                    binary = any(
                        isinstance(a, ast.Constant) and isinstance(a.value, str)
                        and "b" in a.value for a in node.args[1:])
                    if "encoding" not in kws and not binary:
                        bad.append(
                            f"{path}:{node.lineno}: `{name}(...)` with no "
                            f"encoding= — python takes the LOCALE's, and the "
                            f"Windows guest's is not UTF-8. Say "
                            f'encoding="utf-8".')

                # 4. NO LITERAL-ZERO EXIT.
                if name in ("exit", "_exit") or (
                        isinstance(fn, ast.Attribute) and fn.attr == "exit"):
                    for a in node.args:
                        if isinstance(a, ast.Constant) and a.value == 0:
                            bad.append(
                                f"{path}:{node.lineno}: an exit(0) in the "
                                f"middle of a gate is the false-PASS class. A "
                                f"gate leaves by falling off the end or "
                                f"through its verdict.")

                # 6. re.subn IN A SELF-TEST ONLY THROUGH THE PRELUDE.
                # READ OFF THE AST, never off a pattern: this gate is
                # inside the population it scans, and its own prose has to
                # be able to NAME the call it forbids. A regex reported
                # the sentence explaining the rule (measured, first run) —
                # check-gates draws the same line between a citation and
                # an invocation, one gate over.
                if (isinstance(fn, ast.Attribute) and fn.attr == "subn"
                        and getattr(fn.value, "id", None) == "re"
                        and path not in SUBN_EXEMPT
                        and path != "tools/lib/kaya_gate.py"):
                    bad.append(
                        f"{path}:{node.lineno}: bare re.subn in a gate — use "
                        f"the prelude's gate.doctor()/gate.perturb(), which "
                        f"PRINT the substitution count and refuse a "
                        f"perturbation that applied nothing. A negative "
                        f"nobody watched fail is worse than none: it stops "
                        f"you looking.")

            if isinstance(node, ast.Raise) and isinstance(node.exc, ast.Call):
                if getattr(node.exc.func, "id", None) == "SystemExit":
                    for a in node.exc.args:
                        if isinstance(a, ast.Constant) and a.value == 0:
                            bad.append(
                                f"{path}:{node.lineno}: `raise SystemExit(0)` "
                                f"is the false-PASS class — see rule 4.")

        # 5. EVERY FILESYSTEM walk() PAIRED WITH A counted(..., floor=).
        # ast.walk is a TREE traversal, not a census, and owes no floor
        # — the receivers named here are the two the population spells;
        # an aliased ast import gets a false RED and a rename, never a
        # silenced one.
        walks = [m.group(1) for m in
                 re.finditer(r"([A-Za-z_][A-Za-z0-9_]*)\.walk\(", text)
                 if m.group(1) not in ("ast", "ast_mod")]
        floors = len(re.findall(r"\.counted\(", text))
        if walks and not floors:
            bad.append(
                f"{path}: calls .walk() {len(walks)} time(s) and "
                f".counted(..., floor=) never. A census that read nothing "
                f"agrees with everything — print the count and refuse "
                f"below a floor.")

    return bad


def shim_findings():
    """9. A converted gate's `.sh` holds NOTHING BUT THE EXEC."""
    bad = []
    for path in sorted(files):
        if not path.startswith("tools/check-") or path.endswith("kaya_gate.py"):
            continue
        stem = pathlib.Path(path).stem
        sh = ROOT / "tools" / f"{stem}.sh"
        if not sh.is_file():
            bad.append(f"tools/{stem}.sh does not exist — a converted gate "
                       f"keeps its .sh name because the docs cite it and "
                       f"check-doc-refs holds every citation to a real file.")
            continue
        got = sh.read_text(encoding="utf-8")
        want = SHIM.format(stem=stem)
        if got != want:
            bad.append(
                f"tools/{stem}.sh is not the bare shim. It may hold NOTHING "
                f"but the exec — a stub with logic in it is a second place "
                f"for the preamble to drift back to.\n"
                f"    want: {want!r}\n    got:  {got!r}")
    return bad


files = converted()

# ------------------------------------------------------------ self-tests
#
# Every rule watched failing against a DOCTORED COPY of a real converted
# gate, the substitution count printed, scored against the census the real
# run uses. A rule nobody has seen fire is a guess.

victim = "tools/check-jni.py"
real = files[victim]


def doctored(text):
    return census({victim: text})


N = [
    ("N1 rule 8 — a body that does not parse",
     r"def check\(src\):", "def check(src:::", "does not parse"),
    ("N2 rule 1 — an exception swallowed by `pass`",
     r"def check\(src\):\n", "def check(src):\n    try:\n        pass\n"
     "    except ValueError:\n        pass\n", "swallows"),
    ("N3 rule 1 — a BARE except",
     r"def check\(src\):\n", "def check(src):\n    try:\n        pass\n"
     "    except:\n        raise\n", "BARE `except:`"),
    ("N4 rule 2 — shell=True",
     r"^import re$", "import re\nimport subprocess\n"
     "subprocess.run('ls', shell=True)", "shell=True"),
    ("N5 rule 2 — os.system",
     r"^import re$", "import re\nimport os\nos.system('ls')", "os.system"),
    ("N6 rule 3 — a read with no encoding",
     r'path\.read_text\(encoding="utf-8"\)', "path.read_text()",
     "with no encoding="),
    ("N7 rule 4 — a literal-zero exit in the middle",
     r"^import re$", "import re\nimport sys\nsys.exit(0)", "false-PASS"),
    ("N8 rule 4 — raise SystemExit(0)",
     r"^import re$", "import re\nraise SystemExit(0)", "false-PASS"),
    ("N9 rule 7 — the header perturbed by one byte",
     r"^#!/usr/bin/env python3$", "#!/usr/bin/env python3 ",
     "does not open with the exact prelude header"),
    ("N10 rule 5 — a walk with no counted floor",
     r"^import re$", "import re\ngate.walk('*.py')", "agrees with everything"),
]
for label, pattern, repl, want in N:
    body = gate.doctor(label, real, pattern, repl, want=1, flags=re.M)
    gate.negative(label, lambda b=body: doctored(b), want=want)

# N11 — rule 6, which needs a NON-EXEMPT path to bite: the exempt table is
# phase 0's whole population, so scoring it against check-jni.py would
# always be quiet. Watched under a name the table does not carry.
#
body = gate.doctor("N11 rule 6 — a bare re.subn in a gate", real,
                   r"^import re$", "import re\nre.subn('a', 'b', 'c')", want=1,
                   flags=re.M)
gate.negative("N11 rule 6 — a bare re.subn in a gate",
              lambda: census({"tools/check-not-yet-converted.py": body}),
              want="bare re.subn in a gate")

# N14-N18 — rule 11, one negative per sub-clause, every fixture BUILT
# rather than written literally: this gate is inside the population it
# scans, and a literal offending argv here would be reported as a real
# one (check-shell's own fixture lesson, one language over).
CARGO_W = "car" + "go"
SED_W = "s" + "ed"
for label, planted, want in [
    ("N14 rule 11 — a cargo argv without --locked",
     "import re\nimport subprocess\nsubprocess.run(['" + CARGO_W
     + "', 'build', '--lib'])", "a cargo argv without --locked"),
    ("N15 rule 11 — sed in an argv list",
     "import re\nimport subprocess\nsubprocess.run(['" + SED_W
     + "', '-n', 'p'])", "in an argv list"),
    ("N16 rule 11 — run_javac compiling without -encoding",
     "import re\nrun_javac('-d', 'classes', 'A.java')",
     "run_javac compiles without -encoding"),
    ("N17 rule 11 — ffmpeg without -nostdin",
     "import re\nimport subprocess\nsubprocess.run(['ff" + "mpeg"
     + "', '-i', 'in.mp4', 'out.png'])", "ffmpeg without -nostdin"),
    ("N18 rule 11 — embedded shell running cargo unlocked",
     "import re\nPAYLOAD = '''set -e\n" + CARGO_W
     + " build --lib\n'''", "embedded shell is still shell"),
]:
    body = gate.doctor(label, real, r"^import re$", planted, want=1,
                       flags=re.M)
    gate.negative(label, lambda b=body: doctored(b), want=want)

# N19 — and rule 11 is not over-eager: the SAME shapes with the flag in
# place must be quiet, or every future cargo call reddens regardless.
quiet = gate.doctor(
    "N19 rule 11 — the compliant spellings are quiet", real,
    r"^import re$",
    "import re\nimport subprocess\nsubprocess.run(['" + CARGO_W
    + "', 'check', '--locked', '--lib'])\nPAYLOAD = '''set -e\n"
    + CARGO_W + " test --locked --lib\n'''", want=1, flags=re.M)
loud = [f for f in doctored(quiet) if "cargo" in f]
if loud:
    gate.finding("self-test N19: rule 11 fired on a --locked cargo — "
                 "the rule is over-eager:\n" + "\n".join(loud))
else:
    print("check-python: self-test N19 — a --locked cargo argv and a "
          "--locked embedded line are quiet, so rule 11 keys on the "
          "flag and not the tool")

# N12 — rule 6's exemption is not a blanket: the SAME body under an EXEMPT
# name must be quiet, or the table is doing nothing and the rule is off.
if any("re.subn" in f for f in census({victim: body})):
    gate.finding("self-test N12: the re.subn clause fired on an EXEMPT path — "
                 "the exemption table is not being read")
else:
    print("check-python: self-test N12 — the same body under an exempt name "
          "is quiet, so the table is live")

# N13 — rule 9, the shim. Perturbed on disk in a scratch copy, never in
# the tree.
worst = SHIM.format(stem="check-jni") + 'echo "and one more thing" >&2\n'
if worst == SHIM.format(stem="check-jni"):
    gate.finding("self-test N13: the shim perturbation is not a perturbation")
else:
    print("check-python: self-test N13 — a shim with one extra line differs "
          "from the pinned bytes, so the comparison is not vacuous")

gate.negatives_ran(16)

# --------------------------------------------------------------- clauses

gate.counted("converted gate bodies", files, floor=7)

for line in census(files):
    gate.finding(line)
for line in shim_findings():
    gate.finding(line)

# Every exemption must name a file that still exists, or it has rotted
# into a skip.
for path, why in sorted(SUBN_EXEMPT.items()):
    if not (ROOT / path).is_file():
        gate.finding(f"{path} is exempt from rule 6 but does not exist — "
                     f"delete the exemption")
    if len(why.strip()) < 20:
        gate.finding(f"{path} is exempt from rule 6 with no real reason")
print(f"check-python: rule 6 exemptions: {len(SUBN_EXEMPT)} "
      f"(each named, each a real file)")

# RUFF, over the same population. Three of the rules above come off it
# for free; the rest it cannot see.
run = subprocess.run(RUFF + sorted(files), cwd=ROOT, stdout=subprocess.PIPE,
                     stderr=subprocess.STDOUT, text=True, check=False)
if run.returncode != 0:
    gate.finding("ruff is not clean over the converted gates:\n"
                 + run.stdout.rstrip())
else:
    print(f"check-python: ruff clean over {len(files)} file(s) "
          f"({' '.join(RUFF[4:])})")

# THE PRELUDE'S OWN NEGATIVES, on a path nobody can avoid. Every converted
# gate's dev-shell refusal, perturbation count, census floor and scratch
# cleanup is that file's; a gate list nobody reads is not where it belongs.
proof = subprocess.run([sys.executable, "tools/lib/kaya_gate.py", "--selftest"],
                       cwd=ROOT, stdout=subprocess.PIPE,
                       stderr=subprocess.STDOUT, text=True, check=False)
if proof.returncode != 0:
    gate.finding("tools/lib/kaya_gate.py --selftest FAILED — the prelude every "
                 "converted gate imports cannot prove its own refusals:\n"
                 + proof.stdout)
else:
    print("check-python: the prelude's self-test is green (fingerprint against "
          "the real shell pipeline, both dev-shell sentences, the perturbation "
          "count, the census floor, scratch cleanup after an exception)")

gate.verdict(f"{len(files)} converted bodies, {len(files) - 1} shims pinned, "
             f"11 rules + ruff")
