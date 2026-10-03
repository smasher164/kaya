// The media surface's decode, mirror and dispatch (docs/media-plan.md),
// run rather than read. Headless, driven by tools/check-abort.py with
// KAYA_CHECK=media. The records are packed as crates/kaya/src/wire.rs packs
// them and go through the generated decoder and the binding's own arm.

using System;
using System.Collections.Generic;
using System.IO;
using System.Text;
using System.Threading;

[KayaGen]
record MediaCheckRow(string Name, Player Clip);

static class MediaCheck
{
    static void Check(bool ok, string what)
    {
        if (!ok)
        {
            Console.WriteLine("media-check: FAIL — " + what);
            Environment.Exit(1);
        }
    }

    static byte[] Record(ushort kind, Action<BinaryWriter> body)
    {
        var ms = new MemoryStream();
        var w = new BinaryWriter(ms);
        w.Write(0u);
        w.Write(kind);
        w.Write((ushort)0);
        body(w);
        var rec = ms.ToArray();
        BitConverter.GetBytes((uint)rec.Length).CopyTo(rec, 0);
        return rec;
    }

    static void Str(BinaryWriter w, string s)
    {
        var bytes = Encoding.UTF8.GetBytes(s);
        w.Write(KayaWire.ValueStr);
        w.Write((uint)bytes.Length);
        w.Write(bytes);
        for (int pad = (8 - bytes.Length % 8) % 8; pad > 0; pad--) w.Write((byte)0);
    }

    static void Strs(BinaryWriter w, params string[] tags)
    {
        w.Write((uint)tags.Length);
        w.Write(0u);
        foreach (var t in tags) Str(w, t);
    }

    static byte[] Changed(ulong player, uint state, uint failure, ulong duration, uint width,
        uint height, string detail) => Record(KayaWire.OccKindPlayerChanged, w =>
        {
            w.Write(player);
            w.Write(state);
            w.Write(failure);
            w.Write(duration);
            w.Write(width);
            w.Write(height);
            Str(w, detail);
        });

    static byte[] Ms(ushort kind, ulong player, ulong ms) => Record(kind, w =>
    {
        w.Write(player);
        w.Write(ms);
    });

