package dev.kaya.guests;

import dev.kaya.KayaApp;
import java.util.List;

/**
 * The restored shape from the JVM — guests/rust/restoredocs.rs,
 * tools/scenes/restoredocs.steps (docs/restoration-plan.md SR9): each
 * document's title and text live in its own session scope, and act two
 * recreates the documents the last launch left, takes each scope back, and
 * selects the active one.
 */
public final class Restoredocs {
    public static void app() {
        KayaApp app = new KayaApp();
        List<Long> documents = List.of(10L, 11L, 12L);
        long active = 0;
        var primary = KayaApp.restoredWindows().stream().filter(w -> w.id() == 0).findFirst();
        if (primary.isPresent()) {
            documents = primary.get().documents();
            active = primary.get().activeDocument();
        } else {
            String[] titles = {"a", "b", "c"};
            for (int i = 0; i < titles.length; i++) {
                KayaApp.documentSession(documents.get(i)).setString("title", titles[i]);
            }
        }
        List<Long> docs = documents;
        long selected = active;

        app.build(tx -> {
            tx.window(0).title("restoredocs").size(640, 420);
            for (long id : docs) {
                KayaApp.SessionHandle scope = KayaApp.documentSession(id);
                String title = scope.getString("title", "untitled");
                tx.addDocument(id).title(title).restore(id);
                KayaApp.Signal<String> caption = tx.signal(title + " body");
                tx.mountIn(id, tx.column(col -> {
                    tx.label(caption).a11yId("caption-" + title);
                    KayaApp.Widget field = tx.entry().a11yId("body-" + title);
                    tx.setText(field, scope.getString("body", ""));
                    app.onChange(field, (t, text) -> scope.setString("body", text));
                    tx.button("recall", t -> t.write(caption,
                            KayaApp.documentSession(id).getString("title", "untitled") + " body"))
                            .a11yId("recall-" + title);
                }));
            }
            if (selected != 0) {
                tx.selectDocument(selected);
            }
        });

        app.dispatchLoop();
    }
}
