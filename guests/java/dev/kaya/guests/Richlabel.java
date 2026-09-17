package dev.kaya.guests;

import dev.kaya.KayaApp;

import java.util.ArrayList;
import java.util.List;

/**
 * The rich label scene from the JVM — guests/rust/richlabel.rs,
 * tools/scenes/richlabel.steps (docs/rich-text-plan.md R8, §15): a label
 * carries the inline vocabulary read-only. THE OFFSETS ARE UTF-8 BYTES;
 * the accented first word is what makes a UTF-16 reader fail
 * (docs/ranges-units.md), so every range here goes through TextRange.in,
 * which converts against the text it indexes.
 */
public final class Richlabel {
    /** Java lambdas cannot assign captured locals. */
    private static final class Refs {
        KayaApp.Widget body, heading;
    }

    /** THE ACCENT IS IN A {@code \}{@code u} ESCAPE: a literal's bytes
     * follow the compiler's encoding, and the Android build that also
     * compiles this directory passes no {@code -encoding}
     * (android/javahost/build.gradle.kts). */
    private static final String DOC = "H\u00e9llo world, code";

    private static final String TITLE = "Heading with italic";

    private static final String URL = "https://kaya.dev";

    /** The core's spelling of runs ({@code expect_runs}), so the
     * binding's document and the core's mirror are compared as one
     * string. */
    private static String spell(List<KayaApp.TextRun> runs) {
        List<String> parts = new ArrayList<>();
        for (KayaApp.TextRun run : runs) {
            parts.add(run.value().equals("true")
                    ? run.start() + ":" + run.stop() + " " + run.name()
                    : run.start() + ":" + run.stop() + " " + run.name() + "=" + run.value());
        }
        return String.join("|", parts);
    }

    public static void app() {
        KayaApp app = new KayaApp();

        app.build(tx -> {
            tx.window(0).title("richlabel");
            KayaApp.Signal<String> runs = tx.signal("");

            Refs refs = new Refs();
            tx.mount(tx.column(() -> {
                KayaApp.Signal<String> bodyText = tx.signal("");
                KayaApp.Signal<String> headingText = tx.signal(TITLE);

                refs.body = tx.label(bodyText).rich().a11yId("body"); // label#0
                refs.heading = tx.label(headingText).role(KayaApp.Role.HEADING)
                        .rich().a11yId("heading"); // label#1
                tx.label(runs).a11yId("runs"); // label#2

                tx.row(() -> {
                    tx.button("seed", t -> { // button#0
                        KayaApp.Document doc = new KayaApp.Document(DOC)
                                .bold(KayaApp.TextRange.in(DOC, 0, 5))
                                .link(KayaApp.TextRange.in(DOC, 6, 11), URL)
                                .mark(KayaApp.TextRange.in(DOC, 13, 17), "code", "true");
                        KayaApp.Document title = new KayaApp.Document(TITLE)
                                .mark(KayaApp.TextRange.in(TITLE, 13, 19), "italic",
                                        "true");
                        t.setDocument(refs.body, doc);
                        t.setDocument(refs.heading, title);
                        t.write(runs, spell(doc.runs()));
                    });
                    tx.button("insert", t -> { // button#1
                        KayaApp.Edit edit =
                                KayaApp.Edit.insert(KayaApp.TextRange.in(DOC, 5, 5), ", big")
                                        .mark(KayaApp.TextRange.in(", big", 2, 5), "italic",
                                                "true");
                        t.applyEdit(refs.body, edit);
                        t.write(runs, spell(app.document(refs.body).runs()));
                    });
                    // THE RANGED ACT ON A LABEL (docs/rich-text-plan.md §17):
                    // the label's own document written by range, no selection
                    // to move; the ranges convert against the CURRENT text,
                    // which the insert moved.
                    tx.button("mark", t -> { // button#2
                        String text = app.document(refs.body).text();
                        t.formatRange(refs.body, KayaApp.TextRange.in(text, 1, 3), "italic",
                                "true");
                        t.unformatRange(refs.body, KayaApp.TextRange.in(text, 0, 2), "bold");
                        t.write(runs, spell(app.document(refs.body).runs()));
                    });
                });
            }));
        });

        app.dispatchLoop();
    }

    private Richlabel() {}
}
