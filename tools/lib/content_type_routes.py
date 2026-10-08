"""docs/autofill-plan.md A4, A6: the content type is applied and read through
ONE table per backend, and the read is the platform's own property.

No scene can see a SWAPPED row: a backend that applied `.password` for
`new_password`, or `.telephoneNumber` for `email` and read it back through the
same swapped table, passes autofill.steps byte for byte. So the rows are pinned
here against the platforms' documented constants, the apply and the read are
held to the one table, the read to the platform's property with no route to
kaya's model, and the harness's answer set to one spelling in both harnesses.
A backend whose `depth_stub("autofill")` goes must take a row in BACKENDS."""

import re

from kaya_gate import ROOT

HARNESS = "crates/kaya/src/harness.rs"
SWIFT = "swift/KayaSwiftUI.swift"
STUBBED = {
    "crates/kaya/src/gtk.rs": 'depth_stub("autofill")',
    "crates/kaya/src/winui/mod.rs": 'depth_stub("autofill")',
    "android/kaya/src/main/kotlin/dev/kaya/KayaCompose.kt": 'depthStub("autofill")',
}
# Each backend's built arm: the file and the clauses it owes. SwiftUI serves
# macOS and iOS from one file, so its rows are demanded in each half.
BACKENDS = {SWIFT: "the SwiftUI arm"}

# (kaya constant, platform constant, the class the harness reads)
ROWS = [
    ("KAYA_CONTENT_TYPE_USERNAME", ".username", "username"),
    ("KAYA_CONTENT_TYPE_PASSWORD", ".password", "password"),
    ("KAYA_CONTENT_TYPE_NEW_PASSWORD", ".newPassword", "password"),
    ("KAYA_CONTENT_TYPE_ONE_TIME_CODE", ".oneTimeCode", "one_time_code"),
    ("KAYA_CONTENT_TYPE_EMAIL", ".emailAddress", "email"),
    ("KAYA_CONTENT_TYPE_PHONE", ".telephoneNumber", "phone"),
]
SENTENCES = {
    "answer set": (r'pub const CONTENT_READS: \[&str; 6\] = \[([^\]]*)\];',
                   r'let kayaContentReads = \[([^\]]*)\]'),
    "wants refusal": (r'pub const CONTENT_READS_WANTS: &str =\s*"([^"]*)";',
                      r'let kayaContentReadsWants =\s*"([^"]*)"'),
    "new_password refusal": (r'pub const CONTENT_READS_NEW_PASSWORD: &str =\s*"([^"]*)";',
                             r'let kayaContentReadsNewPassword =\s*"([^"]*)"'),
}


def block(text, opener):
    """The brace-balanced body after `opener`, or None."""
    at = text.find(opener)
    if at < 0:
        return None
    start = text.find("{", at)
    depth = 0
    for i in range(start, len(text)):
        if text[i] == "{":
            depth += 1
        elif text[i] == "}":
            depth -= 1
            if depth == 0:
                return text[start:i + 1]
    return None


def halves(body):
    """The table body's macOS and iOS halves, split at its own #else."""
    m = re.search(r"#if os\(macOS\)(.*?)#else(.*?)#endif", body, re.S)
    return (m.group(1), m.group(2)) if m else (None, None)


def row_present(half, row):
    const, platform, reads = row
    return re.search(rf"\(\s*{const}\s*,\s*{re.escape(platform)}\s*,\s*\"{reads}\"\s*\)", half)


