package dev.kaya.milestone2kt;

import dev.kaya.KayaApp;

import java.util.ArrayList;
import java.util.List;

/**
 * The text-ranges conformance scene from the JVM: the three primitives
 * an editor cannot write for itself — HIGHLIGHT a set of ranges, SELECT
 * one, REVEAL one — driven by a search this file writes in four lines.
 *
 * <p>THE FOUR LINES ARE THE POINT. kaya ships no find engine, no find
 * bar and no regex dialect (docs/ranges-plan.md §3): what to decorate is
 * the app's question, and every editor answers it differently. What no
 * app can write for itself is the other half — colouring a run of a
 * native text view, moving its selection, scrolling it into view — and
 * that is exactly what the framework ships. {@code String.indexOf} is
 * the whole search here, and it is the honest amount of machinery for
 * the job.
 *
 * <p>THE OFFSETS ARE NOT JAVA'S, AND THIS SCENE IS WHERE THAT SHOWS.
 * {@code indexOf} answers in UTF-16 code units; kaya's ranges are UTF-8
 * byte offsets, in every binding and on the wire. The document opens
 * with a CJK word for exactly that reason: its three matches sit at
 * bytes 57, 203 and 753 where {@code indexOf} says 51, 197 and 747 —
 * six lower, every time, and every one of them a plausible-looking
 * number. {@link KayaApp.TextRange#in} is the one line where the two
 * units meet, and it is the line a Java app must not skip. (A backend
 * that then forwarded kaya's byte offsets as if they were already its
 * own unit would decorate six characters early, which is the same
 * mistake one layer down; the scene's frozen offsets catch both.)
 *
 * <p>WHAT EACH LEG PROVES, in the order the script runs them:
 * <ul>
 *   <li>a set of three matches decorated at once, read back out of the
 *       platform's own accessibility tree;
 *   <li>one of them selected, likewise;
 *   <li>the third REVEALED — asserted {@code offscreen} first, so the
 *       leg cannot pass on a document that happened to fit;
 *   <li>a user's keystroke DROPPING the declared set (D2: ranges are
 *       app-owned and never tracked across an edit);
 *   <li>a {@code selectRange} REFUSED because the user is
 *       mid-composition (D4), which is the one thing on this surface a
 *       backend is expected not to do.
 * </ul>
 *
 * <p>Canonical semantics in guests/rust/ranges.rs; the byte-frozen
 * contract in tools/scenes/ranges.steps.
 */
final class Ranges {
    /**
     * The document, frozen. Three occurrences of {@code alpha} and
     * nothing else containing that substring; forty short lines, so the
     * last match is far below the window's viewport and REVEAL has
     * something to do.
     *
     * <p>THE CJK WORD IS SPELLED IN {@code \}{@code u} ESCAPES on
     * purpose. A Java string literal's bytes depend on the encoding the
     * compiler was told the file is in — the desktop build passes
     * {@code -encoding UTF-8}, the Android build that also compiles this
     * directory passes nothing and takes the platform default — and a
     * document that decodes differently on one lane is a document with
     * different offsets, which is the one thing this scene cannot
     * survive. An escape is ASCII in the file and the same three
     * characters (U+65E5 U+672C U+8A9E) out of every compiler.
     */
    private static final String DOC =
            """
            line 00: \u65e5\u672c\u8a9e preface
            line 01: gamma kappa
            line 02: alpha beta gamma
            line 03: epsilon theta
            line 04: zeta nu
            line 05: eta zeta
            line 06: theta lambda
            line 07: iota delta
            line 08: kappa iota
            line 09: alpha eta theta
            line 10: mu eta
            line 11: nu mu
            line 12: beta epsilon
            line 13: gamma kappa
            line 14: delta gamma
            line 15: epsilon theta
            line 16: zeta nu
            line 17: eta zeta
            line 18: theta lambda
            line 19: iota delta
            line 20: kappa iota
            line 21: lambda beta
            line 22: mu eta
            line 23: nu mu
            line 24: beta epsilon
            line 25: gamma kappa
            line 26: delta gamma
            line 27: epsilon theta
            line 28: zeta nu
            line 29: eta zeta
            line 30: theta lambda
            line 31: iota delta
            line 32: kappa iota
            line 33: lambda beta
            line 34: mu eta
            line 35: nu mu
            line 36: beta epsilon
            line 37: alpha iota kappa
            line 38: delta gamma
            line 39: the last line""";

