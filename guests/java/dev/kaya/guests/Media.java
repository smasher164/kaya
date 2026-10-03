package dev.kaya.guests;

import dev.kaya.KayaApp;
import dev.kaya.KayaApp.MediaSource;
import dev.kaya.KayaApp.PlayerState;
import dev.kaya.KayaApp.PlayerTracks;
import dev.kaya.KayaApp.SessionActionKind;
import dev.kaya.KayaGen;

import java.math.BigDecimal;
import java.math.RoundingMode;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.List;
import java.util.OptionalInt;

/**
 * The media suite from the JVM — guests/rust/media.rs,
 * tools/scenes/media_{formats,delivery,session,tracks,feed,reader}.steps,
 * docs/media-plan.md §7a, §7b.
 */
public final class Media {
    @KayaGen(key = "Long")
    record FeedClip(String name, KayaApp.Player player) {}

    private record Item(String name, MediaSource source, String mime, String codecs) {}

    private static final String H264 = "avc1.64000b, mp4a.40.2";
    private static final String HEVC = "hvc1.1.6.L60.90, mp4a.40.2";
    private static final String AV1 = "av01.0.00M.08, mp4a.40.2";

    private static Item local(String name, String mime, String codecs) {
        return new Item(name, MediaSource.asset("media/" + name), mime, codecs);
    }

    private static Item served(String base, String name, String mime, String codecs) {
        return new Item(name, MediaSource.url(base + "/" + name), mime, codecs);
    }

    private static List<Item> formats() {
        return List.of(
                local("h264_aac.mp4", "video/mp4", H264),
                local("hevc_aac.mp4", "video/mp4", HEVC),
                local("hevc_aac.mov", "video/quicktime", HEVC),
                local("vp9_opus.webm", "video/webm", "vp09.00.10.08, opus"),
                local("vp9_aac.mp4", "video/mp4", "vp09.00.10.08, mp4a.40.2"),
                local("av1_aac.mp4", "video/mp4", AV1),
                local("av1_opus.webm", "video/webm", "av01.0.00M.08, opus"),
                local("tone.mp3", "audio/mpeg", ""),
                local("tone.m4a", "audio/mp4", "mp4a.40.2"),
                local("tone.ogg", "audio/ogg", "opus"),
                local("tone_opus.webm", "audio/webm", "opus"),
                local("tone.flac", "audio/flac", ""),
                local("tone.wav", "audio/wav", ""));
    }

    private static String mediaUrl() {
        String base = System.getenv("KAYA_MEDIA_URL");
        if (base == null) {
            throw new IllegalStateException(
                    "kaya: the media scenes that stream read KAYA_MEDIA_URL, the local server the lane "
                            + "starts (tools/lib/media_server.py); a hand run goes through tools/run-leg.py");
        }
        return base;
    }

    /** The local server's items, and the three failures: a 404, a local
     * file that is not there, and a port nothing listens on. */
    private static List<Item> delivery() {
        String base = mediaUrl();
        int colon = base.lastIndexOf(':');
        String refused = colon < 0 ? base : base.substring(0, colon) + ":9";
        return List.of(
                served(base, "h264_aac.mp4", "video/mp4", H264),
                served(base, "hls_fmp4.m3u8", "application/vnd.apple.mpegurl", ""),
                served(base, "hls_mpegts.m3u8", "application/vnd.apple.mpegurl", ""),
                served(base, "dash.mpd", "application/dash+xml", ""),
                served(base, "nope.mp4", "video/mp4", H264),
                local("missing.mp4", "video/mp4", H264),
                new Item("refused.mp4", MediaSource.url(refused + "/h264_aac.mp4"), "video/mp4", H264));
    }

    private static String yesNo(boolean b) {
        return b ? "yes" : "no";
    }

    /** Rust's `{:.1}`: the double's exact value, ties to even. */
    private static String seconds(long ms) {
        return new BigDecimal(ms / 1000.0).setScale(1, RoundingMode.HALF_EVEN).toPlainString();
    }

