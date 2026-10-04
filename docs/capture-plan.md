# Capture: the camera and the microphone (design pass, 2026-10-01)

Status: DESIGNED 2026-10-01; the DEPTH SLICE BUILT 2026-10-02 (the protocol,
the core, the SwiftUI arm on the synthetic devices, the Rust binding, the
`capture` and `capture_denied` scenes on the mac lane); the BREADTH BUILT
2026-10-03 (the GTK, WinUI and Compose arms, the iOS legs, all nine bindings;
each lane's synthetic source measured first, in
docs/probes/capture-2026-10-01/{linux,windows,compose,ios}-measured.md), the
Windows legs still to run; what remains is docs/deferred.md's capture BUILD
entry. Asked for by the maintainer's
accepted direction of 2026-09-28: calls are a stage of the chat app
(docs/chat-plan.md), a voice or video call from a conversation with a live
self-preview and a choice of camera and microphone, the simulated peer
answering with a test pattern and a tone so a lane has something fixed to
assert, an incoming call as an ordinary notification, CallKit and
ConnectionService left out unless ruled in, the lanes on SYNTHETIC sources,
and the real webcam and microphone tried by the maintainer by hand. The
network transport (WebRTC or anything simpler) stays in the app's language,
as the chat app's transport did. No ledger entry named capture before this
pass; the roadmap's row is docs/probes/roadmap-framework-parity-2026-09-05.md
B21 ("camera / photo picker"), whose picker half shipped as chat C6
(docs/photo-attach-plan.md). The research behind every platform claim is
docs/probes/capture-2026-10-01/ (apple.md, android-linux.md,
windows-toolkits.md), web only: no camera or microphone was opened anywhere
for this pass.

The reference shape is the web's: `getUserMedia` opens devices into a
stream of at most one video and one audio track, `enumerateDevices` lists
them, a `<video>` element shows the stream, the Permissions API reports
`prompt`, `granted` or `denied`, and failures come from a small closed set
of names (`NotAllowedError`, `NotFoundError`, `NotReadableError`,
`OverconstrainedError`, `AbortError`). kaya follows it the way the media
plan followed `HTMLMediaElement`: an object the app holds, a view that shows
it, and frames and samples handed to the app's own code.

## §1. What the research found

