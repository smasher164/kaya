package dev.kaya.guests;

import dev.kaya.KayaApp;
import dev.kaya.KayaApp.Tint;
import dev.kaya.KayaGen;

/** The cards scene from the JVM — guests/rust/cards.rs, tools/scenes/cards.steps. */
public final class Cards {
    @KayaGen(key = "String")
    record LibraryPlaylist(String name, boolean selected) {}

    private static final String[][] CARDS = {
        {"card1", "Daily Mix 1"}, {"card2", "Daily Mix 2"}, {"card3", "Discover Weekly"},
    };
    private static final String[][] LIBRARY = {
        {"p1", "Liked Songs"}, {"p2", "Late Night Jazz"}, {"p3", "Focus"},
    };

    public static void app() {
        KayaApp app = new KayaApp();
        app.build(tx -> {
            tx.window(0).title("cards").size(520.0, 520.0);
            KayaApp.Signal<String> status = tx.signal("opened: none");
            var library = LibraryPlaylistKaya.collection(tx);
            tx.mount(tx.column(root -> {
                tx.grid(3, cells -> {
                    for (String[] card : CARDS) {
                        KayaApp.Signal<String> title = tx.signal(card[1]);
                        KayaApp.Signal<String> line = tx.signal("Made for you");
                        tx.column(c -> {
                            tx.label(title);
                            tx.caption(line);
                        }).filled(Tint.NEUTRAL).a11yId(card[0])
                                .onActivate(t -> t.write(status, "opened: " + card[1]));
                    }
                }).spacing(12);
                tx.label(status).a11yId("status");
                for (var row : LibraryPlaylistKaya.rows(tx, library)) {
                    KayaApp.Node item = row.row(() -> row.label(row.name));
                    row.setA11yId(item, "lib");
                    row.setSelected(item, row.selected);
                    row.onActivate(item, (t, keys) -> {
                        String picked = (String) keys.get(0);
                        for (String[] entry : LIBRARY) {
                            LibraryPlaylistKaya.patch(t, library, entry[0]).selected(entry[0].equals(picked));
                        }
                    });
                }
            }).spacing(16));
            for (String[] entry : LIBRARY) {
                library.insert(tx, entry[0], new LibraryPlaylist(entry[1], false));
            }
            return null;
        });
        app.dispatchLoop();
    }

    private Cards() {}
}