    public static void app() {
        String scene = System.getenv("KAYA_SELFTEST");
        scene = scene == null ? "" : scene;
        switch (scene) {
            case "media_tracks" -> tracksApp();
            case "media_feed" -> feedApp();
            case "media_reader" -> readerApp();
            default -> playerApp(scene);
        }
    }

    private static final class Walk {
        int at;
        boolean can;
        long furthest;
        int nexts;
    }

    private static void playerApp(String scene) {
        boolean session = scene.equals("media_session");
        List<Item> items = scene.equals("media_delivery") ? delivery() : formats();
        KayaApp app = new KayaApp();
        Walk w = new Walk();
        app.build(tx -> {
            tx.window(0).title("media");
            KayaApp.Signal<String> summary = tx.signal("idle");
            KayaApp.Signal<String> name = tx.signal(session ? "next 0" : "none");
            KayaApp.Player player = tx.player().muted(true).looping(session);
            tx.mount(tx.column(col -> {
                tx.label(summary); // label#0
                tx.label(name); // label#1
                tx.video(player).a11yId("clip").a11yLabel("Clip"); // video#0
                tx.button(session ? "play" : "next", t -> { // button#0
                    if (session) {
                        if (app.player(player).state() == PlayerState.IDLE) {
                            t.playerSource(player, MediaSource.asset("media/h264_aac.mp4"));
                        }
                        t.play(player);
                        return;
                    }
                    if (w.at >= items.size()) {
                        return;
                    }
                    Item item = items.get(w.at++);
                    w.can = KayaApp.canPlay(item.mime(), item.codecs());
                    w.furthest = 0;
                    t.playerSource(player, item.source());
                    t.write(name, item.name());
                    t.write(summary, "loading");
                });
            }));
            if (session) {
                tx.session()
                        .player(player)
                        .title("kaya media")
                        .artist("kaya")
                        .handles(SessionActionKind.NEXT)
                        .declare();
            }
            app.onPlayerState(player, (t, state) -> {
                if (session) {
                    if (state == PlayerState.PLAYING || state == PlayerState.PAUSED) {
                        t.write(summary, state.toString());
                    }
                } else if (state == PlayerState.READY) {
                    t.play(player);
                } else if (state == PlayerState.ENDED) {
                    KayaApp.PlayerReading r = app.player(player);
                    String played = w.furthest >= 1000 ? "played past 1s" : "played to " + w.furthest + "ms";
                    t.write(summary, "ready " + seconds(r.durationMs()) + "s " + r.width() + "x" + r.height()
                            + ", " + played + ", ended, can_play " + yesNo(w.can));
                }
            });
            app.onFailed(player, (t, why, detail) ->
                    t.write(summary, "failed " + why + ", can_play " + yesNo(w.can)));
            app.onPosition(player, (t, ms) -> w.furthest = Math.max(w.furthest, ms));
            app.onSession((t, action) -> {
                if (action.kind() == SessionActionKind.NEXT) {
                    w.nexts++;
                    t.write(name, "next " + w.nexts);
                }
            });
            return null;
        });
        app.dispatchLoop();
    }

    /** One track list as a line: {@code audio en, fr [2]}, the selection
     * counting from 1, {@code -} for none; {@code audio none} for an empty
     * list. */
    private static String trackLine(String what, List<String> tags, OptionalInt selected) {
        if (tags.isEmpty()) {
            return what + " none";
        }
        String pick = selected.isPresent() ? String.valueOf(selected.getAsInt() + 1) : "-";
        return what + " " + String.join(", ", tags) + " [" + pick + "]";
    }

    private record TrackItem(Item item, MediaSource sidecar) {}

