// The Swift arm of the generator family. Reads a guest source file for
// types conforming to KayaGen — the declaration is the schema, nothing
// restated — and writes <file>+Kaya.swift beside it. The declaration's
// shape decides what is generated, the one KayaGen story every
// language tells:
//
//   - an enum is a sum: the generated extension carries the
//     KayaSumElement conformance (prototypes and init(variant:values:)
//     — nothing hand-written), typed field tokens replace label
//     strings, and the eliminator takes one required labeled parameter
//     per constructor, so a missing arm is a missing argument — a
//     compile error, with the scene checking totality again.
//   - a struct is a record: the generated extension carries the
//     KayaRecord conformance (prototype and init(values:)), plus field
//     tokens and the collection factory.
//
// Generated files are checked in; tools/gen-guests.sh regenerates and
// diffs.
//
//     swift run --package-path tools/kaya-swift-gen kaya-swift-gen <guest.swift>

import Foundation
import SwiftParser
import SwiftSyntax

struct Field {
    let label: String
    let type: String
}

struct Case {
    let name: String
    let fields: [Field]
}

enum Decl {
    case sum(name: String, cases: [Case])
    case record(name: String, fields: [Field])

    var name: String {
        switch self {
        case .sum(let name, _), .record(let name, _): return name
        }
    }
}

/// The wire vocabulary a field type maps into: the KayaValue case, the
/// prototype's zero value. Any other type is a loud error — the wire
/// has exactly these four scalars.
let wire: [String: (valueCase: String, zero: String)] = [
    "String": ("str", "\"\""),
    "Bool": ("bool", "false"),
    "Int64": ("i64", "0"),
    "Double": ("f64", "0"),
]

func conformsToKayaGen(_ clause: InheritanceClauseSyntax?) -> Bool {
    clause?.inheritedTypes.contains { $0.type.trimmedDescription == "KayaGen" } == true
}

final class DeclCollector: SyntaxVisitor {
    var decls: [Decl] = []

    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
        guard conformsToKayaGen(node.inheritanceClause) else { return .skipChildren }
        var cases: [Case] = []
        for member in node.memberBlock.members {
            guard let caseDecl = member.decl.as(EnumCaseDeclSyntax.self) else { continue }
            for element in caseDecl.elements {
                var fields: [Field] = []
                for p in element.parameterClause?.parameters ?? [] {
                    fields.append(
                        Field(
                            label: p.firstName?.text ?? "",
                            type: p.type.trimmedDescription))
                }
                cases.append(Case(name: element.name.text, fields: fields))
            }
        }
        decls.append(.sum(name: node.name.text, cases: cases))
        return .skipChildren
    }

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        guard conformsToKayaGen(node.inheritanceClause) else { return .skipChildren }
        // The wire fields: stored properties of wire type, in
        // declaration order.
        var fields: [Field] = []
        for member in node.memberBlock.members {
            guard let varDecl = member.decl.as(VariableDeclSyntax.self) else { continue }
            for binding in varDecl.bindings {
                guard let name = binding.pattern.as(IdentifierPatternSyntax.self),
                    let type = binding.typeAnnotation?.type.trimmedDescription,
                    wire[type] != nil
                else { continue }
                fields.append(Field(label: name.identifier.text, type: type))
            }
        }
        decls.append(.record(name: node.name.text, fields: fields))
        return .skipChildren
    }
}

func upper(_ s: String) -> String { s.prefix(1).uppercased() + s.dropFirst() }
func lower(_ s: String) -> String { s.prefix(1).lowercased() + s.dropFirst() }

