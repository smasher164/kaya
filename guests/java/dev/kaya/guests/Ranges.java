package dev.kaya.guests;

import dev.kaya.KayaApp;

import java.util.ArrayList;
import java.util.List;

/**
 * The ranges scene from the JVM — guests/rust/ranges.rs,
 * tools/scenes/ranges.steps.
 */
public final class Ranges {
    /** The document, frozen. THE CJK WORD IS IN {@code \}{@code u} ESCAPES: a
     * literal's bytes follow the compiler's encoding, and the Android build
     * that also compiles this directory passes no {@code -encoding}. */
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

    private static String doc = DOC;

    /** The whole search: literal, forward, non-overlapping. */
    private static List<KayaApp.TextRange> findAll(String text, String needle) {
        List<KayaApp.TextRange> hits = new ArrayList<>();
        for (int at = text.indexOf(needle); at >= 0;
                at = text.indexOf(needle, at + needle.length())) {
            // Java's UTF-16 index in, kaya's byte offsets out.
            hits.add(KayaApp.TextRange.in(text, at, at + needle.length()));
        }
        return hits;
    }

    public static void app() {
        KayaApp app = new KayaApp();

        app.build(tx -> {
            tx.window(0).title("ranges");
            KayaApp.Signal<String> status = tx.signal("0 matches");

            // Java lambdas cannot assign captured locals.
            KayaApp.Widget[] editor = new KayaApp.Widget[1];
            tx.mount(tx.column(() -> {
                // Every range assertion finds this control by its authored id.
                editor[0] = tx.textarea().a11yId("doc").a11yLabel("Document"); // textarea#0
                tx.setText(editor[0], DOC);
                app.onChange(editor[0], (t, text) -> {
                    doc = text;
                    // A declared set is bound to the text it was declared against.
                    t.write(status, "0 matches");
                });
                tx.label(status); // label#0
                tx.row(() -> {
                    tx.button("find", t -> { // button#0
                        List<KayaApp.TextRange> hits = findAll(doc, NEEDLE);
                        t.highlightRanges(editor[0], hits);
                        // The SECOND match, so a leg can tell the selection apart
                        // from "the first thing found".
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
