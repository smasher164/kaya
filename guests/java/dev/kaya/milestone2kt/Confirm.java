package dev.kaya.milestone2kt;

import dev.kaya.KayaApp;
import dev.kaya.KayaWire;

/**
 * The confirm conformance scene from the JVM — the modal-alert
 * grammar via the chain spelling (the request/result grammar's first
 * client): one button re-shows a two-action alert; the three rounds
 * take the three answer paths (action 0, action 1,
 * KayaWire.ALERT_CHOICE_CANCEL — every platform-native dismissal,
 * -1 in java-int terms), and the status label records each result.
 * The result handler rides the REQUEST (.onResult in the chain, the
 * widget-handler precedent) and retires with its one answer; ids
 * are binding-allocated. See guests/rust/confirm.rs and
 * tools/scenes/confirm.steps.
 */
final class Confirm {
    static void app() {
        KayaApp app = new KayaApp();

        app.build(tx -> {
            tx.windowTitle("confirm");
            KayaApp.Signal<String> status = tx.signal("no decision");
            tx.mount(tx.column(() -> {
                tx.label(status); // label#0
                tx.button("delete", inner -> {
                    // The result handler rides the request and
                    // retires with its one answer; ids are
                    // binding-allocated — no counter plumbing.
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
                    // A different dialog, a different handler: the
                    // association is the registration itself.
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
