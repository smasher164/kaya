package dev.kaya.guests;

import dev.kaya.KayaApp;
import java.util.concurrent.CountDownLatch;

/**
 * The background scene from the JVM — guests/rust/background.rs,
 * tools/scenes/background.steps.
 */
public final class Background {
    private static final CountDownLatch RELEASED = new CountDownLatch(1);
    private static String posted = "";
    private static String nested = "";

    public static void app() {
        KayaApp app = new KayaApp();

        app.build(tx -> {
            tx.window(0).title("background");
            KayaApp.Signal<String> status = tx.signal("idle");
            KayaApp.Signal<String> alive = tx.signal("-");
            KayaApp.Signal<String> detail = tx.signal("-");

            tx.mount(tx.column(() -> {
                tx.label(status).a11yId("status"); // label#0
                tx.label(alive).a11yId("alive"); // label#1
                tx.label(detail).a11yId("nested"); // label#2

                tx.button("start", inner -> { // button#0
                    Thread worker = new Thread(() -> {
                        try {
                            RELEASED.await();
                        } catch (InterruptedException e) {
                            Thread.currentThread().interrupt();
                            return;
                        }
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
                tx.button("ping", inner -> inner.write(alive, "alive")); // button#1
                tx.button("release", inner -> RELEASED.countDown()); // button#2
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
