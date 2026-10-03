package dev.kaya;

import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.List;

/**
 * The Java media surface's decode and mirror (docs/media-plan.md §2, §3,
 * §7b), run rather than read: player_changed, player_tracks and
 * session_action as the core's wire.rs packs them, through the GENERATED
 * decoder (tools/kaya-bindgen's flat class) and KayaApp's media arm; the
 * mirror moved before the handler runs; the failed handler handed the
 * closed reason; a row's player field on the wire as its id; and a stamped
 * video view's player bound from that field. IN PACKAGE dev.kaya so the
 * package-private arm is reachable. Compiled and RUN by
 * tools/java-typecheck.py.
 */
public final class MediaCheck {
    private static void check(boolean ok, String what) {
        if (!ok) {
            System.out.println("media-check: FAIL — " + what);
            System.exit(1);
        }
    }

    /** One occurrence record: {u32 len, u16 kind, u16 0}, the body,
     * padded to 8 as the ring frames it. */
    private static byte[] record(short kind, byte[] body) {
        int len = (8 + body.length + 7) & ~7;
        ByteBuffer b = ByteBuffer.allocate(len).order(ByteOrder.LITTLE_ENDIAN);
        b.putInt(len).putShort(kind).putShort((short) 0).put(body);
        return b.array();
    }

    private static final class Body {
        final ByteBuffer b = ByteBuffer.allocate(512).order(ByteOrder.LITTLE_ENDIAN);

        Body u64(long v) {
            b.putLong(v);
            return this;
        }

        Body u32(int v) {
            b.putInt(v);
            return this;
        }

        Body str(String s) {
            byte[] utf8 = s.getBytes(StandardCharsets.UTF_8);
            b.putInt(KayaWire.VALUE_STR).putInt(utf8.length).put(utf8);
            while (b.position() % 8 != 0) {
                b.put((byte) 0);
            }
            return this;
        }

        Body strs(String... ss) {
            b.putInt(ss.length).putInt(0);
            for (String s : ss) {
                str(s);
            }
            return this;
        }

        byte[] bytes() {
            byte[] out = new byte[b.position()];
            b.flip();
            b.get(out);
            return out;
        }
    }

    record Row(String name, KayaApp.Player player) {}

    private static byte[] readerFrame(long reader, long read, long image, int index) {
        return record(KayaWire.OCC_KIND_READER_FRAME, new Body().u64(reader).u64(read).u64(image)
                .u32(index).u32(2).u32(1).u32(0).u64(40L * index).u64(40L * index).bytes());
    }

    private static byte[] readerDone(long reader, long read, int outcome, int failure) {
        return record(KayaWire.OCC_KIND_READER_DONE, new Body().u64(reader).u64(read)
                .u32(outcome).u32(failure).str("why").bytes());
    }

    private static boolean releases(KayaApp app, long... images) {
        if (app.pendingRecords.size() != images.length) {
            return false;
        }
        for (int i = 0; i < images.length; i++) {
            if (!java.util.Arrays.equals(app.pendingRecords.get(i), KayaWire.txReleaseImage(images[i]))) {
                return false;
            }
        }
        return true;
    }

