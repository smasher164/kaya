"""A secure field's text reaches no transcript (docs/secure-entry-plan.md P6).

A leg's script names every `type_secret` argument, so after the leg the
runner reads its transcripts for each one. An argument too weak to scan for
(it could occur in a log by accident) is refused before the leg counts.
"""

import re

STATEMENT = re.compile(r'(?:^|;)[ \t]*type_secret[ \t]+"((?:[^"\\]|\\.)*)"', re.M)
MIN_CHARS = 6


def _unescape(inner):
    return inner.replace("\\\\", "\0").replace("\\n", "\n").replace("\\r", "\r").replace("\0", "\\")


def secrets_in(script):
    """Every type_secret argument in a script, unescaped, in order."""
    return [_unescape(m.group(1)) for m in STATEMENT.finditer(script or "")]


CLASSES = (("an upper-case letter", r"[A-Z]"), ("a lower-case letter", r"[a-z]"),
           ("a digit", r"[0-9]"))


def weakness(secret):
    """What an argument lacks for a scan to find it by itself: its length
    when short, and each missing character class. Empty when strong."""
    out = []
    if len(secret) < MIN_CHARS:
        out.append(f"{len(secret)} characters, under {MIN_CHARS}")
    out += [f"no {name}" for name, pattern in CLASSES if not re.search(pattern, secret)]
    return out


def refusals(script, transcripts):
    """Sentences refusing the leg: a weak argument, or an argument found in
    one of `transcripts` ({name: text}). Each names the argument by its
    position and length alone."""
    out = []
    for n, secret in enumerate(secrets_in(script), 1):
        weak = weakness(secret)
        if weak:
            out.append(f"secure-scan: type_secret #{n} is too weak to scan for: "
                       f"{', '.join(weak)} (docs/secure-entry-plan.md P6)")
            continue
        for name, text in transcripts.items():
            if text and secret in text:
                out.append(f"secure-scan: the leg's {name} carries type_secret #{n} "
                           f"({len(secret)} characters) — a secure field's text "
                           f"reached a transcript (docs/secure-entry-plan.md P6)")
    return out
