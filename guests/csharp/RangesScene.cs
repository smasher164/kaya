// The text-ranges conformance scene, C# port — the three primitives an
// editor cannot write for itself: HIGHLIGHT a set of ranges, SELECT
// one, REVEAL one. Canonical semantics in guests/rust/ranges.rs; the
// byte-frozen contract in tools/scenes/ranges.steps.
//
// THE OFFSETS ARE WHERE C# EARNS ITS PORT. Rust's match_indices yields
// UTF-8 byte offsets, which is kaya's unit, so the Rust guest hands
// kaya the ranges it already had. .NET's IndexOf answers in UTF-16 code
// units, and over this document — whose first line is CJK — that is SIX
// LESS than the byte offset from the first match onward. Six is not a
// crash: it is a perfectly valid offset, on a character boundary,
// inside the text, so nothing refuses it and the highlight simply
// covers the wrong six characters. TextRange.In is the conversion, in
// the binding, once; this file's job is to prove a guest cannot skip it
// and still pass, because the scene asserts absolute numbers.
//
// THE SEARCH IS FIVE LINES AND THAT IS THE POINT. kaya ships no find
// engine, no find bar and no regex dialect (docs/ranges-plan.md §3):
// what to decorate is the app's question and every editor answers it
// differently. What no app can write for itself is colouring a run of a
// native text view, moving its selection, and scrolling it into view.

using System;
using System.Collections.Generic;
using System.Text;

static class RangesScene
{
    // The document, frozen — three occurrences of `alpha` and nothing
    // else containing that substring; forty short lines, so the last
    // match is far below the viewport and REVEAL has something to do.
    //
    // JOINED WITH AN EXPLICIT \n rather than written as one verbatim
    // literal: the scene's offsets are absolute, and a checkout or a
    // deploy that translated this file's line endings would move every
    // one of them. The separator is stated, so it cannot be translated.
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

    // THE WHOLE SEARCH. Literal, forward, non-overlapping — the standard
    // library's own IndexOf, Ordinal because a find that folded case
    // would owe its users an explanation. An editor that wants case
    // folding, word boundaries or a regex dialect writes them here, in
    // the app.
    //
    // TextRange.In IS THE LINE THAT IS NOT OPTIONAL: `at` is a UTF-16
    // index and kaya's ranges are UTF-8 byte offsets. Handing `at`
    // straight over compiles, runs, and decorates six characters early.
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
        // THE DOCUMENT IS BYTE-FROZEN and this is where a port proves
        // it. tools/scenes/ranges.steps asserts ABSOLUTE offsets
        // (57:62, 203:208, 753:758), so a document that is not
        // byte-identical to the Rust guest's fails them with numbers
        // nobody can read back to a cause. A line-ending translation, a
        // source file decoded as anything but UTF-8, one retyped line —
        // each lands here first, naming the length.
        int bytes = Encoding.UTF8.GetByteCount(Doc);
        if (bytes != 813)
            throw new InvalidOperationException(
                $"kaya guest: the ranges document is {bytes} UTF-8 bytes, not 813 — "
                    + "the scene's offsets are absolute (tools/scenes/ranges.steps)");

        var app = new KayaApp();

        // The app's own copy of the document, which is the ONLY
        // authority on what the offsets mean. It advances on every edit,
        // exactly as an editor's buffer does.
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
                    // THE SEARCH RESULTS ARE STALE AND THE APP SAYS SO.
                    // kaya has already dropped the decorations — a
                    // declared set is bound to the text it was declared
                    // against — and this is the app agreeing rather than
                    // being told: an editor whose document moved has to
                    // search again before it can claim anything about
                    // where the matches are.
                    t.Write(status, "0 matches");
                });
                // The a11y id is not decoration: every range assertion
                // reads the platform's accessibility tree, and the id is
                // how a leg finds this control there.
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
                        // The second match, so a leg can tell the
                        // selection apart from "the first thing found".
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