def findings(sources):
    out = []
    swift, harness = sources[SWIFT], sources[HARNESS]
    table = block(swift, "func kayaContentTypes()")
    if table is None:
        return ["content type: KayaSwiftUI.swift has no kayaContentTypes() table"]
    mac, ios = halves(table)
    if mac is None:
        out.append("content type: kayaContentTypes() is not split into a macOS and an iOS half")
    else:
        for name, half in (("macOS", mac), ("iOS", ios)):
            for row in ROWS:
                if not row_present(half, row):
                    out.append(f"content type: the {name} half of kayaContentTypes() lacks the row "
                               f"{row[0]} -> {row[1]} read as {row[2]}")
            extra = len(re.findall(r"\(\s*KAYA_CONTENT_TYPE_", half)) - len(ROWS)
            if extra:
                out.append(f"content type: the {name} half of kayaContentTypes() has {extra} row(s) "
                           f"beyond the pinned {len(ROWS)}")
    hint = block(swift, "struct KayaContentHint: ViewModifier")
    if hint is None or "kayaContentTypes()" not in hint:
        out.append("content type: KayaContentHint does not take its constant from kayaContentTypes()")
    elif len(re.findall(r"\.textContentType\(platform\)", hint)) != 2:
        out.append("content type: KayaContentHint does not apply .textContentType(platform) "
                   "on both macOS and iOS")
    for view in ("struct KayaEntry: View", "struct KayaSecureField: View"):
        body = block(swift, view)
        if body is None or ".modifier(KayaContentHint(word: node.contentType))" not in body:
            out.append(f"content type: {view.split()[1].rstrip(":")} does not wear KayaContentHint")
    read = block(swift, "func kayaContentRead(")
    if read is None or "kayaContentTypes()" not in read:
        out.append("content type: kayaContentRead does not map back through kayaContentTypes()")
    reads = [m.start() for m in re.finditer(r"private func kayaContentTypeRead\(", swift)]
    if len(reads) != 2:
        out.append(f"content type: {len(reads)} kayaContentTypeRead bodies, wanted the macOS and "
                   f"the iOS one")
    for at, prop in zip(reads, (r"\.contentType\?\.rawValue", r"\.textContentType\?\.rawValue")):
        body = block(swift[at:], "private func kayaContentTypeRead(") or ""
        if not re.search(r"kayaContentRead\(\w+(\[0\])?" + prop, body):
            out.append(f"content type: a kayaContentTypeRead does not read the platform's own "
                       f"{prop.replace(chr(92), '')}")
        if re.search(r"\bkayaScene\b|\bnode\b", body):
            out.append("content type: a kayaContentTypeRead reaches kaya's model, so it could "
                       "echo the word instead of reading the platform")
    for label, (rust_pattern, swift_pattern) in SENTENCES.items():
        a, b = re.findall(rust_pattern, harness), re.findall(swift_pattern, swift)
        if len(a) != 1 or len(b) != 1:
            out.append(f"content type: the {label} is not spelled once in each harness")
        elif re.sub(r"\s+", "", a[0]) != re.sub(r"\s+", "", b[0]):
            out.append(f"content type: the {label} differs: harness.rs {a[0]!r}, SwiftUI {b[0]!r}")
    for rel, stub in STUBBED.items():
        if stub not in sources[rel] and rel not in BACKENDS:
            out.append(f"content type: {rel} no longer calls {stub} and has no row in "
                       f"tools/lib/content_type_routes.py's BACKENDS")
    return out


def run(g):
    rels = [HARNESS, SWIFT, *STUBBED]
    sources = {rel: (ROOT / rel).read_text(encoding="utf-8") for rel in rels}
    still = [rel for rel, stub in STUBBED.items() if stub in sources[rel]]
    g.counted("content type rows pinned per Apple half", len(ROWS), floor=6)
    g.counted("content type backends still stubbed", len(still), floor=0)
    for line in findings(sources):
        g.finding(line)
    cuts = [
        ("a swapped iOS row", SWIFT, r"\n            \(KAYA_CONTENT_TYPE_EMAIL, \.emailAddress, \"email\"\)",
         '\n            (KAYA_CONTENT_TYPE_EMAIL, .telephoneNumber, "email")', "lacks the row"),
        ("new_password applied as password on the mac", SWIFT,
         r"\(KAYA_CONTENT_TYPE_NEW_PASSWORD, \.newPassword, \"password\"\),\n                \(KAYA_CONTENT_TYPE_EMAIL",
         '(KAYA_CONTENT_TYPE_NEW_PASSWORD, .password, "password"),\n                (KAYA_CONTENT_TYPE_EMAIL',
         "lacks the row"),
        ("the mac hint applied nowhere", SWIFT, r"            content\.textContentType\(platform\)\n",
         "            content\n", "on both macOS and iOS"),
        ("the secure field without its hint", SWIFT,
         r"(\? \.infinity : 200\)\n)        \.modifier\(KayaContentHint\(word: node\.contentType\)\)\n(        \.focused\(\$focused\)\n        #if os\(iOS\))",
         r"\1\2",
         "KayaSecureField does not wear"),
        ("the mac read echoing the model", SWIFT,
         r"return kayaContentRead\(fields\[0\]\.contentType\?\.rawValue\)",
         "return kayaContentRead(kayaContentTypes().first { Int64($0.word) == kayaScene.focusedId.map { _ in 0 } ?? 0 }?.platform.rawValue)",
         "does not read the platform's own"),
        ("the new_password refusal reworded in Swift", SWIFT, r"and a new_password field reads as password\"",
         'and new_password reads as password"', "new_password refusal differs"),
        ("GTK's stub gone with no row", "crates/kaya/src/gtk.rs",
         r'crate::depth_stub\("autofill"\)', 'crate::depth_stub("autofil")', "no longer calls"),
    ]
    for label, rel, pattern, repl, want in cuts:
        want_n = 2 if rel.endswith("gtk.rs") else 1
        broken = g.doctor(f"content type: {label}", sources[rel], pattern, repl, want=want_n)
        g.negative(f"content type: {label}",
                   lambda rel=rel, broken=broken: findings({**sources, rel: broken}), want=want)
