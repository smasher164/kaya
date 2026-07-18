// The C# arm of the generator family. Reads guest sources for
// [KayaGen] declarations — the declaration is the schema, nothing
// restated — and writes <Type>Kaya.cs beside them. The declaration's
// shape decides what is generated, the one KayaGen story every
// language tells: an abstract record is a sum (the derived records,
// in declaration order, are the constructors) and gets the collection
// factory plus the compile-total EachSum eliminator — each
// constructor a required delegate parameter, named at the call site,
// so a missing arm is a missing argument, a compile error, with the
// scene checking totality again. A plain record gets the collection
// factory, exact-index field tokens, and a named-setter patch (each
// Set records one update_field — a patch is recorded writes, never a
// diff). Generated files are checked in; tools/gen-guests.sh
// regenerates and diffs.
//
//     dotnet run --project tools/kaya-csgen -- <guest source dir>

using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using Microsoft.CodeAnalysis;
using Microsoft.CodeAnalysis.CSharp;
using Microsoft.CodeAnalysis.CSharp.Syntax;

static class Program
{
    static int Main(string[] args)
    {
        if (args.Length != 1)
        {
            Console.Error.WriteLine("usage: kaya-csgen <guest source dir>");
            return 2;
        }
        var dir = args[0];
        var sums = 0;
        foreach (var file in Directory.EnumerateFiles(dir, "*.cs").OrderBy(f => f))
        {
            if (Path.GetFileName(file).EndsWith("Kaya.cs", StringComparison.Ordinal))
                continue;
            var root = CSharpSyntaxTree.ParseText(File.ReadAllText(file)).GetRoot();
            var records = root.DescendantNodes()
                .OfType<RecordDeclarationSyntax>()
                .ToList();
            foreach (var marked in records.Where(IsKayaGen))
            {
                var name = marked.Identifier.Text;
                var ns = marked.Ancestors()
                    .OfType<BaseNamespaceDeclarationSyntax>()
                    .Select(n => n.Name.ToString())
                    .FirstOrDefault();
                var outPath = Path.Combine(dir, name + "Kaya.cs");
                // The declaration's shape decides: abstract record =
                // sum, plain record = record.
                if (marked.Modifiers.Any(m => m.IsKind(SyntaxKind.AbstractKeyword)))
                {
                    // Declaration order in the file is the constructor
                    // order — the same order every other tier stamps.
                    var ctors = records
                        .Where(r => r.BaseList != null && r.BaseList.Types.Any(t =>
                            t.Type is IdentifierNameSyntax id && id.Identifier.Text == name))
                        .OrderBy(r => r.SpanStart)
                        .Select(r => (name: r.Identifier.Text,
                            fields: (r.ParameterList?.Parameters ?? default)
                                .Select(p => (name: p.Identifier.Text, type: p.Type?.ToString()))
                                .Where(f => Wire.Contains(f.type))
                                .ToList()))
                        .ToList();
                    if (ctors.Count < 2)
                    {
                        Console.Error.WriteLine(
                            $"kaya-csgen: [KayaGen] {name} needs two derived records or more");
                        return 1;
                    }
                    File.WriteAllText(outPath, GenerateSum(ns, name, ctors));
                    Console.WriteLine(
                        $"kaya-csgen: wrote {outPath} ({ctors.Count} constructors of {name})");
                }
                else
                {
                    // The wire fields: primary-constructor parameters
                    // of wire type, in declaration order.
                    var fields = (marked.ParameterList?.Parameters ?? default)
                        .Select(p => (name: p.Identifier.Text, type: p.Type?.ToString()))
                        .Where(f => Wire.Contains(f.type))
                        .ToList();
                    if (fields.Count == 0)
                    {
                        Console.Error.WriteLine(
                            $"kaya-csgen: [KayaGen] {name} has no wire-typed parameters");
                        return 1;
                    }
                    File.WriteAllText(outPath, GenerateRecord(ns, name, fields));
                    Console.WriteLine(
                        $"kaya-csgen: wrote {outPath} ({fields.Count} fields of {name})");
                }
                sums++;
            }
        }
        if (sums == 0)
            Console.Error.WriteLine($"kaya-csgen: no [KayaGen] records under {dir}");
        return 0;
    }

