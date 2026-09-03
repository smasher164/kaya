// The ranges scene, C# port — guests/rust/ranges.rs,
// tools/scenes/ranges.steps.

using System;
using System.Collections.Generic;
using System.Text;

static class RangesScene
{
    // Frozen, and joined with an explicit \n: a line-ending translation would
    // move every absolute offset the scene asserts.
    static readonly string Doc = string.Join("\n", new[]
    {
        "line 00: 日本語 preface",
        "line 01: gamma kappa",
        "line 02: alpha beta gamma",
        "line 03: epsilon theta",
        "line 04: zeta nu",
        "line 05: eta zeta",
        "line 06: theta lambda",
        "line 07: iota delta",
        "line 08: kappa iota",
        "line 09: alpha eta theta",
        "line 10: mu eta",
        "line 11: nu mu",
        "line 12: beta epsilon",
        "line 13: gamma kappa",
        "line 14: delta gamma",
        "line 15: epsilon theta",
        "line 16: zeta nu",
        "line 17: eta zeta",
        "line 18: theta lambda",
        "line 19: iota delta",
        "line 20: kappa iota",
        "line 21: lambda beta",
        "line 22: mu eta",
        "line 23: nu mu",
        "line 24: beta epsilon",
        "line 25: gamma kappa",
        "line 26: delta gamma",
        "line 27: epsilon theta",
        "line 28: zeta nu",
        "line 29: eta zeta",
        "line 30: theta lambda",
        "line 31: iota delta",
        "line 32: kappa iota",
        "line 33: lambda beta",
        "line 34: mu eta",
        "line 35: nu mu",
        "line 36: beta epsilon",
        "line 37: alpha iota kappa",
        "line 38: delta gamma",
        "line 39: the last line",
    });

    const string Needle = "alpha";

    // TextRange.In is not optional: `at` is a UTF-16 index, kaya's are bytes.
    static List<TextRange> FindAll(string doc, string needle)
    {
        var hits = new List<TextRange>();
        for (int at = doc.IndexOf(needle, StringComparison.Ordinal); at >= 0;
             at = doc.IndexOf(needle, at + needle.Length, StringComparison.Ordinal))
            hits.Add(TextRange.In(doc, at, needle.Length));
        return hits;
    }

    public static void Run()
    {
    // A drifted document would fail ranges.steps with unreadable numbers.
        int bytes = Encoding.UTF8.GetByteCount(Doc);
        if (bytes != 813)
            throw new InvalidOperationException(
                $"kaya guest: the ranges document is {bytes} UTF-8 bytes, not 813 — "
                    + "the scene's offsets are absolute (tools/scenes/ranges.steps)");

        var app = new KayaApp();

        string doc = Doc;
        Signal status = default;
        Widget editor = default;

        app.Build(tx =>
        {
            tx.Window(title: "ranges");
            status = tx.Signal("0 matches");

            tx.Mount(tx.Column(() =>
            {
                editor = tx.Textarea(onChange: (t, text) =>
                {
                    doc = text;
                    t.Write(status, "0 matches");
                });
                // Every range assertion finds this control by its authored id.
                tx.SetA11yId(editor, "doc");
                tx.SetA11yLabel(editor, "Document");
                tx.SetText(editor, Doc);

                tx.Label(bind: status); // label#0

                tx.Row(() =>
                {
                    tx.Button("find", onClick: t => // button#0
                    {
                        var hits = FindAll(doc, Needle);
                        t.HighlightRanges(editor, hits);
                        // The SECOND match, so a leg can tell the selection
                        // apart from "the first thing found".
                        if (hits.Count > 1)
                            t.SelectRange(editor, hits[1]);
                        t.Write(status, $"{hits.Count} matches");
                    });
                    tx.Button("reveal last", onClick: t => // button#1
                    {
                        var hits = FindAll(doc, Needle);
                        if (hits.Count > 0)
                            t.RevealRange(editor, hits[hits.Count - 1]);
                    });
                    tx.Button("focus editor", onClick: t => t.Focus(editor)); // button#2
                    tx.Button("select first", onClick: t => // button#3
                    {
                        var hits = FindAll(doc, Needle);
                        if (hits.Count > 0)
                            t.SelectRange(editor, hits[0]);
                    });
                });
            }));
        });

        Environment.Exit(app.Run());
    }
}
