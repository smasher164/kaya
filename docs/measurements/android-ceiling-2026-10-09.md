# The android lane over its ceiling, 2026-10-09

The toast matrix (08fbf8a9) read android 1186 s, 912 s net of 274 s of token
waits, against the 870 s ceiling. The matrices before it read 765 (k2), 793
(reveal) and 857 (segmented) net.

## What grew

Nothing in android's own per-leg work. Per-leg seconds from the lane logs
(target/validate-lanes/runs/*/android.log):

| run | legs | leg seconds | median | dnd injections' one-minute host load (mean) |
|---|---|---|---|---|
| 233837Z (k2 matrix) | 232 | 1755 | 4 | 59 |
| 033020Z (segmented matrix) | 235 | 2079 | 6 | 80 |
| 080326Z (toast matrix) | 238 | 2223 | 6 | 51, peak 114 |
| standalone, pre-toast (00:04) | 238 | 989 | | |
| standalone, HEAD (this session) | 241 | 1022 | | 9 |

The touch-mode restore (16c32f3e) and the launcher force-stop (ba65d93b) are
in both the k2 and segmented matrices' logs, so they are not the step between
them. Standalone, the 238 legs the two runs share summed 989 and 999 s; the
three toast legs added 23 s of leg time, so the standalone lane after
build-compose read 509 s against 505. Every lane of the segmented matrix
slowed with android's (mac net 651 -> 784, linux 857 -> 1121 with a core
rebuild, iOS 831 -> 878): the growth is the host under the matrix, which
roughly doubles android's leg time (989 s alone, 2079-2223 s in a matrix).

The toast matrix's android phases: queued-compose 399, queued-jvm 189,
queued-go 125, queued-python 32, legs-pooled 41, legs-isolated 323 (dnd x3
62-64 s, chat-go 54, tasks-compose 28, notify 6, clock24 7). The isolated
phase is serial with three of four phones idle: a third of the lane's net.

## The isolated legs pooled

ALONE reduced to clock24-compose (it sets every phone's 24-hour setting).
Each run below is the whole lane, run-emulator.py `all`, beside 30 spinning
processes with a wall-clock deadline (stopped and checked gone after each
run) and the iOS lane another session was running; seconds from the end of
build-compose to the lane's end.

| run | ALONE | result | after build-compose | isolated | dnd one-minute load (mean) |
|---|---|---|---|---|---|
| serial-load1 | 7 legs (HEAD before this change) | ALL PASS | 689 | 290 | 125 |
| pooled-load1 | clock24 only | 238 green, capture x3 red* | 572 (466 without capture) | 110* | 178 |
| pooled-load2 | clock24 only | ALL PASS | 483 | 3 | 299 |

*Run without KAYA_QUIET=skip, so the three microphone legs ran under the load
(docs/traps.md, the emulator's audio input entry); the matrix runs them in its
quiet tail.

The pooled legs under load: dnd 62-67 s, chat-go 52-54, tasks-compose 33-34,
notify 6-7, all green. With the previous session's four quiet runs
(docs/measurements/lane-wall-2026-10-08.md) that is six of six. The saving
under load is 206-223 s a lane. Not measured: a full matrix, which this
session did not run.

## media_feed-jvm

The red is docs/traps.md's "The goldfish codec HAL's binder pool ran dry".
Not reproduced in six legs beside 28 spinners (load 60-100) or three quiet ones.
Ten players prepare at mount in the feed scene, fourteen goldfish decoders
with the setOutputSurface workaround's re-creations, against the codec HAL's
eight binder threads. Holding a feed's off-screen players unprepared on
Android would keep fewer decoders open at once, which may or may not keep
the HAL out of that state; it is a design change to the media surface and is
left for a ruling.

RULED and built the same day (docs/media-plan.md §7d): a row's player opens
only once its row shows, on all five platforms. `allocate(c2.goldfish.h264.decoder)`
lines in the leg's full logcat buffer, the three media_feed legs on the quiet
pool (KAYA_ONLY=media_feed, each leg forced red after its last step to keep
its buffer):

| | compose | go | jvm |
|---|---|---|---|
| before the scroll, hold cut out (the old behaviour) | 20 | 20 | 20 |
| before the scroll, with the hold | 8 | 12 | 12 |
| whole leg, with the hold | 16 | 20 | 20 |

Each player allocates two decoders (the setOutputSurface workaround's
re-creation), so 4 to 6 rows were shown at mount on the phone. `scroll_end`
carries every row through the viewport, so by the leg's end every player has
opened; releasing a decoder when its row scrolls far out is not built.
