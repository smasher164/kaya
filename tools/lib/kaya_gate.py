"""The gate prelude — imported, never launched (docs/deferred.md's ruling).

Every converted gate opens with the fixed header check-python.py holds
byte-identical, then calls dev_shell_or_die(). What lived in six drifted
copies of a bash preamble lives here once.

THE DRIFT THIS REPLACES, measured 2026-08-27: 81 scripts carried the
dev-shell preamble in 6 textual variants, four already drifted — three
printed a shortened stale sentence and tools/win/undoarmprobe/run.sh
printed ONE sentence for BOTH causes, which is an invariant-3 diagnostic
defect (a sentence that cannot tell "never entered" from "entered before
the flake moved" is believed for the cause it does not name).

Run its own negatives with `python3 tools/lib/kaya_gate.py --selftest`;
tools/check-python.py runs that on every sweep.
"""

import atexit
import contextlib
import hashlib
import os
import pathlib
import re
import shutil
import sys
import tempfile

# From __file__, never from $0 or cwd: a gate must answer the same run
# from any directory, and `cd "$ROOT"` is the shell habit this drops.
ROOT = pathlib.Path(__file__).resolve().parent.parent.parent

# The two sentences, one per cause. Kept as module constants so the
# self-test compares the bytes it will really print, and so
# check-python.py can hold them against the shell preamble's.
UNSET_SENTENCE = "{who}: not inside the dev shell — run this under `nix develop`"
STALE_SENTENCE = (
    "{who}: dev shell is stale — the flake changed since it was entered; "
    "re-enter `nix develop`"
)


def flake_fingerprint(root=None):
    """sha256 over flake.nix then flake.lock, first 12 hex.

    EXACTLY what the shell preamble computes with
    `cat flake.nix flake.lock | shasum -a 256 | cut -c1-12`, and what
    flake.nix's own shellHook exports — one concatenated stream, not two
    hashes. The self-test below runs the real shell pipeline and compares.
    """
    root = pathlib.Path(root) if root is not None else ROOT
    h = hashlib.sha256()
    h.update((root / "flake.nix").read_bytes())
    h.update((root / "flake.lock").read_bytes())
    return h.hexdigest()[:12]


def _who():
    """The script the reader invoked, repo-relative when it is in the tree."""
    argv0 = pathlib.Path(sys.argv[0] or "kaya-gate")
    try:
        return str(argv0.resolve().relative_to(ROOT))
    except (ValueError, OSError):
        return str(argv0)


def dev_shell_refusal(env, want, who):
    """The sentence for this environment, or None if the shell is right.

    Split out from the exit so both branches can be MADE TO PRINT in the
    self-test — invariant 3's rule for diagnostics: a branch nobody has
    seen print is a guess about a state nobody has reached.
    """
    if env == want:
        return None
    if not env:
        return UNSET_SENTENCE.format(who=who)
    return STALE_SENTENCE.format(who=who)


def dev_shell_or_die():
    """Refuse outside the dev shell, naming WHICH of the two causes."""
    refusal = dev_shell_refusal(
        os.environ.get("KAYA_DEV_SHELL", ""), flake_fingerprint(), _who()
    )
    if refusal is not None:
        print(refusal, file=sys.stderr)
        raise SystemExit(1)


# Directories no census wants and every walk pays for: tools/ alone walks
# to 323,273 entries because of the bindgen build trees under it, against
# ~213 tracked files (measured 2026-08-27).
PRUNE = {
    ".git", "target", "target-linux", "build", "__pycache__", ".gradle",
    "node_modules", ".venv", "DerivedData", "Pods", ".mypy_cache",
    ".ruff_cache", ".pytest_cache",
}


class Refusal(Exception):
    """No verdict at all — the run read too little to have an opinion."""


def _excepthook(tp, value, tb, _default=sys.excepthook):
    """An uncaught Refusal ends the gate with its sentence alone.

    refuse() already printed the sentence; the default hook's traceback
    after it reads as a crash in the very place the gate is being most
    deliberate (audit 2026-08-31). The exit code is 1 either way, and a
    gate that CATCHES Refusal never reaches this."""
    if issubclass(tp, Refusal):
        return
    _default(tp, value, tb)


