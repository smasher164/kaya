package dev.kaya.guests;

import dev.kaya.KayaApp;

import java.util.ArrayList;
import java.util.List;

/**
 * The rich text scene from the JVM — guests/rust/richtext.rs,
 * tools/scenes/richtext.steps. THE OFFSETS ARE UTF-8 BYTES; the
 * accented first word is what makes a UTF-16 reader fail
 * (docs/ranges-units.md), so every range here goes through
 * TextRange.in, which converts against the text it indexes.
 */
public final class RichText {
    /** THE ACCENT IS IN A {@code \}{@code u} ESCAPE: a literal's bytes
     * follow the compiler's encoding, and the Android build that also
     * compiles this directory passes no {@code -encoding}
     * (android/javahost/build.gradle.kts). */
    private static final String DOC = "H\u00e9llo world\nSecond line";

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
            tx.window(0).title("richtext");
            KayaApp.Signal<String> last = tx.signal("");
            KayaApp.Signal<String> runs = tx.signal("");

            // Java lambdas cannot assign captured locals.
            KayaApp.Widget[] editor = new KayaApp.Widget[1];
            tx.mount(tx.column(() -> {
                editor[0] = tx.textarea().rich().a11yId("doc").a11yLabel("Document");
                app.onEdit(editor[0], (t, edit) -> {
                    t.write(last, "edit " + edit.start() + ":" + edit.stop() + " <"
                            + edit.inserted() + "> [" + spell(edit.runs()) + "]");
                    t.write(runs, spell(app.document(editor[0]).runs()));
                });
                app.onFormat(editor[0], (t, act) -> {
                    t.write(last, "format " + act.start() + ":" + act.stop() + " "
                            + act.name() + "=" + (act.value() == null ? "off" : act.value()));
                    t.write(runs, spell(app.document(editor[0]).runs()));
                });

                tx.label(last); // label#0
                tx.label(runs); // label#1

                tx.row(() -> {
                    tx.button("seed", t -> { // button#0
                        KayaApp.Document doc = new KayaApp.Document(DOC)
                                .bold(KayaApp.TextRange.in(DOC, 0, 5))
                                .link(KayaApp.TextRange.in(DOC, 6, 11), URL)
                                .block(KayaApp.TextRange.in(DOC, 12, 23),
                                        KayaApp.Block.HEADING2);
                        t.setDocument(editor[0], doc);
                        t.write(runs, spell(doc.runs()));
                    });
                    tx.button("insert", t -> { // button#1
                        KayaApp.Edit edit =
                                KayaApp.Edit.insert(KayaApp.TextRange.in(DOC, 5, 5), ", big")
                                        .mark(KayaApp.TextRange.in(", big", 2, 5), "italic",
                                                "true");
                        t.applyEdit(editor[0], edit);
                        t.write(runs, spell(app.document(editor[0]).runs()));
                    });
                    tx.button("select word", t -> // button#2
                            t.selectRange(editor[0], KayaApp.TextRange.in(DOC, 0, 5)));
                    tx.button("unbold", t -> t.unformat(editor[0], "bold")); // button#3
                    tx.button("heading", t -> // button#4
                            t.setBlock(editor[0], KayaApp.Block.HEADING1));
                    tx.button("focus", t -> t.focus(editor[0])); // button#5
                    tx.button("prefix", t -> { // button#6
                        t.applyEdit(editor[0],
                                KayaApp.Edit.insert(KayaApp.TextRange.in(DOC, 0, 0), "> "));
                        t.write(runs, spell(app.document(editor[0]).runs()));
                    });
                });
            }));
        });

        app.dispatchLoop();
    }

    private RichText() {}
}
