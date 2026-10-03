"""The media suite (tools/scenes/media_*.steps; docs/media-plan.md §7a):
one player shown by one video view. `media_formats` and `media_delivery`
walk a list of items, each loaded, played to its end and summed up in
label#0; `media_session` attaches the player to the app's session and
answers `next` itself; `media_tracks` lists and selects each item's audio
and caption tracks and reads the current cue; `media_feed` stamps a video
view per row, each showing its row's own player, and reads their
visibility (§7b); `media_reader` draws a filmstrip and a waveform on canvases
from a reader with no player (§8 rulings 3 and 4)."""

import os
import sys
from dataclasses import dataclass

import kaya

H264 = "avc1.64000b, mp4a.40.2"
HEVC = "hvc1.1.6.L60.90, mp4a.40.2"
AV1 = "av01.0.00M.08, mp4a.40.2"


@dataclass
class Item:
    name: str
    source: kaya.MediaSource
    mime: str
    codecs: str


def local(name, mime, codecs, label=None):
    return Item(label or name, kaya.MediaSource.asset(f"media/{name}"), mime, codecs)


def served(base, name, mime, codecs):
    return Item(name, kaya.MediaSource.url(f"{base}/{name}"), mime, codecs)


def media_url():
    base = os.environ.get("KAYA_MEDIA_URL")
    if base is None:
        raise SystemExit(
            "kaya: the media scenes that stream read KAYA_MEDIA_URL, the local "
            "server the lane starts (tools/lib/media_server.py); a hand run "
            "goes through tools/run-leg.py")
    return base


def formats():
    return [
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
        local("tone.wav", "audio/wav", ""),
    ]


def delivery():
    """The local server's items, and the three failures: a 404, a local
    file that is not there, and a port nothing listens on."""
    base = media_url()
    refused = base.rsplit(":", 1)[0] + ":9" if ":" in base else base
    return [
        served(base, "h264_aac.mp4", "video/mp4", H264),
        served(base, "hls_fmp4.m3u8", "application/vnd.apple.mpegurl", ""),
        served(base, "hls_mpegts.m3u8", "application/vnd.apple.mpegurl", ""),
        served(base, "dash.mpd", "application/dash+xml", ""),
        served(base, "nope.mp4", "video/mp4", H264),
        local("missing.mp4", "video/mp4", H264),
        Item("refused.mp4", kaya.MediaSource.url(f"{refused}/h264_aac.mp4"),
             "video/mp4", H264),
    ]


def yes_no(can):
    return "yes" if can else "no"


app = kaya.App()


def suite_app(scene):
    session = scene == "media_session"
    items = delivery() if scene == "media_delivery" else formats()
    state = {"at": 0, "can": False, "furthest": 0, "nexts": 0}

    def on_next():
        if state["at"] >= len(items):
            return
        item = items[state["at"]]
        state["at"] += 1
        state["can"] = kaya.can_play(item.mime, item.codecs)
        state["furthest"] = 0
        player.set_source(item.source)
        name.set(item.name)
        summary.set("loading")

    def on_toggle():
        if player.state == kaya.PlayerState.IDLE:
            player.set_source(kaya.MediaSource.asset("media/h264_aac.mp4"))
        player.play()

    def on_state(st):
        if session:
            if st in (kaya.PlayerState.PLAYING, kaya.PlayerState.PAUSED):
                summary.set(str(st))
            return
        if st == kaya.PlayerState.READY:
            player.play()
        elif st == kaya.PlayerState.ENDED:
            furthest = state["furthest"]
            played = ("played past 1s" if furthest >= 1000
                      else f"played to {furthest}ms")
            summary.set(
                f"ready {player.duration_ms / 1000.0:.1f}s "
                f"{player.width}x{player.height}, {played}, ended, "
                f"can_play {yes_no(state['can'])}")

    def on_failed(why, _detail):
        summary.set(f"failed {why}, can_play {yes_no(state['can'])}")

    def on_position(ms):
        state["furthest"] = max(state["furthest"], ms)

    def on_action(action, _at_ms):
        if action == kaya.SessionAction.NEXT:
            state["nexts"] += 1
            name.set(f"next {state['nexts']}")

    with app.window("media"):
        summary = kaya.signal("idle")
        name = kaya.signal("next 0" if session else "none")
        player = kaya.player(muted=True, loop=session, on_state=on_state,
                             on_failed=on_failed, on_position=on_position)
        with kaya.column():
            kaya.label(bind=summary)                                # label#0
            kaya.label(bind=name)                                   # label#1
            kaya.video(player).a11y_id("clip").a11y_label("Clip")  # video#0
            kaya.button("play" if session else "next",              # button#0
                        on_click=on_toggle if session else on_next)
        if session:
            kaya.session(player=player, title="kaya media", artist="kaya",
                         handles=[kaya.SessionAction.NEXT],
                         on_action=on_action)


