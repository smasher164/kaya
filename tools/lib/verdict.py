"""Whether a transcript carries a harness's real verdict.

The one reader every runner asks: a bare `"KAYA_SELFTEST: OK" in out` also
matches a sentence that QUOTES the token (docs/traps.md, the verdict a
refusal quoted). tools/check-flightrec.py's VR clauses refuse any other
reader.
"""
import re

# Not after a quote, and followed by " (" or the end of the line. A lane
# prefix ("I kaya    : ", "ACT2: ", "kaya said: ") and an unterminated
# stderr line before it (windows, "...STALLED ... 1KAYA_SELFTEST: OK (")
# both stay green. run-suites.sh's grep -E is the same rule.
_GREEN = re.compile(r"""(?<!['"`])KAYA_SELFTEST: OK(?= \(|\r?$)""", re.M)
_RED = re.compile(r"""(?<!['"`])KAYA_SELFTEST: FAILED(?= \(|\r?$)""", re.M)


def green(text):
    """True when some line of `text` is a published green verdict."""
    return bool(text) and _GREEN.search(text) is not None


def red(text):
    """True when some line of `text` is a published failed verdict."""
    return bool(text) and _RED.search(text) is not None
