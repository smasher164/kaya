# Capture on the Windows lane: measured (2026-10-02)

The Windows half of docs/capture-plan.md §7 items 3 and 5, measured on the
lane's VM (UTM, arm64, Windows 11 10.0.26200.9457) before the WinUI arm was
written. Every device command ran in the console session through an
interactive scheduled task (`schtasks /it /rl highest`), never over plain
ssh; the probes are `tools/winvcam`'s `kaya-capture-lane` subcommands.

## The VM before the install

- Audio: the virtio HDA device's "Speakers" (render) and "Line In" (capture).
  Line In is UTM's route to the HOST's input and was never opened.
- No camera; the FrameServer and FrameServerMonitor services stopped
  (demand start).
- `HKLM` and `HKCU` `...\CapabilityAccessManager\ConsentStore\webcam` and
  `microphone`: `Allow`; `HKCU ...\webcam\NonPackaged` and
  `...\microphone\NonPackaged`: `Allow`.

## The loopback driver

| | VB-CABLE Driver Pack 45 | VirtualDrivers/Virtual-Audio-Driver |
|---|---|---|
| ARM64 | an `NTARM64` section, `vbaudio_cable64arm_win10.sys` | listed, "tested on x64" |
| signing | catalog signed by Microsoft Windows Hardware Compatibility Publisher | test-signed: `bcdedit /set testsigning on` |
| loopback | "All signals sent to the device output is going on the device input" | a separate speaker and microphone, not connected |
| licence | donationware, use and copy AS IS, not inside another installer | MIT (MS-PL for the sample code) |

VB-CABLE, by measurement of the two requirements a lane has (a production
signature, and a render endpoint that feeds a capture endpoint). Zip sha256
b950e39f01af1d04ea623c8f6d8eb9b6ea5c477c637295fabf20631c85116bfb; inf
`vbMmeCable64_win10.inf` DriverVer 10/07/2024,3.3.1.7, sha256
61c857be74831cc299d9be62f8d49d137f14063454fc54f859d5bc9b4b813daf; ARM64 sys
sha256 2dc35db3dfad0f25771a3e59af38e8b1268878ebe127476ea75fee109f2927dd.

`VBCABLE_Setup_x64.exe -i -h` from an elevated interactive task exited 0 with
no dialog. Before the reboot the endpoints existed already, the render one
named "Speakers (VB-Audio Virtual Cable)"; after it "CABLE Input",
"CABLE In 16ch" and "CABLE Output", each "(VB-Audio Virtual Cable)".

## The cable carries OPEN B

`kaya-capture-lane run` plays 440 Hz on the left channel and 660 Hz on the
right into "CABLE Input", whose mix format is 48000 Hz, 2 channels, float32.
One second of "CABLE Output" read back through WASAPI:

    cable output: 48000 Hz, 2 channels, float true bits 32
    channel 0: 57600 samples, rms 0.354, 440 Hz
    channel 1: 57600 samples, rms 0.354, 660 Hz

## MFCreateVirtualCamera on 25H2 arm64

`MFCreateVirtualCamera(SoftwareCameraSource, Lifetime_Session,
Access_CurrentUser, name, "{clsid}", none)` then `Start` succeeded for both
class ids from an elevated interactive task. The DLL is arm64 (the Frame
Server is a native arm64 service on Windows on Arm), statically linked
against the C runtime, at `C:\Program Files\kaya-capture\`, registered in
HKLM with ThreadingModel Both. `MFEnumDeviceSources` then listed:

    video capture: "kaya Synthetic Camera 1 (Windows Virtual Camera)" \\?\swd#vcamdevapi#9a9e…#{e5323777-f976-4f5b-9b55-b94699c46e44}\{fcebba03-9d13-4c13-9940-cc84fcd132d1}
    video capture: "kaya Synthetic Camera 2 (Windows Virtual Camera)" \\?\swd#vcamdevapi#0709…#{e5323777-f976-4f5b-9b55-b94699c46e44}\{fcebba03-9d13-4c13-9940-cc84fcd132d1}

The pipeline appends " (Windows Virtual Camera)" to the name it was given,
so the arm matches a synthetic camera by the name's start. Both cameras left
the list when the helper exited. Access_AllUsers was not needed.

## The frame layout delivered (item 5)

One frame of camera 1 through an `IMFSourceReader` over its activate: the
native types are exactly the four the source offers (NV12 640x480 at 30 and
15, 1280x720 at 30 and 15); the first frame came after 38 ms, NV12, 460800
bytes, centre Y 101, U 94, V 192 — C83C1E as video-range BT.601 by the core's
own formula, so nothing converts it on the way. The arm hands MediaFrameReader's
NV12 SoftwareBitmap planes to the core as they are (plane descriptions give
each plane's start and stride).

## CheckAccess for an unpackaged process

`AppCapability.Create("webcam"|"microphone").CheckAccess()` from PowerShell
(unpackaged) answered `Allowed`. With `HKCU ...\webcam\NonPackaged` `Value`
written `Deny` it STILL answered `Allowed` (restored to `Allow` straight
after). So CheckAccess says nothing an unpackaged app can use: the arm takes
E_ACCESSDENIED at initialization as the answer (§2 rule 1), and off the
harness `request_permission` opens the kind's default device once to learn it.

## Not measured here

PrintWindow reading a MediaPlayerElement over a frame source is read by the
capture leg's own `expect_video_ink` (see the capture notes for its result);
the VM became unreachable before that leg ran (docs/traps.md, the UTM stop
that wedges).
