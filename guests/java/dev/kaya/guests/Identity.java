package dev.kaya.guests;

import dev.kaya.KayaApp;

/**
 * The identity scene from the JVM — guests/rust/identity.rs,
 * tools/scenes/identity.steps.
 */
public final class Identity {
    private static String draft = "";

    public static void app() {
        KayaApp app = new KayaApp();

        app.build(tx -> {
            // BEFORE THE FIRST MOUNT, per the declared-once wall; the close is
            // safe once appIdentity has registered the bytes.
            try (KayaApp.Asset icon = KayaApp.asset("icons/kaya-mark.png")) {
                tx.appIdentity("Aurora Notes", icon);
            }
            KayaApp.WindowRef win = tx.window(0).title("identity").size(480.0, 360.0);
            // ONE PROMOTED COMMAND, and not about commands: Windows mints its
            // custom caption from the first promotion, taking the system icon.
            win.menu("File").item("Save")
                    .symbol(KayaApp.Symbol.DONE)
                    .primary(true);

            KayaApp.Signal<String> heading = tx.signal("identity");
            KayaApp.Signal<String> status = tx.signal("ready");

            tx.mount(tx.column(() -> {
                tx.label(heading); // label#0
                tx.label(status); // label#1
                tx.entry((t, text) -> draft = text); // entry#0
                tx.button("Go", t -> t.write(status, "clicked " + draft)); // button#0
            }));

            // DESKTOP-ONLY: a phone host rejects createWindow AT THE ROOT, and
            // the android leg drops the step (docs/app-identity-plan.md ruling 3).
            if (KayaApp.capabilities().auxWindows()) {
                tx.createWindow(1).size(360.0, 240.0);
                tx.mountIn(1, tx.column(() -> {
                    KayaApp.Signal<String> caption = tx.signal("no title of its own");
                    tx.label(caption); // label#2
                }));
            }
            return null;
        });

        app.dispatchLoop();
    }

    private Identity() {}
}