    public static void Run()
    {
        // THE THREE FLAT RECORDS, round-tripped field by field.
        var moved = KayaApp.DecodeRecord(Changed(7, KayaWire.PlayerStateFailed,
            KayaWire.MediaFailureNotFound, 2000, 160, 90, "no such file")) as PlayerMoved;
        Check(moved is { Id: 7, State: PlayerState.Failed, Failure: MediaFailure.NotFound,
                DurationMs: 2000, Width: 160, Height: 90, Detail: "no such file" },
            $"player_changed decoded as {moved}");
        var tracks = KayaApp.DecodeRecord(Record(KayaWire.OccKindPlayerTracks, w =>
        {
            w.Write(7ul);
            w.Write(2u);
            w.Write(0u);
            Strs(w, "en", "fr");
            Strs(w, "en");
        })) as TracksListed;
        Check(tracks is { Id: 7 } && string.Join(",", tracks.Tracks.Audio) == "en,fr"
                && string.Join(",", tracks.Tracks.Captions) == "en"
                && tracks.Tracks.AudioSelected == 1 && tracks.Tracks.CaptionSelected == null,
            $"player_tracks decoded as {tracks?.Tracks}");
        var acted = KayaApp.DecodeRecord(Record(KayaWire.OccKindSessionAction, w =>
        {
            w.Write(KayaWire.SessionActionSeekTo);
            w.Write(0u);
            w.Write(1234ul);
        })) as SessionActed;
        Check(acted?.Action == new SessionAction(SessionActionKind.SeekTo, 1234),
            $"session_action decoded as {acted?.Action}");
        var at = KayaApp.DecodeRecord(Ms(KayaWire.OccKindPlayerPosition, 7, 1500)) as PlayerAt;
        Check(at is { Id: 7, PositionMs: 1500, Seeked: false },
            $"player_position decoded as {at}");
        Console.WriteLine("media-check: player_changed, player_tracks, session_action and "
            + "player_position round-trip");

        // THE MIRROR IS CURRENT INSIDE THE HANDLER, and a load resets the
        // position.
        var app = new KayaApp();
        var p = app.Build(tx => tx.Player(muted: true));
        var seen = new List<string>();
        app.OnPlayerState(p, (_, state) =>
            seen.Add($"{state.Name()} {app.Player(p).DurationMs} {app.Player(p).Width}"));
        app.OnFailed(p, (_, why, detail) => seen.Add($"failed {why.Name()} {detail}"));
        app.OnPosition(p, (_, ms) => seen.Add($"at {ms} {app.Player(p).PositionMs}"));
        app.OnSession((_, action) => seen.Add($"session {action.Kind} {action.AtMs}"));
        app.DispatchMedia(KayaApp.DecodeRecord(Changed(p.Id, KayaWire.PlayerStateReady, 0,
            2000, 160, 90, "")));
        app.DispatchMedia(KayaApp.DecodeRecord(Ms(KayaWire.OccKindPlayerPosition, p.Id, 1500)));
        app.DispatchMedia(KayaApp.DecodeRecord(Changed(p.Id, KayaWire.PlayerStateLoading, 0,
            0, 0, 0, "")));
        Check(app.Player(p).PositionMs == 0, "a load kept the old position");
        app.DispatchMedia(KayaApp.DecodeRecord(Changed(p.Id, KayaWire.PlayerStateFailed,
            KayaWire.MediaFailureNetwork, 0, 0, 0, "refused")));
        Check(app.Player(p) is { State: PlayerState.Failed, Failure: MediaFailure.Network },
            $"the mirror reads {app.Player(p)} after a failure");
        app.DispatchMedia(acted);
        var want = "ready 2000 160|at 1500 1500|loading 0 0|failed 0 0|failed network refused"
            + "|session SeekTo 1234";
        Check(string.Join("|", seen) == want,
            $"the handlers heard \"{string.Join("|", seen)}\", wanted \"{want}\"");
        Console.WriteLine("media-check: the mirror leads the handlers; failed hears the closed reason");

        // A STAMPED VIDEO'S PLAYER FIELD reaches PROP_PLAYER from the row.
        app.Build(tx =>
        {
            var rows = MediaCheckRowKaya.Collection(tx);
            tx.Mount(tx.Column(root =>
            {
                foreach (var row in rows.Rows())
                {
                    var n = row.Video(row.Clip);
                    var bound = KayaWire.TxBindPlayerElement(n.Id, 0, 1);
                    Check(Convert.ToHexString(tx.Records[^1]) == Convert.ToHexString(bound),
                        "a stamped video did not bind PROP_PLAYER to the row's player field");
                }
                return root;
            }));
            return 0;
        });
        Check(Convert.ToHexString(BitConverter.GetBytes((long)KayaRecords.ScalarWire(p)))
                == Convert.ToHexString(BitConverter.GetBytes((long)p.Id)),
            "a Player field does not travel as its id");
        Console.WriteLine("media-check: a stamped video binds the row's player field");
        Reader(app);
        CaptureCheck.Run(app);
        Console.WriteLine("media-check: OK");
    }

    static byte[] Framed(ulong reader, ulong read, ulong image, uint index) =>
        Record(KayaWire.OccKindReaderFrame, w =>
        {
            w.Write(reader);
            w.Write(read);
            w.Write(image);
            w.Write(index);
            w.Write(2u);
            w.Write(1u);
            w.Write(0u);
            w.Write(40ul * index);
            w.Write(40ul * index);
        });

    static byte[] Ended(ulong reader, ulong read, uint outcome, uint failure = 0) =>
        Record(KayaWire.OccKindReaderDone, w =>
        {
            w.Write(reader);
            w.Write(read);
            w.Write(outcome);
            w.Write(failure);
            Str(w, failure == 0 ? "" : "no decoder");
        });

    static string Hex(IEnumerable<byte[]> records) =>
        string.Join(",", System.Linq.Enumerable.Select(records, Convert.ToHexString));

