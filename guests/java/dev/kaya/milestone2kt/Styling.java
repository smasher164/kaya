package dev.kaya.milestone2kt;

import dev.kaya.KayaApp;

/**
 * The styling conformance scene from the JVM (docs/styling-plan.md,
 * slice 1): the brand accent, the role tier, and the window inset,
 * together because they are one design — brand slots fill each
 * platform's token system, roles say what a widget MEANS, and the inset
 * is the one layout knob the pass admitted (D3).
 *
 * <p>What each piece demonstrates:
 * <ul>
 * <li>{@code brandAccent(0x3584E4)} — Adwaita blue, the derivation's
 * empirical anchor: one hex is the whole call, the core derives fills
 * and foregrounds, and a platform may let its user override the result
 * (D2).</li>
 * <li>{@code role(Role.HEADING)} on the title label — the platform's
 * heading text style AND the assistive heading trait, which is the one
 * role the steps freeze from the real tree on every lane.</li>
 * <li>{@code role(Role.DESTRUCTIVE)} / {@code role(Role.PROMINENT)} on
 * the two buttons — the platform's own emphasis chrome, and (the
 * scene's point) NO change to what pressing them does.</li>
 * <li>{@code inset(0.0)} — full bleed, the editor's own need, honored
 * unconditionally because the inset is kaya's padding (D3).</li>
 * </ul>
 *
 * <p>Canonical semantics in guests/rust/styling.rs; the byte-frozen
 * contract in tools/scenes/styling.steps.
 */
final class Styling {
    static void app() {
        KayaApp app = new KayaApp();

        app.build(tx -> {
            // BEFORE THE FIRST MOUNT, per the set-once wall: brand is
            // identity, not state.
            tx.brandAccent(0x3584E4);
            tx.window(0).title("styling").size(480.0, 360.0).inset(0.0);
            KayaApp.Signal<String> status = tx.signal("ready");

            tx.mount(tx.column(() -> {
                // expect_ax resolves a target through its AUTHORED id
                // into the real tree, so everything the steps read back
                // is identified (the a11y scene's discipline).
                tx.label("Sections").role(KayaApp.Role.HEADING).a11yId("title"); // label#0
                tx.label(status); // label#1
                tx.button("Delete", t -> t.write(status, "deleted")) // button#0
                        .role(KayaApp.Role.DESTRUCTIVE).a11yId("delete");
                tx.button("Save", t -> t.write(status, "saved")) // button#1
                        .role(KayaApp.Role.PROMINENT).a11yId("save");
            }));
        });

        app.dispatchLoop();
    }

    private Styling() {}
}
