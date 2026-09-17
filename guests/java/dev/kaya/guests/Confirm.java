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
            tx.mount(tx.column(() -> {
                tx.label(status); // label#0
                tx.button("delete", inner -> {
                    inner.showAlert()
                            .title("delete item?")
                            .message("this cannot be undone")
                            .action("Delete")
                            .action("Archive")
                            .cancel("Keep")
                            .onResult((tx2, choice) -> {
                                if (choice == KayaApp.AlertChoice.CANCEL) {
                                    tx2.write(status, "kept");
                                } else if (choice == KayaApp.AlertChoice.ACTION1) {
                                    tx2.write(status, "archived");
                                } else {
                                    tx2.write(status, "deleted");
                                }
                            })
                            .show();
                });
                tx.button("eject", inner -> {
                    inner.showAlert()
                            .title("eject disk?")
                            .message("it is still mounted")
                            .action("Eject")
                            .cancel("Hold")
                            .onResult((tx2, choice) -> {
                                tx2.write(status,
                                        choice == KayaApp.AlertChoice.CANCEL
                                                ? "held" : "ejected");
                            })
                            .show();
                });
            }));
            return null;
        });

        app.dispatchLoop();
    }

    private Confirm() {}
}
