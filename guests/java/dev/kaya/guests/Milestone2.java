package dev.kaya.guests;

import dev.kaya.KayaApp;

/**
 * The milestone2 scene from the JVM — guests/rust/milestone2.rs,
 * tools/scenes/milestone2.steps.
 */
public final class Milestone2 {
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

    /** Java lambdas cannot assign captured locals. */
    private static final class Refs {
        KayaApp.Collection items;
        KayaApp.Node remove;
    }

    private static int steps;

    public static void app() {
        KayaApp app = new KayaApp();

        Scene scene = app.build(tx -> {
            KayaApp.Signal<String> status = tx.signal("step 0");
            KayaApp.Signal<Boolean> extras = tx.signal(false);

            KayaApp.Collection groups = tx.collection();

            Refs refs = new Refs();

            tx.mount(tx.column(() -> {
                tx.button("step", t -> { // button#0
                    steps++;
                    if (steps == 1) {
                        t.insert(groups, "g1", "Work");
                        KayaApp.Collection todos = refs.items.at("g1");
                        t.insert(todos, "a", "send report");
                        t.insert(todos, "b", "buy milk");
                    } else if (steps == 2) {
                        t.insert(groups, "g2", "Home");
                        t.insert(refs.items.at("g2"), "a", "water plants");
                        t.update(groups, "g1", "Office");
                    }
                    t.write(extras, steps == 1);
                    t.write(status, "step " + steps);
                });
                tx.label(status); // label#0
                // A BLOCK body: an expression lambda is ambiguous between the
                // Consumer and Function `when` overloads (docs/traps.md).
                tx.when(extras, t -> {
                    t.label("extras on");
                });
                for (var group : tx.rows(groups)) {
                    group.column(() -> {
                        group.label(group.value());

                        refs.items = group.collection();
                        for (var item : group.rows(refs.items)) {
                            item.column(() -> {
                                item.label(item.value());
                                refs.remove = item.button("remove");
                            });
                        }
                    });
                }
            }));
            return new Scene(status, refs.items, refs.remove);
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
