package dev.kaya.guests;

import dev.kaya.KayaApp;
import dev.kaya.KayaApp.ImagePhase;
import dev.kaya.KayaGen;
import dev.kaya.KayaRecords;

/**
 * The network images scene over HTTP from the JVM —
 * guests/rust/netimage_http.rs, tools/scenes/netimage_http.steps: the row
 * image helper with its default fetch against the lane's media server.
 * Twelve rows share three covers; four fail or wait.
 */
public final class NetimageHttp {
    @KayaGen(key = "String")
    record HttpTrack(String title, String artUrl, byte[] art, ImagePhase phase) {}

    private static final String[] COVERS =
            {"covers/cover-600.jpg", "covers/cover-320.jpg", "covers/cover-1000.jpg"};
    private static int failures;

    public static void app() {
        String base = System.getenv("KAYA_MEDIA_URL");
        if (base == null) {
            throw new IllegalStateException(
                    "kaya: the netimage_http scene reads KAYA_MEDIA_URL, the local server the lane "
                            + "starts (tools/lib/media_server.py)");
        }
        KayaApp app = new KayaApp();

        app.build(tx -> {
            tx.window(0).title("netimage_http").size(640.0, 560.0);
            KayaApp.Signal<String> errors = tx.signal("errors: 0");
            var tracks = HttpTrackKaya.collection(tx);
            var images = new KayaRecords.RowImages<>(app, tracks,
                    HttpTrack::artUrl, HttpTrack::art, HttpTrack::phase)
                    .onError((t, keys, why) -> t.write(errors, "errors: " + (++failures)));

            tx.mount(tx.row(root -> {
                tx.label(errors).a11yId("errors");
                var rows = HttpTrackKaya.rows(tx, tracks);
                for (var row : rows) {
                    row.row(() -> {
                        KayaApp.Node image = row.image(row.art);
                        row.setFit(image, KayaApp.Fit.COVER);
                        row.setMaxWidth(image, 20);
                        row.setMaxHeight(image, 20);
                        row.setPhase(image, row.phase);
                        row.setA11yId(image, "art");
                        images.attach(image);
                        row.label(row.title);
                    });
                }
                rows.columns(new String[] {"Art", "Title"}, KayaApp.Sort.none());
                tx.setGrow(rows.handle, 1);
            }));
            String[][] special = {
                {"missing", "status/404/"},
                {"broken", "status/500/"},
                {"junk", "covers/README.md"},
                {"slow", "trickle/covers/cover-600.jpg"},
            };
            for (String[] s : special) {
                tracks.insert(tx, s[0], new HttpTrack(s[0], base + "/" + s[1], new byte[0], ImagePhase.LOADING));
            }
            for (int i = 0; i < 12; i++) {
                tracks.insert(tx, String.format("a%02d", i), new HttpTrack("Track " + i,
                        base + "/" + COVERS[i % 3], new byte[0], ImagePhase.LOADING));
            }
            return null;
        });

        app.dispatchLoop();
    }

    private NetimageHttp() {}
}
