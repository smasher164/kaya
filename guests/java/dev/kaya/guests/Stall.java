package dev.kaya.guests;

import dev.kaya.KayaApp;

/**
 * The stall conformance scene, Java port — an app thread that stops
 * taking its occurrences is REPORTED (DESIGN.md, Threading model and
 * protocol). See guests/rust/stall.rs and tools/scenes/stall.steps.
 *
 * <p>THIS IS THE ONE GUEST THAT MISUSES KAYA ON PURPOSE, in every
 * language: {@code block} sleeps on the app thread and the scene
 * asserts kaya notices. Do not "fix" it.
 *
 * <p>{@code ping} is load-bearing: a handler blocking on an EMPTY queue
 * looks exactly like an idle app, so the second click is what makes
 * work pending while the app thread is gone.
 */
public final class Stall {
    /** Past the watchdog's one-second threshold, short enough that the
     * leg still asserts the recovery. */
    private static final long BLOCK_MS = 2500;

    /** A day, never a literal park (docs/traps.md, "The stall scene
     * wedges for a DAY"). */
    private static final long WEDGE_MS = 86_400_000L;

    public static void app() {
        KayaApp app = new KayaApp();

        app.build(tx -> {
            tx.window(0).title("stall");
            KayaApp.Signal<String> status = tx.signal("ready");

            tx.mount(tx.column(() -> {
                tx.label(status).a11yId("status"); // label#0

                // DELIBERATELY WRONG, and the only place in this repo
                // that is: real work belongs on a thread of its own
                // with the result posted back through app.post.
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