    /** media_tracks (docs/media-plan.md §3, §7a): each item's audio and
     * caption listing, a second audio track selected, the last caption
     * track selected, and the cue read at 0.5 s and 1.5 s with the player
     * paused there. The sidecar items are the floor file with captions.vtt (the
     * first over h264_frames.mp4): an asset, then fetched from the local
     * server, then a 404 there. */
    private static void tracksApp() {
        String base = mediaUrl();
        Item floor = local("h264_aac.mp4", "video/mp4", H264);
        List<TrackItem> items = List.of(
                new TrackItem(local("h264_2audio.mp4", "video/mp4", H264), null),
                new TrackItem(local("vp9_2audio.webm", "video/webm", "vp09.00.10.08, opus"), null),
                new TrackItem(served(base, "hls_fmp4.m3u8", "application/vnd.apple.mpegurl", ""), null),
                new TrackItem(served(base, "hls_mpegts.m3u8", "application/vnd.apple.mpegurl", ""), null),
                new TrackItem(local("h264_tx3g.mp4", "video/mp4", H264), null),
                new TrackItem(new Item("h264_frames.mp4 + captions.vtt", MediaSource.asset("media/h264_frames.mp4"),
                        "video/mp4", H264), MediaSource.asset("media/captions.vtt")),
                new TrackItem(new Item("h264_aac.mp4 + http captions.vtt", floor.source(), floor.mime(),
                        floor.codecs()), MediaSource.url(base + "/captions.vtt")),
                new TrackItem(new Item("h264_aac.mp4 + http nope.vtt", floor.source(), floor.mime(),
                        floor.codecs()), MediaSource.url(base + "/nope.vtt")));
        KayaApp app = new KayaApp();
        Walk w = new Walk();
        app.build(tx -> {
            tx.window(0).title("media tracks");
            KayaApp.Signal<String> summary = tx.signal("idle");
            KayaApp.Signal<String> name = tx.signal("none");
            KayaApp.Signal<String> audio = tx.signal("audio none");
            KayaApp.Signal<String> captions = tx.signal("captions none");
            KayaApp.Signal<String> cue = tx.signal("");
            KayaApp.Player player = tx.player().muted(true);
            tx.mount(tx.column(col -> {
                tx.label(summary); // label#0
                tx.label(name); // label#1
                tx.label(audio); // label#2
                tx.label(captions); // label#3
                tx.label(cue); // label#4
                tx.video(player).a11yId("clip").a11yLabel("Clip"); // video#0
                tx.button("next", t -> { // button#0
                    if (w.at >= items.size()) {
                        return;
                    }
                    TrackItem ti = items.get(w.at++);
                    w.can = KayaApp.canPlay(ti.item().mime(), ti.item().codecs());
                    if (ti.sidecar() != null) {
                        t.playerCaptions(player, ti.sidecar(), "en");
                    } else {
                        t.clearCaptions(player);
                    }
                    t.playerSource(player, ti.item().source());
                    t.write(name, ti.item().name());
                    t.write(summary, "loading");
                    t.write(cue, "");
                });
                tx.button("audio 2", t -> t.selectAudio(player, 1)); // button#1
                tx.button("captions", t -> { // button#2
                    int listed = app.tracks(player).captions().size();
                    if (listed == 0) {
                        t.write(cue, "captions none");
                    } else {
                        t.selectCaptions(player, listed - 1);
                    }
                });
                tx.button("at 0.5s", t -> { // button#3
                    t.pause(player);
                    t.seek(player, 500);
                });
                tx.button("at 1.5s", t -> { // button#4
                    t.pause(player);
                    t.seek(player, 1500);
                });
                tx.button("captions off", t -> t.captionsOff(player)); // button#5
                tx.button("play", t -> { // button#6
                    t.seek(player, 0);
                    t.play(player);
                });
            }));
            app.onPlayerState(player, (t, state) -> {
                if (state == PlayerState.READY) {
                    t.write(summary, "ready, can_play " + yesNo(w.can));
                }
            });
            app.onFailed(player, (t, why, detail) -> {
                String line = "failed " + why + ", can_play " + yesNo(w.can);
                t.write(summary, line);
                t.write(audio, line);
            });
            app.onTracks(player, (t, tracks) -> {
                t.write(audio, trackLine("audio", tracks.audio(), tracks.audioSelected()));
                t.write(captions, trackLine("captions", tracks.captions(), tracks.captionSelected()));
            });
            app.onCue(player, (t, text) -> t.write(cue, text));
            return null;
        });
        app.dispatchLoop();
    }

