package dev.kaya.guests;

import dev.kaya.KayaApp;
import java.util.List;
import java.util.Map;
import java.util.stream.Collectors;

/**
 * The document-tabs scene from the JVM — guests/rust/doctabs.rs,
 * tools/scenes/doctabs.steps (docs/doctabs-plan.md §5): three documents, one
 * armed against a close, a shared region beside them, the "+", and a
 * programmatic select that echoes nothing.
 */
public final class Doctabs {
    static final long A = 10, B = 11, C = 12, NOTES = 30;
    static final Map<Long, String> NAMES = Map.of(A, "a", B, "b", C, "c");

    public static void app() {
        KayaApp app = new KayaApp();
        long[] untitled = {0};
        long[] regions = {0};

        app.build(tx -> {
            KayaApp.Signal<String> status = tx.signal("ready");

            // THE ONE BUILDER every window's shared region comes from, the
            // first window's and a torn-out one's alike (§1.2).
            Region region = (t, window, id) -> {
                t.addRegionIn(window, id, KayaApp.RegionEdge.LEADING);
                t.mountIn(id, t.column(col -> {
                    t.label(status).a11yId("status");
                    t.entry().a11yId("note");
                    t.button("to a", t2 -> t2.selectDocument(A)).a11yId("first");
                }));
            };

            tx.window(0).title("doctabs").size(640, 420).newDocument(true)
                    .onNewDocument(t -> {
                        untitled[0]++;
                        String name = "untitled " + untitled[0];
                        long id = 100 + untitled[0];
                        t.addDocument(id).title(name).select();
                        KayaApp.Signal<String> caption = t.signal(name + " body");
                        t.mountIn(id, t.column(col -> {
                            t.label(caption);
                        }));
                        t.write(status, "new " + name);
                    })
                    .onDocumentsCloseRequested((t, documents) ->
                            t.write(status, "asked about " + documents.size()))
                    .onDocumentsDetached((t, window, documents) -> {
                        regions[0]++;
                        region.build(t, window, 300 + regions[0]);
                        t.write(status, "detached " + documents.stream()
                                .map(d -> NAMES.getOrDefault(d, "untitled"))
                                .collect(Collectors.joining(" ")));
                    });

            for (long id : List.of(A, B, C)) {
                String name = NAMES.get(id);
                KayaApp.DocumentRef doc = tx.addDocument(id).title(name).tooltip("/documents/" + name)
                        .onSelected(t -> t.write(status, "selected " + name))
                        .onClosed(t -> t.write(status, "closed " + name))
                        .onMoved((t, window, index) -> t.write(status, "moved " + name + " to " + index));
                KayaApp.Signal<String> caption = tx.signal(name + " body");
                tx.mountIn(id, tx.column(col -> {
                    tx.label(caption).a11yId("body-" + name);
                    tx.entry().a11yId("field-" + name);
                    if (id == B) {
                        tx.button("mark b", t -> {
                            t.document(B).dirty(true);
                            t.write(status, "marked b");
                        }).a11yId("mark");
                    }
                }));
                if (id == B) {
                    doc.interceptClose(true).onCloseRequested(t -> t.showAlert()
                            .title("unsaved changes")
                            .message("b has unsaved changes")
                            .action("Discard")
                            .cancel("Keep Editing")
                            .onResult((t2, choice) -> {
                                if (choice == KayaApp.AlertChoice.CANCEL) {
                                    t2.write(status, "kept b");
                                    return;
                                }
                                t2.closeDocument(B);
                                t2.write(status, "discarded b");
                            })
                            .show());
                }
            }
            region.build(tx, 0, NOTES);
        });

        app.dispatchLoop();
    }

    interface Region {
        void build(KayaApp.Tx tx, long window, long id);
    }

    private Doctabs() {}
}
