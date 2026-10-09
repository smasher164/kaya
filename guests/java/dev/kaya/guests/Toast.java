package dev.kaya.guests;

import dev.kaya.KayaApp;
import dev.kaya.KayaGen;
import dev.kaya.KayaRecords;

/**
 * The toast scene from the JVM — guests/rust/toast.rs,
 * tools/scenes/toast.steps, docs/toast-plan.md §5.
 */
public final class Toast {
    @KayaGen(key = "String")
    record ToastItem(String title) {}

    private static int answers;
    private static int undos;
    private static long held;

    private static String titles(KayaApp.Tx tx,
            KayaRecords.Collection<String, ToastItem> items) {
        StringBuilder all = new StringBuilder();
        for (KayaRecords.Entry<String, ToastItem> entry : items.items(tx)) {
            if (all.length() > 0) {
                all.append(", ");
            }
            all.append(entry.value.title());
        }
        return all.length() == 0 ? "empty" : all.toString();
    }

    public static void app() {
        KayaApp app = new KayaApp();

        app.build(tx -> {
            KayaApp.WindowRef win = tx.window(0).title("toast");
            KayaApp.MenuItem edit = win.menu("Edit");
            edit.item("Undo").role(KayaApp.ROLE_UNDO);
            edit.item("Redo").role(KayaApp.ROLE_REDO);

            KayaApp.Signal<String> last = tx.signal("no answer yet");
            KayaApp.Signal<String> count = tx.signal("answers 0");
            KayaApp.Signal<String> undone = tx.signal("nothing undone");
            KayaApp.Signal<String> rows = tx.signal("Milk, Eggs, Bread");
            var items = ToastItemKaya.collection(tx);

            win.onUndone((t, label, delta) -> {
                undos++;
                t.write(undone, "undone " + undos + ": " + label);
                t.write(rows, titles(t, items));
            });

            tx.mount(tx.column(col -> {
                tx.label(last); // label#0
                tx.label(count); // label#1
                tx.label(undone); // label#2
                tx.label(rows); // label#3
                tx.button("show", t -> t.showToast("Saved")
                        .onResult((r, o) -> answer(r, last, count, "Saved", o)).show());
                tx.button("first", t -> t.showToast("First").action("Open")
                        .onResult((r, o) -> answer(r, last, count, "First", o)).show());
                tx.button("second", t -> t.showToast("Second").action("Open")
                        .onResult((r, o) -> answer(r, last, count, "Second", o)).show());
                tx.button("delete", t -> {
                    var all = items.items(t);
                    if (all.isEmpty()) {
                        return;
                    }
                    KayaRecords.Entry<String, ToastItem> first = all.get(0);
                    t.undoable("delete " + first.value.title());
                    t.remove(items.handle, first.key);
                    t.write(rows, titles(t, items));
                    String text = "Deleted " + first.value.title();
                    t.showToast(text).action("Undo").undo()
                            .onResult((r, o) -> answer(r, last, count, text, o)).show();
                });
                tx.button("hold", t -> held = t.showToast("Working")
                        .duration(KayaApp.ToastDuration.LONG)
                        .onResult((r, o) -> answer(r, last, count, "Working", o)).show());
                tx.button("dismiss", t -> {
                    if (held != 0) {
                        t.dismissToast(held);
                        held = 0;
                    }
                });
                for (var row : ToastItemKaya.rows(tx, items)) {
                    row.row(() -> row.label(row.title));
                }
            }));

            for (String title : new String[] {"Milk", "Eggs", "Bread"}) {
                items.insert(tx, title, new ToastItem(title));
            }
            return null;
        });

        app.dispatchLoop();
    }

    private static void answer(KayaApp.Tx tx, KayaApp.Signal<String> last,
            KayaApp.Signal<String> count, String text, KayaApp.ToastOutcome outcome) {
        answers++;
        tx.write(count, "answers " + answers);
        tx.write(last, text + ": " + outcome);
    }

    private Toast() {}
}
