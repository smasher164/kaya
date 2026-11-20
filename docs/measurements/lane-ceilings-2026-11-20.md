# The lane ceilings from a cold reading, 2026-11-20

The maintainer's ruling, 2026-11-20, choosing to raise the ceiling over judging
a lane net of its build, deploy and package phases: "The point of the time
judgement is to measure the iteration loop in the worst case, which involves
rebuilding. It's going to be a constant push and pull but it's important to
hold ourselves to high standards." So a ceiling is set from a matrix on a
commit that changes crates/kaya, which every lane must recompile, and never
from one whose lanes were pre-warmed (docs/HACKING.md, the ceilings
paragraph). The last green matrix before this (799e95ca, windows 1888 s net)
had the windows lane pre-warmed and is not a reading under the ruling.

Sources: the matrix log, the lane logs under
target/validate-lanes/runs/20261120T174103Z/, and the windows lane's
flight-recorder journal (runs/20261120T174516Z-058388/journal.jsonl), whose
leg records carry each leg's end and seconds.

## The cold reading

The change: 84fb1e98 removed number_field::commit, which had no caller outside
one test, so the core's content moved and every lane recompiled it. The gate
sweep before the commit rebuilt the host libkaya, as every pre-commit sweep
does, so the mac lane's core build was warm; the other four lanes built cold.
Nothing was pre-warmed. Host at launch: idle 5603 s, load 8.5 (just after the
gates), AC power at 100%; the windows lane's start read load1 253 with every
lane building at once.

| lane | wall | waits | net | ceiling | net/ceiling | one-time phases (s) |
|---|---|---|---|---|---|---|
| mac | 1286 | 124 | 1162 | 1250 | 93% | core-build+gates 54, guest-builds 24 |
| linux | 1403 | 337 | 1066 | 1250 | 85% | core-build 53, guest-builds 26 |
| windows | 2099 | 36 | 2063 | 1900 | 109% | build 220, native-images 27, deploy 89, package 10, unit-tests 6, caption-centre 30 |
| ios | 1793 | 254 | 1539 | 1550 | 99% | boot 10, core 11.6 + 10.5 (cargo) |
| android | 1345 | 323 | 1022 | 1200 | 85% | builds 36 + 22 + 70 + 33 |
| gates | 523 | 0 | 523 | 660 | 79% | |

Matrix wall 2278 s. Every leg of the five lanes passed; the matrix failed on
the windows DURATION ANOMALY and on android-quiet's capture-compose, the
emulator's audio input breaking at its open (docs/traps.md, the emulator's
audio input, "THE THIRD BREAK"; the bundle could not separate the causes, so
the recorder grew).

The windows lane's warm one-time phases on the matrix before (799e95ca,
pre-warmed) were build 5, deploy 34, package 17. A core change costs it about
270 s: the build compiles the core's dll (`Finished` in 2m 12s, release with
full debuginfo) and then relinks the 103 rust example executables, each
carrying the whole core statically (1m 22s, 1189 MB together), and the deploy
copies them (89 s against 34). On iOS the core's cold build is two cargo runs
of 11.6 and 10.5 s; its 1539 s against the warm 1475 s of 799e95ca is mostly
the admission and the pickers below, not the build.

## The ceilings

A lane over its ceiling or within 3% of it is set at about 1.05-1.08x over
the cold reading; the others keep theirs.

- windows 1900 -> 2200: 2063 s net, 1.07x.
- ios 1550 -> 1650: 1539 s net, 99% of the old ceiling; 1.07x.
- mac (93%), linux (85%), android (85%) and the gates (79%) keep 1250, 1250,
  1200 and 660.

## The pull: the largest wins left

### Windows

The suites took 1743 s: 19 pooled blocks, 477 legs, 981 s of wall for 3134
leg-seconds; 117 one-leg blocks, 742 s of wall for 590 leg-seconds.

1. **The core change's rebuild, about 270 s** (build 220 against 5, deploy 89
   against 34). Of the build, 82 s is relinking 103 example executables that
   each carry the whole core; the deploy's extra 55 s is the copy of what
   changed, of which those 1.19 GB are most of the bytes (the copy was not
   timed per file). What it would take: the rust examples link the core as
   kaya.dll (one artifact rebuilt and copied, 13 MB) or as one executable that
   picks its scene by name, and possibly `debug = "line-tables-only"` for this
   target's release profile. Measure the link and the copy before choosing; the
   ruling makes this the cheapest place to win back a cold matrix.
2. **The one-leg blocks, 742 s of wall for 590 leg-seconds.** The largest
   family is the number field: numberfield, numberfieldde and timecode, 18
   legs, 154 s of wall for 133 leg-seconds, alone because a neighbour's launch
   takes activation and the field commits (win.py; the 2026-10-16 probe showed
   that launching without activation does not make them poolable, since posted
   keys then never reach the field). What it would take: a `type` that reaches
   the field without OS focus, so the legs pool; about 120 s. The other 152 s
   is the one-leg blocks' own overhead (join, drain and the next launch, 1.3 s
   each over 117 blocks), which only fewer blocks would cut.
3. **The media legs run one or two at a time, 147 s of wall for 219
   leg-seconds** (media_delivery as three pairs, 96 s; media_tracks alone, 51
   s), under the maintainer's media-stall ruling of 2026-10-01. What it would
   take: the stall's cause found and fixed, then the twelve legs pooled; about
   100 s.

Not a win: the first pool (274 legs, 481 s of wall for 1685 leg-seconds, 3.5x
on six slots) was measured CPU-bound on the VM on 2026-10-09, and the camera
group inside it ends at +158 s, off its critical path.

### iOS

1. **The LocalStorage admission, 87 and 92 s** on two of the three simulators
   against 17 s on the third, before their first legs. What it would take:
   the admission's slow export read from its own trace to find what the two
   devices wait on; about 70 s per device, on the lane's critical path.
2. **The exclusive token's waits, 254 s**, netted out of the ceiling but on
   the lane's wall and the matrix's: references-swiftui alone waited 106 s,
   swift's first admit 46 s. What it would take: the order in which the
   lanes' exclusive blocks start, so iOS's picker legs do not queue behind the
   other lanes' drags.
3. **The picker family, 458 leg-seconds** (references 168, editor 118, save
   87, filedialog 85; editor-go alone 118 s, the provider settle and the
   document picker's press). What it would take: the provider settle's waits
   bounded by a signal rather than the idle wait, if the provider offers one;
   about 150 s spread over three simulators.

Nothing in this charge implements these; each is a change in kind that needs
its own measurement first.