| | session | preview | frames, samples | permission | synthetic source for a lane |
|---|---|---|---|---|---|
| macOS | `AVCaptureSession`; devices by `DiscoverySession` (`.external`, `.continuityCamera`, `.microphone` from macOS 14); `systemPreferredCamera` (macOS 13) follows the user's choice and Continuity Camera | `AVCaptureVideoPreviewLayer`, a `CALayer` that takes `videoGravity` like `AVPlayerLayer`; in-process snapshots read it black, window-server captures composite it | `AVCaptureVideoDataOutput` on a serial queue the app gives, `CVPixelBuffer` (native `420v`/`420f`, BGRA a conversion at ~2.6x memory), late frames discarded by default; `AVCaptureAudioDataOutput`, Float32 on the mac | `authorizationStatus`: not determined, restricted, denied, authorized; usage strings required or the process is TERMINATED; hardened runtime `device.camera` / `device.audio-input` | none without installing something: a Camera Extension needs a host app in /Applications and the user's approval, DAL plug-ins are disabled from 14.1, a virtual microphone is a HAL plug-in installed with sudo |
| iOS | the same, one active camera per app, `AVCaptureMultiCamSession` for more | the same layer | the same; audio format is the device's (Int16 typically) | the same; camera stops in the background (interruption `videoDeviceNotAvailableInBackground`) | the simulator has NO camera; its microphone is the HOST's input, picked in Simulator's I/O menu; `simctl privacy` lists microphone but no camera service (Xcode 26.6) |
| Android | CameraX 1.6.2: `bindToLifecycle` with use cases; `AudioRecord`, `VOICE_COMMUNICATION` source for calls | `PreviewView` PERFORMANCE (SurfaceView, the media plan's hole) or COMPATIBLE (TextureView); `CameraXViewfinder` in camera-compose prefers the SurfaceView | `ImageAnalysis`, keep-only-latest by default, `YUV_420_888` or RGBA, on the executor the app gives; `AudioRecord.read` blocking on its own thread, 16-bit PCM guaranteed | runtime `CAMERA`, `RECORD_AUDIO`, "only this time"; background apps get no camera and a silent microphone; Android 12 quick-settings toggles give "a blank camera feed" and "silent audio"; `pm grant` from adb | the emulator's camera modes `emulated`, `imagefile:`, `videofile:`; the pool's AVDs say `hw.camera.back=emulated`, `hw.camera.front=none`; the microphone takes PCM over the emulator's gRPC `injectAudio` with no host device, and host audio input is blocked unless asked for |
| GTK 4 | GStreamer beside GTK (GTK has no capture API): `pipewiresrc` on the camera portal's PipeWire remote, or `v4l2src`; audio from `pipewiresrc`/`pulsesrc` | `gtk4paintablesink`'s paintable in a `GtkPicture`, the player's own route (GNOME Snapshot's `aperture` does exactly this) | `appsink` | `org.freedesktop.portal.Camera` `AccessCamera` then `OpenPipeWireRemote`; no portal for the microphone; an unsandboxed app may reach PipeWire directly, and Snapshot falls back to that when the portal fails | a PipeWire node made by `videotestsrc ! pipewiresink mode=provide` with `media.class=Video/Source`, `media.role=Camera` (what the portal's `IsCameraPresent` counts); a null-sink virtual source for audio; v4l2loopback is a kernel module and out of reach in the container |
| WinUI 3 | `MediaCapture` (`SharedReadOnly` or `ExclusiveControl`, `AudioAndVideo`), devices by `DeviceInformation` and a `DeviceWatcher` | no `CaptureElement` in WinUI 3: the documented quickstart is `MediaPlayerElement` over `MediaSource.CreateFromMediaFrameSource`, which decodes a BT.601 camera as BT.709 (docs/traps.md, the WinUI self-view colour), so kaya draws the reader's own frames into a `WriteableBitmap` | `MediaFrameReader` raising `FrameArrived` on its own thread (Realtime drops all but the newest); the microphone through the same reader since 1803 | an UNPACKAGED app gets no prompt: one "let desktop apps access your camera" switch, and `E_ACCESSDENIED` at initialization; per-app prompts for desktop apps are in an Insider build only | `MFCreateVirtualCamera` (Windows 11): a COM media source DLL registered in HKLM, loaded by the Frame Server, so built for arm64 on the lane's VM; no built-in virtual microphone (VB-CABLE has an ARM64 driver, admin install and reboot) |

Every platform draws its own privacy indicator, so kaya draws none.
Flutter's `camera` previews through a Texture and has no audio stream;
VisionCamera previews through the platform's view, runs frame processors
on a worklet thread and has a closed error union; MAUI and Qt report errors
as free strings; Qt 6.8 lets an app feed a capture session its own frames.
Chromium's `--use-fake-device-for-media-stream` (a test pattern and a beep)
is the prior art for the lanes.

## §2. The capture object

A capture is an app-held object with an id, created and released in a
transaction like the player, with no place in the layout. It holds at most
ONE camera and ONE microphone, as a web stream holds one track of each; an
audio-only call is a capture with no camera, as an audio-only player is a
player with no picture.

**Devices** (an app-level reading, not per capture): each with the
platform's own stable id, its localized name, its kind (`camera`,
`microphone`) and, for a camera, its facing (`front`, `back`, `external`,
`unknown`); `devices_changed` when one comes or goes. The platform's
preferred device is marked (`systemPreferredCamera`, Windows' default
capture device), so an app that offers no choice opens what the user chose.

