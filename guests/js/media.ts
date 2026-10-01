// The media suite (tools/scenes/media_*.steps; docs/media-plan.md §7a):
// one player shown by one video view. media_formats and media_delivery
// walk a list of items, each loaded, played to its end and summed up in
// label#0; media_session attaches the player to the app's session and
// answers `next` itself; media_tracks lists and selects each item's audio
// and caption tracks and reads the current cue; media_feed stamps a video
// view per row, each showing its row's own player, and reads their
// visibility (§7b).
//     KAYA_SELFTEST=media_formats node guests/js/media.ts

import * as kaya from "kaya-gui";

const H264 = "avc1.64000b, mp4a.40.2";
const HEVC = "hvc1.1.6.L60.90, mp4a.40.2";
const AV1 = "av01.0.00M.08, mp4a.40.2";

type Item = { name: string; source: kaya.MediaSource; mime: string; codecs: string };

function local(name: string, mime: string, codecs: string, label?: string): Item {
  return { name: label ?? name, source: kaya.MediaSource.asset(`media/${name}`), mime, codecs };
}

function served(base: string, name: string, mime: string, codecs: string): Item {
  return { name, source: kaya.MediaSource.url(`${base}/${name}`), mime, codecs };
}

function mediaUrl(): string {
  const base = process.env["KAYA_MEDIA_URL"];
  if (base === undefined) {
    throw new Error(
      "kaya: the media scenes that stream read KAYA_MEDIA_URL, the local server the lane starts (tools/lib/media_server.py); a hand run goes through tools/run-leg.py",
    );
  }
  return base;
}

function formats(): Item[] {
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
  ];
}

// The local server's items, and the three failures: a 404, a local file
// that is not there, and a port nothing listens on.
function delivery(): Item[] {
  const base = mediaUrl();
  const colon = base.lastIndexOf(":");
  const refused = colon < 0 ? base : `${base.slice(0, colon)}:9`;
  return [
    served(base, "h264_aac.mp4", "video/mp4", H264),
    served(base, "hls_fmp4.m3u8", "application/vnd.apple.mpegurl", ""),
    served(base, "hls_mpegts.m3u8", "application/vnd.apple.mpegurl", ""),
    served(base, "dash.mpd", "application/dash+xml", ""),
    served(base, "nope.mp4", "video/mp4", H264),
    local("missing.mp4", "video/mp4", H264),
    { name: "refused.mp4", source: kaya.MediaSource.url(`${refused}/h264_aac.mp4`), mime: "video/mp4", codecs: H264 },
  ];
}

function yesNo(can: boolean): string {
  return can ? "yes" : "no";
}

const app = new kaya.App();

function suiteApp(scene: string): void {
  const session = scene === "media_session";
  const items = scene === "media_delivery" ? delivery() : formats();
  let at = 0;
  let can = false;
  let furthest = 0;
  let nexts = 0;

  function onNext(): void {
    const item = items[at];
    if (item === undefined) return;
    at += 1;
    can = kaya.canPlay(item.mime, item.codecs);
    furthest = 0;
    player.setSource(item.source);
    name.set(item.name);
    summary.set("loading");
  }

  function onToggle(): void {
    if (player.state === "idle") player.setSource(kaya.MediaSource.asset("media/h264_aac.mp4"));
    player.play();
  }

  function onState(state: kaya.PlayerState): void {
    if (session) {
      if (state === "playing" || state === "paused") summary.set(state);
      return;
    }
    if (state === "ready") player.play();
    else if (state === "ended") {
      const played = furthest >= 1000 ? "played past 1s" : `played to ${furthest}ms`;
      summary.set(
        `ready ${(player.durationMs / 1000).toFixed(1)}s ${player.width}x${player.height}, ${played}, ended, can_play ${yesNo(can)}`,
      );
    }
  }

  function onFailed(why: kaya.MediaFailure): void {
    summary.set(`failed ${why}, can_play ${yesNo(can)}`);
  }

  function onPosition(ms: number): void {
    furthest = Math.max(furthest, ms);
  }

  function onAction(action: kaya.SessionAction): void {
    if (action === "next") {
      nexts += 1;
      name.set(`next ${nexts}`);
    }
  }

  const { summary, name, player } = app.window({ title: "media" }, () => {
    const summary = kaya.signal("idle");
    const name = kaya.signal(session ? "next 0" : "none");
    const player = kaya.player({ muted: true, loop: session, onState, onFailed, onPosition });
    kaya.column(() => {
      kaya.label({ bind: summary }); // label#0
      kaya.label({ bind: name }); // label#1
      kaya.video(player).a11yId("clip").a11yLabel("Clip"); // video#0
      kaya.button(session ? "play" : "next", { onClick: session ? onToggle : onNext }); // button#0
    });
    if (session) kaya.session({ player, title: "kaya media", artist: "kaya", handles: ["next"], onAction });
    return { summary, name, player };
  });
}

// One track list as a line: `audio en, fr [2]`, the selection counting
// from 1, `-` for none; `audio none` for an empty list.
function trackLine(what: string, tags: readonly string[], selected: number | null): string {
  if (tags.length === 0) return `${what} none`;
  const pick = selected === null ? "-" : String(selected + 1);
  return `${what} ${tags.join(", ")} [${pick}]`;
}

