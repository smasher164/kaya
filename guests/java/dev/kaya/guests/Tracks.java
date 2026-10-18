package dev.kaya.guests;

import dev.kaya.KayaApp;
import dev.kaya.KayaApp.Fit;
import dev.kaya.KayaApp.Shape;
import dev.kaya.KayaApp.Tint;
import dev.kaya.KayaGen;
import dev.kaya.KayaRecords;

/** The tracks scene from the JVM — guests/rust/tracks.rs, tools/scenes/tracks.steps. */
public final class Tracks {
    @KayaGen(key = "String")
    record PlaylistTrack(String number, String title, String artist, String album, byte[] art, Tint titleTint,
            boolean selected) {}

    private static final int PLAYLIST = 60;
    private static final int PLAYING = 3;
    private static final String[][] NAMES = {
        {"Blue in Green", "Miles Davis", "Kind of Blue"},
        {"So What", "Miles Davis", "Kind of Blue"},
        {"Naima", "John Coltrane", "Giant Steps"},
    };

    private static KayaApp.Widget table(KayaApp.Tx tx, KayaRecords.Collection<String, PlaylistTrack> tracks,
            String id, String rowId, java.util.function.BiConsumer<KayaApp.Tx, String> pick,
            java.util.function.BiConsumer<KayaApp.Tx, String> play) {
        var rows = PlaylistTrackKaya.rows(tx, tracks);
        for (var row : rows) {
            KayaApp.Node line = row.row(() -> {
                row.label(row.number);
                row.row(() -> {
                    KayaApp.Node image = row.image(row.art);
                    row.setFit(image, Fit.COVER);
                    row.setMaxWidth(image, 40);
                    row.setMaxHeight(image, 40);
                    row.setShape(image, Shape.ROUNDED);
                    row.setA11yId(image, "art");
                    row.column(() -> {
                        KayaApp.Node title = row.label(row.title);
                        row.setTint(title, row.titleTint);
                        row.setA11yId(title, "name");
                        row.caption(row.artist);
                    });
                });
                row.label(row.album);
            });
            row.setA11yId(line, rowId);
            row.setSelected(line, row.selected);
            row.onSelect(line, (t, keys) -> pick.accept(t, (String) keys.get(0)));
            row.onActivate(line, (t, keys) -> play.accept(t, (String) keys.get(0)));
        }
        rows.columns(new String[] {"#", "Title", "Album"}, KayaApp.Sort.none());
        rows.handle.a11yId(id);
        return rows.handle;
    }

    private static PlaylistTrack track(int i, byte[] art) {
        String[] n = NAMES[i % NAMES.length];
        return new PlaylistTrack(Integer.toString(i + 1), n[0], n[1], n[2], art,
                i + 1 == PLAYING ? Tint.ACCENT : Tint.NONE, false);
    }

    public static void app() {
        KayaApp app = new KayaApp();
        byte[] art;
        try (KayaApp.Asset a = KayaApp.asset("covers/cover-600.jpg")) {
            art = a.bytes();
        }
        app.build(tx -> {
            tx.window(0).title("tracks").size(720.0, 640.0);
            var album = PlaylistTrackKaya.collection(tx);
            var playlist = PlaylistTrackKaya.collection(tx);
            KayaApp.Signal<String> pickedText = tx.signal("picked: none");
            KayaApp.Signal<String> played = tx.signal("played: none");
            java.util.function.BiConsumer<KayaApp.Tx, String> select = (t, picked) -> {
                for (int i = 0; i < NAMES.length; i++) {
                    PlaylistTrackKaya.patch(t, album, "a" + (i + 1)).selected(("a" + (i + 1)).equals(picked));
                }
                for (int i = 0; i < PLAYLIST; i++) {
                    PlaylistTrackKaya.patch(t, playlist, "t" + (i + 1)).selected(("t" + (i + 1)).equals(picked));
                }
            };
            java.util.function.BiConsumer<KayaApp.Tx, String> pick = (t, picked) -> {
                t.write(pickedText, "picked: " + picked);
                select.accept(t, picked);
            };
            java.util.function.BiConsumer<KayaApp.Tx, String> play = (t, picked) -> {
                t.write(played, "played: " + picked);
                select.accept(t, picked);
            };
            tx.mount(tx.column(root -> {
                tx.label(pickedText).a11yId("picked");
                tx.label(played).a11yId("played");
                table(tx, album, "album", "a", pick, play);
                tx.setGrow(table(tx, playlist, "tracks", "t", pick, play), 1);
            }).spacing(12));
            for (int i = 0; i < NAMES.length; i++) {
                album.insert(tx, "a" + (i + 1), track(i, art));
            }
            for (int i = 0; i < PLAYLIST; i++) {
                playlist.insert(tx, "t" + (i + 1), track(i, art));
            }
            return null;
        });
        app.dispatchLoop();
    }

    private Tracks() {}
}
