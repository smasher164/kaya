// The media suite, C# port — guests/rust/media.rs, tools/scenes/media_*.steps.

using System;
using System.Collections.Generic;
using System.Globalization;

// Its own namespace: range owns the bare Clip.
namespace Media;

[KayaGen]
record MediaClip(string Name, Player Player);

/// One item: what the label names, where it comes from, and the type the
/// capability query is asked about.
record Item(string Name, MediaSource Source, string Mime, string Codecs);

static class MediaScene
{
    const string H264 = "avc1.64000b, mp4a.40.2";
    const string Hevc = "hvc1.1.6.L60.90, mp4a.40.2";
    const string Av1 = "av01.0.00M.08, mp4a.40.2";
    const int FeedRows = 10;

    static Item Local(string name, string mime, string codecs) =>
        new(name, MediaSource.Asset($"media/{name}"), mime, codecs);

    static Item Served(string baseUrl, string name, string mime, string codecs) =>
        new(name, MediaSource.Url($"{baseUrl}/{name}"), mime, codecs);

    static List<Item> Formats() => new()
    {
        Local("h264_aac.mp4", "video/mp4", H264),
        Local("hevc_aac.mp4", "video/mp4", Hevc),
        Local("hevc_aac.mov", "video/quicktime", Hevc),
        Local("vp9_opus.webm", "video/webm", "vp09.00.10.08, opus"),
        Local("vp9_aac.mp4", "video/mp4", "vp09.00.10.08, mp4a.40.2"),
        Local("av1_aac.mp4", "video/mp4", Av1),
        Local("av1_opus.webm", "video/webm", "av01.0.00M.08, opus"),
        Local("tone.mp3", "audio/mpeg", ""),
        Local("tone.m4a", "audio/mp4", "mp4a.40.2"),
        Local("tone.ogg", "audio/ogg", "opus"),
        Local("tone_opus.webm", "audio/webm", "opus"),
        Local("tone.flac", "audio/flac", ""),
        Local("tone.wav", "audio/wav", ""),
    };

    static string MediaUrl(string scenes) =>
        Environment.GetEnvironmentVariable("KAYA_MEDIA_URL")
        ?? throw new InvalidOperationException(
            $"kaya: the {scenes} read KAYA_MEDIA_URL, the local server the lane starts "
            + "(tools/lib/media_server.py); a hand run goes through tools/run-leg.py");

    /// The local server's items, and the three failures: a 404, a local
    /// file that is not there, and a port nothing listens on.
    static List<Item> Delivery()
    {
        var baseUrl = MediaUrl("media_delivery scene");
        int colon = baseUrl.LastIndexOf(':');
        var refused = colon < 0 ? baseUrl : $"{baseUrl[..colon]}:9";
        return new()
        {
            Served(baseUrl, "h264_aac.mp4", "video/mp4", H264),
            Served(baseUrl, "hls_fmp4.m3u8", "application/vnd.apple.mpegurl", ""),
            Served(baseUrl, "hls_mpegts.m3u8", "application/vnd.apple.mpegurl", ""),
            Served(baseUrl, "dash.mpd", "application/dash+xml", ""),
            Served(baseUrl, "nope.mp4", "video/mp4", H264),
            Local("missing.mp4", "video/mp4", H264),
            new("refused.mp4", MediaSource.Url($"{refused}/h264_aac.mp4"), "video/mp4", H264),
        };
    }

    static string YesNo(bool can) => can ? "yes" : "no";

