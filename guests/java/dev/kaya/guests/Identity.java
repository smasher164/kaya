package dev.kaya.guests;

import dev.kaya.KayaApp;

/**
 * The app-identity conformance scene from the JVM: an app declares what
 * it is called and what it looks like, and the platform shows both.
 * Canonical semantics in guests/rust/identity.rs; the byte-frozen
 * contract in tools/scenes/identity.steps.
 *
 * <p>THE MARK IS THE VENDORED ONE (four flat quadrants) because no
 * platform's own default icon can land on four declared colours, so a
 * lowering that never applied can never read as a pass.
 *
 * <p>THE SECOND WINDOW HAS NO TITLE OF ITS OWN, deliberately: that is
 * the blank an app's NAME fills on every platform.
 */
public final class Identity {
    private static String draft = "";

    public static void app() {
        KayaApp app = new KayaApp();

        app.build(tx -> {
                        // BEFORE THE FIRST MOUNT, per the declared-once wall. The
                        // bytes never enter this JVM's heap — the handle goes
                        // straight to the blob channel — and try-with-resources is
                        // safe because appIdentity has already registered them into
                        // the pending blob table, which keeps its own reference.
            try (KayaApp.Asset icon = KayaApp.asset("icons/kaya-mark.png")) {
                tx.appIdentity("Aurora Notes", icon);
            }
            KayaApp.WindowRef win = tx.window(0).title("identity").size(480.0, 360.0);
                        // ONE PROMOTED COMMAND, AND IT IS NOT ABOUT COMMANDS.
                        // Windows mints its custom caption from the first promotion
                        // and from nothing else, and a custom caption REPLACES the
                        // system one — taking the system-drawn app icon with it. A
                        // scene with no promotion would leave that sink unreached.
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

                        // THE UNTITLED WINDOW, and it is DESKTOP-ONLY: a phone host
                        // rejects createWindow AT THE ROOT (KAYA_CAP_AUX_WINDOWS is
                        // unset there), so a guest that built it aborts before it
                        // ever mounts. It declares no title at all rather than an
                        // empty one: an empty string is a title an app WROTE, and
                        // the rule under test is what a window with nothing written
                        // shows. The android leg drops the one step that reads it;
                        // the NAME's reader there is the APK's own android:label
                        // (docs/app-identity-plan.md ruling 3).
                        //
                        // THE HOST IS ASKED, and it is the CORE that answers: the
                        // word it reads is the same const the wall inside
                        // createWindow tests (crates/kaya/src/scene.rs).
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
