package dev.kaya.milestone2kt;

import dev.kaya.KayaApp;
import dev.kaya.KayaWire;

/**
 * The milestone-2 scene from the JVM, on the construction sugar: typed
 * handles, constructors carrying their handlers, containers taking
 * their children, and Consumer&lt;Tpl&gt; closures instead of
 * template_end bookkeeping. The ring recipe (Unsafe fenced access)
 * lives in KayaApp; the wire vocabulary (KayaWire) is generated from
 * kaya::spec by kaya-bindgen.
 */
final class Milestone2 {
    /**
     * The template handles the handlers need — templates and build
     * hand their declarations back out (KayaApp.Stamped), so nothing
     * escapes through static fields.
     */
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

            // Auto-parenting puts the templates where they stand: the
            // When and the For are declared inside the column, between
            // their siblings, and parent themselves there. Handles
            // still escape through the For body's return value (one
            // slot per handle, the lambda-capture idiom).
            Scene[] built = new Scene[1];
            tx.mount(tx.column(() -> {
                tx.button("step", t -> {
                    steps++;
                    if (steps == 1) {
                        t.insert(groups, "g1", "Work");
                        KayaApp.Collection todos = built[0].items.at("g1");
                        t.insert(todos, "a", "send report");
                        t.insert(todos, "b", "buy milk");
                    } else if (steps == 2) {
                        t.insert(groups, "g2", "Home");
                        t.insert(built[0].items.at("g2"), "a", "water plants");
                        t.update(groups, "g1", "Office");
                    }
                    t.write(extras, steps == 1);
                    t.write(status, "step " + steps);
                });
                tx.label(status);
                tx.when(extras, t -> {
                    KayaApp.Node bannerLabel = t.widget(KayaWire.KIND_LABEL);
                    t.setText(bannerLabel, "extras on");
                });
                built[0] = tx.forEach(groups, t -> {
                    KayaApp.Collection[] items = new KayaApp.Collection[1];
                    KayaApp.Node[] remove = new KayaApp.Node[1];
                    t.column(() -> {
                        KayaApp.Node name = t.widget(KayaWire.KIND_LABEL);
                        t.bindTextElement(name, 0);

                        items[0] = t.collection();
                        t.forEach(items[0], item -> {
                            item.column(() -> {
                                KayaApp.Node text = item.widget(KayaWire.KIND_LABEL);
                                item.bindTextElement(text, 0);
                                remove[0] = item.widget(KayaWire.KIND_BUTTON);
                                item.setText(remove[0], "remove");
                            });
                        });
                    });
                    return new Scene(status, items[0], remove[0]);
                }).out;
            }));
            return built[0];
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