    private static final int FEED_ROWS = 10;

    /** media_feed (docs/media-plan.md §7b): a scroll of rows, each a video
     * view showing its row's own player, paused on its first frame; the
     * first and last rows' visibility in label#0 and label#1. */
    private static void feedApp() {
        KayaApp app = new KayaApp();
        app.build(tx -> {
            tx.window(0).title("media feed").size(420.0, 480.0);
            KayaApp.Signal<String> first = tx.signal("r0 out");
            KayaApp.Signal<String> last = tx.signal("r" + (FEED_ROWS - 1) + " out");
            var clips = FeedClipKaya.collection(tx);
            KayaApp.Node[] video = new KayaApp.Node[1];
            tx.mount(tx.column(col -> {
                tx.label(first); // label#0
                tx.label(last); // label#1
                tx.scroll(s -> {
                    tx.column(c -> {
                        for (var row : FeedClipKaya.rows(tx, clips)) {
                            row.label(row.name);
                            video[0] = row.video(row.player);
                        }
                    });
                }).grow(1.0);
            }));
            for (int i = 0; i < FEED_ROWS; i++) {
                KayaApp.Player player = tx.player().muted(true).source(MediaSource.asset("media/h264_aac.mp4"));
                clips.insert(tx, (long) i, new FeedClip("r" + i, player));
            }
            app.onVisibility(video[0], (t, keys, shown) -> {
                int row = ((Long) keys.get(0)).intValue();
                String word = shown >= 0.999 ? "whole" : shown > 0.0 ? "in" : "out";
                if (row == 0) {
                    t.write(first, "r0 " + word);
                }
                if (row == FEED_ROWS - 1) {
                    t.write(last, "r" + row + " " + word);
                }
            });
            return null;
        });
        app.dispatchLoop();
    }

    /** The answered times as the labels spell them: each time asked, then
     * the time of the picture the platform returned, in ms. */
    private static String frameLine(String what, List<KayaApp.Frame> frames, KayaApp.ReadOutcome outcome) {
        List<KayaApp.Frame> sorted = new ArrayList<>(frames);
        sorted.sort(Comparator.comparingInt(KayaApp.Frame::index));
        StringBuilder line = new StringBuilder(what);
        for (KayaApp.Frame f : sorted) {
            line.append(' ').append(f.requestedMs()).append('@').append(f.actualMs());
        }
        return line.append(' ').append(outcomeWord(outcome)).toString();
    }

    private static String outcomeWord(KayaApp.ReadOutcome outcome) {
        return switch (outcome) {
            case KayaApp.ReadOutcome.Completed c -> "completed";
            case KayaApp.ReadOutcome.Cancelled c -> "cancelled";
            case KayaApp.ReadOutcome.Failed f -> "failed " + f.reason();
        };
    }

    private static final KayaApp.Viewbox STRIP = new KayaApp.Viewbox(320.0, 45.0);
    private static final KayaApp.Viewbox WAVE = new KayaApp.Viewbox(200.0, 60.0);
    /** h264_frames.mp4's grey bands: frame 12 and frame 37 at 25 fps, its
     * one keyframe at 0 (tools/gen-media.py). */
    private static final long[] BANDS = {480, 1480};