    public static void Run()
    {
        var scene = Environment.GetEnvironmentVariable("KAYA_SELFTEST") ?? "";
        switch (scene)
        {
            case "media_tracks": TracksApp(); return;
            case "media_feed": FeedApp(); return;
            case "media_reader": ReaderApp(); return;
        }
        bool session = scene == "media_session";
        var items = scene == "media_delivery" ? Delivery() : Formats();
        var app = new KayaApp();
        int at = 0;
        bool can = false;
        ulong furthest = 0;
        int nexts = 0;

        var (summary, name, player) = app.Build(tx =>
        {
            tx.Window(title: "media");
            var summary = tx.Signal("idle");
            var name = tx.Signal(session ? "next 0" : "none");
            var player = tx.Player(muted: true, loop: session);
            tx.Mount(tx.Column(root =>
            {
                tx.Label(bind: summary);                               // label#0
                tx.Label(bind: name);                                  // label#1
                var clip = tx.Video(player);                           // video#0
                tx.SetA11yId(clip, "clip");
                tx.SetA11yLabel(clip, "Clip");
                if (session)                                           // button#0
                    tx.Button("play", t =>
                    {
                        if (app.Player(player).State == PlayerState.Idle)
                            t.SetSource(player, MediaSource.Asset("media/h264_aac.mp4"));
                        t.Play(player);
                    });
                else
                    tx.Button("next", t =>
                    {
                        if (at >= items.Count) return;
                        var item = items[at++];
                        can = Kaya.CanPlay(item.Mime, item.Codecs);
                        furthest = 0;
                        t.SetSource(player, item.Source);
                        t.Write(name, item.Name);
                        t.Write(summary, "loading");
                    });
                return root;
            }));
            if (session)
                tx.Session(player: player, title: "kaya media", artist: "kaya",
                    handles: new[] { SessionActionKind.Next });
            return (summary, name, player);
        });

        app.OnPlayerState(player, (t, state) =>
        {
            if (session)
            {
                if (state is PlayerState.Playing or PlayerState.Paused)
                    t.Write(summary, state.Name());
                return;
            }
            if (state == PlayerState.Ready)
            {
                t.Play(player);
            }
            else if (state == PlayerState.Ended)
            {
                var r = app.Player(player);
                var played = furthest >= 1000 ? "played past 1s" : $"played to {furthest}ms";
                var seconds = (r.DurationMs / 1000.0).ToString("F1", CultureInfo.InvariantCulture);
                t.Write(summary,
                    $"ready {seconds}s {r.Width}x{r.Height}, {played}, ended, can_play {YesNo(can)}");
            }
        });
        app.OnFailed(player, (t, why, _) =>
            t.Write(summary, $"failed {why.Name()}, can_play {YesNo(can)}"));
        app.OnPosition(player, (_, ms) => furthest = Math.Max(furthest, ms));
        app.OnSession((t, action) =>
        {
            if (action.Kind == SessionActionKind.Next)
            {
                nexts++;
                t.Write(name, $"next {nexts}");
            }
        });
        Environment.Exit(app.Run());
    }

    /// One track list as a line: `audio en, fr [2]`, the selection counting
    /// from 1, `-` for none; `audio none` for an empty list.
    static string TrackLine(string what, IReadOnlyList<string> tags, int? selected)
    {
        if (tags.Count == 0) return $"{what} none";
        var pick = selected is int i ? (i + 1).ToString(CultureInfo.InvariantCulture) : "-";
        return $"{what} {string.Join(", ", tags)} [{pick}]";
    }