    /// AFTER A CANCEL OR A CLOSE THE APP HEARS ONLY THE END: answers already
    /// in the ring are dropped, and the images they carried are released by
    /// the next commit, since the app never learned them (docs/media-plan.md
    /// §8 ruling 4). The awaited tier answers in index order, and a
    /// cancelled or failed awaiting gives back what its read had carried.
    static void Reader(KayaApp app)
    {
        foreach (var how in new[] { "cancel", "close" })
        {
            var heard = new List<string>();
            var (reader, read) = app.Build(tx =>
            {
                var r = tx.Reader(MediaSource.Asset("media/h264_frames.mp4"));
                return (r, tx.ReadFrames(r, new ulong[] { 0, 40 },
                    onFrame: (_, f) => heard.Add($"frame {f.Index}"),
                    onDone: (_, o) => heard.Add($"done {o is ReadOutcome.Cancelled}")));
            });
            app.Build(tx =>
            {
                if (how == "cancel") tx.CancelRead(reader, read);
                else tx.CloseReader(reader);
                return 0;
            });
            app.DispatchMedia(KayaApp.DecodeRecord(Framed(reader.Id, read.Id, 77, 0)));
            Check(Hex(app.pendingRecords) == Hex(new[] { KayaWire.TxReleaseImage(77) }),
                $"{how}: a late frame left {app.pendingRecords.Count} records for the next commit, "
                + "want its image's release");
            app.DispatchMedia(KayaApp.DecodeRecord(Ended(reader.Id, read.Id,
                KayaWire.ReadOutcomeCancelled)));
            Check(string.Join("|", heard) == "done True",
                $"{how}: the app heard \"{string.Join("|", heard)}\", want only the end");
            app.Build(_ => 0);
            Check(app.pendingRecords.Count == 0 && !app.readHandlers.ContainsKey(read.Id)
                    && app.abandonedReads.Count == 0,
                $"{how}: after the next commit the read is still registered or its release waits");
        }
        Console.WriteLine("media-check: a cancelled or closed read is heard only at its end, "
            + "its late images released");

        KayaApp.ClaimAppThread();
        var previous = System.Threading.SynchronizationContext.Current;
        app.InstallAsyncContext();
        try
        {
            var clip = app.Build(tx => tx.Reader(MediaSource.Asset("media/h264_frames.mp4")));
            ulong Latest() => System.Linq.Enumerable.Max(app.readHandlers.Keys);

            var whole = app.FramesAsync(clip, new ulong[] { 0, 40 }, 80, 45, FrameAccuracy.Keyframe);
            ulong read = Latest();
            app.DispatchMedia(KayaApp.DecodeRecord(Framed(clip.Id, read, 11, 1)));
            app.DispatchMedia(KayaApp.DecodeRecord(Framed(clip.Id, read, 10, 0)));
            app.DispatchMedia(KayaApp.DecodeRecord(Ended(clip.Id, read, KayaWire.ReadOutcomeCompleted)));
            app.DrainAsync();
            Check(whole.IsCompletedSuccessfully
                    && string.Join(",", whole.Result.ConvertAll(f => f.Index)) == "0,1",
                $"an awaited read answered {whole.Status}, want its frames in index order");

            var stop = new System.Threading.CancellationTokenSource();
            var given = app.FramesAsync(clip, new ulong[] { 0, 40 }, cancel: stop.Token);
            read = Latest();
            app.DispatchMedia(KayaApp.DecodeRecord(Framed(clip.Id, read, 12, 0)));
            stop.Cancel();
            app.DrainAsync();
            Check(given.IsCanceled
                    && Hex(app.pendingRecords) == Hex(new[] { KayaWire.TxReleaseImage(12),
                        KayaWire.TxCancelRead(clip.Id, read) }),
                $"a cancelled awaiting is {given.Status} with {app.pendingRecords.Count} records "
                + "waiting, want cancelled with its image's release and the read's cancel");
            app.DrainPosted();
            app.DispatchMedia(KayaApp.DecodeRecord(Framed(clip.Id, read, 13, 1)));
            Check(Hex(app.pendingRecords) == Hex(new[] { KayaWire.TxReleaseImage(13) }),
                "a cancelled awaiting's late frame was not released");
            app.DispatchMedia(KayaApp.DecodeRecord(Ended(clip.Id, read, KayaWire.ReadOutcomeCancelled)));
            app.Build(_ => 0);

            var failing = app.FramesAsync(clip, new ulong[] { 0, 40 });
            read = Latest();
            app.DispatchMedia(KayaApp.DecodeRecord(Framed(clip.Id, read, 14, 0)));
            app.DispatchMedia(KayaApp.DecodeRecord(Ended(clip.Id, read, KayaWire.ReadOutcomeFailed,
                KayaWire.MediaFailureDecodeError)));
            app.DrainAsync();
            Check(failing.Exception?.InnerException is MediaReadException
                    { Why: MediaFailure.DecodeError, Detail: "no decoder" }
                    && Hex(app.pendingRecords) == Hex(new[] { KayaWire.TxReleaseImage(14) }),
                $"a failed awaiting is {failing.Status} with {app.pendingRecords.Count} records "
                + "waiting, want MediaReadException and its image's release");
            app.DrainPosted();
            Check(app.pendingRecords.Count == 0 && app.readHandlers.Count == 0,
                "an awaited read's registration or release outlived it");
        }
        finally { System.Threading.SynchronizationContext.SetSynchronizationContext(previous); }
        Console.WriteLine("media-check: an awaited read answers in index order; a cancelled or "
            + "failed one gives back its images");
    }
}

