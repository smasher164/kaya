package dev.kaya.guests;

import dev.kaya.KayaApp;
import dev.kaya.KayaGen;
import dev.kaya.KayaRecords;

import java.util.List;
import java.util.function.BiConsumer;

/**
 * The row menu scene from the JVM — guests/rust/rowmenu.rs,
 * tools/scenes/rowmenu.steps (docs/media-player-plan.md M26).
 */
public final class Rowmenu {
    @KayaGen(key = "String")
    record RowmenuEntry(String title, String mark) {}

    public static void app() {
        KayaApp app = new KayaApp();

        app.build(tx -> {
            tx.window(0).title("rowmenu");
            KayaApp.Signal<String> status = tx.signal("ready");
            var notes = RowmenuEntryKaya.collection(tx);
            var files = RowmenuEntryKaya.collection(tx);
            KayaApp.ContextCatalog noteMenu = tx.contextCatalog();
            KayaApp.MenuItem star = noteMenu.item("Star")
                    .onActivateNode(toggle(notes, status, "Star", "Unstar", "starred", "unstarred"));
            noteMenu.separator();
            noteMenu.item("Open").onActivateNode((t, keys) -> t.write(status, "opened " + keys.get(0)));
            KayaApp.ContextCatalog fileMenu = tx.contextCatalog();
            KayaApp.MenuItem pin = fileMenu.item("Pin")
                    .onActivateNode(toggle(files, status, "Pin", "Unpin", "pinned", "unpinned"));
            fileMenu.separator();
            fileMenu.item("Open").onActivateNode((t, keys) -> t.write(status, "opened " + keys.get(0)));

            tx.mount(tx.column(col -> {
                tx.label(status);
                for (var note : RowmenuEntryKaya.rows(tx, notes)) {
                    KayaApp.Node line = note.row(() -> note.label(note.title));
                    note.setA11yId(line, "note");
                    note.contextMenu(line, noteMenu);
                    note.contextLabel(line, star, note.mark);
                }
                var rows = RowmenuEntryKaya.rows(tx, files);
                for (var file : rows) {
                    KayaApp.Node line = file.row(() -> file.label(file.title));
                    file.setA11yId(line, "file");
                    file.contextMenu(line, fileMenu);
                    file.contextLabel(line, pin, file.mark);
                }
                tx.setGrow(rows.handle, 1);
                rows.columns(new String[] { "Name" }, KayaApp.Sort.none());
            }));
            String[][] noteSeeds = { { "a", "apples", "Star" }, { "b", "bread", "Unstar" } };
            for (String[] seed : noteSeeds) {
                notes.insert(tx, seed[0], new RowmenuEntry(seed[1], seed[2]));
            }
            String[][] fileSeeds = { { "x", "x.txt", "Pin" }, { "y", "y.txt", "Unpin" } };
            for (String[] seed : fileSeeds) {
                files.insert(tx, seed[0], new RowmenuEntry(seed[1], seed[2]));
            }
            return null;
        });

        app.dispatchLoop();
    }

    private static BiConsumer<KayaApp.Tx, List<Object>> toggle(
            KayaRecords.Collection<String, RowmenuEntry> c, KayaApp.Signal<String> status,
            String on, String off, String did, String undid) {
        return (t, keys) -> {
            String key = (String) keys.get(0);
            RowmenuEntry entry = c.get(t, key);
            boolean set = entry != null && entry.mark().equals(on);
            RowmenuEntryKaya.patch(t, c, key).mark(set ? off : on);
            t.write(status, (set ? did : undid) + " " + key);
        };
    }

    private Rowmenu() {}
}
