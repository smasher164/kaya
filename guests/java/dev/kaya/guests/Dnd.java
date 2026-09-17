package dev.kaya.guests;

import dev.kaya.KayaApp;
import dev.kaya.KayaGen;

import java.io.IOException;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.ArrayList;
import java.util.List;
import java.util.function.BiConsumer;

/**
 * The drag-and-drop scene from the JVM — guests/rust/dnd.rs,
 * tools/scenes/dnd.steps. THE ROOT IS A ROW so column#0 is the
 * reorderable For's container.
 */
public final class Dnd {
    @KayaGen(key = "String")
    record DndItem(String title) {}

    /** Java lambdas cannot assign captured locals. */
    /** The TRACE's own slots: a For's body runs once where the compiler
     * cannot see it, and the template zone is outside the ruling. */
    private static final class Refs {
        KayaApp.Node rowNode, itemNode;
    }

    /** What the row body declared, on its way out to the handlers. */
    private record Targets(KayaApp.Widget source, KayaApp.Widget text,
            KayaApp.Widget note, KayaApp.Widget files, KayaApp.Widget rows) {}

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

    private static String keyWord(List<Object> keys) {
        return keys.isEmpty() ? "" : String.valueOf(keys.get(0));
    }

    // The file the scene drops as a FOREIGN source (D6), written by the
    // guest at $TMP/kaya-dnd-$PID/dropped.txt — the picker and clipboard
    // scenes' convention, and the same place the interpreters expand $TMP
    // to. TMPDIR FIRST: java.io.tmpdir ignores it on macOS
    // (docs/traps.md, "java.io.tmpdir").
    private static void writeDroppedFile() {
        String tmp = System.getenv("TMPDIR");
        if (tmp == null || tmp.isEmpty()) {
            tmp = System.getProperty("java.io.tmpdir");
        }
        if (System.getProperty("java.specification.vendor", "")
                .contains("Android")) {
            String ext = System.getenv("EXTERNAL_STORAGE");
            tmp = (ext == null || ext.isEmpty() ? "/sdcard" : ext) + "/Documents";
        }
        try {
            Path dir = Paths.get(tmp, "kaya-dnd-" + pid());
            Files.createDirectories(dir);
            Files.write(dir.resolve("dropped.txt"),
                    "dropped bytes".getBytes(StandardCharsets.UTF_8));
        } catch (IOException e) {
            throw new RuntimeException(e);
        }
    }

    /** This process's id, without NAMING {@code ProcessHandle}: the Android
     * SDK has no such class, so naming it is a compile error there. */
    private static long pid() {
        try {
            return Long.parseLong(
                    new java.io.File("/proc/self").getCanonicalFile().getName());
        } catch (Exception noProc) {
            // macOS and Windows have no /proc; ask the JDK.
            try {
                Class<?> handle = Class.forName("java.lang.ProcessHandle");
                Object current = handle.getMethod("current").invoke(null);
                return (Long) handle.getMethod("pid").invoke(current);
            } catch (Exception e) {
                throw new IllegalStateException(
                        "kaya: cannot determine this process's id", e);
            }
        }
    }

    private static String readBack(KayaApp.PickedFile file) {
        try (InputStream in = file.open(KayaApp.FileMode.READ).stream()) {
            return new String(in.readAllBytes(), StandardCharsets.UTF_8);
        } catch (IOException e) {
            return "open failed: " + e.getMessage();
        }
    }

