package dev.kaya.guests;

import dev.kaya.KayaApp;

import java.util.ArrayList;
import java.util.List;

/**
 * The app-owned undo scene from the JVM — guests/rust/ownundo.rs,
 * tools/scenes/ownundo.steps (docs/rich-text-plan.md R6, §14).
 */
public final class Ownundo {
    /** The app's own history: the document before each user edit, and the
     * documents an undo took away. Static because a Java lambda cannot
     * assign a captured local. */
    private static final List<KayaApp.Document> UNDO = new ArrayList<>();

    private static final List<KayaApp.Document> REDO = new ArrayList<>();

    private static KayaApp.Document current = new KayaApp.Document("");

    public static void app() {
        KayaApp app = new KayaApp();

        KayaApp.Widget[] widgets = new KayaApp.Widget[2];

        app.build(tx -> {
            KayaApp.WindowRef win = tx.window(0).title("ownundo");
            KayaApp.MenuItem edit = win.menu("Edit");

            KayaApp.Signal<String> status = tx.signal("undo 0 redo 0");

            edit.item("Undo").role(KayaApp.ROLE_UNDO).onActivate(t -> {
                if (UNDO.isEmpty()) {
                    return;
                }
                KayaApp.Document before = UNDO.remove(UNDO.size() - 1);
                REDO.add(current);
                current = before;
                t.setDocument(widgets[1], before);
                publish(t, status, widgets[1]);
            });
            edit.item("Redo").role(KayaApp.ROLE_REDO).onActivate(t -> {
                if (REDO.isEmpty()) {
                    return;
                }
                KayaApp.Document after = REDO.remove(REDO.size() - 1);
                UNDO.add(current);
                current = after;
                t.setDocument(widgets[1], after);
                publish(t, status, widgets[1]);
            });

            tx.mount(tx.column(() -> {
                tx.label(status).a11yId("status"); // label#0
                widgets[0] = tx.textarea().rich().a11yId("native").a11yLabel("Native");
                widgets[1] = tx.textarea().rich().ownUndo()
                        .a11yId("owned").a11yLabel("Owned");
                app.onEdit(widgets[1], (t, e) -> {
                    UNDO.add(current);
                    current = app.document(widgets[1]);
                    REDO.clear();
                    publish(t, status, widgets[1]);
                });
                tx.row(() -> {
                    tx.button("focus native", t -> t.focus(widgets[0])); // button#0
                    tx.button("focus owned", t -> t.focus(widgets[1]));  // button#1
                });
            }));
        });

        app.dispatchLoop();
    }

    private static void publish(KayaApp.Tx t, KayaApp.Signal<String> status,
            KayaApp.Widget owned) {
        t.write(status, "undo " + UNDO.size() + " redo " + REDO.size());
        t.canUndo(owned, !UNDO.isEmpty());
        t.canRedo(owned, !REDO.isEmpty());
    }

    private Ownundo() {}
}
