# Probe: what the linux lane's container needs for video (2026-09-03)

Answers docs/video-editor-plan.md §6 probe 2. Method: a scratch image built
FROM the lane's own `kaya-linux:latest` (tools/linux/Dockerfile UNTOUCHED),
candidate packages added in separately-attributable layers, two clips
generated with the image's own ffmpeg, everything run under the lane's Xvfb.

Host: darwin/arm64, docker 29.7.2. Image arch: **arm64/linux**, Debian trixie
(pinned by digest `fac46bff2e02…`), GTK **4.18.6+ds-2**, cargo 1.98.0 present.


## 0. Package availability in the lane's own Debian release (trixie, arm64)

Read out of the lane image itself (`apt-cache policy`, 2026-09-03):

| package | candidate version | verdict |
|---|---|---|
| `gstreamer1.0-plugins-base` | 1.26.2-1+deb13u1 | present |
| `gstreamer1.0-plugins-good` | 1.26.2-1+deb13u2 | present |
| `gstreamer1.0-plugins-bad` | 1.26.2-3+deb13u3 | present |
| `gstreamer1.0-plugins-ugly` | 1.26.3-4+deb13u1 | present |
| `gstreamer1.0-libav` | 1.26.2-1+deb13u1 | present |
| `gstreamer1.0-gtk4` | **0.13.5-1** | **present — gst-plugins-rs, packaged** |
| `libgtk-4-media-gstreamer` | 4.18.6+ds-2 | present |
| `libgstreamer1.0-dev` | 1.26.2-2 | present |
| `libgstreamer-plugins-base1.0-dev` | 1.26.2-1+deb13u1 | present |
| `gstreamer1.0-tools` | 1.26.2-2 | present |
| `gstreamer1.0-gl` / `gstreamer1.0-x` | 1.26.2-1+deb13u1 | present |
| `gstreamer1.0-plugins-rs` | — | **does not exist** (the Rust plugin set is split per plugin; `gstreamer1.0-gtk4` IS the one kaya wants) |

`libgtk-4-media-gstreamer`'s Depends, confirmed on the machine, are the shared
libraries ONLY — `libgstreamer1.0-0`, `libgstreamer-plugins-base1.0-0`,
`libgstreamer-gl1.0-0`, `libgtk-4-1`, `libglib2.0-0t64`, `libgraphene-1.0-0`,
`libc6`. **No plugin set is pulled**, exactly as D7 predicted. Installing the
media module alone gives GTK a backend with no codecs.

## 1. The failure sentence, measured (question 2)