    public static void app() {
        writeDroppedFile();
        KayaApp app = new KayaApp();

        app.build(tx -> {
            var items = DndItemKaya.collection(tx);
            var items2 = DndItemKaya.collection(tx);
            var dropStatus = tx.signal("no drop yet");
            var dragStatus = tx.signal("no drag yet");
            var sourceText = tx.signal("hello");
            var textTarget = tx.signal("text target");
            var noteTarget = tx.signal("note target");
            var filesTarget = tx.signal("files target");

            Refs refs = new Refs();
            tx.window(0).title("dnd");
            var built = tx.row(cells -> {
                // The For opens when rows() is called, so it is minted
                // INSIDE the row: a window prop emitted between the open
                // and the template's end is refused by the core.
                var rows = DndItemKaya.rows(tx, items);
                for (var row : rows) {
                    refs.rowNode = row.label(row.title);
                    row.setA11yId(refs.rowNode, "row");
                }
                KayaApp.Widget rowsWidget = rows.handle;
                tx.setA11yId(rowsWidget, "rows");
                var targets = tx.column(col -> {
                    KayaApp.Widget sourceLabel = tx.label(sourceText); // label#0
                    KayaApp.Widget textTargetLabel = tx.label(textTarget); // label#1
                    tx.setAccepts(textTargetLabel, KayaApp.ACCEPT_TEXT);
                    tx.setDropTarget(textTargetLabel, KayaApp.Op.COPY);
                    KayaApp.Widget noteTargetLabel = tx.label(noteTarget); // label#2
                    tx.setAccepts(noteTargetLabel, NOTE_ID);
                    tx.setDropTarget(noteTargetLabel, KayaApp.Op.COPY, KayaApp.Op.MOVE);
                    KayaApp.Widget filesTargetLabel = tx.label(filesTarget); // label#3
                    tx.setAccepts(filesTargetLabel, KayaApp.ACCEPT_FILES);
                    tx.setDropTarget(filesTargetLabel, KayaApp.Op.COPY);
                    tx.label(dropStatus); // label#4
                    tx.label(dragStatus); // label#5
                    return new Targets(sourceLabel, textTargetLabel, noteTargetLabel,
                            filesTargetLabel, rowsWidget);
                }).value();
                // THE TEMPLATE ZONE (docs/dnd-plan.md §4): every stamped
                // item is a text destination, and its payload IS the
                // row's own field — resolved per copy, re-declared when
                // the field changes — column#2.
                var itemRows = DndItemKaya.rows(tx, items2);
                for (var row : itemRows) {
                    refs.itemNode = row.label(row.title);
                    row.setA11yId(refs.itemNode, "item");
                    row.setAccepts(refs.itemNode, KayaApp.ACCEPT_TEXT);
                    row.setDropTarget(refs.itemNode, KayaApp.Op.COPY);
                    row.draggable(refs.itemNode).text(row.title).allow(KayaApp.Op.COPY).declare();
                }
                tx.setA11yId(itemRows.handle, "items");
                tx.button("rename y", t -> // button#0
                        items2.update(t, "y", new DndItem("yy")));
                return targets;
            });
            tx.mount(built.id());
            Targets targets = built.value();
            KayaApp.Widget source = targets.source();
            tx.draggable(source)
                    .text("hello")
                    .custom(NOTE_ID, "note!".getBytes(StandardCharsets.UTF_8))
                    .allow(KayaApp.Op.COPY)
                    .allow(KayaApp.Op.MOVE)
                    .declare();
            tx.setReorderable(targets.rows(), true);

            app.onDrop(targets.text(), dropped(app, "text target", textTarget, dropStatus,
                    sourceText, source));
            app.onDrop(targets.note(), dropped(app, "note target", noteTarget, dropStatus,
                    sourceText, source));
            app.onDrop(targets.files(), dropped(app, "files target", filesTarget, dropStatus,
                    sourceText, source));
            app.onDragEnded(source, (t, op) ->
                    t.write(dragStatus, "drag ended " + word(op)));
            app.onDrop(refs.itemNode, (t, keys, d) -> {
                String op = word(d.operation());
                if (d.clip() instanceof KayaApp.Representation.Text text) {
                    t.write(dropStatus, "item " + keyWord(keys) + " got text "
                            + text.value() + " (" + op + ")");
                } else {
                    t.write(dropStatus, "item " + keyWord(keys) + " got other ("
                            + op + ")");
                }
            });
            app.onDragEnded(refs.itemNode, nodeEnded("item", dragStatus));
            app.onDragEnded(refs.rowNode, nodeEnded("row", dragStatus));
            // The moved row's key rides as the kaya-private custom
            // representation; the anchor is the row it landed on (D8).
            app.onDrop(targets.rows(), (t, d) -> {
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
            for (String key : new String[] {"x", "y"}) {
                items2.insert(tx, key, new DndItem(key));
            }
            return null;
        });

        app.dispatchLoop();
    }

    private static KayaApp.DragEndedHandler nodeEnded(
            String what, KayaApp.Signal<String> dragStatus) {
        return (t, keys, op) -> t.write(dragStatus,
                what + " " + keyWord(keys) + " drag ended " + word(op));
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
            } else if (d.clip() instanceof KayaApp.Representation.Files files) {
                // A dropped file IS a picked file (D6): read it back
                // through the same table the picker fills.
                List<String> said = new ArrayList<>();
                for (KayaApp.PickedFile f : files.value()) {
                    said.add(f.name() + " " + readBack(f));
                }
                t.write(dropStatus, name + " got " + String.join(", ", said)
                        + " (" + op + ")");
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
