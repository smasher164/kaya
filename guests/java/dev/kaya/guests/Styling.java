package dev.kaya.guests;

import dev.kaya.KayaApp;

/**
 * The styling conformance scene from the JVM (docs/styling-plan.md,
 * slice 1): the brand accent, the role tier and the window inset.
 * Canonical semantics in guests/rust/styling.rs; the byte-frozen
 * contract in tools/scenes/styling.steps.
 */
public final class Styling {
    public static void app() {
        KayaApp app = new KayaApp();

        app.build(tx -> {
            // BEFORE THE FIRST MOUNT, per the set-once wall.
            tx.brandAccent(0x3584E4);
            tx.window(0).title("styling").size(480.0, 360.0).inset(0.0);
            KayaApp.Signal<String> status = tx.signal("ready");

            tx.mount(tx.column(() -> {
                // expect_ax resolves a target through its AUTHORED id,
                // so everything the steps read back is identified.
                tx.heading("Sections").a11yId("title"); // label#0
                tx.label(status); // label#1
                tx.button("Delete", t -> t.write(status, "deleted")) // button#0
                        .role(KayaApp.Role.DESTRUCTIVE).a11yId("delete");
                tx.button("Save", t -> t.write(status, "saved")) // button#1
                        .role(KayaApp.Role.PROMINENT).a11yId("save");
                // Declared so every backend's caption arm runs, like the
                // two button roles: no universal AX observable, so the
                // walls are the arms' refusals plus this label's text.
                tx.caption("captioned"); // label#2
            }));
        });

        app.dispatchLoop();
    }

    private Styling() {}
}
