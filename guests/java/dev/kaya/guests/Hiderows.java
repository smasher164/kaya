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

    private static final String[] NOTES = { "alpha", "beta", "gamma" };

    private static String fileName(int i) {
        return String.format("file %03d", i);
    }

    public static void app() {
        KayaApp app = new KayaApp();

        app.build(tx -> {
            tx.window(0).title("hiderows");
            var notes = HiderowsNoteKaya.collection(tx);
            var files = HiderowsFileKaya.collection(tx);
            KayaApp.Signal<Boolean> two = tx.signal(false);

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
                tx.checkbox("Hide two", (t, on) -> t.write(two, on)).a11yId("hide_two");
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
