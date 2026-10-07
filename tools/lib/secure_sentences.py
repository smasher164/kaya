"""docs/secure-entry-plan.md P6: the secure field's refusals and the masked
read's sentences are one set of bytes in the three harnesses, and each
interpreter's step loop takes a type_secret's text out of the statement
before it logs it."""

import re

from kaya_gate import ROOT

HARNESS = "crates/kaya/src/harness.rs"
SWIFT = "swift/KayaSwiftUI.swift"
COMPOSE = "android/kaya/src/main/kotlin/dev/kaya/KayaCompose.kt"

# name: (harness.rs constant, Swift let, Kotlin const)
SENTENCES = {
    "expect refusal": ("SECURE_EXPECT", "kayaSecureExpect", "KAYA_SECURE_EXPECT"),
    "set_text refusal": ("SECURE_SET_TEXT", "kayaSecureSetText", "KAYA_SECURE_SET_TEXT"),
    "type refusal": ("TYPE_INTO_SECURE", "kayaTypeIntoSecure", "KAYA_TYPE_INTO_SECURE"),
    "focus refusal": ("TYPE_SECRET_ELSEWHERE", "kayaTypeSecretElsewhere",
                      "KAYA_TYPE_SECRET_ELSEWHERE"),
    "ASCII refusal": ("TYPE_SECRET_ASCII", "kayaTypeSecretAscii", "KAYA_TYPE_SECRET_ASCII"),
}
UNMASKED = "the platform presents {n} of the secure field's characters unmasked"
UNMASKED_SPELLED = {HARNESS: "the platform presents {n} of the secure field's characters unmasked",
                    SWIFT: "the platform presents \\(unmasked) of the secure field's characters unmasked",
                    COMPOSE: "the platform presents $unmasked of the secure field's characters unmasked"}
SECRET_OUT = {SWIFT: ("let (line, secret) = kayaSecretOut(", 'print("KAYA_HARNESS: +'),
              COMPOSE: ("val (line, secret) = kayaSecretOut(", 'Log.i("kaya", "KAYA_HARNESS: +${offset}ms $line")')}


def value(source, rel, name):
    pattern = {HARNESS: r"pub const " + name + r': &str =\s*"((?:[^"\\]|\\.)*)";',
               SWIFT: r"let " + name + r' =\s*"((?:[^"\\]|\\.)*)"',
               COMPOSE: r"internal const val " + name + r' =\s*"((?:[^"\\]|\\.)*)"'}[rel]
    found = re.findall(pattern, source)
    return found[0] if len(found) == 1 else None


def findings(sources):
    out = []
    for label, names in SENTENCES.items():
        seen = {}
        for rel, name in zip((HARNESS, SWIFT, COMPOSE), names):
            got = value(sources[rel], rel, name)
            if got is None:
                out.append(f"secure sentences: {rel} has no single {name} — the {label} "
                           f"must be spelled once per harness")
            else:
                seen[rel] = got
        if len(set(seen.values())) > 1:
            out.append(f"secure sentences: the {label} differs across the harnesses: "
                       + "; ".join(f"{rel}: {text!r}" for rel, text in seen.items()))
    for rel, spelled in UNMASKED_SPELLED.items():
        if spelled not in sources[rel]:
            out.append(f"secure sentences: {rel} no longer says {UNMASKED!r} for a mask that "
                       f"shows typed characters")
    for rel, (take, log) in SECRET_OUT.items():
        at, logged = sources[rel].find(take), sources[rel].find(log)
        if at < 0 or logged < 0 or logged < at:
            out.append(f"secure sentences: {rel}'s step loop logs a statement before "
                       f"kayaSecretOut has taken a type_secret's text out of it")
    return out


def run(g):
    sources = {rel: (ROOT / rel).read_text(encoding="utf-8") for rel in (HARNESS, SWIFT, COMPOSE)}
    g.counted("secure sentences held in 3 harnesses", len(SENTENCES) + 1, floor=6)
    for line in findings(sources):
        g.finding(line)
    for rel, names in ((SWIFT, SENTENCES["focus refusal"]), (COMPOSE, SENTENCES["focus refusal"])):
        own = names[1] if rel == SWIFT else names[2]
        broken = g.doctor(f"secure {own} reworded in {rel}", sources[rel],
                          re.escape("and the focus is not on one"), "and the focus is elsewhere")
        g.negative(f"secure focus refusal reworded in {rel}",
                   lambda rel=rel, broken=broken: findings({**sources, rel: broken}),
                   want="the focus refusal differs")
    broken = g.doctor("secure Kotlin step loop taking the secret after the log", sources[COMPOSE],
                      re.escape("val (line, secret) = kayaSecretOut(raw.trim())"),
                      "val (line, secret) = Pair(raw.trim(), null as KayaSecret?)")
    g.negative("secure Kotlin step loop logging the raw statement",
               lambda: findings({**sources, COMPOSE: broken}), want="logs a statement before")
