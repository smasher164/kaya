package dev.kaya.guests;

import dev.kaya.KayaApp;
import dev.kaya.KayaGen;
import dev.kaya.KayaRecords;

import java.util.ArrayList;
import java.util.List;

/**
 * The rich rows scene from the JVM — guests/rust/richrows.rs,
 * tools/scenes/richrows.steps: a rich textarea per stamped ROW whose
 * document is a FIELD of the row (docs/rich-text-plan.md §19). The app
 * writes a copy's document by patching its row, and a copy's own act
 * folds into the row the app reads back.
 */
public final class Richrows {
    @KayaGen(key = "String")
    record Note(String title, KayaApp.Document body) {}

    /** THE ACCENT IS IN A {@code \}{@code u} ESCAPE: a literal's bytes
     * follow the compiler's encoding, and the Android build that also
     * compiles this directory passes no {@code -encoding}
     * (android/javahost/build.gradle.kts). */
    private static final String FIRST = "H\u00e9llo world";

    /** The core's spelling of runs ({@code expect_runs}), so the row's
     * field and the core's mirror are compared as one string. */
    private static String spell(List<KayaApp.TextRun> runs) {
        List<String> parts = new ArrayList<>();
        for (KayaApp.TextRun run : runs) {
            parts.add(run.value().equals("true")
                    ? run.start() + ":" + run.stop() + " " + run.name()
                    : run.start() + ":" + run.stop() + " " + run.name() + "=" + run.value());
        }
        return String.join("|", parts);
    }

    private static Note row(KayaApp.Tx tx,
            KayaRecords.Collection<String, Note> notes, String key) {
        for (KayaRecords.Entry<String, Note> entry : notes.items(tx)) {
            if (entry.key.equals(key)) {
                return entry.value;
            }
        }
        throw new IllegalStateException("richrows: no row " + key);
    }

    public static void app() {
        KayaApp app = new KayaApp();

        app.build(tx -> {
            KayaApp.WindowRef win = tx.window(0).title("richrows");
            KayaApp.MenuItem editMenu = win.menu("Edit");
            editMenu.item("Undo").role(KayaApp.ROLE_UNDO);
            editMenu.item("Redo").role(KayaApp.ROLE_REDO);

            var notes = NoteKaya.collection(tx);
            KayaApp.Signal<String> last = tx.signal("");
            KayaApp.Signal<String> view = tx.signal("");

            // An undo or redo moved the row back: the app reads ITS OWN
            // mirror of row b, which is the fold a restored Blob field
            // lands in.
            KayaApp.UndoHandler restored = (t, label, delta) -> {
                Note note = row(t, notes, "b");
                t.write(view, note.body().text() + " | " + spell(note.body().runs()));
            };
            win.onUndone(restored).onRedone(restored);

            tx.mount(tx.column(() -> {
                tx.label(last); // label#0
                tx.label(view); // label#1

                tx.row(() -> {
                    tx.button("patch b", t -> { // button#0
                        t.undoable("patch b");
                        NoteKaya.patch(t, notes, "b").body(
                                new KayaApp.Document("Patched").italic(
                                        KayaApp.TextRange.ofBytes(0, 7)));
                    });
                    tx.button("read a", t -> { // button#1
                        Note note = row(t, notes, "a");
                        t.write(view, note.body().text() + " | " + spell(note.body().runs()));
                    });
                });

                for (var r : NoteKaya.rows(tx, notes)) {
                    r.column(() -> {
                        r.label(r.title);
                        KayaApp.Node body = r.textareaRich(r.body);
                        r.setA11yId(body, "body");
                        // The row's field already carries the copy's act
                        // when these fire: the app reads the row, never
                        // the widget.
                        app.onEdit(body, (t, keys, edit) -> acted(t, notes, last, keys));
                        app.onFormat(body, (t, keys, act) -> acted(t, notes, last, keys));
                    });
                }
            }));

            notes.insert(tx, "a", new Note("a",
                    new KayaApp.Document(FIRST).bold(KayaApp.TextRange.ofBytes(0, 6))));
            notes.insert(tx, "b", new Note("b",
                    new KayaApp.Document("Second note").link(
                            KayaApp.TextRange.ofBytes(7, 11), "https://kaya.dev")));
        });

        app.dispatchLoop();
    }

    private static void acted(KayaApp.Tx tx, KayaRecords.Collection<String, Note> notes,
            KayaApp.Signal<String> last, List<Object> keys) {
        Note note = row(tx, notes, (String) keys.get(0));
        tx.write(last, keys.get(0) + ": " + spell(note.body().runs()));
    }

    private Richrows() {}
}