// The capture surface's decode, mirror and dispatch, and its capture-thread
// callbacks' three rules (docs/capture-plan.md §2, §4): a transaction from
// the capture thread is refused, the frame a callback is handed is its own
// copy, and a released capture's callbacks are dropped. Headless, run inside
// KAYA_CHECK=media (MediaCheck.Run calls it); the callbacks are driven
// through the binding's own trampolines, from another thread, the way the
// core calls them.
static unsafe class CaptureCheck
{
    static void Check(bool ok, string what)
    {
        if (!ok)
        {
            Console.WriteLine("media-check: FAIL — capture: " + what);
            Environment.Exit(1);
        }
    }

    static byte[] Record(ushort kind, Action<BinaryWriter> body)
    {
        var ms = new MemoryStream();
        var w = new BinaryWriter(ms);
        w.Write(0u);
        w.Write(kind);
        w.Write((ushort)0);
        body(w);
        var rec = ms.ToArray();
        BitConverter.GetBytes((uint)rec.Length).CopyTo(rec, 0);
        return rec;
    }

    static void Str(BinaryWriter w, string s)
    {
        var bytes = Encoding.UTF8.GetBytes(s);
        w.Write(KayaWire.ValueStr);
        w.Write((uint)bytes.Length);
        w.Write(bytes);
        for (int pad = (8 - bytes.Length % 8) % 8; pad > 0; pad--) w.Write((byte)0);
    }

    static void I64(BinaryWriter w, long v)
    {
        w.Write(KayaWire.ValueI64);
        w.Write(8u);
        w.Write(v);
    }

    static byte[] Changed(ulong capture, uint state, uint failure, uint width, uint height,
        uint rate, string detail) => Record(KayaWire.OccKindCaptureChanged, w =>
        {
            w.Write(capture);
            w.Write(state);
            w.Write(failure);
            w.Write(0u);
            w.Write(width);
            w.Write(height);
            w.Write(rate);
            Str(w, detail);
        });

    /// Call the binding's frame trampoline on another thread, as kaya's
    /// capture thread does, with a 4x2 NV12 frame in native memory.
    static void FrameFromAnotherThread(ulong capture, byte* y, byte* uv)
    {
        var t = new Thread(() =>
        {
            var f = new Kaya.NativeCaptureFrame
            {
                Width = 4, Height = 2, Y = y, UV = uv, YStride = 4, UVStride = 4,
                TimestampNs = 7, Rotation = 90,
            };
            var trampoline = Kaya.FrameTrampoline;
            trampoline((IntPtr)(long)capture, &f);
        });
        t.Start();
        t.Join();
    }

