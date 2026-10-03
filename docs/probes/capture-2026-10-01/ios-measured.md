# Capture on the iOS simulator: measured 2026-10-02 (docs/capture-plan.md §7 item 4)

The arm is the shared SwiftUI interpreter's in-process synthetic source; these
are the two premises its legs rest on.

1. **The simulator has no camera service.** `xcrun simctl help privacy`
   (Xcode 26.6, 17F113; the iOS 26.5 pool kaya-sim-0..2 and kaya-sim-pad)
   lists calendar, contacts-limited, contacts, location, location-always,
   photos-add, photos, media-library, microphone, motion, reminders and siri:
   no camera. An `AVCaptureDevice.DiscoverySession` in the simulator was NOT
   run, because it reaches the host's CoreMediaIO, which is the maintainer's
   camera stack.
2. **The in-process source keeps the host's microphone closed.** The
   simulator's microphone is the host's input, so this was read on the host:
   `kAudioDevicePropertyDeviceIsRunningSomewhere` of the default input device,
   a property read that needs no permission and opens nothing, sampled at
   10 Hz across `KAYA_ONLY=capture tools/ios/run-sim.py` (rc 0, both legs
   PASS): 0 in all 235 one-second readings. The property was calibrated on
   the default OUTPUT device first: 1 for 10 of 10 samples during a silent
   `afplay -v 0.0`, 0 for 10 of 10 without it.

Rule 7 (the `.playAndRecord` category while a capture with a microphone
runs) cannot be taken under the harness: activating it opens the simulator's
input, which is the host's. It belongs to the real path behind the wall
(docs/deferred.md's capture BUILD entry).

The probe, compiled with `cc -O1 -o mic mic.c -framework CoreAudio` in the
dev shell (`PROBE_OUTPUT=1` reads the default output device instead):

```c
// Reads, never opens: whether the default input device is running in any
// process (kAudioDevicePropertyDeviceIsRunningSomewhere). No TCC prompt.
#include <CoreAudio/CoreAudio.h>
#include <stdio.h>
#include <unistd.h>
#include <time.h>
#include <stdlib.h>
static UInt32 get_u32(AudioObjectID obj, AudioObjectPropertySelector sel, AudioObjectPropertyScope scope) {
    AudioObjectPropertyAddress a = {sel, scope, kAudioObjectPropertyElementMain};
    UInt32 v = 0, n = sizeof v;
    if (AudioObjectGetPropertyData(obj, &a, 0, NULL, &n, &v) != noErr) return 0xFFFFFFFF;
    return v;
}
int main(int argc, char **argv) {
    int seconds = argc > 1 ? atoi(argv[1]) : 1;
    AudioObjectPropertyAddress da = {getenv("PROBE_OUTPUT") ? kAudioHardwarePropertyDefaultOutputDevice : kAudioHardwarePropertyDefaultInputDevice, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    AudioDeviceID dev = 0; UInt32 n = sizeof dev;
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &da, 0, NULL, &n, &dev) != noErr) { printf("no default input\n"); return 2; }
    int on = 0;
    for (int i = 0; i < seconds * 10; i++) {
        UInt32 r = get_u32(dev, kAudioDevicePropertyDeviceIsRunningSomewhere, kAudioObjectPropertyScopeGlobal);
        if (r == 1) on++;
        if (i % 10 == 0) { printf("t=%ds input %u running_somewhere=%u\n", i / 10, dev, r); fflush(stdout); }
        usleep(100000);
    }
    printf("samples %d, running %d\n", seconds * 10, on);
    return on ? 1 : 0;
}
```
