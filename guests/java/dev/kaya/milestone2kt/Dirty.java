package dev.kaya.milestone2kt;

import dev.kaya.KayaApp;
import dev.kaya.KayaWire;

/**
 * The dirty-state conformance scene from the JVM: unsaved work as
 * window chrome (docs/dirty-plan.md). The app declares the state and
 * each backend spells its platform's own affordance. Canonical
 * semantics in guests/rust/dirty.rs; the byte-frozen contract in
 * tools/scenes/dirty.steps.
 */
final class Dirty {
    static void app() {
        KayaApp app = new KayaApp();

        app.build(tx -> {
            KayaApp.WindowRef win = tx.window(0).title("dirty").vetoClose(true);
            KayaApp.Signal<String> doc = tx.signal("notes");
            KayaApp.Signal<String> status = tx.signal("saved");

            win.onCloseRequested(t -> {
                t.showAlert()
                        .title("unsaved changes")
                        .message("the document has unsaved changes")
                        .action("Discard")
                        .cancel("Keep Editing")
                        .onResult((t2, choice) -> {
                            if (choice == KayaWire.ALERT_CHOICE_CANCEL) {
                                t2.write(status, "kept editing");
                            } else {
                                // This call ABORTS if it ever runs; the
                                // scene answers cancel so it does not
                                // (docs/traps.md, "An app can VETO a
                                // close but cannot AGREE to one").
                                t2.destroyWindow(0);
                            }
                        })
                        .show();
            });

            tx.mount(tx.column(() -> {
                tx.label(doc); // label#0
                tx.label(status); // label#1
                // The document and the mark are two statements: neither
                // implies the other, so both are written here.
                tx.button("edit", t -> { // button#0
                    t.write(doc, "notes and a line");
                    t.write(status, "unsaved");
                    t.window(0).dirty(true);
                });
                tx.button("save", t -> { // button#1
                    t.write(status, "saved");
                    t.window(0).dirty(false);
                });
            }));
        });

        app.dispatchLoop();
    }

    private Dirty() {}
}
