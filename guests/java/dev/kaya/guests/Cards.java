package dev.kaya.guests;

import dev.kaya.KayaApp;
import dev.kaya.KayaApp.Symbol;
import dev.kaya.KayaApp.Tint;
import dev.kaya.KayaGen;

/** The cards scene from the JVM — guests/rust/cards.rs, tools/scenes/cards.steps. */
public final class Cards {
    @KayaGen(key = "String")
    record LibraryPlaylist(String name, boolean selected, Symbol symbol) {}

    private static final String[][] CARDS = {
        {"card1", "Daily Mix 1"}, {"card2", "Daily Mix 2"}, {"card3", "Discover Weekly"},
    };
    // The third card is taller, so the row's cards take its height (M16 (1)).
    private static final String TALL = "card3";
    // Cut at two lines with the platform's ellipsis (M16 (2)).
    private static final String BLURB = "Fresh picks every Monday, from the artists you play the most and the ones they listen to";
    private static final String[][] LIBRARY = {
        {"p1", "Liked Songs"}, {"p2", "Late Night Jazz"}, {"p3", "Focus"},
    };

    private static KayaApp.Widget card(KayaApp.Tx tx, KayaApp.Signal<String> status, String id, String name) {
        KayaApp.Signal<String> title = tx.signal(name);
        KayaApp.Signal<String> line = tx.signal("Made for you");
        KayaApp.Signal<String> blurb = tx.signal(BLURB);
        return tx.column(c -> {
            tx.label(title);
            tx.caption(line);
            if (id.equals(TALL)) {
                tx.caption(blurb).maxLines(2).a11yId("blurb");
            }
        }).filled(Tint.NEUTRAL).a11yId(id).onActivate(t -> t.write(status, "opened: " + name));
    }

    public static void app() {
        KayaApp app = new KayaApp();
        app.build(tx -> {
            tx.window(0).title("cards").size(520.0, 520.0);
            KayaApp.Signal<String> status = tx.signal("opened: none");
            var library = LibraryPlaylistKaya.collection(tx);
            // A section hidden by a When and an empty For take no space (M16 (3)).
            KayaApp.Signal<Boolean> hidden = tx.signal(false);
            var empty = LibraryPlaylistKaya.collection(tx);
            tx.mount(tx.column(root -> {
                KayaApp.Widget grid = tx.grid(1, cells -> {
                    for (String[] c : CARDS) {
                        card(tx, status, c[0], c[1]);
                    }
                }).spacing(12).columnsAuto(140).a11yId("cards");
                tx.button("More", t -> t.within(grid, () -> card(t, status, "card4", "Release Radar"))).a11yId("more");
                tx.label(status).a11yId("status");
                tx.when(hidden, t -> {
                    t.label("never shown");
                });
                for (var row : LibraryPlaylistKaya.rows(tx, empty)) {
                    row.row(() -> row.label(row.name));
                }
                tx.label("end").a11yId("end");
                for (var row : LibraryPlaylistKaya.rows(tx, library)) {
                    KayaApp.Node[] item = new KayaApp.Node[1];
                    row.row(() -> {
                        item[0] = row.row(() -> row.label(row.name));
                        KayaApp.Node play = row.button("Play");
                        row.setSymbol(play, row.symbol);
                        row.setA11yId(play, "go");
                        app.onClick(play, (t, keys) -> {
                            String played = (String) keys.get(0);
                            for (String[] entry : LIBRARY) {
                                LibraryPlaylistKaya.patch(t, library, entry[0])
                                        .symbol(entry[0].equals(played) ? Symbol.PAUSE : Symbol.PLAY);
                            }
                        });
                    });
                    row.setA11yId(item[0], "lib");
                    row.setSelected(item[0], row.selected);
                    row.onActivate(item[0], (t, keys) -> {
                        String picked = (String) keys.get(0);
                        for (String[] entry : LIBRARY) {
                            LibraryPlaylistKaya.patch(t, library, entry[0]).selected(entry[0].equals(picked));
                        }
                    });
                }
            }).spacing(16));
            for (String[] entry : LIBRARY) {
                library.insert(tx, entry[0], new LibraryPlaylist(entry[1], false, Symbol.PLAY));
            }
            return null;
        });
        app.dispatchLoop();
    }

    private Cards() {}
}
