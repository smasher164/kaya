package dev.kaya.milestone2kt;

import dev.kaya.KayaApp;

/**
 * The stamped-accessibility scene from the JVM: two entries stamped
 * from ONE template, each carrying its own row's accessibility
 * identity, read back out of the PLATFORM'S accessibility tree rather
 * than kaya's model.
 *
 * <p>The a11y scene proves the wrap-native bet for LIVE widgets; this
 * one proves it for COPIES — the case none of the accessibility
 * milestone's 719 legs ever exercised, because until the template zone
 * could spell the props (docs/tpl-props-plan.md P1) no guest could
 * author a stamped widget's name at all.
 *
 * <p>A SEPARATE SCENE BY DESIGN, not by size: a For materializes as a
 * column, harness registries are creation-order, and container creation
 * order differs by language — so the a11y scene, which asserts every
 * container kind ordinally, cannot host a For without {@code column#0}
 * meaning different widgets on different lanes. This scene asserts no
 * container, so the For's column may land anywhere in the registry
 * (guests/haskell/reorder.hs documents the ordering rule).
 *
 * <p>Canonical semantics in guests/rust/a11yrows.rs; the byte-frozen
 * contract is tools/scenes/a11yrows.steps.
 */
final class A11yRows {
    static void app() {
        KayaApp app = new KayaApp();

        app.build(tx -> {
            KayaApp.Collection notes = tx.collection();

            tx.mount(tx.column(() -> {
                // The tracing tier: the for-each IS the For — the body
                // runs once, and value() is the element's own token (a
                // scalar collection has exactly one field, the element
                // itself).
                for (var note : notes.rows()) {
                    KayaApp.Node field = note.entry();
                    // BOTH PROPS ELEMENT-SOURCED. The label is the
                    // point — a list row announcing its own name to
                    // assistive tech. The id is forced: expect_ax
                    // searches the real tree BY the authored
                    // identifier, so copies sharing a const id are
                    // indistinguishable to it and the read refuses them
                    // (it answered with the first copy's label for the
                    // second's index until it learned to). A shared
                    // const id stays legal in the core; it is just
                    // unreadable by that verb.
                    note.setA11yId(field, note.value());
                    note.setA11yLabel(field, note.value());
                }
            }));

            // Seeded after the mount, Reorder.java's shape: the two
            // copies stamp from a template that is already closed. No
            // key of their own — nothing outside kaya addresses these
            // rows by key, and the a11y identity comes from the value.
            tx.insertFresh(notes, "First note");
            tx.insertFresh(notes, "Second note");
            return null;
        });

        app.dispatchLoop();
    }

    private A11yRows() {}
}
