package dev.kaya.milestone2kt;

import dev.kaya.KayaApp;

/**
 * The panels conformance scene from the JVM — see guests/rust/panels.rs
 * for the full rationale. A main window and an inspector; the inspector
 * arms vetoClose, so the chrome close EMITS close_requested and closes
 * nothing — the guest answers by recording the request in the status
 * label and destroying the window (the request/confirm veto class,
 * DESIGN.md's Presentation contexts). Desktop-only: phone hosts reject
 * createWindow at the root by capability.
 *
 * The createWindow chain is Java's spelling of the window sugar;
 * app.onCloseRequested is the event surface.
 */
final class Panels {
    static void app() {
        KayaApp app = new KayaApp();

        KayaApp.Signal<String> status = app.build(tx -> {
            tx.windowTitle("panels");
            KayaApp.Signal<String> s = tx.signal("two panels");
            tx.mount(tx.column(() -> {
                tx.label(s); // label#0
            }));

            // The veto handler binds to the inspector at its
            // declaration (handlers scope to the thing that creates
            // them): it can only ever mean this window's close.
            tx.createWindow(1)
                    .title("inspector")
                    .size(480.0, 320.0)
                    .vetoClose(true)
                    .onCloseRequested(tx2 -> {
                        tx2.write(s, "close requested");
                        tx2.destroyWindow(1);
                    });
            tx.mountIn(1, tx.column(() -> {
                KayaApp.Signal<String> caption = tx.signal("inspector pane");
                tx.label(caption); // label#1
            }));
            return s;
        });

        if (status == null) throw new IllegalStateException();

        app.dispatchLoop();
    }

    private Panels() {}
}
