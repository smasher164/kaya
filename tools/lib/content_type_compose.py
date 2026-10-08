"""docs/autofill-plan.md §3, A5, A6: the Compose arm's half of
content_type_routes.py. The table's rows pinned to Compose's ContentType
constants, its numbers to kaya.h, the keyboard each word asks for, the hint
worn by both fields, and the read held to the semantics node's own
ContentType with no route to kaya's model."""

import re

COMPOSE = "android/kaya/src/main/kotlin/dev/kaya/KayaCompose.kt"
HEADER = "crates/kaya/include/kaya.h"

ROWS = [
    'KayaContentRow(CONTENT_TYPE_USERNAME, ContentType.Username, "username")',
    'KayaContentRow(CONTENT_TYPE_PASSWORD, ContentType.Password, "password")',
    'KayaContentRow(CONTENT_TYPE_NEW_PASSWORD, ContentType.NewPassword, "password")',
    'KayaContentRow(CONTENT_TYPE_ONE_TIME_CODE, ContentType.SmsOtpCode, "one_time_code")',
    'KayaContentRow(CONTENT_TYPE_EMAIL, ContentType.EmailAddress, "email")',
    'KayaContentRow(CONTENT_TYPE_PHONE, ContentType.PhoneNumber, "phone")',
]
KEYBOARD = [
    "CONTENT_TYPE_EMAIL -> KeyboardType.Email",
    "CONTENT_TYPE_PHONE -> KeyboardType.Phone",
    "CONTENT_TYPE_ONE_TIME_CODE -> if (secure) KeyboardType.NumberPassword else KeyboardType.Number",
    "else -> if (secure) KeyboardType.Password else KeyboardType.Unspecified",
    "val plain = secure || word == CONTENT_TYPE_USERNAME || word == CONTENT_TYPE_EMAIL ||"
    " word == CONTENT_TYPE_ONE_TIME_CODE",
    "capitalization = KeyboardCapitalization.None, autoCorrectEnabled = false,",
]
WEARS = {
    "private fun KayaSecureField(": [".then(kayaContentHint(node.id, node.contentType))",
                                     "keyboardOptions = kayaContentKeyboard(node.contentType, secure = true)"],
    "fun KayaTextField(": [".then(if (singleLine && !search) kayaContentHint(node.id, node.contentType) else Modifier)",
                           "kayaContentKeyboard(node.contentType, secure = false)"],
}
APPLY = "PROP_CONTENT_TYPE -> KayaSceneModel.nodes[id]!!.contentType = readI64(b)"
SENTENCES = {
    "answer set": (r'pub const CONTENT_READS: \[&str; 6\] = \[([^\]]*)\];',
                   r'internal val KAYA_CONTENT_READS = listOf\(([^)]*)\)'),
    "wants refusal": (r'pub const CONTENT_READS_WANTS: &str =\s*"([^"]*)";',
                      r'internal const val KAYA_CONTENT_READS_WANTS =\s*"([^"]*)"'),
    "new_password refusal": (r'pub const CONTENT_READS_NEW_PASSWORD: &str =\s*"([^"]*)";',
                             r'internal const val KAYA_CONTENT_READS_NEW_PASSWORD =\s*"([^"]*)"'),
}


def flat(text):
    return re.sub(r"\s+", "", text)


def balanced(text, opener, open_ch="{", close_ch="}"):
    at = text.find(opener)
    if at < 0:
        return None
    start = text.find(open_ch, at + len(opener) - 1)
    depth = 0
    for i in range(start, len(text)):
        if text[i] == open_ch:
            depth += 1
        elif text[i] == close_ch:
            depth -= 1
            if depth == 0:
                return text[start:i + 1]
    return None