func die(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

/// A constructor expression with every field at its zero value.
func zeroCall(_ head: String, _ fields: [Field]) -> String {
    if fields.isEmpty { return head }
    let args = fields.map { "\($0.label): \(wire[$0.type]!.zero)" }
    return "\(head)(\(args.joined(separator: ", ")))"
}

/// The `guard case .str(let title) = values[0], …` unpacking lines.
func unpackLines(_ fields: [Field], indent: String, onFail: String) -> [String] {
    let guards = fields.enumerated().map { (j, f) in
        "case .\(wire[f.type]!.valueCase)(let \(f.label)) = values[\(j)]"
    }
    return [
        "\(indent)guard \(guards.joined(separator: ", ")) else {",
        "\(indent)    preconditionFailure(\"\(onFail)\")",
        "\(indent)}",
    ]
}

func generateSum(_ name: String, _ cases: [Case]) -> String {
    var b = ""
    func line(_ s: String = "") { b += s + "\n" }

    line("extension \(name): KayaSumElement {")
    line("    /// One prototype per constructor, in declaration order — the")
    line("    /// one spelling of the constructor order.")
    line("    static var prototypes: [\(name)] {")
    line("        [")
    for c in cases {
        line("            \(zeroCall(".\(c.name)", c.fields)),")
    }
    line("        ]")
    line("    }")
    line("")
    line("    init(variant: UInt32, values: [KayaValue]) {")
    line("        switch variant {")
    for (i, c) in cases.enumerated() {
        line("        case \(i):")
        if c.fields.isEmpty {
            line("            self = .\(c.name)")
            continue
        }
        unpackLines(c.fields, indent: "            ",
                    onFail: "kaya: \(c.name) fields out of order").forEach { line($0) }
        let args = c.fields.map { "\($0.label): \($0.label)" }
        line("            self = .\(c.name)(\(args.joined(separator: ", ")))")
    }
    line("        default:")
    line("            preconditionFailure(\"kaya: \(name) has no variant \\(variant)\")")
    line("        }")
    line("    }")
    line("}")
    line("")

    // Typed field tokens: one namespace per constructor, one token per
    // wire field, index resolved here at generation.
    for c in cases where !c.fields.isEmpty {
        line("/// \(c.name)'s typed field tokens.")
        line("enum \(name)\(upper(c.name))Fields {")
        for (j, f) in c.fields.enumerated() {
            line("    static let \(f.label) = KayaField<\(f.type)>(index: \(j))")
        }
        line("}")
        line("")
    }

    // The refined arm vocabularies: the tokens plus the template
    // surface, typed end to end.
    for c in cases {
        line("/// \(c.name)'s refined arm vocabulary: typed tokens, no label")
        line("/// strings.")
        line("struct \(name)\(upper(c.name))Arm {")
        for f in c.fields {
            line("    let \(f.label) = \(name)\(upper(c.name))Fields.\(f.label)")
        }
        line("    func label(_ t: KayaTpl, _ f: KayaField<String>) -> KayaNodeHandle {")
        line("        t.label(f)")
        line("    }")
        line("")
        line("    func checkbox(")
        line("        _ t: KayaTpl, _ f: KayaField<Bool>,")
        line("        onToggle: ((KayaAppTx, [KayaValue], Bool) -> Void)? = nil")
        line("    ) -> KayaNodeHandle {")
        line("        t.checkbox(f, onToggle: onToggle)")
        line("    }")
        line("}")
        line("")
    }

    line("/// The collection factory: the constructor order lives in the")
    line("/// generated prototypes.")
    line("func \(lower(name))Collection(_ tx: KayaAppTx) -> KayaSumCollection<\(name)> {")
    line("    tx.sumCollection(of: \(name).self)")
    line("}")
    line("")
    line("/// The compile-total eliminator: one required labeled parameter")
    line("/// per constructor, with the scene checking totality again.")
    line("func \(lower(name))EachSum(")
    line("    _ tx: KayaAppTx, _ c: KayaSumCollection<\(name)>,")
    for (i, c) in cases.enumerated() {
        let comma = i == cases.count - 1 ? "" : ","
        line("    \(c.name): @escaping (KayaTpl, \(name)\(upper(c.name))Arm) -> Void\(comma)")
    }
    line(") -> KayaWidget {")
    line("    tx.eachSum(")
    line("        c,")
    line("        arms: [")
    for c in cases {
        line("            c.arm(\(zeroCall(".\(c.name)", c.fields))) { t, _ in \(c.name)(t, \(name)\(upper(c.name))Arm()) },")
    }
    line("        ])")
    line("}")
    return b
}

func generateRecord(_ name: String, _ fields: [Field]) -> String {
    var b = ""
    func line(_ s: String = "") { b += s + "\n" }

    line("extension \(name): KayaRecord {")
    line("    /// The prototype Mirror walks for the schema; every field at")
    line("    /// its zero value.")
    line("    static let prototype = \(zeroCall(name, fields))")
    line("")
    line("    init(values: [KayaValue]) {")
    unpackLines(fields, indent: "        ",
                onFail: "kaya: \(name) fields out of order").forEach { line($0) }
    let args = fields.map { "\($0.label): \($0.label)" }
    line("        self.init(\(args.joined(separator: ", ")))")
    line("    }")
    line("}")
    line("")
    line("/// \(name)'s typed field tokens.")
    line("enum \(name)Fields {")
    for (j, f) in fields.enumerated() {
        line("    static let \(f.label) = KayaField<\(f.type)>(index: \(j))")
    }
    line("}")
    line("")
    line("/// The collection factory; the struct is the schema.")
    line("func \(lower(name))Collection(_ tx: KayaAppTx) -> KayaRecordCollection<\(name)> {")
    line("    tx.collection(of: \(name).self)")
    line("}")
    return b
}

func generate(_ decl: Decl) -> String {
    switch decl {
    case .sum(let name, let cases):
        for c in cases {
            for f in c.fields where wire[f.type] == nil {
                die("kaya-swift-gen: \(name).\(c.name).\(f.label): \(f.type) is not a wire type")
            }
        }
        if cases.count < 2 {
            die("kaya-swift-gen: \(name) needs two constructors or more")
        }
        return generateSum(name, cases)
    case .record(let name, let fields):
        if fields.isEmpty {
            die("kaya-swift-gen: \(name) has no wire-typed stored properties")
        }
        return generateRecord(name, fields)
    }
}

let arguments = CommandLine.arguments.dropFirst()
guard !arguments.isEmpty else {
    die("usage: kaya-swift-gen <guest.swift>...")
}
for path in arguments {
    guard let source = try? String(contentsOfFile: path, encoding: .utf8) else {
        die("kaya-swift-gen: cannot read \(path)")
    }
    let collector = DeclCollector(viewMode: .sourceAccurate)
    collector.walk(Parser.parse(source: source))
    guard !collector.decls.isEmpty else {
        die("kaya-swift-gen: no KayaGen types in \(path)")
    }
    var out = "// Code generated by kaya-swift-gen; DO NOT EDIT.\n"
    out += "// Regenerate with tools/gen-guests.sh (which also checks freshness).\n\n"
    out += collector.decls.map(generate).joined(separator: "\n")
    let outPath = String(path.dropLast(".swift".count)) + "+Kaya.swift"
    try! out.write(toFile: outPath, atomically: true, encoding: .utf8)
    let names = collector.decls.map(\.name).joined(separator: ", ")
    print("kaya-swift-gen: wrote \(outPath) (\(names))")
}
