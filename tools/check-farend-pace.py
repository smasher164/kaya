#!/usr/bin/env python3
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent / "lib"))
from kaya_gate import Gate, dev_shell_or_die

dev_shell_or_die()

# A FAR-END PEER THAT FELL BEHIND SKIPS TO THE PRESENT (docs/traps.md, the
# far end that replayed its stall): every far-end guest paces its frames
# and samples by the wall clock, and a peer the host starved for seconds
# would otherwise submit every missed frame back to back (a 1280x720
# conversion each, on the thread that also writes the voice) and write
# seconds of samples the 200 ms voice queue drops anyway. Each guest
# carries two skips before its catch-up loops: more than two frames
# behind, the frame counter jumps to the present; more than the queue
# behind, the sample counter jumps to the queue's edge.

import re

g = Gate("check-farend-pace")

# Each guest's two skips, as the language spells them. The frame skip
# assigns the frame counter from `elapsed` and 15; the sample skip assigns
# the sample counter from `elapsed` and the queue's 200 ms.
GUESTS = {
    "guests/rust/farend.rs": (
        r"sent_frames = elapsed\.as_micros\(\) as u64 \* 15 / 1_000_000",
        r"sent_samples = \(elapsed\.as_micros\(\) as u64 - 200_000\) \* 48 / 1_000 / 480 \* 480"),
    "guests/python/farend.py": (
        r"sent_frames = int\(elapsed \* 15\)",
        r"sent_samples = int\(\(elapsed - 0\.2\) \* 48000 / 480\) \* 480"),
    "guests/go/farend/farend.go": (
        r"sentFrames = elapsed \* 15 / 1_000_000",
        r"sentSamples = \(elapsed - 200_000\) \* 48 / 1_000 / 480 \* 480"),
    "guests/csharp/FarendScene.cs": (
        r"sentFrames = elapsed \* 15 / 1_000_000;",
        r"sentSamples = \(elapsed - 200_000\) \* 48 / 1_000 / 480 \* 480;"),
    "guests/java/dev/kaya/guests/Farend.java": (
        r"sentFrames = \(long\) \(elapsed \* 15\);",
        r"sentSamples = \(long\) \(\(elapsed - 0\.2\) \* 48000 / 480\) \* 480;"),
    "guests/swift/farend.swift": (
        r"sentFrames = Int\(elapsed \* 15\)",
        r"sentSamples = Int\(\(elapsed - 0\.2\) \* 48000 / 480\) \* 480"),
    "guests/ocaml/farend.ml": (
        r"sent_frames := int_of_float \(elapsed \*\. 15\.0\)",
        r"sent_samples := int_of_float \(\(elapsed -\. 0\.2\) \*\. 48000\.0 /\. 480\.0\) \* 480"),
    "guests/haskell/farend.hs": (
        r"floor \(elapsed \* 15\)",
        r"floor \(\(elapsed - 0\.2\) \* 48000 / 480\) \* 480"),
    "guests/js/farend.ts": (
        r"sentFrames = Math\.floor\(elapsed \* 15\);",
        r"sentSamples = Math\.floor\(\(elapsed - 0\.2\) \* 48000 / 480\) \* 480;"),
}


def census(sources):
    found = []
    for rel, (frames, samples) in GUESTS.items():
        text = sources[rel]
        if not re.search(frames, text):
            found.append(f"{rel}: the peer replays every missed frame (no skip to the present "
                         f"before its frame loop)")
        if not re.search(samples, text):
            found.append(f"{rel}: the peer replays its whole stall into the voice queue (no "
                         f"skip to the queue's edge before its sample loop)")
    return found


REAL = {rel: g.read(rel) for rel in GUESTS}
for line in census(REAL):
    g.finding(line, at="far-end pacing")

# Every guest's skips cut in a copy, both at once, the count printed.
for rel, (frames, samples) in GUESTS.items():
    cut = dict(REAL)
    cut[rel] = g.doctor(f"{rel} frame skip cut", REAL[rel], frames, "cut_frames")
    g.negative(f"{rel} replaying every missed frame", lambda c=cut: census(c),
               want="replays every missed frame")
    cut2 = dict(REAL)
    cut2[rel] = g.doctor(f"{rel} sample skip cut", REAL[rel], samples, "cut_samples")
    g.negative(f"{rel} replaying its stall into the queue", lambda c=cut2: census(c),
               want="replays its whole stall")
g.negatives_ran(2 * len(GUESTS))
g.verdict(f"{len(GUESTS)} far-end guests skip to the present after a stall")