def track_line(what, tags, selected):
    """One track list as a line: `audio en, fr [2]`, the selection
    counting from 1, `-` for none; `audio none` for an empty list."""
    if not tags:
        return f"{what} none"
    pick = "-" if selected is None else str(selected + 1)
    return f"{what} {', '.join(tags)} [{pick}]"


def tracks_app():
    """media_tracks (docs/media-plan.md §3, §7a): each item's audio and
    caption listing, a second audio track selected, the last caption track
    selected, and the cue read at 0.5 s and 1.5 s with the player paused
    there. The sidecar items are the floor file with captions.vtt (the first
    over h264_frames.mp4): an asset, then fetched from the local server, then
    a 404 there."""
    base = media_url()
    items = [
        (local("h264_2audio.mp4", "video/mp4", H264), None),
        (local("vp9_2audio.webm", "video/webm", "vp09.00.10.08, opus"), None),
        (served(base, "hls_fmp4.m3u8", "application/vnd.apple.mpegurl", ""), None),
        (served(base, "hls_mpegts.m3u8", "application/vnd.apple.mpegurl", ""), None),
        (local("h264_tx3g.mp4", "video/mp4", H264), None),
        (local("h264_frames.mp4", "video/mp4", H264, "h264_frames.mp4 + captions.vtt"),
         kaya.MediaSource.asset("media/captions.vtt")),
        (local("h264_aac.mp4", "video/mp4", H264, "h264_aac.mp4 + http captions.vtt"),
         kaya.MediaSource.url(f"{base}/captions.vtt")),
        (local("h264_aac.mp4", "video/mp4", H264, "h264_aac.mp4 + http nope.vtt"),
         kaya.MediaSource.url(f"{base}/nope.vtt")),
    ]
    state = {"at": 0, "can": False}

    def on_next():
        if state["at"] >= len(items):
            return
        item, sidecar = items[state["at"]]
        state["at"] += 1
        state["can"] = kaya.can_play(item.mime, item.codecs)
        if sidecar is not None:
            player.set_captions(sidecar, "en")
        else:
            player.clear_captions()
        player.set_source(item.source)
        name.set(item.name)
        summary.set("loading")
        cue.set("")

    def on_second_audio():
        player.select_audio(1)

    def on_captions():
        listed = len(player.tracks.captions)
        if listed == 0:
            cue.set("captions none")
        else:
            player.select_captions(listed - 1)

    def on_captions_off():
        player.select_captions(None)

    def at(ms):
        def go():
            player.pause()
            player.seek(ms)
        return go

    def on_play_from_start():
        player.seek(0)
        player.play()

    def on_state(st):
        if st == kaya.PlayerState.READY:
            summary.set(f"ready, can_play {yes_no(state['can'])}")

    def on_failed(why, _detail):
        line = f"failed {why}, can_play {yes_no(state['can'])}"
        summary.set(line)
        audio.set(line)

    def on_tracks(t):
        audio.set(track_line("audio", t.audio, t.audio_selected))
        captions.set(track_line("captions", t.captions, t.caption_selected))

    def on_cue(text):
        cue.set(text)

    with app.window("media tracks"):
        summary = kaya.signal("idle")
        name = kaya.signal("none")
        audio = kaya.signal("audio none")
        captions = kaya.signal("captions none")
        cue = kaya.signal("")
        player = kaya.player(muted=True, on_state=on_state, on_failed=on_failed,
                             on_tracks=on_tracks, on_cue=on_cue)
        with kaya.column():
            kaya.label(bind=summary)                                # label#0
            kaya.label(bind=name)                                   # label#1
            kaya.label(bind=audio)                                  # label#2
            kaya.label(bind=captions)                               # label#3
            kaya.label(bind=cue)                                    # label#4
            kaya.video(player).a11y_id("clip").a11y_label("Clip")  # video#0
            kaya.button("next", on_click=on_next)                   # button#0
            kaya.button("audio 2", on_click=on_second_audio)        # button#1
            kaya.button("captions", on_click=on_captions)           # button#2
            kaya.button("at 0.5s", on_click=at(500))                # button#3
            kaya.button("at 1.5s", on_click=at(1500))               # button#4
            kaya.button("captions off", on_click=on_captions_off)   # button#5
            kaya.button("play", on_click=on_play_from_start)        # button#6