**Props:** `camera` and `microphone` (a device id, none for neither);
`width`, `height`, `frame_rate`, each a wish the platform meets with its
nearest format (the web's `ideal`), the format chosen read back;
`muted`, which keeps the microphone open and delivers silence, as a call's
mute does (the web's `enabled = false`). Turning the camera off is setting
`camera` to none, which closes it and puts the indicator out.

**Commands:** `start`, `stop`, `request_permission(kind)`.

**Readings:** `state` (`idle`, `starting`, `running`, `interrupted`,
`failed`), the format chosen, and per kind the permission: `prompt`,
`granted`, `denied` (the web's three; Apple's `restricted` is `denied` with
the platform's sentence as `detail`).

**Occurrences:** `state_changed`, `failed(reason)`, `interrupted(reason)`
and its end, `permission_changed(kind)`, `devices_changed`.

**Rules.**

1. `start` asks for permission when the state is `prompt`, as
   `getUserMedia` does; `request_permission` lets the app ask earlier,
   before its call screen. Android asks at the first need and reads the
   answer at the next resume, the notification arm's measured pattern.
   Windows' unpackaged answer is learned at initialization (`E_ACCESSDENIED`
   is `denied`), and what `CheckAccess` says before that is measured (§7).
2. **Failures are closed, one vocabulary in nine bindings:** `denied`,
   `not_found` (no such device, or none at all), `in_use` (another app
   holds it: iOS `videoDeviceInUseByAnotherClient`, WinUI
   `ExclusiveControlNotAvailable` or `0xC00D3704`, Android's camera-in-use
   errors), `disconnected` (removed while running), `unsupported` (no
   format at all near the wish), `hardware_error` (the rest, the platform's
   sentence beside it), and `timeout` with the media plan's bound and
   meaning (docs/media-plan.md §7c) for a start the platform never answers.
3. **Interruptions are a state, not a failure**, since they end by
   themselves: `background` (iOS, Android), `another_app` (iOS, Android's
   higher-priority recorder), `system_pressure` (iOS thermal), with the
   capture back to `running` when they end. Whether an app can see
   Android's sensor toggle rather than a blank feed is measured (§7).
4. **The self-view mirrors, the frames never do.** A preview of a front or
   desktop camera is mirrored, which is each platform's default where it has
   one (`automaticallyAdjustsVideoMirroring`, `PreviewView` for a front
   camera) and kaya's transform where it has none (WinUI, GTK); frames
   handed to the app are as the camera saw them, as on the web.
5. **Keep-awake** is the player's rule 5 (docs/media-plan.md §2) for a
   running capture whose preview is on screen.
6. **Foreground only in the first slice**: background capture needs iOS's
   `audio` mode and Android's camera and microphone foreground services.
7. On iOS a capture with a microphone takes the `.playAndRecord` category
   in `.videoChat` or `.voiceChat` mode while it runs, and the player's
   `.playback` (docs/media-plan.md §2 rule 6) returns when it stops.

## §3. The preview

The video view shows a capture as it shows a player: `video(capture)`. One
kind for moving pictures from an object, the media plan's ruling 6 ("the
kind is the choice") carried one source further, and on three backends the
lowering is the same element the player already uses:

| backend | lowering | what it cannot do |
|---|---|---|
| macOS, iOS | `AVCaptureVideoPreviewLayer` in the representable that holds `AVPlayerLayer` today | as the player's layer: composited, read only by a window-server capture |
| GTK 4 | `GtkPicture` over `gtk4paintablesink` on a tee of the capture pipeline | nothing beyond the player's |
| WinUI 3 | the reader's own frames through `CaptureFrame::rgb_at` into a `WriteableBitmap` (docs/traps.md, the WinUI self-view colour) | external content, as the player's (docs/media-plan.md §3) |
| Android | CameraX `Preview` into a `PreviewView` (or `CameraXViewfinder`) in PERFORMANCE mode | the SurfaceView hole, as the player's |

A self-view's natural size is half its frames' (320x240 for 640x480,
640x360 for 1280x720) and 320x240 while no camera is open; frames carrying
a rotation of 90 or 270 stand on end, so their upright picture is fitted
inside that half-size box (180x240 for 640x480, 203x360 for 1280x720) and a
layout that fits one platform fits the others. It takes no minimum: in a window narrower than that it shrinks to the room
it is given, keeping its aspect, so its height follows its width and the
picture fills it with no bands (docs/media-plan.md §3, the one rule every
video view keeps). The natural size is computed in one place,
`crate::capture::self_view_natural`, which GTK and WinUI call directly and
the two interpreters reach through `kaya_capture_self_view_natural` (the
SwiftUI host table) and `KayaPresent.captureSelfViewNatural` (JNI);
tools/check-verbs.py's video view clause holds every arm to it. The
rotation is the one the frames carry (§4): a phone's camera sensor is
mounted across its portrait panel, so Android hands 640x480 frames with a
rotation of 90 and its preview draws them upright, 3:4; the box takes the
upright shape rather than the sideways frames', and the preview is cropped
to the frames' field of view where the platform's preview stream has
another aspect (docs/traps.md, the Android self-view's shape). Half rather than the whole: a
1280x720 camera at its full size is wider than most windows a call sits in,
and the frames the app is handed are the full size either way (§4).

The one-view rule, `fit`, `aspect` (the box's ratio the app chooses,
docs/media-plan.md §3, RULED 2026-10-03: a 16:9 box with `cover` shows a
phone's upright 3:4 camera as the wide tile the other platforms show), the
accessibility props and the visibility occurrence are the video view's. An app that must process its self-view
(a blurred background) shows `surface(capture)` instead, the frames mode of
docs/media-plan.md §4, or feeds its processed frames to a surface (§5).

## §4. Frames and samples to the app

The transport is the app's, so kaya hands it what the platform captured:

- **Frames** are NV12 in CPU memory (Y plane, then interleaved UV), with
  width, height, both strides, a timestamp on the capture's own monotonic
  clock in nanoseconds, and the rotation the frame needs to stand upright
  (0, 90, 180, 270), carried as metadata as WebRTC carries it rather than
  paid for by rotating pixels. NV12 is Apple's native `420v`/`420f` and the
  usual layout of Android's `YUV_420_888`, MediaFrameReader's and a
  webcam's through GStreamer; kaya repacks only where the platform hands
  another layout.
- **Samples** are signed 16-bit PCM, 48 kHz, mono, in 10 ms chunks of 480,
  the framing every WebRTC stack and Opus encoder takes; the core
  resamples and converts where the platform's native format differs
  (Float32 on the mac, 44.1 kHz where Android gives only that, stereo
  Float32 on Windows).
- **The thread is kaya's capture thread, never the app thread.** A frame or
  chunk is a callback with a BORROWED buffer valid until it returns; the
  next frame is dropped while the app's callback still runs (keep-only-
  latest, every platform's default); samples are never dropped, a slow
  callback reporting `overrun` in the occurrence stream. The callback holds
  no transaction: to touch the scene it posts, the chat app's socket-reader
  route (docs/chat-plan.md §0), and the bindings' wrong-thread refusal is
  what holds that. Bindings with a collector copy the buffer into their own
  byte array before the call (C, Rust, Swift and Go borrow), since a view
  kept past the callback is the handle-lifetime question
  docs/media-plan.md §4 leaves to the producer research.

GPU frames (an `IOSurface`, an `AHardwareBuffer`) are not offered in the
first slice: a software video encoder reads CPU memory, and handing GPU
handles to nine languages is the app-as-producer research
(docs/deferred.md's "RESEARCH: the app as a surface's producer").

## §5. The far end: the peer's picture and the peer's voice

A call shows the peer's frames and plays the peer's samples, both arriving
in the app's code from its transport. Today neither has a route: the player
takes a source, never a stream, and the surface's app producer is GPU-only
and unbuilt. Two pieces close it:

- **The surface takes CPU frames from the app**, NV12 as in §4, the app
  calling `submit_frame` from any thread; the backend uploads (a
  `CVPixelBufferPool` into an `AVSampleBufferDisplayLayer`, a
  `GdkMemoryTexture`, a `CompositionDrawingSurface`, an `ImageWriter` on
  the surface's `Surface`) and composites on the display clock, keeping
  the last frame. This is the surface's contract with memory in place of a
  texture; the GPU producer stays the research's.
- **A voice output object** plays 48 kHz s16 mono chunks the app writes:
  `AVAudioSourceNode` on the engine the capture's voice processing uses,
  `AudioTrack` with `USAGE_VOICE_COMMUNICATION`, WASAPI render or
  AudioGraph's frame input node in the Communications category, `appsrc`
  into PipeWire with `media.role=Phone`.

Why kaya and not the app plays the peer: the platform's echo canceller
needs the far-end signal as its reference, and only kaya can put playback
and capture on the same voice path (Apple's voice-processing I/O, Android's
`VOICE_COMMUNICATION` with `AcousticEchoCanceler`, Windows'
Communications category). Voice processing is on by default for a capture
with a microphone, the web's `echoCancellation` default, with a `voice`
prop to turn it off for music. GTK's carve-out, stated once: PipeWire's
echo-cancel module is not loaded by default and kaya does not load modules
into a user's session, so on Linux the canceller is present only where the
desktop provides it, and `voice` reads back whether it is.

## §6. The media session, the notification, the call

A call is not Now Playing: a capture never attaches to the media session,
and a voice output is not a player. The web's video-conferencing actions
(`togglemicrophone`, `togglecamera`, `hangup`) are a later follow-on. An
incoming call is an ordinary notification (docs/notification-reply-plan.md's
machinery): the peer's call posts one keyed by the conversation, and
activating it opens the call screen where the app's own Answer and Decline
buttons are; no ringing loop, no full-screen intent. CallKit and
ConnectionService stay out, as directed.

## §7. Testing with no real camera, and what is measured first

**The wall.** A lane never opens a real camera or microphone, and on the
mac that has to be structural, not a habit: a guest launched from a lane
inherits the TCC grant of its responsible process (the terminal or launchd
parent), so a leg reaching a real device would open the maintainer's camera
with no prompt at all; the iOS simulator's microphone IS the host's input;
the emulator's microphone is the host's once `-allow-host-audio` or
`hostmicon` is set. So under the harness (`KAYA_SELFTEST`) each backend's
one device-open function accepts only a synthetic device and refuses any
other naming it; the Android runner refuses a host-audio flag and a
`webcam` camera mode; a gate holds every open path dominated by the check,
with a watched negative. The maintainer's hand run of the chat app outside
the harness is the only route to real devices.

**The synthetic content** is one definition everywhere: a flat asymmetric
colour (the media suite's C83C1E) and a 440 Hz tone for the local devices,
1E5AC8 and 660 Hz for the simulated peer, two synthetic cameras of
different colours and two microphones of different pitches so the device
choice is assertable. The core keeps statistics of what passes through §4
(frames counted, the last frame's centre colour, the dominant frequency of
the last second of samples by zero crossings) and the harness reads those,
so no app reports its own evidence. The preview's colour is read by each
lane's existing video ink route.

**Where the synthetic device sits, per platform** (as deep in the
platform's own path as the lane can reach):

| platform | camera | microphone | what it leaves untested |
|---|---|---|---|
| Android emulator | `-camera-front`/`-camera-back videofile:` of the suite's clips (CameraX, the real path) | gRPC `injectAudio` of the tone (`AudioRecord`, the real path) | a physical device's quirks |
| Linux container | a PipeWire daemon per session with `videotestsrc` nodes carrying `media.role=Camera`, reached through the portal and with no portal | a PipeWire virtual source fed by `audiotestsrc` | a real camera's formats |
| Windows VM | an MF virtual camera, a small arm64 media source DLL in tools/, registered once on the VM by admin, created per leg with session lifetime | a loopback audio driver (VB-CABLE ARM64 or the open Virtual-Audio-Driver) carrying the tone | the per-app prompt when it ships |
| macOS, iOS simulator | kaya's in-process synthetic device behind the same capture object: frames into an `AVSampleBufferDisplayLayer` preview and the §4 path | the same, in-process | `AVCaptureSession` itself, which only the maintainer's hand run reaches |

**Measured first**, each before its arm is written:

1. Android: `videofile:` on the pool's headless SwiftShader emulator, and
   whether a camera flag applies over the read-only `default_boot`
   snapshot (tools/android/run-emulator.py loads it with
   `-force-snapshot-load`; an AVD change rebuilds the snapshot, never an
   erase); `injectAudio` reaching `AudioRecord` with the pool's `-no-audio`;
   the front camera, which the pool's AVDs set to none.
2. Linux: PipeWire and WirePlumber running headless per session in the
   lane image (neither is installed: tools/linux/Dockerfile); the portal's
   permission store keyed for an unsandboxed app, and pre-granting it; the
   portal's service files, moved off the default bus because GTK's file
   chooser routes through any activatable portal (the Dockerfile's measured
   note), put on the bus for capture legs only, as the notify legs do.
3. Windows: `MFCreateVirtualCamera` on the 25H2 arm64 VM, the DLL's
   architecture, `PrintWindow` reading `MediaPlayerElement` over a frame
   source (measured for a player, docs/media-plan.md §6), `CheckAccess`'s
   answer for an unpackaged process, and the loopback driver.
4. iOS: that the simulator lists no camera (one project claims a host
   Camera Extension appears there), and that the in-process source keeps
   the simulator's microphone, the host's, closed.
5. Every platform: the frame layout actually delivered, NV12 or another,
   and the native sample format, against §4's conversions.
6. By the maintainer, by hand: the mac's preview and frames from the real
   webcam and Continuity Camera, `systemPreferredCamera` following his
   choice, `in_use` with FaceTime holding the camera, the indicator on and
   off with `camera` set to none, and the echo canceller with speakers on.

## §7a. An opt-in check on real devices (the maintainer, 2026-10-01)

The lanes never open a real camera or microphone: their assertions need
fixed content, the runs are unattended on the maintainer's own machine (the
camera light, a recording of the room, screenshots kept in a failure
bundle), macOS asks permission for every rebuilt guest, and four of five
lanes have no real device. Beside the maintainer's own hand run of the chat
app's call, an OPT-IN leg that only a person starts, never part of any
matrix, checks what does not depend on what the camera sees: the real
devices are listed, frames arrive at a plausible size and rate, samples
arrive from the microphone, and stopping the capture turns the device's
indicator off. It keeps no pixels and no samples in its log or bundle.

## §8. Sequencing and bindings

Depth on the mac with the in-process source: the capture object, the
preview, §4's callbacks and statistics, the core, SwiftUI and Rust, with a
`capture` scene; then the breadth (GTK, WinUI, Compose, the iOS legs, the
other eight bindings, every binding doing the object, the C floor through
kaya.h), each lane's synthetic device measured first (§7); then §5's
surface frames and voice output; then the chat app's call stage (a new C10 row
in docs/chat-plan.md's table): call and video call from a conversation, the
self-preview, the device pickers, the simulated peer's pattern and tone
through the app's loopback transport (Go, the chat app's language; pion is
the Go WebRTC stack if the app wants one), mute and camera off, and the
incoming call as a notification. Not promised: recording to a file, photo
capture (the system camera UI through a picker is a separate, smaller
slice), screen sharing, background calls, CallKit, ConnectionService.

## §9. The rulings asked — all five RULED 2026-10-02 as recommended (the maintainer: "go with your recommendation"), the Windows VM's one-time virtual camera and loopback install with its reboot included

1. **The preview is the video view given a capture**, `video(capture)`,
   not a new kind. RECOMMENDED: yes. Three of four backends lower it to the
   element the player already uses, and the one-view rule, `fit` and the
   visibility occurrence come with it.
2. **Frames are NV12 in CPU memory and samples are 48 kHz 16-bit mono in
   10 ms chunks, handed on kaya's capture thread in a buffer borrowed for
   the callback.** RECOMMENDED: yes. It is what encoders and WebRTC stacks
   take; GPU frames wait for the producer research.
3. **The lanes' synthetic devices sit in each platform's own path where a
   lane can reach it** (the emulator's camera and audio injection, PipeWire
   nodes in the container, an MF virtual camera and a loopback driver
   installed once on the Windows VM) **and inside kaya on the mac and the
   iOS simulator, behind a wall that refuses a real device under the
   harness.** RECOMMENDED: yes. The other answer, kaya's in-process device
   everywhere, is cheaper but would test no platform's capture path on any
   lane; the Windows half needs the VM changed by an admin install and a
   reboot, which is the maintainer's to allow.
4. **kaya plays the peer's voice and shows the peer's picture** (§5): a
   voice output object, and the surface taking the app's CPU frames, with
   the platform's echo cancelling on by default. RECOMMENDED: yes, since
   echo cancelling needs playback and capture on one voice path; the
   alternative leaves every app to bring its own canceller.
5. **On Linux, the camera portal first and PipeWire directly when no portal
   answers**, GNOME Snapshot's rule. RECOMMENDED: yes; portal-only would
   leave a desktop with no portal backend without a camera.

## §10. The choices the build settled — RULED 2026-10-03 as built (the maintainer: "go with your recommendations")

The depth and breadth slices met eight questions the plan above did not
settle, built a recommendation for each, and the maintainer took all eight
(docs/deferred.md's capture BUILD entry):

1. Audio captured just before a mute is still delivered; the mute takes the
   next chunk.
2. A video view shows a player or a capture, never both, and a row template
   shows no capture.
3. Starting a capture on a machine with no device of that kind is a scene
   error, not a failure the app handles.
4. Watching the devices also reports each permission as it stands.
5. A capture callback that raises is caught, logged naming the capture, and
   the capture keeps running (DESIGN.md's abort rule on the capture thread),
   in all nine bindings.
6. Under the harness every backend lists the core's synthetic device table.
7. Where a lane has one audio input, the two synthetic microphones are its
   left and right channels.
8. iOS sets the `.playAndRecord` audio category only on the real-device
   path; and JS runs capture callbacks in a worker the capture thread calls
   and waits on.
