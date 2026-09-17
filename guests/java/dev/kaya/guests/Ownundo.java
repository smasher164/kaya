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
     * documents an undo took away. A named holder, not static fields —
     * this scene's history has no reason to outlive its one app(). */
    /** The app's OWN undo history, plus the two textareas its menu
     * items were declared before: mutable app state and a forward
     * reference, not a container body smuggling its result out. */
    private static final class State {
        KayaApp.Widget nativeArea, owned;
        final List<KayaApp.Document> undo = new ArrayList<>();
        final List<KayaApp.Document> redo = new ArrayList<>();
        KayaApp.Document current = new KayaApp.Document("");
    }

    public static void app() {
        KayaApp app = new KayaApp();

        State s = new State();

        app.build(tx -> {
            KayaApp.WindowRef win = tx.window(0).title("ownundo");
            KayaApp.MenuItem edit = win.menu("Edit");

            KayaApp.Signal<String> status = tx.signal("undo 0 redo 0");

            edit.item("Undo").role(KayaApp.ROLE_UNDO).onActivate(t -> {
                if (s.undo.isEmpty()) {
                    return;
                }
                KayaApp.Document before = s.undo.remove(s.undo.size() - 1);
                s.redo.add(s.current);
                s.current = before;
                t.setDocument(s.owned, before);
                publish(t, status, s);
            });
            edit.item("Redo").role(KayaApp.ROLE_REDO).onActivate(t -> {
                if (s.redo.isEmpty()) {
                    return;
                }
                KayaApp.Document after = s.redo.remove(s.redo.size() - 1);
                s.undo.add(s.current);
                s.current = after;
                t.setDocument(s.owned, after);
                publish(t, status, s);
            });

            tx.mount(tx.column(col -> {
                tx.label(status).a11yId("status"); // label#0
                s.nativeArea = tx.textarea().rich().a11yId("native").a11yLabel("Native");
                s.owned = tx.textarea().rich().ownUndo()
                        .a11yId("owned").a11yLabel("Owned");
                app.onEdit(s.owned, (t, e) -> {
                    s.undo.add(s.current);
                    s.current = app.document(s.owned);
                    s.redo.clear();
                    publish(t, status, s);
                });
                tx.row(row -> {
                    tx.button("focus native", t -> t.focus(s.nativeArea)); // button#0
                    tx.button("focus owned", t -> t.focus(s.owned));  // button#1
                });
            }));
        });

        app.dispatchLoop();
    }

    private static void publish(KayaApp.Tx t, KayaApp.Signal<String> status, State s) {
        t.write(status, "undo " + s.undo.size() + " redo " + s.redo.size());
        t.canUndo(s.owned, !s.undo.isEmpty());
        t.canRedo(s.owned, !s.redo.isEmpty());
    }

    private Ownundo() {}
}
