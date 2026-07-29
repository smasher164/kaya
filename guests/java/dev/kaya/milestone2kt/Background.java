package dev.kaya.milestone2kt;

import dev.kaya.KayaApp;
import java.util.concurrent.CountDownLatch;

/**
 * The background conformance scene, Java port — work off the app
 * thread, posted back (docs/background-work-plan.md).
 *
 * <p>WHAT IT PROVES, and the reason for its odd shape: a wrong
 * implementation must DEADLOCK rather than disagree. The worker parks
 * until a CLICK releases it, and only a live app thread can process a
 * click — so a binding that let background work occupy the app thread
 * cannot reach the end of the script at all. It could not even deliver
 * its own release.
 *
 * <p>The parking is a plain CountDownLatch and the worker a plain
 * DAEMON thread. kaya supplies no waiting primitive and should not: the
 * point is that a guest uses its own language's concurrency and hands
 * back only the result. The daemon flag matters — a parked non-daemon
 * thread keeps the JVM alive, which never shows on a passing run and
 * turns a FAILING one into a timeout instead of a report.
 *
 * <p>The accumulators are the guest's own state rather than signal
 * read-backs — signals are write-only by doctrine. They need no lock:
 * everything that touches them runs on the app thread, inside a posted
 * transaction.
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
                // Authored so the CLOSING read can address it: the AX
                // read needs an identifier, and an index read passes for
                // an arm that ran and drew nothing.
                tx.label(detail).a11yId("nested"); // label#2

                tx.button("start", inner -> { // button#0
                    Thread worker = new Thread(() -> {
                        try {
                            // Parks here until the scene clicks release.
                            // Were the binding running this on the app
                            // thread, that click could never be
                            // processed and the whole scene would
                            // deadlock — the point.
                            RELEASED.await();
                        } catch (InterruptedException e) {
                            Thread.currentThread().interrupt();
                            return;
                        }
                        // Three posts, in order. The accumulator makes
                        // this a test of ORDER and not merely of which
                        // one ran last.
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
                // Proof the app thread is still serving input while the
                // worker is parked and has posted nothing.
                tx.button("ping", inner -> inner.write(alive, "alive")); // button#1
                tx.button("release", inner -> RELEASED.countDown()); // button#2
                // A post from INSIDE a handler QUEUES for after; it
                // never nests. The handler appends a, posts a body
                // appending b, appends c — so it commits "ac" and the
                // posted body then commits "acb". Nesting can only ever
                // produce "abc".
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
