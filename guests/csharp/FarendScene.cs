// The far end scene, C# port (docs/capture-plan.md §5): a surface showing the
// NV12 frames the app submits from its own thread, and a voice output playing
// the samples it writes there. See guests/rust/farend.rs and
// tools/scenes/farend.steps.

using System;
using System.Diagnostics;
using System.Threading;

static class FarendScene
{
    /// What the far end sends: a flat colour at a size and a tone (0: silence).
    sealed class Peer
    {
        public uint Rgb = 0x1E5AC8, W = 640, H = 480;
        public double Hz = 660;
        public bool On;
    }

    static (byte[] Y, byte[] UV) Nv12(uint w, uint h, uint rgb)
    {
        double r = (rgb >> 16) & 0xFF, g = (rgb >> 8) & 0xFF, b = rgb & 0xFF;
        var y = (byte)Math.Round(16 + 0.257 * r + 0.504 * g + 0.098 * b);
        var u = (byte)Math.Round(128 - 0.148 * r - 0.291 * g + 0.439 * b);
        var v = (byte)Math.Round(128 + 0.439 * r - 0.368 * g - 0.071 * b);
        var luma = new byte[w * h];
        Array.Fill(luma, y);
        var chroma = new byte[w * h / 2];
        for (int i = 0; i < chroma.Length; i += 2) { chroma[i] = u; chroma[i + 1] = v; }
        return (luma, chroma);
    }

    /// The peer's thread: a frame every 1/15 s and 10 ms of samples every
    /// 10 ms, paced by the clock, until hung up.
    static void RunPeer(Peer peer, SurfaceFrames frames, VoiceWriter voice)
    {
        var clock = Stopwatch.StartNew();
        long sentFrames = 0, sentSamples = 0;
        (uint Rgb, uint W, uint H, byte[] Y, byte[] UV)? shown = null;
        double phase = 0;
        var chunk = new short[480];
        while (true)
        {
            uint rgb, w, h;
            double hz;
            lock (peer)
            {
                if (!peer.On) return;
                (rgb, w, h, hz) = (peer.Rgb, peer.W, peer.H, peer.Hz);
            }
            long elapsed = clock.ElapsedTicks * 1_000_000 / Stopwatch.Frequency;
            while (sentFrames * 1_000_000 / 15 <= elapsed)
            {
                if (shown is not { } s || s.Rgb != rgb || s.W != w || s.H != h)
                {
                    var (y, uv) = Nv12(w, h, rgb);
                    shown = (rgb, w, h, y, uv);
                }
                var p = shown.Value;
                frames.Submit(new CaptureFrame(w, h, p.Y, p.UV, w, w, (ulong)elapsed * 1000, 0));
                sentFrames++;
            }
            while (sentSamples * 1_000 / 48 <= elapsed)
            {
                for (int i = 0; i < chunk.Length; i++)
                {
                    chunk[i] = hz > 0 ? (short)(Math.Sin(phase) * 12000) : (short)0;
                    phase = (phase + 2 * Math.PI * hz / 48000) % (2 * Math.PI);
                }
                voice.Write(chunk);
                sentSamples += 480;
            }
            Thread.Sleep(5);
        }
    }

    public static void Run()
    {
        var app = new KayaApp();
        var peer = new Peer();
        Voice? call = null;
        Thread? thread = null;
        Widget surface = default;
        var route = app.Build(tx =>
        {
            tx.Window(title: "far end", width: 520, height: 640);
            var route = tx.Signal("voice none");
            tx.Mount(tx.Column(root =>
            {
                tx.Label(bind: route); // label#0
                tx.Row(buttons =>
                {
                    tx.Button("Connect", t => // button#0
                    {
                        if (call != null) return;
                        var v = t.Voice((tt, r, _) => tt.Write(route, r switch
                        {
                            VoiceRoute.Voice or VoiceRoute.Plain or VoiceRoute.Synthetic => "voice playing",
                            VoiceRoute.Failed => "voice failed",
                            _ => "voice none",
                        }));
                        call = v;
                        lock (peer) { (peer.Rgb, peer.W, peer.H, peer.Hz, peer.On) = (0x1E5AC8u, 640u, 480u, 660.0, true); }
                        var frames = t.Frames(surface);
                        thread = new Thread(() => RunPeer(peer, frames, v.Writer())) { IsBackground = true };
                        thread.Start();
                    });
                    tx.Button("Change", t => // button#1
                    {
                        lock (peer) { (peer.Rgb, peer.W, peer.H, peer.Hz) = (0xC83C1Eu, 1280u, 720u, 440.0); }
                    });
                    tx.Button("Quiet", t => { lock (peer) peer.Hz = 0; }); // button#2
                    tx.Button("Hang up", t => // button#3
                    {
                        if (call is not { } v) return;
                        lock (peer) peer.On = false;
                        thread?.Join();
                        t.ReleaseVoice(v);
                        call = null;
                        t.Write(route, "voice none");
                    });
                    return buttons;
                });
                surface = tx.Surface(); // surface#0
                tx.SetA11yLabel(surface, "Peer");
                return root;
            }));
            return route;
        });
        Environment.Exit(app.Run());
    }
}
