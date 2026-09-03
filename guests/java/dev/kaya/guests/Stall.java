package dev.kaya.guests;

import dev.kaya.KayaApp;

/**
 * The stall scene from the JVM — guests/rust/stall.rs, tools/scenes/stall.steps.
 */
public final class Stall {
    /** Past the watchdog's one-second threshold, short enough not to cost. */
    private static final long BLOCK_MS = 2500;

    /** A day, never a literal park (docs/traps.md, the stall scene wedges for
     * a DAY). */
    private static final long WEDGE_MS = 86_400_000L;

    public static void app() {
        KayaApp app = new KayaApp();

        app.build(tx -> {
            tx.window(0).title("stall");
            KayaApp.Signal<String> status = tx.signal("ready");

            tx.mount(tx.column(() -> {
                tx.label(status).a11yId("status"); // label#0

                // DELIBERATELY WRONG, and the only place in this repo that is.
                tx.button("block", inner -> { // button#0
                    try {
                        Thread.sleep(BLOCK_MS);
                    } catch (InterruptedException e) {
                        Thread.currentThread().interrupt();
                    }
                });
                tx.button("ping", inner -> { // button#1
                    inner.write(status, "pinged");
                });
                tx.button("wedge", inner -> { // button#2
                    try {
                        Thread.sleep(WEDGE_MS);
                    } catch (InterruptedException e) {
                        Thread.currentThread().interrupt();
                    }
                });
            }));
        });

        app.dispatchLoop();
    }

    private Stall() {}
}