    static void SamplesFromAnotherThread(ulong capture)
    {
        var t = new Thread(() =>
        {
            var chunk = stackalloc short[480];
            var trampoline = Kaya.SamplesTrampoline;
            trampoline((IntPtr)(long)capture, chunk, 480, 11);
        });
        t.Start();
        t.Join();
    }

    /// `app` is the process's one KayaApp, MediaCheck's.
    public static void Run(KayaApp app)
    {
        // THE FOUR RECORDS, decoded and absorbed; the mirror leads the handlers.
        var c = app.Build(tx => tx.Capture(camera: "cam", microphone: "mic", size: (640, 480)));
        var heard = new System.Collections.Generic.List<string>();
        app.OnCaptureState(c, (_, r) => heard.Add($"{r.State.Name()} {app.Capture(c).Width}"));
        app.OnCaptureFailed(c, (_, why, detail) => heard.Add($"failed {why.Name()} {detail}"));
        app.OnCaptureOverrun(c, (_, ms) => heard.Add($"overrun {ms}"));
        app.OnPermission((_, kind, p) => heard.Add($"{kind.Name()} {p.Name()} {app.Permission(kind).Name()}"));
        app.OnCaptureDevices((_, list) => heard.Add($"devices {list.Count} {app.CaptureDevices()[0].Id}"));
        Check(app.Permission(CaptureKind.Microphone) == Permission.Prompt,
            "an unheard permission does not read prompt");
        app.DispatchCapture(KayaApp.DecodeRecord(Record(KayaWire.OccKindCapturePermission, w =>
        {
            w.Write(KayaWire.CaptureKindCamera);
            w.Write(KayaWire.PermissionGranted);
            Str(w, "");
        })));
        app.DispatchCapture(KayaApp.DecodeRecord(Changed(c.Id, KayaWire.CaptureStateRunning,
            KayaWire.CaptureFailureNone, 640, 480, 30, "")));
        app.DispatchCapture(KayaApp.DecodeRecord(Record(KayaWire.OccKindCaptureOverrun, w =>
        {
            w.Write(c.Id);
            w.Write(250ul);
        })));
        app.DispatchCapture(KayaApp.DecodeRecord(Record(KayaWire.OccKindCaptureDevices, w =>
        {
            w.Write(5u);
            w.Write(0u);
            Str(w, "cam");
            Str(w, "Camera");
            I64(w, KayaWire.CaptureKindCamera);
            I64(w, KayaWire.CameraFacingFront);
            w.Write(KayaWire.ValueBool);
            w.Write(1u);
            w.Write(1ul);
        })));
        app.DispatchCapture(KayaApp.DecodeRecord(Changed(c.Id, KayaWire.CaptureStateFailed,
            KayaWire.CaptureFailureInUse, 0, 0, 0, "the platform's words")));
        var want = "camera granted granted|running 640|overrun 250|devices 1 cam|failed 0"
            + "|failed in_use the platform's words";
        Check(string.Join("|", heard) == want,
            $"the handlers heard \"{string.Join("|", heard)}\", wanted \"{want}\"");
        Check(app.CaptureDevices()[0] is { Kind: CaptureKind.Camera, Facing: CameraFacing.Front,
                Preferred: true },
            $"the device list reads {app.CaptureDevices()[0]}");
        Console.WriteLine("media-check: capture_changed, capture_permission, capture_overrun and "
            + "capture_devices reach the mirror before the handlers");

        // A CALLBACK HOLDS NO TRANSACTION, AND ITS FRAME IS ITS OWN COPY.
        KayaApp.ClaimAppThread();
        var y = (byte*)System.Runtime.InteropServices.NativeMemory.Alloc(8);
        var uv = (byte*)System.Runtime.InteropServices.NativeMemory.Alloc(4);
        for (int i = 0; i < 8; i++) y[i] = (byte)(16 + i);
        for (int i = 0; i < 4; i++) uv[i] = 128;
        var s = app.Build(tx => tx.Signal("before"));
        string? refused = null;
        CaptureFrame? kept = null;
        short[]? chunk = null;
        string ran = "";
        app.OnCaptureFrame(c, f =>
        {
            kept = f;
            try { app.Build(tx => tx.Write(s, "from the capture thread")); }
            catch (InvalidOperationException e) { refused = e.Message; }
            app.Post(tx => { ran = "posted"; tx.Write(s, "posted"); });
        });
        app.OnCaptureSamples(c, (samples, _) => chunk = samples);
        FrameFromAnotherThread(c.Id, y, uv);
        Check(refused is { } msg && msg.Contains("belongs to the app thread") && msg.Contains("App.Post"),
            $"a transaction from the capture thread was answered with \"{refused}\" — it must be "
            + "the wrong-thread refusal naming App.Post");
        app.DrainPosted();
        Check(ran == "posted", "the callback's post did not reach the app thread");
        Check(kept is { Width: 4, Height: 2, YStride: 4, UVStride: 4, TimestampNs: 7, Rotation: 90 }
                && kept.Y.Length == 8 && kept.UV.Length == 4,
            $"the frame arrived as {kept}");
        var first = kept!;
        first.UV[0] = 1;
        y[0] = 99;
        FrameFromAnotherThread(c.Id, y, uv);
        Check(first.Y[0] == 16 && uv[0] == 128 && kept!.Y[0] == 99,
            $"a kept frame reads {first.Y[0]} after the next frame brought {kept?.Y[0]}, and "
            + $"kaya's UV reads {uv[0]} after the app wrote its copy — a frame must be the "
            + "callback's own copy");
        app.DrainPosted();
        SamplesFromAnotherThread(c.Id);
        Check(chunk is { Length: 480 }, $"the chunk arrived as {chunk?.Length} samples");
        Console.WriteLine("media-check: a capture callback is refused a transaction, posts, and "
            + "keeps its own copy");

        // A CALLBACK THAT THROWS IS LOGGED AND THE CAPTURE KEEPS RUNNING
        // (DESIGN.md's abort rule on the capture thread): the next frame and
        // chunk still reach it.
        int frames = 0, chunks = 0;
        app.OnCaptureFrame(c, _ =>
        {
            if (++frames == 1) throw new InvalidOperationException("the app's first frame");
        });
        app.OnCaptureSamples(c, (_, _) =>
        {
            if (++chunks == 1) throw new InvalidOperationException("the app's first chunk");
        });
        for (int i = 0; i < 2; i++)
        {
            FrameFromAnotherThread(c.Id, y, uv);
            SamplesFromAnotherThread(c.Id);
        }
        Check(frames == 2 && chunks == 2,
            $"after a throwing call the callbacks ran {frames} frame(s) and {chunks} chunk(s), want 2 each");
        app.OnCaptureFrame(c, f => kept = f);
        app.OnCaptureSamples(c, (samples, _) => chunk = samples);
        Console.WriteLine("media-check: a capture callback that throws is logged and the capture "
            + "keeps running");

        // A RELEASED CAPTURE'S CALLBACKS ARE DROPPED, once the release commits.
        try
        {
            app.Build<int>(tx =>
            {
                tx.ReleaseCapture(c);
                throw new InvalidOperationException("abandoned");
            });
        }
        catch (InvalidOperationException) { }
        Check(Kaya.HoldsCaptureSinks(c.Id), "a rolled-back release dropped the callbacks");
        app.Build(tx => tx.ReleaseCapture(c));
        Check(!Kaya.HoldsCaptureSinks(c.Id), "the binding still holds a released capture's callbacks");
        kept = null;
        chunk = null;
        FrameFromAnotherThread(c.Id, y, uv);
        SamplesFromAnotherThread(c.Id);
        Check(kept == null && chunk == null, "a released capture's callbacks still ran");
        System.Runtime.InteropServices.NativeMemory.Free(y);
        System.Runtime.InteropServices.NativeMemory.Free(uv);
        Console.WriteLine("media-check: a released capture's callbacks are dropped");
    }
}