    /// media_tracks (docs/media-plan.md §3, §7a): each item's audio and
    /// caption listing, a second audio track selected, the last caption
    /// track selected, and the cue read at 0.5 s and 1.5 s with the player
    /// paused there. The sidecar items are the floor file with captions.vtt
    /// (the first over h264_frames.mp4): an asset, then fetched from the local
    /// server, then a 404 there.
    static void TracksApp()
    {
        var baseUrl = MediaUrl("media scenes that stream");
        Item Floor(string label) => Local("h264_aac.mp4", "video/mp4", H264) with { Name = label };
        var items = new List<(Item Item, MediaSource? Sidecar)>
        {
            (Local("h264_2audio.mp4", "video/mp4", H264), null),
            (Local("vp9_2audio.webm", "video/webm", "vp09.00.10.08, opus"), null),
            (Served(baseUrl, "hls_fmp4.m3u8", "application/vnd.apple.mpegurl", ""), null),
            (Served(baseUrl, "hls_mpegts.m3u8", "application/vnd.apple.mpegurl", ""), null),
            (Local("h264_tx3g.mp4", "video/mp4", H264), null),
            (Local("h264_frames.mp4", "video/mp4", H264) with { Name = "h264_frames.mp4 + captions.vtt" }, MediaSource.Asset("media/captions.vtt")),
            (Floor("h264_aac.mp4 + http captions.vtt"), MediaSource.Url($"{baseUrl}/captions.vtt")),
            (Floor("h264_aac.mp4 + http nope.vtt"), MediaSource.Url($"{baseUrl}/nope.vtt")),
        };
        var app = new KayaApp();
        int at = 0;
        bool can = false;

        var (summary, audio, captions, cue, player) = app.Build(tx =>
        {
            tx.Window(title: "media tracks");
            var summary = tx.Signal("idle");
            var name = tx.Signal("none");
            var audio = tx.Signal("audio none");
            var captions = tx.Signal("captions none");
            var cue = tx.Signal("");
            var player = tx.Player(muted: true);
            tx.Mount(tx.Column(root =>
            {
                tx.Label(bind: summary);                               // label#0
                tx.Label(bind: name);                                  // label#1
                tx.Label(bind: audio);                                 // label#2
                tx.Label(bind: captions);                              // label#3
                tx.Label(bind: cue);                                   // label#4
                var clip = tx.Video(player);                           // video#0
                tx.SetA11yId(clip, "clip");
                tx.SetA11yLabel(clip, "Clip");
                tx.Button("next", t =>                                 // button#0
                {
                    if (at >= items.Count) return;
                    var (item, sidecar) = items[at++];
                    can = Kaya.CanPlay(item.Mime, item.Codecs);
                    if (sidecar is MediaSource s) t.SetCaptions(player, s, "en");
                    else t.ClearCaptions(player);
                    t.SetSource(player, item.Source);
                    t.Write(name, item.Name);
                    t.Write(summary, "loading");
                    t.Write(cue, "");
                });
                tx.Button("audio 2", t => t.SelectAudio(player, 1));   // button#1
                tx.Button("captions", t =>                             // button#2
                {
                    int listed = app.Tracks(player).Captions.Count;
                    if (listed == 0) t.Write(cue, "captions none");
                    else t.SelectCaptions(player, listed - 1);
                });
                foreach (var (caption, ms) in new[] { ("at 0.5s", 500UL), ("at 1.5s", 1500UL) })
                    tx.Button(caption, t =>                            // button#3, button#4
                    {
                        t.Pause(player);
                        t.Seek(player, ms);
                    });
                tx.Button("captions off", t => t.SelectCaptions(player, null)); // button#5
                tx.Button("play", t =>                                 // button#6
                {
                    t.Seek(player, 0);
                    t.Play(player);
                });
                return root;
            }));
            return (summary, audio, captions, cue, player);
        });

        app.OnPlayerState(player, (t, state) =>
        {
            if (state == PlayerState.Ready)
                t.Write(summary, $"ready, can_play {YesNo(can)}");
        });
        app.OnFailed(player, (t, why, _) =>
        {
            var line = $"failed {why.Name()}, can_play {YesNo(can)}";
            t.Write(summary, line);
            t.Write(audio, line);
        });
        app.OnTracks(player, (t, tracks) =>
        {
            t.Write(audio, TrackLine("audio", tracks.Audio, tracks.AudioSelected));
            t.Write(captions, TrackLine("captions", tracks.Captions, tracks.CaptionSelected));
        });
        app.OnCue(player, (t, text) => t.Write(cue, text));
        Environment.Exit(app.Run());
    }

    /// media_feed (docs/media-plan.md §7b): a scroll of rows, each a video
    /// view showing its row's own player, paused on its first frame; the
    /// first and last rows' visibility in label#0 and label#1.
    static void FeedApp()
    {
        var app = new KayaApp();
        app.Build(tx =>
        {
            tx.Window(title: "media feed", width: 420.0, height: 480.0);
            var first = tx.Signal("r0 out");
            var last = tx.Signal($"r{FeedRows - 1} out");
            var clips = MediaClipKaya.Collection(tx);
            tx.Mount(tx.Column(root =>
            {
                tx.Label(bind: first);                                 // label#0
                tx.Label(bind: last);                                  // label#1
                tx.Scroll(_ =>
                {
                    tx.Column(_ =>
                    {
                        foreach (var row in clips.Rows())
                        {
                            row.Label(row.Name);
                            row.Video(row.Player, (t, keys, shown) =>
                            {
                                var at = (long)keys[0];
                                var word = shown >= 0.999 ? "whole" : shown > 0.0 ? "in" : "out";
                                if (at == 0) t.Write(first, $"r0 {word}");
                                if (at == FeedRows - 1) t.Write(last, $"r{at} {word}");
                            });
                        }
                    });
                }, grow: 1.0);
                return root;
            }));
            for (int i = 0; i < FeedRows; i++)
            {
                var player = tx.Player(muted: true, source: MediaSource.Asset("media/h264_aac.mp4"));
                clips.Insert(tx, (long)i, new MediaClip($"r{i}", player));
            }
        });
        Environment.Exit(app.Run());
    }