def compose_findings(sources, harness):
    code, header = sources[COMPOSE], sources[HEADER]
    out = []
    table = balanced(code, "internal fun kayaContentTypes(): List<KayaContentRow> = listOf(", "(", ")")
    if table is None:
        return ["content type: KayaCompose.kt has no kayaContentTypes() table"]
    for row in ROWS:
        if flat(row) not in flat(table):
            out.append(f"content type: the Compose arm's kayaContentTypes() lacks the row {row}")
    extra = len(re.findall(r"KayaContentRow\(", table)) - len(ROWS)
    if extra:
        out.append(f"content type: the Compose arm's kayaContentTypes() has {extra} row(s) "
                   f"beyond the pinned {len(ROWS)}")
    defines = dict(re.findall(r"#define KAYA_(CONTENT_TYPE_\w+) (\d+)", header))
    copies = re.findall(r"internal const val (CONTENT_TYPE_\w+) = (\d+)L", code)
    if len(copies) != 6:
        out.append(f"content type: KayaCompose.kt copies {len(copies)} CONTENT_TYPE_* numbers, wanted 6")
    for name, value in copies:
        if defines.get(name) != value:
            out.append(f"content type: KayaCompose.kt {name} = {value}, kaya.h KAYA_{name} = "
                       f"{defines.get(name)}")
    keyboard = balanced(code, "internal fun kayaContentKeyboard(") or ""
    for clause in KEYBOARD:
        if flat(clause) not in flat(keyboard):
            out.append(f"content type: the Compose keyboard does not hold {clause}")
    hint = balanced(code, "internal fun kayaContentHint(") or ""
    if "kayaContentTypes()" not in hint or "contentType = platform" not in hint \
            or "this[KayaNodeId] = id" not in hint:
        out.append("content type: kayaContentHint does not set the semantics contentType from "
                   "kayaContentTypes() beside the node's KayaNodeId")
    for opener, clauses in WEARS.items():
        body = balanced(code, opener) or ""
        for clause in clauses:
            if flat(clause) not in flat(body):
                out.append(f"content type: {opener.split()[-1].rstrip('(')} does not wear {clause}")
    if flat(APPLY) not in flat(code):
        out.append("content type: the Compose apply arm does not keep the word on the node")
    read = balanced(code, "private fun kayaContentTypeRead(") or ""
    for need in ("SemanticsProperties.ContentType", "kayaContentTypes()", "KayaNodeId"):
        if need not in read:
            out.append(f"content type: the Compose read does not read {need}")
    if re.search(r"KayaSceneModel|\.contentType\b|\.word\b|\bnode\b", read):
        out.append("content type: the Compose read reaches kaya's word or model, so it could "
                   "echo the word instead of reading the platform")
    for label, (rust_pattern, kotlin_pattern) in SENTENCES.items():
        a, b = re.findall(rust_pattern, harness), re.findall(kotlin_pattern, code)
        if len(a) != 1 or len(b) != 1:
            out.append(f"content type: the {label} is not spelled once in harness.rs and Compose")
        elif flat(a[0]) != flat(b[0]):
            out.append(f"content type: the {label} differs: harness.rs {a[0]!r}, Compose {b[0]!r}")
    return out


CUTS = [
    ("Compose's email row applied as a phone",
     r'ContentType\.EmailAddress, "email"\)', 'ContentType.PhoneNumber, "email")', "lacks the row"),
    ("Compose's new_password applied as password",
     r'ContentType\.NewPassword, "password"\)', 'ContentType.Password, "password")', "lacks the row"),
    ("Compose's code keyboard as text",
     r"KeyboardType\.NumberPassword else KeyboardType\.Number\n",
     "KeyboardType.NumberPassword else KeyboardType.Text\n", "keyboard does not hold"),
    ("Compose's secure field without its hint",
     r"\n            \.then\(kayaContentHint\(node\.id, node\.contentType\)\)\n", "\n",
     "KayaSecureField does not wear"),
    ("Compose's read echoing the model",
     r"\?: return@onUi Pair\(\"none\", \"\"\)\n",
     '?: return@onUi Pair(KayaSceneModel.nodes[id]?.let { "none" } ?: "none", "")\n',
     "reaches kaya's word or model"),
    ("Compose's drifted number", r"(internal const val CONTENT_TYPE_EMAIL = )5L", r"\g<1>6L",
     "kaya.h KAYA_CONTENT_TYPE_EMAIL"),
    ("Compose's new_password refusal reworded",
     r"and a new_password field reads as password\"\n",
     'and new_password reads as password"\n', "new_password refusal differs"),
]