    static readonly System.Collections.Generic.HashSet<string> Wire =
        new() { "string", "bool", "long", "double" };

    static bool IsKayaGen(RecordDeclarationSyntax r) =>
        r.AttributeLists.SelectMany(l => l.Attributes)
            .Any(a => a.Name.ToString() is "KayaGen" or "KayaGenAttribute");

    static string GenerateSum(string ns, string sum,
        List<(string name, List<(string name, string type)> fields)> ctors)
    {
        var b = new System.Text.StringBuilder();
        b.AppendLine("// Code generated by kaya-csgen; DO NOT EDIT.");
        b.AppendLine("// Regenerate with tools/gen-guests.sh (which also checks freshness).");
        b.AppendLine();
        if (ns != null)
        {
            b.AppendLine($"namespace {ns};");
            b.AppendLine();
        }
        b.AppendLine($"/// <summary>{sum}'s generated sum surface: the collection factory");
        b.AppendLine("/// and the compile-total eliminator — one required delegate per");
        b.AppendLine("/// constructor, named at the call site, with the scene checking");
        b.AppendLine("/// totality again.</summary>");
        b.AppendLine($"static class {sum}Kaya");
        b.AppendLine("{");
        var typeofs = string.Join(", ", ctors.Select(c => $"typeof({c.name})"));
        b.AppendLine($"    public static SumCollection<{sum}> Collection(Tx tx) =>");
        b.AppendLine($"        tx.SumOf<{sum}>({typeofs});");
        b.AppendLine();
        b.AppendLine($"    public static Widget EachSum(Tx tx, SumCollection<{sum}> c,");
        for (var i = 0; i < ctors.Count; i++)
        {
            var comma = i == ctors.Count - 1 ? ") =>" : ",";
            b.AppendLine(
                $"        System.Action<Tpl, SumCase<{ctors[i].name}>> {Lower(ctors[i].name)}{comma}");
        }
        var arms = string.Join(", ", ctors.Select(c => $"c.Arm<{c.name}>({Lower(c.name)})"));
        b.AppendLine($"        tx.EachSum(c, {arms});");
        b.AppendLine();
        foreach (var ctor in ctors.Where(c => c.fields.Count > 0))
        {
            b.AppendLine($"    /// <summary>As{ctor.name} re-eliminates at call time: the null");
            b.AppendLine("    /// is the refinement, fresh at write time — a stale occurrence");
            b.AppendLine($"    /// folds into ?. — and each setter's update carries {ctor.name}");
            b.AppendLine("    /// as its witness, asserted again by the scene.</summary>");
            b.AppendLine($"    public static {sum}{ctor.name}Patch As{ctor.name}(Tx tx, SumCollection<{sum}> c, object key) =>");
            b.AppendLine($"        tx != null && c.Get(tx, key) is {ctor.name}");
            b.AppendLine($"            ? new {sum}{ctor.name}Patch(tx, c, key) : null;");
            b.AppendLine();
        }
        b.AppendLine("}");
        foreach (var ctor in ctors.Where(c => c.fields.Count > 0))
        {
            b.AppendLine();
            b.AppendLine($"/// <summary>{ctor.name}'s refined patch: named setters over the");
            b.AppendLine("/// witnessed update.</summary>");
            b.AppendLine($"sealed class {sum}{ctor.name}Patch");
            b.AppendLine("{");
            b.AppendLine("    readonly Tx tx;");
            b.AppendLine($"    readonly SumCollection<{sum}> c;");
            b.AppendLine("    readonly object key;");
            b.AppendLine();
            b.AppendLine($"    internal {sum}{ctor.name}Patch(Tx tx, SumCollection<{sum}> c, object key)");
            b.AppendLine("    {");
            b.AppendLine("        this.tx = tx;");
            b.AppendLine("        this.c = c;");
            b.AppendLine("        this.key = key;");
            b.AppendLine("    }");
            foreach (var f in ctor.fields)
            {
                b.AppendLine();
                b.AppendLine($"    public {sum}{ctor.name}Patch {f.name}({f.type} v)");
                b.AppendLine("    {");
                b.AppendLine($"        c.UpdateField<{ctor.name}, {f.type}>(tx, key, x => x.{f.name}, v);");
                b.AppendLine("        return this;");
                b.AppendLine("    }");
            }
            b.AppendLine("}");
        }
        return b.ToString();
    }

