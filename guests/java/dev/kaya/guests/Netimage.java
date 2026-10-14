package dev.kaya.guests;

import dev.kaya.KayaApp;
import dev.kaya.KayaApp.ImagePhase;
import dev.kaya.KayaGen;
import dev.kaya.KayaRecords;

import java.util.ArrayList;
import java.util.HashSet;
import java.util.List;
import java.util.Set;
import java.util.concurrent.LinkedBlockingQueue;

/**
 * The network images affordance scene from the JVM — guests/rust/netimage.rs,
 * tools/scenes/netimage.steps. No HTTP: each "download" is a job a worker
 * thread holds until a click releases it.
 */
public final class Netimage {
    @KayaGen(key = "String")
    record NetTrack(String title, String artUrl, byte[] art, ImagePhase phase) {}

    private static final int ROWS = 300;

    /** A live job (bytes, or null for a failure) or a row's. */
    private record Job(boolean live, byte[] bytes, String key, String url) {}

    private static Job live;
    private static List<Job> pending = new ArrayList<>();
    private static final Set<String> needed = new HashSet<>();
    private static final Set<String> ever = new HashSet<>();
    private static String twice;

    public static void app() {
        KayaApp app = new KayaApp();
        LinkedBlockingQueue<List<Job>> jobs = new LinkedBlockingQueue<>();

        byte[][] covers = new byte[3][];
        String[] names = {"covers/cover-600.jpg", "covers/cover-320.jpg", "covers/cover-1000.jpg"};
        for (int i = 0; i < 3; i++) {
            try (KayaApp.Asset a = KayaApp.asset(names[i])) {
                covers[i] = a.bytes();
            }
        }
        live = new Job(true, covers[0], null, null);

        record Handles(KayaApp.Signal<byte[]> art, KayaApp.Signal<ImagePhase> phase,
                KayaRecords.Collection<String, NetTrack> tracks) {}
        Handles h = app.build(tx -> {
            tx.window(0).title("netimage").size(820.0, 640.0);
            KayaApp.Signal<byte[]> art = tx.signal(new byte[0]);
            KayaApp.Signal<ImagePhase> phase = tx.signal(ImagePhase.LOADING);
            KayaApp.Signal<String> band = tx.signal("band: -");
            KayaApp.Signal<String> released = tx.signal("released: none");
            KayaApp.Signal<String> again = tx.signal("again: none");
            var tracks = NetTrackKaya.collection(tx);

            tx.mount(tx.column(root -> {
                tx.column(col -> {
                    tx.image(art).maxWidth(96).maxHeight(96).fit(KayaApp.Fit.COVER)
                            .phase(phase).a11yId("cover").a11yLabel("Cover");
                    tx.row(buttons -> {
                        tx.button("release", t -> {
                            if (live != null) {
                                jobs.add(List.of(live));
                                live = null;
                            }
                        }).a11yId("release");
                        tx.button("refresh", t -> {
                            live = new Job(true, covers[1], null, null);
                            t.write(phase, ImagePhase.LOADING);
                        }).a11yId("refresh");
                    });
                    tx.row(buttons -> {
                        tx.button("junk", t -> {
                            t.write(art, "not an image".getBytes(java.nio.charset.StandardCharsets.UTF_8));
                            t.write(phase, ImagePhase.SHOWN);
                        }).a11yId("junk");
                        tx.button("fail", t -> {
                            live = new Job(true, null, null, null);
                            t.write(art, new byte[0]);
                            t.write(phase, ImagePhase.LOADING);
                        }).a11yId("fail");
                    });
                    tx.row(buttons -> {
                        tx.button("rows", t -> {
                            needed.clear();
                            jobs.add(pending);
                            pending = new ArrayList<>();
                        }).a11yId("rows");
                        tx.button("delete", t -> t.remove(tracks.handle, "t299")).a11yId("delete");
                        tx.button("retarget", t -> {
                            pending.add(0, new Job(false, covers[2], "t298", "u/298b"));
                            NetTrackKaya.patch(t, tracks, "t298").artUrl("u/298b");
                        }).a11yId("retarget");
                    });
                    tx.label(band).a11yId("band");
                    tx.label(released).a11yId("released");
                    tx.label(again).a11yId("again");
                });
                var rows = NetTrackKaya.rows(tx, tracks);
                for (var row : rows) {
                    row.row(() -> {
                        KayaApp.Node image = row.image(row.art);
                        row.setFit(image, KayaApp.Fit.COVER);
                        row.setMaxWidth(image, 20);
                        row.setMaxHeight(image, 20);
                        row.setPhase(image, row.phase);
                        row.setA11yId(image, "art");
                        app.onNeeded(image, (t, keys) -> {
                            String key = (String) keys.get(0);
                            if (!needed.add(key) && twice == null) {
                                twice = key;
                            }
                            ever.add(key);
                            int i = Integer.parseInt(key.substring(1));
                            pending.add(new Job(false, covers[i % 3], key, "u/" + i));
                            t.write(band, ever.size() < ROWS ? "band: partial" : "band: " + ever.size());
                            t.write(again, "again: " + (twice == null ? "none" : twice));
                        });
                        app.onReleased(image, (t, keys) -> {
                            String key = (String) keys.get(0);
                            needed.remove(key);
                            pending.removeIf(j -> key.equals(j.key()));
                            t.write(released, "released: some");
                        });
                        row.label(row.title);
                    });
                }
                rows.columns(new String[] {"Art", "Title"}, KayaApp.Sort.none());
                rows.handle.a11yId("tracks");
                tx.setGrow(rows.handle, 1);
            }));
            for (int i = 0; i < ROWS; i++) {
                tracks.insert(tx, String.format("t%03d", i),
                        new NetTrack("Track " + i, "u/" + i, new byte[0], ImagePhase.LOADING));
            }
            return new Handles(art, phase, tracks);
        });

        Thread worker = new Thread(() -> {
            while (true) {
                List<Job> batch;
                try {
                    batch = jobs.take();
                } catch (InterruptedException e) {
                    return;
                }
                for (Job job : batch) {
                    if (job.live() && job.bytes() != null) {
                        app.post(t -> {
                            t.write(h.art(), job.bytes());
                            t.write(h.phase(), ImagePhase.SHOWN);
                        });
                    } else if (job.live()) {
                        app.post(t -> t.write(h.phase(), ImagePhase.FAILED));
                    } else {
                        app.post(t -> NetTrackKaya.patchIf(t, h.tracks(), job.key(),
                                NetTrackKaya.ART_URL, job.url()).art(job.bytes()).phase(ImagePhase.SHOWN));
                    }
                }
            }
        }, "netimage-worker");
        worker.setDaemon(true);
        worker.start();

        app.dispatchLoop();
    }

    private Netimage() {}
}
