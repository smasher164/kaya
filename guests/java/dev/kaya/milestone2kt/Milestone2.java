package dev.kaya.milestone2kt;

import dev.kaya.KayaApp;

/**
 * The milestone-2 scene from the JVM: nested collections, and a click
 * on a stamped copy arriving with that copy's key path. The keys are
 * the app's own ("g1", "a"), so no minter is involved.
 */
final class Milestone2 {
    /** The handles the build body hands back out. */
    private static final class Scene {
        final KayaApp.Signal<String> status;
        final KayaApp.Collection items;
        final KayaApp.Node removeButton;

        Scene(KayaApp.Signal<String> status, KayaApp.Collection items,
                KayaApp.Node removeButton) {
            this.status = status;
            this.items = items;
            this.removeButton = removeButton;
        }
    }

    private static int steps;

    static void app() {
        KayaApp app = new KayaApp();

        Scene scene = app.build(tx -> {
            KayaApp.Signal<String> status = tx.signal("step 0");
            KayaApp.Signal<Boolean> extras = tx.signal(false);

            KayaApp.Collection groups = tx.collection();

            // Java lambdas cannot assign captured locals, so handles
            // declared inside a container body come back out through
            // one-slot arrays.
            KayaApp.Collection[] items = new KayaApp.Collection[1];
            KayaApp.Node[] remove = new KayaApp.Node[1];

            tx.mount(tx.column(() -> {
                tx.button("step", t -> { // button#0
                    steps++;
                    if (steps == 1) {
                        t.insert(groups, "g1", "Work");
                        KayaApp.Collection todos = items[0].at("g1");
                        t.insert(todos, "a", "send report");
                        t.insert(todos, "b", "buy milk");
                    } else if (steps == 2) {
                        t.insert(groups, "g2", "Home");
                        t.insert(items[0].at("g2"), "a", "water plants");
                        t.update(groups, "g1", "Office");
                    }
                    t.write(extras, steps == 1);
                    t.write(status, "step " + steps);
                });
                tx.label(status); // label#0
                // A BLOCK body: an expression lambda is ambiguous
                // between the Consumer and Function `when` overloads
                // (docs/traps.md).
                tx.when(extras, t -> {
                    t.label("extras on");
                });
                for (var group : tx.rows(groups)) {
                    group.column(() -> {
                        group.label(group.value());

                        items[0] = group.collection();
                        for (var item : group.rows(items[0])) {
                            item.column(() -> {
                                item.label(item.value());
                                remove[0] = item.button("remove");
                            });
                        }
                    });
                }
            }));
            return new Scene(status, items[0], remove[0]);
        });

        app.onClick(scene.removeButton, (tx, keys) -> {
            String group = (String) keys.get(0);
            String item = (String) keys.get(1);
            KayaApp.Collection todos = scene.items.at(group);
            tx.remove(todos, item);
            int left = tx.count(todos);
            tx.write(scene.status, "removed " + group + "/" + item + ", " + left + " left");
        });

        app.dispatchLoop();
    }

    private Milestone2() {}
}
