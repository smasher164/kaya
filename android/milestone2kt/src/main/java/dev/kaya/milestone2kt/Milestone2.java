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
    /**
     * The scene's handles, returned by the build body — templates and
     * build hand their declarations back out (KayaApp.Stamped), so
     * nothing escapes through static fields.
     */
    private static final class Scene {
        final KayaApp.Signal status;
        final KayaApp.Signal extras;
        final KayaApp.Widget step;
        final KayaApp.Collection groups;
        final KayaApp.Collection items;
        final KayaApp.Node removeButton;

        Scene(
                KayaApp.Signal status,
                KayaApp.Signal extras,
                KayaApp.Widget step,
                KayaApp.Collection groups,
                KayaApp.Collection items,
                KayaApp.Node removeButton) {
            this.status = status;
            this.extras = extras;
            this.step = step;
            this.groups = groups;
            this.items = items;
            this.removeButton = removeButton;
        }
    }

    private static int steps;

    static void app() {
        KayaApp app = new KayaApp();

        Scene scene = app.build(tx -> {
            KayaApp.Signal status = tx.signal("step 0");
            KayaApp.Signal extras = tx.signal(false);

            KayaApp.Widget column = tx.widget(KayaWire.KIND_COLUMN);
            KayaApp.Widget step = tx.widget(KayaWire.KIND_BUTTON);
            tx.setText(step, "step");
            KayaApp.Widget statusLabel = tx.widget(KayaWire.KIND_LABEL);
            tx.bindText(statusLabel, status);

            KayaApp.Widget banner = tx.when(extras, t -> {
                KayaApp.Node bannerLabel = t.widget(KayaWire.KIND_LABEL);
                t.setText(bannerLabel, "extras on");
            });

            KayaApp.Collection groups = tx.collection();
            KayaApp.Stamped<KayaApp.Widget, Scene> groupList = tx.forEach(groups, t -> {
                KayaApp.Node groupColumn = t.widget(KayaWire.KIND_COLUMN);
                KayaApp.Node name = t.widget(KayaWire.KIND_LABEL);
                t.bindTextElement(name, 0);
                t.addChild(groupColumn, name);

                KayaApp.Collection items = t.collection();
                KayaApp.Stamped<KayaApp.Node, KayaApp.Node> itemList = t.forEach(items, item -> {
                    KayaApp.Node row = item.widget(KayaWire.KIND_COLUMN);
                    KayaApp.Node text = item.widget(KayaWire.KIND_LABEL);
                    item.bindTextElement(text, 0);
                    KayaApp.Node remove = item.widget(KayaWire.KIND_BUTTON);
                    item.setText(remove, "remove");
                    item.addChild(row, text);
                    item.addChild(row, remove);
                    return remove;
                });
                t.addChild(groupColumn, itemList.handle);
                return new Scene(status, extras, step, groups, items, itemList.out);
            });

            tx.addChild(column, step);
            tx.addChild(column, statusLabel);
            tx.addChild(column, banner);
            tx.addChild(column, groupList.handle);
            tx.mount(column);
            return groupList.out;
        });

        app.onClick(scene.step, tx -> {
            steps++;
            if (steps == 1) {
                tx.insert(scene.groups, "g1", "Work");
                KayaApp.Collection todos = scene.items.at("g1");
                tx.insert(todos, "a", "send report");
                tx.insert(todos, "b", "buy milk");
            } else if (steps == 2) {
                tx.insert(scene.groups, "g2", "Home");
                tx.insert(scene.items.at("g2"), "a", "water plants");
                tx.update(scene.groups, "g1", "Office");
            }
            tx.write(scene.extras, steps == 1);
            tx.write(scene.status, "step " + steps);
        });

        app.onClick(scene.removeButton, (tx, keys) -> {
            String group = (String) keys.get(0);
            String item = (String) keys.get(1);
            // The instance handle names the target once; mutation and
            // read hang off the same value. The collection is the
            // model: the count read is the fold of the patches, this
            // one included.
            KayaApp.Collection todos = scene.items.at(group);
            tx.remove(todos, item);
            int left = tx.count(todos);
            tx.write(scene.status, "removed " + group + "/" + item + ", " + left + " left");
        });

        app.dispatchLoop();
    }

    private Milestone2() {}
}
