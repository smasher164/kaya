"""A gate's declared inputs must cover the files it actually reads.

tools/keyed.sh skips a gate whose declared input set has not moved since
it last passed, so an input a gate READS but does not DECLARE is a
false-PASS generator — and it fires exactly when the undeclared file is
the thing that changed. So: scan each gate's script for repo paths it
names IN CODE, and require each to be covered by that gate's declared
set.

CODE, NOT PROSE. Counting every mention reports comments citing CLAUDE.md
or docs/traps.md for the reasoning behind a rule, with no true positives
at all, so comments and docstrings are stripped first. That gives up a
path constructed at runtime, which is the honest limit of reading a
script instead of running it.
"""

import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]

# Every gate gets tools/ and the flake implicitly (see build-id.sh's
# gate_key), so a script naming its own siblings is always covered.
IMPLICIT = ("tools/", "flake.nix", "flake.lock")

# A repo path, as it appears in a script: a source file, or a directory
# that is one of the declarable roots.
PATH = re.compile(r"[A-Za-z0-9_][A-Za-z0-9_./-]*\.[A-Za-z0-9_]+")


def _table(name: str) -> dict[str, list[str]]:
    text = (ROOT / "tools" / "build-id.sh").read_text()
    marker = name + " = {"
    body = text[text.index(marker) : text.index("\n}", text.index(marker))]
    ns: dict = {}
    exec(name + " = {" + body[len(marker) :] + "\n}", ns)  # noqa: S102
    return ns[name]


def gates() -> dict[str, list[str]]:
    """The GATES table with each gate's ARTIFACT_GATES paths folded in
    as declared inputs — an artifact in the key is a declared read,
    read from build-id.sh rather than duplicated."""
    table = _table("GATES")
    for gate, artifacts in _table("ARTIFACT_GATES").items():
        if gate in table:
            table[gate] = table[gate] + artifacts
    return table


def code_only(source: pathlib.Path) -> str:
    """The script with comments and docstrings removed.

    A docstring is prose in a string literal, and `ast` is what tells one
    apart from a path a call actually uses.
    """
    text = source.read_text()
    if source.suffix == ".py":
        import ast

        try:
            tree = ast.parse(text)
        except SyntaxError:
            tree = None
        if tree is not None:
            spans = []
            for node in ast.walk(tree):
                # Only the statement-list `body` of a module/class/def
                # can open with a docstring; an IfExp also has a `body`
                # and it is a bare expression.
                doc = getattr(node, "body", None)
                if not isinstance(doc, list) or not doc:
                    continue
                if not isinstance(doc[0], ast.Expr):
                    continue
                first = doc[0].value
                if isinstance(first, ast.Constant) and isinstance(first.value, str):
                    spans.append((first.lineno, first.end_lineno))
            lines = text.splitlines()
            for start, end in spans:
                for n in range(start - 1, min(end, len(lines))):
                    lines[n] = ""
            text = "\n".join(lines)
    text = "\n".join(
        line for line in text.splitlines() if not line.lstrip().startswith("#")
    )
    # A quoted string with a SPACE in it is a message, not a path: a path
    # in a read position is a bare word or a quoted string of just the
    # path, and neither has a space.
    return re.sub(r"\"[^\"\n]* [^\"\n]*\"|'[^'\n]* [^'\n]*'", '""', text)


def mentioned(script: pathlib.Path) -> set[str]:
    """Repo-relative paths this script names in code, that really exist."""
    out = set()
    for hit in PATH.findall(code_only(script)):
        hit = hit.strip("/")
        if (ROOT / hit).exists():
            out.add(hit)
    return out


def covered(path: str, declared: list[str]) -> bool:
    for root in tuple(declared) + IMPLICIT:
        root = root.rstrip("/")
        if path == root or path.startswith(root + "/"):
            return True
    return False


def helpers(script: pathlib.Path) -> list[pathlib.Path]:
    """tools/lib/*.py a gate shells out to are part of the gate."""
    return [
        ROOT / hit
        for hit in re.findall(r"tools/lib/[\w.-]+\.py", code_only(script))
        if (ROOT / hit).exists()
    ]


def main() -> int:
    table = gates()
    status = 0
    checked = 0
    for gate, declared in table.items():
        script = ROOT / "tools" / f"{gate}.sh"
        if not script.exists():
            continue
        checked += 1
        sources = [script] + helpers(script)
        for source in sources:
            for path in sorted(mentioned(source)):
                if covered(path, declared):
                    continue
                where = source.relative_to(ROOT)
                print(
                    f"keyed-inputs: {gate} names {path} in {where} but does not "
                    f"declare it — build-id.sh GATES[{gate!r}] = {declared}. "
                    f"Under KAYA_FAST a change there would hand back a stale PASS.",
                    file=sys.stderr,
                )
                status = 1

    if checked < 10:
        print(
            f"keyed-inputs: only {checked} gate scripts found — the GATES "
            f"table or the tools/ layout moved and this went vacuous",
            file=sys.stderr,
        )
        return 1

    # The gate guards itself: an undeclared path must not read as covered.
    if covered("crates/kaya/src/gtk.rs", ["guests"]):
        print("keyed-inputs: SELF-TEST FAIL (undeclared path read as covered)", file=sys.stderr)
        return 1
    if not covered("crates/kaya/src/gtk.rs", ["crates"]):
        print("keyed-inputs: SELF-TEST FAIL (declared path read as uncovered)", file=sys.stderr)
        return 1
    return status


if __name__ == "__main__":
    sys.exit(main())