The probe: a PyGObject GTK4 program that constructs `Gtk.MediaFile.new_for_filename`,
calls `play()`, and samples `timestamp` every 100 ms under `xvfb-run -a -s
"-screen 0 1600x1000x24"` (the lane's own screen geometry).

**On the lane's image EXACTLY AS SHIPPED (no GStreamer packages added):**

```
[type] GtkNoMediaFile
[after-new] error='GTK could not find a media module. Check your installation.'
            domain=g-io-error-quark code=15 prepared=True ts=0 dur=0 w=0 h=0
VERDICT: FAILED  sentence='GTK could not find a media module. Check your installation.'
```

**With the packages installed but `GTK_MEDIA=none`: byte-identical.**

So the sentence is one assertable string covering both causes:

> `GTK could not find a media module. Check your installation.`

with `domain = g-io-error-quark`, `code = 15` (`G_IO_ERROR_NOT_SUPPORTED`).
Three properties of it that matter for a watched branch:

- **It is present at CONSTRUCTION, before `play()`** — `get_error()` is already
  non-NULL on the object `new_for_filename` returned. No waiting, no main loop.
- **The object's type is `GtkNoMediaFile`**, so the class name is a second,
  independent witness.
- **`is_prepared()` is TRUE while the error is set.** A branch keyed on
  "prepared" alone reads this failure as success.

Two neighbouring sentences, also measured:

- `GTK_MEDIA=help` prints the backend list. On the lane's image as shipped it is
  `none - -2147483648` ALONE; with `libgtk-4-media-gstreamer` installed it is
  `gstreamer - 10` and `none - -2147483648`. That is a cheaper image-level
  assertion than constructing a media file.
- `GTK_MEDIA=bogus` prints `Gtk-WARNING **: Media extension "bogus" from
  GTK_MEDIA environment variable not found.` **and then falls back to the real
  gstreamer backend and plays.** A typo in the variable is not a failure; only
  the literal `none` disables playback.

**With the packages installed and `GTK_MEDIA` unset, both clips play** (muted;
the container has no sound card, and an unmuted run buries the output in ALSA
and PipeWire noise without failing):

| clip | prepared | intrinsic size | duration | timestamp advances | ended |
|---|---|---|---|---|---|
| H.264/MP4 | yes | 320x240 | 2000000 us | 19 in 2.0 s wall | yes |
| VP9/WebM | yes | 320x240 | 2000333 us | 19 in 2.0 s wall | yes |

TRAP worth carrying forward: after `ended` fires, the H.264 run reported
`timestamp = 2000000` but the VP9 run reported `timestamp = 0`. Read the
timestamp AT the `notify::ended` callback, not after the loop.

## 2. The GStreamer pipeline, measured (question 1's other half)

Under the same Xvfb, `gst-launch-1.0 playbin3`:

| pipeline | result | wall |
|---|---|---|
| H.264/MP4 -> `fakesink` | EOS, rc=0 | 0.003 s |
| VP9/WebM -> `fakesink` | EOS, rc=0 | 0.001 s |
| H.264/MP4 -> `gtk4paintablesink` | EOS, rc=0 | **2.004 s** |
| VP9/WebM -> `gtk4paintablesink` | EOS, rc=0 | **2.002 s** |

**The wall clock is the real finding.** `fakesink` does not sync to the clock,
so it reaches EOS in 3 ms on a 2 s clip: EOS from a fakesink pipeline proves
the file was demuxed, NOT that it played. `gtk4paintablesink` takes the clip's
own 2.00 s, which is the honest witness that frames were produced on a clock.
A lane leg must assert the duration, not just EOS.

### THE FALSE GREEN: a missing decoder is a WARNING, and the pipeline still says EOS

Measured by pointing `GST_PLUGIN_SYSTEM_PATH_1_0` at a directory holding all 258
plugins EXCEPT `libgstlibav.so` and `libgstopenh264.so` (`gst-inspect-1.0
avdec_h264` confirmed absent first), then playing the H.264 clip:

```
Missing element: H.264 (Constrained Baseline Profile) decoder
WARNING: from element /GstPlayBin3:playbin3-0/GstURIDecodeBin3:uridecodebin3/GstDecodebin3:decodebin3-0:
  Your GStreamer installation is missing a plug-in.
Additional debug info: ../gst/playback/gstdecodebin3.c(3204):
  mq_slot_check_reconfiguration (): ... Some plugins were missing
Pipeline is PREROLLED ...
Got EOS from element "playbin3-0".
Execution ended after 0:00:00.003730208
### rc=0
```

`playbin3` posts a `missing-plugin` ELEMENT message and a **`Warning`**, then
plays whatever it can and **reaches EOS with exit status 0**. A kaya GTK arm
that watches only `MessageView::Error` and `Eos` would report a codec-less
playback as SUCCESS. The arm must watch `Warning` and the `missing-plugin`
element message too, and the scene must assert that `position` advanced.
(A rank-based attempt to hide the decoder — `GST_PLUGIN_FEATURE_RANK=avdec_h264:NONE`
— produced the same silent EOS with no missing-plugin message at all, which is
worse: use a real subset registry if this is ever re-tested.)

## 3. `gtk4paintablesink` is PACKAGED in the lane's own Debian release (question 3)

It does **not** have to be built from `gst-plugins-rs`. `apt-get install
gstreamer1.0-gtk4` on Debian trixie installs
`/usr/lib/aarch64-linux-gnu/gstreamer-1.0/libgstgtk4.so`, and
`gst-inspect-1.0 gtk4paintablesink` reads it back:

```
Long-name       GTK 4 Paintable Sink
Rank            none (0)
Plugin          gtk4   version 0.13.5-RELEASE   license MPL
Source module   gst-plugin-gtk4
Binary package  gst-plugin-gtk4
Origin URL      https://gitlab.freedesktop.org/gstreamer/gst-plugins-rs
Source release  2025-03-04
```

`dpkg -S` confirms `gstreamer1.0-gtk4:arm64` owns that file. **Cost: 3.69 MB
unpacked, one apt line, seconds.** (`gstreamer1.0-plugins-rs` — the name the
plan's §6 guessed at — does not exist; Debian splits the Rust plugins per
plugin, and `gstreamer1.0-gtk4` is the one kaya wants.)

### The from-source alternative, priced for comparison

Measured, not estimated: `gst-plugin-gtk4` 0.13.5 fetched from crates.io and
built with `cargo build --release` inside the same container.

| | apt (`gstreamer1.0-gtk4`) | built from gst-plugins-rs |
|---|---|---|
| wall time | seconds (apt) | **22 s** compile, 135 crates |
| what you get | `libgstgtk4.so`, 3.69 MB unpacked incl. package metadata | `libgstgtk4.so`, 1.04 MB |
| build scratch | none | **540 MB** (65 MB cargo registry + 475 MB target) |
| in the image | one apt line in a trailing layer | a multi-stage build, or 540 MB of layer |
| version | 0.13.5, moves with trixie point releases | whatever is pinned |

The from-source route is not expensive in TIME; it is expensive in the
container, where the 540 MB of scratch either lands in a layer or forces a
second build stage. **Use the package.**

**`Rank = none (0)` matters:** `playbin3` will never autoplug this sink. kaya
must set `video-sink` explicitly, which is what the plan's design already says.

### The Rust host driving it, measured end to end

A scratch Cargo project inside the container, `gstreamer = "0.24"` + `gtk4 =
"0.10"` from crates.io (resolved to gstreamer 0.24.5, gtk4 0.10.3, glib 0.21.5;
80 packages), built with `cargo build --locked --release`:

- **cargo IS in the lane's image** — `cargo 1.98.0`, from the Dockerfile's rustup line.
- **build: 21.85 s, 580 KB binary**, no system dependency missing (the
  `-sys` crates found GTK 4.18.6 and GStreamer 1.26.2 through the dev packages).

Running it under Xvfb against both clips:

```
paintable before play: GstGtk4Paintable 0x0
paintable after  play: 320x240
positions_ms  = [0, ..., 21, 42, 106, ..., 1984, 2000]     (real-time advance)
duration_ms   = Some(2000)
rate=2.0 + SeekFlags::FLUSH|ACCURATE seek accepted = true
VERDICT: EOS wall=2047ms          (H.264/MP4)
VERDICT: EOS wall=2018ms          (VP9/WebM)
```

Three things that settle §2's Linux row:

1. The `paintable` property is a `GstGtk4Paintable` implementing
   `gdk::Paintable` — the type `GtkPicture` takes and the type kaya's own
   `KayaCanvas` already accepts.
2. **Its intrinsic size is `0x0` before the first frame and `320x240` after.**
   That is a first-frame-arrival observable available to the harness with no
   pixel read at all, which matters given §3's "kaya cannot read those pixels
   back".
3. **A rate-2.0 accurate seek is ACCEPTED** — the `speed` prop D7 says
   `GtkMediaStream` cannot express. The parity argument for the `gstreamer-rs`
   route is confirmed on the machine, not just in the docs.

## 4. Image size delta (question 4)

Baseline `kaya-linux:latest` = 1,907,107,737 bytes content / 8.57 GB unpacked.
Probe image = 1,973,669,923 bytes content / 8.85 GB unpacked.
`docker system df -v` attributes **278.3 MB** of unique disk to the probe layers
(that is unpacked layers plus their content blobs).

Per group, from `docker history` (unpacked layer size):

| layer | packages | unpacked |
|---|---|---|
| L1 | `gstreamer1.0-plugins-base` `-good` `gstreamer1.0-libav` `gstreamer1.0-tools` | **25.2 MB** |
| L2 | `gstreamer1.0-gtk4` | **3.69 MB** |
| L3 | `libgtk-4-media-gstreamer` | **2.31 MB** |
| L4 | `libgstreamer1.0-dev` `libgstreamer-plugins-base1.0-dev` | **31.4 MB** |
| L5 | `gstreamer1.0-plugins-bad` `gstreamer1.0-gl` `gstreamer1.0-x` | **149 MB** |
| L6 | `gir1.2-gtk-4.0` | 0.06 MB (already in the image) |

**L5 is 70% of the delta and is not needed.** `gstreamer1.0-plugins-bad` alone
drags in `libgtk-3-0t64`, `liblrdf0`, `libnice10` and the rest of the bad set;
its only relevance was `openh264dec` as a second H.264 decoder, and
`gstreamer1.0-libav` already provides `avdec_h264`. `gstreamer1.0-gl` and
`-x` are not needed either: `gtk4paintablesink` reached EOS in real time under
bare Xvfb without them.

**The recommended set is L1 + L2 + L4 = 60.3 MB unpacked** (~3.2% on a 1.9 GB
image), or **L1 + L2 + L3 + L4 = 62.6 MB** if the `GtkMediaFile` path is kept
as the watched `GTK_MEDIA=none` branch.

## 5. The Dockerfile fragment, ready to paste

A trailing layer, per tools/linux/Dockerfile's own convention ("appending
rebuilds in seconds where touching the first apt list rebuilds the toolchain
world"). Versions deliberately unpinned, per that file's stated policy.

```dockerfile
# Video (docs/video-editor-plan.md §2, the Linux row): the platform decodes
# headlessly and kaya presents the frames. The pipeline is gstreamer-rs
# driving playbin3 into gtk4paintablesink, whose `paintable` property is the
# gdk::Paintable a GtkPicture takes.
#
# WHAT EACH LINE IS FOR, because a plugin set is invisible until a codec is
# missing and a missing codec is a WARNING, not an error (probe 2026-09-03):
#   plugins-base  playbin3/decodebin3, typefind, videoconvert
#   plugins-good  qtdemux (MP4), matroskademux (WebM), vp8dec/vp9dec
#   libav         avdec_h264 — the H.264 floor the codec ruling names
#   gtk4          gtk4paintablesink, from gst-plugins-rs; PACKAGED in trixie
#                 (0.13.5-1), not built from source. Its rank is none(0), so
#                 kaya sets video-sink explicitly; playbin3 never picks it.
#   *-dev         headers for the gstreamer/gstreamer-video crates
# libgtk-4-media-gstreamer is GTK's OWN GtkMediaFile backend. kaya does not
# use it (GtkMediaStream has no playback rate, so it cannot reach the video
# kind's `speed`), but it is what makes GTK_MEDIA=none a WATCHED branch
# rather than a believed one: without it, GTK_MEDIA is a no-op because there
# is nothing to switch off.
#
# DELIBERATELY ABSENT: gstreamer1.0-plugins-bad, -gl and -x. They cost 149 MB
# against the whole set's 212 MB, drag in libgtk-3, and buy nothing measured —
# gtk4paintablesink rendered a clip to EOS in real time under bare Xvfb
# without them.
#
# A trailing layer on purpose, per the note above.
RUN apt-get update && apt-get install -y --no-install-recommends \
    gstreamer1.0-plugins-base gstreamer1.0-plugins-good \
    gstreamer1.0-libav gstreamer1.0-gtk4 \
    libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev \
    libgtk-4-media-gstreamer \
    && rm -rf /var/lib/apt/lists/*
```

Add `gstreamer1.0-tools` (a further ~1 MB, inside L1's 25.2 MB) only if a
human wants `gst-inspect-1.0` / `gst-launch-1.0` inside the container for
debugging; nothing the lane runs needs it.

## 6. Assertable strings, collected

For whoever writes the GTK arm and its watched branches:

| condition | observable |
|---|---|
| no media module (packages absent, or `GTK_MEDIA=none`) | `GtkMediaFile` error, domain `g-io-error-quark`, code 15, message **`GTK could not find a media module. Check your installation.`**, set at construction |
| media backends available | `GTK_MEDIA=help` prints `gstreamer - 10` and `none - -2147483648`; as shipped today the lane's image prints only the `none` line |
| a bad `GTK_MEDIA` value | `Gtk-WARNING **: Media extension "<name>" from GTK_MEDIA environment variable not found.` then a SILENT fallback to gstreamer |
| a codec is missing | bus `Element` message named `missing-plugin`, plus a bus **`Warning`** `Your GStreamer installation is missing a plug-in.` with debug `Some plugins were missing` — and then a normal EOS with status 0 |
| playback actually happened | `gtk4paintablesink`'s paintable goes `0x0` -> `320x240`; `query_position` advances; wall clock equals the clip duration |

## 7. What this means for docs/video-editor-plan.md §2 and §6

§2's Linux row survives the probe intact and gets cheaper than it looked:
`gstreamer-rs` driving `playbin3` into `gtk4paintablesink` runs headlessly under
the lane's own Xvfb on both an H.264/MP4 and a VP9/WebM clip, a rate-2.0
accurate seek is accepted (the `speed` prop `GtkMediaStream` cannot express, so
the parity argument for choosing this route over `GtkMediaFile` is now measured
rather than argued), and the sink is a packaged Debian plugin —
`gstreamer1.0-gtk4` 0.13.5 — so nothing is built from `gst-plugins-rs` and the
whole recommended package set costs 60 MB unpacked on a 1.9 GB image.

§6's probe 2 is answered and can be struck, with one finding it did not
anticipate: the missing-plugin case is NOT symmetric with the missing-module
case. GTK's missing module is the clean assertable sentence §6 expected
(`GTK could not find a media module. Check your installation.`, `g-io-error-quark`
code 15, present at construction, identical whether the packages are absent or
`GTK_MEDIA=none`), but a missing CODEC arrives on the GStreamer bus as a
`missing-plugin` element message and a **Warning**, after which the pipeline
reaches EOS with status 0 — so the Linux arm must watch warnings and assert that
`position` advanced, or it will report a codec-less playback as success.

## 8. Method and residue

- tools/linux/Dockerfile was NOT modified. The probe image was
  `FROM kaya-linux:latest` in a scratch directory, layers split so
  `docker history` attributes each package group.
- Clips generated by the image's own ffmpeg 7.1.5: `clip-h264.mp4`
  (H.264 constrained baseline + AAC, 320x240, 2 s, flat #1C71D8, 5,258 bytes)
  and `clip-vp9.webm` (VP9, 320x240, 2 s, flat #33D17A, 1,972 bytes).
- Everything ran under `xvfb-run -a -s "-screen 0 1600x1000x24"`, the lane's
  own screen geometry (tools/linux/run-suites.sh).
- Unmuted playback buries the output in ALSA and PipeWire errors because the
  container has no sound card. They are noise, not failures; the probe muted
  the stream and filtered them.

## 9. Cleanup, proven

- `docker ps` and `docker ps -a`: **empty**. Six probe containers were run, all
  `--rm` and all named `kayaprobe-*`; none survives.
- `docker rmi kaya-videoprobe:scratch` -> `Deleted:
  sha256:185f8ecc2c2ce6fb46db920ff36b2c45ce1865aff721fb36bff5d74d1ccb90c1`.
  `docker image ls` now diffs IDENTICAL against the baseline captured before the
  probe (`linux-videoprobe/image-ls-before.txt`).
- Host scratch: **152 KB** (`du -sh
  ~/.claude/jobs/87aed9b4/tmp/linux-videoprobe`). Both cargo builds used
  `CARGO_TARGET_DIR` and `CARGO_HOME` INSIDE the container, so the 540 MB
  from-source measurement and the 80-crate probe build died with their
  containers and never touched the host.
- Residue on the record: docker's build cache grew 13.21 -> 13.38 GB (~170 MB,
  the probe's apt layers). It is NOT pruned deliberately — the only filter that
  would reach it also drops `kaya-linux`'s own build cache, which would make the
  next linux lane rebuild the toolchain world. `docker builder prune` reclaims it
  whenever wanted.
- The repo is untouched: `git status --porcelain` shows only
  `?? tools/android/videoprobe/`, which is the ANDROID probe's gradle project
  (created 01:33 by the sibling agent running §6 probe 1), not this one's.

## STATUS: COMPLETE