    /// h264_frames.mp4's grey bands: frame 12 (0x505050) and frame 37
    /// (0xA0A0A0) at 25 fps, its one keyframe at 0 (tools/gen-media.py).
    static readonly ulong[] Bands = { 480, 1480 };
    static readonly Viewbox StripBox = new(320.0, 45.0);
    static readonly Viewbox WaveBox = new(200.0, 60.0);

    /// The answered times as the labels spell them: each time asked, then
    /// the time of the picture the platform returned, in ms.
    static string FrameLine(string what, List<Frame> frames, ReadOutcome outcome)
    {
        var sorted = new List<Frame>(frames);
        sorted.Sort((a, b) => a.Index.CompareTo(b.Index));
        var times = sorted.ConvertAll(f => $"{f.RequestedMs}@{f.ActualMs}");
        return $"{what} {string.Join(" ", times)} {OutcomeWord(outcome)}";
    }

    static string OutcomeWord(ReadOutcome outcome) => outcome switch
    {
        ReadOutcome.Completed => "completed",
        ReadOutcome.Cancelled => "cancelled",
        ReadOutcome.Failed failed => $"failed {failed.Why.Name()}",
        _ => throw new InvalidOperationException($"an outcome no read ends with: {outcome}"),
    };

    /// media_reader (docs/media-plan.md §8 rulings 3 and 4): a reader with
    /// no player draws a filmstrip of h264_frames.mp4's exact and keyframe
    /// pictures and a waveform of tone.wav's peaks beside two loaded
    /// images; a read the server never finishes is cancelled and another is
    /// closed under its reader; a file that is not media and a missing file
    /// fail.
    static void ReaderApp()
    {
        var baseUrl = MediaUrl("media_reader scene");
        var app = new KayaApp();
        var exact = new List<Frame>();
        var keyframe = new List<Frame>();
        var failures = new List<string>();
        var missing = new List<string>();
        var cancels = new List<string>();
        Action<Tx>? trickling = null;
        Signal[] labels = Array.Empty<Signal>();
        Widget strip = default, wave = default;
        Reader clip = default;
        Image logo = default, photo = default;

        Action<Tx, ReadOutcome> Settle(List<string> list, int label, string what) => (t, outcome) =>
        {
            list.Add($"{what} {OutcomeWord(outcome)}");
            list.Sort(StringComparer.Ordinal);
            t.Write(labels[label], string.Join("; ", list));
        };

        void KeyframeDone(Tx t, ReadOutcome outcome)
        {
            t.Write(labels[1], FrameLine("keyframe", keyframe, outcome));
            exact.Sort((a, b) => a.Index.CompareTo(b.Index));
            keyframe.Sort((a, b) => a.Index.CompareTo(b.Index));
            var tiles = new List<Frame>(exact);
            tiles.AddRange(keyframe);
            t.Draw(strip, d =>
            {
                for (int i = 0; i < tiles.Count; i++)
                    d.Image(tiles[i].Image, 80.0 * i, 0.0, 80.0, 45.0);
            });
        }

        void ExactDone(Tx t, ReadOutcome outcome)
        {
            t.Write(labels[0], FrameLine("exact", exact, outcome));
            t.ReadFrames(clip, Bands, 80, 45, FrameAccuracy.Keyframe,
                onFrame: (_, f) => keyframe.Add(f), onDone: KeyframeDone);
        }

        void PeaksHeard(Tx t, Peaks p)
        {
            short lows = 0, highs = 0;
            for (int i = 0; i < p.Count; i++)
            {
                var (lo, hi) = p.Pair(i, 0);
                if (i == 0 || lo < lows) lows = lo;
                if (i == 0 || hi > highs) highs = hi;
            }
            t.Write(labels[2], $"peaks {p.SampleRate} Hz, {p.Channels} ch, {p.Count} pairs of "
                + $"{p.SamplesPerPair}, {lows}..{highs}");
            t.Draw(wave, d =>
            {
                static double Y(short v) => 30.0 - v * 25.0 / 8192.0;
                for (int i = 0; i < p.Count; i++)
                {
                    var (lo, hi) = p.Pair(i, 0);
                    double x = 8.0 + 7.0 * i;
                    d.MoveTo(x, Y(hi)).LineTo(x + 5.0, Y(hi)).LineTo(x + 5.0, Y(lo)).LineTo(x, Y(lo)).Close();
                    d.Fill(Paint.Series, FillRule.Nonzero);
                }
                d.Image(logo, 150.0, 4.0, 20.0, 20.0);
                d.Image(photo, 150.0, 30.0, 40.0, 30.0);
            });
        }

        app.Build(tx =>
        {
            tx.Window(title: "media reader", width: 560.0, height: 560.0);
            labels = Array.ConvertAll(
                new[] { "exact", "keyframe", "peaks", "failures", "no track", "cancel" },
                s => tx.Signal(s));
            tx.Mount(tx.Column(root =>
            {
                foreach (var label in labels[..5]) tx.Label(bind: label);   // label#0..#4
                strip = tx.Canvas(StripBox);
                tx.SetA11yId(strip, "strip");
                tx.SetA11yLabel(strip, "Filmstrip");
                wave = tx.Canvas(WaveBox);
                tx.SetA11yId(wave, "wave");
                tx.SetA11yLabel(wave, "Waveform");
                tx.Button("start", t =>                               // button#0
                {
                    var trickle = t.Reader(MediaSource.Url($"{baseUrl}/trickle/h264_frames.mp4"));
                    var read = t.ReadFrames(trickle, new ulong[] { 0 }, 80, 45, FrameAccuracy.Exact,
                        onDone: Settle(cancels, 5, "trickle"));
                    var closing = t.Reader(MediaSource.Url($"{baseUrl}/trickle/h264_aac.mp4"));
                    t.ReadFrames(closing, new ulong[] { 0 }, 80, 45, FrameAccuracy.Exact,
                        onDone: Settle(cancels, 5, "closed"));
                    trickling = c =>
                    {
                        c.CancelRead(trickle, read);
                        c.CloseReader(closing);
                    };
                    t.Write(labels[5], "reading");
                });
                tx.Button("cancel", t =>                              // button#1
                {
                    trickling?.Invoke(t);
                    trickling = null;
                });
                tx.Label(bind: labels[5]);                            // label#5
                return root;
            }));

            clip = tx.Reader(MediaSource.Asset("media/h264_frames.mp4"));
            tx.ReadFrames(clip, Bands, 80, 45, FrameAccuracy.Exact,
                onFrame: (_, f) => exact.Add(f), onDone: ExactDone);

            var tone = tx.Reader(MediaSource.Asset("media/tone.wav"));
            tx.ReadPeaks(tone, 4800, onPeaks: PeaksHeard, onDone: (t, outcome) =>
            {
                if (outcome is not ReadOutcome.Completed)
                    t.Write(labels[2], $"peaks {OutcomeWord(outcome)}");
            });

            foreach (var (what, source) in new[] { ("OFL.txt", "fonts/OFL.txt"), ("missing.mp4", "media/missing.mp4") })
            {
                var reader = tx.Reader(MediaSource.Asset(source));
                tx.ReadFrames(reader, new ulong[] { 0 }, 80, 45, FrameAccuracy.Exact,
                    onDone: Settle(failures, 3, what));
            }

            var silent = tx.Reader(MediaSource.Asset("media/h264_noaudio.mp4"));
            tx.ReadPeaks(silent, 4800, onDone: Settle(missing, 4, "noaudio peaks"));
            var song = tx.Reader(MediaSource.Asset("media/tone.mp3"));
            tx.ReadFrames(song, new ulong[] { 0 }, 80, 45, FrameAccuracy.Exact,
                onDone: Settle(missing, 4, "mp3 frames"));

            logo = tx.LoadImage(MediaSource.Asset("images/a11y-logo.png"));
            photo = tx.LoadImage(MediaSource.Asset("images/photo.jpg"));
        });
        Environment.Exit(app.Run());
    }
}