    /** docs/media-plan.md §8 ruling 4, rule 4: after cancelRead or
     * closeReader the app hears only the read's end, and an unheard
     * frame's image is released by the next commit; an awaited read the
     * same, by cancelling its future or by a failed end. */
    private static void readerRule(KayaApp app) {
        for (boolean closing : new boolean[] {false, true}) {
            List<String> heard = new ArrayList<>();
            KayaApp.Reader[] reader = new KayaApp.Reader[1];
            KayaApp.Read[] read = new KayaApp.Read[1];
            app.build((java.util.function.Consumer<KayaApp.Tx>) tx -> {
                reader[0] = tx.reader(KayaApp.MediaSource.asset("media/h264_frames.mp4"));
                read[0] = tx.readFrames(reader[0], new long[] {0, 40}, 0, 0, KayaApp.FrameAccuracy.EXACT);
            });
            app.onFrame(read[0], (tx, f) -> heard.add("frame " + f.index()));
            app.onReadDone(read[0], (tx, o) -> heard.add("done " + o));
            long r = reader[0].id();
            long id = read[0].id();
            long image = closing ? 910 : 900;
            app.readerOccurrence(KayaWire.parseOccurrence(readerFrame(r, id, image, 0)));
            app.build((java.util.function.Consumer<KayaApp.Tx>) tx -> {
                if (closing) {
                    tx.closeReader(reader[0]);
                } else {
                    tx.cancelRead(reader[0], read[0]);
                }
            });
            app.readerOccurrence(KayaWire.parseOccurrence(readerFrame(r, id, image + 1, 1)));
            check(heard.equals(List.of("frame 0")),
                    "reader: a late answer after cancel or close was heard: " + heard);
            check(releases(app, image + 1), "reader: the unheard frame's image was not queued for release");
            app.readerOccurrence(KayaWire.parseOccurrence(
                    readerDone(r, id, KayaWire.READ_OUTCOME_CANCELLED, KayaWire.MEDIA_FAILURE_NONE)));
            check(heard.equals(List.of("frame 0", "done Cancelled[]")), "reader: the end was not heard: " + heard);
            check(app.pendingRecords.isEmpty(), "reader: the release did not ride the next commit");
            check(app.doneHandlers.isEmpty() && app.frameHandlers.isEmpty(),
                    "reader: the read's handlers did not retire");
        }

        KayaApp.Reader[] clip = new KayaApp.Reader[1];
        List<java.util.concurrent.CompletableFuture<List<KayaApp.Frame>>> futures = new ArrayList<>();
        app.build((java.util.function.Consumer<KayaApp.Tx>) tx -> {
            clip[0] = tx.reader(KayaApp.MediaSource.asset("media/h264_frames.mp4"));
            futures.add(tx.framesFuture(clip[0], new long[] {0, 40}, 0, 0, KayaApp.FrameAccuracy.EXACT));
        });
        long r = clip[0].id();
        long awaited = app.readWaiters.keySet().iterator().next();
        long image = 920;
        app.readerOccurrence(KayaWire.parseOccurrence(readerFrame(r, awaited, image, 0)));
        futures.get(0).cancel(true);
        app.drainAsync();
        check(app.readWaiters.isEmpty(), "reader: the cancelled future stayed registered");
        app.readerOccurrence(KayaWire.parseOccurrence(readerFrame(r, awaited, image + 1, 1)));
        check(releases(app, image + 1), "reader: the cancelled future's late image was not queued for release");
        app.readerOccurrence(KayaWire.parseOccurrence(
                readerDone(r, awaited, KayaWire.READ_OUTCOME_CANCELLED, KayaWire.MEDIA_FAILURE_NONE)));
        app.build((java.util.function.Consumer<KayaApp.Tx>) tx -> {});

        app.build((java.util.function.Consumer<KayaApp.Tx>) tx ->
                futures.add(tx.framesFuture(clip[0], new long[] {0, 40}, 0, 0, KayaApp.FrameAccuracy.EXACT)));
        long failing = app.readWaiters.keySet().iterator().next();
        long next = 930;
        app.readerOccurrence(KayaWire.parseOccurrence(readerFrame(r, failing, next, 0)));
        app.readerOccurrence(KayaWire.parseOccurrence(
                readerDone(r, failing, KayaWire.READ_OUTCOME_FAILED, KayaWire.MEDIA_FAILURE_NOT_FOUND)));
        app.drainAsync();
        Throwable why = null;
        try {
            futures.get(1).getNow(null);
        } catch (java.util.concurrent.CompletionException e) {
            why = e.getCause();
        }
        check(why instanceof KayaApp.ReadException e
                        && e.outcome().equals(new KayaApp.ReadOutcome.Failed(KayaApp.MediaFailure.NOT_FOUND, "why")),
                "reader: a failed awaited read did not complete with its reason: " + why);
        check(releases(app, next), "reader: a failed awaited read's image was not queued for release");
        app.build((java.util.function.Consumer<KayaApp.Tx>) tx -> {});
    }

