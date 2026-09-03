package dev.kaya.guests;

import dev.kaya.KayaApp;

/**
 * The styling scene from the JVM — guests/rust/styling.rs,
 * tools/scenes/styling.steps.
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
                // expect_ax resolves a target through its AUTHORED id.
                tx.heading("Sections").a11yId("title"); // label#0
                tx.label(status); // label#1
                tx.button("Delete", t -> t.write(status, "deleted")) // button#0
                        .role(KayaApp.Role.DESTRUCTIVE).a11yId("delete");
                tx.button("Save", t -> t.write(status, "saved")) // button#1
                        .role(KayaApp.Role.PROMINENT).a11yId("save");
                // Declared so every backend's caption arm runs: no universal AX
                // observable, so the walls are the arms' refusals.
                tx.caption("captioned"); // label#2
            }));
        });

        app.dispatchLoop();
    }

    private Styling() {}
}
