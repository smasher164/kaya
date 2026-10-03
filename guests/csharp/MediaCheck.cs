// The media surface's decode, mirror and dispatch (docs/media-plan.md),
// run rather than read. Headless, driven by tools/check-abort.py with
// KAYA_CHECK=media. The records are packed as crates/kaya/src/wire.rs packs
// them and go through the generated decoder and the binding's own arm.

using System;
using System.Collections.Generic;
using System.IO;
using System.Text;

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
