package dev.kaya.milestone2kt;

import dev.kaya.KayaApp;

/**
 * The layout scene from the JVM — the native-default observation
 * vehicle; see guests/rust/layout.rs for the axes it stresses. The two
 * label expects (KAYA_SELFTEST=layout) only prove the tree built; the
 * scene asserts no geometry — container targets index by creation
 * order, which legitimately differs per language. The grow contract is
 * asserted in the grow scene instead.
 */
final class Layout {
    static void app() {
        KayaApp app = new KayaApp();

        app.build(tx -> {
            KayaApp.Signal<String> probe = tx.signal("Layout probe");
            KayaApp.Signal<String> tail = tx.signal("tail");
            KayaApp.Signal<String> mixed = tx.signal("mixed");
            KayaApp.Signal<String> nested = tx.signal("nested");
            KayaApp.Signal<String> deep = tx.signal("deep");

            tx.mount(tx.column(() -> {
                tx.label(probe); // label#0

                // Main-axis free space: three unequal children with
                // leftover room.
                tx.row(() -> {
                    tx.button("A");
                    tx.button("longer");
                    tx.label(tail); // label#1
                });

                // Cross-axis alignment: three different intrinsic
                // heights, one grower filling the leftover row width.
                tx.row(() -> {
                    tx.checkbox("check", null);
                    tx.label(mixed); // label#2
                    tx.slider(0.0, 1.0, 0.5, null).grow(1.0);
                });

                // Proportional grow: two growers of unequal weight in
                // one row.
                tx.row(() -> {
                    tx.slider(0.0, 1.0, 0.25, null).grow(1.0);
                    tx.slider(0.0, 1.0, 0.75, null).grow(3.0);
                });

                // Nesting: a column inside the root column, a row
                // inside that.
                tx.column(() -> {
                    tx.label(nested); // label#3
                    tx.row(() -> {
                        tx.label(deep); // label#4
                        tx.button("x");
                    });
                });
            }));
            return null;
        });

        app.dispatchLoop();
    }

    private Layout() {}
}