sys.excepthook = _excepthook


class Gate:
    """One gate's findings, census floors, scratch space and negatives.

    Printing is deliberately narrow: `<name>: ...` on every line, findings
    and refusals to stderr, so a converted gate's output is the shape the
    runners already read.
    """

    def __init__(self, name):
        self.name = name
        self.status = 0
        self._read = {}
        self._walks = {}
        self._counted = set()
        self._negatives = 0
        self._perturbs = 0
        self._scratch = None

    # ---------------------------------------------------------- census

    def read(self, rel):
        """One file's text, cached, ALWAYS with an explicit encoding.

        The javac `-encoding` trap one surface over: python's default is
        the locale's, and the Windows guest's locale is not UTF-8.
        """
        key = str(rel)
        if key not in self._read:
            p = pathlib.Path(rel)
            if not p.is_absolute():
                p = ROOT / p
            self._read[key] = p.read_text(encoding="utf-8")
        return self._read[key]

    def walk(self, *globs, under="."):
        """Paths under `under` matching any glob, from ONE cached traversal.

        The shell shape walks once per heredoc; this walks once per root.
        Pair every walk with counted(..., floor=) — check-python.py holds
        that pairing, because a census that read nothing agrees with
        everything.
        """
        base = (ROOT / under).resolve()
        if under not in self._walks:
            found = []
            for dirpath, dirnames, filenames in os.walk(base):
                dirnames[:] = [d for d in dirnames if d not in PRUNE]
                for fn in filenames:
                    found.append(pathlib.Path(dirpath) / fn)
            self._walks[under] = sorted(found)
        out = []
        for p in self._walks[under]:
            rel = p.relative_to(base)
            if any(rel.match(g) or p.match(g) for g in globs):
                out.append(p)
        return out

    def counted(self, label, items, floor):
        """Print the count and REFUSE below the floor.

        A census that reads two files agrees with everything, so the floor
        is the difference between a scan and a scan-shaped no-op. The
        count is printed on every run so the number is on the record even
        when it passes.
        """
        n = len(items) if not isinstance(items, int) else items
        print(f"{self.name}: {label}: {n}")
        self._counted.add(label)
        if n < floor:
            self.refuse(
                f"{label} found {n}, below the floor of {floor} — a census "
                f"that read almost nothing agrees with everything, so this "
                f"is a REFUSAL, not a pass"
            )
        return items

    def finding(self, msg, *, at=None):
        """One finding. Sets the exit status; never raises."""
        where = f"{at}: " if at else ""
        print(f"{self.name}: {where}{msg}", file=sys.stderr)
        self.status = 1

    def refuse(self, why):
        """No verdict at all — distinct from a finding, and terminal."""
        print(f"{self.name}: REFUSAL — {why}", file=sys.stderr)
        raise Refusal(why)

    def verdict(self, detail=""):
        """The one way out. `<name>: OK (detail)` or FINDINGS ABOVE."""
        if self.status == 0:
            print(f"{self.name}: OK{f' ({detail})' if detail else ''}")
        else:
            print(f"{self.name}: FINDINGS ABOVE", file=sys.stderr)
        raise SystemExit(self.status)

    # ------------------------------------------------------- self-test

    def scratch(self):
        """A tempdir removed at exit — the EXIT trap, ported.

        atexit rather than a `finally`: a gate that dies on an unexpected
        exception must still not leave a tree behind, which is what the
        shell's `trap ... EXIT` bought.
        """
        if self._scratch is None:
            self._scratch = pathlib.Path(tempfile.mkdtemp(prefix=f"{self.name}-"))
            atexit.register(shutil.rmtree, self._scratch, ignore_errors=True)
        return self._scratch

    def shadow(self, *rels):
        """A symlink-free copy of subtrees into scratch, for a doctored run."""
        dest = self.scratch() / "shadow"
        for rel in rels:
            src = ROOT / rel
            out = dest / rel
            out.parent.mkdir(parents=True, exist_ok=True)
            if src.is_dir():
                shutil.copytree(
                    src, out, symlinks=False, dirs_exist_ok=True,
                    ignore=shutil.ignore_patterns(*PRUNE),
                )
            else:
                shutil.copy2(src, out)
        return dest

    def doctor(self, label, text, pattern, repl, *, want=1, flags=0):
        """re.subn in MEMORY, count printed, refused when it is not `want`.

        Nothing is written to the tree, so the perturb-restore hazard
        (docs/traps.md — a git checkout on a mid-slice tree erases
        uncommitted work) disappears by construction. An unchanged text
        is a FAILED self-test, never a passed one: the wayland seat guard
        passed VACUOUSLY TWICE because its pattern never matched at all.
        """
        out, n = re.subn(pattern, repl, text, flags=flags)
        print(f"{self.name}: self-test {label}, {n} substitution(s)")
        if n != want:
            print(
                f"{self.name}: SELF-TEST BROKEN — {label} applied {n} "
                f"substitution(s), wanted exactly {want}. An unperturbed "
                f"copy proves nothing; the pattern no longer matches the "
                f"file as written.",
                file=sys.stderr,
            )
            raise SystemExit(1)
        return out

    def perturb(self, label, rel, pattern, repl, *, want=1, flags=0):
        """doctor() onto a COPY IN SCRATCH; returns the copy's path.

        Each call gets its OWN file (the suffix keeps the extension for
        anything that compiles the copy): negatives are evaluated
        eagerly today, but N perturbations of one source sharing a name
        means a deferred lambda would read the LAST doctored copy and
        go green for the wrong reason (audit 2026-08-31)."""
        text = self.doctor(label, self.read(rel), pattern, repl, want=want,
                           flags=flags)
        self._perturbs += 1
        out = self.scratch() / f"perturb-{self._perturbs}-{pathlib.Path(rel).name}"
        out.write_text(text, encoding="utf-8")
        return out

    def negative(self, label, census_fn, *, want):
        """Run THE GATE'S OWN census over doctored input; demand the finding.

        In-process, so a negative cannot drift from the census the way a
        re-typed heredoc can — which is the failure that let three of
        check-tx-liveness's five clauses pass with the guard deleted.
        """
        self._negatives += 1
        got = list(census_fn())
        if not any(want in line for line in got):
            print(
                f"{self.name}: SELF-TEST FAILED — {label} was not refused.\n"
                f"  wanted a finding containing: {want}\n"
                f"  got: " + ("\n       ".join(got) or "(nothing — the census "
                                                       "accepted it)"),
                file=sys.stderr,
            )
            self.status = 1
            return False
        return True

    def negatives_ran(self, n):
        """Refuse a verdict unless exactly `n` negatives actually ran."""
        print(f"{self.name}: {self._negatives} watched negative(s) ran")
        if self._negatives != n:
            self.refuse(
                f"{self._negatives} watched negative(s) ran, but {n} are "
                f"declared — a self-test that did not run is not a self-test"
            )


