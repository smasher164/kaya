#!/usr/bin/env python3
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent / "lib"))
from kaya_gate import ROOT, dev_shell_or_die, scratch_dir

dev_shell_or_die()

# The media test suite's files (docs/media-plan.md §7a; the probe that
# chose them is docs/probes/media-suite-2026-09-29.md). FFmpeg is the dev
# shell's, a development tool only: nothing shipped links it.
#
#   tools/gen-media.py                  write guests/assets/media/
#   tools/gen-media.py --out DIR        write DIR instead
#   tools/gen-media.py --check [--against DIR]
#                                       regenerate into scratch and compare
#                                       byte for byte with the committed
#                                       family (or DIR); never writes it
#
# Byte-stable only with +bitexact as OUTPUT options and the Ogg serial
# pinned (docs/probes/media-suite-2026-09-29.md, The files); one thread per
# encoder, since a threaded encoder's output depends on the scheduling.

import argparse
import subprocess

FAMILY = ROOT / "guests" / "assets" / "media"

COLOR = "0xC83C1E"
SIZE = "160x90"
FPS = 25
SECONDS = 2

BITEXACT = ["-fflags", "+bitexact", "-flags", "+bitexact",
            "-map_metadata", "-1", "-map_chapters", "-1"]
# THE sRGB TRANSFER TAG, not bt709's: AVFoundation colour-manages the frame,
# so a bt709 transfer reads back CF4421 and this one C83C1E; and the source
# is built in RGB, since lavfi's `color` computes its YUV with BT.601 whatever
# the file says (docs/traps.md, the video colour entry).
TAGS709 = ["-color_primaries", "bt709", "-color_trc", "iec61966-2-1",
           "-colorspace", "bt709", "-color_range", "tv"]
VF = ("scale=out_color_matrix=bt709:out_range=tv,format=yuv420p,"
      "setparams=color_primaries=bt709:color_trc=iec61966-2-1:colorspace=bt709:range=tv")

CUES = """WEBVTT

00:00:00.000 --> 00:00:01.000
first cue

00:00:01.000 --> 00:00:02.000
second cue
"""

H264 = ["-c:v", "libx264", "-profile:v", "high", "-level:v", "1.1",
        "-bf", "0", "-g", str(FPS), "-keyint_min", str(FPS),
        "-sc_threshold", "0", "-threads", "1",
        "-x264-params", "threads=1:lookahead-threads=1:sliced-threads=0"]
HEVC = ["-c:v", "libx265", "-tag:v", "hvc1", "-g", str(FPS),
        "-x265-params", "pools=1:frame-threads=1:log-level=error:bframes=0"]
VP9 = ["-c:v", "libvpx-vp9", "-threads", "1", "-row-mt", "0",
       "-deadline", "good", "-cpu-used", "8", "-b:v", "100k",
       "-g", str(FPS)]
AV1 = ["-c:v", "libaom-av1", "-threads", "1", "-row-mt", "0",
       "-cpu-used", "8", "-b:v", "100k", "-g", str(FPS)]
AAC = ["-c:a", "aac", "-b:a", "64k"]
OPUS = ["-c:a", "libopus", "-b:a", "48k"]


def video():
    return ["-f", "lavfi", "-i",
            f"color=c={COLOR}:s={SIZE}:r={FPS}:d={SECONDS},format=rgb24"]


def tone(hz):
    return ["-f", "lavfi", "-i",
            f"sine=frequency={hz}:sample_rate=48000:duration={SECONDS}"]


def ffmpeg(out, *args):
    cmd = ["ffmpeg", "-nostdin", "-hide_banner", "-loglevel", "error",
           "-y", *args]
    r = subprocess.run(cmd, cwd=out, capture_output=True, text=True,
                       check=False)
    if r.returncode != 0:
        raise SystemExit(f"gen-media: ffmpeg failed ({r.returncode}): "
                         f"{' '.join(args)}\n{r.stderr.strip()}")


def av(out, name, vcodec, acodec, extra=()):
    ffmpeg(out, *video(), *tone(440), "-map", "0:v", "-map", "1:a",
           "-vf", VF, *TAGS709, *vcodec, *acodec, *extra, *BITEXACT, name)


