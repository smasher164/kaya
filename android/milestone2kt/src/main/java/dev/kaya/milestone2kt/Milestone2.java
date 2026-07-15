package dev.kaya.milestone2kt;

import dev.kaya.KayaApp;
import dev.kaya.KayaWire;

/**
 * The milestone-2 scene from the JVM, on the idiomatic surface
 * (KayaApp): typed handles instead of hand-numbered ids,
 * Consumer&lt;Tpl&gt; closures instead of template_end bookkeeping, and
 * click handlers instead of a hand-rolled dispatch loop. The ring
 * recipe (Unsafe fenced access) lives in KayaApp now; the wire
 * vocabulary (KayaWire) is generated from kaya::spec by kaya-bindgen.
 */
final class Milestone2 {
    private static KayaApp.Signal status;
    private static KayaApp.Signal extras;
    private static KayaApp.Widget step;
    private static KayaApp.Collection groups;
    private static KayaApp.Collection items;
    private static KayaApp.Node removeButton;
    private static int steps;

    static void app() {
        KayaApp app = new KayaApp();

        app.build(tx -> {
            status = tx.signal("step 0");
            extras = tx.signal(false);

            KayaApp.Widget column = tx.widget(KayaWire.KIND_COLUMN);
            step = tx.widget(KayaWire.KIND_BUTTON);
            tx.setText(step, "step");
            KayaApp.Widget statusLabel = tx.widget(KayaWire.KIND_LABEL);
            tx.bindText(statusLabel, status);

            KayaApp.Widget banner = tx.when(extras, t -> {
                KayaApp.Node bannerLabel = t.widget(KayaWire.KIND_LABEL);
                t.setText(bannerLabel, "extras on");
            });

            groups = tx.collection();
            KayaApp.Widget groupList = tx.forEach(groups, t -> {
                KayaApp.Node groupColumn = t.widget(KayaWire.KIND_COLUMN);
                KayaApp.Node name = t.widget(KayaWire.KIND_LABEL);
                t.bindTextElement(name, 0);
                t.addChild(groupColumn, name);

                items = t.collection();
                KayaApp.Node itemList = t.forEach(items, item -> {
                    KayaApp.Node row = item.widget(KayaWire.KIND_COLUMN);
                    KayaApp.Node text = item.widget(KayaWire.KIND_LABEL);
                    item.bindTextElement(text, 0);
                    removeButton = item.widget(KayaWire.KIND_BUTTON);
                    item.setText(removeButton, "remove");
                    item.addChild(row, text);
                    item.addChild(row, removeButton);
                });
                t.addChild(groupColumn, itemList);
            });

            tx.addChild(column, step);
            tx.addChild(column, statusLabel);
            tx.addChild(column, banner);
            tx.addChild(column, groupList);
            tx.mount(column);
        });

        app.onClick(step, tx -> {
            steps++;
            if (steps == 1) {
                tx.insert(groups, null, "g1", "Work");
                tx.insert(items, new Object[] {"g1"}, "a", "send report");
                tx.insert(items, new Object[] {"g1"}, "b", "buy milk");
            } else if (steps == 2) {
                tx.insert(groups, null, "g2", "Home");
                tx.insert(items, new Object[] {"g2"}, "a", "water plants");
                tx.update(groups, null, "g1", "Office");
            }
            tx.write(extras, steps == 1);
            tx.write(status, "step " + steps);
        });

        app.onClick(removeButton, (tx, keys) -> {
            String group = (String) keys.get(0);
            String item = (String) keys.get(1);
            tx.remove(items, new Object[] {group}, item);
            // The collection is the model: the count read here is the
            // fold of the patches, this one included.
            int left = tx.count(items, new Object[] {group});
            tx.write(status, "removed " + group + "/" + item + ", " + left + " left");
        });

        app.dispatchLoop();
    }

    private Milestone2() {}
}
