package dev.kaya.guests;

import dev.kaya.KayaApp;
import dev.kaya.KayaGen;

import java.nio.charset.StandardCharsets;
import java.util.function.BiConsumer;

/**
 * The drag-and-drop scene from the JVM — guests/rust/dnd.rs,
 * tools/scenes/dnd.steps. THE ROOT IS A ROW so column#0 is the
 * reorderable For's container.
 */
public final class Dnd {
    @KayaGen(key = "String")
    record DndItem(String title) {}

    private static final String NOTE_ID = "dev.kaya/note";

    private static String word(KayaApp.Op op) {
        if (op == KayaApp.Op.COPY) {
            return "copy";
        }
        if (op == KayaApp.Op.MOVE) {
            return "move";
        }
        return "none";
    }

    public static void app() {
        KayaApp app = new KayaApp();

        app.build(tx -> {
            var items = DndItemKaya.collection(tx);
            var dropStatus = tx.signal("no drop yet");
            var dragStatus = tx.signal("no drag yet");
            var sourceText = tx.signal("hello");
            var textTarget = tx.signal("text target");
            var noteTarget = tx.signal("note target");
            var filesTarget = tx.signal("files target");

            KayaApp.Widget[] made = new KayaApp.Widget[4];
            tx.window(0).title("dnd");
            tx.mount(tx.row(() -> {
                // The For opens when rows() is called, so it is minted
                // INSIDE the row: a window prop emitted between the open
                // and the template's end is refused by the core.
                var rows = DndItemKaya.rows(tx, items);
                for (var row : rows) {
                    row.setA11yId(row.label(row.title), "row");
                }
                made[3] = rows.handle;
                tx.column(() -> {
                    made[0] = tx.label(sourceText); // label#0
                    made[1] = tx.label(textTarget); // label#1
                    tx.setAccepts(made[1], KayaApp.ACCEPT_TEXT);
                    tx.setDropTarget(made[1], KayaApp.Op.COPY);
                    made[2] = tx.label(noteTarget); // label#2
                    tx.setAccepts(made[2], NOTE_ID);
                    tx.setDropTarget(made[2], KayaApp.Op.COPY, KayaApp.Op.MOVE);
                    var files = tx.label(filesTarget); // label#3
                    tx.setAccepts(files, KayaApp.ACCEPT_FILES);
                    tx.setDropTarget(files, KayaApp.Op.COPY);
                    tx.label(dropStatus); // label#4
                    tx.label(dragStatus); // label#5
                });
            }));
            KayaApp.Widget source = made[0];
            tx.draggable(source)
                    .text("hello")
                    .custom(NOTE_ID, "note!".getBytes(StandardCharsets.UTF_8))
                    .allow(KayaApp.Op.COPY)
                    .allow(KayaApp.Op.MOVE)
                    .declare();
            tx.setReorderable(made[3], true);

            app.onDrop(made[1], dropped(app, "text target", textTarget, dropStatus,
                    sourceText, source));
            app.onDrop(made[2], dropped(app, "note target", noteTarget, dropStatus,
                    sourceText, source));
            app.onDragEnded(source, (t, op) ->
                    t.write(dragStatus, "drag ended " + word(op)));
            // The moved row's key rides as the kaya-private custom
            // representation; the anchor is the row it landed on (D8).
            app.onDrop(made[3], (t, d) -> {
                if (!(d.clip() instanceof KayaApp.Representation.Custom moved)
                        || d.anchor().isEmpty()
                        || !(d.anchor().get(0) instanceof String anchor)) {
                    return;
                }
                String key = new String(moved.bytes(), StandardCharsets.UTF_8);
                if (d.before()) {
                    items.moveBefore(t, key, anchor);
                } else {
                    items.moveAfter(t, key, anchor);
                }
            });

            for (String key : new String[] {"a", "b", "c"}) {
                items.insert(tx, key, new DndItem(key));
            }
            return null;
        });

        app.dispatchLoop();
    }

    private static BiConsumer<KayaApp.Tx, KayaApp.Dropped> dropped(
            KayaApp app, String name, KayaApp.Signal<String> target,
            KayaApp.Signal<String> dropStatus, KayaApp.Signal<String> sourceText,
            KayaApp.Widget source) {
        return (t, d) -> {
            String op = word(d.operation());
            if (d.clip() instanceof KayaApp.Representation.Text text) {
                t.write(dropStatus, name + " got text " + text.value() + " (" + op + ")");
                t.write(target, text.value());
            } else if (d.clip() instanceof KayaApp.Representation.Custom custom) {
                t.write(dropStatus, name + " got " + custom.id() + " "
                        + custom.bytes().length + " bytes (" + op + ")");
            } else {
                t.write(dropStatus, name + " got other (" + op + ")");
            }
            // A same-app MOVE removes its original in the same batch (D2).
            if (d.operation() == KayaApp.Op.MOVE) {
                t.write(sourceText, "moved out");
                t.draggable(source).declare();
            }
        };
    }

    private Dnd() {}
}
