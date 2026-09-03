package dev.kaya.guests;

import dev.kaya.KayaApp;

/**
 * The a11yrows scene from the JVM — guests/rust/a11yrows.rs,
 * tools/scenes/a11yrows.steps.
 */
public final class A11yRows {
    public static void app() {
        KayaApp app = new KayaApp();

        app.build(tx -> {
            KayaApp.Collection notes = tx.collection();
            KayaApp.Collection heads = tx.collection();

            tx.mount(tx.column(() -> {
                for (var note : tx.rows(notes)) {
                    KayaApp.Node field = note.entry();
                    // Element-sourced: expect_ax refuses an ambiguous authored
                    // id (docs/tpl-props-plan.md).
                    note.setA11yId(field, note.value());
                    note.setA11yLabel(field, note.value());
                }

                // Java's container body is a Runnable that receives nothing, so
                // role and inset are spelled on the row surface.
                for (var head : tx.rows(heads)) {
                    KayaApp.Node bar = head.row(() -> {
                        KayaApp.Node title = head.label(head.value());
                        head.setRole(title, KayaApp.Role.HEADING);
                        head.setA11yId(title, head.value());
                    });
                    head.setInset(bar, 8.0);
                }
            }));

            tx.insertFresh(notes, "First note");
            tx.insertFresh(notes, "Second note");
            tx.insertFresh(heads, "Heading one");
            tx.insertFresh(heads, "Heading two");
            return null;
        });

        app.dispatchLoop();
    }

    private A11yRows() {}
}
