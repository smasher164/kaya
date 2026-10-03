# Linux capture, measured (docs/capture-plan.md §7 items 2 and 5), 2026-10-02

Measured in the lane image (tools/linux/Dockerfile, debian trixie arm64) with
the capture layer added: pipewire 1.4.2-1, wireplumber 0.5.8-2,
gstreamer1.0-pipewire 1.4.2-1, xdg-desktop-portal 1.20.3+ds-1,
xdg-desktop-portal-gtk 1.15.3-1, GStreamer 1.26. No camera or microphone
exists in the container; every device below is the lane's synthetic one.

## PipeWire and WirePlumber headless, per session

- `pipewire` then `wireplumber` start with no systemd, given a private
  `XDG_RUNTIME_DIR` (the socket `pipewire-0` lives there), a session bus
  (`dbus-launch`) and `DISABLE_RTKIT=y`. The only complaint is module-rt's
  "Realtime scheduling disabled", a warning. The graph has `Dummy-Driver`
  and `Freewheel-Driver` and nothing else.
- WirePlumber sets `default.video.source` / `default.audio.source` to the
  first matching node it sees (here the synthetic ones), so a consumer with
  NO target would be handed one: the arm always names its target and sets
  `node.dont-fallback`, `node.dont-reconnect` (the wall, below).

## The synthetic devices: why not gst-launch

- `videotestsrc ! pipewiresink mode=provide stream-properties=...
  media.class=Video/Source,media.role=Camera` makes a node a consumer finds
  by `target-object=<node.name>`, BUT: (1) it offers exactly the one format
  its caps fixed, so a device offering 640x480@30 and 1280x720@15 at once
  cannot be built from it, and (2) the provider pipeline ERRORS AND EXITS
  the moment its consumer unlinks ("all buffers have been removed ...
  PipeWire link to remote node was destroyed", gstpipewiresink.c:599), so a
  camera closed once is gone for the rest of the leg.
- `audiotestsrc ! pipewiresink mode=provide ... media.class=Audio/Source`
  is never linked at all: WirePlumber's si-audio-adapter answers "no usable
  format found for node".
- So the lane's devices are tools/linux/pwsynth/pwsynth.c, a pw_stream per
  device: a camera is a DRIVER Video/Source (`media.role=Camera`) offering
  NV12 640x480 and 1280x720, each at 15 and 30 fps, the colour written as
  video-range BT.601 Y/U/V (C83C1E is Y 101, U 94, V 192); a microphone is
  an Audio/Source of F32 stereo at 48 kHz, one sine on both channels.

## What a consumer is handed (item 5)

- `pipewiresrc target-object=kaya-synthetic-camera-1` alone: "stream error:
  target not found" — WirePlumber's find-best-target asserts on a missing
  `media.type` (`find-best-target.lua:48`, `common-utils.lua:54`). With
  `stream-properties=props,media.type=Video,media.category=Capture,
  media.role=Camera` (Audio for a microphone) it links.
- Caps delivered: `video/x-raw, format=NV12, interlace-mode=progressive,
  width=640, height=480, framerate=15/1` unfiltered (the first format the
  device offers); a caps filter picks 1280x720@15. NO `colorimetry` field:
  gstreamer1.0-pipewire 1.4 does not carry the format's colorMatrix /
  colorRange into caps, so GStreamer defaults it by size (BT.601 at SD,
  BT.709 at 720p and up).
- The bytes: one data block, Y plane `width` bytes a row then the
  interleaved UV plane, exactly GStreamer's default NV12 layout; Y 101,
  U 94, V 192 at every sampled point for C83C1E.
- A consumer leaving and another arriving: the pw_stream device stays
  (paused, streaming again, renegotiating 640x480@15 -> 1280x720@15 ->
  640x480@15 in its log).
- GStreamer's own NV12 -> RGB of 1E5AC8 at 640x480 reads 1E56C6 (green 4,
  blue 2 off), within GTK's video ink tolerance of 4 and outside the core's
  capture tolerance of 3; the core's own read of the NV12 is within 2.
- Microphones: `audio/x-raw, layout=interleaved, format=F32LE, rate=48000,
  channels=2`, peak 0.5, zero crossings 439.7 Hz and 659.1 Hz.
- GstDeviceMonitor (pipewiredeviceprovider) lists each node with its
  `node.name`, `node.description`, `media.class`, `media.role`, `is-default`
  and the four caps structures the camera offers.

## The camera portal (org.freedesktop.portal.Camera)

The portal's two service files are off the default bus (the Dockerfile's
file-chooser note); a bus started with `/opt/kaya-portal` on XDG_DATA_DIRS
activates it. With pipewire, wireplumber and the synthetic camera up:

- `IsCameraPresent` true (it counts `media.class=Video/Source` with
  `media.role=Camera`), `version` 1.
- AN UNSANDBOXED APP IS KEYED BY THE EMPTY APP ID. `Registry.Register` of an
  id with no desktop entry is refused ("App info not found for
  'dev.kaya.Probe'"), and the store then reads `{'': [...]}` for the caller.
- Nothing stored for '': AccessCamera's Request gets NO Response within
  15 s (the gtk backend's "Allow ... to Use the Camera?" dialog waits on the
  display), and the store afterwards reads `'': ['no']`.
- PRE-GRANTED (`PermissionStore.SetPermission devices true camera '' ['yes']`
  through gdbus, before the call): Response `(0, {})` at once;
  `OpenPipeWireRemote` hands an fd; `pipewiresrc fd=<it>
  target-object=kaya-synthetic-camera-1` delivers the same NV12 640x480@15.
  The camera remote does NOT show a microphone (`target-object=
  kaya-synthetic-microphone-1` on it never prerolls): the microphone has no
  portal and is reached on PipeWire directly.
- PRE-DENIED (`['no']`): Response `(1, {})` at once, and OpenPipeWireRemote
  answers `org.freedesktop.portal.Error.NotAllowed: Permission denied`.
  The arm reads a response of 1 or 2 as `denied`.
