package dev.kaya.guests;

import dev.kaya.KayaApp;

/**
 * The confirm scene from the JVM — guests/rust/confirm.rs,
 * tools/scenes/confirm.steps.
 */
public final class Confirm {
    public static void app() {
        KayaApp app = new KayaApp();

        app.build(tx -> {
            tx.window(0).title("confirm");
            KayaApp.Signal<String> status = tx.signal("no decision");
            tx.mount(tx.column(col -> {
                tx.label(status); // label#0
                tx.button("delete", inner -> {
                    app.observe(inner.showAlert()
                            .title("delete item?")
                            .message("this cannot be undone")
                            .action("Delete")
                            .action("Archive")
                            .cancel("Keep")
                            .showFuture().thenAccept(choice -> app.build(tx2 -> {
                                if (choice == KayaApp.AlertChoice.CANCEL) {
                                    tx2.write(status, "kept");
                                } else if (choice == KayaApp.AlertChoice.ACTION1) {
                                    tx2.write(status, "archived");
                                } else {
                                    tx2.write(status, "deleted");
                                }
                            })));
                });
                tx.button("eject", inner -> {
                    app.observe(inner.showAlert()
                            .title("eject disk?")
                            .message("it is still mounted")
                            .action("Eject")
                            .cancel("Hold")
                            .showFuture().thenAccept(choice -> app.build(tx2 -> {
                                tx2.write(status,
                                        choice == KayaApp.AlertChoice.CANCEL
                                                ? "held" : "ejected");
                            })));
                });
            }));
            return null;
        });

        app.dispatchLoop();
    }

    private Confirm() {}
}