@contextlib.contextmanager
def scratch_dir(prefix="kaya-gate-"):
    """EXIT-safe temp directory for code with no Gate in hand."""
    d = pathlib.Path(tempfile.mkdtemp(prefix=prefix))
    try:
        yield d
    finally:
        shutil.rmtree(d, ignore_errors=True)


# ------------------------------------------------------------ self-test


def _selftest():  # noqa: PLR0915 — one flat list of watched properties
    """Every claim above, watched. Printed counts, not assertions."""
    import subprocess

    bad = 0

    def check(label, ok):
        nonlocal bad
        print(f"kaya_gate: {label}: {'OK' if ok else 'FAILED'}")
        if not ok:
            bad += 1

    # F1. THE FINGERPRINT IS THE SHELL'S. Not "a sha over the two files"
    # — the real pipeline, run, and compared. A python hash that agreed
    # with itself and not with the 81 shell preambles would lock everyone
    # out of every converted gate at once.
    shell = subprocess.run(
        ["sh", "-c", "cat flake.nix flake.lock | shasum -a 256 | cut -c1-12"],
        cwd=ROOT, stdout=subprocess.PIPE, text=True, check=False,
    ).stdout.strip()
    mine = flake_fingerprint()
    print(f"kaya_gate: shell pipeline {shell!r} vs prelude {mine!r}")
    check("F1 fingerprint matches the shell preamble's", shell == mine)
    # And against what the dev shell actually exported, when there is one.
    live = os.environ.get("KAYA_DEV_SHELL", "")
    if live:
        print(f"kaya_gate: live KAYA_DEV_SHELL {live!r}")
        check("F1b fingerprint matches the shell that is running", live == mine)

    # F2. TWO CAUSES, TWO SENTENCES — the defect the research found in
    # tools/win/undoarmprobe/run.sh. Both branches MADE TO PRINT.
    unset = dev_shell_refusal("", mine, "tools/x.sh")
    stale = dev_shell_refusal("deadbeefcafe", mine, "tools/x.sh")
    good = dev_shell_refusal(mine, mine, "tools/x.sh")
    print(f"kaya_gate: unset -> {unset}")
    print(f"kaya_gate: stale -> {stale}")
    print(f"kaya_gate: correct -> {good!r}")
    check("F2 an unset shell is refused", unset is not None)
    check("F2 a stale shell is refused", stale is not None)
    check("F2 the two causes get DIFFERENT sentences", unset != stale)
    check("F2 'not inside' names only the unset cause", "not inside" in unset
          and "not inside" not in stale)
    check("F2 'stale' names only the stale cause", "stale" in stale
          and "stale" not in unset)
    check("F2 a correct shell is not refused", good is None)

    # F3. THE PERTURBATION COUNT IS LOAD-BEARING. A doctor() that applied
    # nothing must exit, not return an unchanged string.
    g = Gate("selftest")
    got = g.doctor("F3 applied", "alpha beta", r"beta", "gamma")
    check("F3 a matching perturbation returns the doctored text",
          got == "alpha gamma")
    child = subprocess.run(
        [sys.executable, "-c",
         "import pathlib, sys; sys.path.insert(0, "
         f"{str(pathlib.Path(__file__).resolve().parent)!r}); "
         "from kaya_gate import Gate; "
         "Gate('probe').doctor('F3 unmatched', 'alpha', 'zeta', 'x')"],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, check=False,
    )
    print(f"kaya_gate: F3 unmatched-perturbation child rc={child.returncode}")
    check("F3 a perturbation that applied NOTHING is a broken self-test",
          child.returncode != 0 and "SELF-TEST BROKEN" in child.stderr)
    check("F3 the broken-self-test sentence says how many it wanted",
          "wanted exactly 1" in child.stderr)

    # F4. THE CENSUS FLOOR REFUSES. A count below the floor is a refusal,
    # not a finding — the gate has no opinion, which is a different thing
    # from a clean one.
    g2 = Gate("selftest")
    try:
        g2.counted("things", [1, 2], floor=10)
        refused = False
    except Refusal:
        refused = True
    check("F4 a census below its floor REFUSES", refused)
    g3 = Gate("selftest")
    g3.counted("things", list(range(20)), floor=10)
    check("F4 a census above its floor does not", g3.status == 0)

    # F5. A NEGATIVE THAT DID NOT GO RED IS A FAILURE, and one that did
    # is not.
    g4 = Gate("selftest")
    g4.negative("F5 a census that accepted the defect", lambda: [], want="boom")
    check("F5 an unrefused negative sets the status", g4.status == 1)
    g5 = Gate("selftest")
    g5.negative("F5 a census that caught it", lambda: ["boom here"], want="boom")
    check("F5 a refused negative leaves the status clean", g5.status == 0)
    g5.negatives_ran(1)
    check("F5 the negative count is what actually ran", g5._negatives == 1)
    g6 = Gate("selftest")
    try:
        g6.negatives_ran(3)
        counted_wrong = False
    except Refusal:
        counted_wrong = True
    check("F5 declaring more negatives than ran REFUSES", counted_wrong)

    # F6. SCRATCH IS EXIT-SAFE — including when the process dies of an
    # exception, which is what the shell's `trap ... EXIT` bought and what
    # a `finally` in the happy path does not.
    probe = subprocess.run(
        [sys.executable, "-c",
         "import pathlib, sys; sys.path.insert(0, "
         f"{str(pathlib.Path(__file__).resolve().parent)!r}); "
         "from kaya_gate import Gate; g = Gate('probe'); d = g.scratch(); "
         "print(d); raise RuntimeError('die')"],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, check=False,
    )
    left = probe.stdout.strip()
    print(f"kaya_gate: F6 child died with rc={probe.returncode}, "
          f"its scratch was {left}")
    check("F6 a scratch dir does not survive an exception",
          bool(left) and not pathlib.Path(left).exists())

    # F7. read() names an encoding. Proven by BYTES, not by reading the
    # source: a non-UTF-8 locale must not change what a gate reads.
    g7 = Gate("selftest")
    sample = g7.scratch() / "u.txt"
    sample.write_text("café — ünïcode\n", encoding="utf-8")
    env = dict(os.environ, LC_ALL="C", LANG="C")
    probe = subprocess.run(
        [sys.executable, "-c",
         "import pathlib, sys; sys.path.insert(0, "
         f"{str(pathlib.Path(__file__).resolve().parent)!r}); "
         "from kaya_gate import Gate; "
         f"print(len(Gate('probe').read({str(sample)!r})))"],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
        env=env, check=False,
    )
    print(f"kaya_gate: F7 under LC_ALL=C the file read as "
          f"{probe.stdout.strip()!r} chars (want 15), rc={probe.returncode}")
    check("F7 read() is UTF-8 whatever the locale says",
          probe.stdout.strip() == "15")

    # F8. walk() prunes. tools/ holds 323k entries and ~213 tracked files;
    # a walk that descended into target/ would cost seconds per gate.
    g8 = Gate("selftest")
    scripts = g8.walk("*.py", under="tools")
    print(f"kaya_gate: F8 walk found {len(scripts)} tools/**/*.py")
    check("F8 walk finds the tools scripts", len(scripts) > 50)
    check("F8 walk prunes build directories",
          not any("target" in p.parts for p in scripts))

    # F9. AN UNCAUGHT REFUSAL IS THE SENTENCE ALONE: rc 1, the REFUSAL
    # line, and no traceback after it — refuse() said everything there
    # is to say, and a traceback after a correct refusal reads as a
    # crash (audit 2026-08-31).
    probe = subprocess.run(
        [sys.executable, "-c",
         "import pathlib, sys; sys.path.insert(0, "
         f"{str(pathlib.Path(__file__).resolve().parent)!r}); "
         "from kaya_gate import Gate; Gate('probe').refuse('no data')"],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, check=False,
    )
    print(f"kaya_gate: F9 uncaught refusal rc={probe.returncode}, "
          f"stderr={probe.stderr.strip()!r}")
    check("F9 an uncaught refusal exits 1 with its sentence",
          probe.returncode == 1 and "probe: REFUSAL — no data" in probe.stderr)
    check("F9 no traceback follows the refusal sentence",
          "Traceback" not in probe.stderr)

    # F10. TWO PERTURBATIONS OF ONE SOURCE ARE TWO FILES: a shared name
    # means a deferred negative reads the LAST doctored copy and goes
    # green for the wrong reason (audit 2026-08-31).
    g10 = Gate("selftest")
    sample10 = g10.scratch() / "p.txt"
    sample10.write_text("alpha beta\n", encoding="utf-8")
    p1 = g10.perturb("F10 first", sample10, "alpha", "ALPHA")
    p2 = g10.perturb("F10 second", sample10, "beta", "BETA")
    check("F10 two perturbations of one source are two files", p1 != p2)
    check("F10 each copy carries its own doctoring",
          "ALPHA" in p1.read_text(encoding="utf-8")
          and "BETA" in p2.read_text(encoding="utf-8")
          and "BETA" not in p1.read_text(encoding="utf-8"))

    print(f"kaya_gate: SELF-TEST {'OK' if not bad else f'FAILED ({bad})'}")
    return bad == 0


if __name__ == "__main__":
    if sys.argv[1:] != ["--selftest"]:
        raise SystemExit("usage: kaya_gate.py --selftest")
    raise SystemExit(0 if _selftest() else 1)