// media_tracks (docs/media-plan.md §3, §7a): each item's audio and caption
// listing, a second audio track selected, the last caption track selected,
// and the cue read at 0.5 s and 1.5 s with the player paused there. The
// sidecar items are the floor file with captions.vtt (the first over
// h264_frames.mp4): an asset, then fetched from the local server, then a 404
// there.
function tracksApp(): void {
  const base = mediaUrl();
  const items: [Item, kaya.MediaSource | null][] = [
    [local("h264_2audio.mp4", "video/mp4", H264), null],
    [local("vp9_2audio.webm", "video/webm", "vp09.00.10.08, opus"), null],
    [served(base, "hls_fmp4.m3u8", "application/vnd.apple.mpegurl", ""), null],
    [served(base, "hls_mpegts.m3u8", "application/vnd.apple.mpegurl", ""), null],
    [local("h264_tx3g.mp4", "video/mp4", H264), null],
    [local("h264_frames.mp4", "video/mp4", H264, "h264_frames.mp4 + captions.vtt"), kaya.MediaSource.asset("media/captions.vtt")],
    [local("h264_aac.mp4", "video/mp4", H264, "h264_aac.mp4 + http captions.vtt"), kaya.MediaSource.url(`${base}/captions.vtt`)],
    [local("h264_aac.mp4", "video/mp4", H264, "h264_aac.mp4 + http nope.vtt"), kaya.MediaSource.url(`${base}/nope.vtt`)],
  ];
  let at = 0;
  let can = false;

  function onNext(): void {
    const entry = items[at];
    if (entry === undefined) return;
    at += 1;
    const [item, sidecar] = entry;
    can = kaya.canPlay(item.mime, item.codecs);
    if (sidecar !== null) player.setCaptions(sidecar, "en");
    else player.clearCaptions();
    player.setSource(item.source);
    name.set(item.name);
    summary.set("loading");
    cue.set("");
  }

  function onCaptions(): void {
    const listed = player.tracks.captions.length;
    if (listed === 0) cue.set("captions none");
    else player.selectCaptions(listed - 1);
  }

  function seekTo(ms: number): () => void {
    return () => {
      player.pause();
      player.seek(ms);
    };
  }

  function onState(state: kaya.PlayerState): void {
    if (state === "ready") summary.set(`ready, can_play ${yesNo(can)}`);
  }

  function onFailed(why: kaya.MediaFailure): void {
    const line = `failed ${why}, can_play ${yesNo(can)}`;
    summary.set(line);
    audio.set(line);
  }

  function onTracks(t: kaya.Tracks): void {
    audio.set(trackLine("audio", t.audio, t.audioSelected));
    captions.set(trackLine("captions", t.captions, t.captionSelected));
  }

  const { summary, name, audio, captions, cue, player } = app.window({ title: "media tracks" }, () => {
    const summary = kaya.signal("idle");
    const name = kaya.signal("none");
    const audio = kaya.signal("audio none");
    const captions = kaya.signal("captions none");
    const cue = kaya.signal("");
    const player = kaya.player({ muted: true, onState, onFailed, onTracks, onCue: (text) => cue.set(text) });
    kaya.column(() => {
      kaya.label({ bind: summary }); // label#0
      kaya.label({ bind: name }); // label#1
      kaya.label({ bind: audio }); // label#2
      kaya.label({ bind: captions }); // label#3
      kaya.label({ bind: cue }); // label#4
      kaya.video(player).a11yId("clip").a11yLabel("Clip"); // video#0
      kaya.button("next", { onClick: onNext }); // button#0
      kaya.button("audio 2", { onClick: () => player.selectAudio(1) }); // button#1
      kaya.button("captions", { onClick: onCaptions }); // button#2
      kaya.button("at 0.5s", { onClick: seekTo(500) }); // button#3
      kaya.button("at 1.5s", { onClick: seekTo(1500) }); // button#4
      kaya.button("captions off", { onClick: () => player.selectCaptions(null) }); // button#5
      kaya.button("play", {
        onClick: () => {
          player.seek(0);
          player.play();
        },
      }); // button#6
    });
    return { summary, name, audio, captions, cue, player };
  });
}

const Clip = kaya.record({ name: String, player: kaya.Player }, "Clip");

const FEED_ROWS = 10;

// media_feed (docs/media-plan.md §7b): a scroll of rows, each a video view
// showing its row's own player, paused on its first frame; the first and
// last rows' visibility in label#0 and label#1, as the feed app reads it
// to keep players only for the rows on screen.
function feedApp(): void {
  function onShown(row: kaya.RowHandle<kaya.Fields<typeof Clip.schema>>, shown: number): void {
    const at = Number(row.key);
    const word = shown >= 0.999 ? "whole" : shown > 0 ? "in" : "out";
    if (at === 0) first.set(`r0 ${word}`);
    if (at === FEED_ROWS - 1) last.set(`r${at} ${word}`);
  }

  const { first, last } = app.window({ title: "media feed", width: 420, height: 480 }, () => {
    const first = kaya.signal("r0 out");
    const last = kaya.signal(`r${FEED_ROWS - 1} out`);
    const clips = kaya.collection(Clip);
    kaya.column(() => {
      kaya.label({ bind: first }); // label#0
      kaya.label({ bind: last }); // label#1
      kaya.scroll({ grow: 1 }, () => {
        kaya.column(() => {
          for (const clip of clips) {
            kaya.label({ bind: clip.name });
            kaya.video(clip.player, { onVisibility: onShown });
          }
        });
      });
    });
    for (let i = 0; i < FEED_ROWS; i++) {
      const player = kaya.player({ source: kaya.MediaSource.asset("media/h264_aac.mp4"), muted: true });
      clips.insert(i, Clip({ name: `r${i}`, player }));
    }
    return { first, last };
  });
}

const scene = process.env["KAYA_SELFTEST"] ?? "";
if (scene === "media_tracks") tracksApp();
else if (scene === "media_feed") feedApp();
else suiteApp(scene);

app.run();
