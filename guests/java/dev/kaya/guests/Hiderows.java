package dev.kaya.guests;

import dev.kaya.KayaApp;
import dev.kaya.KayaGen;

/**
 * The hidden-rows scene from the JVM — guests/rust/hiderows.rs,
 * tools/scenes/hiderows.steps (docs/hidden-plan.md).
 */
public final class Hiderows {
    @KayaGen(key = "String")
    record HiderowsNote(String title, boolean unmatched) {}

    @KayaGen(key = "String")
    record HiderowsFile(String name, String size, boolean unmatched) {}

    /** Java lambdas cannot assign captured locals. */
    private static final class Refs {
        KayaApp.Widget draft;
    }

    private static final String[] NOTES = { "alpha", "beta", "gamma" };

    private static String fileName(int i) {
        return String.format("file %03d", i);
    }

    public static void app() {
        KayaApp app = new KayaApp();

        app.build(tx -> {
            tx.window(0).title("hiderows").size(480, 760);
            var notes = HiderowsNoteKaya.collection(tx);
            var files = HiderowsFileKaya.collection(tx);
            KayaApp.Signal<Boolean> two = tx.signal(false);
            KayaApp.Signal<Boolean> pane = tx.signal(false);
            Refs refs = new Refs();

            tx.mount(tx.column(col -> {
                tx.search((t, query) -> {
                    for (String title : NOTES) {
                        HiderowsNoteKaya.patch(t, notes, title).unmatched(!title.contains(query));
                    }
                }).placeholder("Find notes").a11yId("find_notes");
                var list = HiderowsNoteKaya.rows(tx, notes);
                for (var note : list) {
                    KayaApp.Node line = note.row(() -> {
                        note.label(note.title);
                        note.setA11yId(note.entry(), "note");
                    });
                    note.setHidden(line, note.unmatched);
                }
                tx.setA11yId(list.handle, "notes");
                tx.grid(2, tiles -> {
                    tx.label("one");
                    tx.label("two").hidden(two);
                    tx.label("three");
                }).a11yId("tiles");
                tx.column(hideable -> {
                    tx.scroll(strip -> {
                        tx.row(cards -> {
                            for (int i = 1; i <= 20; i++) {
                                KayaApp.Signal<String> caption = tx.signal("card " + i);
                                tx.label(caption);
                            }
                        });
                    }).axis(KayaApp.Axis.HORIZONTAL).a11yId("strip");
                    refs.draft = tx.textarea().a11yId("draft").a11yLabel("Draft");
                }).hidden(pane);
                tx.row(controls -> {
                    tx.checkbox("Hide two", (t, on) -> t.write(two, on)).a11yId("hide_two");
                    tx.checkbox("Hide pane", (t, on) -> t.write(pane, on)).a11yId("hide_pane");
                });
                tx.button("select first", t -> {
                    t.focus(refs.draft);
                    t.selectRange(refs.draft, KayaApp.TextRange.ofBytes(0, 5));
                }).a11yId("select_first");
                tx.search((t, query) -> {
                    for (int i = 0; i < 300; i++) {
                        HiderowsFileKaya.patch(t, files, fileName(i)).unmatched(!fileName(i).contains(query));
                    }
                }).placeholder("Find files").a11yId("find_files");
                var table = HiderowsFileKaya.rows(tx, files);
                for (var file : table) {
                    KayaApp.Node line = file.row(() -> {
                        file.label(file.name);
                        file.label(file.size);
                    });
                    file.setHidden(line, file.unmatched);
                }
                tx.setA11yId(table.handle, "files");
                tx.setGrow(table.handle, 1);
                table.columns(new String[] { "Name", "Size" }, KayaApp.Sort.none());
            }));
            for (String title : NOTES) {
                notes.insert(tx, title, new HiderowsNote(title, false));
            }
            for (int i = 0; i < 300; i++) {
                files.insert(tx, fileName(i), new HiderowsFile(fileName(i), i + " KB", false));
            }
            return null;
        });

        app.dispatchLoop();
    }

    private Hiderows() {}
}