    private static final class Reads {
        final List<KayaApp.Frame> exact = new ArrayList<>();
        final List<KayaApp.Frame> keyframe = new ArrayList<>();
        final List<String> failures = new ArrayList<>();
        final List<String> missing = new ArrayList<>();
        final List<String> cancels = new ArrayList<>();
        KayaApp.Reader trickle;
        KayaApp.Read trickleRead;
        KayaApp.Reader closing;
    }

    private static double waveY(short v) {
        return 30.0 - v * 25.0 / 8192.0;
    }

    /** media_reader (docs/media-plan.md §8 rulings 3 and 4): a reader with
     * no player draws a filmstrip of h264_frames.mp4's exact and keyframe
     * pictures and a waveform of tone.wav's peaks beside two loaded images;
     * a read the server never finishes is cancelled and another is closed
     * under its reader; a file that is not media and a missing file fail. */
    private static void readerApp() {
        String base = mediaUrl();
        KayaApp app = new KayaApp();
        Reads w = new Reads();
        app.build(tx -> {
            tx.window(0).title("media reader").size(560.0, 560.0);
            List<KayaApp.Signal<String>> labels = new ArrayList<>();
            for (String s : List.of("exact", "keyframe", "peaks", "cancel", "failures", "no track")) {
                labels.add(tx.signal(s));
            }
            KayaApp.Widget[] canvases = new KayaApp.Widget[2];
            tx.mount(tx.column(col -> {
                for (KayaApp.Signal<String> label : labels) {
                    tx.label(label); // label#0..#5
                }
                canvases[0] = tx.canvas(STRIP).a11yId("strip").a11yLabel("Filmstrip");
                canvases[1] = tx.canvas(WAVE).a11yId("wave").a11yLabel("Waveform");
                tx.button("start", t -> { // button#0
                    w.trickle = t.reader(MediaSource.url(base + "/trickle/h264_frames.mp4"));
                    w.trickleRead = t.readFrames(w.trickle, new long[] {0}, 80, 45, KayaApp.FrameAccuracy.EXACT);
                    app.onReadDone(w.trickleRead, (u, o) -> noted(u, labels.get(3), w.cancels, "trickle", o));
                    w.closing = t.reader(MediaSource.url(base + "/trickle/h264_aac.mp4"));
                    KayaApp.Read closingRead = t.readFrames(w.closing, new long[] {0}, 80, 45,
                            KayaApp.FrameAccuracy.EXACT);
                    app.onReadDone(closingRead, (u, o) -> noted(u, labels.get(3), w.cancels, "closed", o));
                    t.write(labels.get(3), "reading");
                });
                tx.button("cancel", t -> { // button#1
                    if (w.trickle != null) {
                        t.cancelRead(w.trickle, w.trickleRead);
                        t.closeReader(w.closing);
                        w.trickle = null;
                    }
                });
            }));
            KayaApp.Widget strip = canvases[0];
            KayaApp.Widget wave = canvases[1];

            KayaApp.Reader clip = tx.reader(MediaSource.asset("media/h264_frames.mp4"));
            KayaApp.Read exact = tx.readFrames(clip, BANDS, 80, 45, KayaApp.FrameAccuracy.EXACT);
            app.onFrame(exact, (t, f) -> w.exact.add(f));
            app.onReadDone(exact, (t, o) -> {
                t.write(labels.get(0), frameLine("exact", w.exact, o));
                KayaApp.Read keyframe = t.readFrames(clip, BANDS, 80, 45, KayaApp.FrameAccuracy.KEYFRAME);
                app.onFrame(keyframe, (u, f) -> w.keyframe.add(f));
                app.onReadDone(keyframe, (u, ko) -> {
                    u.write(labels.get(1), frameLine("keyframe", w.keyframe, ko));
                    List<KayaApp.Frame> tiles = new ArrayList<>();
                    for (List<KayaApp.Frame> frames : List.of(w.exact, w.keyframe)) {
                        List<KayaApp.Frame> sorted = new ArrayList<>(frames);
                        sorted.sort(Comparator.comparingInt(KayaApp.Frame::index));
                        tiles.addAll(sorted);
                    }
                    u.draw(strip, d -> {
                        for (int i = 0; i < tiles.size(); i++) {
                            d.image(tiles.get(i).image(), 80.0 * i, 0.0, 80.0, 45.0);
                        }
                    });
                });
            });

            KayaApp.Reader tone = tx.reader(MediaSource.asset("media/tone.wav"));
            KayaApp.Read peaks = tx.readPeaks(tone, 4800);
            KayaApp.Image[] images = new KayaApp.Image[2];
            app.onPeaks(peaks, (t, p) -> {
                int lows = 0;
                int highs = 0;
                for (int i = 0; i < p.count(); i++) {
                    lows = i == 0 ? p.pair(i, 0).min() : Math.min(lows, p.pair(i, 0).min());
                    highs = i == 0 ? p.pair(i, 0).max() : Math.max(highs, p.pair(i, 0).max());
                }
                t.write(labels.get(2), "peaks " + p.sampleRate() + " Hz, " + p.channels() + " ch, "
                        + p.count() + " pairs of " + p.samplesPerPair() + ", " + lows + ".." + highs);
                t.draw(wave, d -> {
                    for (int i = 0; i < p.count(); i++) {
                        KayaApp.Pair pair = p.pair(i, 0);
                        double x = 8.0 + 7.0 * i;
                        d.moveTo(x, waveY(pair.max())).lineTo(x + 5.0, waveY(pair.max()))
                                .lineTo(x + 5.0, waveY(pair.min())).lineTo(x, waveY(pair.min())).close();
                        d.fill(KayaApp.Paint.SERIES, KayaApp.FillRule.NONZERO);
                    }
                    d.image(images[0], 150.0, 4.0, 20.0, 20.0);
                    d.image(images[1], 150.0, 30.0, 40.0, 30.0);
                });
            });
            app.onReadDone(peaks, (t, o) -> {
                if (!(o instanceof KayaApp.ReadOutcome.Completed)) {
                    t.write(labels.get(2), "peaks " + outcomeWord(o));
                }
            });

            for (String[] item : new String[][] {{"OFL.txt", "fonts/OFL.txt"}, {"missing.mp4", "media/missing.mp4"}}) {
                KayaApp.Reader reader = tx.reader(MediaSource.asset(item[1]));
                KayaApp.Read read = tx.readFrames(reader, new long[] {0}, 80, 45, KayaApp.FrameAccuracy.EXACT);
                app.onReadDone(read, (t, o) -> noted(t, labels.get(4), w.failures, item[0], o));
            }

            KayaApp.Reader silent = tx.reader(MediaSource.asset("media/h264_noaudio.mp4"));
            KayaApp.Read silentRead = tx.readPeaks(silent, 4800);
            app.onReadDone(silentRead, (t, o) -> noted(t, labels.get(5), w.missing, "noaudio peaks", o));
            KayaApp.Reader song = tx.reader(MediaSource.asset("media/tone.mp3"));
            KayaApp.Read songRead = tx.readFrames(song, new long[] {0}, 80, 45, KayaApp.FrameAccuracy.EXACT);
            app.onReadDone(songRead, (t, o) -> noted(t, labels.get(5), w.missing, "mp3 frames", o));

            images[0] = tx.loadImage(MediaSource.asset("images/a11y-logo.png"));
            images[1] = tx.loadImage(MediaSource.asset("images/photo.jpg"));
            return null;
        });
        app.dispatchLoop();
    }

    private static void noted(KayaApp.Tx tx, KayaApp.Signal<String> label, List<String> list, String what,
            KayaApp.ReadOutcome outcome) {
        list.add(what + " " + outcomeWord(outcome));
        list.sort(null);
        tx.write(label, String.join("; ", list));
    }

    private Media() {}
}
