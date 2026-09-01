# validate-linux.sh + validate-all.sh -> python (runner conversion, stage 4b)

The last two lane-tier runners under docs/runner-conversion-plan.md
§4 item 3, converted together: the linux docker wrapper (51 lines)
and the matrix driver (317 lines). gates.sh remains, last by the
plan's own ordering.

## What moved where

- tools/validate-linux.py — the docker wrapper: gen-market --ensure
  on the host side (the container's root must not own the stamp), the
  image build, the mounted flight-recorder home, the 1800s ceiling on
  the container run. NO lanes module: the linux tables live in
  tools/linux/run-suites.sh, an IN-CONTAINER payload that stays shell
  by §6 — check-steps' linux arms keep reading that text unchanged.
- tools/validate-all.py — the matrix driver. The lane roster is the
  launch block itself (check-gates pins it byte-for-byte, so the
  spellings ARE the data), and the BUDGETS dict carries every
  ceiling with its full measured history — the ~180 lines of
  raise/lower reasoning moved intact, because those comments are the
  calibration record invariant 8 runs on.
- One timing correctness point over a naive port: the shell measured
  each lane's duration inside its own subshell; a python collection
  that waited lanes in queue order would bill an early finisher for
  its slower siblings' wall time. Each lane gets a waiter thread that
  stamps the end at actual exit.

## The re-teach

check-gates' matrix block was the whole surface: PLATFORM_LAUNCHES,
GATE_LAUNCH, ANDROID_PID/ANDROID_WAIT re-pinned to the python
spellings; matrix_parallel_problem parses the python parallel block
(the five launches consecutive with the linux env rider's
continuation tolerated, the android-wait tail, gates.sh appearing
only in the fingerprint and the niced launch); N5, N6, N7, N10, N11
and N12 re-spelled as python perturbations, each applied with its
count printed and red re-proven. bench-tables' MATRIX_RUNNERS
basenames flipped to the .py bodies. No doc line anchors exist for
either file; every prose path stays valid through the shims.

## Record

- Full gate sweep on the converted tree: 50/50 (check-gates' six
  matrix negatives applied against the python spellings, each count
  printed).
- Linux lane run 1: 603/604 — the one red was
  portfolio-python-wayland's fold assertion ("column#9 fold reads
  folded, wanted it not folded"), a scene that runs entirely inside
  the untouched in-container run-suites.sh. First sighting of this
  shape (three greens beside it in the kept journals); if it recurs
  it earns a WATCH entry.
- Linux lane runs 2 and 3: ALL PASS 604/604 both — container-suites
  222s and 223s on the warm image.
- Matrix through the python driver, first attempt: the DRIVER's
  mechanics all held — six units launched on the pinned schedule,
  per-lane waiter-thread timings sane, budgets consulted, verdict
  table printed — and two lanes flaked on a host whose 15-minute
  load average read 53.8 (the SEVENTH full matrix in four hours,
  every lane within ~1x of its ceiling: windows 517s against 520).
  The windows red was the caption-centre probe's honest under-run
  (10 of 11 planned measurements, all 201 legs and 24 guest unit
  tests green); the android red was portfolio-python's title
  assertion (read "portfolio", wanted "Transactions") — the third
  portfolio-adjacent flake of the saturated stretch, after the
  wayland fold and beside the ios AX crash. No leaked load: the top
  consumers were the warm pools and the session itself, and the
  1-minute average was already 4.6 by the postmortem. The rerun
  below gated on load < 6 before starting.
- Matrix, the record run (load-gated): ALL PASS, 1,390 legs —
  mac 340s/349, linux 411s/604, windows 439s/201, ios 475s/113,
  android 230s/123, the gate sweep 50/50 inside it, 631s wall
  (parallel), every lane comfortably under its ceiling.
