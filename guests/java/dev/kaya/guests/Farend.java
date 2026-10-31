package dev.kaya.guests;

import dev.kaya.KayaApp;

/**
 * The far end from the JVM — guests/rust/farend.rs, tools/scenes/farend.steps,
 * docs/capture-plan.md §5: a surface showing the NV12 frames the app submits
 * from its own thread, and a voice output playing the samples it writes.
 */
public final class Farend {
    /** What the far end sends: a flat colour at a size and a tone (0: silence). */
    private static final class Peer {
        int rgb = 0x1E5AC8;
        int width = 640;
        int height = 480;
        double hz = 660;
        boolean on;
    }

    /** A flat colour as NV12, video-range BT.601. */
    private static byte[][] nv12(int w, int h, int rgb) {
        double r = (rgb >> 16) & 0xFF, g = (rgb >> 8) & 0xFF, b = rgb & 0xFF;
        byte y = (byte) Math.round(16 + 0.257 * r + 0.504 * g + 0.098 * b);
        byte u = (byte) Math.round(128 - 0.148 * r - 0.291 * g + 0.439 * b);
        byte v = (byte) Math.round(128 + 0.439 * r - 0.368 * g - 0.071 * b);
        byte[] luma = new byte[w * h];
        java.util.Arrays.fill(luma, y);
        byte[] chroma = new byte[w * h / 2];
        for (int i = 0; i < chroma.length; i += 2) {
            chroma[i] = u;
            chroma[i + 1] = v;
        }
        return new byte[][] {luma, chroma};
    }

    /** The peer's thread: a frame every 1/15 s and 10 ms of samples every
     * 10 ms, paced by the clock, until hung up. */
    private static void runPeer(Peer peer, KayaApp.SurfaceFrames frames, KayaApp.VoiceWriter voice) {
        long start = System.nanoTime();
        long sentFrames = 0, sentSamples = 0;
        int shownRgb = -1, shownW = 0, shownH = 0;
        byte[][] planes = null;
        double phase = 0;
        short[] chunk = new short[480];
        while (true) {
            int rgb, w, h;
            double hz;
            synchronized (peer) {
                if (!peer.on) {
                    return;
                }
                rgb = peer.rgb;
                w = peer.width;
                h = peer.height;
                hz = peer.hz;
            }
            double elapsed = (System.nanoTime() - start) / 1e9;
            while (sentFrames / 15.0 <= elapsed) {
                if (planes == null || rgb != shownRgb || w != shownW || h != shownH) {
                    planes = nv12(w, h, rgb);
                    shownRgb = rgb;
                    shownW = w;
                    shownH = h;
                }
                frames.submit(new KayaApp.CaptureFrame(w, h, planes[0], planes[1], w, w, (long) (elapsed * 1e9), 0));
                sentFrames++;
            }
            while (sentSamples / 48000.0 <= elapsed) {
                for (int i = 0; i < chunk.length; i++) {
                    chunk[i] = hz > 0 ? (short) Math.round(Math.sin(phase) * 12000) : 0;
                    phase = (phase + 2 * Math.PI * hz / 48000) % (2 * Math.PI);
                }
                voice.write(chunk);
                sentSamples += 480;
            }
            try {
                Thread.sleep(5);
            } catch (InterruptedException e) {
                return;
            }
        }
    }

    public static void app() {
        KayaApp app = new KayaApp();
        Peer peer = new Peer();
        KayaApp.Voice[] call = new KayaApp.Voice[1];
        Thread[] thread = new Thread[1];
        KayaApp.Widget[] view = new KayaApp.Widget[1];
        KayaApp.Signal<?>[] made = new KayaApp.Signal<?>[1];
        app.build(tx -> {
            tx.window(0).title("far end").size(520.0, 640.0);
            KayaApp.Signal<String> route = tx.signal("voice none");
            made[0] = route;
            tx.mount(tx.column(col -> {
                tx.label(route); // label#0
                tx.row(buttons -> {
                    tx.button("Connect", t -> { // button#0
                        if (call[0] != null) {
                            return;
                        }
                        KayaApp.Voice v = t.voice();
                        call[0] = v;
                        app.onVoiceRoute(v, (rt, r, detail) -> rt.write(route, switch (r) {
                            case VOICE, PLAIN, SYNTHETIC -> "voice playing";
                            case FAILED -> "voice failed";
                            default -> "voice none";
                        }));
                        synchronized (peer) {
                            peer.rgb = 0x1E5AC8;
                            peer.width = 640;
                            peer.height = 480;
                            peer.hz = 660;
                            peer.on = true;
                        }
                        KayaApp.SurfaceFrames frames = app.surfaceFrames(view[0]);
                        thread[0] = new Thread(() -> runPeer(peer, frames, v.writer()), "far end");
                        thread[0].setDaemon(true);
                        thread[0].start();
                    });
                    tx.button("Change", t -> { // button#1
                        synchronized (peer) {
                            peer.rgb = 0xC83C1E;
                            peer.width = 1280;
                            peer.height = 720;
                            peer.hz = 440;
                        }
                    });
                    tx.button("Quiet", t -> { // button#2
                        synchronized (peer) {
                            peer.hz = 0;
                        }
                    });
                    tx.button("Hang up", t -> { // button#3
                        if (call[0] == null) {
                            return;
                        }
                        synchronized (peer) {
                            peer.on = false;
                        }
                        try {
                            thread[0].join();
                        } catch (InterruptedException e) {
                            Thread.currentThread().interrupt();
                        }
                        t.releaseVoice(call[0]);
                        call[0] = null;
                        t.write(route, "voice none");
                    });
                });
                view[0] = tx.surface().a11yLabel("Peer"); // surface#0
            }));
            return null;
        });
        app.dispatchLoop();
    }

    private Farend() {}
}