def audio_only(out, name, acodec, extra=()):
    ffmpeg(out, *tone(440), "-map", "0:a", *acodec, *extra, *BITEXACT, name)


def two_audio(out, name, vcodec, acodec):
    ffmpeg(out, *video(), *tone(440), *tone(660),
           "-map", "0:v", "-map", "1:a", "-map", "2:a",
           "-vf", VF, *TAGS709, *vcodec, *acodec,
           "-metadata:s:a:0", "language=eng",
           "-metadata:s:a:1", "language=fra", *BITEXACT, name)


def write(out, name, text):
    (out / name).write_text(text, encoding="utf-8", newline="\n")


def hls(out, tree, seg):
    """One tree: a video playlist, two audio renditions, a WebVTT
    subtitle rendition, 1 s segments, and a hand-written master."""
    kind = ["-hls_segment_type", seg]
    ext = "m4s" if seg == "fmp4" else "ts"

    def media(name, inputs, codec, meta=()):
        init = (["-hls_fmp4_init_filename", f"{tree}_{name}_init.mp4"]
                if seg == "fmp4" else [])
        ffmpeg(out, *inputs, *codec, *meta, "-muxdelay", "0",
               "-muxpreload", "0", "-f", "hls", "-hls_time", "1",
               "-hls_playlist_type", "vod", "-hls_flags", "independent_segments",
               *kind, *init,
               "-hls_segment_filename", f"{tree}_{name}_%d.{ext}",
               *BITEXACT, f"{tree}_{name}.m3u8")

    media("video", video(), ["-vf", VF, *TAGS709, *H264, "-an"])
    media("audio_en", tone(440), [*AAC, "-vn"], ["-metadata:s:a:0", "language=eng"])
    media("audio_fr", tone(660), [*AAC, "-vn"], ["-metadata:s:a:0", "language=fra"])
    # The cue times are the segments' own clock: every segment above is
    # muxed from 0 (-muxdelay 0), so the map names 0 on both sides.
    write(out, f"{tree}_subs.vtt",
          CUES.replace("WEBVTT\n",
                       "WEBVTT\nX-TIMESTAMP-MAP=MPEGTS:0,LOCAL:00:00:00.000\n", 1))
    write(out, f"{tree}_subs.m3u8",
          "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:2\n"
          "#EXT-X-MEDIA-SEQUENCE:0\n#EXT-X-PLAYLIST-TYPE:VOD\n"
          f"#EXTINF:{SECONDS}.000000,\n{tree}_subs.vtt\n#EXT-X-ENDLIST\n")
    video_bytes = sum(p.stat().st_size for p in out.glob(f"{tree}_video*.{ext}"))
    video_bytes += sum(p.stat().st_size for p in out.glob(f"{tree}_video_init.mp4"))
    audio_bytes = sum(p.stat().st_size for p in out.glob(f"{tree}_audio_en*.{ext}"))
    bandwidth = (video_bytes + audio_bytes) * 8 // SECONDS
    version = 7 if seg == "fmp4" else 6
    write(out, f"{tree}.m3u8",
          f"#EXTM3U\n#EXT-X-VERSION:{version}\n#EXT-X-INDEPENDENT-SEGMENTS\n"
          '#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",LANGUAGE="en",NAME="English",'
          f'DEFAULT=YES,AUTOSELECT=YES,CHANNELS="1",URI="{tree}_audio_en.m3u8"\n'
          '#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",LANGUAGE="fr",NAME="French",'
          f'DEFAULT=NO,AUTOSELECT=YES,CHANNELS="1",URI="{tree}_audio_fr.m3u8"\n'
          '#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",LANGUAGE="en",'
          'NAME="English",DEFAULT=NO,AUTOSELECT=YES,FORCED=NO,'
          f'URI="{tree}_subs.m3u8"\n'
          f"#EXT-X-STREAM-INF:BANDWIDTH={bandwidth},"
          'CODECS="avc1.64000b,mp4a.40.2",'
          f"RESOLUTION={SIZE},FRAME-RATE={FPS}.000,"
          'AUDIO="aud",SUBTITLES="subs"\n'
          f"{tree}_video.m3u8\n")


