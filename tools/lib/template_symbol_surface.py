"""docs/media-player-plan.md M16 (21), (29); called by check-sugar-surface.

Each row is one binding's template-zone symbol, read out of that binding's own
file: a constant on a stamped button, the Symbol type as a record field, and
the setter that binds a stamped copy's symbol to a row's field. The OCaml
binding keeps the vocabulary as a list too (`all_symbols`, which
`symbol_of_packed` searches), held here to its type's constructors."""

import re

from kaya_gate import ROOT, Gate

RS = "crates/kaya/src/app.rs"
PY = "bindings/python/kaya/__init__.py"
JS = "bindings/js/kaya/index.ts"
GO = "bindings/go/app.go"
GOR = "bindings/go/records.go"
GOS = "bindings/go/sums.go"
GOG = "cmd/kaya-gen/main.go"
CS = "bindings/csharp/KayaApp.cs"
CSR = "bindings/csharp/KayaRecords.cs"
CSG = "tools/kaya-csgen/Program.cs"
JV = "bindings/java/dev/kaya/KayaApp.java"
JVR = "bindings/java/dev/kaya/KayaRecords.java"
JVP = "tools/java-processor/dev/kaya/processor/KayaProcessor.java"
SW = "bindings/swift/KayaApp.swift"
SWR = "bindings/swift/KayaRecords.swift"
SWG = "tools/kaya-swift-gen/Sources/main.swift"
ML = "bindings/ocaml/kaya_app.mli"
MLI = "bindings/ocaml/kaya_app.ml"
PPX = "bindings/ocaml/ppx/kaya_ppx.ml"
HS = "bindings/haskell/KayaApp.hs"

# (label, file, pattern, the name inside it a rename cuts)
ROWS = [
    ("rust field type", RS, r"^impl KayaField for Symbol \{", "Symbol"),
    ("rust template symbol", RS, r"^impl From<Symbol> for TplSource<SymbolKind> \{", "From"),
    ("rust field bind", RS, r"pub fn symbol\(&mut self, node: TemplateNodeId, src: impl Into<TplSource<SymbolKind>>\)", "SymbolKind"),

    ("python field type", PY, r"^_WIRE_TYPES\.append\(\(Symbol, wire\.VALUE_I64\)\)", "Symbol"),
    ("python template symbol", PY, r"^def _set_symbol\(handle: _Handle, symbol: Symbol \| str \| Source\) -> None:(?:\n[^\n]*){0,8}?\n    if isinstance\(symbol, FieldRef\):", "_set_symbol"),
    ("python field bind", PY, r"wire\.tx_bind_symbol_element\(handle\.id, symbol\._level\(\), symbol\._index\)", "tx_bind_symbol_element"),

    ("js field type", JS, r"token === Tint \|\| token === Symbol_\) return wire\.VALUE_I64;", "Symbol_"),
    ("js template symbol", JS, r"^function setSymbol\(handle: Widget, symbol: SymbolValue \| SymbolName \| FieldRef\): void \{", "setSymbol"),
    ("js field bind", JS, r"wire\.tx_bind_symbol_element\(handle\.id, symbol\._level\(\), symbol\._index\)", "tx_bind_symbol_element"),

    ("go field type", GOG, r'^\t"kaya\.Symbol": true,', "Symbol"),
    ("go record scalar", GOR, r"\tcase Symbol:\n\t\treturn int64\(d\)", "Symbol"),
    ("go template symbol", GO, r"^func \(t \*Tpl\) SetSymbol\(n Node, symbol Symbol\) \{", "SetSymbol"),
    ("go field bind", GO, r"^func \(t \*Tpl\) BindSymbol\(n Node, f Field\[Symbol\]\) \{", "BindSymbol"),
    ("go sum arm field bind", GOS, r"^func \(sc SumCase\[K, V\]\) BindSymbol\(n Node, f Field\[Symbol\]\)", "BindSymbol"),
    ("go generated row field bind", GOG, r'w\("func \(r %sRow\) BindSymbol\(n kaya\.Node, f kaya\.Field\[kaya\.Symbol\]\)', "BindSymbol"),

    ("csharp field type", CSR, r": t == typeof\(Symbol\) \? KayaWire\.ValueI64", "Symbol"),
    ("csharp template symbol", CS, r"public void SetSymbol\(Node n, Symbol symbol\) =>", "SetSymbol"),
    ("csharp field bind", CS, r"public void SetSymbol\(Node n, Field<Symbol> f, uint level = 0\) =>", "SetSymbol"),
    ("csharp generated row field bind", CSG, r'Set\("SetSymbol", \["Node n", "Field<Symbol> f", "uint level = 0"\]', "SetSymbol"),

    ("java field type", JVR, r"if \(t == KayaApp\.Symbol\.class\) return KayaWire\.VALUE_I64;", "Symbol"),
    ("java processor type", JVP, r'case "dev\.kaya\.KayaApp\.Symbol" -> "dev\.kaya\.KayaApp\.Symbol";', "Symbol"),
    ("java template symbol", JV, r"public void setSymbol\(Node n, Symbol symbol\) \{\n\s+tx\.emit", "setSymbol"),
    ("java field bind", JV, r"public void setSymbol\(Node n, KayaRecords\.Field<Symbol> f\) \{\n\s+tx\.emit\(KayaWire\.txBindSymbolElement", "setSymbol"),

    ("swift field type", SWR, r"case let s as KayaSymbol: return \.i64\(s\.rawValue\)", "KayaSymbol"),
    ("swift generated field type", SWG, r'"KayaSymbol": \("i64", "\.add"\),', "KayaSymbol"),
    ("swift template symbol", SW, r"public func setSymbol\(_ n: KayaNodeHandle, _ symbol: KayaSymbol\) \{", "setSymbol"),
    ("swift field bind", SW, r"public func setSymbol\(_ n: KayaNodeHandle, level: UInt32 = 0, _ f: KayaField<KayaSymbol>\) \{", "setSymbol"),

    ("ocaml field type", ML, r"^val symbol_field : int -> \('a, symbol\) field", "symbol_field"),
    ("ocaml ppx field type", PPX, r"\| \[%type: Kaya_app\.symbol\] -> Some Sym", "symbol"),
    ("ocaml template symbol", ML, r"  val button :\n(?:    [^\n]*\n)*?    \?symbol:symbol ->\n    \?symbol_field", "symbol:symbol"),
    ("ocaml field bind", ML, r"  val button :\n(?:    [^\n]*\n)*?    \?symbol_field:\('f, symbol\) field ->", "symbol_field"),

    ("haskell field type", HS, r"^instance KayaFieldType Symbol where", "Symbol"),
    ("haskell template symbol", HS, r"^  TplSymbol :: Symbol -> TplAttr", "TplSymbol"),
    ("haskell field bind", HS, r"^  TplSymbolField :: KField Symbol -> TplAttr", "TplSymbolField"),
]
FLOOR = 30
LANGS = ("rust", "python", "js", "go", "csharp", "java", "swift", "ocaml", "haskell")
PARTS = ("field type", "template symbol", "field bind")
FAKE = "kayaFakeTemplateSymbol"