@dataclass
class Clip:
    name: str
    player: kaya.Player


FEED_ROWS = 10


def feed_app():
    """media_feed (docs/media-plan.md §7b): a scroll of rows, each a video
    view showing its row's own player, paused on its first frame; the first
    and last rows' visibility in label#0 and label#1, as the feed app reads
    it to keep players only for the rows on screen."""

    def on_shown(row, shown):
        at = int(row.key)
        word = "whole" if shown >= 0.999 else "in" if shown > 0.0 else "out"
        if at == 0:
            first.set(f"r0 {word}")
        if at == FEED_ROWS - 1:
            last.set(f"r{at} {word}")

    with app.window("media feed", width=420.0, height=480.0):
        first = kaya.signal("r0 out")
        last = kaya.signal(f"r{FEED_ROWS - 1} out")
        clips = kaya.collection(Clip)
        with kaya.column():
            kaya.label(bind=first)                                  # label#0
            kaya.label(bind=last)                                   # label#1
            with kaya.scroll(grow=1.0):
                with kaya.column():
                    for clip in clips:
                        kaya.label(bind=clip.name)
                        kaya.video(clip.player, on_visibility=on_shown)
        for i in range(FEED_ROWS):
            p = kaya.player(kaya.MediaSource.asset("media/h264_aac.mp4"),
                            muted=True)
            clips.insert(i, Clip(name=f"r{i}", player=p))


def outcome_word(outcome):
    if outcome.status == kaya.ReadStatus.FAILED:
        return f"failed {outcome.failure}"
    return str(outcome.status)


def frame_line(what, frames, outcome):
    """The answered times as the labels spell them: each time asked, then
    the time of the picture the platform returned, in ms."""
    times = " ".join(f"{f.requested_ms}@{f.actual_ms}"
                     for f in sorted(frames, key=lambda f: f.index))
    return f"{what} {times} {outcome_word(outcome)}"


# h264_frames.mp4's grey bands: frame 12 (0x505050) and frame 37 (0xA0A0A0)
# at 25 fps, its one keyframe at 0 (tools/gen-media.py).
BANDS = [480, 1480]


