package dev.kaya.milestone2kt;

import dev.kaya.KayaApp;

/**
 * The panels conformance scene from the JVM — see guests/rust/panels.rs
 * for the rationale. The inspector arms vetoClose, so its chrome close
 * emits close_requested and closes nothing; the guest records the
 * request and destroys the window itself.
 *
 * <p>DESKTOP ONLY: phone hosts reject createWindow at the root by
 * capability.
 */
final class Panels {
    static void app() {
        KayaApp app = new KayaApp();

        KayaApp.Signal<String> status = app.build(tx -> {
            tx.window(0).title("panels");
            KayaApp.Signal<String> s = tx.signal("two panels");
            tx.mount(tx.column(() -> {
                tx.label(s); // label#0
            }));

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
