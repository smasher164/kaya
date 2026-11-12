package dev.kaya.guests;

import dev.kaya.KayaApp;

import java.util.ArrayList;
import java.util.List;

/**
 * The rich document scene from the JVM — guests/rust/richdoc.rs,
 * tools/scenes/richdoc.steps (docs/rich-document-plan.md §9 step 2): a
 * heading, a body paragraph with a preset colour, a bullet list with a
 * nested item, a numbered list and a checklist, then the paragraph acts from
 * buttons, the platform's colour picker and a {@code .kdoc} round trip, then
 * a file carrying keys this kaya does not know (RD17). label#1 is the
 * binding's own Document, folded from the same deltas, so it must spell what
 * the core holds.
 */
public final class Richdoc {
    /** A SELF-REFERENCE, not a smuggle: the textarea's own onEdit reads
     * the document of the widget being declared. */
    private static final class Refs {
        KayaApp.Widget editor;
    }

    /** BYTE-IDENTICAL to guests/rust/richdoc.rs's DOC. */
    private static final String DOC =
            "Groceries\nFresh from the market.\nApples\nGreen ones\nBread\nWash\nSlice\nMilk\nEggs";

    /** BYTE-IDENTICAL to guests/rust/richdoc.rs's UNKNOWN. */
    private static final String UNKNOWN =
            "{\"kaya\": \"document\", \"version\": 1, \"com.example.theme\": {\"page\": \"sepia\"}, "
            + "\"paragraphs\": [{\"embed\": \"e1\", \"spans\": [[\"Loose\"]]}, "
            + "{\"com.example.pinned\": true, \"spans\": [[\"Pinned\"]]}]}";

    private static String spell(List<KayaApp.TextRun> runs) {
        List<String> parts = new ArrayList<>();
        for (KayaApp.TextRun run : runs) {
            parts.add(run.isFlag()
                    ? run.range().start + ":" + run.range().stop + " " + run.name()
                    : run.range().start + ":" + run.range().stop + " " + run.name() + "=" + run.value());
        }
        return String.join("|", parts);
    }


    private static KayaApp.TextRange span(int start, int stop) {
        return KayaApp.TextRange.in(DOC, start, stop);
    }

    public static void app() {
        KayaApp app = new KayaApp();
        KayaApp.Document doc = new KayaApp.Document(DOC)
                .block(span(0, 9), KayaApp.Block.HEADING1)
                .color(span(25, 31), "#016FEF")
                .list(span(33, 56), KayaApp.ListKind.BULLET)
                .indent(span(40, 50), 1)
                .list(span(57, 67), KayaApp.ListKind.NUMBERED)
                .checked(span(68, 72))
                .list(span(68, 77), KayaApp.ListKind.CHECK);

        app.build(tx -> {
            KayaApp.WindowRef win = tx.window(0).title("richdoc").size(560.0, 620.0);
            KayaApp.MenuItem edit = win.menu("Edit");
            edit.item("Cut").role(KayaApp.ROLE_CUT);
            edit.item("Copy").role(KayaApp.ROLE_COPY);
            edit.item("Paste").role(KayaApp.ROLE_PASTE);

            KayaApp.Signal<String> last = tx.signal("");
            KayaApp.Signal<String> runs = tx.signal(spell(doc.runs()));
            KayaApp.Signal<String> kdoc = tx.signal("");

            Refs refs = new Refs();
            tx.mount(tx.column(col -> {
                refs.editor = tx.textarea().rich().grow(1.0).a11yId("doc").a11yLabel("Document");
                app.onEdit(refs.editor, (t, e) -> {
                    String source = e.source() == null ? "?" : e.source().toString();
                    t.write(last, "edit " + e.range().start + ":" + e.range().stop + " <"
                            + e.inserted().replace("\n", "\\n") + "> " + source + " ["
                            + spell(e.runs()) + "]");
                    t.write(runs, spell(app.document(refs.editor).runs()));
                });
                app.onFormat(refs.editor, (t, act) -> {
                    t.write(last, "format " + act.range().start + ":" + act.range().stop + " "
                            + act.name() + "=" + (act.value() == null ? "off" : act.value()));
                    t.write(runs, spell(app.document(refs.editor).runs()));
                });

                tx.label(last); // label#0
                tx.label(runs); // label#1
                tx.label(kdoc); // label#2

                tx.row(row -> {
                    tx.button("numbered", t -> t.setList(refs.editor, KayaApp.ListKind.NUMBERED)); // button#0
                    tx.button("indent", t -> t.indent(refs.editor)); // button#1
                    tx.button("red", t -> t.color(refs.editor, "#DD1F24")); // button#2
                    tx.button("colour", t -> t.pickTextColor(refs.editor)); // button#3
                    tx.button("kdoc", t -> { // button#4
                        KayaApp.Document now = app.document(refs.editor);
                        byte[] bytes = now.toKdoc();
                        KayaApp.Kdoc back = KayaApp.Document.fromKdoc(bytes);
                        String extra = back.document().extra().replace('"', '\'');
                        t.setDocument(refs.editor, back.document());
                        t.write(kdoc, "kdoc " + bytes.length + " bytes, read_only "
                                + back.readOnly().orElse("none") + ", same "
                                + back.document().equals(now) + ", extra "
                                + (extra.isEmpty() ? "none" : extra));
                        t.write(runs, spell(back.document().runs()));
                    });
                    tx.button("keys", t -> { // button#5
                        KayaApp.Kdoc file = KayaApp.Document.fromKdoc(
                                UNKNOWN.getBytes(java.nio.charset.StandardCharsets.UTF_8));
                        t.setDocument(refs.editor, file.document());
                        t.write(kdoc, "opened read_only " + file.readOnly().orElse("none") + ", extra "
                                + file.document().extra().replace('"', '\''));
                        t.write(runs, spell(file.document().runs()));
                    });
                });
            }));
            tx.setDocument(refs.editor, doc);
        });

        app.dispatchLoop();
    }

    private Richdoc() {}
}
