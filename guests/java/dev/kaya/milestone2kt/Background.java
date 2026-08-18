package dev.kaya.milestone2kt;

import dev.kaya.KayaApp;
import java.util.concurrent.CountDownLatch;

/**
 * The background conformance scene, Java port — work off the app
 * thread, posted back (docs/background-work-plan.md).
 *
 * <p>THE SHAPE IS DELIBERATE: a wrong implementation must DEADLOCK
 * rather than disagree. The worker parks until a CLICK releases it, and
 * only a live app thread can process a click.
 *
 * <p>The worker MUST be a daemon thread: a parked non-daemon thread
 * keeps the JVM alive, which never shows on a passing run and turns a
 * FAILING one into a timeout instead of a report.
 *
 * <p>The accumulators need no lock — everything that touches them runs
 * on the app thread, inside a posted transaction.
 */
final class Background {
    private static final CountDownLatch RELEASED = new CountDownLatch(1);
    private static String posted = "";
    private static String nested = "";

    static void app() {
        KayaApp app = new KayaApp();

        app.build(tx -> {
            tx.window(0).title("background");
            KayaApp.Signal<String> status = tx.signal("idle");
            KayaApp.Signal<String> alive = tx.signal("-");
            KayaApp.Signal<String> detail = tx.signal("-");

            tx.mount(tx.column(() -> {
                tx.label(status).a11yId("status"); // label#0
                tx.label(alive).a11yId("alive"); // label#1
                // Authored id: the closing read is an AX read, and an
                // index read passes for an arm that drew nothing.
                tx.label(detail).a11yId("nested"); // label#2

                tx.button("start", inner -> { // button#0
                    Thread worker = new Thread(() -> {
                        try {
                            RELEASED.await();
                        } catch (InterruptedException e) {
                            Thread.currentThread().interrupt();
                            return;
                        }
                        // The accumulator makes this a test of ORDER,
                        // not of which post ran last.
                        for (String step : new String[] {"1", "2", "3"}) {
                            app.post(tx2 -> {
                                posted += step;
                                tx2.write(status, posted);
                            });
                        }
                    }, "background-worker");
                    worker.setDaemon(true);
                    worker.start();
                    inner.write(status, "working");
                });
                // Proof the app thread still serves input while the
                // worker is parked.
                tx.button("ping", inner -> inner.write(alive, "alive")); // button#1
                tx.button("release", inner -> RELEASED.countDown()); // button#2
                // A post from INSIDE a handler QUEUES for after; it
                // never nests, so this commits "ac" and then "acb".
                // Nesting could only ever produce "abc".
                tx.button("nest", inner -> { // button#3
                    nested += "a";
                    app.post(tx2 -> {
                        nested += "b";
                        tx2.write(detail, nested);
                    });
                    nested += "c";
                    inner.write(detail, nested);
                });
            }));
            return null;
        });

        app.dispatchLoop();
    }

    private Background() {}
}