    public static void main(String[] args) throws Exception {
        String lib = System.getenv("KAYA_LIB");
        if (lib != null) {
            System.load(lib);
        } else {
            System.loadLibrary("kaya");
        }
        KayaRing.attach();

        // THE GENERATED DECODER, player_changed: failed(not_found), 2000 ms,
        // 160x90, a detail sentence.
        byte[] changed = record(KayaWire.OCC_KIND_PLAYER_CHANGED, new Body()
                .u64(7).u32(KayaWire.PLAYER_STATE_FAILED).u32(KayaWire.MEDIA_FAILURE_NOT_FOUND)
                .u64(2000).u32(160).u32(90).str("gone").bytes());
        KayaWire.Occ occ = KayaWire.parseOccurrence(changed);
        check(occ != null && occ.id == 7 && occ.keys.isEmpty(),
                "player_changed decoded with the wrong id or keys: " + (occ == null ? null : occ.id));
        check(List.of((long) KayaWire.PLAYER_STATE_FAILED, (long) KayaWire.MEDIA_FAILURE_NOT_FOUND,
                        2000L, 160L, 90L, "gone").equals(occ.payload),
                "player_changed's tail read back as " + occ.payload);

        byte[] tracks = record(KayaWire.OCC_KIND_PLAYER_TRACKS, new Body()
                .u64(7).u32(2).u32(0).strs("en", "fr").strs("en").bytes());
        KayaWire.Occ tocc = KayaWire.parseOccurrence(tracks);
        check(tocc != null && tocc.id == 7 && List.of(2L, 0L, 2L, "en", "fr", 1L, "en").equals(tocc.payload),
                "player_tracks read back as " + (tocc == null ? null : tocc.payload));

        byte[] action = record(KayaWire.OCC_KIND_SESSION_ACTION, new Body()
                .u32(KayaWire.SESSION_ACTION_SEEK_TO).u32(0).u64(1500).bytes());
        KayaWire.Occ aocc = KayaWire.parseOccurrence(action);
        check(aocc != null && aocc.id == 0
                        && List.of((long) KayaWire.SESSION_ACTION_SEEK_TO, 1500L).equals(aocc.payload),
                "session_action read back as " + (aocc == null ? null : aocc.payload));

        // THE MEDIA ARM: the mirror first, then the handlers.
        KayaApp app = new KayaApp();
        KayaApp.Player[] made = new KayaApp.Player[1];
        List<Object> seen = new ArrayList<>();
        List<byte[]> bound = new ArrayList<>();
        java.lang.reflect.Field records = KayaApp.Tx.class.getDeclaredField("records");
        records.setAccessible(true);
        app.build((java.util.function.Consumer<KayaApp.Tx>) tx -> {
            made[0] = tx.player();
            KayaApp.Tpl tpl = app.new Tpl(tx);
            tpl.video(KayaRecords.fieldAt(1));
            try {
                @SuppressWarnings("unchecked")
                List<byte[]> recs = (List<byte[]>) records.get(tx);
                bound.addAll(recs);
                recs.clear();
            } catch (IllegalAccessException e) {
                throw new IllegalStateException(e);
            }
        });
        KayaApp.Player p = made[0];
        app.onPlayerState(p, (tx, state) -> seen.add("state " + state + " mirror " + app.player(p).state()));
        app.onFailed(p, (tx, why, detail) -> seen.add("failed " + why + " " + detail));
        app.onTracks(p, (tx, t) -> seen.add("tracks " + t.audio() + t.audioSelected() + t.captionSelected()));
        app.onSession((tx, a) -> seen.add("session " + a.kind() + " " + a.atMs()));
        long id = p.id();
        app.mediaOccurrence(KayaWire.parseOccurrence(record(KayaWire.OCC_KIND_PLAYER_CHANGED, new Body()
                .u64(id).u32(KayaWire.PLAYER_STATE_FAILED).u32(KayaWire.MEDIA_FAILURE_NOT_FOUND)
                .u64(2000).u32(160).u32(90).str("gone").bytes())));
        app.mediaOccurrence(KayaWire.parseOccurrence(record(KayaWire.OCC_KIND_PLAYER_TRACKS, new Body()
                .u64(id).u32(2).u32(0).strs("en", "fr").strs("en").bytes())));
        app.mediaOccurrence(KayaWire.parseOccurrence(action));
        check(seen.equals(List.of("state failed mirror failed", "failed not_found gone",
                        "tracks [en, fr]OptionalInt[1]OptionalInt.empty", "session seek_to 1500")),
                "the media arm answered " + seen);
        KayaApp.PlayerReading r = app.player(p);
        check(r.durationMs() == 2000 && r.width() == 160 && r.height() == 90
                        && r.failure().orElse(null) == KayaApp.MediaFailure.NOT_FOUND,
                "the mirror reads " + r);

        // A POSITION, then a LOADING that resets it.
        app.mediaOccurrence(KayaWire.parseOccurrence(record(KayaWire.OCC_KIND_PLAYER_POSITION,
                new Body().u64(id).u64(1234).bytes())));
        check(app.player(p).positionMs() == 1234, "a position read back as " + app.player(p).positionMs());
        app.mediaOccurrence(KayaWire.parseOccurrence(record(KayaWire.OCC_KIND_PLAYER_CHANGED, new Body()
                .u64(id).u32(KayaWire.PLAYER_STATE_LOADING).u32(KayaWire.MEDIA_FAILURE_NONE)
                .u64(0).u32(0).u32(0).str("").bytes())));
        check(app.player(p).positionMs() == 0, "loading left the position at " + app.player(p).positionMs());

        // A ROW'S PLAYER FIELD: its id on the wire, 0 for none.
        KayaRecords.Info info = KayaRecords.Info.of(Row.class);
        Object[] wire = info.wireFields(new Row("a", p));
        check(Long.valueOf(id).equals(wire[1]), "a row's player field packed as " + wire[1]);
        check(Long.valueOf(0).equals(info.wireFields(new Row("b", null))[1]), "a row with no player did not pack 0");

        // A STAMPED VIDEO VIEW binds PROP_PLAYER from the row's field.
        boolean found = false;
        for (byte[] rec : bound) {
            ByteBuffer b = ByteBuffer.wrap(rec).order(ByteOrder.LITTLE_ENDIAN);
            if (b.getShort(4) == KayaWire.TX_KIND_SET_PROPERTY && b.getInt(16) == KayaWire.PROP_PLAYER
                    && b.getInt(20) == KayaWire.SOURCE_ELEMENT
                    && b.getInt(24) == 0 && b.getInt(28) == 1) {
                found = true;
            }
        }
        check(found, "the template video emitted no PROP_PLAYER bound to field 1 (" + bound.size() + " records)");

        readerRule(app);

        System.out.println("media-check: OK — player_changed, player_tracks and session_action decode"
                + " through the generated decoder, the mirror moves before the handler, the failed"
                + " handler hears not_found, loading resets the position, a row's player packs as"
                + " its id and a stamped video binds PROP_PLAYER from the row's field; a cancelled,"
                + " closed or failed read is heard only by its end and its unheard images are"
                + " released by the next commit");
    }

    private MediaCheck() {}
}