def dash(out):
    ffmpeg(out, *video(), *tone(440), *tone(660),
           "-map", "0:v", "-map", "1:a", "-map", "2:a",
           "-vf", VF, *TAGS709, *H264, *AAC,
           "-metadata:s:a:0", "language=eng",
           "-metadata:s:a:1", "language=fra",
           "-f", "dash", "-seg_duration", "1", "-use_template", "1",
           "-use_timeline", "0", "-single_file", "0",
           "-adaptation_sets", "id=0,streams=0 id=1,streams=1 id=2,streams=2",
           "-init_seg_name", "dash_init_$RepresentationID$.m4s",
           "-media_seg_name", "dash_chunk_$RepresentationID$_$Number%05d$.m4s",
           *BITEXACT, "dash.mpd")


def generate(out):
    out.mkdir(parents=True, exist_ok=True)
    av(out, "h264_aac.mp4", H264, AAC)
    av(out, "hevc_aac.mp4", HEVC, AAC)
    av(out, "hevc_aac.mov", HEVC, AAC)
    av(out, "vp9_opus.webm", VP9, OPUS)
    # VP9 in MP4: Apple lists the video track undecodable and would play the
    # audio alone, the mac's own quiet case (docs/media-plan.md §7a).
    av(out, "vp9_aac.mp4", VP9, AAC)
    av(out, "av1_aac.mp4", AV1, AAC)
    av(out, "av1_opus.webm", AV1, OPUS)
    audio_only(out, "tone.mp3", ["-c:a", "libmp3lame", "-b:a", "64k"],
               ["-write_xing", "0", "-id3v2_version", "0"])
    audio_only(out, "tone.m4a", AAC)
    audio_only(out, "tone.ogg", OPUS, ["-serial_offset", "1"])
    audio_only(out, "tone_opus.webm", OPUS)
    audio_only(out, "tone.flac", ["-c:a", "flac"])
    audio_only(out, "tone.wav", ["-c:a", "pcm_s16le"])
    write(out, "captions.vtt", CUES)
    ffmpeg(out, *video(), *tone(440), "-i", "captions.vtt",
           "-map", "0:v", "-map", "1:a", "-map", "2:s",
           "-vf", VF, *TAGS709, *H264, *AAC, "-c:s", "mov_text",
           "-metadata:s:s:0", "language=eng", *BITEXACT, "h264_tx3g.mp4")
    two_audio(out, "h264_2audio.mp4", H264, AAC)
    two_audio(out, "vp9_2audio.webm", VP9, OPUS)
    hls(out, "hls_fmp4", "fmp4")
    hls(out, "hls_mpegts", "mpegts")
    dash(out)


def listing(d):
    return {p.relative_to(d).as_posix(): p.read_bytes()
            for p in sorted(d.rglob("*")) if p.is_file() and p.name != "README.md"}


def compare(fresh, committed):
    """Every difference, by name; empty when the two agree byte for byte."""
    a, b = listing(fresh), listing(committed)
    bad = [f"{committed.relative_to(ROOT) if committed.is_relative_to(ROOT) else committed}"
           f"/{n}: not generated by tools/gen-media.py" for n in sorted(set(b) - set(a))]
    bad += [f"{n}: generated but not in {committed}" for n in sorted(set(a) - set(b))]
    bad += [f"{n}: differs from what tools/gen-media.py generates"
            for n in sorted(set(a) & set(b)) if a[n] != b[n]]
    return bad, len(a)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", type=pathlib.Path)
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--against", type=pathlib.Path, default=FAMILY)
    args = ap.parse_args()
    if args.check:
        with scratch_dir("kaya-gen-media-") as fresh:
            generate(fresh)
            bad, n = compare(fresh, args.against)
        if bad:
            for b in bad:
                print(f"gen-media: {b}", file=sys.stderr)
            print(f"gen-media: FAIL — {len(bad)} of {n} files; regenerate with "
                  f"`tools/gen-media.py`", file=sys.stderr)
            raise SystemExit(1)
        print(f"gen-media: OK — {n} files byte-identical to {args.against}")
        return
    out = args.out or FAMILY
    for p in out.glob("*"):
        if p.is_file() and p.name != "README.md":
            p.unlink()
    generate(out)
    print(f"gen-media: wrote {len(listing(out))} files to {out}")


main()
