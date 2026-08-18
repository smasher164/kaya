package dev.kaya.milestone2kt;

import dev.kaya.KayaApp;

/**
 * The stamped-accessibility scene from the JVM: two entries stamped
 * from ONE template, each carrying its own row's accessibility
 * identity. Canonical semantics in guests/rust/a11yrows.rs; the
 * byte-frozen contract is tools/scenes/a11yrows.steps.
 *
 * <p>SEPARATE FROM THE a11y SCENE ON PURPOSE: a For materializes as a
 * column and container registries are creation-order, so a For inside
 * the a11y scene would make {@code column#0} name different widgets on
 * different lanes. This scene asserts no container.
 */
final class A11yRows {
    static void app() {
        KayaApp app = new KayaApp();

        app.build(tx -> {
            KayaApp.Collection notes = tx.collection();
            KayaApp.Collection heads = tx.collection();

            tx.mount(tx.column(() -> {
                for (var note : notes.rows()) {
                    KayaApp.Node field = note.entry();
                    // Both props element-sourced. The id has to be:
                    // expect_ax addresses the real tree BY identifier
                    // and refuses an ambiguous one, so stamped copies
                    // cannot share a const id (docs/tpl-props-plan.md).
                    note.setA11yId(field, note.value());
                    note.setA11yLabel(field, note.value());
                }

                // The stamped styling props, on a SECOND collection: a
                // scalar row has one field to spend on an id, so a
                // second readable copy needs strings of its own. Java's
                // container body is a Runnable that receives nothing,
                // so role and inset are both spelled on the row surface
                // where Rust splits them across Tpl and the row trace.
                for (var head : heads.rows()) {
                    KayaApp.Node bar = head.row(() -> {
                        KayaApp.Node title = head.label(head.value());
                        head.setRole(title, KayaApp.Role.HEADING);
                        head.setA11yId(title, head.value());
                    });
                    head.setInset(bar, 8.0);
                }
            }));

            // Seeded after the mount: every copy stamps from a template
            // that is already closed.
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
