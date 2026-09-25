# The Windows drag's pacing, measured (2026-09-24)

`inject_drag` drives real mouse input at screen pixels and cannot read
what the application did with it, so every phase of the gesture ended in
a sleep: 500ms with the cursor on the source, 300ms after the press, six
threshold moves at 60ms, thirty travel steps at 60ms, 400ms at the
destination, 300ms after a nudge. 3,660ms per drag. The dnd scene makes
eight of them, so ~29s of a 32s leg was sleep. Six language legs run that
scene, so ~176s of the windows lane's 1,282s, plus the tasks scene's
single drag on each of its own.

None of those numbers had ever been measured. They are drive.ps1's, from
the 2026-09-03 probe, which wrote them to make a first drag work at all;
the same seven sit in `tools/guest/dnd-witness.ps1` and in
`tools/win/dragprobe/drive.ps1`.

## What the sweep found

The pacing was made settable (`KAYA_DRAG_PACE`, seven numbers, removed
again after the sweep) and the real `dnd_rust` leg was driven on the VM
with the guest killed between reps.

| pacing (settle,press,thresh,steps,travel,land,jiggle) | sleep per drag | leg | green |
| --- | --- | --- | --- |
| 500,300,60,30,60,400,300 (shipped) | 3,660ms | 33.4s | 2/2 |
| 100,80,15,8,15,120,80 | 590ms | 8.0s | 3/3 |
| 40,30,5,4,5,50,30 | 195ms | 4.3s | 3/3 |
| 10,10,2,2,2,15,10 | 53ms | 3.0s | 20/20 |

So there is no floor anywhere near the shipped numbers: the scene passed
twenty consecutive times at 53ms, one sixty-ninth of the sleep it shipped
with.

THE FIRST ATTEMPT AT THIS MEASUREMENT REPORTED A FLOOR THAT DID NOT
EXIST. At 53ms the first twenty-rep run came back 18/20, and the two
reds were adjacent: rep 9 hung its full 150s and rep 10 failed every
drag 1.9s later. The sweep was leaving each rep's guest running, so the
next rep's window was never frontmost. With a `taskkill` between reps the
same pacing is 20/20. A harness that contaminates its own runs measures
itself.

## What replaced the guesses

Two of the three long sleeps were standing in for a signal the process
already has, and kaya's own window is at one end of every drag the lane
drives:

- `DRAGS_STARTED`, bumped in the source's `DragStarting` handler.
- `HOVERS_ANSWERED`, bumped in `xaml_drag_event` after the destination's
  verdict is set.

`inject_drag` waits on those with a ceiling instead of sleeping. On an
idle guest both answers arrive at once:

```
kaya: winui drag began start in 0ms, 1/1 hover at the release point in 5ms, 481ms in all
kaya: winui drag began start in 0ms, 1/1 hover at the release point in 2ms, 465ms in all
```

THE LANDING IS NOT A MOVE. The first signal-driven version waited at the
destination as well and cost 601ms on every drag, `0/1` every time: the
travel's last step lands exactly on `to`, so the `move_to(to)` after it
moves the cursor nowhere, Windows sends no message, and no hover is ever
answered for it. The nudge is the arrival, and its hover is the better
signal anyway — messages arrive in order, so an answer for the nudge's
position says every move before it was processed, and it is the position
the button comes up at.

## What ships

Three sleeps with no signal behind them (100ms settle, 100ms press, 15ms
per move, eight travel steps) and two ceilings of 600ms. 465ms per drag
measured (100 + 100 + 6x15 + 0 + 8x15 + 5), 1,610ms worst case if
both ceilings expire because a destination answers nothing at all.

| | per drag | dnd leg |
| --- | --- | --- |
| before | 3,660ms | 33.4s |
| after | 465ms | 6.7s |

12/12 green on the signal-driven shape by hand, and then the shape that
matters: UNDER THE FULL FIVE-LANE MATRIX, where the VM is starved by the
other four lanes and the windows lane itself spends 339s waiting for the
exclusive token, the six dnd legs read 5, 5, 5, 6, 5 and 5 seconds
against the 31-32s they read before. That is the answer to the only real
question a fixed dwell raises — whether the margin survives a loaded
host — and a wait on the app's own answer does not have to have one.

| | before | after |
| --- | --- | --- |
| dnd_rust under the matrix | 31s | 5s |
| dnd_python / js / go / csharp / java | 31-32s | 5-6s |

## What did not change

`tools/guest/dnd-witness.ps1` drives the two cross-app legs, where one
end is a stock Win32 reader in another process that answers nothing a
PowerShell script can read. Its dwells stay, and stay guessed
(docs/deferred.md's witness-drag dwell entry).
`tools/win/dragprobe/drive.ps1` is the 2026-09-03 probe's own artifact
and keeps its pacing, because changing it would change what that probe
measured.
