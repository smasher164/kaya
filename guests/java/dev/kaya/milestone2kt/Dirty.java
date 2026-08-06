package dev.kaya.milestone2kt;

import dev.kaya.KayaApp;
import dev.kaya.KayaWire;

/**
 * The dirty-state conformance scene from the JVM: unsaved work as
 * window chrome (docs/dirty-plan.md). One boolean beside {@code title}
 * and {@code vetoClose} — the app declares STATE and the backend
 * spells its platform's own affordance (the dot in the close button on
 * macOS, a leading {@code *} in the rendered caption on Windows, a
 * bullet in the GTK header bar, nothing on the phones, which have
 * none).
 *
 * <p>TWO DECLARATIONS, ON PURPOSE. An edit writes the document AND
 * says {@code .dirty(true)}; saving writes it back and says
 * {@code .dirty(false)}. kaya does not watch your signals and guess —
 * "the document has unsaved changes" is a statement only the app can
 * make, and the window prop is where it makes it.
 *
 * <p>AND THE MARK ARMS NOTHING. The close attempt fires the veto class
 * this window already opted into, the app opens its own dialog, and
 * cancelling keeps the window with the mark still up. That flow is
 * composed here out of parts that predate this prop — which is the
 * whole reason {@code dirty} is presentation and nothing else.
 *
 * <p>Canonical semantics in guests/rust/dirty.rs; the byte-frozen
 * contract in tools/scenes/dirty.steps.
 */
final class Dirty {
    static void app() {
        KayaApp app = new KayaApp();

        app.build(tx -> {
            // `dirty` and `vetoClose` are orthogonal — either can be
            // set without the other, on every platform. This window
            // takes both because it is an editor: it owns its close so
            // it can ask.
            KayaApp.WindowRef win = tx.window(0).title("dirty").vetoClose(true);
            KayaApp.Signal<String> doc = tx.signal("notes");
            KayaApp.Signal<String> status = tx.signal("saved");

            // The handler binds to THE WINDOW at its declaration: it
            // can only ever mean this surface's close was asked for.
            // Nothing has closed when it runs — the veto class says so
            // — and an editor with unsaved work asks; a clean one
            // agrees at once.
            win.onCloseRequested(t -> {
                t.showAlert()
                        .title("unsaved changes")
                        .message("the document has unsaved changes")
                        .action("Discard")
                        .cancel("Keep Editing")
                        .onResult((t2, choice) -> {
                            if (choice == KayaWire.ALERT_CHOICE_CANCEL) {
                                // Answering a dialog is not saving:
                                // the mark stays up either way.
                                t2.write(status, "kept editing");
                            } else {
                                // Agreeing destroys the surface, which
                                // for the PRIMARY window is the process
                                // itself — so the scene answers cancel
                                // and this arm stays the honest
                                // spelling of "yes, close it" rather
                                // than a step.
                                t2.destroyWindow(0);
                            }
                        })
                        .show();
            });

            tx.mount(tx.column(() -> {
                tx.label(doc); // label#0
                tx.label(status); // label#1
                // ONE TRANSACTION for the document and the mark: the
                // handler was handed it, and the composition this scene
                // exists to show is the two statements standing side by
                // side. Neither implies the other.
                tx.button("edit", t -> { // button#0
                    t.write(doc, "notes and a line");
                    t.write(status, "unsaved");
                    t.window(0).dirty(true);
                });
                // Saving clears both, so the mark comes DOWN as well as
                // up — a lowering that only ever sets the flag passes
                // every assertion before this one.
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
