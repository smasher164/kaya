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
        Console.WriteLine("media-check: OK");
    }
}