def ocaml_vocabulary(text):
    """The `type symbol` constructors and `all_symbols`, in order, from the
    OCaml binding's .ml; None for a half the reader cannot find."""
    decl = re.search(r"^type symbol =\n((?:  [^\n]*\n)+)", text, re.M)
    listed = re.search(r"^let all_symbols =\n  \[([^\]]*)\]", text, re.M)
    if decl is None or listed is None:
        return None, None
    body = re.sub(r"\(\*.*?\*\)", "", decl.group(1), flags=re.S)
    return re.findall(r"\|\s*([A-Z]\w*)", body), re.findall(r"[A-Z]\w*", listed.group(1))


def findings(texts, rows=ROWS):
    if len(rows) < FLOOR:
        return [f"template symbol census read fewer than {FLOOR} surfaces"]
    out = [f"template symbol {label} absent in {rel}"
           for label, rel, pattern, _token in rows if not re.search(pattern, texts[rel], re.M)]
    for lang in LANGS:
        mine = [label[len(lang) + 1:] for label, *_ in rows if label.startswith(lang + " ")]
        for part in PARTS:
            if part not in mine:
                out.append(f"template symbol census holds no {part} row for {lang}")
    declared, listed = ocaml_vocabulary(texts[MLI])
    if declared is None:
        out.append(f"template symbol: {MLI} lost `type symbol` or `let all_symbols`")
    elif declared != listed:
        out.append(f"template symbol: {MLI}'s all_symbols {listed} is not its type's constructors {declared}, "
                   "in order, so symbol_of_packed cannot answer every symbol")
    return out


def run():
    gate = Gate("check-template-symbol-surface")
    texts = {rel: (ROOT / rel).read_text(encoding="utf-8") for rel in {r for _, r, _, _ in ROWS} | {MLI}}
    declared, _ = ocaml_vocabulary(texts[MLI])
    gate.counted("ocaml symbol constructors", declared or [], floor=36)
    baseline = findings(texts)
    for problem in baseline:
        gate.finding(problem)
    if baseline:
        print("check-template-symbol-surface: FINDINGS ABOVE")
        return gate.status
    fake_rows = [(label, rel, pattern.replace(re.escape(token), FAKE).replace(token, FAKE), token)
                 for label, rel, pattern, token in ROWS]
    fired = sum(1 for line in findings(texts, fake_rows) if " absent in " in line)
    print(f"check-template-symbol-surface: fake names fired {fired}/{len(ROWS)}")
    if fired != len(ROWS):
        gate.finding(f"check-template-symbol-surface: {len(ROWS) - fired} fake-name rows still matched")
    for label, rel, pattern, token in ROWS:
        count = len(re.findall(pattern, texts[rel], re.M))
        broken = gate.doctor(label, texts[rel], pattern,
                             lambda m, token=token: m.group(0).replace(token, "kayaCut"),
                             want=count, flags=re.M)
        gate.negative(label, lambda rel=rel, broken=broken: findings({**texts, rel: broken}),
                      want=f"template symbol {label} absent")
    gate.negative("empty reader", lambda: findings(texts, []), want=f"fewer than {FLOOR}")
    withheld = [row for row in ROWS if row[0] != "python template symbol"]
    gate.negative("a binding's row withheld", lambda: findings(texts, withheld),
                  want="no template symbol row for python")
    short = gate.doctor("ocaml all_symbols missing Save", texts[MLI], r"Strikethrough; Save \]", "Strikethrough ]")
    gate.negative("ocaml all_symbols missing Save", lambda: findings({**texts, MLI: short}),
                  want="is not its type's constructors")
    gate.negatives_ran(len(ROWS) + 3)
    if gate.status == 0:
        print(f"check-template-symbol-surface: OK ({len(ROWS)} template symbol surfaces in nine bindings)")
    return gate.status
