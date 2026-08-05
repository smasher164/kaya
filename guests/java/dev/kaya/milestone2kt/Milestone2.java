package dev.kaya.milestone2kt;

import dev.kaya.KayaApp;

/**
 * The milestone-2 scene from the JVM, on the construction sugar: typed
 * handles, constructors carrying their handlers, containers taking
 * their children, and the tracing tier for both Fors — a nested {@code
 * for} statement over {@code rows()} IS the nested For, so nothing
 * spells template_end and nothing binds an element by index. The ring
 * recipe (Unsafe fenced access) lives in KayaApp; the wire vocabulary
 * (KayaWire) is generated from kaya::spec by kaya-bindgen.
 *
 * <p>WHAT THIS SCENE DOCUMENTS IS THE EVENT SIDE (DESIGN.md, the scope
 * ratified 2026-08-05): the step button carries its handler where it
 * stands, while the stamped remove button is registered CENTRALLY
 * after the build, against the template node the build body handed
 * back — a click on a copy arrives carrying that copy's key path,
 * which is the thing this scene exists to show. Construction is
 * ordinary sugar here, as in every example that is not a C guest. The
 * keys are the app's own ("g1", "a"): identity it chose, so no minter
 * is involved.
 */
final class Milestone2 {
    /**
     * The template handles the handlers need — build hands its
     * declarations back out, so nothing escapes through static fields.
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

            // Java lambdas cannot assign captured locals, so the two
            // handles declared inside the blueprint — the nested
            // collection and the stamped button — come back out
            // through one-slot arrays (Entry.java's idiom, and
            // Undo.java's).
            KayaApp.Collection[] items = new KayaApp.Collection[1];
            KayaApp.Node[] remove = new KayaApp.Node[1];

            // Auto-parenting puts the templates where they stand: the
            // When and the For are declared inside the column, between
            // their siblings, and parent themselves there.
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
                // A block body: an expression lambda is ambiguous
                // between the Consumer and Function when overloads.
                tx.when(extras, t -> {
                    t.label("extras on");
                });
                // The tracing tier: each for-each IS the For — the
                // body runs once, and value() is the element's own
                // token (a scalar collection has exactly one field,
                // the element itself, which is what an index used to
                // spell). The traces nest because each rides the zone
                // it opens in.
                for (var group : groups.rows()) {
                    group.column(() -> {
                        group.label(group.value());

                        items[0] = group.collection();
                        for (var item : items[0].rows()) {
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