    static string GenerateRecord(string ns, string rec, List<(string name, string type)> fields)
    {
        var b = new System.Text.StringBuilder();
        b.AppendLine("// Code generated by kaya-csgen; DO NOT EDIT.");
        b.AppendLine("// Regenerate with tools/gen-guests.sh (which also checks freshness).");
        b.AppendLine();
        if (ns != null)
        {
            b.AppendLine($"namespace {ns};");
            b.AppendLine();
        }
        b.AppendLine($"/// <summary>{rec}'s generated record surface: the collection");
        b.AppendLine("/// factory, exact-index field tokens, and a named-setter patch");
        b.AppendLine("/// (each set records one update_field — a patch is recorded");
        b.AppendLine("/// writes, never a diff).</summary>");
        b.AppendLine($"static class {rec}Kaya");
        b.AppendLine("{");
        b.AppendLine($"    public static RecordCollection<{rec}> Collection(Tx tx) =>");
        b.AppendLine($"        tx.CollectionOf<{rec}>();");
        b.AppendLine();
        for (var i = 0; i < fields.Count; i++)
        {
            b.AppendLine(
                $"    public static readonly Field<{fields[i].type}> {fields[i].name} ="
                + $" KayaRecords.FieldAt<{fields[i].type}>({i});");
        }
        b.AppendLine();
        b.AppendLine($"    public static {rec}KayaPatch Patch(Tx tx, RecordCollection<{rec}> c, object key) =>");
        b.AppendLine($"        new {rec}KayaPatch(c.Patch(tx, key));");
        b.AppendLine();
        b.AppendLine("    /// <summary>The record template: the body runs once, authoring");
        b.AppendLine("    /// the blueprint with the typed row surface (exact-index");
        b.AppendLine("    /// tokens, no probes); stamping is the core's replay.</summary>");
        b.AppendLine($"    public static Widget Each(Tx tx, RecordCollection<{rec}> c,");
        b.AppendLine($"        System.Action<Tpl, {rec}Row> body) =>");
        b.AppendLine($"        tx.Each(c.Collection, t => body(t, new {rec}Row()));");
        b.AppendLine("}");
        b.AppendLine();
        b.AppendLine("/// <summary>The row surface: one token per wire field, and the");
        b.AppendLine("/// template constructors that consume them.</summary>");
        b.AppendLine($"sealed class {rec}Row");
        b.AppendLine("{");
        foreach (var f in fields)
        {
            b.AppendLine($"    public readonly Field<{f.type}> {f.name} = {rec}Kaya.{f.name};");
        }
        b.AppendLine();
        b.AppendLine($"    public Node Label(Tpl t, Field<string> f) => t.Label(f);");
        b.AppendLine();
        b.AppendLine($"    public Node Checkbox(Tpl t, Field<bool> f,");
        b.AppendLine("        System.Action<Tx, System.Collections.Generic.List<object>, bool> onToggle = null) =>");
        b.AppendLine("        t.Checkbox(f, onToggle);");
        b.AppendLine("}");
        b.AppendLine();
        b.AppendLine($"sealed class {rec}KayaPatch");
        b.AppendLine("{");
        b.AppendLine($"    readonly RecordPatch<{rec}> p;");
        b.AppendLine();
        b.AppendLine($"    internal {rec}KayaPatch(RecordPatch<{rec}> p) => this.p = p;");
        foreach (var f in fields)
        {
            b.AppendLine();
            b.AppendLine($"    public {rec}KayaPatch {f.name}({f.type} v)");
            b.AppendLine("    {");
            b.AppendLine($"        p.Set({rec}Kaya.{f.name}, v);");
            b.AppendLine("        return this;");
            b.AppendLine("    }");
        }
        b.AppendLine("}");
        return b.ToString();
    }

    static string Lower(string s) => char.ToLowerInvariant(s[0]) + s.Substring(1);
}
