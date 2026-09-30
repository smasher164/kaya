# media — the media test suite's files (docs/media-plan.md §7a)

Generated here by tools/gen-media.py with the dev shell's FFmpeg; they are
committed bytes, deterministic (the same FFmpeg writes the same files), so
`tools/gen-media.py --check` regenerates into scratch and compares. The
choice of files is the one docs/probes/media-suite-2026-09-29.md measured on
every platform.

Every video is 160x90 at 25 fps of one flat colour, sRGB C83C1E, tagged
BT.709 primaries and matrix with the sRGB TRANSFER, so a platform that
colour-manages the frame shows C83C1E (a BT.709 transfer reads CF4421,
docs/traps.md), and every audio track a 440 Hz sine at 48 kHz, 2 s each. Where a
file carries two audio tracks the second is 660 Hz, tagged `fra` beside the
first's `eng`, so a check can tell them apart by pitch.

- `h264_aac.mp4` (the codec floor, docs/media-plan.md §8 ruling 1),
  `hevc_aac.mp4` and `hevc_aac.mov` (tag `hvc1`), `vp9_opus.webm`,
  `av1_aac.mp4`, `av1_opus.webm` (libaom), and `vp9_aac.mp4`, VP9 in MP4,
  whose video Apple lists as undecodable while the audio would play: the
  quiet failure kaya's decodability check has to catch on the mac.
- `tone.mp3`, `tone.m4a` (AAC), `tone.ogg` (Opus), `tone_opus.webm`,
  `tone.flac`, `tone.wav`: audio only.
- `captions.vtt`: two cues, "first cue" 0-1 s and "second cue" 1-2 s, the
  sidecar. `h264_tx3g.mp4` carries the same cues as a `mov_text` track
  (`eng`).
- `h264_2audio.mp4`, `vp9_2audio.webm`: two audio tracks.
- `hls_fmp4.m3u8` and `hls_mpegts.m3u8`: the HLS master playlists, written by
  the generator rather than FFmpeg, each naming a video playlist, two audio
  renditions (`en`, `fr`) and a WebVTT subtitle rendition, 1 s segments. The
  trees are FLAT, prefixed `hls_fmp4_` and `hls_mpegts_`, because an asset
  family is one directory deep (docs/assets-plan.md A2); the playlists name
  their segments relatively.
- `dash.mpd` with `dash_init_*` and `dash_chunk_*`: the same video and two
  audio streams as DASH.

No licence question arises: the pictures and tones are synthetic and made by
this repository's own generator, no upstream material is in them.

To regenerate: `tools/gen-media.py` inside `nix develop` rewrites this
directory (this README is kept); commit the result. The local server that
serves this directory to the lanes is tools/media-server.py.
