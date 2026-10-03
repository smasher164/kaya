# Capture on the Android lane: measured (2026-10-02)

docs/capture-plan.md §7 items 1 and 5, measured on the host before and while
the Compose arm (android/kaya/src/main/kotlin/dev/kaya/KayaCapture.kt) was
written. Emulator 37.1.11.0 (nix store), system image API 35 google_apis
arm64-v8a, SwiftShader (`-gpu swiftshader_indirect`), headless, the pool's
360x800 panel at density 160. No host camera or microphone was opened: every
emulator here ran without `-allow-host-audio` and with no `webcam` mode.

## 1. The cameras: `imagefile:` and the read-only snapshot

A scratch AVD (`capprobe`, same image and panel, port 5580, deleted after)
seeded a `default_boot` snapshot exactly as the runner does, then:

| launch | cameras the guest lists (`dumpsys media.camera`) |
|---|---|
| snapshot seeded with the AVD's defaults (back `emulated`, front `none`), cold | 1, back, `device@1.1/internal/1` |
| `-read-only -snapshot default_boot -force-snapshot-load` plus `-camera-front imagefile:… -camera-back imagefile:…` | snapshot LOADED (586 ms), still 1 camera, the snapshot's |
| cold boot (`-no-snapshot`) with the same two flags | 2: back `internal/10`, front `internal/11` |

The camera list is the guest's, taken at boot, so a flag over the snapshot
changes nothing a guest can see. The runner therefore writes
`hw.camera.front` and `hw.camera.back` as `imagefile:` into the phone AVD's
config.ini (tools/android/run-emulator.py `shape_pool_cameras`) and reseeds
the snapshot once; measured on the pool, the reseeded snapshot boots with both
cameras (`the guest lists 2 camera(s) ['Back', 'Front']` in every capture
leg's log).

The `imagefile:` cameras offer YUV_420_888 at 320x240, 352x288, 640x480,
1280x720 and 1280x960, each with a minimum frame duration of 33.3 ms, and AE
target ranges (2,15), (15,15), (2,30), (30,30). So the formats offered to the
core's nearest_format are those sizes at 15 and 30, and the scene's wishes
meet 640x480@30 and 1280x720@15.

A 1280x720 PREVIEW beside the 1280x720 analysis stream was refused by CameraX
on the 360x800 phone (`failed unsupported`): a preview past the display's own
size is outside the guaranteed stream combinations. The preview takes the
platform's own size at the frames' aspect; the frames keep the chosen size.

## 2. The frame layout (item 5)

`KAYA_CAPTURE_LAYOUT: 640x480 y 640/1 u 320/1 v 320/1 -> repacked` and the
same at 1280x720 (`1280/1`, `640/1`, `640/1`): the emulator's camera hands
YUV_420_888 as three planes with a pixel stride of 1 (I420), not NV12, so the
arm repacks to NV12 (crates/kaya/src/android.rs `present_capture_frame`; a
camera that hands U and V interleaved with V one byte after U goes over in
place). The flat colours read back through the core's BT.601 conversion as
C83C1E or C63C1D and 1E5AC8, within expect_capture's 3; the screencap of the
preview reads C63C1E and 1E59C6, within the Android video ink's 14.

## 3. The microphone: gRPC `injectAudio`

- `-grpc <port>` alone answers "security: Insecure, auth: none" on [::], every
  interface. `-grpc <port> -grpc-use-token` binds 127.0.0.1 and wants a
  per-instance token the emulator writes to
  `~/Library/Caches/TemporaryItems/avd/running/pid_<pid>.ini` (`grpc.token`);
  the console's `~/.emulator_console_auth_token` is refused ("The token
  `Bearer …` is invalid", grpc-status 16). Read-only instances launched
  without `-grpc` write no discovery file.
- STARTING AN INJECTION WHILE NO GUEST APP RECORDS ENDS THE EMULATOR IN
  SIGSEGV (exit 139): with `-no-audio` (228 packets sent unpaced), with
  `-audio none` (155 unpaced; 10 to 11 paced at 10 ms with the format on the
  first packet alone, the shape of the AndroidGoLab ndk e2e audio-inject
  client), mono or stereo alike. The crashpad minidump, symbolized with
  `atos` against the emulator binary: `audio_forwarder_enable + 112`, a load at
  address 0x58 through the NULL an indirect call returned, under
  `QemuAudioInputEngine::start` ← `QemuAudioInputStream::QemuAudioInputStream`
  ← `EmulatorControllerImpl::injectAudio`.
- Started once the app's input delivers (§4), the injection works under the
  pool's own `-no-audio`, and survives the guest closing and reopening its
  input (a device switch, the camera turned off, the stop): one stream per
  leg, ~1000-2000 packets, no crash on any of the five pool emulators.
- A SECOND call while the first stream's microphone is registered is refused
  ("There can be only one microphone active"), twenty times over 8 s after the
  first stream was closed and the guest's input reopened. So the runner starts
  one stream at the app's first `KAYA_REQUEST: microphone on` and stops it at
  the leg's end (tools/lib/emulator_capture.py, the runner's
  `lane_microphone`).
- The samples: AudioRecord, VOICE_COMMUNICATION, 48 kHz, CHANNEL_IN_STEREO,
  ENCODING_PCM_FLOAT, answers `48000 Hz, 2 channel(s), float`
  (`KAYA_CAPTURE_AUDIO`), and the injected 44.1 kHz stereo s16 reaches it with
  the channels apart: the left channel reads 440 Hz and the right 660 Hz
  through the core's zero-crossing count. Watched: the channel swapped in the
  arm reads `samples 690 Hz, wanted … 440 Hz` (the leg red).

## 4. Under host load (2026-10-03, after capture-go went red in a matrix)

The matrix red read `samples silent` for the whole first input with the tone
streaming. The guest's audio HAL logged, from about the first second of that
input, `pcm_readi failed with 'cannot read/write stream data: I/O error'`
about ten times a second and padded every read with silence until the input
was closed (talsa::pcmRead retries EIO three times and never re-prepares the
pcm). capture-go pinned to each pool phone, the failed reads counted per leg:

| condition | runs | runs with failed reads | red |
|---|---|---|---|
| quiet host | 8 | 0 | 0 |
| 14 spinning cores (wall-clock bounded, stopped after) | 8 | 4 | 3 |
| the same, the first packet's time logged | 6 | 6 | 5 |
| the same, stream restarted on the first failure | 5 | 4 | 4 |
| the same, injected at 48 kHz | 5 | 5 | 3 |
| the same, NO injection at all | 4 | 3 | (all, no tone) |
| a 1 s and a 3 s stall of the stream, quiet host | 2 | 0 | 0 |

The input breaks under load with no tone at all, so the injection is not the
cause, and neither resampling, a stalled stream nor a restarted one moves it.
The capture legs that open a microphone run EXCLUSIVE, and each capture leg's
log names the HAL's failed reads per second (`audio HAL: …`).

Two more crashes of the §3 kind: the tone asked for with the AudioRecord made
but not started, and (load 121) asked for after startRecording but before the
first read came back. Both minidumps: `audio_forwarder_enable + 112` under
`EmulatorControllerImpl::injectAudio`. The arm now asks once its first read
returns.
