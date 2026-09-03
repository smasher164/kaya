package dev.kaya.guests;

import dev.kaya.KayaApp;
import dev.kaya.KayaWire;

/**
 * The dirty scene from the JVM — guests/rust/dirty.rs, tools/scenes/dirty.steps.
 */
public final class Dirty {
    public static void app() {
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
                                // Aborts if it ever runs (docs/traps.md, an app
                                // can VETO a close but cannot AGREE to one).
                                t2.destroyWindow(0);
                            }
                        })
                        .show();
            });

            tx.mount(tx.column(() -> {
                tx.label(doc); // label#0
                tx.label(status); // label#1
                // The document and the mark are two statements.
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