    private static final String NEEDLE = "alpha";

    /**
     * The app's own copy of the document, which is the ONLY authority on
     * what the offsets mean. It advances on every edit, exactly as an
     * editor's buffer does — and it is a fold of the change occurrences,
     * never a read of the widget: kaya has none.
     */
    private static String doc = DOC;

    /**
     * THE WHOLE SEARCH. Literal, forward, non-overlapping — Java's own
     * {@code indexOf}, converted once per hit into the unit kaya's
     * ranges are made of. An editor that wants case folding, word
     * boundaries or a regex dialect writes those here, in the app, where
     * its users can be told what they mean.
     */
    private static List<KayaApp.TextRange> findAll(String text, String needle) {
        List<KayaApp.TextRange> hits = new ArrayList<>();
        for (int at = text.indexOf(needle); at >= 0;
                at = text.indexOf(needle, at + needle.length())) {
            // Java's index in, kaya's offsets out, against THIS text.
            hits.add(KayaApp.TextRange.in(text, at, at + needle.length()));
        }
        return hits;
    }

    static void app() {
        KayaApp app = new KayaApp();

        app.build(tx -> {
            tx.window(0).title("ranges");
            KayaApp.Signal<String> status = tx.signal("0 matches");

            // Java lambdas cannot assign captured locals, so the editor
            // handle the button bodies need comes back out of the
            // container body through a one-slot array (Clipboard.java's
            // idiom, and Undo.java's).
            KayaApp.Widget[] editor = new KayaApp.Widget[1];
            tx.mount(tx.column(() -> {
                // The editor, seeded with the document the app opened.
                // The a11y id is not decoration: every range assertion
                // reads the platform's accessibility tree, and the id is
                // how a leg finds this control there.
                editor[0] = tx.textarea().a11yId("doc").a11yLabel("Document"); // textarea#0
                tx.setText(editor[0], DOC);
                app.onChange(editor[0], (t, text) -> {
                    doc = text;
                    // THE SEARCH RESULTS ARE STALE AND THE APP SAYS SO.
                    // kaya has already dropped the decorations — a
                    // declared set is bound to the text it was declared
                    // against — and this is the app agreeing rather than
                    // being told: an editor whose document moved has to
                    // search again before it can claim anything about
                    // where the matches are.
                    t.write(status, "0 matches");
                });
                tx.label(status); // label#0
                tx.row(() -> {
                    tx.button("find", t -> { // button#0
                        List<KayaApp.TextRange> hits = findAll(doc, NEEDLE);
                        t.highlightRanges(editor[0], hits);
                        // The second match, so a leg can tell the
                        // selection apart from "the first thing found".
                        if (hits.size() > 1) {
                            t.selectRange(editor[0], hits.get(1));
                        }
                        t.write(status, hits.size() + " matches");
                    });
                    tx.button("reveal last", t -> { // button#1
                        List<KayaApp.TextRange> hits = findAll(doc, NEEDLE);
                        if (!hits.isEmpty()) {
                            t.revealRange(editor[0], hits.get(hits.size() - 1));
                        }
                    });
                    tx.button("focus editor", t -> t.focus(editor[0])); // button#2
                    tx.button("select first", t -> { // button#3
                        List<KayaApp.TextRange> hits = findAll(doc, NEEDLE);
                        if (!hits.isEmpty()) {
                            t.selectRange(editor[0], hits.get(0));
                        }
                    });
                });
            }));
        });

        app.dispatchLoop();
    }

    private Ranges() {}
}
