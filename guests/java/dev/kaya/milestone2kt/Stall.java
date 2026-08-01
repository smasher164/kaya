package dev.kaya.milestone2kt;

import dev.kaya.KayaApp;

/**
 * The stall conformance scene, Java port — an app thread that stops
 * taking its occurrences is REPORTED (DESIGN.md, Threading model and
 * protocol).
 *
 * <p>THIS IS THE ONE GUEST THAT MISUSES KAYA ON PURPOSE, in every
 * language. Every other guest keeps blocking work off the app thread —
 * each of the eight filedialog guests carries a paragraph explaining
 * why its read goes to a worker — and that discipline was entirely
 * unenforced. Nothing would have told anyone that a guest ignoring it
 * had wedged the app. The class is not hypothetical: a Haskell release
 * once used a blocking put, so a second click would have blocked the
 * app thread forever, and no gate saw it.
 *
 * <p>So {@code block} does exactly the forbidden thing — it sleeps on
 * the app thread — and the scene asserts that kaya NOTICES. A scene
 * that merely timed out would prove the app was broken; this proves the
 * framework reported it, which is the whole feature.
 *
 * <p>WHY THE SECOND CLICK MATTERS: the consumer cursor advances BEFORE
 * a record reaches the guest, so a handler blocking on an empty queue
 * looks exactly like an idle app — and nothing is waiting on it, so it
 * may as well be. {@code ping} is what makes work PENDING while the app
 * thread is gone. That is what the watchdog can see, and it is what a
 * person reports: they click, and click again, and nothing happens.
 *
 * <p>The recovery is asserted too: the blocked handler returns, the
 * queued click is taken, and the label shows it — so the watchdog
 * reported a stall rather than a death, and nothing was dropped.
 *
 * <p>AND THEN ONE THAT NEVER COMES BACK. A handler blocking for 2.5
 * seconds is a SLOW handler, and every assertion above would pass for
 * one; a real deadlock does not politely end. `wedge` never returns, so
 * the scene ends there — and the leg still reports its verdict, because
 * the harness runs on its own thread and asks the MAIN thread to exit.
 * Neither path needs the app thread that is gone.
 *
 * <p>See guests/rust/stall.rs and tools/scenes/stall.steps.
 */
final class Stall {
    /**
     * Comfortably past the watchdog's one-second threshold, and short
     * enough that the leg is not paying for it: the scene asserts the
     * stall and then the recovery, so this is the whole cost.
     */
    private static final long BLOCK_MS = 2500;

    /**
     * AND ONE THAT NEVER COMES BACK, which is the shape a real deadlock
     * has. A day rather than a literal park, because "forever" is spelled
     * differently in all eight languages and some of those spellings wake
     * their runtime's own deadlock detector; within a leg that lasts
     * seconds, a day and forever are the same thing. The process exits out
     * from under it.
     */
    private static final long WEDGE_MS = 86_400_000L;

    static void app() {
        KayaApp app = new KayaApp();

        app.build(tx -> {
            tx.window(0).title("stall");
            KayaApp.Signal<String> status = tx.signal("ready");

            tx.mount(tx.column(() -> {
                tx.label(status).a11yId("status"); // label#0

                // DELIBERATELY WRONG, and the only place in this repo
                // that is. Anything real belongs on a thread of its own
                // with the result posted back through app.post — which
                // is what every other guest does, and what the
                // watchdog's own message tells you to do.
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
