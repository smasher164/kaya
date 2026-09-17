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
    /** Java lambdas cannot assign captured locals. */
    /** A SELF-REFERENCE, not a smuggle: the textarea's own onEdit reads
     * the document of the widget being declared. */
    private static final class Refs {
        KayaApp.Widget editor;
    }

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
            parts.add(run.isFlag()
                    ? run.range().start + ":" + run.range().stop + " " + run.name()
                    : run.range().start + ":" + run.range().stop + " " + run.name() + "=" + run.value());
        }
        return String.join("|", parts);
    }

    public static void app() {
        KayaApp app = new KayaApp();

        app.build(tx -> {
            tx.window(0).title("richtext");
            KayaApp.Signal<String> last = tx.signal("");
            KayaApp.Signal<String> runs = tx.signal("");

            Refs refs = new Refs();
            tx.mount(tx.column(col -> {
                refs.editor = tx.textarea().rich().a11yId("doc").a11yLabel("Document");
                app.onEdit(refs.editor, (t, edit) -> {
                    String source = edit.source() == null ? "?" : edit.source().toString();
                    t.write(last, "edit " + edit.range().start + ":" + edit.range().stop + " <"
                            + edit.inserted() + "> " + source + " ["
                            + spell(edit.runs()) + "]");
                    t.write(runs, spell(app.document(refs.editor).runs()));
                });
                app.onFormat(refs.editor, (t, act) -> {
                    t.write(last, "format " + act.range().start + ":" + act.range().stop + " "
                            + act.name() + "=" + (act.value() == null ? "off" : act.value()));
                    t.write(runs, spell(app.document(refs.editor).runs()));
                });

                tx.label(last); // label#0
                tx.label(runs); // label#1

                tx.row(row -> {
                    tx.button("seed", t -> { // button#0
                        KayaApp.Document doc = new KayaApp.Document(DOC)
                                .bold(KayaApp.TextRange.in(DOC, 0, 5))
                                .link(KayaApp.TextRange.in(DOC, 6, 11), URL)
                                .block(KayaApp.TextRange.in(DOC, 12, 23),
                                        KayaApp.Block.HEADING2);
                        t.setDocument(refs.editor, doc);
                        t.write(runs, spell(doc.runs()));
                    });
                    tx.button("insert", t -> { // button#1
                        KayaApp.Edit edit =
                                KayaApp.Edit.insert(KayaApp.TextRange.in(DOC, 5, 5), ", big")
                                        .mark(KayaApp.TextRange.in(", big", 2, 5), "italic",
                                                true);
                        t.applyEdit(refs.editor, edit);
                        t.write(runs, spell(app.document(refs.editor).runs()));
                    });
                    tx.button("select word", t -> // button#2
                            t.selectRange(refs.editor, KayaApp.TextRange.in(DOC, 0, 5)));
                    tx.button("unbold", t -> t.unformat(refs.editor, "bold")); // button#3
                    tx.button("heading", t -> // button#4
                            t.setBlock(refs.editor, KayaApp.Block.HEADING1));
                    tx.button("focus", t -> t.focus(refs.editor)); // button#5
                    tx.button("prefix", t -> { // button#6
                        t.applyEdit(refs.editor,
                                KayaApp.Edit.insert(KayaApp.TextRange.in(DOC, 0, 0), "> "));
                        t.write(runs, spell(app.document(refs.editor).runs()));
                    });
                });
            }));
        });

        app.dispatchLoop();
    }

    private RichText() {}
}