def reader_app():
    """media_reader (docs/media-plan.md §8 rulings 3 and 4): a reader with
    no player draws a filmstrip of h264_frames.mp4's exact and keyframe
    pictures and a waveform of tone.wav's peaks beside two loaded images; a
    read the server never finishes is cancelled and another is closed under
    its reader; a file that is not media and a missing file fail."""
    base = media_url()
    exact, keyframe, failures, missing, cancels = [], [], [], [], []
    trickling = []

    def on_exact_done(outcome):
        labels[0].set(frame_line("exact", exact, outcome))
        clip.frames(BANDS, max_size=(80, 45),
                    accuracy=kaya.FrameAccuracy.KEYFRAME,
                    on_frame=keyframe.append, on_done=on_keyframe_done)

    def on_keyframe_done(outcome):
        labels[1].set(frame_line("keyframe", keyframe, outcome))
        tiles = [f.image for f in sorted(exact, key=lambda f: f.index)]
        tiles += [f.image for f in sorted(keyframe, key=lambda f: f.index)]
        with strip.draw() as d:
            for i, image in enumerate(tiles):
                d.image(image, 80.0 * i, 0.0, 80.0, 45.0)

    def on_peaks(p):
        lows = min((p.pair(i)[0] for i in range(len(p))), default=0)
        highs = max((p.pair(i)[1] for i in range(len(p))), default=0)
        labels[2].set(f"peaks {p.sample_rate} Hz, {p.channels} ch, "
                      f"{len(p)} pairs of {p.samples_per_pair}, {lows}..{highs}")

        def y(v):
            return 30.0 - float(v) * 25.0 / 8192.0

        with wave.draw() as d:
            for i in range(len(p)):
                lo, hi = p.pair(i)
                x = 8.0 + 7.0 * i
                (d.move_to(x, y(hi)).line_to(x + 5.0, y(hi))
                 .line_to(x + 5.0, y(lo)).line_to(x, y(lo)).close())
                d.fill("series", "nonzero")
            d.image(logo, 150.0, 4.0, 20.0, 20.0)
            d.image(photo, 150.0, 30.0, 40.0, 30.0)

    def on_peaks_done(outcome):
        if outcome.status != kaya.ReadStatus.COMPLETED:
            labels[2].set(f"peaks {outcome_word(outcome)}")

    def into(lines, label, what):
        def done(outcome):
            lines.append(f"{what} {outcome_word(outcome)}")
            lines.sort()
            label.set("; ".join(lines))
        return done

    def on_start():
        trickle = kaya.reader(kaya.MediaSource.url(f"{base}/trickle/h264_frames.mp4"))
        read = trickle.frames([0], max_size=(80, 45),
                              accuracy=kaya.FrameAccuracy.EXACT,
                              on_done=into(cancels, labels[5], "trickle"))
        closing = kaya.reader(kaya.MediaSource.url(f"{base}/trickle/h264_aac.mp4"))
        closing.frames([0], max_size=(80, 45), accuracy=kaya.FrameAccuracy.EXACT,
                       on_done=into(cancels, labels[5], "closed"))
        trickling[:] = [read, closing]
        labels[5].set("reading")

    def on_cancel():
        if trickling:
            read, closing = trickling
            trickling.clear()
            read.cancel()
            closing.close()

    with app.window("media reader", width=560.0, height=560.0):
        labels = [kaya.signal(s) for s in
                  ("exact", "keyframe", "peaks", "failures", "no track", "cancel")]
        with kaya.column():
            for label in labels[:5]:
                kaya.label(bind=label)                              # label#0..#4
            strip = kaya.canvas((320.0, 45.0)).a11y_id("strip").a11y_label("Filmstrip")
            wave = kaya.canvas((200.0, 60.0)).a11y_id("wave").a11y_label("Waveform")
            kaya.button("start", on_click=on_start)                 # button#0
            kaya.button("cancel", on_click=on_cancel)               # button#1
            kaya.label(bind=labels[5])                              # label#5

        clip = kaya.reader(kaya.MediaSource.asset("media/h264_frames.mp4"))
        clip.frames(BANDS, max_size=(80, 45), accuracy=kaya.FrameAccuracy.EXACT,
                    on_frame=exact.append, on_done=on_exact_done)

        tone = kaya.reader(kaya.MediaSource.asset("media/tone.wav"))
        tone.peaks(4800, on_peaks=on_peaks, on_done=on_peaks_done)

        for what, source in (("OFL.txt", "fonts/OFL.txt"),
                             ("missing.mp4", "media/missing.mp4")):
            kaya.reader(kaya.MediaSource.asset(source)).frames(
                [0], max_size=(80, 45), accuracy=kaya.FrameAccuracy.EXACT,
                on_done=into(failures, labels[3], what))

        kaya.reader(kaya.MediaSource.asset("media/h264_noaudio.mp4")).peaks(
            4800, on_done=into(missing, labels[4], "noaudio peaks"))
        kaya.reader(kaya.MediaSource.asset("media/tone.mp3")).frames(
            [0], max_size=(80, 45), accuracy=kaya.FrameAccuracy.EXACT,
            on_done=into(missing, labels[4], "mp3 frames"))

        logo = kaya.load_image(kaya.MediaSource.asset("images/a11y-logo.png"))
        photo = kaya.load_image(kaya.MediaSource.asset("images/photo.jpg"))


scene = os.environ.get("KAYA_SELFTEST", "")
if scene == "media_tracks":
    tracks_app()
elif scene == "media_reader":
    reader_app()
elif scene == "media_feed":
    feed_app()
else:
    suite_app(scene)

sys.exit(app.run())
