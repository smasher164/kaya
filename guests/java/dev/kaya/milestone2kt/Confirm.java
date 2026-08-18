package dev.kaya.milestone2kt;

import dev.kaya.KayaApp;
import dev.kaya.KayaWire;

/**
 * The confirm conformance scene from the JVM — the modal-alert grammar
 * via the chain spelling. The three rounds take the three answer paths
 * (action 0, action 1, and KayaWire.ALERT_CHOICE_CANCEL, which is every
 * platform-native dismissal). See guests/rust/confirm.rs and
 * tools/scenes/confirm.steps.
 */
final class Confirm {
    static void app() {
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
                                if (choice == KayaWire.ALERT_CHOICE_CANCEL) {
                                    tx2.write(status, "kept");
                                } else if (choice == 1) {
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
                                        choice == KayaWire.ALERT_CHOICE_CANCEL
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
