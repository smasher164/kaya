# Deferred work ledger

The running inventory of punted items. Check things off here as they
land; add new deferrals with enough context that a future contributor
(human or agent) can pick them up cold. DESIGN.md's open-questions
section is the architectural counterpart; this is the working list.
Landed history lives in git; this file only carries what is still open.
(Pruned 2026-07-23: the grow/spacing/align, dressed-floor, window,
scroll/nav breadth, matrix-speed, and backend-roster sagas landed and
moved to git history; their traps live in docs/traps.md.)

## BUILD — the flight recorder: one failure is enough evidence (Akhil, 2026-08-27)
KEY: flightrec, flight recorder, capture bundle, journal jsonl, XDG_STATE_HOME, KAYA_FLIGHTREC_DIR, KAYA_VERB_TRACE, vtrace, verb trace, foreground sampler, PrintWindow shot, flightrec-selftest

A leg that fails once and passes on the rerun leaves nothing behind but a
verdict, so the next sighting starts from zero — and the ghost families
(the file dialogs, the contended pickers) are exactly the ones that do
that. ONE FAILURE MUST BE ENOUGH EVIDENCE: every leg is journalled, and
every FAIL collects the state that was live at the time.

DEPTH LANDED 2026-08-27 — journal + windows + mac + the Rust verb trace.
RUNNER BREADTH CLOSED 2026-08-29: all five lanes journal and print a
terminal verdict, held by check-gates (refreshed 2026-08-31 — all six
runner scripts reference flightrec). WHAT KEEPS THIS ENTRY UNSTRUCK:
the two interpreter harnesses (KayaSwiftUI.swift, KayaCompose.kt)
still have no verb-trace ring, so a FAIL inside either interpreter's
own harness carries less state than a Rust-backend FAIL does.

WHAT LANDED
- THE JOURNAL, `tools/lib/flightrec.py` + `tools/lib/flightrec.sh`. JSONL
  under `${KAYA_FLIGHTREC_DIR:-${XDG_STATE_HOME:-~/.local/state}/kaya/flightrec}`:
  a run header (run id, all three tree ids from build-id.sh, host load,
  free disk, memory pressure) and a record per leg (lane, leg, verdict,
  duration, failure sentence, bundle path). Retention is newest N run
  directories (default 20), enforced at run start with the cap PRINTED;
  bundles live inside the run directory, so a bundle can never outlive its
  own journal record.
  THE LOCATION IS THE DESIGN DECISION, read against the storage-cleanup
  entry below: target/ (including target/validate-failures), the
  worktrees "and their targets", docker, the nix store and the /private/tmp
  scratchpads are all named by that sweep. A dot-dir under the repo root
  is the trap that looks safe — agents work inside `.claude/worktrees/<id>/`,
  so it resolves INSIDE a worktree the sweep deletes, `git clean -xdf`
  eats it, and it fragments one journal into one per checkout. The XDG
  state dir is named by no candidate, survives `rm -rf target`, and is one
  home per machine, which is what lets two lanes from two worktrees appear
  in one journal.
- MAC AT-FAIL CAPTURE, in `tools/validate-mac.sh`'s `run()` on all three
  of its paths. Seven sections: the per-leg sampler's history, `sample`
  of the live guest, the leg log, WindowServer CPU, the CGWindowList
  window list (`tools/mac/flightrec-winlist.swift`, built on demand to a
  content-hashed path), a screencapture of the guest's OWN window by id,
  and a bounded kaya-scoped `log show` slice.
- WINDOWS AT-FAIL CAPTURE, `tools/guest/flightrec.ps1` (+ `flightrec.cmd`
  and `run-hidden-args.vbs`, because `run-hidden.vbs` eats its second
  argument as KAYA_WIN_SLOT and cannot forward a leg name). A foreground
  sampler for the life of the leg, then a collect: visible windows, any
  live dialog's UIA tree, a bounded wevtutil slice, the filtered process
  list, and a PrintWindow shot. Wired at TWO sites — every FAIL, and
  run_one_suite's TIMEOUT path BEFORE `kill_guests`, which is the only
  moment a failing guest still has a window to photograph.
- THE VERB TRACE, `crates/kaya/src/vtrace.rs`: a 2048-record ring behind a
  const-constructible Mutex static, dumped to `KAYA_VERB_TRACE` on failure
  only, from both the failed verdict and the watchdog's wedge arm. It had
  to be a static and not a local because the watchdog thread exits the
  process itself. The file-dialog family, click, type, focus and the
  id-normalization search are instrumented; `poll_named` gives a retried
  observation its per-attempt records, which plain `poll` never kept.

WHY A SELF-TEST AND NOT A NUMBERED GATE. `tools/flightrec-selftest.sh` is
deliberately not named `check-*.sh`: check-gates' delegation clause forbids
validate-mac from invoking anything gate-shaped, its census would demand
registration in four places, and what needs proving is a RUNTIME property
of a host — that these capture commands answer here — which no static gate
can see. It cuts the REAL `run()` out of validate-mac by brace depth and
drives it with an always-failing leg. Six clauses, four watched
perturbations, and the tree's hashes compared before and after.

FOUR DEFECTS IT CAUGHT WHILE BEING BUILT, all in the recorder itself, and
each one a diagnostic that would have lied rather than gone quiet:
 1. `flightrec_start` captured the writer with `2>&1`. Stderr is unbuffered
    and stdout is not, so the retention sentence came out first and became
    the run id; every leg record was filed under a path made of it.
 2. The mac shot matched any window whose line contained "kaya" and
    PHOTOGRAPHED THE MAINTAINER'S EDITOR, whose window is titled after the
    repository — docs/traps.md's privacy leak arriving by a door the trap
    does not name. It is addressed by the guest's pid now.
 3. Giving the serial path a `tee` put tee in the leg's descendants, and a
    name-blocklist picked it as the guest: `sample` profiled TEE and the
    bundle recorded that as the guest's stack. Pid resolution is anchored
    on `timeout` now, and every sampler line carries the pid's own name.
 4. `GetClassNameW`/`GetWindowTextW` without `CharSet.Unicode` returned ONE
    CHARACTER per name, so `#32770` could never match, the UIA walk could
    never fire and the shot could never find its window — three sections
    that would have answered "nothing was there" forever. Beside it, a
    .ps1 with an em-dash in a string literal does not parse at all on the
    guest (PowerShell 5.1 reads the ANSI codepage and the mojibake carries
    a double quote); both are in docs/traps.md and clause N5 holds the
    second.

THE RECORDER'S FIRST MATRIX CAUGHT THE RECORDER (2026-08-27, and this is
the finding worth keeping). Every leg went green on all five lanes and the
journal worked — and the WINDOWS LANE TRIPPED ITS DURATION CEILING at 605s
against a 520s ceiling and a ~495s warm baseline. The every-leg signature,
and the per-leg hooks were the only work added: ~110s over 194 legs, about
0.55s each, ALL OF IT ON THE PASS PATH.

Measured on the VM rather than guessed, same ssh mux, quiescent, n=10:
`flightrec_win_leg_reset` 37ms, `sampler_start` (schtasks create+run)
155ms, `sampler_stop` 85ms, `flightrec_leg` (one python3 spawn) 27ms —
304ms of three ssh round trips plus a process, on every leg whether it
failed or not. 304ms quiescent against ~550ms observed is the expected
inflation at KAYA_WIN_JOBS=6 on oversubscribed vCPUs, which this lane's
own comments already record.

THE RULE IT COST US: AN OBSERVER MUST BE FREE WHEN NOTHING FAILS. The
diagnostics belong on the failure path, and anything the pass path pays is
multiplied by every leg on every lane forever. The fixes are all the same
shape — move the cost off the leg:
- The foreground sampler is ONE LANE-WIDE PROCESS, started once, writing a
  capped ring with guest-epoch timestamps; the failure path reads the
  leg's window out of it, using an offset read once at lane start. The
  foreground is a machine-wide property, so per-leg samplers were always
  the wrong unit.
- The journal SPOOLS. A leg appends one TAB-separated line with a bash
  `printf` builtin — no subprocess — and one python3 turns the spool into
  JSONL at lane end and again from the EXIT trap (the flush truncates, so
  the second call cannot double the records).
- Nothing bundle-shaped is created on the pass path; `flightrec_win_leg`
  returns after that one printf.
Re-measured, same method: the pass path is 0.130ms per leg (n=200), down
from 304ms, and the whole lane now pays ~509ms once (clock sync 336ms,
sampler start 123ms, flush of 200 records 50ms). One real windows suite,
five legs concurrent, alternating: hooks-off median 2605ms (spread
2515-4278), hooks-on median 2622ms (2616-2797) — the hooks-on runs sit
inside hooks-off's own spread, and they include that once-per-lane setup.
tools/flightrec-selftest.sh clause N6 is the wall: a PASSING leg must
scaffold no bundle, must still be journalled through the spool, must leave
the spool truncated, and `flightrec_leg`'s body may not name python3,
run_ssh, scp or mkdir. A lane ceiling noticed this once, after a whole
matrix; N6 notices in seconds.

WHAT IS OPEN
- BREADTH: linux (`tools/validate-linux.sh`), iOS (`tools/ios/run-sim.sh`)
  and Android (`tools/android/run-emulator.sh`) do not journal or capture.
  Android and iOS already dump some at-fail evidence into
  target/validate-failures; folding those into the bundle is the shape.
- THE INTERPRETER RINGS. Both re-implement the verbs and their
  `while retryStep` wrapper is a CHEAPER attempt point than Rust's, but a
  hand-copied diagnostic in three harnesses with no compile-time link is
  the drift class that let the ax observation sit spelled two ways for
  months. If they get it, one slice, with a check-verbs clause pinning the
  env var name, the failure-only rule and the line format.
- RETENTION IS PER-RUN-COUNT, not per-byte. A run whose every leg fails
  with a large bundle is bounded only by the section and bundle caps
  (2 MiB / 32 MiB, both printed). A byte ceiling across the whole home is
  the obvious next turn if this ever grows teeth.
- NOBODY RUNS THE SELF-TEST AUTOMATICALLY. It is standalone by choice (see
  above), so the standing wall is the bundle report's own printed counts
  on every failure. If that proves too quiet, the answer is a gate.

## ~~CHORE — storage cleanup: the host is nearing disk capacity (Akhil, 2026-08-27)~~
KEY: disk cleanup, target directory size, scratchpad growth, docker prune, nix store gc, validate-failures logs

CLOSED 2026-08-31 by ruling, both open halves resolved as deliberate
non-actions: NO NIX GC POLICY — the store measured 77G on a disk at
43% used (536G free of 927G), not pressing; revisit only if disk
pressure returns — and the standing tools/ cleanup recipe DECLINED;
cleanup stays ad hoc under this entry's own doctrine (measure first,
nothing cleared while a matrix runs). Measured at close: repo target/
29G (regrown since the sweep, normal), target-linux 6.7G,
.claude/worktrees gone, docker 18G images + 8.1G build cache with
kaya-linux (8.3G) kept, scratchpads 88M.

Akhil is nearing the disk's capacity, and last time the culprit was
temporary data in this project (the standing doctrine from the
2026-08-04 incident: when a disk fills, `du -sh` the session
scratchpad FIRST — a load-generating build loop once left a 516 GB
scratch target behind). Candidates to measure and clear, in suspicion
order: the repo's own `target/` (multi-GB debug tree plus four cross
targets; the artifact-reading gates link against it, so clearing it
costs one rebuild), stale `.claude/worktrees` and their targets (the
agent rounds trim theirs, but prune anyway), docker images and build
cache (one 2026-08-26 round reclaimed 3.4 GB with a prune), the nix
store (every `nix develop`/`nix run` accretes paths; `nix store gc`
with the generations policy decided first), android build outputs
(regrow ~1-3 GB per assemble), `target/validate-failures` logs, and
session scratchpads under /private/tmp. Measure BEFORE deleting and
record the numbers here; nothing is cleared while a matrix runs.
MEASURED 2026-08-27 (disk at 93%, 66G free of 927G): `.claude/
worktrees` 40G (stale ended-session worktrees — the per-round prunes
only ever removed the current session's), repo `target/` 54G (months
of accreted cross-target and incremental artifacts), docker 43.5G
with ~21G reclaimable (images 25.5G/11.6G, build cache 18G/9.4G),
haskell dist-newstyle 1.8G, android builds ~1.4G, failure logs and
scratchpads ~180M. Roughly 118G reclaimable, all regenerable build
output. The pass is HELD until the in-flight ax diagnosis lands: its
live worktree sits inside the prune target, its container depends on
the docker image, and a 100G deletion storm is background IO during
timed lane runs — the quiescent-machine rule applies to cleanup too.
SWEPT 2026-08-27 night, once the machine freed: 66G -> 168G free
(93% -> 82%): the stale worktrees (three old workflow runs among
them), target/ and target-linux, docker's 18G builder cache (the
kaya-linux image kept — the lane needs it), android and haskell
build dirs. Failure logs and the live scratchpad kept. The lane
ceilings tripped on the two runs after the sweep with a chosen,
recorded cause — cold caches refilling (linux 796s then 524s against
its 470s ceiling; windows 577s then 533s against 520s; every leg
green both runs) — and are expected back under their ceilings on the
next warm run; a THIRD consecutive anomaly is a real investigation,
not this note. The nix
store gc policy remains the open half; the standing cleanup recipe
remains the discussion half.
Worth discussing alongside: a standing `tools/` cleanup recipe so this
is a command, not an archaeology session, each time.

## ~~FIX — AddressSanitizer hangs pre-main under the dev shell's clang on this host (found 2026-08-26 by the KayaTx cap round; Akhil: research and fix, 2026-08-27)~~
KEY: asan darwin nix, compiler-rt sanitizer runtime, clang 21.1.8 hang, libc interceptors initialized, guard page probe

COMPLETE 2026-08-27, FIXED INSIDE NIX, no carve-out and no input bump.
Research first, as asked, and it answered every question the entry put:
nixpkgs' darwin compiler-rt is NOT broken (it builds and ships the
sanitizer runtimes; the exclusion is `isDarwinStatic`, not `isDarwin`).
The hang is an upstream compiler-rt self-deadlock against a macOS 26 dyld
change — ASan's own malloc interceptor re-enters a non-recursive init spin
lock through `dyld_shared_cache_iterate_text` -> `_Block_copy` -> malloc,
sampled frame by frame and matching llvm/llvm-project#200447 — so it is an
OS-side change every pre-2026 compiler-rt hits, Apple's clang included, and
not a nix-versus-Apple divergence. Measured on this host: llvm 18, 19, 20,
21.1.7 and 21.1.8 all hang; **22.1.8 works**, and its three fixes (#167797,
#182943, #191039) are on `release/22.x` and on no earlier branch, with
21.1.8 the last 21.x release. nixpkgs' `llvmPackages_22` already exists at
the rev flake.lock pins.

So flake.nix wires that compiler into the ONE dev shell under a name of its
own, `kaya-asan-clang` — not a second devShell (a gate that needs a
different `nix develop` is a guard someone has to remember) and not a
second `clang` on PATH (a PATH-ordering accident, where the loser hangs for
its whole ceiling instead of failing). `clang` still means 21.1.8 and
nothing kaya ships moved. The Xcode fallback the entry contemplated is real
— Apple clang 21.0.0 outside the shell works here — but was NOT taken and
needs no sign-off: it fixes nothing (the same bug reproduces on Xcode 26.3
and older, so it pins the fix to an unpinned host artifact) and the ABI
split between the two runtimes is total.

What it unblocks, live: tools/check-c-bounds.sh has an ASAN COMPANION MODE
beside the guard page — the same c-tx-cap probe on a plain malloc
(`heap`/`heap-many`), where the pre-cap header is a reported
heap-buffer-overflow naming the write and its size and this one writes
nothing. The guard page stays the PRIMARY (deterministic, byte-exact,
linux-runnable, and the mode that is not skippable); a host without the
compiler passes on it alone and PRINTS the skip, with self-test N5 cutting
that branch out of the gate and making it print on every run.

AND A TRAP THE FIX FOUND (docs/traps.md): a sanitizer build inside this
dev shell reports NOTHING unless the wrapper's hardening is off. `fortify`
and `fortify3` preempt ASan — an out-of-bounds store exited 0 with no
report, a memcpy one died of SIGTRAP with zero bytes, and the wrapper
appends its own `-D_FORTIFY_SOURCE` after your flags so no command-line
`-U`/`-D` undoes it. `asan_build` sets `NIX_HARDENING_ENABLE=""` and says
why. Wired naively, the companion would have been green and blind.

Measured (scratchpad txcap round, three ways): the dev shell's clang
21.1.8 compiles and links -fsanitize=address, but ANY sanitized
binary — a clean 8-byte malloc, a deliberate heap overflow — hangs
before main at 98% CPU, verbosity=1 stopping right after "libc
interceptors initialized", zero bytes of report. /usr/bin/clang inside
the shell resolves to the SAME nix wrapper, so Xcode's working ASan is
shadowed by the everything-inside-nix rule. Akhil is surprised the
runtime is broken and wants it FIXED, with research first: what state
is nixpkgs' darwin compiler-rt sanitizer support actually in (known
issues, whether another llvm major in nixpkgs works, interposition/
dyld interactions on current macOS), and only if nixpkgs is truly
broken does the fallback get considered — Xcode's clang passed through
the flake as a DECLARED exception scoped to sanitizer probes (a
carve-out, so it comes back for sign-off). What a fix unblocks: real
ASan negatives for C-floor guards and any future native-memory probe.
The guard-page technique from the txcap round stays either way — it is
deterministic where redzones are heuristic and runs on the linux lane.

## ~~DISCUSS — the shell-then-python two-step: why not python all the way down? (Akhil, 2026-08-27)~~
KEY: shell wrapper python census, gate script language, check-shell scope, dev-shell preamble

CLOSED 2026-08-27 BY RULING, same day, on the measured analysis
(shellpy-research.md, session scratchpad; the numbers that decided
it: gates already 53% python; one gate spending 21.7s spawning
47,877 greps beside its own 86ms python census; SIX drifted copies
of the dev-shell preamble; 76 duplicated heredoc helpers; ~292
watched negatives as the honest migration price). Three rulings:
(1) gates convert incrementally against an IMPORTED shared library,
an imported shared gate library under tools/lib (kaya_gate, built by phase 0) — never a launcher, so every gate stays
standalone-runnable; (2) ruff joins the flake in phase 0, paying
the one-time fingerprint move; (3) the RUNNERS STAY SHELL FOR NOW —
recorded as a present-tense boundary, NOT as never (Akhil,
verbatim in spirit: do not codify never-convert, we do not know
what the infra will look like) — python decides, shell launches,
revisit when the infra changes shape. The non-negotiable rider:
every converted gate's watched negatives are re-proven red on the
converted body before the old body is deleted. Phasing per the
analysis: the six zero-negative gates first.

PHASE 0 LANDED 2026-08-27 (the ruling stands as written; this is the
work, not a re-strike). tools/lib/kaya_gate.py is the imported prelude
— ROOT from `__file__`, the dev-shell fingerprint computed EXACTLY as
the shell preamble's `cat flake.nix flake.lock | shasum -a 256 |
cut -c1-12` and proven against that real pipeline in its own
self-test, the two causes back to two sentences (the drifted variant
printed ONE for both, an invariant-3 defect inside the block 81
scripts copy), plus doctor/perturb with the count printed and a
refusal at zero, a census floor, atexit scratch and negatives_ran.
Eight watched property groups, every refusal MADE TO PRINT. `ruff`
joined flake.nix from the PINNED nixpkgs (flake.lock unmoved), and
the fingerprint moved with it as ruled: 5061dae8d7b8 -> e232b0560910.
tools/check-python.sh is the new gate, 49th in the sweep, holding ten
rules ruff cannot plus ruff itself, and running the prelude's
negatives so the file every gate imports proves its refusals where
nobody can skip them. Eleven watched negatives.

THE SIX ARE CONVERTED — check-ledger, check-doc-refs, check-gates,
check-table-card, check-jni, check-universal-props — with the rider
honoured: each old body and its converted body were run BACK TO BACK
on the same tree and stdout, stderr and exit status compared. Eleven
of the twelve pass/fail comparisons are BYTE-IDENTICAL. The twelfth
is check-doc-refs' N6 self-test narration, which cites its own source
as its in-range line-anchor fixture and skips its own source in the
mortal-path clause: the body moved, so the sentence must name the
file that now holds it. No verdict, finding or exit status moved.

A CONVERTED GATE KEEPS ITS `.sh` NAME, as a two-line exec shim. The
research wanted no stub; the count that overrules it is ~50
path-shaped citations of these six `.sh` names in docs/probes,
docs/chrome, docs/traps.md, the plans and crates/kaya/src/jvm.rs, every
one of which check-doc-refs holds to a file that exists — a rename
falsifies recorded history or buries it under `(gone)`. The stub's
own risk (a second place for the preamble to drift) is closed by
check-python pinning its exact bytes, so it can never hold anything
but the exec. This also left gates.sh's GATES, check-gates' census
and both doctrine mirrors untouched by the conversion itself, so a
phase-0 mistake could not be a list mistake.

WHAT PHASE 1 OWES, recorded so it is not rediscovered: rule 6 (`re.subn`
only through the prelude) carries all five verbatim-converted bodies in
check-python's SUBN_EXEMPT, each with a reason and each required to name
a real file. That table SHRINKS — the next conversion is held to the
rule — and the clause stops needing a table the day it empties.

Akhil's framing, to discuss before anyone acts: lots of the project's
shell scripts do a little work and then launch python scripts — the
gate shape is typically a bash preamble (the dev-shell fingerprint
check, arg handling, the EXIT trap) around a python3 heredoc census
plus bash self-tests. Python can do all of it, and the move might buy
robustness and perf. Standing context for the discussion: the repo
already bans sed/awk in favor of python3 (BSD/GNU divergence measured
repeatedly), the zsh word-splitting trap cost a false all-green once,
and check-shell exists precisely because shell's $?/pipeline shapes
keep needing enforcement — all of which argues the shell surface is
maintained at cost. What the discussion must answer before a sweep:
where the dev-shell fingerprint preamble lives in a python world (a
shared prelude? a launcher?), what check-shell's role becomes, whether
gates.sh itself converts, how the self-test/watched-negative idiom and
EXIT-trap cleanup port, and whether the 47-gate sweep's per-process
overhead actually moves. Nothing converts until the shape is ruled.

## ~~GAP — Compose quotes the ax observation SwiftUI leaves bare (found 2026-08-26, by the ink-tolerance round)~~
KEY: ax observation quoting, image/Portfolio value, byte-compared verdict, canvas ax

CLOSED 2026-08-27, RULED QUOTED. There were THREE spellings to weigh,
not two: harness.rs — the GTK and WinUI path, and the norm the
interpreters follow — writes `ax {want:?}`, which is Rust Debug and
therefore quoted, so the majority and the harness agreed already and
KayaSwiftUI.swift was the lone minority. The bare form had no measured
reason behind it: it is the original mac depth slice (b560753) never
revisited, written in the same commit that gave harness.rs the quoted
one, and SwiftUI is not bare by convention either — the same file
quotes `section`, `title`, `alert` and `clipboard`. The quoted form was
already on the record in recorded lane verdicts
(docs/styling/typeface-gtk-arm.md:20, typeface-winui-arm.md:353,
docs/traps.md:3493), and the quotes are what make a placeholder answer
like `<not in the accessibility tree>` read as a VALUE rather than as
prose. So SwiftUI moved, on mac AND iOS.

`expect_ax_hint` carried the identical divergence and was swept with it
— the entry named only `ax`. The failure sentence moved too: it is the
same value one line over, and a harness whose PASS text quotes and
whose FAIL text does not is the same defect.

NO LANE COULD HAVE CAUGHT THIS. Every runner only greps the verdict for
`KAYA_SELFTEST: OK` and never diffs its text (validate-mac.sh:523,
run-emulator.sh, run-sim.sh, run-suites.sh), so the byte-compared-verdict
rule is doctrine that only a gate can hold. tools/check-verbs.sh got the
clause: a census reading each emitter out of its OWN ARM in all three
harnesses, flattening every interpolation to `<v>` so three languages
compare as one string, holding both the observation and the `wanted`
failure sentence at the ruled spelling. An arm it cannot read is a
finding that names it, never a skip — an earlier draft anchored on
`Step::ExpectAx(` alone matched harness.rs's PARSER first, found ZERO
observations there and agreed with everything. Five watched negatives,
counts printed, each scored against the real check's own findings.
No `.steps` file re-freezes: all 41 `expect_ax`/`expect_ax_hint` lines
are argument-side, already quoted by the scene grammar.

## ~~GAP — an empty a11y label had four semantics and only WinUI's aborted (found 2026-08-27 by the day batch's first matrix)~~
KEY: a11y-empty-label, A11yLabel empty, chart_summary, empty accessible name, winui cannot apply, pattern guard fall-through, A11yHint empty

CLOSED 2026-08-27, RULED REFUSED AT THE ROOT. The windows lane's
portfolio_python leg died with `kaya: draining a transaction: kaya:
winui cannot apply A11yLabel = Str("") here`, and the FINDER WAS THE
FLIGHT RECORDER's bundle for that leg — the entry at the top of this
file, on its first day carrying a real failure.

THE DECLARATION WAS `chart_summary = kaya.signal("")` filled by `set()`
one line later, so the INITIAL application delivered an empty label. All
four backends' comments claim the same intent, "empty means unset, and
unset stays untouched"; three implement it and one does not:
  - gtk.rs matches the arm unconditionally and tests emptiness INSIDE
    the body — silent no-op.
  - KayaSwiftUI.swift stores it and skips `.accessibilityLabel` when
    empty; the AX host writes nil. Silent no-op — WHICH IS WHY THE MAC
    LEG PASSED THREE TIMES.
  - KayaCompose.kt: `contentDescription = a11yLabel.ifEmpty { null }`.
    Silent no-op.
  - winui/mod.rs put the emptiness test in the PATTERN GUARD, so an
    empty label matched no arm and fell through to the match's
    catch-all `panic!`. The author wrote the comment for gtk's shape
    and the code for a fall-through.

TWO LAYERS, because the wall alone does not reach the whole failure:
 1. The guest declares the real text — `chart_summary_text(*value_series())`
    is computable at build time, which `draw_chart()` proves by
    recomputing the identical string from the identical series on the
    next line. The transient empty never existed for a reason.
 2. The ROOT refuses an empty a11y label at `check_prop_value`
    (crates/kaya/src/scene.rs), the one chokepoint all eight bindings
    reach, in a sentence naming the widget's kind. An empty accessible
    name is not a declaration; settling it once beats settling it four
    times differently (invariant 1).

CLEARING A LABEL that was set is a DIFFERENT ACT and has no spelling
today. If it is ever wanted it gets its own explicit one rather than
riding on `""` (DESIGN.md, Binding conventions).

WHY THE WINUI ARM WAS FIXED AND NOT DELETED as unreachable belt. The
root's wall sees `PropValue::Const` and `PropValue::Signal` — it does
NOT see `PropValue::Element`, the row-field carrier, because
scene.rs:3993 has no value to check at declare time and only checks the
nesting level. A label bound to a row field (`a11yrows` in all eight
languages, and the whole template zone) still arrives at the backend
with whatever the row holds. So winui's two arms moved to gtk's shape
— match unconditionally, test inside — and the row-data empty is now
the same no-op on all four backends instead of an abort on one.
`A11yHint` carried the IDENTICAL pattern-guard fall-through one line
down and was fixed with it; nothing declares an empty hint today, which
is precisely why it would have been found the way the label was, on a
lane, months from now.

THE CENSUS, run BEFORE the wall landed (146 a11y-label sites across all
8 bindings plus the C floor): ZERO literal empty labels anywhere in
`guests/`, and `portfolio.py`'s signal was the only declaration that
delivered one. Every `a11yrows` guest inserts non-empty notes, so no
lane was carrying a second instance of this class.

GUARDS: three core tests (`an_empty_a11y_label_dies_at_declare`,
`an_a11y_label_bound_to_an_empty_signal_dies_at_declare` — the shipped
shape — and a positive control `a_spoken_a11y_label_records_by_either_carrier`,
without which the two negatives would pass against a wall that refused
every label there is), plus a clause in the Python check family. That
clause is deliberately NOT a second refusal: `kaya_app_checks.py` never
enters the core, and `brand_accent`'s neighbouring comment already
ruled this shape ("the 24-bit rule is deliberately the ROOT's ... a
binding-local copy of a root wall was once the only wall in eight").
It checks instead that the empty label REACHES THE WIRE with an empty
length word — because the way this fix unravels silently is a binding
that gets helpful and drops the empty itself, leaving the root nothing
to refuse and every gate green.

## Next milestones (in rough priority order)

THE NAMED FORCING ARTIFACT WAS A **TEXT EDITOR** (Akhil, 2026-07-24),
chosen to resolve this ledger's admission policy: items "waiting for
an artifact" could not fire until one was named. IT SHIPPED 2026-08-10
(`47bd2ab`: guests/go/editor/editor.go + tools/scenes/editor.steps,
legs on all five lanes; design record docs/editor-plan.md, toolbar
follow-on docs/chrome-plan.md). Everything it was chosen to force
landed — file dialogs, clipboard, the edit roles, undo/redo,
dirty-state titles, text ranges and find — and the struck bullets
below are that record. The forcing framing is DISCHARGED: no open item
below waits on "the editor" as its trigger; each open bullet names its
own trigger (the bookmark/persistence bullet's RECENT FILES trigger,
docs/editor-plan.md §3, is now one the shipped editor can fire).
The SECOND forcing artifact was the PORTFOLIO (guests/python/
portfolio.py), which drove tables, canvas, adaptive layout and the
grouped iOS tier through 2026-08-30. The section remains the roadmap
list, in rough priority order; chat / todo / media stay unpicked.

- ~~**Clipboard**~~ — COMPLETE 2026-08-04: all five backends, all
  eight bindings, every lane green in the full matrix (mac 232, linux
  426, windows 145, ios 46, android 50; three consecutive ALL PASS
  runs plus a confirming exit-0). The measured record is
  docs/clipboard-plan.md §0-§9; the fan-out's defect harvest (most of
  it pre-existing) is in docs/traps.md and this file's checked-off
  entries. Editor prerequisites remaining after this: undo/redo,
  dirty-state window titles, find.

- ~~**Saving a file**~~ — CLOSED 2026-08-19 on this entry's own terms:
  every piece of scope below is struck, the last of it (the three `Stage`
  default bodies) in `cbf6476`. What survives are the two RECORDED
  DEFERRALS at the end, each with its own trigger and its own reason —
  the save-over-an-existing-file path, and `filters` — not pending work.
  The body below is the record. As filed, IN FLIGHT 2026-08-09. The
  design is ratified and
  written down: docs/save-plan.md D1-D5, off five probe reports. One new
  request record (`show_save_dialog { window, dialog, suggested_name,
  filters }`) answering on the PICKER'S result grammar with one locator,
  and one decision with semantics in it: a save result registers a source
  whose open CREATES, so "open the destination for write" yields an empty
  file on all five platforms — Android and iOS hand back a document that
  exists, macOS/GTK/Windows hand back a name for a file nobody has made
  (measured; macOS does not truncate on Replace either). A fourth
  `FILE_MODE_CREATE` is the named rejection: creation belongs to the
  destination the dialog promised, not to the caller's intent. DEPTH
  LANDED: spec + the core's `SaveDestination` + the Rust surface
  (`tx.save_file(name)`, `msgs.on_saved`) + the SwiftUI mac arm + the
  `save` scene. BREADTH LANDED 2026-08-10 (`67d14f0`): the two remaining
  backend arms, the seven other bindings and their guests, and the
  file-mode gate — the struck bullets below. What survives:
  - ~~**DEPTH STUB: save on swiftui/ios**~~ — LANDED 2026-08-09.
    `UIDocumentPickerViewController(forExporting:asCopy:)`, whose every
    initializer takes a URL that ALREADY EXISTS, so the backend stages a
    ZERO-BYTE file carrying the suggested name and exports that — the
    emptiness is D1 itself, since the export copies what it is given and
    that is what an untouched destination would read back. The answer
    arrives through the picker's own `didPickDocumentsAt` delegate, so
    there is no new result path; the destination is retained as an
    ordinary picked URL and redeemed through `kaya_swiftui_open_picked`.
    D4's text entry landed as four simdrive verbs
    (`savestate`/`savename`/`savepress`/`savecancel`): the name is set
    and READ BACK over accessibility, and `savepress` matches the
    navigation strip's `Save` EXACTLY because `press Save` falsely
    succeeds on this sheet — it matches the static text "Save as" by
    containment and the sheet stays up. `save-swiftui` runs in
    tools/ios/run-sim.sh.
  - ~~**DEPTH STUB: save on gtk**~~ — LANDED 2026-08-09.
    `gtk::FileDialog` asked to `save()` rather than `open()`, so the live
    slot, the retire path, the result occurrence, the armed directory and
    the DISMISSED-to-empty cancel are all the picker's already; the two
    differences are `set_initial_name` and registering the answer as
    `protocol::SaveDestination` rather than `PathSource`. The three
    `Stage` methods read and drive the real panel over the AT-SPI walk
    the picker already uses, telling the two dialogs apart by the
    `EditableText` name field the save panel alone publishes.
    `save-rust` runs on both protocols in tools/linux/run-suites.sh.
  - ~~**DEPTH STUB: save on winui**~~ — LANDED 2026-08-10.
    `IFileSaveDialog` (NOT
    `FileSavePicker`, whose start location is an enum and which needs an
    owner HWND unpackaged), driven through the UIA machinery deploy-win
    already has; `save` is in deploy-win's SCENES and `run_suite
    save_rust` is a live leg.
  - ~~**DEPTH STUB: save on compose**~~ — LANDED 2026-08-10.
    `ACTION_CREATE_DOCUMENT`, which
    hands back a content locator to a document that ALREADY EXISTS, so
    the core's create is a no-op there and the uniform behaviour is free;
    `run_apk save-compose` is a live leg.
  - ~~**The seven other bindings**~~ — LANDED 2026-08-10: the save request
    and its result in
    Python, Go, C#, Java, Swift, OCaml, Haskell, plus the C floor's
    explicit spelling, each with its own `save` guest.
  - ~~**Java's picked handle is read-only in every mode, on every
    platform**~~ — FIXED 2026-08-10 in this milestone's breadth per
    docs/save-plan.md D3: `bindings/java/dev/kaya/KayaApp.java` now opens
    a `FileOutputStream` for write and both streams for read-write. As
    found by the save probes, it returned a `FileInputStream` whatever
    the mode, so a Java app could not write to a picked file anywhere.
  - ~~**The Swift interpreter matches file-mode NUMBERS as bare
    literals**~~ — GUARDED 2026-08-10 by `tools/check-file-modes.sh`,
    which reads the number `swift/KayaSwiftUI.swift`'s opener RECEIVES
    against the spec's own and censuses every other site that decodes
    one. D3 asked for exactly this gate.
  - **The save-over-an-existing-file path is undriven.** macOS answers a
    Save onto an existing name with a SECOND, UNNAMED `AXSheet` whose
    buttons carry stable identifiers (`action-button-1` = Replace,
    `action-button-2` = Cancel) and localized titles; the completion does
    not fire until one is pressed. The shared scene cannot drive it,
    because Android's `ACTION_CREATE_DOCUMENT` and iOS's export never
    prompt at all — they rename to `name (1)` — so a `file_save replace`
    step would be unsatisfiable on two of five platforms. If it is ever
    wanted it is a mac/linux/windows-only leg, not a line in
    `save.steps`. Measurements: docs/probes/save-probe-mac.md.
  - **`filters` on a save request is exercised at the wire level only.**
    The `save` scene sends none, deliberately: with `allowedContentTypes`
    set, NSSavePanel appends the first allowed extension to a name that
    has none and publishes the STEM in its name field when the user's
    Finder preference hides extensions — a machine-wide setting deciding
    a byte-frozen assertion. A scene that wants filters must name files
    whose extension is already in the filter.
  - ~~**THE THREE SAVE `Stage` METHODS STILL CARRY DEFAULT BODIES**~~ —
    DONE 2026-08-17 in `cbf6476`. `save_dialog_state`, `set_save_name`
    and `confirm_save` now end in `;` (crates/kaya/src/harness.rs:877,
    :881, :884), so a backend that forgets one fails to COMPILE like
    every other observation, and tools/lib/stage-coverage.py — whose
    REQUIRED regex is exactly a signature ending in `;` — holds all
    three for GTK and WinUI the way the entry asked.

- **No bookmark/persistence machinery: a picked file cannot be reopened
  across restarts** (deferred by docs/save-plan.md §3, which said
  "ledger it"; written down here 2026-08-17, which is when someone
  checked and found the line missing). kaya hands the guest a HANDLE
  for a file the user chose and the handle dies with the process:
  nothing in the vocabulary stores a durable reference an app can
  redeem on its next launch without showing a picker again. The
  platforms all have the machinery, in THREE different spellings, and
  that is most of the work — macOS security-scoped bookmarks, iOS a
  PLAIN bookmark (the scope flag is `API_UNAVAILABLE(ios)`, the trap
  docs/file-dialogs-plan.md recorded), Android a persistable URI
  permission taken against the resolver, and on GTK and Windows the
  path itself, which is exactly why a path cannot be the uniform form.
  TRIGGER: an app that wants RECENT FILES. docs/editor-plan.md §3 names
  it as the editor's own first cut, so the trigger is one artifact away
  rather than hypothetical. What this is NOT, both refused on their own
  reasons in the same §3: a filesystem API for guests, and a directory
  picker.
  KEY: bookmark, persistence, security-scoped, persistable URI, recent
  files, reopen across restarts

- ~~**Dirty state**~~ — LANDED 2026-08-06, and CLOSED on this entry's own
  terms: all four backend arms are struck below, the window prop has its
  sugar spelling in all eight bindings, `dirty` has a guest in each of
  the nine (the C floor included), and the scene graduated out of
  DEPTH_SCENES into SCENES. The body below is the record. As filed,
  IN FLIGHT 2026-08-06. The design is ratified and
  written down: docs/dirty-plan.md D1-D6, off five probe reports. One
  `dirty` bool beside `title` and `veto_close`; the app declares state
  and each backend spells its own chrome (the close-button dot on
  macOS, a leading `*` in the rendered caption on Windows, a bullet in
  the GTK header bar, nothing on the phones, which have none). The
  title string is untouched everywhere — Qt's `[*]` template is the
  named rejection. It arms nothing: the "unsaved changes, close
  anyway?" flow stays composed from `veto_close` plus the dialog
  machinery. DEPTH LANDED: spec + Rust surface + the SwiftUI mac arm +
  the `dirty` scene. What is still open, each held by a gate that is
  RED BY DESIGN until it lands:
  - ~~**DEPTH STUB: dirty on gtk** — the GTK arm (a bullet label beside
    the header-bar title, the living GNOME convention) and its AT-SPI
    read. `Stage::window_dirty` refuses loudly meanwhile; the linux
    runner wires no `dirty` legs.~~ LANDED 2026-08-06: every kaya window
    now carries the marker in its header bar (GNOME Text Editor's
    CenterBox shape, so the title does not move when the mark goes up),
    with an accessible label that is what makes it readable at all;
    `Stage::window_dirty` walks AT-SPI for that node inside the frame
    the window publishes, and reports UNREADABLE as its own failure
    rather than as `false`. The linux runner wires the scene for every
    guest this lane carries — the seven non-Swift bindings plus the C
    floor — on both protocols, each through `a11y-leg.sh`, which is what
    makes GTK publish a tree at all.
  - ~~**DEPTH STUB: dirty on winui** — the WinUI arm (a leading `*`
    composed into the rendered caption, the measured Notepad
    convention) and its caption read. Same shape; the windows runner
    wires no `dirty` legs.~~ LANDED 2026-08-06: the marker composes in
    `refresh_caption`, the one caption writer this backend now has
    (five `SetTitle` sites collapsed into it, and `deploy-win.sh`
    refuses a sixth); `Stage::window_dirty` reads the real OS caption;
    `run_suite dirty_rust` is a live leg.
  - ~~**DEPTH STUB: dirty on compose**~~ — LANDED 2026-08-06. All four
    interpreter layers in KayaCompose.kt (constant, apply arm, model
    field, verb arm); the lowering is deliberately EMPTY, which is D4,
    and `expect_dirty` reads the applied prop back — watched failing
    with the apply arm dropping the value, and again with a lowering
    that sets but never clears. The chrome-close tail is answered the
    way the iOS lane answered it, on purpose: `dirty-compose` runs the
    shared scene's phone-expressible PREFIX (the mark up, down on save,
    up again), cut at `close_window` and guarded on the `expect_dirty`
    verb, with the declined steps printed. One android-only claim rides
    on top — `expect_title "dirty"` while the mark is UP, which is the
    observable form of "no chrome" and fails the moment anything
    composes a marker into the task label.
  - ~~**DEPTH STUB: dirty on swiftui/ios**~~ — LANDED 2026-08-06.
    `expect_dirty` reads the applied prop back off the window model
    (D5's iOS row); the lowering stays empty, which is D4. The question
    this entry held open — the scene drives a chrome CLOSE, which no
    phone has — was answered with NEITHER of the two options it named:
    not an all-or-nothing carve-out (D4's arm would then be applied and
    asserted by nobody) and not a sibling scene (every runner would owe
    it legs, a cross-lane obligation minted mid-fan-out). The iOS leg
    runs the shared scene's PHONE-EXPRESSIBLE PREFIX — everything above
    `close_window`, which is the mark going up, coming down on save,
    and going up again — with the cut declared by VERB and guarded
    both ways in tools/ios/run-sim.sh. The Compose arm faces the same
    tail and can lift the same shape; if it does, the two belong in one
    helper rather than two spellings.
  - ~~The seven other bindings' sugar spelling of the window prop
    (check-sugar-surface's window-prop sweep holds it open) and the
    scene's guests, at which point `dirty` graduates out of
    DEPTH_SCENES.~~ — DONE: all eight bindings spell the prop, all nine
    guests exist, and `dirty` is in validate-mac's SCENES.

- ~~**Text ranges**~~ — CLOSED 2026-08-19 on this entry's own terms, as
  the struck bullet below already said: all four backend arms landed, all
  eight bindings carry the three primitives, the nine guests exist and
  `ranges` is in validate-mac's SCENES. What survives is what that bullet
  names — the three unstruck bullets below (the iOS composition guard no
  leg can fail for, the windows highlight read that is not the
  accessibility tree, and the IME-composition sweep GTK/WinUI/Compose
  still owe) plus the ASCII constraint, which is a recorded constraint
  and not pending work. The body below is the record. As filed,
  IN FLIGHT 2026-08-06. The design is ratified
  (docs/ranges-plan.md D1-D6) off five probe reports and a units
  ruling: three primitives on the TEXTAREA — `highlight_ranges` (a
  declared set), `select_range` (one range) and `reveal_range` (scroll
  into view) — app-declared in UTF-8 byte offsets, validated at one
  core chokepoint, converted to each backend's own unit before
  lowering, and NEVER tracked across an edit. kaya ships no find
  engine, find bar or regex dialect: those belong to the editor, which
  is what this unblocks. DEPTH LANDED: spec + core + Rust surface + the
  SwiftUI **mac** arm + the `ranges` scene, with every negative test
  watched failing. What is still open, each held by a gate that is RED
  BY DESIGN until it lands:
  - ~~**DEPTH STUB: ranges on gtk**~~ — LANDED 2026-08-06. `GtkTextTag`
    for the highlight, `gtk_text_buffer_select_range` for the selection,
    and `scroll_to_mark` (not `scroll_to_iter`: GTK computes line
    heights on an idle and documents the mark form as the one that
    finishes after line validation) through the GtkScrolledWindow the
    textarea foundation gave it. Both linux-only obligations met and
    both watched failing: offsets lower in CODE POINTS, and the CRLF
    correction is now in all three lowerings and in the reads, since the
    buffer keeps a `\r` that `lf()` never showed the guest. The reads
    are AT-SPI (attribute runs, `GetSelection`, `GetRangeExtents` against
    the node's own extents). `compose` needed an input method, because
    GTK has no other way to make marked text: kaya registers a
    `GtkIMContext` on GTK's own `gtk-im-module` extension point, at the
    lowest priority so it is only ever reached by name.
  - ~~**DEPTH STUB: ranges on winui**~~ — LANDED 2026-08-06. The WinUI
    arm on the RichEditBox the foundation switched to:
    `CharacterFormat.BackgroundColor` over `ITextRange` for the set,
    `Selection.SetRange` for the selection, `ScrollIntoView` for reveal,
    all three batched behind `BatchDisplayUpdates`. The planned readback
    was not available: **WinUI publishes no Text pattern on an
    in-process automation peer**, so `GetAttributeValue(BackgroundColor)`
    / `GetSelection` / `GetVisibleRanges` have no provider to answer them
    in this process (`RichEditBoxAutomationPeer` declares one interface
    in the SDK metadata where `ButtonAutomationPeer` declares
    `IInvokeProvider` beside its own, and live reflection agrees), and
    the only route that does publish them is an out-of-process UIA
    CLIENT — the file-dialog era's crash class, barred at the
    Cargo.toml. The reads therefore go one layer down, to Rich Edit's
    own document model: a per-character background scan for the set,
    `Selection.StartPosition/EndPosition` for the selection, and
    `ITextRange::GetRect(ClientCoordinates|AllowOffClient)` against the
    control's own bounds for the viewport. **This is the one lane whose
    highlight assertion does not go through the accessibility tree**,
    and closing that gap needs either a WinUI peer that publishes the
    pattern or a sanctioned way to run a UIA client here; recorded
    below as its own item.
  - ~~**DEPTH STUB: ranges on compose**~~ — LANDED 2026-08-06. Not by
    the route this entry guessed: `BasicTextField(state=)` has NO
    styling hook at kaya's pins (compile-proven — no
    `visualTransformation`, `OutputTransformation` can only edit text,
    `TextHighlightType` is internal and means stylus preview), and the
    `AnnotatedString` route COMPILES CLEAN, stores a plain String and
    paints nothing. The arm draws the ranges instead, onto the
    platform's own `TextLayoutResult.getPathForRange`, inside the
    field's decorator; the selection is `TextFieldState.edit {}` with
    D4's refusal asking `TextFieldState.composition`; reveal computes
    from the field's own layout and drives its own `ScrollState`. The
    textarea gained a bounded viewport in the process (Compose's was
    the one backend whose textarea GREW, so reveal had nothing to
    scroll). The surrogate-pair question this entry raised is answered
    on the READ side, where the only offset arithmetic lives: a
    `substring` across a pair yields a lone surrogate that UTF-8
    encodes as a single `?`, so both conversions refuse a split
    endpoint rather than rounding.
  - ~~**DEPTH STUB: ranges on swiftui/ios**~~ — LANDED 2026-08-06. The
    iOS half of KayaSwiftUI.swift, on the `UITextView` the textarea
    foundation gave it: `NSTextStorage`'s `.backgroundColor` for the set
    (the mac arm's mechanism, chosen over TextKit 2 rendering attributes
    because those paint NOTHING until someone calls `setNeedsDisplay()`
    and nothing on the SwiftUI update path does — green harness, blank
    screen), `selectedRange` for the selection, and
    `scrollRangeToVisible` wrapped in `performWithoutAnimation` for
    reveal, which is ANIMATED on this platform and reads as a no-op at
    the call site. The reads are the live control's storage, selection
    and `textViewportLayoutController.viewportRange` — the iOS sibling of
    the `AXVisibleCharacterRange` mac reads. The two NOT-MEASURED
    questions are answered: `UITextView.selectedRange` does NOT snap
    (both endpoints kept verbatim, unlike AppKit, which snaps the start)
    and CLAMPS an out-of-range selection to a caret at the end; and
    `UITextInput.offset(from:to:)` counts UTF-16 code units, as does
    `NSTextContentManager.offset(from:to:)`, so there is no second unit
    inside the file.
  - **DEFERRED — one iOS guard has no leg that can fail for it.** The
    text push refuses to run while `markedTextRange` is non-nil, and the
    destruction it prevents is measured on the platform (a programmatic
    `view.text =` during a composition drops the marked text and fires no
    delegate callback at all). The `ranges` scene cannot falsify it:
    UITextView NOTIFIES its delegate for marked text, so kaya's model
    never lags the view during a composition kaya provoked and the
    guard's condition is never reached — removing it leaves the leg
    green, watched. Making it a leg needs a scene in which the APP writes
    text while the user is composing, which is a cross-lane obligation
    rather than one backend's.
  - **DEFERRED — the windows highlight read is not the accessibility
    tree.** Every other lane asserts its decorated ranges through the
    surface an assistive client sees (mac's `AXAttributedStringForRange`,
    linux's AT-SPI text attributes); windows asserts them through Rich
    Edit's own document model, because WinUI's in-process automation
    peer for a text control publishes no Text pattern at all (measured
    twice — SDK metadata and live reflection). The consequence is
    narrow and worth stating: the windows lane proves the platform is
    RENDERING the decoration, not that a screen reader can HEAR it. The
    exits are a WinUI peer that hands out `ITextProvider` (nothing kaya
    controls) or a sanctioned out-of-process UIA client for this one
    read, which needs the file-dialog fatality re-measured with a client
    attached before anyone relies on it.
  - **A SWEEP ITEM EVERY BACKEND OWES, measured on mac and open
    everywhere else**: does a programmatic text write during an IME
    composition destroy the composition? On macOS it did, silently, and
    told the app the user had typed nothing — `setMarkedText` notifies
    no delegate, so kaya's model never learns a composition is running
    and the next update pass assigns over it. Fixed on mac by not
    pushing while `hasMarkedText()`. **UIKit: ANSWERED 2026-08-06, same
    verdict, different precondition** — a programmatic write during a
    composition drops the marked text and fires no delegate callback, so
    the same guard is in force on iOS; but `setMarkedText` DOES notify
    the delegate there, so kaya's model never silently lags the view and
    the mac defect's own mechanism does not arise. The question has still
    not been put to GTK, WinUI or Compose, and the answer must be
    MEASURED rather than inherited.
  - ~~The seven other bindings' sugar (`highlight_ranges`,
    `select_range`, `reveal_range`, and `set_text`, which this
    milestone added as sugar over the generic prop setter so an app can
    open a document into an editor) plus the C floor, at which point
    `ranges` graduates out of DEPTH_SCENES.~~ — DONE: all eight bindings
    carry the three primitives, the nine guests exist, the Compose
    interpreter has the verbs and constants check-verbs held open, and
    `ranges` is in validate-mac's SCENES. What is still open on this
    entry is the three DEFERRED bullets above, not the surface.
  - **The scene is pure ASCII and that is a constraint, not a
    preference.** A `.steps` file travels through three step
    interpreters, a shell and an environment variable, and only the
    Rust reader is proven to decode it as UTF-8 (`check-steps`'s own
    python lint opens it with the LOCALE's encoding). The unit
    assertion is bought instead by putting a CJK word in the GUEST's
    source, which every language's compiler guarantees is UTF-8, so
    every match sits six bytes further along than it sits in UTF-16.
    Proving the `.steps` path end to end is its own piece of work
    (docs/ranges-units.md §8.7 asked for it) and belongs where it
    can be proven on all five lanes.

- **Text ranges are deferred on the ENTRY widget** (deferred by
  docs/ranges-plan.md D1, which promised "Deferral is recorded in
  docs/deferred.md with the three measured reasons, not silently";
  written down here 2026-08-17, when someone checked and found no such
  line). `highlight_ranges`, `select_range` and `reveal_range` are
  TEXTAREA-only in the spec, and the sweep behind that (invariant 2's,
  from the plan's five probe reports) gave three reasons, all measured:
  - **linux — can't honestly.** An entry's highlight rides ABSOLUTE
    byte offsets that do not follow edits, and neither reveal nor any
    geometry is observable over AT-SPI, so a GTK arm could be written
    but never asserted.
  - **ios — can't fully.** The entry has three distinct gaps at the
    iOS floor (the iOS probe's §entry), where all three primitives were
    affordable on the TEXTAREA through public UIKit API.
  - **no consumer.** The editor — the named forcing artifact, and the
    reason ranges exist — is a textarea. Nothing has asked.
  TRIGGER: an artifact whose decoration lives in a single-line field
  (validation marking, find-as-you-type in a search box). It arrives
  with per-platform verdicts already taken, so the work is the linux
  and iOS answers, not the design.
  KEY: entry ranges, entry-widget deferral, highlight_ranges,
  select_range, reveal_range, weak sibling

- **DEFERRED — wayland lane session architecture (researched
  2026-08-03, no trigger yet).** The GTK clipboard work pinned two
  session-level constraints and researched their exits
  (docs/clipboard-plan.md §5b, "researched escapes", has the detail
  and the source-level citations):
  - A persistent seat keyboard and pooled focus assertions are
    mutually exclusive (keyboard focus is per-seat-exclusive; a
    session holder broke three legs the day it was tried).
  - GDK pins `gdk_display_get_clipboard` to the FIRST seat, so
    multi-seat can solve FOCUS exclusivity (with a ~20-line wtype
    seat flag or a vendored micro-client, plus swaymsg per-seat
    focus steering) but can NEVER partition clipboards between GDK
    apps in one session.
  THE EXIT THAT COVERS EVERYTHING: per-leg sway instances — measured
  55ms to socket, the same cost class as the per-leg Xvfb the x11
  half already uses. One session per leg dissolves focus
  exclusivity, makes session keyboards safe, and gives each leg a
  private clipboard (the wayland clipboard legs could then
  unserialise). TRIGGERS: the first feature needing a persistent
  seat keyboard (IME, key repeat, compositor-level shortcut
  injection), or wayland lane time budget pressure from the
  serialised clipboard block. Do it as its own slice — it is a
  compositor-session change, and §0e records what the last one cost
  to re-prove.

  The original entry follows, for the reasoning it carries.

- ~~**Clipboard** — the next editor prerequisite~~ — COMPLETE 2026-08-04;
  this is the ORIGINAL entry, kept for the design reasoning it carries
  and struck where the wayland carve-out above left it unstruck. The
  closing record is the struck Clipboard entry at the top of this file.
  As filed, it was the prerequisite that
  unblocked the most: the edit roles (cut/copy/paste) are inert without
  it, while undo/redo, find and dirty-state titles do not depend on it.
  THE DESIGN IS WRITTEN: docs/clipboard-plan.md §0, with the reasoning
  and, for each decision that replaced an earlier answer, the answer it
  replaced. Four things worth knowing before opening it:
  - the clipboard is ONE CLIP IN SEVERAL REPRESENTATIONS on all six
    targets, so a text-only surface is a misstatement of it rather than
    a simplification;
  - COPY TAKES A RECORD AND PASTE RETURNS A SUM (you offer many, you
    receive one), which makes "at most one per kind" structural instead
    of a runtime check;
  - ACCEPTANCE IS PER-WIDGET, not app-global, because whether Paste is
    live is the intersection of what the clipboard offers and what the
    focused target accepts — which is exactly what the platforms
    already ask the focused responder;
  - files on the clipboard ARE the file-dialog capability, so a picked
    file goes straight on and a pasted one opens with the call that
    already exists.
  Four probes stood between the plan and any code (§0d); all four have
  reported, and §0e/§1b record what they found — including the two
  assumptions they overturned (Weston has no clipboard at all, and
  macOS does not prompt).
- ~~**GAP — the stall diagnostic DESIGN promises is not implemented.**~~
  CLOSED 2026-07-31 (`stall.rs`, `expect_stall` in all three interpreters,
  the scene, matrix 841; negatives watched) — the body below is the record.
  As found:
  DESIGN's threading section says it comes free from the transport:
  "the core reads the app's log-consumer cursor, and undrained for N
  seconds is the health signal". Nothing in crates/ reads that cursor,
  so today an app thread stuck inside a handler is INVISIBLE — the
  window keeps drawing while input silently stops.
  WHAT MAKES IT WORTH BUILDING (2026-07-28): the background sweep found
  Haskell's release using `putMVar`, which BLOCKS when the MVar is
  full, so a second click would have blocked the app thread forever.
  The scene clicks once, so no gate saw it; Akhil found it by asking
  whether Go's `close` blocks. That is the general class — a handler
  that blocks — and it has no gate at all. The stall signal IS that
  gate, and it would also catch the misuse the file-dialog design
  explicitly permits (a guest calling the blocking open on the app
  thread), turning "the app looks alive and ignores you" into a
  reported fault. Wire it into the harness so a scene FAILS on a stall
  rather than timing out.
  DEPTH SLICE LANDED 2026-07-31: crates/kaya/src/stall.rs, the
  `expect_stall` verb in all three interpreters, the `stall` scene, and
  the Rust guest on mac + linux + windows. Matrix ALL PASS at 841 legs.
  THREE THINGS THE SLICE TAUGHT, all of which cost a lane run each:
  - **The cursor is not the signal, the COUNTERS are.** DESIGN says the
    core reads the app's consumer cursor, and the occurrence ring has
    one — but the ring is only ONE of two transports. The Rust binding's
    own path is an mpsc channel (lib.rs sets `OccSink::Mpsc`), so on mac
    and iOS nothing ever moves a ring cursor and the first watchdog
    reported "keeping up" about an app that was provably asleep. Two
    counters (enqueued, taken) say the same thing about either.
  - **Nothing may start from an entry point.** It was started from
    `kaya_run`, which is one of three entries — `kaya::run` reaches
    `swiftui_host::run` and `backend::run_core` directly. Every Rust
    guest on every platform ran with no watchdog. It now starts itself
    from the first enqueue, which no path can avoid.
  - **A stall needs PENDING work to be visible, and that is correct.**
    The consumer cursor advances before a record reaches the guest, so a
    handler blocking on an empty ring is indistinguishable from an idle
    app — and nothing is waiting on it, so it may as well be. The scene
    therefore clicks twice, which is also what a person does.
  BREADTH SWEEP COMPLETE 2026-08-01. All eight guest languages, every
  runner: mac (8 languages), linux (7), windows (5), iOS (rust + swift),
  android (compose + jvm). `stall` graduated out of DEPTH_SCENES on all
  three desktop runners. Matrix ALL PASS at 868 legs, green on the first
  try — the watchdog being core-side meant the sweep was guests and
  runner wiring only, with no backend arm anywhere.
  WHY EVERY LANGUAGE AND NOT JUST RUST: the misuse is available in all
  of them, and it is the one discipline no gate enforced — each guest's
  "do the blocking work on a worker" comment was honour-system until
  this scene existed. A diagnostic that only fired for Rust guests would
  have left seven bindings exactly as blind as before. Each leg is also
  self-verifying: a guest whose block does not block reports no stall
  and FAILS, so a passing leg is evidence that language really did wedge
  its app thread and that kaya really did notice.
  AND THE NEVER-RECOVERS HALF, added the same day: a third button whose
  handler never returns, asserted LAST because nothing can follow it. A
  handler that blocks for 2.5 seconds is a SLOW handler, and every
  assertion in the first half would also pass for one; a real deadlock
  does not politely end. Two findings from it:
  - **The verdict has to be final.** `finish` prints the verdict and
    asks the MAIN thread for an orderly exit, which is what normally
    ends the process. But an app thread that never returns cannot take
    part in shutdown — the cleanup would have to run on the thread that
    is gone — and five of the eight bindings then hung at exit waiting
    for it (python, go, csharp, ocaml, haskell; rust and java exited
    fine). Every assertion passed and the legs still burned their whole
    180-second timeout. No framework can fix that: there is nowhere
    left to run the cleanup. The harness now waits a grace period after
    `finish` and then leaves under its own verdict, so the normal path
    still wins everywhere it works.
  - **The settle before the second stall is load-bearing.** The
    watchdog clears its reading when the queue drains and polls at
    100ms, so without a pause the second assertion could be satisfied
    by the FIRST stall's leftover reading. Negative-tested: with the
    wedge made a no-op the leg fails, so it cannot pass on the stale
    value.
  ONE CHARACTERISTIC WORTH KNOWING, seen 2026-08-02: the watchdog fired
  inside `commands_csharp` on the windows lane, which has nothing to do
  with stalls. The leg passed 3/3 when run alone and failed under the
  4-wide pool, so the app thread was STARVED by contention rather than
  blocked in a handler — and from outside those look identical, because
  both are "nobody took the queued occurrence for a second". The report
  is diagnostic and failed nothing on its own (the leg's own assertions
  timed out), but a reader who sees it under load should suspect
  scheduling before suspecting a handler. KAYA_STALL_MS raises the
  threshold if a lane ever needs it to.
- ~~**GAP — a kaya app cannot do background work.**~~ CLOSED 2026-07-28,
  same day, all nine languages (thread + `App.Post`/`Poster` + `kaya_wake`;
  matrix 808) — the body below is the record. The GAP was found 2026-07-28
  while designing file dialogs, and it is the reason that design kept
  contorting. There is NO way for a guest thread to get back onto the
  app thread: `App` is not thread-safe (Go's `Build` has a re-entrancy
  panic but no lock, and its maps are unsynchronized), no binding has a
  post primitive (grepped, all eight), and the app thread's only wake-up
  is `kaya_wait_occurrences`, blocked in C. So a guest that opens a file
  over the network, reads 2 GB, or calls an HTTP API either blocks the
  app thread — where the window keeps drawing but input stops doing
  anything, which is the worst possible failure because it LOOKS alive —
  or does it on its own thread and then cannot write the result into a
  signal. Without this, features whose result arrives late have to be
  designed in continuation-passing style, one callback per step, which
  is designing around the hole rather than fixing it.
  DEPTH SLICE LANDED 2026-07-28 (`c8a7ae1`, `1dc01c0`, `6f18896`,
  `0f65315`), validate-mac ALL PASS at 202 legs. `kaya_wake` rings both
  waiting paths; Go got `App.Post` with a drain-poll-wait loop; Rust got
  `Poster`, which must be a SEPARATE Send+Sync handle because `AppCtx`
  holds `Cell`/`RefCell` and is deliberately `!Sync` — making it
  shareable would legalize the danger rather than remove it. Closures
  never cross the C ABI: the floor says only "wake up".
  SWEEP LANDED the same day: all EIGHT languages post, each parking in
  its own idiom (channel, Event, DispatchSemaphore, ManualResetEventSlim,
  Mutex+Condition, MVar, CountDownLatch, mpsc), and the background scene
  runs in all eight on mac. Two finds the sweep paid for: the byte-path
  bindings (Python, Swift) would have RE-PARSED THE PREVIOUS RECORD on a
  wake, since they decoded the buffer whenever the size was non-zero —
  latent until they got a post; and Haskell's release used `putMVar`,
  which BLOCKS when full, so a second click would have blocked the app
  thread forever (`tryPutMVar` now). OCaml's release takes a bounded
  lock, the only one that does, and says so.
  COMPLETE 2026-07-28, matrix ALL PASS at 808 legs across all five
  lanes (up from 779). NINE languages including the C floor, which is
  where queue-plus-wake is written out rather than hidden behind a
  `post` — and which found a defect no sugar binding could: C queues
  DATA where every other language queues a CLOSURE, so one queue cannot
  carry two destinations, and the first version wrote every posted step
  to the wrong signal. Each entry now names its own target.
  Two things the slice cost that the plan did not predict: the wake
  CANNOT be gated by a scene (after the release click the app thread is
  freshly awake, so re-entering the wait before the worker posts is a
  genuine race), so it is a `cargo test` that spins on a new parked-count
  observation; and a public `Occurrence::Woken` variant was the wrong
  shape, because guests match that enum exhaustively — it is a
  `pub(crate) enum Inbox` instead. This unblocks file dialogs
  (docs/file-dialogs-plan.md), clipboard, notifications, and the
  editor's own reads.
- ~~**DEFECT — Go silently drops a write to a closed transaction.**~~
  FIXED 2026-07-28 for Go and Rust, CLOSED 2026-07-31 for the remaining
  five, and GUARDED by tools/check-tx-liveness.sh — the body below is
  the record. Go's `Tx.emit` is now the one append site and `Tx.alive`
  the one panic (bindings/go/app.go). As found:
  `Tx` carried a `closed` flag and the Widget/MenuItem chain methods
  checked it, but `tx.Write` and `tx.Signal` did not: they appended to
  `tx.records`, a slice `Build` had already submitted and would never
  submit again. The write vanished with no panic and no error. It was
  nearly unreachable at the time because nothing invited a guest to hold
  a `Tx` past its handler; the post primitive above was exactly that
  invitation, which is why it had to be fixed WITH it.
  FIXED FOR GO AND RUST 2026-07-28. Go routes all 109 append sites
  through one `Tx.emit` (plus `Tx.mirror` for model reads), so the
  liveness check cannot be missed at a new callsite, and a test asserts
  exactly one direct append survives. Rust's compile error is pinned by
  a `compile_fail` doctest on `Tx<'static>` — `'static` deliberately, so
  it cannot pass for failing some unrelated `'static` bound — paired
  with a PASSING assertion that `SignalId` and `WidgetId` are `Send`,
  because a compile_fail that dies of an unrelated error pins nothing.
  PYTHON NEEDED ITS OWN SPELLING, added with the sweep: its ambient `_tx`
  is a module GLOBAL, not thread-local, so a background
  `with app.build():` would stamp records into the app thread's open
  transaction, silently interleaved. It has no handle to check, so it
  checks the THREAD — `_require_app_thread` raises and names `app.post`
  as the fix. Signal writes needed no new guard: outside a transaction
  they already raise.
  CLOSED 2026-07-31 for the remaining five, and the sweep found that
  the languages split in two rather than one rule fitting all:
  - **HANDLE bindings** hand the guest a transaction object, so a stale
    one can be refused. C# and Swift needed NO callsite changes at all —
    every write already went through one member (`Records.Add(...)` in
    C#, `tx.<verb>(...)` in Swift), so making that member a PROPERTY
    that checks liveness first guards all ~100 and ~90 of them, and
    guards the next one written. Java has no properties, so it took
    Go's shape: 109 direct appends routed through one private `emit`.
  - **AMBIENT bindings** keep the open transaction in a global, so
    there is no handle to invalidate — a background build would stamp
    into the app thread's transaction (OCaml) or race its IORefs
    (Haskell). Both check the THREAD at the build entry, which is
    exactly Python's `_require_app_thread`, so the three ambient
    bindings now spell the rule identically.
  THE GATE IS `tools/check-tx-liveness.sh`, in validate-mac: it pins
  that each guard exists, that each chokepoint is still the ONLY way in
  (exact counts, not "at most"), and that every message names the post
  as the way out. Five negative tests, and the first draft of the gate
  FAILED three of them — grepping a bare function name matched the
  definition as well as the call, so the ocaml and haskell clauses
  passed with the call deleted. Bounds that say "at most" hide the
  extra write they are meant to catch.
- ~~**DEFECT — the iPad menu lowering is wrong as of iPadOS 26**~~ —
  FIXED 2026-07-25, checked off 2026-07-27. As filed (2026-07-24): kaya
  routed the entire catalog into a trailing More overflow on every iOS
  host — `KayaPhoneMenuToolbar`, gated `#if os(iOS)` — so a full
  command catalog hid behind a phone affordance while iPadOS 26's own
  menu bar sat empty.
  WHAT ACTUALLY SHIPPED: `KayaPhoneMenuToolbar` is gone. The arm is
  chosen by `KayaMenuFormFactorChrome`, which reads the live horizontal
  SIZE CLASS — regular takes the system menu bar, compact the toolbar —
  and the bar itself is driven through `UIMenuBuilder`
  (`kayaBuildCatalogMenus`), not SwiftUI's `.commands`, because
  CommandsBuilder has no `buildArray` and cannot express an
  append-at-any-time number of top-level menus. The menus-swiftui-pad
  leg asserts `expect_menu_presentation "regular/bar"` and passes; that
  literal reports `regular/overflow` if the arm choice ever regresses,
  which is precisely the original defect.
  WHY IT SAT HERE TWO DAYS AFTER BEING FIXED, and the lesson: the entry
  below ("the iPad menu bar's gate is OWED") recorded the fix in
  passing — "the lowering LANDED and is confirmed working" — while THIS
  entry, the one titled DEFECT and sorted to the top of the file, was
  never touched. A fix recorded in a neighbouring entry is not recorded.
  Worse, on 2026-07-27 an audit of this very file repeated the stale
  claim into the form-factor entry below, because it trusted this text
  instead of grepping for the symbol it names. WHEN AN ENTRY NAMES A
  SYMBOL, GREP FOR IT — that is a two-second check and it is the whole
  audit.
  THE TRAP WORTH KEEPING: the ledger already carried an iPad item, but
  its trigger was "an artifact running on iPad with a keyboard", framed
  around `UIKeyCommand` HUD exposure — the pre-26 framing, when a
  keyboard was the only route to commands on iPad. That trigger can
  never fire for the thing that now matters (a plain iPad, no keyboard,
  with a menu bar). A trigger written against a platform's CURRENT
  shape expires when the platform moves; triggers naming a platform
  capability need a re-read date, not just an artifact.

- **The iPad menu bar's gate is OWED, and the accessibility milestone
  pays it** (2026-07-25). The lowering LANDED and is confirmed working
  — visually, on an iPad Pro simulator: swipe down and the kaya catalog
  is there in the system menu bar. What is missing is an automated
  observation, and the reason is structural, measured, not assumed:
  the iPadOS menu bar is built LAZILY. `buildMenu(with:)` runs exactly
  ONCE, at launch, with an empty catalog, and never again no matter how
  many times `UIMenuSystem.main.setNeedsRebuild()` is called (traced:
  10 rebuild requests, 1 build). UIKit defers the build until the bar
  is about to be PRESENTED, the bar stays hidden until a swipe or
  hover, and UIKit exposes NO way to present a menu programmatically
  — so a headless scene structurally cannot witness the build.
  CONSEQUENCE, recorded in the code too: on iOS-regular alone, the
  presentation half of `expect_menu_presentation` is ARM-DERIVED — it
  reports the lowering the window selected, not a reading of rendered
  chrome. Every other backend still reads its real chrome. So the verb
  can catch a regression in the ARM CHOICE (which is what the original
  defect was) but NOT one in the build.
  THE SCHEDULED FIX DOES NOT WORK — MEASURED 2026-07-25, after the
  accessibility milestone landed. This entry used to say "a menu bar is
  an accessibility element, so the AX-tree verb restores an independent
  read". It does not. Dumping the iPad's own accessibility tree from
  inside a running menus scene (61 nodes, on an iPad Pro simulator)
  finds the scene's widgets and a `UIKitNavigationBar` and NO menu-bar
  element of any kind. That is consistent with the laziness measured
  above rather than a separate surprise: `buildMenu` ran once at launch
  with an empty catalog, so there is nothing built for the tree to
  carry. The read machinery itself is fine — the same dump resolved a
  widget by its authored id in the same run.
  There is also a structural mismatch worth stating: `expect_ax`
  addresses a WIDGET target through its authored `a11y_id`, and the
  menu bar is not a widget in kaya's model, so even a tree containing
  it would want a different verb shape.
  `UIMainMenuSystem` WAS TRIED AND DOES NOT DELIVER — MEASURED
  2026-07-26, on an iPad Pro simulator, iOS 26.5 runtime and SDK. iOS
  26 added `UIMainMenuSystem.shared.setBuildConfiguration(_:buildHandler:)`
  specifically for this menu bar, and its header promises exactly what
  this entry wants: the handler is used "instead of calling
  `-buildMenuWithBuilder:`", and "setting this will invalidate and
  rebuild the main menu system". That reads like an on-demand build,
  which is the one thing the responder path cannot do. It is not what
  happens. Registered from
  `application(_:didFinishLaunchingWithOptions:)`, the trace from the
  menus-swiftui-pad leg reads:

      didFinishLaunching ran
      setBuildConfiguration returned      (no assert, iOS 26 available)
      buildMenu roots=0                   (the RESPONDER path, still)
      rebuild requested  x10              (and no build follows any)

  So the call succeeds, the handler is NEVER invoked — not on set, not
  on ten setNeedsRebuild calls — and it does not replace
  `buildMenu(with:)` as documented. DO NOT SWITCH THE LOWERING TO IT:
  the responder path is the one that actually builds the bar today, and
  adopting the documented-but-inert API would trade a working menu bar
  for a silent one.
  WHAT IS ACTUALLY LEFT: nothing automated, in-process or out. An
  out-of-process client (XCUITest) sees only what is presented, and
  UIKit exposes no way to present the bar programmatically — a human
  gesture is the only trigger. Independent corroboration: an Apple
  developer forum thread on UI-testing iPadOS 26 menu bar items reports
  the same absence, that menu items do not appear in the
  XCUIApplication element tree on iPadOS while the identical test works
  on macOS. So on iOS-regular the presentation half stays ARM-DERIVED,
  the bar's correctness rests on the visual confirmation recorded
  above, and this entry is a RE-READ ITEM, not a scheduled fix. The
  re-read trigger is now SHARPER than "when iPadOS exposes something":
  re-check when `setBuildConfiguration`'s documented invalidate-and-
  rebuild actually fires, since the API to make this work already
  exists and only its behavior is missing.
  `KAYA_MENU_TRACE=1` is left in the interpreter, env-gated — it is
  what proved the laziness and will be wanted again.

- ~~**GTK's collapsed list-detail pane has NO back affordance, and back
  pops anyway**~~ — FOUND AND FIXED 2026-07-27, by screenshotting the
  collapsed window. The split arm hid kaya's own header back button for
  the WHOLE presentation, on the stated belief that "collapsed,
  libadwaita draws its own inside the navigation view". It does not:
  libadwaita draws that button only inside a header bar IT owns (an
  `AdwHeaderBar` in the page, normally via `AdwToolbarView`), and
  kaya's `AdwNavigationPage`s wrap the raw scene root. `back` then
  activated `navigation.pop` on the split view directly, consulting no
  affordance, so it popped where the user had no button to press —
  the Compose divergence mirrored (that one popped past a DISABLED
  BackHandler, this one past an ABSENT button), and the same decision
  covers both.
  THE FIX: the split arm shows the button exactly when collapsed and
  the stack is non-empty, `back`'s split-view special case is gone so
  ONE path serves both arms, and a `notify::collapsed` handler
  re-drives visibility when the breakpoint flips — the shape WinUI
  needed for `ModeChanged`, for the same reason (the collapse settles
  during layout, not at the write that caused it). The two-pane rule
  now falls out of the same visibility test as everything else: two
  panes, no button, nothing to drive.
  WHAT MADE IT INVISIBLE, and the guard still owed: no verb asserts
  that an affordance is THERE. `split.steps` drove `back` at 360 and
  passed the whole time, because the verb was reaching past the screen
  to the widget. It now depends on the real button, so that assertion
  gates the affordance's presence — negative-tested: hide the button
  and the scene fails with `entries 1, wanted 0`. But that is a
  coincidence of this scene, not a rule. FOUR backends now implement
  "refuse where the affordance is absent" four times; an
  affordance-presence assertion (the `expect_ax` precedent — read the
  real tree, not a flag) would make it one. That is a protocol change,
  so it is filed rather than done — PROMOTED 2026-08-19 to its own
  entry ("The refusal affordances are never asserted PRESENT"), because
  a live item inside struck text is invisible to every skim.

- ~~**The phone lanes have no list-detail coverage**~~ — LANDED
  2026-07-27. The `listdetail` scene is the `split` scene's phone-safe
  sibling: no resize, no literal, just the BARE `expect_split`
  invariant, which is true at every width a lane can hand it. It runs
  on all five, and on two devices per phone lane, because a compact
  host satisfies the invariant vacuously and could only report that the
  stacked arm ran. The iPad leg it already had, and the Android lane
  now has a 1280dp `medium_tablet` beside its 320dp pool for the same
  reason and with the same scope: one device, one scene. Those two legs
  are the first and only ones in any lane to reach the SwiftUI and
  Compose split arms — the Compose one had never rendered under a test.
  THE DEVICE IS THE WIDTH, so it owes the rule a resize owes:
  run-emulator asserts each device's dp is outside the 400..840 band
  before running (the same tablet rotated to portrait is 800dp, and
  would fail the invariant for a reason that is not a bug).

- ~~**The list-detail arms use PLAIN containers, not the platforms'
  adaptive wrappers**~~ — LANDED 2026-07-27, all four. GTK's `Box`
  became `AdwNavigationSplitView`, WinUI's two-star-column `Grid`
  became `TwoPaneView`, Compose's `Row` became
  `ListDetailPaneScaffold`; SwiftUI already had `NavigationSplitView`.
  What that bought, itemized against what this entry said the plain
  containers cost: the collapse/expand ANIMATION, and each platform's
  own pane proportions and separators — `protocol::leading_pane_width`
  now has a single caller (WinUI, whose control defaults to the
  down-the-middle split no platform ships) instead of a Rust copy and a
  Kotlin one.
  THE INTEGRATION SUBTLETY resolved the way this entry predicted it
  had to: every wrapper is driven FROM the core stack and told the ONE
  fact it needs — is a detail open. `androidx...adaptive-navigation` is
  deliberately NOT a dependency, because its navigator would hold a
  destination history; `ListDetailPaneScaffold` takes a caller-supplied
  `ThreePaneScaffoldValue`, which is the whole reason it can be used
  without one.
  AND THE OBSERVATION MOVED WITH THE CONTAINER: `expect_split` now
  reads the wrapper's own arrangement on all three — `is_collapsed`,
  `TwoPaneView.Mode`, the scaffold's per-role adapted values — instead
  of a value the arm stamped about itself.

- ~~**Adaptive LAYOUT is the second form-factor surface, and it owns
  `resize_window`**~~ — LANDED 2026-07-26/27 as list-detail. `list_detail`
  is a window prop, all four backends lower it to their platform's own
  adaptive container, each decides where one pane becomes two,
  `resize_window` drives the real transition and `expect_split`
  re-asserts on the far side. The scene runs on three desktop lanes and
  its phone-safe sibling `listdetail` on all five, with a device per
  size class on the two that cannot resize.
  The REFRAMING this entry argued for is what happened, and is worth
  keeping: `resize_window` was originally filed as the menus
  milestone's gate, but a verb that drives a transition no code
  specializes gates nothing, so it shipped WITH the feature it gates.
  MULTI-COLUMN was the part of "adaptive layout" that had NOT landed —
  this entry covered two surfaces and only list-detail was done then.
  PROMOTED 2026-08-19 to its own entry ("Multi-column adaptive layout
  — the unbuilt half"), same reason: live work inside struck text is
  invisible to every skim. That milestone SHIPPED and was struck
  2026-08-31; its residue lives in "Multi-column residue" further
  down.
  Encouraging for admission: the adaptive split IS a 4/4 native
  intersection, unlike the DRAGGABLE splitter (2/4) it is easily
  confused with — SwiftUI `NavigationSplitView`, Compose's Material 3
  adaptive scaffolds (`ListDetailPaneScaffold`) driven by
  `WindowSizeClass`, libadwaita's `AdwBreakpoint` +
  `AdwNavigationSplitView`, and WinUI's `TwoPaneView` / NavigationView
  display modes and adaptive triggers. Every one is size-class-driven
  by design, which is exactly the axis now in place.
  (The presentation assertion this entry used to call open LANDED:
  `menus.steps:85` carries the bare `expect_menu_presentation`, the
  ASYMMETRIC INVARIANT — regular implies not overflow, true on every
  platform and exactly the original defect — with the reasoning in a
  comment beside it, and the iPad leg appends the exact
  `"regular/bar"` literal. What is still owed there is narrower and
  lives in the iPad entry above: on iOS-regular that assertion is
  ARM-DERIVED, so it catches an arm-choice regression and not a build
  one.)

- ~~**Form factor as the adaptivity axis**~~ (DESIGN's "Form factor and
  adaptivity", 2026-07-24) — DONE, CLOSED 2026-07-27; what is left is
  the OWED GATE in the iPad entry above, which is a re-read item and not
  this one. The body below is the record. As filed:
  kaya keyed adaptivity on PLATFORM —
  compile-time `#if os(iOS)`, and the compact-overflow rule written as
  desktop-vs-phone. The correct axis is the window's size class,
  resolved at runtime, per window. Every backend already had the
  concept and kaya used none: SwiftUI's horizontal size class,
  Compose's `WindowSizeClass`, libadwaita's `AdwBreakpoint`, WinUI's
  adaptive triggers. Scope: a size-class notion in the core/window
  model, the four backend readings, re-keying the menus compact rule
  off `#if os(iOS)`, and the iPad `UIMenuBuilder` arm. The gate is
  already specified and already in this ledger — `resize_window` drives
  the size-class transition and re-asserts on the far side, which makes
  adaptivity a matrix fact instead of a claim. THE TWO ITEMS MERGE;
  do not schedule `resize_window` separately.
  THIS SCOPE IS SPENT — the item is DONE (corrected 2026-07-27, after
  the first pass got it wrong). Every backend reads its own size class;
  `resize_window` and both presentation assertions exist and run;
  list-detail is a second lowering obeying the axis, so "menus are the
  only one" stopped being true; and the menus rule is NO LONGER keyed
  on the platform — `KayaMenuFormFactorChrome` reads the horizontal
  size class, and the iPad `UIMenuBuilder` arm shipped with it. The
  first pass claimed the `#if os(iOS)` gate survived; it did not, and
  the claim came from reading the DEFECT entry above rather than the
  source.
  WHAT IS ACTUALLY LEFT is not this item at all: it is the OWED GATE in
  the iPad entry above — on iOS-regular the presentation half is
  ARM-DERIVED because the iPadOS bar cannot be observed headlessly.
  That is a re-read item, not scheduled work.

- **Window vocabulary** remainder (the rest LANDED through the
  window/panels/confirm/nav/sections scenes): presentation styles
  beyond the primary set (utility panels, always-on-top). Auxiliary
  windows themselves landed (`create_window`/`destroy_window`, gated on
  `KAYA_CAP_AUX_WINDOWS`, driven by tools/scenes/panels.steps), but
  every window is an ORDINARY one: `WINDOW_PROPS` holds title, width,
  height, veto_close, sections_presentation, list_detail, dirty and
  inset, and no level or presentation style. Scope when it fires: a
  presentation-style enum plus four lowerings and a scene.
  TRIGGER: an artifact that wants a floating inspector or palette — a
  tool-shaped app. Nothing in the tree has one. Written down 2026-08-19,
  because as filed this entry named no trigger at all and could only
  ever be read and skipped.
  KEY: window presentation style, utility panel, always-on-top,
  floating inspector, WINDOW_PROPS, window level
- **App-developer capability decisions** (raised 2026-07-23; each
  wants a design pass or an explicit v2 verdict, none is speculative
  protocol work):
  - **Styling tier 1 — the successor decision is MADE** (2026-07-24,
    DESIGN's "Brand identity and the styling ceiling"). The v1 stance
    stays zero *arbitrary* styling; what is admitted is two tiers.
    (a) SEMANTIC ROLES — destructive/prominent/plain on buttons,
    title/heading/body/caption on labels — the `role` grammar the
    menus milestone already built, reused verbatim. (b) A BRAND TIER
    of app-level slots (accent, typeface family, icon set), each of
    which every platform already exposes and expects apps to fill.
    Slots may take per-platform VALUES; the vocabulary stays uniform.
    What remains open under this heading, each a design pass:
    - The exact slot list and the four lowerings per slot. Carry the
      WinUI trap into the lowering: `SystemAccentColor` is NOT
      overridable (microsoft-ui-xaml#6394) — override the derived
      `AccentFillColorDefaultBrush` family in `ThemeDictionaries`.
      A lowering that sets `SystemAccentColor` compiles, runs, and is
      silently ignored, so this wants a gate, not a comment.
    - ~~**Semantic icon names.**~~ — LANDED 2026-08-16 in `c94da13`,
      exactly as filed: a closed name set (`symbol`, sprop 3 / mprop 9,
      `PropKind::Enum("symbol")` at crates/kaya/src/spec.rs:229 and
      :253) BESIDE the `icon` Blob, which stays for app-specific art.
      The vocabulary is `wire::SYMBOLS` and two gates hold it —
      tools/check-symbols.sh (every SF name exists at kaya's floor) and
      tools/check-symbol-parity.sh (one vocabulary, six files). As
      filed: `icon` is a Blob today (sprop 2 / mprop 5), which is the
      wrong primitive for STANDARD icons — the platforms draw the same
      concept differently, and their symbol sets metric-match adjacent
      text while a blob cannot. NOT a tinting problem: a single-color
      raster tints fine on all four.
    - **Vector/DPI story for the Blob** (separate from the above): all
      four decoders are raster-only today — `NSImage(data:)`,
      `BitmapFactory.decodeByteArray`, `gdk::Texture::from_bytes`
      (PNG/JPEG per its own comment), `BitmapImage::SetSource`. Android
      cannot be fixed by API choice: `VectorDrawable` needs a compiled
      resource, with no runtime inflate-from-bytes. A PNG shipped at one
      size is soft at 2x/3x and kaya has no multi-resolution story. The
      shape that fits kaya: rasterize SVG IN CORE with `resvg` — one
      renderer, byte-identical output on all five platforms, the same
      doctrine as the shared scene scripts, and it routes around the
      Android limit. Cost: core must learn the target scale factor,
      which it does not know today.
    - ~~Typeface substitution must change the FAMILY only, never the
      scale (Dynamic Type / `sp` both break otherwise), which makes the
      role tier a precondition rather than an alternative.~~ — LANDED
      2026-08-16 in `31ace6b` with that rule in the wire contract:
      `set_brand_typeface` (crates/kaya/src/spec.rs:1078) carries a
      family and no scale, and `expect_typeface` reads back the family
      the text system actually resolved (tools/scenes/typeface.steps
      freezes `expect_typeface "Sora"`). The one remainder is the iOS
      observation depth stub, held by the typeface tracker section
      further down this file, not here.
  - ~~**Accessibility surfacing**~~ — LANDED 2026-07-25. Two universal
    props (`a11y_id`, `a11y_label`) in all 8 bindings plus the C
    floor, and `expect_ax`, which reads each platform's REAL tree
    (AXUIElement, UIKit's materialized elements, Compose's merged
    semantics, AT-SPI, UIA) over every widget kind on all five
    backends, byte-identical. See DESIGN's Accessibility section for
    the per-backend read table. The iPad menu bar's independent
    observation was expected to ride this verb and MEASURED NOT TO —
    see that entry, which is now a re-read item.
    THE HINT PROP LANDED 2026-07-25 (`a11y_hint`, spec prop 14): the
    activation kinds carry it — `.accessibilityHint()` on Apple, the
    click action's LABEL on Compose (measured: a label-only semantics
    node relabels a Material3 Button's action and KEEPS it), GTK's
    `Property::Description`, `AutomationProperties.HelpText` on WinUI —
    read back by its own verb `expect_ax_hint` and green on all five
    lanes. The root scopes it to button/checkbox/select/radio because a
    hint describes what ACTIVATING a control does and Android has
    nowhere to put one without an action; that domain is unit-tested
    both ways. Still open, trigger-gated: hints on the adjustable and
    editable kinds (slider, entry, textarea), whose Android route is a
    different action's label.
  - **Video widget**: unexamined — DESIGN has the surface-handle
    transport (~~the Canvas zero-copy arm~~ the pixel-handoff arm; the
    canvas widget stopped being that on 2026-08-26, docs/canvas-plan.md
    §1.4) but no media-playback
    story. The wrap-native bet suggests a Video widget over each
    platform's native player (AVPlayerView / MediaPlayerElement /
    Media3 / GStreamer) before any frame-pushing pipeline.
    Trigger-gated on an artifact app.
  - Audio is NOT listed here: it is designed (core-owned RT callback
    + sample ring + node-graph vocabulary, DESIGN's Audio passage)
    and stays admission-gated on an app that needs it.
- The stock stacks' nil-frames are re-proposers too, in theory. A
  constraint-less `.frame` around a stock stack's child still places
  by re-proposing the child's fitted size; today every stock-branch
  child is a control (idempotent under its own size) or a container
  whose squeeze no scene constructs, so nothing observable fails. A
  KayaStretchCell replacement was attempted in the dressed-floor
  slice and RETREATED: a custom Layout does not forward alignment
  guides (baseline rows classified "mixed") and its guide-forwarding
  overloads SIGTRAPed the gallery leg — a correct replacement must
  forward guides for real, and per doctrine the failure wants a
  CONSTRUCTED failing scene (stock column in stock column with a
  bordered-button row) before the next fix attempt.
- An `expect_honest` gate: measured-vs-drawn self-agreement per
  control. The dressed-floor hunts exposed two symptom shapes the
  geometry gates are structurally blind to — a control whose caption
  wraps or truncates still classifies and fills correctly (the
  "tic/k" wrap shipped through two 18/18 iOS runs). Both shapes share
  one observable: the control's DRAWN box diverges from its honest
  ideal (wrapped pill 42.67x56.33 vs ideal 51.67x34.33; a compat-mac
  liar diverges the other way). Design: record each control's
  answered ideal (sizeThatFits(.unspecified) — stable like a font
  metric, so the recording trap does not apply) alongside the
  existing drawn-geometry readers, and a verb compares them under
  ample space. Interpreters first (the historic miss layer), then the
  native backends' analogs. Caveat named by the mac experiments: in
  a compat-stamped process the SwiftUI-side layout box and the AppKit
  PAINT disagree while both SwiftUI numbers agree — catching that
  class needs the AppKit frame walked, which the bridge already
  makes moot for buttons; scope the first cut to SwiftUI-side
  self-agreement.
- ~~The suite runners screenshot AFTER teardown.~~ — CLOSED 2026-07-27
  by taking this entry's SECOND option: the ad-hoc per-leg captures are
  gone from run-emulator and run-sim, and the recording pipeline is the
  visual record (a still at every step, anchored to the harness
  transcript rather than to a guessed delay; `KAYA_RECORD=1`).
  The first option — move the capture earlier — was tried and measured
  three ways before giving up on it, which is the part worth keeping.
  On Android `am start -W` already blocks until the first frame
  (TotalTime ~420ms), the scene then reaches its verdict and exits
  ~300ms later, and screencap costs ~100ms of that: waiting 2s and 1s
  both produced wallpaper, and waiting 0s produced the launch SPLASH,
  before the scene had drawn. The real-UI window is narrower than the
  jitter around it. On iOS it was never a race at all —
  `simctl launch --console-pty` returns only when the guest EXITS, so
  every capture on that line was strictly post-teardown (50 of 51
  outputs were the home screen, 2.4MB each).
  IF THE SHOTS ARE EVER WANTED BACK, the deterministic hook is a
  linger: `record_linger` in harness.rs already holds the window 750ms
  after the last step under `KAYA_RECORD`/`KAYA_HARNESS_GATE`, and a
  third trigger would make a capture landable. That is core surface for
  a debug convenience, which is why it was not taken now.
- The C floor's grow/layout scenes, out on purpose: the floor
  documents the explicit wire; a separate exercise. (Map for the next
  layout prop, from grow's landing: native weights on WinUI — `Grid`
  star sizing — and Compose — `Modifier.weight`; constructed on GTK4
  — a custom `GtkLayoutManager` — and SwiftUI — a custom `Layout`.)
- **The versioned binding style guide** (DESIGN open question #1) —
  DEPRIORITIZED 2026-07-24 (Akhil): kaya maintains its own bindings, so
  cross-binding consistency comes from one set of hands plus the gates
  (check-sugar-surface, the abort checks, the emission checks), not
  from a document. A style guide is what you write when OUTSIDE
  contributors author bindings; revisit when the library is mature
  enough for that to be true. The per-family spellings stay ratified
  and in force (chains: Rust/Go/Java; named args:
  Swift/Python/C#/OCaml; config lists: Haskell — DESIGN's Binding
  conventions; OCaml's ambient-transaction spelling, 2026-07-22).
  Three items filed under it are NOT style and keep their own standing:
  - **Container scoping for layout props** — typed row/column contexts
    making an orphan `grow` a compile error. A safety guard (types over
    runtime checks), not ergonomics. The ambient languages' nullary
    container bodies cannot express a receiver without a redesign,
    which is why it waited.
  - **Derived-signal vocabulary beyond Python** (eq/ne/fmt) and
    **blob-signal parity** (Go has typed Signal[[]byte]; others wrap
    handles) — capability gaps between bindings, not spelling ones.
  - **Decision gate for deleting the probe/reflection selector floor**
    that the KayaGen generators superseded — debt with a real deletion
    behind it.
  The rest — per-language tiers, ambient-tx spellings for the remaining
  languages, optional static analyzers,
  multi-window ergonomics — waits for the guide, and the guide waits
  for maturity.
- STANDING CONSTRAINT — do not bump the flake SDK without preserving
  a compat-generation leg. The nix shell links every non-swift leg
  binary against its pinned SDK (audit 2026-07-21: python3/go/dotnet/
  ocaml/rust 14.4, zulu JDK 11.3), so those legs exercise SwiftUI 26's
  COMPATIBILITY design generation, while the swift mac guests compile
  against the system toolchain and exercise the modern generation —
  both covered on purpose. Vendor audit (2026-07-21, official
  binaries, LC_BUILD_VERSION sdk field): .NET host 10.0.10 = 15.5,
  .NET 11-preview.6 = 15.5, apphost stub = 15.5; zulu jre 21/25 =
  13.3, Temurin 21 = 14.2, Oracle JDK 25 = 14.5. No vendor ships a
  ≥26 stamp; nixpkgs' darwin `openjdk17` IS repackaged zulu (no
  source-built lever). The compat generation is where the Button
  measurement bug class lives and is a permanent first-class citizen;
  the native-kit button bridges are load-bearing indefinitely, not
  transitional.
  APPROVED 2026-08-16 (maintainer): bump the SDK for the kaya-built legs so guests opt into macOS 26's modern design generation; the artifact-screenshot caveat (stills will show the modern look, not older releases') is acknowledged. The constraint above still binds: the compat generation keeps a leg — the vendor-stamped hosts (JVM, .NET apphost) stay compat regardless of the flake, and the bump slice must VERIFY that coverage rather than assume it. Scout report: docs/chrome/sdk-bump-scout.md.
  THE BUMP LANDED 2026-08-17 (`4e5c67e`), and the verification is now
  mechanical rather than owed: `tools/check-design-generation.sh` reads
  which generation each mac leg's host was linked for and refuses if
  EITHER door closes, so the standing constraint above is enforced by a
  gate instead of by whoever remembers it. The constraint itself does
  not expire — it is what the gate holds.

## Protocol / core

- ~~**No app can control the margin around its window content**~~ (found
  by the editor, 2026-08-10; the maintainer chose to ship v1 with the
  margin rather than fix it now) — CLOSED 2026-08-12, and BOTH shapes
  below shipped rather than one: the WINDOW content inset is wprop 8
  (`55f1873`) and the CONTAINER inset is prop 17 (`5e650a0`, the
  editor's own buffer taking the edge while the chrome keeps its
  margin). The interpreter's five hard-coded sites now read
  `.padding(scene.windows[…]?.inset ?? 16)`, so the default is still 16
  and no existing scene moved — costing (a)'s promise, with (b)'s reach
  added a level down. The body below is the record. As found:
  the SwiftUI interpreter inset window
  content by a hard-coded `.padding(16)` (swift/KayaSwiftUI.swift, five
  sites) and the spec had NO padding property anywhere: containers could
  SPACE their children apart, but nothing controlled the space AROUND
  content. So a full-bleed layout — a Sublime-shaped editor, a canvas,
  a photo view — was inexpressible.
  Two shapes were costed when it came up:
  (a) a WINDOW content-padding prop beside title/size/dirty, defaulting
      to today's 16 so no existing scene moves; the app asks for 0.
      Additive, spec-first, the dirty-state milestone's shape.
  (b) padding as a property of any CONTAINER, with the interpreter no
      longer padding the root. More correct and useful to every app,
      but it moves how every existing scene lays out, so all nine
      guests and their byte-frozen strings need re-examining.
  Whoever picks this up: (b) is the better framework answer and (a) is
  the cheaper one; the editor only needs (a).
  **HOME: the styling/branding pass** (Akhil, 2026-08-10), which is
  ALREADY DESIGNED in DESIGN.md (brand slots, semantic emphasis via the
  role grammar, symbol sets, and the WinUI accent trap) — this entry
  should be read against that section, not as a fresh idea.
  AND NOTE THE TENSION, because it is the actual decision: that section
  explicitly REFUSES arbitrary per-widget appearance and names "a
  padding override" as an example of what the dressed floor exists to
  refuse. So the question is not "add padding"; it is whether the
  WINDOW CONTENT INSET is (i) part of the platform-flowing bet and
  therefore correct as-is, with full-bleed layouts simply unsupported,
  or (ii) a LAYOUT fact rather than an appearance one — like grow and
  spacing, which the design already admits — and therefore the one knob
  that belongs. Decide that first; the two costings above only matter
  if the answer is (ii).


- ~~**A stable identifier prop (`test_id`, doubling as the accessibility
  identifier)**~~ (LANDED 2026-08-21 — the ADDRESSING half, pulled
  forward by the maintainer when the portfolio scene became the
  entry's named trigger: `kind@id` beside `kind#index` in all three
  harness implementations, resolved against the authored `a11y_id`.
  The core's Target carries the id (leaked to 'static, the
  scene-script precedent, so Target stays Copy); the runner
  NORMALIZES once per step through the new `Stage::resolve_id` —
  observations retry the resolution on the poll clock, actions refuse
  at once — so the dozens of index-shaped Stage reads never learned
  about ids, and `Step::targets_mut` is the one exhaustive map a new
  targeted variant must join. The interpreters resolve directly
  (first node in the kind's registry with the matching a11yId); GTK
  scans the widget names its a11y arm already writes; WinUI reads
  AutomationId back off the controls — EXCEPT buttons, whose registry
  stores click TAGS by design, so button@id resolves None there
  alone, the dirty read-table's documented-divergence shape, until a
  scene needs it. Python's `columns()` grew the `a11y_id=` kwarg so a
  table container can author its key in the sugar. Watched: the
  refusal was seen live on mac with the app's id renamed away ("no
  such target column@positions", sixteen times down the scene), and
  the parse half is unit-pinned. NOT migrated: every existing scene
  stays positional (leaf kinds are stable by body order); the layout
  scene's rows can now be asserted whenever someone wants them, and
  the container lint STAYS for positional targets — @ids are its
  sanctioned alternative, not its retirement. EXTENDED 2026-08-23:
  `kind@id[key.path]` narrows a table target to one string-keyed stamped
  copy; resolve_id maps authored id -> template node -> live sort tag,
  and the exhaustive targets_mut match now makes an omitted future
  targeted Step a compile error.
  KEY: kind@id, kind@id[key.path], resolve_id, targets_mut, a11y_id addressing, column@positions)
  ORIGINAL ENTRY, for the record: harness scripts should
  address widgets by the same authored key on every platform, not by
  `kind#index`. Positional targets exist only because they were free
  (the per-kind driving registries already existed); an authored key
  flowing over the wire dissolves the creation-order instability
  entirely — containers freely addressable, no unique-by-convention
  discipline, no check-steps container lint, and the layout scene's
  rows become assertable instead of observation-only. Frame it as the
  accessibility identifier (accessibilityIdentifier / testTag /
  resource-id are the platform mappings) so it is a real product
  surface with the harness as first consumer, not test plumbing on the
  production wire.
  HALF OF THIS IS ALREADY PAID (noted 2026-07-27, on an audit of this
  file). The accessibility milestone landed the prop: `a11y_id` is
  spec prop 12, and it lowers to exactly the mappings proposed above —
  `accessibilityIdentifier` on the Apple backends, `Modifier.testTag`
  on Compose. So the expensive half of the original cost — a Prop in
  spec.rs, the hash moving, everything regenerating — is spent, and
  the framing question is settled rather than open. Do not plan it
  again.
  WHAT IS ACTUALLY LEFT is the ADDRESSING half: a name→widget map in
  the backends and both interpreters, `parse_target` accepting an
  authored key beside `kind#index`, and a steps migration. Every scene
  still targets positionally, so the payoff is untouched — containers
  freely addressable, no unique-by-convention discipline, check-steps'
  container lint retired, and the layout scene's rows assertable
  instead of observation-only. TRIGGER: the first scene that needs to
  assert on a container the uniqueness convention cannot name — the
  layout scene already qualifies whenever its rows deserve assertions.

- **Session restoration — core-owned, and cheap only here** (from the
  2026-07-24 survey; TRIGGER SATISFIED by the text editor). THE UNDO
  HALF OF THIS ENTRY IS DONE: the design pass it demanded happened, the
  depth slice landed 2026-08-04 and the completion pass closed its
  follow-ups 2026-08-05 (see the undo entries below), and `undo` runs on
  every lane. What is still open is RESTORATION — nothing in crates/
  serialises a scene or brings one back — and the argument for it is
  the same one, so the body below is kept whole.
  Every other cross-platform framework bolts undo onto
  application state it does not own; macOS has `NSUndoManager` and the
  other three platforms have nothing portable. kaya owns all state at
  rest and every mutation already arrives as a transaction, so an undo
  stack is a log of objects core materializes anyway. The same
  machinery gives window/session restoration — serialize the core
  scene, not the app's state — which cmyr's ingredient list names and
  nobody enjoys writing. NOT free: the design pass has to answer which
  transactions are undoable, whether an undo re-runs handlers or simply
  applies the inverse transaction, and what happens to occurrences
  emitted during an undo. Do the design pass before any protocol work;
  the machinery being present is not the same as the semantics being
  obvious.
- **The system-integration floor** (from the survey; the editor
  triggers the first three). Four surfaces, native on every platform,
  none previously in this ledger, and collectively what separates a
  demo from an app. HALF OF IT IS BUILT: file dialogs landed open
  2026-07-31 and save 2026-08-10, and the clipboard is checked off at
  the top of this file — so what this entry still holds open is
  NOTIFICATIONS and DRAG AND DROP, neither of which the spec mentions
  today, plus printing behind them. The survey's framing follows
  unchanged, because the ordering argument is what the entry is for.
  In the order real apps need them: **file dialogs**
  — NOT a widget, a presentation context returning a result. RATIFIED
  2026-07-27, see DESIGN's "File dialogs": the alert grammar holds, but
  the result is a LIST OF HANDLES redeemable for open DESCRIPTORS, not
  paths — Android and iOS have no path to give, and kaya hands over a
  capability rather than moving bytes. Open comes first, save second;
  **clipboard** — note it is SYNCHRONOUS on
  mac/Windows and ASYNCHRONOUS on Linux, so the API must be
  async-shaped or it is wrong on one platform, and it is also the
  unblocker for the deferred cut/copy/paste roles; **notifications** —
  the four platform models are close; **drag and drop** — the most
  divergent, and it interacts with window management on both mac and
  Windows. **Printing** sits behind all four and is not editor-forced.
- **Standard commands LANDED 2026-07-24** (the follow-up milestone to
  menus): a chord rides any window-anchored LEAF command rather than
  plain actions alone, the key floor admits eight named punctuation
  keys, and `role` names a standard command with `settings` as its one
  v1 value. DESIGN.md's "Standard commands" and the shortcut policy
  carry the rules; the `commands` scene proves all three in nine
  languages on every lane. ~~Still open, trigger-gated: roles beyond
  `settings`~~ — the roles half is SHIPPED 2026-08-04: `MENU_ROLES`
  carries six, and the five past `settings` arrived under this entry's
  own trigger — `cut`, `copy` and `paste` with the clipboard milestone
  (2026-08-02), `undo` and `redo` with the undo one (2026-08-04), each
  reaching all four backends, with tools/check-roles.sh holding the
  vocabulary and the arms to one line and DESIGN.md's cut list now
  reading "roles beyond the six". STILL OPEN, trigger-gated:
  punctuation keys beyond the admitted set — `scene.rs` admits exactly
  eight and semicolon, quote and grave are absent.
- **Menus follow-ons.** The command vocabulary LANDED 2026-07-24 —
  both anchors, all four backends, all 8 bindings plus the C floor,
  and the menus scene green on every lane. DESIGN.md's "Menus and the
  command vocabulary" is the whole record — the design, the lowering
  per host, and the two platform limits under "Where a platform cannot
  say it". What stayed out is trigger-gated, each trigger
  stated in that section's "Deliberate cuts and admission triggers":
  shared command identity across anchors (the responder-chain/target
  problem), For-stamped items, `bind_field` labels on context items,
  merging authored items into native text-control menus, a GTK
  hamburger presentation hint, item removal, context-item shortcuts,
  ~~role-based standard items (including native Settings placement)~~,
  punctuation shortcut keys, and ~~a toolbar grammar, only under
  artifact pressure~~. TWO OF THOSE HAVE SINCE COME IN. Role-based
  standard items shipped whole: `settings` with the standard-commands
  follow-up 2026-07-24, native placement included, then
  `cut`/`copy`/`paste` 2026-08-02 and `undo`/`redo` 2026-08-04, six
  roles on four backends. The toolbar trigger was ANSWERED 2026-08-17,
  and the answer was that no grammar was needed: what the artifacts
  wanted was desktop presence, which adaptive menu promotion already
  expresses, so `primary` grew its desktop lowerings and nothing else
  moved — no record, no prop, no spec hash, no binding spelling.
  DESIGN's own cut list carries that answer; app-declared toolbar ORDER
  stays unadmitted under the same trigger.
  One follow-on the section does not carry: iOS has
  no hardware-keyboard route to the catalog. The interpreter holds
  the shortcut table (the harness verb drives it, and the scene
  proves the dispatch), but nothing binds it to a real iPad keyboard
  or to the hold-Command HUD. NARROWER THAN IT READS (corrected
  2026-07-27): the `UIMenuBuilder` half SHIPPED — `kayaBuildCatalogMenus`
  runs on BOTH iOS form factors, and on iPhone it feeds the
  hardware-keyboard HUD; only the VISIBLE arm keys on size class. What
  is actually missing is the CHORD: the generated `UIAction`s carry no
  `input:`/`modifierFlags`, so nothing is bound to a key. (The macOS
  lowering is NSMenu rather than SwiftUI `.commands`, which is why
  neither side goes through CommandsBuilder.) TRIGGER (SUPERSEDED 2026-07-24 — see the iPad
  DEFECT entry at the top; iPadOS 26's menu bar is not keyboard-gated,
  so this trigger could never fire for the case that matters): an
  artifact running on iPad with a keyboard. Android's equivalent route
  IS live (each host Activity forwards `dispatchKeyShortcutEvent` into
  the same table).
- scrollTo + ref markers (per-instance handles): brings the first
  instance-addressed command (TemplateNodeId + key path target) and the
  silent vanished-target no-op (live-zone commands fail loudly; stamped
  copies legitimately vanish under rebuild). Wants a long-list scene —
  which pairs with row-window virtualization for For.
- Horizontal scroll axis: an axis enum prop — decide when a scene
  needs it (the scroll depth ledger's remaining item).
- Command completion observability (awaitable commands — the Compose
  scrollToItem precedent); command payloads (a set_text command awaits
  an autofill-shaped artifact). Admission policy: each verb needs a
  real artifact.
- Value::Record — waits for nested fields or field-level sum payloads.
- Nesting depth >2 validation; typed keys in collection schemas.
- Occurrence growth: subscription/filtering (every click emits today),
  suspension lifecycle (Android).
- Vello scene-encoding subset (open question #3) — ~~arrives with
  Canvas, post-v1,~~ RE-FILED 2026-08-26 against the PIXEL-HANDOFF
  feature it was always about (docs/canvas-plan.md §1.4, §12): an app
  that renders its own frames on its own schedule and hands kaya
  finished pixels. It never governed the canvas WIDGET, and it does not
  now — the canvas ratification put kaya's own op vocabulary on the
  wire and kaya's own CPU rasterizer behind it, so nothing about a
  rasterizer's format crosses a binding. The encoding also turned out
  not to be available to adopt: Vello calls itself alpha, its only
  statement about freezing the format is a 2023 roadmap saying it is
  too early, `Encoding` is twelve parallel `Vec`s with no `repr(C)` and
  no serde, it breaks at minor versions, and the one serious FFI
  binding wrapped scene-BUILDING calls instead and was archived waiting
  for a final API. Still open, and still on the surface-handle
  transport (pixel surfaces as IOSurface/DXGI/dmabuf handles; the blob
  channel is the byte-copy arm, the pixel-handoff feature is the
  zero-copy arm).
  AND THE ZERO-COPY ARM HAS A WIDGET, corrected 2026-08-26 (ruling 16,
  docs/canvas-plan.md §16): it was never a second canvas. It is the
  IMAGE widget learning a HIGH-RATE UPDATE PATH for content kaya did
  not draw — video frames, a camera, an external engine's output —
  which is why "re-filed against the pixel-handoff feature" above
  should be read as re-filed against the image widget's high-rate path.
  The split is by where the pixels come from: the canvas is pixels the
  core rasterized from a declaration it can validate and hash, the
  image is pixels somebody else produced and kaya presents. Flutter
  ships the same split as Canvas versus Texture, the latter "repainted
  autonomously as dictated by the backend (e.g. on arrival of a video
  frame)" — the contrast is kaya's own reading, since those two Flutter
  pages never mention each other. Nothing in the canvas's animation
  scope (ruling 14) reaches this: a GPU DISPLAY path is the core
  choosing how to present its own raster, not an app handing kaya
  frames.
  KEY: Vello, scene encoding, pixel handoff, zero-copy, surface handle,
  IOSurface, dmabuf, image widget, Texture
- Blob follow-ups: dedup on repeated registration (needs an artifact);
  kaya_blob_from_file/mmap escalation (needs an artifact showing the
  register copy matters — decode dominates by an order of magnitude).

## Bindings / ergonomics

- Component functions as the reusable named unit (Solid's model, slot
  proxies = the function signature) — mostly ratification for the
  typed languages; Python validates at record time.
- Switch sugar (app-level one-of-N over a signal; sum-typed elements
  already cover collection rows) — wants the comparison vocabulary
  first.
- Template-declared collection escape to handlers (`group.items` via
  the element proxy) — flagged, undesigned; wait for a motivating
  scene.
- Portal (platform overlays; protocol + backend work).
- OCaml effect-handler ambience (true Python-style ambient
  transactions; runtime-only scoping errors — OCaml has no effect
  typing).
- Binding-maintained mirrors (todos-iterable style shadow state).
- Navigation sugar remainder from the nav breadth slice: (1)
  pop_to_root/pop(n) sugar + the binding stack mirrors it needs;
  (2) signal-bound entry titles have wire + scene + fan-out but no
  binding sugar.

### Swift reads its constants straight out of the C header, and the header is not namespaced

Swift is the ONE binding with no generated constants: every other
language's kaya-bindgen emitter walks `spec.enums` and writes them out,
while Swift imports kaya.h with `-import-objc-header` and names the C
symbols directly (`KAYA_PROP_ALIGN`, `KAYA_ALIGN_START`). That was
deliberate — Swift's C interop is free, so re-declaring would be pure
duplication.

The clipboard found the crack in it. Constants declared in
`crates/kaya/src/capi.rs` carry the `KAYA_` prefix in their Rust names
and reach the header prefixed; constants declared in
`crates/kaya/src/wire.rs` do not, and cbindgen exports them verbatim.
So the header defines `CLIP_TEXT`, not `KAYA_CLIP_TEXT` — and the
`KayaRepresentation` doc comment, written from the other side, promises
`KAYA_CLIP_*`. The Swift clipboard surface uses `CLIP_TEXT`, which is
what is actually there.

THE WIDER PROBLEM is not the clipboard's. kaya.h currently exports
214 unprefixed defines of 418 in all — the MAJORITY of the header, not a
corner of it (re-measured 2026-08-19; as filed it said "about sixty").
Every `REC_*`, every `TX_*`, every
`APPLY_*`, the `VALUE_*` types, the `PROP_*` and `WPROP_*` keys, the
`CLIP_*` masks, the `KIND_*`/`MPROP_*`/`EPROP_*`/`ALIGN_*`/
`FILE_MODE_*`/`ALERT_CHOICE_*` families, and `HEADER_SIZE`, which is a
name no public header should take. Any C or Swift consumer that includes
kaya.h inherits all of them.

WHY IT IS A SLICE AND NOT A RENAME. Fixing it means deciding how the
Swift binding should name what the header exposes at all — generated
constants like the other seven, a Swift enum wrapping them, or a
prefixed header it keeps reading — and each answer rewrites call sites
across the Swift binding, the SwiftUI interpreter, every Swift guest
and every C guest. Doing it inside a feature milestone would mix a
mechanical sweep into changes that need to be readable. Take it on its
own, with the C guests compiled and the whole matrix run after.

### The accessibility walk visits every window twice

`kayaAxKids` in swift/KayaSwiftUI.swift gathers an element's children
from three attributes and deduplicates only the third:

    var out = windows + children                 // no dedup
    for n in nav where !out.contains(where: { CFEqual($0, n) }) { ... }

An `AXApplication` publishes the same window under BOTH `AXWindows` and
`AXChildren`, so `out` holds it twice and every walk descends the whole
window subtree twice. Visible directly in a `KAYA_AX_TRACE=1` dump as
two identical `AXWindow id=main.KayaRoot-1-AppWindow-1` subtrees
(observed 2026-08-02 on the clipboard scene).

WHY IT IS WORTH FIXING rather than shrugging at: AX cost is this
subsystem's documented hazard, not a micro-optimisation. Announcing
`AXEnhancedUserInterface` makes AppKit rebuild its accessibility
hierarchy and drive a full layout pass, which on 2026-07-25 put legs
past their 120s timeout under the 8-wide pool while the same binary
passed standalone. Every `expect_ax` pays the walk, and halving it is
one line: extend the `CFEqual` dedup to cover `windows + children`.

WHY IT IS NOT DONE HERE: it changes the SwiftUI interpreter's shared
read path, which every accessibility assertion on mac and iOS depends
on, in the middle of a clipboard milestone. It wants its own slice with
the a11y scene and the full matrix behind it — and a before/after read
count, so the saving is measured rather than assumed.

## Testing / infrastructure


- **The table bench drives two platforms of five.** tools/bench-tables.sh
  runs `guest` (headless, the binding's accumulation path) and `macos`
  (launch to verdict on the SwiftUI interpreter); `linux`, `windows`,
  `android` and `ios` are refused with a sentence naming
  docs/measurements/README.md's "The five rigs", where each 2026-08-24
  procedure is written out step by step. They were deliberately NOT
  transcribed into orchestration nobody could exercise the night it was
  written: an ssh/schtasks, `am start` or simctl driver that no run
  touches rots in silence, which invariant 3 calls a guess. Automating
  one means having its environment up while it is written and watching
  it produce a number. Until then the refusal is the honest answer, and
  it is watched printing on all four.
  KEY: bench-tables, five rigs, choke bench recipe, tools/bench, not automated
- ~~**Go 1.27 STABLE is out; the three 1.27rc2 pins should move to it**~~
  — DONE 2026-08-22, the entry's own interim option: all three pins
  moved TOGETHER to the 1.27.0 release tarballs with go.dev's published
  sha256s (flake.nix's fetchurl, tools/linux/Dockerfile's sha256sum -c,
  tools/deploy-win.sh's Invoke-WebRequest), `nix develop -c go version`
  answers go1.27.0, and deploy-win's VM check became VERSION-KEYED —
  the old `if exist` would have kept the VM's cached rc2 through the
  bump forever. AND the clean move landed the same hour, the
  maintainer asking the right question at the mkDerivation ("why do
  you need to mkDerivation?"): flake.nix now takes go_1_27 from a
  DEDICATED nixpkgs-go input locked independently at nixos-unstable —
  the main input's locked rev only carries 1.27rc1, and bumping IT
  moves every tool at once, which a second input avoids. The
  hand-rolled tarball derivation is gone from the flake; release
  tarballs remain only where no nix exists (the linux container's
  Dockerfile, the windows VM), same version, moving in lockstep.
  KEY: go 1.27rc2, go127, pinned binary distro, nixos-unstable channel
- ~~**A GUARD THAT ABORTS THE PROCESS IS THE WRONG SHAPE, and this is the
  second instance.**~~ — CLOSED 2026-08-21: the rule adopted, both
  instances converted, and every other guard of the shape with them. Measured 2026-08-10 on mac:
  under an environmental slowdown the file picker missed the step budget, the
  scene proceeded and requested a second dialog, and the one-dialog-per-process
  guard (`file_dialog_shown`, crates/kaya/src/capi.rs — GREP THE FUNCTION NAME,
  the line number has moved three times) panicked in a non-unwinding context,
  so the leg died with `fatal runtime error: failed to initiate panic` and no
  verdict list.
  THE RULE NOW LIVES IN crates/kaya/src/fault.rs: `report` latches a sentence,
  `guard` stops an unwind at a nounwind boundary, `latched` is a
  peek the harnesses poll. `file_dialog_shown` and `alert_shown` answer `false`
  and scene.rs DROPS the op; the two retire twins report; and `Scene::apply`
  itself runs under `fault::guard` in capi's `kaya_next_commands`, in winui's
  and gtk's `drain_transactions`, and in winui's `deliver_undo` — which is what
  puts scene.rs's ~100 app-misuse assertions on the reddening path, the
  `destroy_window(0)` arm docs/traps.md records as unreachable-but-fatal in
  nine guests among them.
  AND THE OTHER HALF OF THE CONTRACT SURVIVED IT, by the maintainer's
  ruling the same day: `report` FORKS on `fault::watch()` — each of the
  three script runners declares itself watched before its first step
  (`fault::tests::every_harness_runner_watches` holds all three to the
  call), and an UNWATCHED process — a real app misusing the API, or the
  bindings' corpse-reading children (bindings/go/internal/rootprobe) —
  still dies legibly, sentence first, exit 1. Without the fork the five
  Go wall families hung forever on a pump that reported and kept
  waiting: measured, three children parked in wait4, one orphaned past
  its grandparent's death. With it the identity wall passes in 0.6s,
  children dying in 10ms with their sentences.
  The sentence reaches the verdict list on all four backends: harness.rs for
  GTK and WinUI, `kaya_fault` plus a `fault` slot on `KayaHostApi` for SwiftUI
  mac and iOS, `KayaPresent.fault()` for Compose. All three harnesses also
  RETRACT the in-flight attempt, because `poll` ends the moment a fault latches
  and the read it was holding is therefore not final; harness.rs gained that on
  2026-08-21 after a watched negative showed its verdict leading with
  `label#0 reads "0 matches", wanted "3 matches"` and naming the real cause
  second — this entry's own complaint, one layer down.
  THE WALL IS RUNG 1, not a gate anyone must remember: `fault::tests` is a
  source census over capi.rs, scene.rs, winui/mod.rs and gtk.rs read through
  `include_str!` (so it cannot read a stale copy, and it censuses the
  Windows-only body on every platform), and it runs in
  `cargo test -p kaya --features harness`.
  Watched negative, mac: `file_dialog_retire` perturbed to hold the slot, so the
  filedialog scene's second picker meets a live first one. The leg answers
  `KAYA_SELFTEST: FAILED (kaya: file dialog 1 is already live — one per
  process; show the next from the first's result handler)` instead of dying.
  KEY: fault.rs, fault::guard, fault::watch, nounwind boundary, rootprobe exit

- ~~**DEFECT (rare, Windows) — the IME refusal path can ABORT the process.**~~
  — FIXED 2026-08-21. Measured 2026-08-09 in the ranges scene on WinUI: the
  scene starts a composition, asks for a selection, and the core CORRECTLY
  refuses it (`select_range refused: ime_composition`, the ratified D4 rule) —
  and then an apply op into the RichEditBox failed with
  `HRESULT(0x8000FFFF) "Catastrophic failure"`, which panicked at
  `drain_transactions`' `apply(core, op).expect(…)` inside a function that
  cannot unwind, so the process aborted (exit 0xC0000409) rather than failing
  the leg. Its twin on the undo path, `deliver_undo`'s
  `.expect("kaya: applying an undo op failed")`, had the same shape.
  BOTH `.expect`s ARE GONE. Each site now names the op and reports through
  crates/kaya/src/fault.rs — `kaya: applying <op-head> failed: <hresult>` — and
  each body runs under `fault::guard`, so the leg REDDENS carrying the
  harness's step list. A third instance in the same function, the menu-chrome
  rebuild's `.expect`, went with them. Watched negatives on the windows lane
  force `E_UNEXPECTED` at each site: `ranges_rust` answers
  `KAYA_SELFTEST: FAILED (kaya: applying HighlightRanges { … } failed: … (0x8000FFFF))`
  and `undo_rust` answers the same for `applying undo op SetProp { … }`, both
  with `EXIT=1`.
  THE FIRST QUESTION THIS ENTRY ASKED IS ANSWERED, AND THE ANSWER IS NO: the
  refusal does NOT leave the rich edit control in a state the next op cannot
  survive, so there is nothing for the refusal to restore. 20 unperturbed runs
  of `ranges_rust` passed with the refusal on every one and zero apply faults;
  a probe driving the next op (`reveal_range`) into the same control with the
  composition still live passed 5/5, and a probe adding the heaviest write
  (`highlight_ranges` — a CharacterFormat pass over the whole story) passed
  5/5. Reading the scene's own step list says where the failing op could have
  come from instead: the refused `select_range` is the LAST apply into that
  control, so the next one can only have arrived from teardown, where the
  composition's forced finalisation raises TextChanged, the guest folds
  `Msg::Edited`, and an apply into a XAML tree in rundown answers
  `E_UNEXPECTED`. That is a race with shutdown, not a poisoned control.
  HONEST LIMIT: the abort itself did not reproduce in 25 runs, which is not
  enough to call a 1-in-5 gone. What is true either way is that a recurrence
  now names the op and the HRESULT instead of destroying the evidence.

- ~~**stall-compose is timing-sensitive and fails ~1 run in 11**~~ (measured
  2026-08-07) — FIXED 2026-08-21 by taking the assertion off the absence
  that ends. The arithmetic, measured this time rather than guessed: a
  stall is pending work untouched for KAYA_STALL_MS (1000ms), the pending
  work is the harness's SECOND click, and so the leg passed only while
  gap(click#0 -> click#1) + 1000ms stayed under the guests' 2500ms block.
  That gap is the harness's own two round trips through the UI thread and
  it grows with the machine: 404-595ms idle, 1823/2542/2840ms under 24
  burners, and the 2542ms run reproduced the ledger's failure exactly —
  the ping landing after the block had already ended, so nothing was ever
  pending while the app thread was away. tools/scenes/stall.steps now
  asks expect_stall ONCE, of the wedge, whose handler blocks for a day so
  the click it strands is pending for as long as the assertion needs; the
  bounded block keeps the two claims that never raced, that it came back
  with nothing dropped and that the watchdog took its reading back.
  Verbs unchanged, so no interpreter moved. Reshaped scene under 32
  burners: 5/5 PASS including gaps of 2751ms and 2889ms, both guaranteed
  reds before. BOTH directions watched failing with the watchdog
  perturbed (Verdict::Stalled storing nothing; a pending/claimed pair
  blind to the consumer), each rebuilt and run as a real leg. Beside it,
  KayaCompose.kt's kayaAwaitAnswer no longer measures its silent timeout
  in ITERATIONS — `repeat(60) { Thread.sleep(5) }` is "300ms" that
  measured 2400ms under load — which was the larger half of that gap.
  Full account in docs/traps.md, "A scene that asserts a BOUNDED absence
  is racing the machine".
  KEY: stall.steps, expect_stall, expect_no_stall, kayaAwaitAnswer,
  KAYA_STALL_MS, stall-compose, stall-jvm, stall-go
- ~~**The Swift iOS bundle is not self-contained**~~ (measured 2026-08-07
  while landing Go on iOS, by a negative test aimed at something else)
  — FIXED 2026-08-19, both halves, in tools/ios/run-sim.sh's swift
  suite: the link names `"$TARGET_DIR/libkaya.a"` by path the way the Go
  arm's `#cgo ios` line does, and every `${guest}swift-bin` is
  `build-id.sh --verify`'d before a bundle is made — the Go arm's own
  test one suite down, moved up.
  WATCHED FAILING against the real toolchain, one guest linked both
  ways: with `-L … -lkaya` the binary carries `otool -L
  …/target/aarch64-apple-ios-sim/debug/deps/libkaya.dylib`, an absolute
  build-machine path outside the bundle, and the new verify refuses it
  ("NO build id — nothing here was built from core", rc 1); with the
  archive named by path `otool -L` lists no libkaya at all and the
  verify passes.
  As measured: the Go arm proved that linking `-L … -lkaya` instead of
  naming the archive by path still BUILDS, and `otool -L` then shows the
  binary naming an absolute build-machine path to `…/deps/libkaya.dylib`
  — which is what the SWIFT iOS leg shipped. It worked only because
  the lane builds and runs on one machine.
- ~~**guests/go/filedialog/filedialog.go computes its scene directory from a
  bare `os.TempDir()`**~~ — FIXED 2026-08-17, together with the doctrine
  that decides it. The guest now branches in `sceneRoot()` and asks the
  HOST for the mobile locations through `kaya.Env` — Android's
  `EXTERNAL_STORAGE`/Documents, iOS's `HOME`/Documents — keeping
  `os.TempDir` as the DESKTOP fallback only, where the guest owns main
  and Go's copy of the environment is the host's. Its header used to
  argue the opposite ("Go's own answer to where is temp"); that argument
  lost to the measurement behind docs/go-mobile-plan.md D2 — a
  `-buildmode=c-shared` library is loaded rather than exec'd, so Go's
  environment is empty forever on Android and `os.TempDir` answers with
  its hardcoded `/tmp`, which is not a place an Android app may write.
  Nothing errors; the files just go where nothing looks. The rule is now
  stated in DESIGN.md's Binding conventions (a guest asks KAYA for
  platform locations, never the language runtime's snapshot) and
  tools/check-go-env.sh enforces the shape: a bare `os.TempDir` is red,
  and it is legal only as the fallback of a function that branches on
  `runtime.GOOS`. The defect this entry filed — the iOS leg landing on
  a guest that writes where the picker cannot look — can no longer be
  written.


- ~~**DEFECT — the handle bindings' transaction liveness check tests
  `closed` but not the THREAD**~~ (FIXED 2026-08-21: Go, Java, C# and
  Swift call a `requireAppThread` at the SAME write chokepoint that
  tests `closed` AND at the build entry — the second site is not
  redundant, since a background `Build` whose body writes nothing
  reaches no chokepoint at all, and that is the shape an async
  continuation which does not know about `Post` actually takes. The
  dispatch loop claims the thread on the way in; the claim is LAZY
  (zero until then), matching python's `_app_thread = None` arm, so
  the guest's opening build on the main thread is still allowed. All
  four print the ambient bindings' own sentence, naming the post as
  the way out. Rust needs nothing: `Tx` is `!Send`/`!Sync` and the
  compile_fail doctest pins it. GO HAD NO THREAD IDENTITY TO READ and
  the spelling was decided by measurement — a goroutine id parsed out
  of `runtime.Stack` costs 1.2us shallow and 4.0us twelve frames
  down against 13ns for `pthread_self()` through cgo, and the gate is
  per RECORD — so `App.Serve` now calls `runtime.LockOSThread()` and
  the OS thread answers for the goroutine exactly. Behaviour pinned in
  bindings/go/app_test.go's TestATransactionRefusesAnotherGoroutine
  and guests/csharp/AbortCheck.cs's WrongThread, both watched failing.
  GUARD: tools/check-tx-liveness.sh's wrong-thread census — five facts
  per handle binding read out of EXTRACTED BODIES rather than grepped
  by name, because `alive()` is also the ASSET handle's liveness check
  in Java and Swift and comes first in both files; it refuses a
  verdict if the walk and the table disagree, and four self-tests
  perturb copies with counts printed on every run.)
- Two smaller findings from the same research: CPython's
  `PyGILState_Ensure`-during-finalization hang would compound the known
  exit hang at crates/kaya/src/harness.rs:1832-1854 if Python ever runs
  on mobile; and signal-handler ordering (Rust std's stack guard, a
  guest runtime's handlers, the host crash reporter) is a three-way
  negotiation nobody currently owns — it becomes real the moment a
  second runtime lives in the process.


- **A todos-c leg hung for 180s once on linux/x11 (2026-08-07) and has
  not reproduced.** It died at the FIRST assertion — the guest never
  came up at all — inside a full matrix; the leg then passed in the
  record matrix minutes earlier and in five consecutive targeted runs
  afterwards (10 legs, 1-2s each). Recorded so the second occurrence
  starts from here rather than from scratch: what to capture next time
  is the guest's state while it hangs (is the process alive? did it
  reach the GTK main loop? does the harness handshake show?), because
  a 180s stop at step one is a startup deadlock, not a slow scene.


- **Undo follow-ups carried out of the depth slice (2026-08-04).**
  CLOSED 2026-08-05 by the completion pass, which took all of them in
  one slice rather than accumulating stages. One is a ratification the
  maintainer owns and is stated as a proposal, not a change; the rest
  are done or answered from evidence. Commit forthcoming; the working
  record is docs/probes/undo-completion.md.
  - ~~**A fully-undone episode is not redoable.**~~ **FIXED.** A walk
    that reaches the run's start now CLOSES the episode and pushes it
    onto the redo side (`Scene::note_native_undo`), so it redoes through
    the same machinery a coarsely-undone episode already used — its
    after-image written by the core, named by the same `redone`
    occurrence. No wire moved and no backend was touched: every arm asks
    the core for the route first, so `route_redo` answering `Core` where
    it answered `Nothing` changes behaviour on all five.
    The parenthetical in the old entry was wrong and is worth keeping
    for the correction: the native tier's own redo does NOT cover for
    it while the field keeps focus — kaya's Edit>Redo consumes the
    command and, unbanked, routes it to `Nothing`.
    Pinned by two unit tests beside the ledger tests and by
    tools/scenes/undo.steps, which reads the ENABLEMENT before
    activating (unbanked, the first failure is `menu "Edit>Redo" reads
    "disabled", wanted "enabled"` — watched, with the banking reverted
    and the tree rebuilt).
  - ~~**A stamped copy's typing is not banked**~~ — SHIPPED 2026-08-05 in
    `1d2cf95` ("rows join the ledger: the texts run carries a path, the
    stamp keeps its map, and no field is beneath undo"). Option A is in
    the tree: crates/kaya/src/spec.rs:275 reads `texts: groups(i64 size,
    i64 id, i64 path_len, path_len key values, str text)` and :2001-2007
    spells out the identity rule (path_len 0 = a live widget id, a
    non-empty path = the TEMPLATE NODE of a stamped copy addressed by
    that key path). The ruling below is the record of how it was decided;
    it is no longer a plan.
    As MEASURED, and it was a
    RATIFICATION the maintainer owns, so the tree was unchanged on it.
    The deciding fact: the `undone`/`redone` payload's `texts` run is
    fixed-arity PAIRS (`I64 widget id, Str` — spec.rs, wire.rs's one
    encoder), while `entries`/`orders` are arity-first GROUPS that can
    carry an instance path. A stamped copy's identity on that channel is
    `(template node, key path)`, so an instance field is NOT addressable
    on the existing wire.
    The core half alone is cheap — `run_body` already builds the
    template-node-to-copy map while stamping and discards it — but
    building only that would restore the widget while handing the app a
    pair naming an id it cannot resolve, which breaks D5's "this record
    is the ONLY thing the app hears" silently. The options (A: make
    `texts` arity-first, hash moves, no backend cost; B: ratify
    native-tier-only for stamped fields, with the reactive doctrine's
    own answer — bind the row's text to a record field and the `entries`
    run already carries it; C: carry the internal id, named only so it
    is not rediscovered) are written out with their bills in
    docs/probes/undo-completion.md §ITEM 2.
    **RULED 2026-08-06, option A (the maintainer): `texts` becomes an
    arity-first group like its two siblings, instance paths join the
    channel, the spec hash moves, the eight bindings' delta decode and
    the folding guests move with it, and no backend moves (measured,
    not assumed). Stamped-row typing then joins the ledger with the
    same guarantees as everything else — the reactive doctrine's own
    answer, since text is app state everywhere else in the design.
    Ships as the final undo slice, immediately after this one.** —
    and it did, the same day: `1d2cf95`.
  - ~~**note_native_undo has no redo twin.**~~ **RESOLVED BY EVIDENCE.**
    The item said "revisit with the first arm whose platform
    distinguishes them"; all five do, and every one already feeds the
    distinct query into `route_redo`, which is where the distinction is
    consumed. The sample's third argument is not "can this walk go on" —
    it is the EXHAUSTED-BACKWARD-WALK test, and a `canRedo` there would
    read false at the end of a forward walk and send the core backwards.
    Three arms say so independently at their own call sites
    (KayaSwiftUI.swift, KayaCompose.kt, gtk.rs — which further refuses
    to report a redo that moved nothing). The forward analogue is
    unreachable for A1's reason: the platform's redo stack is created by
    the backward walk and reaches exactly as far as it came back.
  - ~~**The interpreter now writes a node's text on a routed native
    undo.**~~ **ANSWERED BY THE FAN-OUT.** The "second look when another
    arm needs the same move" happened: no other arm needs it, and each
    measured why. iOS deliberately does NOT write the node (UIKit's undo
    is an ordinary text replacement, so the binding setter already ran);
    Compose does not either (the undo moves the shared TextFieldState);
    GTK and WinUI own raw controls. The mac write is §3a's rule where
    §3a's premise fails — a declarative layer between the widget and the
    model — and it is now paired with a gate
    (tools/check-native-undo.sh) rather than with a note.

  From the fresh-key breadth arms (2026-08-05), a doctrine question
  for the maintainer — RULED same day, option B: the entry/milestone2
  carve-out covers the event-receiving mechanism only (DESIGN.md,
  Binding conventions, has the ratified scope); construction and
  collection idioms graduate to sugar. Entry graduates first,
  milestone2 rides the next slice, and the gate clause extends to it
  then.
  - **The entry/milestone2 tier question is RULED and APPLIED; what is
    left is one gate clause.** ~~What tier does the entry scene sit at,
    per language — and why is the tree split?~~ — ANSWERED 2026-08-05
    (option B, above) and applied since: both guests carry the ratified
    scope in their own headers ("ONE OF TWO RUST GUESTS ON THE RAW EVENT
    SURFACE … Construction is the ordinary sugar either way — the
    carve-out is the event mechanism, not the tree"), and the
    CONSTRUCTION half is pinned by a gate — tools/guest-floor.py sweeps
    every non-C guest for floor spellings with an empty exemption table
    and reports zero hits.
    STILL OPEN, and it is the only thing left here: nothing in tools/
    names entry and milestone2 as THE two raw-event guests, so a third
    could join or one could quietly graduate and no gate would notice.
    One clause beside guest-floor.py's sweep closes it.
    KEY: raw event surface, entry.rs, milestone2.rs, guest-floor,
    documented floor, occurrence loop
    As found: DESIGN.md sanctions entry and milestone2 as "the
    documented floor" for the raw occurrence loop, and four entry
    guests (rust, swift, ocaml, haskell) are spelled at the explicit
    widget floor with hand-counted keys — but python's is
    sugar-constructed, and go/csharp/java sit in between. The
    fresh-key slice ruled conservatively: entry keeps hand-spelled
    keys in ALL EIGHT languages (uniform spelling for a documentation
    scene; four arms' adoptions were reverted unrun). The open call:
    either the entry guests all migrate to the construction floor
    (making the demonstration uniform), or the "documented floor"
    carve-out is narrowed to the occurrence loop alone and the
    construction/collection spelling graduates to sugar everywhere.
    Whichever way, the carve-out should be stated per DESIGN.md's
    Binding-conventions rule, and a gate clause should pin the chosen
    tier so the split cannot silently re-open.

  From the milestone2 graduation (2026-08-05):
  - **CLOSED 2026-08-07 — GUARD GAP: the harness resolves widgets by
    registry, so a leg cannot see a widget that never got parented.**
    Proven by the defect it hid: Swift's milestone2 window rendered TWO
    widgets (the step button and status label) instead of its full UI
    for milestones, with every leg green, because `kind#index` targets
    resolve against per-kind registries populated at create/stamp time
    (KayaSwiftUI.swift:410-431) — never by walking the mounted tree.
    An unparented widget answers reads, produces expected strings, and
    displays nothing.

    The entry asked for a HARNESS-level assertion in both
    interpreters. It was built one layer lower instead, and the reason
    is the reason it is now free: `Scene::apply` is the funnel for all
    five backends (gtk.rs:1079/:6412, winui/mod.rs:829, capi.rs:2335
    for the two interpreters), so ONE implementation covers nine guest
    languages, fires at BUILD time rather than read time — which
    catches an orphan no scene happens to name — and fires in a real
    app that never runs the harness, which a harness-side wall never
    could. The rule the core now enforces:

    > A widget created in a transaction must be reachable from a
    > mounted root by the end of that transaction.

    `crates/kaya/src/scene.rs`: `parent_of` (child -> parent, live
    zone), `mounted_windows` widened from a set to surface -> its root
    widget, and `first_unreachable` at the barrier beside the menu
    domain check. Batch-scoped, not a global sweep, because the core
    never prunes `self.widgets` — DestroyWindow and PopEntry drop the
    surface and leave the ids (that leak is real and still open; see
    the entry below). 14 tests, 4 perturbations watched failing
    (barrier off -> 6 negatives fail; the perturbation helper neutered
    -> the two shipped-defect negatives fail on their substitution
    count rather than passing vacuously; DestroyWindow keeping its dead
    root -> 1 fails; the cycle refusal off -> 1 fails and the bounded
    walk still terminates).

    WHAT IT DOES NOT COVER, so nobody reads it as total: an orphan made
    by a BACKEND — one that receives `ApplyOp::AddChild` and fails to
    reparent — is invisible to the core, which sees the op and not the
    toolkit's tree. Only GTK's `WidgetExt::root()`, WinUI's `XamlRoot`
    and the interpreters' `parents` maps can see that one. No such
    defect is on record; all three recorded instances were made above
    the core, in a binding. That tier stays open below.
  - ~~**The sibling suspicion was right, and a THIRD instance was still
    live at HEAD.**~~ — FIXED 2026-08-07, see the note below this
    paragraph. `guests/swift/menus.swift` was fixed by eye in
    aadbe9e. `guests/swift/feed.swift:27-55` was not: `promote`,
    `status` and `list` were built at ambient parent 0 and only
    MENTIONED inside `tx.row { }`, whose result builder discards a bare
    expression — so the mounted row had no children at all and
    `feed-swift-swiftui` passed every leg against an invisible window
    for two weeks. The wall's first run named it in one line, with no
    debugging: the whole mac lane came back 257 PASS / 1 FAIL and the
    one failure printed which widget and why.

    ~~OPEN — the fix is one guest file, and the wall arm does not own
    guests/.~~ — FIXED 2026-08-07 in `11bde48`, the same commit that
    landed the orphan wall. `guests/swift/feed.swift:27-55` now declares
    every child inside `tx.row { }` and carries the reason at the site
    ("a widget parents at CREATION, and a bare expression never reaches
    buildExpression"). The correction is aadbe9e's: declare each child
    WHERE IT STANDS, inside `tx.row { }`, instead of building it outside
    and naming it within.
  - **STILL OPEN — the core never prunes `self.widgets`.**
    `DestroyWindow` (scene.rs) removes the window, its nav stacks, its
    sections and its shortcuts, and touches `self.widgets` not at all;
    `PopEntry` is the same. A destroyed tree's live widget ids stay in
    the map forever. Harmless today and deliberately routed around (the
    reachability barrier is batch-scoped for exactly this reason, and a
    test pins that a destroyed window's widgets are not re-accused),
    but it is a leak in a long-running app that opens and closes
    windows.
  - The Swift binding's template zone never pushed a parenting frame
    for forEach/when bodies (fixed 2026-08-05 in the graduation: an
    inTemplateBody frame at all four combinators, matching Java's
    always-present barrier). Kept here as the failure-class record:
    the defect survived because NO Swift guest had ever declared a For
    inside a template container — first-use-of-a-combination holes are
    what the scene matrix's breadth is for.

  From the fresh-key depth arm (2026-08-05):
  - ~~**DEFECT — a derived signal is not recomputed after an undo.**~~
    **RETRACTED 2026-08-06, ratified by the maintainer — a false alarm
    from call-graph reading, and the record stays because the next
    reader will make the same inference.** The claim was: absorb_undo
    never calls recompute_derived, therefore a derived label goes
    stale when undo restores or removes entries. The claim's premise
    is true and its conclusion is false: a derived write is an
    ordinary WriteSignal batched into the SAME transaction as its
    mutation (recompute_derived pushes unconditionally — no cache, no
    skip), and Scene::bank_group banks EVERY dirty signal into both
    directions of the step, so undo restores the derived value
    together with the collection it derives from. They cannot
    disagree. The C# and Swift absorb comments said this all along;
    the resolution slice propagates that comment to the six bindings
    that skip silently, and the todos scene gains an undoable step so
    the correct behavior is pinned by the matrix, not trusted.
    ONE RESIDUAL, real but unconstructible today: a derive declared
    AFTER a step was banked is absent from that step's signal set, so
    undoing past its declaration leaves it inconsistent until the
    next mutation. Every guest declares derives in the opening build;
    if a scene ever declares one late, this line is the warning.
  - **Residual, taken deliberately: the toolkit's child order after an
    undo restore is asserted at the app's mirror (the keys label), not
    at the toolkit.** `expect_order` would need the For's container to
    be the only column (the reorder root-as-row trick) across all 8
    guests. Core-side, an undo's re-insert and re-order travel the
    same `apply_delta` path the reorder scene already exercises at the
    toolkit.

  Two more carried out of the fan-out (2026-08-04), both gate gaps
  rather than behavior, both CLOSED:
  - ~~**check-steps is blind to the C floor.**~~ **FIXED 2026-08-05**
    (`sweep_c_floor` in tools/check-steps.sh). Not a row in the existing
    per-language sweep, and the gate says why: that sweep demands a MAC
    leg for every scene in mac's SCENES whose guest file exists, and the
    C floor deliberately carries a different scene set per lane — a `c`
    row there would demand ten mac legs nobody intended. It is swept
    instead from the two declarations the floor actually has: every
    scene guests/c/Makefile builds must be RUN by some lane (keyed on
    the binary path `c-guests/<scene>`, the one signature all three leg
    spellings share), a runner that NAMES the C scenes it builds must
    run each of them, and a leg pointing at a binary the Makefile never
    builds is refused. Watched failing three ways — the mac undo leg
    deleted (both clauses fire), the linux todos leg deleted, a leg
    re-pointed at a typo — each restored by sha256.
  - ~~**The shared scene's stated D5 text-run proof cannot fail.**~~
    **FIXED 2026-08-05 by the fresh-key depth arm**, which reshaped
    tools/scenes/undo.steps exactly as this entry asked: the add's
    empty-draft refusal now reads the app's own draft at the one moment
    the app's copy and the widget's disagree. Watched failing three ways
    on the mac leg (the whole `delta.texts` fold deleted, the undone
    half alone, the redone half alone), so both directions of the run
    are independently load-bearing.



- ~~**DEFECT — filedialog_java is a coin flip on windows**~~ — FIXED
  2026-08-03, and GUARDED. The per-dialog STA thread ran
  `CoUninitialize()` the moment `Show()` returned, which "forces all
  RPC connections on the thread to close" while the Shell's own
  workers still held proxies into that apartment, so RPCRT4 raised
  RPC_E_DISCONNECTED (0x80010108) on a comdlg32 worker. Only the JVM
  turned that into a fatal error. There is now ONE dialog apartment
  per process, started at the first pick, pumping, never uninitialized
  — `dialog_apartment` in crates/kaya/src/winui/mod.rs carries the
  numbers. The measured grace period (the other candidate remedy) is
  recorded there too, and rejected: 5ms still failed 2 of 15.
  THE GUARD IS THE SCENE ITSELF. A vectored handler counts
  first-chance RPC_E_DISCONNECTED for every harness build, and the
  WinUI `Stage::finish` fails the scene on a non-zero count in every
  language. Watched failing: with the defect put back, the RUST leg —
  which passed 10/10 on that same defect before the guard existed —
  went 6/12 red, each naming the mechanism. 145/145 with it armed, so
  its false-positive rate on this lane is zero.
  READ THE TRAP BEFORE RE-MEASURING ANYTHING LIKE THIS
  (docs/traps.md, §"A windows race can stop reproducing"): the defect
  reproduced 8/10 at 20:00 and 0/10 on the SAME BUILD an hour later.
  It comes back under load.

- ~~**The step-failed line exists in TWO of the three harnesses**~~
  (filed 2026-08-03 when it was one; crates/kaya/src/harness.rs got it
  2026-08-10 in `47bd2ab`) — FIXED 2026-08-21: KayaCompose.kt's
  bounded-retry wrapper prints `KAYA_HARNESS: step-failed <text>` on the
  same `Log.i("kaya", ...)` writer as its step trace, byte-identical to
  the other two, and the three are no longer compared by eye —
  tools/check-verbs.sh holds them level in two clauses: the line is
  present in all three WITH the failure text interpolated (a fixed
  sentence names no cause), and in the two interpreters at least one such
  print sits AFTER the last `retryStep = true`, i.e. in the branch that
  runs when the retry gives up. That second clause is the one with teeth:
  KayaSwiftUI.swift prints the same line from its clip-breach arm, so
  presence alone was satisfiable by a copy on a path the wrapper never
  takes. Four watched negatives, all red (deleting the Kotlin line,
  replacing its interpolation with a fixed sentence, deleting ONLY the
  Swift wrapper's copy, deleting the Rust line). Seen firing on a real
  android leg: the line lands one step before the verdict, carrying the
  same sentence.
- **Follow-ups from the WinUI chord-drop fix (2026-08-03).** The race:
  chords were dispatched over TWO routes split by leaf kind (79dcd1d),
  and the XAML-accelerator route PERMANENTLY DROPS a chord arriving
  within ~45ms of the previous chord's activation — measured 42% per
  commands leg, language-independent, fixed by dispatching every
  catalog chord from the thread key hook against core.menu_shortcuts
  (the same table that gates the harness verb), 0/46 after. Left open,
  in priority order:
  - A text gate pinning the one-route rule: key_hook's dispatch names
    all three of MenuItemKind::{Action,Toggle,RadioOption} and no
    consume path is conditional on kind. Cheap check-verbs-style
    clause; the compile-time exhaustive match guards NEW kinds but not
    a deliberate re-split.
  - The echo premise (a programmatic IsChecked set must not raise
    Click) is now load-bearing for radios too and is checked only by
    menu_probe behind KAYA_WINUI_MENU_PROBE. Promote canary 1 out of
    the flag gate, the way assert_chord_premise is unflagged.
  - No scene presses a chord on a DISABLED item; the fixed route makes
    that fully inert (consumed, no stamp, no emit) — believed right,
    unverified live.
  - The same two-route shape exists on GTK (GtkShortcutController),
    SwiftUI (.keyboardShortcut) and Compose. Those lanes are green but
    nobody has measured whether their pass sits on the same
    tens-of-milliseconds gap. One timing probe each (press a chord
    ~20ms after the previous chord's occurrence) before assuming WinUI
    was special.
  - Unexplained: the lane was recorded 145/145 at the WinUI clipboard
    slice, which a stable 42% per-leg rate makes essentially
    impossible. Either that run was an outlier or the VM's timing
    distribution shifted around the ~45ms boundary. The experiment if
    anyone wants it closed: rebuild the exact 48cfbad tree and loop
    commands_rust there.

- ~~**GAP — an `#if os(iOS)` branch in a SWIFT GUEST is invisible to
  every fast gate.**~~ — CLOSED 2026-08-18, and the closing record is
  the "No gate compiles a Swift GUEST for iOS" section further down this
  file (the same gap, found again and written down twice).
  tools/swift-typecheck.sh:160-214 is exactly the loop this asked for:
  it reads IOS_SWIFT_SCENES and IOS_MIN out of tools/ios/run-sim.sh,
  refuses when a shipped guest's source is missing, typechecks each
  against `-sdk iphonesimulator … arm64-apple-ios$ios_min-simulator`,
  and skips with the loud note when there is no simulator SDK.
  As found 2026-08-03 while wiring the iOS clipboard
  legs: tools/swift-typecheck.sh's guest loop compiles the guests for
  macOS only, so the iOS scene_root branch guests/swift/clipboard.swift
  needed (the §7.6 android trap's cousin — the guest and the
  interpreter must agree on $TMP) typechecks nowhere until
  run-sim.sh's own build loop compiles it on a booted pool. The
  interpreter's iOS half earned its typecheck pass for exactly this
  class; the guests deserve the same — an iphonesimulator -typecheck
  loop over guests/swift/*.swift in swift-typecheck.sh, gated the
  same way (skip with the loud note when no simulator SDK exists).
  Cheap; nobody has been burned yet; write it before someone is.

- ~~**Python's lifecycle handlers ran outside a transaction**~~ — FIXED
  2026-07-27, and GUARDED. The dispatch loop wrapped widget and menu
  handlers but called the six lifecycle handlers bare
  (close_requested, window_closed, entry_popped, section_selected,
  back_requested, alert_result), so `destroy_window` inside an
  on_close_requested raised "no ambient transaction" and DESIGN's
  ratified "a handler is a transaction" was false in Python alone. All
  seven sites now share one `App._dispatch`, which also gives the
  lifecycle paths the rollback-and-log discipline they never had.
  WHY NO GATE SAW IT: the scenes passed, because five guests each
  opened a transaction by hand. The workaround was the camouflage. The
  guard is therefore `tools/check-ambient-tx.sh`, which forbids a guest
  from opening one inside a handler — with nothing able to compensate,
  the existing scenes ARE the test.
  SCOPE, stated so nobody widens it carelessly: the defect needs an
  AMBIENT transaction. Go/Java/Swift/C# pass the tx as a parameter, so
  it is not expressible; Haskell opens one explicitly in every handler
  (idiom, uniform, not a workaround); OCaml is ambient and was already
  correct, but has no reliable textual discriminator — its guard, if
  ever wanted, is a behavioural check in the check-abort family.


- Reproducibility, the remainder after 2026-07-26. What landed: the
  container base pinned by digest, opam's rolling index pinned to a
  commit (with the direct packages version-pinned on top), `--locked`
  on every cargo invocation with a check-shell clause holding it,
  check-pins over the ecosystems that have no lockfile at all, and the
  build id — libkaya carries a marker naming the sources it was
  compiled from, every lane `--verify`s what it runs or ships, and
  check-build-id proves both halves live. What did NOT, each for a
  stated reason rather than for lack of time:
  - APT PACKAGE VERSIONS in the container. Freezing them means
    snapshot.debian.org, which is slow and periodically unavailable —
    that trades continuous small drift for an occasional inability to
    rebuild the image at all. trixie is stable, so the drift is point
    releases and security updates, and the security half is drift we
    want. Revisit if a Debian update ever breaks a lane; the fix would
    be to pin the snapshot only for the release that broke.
  - GRADLE DEPENDENCY LOCKING and NUGET packages.lock.json. Both
    ecosystems already name exact versions and resolve them from
    immutable repositories, so a lockfile adds regeneration ceremony
    without adding determinism. check-pins guards the property that
    actually matters (no dynamic version ever enters). Revisit if a
    transitive graph ever surprises us, or on the first supply-chain
    requirement — that is when VERIFICATION metadata (checksums), a
    different feature from locking, starts earning its cost.
  - CABAL FREEZE. The Haskell guests depend only on boot libraries
    (base, bytestring, containers), which ship with the compiler — and
    the two lanes use DIFFERENT compilers (nix's ghc on mac, apt's in
    the container), so a freeze file pinning boot-library versions
    would be wrong on one of them by construction.
  - (CLOSED 2026-07-26.) The build id now reaches all three compiled
    artifacts: libkaya (`core`), the SwiftUI interpreter (`swiftui`,
    both the mac dylib and the iOS one), and the Compose interpreter
    (`compose`, verified inside the apk — an apk is a zip, so the
    verifier reads its dex members, and which classes*.dex a string
    lands in is not stable). Each is keyed on its own sources plus the
    INTERFACE it compiles against, not on the core's implementation, so
    a backend edit does not invalidate an interpreter.
  - BIT-IDENTICAL OUTPUT is not claimed anywhere and is not the goal
    here. The id fingerprints INPUTS: a different id always means
    different sources, but one id does not promise two byte-identical
    binaries (build paths, timestamps, codegen nondeterminism). Real
    output determinism wants -Zremap-path-prefix and friends, and its
    payoff is a shared build cache, which is a packaging-milestone
    concern.
- ~~deploy-win.sh uses `sed` and `awk`~~ — LANDED 2026-07-27 (the
  rewrite and its gate both rode `d1a64fd`). check-shell now bans both
  in COMMAND POSITION across `tools/**/*.sh`, with a self-test that
  scores a real invocation against the word inside another word — the
  first draft flagged "used" in a comment. Heredoc bodies are dropped
  from the scan, because the scanner itself lives in one.
- ~~**`split` and `listdetail` are rust-only, and the per-language
  verdict is still owed**~~ — SWEPT 2026-07-27. Seven new guests
  (python, go, csharp, swift, ocaml, haskell, java), and the verdict
  is DO for all seven: `split` joined SCENES on the three desktop
  runners, `listdetail` rides the same guests on all five lanes, and
  DEPTH_SCENES is empty everywhere.
  SEVEN FILES, NOT FOURTEEN, because a scene selects a SCRIPT, never
  an app: `KAYA_SELFTEST` only names the `.steps` file the harness
  reads, so one guest per language serves both scenes. The one
  assertion that could not be shared is the window title (one app has
  one title), which is why `listdetail.steps` does not make it. Two
  places assumed scene-name == guest-name and had to be taught
  otherwise: the iOS swift loop now takes `scene:guest` entries
  (`listdetail:split`), and the Windows launchers name the guest
  explicitly.
  THE SWEEP PAID FOR ITSELF TWICE, which is the argument this entry
  previously got wrong — it reasoned these guests would "mostly
  re-test the generator". They did not, because the SUGAR is not
  generated:
  - **Python could not declare list-detail at all.** `wire.py` is
    generated from spec.rs and had `tx_set_window_list_detail`, but
    `__init__.py` — the hand-written sugar every Python app uses —
    never threaded the prop through `App.window()` or
    `create_window()`. Fixed. Nothing in eight languages of Rust-only
    scene coverage could have found this.
  - **A list-detail window with an EMPTY stack had no title**, on all
    three backends that build the pane pair themselves (SwiftUI, GTK,
    WinUI): the split arm titled the window from the top entry and
    fell back to the empty string. It read as correct for one reason —
    the only guest running the scene was an example binary named
    `split`, and the scene asserts the title `"split"`, so AppKit's
    process-name fallback matched by coincidence. The Python port
    reported `python3.14`. A NAMING COINCIDENCE HAD BEEN STANDING IN
    FOR THE FEATURE.
  Also learned: `TwoPaneView` is a pri-adjacency control like
  `ProgressBar` (its template needs the XamlControlsResources merge),
  so the Windows go/csharp launchers take the progress shape. With the
  plain shape both crashed at the first `expect_split` with
  0xc000027b, a stowed XAML exception.

- Scene-run coverage, the remaining half: check-steps' wired() now
  demands per-runner LEG SIGNATURES (run $scene- / run "$proto"
  $scene- / run_suite ${scene}_), so a scene absent from a runner
  fails the gate — but a grep signature proves WIRING, not execution.
  Nothing yet proves the exact scene × language × platform tuples
  that actually ran and produced verdicts (a runner can still skip
  legs at runtime); an executed-suite manifest compared against the
  expected tuple set is the missing gate.
  Packaging notes for whoever adds the next scene (walked end to end
  by menus, 2026-07-24): on iOS the swift guest rides
  IOS_SWIFT_SCENES — a bare name, or `scene:guest` where two scenes
  share one app, with bundle and leg derived — while a rust
  example needs its own build+bundle+queue_leg block; Android has one
  apk PER GUEST TIER, each a scene selector keyed on KAYA_SELFTEST —
  milestone2 (the Rust guest: a new scene needs a `mod` + match arm
  in guests/rust/milestone2_android.rs) and milestone2kt (the JVM
  guest: its MainActivity needs the matching arm) — plus a run_apk
  leg per tier; on Windows the name in deploy-win's SCENES derives
  the cross-build, the scp of exe/python/go sources, and the taskkill
  entries, leaving only a tools/guest/run_<scene>_<lang>.cmd per
  language and the run_suite block. A scene whose guests do not all
  exist yet must NOT join SCENES: the per-language surfaces glob for
  sources and must keep failing loudly for the scenes that do exist.
- Recording stills DRIFT across a long scene: the film and the
  harness transcript are anchored at ONE instant, and their clocks
  then run at different rates, so a step's still is progressively
  earlier than the step. Menus (38 steps, ~2.4s of transcript) is the
  first scene long enough to show it — measured 2026-07-24 on iOS:
  the leg's steps span 2.4s of harness time while the same run
  occupies ~1.3s of film, so `step-38` renders a state from before
  `click button#2`. The film itself is complete (t=31.0s of suite-1
  shows the true final frame: `shared`, Publish promoted, the removed
  row gone) — only the mapping is wrong. Same root cause as the
  "anchor implausible" failures on the busiest simulator, where the
  accumulated drift pushes a leg's span past the film's end and the
  extractor (correctly) refuses. Android has the weaker form: it
  anchors at stop time minus duration, and screenrecord drops its
  buffered tail. Fix direction: calibrate rate, not just offset — two
  fiducials AT OPPOSITE ENDS of a film, or a per-leg in-band fiducial —
  rather than trusting one anchor across a whole suite. THE PHRASING IS
  DELIBERATE (sharpened 2026-08-19): iOS already plants two fiducials
  (tools/ios/run-sim.sh — a dark flip and the flip BACK) and they are
  BOTH AT THE START, which makes the anchor survive a recorder that
  attached mid-flip and does nothing at all for the rate. Two fiducials
  at one end is not this item. Windows has a third
  variant: `KAYA_RECORD=1 deploy-win … menus_rust` passed the leg and
  then reported "the capturer produced no frames" — the WGC capturer
  never attached to a window that lives about two seconds.
- Per-binding EMISSION checks (kaya_app_checks.py-style — assert the
  records a construction emits) in Java and Haskell — Go, Swift, C#
  and OCaml already have one (run by tools/check-abort.sh), so this is
  two languages owed, not seven.
  The motivating miss: the Swift binding's containerOf ACCEPTED
  construction-time `spacing:` but never applied it (one commit's
  worth of silently dropped writes) — and no gate could see it,
  because the interpreter's render and its fills observation share
  the node state a wire-dropped write never reaches; recordings were
  the only gate for that class.
- The WinUI bindings have no regeneration gate:
  crates/kaya/src/winui/bindings.rs comes from tools/winui-bindgen, but
  unlike gen-header/gen-bindings/gen-guests there is no `--check`
  proving the checked-in file matches the generator — a hand edit (or a
  filter change without regeneration) goes unnoticed until the next
  regeneration clobbers it. COMPILABILITY is already covered on every
  mac run — `tools/check-targets.sh` cross-compiles the windows target,
  so a broken bindings.rs fails in seconds rather than on the VM. What
  is missing is PROVENANCE: nothing proves the checked-in file is what
  the generator would emit.
- Mount-transaction focus negative test: the Focus command now
  defers until the element is loaded/mapped on WinUI/GTK (the
  materialization class, traps.md), but no scene issues focus IN the
  mount tx — the entry scene focuses from the add fold, long after
  load. The class fix is structural; the missing gate is a scene (or
  an entry-scene opening step) that focuses at mount and asserts
  expect_focused, proving the deferral on all platforms.
- resize_window harness verb — the VERB LANDED with the form-factor
  milestone: `split.steps` drives three REAL resizes and re-asserts the
  presentation on the far side, on all three desktop lanes. WHAT IS
  STILL OWED is narrower than this entry used to claim (corrected
  2026-07-27): no scene re-asserts GEOMETRY across a resize —
  `expect_root_fills` / `expect_shares` / `expect_fills` appear nowhere
  in split.steps — so reflow-under-resize is not a matrix fact even
  though the transition is. Also still the place to watch WinUI's known
  interactive-resize flicker (platform-level; we already avoid the
  transparent-background worst case — keep WinAppSDK current).
- The macOS `back` verb drives the path binding (GTK/WinUI/Compose
  drive real chrome; mac needs a stable handle on NavigationStack's
  private toolbar button).
- Ergonomic: a `kaya::park(&ctx)` keep-alive primitive for static
  (handler-less) scenes, so they don't reach for `Messages::<()>` just
  to block until Shutdown (see traps.md).
- Android recording anchors flake under load: one todos-rust leg
  failed extraction with "anchor implausible (leg spans
  -10106..-6353ms)" — screenrecord buffered its start ~10s, the
  kill-minus-duration arithmetic drifted by that much, and the
  plausibility guard rightly refused to fabricate stills (the scene
  itself passed; a rerun was clean). One transient in dozens of runs,
  but the class is structural: if it recurs, Android earns a
  content-anchored scheme the way iOS earned its appearance-flip
  fiducial — the arithmetic anchor is the last one left.
- bench-encode blob leg: register+reference throughput with an MB/s
  floor, so payload-path structural regressions trip at gate time.
  (Adding it means a second phase in each language's encode_bench
  program + floors in tools/bench-encode.sh — keep it separate from
  the existing rec/s floors, which would otherwise deflate.) The
  table/scroll bench is a separate family and carries no floors by
  design: tools/bench-tables.sh, recorded under
  docs/measurements/README.md.
- Matrix speed, remaining (diminishing returns): a real swiftmodule
  for the Swift bindings; a Windows VM with more cores.
- Windows entry follow-ups: IME contract notes for mobile; the WinUI
  text-flyout-open path is untested.
- Select follow-ons, each waiting on a REAL need: a template
  (For-body) select only gets the stateless index checks — the
  option-count upper bound is live-widget-only (the count map keys
  on live ids); option disabling; multi-select (a different control
  on every platform — checkable menu items, list boxes — probably a
  separate kind); signal-bound OPTION LABELS work today (label text
  binding fans out to the rows), but signal-bound option LISTS
  (dynamic add) are append-only via add_child with no remove.
- Canvas widget (Akhil, 2026-07-22; post-style-guide, before webview):
  a drawing surface. The viable shape is a DISPLAY LIST — the guest
  transmits drawing commands (paths, fills, strokes, transforms, text
  runs) as data; core retains it as a prop; ~~backends replay it into
  the native surface (SwiftUI Canvas, Compose DrawScope, GTK4
  DrawingArea/cairo; WinUI needs Win2D CanvasControl — a new NuGet
  dependency and packaging payload)~~. Callback-per-frame immediate
  mode is REJECTED (8-language FFI churn, divergent frame timing).
  The slippery slope is the op vocabulary (gradients, blend modes,
  images, text shaping) — start with a deliberately minimal op set.
  Pointer-event occurrences on the canvas are a further deferral
  inside this one.
  KEY: canvas, drawing, display list, viewbox, paint role, raster,
  tiny-skia, Win2D, set_drawing, redraw, scale mode, fixed, letterbox,
  rgba, animation, mailbox
  ARCHITECTURE RATIFIED 2026-08-26 (Akhil, after two research rounds
  — docs/canvas-plan.md, which is no longer a draft): THE CORE
  RASTERIZES ITS OWN COMMAND LIST INTO A PIXEL BUFFER AND BACKENDS
  ONLY BLIT IT, through the image machinery they already have. That
  is what strikes the replay clause above: lowering one op list into
  four native drawing APIs is dead (Qt migrated away from it and
  states the payoff as platform-independent pixel exactness; .NET
  MAUI shipped it and its issue record is the cost). The rasterizer
  is a pinned implementation detail — tiny-skia today, vello_cpu
  revisitable when it stabilizes, a one-crate swap with no binding
  churn; GPU rendering for this buffer is refused on principle
  (driver-dependent AA breaks byte-identity and the linux lane has no
  GPU). TEXT IS IN v1, since a chart needs tick labels from the first
  chart, with one shaping engine in the core (harfrust shapes,
  skrifa/read-fonts outline, tiny-skia fills them as paths — the
  crate landscape verified 2026-08-26 against the archived-crate wave,
  since resvg's own rustybuzz/ttf-parser are abandoned,
  RUSTSEC-2026-0206); text is the
  feature that REQUIRES the buffer, because fonts diverge per
  platform both by name resolution and by text engine. FONTS ARE
  ASSETS through the one resolver, with the reserved name
  `kaya/default-font` answered from bytes embedded in libkaya (the
  vendored Sora) and the `kaya/` prefix refused in app packages. The
  ops travel as ordinary tagged values on set_column_headers' shape,
  and Win2D is not needed at all under the buffer.
  DEPTH LANDED 2026-08-26 (phases 1-2, mac only): the `canvas` kind,
  the `set_drawing` record and the five vocabularies are in the spec;
  crates/kaya/src/canvas.rs validates, shapes and rasterizes; the
  SwiftUI backend blits and reports its scale and appearance; the
  three verbs and tools/scenes/canvas.steps are green on the mac lane
  (`canvas-rust-swiftui`).
  BREADTH LANDED 2026-08-26 (phase 3): GTK, WinUI and Compose blit —
  no backend declares `depth_stub("canvas")` any more, and each reports
  its own scale and appearance through the two channels the mac added.
  The canvas scene is wired on all five lanes (`canvas-rust` on linux,
  `canvas_rust` on windows, `canvas-compose` on android,
  `canvas-rust-swiftui` on mac, and `canvas` from the iOS swift suite
  over the new guests/swift/canvas.swift).
  THE CHART LANDED 2026-08-27 (phase 4), which is the artifact this
  whole feature exists to feed: guests/python/portfolio.py's dashboard
  draws the book valued at each of the last 90 days' prices, as app
  arithmetic over a new derived asset (guests/assets/market/prices.csv,
  which tools/gen-market.py now writes beside the ledger) spoken in the
  op vocabulary and the paint roles — no new core surface. The scene
  freezes the three verbs plus the drawing's accessible name on the
  three desktop lanes, at rest and after the tick, where the op count
  and ink bounds hold still and only the hash moves. THE CHART TIES OUT
  the way the ledger does: the history's last day IS the book's live
  prices, so the series' last point is label#0's money to the byte —
  refused by the generator, by check-assets' new C11 and by the guest at
  startup, all three watched red. BOTH MODES WERE LOOKED AT, by
  rendering the core's own display raster per mode rather than switching
  the host's appearance (docs/measurements/canvas-palette-look-2026-08-27.txt):
  no palette value needed nudging, dark measures stronger than light on
  six of seven contrast rows, and the one open question is whether the
  plot ground should read RECESSED in dark when it reads as a raised
  card in light — the tables beside it draw their card in the platform's
  own token, so a dark host may show the chart sitting darker than they
  do. The headline stays open for what is
  left: the LOOKS RULING on the captures (mac captured 2026-08-27;
  linux, windows, and the two mobile lanes when packaging reaches them),
  and PHASE 5, the matrix — which is also the only thing
  that can answer §11's measure-at-implementation #2 (the WinUI BGRA
  swizzle) and #4 (what GDK's scale returns at a fraction), since both
  are readings no host that types `cargo check` performs. Phase 4 did
  NOT build ruling 12's size-mode declaration and deliberately so: no
  prop exists in the spec, the core rasterizes at the viewbox and all
  four backends still stretch, so a binding surface alone would spell
  `scale` in eight languages over a core that letterboxes in none of
  them. The chart is laid out at its NATURAL SIZE instead, the one
  geometry where the three modes coincide (see the stretch entry).
  POST-DEPTH RULINGS 2026-08-26 (Akhil, after the animation research
  round — docs/canvas-plan.md §0 rows 12-16, where each is recorded
  with its reasoning). Five, and one supersedes ratified text.
  (12) SIZE POLICY, the unified framing: a drawing is a FUNCTION OF
  SIZE, delivered as a REDRAW OCCURRENCE with latest-wins mailbox
  semantics and frame dropping; `scale` and `fixed` are DECLARATIONS
  THAT THE FUNCTION IS CONSTANT, which licenses the core to answer a
  size change by re-rasterizing under a transform with no round trip —
  uniform-fit letterbox for `scale`, never-adapt letterbox for
  `fixed`. Default is `scale` on a self-sufficiency argument (it is the
  only mode available to a guest that wired no handler); `redraw` is
  the charting and game mode; `fixed` is how a drawing refuses coercion
  from a stretch-aligned parent. This STRIKES docs/canvas-plan.md §3.2's rules
  2 and 3 and §12's rejection of a resize occurrence, and it is why the
  stretch entry below is re-framed rather than closed (§3.2.1).
  (13) PAINT: literal RGBA is the FLOOR, since a quadruple of bytes is
  trivially byte-identical and therefore costs the frozen hash nothing
  — the escalation gate was protecting an observable a literal cannot
  threaten. The semantic roles stay, as MODE-AWARE sugar over kaya's
  palette, resolved IN THE CORE because the appearance bit is not known
  when the guest declares. And the palette's VALUES are tweakable
  pixels, never again a ruling. First site to move: the paint enum
  comment in crates/kaya/src/spec.rs, which reads "PAINT IS A ROLE,
  NEVER RGB (§3.4) ... Literal RGB is the named escalation".
  (14) ANIMATION IS IN SCOPE of the canvas, games and simulations
  included, on a measured basis: the whole-list resubmit is 0.019ms,
  0.1% of a frame and ~370x cheaper than that frame's raster, so the
  display list is not the ceiling — RASTER is (14.2ms desktop-class,
  30.3ms phone-class on an M5 Pro; tiny-skia's antialiased path fill is
  11-17x its aliased fill, which is the whole ceiling). Levers in
  order: multithreaded band tiling (measured 3.4x, zero API change), a
  per-canvas aliasing knob, damage tracking, vello_cpu as a standing
  evaluation, and a GPU DISPLAY path reserved-not-planned — the harness
  already tolerates that one, since the canonical hash is CPU by
  definition and expect_ink samples flat-fill interiors (docs/canvas-plan.md
  §15).
  (15) That 0.019ms is a RUST number. Python and Java get measured
  before breadth hardens, and the PACKED ENCODING LANE triggers PER
  BINDING on measured need, with its layout GENERATOR-EMITTED rather
  than hand-copied into eight files (the file-modes trap).
  (16) The zero-copy arm was never a second canvas — it is the IMAGE
  widget's high-rate update path; see the Vello entry, re-worded the
  same day (docs/canvas-plan.md §16).
- ~~**DEPTH STUB: canvas on gtk** — the blit is the breadth phase
  (docs/canvas-plan.md §8, §11 phase 3): a GdkMemoryTexture over the
  core's premultiplied RGBA8 buffer in a GtkPicture, the raw-pixel
  sibling of the encoded `gdk::Texture::from_bytes` arm already there,
  plus the GdkTexture download that answers expect_ink. Closed when
  tools/linux/run-suites.sh wires the canvas legs and they pass.
  KEY: canvas, set_drawing, canvas_probe, canvas_ink, GdkMemoryTexture~~
  LANDED 2026-08-26 (breadth): `gdk::MemoryTexture` with
  `R8g8b8a8Premultiplied` — tiny-skia's own layout, no swizzle — behind
  `Snapshot::to_paintable`, which is where the LOGICAL size goes since a
  GdkTexture carries no scale and GtkPicture's natural size is the
  texture's pixels. `canvas_ink` renders the toplevel's WidgetPaintable
  through the real GSK renderer and downloads it, measuring the
  pixel-per-logical ratio off the returned texture rather than assuming
  it. Scale is `gdk_surface_get_scale`'s DOUBLE (§5 rule 1) and the
  appearance is `AdwStyleManager:dark`, the reading the brand accent
  already takes. `canvas-rust` is wired in tools/linux/run-suites.sh.
- ~~**DEPTH STUB: canvas on winui** — the blit is the breadth phase
  (docs/canvas-plan.md §8, §11 phase 3): a WriteableBitmap whose pixel
  buffer receives the core's premultiplied RGBA8, plus the
  premultiplied-BGRA8 swizzle §11's measure-at-implementation list
  holds open, and RenderTargetBitmap for expect_ink. Closed when
  tools/deploy-win.sh wires the canvas legs and they pass.
  KEY: canvas, set_drawing, canvas_probe, canvas_ink, WriteableBitmap~~
  LANDED 2026-08-26 (breadth): `WriteableBitmap.PixelBuffer` through
  `IBufferByteAccess`, with the RGBA->BGRA swizzle in the one arm that
  has it. The bindings gained WriteableBitmap, RenderTargetBitmap,
  IBuffer, Stretch, ElementTheme and XamlRootChangedEventArgs — four of
  those were vtable PADS whose methods did not exist until their
  argument types were filtered. Scale is
  `XamlRoot.RasterizationScale`, appearance `FrameworkElement.ActualTheme`.
  `canvas_rust` is wired in tools/deploy-win.sh with its launcher.
  THE INK READ WAS RenderTargetBitmap AND IS `PrintWindow` NOW
  (2026-08-26, same day): that API renders (Completed, 300x120) and then
  `GetPixelsAsync` yields NO BUFFER on this VM — for the window root as
  well as the canvas, under both RenderAsync overloads, from a completion
  handler and from a polled operation alike — because the adapter is a
  Red Hat VirtIO GPU DOD, display-only, with no D3D read back
  (docs/traps.md, "RenderTargetBitmap renders and hands back NO PIXELS",
  which carries every dead end and the resolution).
  `canvas_ink` now asks DWM to print the WINDOW —
  `PrintWindow(hwnd, dc, PW_RENDERFULLCONTENT)` into a top-down 32-bit
  DIB — and cuts the canvas's box out of it, mapped by XAML's
  `TransformToVisual` to the window root times `RasterizationScale`,
  plus client-to-screen minus the outer rect. Synchronous, so the
  swallowed completion `Result` and the ~200 outstanding renders the old
  shape left behind are gone by construction: ONE grab per step attempt,
  on the UI thread the read already runs on. NOT a copy of the screen,
  which also works on this adapter but reads a POSITION: the lane tiles
  six legs at KAYA_WIN_SLOT and slots 4 and 5 sit off the bottom of an
  800-tall desktop, where the screen copy measured PURE BLACK while the
  window print passed the leg.
  AND THAT ANSWERS §11's measure-at-implementation #2, the BGRA contract
  on a real VM: the read samples the window's own pixels, so a swizzle
  error would show `F7E3D2` where the scene wants `D2E3F7`. Measured
  `FFFFFF/D2E3F7`, the core's own bytes to the digit — this platform
  converts no colour on the path, so the ±1 the mac needs is slack here.
  KEY: expect_ink, canvas_ink, RenderTargetBitmap, GetPixelsAsync,
  PrintWindow, PW_RENDERFULLCONTENT, VirtIO GPU DOD
- ~~**DEPTH STUB: canvas on compose** — the blit is the breadth phase
  (docs/canvas-plan.md §8, §11 phase 3): an ImageBitmap filled from the
  core's buffer in the KIND_CANVAS render arm, plus PixelCopy or a
  bitmap draw for expect_ink. The wire constants and the three verb
  arms are in already, so only the render and the read-back are
  outstanding. Closed when tools/android/run-emulator.sh wires the
  canvas legs and they pass.
  KEY: canvas, set_drawing, KIND_CANVAS, CANVAS_VOCABULARY,
  expect_drawing_hash~~
  LANDED 2026-08-26 (breadth): `Bitmap.Config.ARGB_8888` is RGBA in
  memory order on Android and premultiplied by default, so
  `copyPixelsFromBuffer` takes the core's buffer with no swizzle. The
  reported scale IS the composition density, which is what makes
  Image's own intrinsic sizing land on the viewbox in dp. `expect_ink`
  is PixelCopy of the real window surface, aimed through the
  window-to-surface offset kayaTextBoxes documents. Two new natives —
  `KayaPresent.presentation` and `KayaPresent.canvasProbe` — registered
  in crates/kaya/src/android.rs. `canvas-compose` is wired in
  tools/android/run-emulator.sh. KayaCompose.kt now stubs NOTHING, so
  its `depthStub` helper is gone (an unused private function fails
  check-detekt); a comment holds the shape for the next depth slice.
- ~~The canvas's ink assertion NAMES THE APPEARANCE, and that is a
  limitation rather than a design (found 2026-08-26, while freezing
  tools/scenes/canvas.steps). `expect_drawing_hash` pins the scale and
  the palette itself, so it is one string on five platforms whatever
  the host is set to; `expect_ink` samples the DISPLAY raster, which
  uses the platform's own light/dark bit, and kaya's chart palette has
  two modes — so the frozen colours would quietly depend on the
  machine's appearance setting. The verb therefore reports the mode it
  sampled (`light FFFFFF/D2E3F7`) and a dark-mode host fails with a
  sentence that says why instead of a bare colour mismatch. What would
  close it: either the harness pins the appearance for a leg the way it
  pins the scale, or the scene carries both modes' strings. Phase 4 is
  where the palette gets looked at hardest in both modes anyway.
  THE APPEARANCE HALF IS STILL OPEN, and a SECOND, unrelated dependence
  on the host was ruled out from under it 2026-08-26: the ink compare is
  now ±1 per channel and the scene freezes the CORE's bytes, because a
  macOS window's backing store carries the DISPLAY's profile and reads
  D2E3F7 back as D2E2F7 while Android reports the core's own bytes
  (docs/canvas-plan.md §7.2's amendment, docs/traps.md's measurement).
  That ruling settles the COLOUR SPACE, not the light/dark mode; the two
  are separate axes and this entry is the second one. Note for whoever
  closes it: the tolerance is exactly ±1 and is NOT the place to absorb
  a mode difference — a dark palette is a different colour, not a
  rounding, and tools/check-verbs.sh pins all three harnesses' constants
  at the ruled value for that reason.
  A THIRD ROUTE OPENED 2026-08-26 with the paint floor (ruling 13,
  docs/canvas-plan.md §3.4): a test figure painted in LITERAL RGBA has
  no appearance dependence to pin, so the mode-sensitivity can be
  designed out of the FIGURE rather than pinned in the harness — which
  also matches expect_ink's inherited discipline of flat, unmistakable
  colours. The roles then keep being what the PORTFOLIO chart is
  painted with, where two-mode legibility is the point.
  KEY: expect_ink, canvas_ink, kayaCanvasAppearance, appearance, palette,
  rgba~~
  CLOSED 2026-08-27, by the second of the two routes this entry named —
  the scene carries both modes' strings:

      expect_ink canvas@chart "15,20 70,63 = light FFFFFF/D2E3F7 dark 16181C/212A35"

  The RHS is alternating mode word and colour run; each harness selects
  the half its own appearance names (`ink_for_mode` in harness.rs,
  `kayaInkForMode` in KayaSwiftUI.swift and KayaCompose.kt) and compares
  it within the SAME ±1, which stays exactly ±1 — this entry's own note
  about not absorbing a mode difference in the tolerance is honoured, and
  check-verbs' four tolerance negatives are untouched. A mode the string
  does not name never matches. The dark pair is DERIVED by the mechanism
  that derived the light one (canvas.rs's
  the_scene_probe_points_are_opaque_and_pinned rasterizes both modes now);
  it was guessed wrong by one on two channels before being derived, which
  is written into the scene comment.
  THE VERDICT IS THE WHOLE LINE on every platform, so a dark mac and a
  light emulator publish byte-identical text — invariant 6 is stronger
  than before, since the old published text was the single mode's and no
  dark host could produce it.
  The third route (a literal-RGBA figure) is NOT taken and is not
  reopened here: the portfolio chart stays painted in ROLES, which is the
  thing two-mode legibility is for.
  AND IT WAS NOT THE ONLY DEFECT ON THIS LINE. Closing it on a dark-mode
  machine surfaced a real bug the light-only string had been hiding for
  the whole milestone: the canvas RENDERED LIGHT IN A DARK WINDOW,
  because the backend's presentation report was dropped before the
  presentation scene existed. Fixed in the same round (capi.rs's
  `PRESENTATION_REPORTED` latch); the mechanism is a CLASS and is written
  up in docs/traps.md, "A presentation-side report that arrives before
  the scene".
  AND THE OTHER ROUTE EXISTS NOW TOO (2026-08-28), which matters because
  this entry named exactly two and a future reader would otherwise think
  only one was ever built: "the harness pins the appearance for a leg the
  way it pins the scale" is `KAYA_APPEARANCE=light|dark`
  (tools/check-appearance.sh). It does not replace the two-mode string —
  that is what makes the VERDICT byte-identical across platforms — it
  makes the dark half REACHABLE, as the `canvasdark-*` leg on all five
  lanes, instead of only on a machine somebody had set to dark.
- **The portfolio chart's well reads RAISED in light and RECESSED in
  dark, and nobody has ruled on it** (measured 2026-08-27,
  docs/measurements/canvas-palette-look-2026-08-27.txt §3). In light the
  plot ground is WHITE on a EEF1F2 window — a raised card, matching the
  tables beside it. In dark the plot ground 16181C is DARKER than any
  plausible macOS dark window: the opposite reading, at the weakest
  separation in the whole contrast table (1.07). It is a taste question
  AND a consistency question, because the tables next to the chart draw
  their card in the PLATFORM's own token (tools/check-table-card.sh)
  while the canvas draws in kaya's palette, so on a dark host the chart
  can sit visibly darker than the cards beside it.
  WHAT WAS BLOCKING IT IS GONE: the measurement said this "needs a dark
  machine, one capture, and the maintainer's eye", and the dark window
  half LANDED 2026-08-28 as `KAYA_APPEARANCE=light|dark` — a per-process
  override through each platform's own mechanism, so a real dark window
  opens on a light desk and no host setting is written. The capture is
  now one command on this machine.
  WHAT IS STILL OPEN is only the ruling: whether a chart well should read
  raised or recessed in dark, and whether the canvas should reach for the
  platform's card token the way the tables do. Not decidable without the
  maintainer's eye on a picture, which is §7.3's whole point — every
  scene assertion was green through the two look bugs the portfolio has
  already shipped.
  KEY: palette-look, plot ground, raised, recessed, card, well,
  KAYA_APPEARANCE, check-table-card
- ~~**kaya's Android mount is not re-entrant across an activity relaunch,
  and the second mount kills the process** (measured 2026-08-27 on the
  android lane, while landing `KAYA_APPEARANCE`). Android relaunches an
  activity for any configuration change the activity does not declare —
  night mode, ROTATION, locale, font scale, density. The relaunch runs
  `onCreate` twice IN ONE PROCESS, so `KayaCompose.mount` starts the pump
  twice, the guest builds its scene twice, and the core — which is a
  process-global singleton — dies on the duplicate:

      wm_relaunch_resume_activity … MainActivity
      wm_on_create_called  performCreate            <- mount #1
      wm_on_destroy_called performDestroy
      E kaya log_panics: 'kaya: widget id … already exists' scene.rs:1419
      wm_on_create_called  performCreate            <- mount #2
      ActivityManager: Process dev.kaya.milestone2 has died

  The buffers this came out of were
  `target/validate-failures/android-canvasdark-compose-buffers.log (gone)`
  — that directory is a lane artifact and is cleaned between runs, which
  is why the sequence above is quoted here in full rather than cited.
  HOW IT WAS FOUND: the appearance knob's first Android mechanism was
  `UiModeManager.setApplicationNightMode`, which is exactly such a
  configuration change, and the dark canvas leg died at ~63s having
  printed no verdict — three launch attempts, three identical deaths.
  NOT A DEFECT OF THAT KNOB, which no longer uses that call: any kaya app
  on Android has this today. A phone rotation is the ordinary way in, and
  no scene rotates a device, which is why nothing has ever seen it.
  WHAT WOULD CLOSE IT: either mount becomes re-entrant — detecting a
  second entry in the same process and re-attaching the existing scene to
  the new activity rather than rebuilding — or every kaya activity
  declares the configuration changes it absorbs, which trades the crash
  for the half-dark window the manifest theme would no longer re-resolve.
  The first is the real fix and is a LIFECYCLE SEMANTICS change for every
  kaya app, so it wants the maintainer's ruling rather than a leg's.
  THE RULING CAME 2026-08-27, in two parts. (1) Recreation is INVISIBLE
  TO GUESTS: no new binding surface, no lifecycle callback — the only
  observables are the size and appearance changes that caused the
  relaunch, which already arrive as the uniform events every platform
  delivers. (2) The guest builds ONCE PER PROCESS behind a latch taken
  on the FIRST `onCreate` — deliberately not `Application.onCreate`,
  because the harness maps `KAYA_*` intent extras into libc's environ
  before the guest library starts (check-go-env's ordering) and an
  Application has no intent, so building there starts every selftest
  under an unset `KAYA_SELFTEST`, which is the default arm and not an
  error. Later `onCreate`s RE-ATTACH ONLY: swap `mountedActivity`
  (identity-guarded, nulled on the mounted activity's ON_DESTROY so the
  verbs that need an activity — pickers, clipboard — refuse through
  their existing null checks instead of touching a destroyed one),
  re-apply the appearance override to the new window, re-add the
  lifecycle observer, `setContent`. The pump's captured activity becomes
  a main-looper Handler. NO CORE RESYNC: `KayaSceneModel` is
  process-global and a fresh composition re-projects the whole of it by
  construction — Compose's snapshot system is itself a process
  singleton, two successive compositions read one model safely, and a
  write landing in the destroy/create gap keeps its value and loses
  only the apply notification, which the new composition's first read
  covers.
  THE ECOSYSTEM AGREES, measured against sources 2026-08-27 rather than
  recalled: every engine-owns-state framework ALSO absorbs config
  changes in the manifest (Flutter declares 11 flags including uiMode,
  SDL3 13, Godot 11, React Native 7, MAUI 6), and Google's own guidance
  says "It is impossible to entirely disable Activity recreation" — so
  absorption is an optimization and re-attach is the correctness floor;
  back-out-and-reopen recreates the activity under a living process no
  matter what the manifest declares. Of them all only Flutter truly
  re-attaches (evicting the incumbent activity before the newcomer
  attaches — our identity guard's sibling); SDL and Godot kill the
  process instead; MAUI, Avalonia and React Native hand each new
  activity a FRESH tree off the surviving engine, which is exactly the
  `KayaSceneModel` shape. iOS runs every configuration change by
  mutating traits in place — no teardown — but CAN disconnect a scene
  (window and views die, process and model survive), so
  re-projection-from-model is the cross-platform rule while the
  recreation PROOF is android-only: drive `activity.recreate()`
  mid-scene as an android-lane phase, on the windows lane's
  on-guest-unit-tests precedent, never as a shared .steps verb the
  other platforms would have to stub.
  DECIDED IN THE CLOSING SLICE: whether kaya's manifest absorbs too
  (the knob's `createConfigurationContext` machinery already re-resolves
  windowBackground under a forced configuration, which is the one piece
  absorption was missing); and the AUDIT: whatever `KayaRing.attach` /
  `KayaGo.attach` retain across JNI must be application-scoped, never
  activity-scoped.
  KEY: mount, re-entrant, relaunch, onCreate, configChanges, rotation,
  already exists, scene.rs, KayaCompose.mount, am_proc_died, build-once
  latch, activity.recreate~~
  CLOSED 2026-08-27, as ruled and then as ruled again. The guest starts
  ONCE PER PROCESS behind a latch taken on the first Activity
  `onCreate`, in four places and never in a shell:
  `KayaCompose.mount`'s `mounted`, `crates/kaya/src/android.rs`'s
  `claim_attach()` (both `attach` and `Java_dev_kaya_KayaRing_attach`),
  `bindings/go/android.go`'s `androidAttached` — whose PANIC became a
  quiet `return presentGuest` — and `KayaRing.startGuest`'s
  `guestStarted`. A later onCreate re-attaches only: swap
  `mountedActivity` (identity-guarded, nulled on that activity's
  ON_DESTROY), re-apply the appearance override to the NEW window,
  re-observe the lifecycle, re-materialize the title onto the new
  Activity (`expect_title` reads `activity.title`, which comes back as
  the MANIFEST LABEL otherwise), `setContent`. The pump's captured
  `runOnUiThread` is a main-looper Handler; the harness's captured
  activity is a getter, so its ~150 reads follow the swap and a verb
  added later gets the current one for free. No core resync: a fresh
  composition re-projects `KayaSceneModel`, and its presentation
  `LaunchedEffect` re-reports scale and appearance by construction.
  THE JVM TIER TOOK A SECOND RULING, 2026-08-27, and it is the reason
  all three tiers now read alike. That shell used to start the guest
  itself (`Thread(scene, "kaya-app").start()`), so no kaya call stood
  between the second onCreate and the second `Todos.app()`; the first
  implementation kept the shell's shape and absorbed the second entry at
  the first binding call instead, which put an Android rule inside
  `KayaApp` and left one tier's semantics different from the other two.
  THE MAINTAINER TOOK THE LIBRARY CALL: `KayaRing.startGuest(scene)`
  replaces the shell's `Thread(...)`, kaya owns the app thread on every
  Android tier, and a guest's entry is NEVER RE-ENTERED anywhere — so
  "absorbed at the first binding call" is retired along with
  `KayaRing.reentersGuestEntry()`, which existed only to name the
  platforms that needed absorbing.
  WHAT SURVIVES IN `KayaApp` IS A BACKSTOP WITH ONE SENTENCE: a second
  App in one process throws, on every platform, because the core is a
  process-global singleton and two Apps mint ids from two counters into
  one scene — a crash three removes from the mistake. Nothing on the
  platform's side can reach it now; what it catches is an app that
  spawns a second entry itself. It cost one fixture: AbortCheck built a
  second App on purpose so `IdSpaceCheck`'s run would start at 1, and
  now takes the process's one App as an argument and runs first.
  THE AUDIT FOUND ONE THING: `android.rs` held the ACTIVITY in a
  `OnceLock` "for the process's life" as the Context for an asset read,
  so after a recreation the process kept the FIRST, destroyed one
  forever. It stores `getApplicationContext()` now (`APP_CONTEXT`).
  Everything else attach retains — the JavaVM and two class global refs —
  was already application-scoped.
  THE MANIFEST DOES NOT ABSORB, and the number is why. Re-attach costs
  78ms (compose), 91ms (go), 91ms (jvm), measured end to end on the
  android lane 2026-08-27 — `KAYA_REMOUNT: recreating` to `re-attached`,
  destroy plus create plus first draw, same pid. Absorption is an
  optimization on a correctness floor that now exists, and it is not a
  free one: `android:configChanges="uiMode"` stops the platform
  re-resolving the manifest theme's `windowBackground`, which is the
  half-dark app D1 exists to have fixed, so absorbing means re-applying
  the window background on every absorbed change and a check-appearance
  clause to hold it. 80ms on a rotation does not buy that. REOPEN IT if
  a real app is ever measured losing something visible across a
  re-attach; the ecosystem's flag lists (Flutter 11, SDL 13, Godot 11)
  are in the research file, and Google's own "It is impossible to
  entirely disable Activity recreation" is why they are optimizations
  there too.
  THE PROOF RUNS ON EVERY ANDROID LANE, not behind a flag:
  `remount-compose`, `remount-jvm` and `remount-go` run `todos` with
  `KAYA_RECREATE_AFTER=6`, so `Activity.recreate()` fires mid-scene and
  the remaining eight statements — menu enablement, two menu
  activations, a field-level toggle and four label reads — run against
  the NEW view tree over the OLD process's model, once per guest tier.
  `remount-nav-compose` is the PER-WINDOW half beside them, which
  `todos` cannot reach: `nav` under `KAYA_APPEARANCE=dark`, cut so a
  title read is the very next statement, because a title is materialized
  ON the Activity here (`expect_title` reads `activity.title`) and a
  re-created one answers "Aurora Notes" — the manifest label — until the
  model is written back onto it, measured.
  `run_apk_on` greps the harness's two sentences (the one naming the
  statement it cut after, which is how a scene edit that shifts the
  count fails naming both sides) and counts `KAYA_PRESENTATION` at two
  or more, since the core latches the last report and a composition that
  never re-reports moves nothing observable. Beside them two witnesses
  inside the harness's own recreate: `kayaSecondMountThreads`, because a
  second pump or a second script runner is invisible to every assertion
  a scene can make (two pumps drain one core and two runners publish the
  same green verdict, of which the lane reads the first); and
  `appearanceAppliedTo`, because the override's window-background write
  is the one half of the appearance that is per-window, and no scene can
  see a window background at all.
  WATCHED FAILING, all six, on a device: the rust latch removed ->
  `kaya: menu item id MenuItemId(1) already exists`; the go latch removed
  -> the second goroutine's app-thread panic; `KayaRing.startGuest`'s
  latch removed -> a second `Todos.app()` and the FATAL EXCEPTION this
  entry was filed for, now naming the cause (`a second App in this
  process`) instead of a thread; the per-process work un-gated -> "2
  named kaya-compose-pump, 2 named kaya-selftest"; `refreshNavTitle`
  removed -> `title "Aurora Notes", wanted "detail"`; the appearance
  install moved into the first-mount branch -> the per-window refusal.
  `tools/java-typecheck.sh` runs the KayaApp backstop off-device on every
  gate sweep, watched failing against a copy with the latch removed.
- ~~A canvas STRETCHES ITS BUFFER rather than re-rasterizing at the
  assigned track~~ (found while landing the depth slice 2026-08-26). The
  core rasters at the VIEWBOX times the reported scale, and the backend
  blits that image into whatever track layout gives it — so a canvas at
  its natural size is pixel-exact, and one given more space has its pen
  and its glyphs stretched with it. What is missing either way is the
  backend report that would tell the core what the track is, beside the
  scale report `kaya_presentation` already carries. Not reachable by the
  depth scene, whose canvas sits at its natural size.
  RE-FRAMED 2026-08-26 BY THE SIZE POLICY (ruling 12, docs/canvas-plan.md
  §3.2.1), and the re-framing is the reason this entry cannot just be
  implemented as written: it used to cite §3.2 RULE 3 as the rule being
  broken, and rule 3 is now superseded along with rule 2. The defect is
  the same — a stretched blit — but the fix is no longer "apply the
  stretch to positions alone". It is the three modes: `scale`
  re-rasterizes under a UNIFORM fit with a letterbox (the pen scales
  with everything else, because it is the same drawing at a new size),
  `fixed` never adapts, `redraw` asks the guest. TWO SITES STILL ENCODE
  THE SUPERSEDED RULE and are where the correction starts:
  `rasterize`'s signature in crates/kaya/src/canvas.rs, which takes a
  target and stretches positions into it, and its unit test
  `a_stretch_does_not_thicken_the_pen`, which proves arithmetic the
  ruling replaced. AND ONE THING NOT TO DO MEANWHILE: do not copy the
  mac arm's stretch into the three phase-3 blits, since that turns a
  one-file correction into a four-file one (docs/canvas-plan.md §11).
  STILL OPEN AFTER PHASE 4 (2026-08-27), and phase 4 says why it was not
  taken there: the portfolio chart wanted a size declaration, and the
  declaration a guest could have spelled would have named a semantics no
  backend performs — the prop is in no spec, the letterbox is in no
  core, and the track report the first paragraph asks for is still
  missing. So the chart is laid out at its NATURAL SIZE (no grow, in a
  hugging column), the one geometry where `scale`, `fixed` and the
  present stretch all agree, and the guest says so at the site. That is
  the honest state until the three modes land; it is also why no scene
  in the tree exercises a stretched canvas.
  KEY: viewbox, stretch, emit_drawing, presentation, rasterize, redraw,
  scale mode, fixed, letterbox
  RULED 2026-08-27 (evening): this closes inside the size-policy
  slice — scale re-rasters the same display list at the assigned
  track; the source spelling and fixed's forcing artifact (a drawn
  mark in the portfolio dashboard) are recorded at
  docs/canvas-plan.md §3.2.1's evening addendum.
  DEPTH LANDED 2026-08-27: the missing report is `kaya_canvas_track`,
  the backend geometry report this entry's first paragraph asks for;
  `rasterize` takes a TRACK and fits the viewbox into it uniformly and
  centred, so it can no longer stretch anything, and
  `a_stretch_does_not_thicken_the_pen` is gone with the rule it proved
  (`the_fit_is_uniform_and_centred` and
  `the_uniform_fit_scales_the_pen_with_the_drawing` are its
  replacements). Spec: `size_policy`, tx 47 `set_size_policy`,
  occurrences 20/21. Rust binding: `Widget::fixed`,
  `Widget::on_draw`, `Widget::on_tick`. Backend: the SwiftUI arm's
  1:1 blit and its track report. Scene: tools/scenes/sizepolicy.steps,
  whose `expect_raster canvas@fit "track"` IS this defect's
  assertion — nothing else can see it, since the hash and the ink
  bounds come from the canonical raster and are policy-blind. The
  BREADTH is open below (the two other backends, the seven other
  bindings, the template zone and the portfolio's drawn mark).
  GTK JOINED 2026-08-28, and its half of the stretch was the widget:
  `GtkPicture` was set to `ContentFit::Fill` — this defect written out
  by hand — and no other member of that vocabulary means 1:1 either, so
  the canvas widget is kaya's own `KayaCanvas` now (docs/canvas-plan.md
  §3.2.1's GTK note).
- **THE SIZE POLICY IS A DEPTH SLICE (2026-08-27)** — spec, core, the
  Rust binding, the SwiftUI mac arm, the GTK arm (2026-08-28) and
  tools/scenes/sizepolicy.steps are in; nothing else is.
  THE BINDINGS WAVE LANDED 2026-08-28 and closes the seven-binding half:
  every binding spells the three declarations in its own idiom (Rust,
  Go, C#, Java, Swift chain them; Python takes keywords on `canvas`,
  OCaml labelled arguments, Haskell a Build action beside two
  App-registered handlers), each putting the policy on the wire in the
  same act as the registration, and each answering the two asks inside a
  transaction the BINDING opens. `guests/<lang>/sizepolicy.*` exists in
  all eight and the scene runs all eight on the mac lane (the java leg
  since the coordinate-flip close below), which is why it moved from
  validate-mac's DEPTH_SCENES into SCENES. The C floor
  can spell it — `kaya_tx_set_size_policy` plus a generated
  `kaya_parse_draw_requested`/`kaya_parse_tick` — and carries no guest,
  which is the floor's roster (guests/c/Makefile's SCENES), not a gap.
  WHAT IS STILL OPEN, and each of it is fan-out work rather than a
  design question (docs/canvas-plan.md §3.2.1 settled the spelling):
  - ~~**THE JAVA LEG IS NOT WIRED, and the cause is the mac backend's
    canvas geometry rather than the binding.**~~ — CLOSED 2026-08-28 by
    the ledgered candidate: `kayaCanvasLiveResolve` resolves the
    canvas's AX element by its accessibility identifier at read time,
    reads the element's own position and size — a second measurement,
    independent of `KayaCanvasReader`'s stored rectangle — and on
    disagreement past a point corrects the stored frame AND re-reports
    the track, so `expect_ink`'s sample rectangle and the core's raster
    move together (the one-reader rule kept on the corrected value).
    Both track-consulting verbs resolve first (`expect_ink`,
    `expect_raster`); the AX box is the TRACK because the identifier
    rides outside the grow frame — measured on the healthy python leg
    agreeing with the reader to the point on all four canvases,
    including the grown `fixed` one whose blit box would have echoed
    the raster back. AND THE CLOSE IDENTIFIED THE CAUSE the ledger's
    theory had wrong: the recorded frames were never from an earlier
    layout — they are the Y-FLIP of the true ones (content height 420;
    `420 - y - h` reproduces all four recorded positions exactly), so
    on the JVM host the reader's `.global` frames arrive in a
    bottom-left-origin space while every other leg's arrive top-down.
    That is why the heights were right, the positions overlapped, and
    the render was byte-identical. Corrected, the JVM leg's rectangles
    are python's own 44/136/228/320 and the verdict text matches
    python's byte for byte. `sizepolicy-java-swiftui` is wired in
    tools/validate-mac.sh, and that leg is the standing negative: the
    JVM's readers report the mirrored space for the life of the
    process, so dropping the correction reds it (docs/traps.md holds
    the full measurement).
  - ~~**THE PORTFOLIO'S DRAWN MARK IS IMPLEMENTED AND HELD, awaiting the
    maintainer's visual ruling.**~~ — CLOSED 2026-08-28, placement ruled
    INLINE WITH THE TITLE: the 28x28 `fixed` chip sits in a hugging row
    before label#0, where it can take no share of the column's leftover
    (as a bare column child it did — the chip floated centred in empty
    space with the chart pushed to the column's bottom, every assertion
    green, which is why the wave held it for the ruling instead of
    shipping ugly). Applied with the draw ops INLINED at the call site
    per the maintainer's preference — `draw_mark` existed only to ape
    `draw_chart`, which is a function because it re-runs per Day tick;
    the mark never redraws. The wave's hope that the scene could take
    `expect_raster canvas@mark "viewbox"` once the backends reported
    tracks was WRONG, and the line was tried and measured failing: an
    ungrown chip's track IS its viewbox, both answers are true at once,
    and the core's precedence (scene.rs's canvas_raster_shape) says
    "track" — a policy is observable only where track and viewbox
    differ, which is why sizepolicy.steps' canvases all grow and why
    that scene keeps `fixed`'s assertion. The mark carries drawing,
    hash and ink — the wave's frozen strings, since placement moves no
    pixel of the drawing itself.
  - ~~**DEPTH STUB: sizepolicy on gtk**~~ — LANDED 2026-08-28: the GTK
    arm reports each canvas's allocation to `Scene::set_canvas_track` off
    the window's own `GtkTickCallback` and drives the frame clock from
    the same callback, `KAYA_SELFTEST`-guarded so a scene's frame count
    stays the scene's; the `sizepolicy-rust` leg is wired on both
    protocols in tools/linux/run-suites.sh. THE BLIT MOVED WITH IT, and
    that is the part a reader will not expect: `fixed` rasters at the
    viewbox whatever the track is, so the blit has to be strictly 1:1 —
    and no member of `GtkContentFit` means that (Fill stretches, Contain
    and Cover scale up, ScaleDown scales down), while GTK never allocates
    a widget more than its parent assigned, so a squeezed canvas met one
    of those fits whichever was chosen. The canvas widget is a
    `KayaCanvas` now (a `GtkWidget` subclass: natural size = the blit,
    snapshot = the blit centred and clipped), and `ContentFit::Fill` —
    which cited §3.2's superseded rule 2 — is gone with the stretch it
    named. tools/check-canvas-blit.sh gained the GTK half of clause 4.
  - ~~**DEPTH STUB: sizepolicy on winui**~~ — CLOSED 2026-08-28: the
    winui arm reports the track, drives frames off
    `CompositionTarget::Rendering` outside the harness, and the
    `sizepolicy_rust` leg runs on the windows lane. THE REPORT IS NOT
    THE `Image`'s ARRANGED SIZE, which is what this bullet said and what
    a first attempt would write: `set_drawing` gives that Image an
    explicit Width/Height taken from the BUFFER — the 1:1 blit — and an
    explicit size is a HARD constraint in XAML, so `ActualWidth` reads
    the RASTER's size back however much room the row had, track and
    raster agree by construction, and the policy is inert with every leg
    green. It is the SwiftUI trap in this toolkit's spelling (§3.2.1,
    "the backend reader has to sit OUTSIDE the grow frame"). What
    answers is `LayoutInformation.GetLayoutSlot` — the area the PARENT
    assigned — for a GROWN canvas, and the element's own box for an
    ungrown one, which is the mac's
    `.frame(maxWidth: node.grow > 0 ? .infinity : nil)` conditional
    verbatim: a Grid cell spans the panel's cross axis whatever the
    child does with it, so the slot of an ungrown canvas is the whole
    column's width and a `scale` canvas would re-raster into it
    letterboxed, with every frozen ink probe landing somewhere else.
    Three types had to leave the bindgen filter's vtable pads for any of
    it (`LayoutInformation`, `CompositionTarget`, `RenderingEventArgs`
    plus `Windows.Foundation.TimeSpan` for its `RenderingTime`).
  - ~~**DEPTH STUB: sizepolicy on compose**~~ — LANDED 2026-08-28: the
    canvas arm is a `Layout` that reports its own CONSTRAINED size
    through `KayaPresent.canvasTrack` (the image inside it is always the
    buffer, so reading that would make track and raster agree by
    construction), blits the buffer 1:1 and centred, and drives
    `kaya_frame` off `withFrameNanos` outside the harness. `expect_raster`
    and `frame` are real arms; `sizepolicy-compose` is wired in
    tools/android/run-emulator.sh against guests/rust/sizepolicy.rs.
    Watched red on a live emulator leg with the track report cut out
    (`raster no track reported, wanted track`).
  - ~~**iOS is DECLARED OFF, not stubbed**~~ — CLOSED 2026-08-28: the
    distinction was real (swift/KayaSwiftUI.swift serves mac AND iOS, so
    the feature was THERE and simply never run), and a run has now
    measured it. `sizepolicy` moved from `IOS_UNWIRED_SCENES` into
    `IOS_SWIFT_SCENES`, and `sizepolicy-swift` passes on the simulator
    with the verdict string the mac's own leg prints, byte for byte.
  - **THE TEMPLATE ZONE IS REFUSED, LOUDLY.** A `set_size_policy`
    against a canvas TEMPLATE NODE panics naming this entry, rather
    than being half-implemented: the core would have to key the policy,
    the track and the mailbox per stamped copy, and address the ask by
    node plus key path. The wire grammar already carries that shape
    (`draw_body` takes a path and `Occurrence::InstanceDrawRequested`
    exists, both round-tripped in wire.rs's tests), so the closing work
    is scene.rs's side alone. Until then a canvas in a row template is
    `scale`, which is the default and correct.
  - **THE NON-HARNESS FRAME DRIVE IS EXERCISED BY NO LANE.**
    `KayaCanvasTicker` (a `TimelineView(.animation)`, one per canvas,
    absent under `KAYA_SELFTEST`) is what drives `kaya_frame` in a real
    app, and every scene drives frames by verb instead — deliberately,
    since a leg's frame count may not be a fact about the machine. So
    the code that runs in a SHIPPED app is the half no test reaches.
    RULED 2026-08-27 (late): the forcing artifact is a REAL 60fps
    canvas animation — a simulation or small game as its own scene or
    app — because nothing in the tree can be promoted into the role:
    the portfolio chart is NOT a tick user (Day tick is a MODEL change;
    the chart redraws through the ordinary submit path), and a scene
    that fakes frames by verb is the harness half again. Until that
    artifact exists, a capture round on a running animation
    (docs/canvas-plan.md §7.3's per-platform captures) is the interim
    answer, the same one the look-bug class already has.
  KEY: size policy, sizepolicy, set_size_policy, expect_raster, frame
  verb, canvas_track, kaya_frame, on_draw, on_tick, fixed, letterbox,
  KayaCanvasTicker, template zone canvas, KayaCanvasReader,
  kayaCanvasFrames, sizepolicy-java-swiftui, portfolio mark, MARK_BOX
- ~~CROSS-ISA byte-identity of the canvas raster is UNMEASURED~~ —
  CLOSED 2026-08-26: measured before the first hash went into a .steps file,
  and the two agree: aarch64 and x86_64 both rasterize the canvas
  scene's shapes to `40b0692193e14148`
  (docs/measurements/canvas-cross-isa-2026-08-26.txt, the report the
  probe and its caveat live in). So `expect_drawing_hash` stays ONE
  string per lane rather than one per architecture family, which is what
  docs/canvas-plan.md §7.1 named as the thing that could falsify the
  primary observable. WHAT IS STILL OPEN, and it is the caveat rather
  than the claim: the x86_64 run was EMULATED (Docker Desktop on Apple
  silicon), so it exercised the x86_64 codegen path — where a SIMD
  divergence would live — and not a real x86_64 CPU's corner cases. The
  day kaya adds a NATIVE x86_64 lane, re-run the probe before trusting
  the frozen hash there. KEY: cross-ISA, aarch64, x86_64, drawing hash,
  tiny-skia
- ~~**DEFECT — a canvas text run whose font will not resolve AT RASTER
  TIME is dropped silently.**~~ Found 2026-08-26 while re-freezing
  tools/scenes/canvas.steps, and filed here with its resolution because
  the fix and the finding are the same day's work.
  `validate()` resolves every `draw_font` asset and refuses the drawing
  if one is missing — and THE RASTER RESOLVES IT AGAIN, where
  `Face::open` answered `None` and the run was simply not drawn. Nothing
  logged and nothing refused: the only thing that moved was §7.1's frozen
  hash, which is the silent-wrongness class this project exists to kill.
  Measured: the pin test failed 8/8 against one build with
  `c4fa15caf170a5ff`, exactly this scene minus its one disk-resolved run
  (docs/traps.md carries the four hashes and the mechanism).
  RULED AND CLOSED 2026-08-26 (maintainer): the raster REFUSES. The
  sentence names the asset — the reserved name or the app's asset id —
  and the run's text, carries the resolver's own words, and reaches the
  leg's verdict through `crate::fault::guard` exactly as a §3.5 refusal
  does. It refuses at the TEXT op, so a selected face nothing draws with
  refuses nothing, and AS A UNIT: the panic precedes the first glyph and
  the unwind takes the pixmap, so no half-drawn buffer reaches a backend
  (which would be the empty-child class one layer down). `Face::open`
  parses the bytes too, since an asset that resolves and is not a font
  dropped the run just as quietly. Both branches are watched printing in
  `canvas::tests::a_vanished_font_refuses_the_run_rather_than_dropping_it`,
  which doctors the resolver BETWEEN validate and raster under
  `crate::assets::serially()` — the state no scene can reach, which is
  why this is a unit guard and not a gate. The pin test's resolution
  assert stays as the EARLIER wall (docs/canvas-plan.md §3.5's amendment,
  docs/traps.md).
  KEY: Face::open, font_bytes, draw_font, rasterize, c4fa15caf170a5ff,
  raster time, dropped run
- Webview widget (Akhil, 2026-07-22; deferred furthest — the
  framework inside it is the entire web platform): minimal uniform
  surface is load-URL/load-HTML plus a navigation-requested veto
  (fits the existing veto grammar). The hard parts are the four
  embedders (WKWebView, WebView2, Android WebView, WebKitGTK) whose
  JS-bridge/cookie/permission models diverge, and distribution
  (WebView2 Evergreen runtime, webkit2gtk distro variance) — both
  land on the packaging milestone. A user-facing native-view escape
  hatch is NOT the default answer (breaks the cross-platform promise
  per-widget, forces per-platform guest code).
- Packaging: at-release items — Hackage/opam publication, Go vanity
  import path (akhil.cc/kaya + go-import meta; dev.kaya is
  unpublishable), Maven publication under cc.akhil, npm kaya-gui after
  account recovery; a LICENSE decision before any real release;
  trusted publishing (OIDC) on nuget/PyPI/npm when releases start.
  Android Python/Go guests need binding bootstrap (briefcase/gomobile).
  Swift SPM packaging needs a modulemap target.
  APP-DISTRIBUTION PAYLOADS (Akhil, 2026-07-22): a user who imports
  kaya and ships an app must get every runtime artifact the platform
  needs, per platform, without reading our runbooks. The inventory
  the suites already prove out: WINDOWS — resources.pri beside the
  PROCESS exe (the pri-adjacency rule in traps.md; for dll-hosted
  languages the packaging story must place it beside the interpreter
  or ship an apphost), the WindowsAppRuntime bootstrap dll, and
  kaya.dll on PATH; MAC — libkaya.dylib plus the SwiftUI interpreter
  dylib (KAYA_SWIFTUI_LIB or dyld-adjacent); iOS — both inside the
  bundle (the run-sim make_bundle recipe is the spec); ANDROID —
  libkaya.so in jniLibs + the Kotlin interpreter classes; LINUX —
  libkaya.so with the GTK backend compiled in. Each language's
  package should carry or fetch these so `pip install kaya-gui` /
  `go get` / `cargo add` yields a runnable, distributable app —
  wheels with platform tags, cargo build-script asset embedding,
  gradle AAR, etc. This is the packaging milestone's acceptance
  test: a fresh machine, one package-manager install, one binary
  handed to a friend.
- Alert relaxations, each waiting on a REAL need, none speculative:
  programmatic dismissal (a guest-side cancel verb — rare; adds a
  second retire path to a grammar whose whole point is ONE),
  per-window alert concurrency (the process-wide one-live-alert
  floor is ContentDialog's per-root rule spelled strictly; relaxing
  means per-window slots and a WinUI carve-out), and a third-plus
  action (the platform floor is ContentDialog's two-actions-plus-
  close; more means a custom row on WinUI — no longer the dressed
  floor).
- Swift guests on Linux and Windows. Upstream swift.org toolchains
  exist for both, but neither pinned world (docker image, VM) carries
  one, and the swift SURFACE is already fully proven — typecheck on
  two Apple targets plus 25 live mac legs and the iOS suite. The
  value would be backend×language matrix breadth, not new surface
  proof; take it only if a real swift-on-linux/windows user appears.
- Node.js guest (the roster's first async surface): Node first;
  function-floor tier via N-API (V8 pointer compression forbids
  external ArrayBuffers over native memory — no direct ring);
  main thread blocks in kaya_run, app logic in a worker; layer 3 wants
  for-await occurrence iteration.
- Arena offset+length form (row batches, audio) — returns when the row
  window and audio land; the blob table is its v1 realization.
- Attach/embedding tooling rework (parked at milestone 0).


## Retire the hand-edited shell and cmd scripts

Raised 2026-07-31, after file dialogs. The repo already bans sed and awk
for ad-hoc text work because BSD and GNU diverge; this is the same
argument one level up, about the scripts themselves.

The failure mode is not that shell is hard to write. It is that these
files are easy to CORRUPT and the corruption is invisible until a lane
runs. Measured in one session: tools/guest/*.cmd must keep CRLF or
cmd.exe reads a lone LF as part of the command, and two separate
attempts to edit one of them programmatically mangled it — once by
splitting on CRLF and rejoining wrong, once by a `\r\n` that did not
survive shell quoting into python. Neither showed up until a leg timed
out at 327 seconds. Around the same afternoon a slice edit to
tools/deploy-win.sh silently swallowed five `run_suite background_*`
lines; only check-steps caught it.

What to move, roughly in order of pain: tools/guest/*.cmd (CRLF, cmd
escaping, 188 near-identical files — re-measured 2026-08-19; as filed it
said "forty", so the surface has quadrupled and 188 near-identical files
is a GENERATION problem rather than a translation one, which changes the
item's shape as well as its size), tools/deploy-win.sh (the longest
and the one whose leg ordering is load-bearing), then the rest of
tools/*.sh — 52 of them today against 2 tools/*.py, so nothing has moved
yet (overtaken: see the 2026-08-31 progress note below — the gate tier
is done, the runners and guest .cmd files are what remain). Python is
the obvious target — it is already the mandated
language for text processing here, it is in the dev shell, and it has
real data structures for things the shell fakes with string splicing.

Two things NOT to lose in the move: the dev-shell fingerprint check
every tools/ script starts with, and the `$?`-read-once discipline that
tools/check-shell.sh enforces (a rule that exists only because shell
makes it easy to get wrong — which is itself an argument for leaving).
See also the portsh work for the cases where one script must run on both
sides.

PROGRESS 2026-08-31: the GATE tier is converted — every census and
self-test gate body under tools/ is python against the imported
prelude (48 bodies in check-python's census; the ONE gate still in
shell is tools/swift-typecheck.sh, deliberately: its body is swiftc
invocation loops, the in-toolchain launcher shape, not decision
logic; each old body was run beside its replacement on
the same tree with stdout, stderr and exit compared, and every watched
negative re-proven red on the converted body; the two largest,
tools/check-steps.py and tools/check-sugar-surface.py, closed the set
today, both byte-identical on both streams). The runners, keyed.sh, the
generators and tools/lib/*.sh stay shell by the 2026-08-27 ruling's
present-tense boundary. Both things the paragraph above said not to
lose survived the move: the fingerprint lives in tools/lib/kaya_gate.py
and is proven against the real shell pipeline in its own self-test, and
the `$?` discipline retired with the shell bodies — check-python's
eleven rules are its replacement. A dedicated clause-by-clause audit of
all 37 non-verbatim conversions
(docs/measurements/gate-conversion-audit-2026-08-31.md) found four real
defects: check-wheel's import smoke lost the shell's cd (a standalone
run from bindings/python could green a wheel shipping nothing),
check-shell's four per-command rules policed no .py body (restored as
check-python rule 11, both argv-list and embedded-shell spellings),
check-case never read git ls-files' exit, and check-ambient-tx's census
had no floor — all four fixed the same day with watched proofs. What
remains of this entry: the tools/guest/*.cmd generation problem and the
runner boundary (the windows half is the 2026-08-31 HOLD entry below).

RULED 2026-08-31 (Akhil, evening, after the matrix record): NEW
SCRIPTS ARE PYTHON FIRST — on the kaya_gate prelude — so nothing new
joins this entry, and the NEXT TRANCHES convert in order: (1) the
three generators (gen-header, gen-bindings, gen-guests — decision
logic already in the gate sweep), (2) keyed.sh and build-id.sh as
typed python modules with thin CLI faces, their GATES/input-set
tables becoming importable data, (3) the runners, reframed as
leg-tables-become-shared-data — check-steps, check-staging and
check-gates regex-parse runner shell text today, so each runner port
re-teaches its census gates to import the same tables;
deploy-win.sh first. This moves the 2026-08-27 ruling's
runners-stay-shell boundary, which was recorded present-tense for
exactly this revisit. Out of scope as before: in-container and
in-toolchain payloads, and the .cmd stubs (the HOLD).

TRANCHES 1 AND 2 LANDED THE SAME EVENING (511a3da, 36d7213): the
three generators and keyed/build-id are python, every mode
byte-compared against the old body on the same tree, and each
tranche paid immediately — gen-bindings' bare `cargo run` was the
one cargo invocation outside both cargo rules' alternation (it
carries --locked now and `run` joined the rules), and
tools/lib/keyed-inputs.py turned out to be parsing build-id.sh's
text and scanning tools/<gate>.sh SHIMS — its input-coverage census
had gone progressively vacuous across the whole conversion, and it
imports the module and scans the .py bodies now. Tranche 3 is
MEASURED and needs its plan first: 10,076 lines across six runners,
with EIGHT gates text-parsing deploy-win alone (appearance,
app-identity, assets, build-id, gates, staging, stubs, steps) — the
leg-table schema those eight would import instead is the design
decision, docs/runner-conversion-plan.md is its home, and each
runner port is validated by its own lane plus the matrix.

TRANCHE 3 STAGE 1 LANDED 2026-08-31, the evening after the plan:
deploy-win is python. The leg tables are tools/lib/lanes/win.py —
SCENES, the depth default under its KAYA_WIN_DEPTH_SCENES override,
GO_ONLY/PY_ONLY, and ORDER as blocks-between-drains with each
barrier's measured reason as the block's comment — the body is
tools/deploy-win.py on the prelude with the .sh a pinned shim, and
the flight recorder's windows half crossed into
tools/lib/flightrec_lane.py with it. The roster rider compared EQUAL
on every axis (41/3/1/2 scene lists, 201 legs in order, 32 blocks)
before the crossing and again afterward against the git-materialized
shell body. All eight parsing gates were re-taught in the same slice
— steps/staging/appearance/stubs and scene-features import or read
the module, assets/build-id/gates read the python body — each with
its negatives re-proven red on the import path (the deleted-nav
family watched reddening check-steps live), and the tranche paid the
usual immediate dividends: check-build-id's --verify coverage clause
got its first watched negative, check-steps' serial clause grew the
undo arm the shell body's comment had recorded as missing, the
launchers census now covers the milestone2 bare five, and
check-staging's two hand-written .ps1 lists collapsed into the one
deploy_artifacts() list with both census directions watched. The one
runtime defect the first lane found is a trap now (docs/traps.md,
"NOT UTF-8"): the guest's output files carry cmd.exe codepage bytes
and a strict text=True decode killed the leg WAITER — every
guest-origin capture says errors="replace". Validated: gates 50/50,
windows lane green twice standalone (suites 138s/134s, the second
through the deploy-unchanged stamp path), matrix ALL PASS 1,390 legs
in 639s (a first matrix ran all legs green with linux 5s over its
530s ceiling — the container's mtime-busted core rebuild plus sweep
contention, not the lane; the rerun's linux was 404s). Enumeration
and re-teach record:
docs/measurements/deploy-win-conversion-2026-08-31.md.

STAGE 2 (run-sim) LANDED THE SAME EVENING, the same shape: tables in
tools/lib/lanes/ios.py (four suite rosters, the declared-off lists,
PAD_EXTRAS and the per-leg cut/drop/keep/extra MODS), body
tools/ios/run-sim.py with the shim pinned, IosRecorder in
flightrec_lane.py, rider EQUAL on every axis (113 legs in queue
order). Stage 2's own findings: a NINTH parser the enumeration missed
— tools/swift-typecheck.sh reads IOS_MIN and the swift roster out of
the runner, and its floor REFUSED A VERDICT loudly on the first sweep,
the correct failure mode; it imports the lane module now, and the
stages 3-4 lesson is to sweep the SHELL gates for runner reads too.
And expect_app_icon caught a real conversion slip on the first lane
run — the rust identity bundle lost its make_bundle identity argument
in translation and the leg went red naming exactly that (112/113,
then 113/113 twice after the one-line fix). check-python's population
extended to tools/**/*.py with a second byte-pinned header for
depth-2 runners; scene-features and check-stubs import lanes/ rows
through a wired_scenes() floor, closing two silently-vacuous-on-a-shim
readers; check-steps' 26 clipboard/picker negatives re-spelled to the
python body and the module. Validated: gates 50/50, ios lane green
twice (113/113), matrix ALL PASS 1,390 legs in 631s. Record:
docs/measurements/run-sim-conversion-2026-08-31.md.

STAGE 3 (run-emulator) LANDED THE SAME NIGHT: the 123 legs and their
exceptions (the tablet leg, the remount pairs, the KAYA_ASSET_DIR and
dark-appearance riders, the per-scene cuts and the identity drop) are
tools/lib/lanes/android.py; the body is tools/android/run-emulator.py
on the prelude with the shim pinned and AndroidRecorder in
flightrec_lane.py; the emulator-state library stays SHELL by the
plan's §6 (probe-env.sh still sources it) and the runner bridges to
it, one copy. The rider compared EQUAL on every axis including each
leg's CALL KIND, and a second rider closed the class stage 2 caught
one instance of: the old shell scene_script/cut/drop functions,
materialized from git and executed, produced byte-identical
KAYA_SELFTEST_SCRIPT payloads to the new script_for() for all 39
scenes. tools/lib/android-leg-order.py — the deepest parser, ~19
clause families over shell text — was rewritten whole against the
python body and the module, 38 watched negatives with counts printed,
two of which caught its own first draft. Stage 3's finds beyond the
runner: bench-tables.sh's MATRIX_RUNNERS still pgrep'd the stage-1/2
.sh basenames the shims no longer answer to (path literals are a
second reader class beside parsers), and check-build-id's 2b-android
pair of bare substrings had no negative — it reads the python body
line-wise now with both halves watched red. Validated: gates 50/50,
android lane green twice (123/123 both, journal carrying every leg),
matrix ALL PASS 1,390 legs in 616s with android at 226s — the first
matrix's five lanes all passed and its one red was check-doc-refs
refusing the new measurement doc's own pgrep quotation, the recording
sweep catching the record it rides in. Record:
docs/measurements/run-emulator-conversion-2026-08-31.md. Stage 4
(validate-mac, validate-linux, validate-all) then gates.sh remain.
KEY: python-first, tranche, generators, keyed, build-id, runner
conversion, leg tables

## MAYBE: read Windows accessibility client-side, like the other platforms

Raised 2026-07-31, NOT decided. Recorded so a green lane does not read
as a settled question. RE-AFFIRMED 2026-08-31 (maintainer): stays a
MAYBE on its recorded trigger — a defect slipping past the Windows
a11y legs that a client-side read would have caught.

The Windows `expect_ax` read is IN-PROCESS and PROVIDER-SIDE: it asks
XAML what it publishes, through FrameworkElementAutomationPeer. mac
(AXUIElement), linux (AT-SPI) and android (an accessibility service) all
read CLIENT-SIDE, from outside the app, which is the stronger form —
it observes what an assistive technology would actually receive rather
than what the app believes it exposes. The asymmetry predates the file
dialog work and nothing about it is newly broken.

WHY IT IS ONLY A MAYBE. The obvious fix — a Win32 UI Automation client
walking our own process — is now known to be the thing that cannot be
done here: attaching any UIA client makes the shell's DirectUI raise
automation events during message dispatch, which raises a NONCONTINUABLE
COM exception inside the guest that HotSpot reports as fatal
(docs/traps.md). It would have to run out of process, in the shape
iOS's tools/ios/simdrive uses, and it would have to be guaranteed not to
be attached while a file dialog is up. That is a lot of machinery for a
read that currently works.

The honest counter-argument is that a provider-side read cannot catch
the class of bug where XAML publishes something a client cannot see, and
that is exactly the class the a11y milestone was about. Decide on
evidence: if a real defect ever slips past the Windows a11y legs while
another platform's client-side read would have caught it, this stops
being a maybe.
## MAYBE: the WinUI seed writes once too, on a board with a relay on it

Raised 2026-08-04, alongside the mac seed's fix (docs/traps.md,
docs/clipboard-plan.md §9). RE-AFFIRMED 2026-08-31 (maintainer):
stays a MAYBE on its recorded trigger — KAYA_SEED_LOST or "never
appeared on the clipboard" on a windows clipboard leg. The macOS seed was measured LOSING its
write, silently, whenever another process touched the pasteboard inside
`osascript`'s clear-then-put window — 12 of 12 writes gone against a
competitor writing every 10ms, rc=0 and no stderr each time. Its remedy
is a bounded re-issue: the seed is idempotent, and a write that was
refused cannot be waited into existence.

`crates/kaya/src/winui/mod.rs`'s `clipboard_seed` has the same SHAPE —
`Set-Clipboard`, then poll `Contains*` for 5s, then fail — on a board
that has the same second principal available to it: the Windows guest's
clipboard is relayed to and from the host by SPICE's vdagent whenever
UTM's clipboard sharing is on, which it is on this machine. Nothing has
been observed failing there; the windows lane's five clipboard legs
pass. So this is recorded, not scheduled.

WHAT WOULD DECIDE IT. A windows clipboard leg failing with
`KAYA_SEED_LOST` or `never appeared on the clipboard` is this exact
class, and the fix is the mac one transliterated: re-issue the write
inside the poll instead of polling harder. Do not go looking before
then — the arm was settled 2026-08-03 and a speculative rewrite of a
green lane's seed buys nothing.

## MAYBE: the other three backends say nothing when a standard command is inert

Raised 2026-08-04 with the mac paste fix (docs/traps.md, "A standard
clipboard command that is DISABLED does nothing"). RE-AFFIRMED
2026-08-31 (maintainer): the triple-defer stands per backend — GTK
and Compose structurally cannot fire the note in their lanes, WinUI
builds it on the first stale-label sighting. A role item works out
its own enablement — what the clipboard offers intersected with what the
focused widget accepts — and a disabled item is inert on every backend,
which is right and matches native chrome. What only the SwiftUI
interpreter now does is SAY SO: `kayaRoleInertNote` prints the
intersection that came up empty, plus whether the board has changed
since kaya wrote it, when a harness `menu_activate` lands on a command
that cannot act.

The verdicts, one per backend (invariant 2):

- SwiftUI mac and iOS — DONE, one body, the defect's own platform.
- GTK / linux — DEFER. The failure needs a second principal writing the
  one clipboard, and each lane run owns a private compositor inside its
  container; there is nobody else to write it. Copy the shape if a real
  desktop session ever runs these legs.
- WinUI / windows — DEFER, and the strongest candidate of the three: its
  board has the same SPICE relay on the other side as the mac one (see
  the seed MAYBE above). A windows clipboard leg failing on a stale
  label after a `menu_activate "Edit>Paste"` is this class. The arm was
  settled 2026-08-03 and this session was not to touch it.
- Compose / android — DEFER. One clipboard per device, the emulator's
  host bridge severed both ways (docs/clipboard-plan.md §7 finding 4),
  so again no second principal.

Cheap when it comes: the note needs the focused node's accept list, the
board's type list, and the changeCount the backend last wrote — all
three already exist in every backend's clipboard arm.

## MAYBE: identity.toml carries a DEFAULT accent seed (raised 2026-08-31)
KEY: identity accent default, brand_accent default, identity.toml accent, mark color seed

Raised by the maintainer the night the portfolio's brand landed as the
mark's blue BY HAND — the coherence was a taste call, and his instinct
was to make it a mechanism: identity.toml gains an `accent =` line, an
app that never calls `brand_accent()` inherits it, and the call
overrides. Uniform by construction, since brand_accent already lowers
on all five platforms. Two frictions on the record before anyone
builds it: the identity file is PACKAGING-TIME and the brand is
RUNTIME STYLING — two subsystems the design keeps deliberately apart,
each with its own walls — and this repo carries ONE identity file
shared by every demo guest while their seeds legitimately differ (the
styling scene brands 0x3584E4 under the same mark), so the default
only lands cleanly once apps ship their own identity files. WHAT WOULD
DECIDE IT: a second real app hand-copying a mark color into
brand_accent — that duplication is exactly what the default would
erase.

## SOLVED: template-node props (was "grow, the a11y pair, accepts, on_paste")

Raised 2026-08-10 by the sugar pass; CLOSED 2026-08-11 by the props
slice (docs/tpl-props-plan.md). A template node now carries the a11y
trio (source-taking — a stamped row announces its OWN name), a const
accept list, grow, and a working paste hook, in all eight bindings,
gated receiver-keyed in check-sugar-surface with negatives watched.

What the closure taught, kept here because the entry predicted wrong:
the paste hook was not "unreachable for want of a registrar" — seven of
eight bindings HAD the registrar and the dispatch, and the hook still
could never fire, because every backend gates the paste occurrence on
the focused widget's accept list and no template node could declare
one. A silent REGISTRAR, not a silent drop. The keystone was `accepts`.
The a11yrows scene (stamped a11y read from the real tree) and the
clipboard scene's stamped paste target are the legs that watched both
arms fire for the first time.

Still open from the entry, deliberately: spacing and align stay
floor-only on template containers, uniformly, in every binding alike.

## SOLVED: the floor tier is repo-wide (was "a guest at the FLOOR fails no gate unless its scene is in the tables")

Raised 2026-08-10; CLOSED 2026-08-11. tools/guest-floor.py now carries
the whole per-language floor vocabulary over every sugar guest:
absolute patterns for every spelling with no legitimate use, a
paren-balanced >=2-argument scan that tells kaya's For (collection
first) from every stdlib forEach (body alone), Swift's trailing-closure
distinction, the labelled-argument boundary that keeps OCaml's sugar
out of its floor family, and generated files exempt by their own
marker. Every rule carries a fire line and a quiet line run through the
real engine on every invocation.

The "floor IN A SCENE THAT HAS SUGAR FOR IT" distinction the entry
called a real piece of design dissolved instead of being built: the one
irreducibly contextual family (SetText, the verb/floor name collision
in six languages) was retired by giving those six Rust's two-name split
— the template prop write is hidden or renamed, so the verb keeps its
name and the floor spelling became sweepable or unspeakable. The
receiver's type was the discriminator no regex could see, so the type
system was made to hold the wall instead.

The census that drove it: 44 patterns x 284 guest files = 36 hits — 11
floor (all converted), 21 legitimate, 4 sugar gaps (each closed:
Tpl.each in OCaml and Haskell, Haskell's live bound slider, the
scalar-element token). Sweep result today: zero hits, zero exemptions.

## SOLVED: the rust guests cost ~11s to START (macOS walked their build directory)

Measured and FIXED 2026-08-10, while diagnosing two matrix failures
during the template-zone sugar pass. Kept because the mechanism
generalises and the wrong first answer is instructive.

Per-language leg times for one scene, mac lane, machine quiet
(tools/validate-mac.sh, `split`):

    rust 38s   ocaml 16s   haskell 10s   swift 9s
    python 1s  go 0s       csharp 0s     java 1s

**The wrong answer, written down first:** that a Rust example links the
whole crate statically and pays a dyld pass over a big binary. It is
tidy, it fits the language split, and it is false. The binary is 4.8 MB,
and the other compiled guests (ocaml, haskell, swift) were not slow for
that reason either. It survived long enough to reach this file.

**The real one, from `sample` on the live process** — which is what the
lane's own timeout diagnostic tells you to do, and it named this in one
shot. The whole stack sat in:

    NSApplication init -> _NSInitializeAppContext -> _isMenuBarVisible
      -> GetCurrentProcess -> _RegisterApplication -> _LSApplicationCheckIn
         -> CFBundleGetValueForInfoDictionaryKey -> _CFBundleReadDirectory

macOS registers every UNBUNDLED executable with LaunchServices at
launch, and CoreFoundation reads the executable's CONTAINING DIRECTORY
as if it were a bundle — enumerating every sibling.
`target/debug/examples` is a build directory that accumulates a hashed
binary, a `.d` and a `.dSYM` per example per build. On this machine it
had reached **776,613 entries and 3.8 GB**.

Same binary, back to back:

    target/debug/examples/split   7.7s
    a two-entry directory         0.13s

Fifty-nine times. Across 32 legs that was 979s of the mac lane's 2020s
of leg time — 48% — and it is the entire gap between rust (mean 30.6s)
and go/python/csharp/java (mean ~1.2s). The staged binary is as fast as
any of them; nothing about Rust was ever involved.

It is also what made the parallel matrix a coin flip: contention
stretched those legs ~3x and `split-rust` at 38s crossed the 120s
per-leg timeout. Two consecutive matrix runs failed on different lanes
with nothing wrong in the tree.

**The fix:** validate-mac stages the built examples into
`target/rust-guests` (list derived from `$SCENES`, so a new scene cannot
be built and then left running out of the build directory) and asserts
that directory stays small. `tools/check-shell.sh` refuses any `run`
line that execs out of `target/{debug,release}/{examples,deps}`, with a
self-test, watched failing.

**Nothing is left, and the measured result is bigger than the diagnosis
predicted.** Per-language leg totals across the whole mac lane, before
and after:

    rust   979s -> 50s      ocaml   348s -> 35s
    haskell 272s -> 41s     swift   252s -> 48s
    go       53s -> 50s     python   40s -> 41s
    java     40s -> 38s     csharp   36s -> 40s

    total leg-seconds 2020 -> 343; lane wall 547s -> 223s

The prediction was that rust alone would collapse. Ocaml, haskell and
swift collapsed with it — from 10.9s, 8.5s and 7.9s means to 1.1s, 1.3s
and 1.5s — and that is the part worth keeping. They were never slow for
their own reasons: they ran CONCURRENTLY with 32 rust legs, each walking
a 776,613-entry directory through a single LaunchServices XPC service,
and they were starved by the contention. All eight languages now sit
between 1.1s and 1.6s.

So a per-leg cost paid by ONE language showed up as every language being
slow, which is why the per-language table at the top of this entry read
as a language story and was not one. When a whole lane is slow, the
shape to look for is a shared serialising service, not a per-language
trait.

## Live-zone a11y props take only constants — except in Python

Opened 2026-08-11 by the props slice, which noticed it while landing the
TEMPLATE zone's sourced a11y: Python's shared handle base gives its LIVE
widgets signal-sourced a11y (one surface serves both zones there), while
the other seven bindings' live `a11y_label` takes a constant string
only. So the eight disagree — and the direction of the disagreement is
odd on its face: a STAMPED copy's label can follow a signal in all
eight, a LIVE widget's can in one.

A dynamic live label is real accessibility (a play/pause button's
spoken name flips with its state), so the likely resolution is widening
the seven, as a sweep with a gate clause — never one binding at a time
(the template-grow lesson, written where that clause lives). Python is
left wide meanwhile: narrowing it would need an artificial wall in the
one binding whose design makes the uniform width free.

## ~~tools/tpl-surfaces.py sees constructors, not props — three follow-ups~~

CLOSED 2026-08-17 by the template role/inset slice, which is what made
them real: the census had to grow prop awareness or the new surface would
ship unswept, which is the exact defect class the census exists for.

Opened 2026-08-11. The census's zone readers match constructor
signatures, so the props slice's surfaces are held by check-sugar-surface
clauses and per-binding tests instead. Three specific gaps the fan-out
reports named:

- ~~**Go**: the reader's pattern sees neither a digit in a method name
  (`SetA11yID`) nor a generic method (`BindA11yID[`). The surface
  pairing lives in bindings/go/tplzone_test.go meanwhile; the two
  should agree or one should go.~~ CLOSED 2026-08-17. The pattern now reads
  `([A-Z][A-Za-z0-9]*)\s*[\(\[]`. The two agree rather than one going:
  Go's `Row` EMBEDS `*Tpl` so the compiler holds that pair, and the two
  surfaces that really can drift (`SumCase` and cmd/kaya-gen's
  `<name>Row`, both holding a private `t`) stay with tplzone_test.go —
  recorded in this file's own exemption list rather than merely absent.
- ~~**Java**: `Tpl` and `RowSurface` want the level-holding clause Rust's
  Tpl/Row pair has — a prop on one and not the other is reachable
  through `tx.forEach` and not `for (var row : ...)`.~~ CLOSED 2026-08-17.
  It has one, and
  it found drift the moment it ran: `RowSurface` forwarded the three
  a11y field-binds and not the five level-taking binds beside them, and
  not `when` — where the miss was sharpest, since `Tx.when` mints a LIVE
  widget id and `Tpl.when` mints a node id, so a guest inside a row
  trace reaching for the statement-level one emitted the wrong id space
  with nothing to say so. Six forwards, and the exclusion set is the
  four names measured to be plumbing.
- ~~**C#**: the generated `<Rec>Row` façade wants the same; a tested
  implementation was offered at the fan-out
  (docs/probes/csprobe/facade-parity.py, watched failing against HEAD's
  11 missing forwards including a year-old SetGrow drift).~~ CLOSED
  2026-08-17. The clause reads the GENERATED files — what a guest
  actually calls — and names the generator as the fix; finding none of
  them is itself a failure, since a façade reader that locates nothing
  agrees with everything. NOTE THE ENTRY WAS ALREADY HALF-STALE when it
  was closed: the 11 forwards had been closed by the props slice itself,
  so what was genuinely missing all along was only the gate that would
  notice the NEXT drift. A census offered and not landed is a
  measurement with a shelf life.

The census's three watched negatives now live in check-sugar-surface.sh:
a template setter deleted while its identically-spelled LIVE twin stays
(OCaml, the historical shape), a forward deleted from a generated C#
façade, and the zone's own header renamed — the third proving the reader
REFUSES a verdict rather than reporting an empty zone as a clean one.

## ~~The styling scene's depth stubs (slice 1 mid-flight, expected to close with the fan-out)~~

CLOSED 2026-08-19 as a tracker, and it closed the way it said it would —
with the fan-out. All three depth stubs below are struck and LANDED
2026-08-12; no `depth_stub("styling")` survives anywhere in the tree
(check-stubs green, and the ONE remaining depth-stub call in the whole
repo is typeface-on-iOS), and `styling` is a live scene on all five
lanes: validate-mac's SCENES, deploy-win's SCENES, run-suites' SCENES
with nine legs including the C floor, run-sim's IOS_SWIFT_SCENES and
IOS_GO_SCENES, and `run_apk styling-compose`. The one thing it carried
that is NOT closed by this strike — the full M3 scheme from a seed —
has been lifted out into its own entry directly below, so it stops
living inside a closed tracker.

As filed: three backends hold `depth_stub("styling")` while the SwiftUI
interpreter carries slice 1's one real brand lowering
(docs/styling-plan.md §3 — depth then breadth, the standing pattern):

- ~~**DEPTH STUB: styling on gtk** — the accent lowering is the
  `--accent-bg-color`/`--accent-fg-color`/standalone override route,
  measured working in kaya's container by the styling research, plus
  the adw feature bump v1_4 → v1_7 it needs. Fan-out work; the inset
  arm is already live there.~~ LANDED 2026-08-12: the three custom
  properties per appearance, re-written when the session flips, plus
  `.destructive-action`/`.suggested-action`/`.heading` + the AT-SPI
  heading role. NO adw bump was needed — the override is CSS the
  runtime library reads (1.6+, and the image ships 1.7.6), while the
  Rust surface it uses (`StyleManager::dark`) is 1.0-era; measured by
  building and painting at `v1_4`.
- ~~**DEPTH STUB: styling on winui**~~ — LANDED 2026-08-12. The brand
  accent and the two button roles were already real (the six
  `SystemAccentColor*` stops in Light+Dark ThemeDictionaries, crossed
  the way Fluent reads them, never `SystemAccentColor` itself and never
  a HighContrast entry; `AccentButtonStyle` for prominent,
  `SystemFillColorCriticalBrush` on the caption for destructive —
  Fluent ships no destructive button); the stub survived on HEADING
  alone, blocked by one missing line in tools/winui-bindgen's filter.
  `Microsoft.UI.Xaml.Automation.Peers.AutomationHeadingLevel` is now
  filtered in, and regenerating turned the four `usize` vtable pads
  into real methods — `AutomationProperties::SetHeadingLevel` (the
  setter) plus `GetHeadingLevel` on `AutomationPeer` and its subclasses
  (the read). The role arm is SetHeadingLevel(`Level2`) +
  `SubtitleTextBlockStyle`, and `WinUiStage::ax` consults HeadingLevel
  BEFORE the control-type ladder, because UIA has no heading control
  type — a heading TextBlock reports `Text`, so a type-first ladder
  answers `label/Sections` where the scene froze `heading/Sections`.
  That ordering is pinned by `ax_role`'s unit tests, watched failing.
  The enum's members are `None`, `Level1`..`Level9`; the docs'
  `HeadingLevel1` spelling is the UWP one and does not exist here. NOT
  PROVEN HERE: no leg ran — the windows lane needs its styling legs
  wired in tools/deploy-win.sh, and the pixels are the captures'
  business. (The inset arm was already live.)
- ~~**DEPTH STUB: styling on compose**~~ — LANDED 2026-08-12. The
  seed-derived scheme goes through the MaterialTheme root the foundation
  landed, the contrast level is read from UiModeManager and re-read
  through a ContrastChangeListener (a scheme that samples it once is the
  MDC #3524 no-op rebuilt one layer up), and the appearance is unpinned:
  the three app manifests now name kaya's own DayNight theme, the theme
  root paints the scheme's background and content colour, and the lane
  was run 82/82 in BOTH notnight and night with the mode read back
  before and after. Roles lower to M3's own emphasis ladder (outlined
  floor -> filled prominent, error-role container for destructive,
  `heading()` semantics + titleLarge for headings, which the published
  AccessibilityNodeInfo reports as `heading/` and which was watched
  falling back to `label/` with the lowering perturbed out). WHAT IS NOT
  DERIVED and is now its own open question below: the secondary,
  tertiary and neutral palettes stay Material's baseline, because
  deriving them needs HCT chroma clamping and that is a dependency
  decision rather than a coding one.

## ~~THE FULL M3 SCHEME FROM A SEED NEEDS A DEPENDENCY DECISION~~
KEY: HCT, chroma clamp, material-color-utilities, secondaryContainer,
seed palette, M3 scheme, materialkolor

COMPLETE 2026-08-31, ruled and landed the same day. ROUTE (b):
`com.materialkolor:material-color-utilities` pinned at **2.1.1** —
NOT the latest, and the ceiling is recorded at the pin
(android/kaya/build.gradle.kts): Kotlin 2.0.21 reads class metadata
only one minor ahead, 3.0.0+ ships 2.2+ metadata, and 5.0.x demands
minCompileSdk 37 against the module's 35; moving the pin means moving
the Kotlin plugin first. The four palettes derive in
KayaColorSchemes.of() via CorePalette (its chroma constants are
byte-identical to 5.0.1's), every role at the 2021 spec's tones
through kaya's own contrast machinery; the primary family's CIELab
path did not move; the ERROR family stays baseline by design. The
wall is KayaColorSchemesTest on the host JVM inside check-compose,
watched red 3-of-6 against the pre-palette code; its first draft
demanded 7:1 of a pair Material clamps by design and was itself
watched failing before the assertion moved to container-vs-page.
The portfolio now declares `brand_accent(0x1C71D8)` (the mark's
blue), so the lavender in every earlier Android capture — Material's
default seed showing through — reads as the brand. In the same
ruling: NO authored multi-color brand vocabulary — one seed stays the
whole surface (the other four platforms have one accent slot each;
Material's own idiom derives the rest), revisited only if a real app
hits the wall. Matrix ALL PASS: mac 349, linux 604, windows 201, ios
113, android 123, gates green — 1,390 legs.

As filed — open, and it is Akhil's: a dependency choice, not a coding
one. Measured
2026-08-12 while landing the Compose styling arm; lifted out of that
tracker 2026-08-19 when the tracker closed, so it is not read as part of
a finished slice. TRIGGER: someone wanting a brand seed to reach the
whole scheme rather than the accent family — or the maintainer simply
picking route (d).

The Compose brand lowering derives the PRIMARY family from the seed —
Material's own tone→role table, its own contrast curves, and its own
tone function (CIELab lightness) with a gamut loop that keeps the tone
and gives up chroma. What it cannot do without HCT is the other four
palettes, whose whole content is chroma clamping: secondary is the
seed's hue at chroma 16, tertiary at hue+60, the neutrals at chroma 4
and 8. Visible consequence today: under a brand, a NavigationBar's
selected-item indicator (secondaryContainer) and the page's surfaces
keep Material's baseline lavender hint. The four routes, priced:
(a) vendor Google's Java sources (Apache-2.0, a few thousand lines in
the tree, nothing to pin — the styling research's own first choice);
(b) `com.materialkolor:material-color-utilities`, a third-party KMP
port of the same code, one pinned line; (c) MDC-Android 1.12.0, which
bundles the utilities but marks every class `@RestrictTo` and drags
appcompat and a dozen more artifacts behind it (measured: 46 classes
under its `color/utilities` package, all restricted);
(d) leave it — the accent family is what every other backend brands
too. Nothing here is urgent and (d) is a real answer.

## ~~The identity scene's depth stubs (the Windows depth, expected to close with the fan-out)~~

CLOSED 2026-08-19 as a depth-stub tracker: all four stubs below are
struck and LANDED 2026-08-18, no `depth_stub("identity")` survives
anywhere in the tree (check-stubs green), and `identity` is a live scene
on all five lanes — validate-mac's SCENES, deploy-win's SCENES,
run-suites' SCENES (seven X11 legs, each wrapped in
identity-class-leg.py, plus the wayland witness), run-sim's
IOS_SWIFT_SCENES and IOS_GO_SCENES, and `run_apk identity-compose`.

WHAT THIS STRIKE DOES NOT CLOSE, and it is still inside this section
because each piece wants a home of its own rather than an agent's
filing: (1) the MEASURED maintainer question below — where the mark sits
in a PROMOTED window's caption — which is a caption-band arrangement
decision and the band's arrangement was a ruling; and (2) the three
packaging routes at the end of this section, all three re-checked absent
from the tree on 2026-08-19: Windows' AUMID
(`SetCurrentProcessExplicitAppUserModelID` — zero hits anywhere),
the macOS `.app` bundle (no kaya-authored bundle tooling), and the Linux
`.desktop` install (no `.desktop` file is tracked), whose precondition —
the `WM_CLASS` entry below — is now CLOSED, so it is unblocked.

As filed: the depth landed 2026-08-18: spec (`set_app_identity` / the apply
record) + the WinUI arm (both sinks — the window icon through
`CreateIconFromResourceEx` -> `Windowing_GetIconIdFromIcon` ->
`AppWindow.SetIcon(IconId)`, and the caption through
`TitleBar.IconSource` <- `ImageIconSource` <- `BitmapImage`) + the Rust
binding (`app_identity` / `app_identity_named`) + the `identity` scene,
Windows only. FOUR declarations across three backend files refused
through the depth-stub helper — the Swift file serves two platforms and
declared for each, because a `#if os(macOS)` arm that works on the
desktop says nothing about the phone — and that is what held the other
lanes' legs off in check-steps and check-stubs
(docs/app-identity-plan.md's sequencing — depth then breadth, the
standing pattern). ALL FOUR CLOSED 2026-08-18 in the breadth fan-out,
below, each with the lane result its arm measured; the settled-tree
five-lane run is the coordinator's and is not claimed here. What the
fan-out found instead of stubs is four new entries after this section —
two measured Linux gaps, and two questions that outgrew the scene:

- ~~**DEPTH STUB: identity on gtk**~~ — LANDED 2026-08-18.
  `ApplyOp::SetAppIdentity` replaces the deliberate no-op:
  `glib::set_prgname` + `glib::set_application_name` for the name,
  `gdk::Texture::from_bytes` + `gdk_toplevel_set_icon_list` for the
  mark, and the name written onto every window that has no title of its
  own — the fill-the-blank rule, never an override, which is the same
  rule the Windows caption writer spells and is why the scene's two
  `expect_title` lines are the same two lines on both. The icon route
  goes STRAIGHT to the texture list and never through an icon NAME, so
  both traps I4a measured (`add_search_path` scans at add time;
  `has_icon()==TRUE` over an empty `get_icon_sizes` makes GTK delete
  `_NET_WM_ICON` silently) sit on a road not taken. Three call sites,
  the WinUI arm's shape: the declaration, and the two places a window is
  first presented; a window with no `GdkSurface` yet is realized later
  and picked up there. `Stage::app_icon` splits an in-process
  `identity_probe` from the `xprop -id <xid> -notype 32c` read run
  OUTSIDE the main context, because the verb is polled every 20 ms and
  holding the context across a subprocess would stall the app being
  read; the `32c` is load-bearing, since xprop KNOWS `_NET_WM_ICON` and
  pretty-prints it as `Icon (64 x 64)` plus an ASCII rendering, which
  says an icon is there and nothing about what colour it is. Three icon
  states (Undeclared / Texture / Refused) rather than two, so the
  diagnostic cannot do what `kayaOpenPanelWhyNot` did one platform over.
  Five watched negatives, each with its substitution count asserted and
  restored from a saved copy; the linux lane went 526 -> 534 legs with
  all 526 control verdicts byte-identical. The two things this stub OWED
  are now the two open entries below — they are gaps in the PLATFORM,
  measured, not work the arm left.
- ~~**DEPTH STUB: identity on swiftui/macos**~~ — LANDED 2026-08-18,
  and it closed the measurement it owed. `kayaApplyMacIdentity` raises
  the activation policy (ruling 2), installs
  `NSApp.applicationIconImage` from the wire's PNG, and writes the menu
  bar's first item title; `kayaWindowCaption` then gives a window with
  no title of its own the declared name, which is what
  `expect_title window#1` reads. THE OWED MEASUREMENT IS ANSWERED: a
  policy raised AFTER launch does put the Dock tile up
  (`setActivationPolicy` returned true, tile captured), so the
  `KAYA_ACTIVATE=1` fallback this entry held open is not wired and
  swift/KayaSwiftUIEntry.swift is untouched — and `.regular` does not
  take the front, so eight identity legs put eight tiles up and steal
  nobody's keyboard. THE FINDING WORTH KEEPING:
  `applicationIconImage` reads back as a 128x128 SIXTEEN-BIT snapshot in
  the display's ICC profile, not the 1024x1024 the plan recorded, and
  converting it back to sRGB through an EIGHT-bit context quantizes
  twice — it reported `1D71D8` for a declared `1C71D8`, one unit out,
  which would have made mac the one lane that could not meet a
  byte-frozen expectation. A 16-bit context with ONE rounding at the end
  recovers all four exactly; truncating the high byte instead of
  rounding does not, so the rounding is load-bearing and the comment
  says so. Eight legs; the mac lane ran 303 legs with no failure. A
  defect its own negative caught: the first caption reader answered `""`
  for a window that DOES NOT EXIST, so `expect_title window#1` passed
  vacuously on iOS until the read was made to `guard let` the window.
- ~~**DEPTH STUB: identity on swiftui/ios**~~ — LANDED 2026-08-18 as
  PACKAGING, which is what this entry said it would be.
  tools/ios/run-sim.sh reads guests/assets/identity.toml ONCE, at the
  top, with tomllib, and never retypes either value; `make_bundle` grew
  a fourth argument that copies the declared mark into the bundle
  VERBATIM — not resized, because the byte-equality rule holds every
  app-icon resource in the tree identical to the declaration and there
  is no asset catalog and no `actool` in this dev shell — and fills
  tools/ios/Info.plist.in's new `@IDENTITY@` slot with
  `CFBundleDisplayName` plus
  `CFBundleIcons > CFBundlePrimaryIcon > CFBundleIconFiles`. The read
  (`kayaIOSAppIconWhyNot`, five states, all five made to print) resolves
  the named file out of the bundle, holds it equal to the bytes the
  guest declared over the wire, and then decodes it with UIKit's OWN
  decoder — so its samples prove the CONVERSION rather than that a file
  was copied. The guest is pointed at the app's DATA CONTAINER and
  deliberately not at the bundle's copy: comparing the bundle with
  itself would make ruling 4's byte equality vacuous on this lane, where
  the data container is a second, independently delivered copy. Three
  legs; `tools/ios/run-sim.sh all` ran 87 legs with zero failures. The
  permanent half — that iOS has no runtime route at all — is now a
  stated divergence in DESIGN.md rather than a ledger row, because it is
  a fact about the platform and not a schedule.
- ~~**DEPTH STUB: identity on compose**~~ — LANDED 2026-08-18, the
  ruling's way. android/build.gradle.kts reads
  guests/assets/identity.toml at configuration time, refuses loudly on a
  missing, empty or unparseable declaration or a missing icon file,
  copies the declared PNG verbatim into each application module's
  generated mipmap, and sets the `kayaAppLabel` manifest placeholder;
  the three app manifests name `@mipmap/kaya_mark` and
  `${kayaAppLabel}`, and `isCrunchPngs = false` stops aapt re-encoding
  the bytes behind the check. Measured through the whole chain: the
  declared file, the generated resource and the entry unzipped OUT OF
  THE APK share one sha256, and `aapt2 dump badging` reports
  `application-label:'Aurora Notes'`. The Compose read resolves this
  package's launcher icon through the system PackageManager
  (`queryIntentActivities(MAIN/LAUNCHER)` -> `ResolveInfo.loadIcon`)
  and samples it, behind a VACUITY WALL that is the point of the whole
  arm: the icon is compiled into the APK whether a guest declared
  anything or not, so the wire declaration must have arrived, decoded,
  and matched before the read will answer at all. Three watched
  negatives, three different sentences. `TaskDescription` stays REFUSED
  (docs/app-identity-plan.md I6) and nothing here calls it. THE
  REGRESSION IT FOUND is the entry's real lesson: `run_apk_on` waited
  for the harness accessibility service by grepping
  `dumpsys accessibility` for `Bound services:.*kaya`, and that line
  prints a LABEL — the service declared none of its own and inherited
  the application's, which used to be "kaya milestone 0". The moment
  `android:label` became the declared name the word "kaya" left the line
  and every leg on every device failed saying the picker never came up,
  through three arms and a reboot each, with the service bound the whole
  time and nothing naming the cause. The service now names itself
  (`android:label="kaya harness"`) and `a11y_label_check` refuses before
  any leg runs, including when it reads no service at all.

One MEASURED question the depth slice raises and does not answer, for
the maintainer rather than for an agent: **where in a PROMOTED window's
caption the app mark sits.** On a window with the standard system
caption the mark is at the caption's LEFT EDGE, which is the convention
the original ledger entry cited and which the system draws unprompted
from the window icon (captured 2026-08-18: the mark, then the window's
title). On a window whose catalog promotes a command, the custom
`TitleBar` draws it AFTER the menu — `File`, then the mark, then the
centred title — because the control lays `IconSource` out after
`LeftHeader` and kaya's `LeftHeader` is the window's menu (the one-band
revision of 2026-08-17). Both are captured. Restoring the left-edge
convention on promoted windows means putting the icon INSIDE
`LeftHeader`, ahead of the `MenuBar`, in a container of kaya's own —
which changes `LeftHeader`'s width, which is an input to
`center_caption_title`'s clamp and to the lane's caption-centre probe.
That is a caption-band arrangement decision, and the band's arrangement
was a maintainer ruling; it is not an agent's to take.

Beyond the four stubs, what the depth slice deliberately left for the
breadth arms, and where each of those went. LANDED 2026-08-18: the
declaration itself (guests/assets/identity.toml, ruling 4's "one file,
two readers", beside the vendored typeface's own pattern); the
byte-equality gate over it (tools/check-app-identity.sh, six clauses,
which found a real drift on its first run — tools/deploy-win.sh staged
the mark with a GLOB and therefore shipped whatever was in the directory
rather than what was declared); the PACKAGING readers the phones have
(the APK's mipmap and `make_bundle`'s bundle copy, per ruling 3); and
the seven remaining bindings' sugar, which turned
`check_styling_point app_identity` from RED-by-design to green in all
eight languages. STILL OPEN: Windows' own AUMID
(`SetCurrentProcessExplicitAppUserModelID`), which draws no pixel but
would stop kaya's Python, Java and dotnet guests grouping under the HOST
executable's taskbar button; the macOS `.app` bundle, which is the only
route to `CFBundleName` and therefore to the Cmd-Tab label; and a Linux
`.desktop` install, whose precondition is the `WM_CLASS` entry below.

## The Linux runtime icon route is X11-only until GTK 4.20 (measured 2026-08-18)
KEY: identity, _NET_WM_ICON, xdg-toplevel-icon, gdk_toplevel_set_icon_list, wayland witness, GTK 4.20

MEASURED on the lane image: `pkg-config --modversion gtk4` is **4.18.6**,
whose Wayland backend answers the icon-list property with a literal
`break;`, and `wayland-info` on the lane's sway lists no
`xdg_toplevel_icon_manager_v1`. So a RUNNING kaya binary puts real pixels
on an X11 window's `_NET_WM_ICON` and nothing at all on Wayland. The
lowering is already protocol-agnostic — GTK 4.20 lowers this same texture
list into `xdg_toplevel_icon_v1.add_buffer` — so what closes this is the
lane image moving, not code in crates/kaya/src/gtk.rs.

THIS IS NOT A DEPTH STUB AND IT IS NOT HELD OPEN BY ONE. gtk.rs has the
feature; what it has not got is a protocol, and a depth stub is
per-BACKEND. So the gap is expressed as a LEG: the wayland ring runs
tools/linux/identity-wayland-witness.sh, which runs the same guest under
wayland and requires the leg to fail on the icon steps AND ONLY on the
icon steps — the count of icon failures read out of
tools/scenes/identity.steps rather than typed into the script, the
failing sentence naming the GDK display object it actually found, and a
grep for the backend's own record of the `gdk_toplevel_set_icon_list`
call, which is what makes "protocol-agnostic by construction" a tested
claim rather than a comment. The NAME half of the identity IS observable
on wayland and stays under test there.

IT SELF-REDS THE DAY THE PROTOCOL ARRIVES. The witness asserts that this
gap still exists, so a platform that starts drawing the icon turns the
leg RED and its failure text names the honest response: run the scene
here. A leg that printed no `KAYA_SELFTEST` verdict at all fails there
too, so "the gap is as documented" can never be confused with "the guest
died at startup". Nothing has to be remembered for this entry to be
re-examined.

An INSTALLED app is unaffected on either protocol: that identity comes
from a `.desktop` file plus the hicolor install, which is ruling 5's
first surface and carries no GTK version condition at all.

## ~~The primary window keeps its launcher binary's `app_id`/`WM_CLASS`~~ — CLOSED 2026-08-18
KEY: identity, app_id, WM_CLASS, g_set_prgname, gdk4-x11, gdk4-wayland, desktop file

**Done.** The primary window's class now follows the declaration on BOTH
protocols, so a `.desktop` entry can match a kaya app's main window —
the precondition the Linux half of the packaging story was waiting on.
`crates/kaya/src/gtk.rs`'s `reclass_toplevels` runs at the identity apply,
after `g_set_prgname`, and moves the class of the windows that ALREADY
EXIST; the program name keeps covering every window created afterwards,
and the two halves are disjoint rather than redundant. `gdk4-x11`,
`gdk4-wayland` and `x11-dl` are in crates/kaya/Cargo.toml with the
reasoning beside them.

MEASURED, both protocols permitting it and neither needing a fallback:
X11 takes `XSetClassHint` on the realized surface's xid — GDK4 exposes no
wrapper, and `set_utf8_property` is NOT the route, since `WM_CLASS` is
ICCCM `STRING` and a `UTF8_STRING` copy is the right name with the wrong
type — and Wayland takes `gdk_wayland_toplevel_set_application_id`, which
xdg-shell explicitly permits after map ("Like other properties, a
set_app_id request can be sent after the xdg_toplevel has been mapped to
update the property"); sway honours it in its own tree.

Held by the LEGS on both rings: `tools/linux/identity-class-leg.py` wraps
every identity leg, reads the class off the real server — `xprop WM_CLASS`
on X11, sway's own tree on wayland — and requires every mapped toplevel of
the app to carry the declared name, plus kaya's own record of having moved
one, so a launcher that happened to share the name cannot pass it.

**A correction to the correction, MEASURED 2026-08-18.** The entry above
used to say a kaya window's class follows `g_get_prgname()`. True on X11
and true on Wayland WITHOUT a session bus; with one, a GtkApplication
window's `app_id` comes from the GApplication ID instead, so the same
binary on the same protocol reported `identity` in one run and
`dev.kaya.Milestone2` in the next, the only difference being the bus that
`tools/linux/a11y-leg.sh` launches. That made the gap worse than recorded,
not better: every kaya app on a real Wayland desktop advertised kaya's own
milestone-2 id. tools/linux/run-suites.sh's comment carries the
measurement.

## ~~`kaya_capabilities()` has no binding surface in any of the eight languages (found 2026-08-18)~~
KEY: kaya_capabilities, KAYA_CAP_AUX_WINDOWS, capability query, create_window, aux window, eight-language sugar

CLOSED 2026-08-19. The maintainer ruled the wrap in, now, because it
cleans up existing code rather than only anticipating a handshake. All
eight bindings have it: the query is `capabilities` in each language's
casing and it answers with NAMED BOOLEANS — `aux_windows` / `AuxWindows`
/ `auxWindows` on a record, struct, dataclass or newtype — never the raw
u64. tools/check-sugar-surface.sh holds the eight level in three clauses
(the query, the named flag, and the bit NUMBER against the core's), each
with a watched negative; 21 perturbations were driven and every one went
red.

THE CORE GOT ONE PREDICATE OUT OF IT, which is the part that matters
more than the sugar. `kaya_capabilities()` and the `create_window` wall
were each their OWN `#[cfg]` in their own file, free to drift in silence
— a distinction of no consequence while every guest derived the answer
from its own platform predicate, and the whole contract the moment eight
bindings hand that answer out. Both now read
`crates/kaya/src/scene.rs`'s `CAPABILITIES`, a `cfg!`-folded const in an
always-compiled module, so what a guest is TOLD and what it would WALK
INTO are the same bit by construction. The wall's sentence did not
change, and neither did its behavior.

AND THE FOUR PLATFORM PREDICATES IN THE GUESTS ARE GONE, which was the
condition of the ruling. Go's `untitled_desktop.go`/`untitled_phone.go`
build-tag pair is one file with an `if`; Rust's three `#[cfg]` attributes
(on an import, a const and the behavior) are none; Java's
`Class.forName("android.os.Build")` probe is deleted; Swift's
`#if !os(iOS)` around the CALLS is a runtime `if`. The other four ports
of the scene ask too, though none of them ever runs where the answer is
false: eight ports of one scene should read the same, and a binding
surface no guest calls is a binding surface no lane exercises.

The rule the sweep used, for the next reader: a conditional that exists
to avoid CALLING something becomes a capability query; one that exists to
avoid COMPILING something stays. The `scene_root()` splits in
guests/rust's filedialog/save/clipboard and guests/swift's
save/clipboard pick a DIRECTORY per platform — no capability bit answers
"where do documents live" — and guests/go/cmd's main pair is a program
entry point that must differ. All kept.

The original entry is kept below for the record.

`kaya_capabilities()` is a real C export (crates/kaya/src/capi.rs, and
crates/kaya/include/kaya.h) that answers exactly the question the
identity scene was forced to ask — does this host have auxiliary windows
— and NO binding wraps it, in any of the eight languages (verified by
grep). This is the first slice where that cost something. `create_window`
is rejected AT THE ROOT on iOS and Android
(`KAYA_CAP_AUX_WINDOWS` is unset), the identity guest opens an auxiliary
window in its BUILD closure — that window is where
`expect_title window#1` reads the declared name back — so on a phone the
guest aborted after one harness step, with the identity already declared.
`sections` gets away with the same call by reachability (its
`create_window` sits in a handler only the desktop tail clicks) and
`split`/`panels` are never phone legs at all.

NOTHING IS BROKEN TODAY, and that is why this is a question rather than a
gap: each guest that reaches a phone derives the answer from its own
platform predicate, keyed on the SAME predicate the core keys on — Go a
build-tag pair (`untitled_desktop.go` / `untitled_phone.go`), Swift a
`#if !os(iOS)`, Rust the `cfg(target_os)` the core's own arm uses, and
Java a runtime `Class.forName("android.os.Build")` probe, because one
Java source is compiled twice (javac for the desktop, gradle for
Android) and the language has no conditional compilation. Each was
watched: `go list` resolves the pair per GOOS, a poisoned copy proved the
Swift branch is compiled on macOS and excluded on iOS, and a wrong Java
answer fails loudly in both directions rather than passing vacuously.
That is the invariant-1 shape — one semantics, four spellings.

THE DECISION IS THE MAINTAINER'S because it is an eight-language sugar
point, not an arm's: whether the capability word the core already owns
gets one spelling per binding plus a `check_styling_point`-style row
holding all eight level, or whether guests keep deriving it from platform
predicates. Invariant 2 makes it a sweep across all eight either way. No
arm took it.

## ~~No gate compiles a Swift GUEST for iOS (gate gap, found 2026-08-18)~~
KEY: swift-typecheck, iOS guest, guests/swift, gate gap, os(iOS)

CLOSED 2026-08-18. tools/swift-typecheck.sh grew the pass: the guests
the iOS lane ships, compiled against the iphonesimulator SDK with the
LANE's flags. Both halves of "the lane's" are read out of
tools/ios/run-sim.sh rather than restated here — the guest list
(IOS_SWIFT_SCENES, 28 of the 37 sources; window/panels and friends are
desktop-only by design) and the deployment target (IOS_MIN = 16.0, which
is NOT the 17.0 the interpreter passes use, and the older target is the
stricter one for availability diagnostics). A gate that invented either
number would be looser or tighter than the lane it stands in for.

Watched red, the asymmetry that is the whole argument for the pass: an
`import AppKit` + `NSWorkspace` use planted in guests/swift/identity.swift
OUTSIDE its `#if !os(iOS)` fails the iOS pass (RC=1, 2 diagnostics,
"no such module 'AppKit'") while the macOS pass over the same bytes stays
green (RC=0, 0 diagnostics). Every pass now names the file set it walked
in the verdict, and a pass handed nothing to compile REFUSES rather than
passes — driven three ways: an empty guests/swift, a run-sim.sh that no
longer declares IOS_SWIFT_SCENES, and a lane entry naming a guest with no
source. No keying change was needed: `tools/` rides every gate key
(tools/build-id.sh), so reading run-sim.sh is already inside
swift-typecheck's declared input set.

The original entry is kept below for the record.

tools/swift-typecheck.sh's iOS pass covers swift/KayaSwiftUI.swift,
swift/KayaSwiftUIEntry.swift and tools/ios/clipctl. Nothing in the gate
set compiles anything under guests/swift/ against an iOS SDK, so the
first compiler to see an `#if os(iOS)` mistake in a Swift guest is the
simulator, minutes into a run.

THAT IS LIVE FROM 2026-08-18 RATHER THAN THEORETICAL:
guests/swift/identity.swift now carries a `#if !os(iOS)` guard around the
auxiliary window, and Swift guests reach phones — tools/ios/run-sim.sh
builds bundles out of guests/swift. The arm typechecked the file by hand
against the simulator SDK (RC=0) and proved the branch really is excluded
there, by splicing a poisoned line into a TEMP COPY: macOS RC=1 with
three diagnostics naming the poison, iOS RC=0 with none. But a hand check
is not a gate, and invariant 3 asks where the wall SITS.

Closing it is small and the shape is already in the file: the macOS guest
loop directly above the iOS pass in tools/swift-typecheck.sh is exactly
what this needs, pointed at the iOS SDK. Note when doing it that the gate
is named after a layer it did not always compile, which has burned
someone here before (docs/traps.md).

## ~~kaya windows have no app icon (maintainer, 2026-08-17)~~
KEY: app icon, window identity, IconSource, caption left

~~ANSWERED 2026-08-18 by docs/app-identity-plan.md (ratified) and the
Windows depth slice above. The original entry is kept below for the
record.~~

Found while ruling on the Windows caption conventions: Windows puts the
app icon at the caption's left edge (Win95 through Notepad on 11), and
kaya has no app-icon vocabulary at all — nothing an app can declare,
nothing a backend lowers. The WinUI TitleBar control has an `IconSource`
slot waiting; mac has the Dock/window-restoration identity; Linux has
the .desktop/window icon; the phones have launcher icons the packaging
already owes. This is APP IDENTITY machinery, not a layout tweak: one
declared identity (name + icon bytes, likely the wire blob channel the
typeface uses) lowered per platform. Design question for a future
slice; the caption-left slot is its Windows home when it lands.

## The caption mark's system-menu affordance waits on two bindings (found 2026-08-18)
KEY: caption icon, system menu, NonClientRegionKind, InputNonClientPointerSource

Every precedent's caption icon opens the system menu on click (the
Win95-lineage affordance). kaya's mark cannot yet: the TitleBar control
publishes the LeftHeader as passthrough to the input system, so real
pointer input never reaches kaya's hit-test (measured: a synthesized
click produced zero WM_NCHITTEST while the drag surface produced five —
the wndproc CAN answer HTSYSMENU; input never asks). The clean route is
SetRegionRects(NonClientRegionKind.Icon, ...) — the Icon kind is
MEASURED PRESENT in the pinned winmd and absent from the generated
bindings. Closing it: two winui-bindgen filter entries, then the
precedence measurement the report says cannot be made until the binding
exists (docs/chrome/winui-icon-position.md).

## The identity scene cannot SEE the promoted caption's mark (proved 2026-08-18)
KEY: identity read, LeftHeader mark, read gap, wall-only guard

The identity read walks WM_GETICON and the window class — honest for the
window icon and the taskbar, blind to the LeftHeader-composed mark on a
promoted window. Proved, not asserted: mark dropped AND the in-process
wall disabled → the scene PASSES with a byte-identical verdict. The wall
(armed per layout pass) is the standing guard; the harness-level read is
the gap. Closing it: a UIA read of the caption band's mark element,
likely alongside the system-menu binding work above.

## ~~The pasteboard needs a foreign-writer witness (measured 2026-08-18)~~
KEY: pasteboard changeCount, clipboard legs, foreign writer, human at the machine

Two mac clipboard legs failed mid-matrix with pastes reading "" while
six siblings passed and the same legs pass standalone: the machine's
one pasteboard was written under the legs (a human ⌘C anywhere does
it — the maintainer was at the keyboard, and IDE activity timestamps
align). The failure SENTENCE cost the investigation: "reads empty"
cannot discriminate a broken paste from a foreign writer.

CLOSED 2026-08-18, swift/KayaSwiftUI.swift. Every stage of a clip — the
app's copy, a seed that settled, a native cut or copy — records the
changeCount it left (kayaClipStaging/kayaClipOwned), and every read or
paste that consumes it compares first (kayaClipWitness). On a mismatch
the step fails with what was measured and nothing more: "the pasteboard
changed under this leg (changeCount N -> M): a foreign writer replaced
the staged content — <consumer> is reading a board this leg did not
stage, and it now offers [types]". WHO wrote it is not on the
pasteboard, so the sentence names nobody. The script then stops — no
assertion after that point is about this leg's clip.

THE DOOR, not the read, is where a paste is witnessed. A paste whose
staged clip was replaced is usually DISABLED, and on macOS the harness
dispatches the REAL NSMenuItem, so kaya gets no say once AppKit has
greyed it: the first placement (inside kayaPerformClipboardRole) never
fired, and the leg still failed "entry#1 reads """. The witness sits in
kayaRoleInertNote, ahead of the enablement question, which every
activation route reaches.

Watched both ways, the perturbation measured rather than assumed
(docs/chrome/pasteboard-witness.md): a driver waits for the leg's
own trace to reach the step after the seed, writes the machine's
pasteboard from OUTSIDE the leg, and reads pbpaste before and after.
With the witness disabled the leg says `label#0 reads "empty", wanted
"text from another app"` — the incident's own sentence; with it, the
transition. All three consumption sites were seen firing. And the
FALSE POSITIVE is watched too: with the cut/copy stage removed, a
native Copy — the leg's own write — is reported as a foreign writer,
and with it the same leg passes. All eight mac clipboard legs green.

## iOS identity packaging is proven on the simulator only (2026-08-18)
KEY: iOS signing, device install, bundle packaging, simulator-only

The identity fan-out's iOS packaging reader (make_bundle consuming the
declaration) is proven end-to-end on the SIMULATOR. The lane has no
.app SIGNING and no device-install route, so a real iPhone has never
shown the mark. Closing it is a signing/provisioning story — its own
slice when a device lane exists; recorded so "iOS identity works" is
read at its true width.

## The iOS pasteboard witness has its marker; two questions stay open (2026-08-18)
KEY: UIPasteboard changedNotification, changeCount focus bumps, iOS witness, marker type

WITNESS LANDED 2026-08-18, on a private marker type rather than the
count. Every clip a kaya-controlled writer composes on iOS carries
`dev.kaya/staged` (swift/KayaSwiftUI.swift's `kayaClipMarkerType`, and
tools/ios/clipctl/main.swift for a seed), and the same consumption sites
the mac witness guards check its PRESENCE where mac checks the count.
Watched failing both ways: a foreign write between stage and consumption
fails the leg naming the marker, and deleting the marker from the seed's
writer fails it naming the stage. docs/traps.md carries the design and
its limits.

THE NOTIFICATION CANDIDATE THIS ENTRY USED TO PROPOSE IS DEAD, and it
was measured rather than argued: a genuine foreign write from another
process on the same simulator delivered ZERO `changedNotification` to an
observing app, twice — app `active` (printed, not assumed), runloop
turning, observer on `object: nil`. It fires for the app's own writes
only. A witness keyed on it would never fire on the event it exists to
catch, which is worse than the false positive it was meant to replace.
Do not build it. (The earlier reading — "it discriminated correctly in
both directions" — came from a probe that only ever saw the app's own
writes.)

WHY FOCUS TOUCHES THE COUNT is answered too, and the answer is that it
does not touch the pasteboard SERVER at all: the +4 is private to the
focusing process, the server's count moves +1 per write, and the two
never reconcile (docs/traps.md). What raises it is the text-input
session — a bare `UIView & UIKeyInput` bumps, a non-editable UITextView
does not, a secure field does not.

WHAT STAYS OPEN, both small:
- REAL HARDWARE is unmeasured. No device in this environment, and no
  credible source compares simulator with device for this behaviour.
  The phenomenon is device-attested in kind for iOS 13 (Apple forums
  123596 and 131419); the magnitude on iOS 26 hardware, and the
  per-process finding above, are untested there. Nothing in the marker
  route depends on the number, so this is confirmation rather than risk.
- THE UIKit FUNCTION BEHIND THE CONSULTATION is unidentified. Not
  `canPerformAction(_:withSender:)` for `paste:` — the 2019 forum
  attribution — which moves nothing when called directly on iOS 26.5.
  The one clue is that `isSecureTextEntry = true` is EXEMPT, which is
  exactly the field iOS does not offer clipboard content to, so the
  consultation is plausibly the clipboard OFFER; no callable API
  reproduces it, and the +4's shape (two inside `becomeFirstResponder`,
  two ~10ms after) says two consultations, twice.

## ~~Comments are drowning the code~~ (maintainer, 2026-08-17)
KEY: comment verbosity, examples readability, war stories, traps pointers

CLOSED 2026-08-19: sweep 2 covered the rest of the tree — thirteen lanes
over crates/, bindings/, tools/, swift/, android/ plus a second guest
pass. ~21,000 comment lines removed (71,253 → ~50,250 by the lanes' own
measured counts), every lane skeleton-proven comment-only against a base
snapshot, every lane's compile and gate battery green. Measured findings
were kept byte-for-byte where they are the only copy; the lanes' reports
itemise them. Two citation families that pointed into a dead session
scratchpad were recovered and landed (docs/ranges-units.md,
docs/styling/) with every citation repointed. What remains above the
target ratio is deliberate: dated measurements, wire-vocabulary docs and
per-clause constraint text. The sweep's own tooling traps are in
docs/traps.md under "Cutting comments is its own trap family".

STATUS 2026-08-18: the EXAMPLES are done — (1) and (2) both. The rule is
in CLAUDE.md/AGENTS.md's environment section, rewritten to the
maintainer's own formulation after he judged the calibration sample and
ruled the cut must go deeper than it did: "the only things you shouldn't
cut are things you'll need for future claude sessions that might need
that context. everything else should be nixed, because it just makes
things harder to read."

All 332 guest files in all nine languages are swept, the four sample
files re-cut to the deeper rule, and the C floor cut like everything
else — the maintainer's ruling on invariant 5 is that the CODE is the
floor's documentation, so its guests keep only agent-context lines.
Both blockers the sample recorded are cleared: the concurrent
template-caption slice landed (5708c98), and the line anchors
docs/sugar-pass-plan.md and this file carry were re-read and repaired.

Four measured findings that lived ONLY in a guest comment were moved to
docs/traps.md before the files carrying them were touched: the live-zone
`When` that stamps an empty key path (the editor's find bar is a
For-of-one-row because of it), `destroy_window(0)`'s abort with no
affirmative for `veto_close` (live in nine dirty guests), the stall
scene's day-not-forever wedge, and each language's own string-offset
unit. What is left in the guests is a pointer.

WHAT WAS NOT DONE THEN — the rest of the tree — is what the 2026-08-19
sweep above did.

The ruling: a comment describes what the code does or states a constraint
the code cannot show — in a line or two. It never explains something the
reader didn't ask, and it never carries the history of how we arrived
here. The repo's comments have grown into essays, worst in the examples,
which are the API's public face: a guest should read as ten lines of
kaya, and today it reads as a page of archaeology with ten lines of kaya
inside.

The cleanup slice, when scheduled: (1) the rule goes into
CLAUDE.md/AGENTS.md so every future session writes to it; (2) examples
first, as their own commit, so the maintainer can calibrate the cut on
one guest before it sweeps the tree; (3) nothing agents need is lost, it
MOVES: a comment whose content is a measured finding gets that finding
into docs/traps.md (if it is not already there) and shrinks to a
one-line pointer at the trap's name. The walls stay; the war stories
relocate.

## ~~GAP — the symbol-floor gate was drafted and never landed~~ (found 2026-08-19)
KEY: symbol-floor gate, check-symbols, name_availability.plist, kayaSymbolTable

RESOLVED 2026-08-19, same day: the maintainer ruled "register it" and the
draft landed as tools/check-symbols.sh, gate 38 in gates.sh's sweep, the
check-gates census and both doctrine mirrors. Two changes against the
draft: the row regex learned the table's fourth column (`rendered`, the
AX read-back measurement, which the floor deliberately does not bind),
and the OK line's count now comes from the same python that enforced the
rule rather than a second grep that could drift to zero. The
kayaSymbolTable header now names the gate. 20 names verified at or below
macOS 13.0 / iOS 16.0 on landing day.

The styling milestone measured (2026-08-16) that NO SCENE can guard the
SF Symbols floor column in swift/KayaSwiftUI.swift's `kayaSymbolTable`:
a resolution check only fails on a machine old enough to BE the floor,
so the scene-level assertion is vacuous on every machine the project
runs on. The only real guard is a static gate reading Apple's
`name_availability.plist` — every name's introduction year against the
declared floor. That gate WAS DRAFTED (`check-symbols.sh`, ~6KB, written
2026-08-16 in that session's scratchpad) and never landed; the
kayaSymbolTable header cited it at a path that stopped existing when the
session ended. Landing it is a registration decision, not just a copy:
it must join tools/, gates.sh's sweep (or its EXCLUDED table with a
reason), the check-gates census, and the CLAUDE.md/AGENTS.md gate list —
which is the maintainer's review. RECOVERY: the draft's bytes are in
this project's session transcripts under
~/.claude/projects/-Users-akhilindurti-Projects-kaya/ — search the
subagent .jsonl files for `check-symbols.sh` and replay the Write
payload (the styling-doc recovery of 2026-08-19 proved this route).

## ~~The template button's caption is not uniform~~ (found 2026-08-17)
KEY: template zone, button caption, bound source, tpl-surfaces takes-a-source

CLOSED 2026-08-18, in the three bindings plus the census.

The eight-binding caption survey (annotated in docs/tpl-props-plan.md)
found template-zone drift the live zone does not have: a per-row button
caption is SUGAR in Rust/Go/Java/OCaml/Haskell, FLOOR-ONLY in C#
(`Tpl.Button(string)`) and Swift (`KayaTpl.button(_:)`), and NOT
EXPRESSIBLE at all in Python — the "shipped unable to declare it" shape
again. It is invisible to tools/tpl-surfaces.py because the census asks
whether a kind HAS a constructor, never whether the constructor takes a
live source.

THE THREE SPELLINGS, each its own language's idiom rather than a shared
one. C# and Swift are overload languages whose `Label`/`label` already
ships the const/signal/field triple, so `Tpl.Button(Signal)` +
`Tpl.Button(Field<string>)` and `KayaTpl.button(KayaSignal)` +
`KayaTpl.button(KayaField<String>)` are simply that triple finished on
the neighbouring kind. Python gained the CAPABILITY, not a spelling:
`_text_value` raises on anything but `str` and the binding has no
widget-level bind to fall to, so `button(bind=)` had to be built, taking
a Signal, the enclosing For's element or one of its fields exactly as
`label(bind=)` does.

AND THE LIVE ZONE STAYED SHUT, which is the half that nearly went wrong.
A bound caption is template-only in all eight (docs/tpl-props-plan.md
F5, re-verified the day before). The other seven refuse it live by
having no such overload; Python's transaction is ambient, so one
function serves both zones and an unguarded `bind=` would have opened a
live-zone divergence in exactly one binding while closing the template
one. It raises outside a template, naming F5 — the same "Python's
equivalent of not compiling is raising here" the `label(bind=)` floor
already uses.

THE CENSUS GREW THE SECOND QUESTION (tools/tpl-surfaces.py): not whether
the kind has a constructor but whether that constructor takes the ROW,
asked as a PAIR — a signal source AND an element field — because the
signal arm alone is answered by every live zone in the tree and the
field arm is the one only a template can spell. Python is IN this census
though it is exempt from the two above, and the difference is the whole
finding: an ambient surface gives every KIND to a template by
construction, but a source is not a kind. check-sugar-surface's self-test
(e) splices the three files back in from `c9bb989` and requires the red
to name csharp, swift and python — five quiet, three named, the drift's
own shape — plus a deleted overload in an UNTOUCHED sibling (java) and a
renamed constructor that must make the reader refuse rather than report
an empty set.

~~STILL OPEN, one surface over: C#'s generated `<Rec>Row` façade
(guests/csharp/*Kaya.cs, emitted by tools/kaya-csgen) forwards
`Button(string)` alone and now lags the zone by two overloads~~ — FIXED
2026-08-19 with the census clause that could not see it; the record is
the entry directly below. As filed: the new arms were reachable through
`tx.Each` and not through `foreach (var row in c.Rows())`, and two `Fwd`
lines beside Program.cs's `Fwd("Button", ["string text"], "text")` plus
a regeneration closed it.

## ~~C#'s generated row façade lags the template button's new caption arms (2026-08-18)~~
KEY: csharp Rec Row facade, kaya-csgen Fwd, Button overloads, tpl-surfaces name-set blindness

FIXED 2026-08-19, as one slice exactly as this entry required. Both
`Fwd` lines went in beside `Fwd("Button", ["string text"], "text")` in
tools/kaya-csgen/Program.cs (line 311 today, not the :322 below — the
file shifted), the two generated façades moved with them
(guests/csharp/{Item,Todo}Kaya.cs now carry `Button(Signal)` and
`Button(Field<string>)`), and tpl-surfaces.py's façade clause compares
ARITY-AND-TYPE instead of name sets — the C-family façades are keyed by
`(name, (parameter types…))` through `_typed_members`, reusing the
splitter the source census already reads for, with Rust's `Row` left
name-keyed because `pub fn` has no overloads to lose. WATCHED FAILING:
one `Button(Signal)` forward deleted from a copy of TodoKaya.cs, 1
substitution printed, the census red naming `Button(Signal)` — and the
OLD name-keyed clause measured GREEN against that same perturbed file,
which is the whole point. Restored from the saved copy, `shasum -c` OK,
census green, `dotnet build` clean.

As filed: tools/kaya-csgen/Program.cs:322 forwards `Button(string text)` and
nothing else, so the `Button(Signal)` and `Button(Field<string>)`
overloads added to `Tpl` on 2026-08-18 are missing from every generated
`<Rec>Row`. A guest writing `foreach (var row in todos.Rows())` cannot
caption a stamped button from the row; a guest writing `tx.Each(...)`
can. That is the difference the façade clause exists to refuse.

WHY NO GATE SEES IT: tpl-surfaces.py's façade clause compares NAME SETS,
and `Button` is in both sets already — overloads are invisible to it, in
the same way the kind census was invisible to sources. Fixing the
forwards and teaching that clause to compare ARITY-AND-TYPE rather than
names are the same slice; doing the first without the second leaves the
next overload free to drift.

The other two façades need nothing here. Rust's `Row` forwards
`button(impl Into<TplSource<StrKind>>)`, so it took every source the
moment `Tpl` did. Swift's generated `<Rec>Row` forwards five
constructors and no prop setters at all and is already ledgered as its
own slice inside tpl-surfaces.py's FACADES comment; its `t: KayaTpl` is
public, so the zone stays reachable through it.

## ~~DEFECT — Compose's title bar never recomposed, and `expect_title` read the other surface~~ (found by the android film 2026-08-17)
KEY: compose windowTitle plain field, TopAppBar stale title, expect_title reads the render, stamped observation, film found it

CLOSED 2026-08-17, the day it was found, in
android/kaya/src/main/kotlin/dev/kaya/KayaCompose.kt.

WHAT THE FILM SAW. The android film of the editor scene
(docs/chrome/film-android.md §9, still-2.45.png) caught one frame
holding two different titles: the platform ActionBar read "notes" while
the M3 TopAppBar directly under it read "untitled".
`KayaSceneModel.windowTitle` was a PLAIN field where every neighbour a
composable reads is `by mutableStateOf`, and the bar's title slot reads
it — so the bar composed once and never again, while
`mountedActivity?.title` kept moving. Five title assertions stood over
that stale bar and every one of them was green.

WHY NO GATE SAW IT. `expect_title`'s android arm read `activity.title`
and nothing else — a read of a DIFFERENT SURFACE than the user's, which
is what the stamped-observation rule exists to refuse. The task label
was correct the whole time, so the read could only ever agree.

THE FIX, both halves. (1) `windowTitle` joined its siblings:
`var windowTitle by mutableStateOf("")`. (2) The read got honest and now
asserts BOTH materializations — the Activity task label (what recents
and the switcher show) AND the composed bar's own title node, tagged
`kaya:toolbar-title` and read off the merged semantics tree through the
same `kayaToolbarNode`/`kayaAxFind` the toolbar reads use. Both-agree
rather than bar-only because the task label is not decoration: a backend
that stopped writing it would be a real regression a bar-only read would
wave through. macOS needs no such pairing — there the NSWindow title bar
IS the materialization, so its arm already reads what the user sees.

The bar half is asserted IF AND ONLY IF the window declares a command
catalog, which is the exact condition `KayaRoot` composes the bar on,
read from the model and never inferred from a failed node lookup: "this
scene has no bar" and "the chrome broke" are different states, and
collapsing them is how a read goes vacuous. `nav` and `dirty` declare no
catalog and are the legs that prove that branch runs.

WATCHED NEGATIVES, both on emulator-5554, perturb-restore from a saved
copy with `shasum -c` and the substitution count printed. (a) The
`mutableStateOf` reverted — the defect restored — turns three of the
editor leg's five title assertions red, and the sentence is the film's
frame in words: `the chrome's title reads "untitled" while the task
label reads "notes", wanted "notes"`. (b) The bar's title expression
replaced by a constant, model and task label left correct — all five go
red naming what the chrome really drew, so the read cannot be an echo.

The observation string did not move: `title "<want>"`, byte for byte,
and the editor leg's whole verdict is byte-identical to the film's.

## The CLASS behind the stale title bar has no gate (opened 2026-08-17 by the fix above)
KEY: KayaSceneModel plain field, composition state, compose recomposition, one-field audit

A `KayaSceneModel` field that decides what a composable DRAWS must be
`by mutableStateOf`, or the surface it feeds composes once and stops.
Nothing enforces that; `windowTitle` shipped as a plain field for a
milestone and only a film caught it, because a plain field is not a
compile error and the scenes read the other surface.

AUDITED WHEN THE FIX LANDED, so the entry records a state and not a
worry: 16 of KayaSceneModel's 53 fields are state-backed, 13 plain ones
are named inside an `@Composable`, and none of the 13 is a second
instance of the defect. AN AUDIT IS ONLY AS FRESH AS ITS DATE, and this
one decayed within two days of being written: re-measured 2026-08-19 the
object holds 53 fields (16 state-backed, 37 plain), where the audit said
51 — `appIdentityName` and `appIdentityIcon` joined from the identity
fan-out, both written at the apply and read only by the harness
diagnostic `kayaAppIconSamples`, never inside a composable that draws,
so they fall in the "stamped BY the composition for the harness to read"
class and the CONCLUSION below still holds. That decay is itself the
argument for the gate. Four (`alertTitle`, `alertMessage`,
`alertActions`, `alertCancel`) are written on the lines immediately
before `alertId`, which IS state, so the flip carries them into the
composition — safe by ORDERING, which is the fragile kind of safe. Five
are registries (`sectionIndex`, `menuItems`, `contextMenus`,
`menuPopupViews`, `cellMinX`) whose elements hold their own state.
Four (`sectionsRendered`, `formFactor`, `menuPresentation`,
`splitPresentation`) are stamped BY the composition for the harness to
read, not read to draw.

The guard, when scheduled: a gate that reads the object's fields and the
`@Composable` bodies and fails a plain field a composable reads to draw,
with the four ordering-safe alert fields exempted BY NAME and with the
ordering itself asserted rather than assumed. It is deliberately not in
this fix — landing a new gate is a four-way edit (the script, gates.sh's
list, check-gates' census, the CLAUDE.md/AGENTS.md prose) and this slice
was scoped to the defect and its ledger.

## The typeface scene's depth stubs (Slice 2b mid-flight, expected to close with the fan-out)

The depth landed 2026-08-16: spec (`set_brand_typeface` / `set_typeface`,
the `platform` enum) + the SwiftUI mac arm + the Rust binding
(`brand_typeface` / `brand_typeface_with`) + the `typeface` scene, mac
only. ONE arm remains (refreshed 2026-08-31): `kayaDepthStub("typeface",
on: "ios")` in swift/KayaSwiftUI.swift is the last depth stub in the
whole repo — GTK, WinUI and Compose all landed (struck below) and the
linux/windows/android lanes run typeface legs; the stub is what holds
the iOS legs off in check-steps and check-stubs (docs/styling-plan.md
Slice 2b — depth then breadth, the standing pattern):

- **DEPTH STUB: typeface on swiftui/ios** — the APPLY side is already
  live on iOS (the same fresh-descriptor route, plus UIFontMetrics for
  Dynamic Type and the Bold Text weight step the probe measured a
  substituted family dropping). What is not proven is the OBSERVATION:
  `expect_typeface`'s read has been measured on a real macOS window and
  never on a device, so the iOS runner wires no typeface legs. Closing
  it is the same UITextView/UITextField walk run in the simulator, with
  the presence gate's negative watched there too.
- ~~**DEPTH STUB: typeface on gtk**~~ — LANDED 2026-08-16. `:root {
  font-family }` in kaya's own provider at APPLICATION priority (never
  `*`, which would take the monospace slot the editor lives in), the
  resolved-family read through `ctx.load_font(...).describe().family()`,
  and the font-BYTES form through `pango_font_map_add_font_file`. Green
  on BOTH display legs, hand-run, with the fallback negative watched
  going red. TWO findings the probe did not have:
  fontconfig's `FcConfigAppFontAddFile` — the documented app-font route —
  RETURNS SUCCESS AND DOES NOTHING once GTK has initialised, which is
  every position a kaya apply can occupy (measured three ways); and
  `Georgia` is not an unmatched name on that image but an ALIASED one,
  which fontconfig resolves to DejaVu Serif rather than to the default
  sans. The trap the probe DID measure stands and is why the read is the
  only observation: a genuinely unmatched family renders byte-identically
  to the unbranded window.
  The LEG is closed too, 2026-08-16: the blocker was that no INSTALLED
  family resolves to one byte-frozen string on every lane (mac/windows
  resolved `Georgia`, linux `DejaVu Serif`, android `Noto Serif`), and
  the vendored font answers it — the guests ship the OFL Sora bytes
  through the blob channel and every lane resolves `Sora`. So
  `tools/linux/run-suites.sh` now wires seven `typeface` legs on both
  display protocols, styling's roster minus the C floor (which has no
  typeface guest), each through `a11y-leg.sh` for the closing
  `expect_ax`. No `KAYA_FONT_FILE` is set there: the guests' default path
  is repo-relative and the container runs from `/work`, the mount. See
  the styling plan's Slice 2b and
  docs/styling/typeface-gtk-arm.md §"the one blocker".
- ~~**DEPTH STUB: typeface on winui**~~ — LANDED 2026-08-16, green on the
  Windows VM. TWO writes, because the platform has two kinds of text: an
  app-level dictionary redefining `ContentControlThemeFontFamily` (+ the
  KeyTip/Pivot keys, never `SymbolThemeFontFamily`) for the 58 CONTROL
  styles, and a local family on every `TextBlock` AT CONSTRUCTION. The
  second is where the probe's proposal was improved on: a local value
  outranks a Style setter in XAML's precedence whatever order they
  arrive, so setting the family in a `text_block()` factory makes "a ramp
  style applied without the family write" — the `XamlAutoFontFamily`
  literal trap — unrepresentable, instead of pairing the two calls at
  each site. `expect_typeface` cannot read a name on this platform (UIA's
  Text pattern is absent in-process and an out-of-process client is
  barred at Cargo.toml), so it reads XAML's own laid-out WIDTH and
  BASELINE for a pinned string and names the fallback through
  DirectWrite. Findings the probe did not have, all measured on the lane:
  **the VM was never down** — Windows drops ICMP, so the probe's `ping`
  test read a healthy guest as powered off (tools/probe-env.sh:31 already
  said so); **XAML's family lookup disagrees with DirectWrite's** (`Segoe
  UI Variable`, this SDK's `Control.FontFamily` default, is not in the
  system collection and XAML still lays it out as its `Text` sibling), so
  DirectWrite PROPOSES the fallback name and XAML's width confirms it;
  **an unresolved family gets a synthetic 0.9em baseline** while its
  glyphs still come from the fallback face, which is why the fallback is
  confirmed on width alone; and **the blob route is `ms-appx:///`, not a
  path** — an absolute filesystem path, a `file://` URI and
  `AddFontResourceExW` (private AND session-wide, return value 1) all
  render the fallback with no error, while a file under the app root
  works. docs/styling/typeface-winui-arm.md.
  The LEG WIRING this arm was scoped out of touching CLOSED 2026-08-16
  (`31ace6b`): `typeface` is in deploy-win's SCENES, `run_suite
  typeface_rust` runs, and `tools/guest/run_typeface_*.cmd` are checked
  in for five languages. Windows is the second lane (after mac) where
  the scene's byte-frozen family resolves, so no per-platform row is
  needed here.
  Two limits of the blob route are unmeasured because no guest ships font
  bytes: the app directory must be writable (an install under Program
  Files is not), and for a DLL-hosted guest `current_exe` is the host
  interpreter's binary, so the app root is its directory and not kaya's.
- ~~**DEPTH STUB: typeface on compose**~~ — LANDED 2026-08-16. TWO
  writes, as the probe measured: `MaterialTheme(typography = …)` for
  Material's own components and `LocalTextStyle provides
  ambient.copy(fontFamily = …)` for kaya's labels and fields, family
  only, so the ambient size stays Unspecified. `expect_typeface` reads
  the SHAPED glyph run's font file and names it out of that file's
  OpenType `name` table, one sample per route, sites required to agree —
  the two obvious reads on this platform (`layoutInput.style.fontFamily`,
  `Typeface.getSystemFontFamilyName()`) both echo the request. The bytes
  form goes to an app-private file, validated with `Typeface.Builder`
  before Compose sees it (Compose's own `Font(File)` throws INSIDE
  composition for a bad blob), and a family this device lacks leaves the
  platform ramp standing and says so, detected at apply time with a
  two-sentinel probe. Both directions of the two-write trap watched going
  red on the lane; docs/styling/typeface-compose-arm.md.
  THE LEG CLOSED 2026-08-16 (`31ace6b`) THE SAME WAY THE GTK ONE DID —
  by the shared blob, which this bullet already named as the only exit
  that keeps the expected family one byte-frozen string on every lane.
  `tools/android/run-emulator.sh` now wires three `typeface` legs
  (compose, jvm, go), each naming the pushed font copy in
  `KAYA_FONT_FILE`. The blocker it records stands as the reason: `Georgia`
  is absent on the emulator image (and Android's family lookup is
  case-SENSITIVE, so no capitalisation of it hits), the request falls
  back to Roboto and the arm says so. Android's row in a per-platform
  scene would have been `serif` (→ `Noto Serif`, metric-matched to Roboto
  so no line box moves); the blob made a per-platform row unnecessary.
- ~~**The seven other bindings**~~ LANDED 2026-08-16 (31ace6b): all eight
  bindings carry the surface, swept by check-sugar-surface. Was:
  `brand_typeface`/`brand_typeface_with`
  in Python, Go, C#, Java, Swift, OCaml, Haskell, plus the C floor's
  explicit spelling, and the `typeface` scene's guest in each.
  check-steps holds the scene rust-only until they arrive.
- ~~**No font FILE ships in the tree yet**~~ CLOSED 2026-08-16 (31ace6b):
  the vendored OFL Sora ships at guests/assets/fonts/ and every lane runs
  it through the blob channel. Was: so the `typeface` scene
  exercises the NAME form only. The bytes form is implemented and
  reachable (`brand_typeface_with(.., font: Some(bytes))` →
  CTFontManager, in-process scope, family name read back off the
  registered descriptor) but nothing asserts it end to end: there is no
  font asset in the repo and no license decision about adding one.
  Closing it is one bundled open-licensed face plus a second scene (the
  slot is set once per process, so the two forms cannot share a run).

## ~~The toolbar scene's depth stubs (C2 mid-flight, expected to close with the fan-out)~~

CLOSED 2026-08-19, with nothing left inside it. Every bullet below is
struck and LANDED 2026-08-17; no `depth_stub("toolbar")` survives
anywhere in the tree (check-stubs green); `toolbar` runs on all five
lanes (validate-mac's SCENES, deploy-win's SCENES, run-suites' SCENES
with seven legs, run-sim's IOS_SWIFT_SCENES and IOS_GO_SCENES, and
`run_apk toolbar-compose`); the seven other bindings owed nothing and
their guests arrived in `a3ea86d`; and the last clause — the graduation
out of validate-mac's DEPTH_SCENES — was already true two days before
the sentence claiming otherwise was written (`cbf6476`).

As filed: the depth landed 2026-08-17: no spec movement at all — the `primary` bit
kaya already ships grew its first desktop lowering (docs/chrome-plan.md
C2, ratified 2026-08-16) — plus two harness verbs (`expect_toolbar`,
`expect_toolbar_item`), the SwiftUI **macOS** arm, the Rust guest and the
`toolbar` scene, mac only. The other four backends refuse through the
depth-stub helper, which is what holds their lanes' legs off in
check-steps and check-stubs (depth then breadth, CLAUDE.md's sequencing):

- ~~**DEPTH STUB: toolbar on gtk**~~ — LANDED 2026-08-17. The look flip
  went in as ratified: every window's chrome is an `AdwHeaderBar` inside
  an `AdwToolbarView` that IS the window's child, so the flat top bar is
  the platform's own default rather than a style kaya asks for. The
  window stays a plain `gtk4::ApplicationWindow` — the SMALLER migration
  the plan preferred — with an empty invisible titlebar widget left in
  the titlebar slot, which is the client-side-decoration switch (measured
  identical to `AdwApplicationWindow`, whose own `get_titlebar()` is an
  internal gizmo doing the same job, under Xvfb, under sway and with
  `GTK_CSD=1`). Promotion is every primary action in catalog preorder —
  no k, because GTK has no capacity of its own — symbol-first, with the
  accessible name written EXPLICITLY, since an icon-only button publishes
  `name=''` and the `expect_toolbar_item` read addresses buttons by what
  the bus answers. Enablement is free: the button names the item's
  existing `win.kmi-<id>` action.
  THE SYNTHESIZED `GtkMenuButton` WAS DELIBERATELY NOT BUILT, and that is
  the one deviation from the research's shape. Its purpose was a home for
  the unpromoted catalog, and this backend already has exactly one: the
  whole catalog is a `GtkPopoverMenuBar` in the strip above the content
  (`ensure_menu_strip`), so a hamburger over the same `gio::Menu` would
  be a second copy of those rows one line above their own menu bar. The
  `expect_toolbar` read answers `menubar` for the same structural reason
  the macOS arm does, and it READS the real bar rather than asserting it
  (`none` if the bar is ever gone). If kaya's linux menu lowering stops
  being a bar, that is when GTK grows the hamburger.
- ~~**DEPTH STUB: toolbar on winui**~~ — LANDED 2026-08-17. The arm the
  research measured: a `CommandBar` in a second Auto row of the window
  shell Grid, one `AppBarButton` per `primary` catalog action in catalog
  preorder, carrying the very `IconElement` the item's menu row carries
  (`symbol_icon`, so the toolbar needed no icon code of its own). NO
  CAPACITY *k* IS APPLIED, and that is measured rather than chosen: this
  bar has DYNAMIC OVERFLOW ON BY DEFAULT, so how many buttons fit is a
  question the platform re-answers at every width breakpoint, and every
  other default — the 48px transparent bar that takes the window's own
  surface, the 20px→16px icon rescaling, the "…" affordance, the label
  hidden while the bar is closed — arrives with the control. Not one
  styling knob is set, which is C2's whole claim on this platform.
  `SECONDARYCOMMANDS STAYS EMPTY`, the same deviation the GTK arm
  records and for the same structural reason: `rebuild_menus` already
  renders the WHOLE catalog into a real `MenuBar` one row above, so
  filling the overflow would be a second copy of those rows 48px under
  their own menu bar. `toolbar_chrome` therefore answers `menubar`, and
  READS it (the real bar's item count) rather than asserting it. The
  read is the UIA tree the menu reads already traverse: the promoted
  buttons are addressed by the name they publish to an assistive client
  (measured on the VM: an `AppBarButton`'s automation name is its
  `Label` — `AppBarButton` is in the closed dxaml half of the framework
  and this could not be read out of the public sources), the symbol is
  the automation name of the `IconElement` in the button's own slot, and
  enablement is `IsEnabled` on the one button object — which on this
  platform really is the same object whether the bar or the overflow is
  showing it. `refresh_role_enablement` stamps the button as well as the
  menu row, because a role's enablement moves with no catalog traffic.
  Five legs on this lane (rust, python, go, csharp, java), the language
  roster the styling family has.
- ~~**DEPTH STUB: toolbar on compose**~~ — LANDED 2026-08-17. The read
  is the composed bar's own subtree: the `TopAppBar` carries a tag, so
  "in the chrome" is a question about the bar rather than the window;
  the promoted set is matched IN TREE ORDER against the tagged buttons
  that composed; the item count is the bar's affordances (the promoted
  pair plus the ⋮, which is a press target this chrome really holds);
  and the remainder's home is the ⋮ anchor's own tag, measured, which is
  why this backend reports `overflow` and not `more`. Per item, off the
  MERGED semantics node a TalkBack user focuses: the symbol is the
  content description `KayaSymbolIcon`'s `Icon` put there, and
  enablement is `SemanticsProperties.Disabled`, which
  `IconButton(enabled=)` publishes through `Modifier.clickable` — one
  tree-hop from what a service is told, and not the model field beside
  it. THE STATED LIMIT: the ADDRESS is resolved through the catalog,
  because an icon-only bar button on this platform publishes the
  SYMBOL's name as its accessible name and never the item's label, and
  adding the label to that description would turn the menus scene's
  already-green `expect_menu_symbol` on a promoted item red
  (docs/chrome/toolbar-android.md §6). Three legs on the emulator
  pool — compose, jvm, go. The depth-stub helper left with it.
- **The seven other bindings need nothing** — and that is the point of
  the ratified shape: `primary(true)` is a spelling all eight bindings
  have shipped since the menus milestone, so this slice adds no binding
  surface and the 8-way sweep is empty by construction. The `toolbar`
  GUEST each language owed ARRIVED 2026-08-17 (`a3ea86d`): python, go,
  csharp, java, swift, ocaml and haskell all have one. ~~WHAT IS LEFT is
  the graduation itself — `toolbar` is still in validate-mac's
  DEPTH_SCENES rather than SCENES, the way styling moved.~~ — DONE, and
  it was already done when this sentence was committed: `cbf6476`
  (2026-08-17) moved `toolbar` out of DEPTH_SCENES into SCENES in the
  same edit that added it to the other lanes. Verified 2026-08-19:
  tools/validate-mac.sh:37 carries `toolbar` in SCENES and :48 reads
  `DEPTH_SCENES="typeface"`.

## Styling follow-ups the fan-out surfaced (2026-08-12, none blocking)

- **~~Font-FILE bundling waits for the asset pipeline~~ REVERSED
  same day (maintainer, 2026-08-16): font bytes ride the existing wire
  blob channel, IN the typeface slice.** The asset pipeline offers
  fonts nothing the blob channel lacks — its real customers are raster
  density variants and OS packaging (the vector-app-art entry's
  future). Register-then-resolve: the blob registers via the
  platform's app-font API, the family name is extracted, and the
  name-based machinery takes over unchanged. The WinUI registration
  route (path#family vs DWrite in-memory loader) is measured at depth,
  not assumed.

- ~~**Sections carry symbols with no harness assertion**~~ (2026-08-16)
  — LANDED 2026-08-17. `expect_section_symbol "<title>" "<name>"` reads
  the REAL rendered switcher row on every backend and answers in the one
  shared vocabulary: the `AXRadioButton`/`AXSegment`'s published
  identifier on macOS (measured — that tree carries no glyph object at
  all, the toolbar arm's channel one construct over), the tab item's
  rendered glyph inverted through `kayaSymbolTable`'s two-name rows on
  iOS, the merged node's content description on Compose, the `GtkImage`
  the `GtkStackSwitcher` really built on GTK, and the
  `NavigationViewItem`'s icon element's UIA name on WinUI. Two
  assertions in `tools/scenes/sections.steps`, and they sit ABOVE the
  phone cut rather than in the desktop tail this entry proposed, for the
  reason in the bullet below — which means FIVE lanes assert them where
  the tail would have reached three.
  THE ACCEPTANCE TEST WAS THE HISTORICAL DEFECT, re-introduced: `body +
  24` back to `body + 20` in the SwiftUI decode now fails the sections
  leg with `section "Feed" symbol "symbol 85899345928 is not in this
  interpreter's table", wanted "home"`, where the whole matrix once
  stayed green. Report: docs/chrome/sections-symbol.md.

- **`expect_sections_presentation`'s window#N verdict is spelled two
  different ways** (found 2026-08-17 while comparing the sections legs
  across lanes). harness.rs — the implementation the GTK and WinUI
  backends run — appends `"{prefix}sections {arm}"`, so the windows lane
  prints `window#1 sections sidebar`; the Compose interpreter spells it
  the same. The SwiftUI interpreter appends `"sections \(armPrefix)…"`
  (KayaSwiftUI.swift:6513 and the failure sentence at :6516, re-anchored
  2026-08-19; filed at :7060, so grep `armPrefix` rather than the
  number),
  so the mac lane prints `sections window#1 sidebar`. Three
  implementations, two spellings, measured side by side:

      windows  ... window#1 title "library", window#1 sections sidebar)
      mac      ... window#1 title "library", sections window#1 sidebar)

  NOTHING CATCHES IT TODAY because the tail that runs this form is
  desktop-only and each lane only requires its own `KAYA_SELFTEST: OK`;
  the two spellings never meet. It is a two-token swap in the SwiftUI
  arm — deliberately NOT folded into the expect_section_symbol slice,
  which was measuring a regression and had no business changing an
  unrelated verdict string in the same run. Whoever takes it: move the
  prefix in both the observed and the failure line, and re-run
  validate-mac (the string is quoted in reports, so grep before and
  after).

- ~~**GTK's sidebar arm draws no section symbol, so the sidebar rows
  cannot be asserted by a shared scene**~~ — CLOSED 2026-08-17 as a
  RATIFIED PLATFORM DIVERGENCE (maintainer), not as work owed: DESIGN.md's
  Binding conventions now states it under "Stated platform divergences"
  — on Linux a sidebar's section rows are text-only, and the
  section-symbol contract there is carried by the BAR presentation's
  rows, which the shared scene already asserts on five lanes. So nothing
  is waiting on a decision; what would reopen it is the GTK re-lowering
  named at the end of this entry, and the day it lands the scene grows
  two lines and the carve-out paragraph goes away. The measurement that
  the ratification rests on, as filed:
  `GtkStackSidebar` binds only the page's
  TITLE into a GtkLabel and ignores `icon-name` entirely (measured, GTK
  4.18.6 — gtk.rs's `refresh_section_symbols` fact 2), and kaya does not
  hand-build rows inside a component that owns them. The other four
  backends all draw it: the macOS `NavigationSplitView` sidebar was
  measured answering `section "Shelves" symbol "search"` / `section
  "Loans" symbol "lock"` through the same read, and WinUI's `Left` pane
  is the same `NavigationViewItem` as its `Top` one. So the sections
  scene asserts its BAR rows only; adding the two sidebar lines would be
  red on linux forever while green everywhere else, and scenes are
  shared verbatim.
  WHAT WOULD CLOSE IT: moving the GTK sections lowering onto
  `AdwViewStack` + `AdwViewSwitcher` (the component that shows icon AND
  title — the same migration `refresh_section_symbols` fact 1 already
  names for the bar arm's icon-replaces-title behavior), or a
  hand-rolled `GtkListBox` sidebar. Both are a re-lowering, not a line,
  and the second contradicts a stated position in that file. The read
  and the verb are already written for both arms on every other backend,
  so the day this lands the scene grows two lines and nothing else.

- **The window chrome knob is DEFERRED (maintainer, 2026-08-16)** —
  docs/chrome-plan.md C1/C1b, drafted and held before ratification.
  `chrome: extended` (content under a transparent title bar) is the
  one piece of the modern-mac look that is HARD to extend across
  platforms and easy to break apps with: the content's top band slides
  under the traffic lights (every current scene puts real content
  there), the drag region fights the top row's clicks (WinUI requires
  an explicit drag region or the window cannot be moved), and a
  default flip would change every app's geometry overnight. The safe
  cases ALREADY auto-extend: a sidebar window gets the full-height
  treatment from the platform today, and a toolbar-carrying window
  would get the tall unified bar with the toolbar itself. What the
  knob alone buys is extended-without-chrome (the Zed-shaped editor),
  which only the app can promise its top edge tolerates. REOPENS when
  an app actually wants that shape; the cleaner rule to consider then:
  extended is DERIVED (toolbar or sidebar present), and the knob
  exists only for the chrome-less case. The toolbar construct (C2, the
  promotion list over the command catalog) is a separate question and
  ~~stays in the draft awaiting its own ratification~~ — C2 was ratified
  2026-08-16 and LANDED 2026-08-17 (docs/chrome-plan.md's status line
  names the five commits); C1 alone is held. Corrected 2026-08-19.

- **The per-platform accent VALUE map is spelled in no binding, and
  cannot be until the core carries a platform id.** D1's grammar admits
  `{<platform>: Accent}` resolved binding-side at runtime; all eight
  arms skipped it independently and said so in their doc comments
  (uniform absence is uniform). The java arm found the real blocker:
  the only platform signal a JVM binding has is `os.name`, which
  reports `Linux` on Android — an app's android value would silently
  resolve to its linux one — and `kaya_capabilities()` carries one bit
  (aux-windows), no platform id. So this is a SPEC question first: a
  platform id the core answers, then eight resolver spellings, then
  the sugar-surface clause. Until then a brand book with per-platform
  values writes per-platform guests, which is exactly what the map
  exists to prevent.
- ~~**The template zone has no `role`.** A stamped "Delete" button inside
  a For cannot be declared destructive in any language — the reference
  sugar (`Tx`/`Tpl`) carries role on the live zone only, and every
  binding matched it (checked during the fan-out, uniform). If a
  collection scene ever wants per-row destructive actions, the
  reference grows `Tpl` role first and the eight spellings follow —
  two lines each per the java arm's estimate — plus a
  tpl-surfaces/tools clause. Deliberately absent today, not forgotten.~~
  LANDED 2026-08-17, with the inset entry below — one fan-out, because
  the walls and sweeps were the same set twice. The record is there.
- ~~**The template zone has no `inset` either — and the editor's find bar
  is the live case.** The container inset landed 2026-08-12 (the prop
  the full-bleed editor forced: its status row insets while the buffer
  runs to the edge), but the find bar's row is a STAMPED node, and the
  template zone carries exactly one layout prop (grow, which scroll
  forced). So the bar still sits flush while the status row does not —
  visible in the editor captures. Same closure shape as role above:
  the reference grows the `Tpl` spelling first, eight bindings follow,
  and the tpl-surfaces census holds it. Worth doing together with
  template `role` if either is admitted, since the walls, sweeps and
  gates are the same set twice.~~ BOTH LANDED 2026-08-17, together, for
  the reason the second entry gives — the walls and sweeps were the same
  set twice. THE SPEC DID NOT MOVE, and that is the finding worth
  keeping: a template node has always ridden the same `set_property`
  record a live widget does, and `declare()` runs the SAME `check_prop`
  before pushing a prop-GENERIC `TplOp::SetProp`, which `run_body()`
  turns into an ordinary `ApplyOp::SetProp` naming the stamped copy's
  live id. So the four backends needed nothing either: a stamped copy's
  role reaches macOS's real accessibility tree as AXHeading through the
  identical arm a live label's does. The whole slice was eight binding
  spellings, one scene, and the census. Both setters are CONST — what a
  copy MEANS and how far its prototype holds children off its edge are
  facts about the prototype, `accepts`'s rule one prop over.
  The assertion is tools/scenes/a11yrows.steps, which grew a SECOND
  scalar collection (`expect_ax` addresses the real tree by identifier
  and refuses an ambiguous one, so a second readable stamped element
  needs its own strings): two `expect_ax label#N "heading/…"` reads of a
  widget no guest authored, plus `expect_inset row#0 8` on a stamped
  container. Uniform in all eight bindings plus the C floor, whose
  generated `kaya_tx_set_role`/`kaya_tx_set_inset` were already its
  surface. The one deviation is Swift's GENERATED `<Rec>Row` façade,
  which forwards no prop setter at all and is its own entry below.
- **Swift's generated `<Rec>Row` façade is not level with its zone, and
  no gate says so.** Measured 2026-08-17 by the template role/inset
  fan-out, which is when the other two façades gained level-holding
  clauses (Java's `RowSurface`, C#'s generated `<Rec>Row`) and Swift's
  was left out on purpose. What it forwards: constructors, and not one
  prop setter — not `setGrow`, not the a11y trio, not `setAccepts`, and
  so not the two this slice added. It is also missing about twenty
  constructors (`entry`, `textarea`, `slider`, `select`, `radio`,
  `progress`, `spacer`, `scroll`, `grid`, the non-field `label`/`image`
  overloads).
  WHY IT IS A DEFER AND NOT A DO: the zone is not unreachable through it
  the way C#'s is. `KayaTpl` sits on a PUBLIC `t`, and guests already
  reach through it (guests/swift/undo.swift), where C#'s field is
  private and Rust's `tx` is private — those two MUST forward or the
  surface is a dead end. So Swift's gap costs an idiom, not a
  capability, and the two generators' stated doctrines genuinely differ
  (C#'s says the whole zone vocabulary is aimed at the façade; Swift's
  says the handle plus the constructors that consume field tokens).
  Closing it is one slice: seven prop forwards, the missing
  constructors, three regenerated `guests/swift/*+Kaya.swift`, and a
  decision about whether `t` can go private once nothing reaches
  through it — after which tools/tpl-surfaces.py's FACADES gains its
  fourth entry and its exemption note loses one paragraph.
- **The three façades disagree about `context_menu`, and the census had
  to write the disagreement down rather than settle it.** Measured
  2026-08-17 while the level-holding clauses landed. Rust's `Row`
  FORWARDS it deliberately — a row trace legitimately anchors a context
  menu, which the menus scene's item rows do, and the forward was added
  for exactly that. C#'s generated `<Rec>Row` lists `ContextMenu` among
  the plumbing it deliberately omits. Both statements are written at
  their own façade, so the census reads each one's own list (anything
  else would be legislating from a gate), and the result is that a C#
  guest holding a row cannot anchor a per-row context menu the way a
  Rust one can — it must open the For itself. One of the two doctrines
  is wrong and ~~the scene that would decide it (menus, per-row) does not
  exist in C#~~ — CORRECTION 2026-08-19: IT DOES, and it is paying the
  cost. `guests/csharp/MenusScene.cs:100-107` opens the For itself
  exactly as this predicted, where `guests/rust/menus.rs:106-114` does
  the same work through the typed row façade
  (`item.label(Task::title())`, `item.context_menu(row, …)`). So this is
  no longer hypothetical: the C# façade header's own predicted failure
  is happening in the EXAMPLE tier, which invariant 5 reserves for the C
  guests. The guest's field READ was moved off the generator-only
  `KayaRecords.FieldAt<string>(0)` onto the element token 2026-08-19; the
  For is still open there, and it must be, because that is where the
  ContextMenu lives. Small, but it is a semantics difference behind a
  spelling difference, which invariant 1 does not allow to stand once
  someone has seen it. THE DIRECTION IS THE MAINTAINER'S — forward
  `ContextMenu` on the C# façade, or ratify Rust's forward away — and
  until it is taken, no agent should pick one by editing a generator.
- **The brand mask bits deserve generated constants.** The
  `set_brand_accent` record's mask (bit 0 = light override, bit 1 =
  dark) has no spec-emitted name, so SEVEN bindings hand-write `1` and
  `2` at their pack sites — the
  check-file-modes shape one record over: renumber the bits and every
  generated surface holds while the literals drift, and the failure is
  a dark override painting the light appearance with no error
  anywhere. The fan-out measured the bits correct everywhere (each arm
  decoded the core's derived words per bit); a `BRAND_MASK_LIGHT`/
  `BRAND_MASK_DARK` pair in the spec moves the agreement from measured
  to structural. Spec-hash move + regeneration + seven callsite edits.
  TWO CORRECTIONS, re-measured 2026-08-19. (1) It is SEVEN bindings, not
  five: python (`__init__.py:2080`), swift (`KayaApp.swift:2669-2670`),
  csharp (`KayaApp.cs:1919`), go (`app.go:1364,1367`), haskell
  (`KayaApp.hs:915`), ocaml (`kaya_app.ml:1286-1287`) — and JAVA, which
  names them `BRAND_MASK_LIGHT`/`BRAND_MASK_DARK`
  (`KayaApp.java:189-190`) but still hand-writes the numbers and is
  checked against the spec by nothing. Rust is the one that cannot
  drift: `app.rs:1468 brand_accent_with` passes `Option<u32>` and never
  packs a mask. (2) The INTERPRETERS do not decode the accent mask at
  all — they receive the DERIVED eleven-word brand. What they
  hand-decode is bit 0 of the OTHER masks: the typeface record's
  (`KayaSwiftUI.swift:3309 if mask & 1 != 0`, `KayaCompose.kt:1949`) and
  the app-identity record's (`KayaCompose.kt:1897`). Same class of
  defect, two records over, so whatever names these bits should name
  those too.

## ~~The APK's own assets/ is not read (asset packaging, Android)~~
KEY: assets, Android, AssetManager, APK, packaging, KAYA_ASSET_DIR

`asset(name)` resolves through a DIRECTORY on every platform
(crates/kaya/src/assets.rs's `Place::Dir`), and Android is the one
platform whose packaged assets are not files: an entry inside an APK has
no path and is read through the platform's AssetManager. The lane pushes
the root to /data/local/tmp and names it in KAYA_ASSET_DIR, which is
what docs/assets-plan.md's A4 table calls the "staged to the lane today"
column and what A5.1 asks for in those words.

What is NOT built is the packaging reader — a `Place::Apk` arm calling
`AssetManager.open`/`list` through the JNI glue. It was designed and
deliberately not written, for invariant 3's reason rather than for
effort: with the lane taking the directory route, the APK arm would be a
branch no run reaches, and a branch nobody has taken is a guess about a
state nobody has been in. The trigger is the packaging milestone: the
moment a kaya APK ships without a runner beside it to push a directory,
the arm is written and the emulator lane stops pushing.

COMPLETE 2026-08-18, and it was written the way the paragraph above
demanded: WITH A LEG THAT TAKES IT. `Place::Apk` is in
crates/kaya/src/assets.rs, the Context and dev.kaya.KayaAssets are
global refs remembered at BOTH attach paths (the KayaRing one had been
throwing its Activity away, so the JVM and Go tiers would have had no
Context at all), and `assets-compose` and `assets-go` arrive with NO
KAYA_ASSET_DIR — so they resolve out of their own package with nothing
staged beside them, which is the only route a shipped app has.
`assets-jvm` keeps the staged-directory route on the same device, and
THE SAME BYTE-FROZEN CENSUS COMES OUT OF BOTH.

Three things the build had to decide, recorded because they are not
obvious:

  The entries sit under `assets/kaya/` and not at the top of `assets/`.
  An app's AssetManager root listing is not exclusively the app's — the
  framework's own asset directories are visible there on several API
  levels — and every AAR on the classpath merges its `assets/` into the
  same namespace. Either would put a name in the census the app never
  shipped, and the census is frozen in a scene. The prefix is written in
  three files and tools/check-assets.sh's C7 holds them equal.

  Absent and unreadable are ONE answer on this route. An APK entry has
  no `ENOENT`; the platform answers with a stream or an IOException. The
  sentence says "no asset named X" plus the census, and lets the reader
  see which it is, rather than naming a cause it did not measure.

  tools/check-jni.sh does NOT cover this class. Its subject is `external
  fun` declarations, and KayaAssets has none — it is called FROM native
  code by `call_static_method`, which no list holds. What holds the name
  is the leg, every run.

## ~~The identity guests still resolve their own icon path~~
KEY: assets, identity, KAYA_ICON_FILE, one resolver, check-assets EXEMPT

The eight typeface guests collapsed to `asset("fonts/sora-wght.ttf")`;
the eight identity guests did not, and still read `KAYA_ICON_FILE` with
a repo-relative default. They are eight of the entries in
tools/check-assets.sh's EXEMPT table, so the gate names them every run
rather than letting them pass quietly, and that table now refuses an
exemption that is no longer earned.

The reason it was not done in the same slice is a real coupling and not
a scheduling one: tools/check-app-identity.sh's C3 clause REQUIRES that
every file naming `KAYA_ICON_FILE` also spells the declared path out of
guests/assets/identity.toml. A guest rewritten to
`asset("icons/kaya-mark.png")` names neither, so C3 has to learn the new
form in the same move — and C3 is the clause that caught a real drift on
its first run, a deploy staging the mark by glob. Changing an identity
gate's rule while migrating the guests it watches, on the day after the
identity slice landed, is two risks in one commit for no gain.

When it happens: C3 gains an arm that accepts `asset("<the declared
icon's path under the root>")` as naming the declaration, the eight
guests lose their environment read, and the eight EXEMPT entries come
out of check-assets.sh together.

COMPLETE 2026-08-18, and that is exactly what happened — the three
moves in one commit, because the stale-exemption clause makes them
inseparable: an EXEMPT entry for a guest that has stopped resolving
anything is itself a finding, so the table could not be left behind.
C3's new arm derives the asset-relative form from the manifest rather
than spelling it, so there is still one source of truth. C3 also gained
the watched negative it had never had.

The lane side went with it: the five `tools/guest/run_identity_*.cmd`
launchers lost their `KAYA_ICON_FILE` lines the way the typeface ones
did, the emulator legs stopped carrying the extra, and the iOS lane
stopped staging a second copy of the mark into the data container.

## ~~The C floor has no asset guest~~
KEY: assets, C floor, guests/c, longhand, invariant 5

The C guests are the explicit floor and document every primitive
longhand, and none of them calls `kaya_asset_open`. The floor's spelling
is settled and stated in crates/kaya/src/capi.rs's doc comments —
`kaya_asset_open`, then `kaya_blob(kaya_asset_blob(handle))` into
whichever generated packer wants the blob, then `kaya_asset_release` —
but nothing under guests/c/ runs it.

It was not bolted onto an EXISTING C guest because every one of them is
wired to a scene whose assertions a brand typeface would move:
guests/c/styling.c is the closest fit and its scene asserts insets and
shares, which a font swap changes. It belongs with the assets
conformance scene below, which is where a C guest can exercise it
against assertions written for it.

COMPLETE 2026-08-18: guests/c/assets.c, which is where it belonged.
Five of the six entry points are written longhand — open, blob, bytes,
release and the sized-then-read `kaya_asset_why_not` — and the sixth,
`kaya_asset_len`, is named in the header as the sizing-only sibling of
`kaya_asset_bytes` (this guest already holds the pointer, so it reads
the length that came with it). It runs on the two lanes that carry the
floor, mac and linux.

## ~~The assets conformance scene~~
KEY: assets, scene, assets.steps, miss diagnostic, census, expect image

Not built. What the slice DOES prove today: `asset()`'s happy path
through a real surface, on four lanes in five to seven languages each —
the typeface scene's guests now call `asset("fonts/sora-wght.ttf")` and
`expect_typeface "Sora"` reads the family the real text system ended up
with, which is the strongest bytes-reached-the-platform observation kaya
owns. The miss diagnostic's eight answers are each made to print by
`assets::tests::why_not_answers_in_facts` and audited by
tools/check-diagnostics.sh at answers=8, measured=8.

What is NOT proven cross-platform is the miss SENTENCE: that the census
of what the package carries is the same eight names on five platforms.
The scene is designed, and the design is the part worth keeping:

    expect label#0 "assets"
    expect image#0 "64x64"
    expect label#1 "<the miss sentence's first line, census and all>"

`expect image#0` is the observation with teeth and it needs NO new verb,
no interpreter arm and no wire constant: the guest hands the vendored
mark's asset to an Image, the platform's own decoder decodes it, and the
harness reads the decoded size off the real image view — the gallery
scene's shape (tools/scenes/gallery.steps:12) with an asset on the input
side. `expect_typeface` was rejected for this scene precisely because
iOS depth-stubs it, which would have exempted the one lane whose asset
delivery is the real packaging mechanism.

The frozen census is the forcing function: it can only pass if every
lane stages the WHOLE root, which is exactly the property A5.1 asks for
and which nothing else observes at run time. It also means adding an
asset reddens the scene, so tools/check-assets.sh should gain a clause
holding that frozen string equal to the root's listing — one gate red
naming the .steps file, before any lane runs, rather than five red lanes.

Cost, measured against the identity scene's own landing: a .steps file,
a guest per language, and legs on all five runners (check-steps'
`wired()` demands every runner or a depth stub, and a depth stub would
be dishonest here because every backend CAN decode a PNG). That is a
breadth commit, and it did not fit beside a migration that had to leave
every lane green.

COMPLETE 2026-08-18, built to that design, with three changes the
building found:

  IT READS THE MISS THROUGH A PUBLIC QUERY, and that query had to be
  added in all eight bindings — `asset_miss_sentence`, the carrier that
  every binding already held internally, made public and given a
  check-sugar-surface row of its own. The design said "a query rather
  than a catch"; what it did not say is that nothing was queryable yet.

  IT READS THE IMAGE THROUGH `bytes()`, not through the blob handle.
  The blob redemption is already proven cross-platform by the typeface
  scene on four lanes; NOTHING proved the `bytes()` redemption through a
  real surface on any lane. The scene closes that half instead of
  re-proving the other. (The C floor guest is the exception and says so:
  `kaya_tx_set_source` takes exactly the handle `kaya_asset_blob` mints,
  so reading the bytes back out to re-register them would copy a buffer
  the core is already holding.)

  THE SCENE GRAMMAR HAD TO LEARN ABOUT QUOTES. The frozen sentence
  contains a `;`, which is the newline stand-in a transport without
  newlines uses, and all three interpreters split statements on it
  unconditionally — so no expected string could contain a semicolon at
  all, a restriction written down nowhere. `split_statements` in
  crates/kaya/src/harness.rs and `kayaSplitStatements` in
  KayaSwiftUI.swift and KayaCompose.kt are now quote-aware, and THIS
  SCENE IS THE WALL that holds the three equal: it runs the same quoted
  `;` through all three, on five lanes.

The clause the design asked check-assets for is C6, and it earned its
keep before the scene ran: the frozen census must equal the root's
listing, so adding an asset is one gate red naming the .steps file
rather than five red lanes.

## ~~An image widget whose bytes half-decode CRASHES the SwiftUI backend~~ — CLOSED 2026-08-19
KEY: swiftui, KayaCell, Layout, subviews, image, decode failure, gallery

FOUND 2026-08-18 by a watched negative for the assets scene, not by a
lane: perturbing guests/rust/assets.rs to hand the image widget the
VENDORED FONT's 111400 bytes instead of the mark's killed the process
with SIGTRAP before any expectation could be read.

    KayaCell.sizeThatFits(proposal:subviews:cache:)
      <- LayoutSubviews.subscript.getter   (EXC_BREAKPOINT)

REPRODUCED 2026-08-19 with that exact stack, from a scratch guest that
mounts an undecodable image as a DIRECT CHILD OF THE ROOT, and fixed the
same day. What the entry asked for first — why the gallery's 12 bytes
survive — has an answer, and it is not the one the title assumed.

### IT WAS NEVER THE BYTES. IT WAS THE POSITION.

The column and row render arms take the KayaFlex/KayaCell path only when
`isRoot || node.children.contains(where: { $0.grow > 0 })`; everything
else is a stock VStack/HStack, and a nothing-child in a stock stack is
harmless. gallery.rs puts both its images in a growerless nested row. The
same 12 bytes one level up — a direct child of the root — trap. Sweeping
(4 byte shapes x 2 positions) on this backend before the fix:

    flex   junk     KILLED by signal 5      <- the crash
    stack  junk     OK (imageSize 0x0)      <- what the gallery has
    (good/truncated/corrupt read 2x2 in both positions)

So "which undecodable input reaches the placeholder" was the wrong
question: EVERY nil decode reaches it from a stock stack and NONE does
from a flex cell. No scene has the second position, which is why no lane
could have caught this.

### AND THE TITLE'S "HALF-DECODE" NAMES BYTES THAT DO NOT CRASH THIS
### BACKEND AT ALL

Probed directly (NSImage(data:) on macOS 26):

    good      NON-NIL 2x2, cgImage 2x2, tiff 3362 bytes
    truncated NON-NIL 2x2, cgImage 2x2, tiff NIL   (sig + whole IHDR,
                                                    IDAT cut, no IEND)
    corrupt   NON-NIL 2x2, cgImage 2x2, tiff 3362  (IDAT payload
                                                    clobbered)
    junk      NIL                                  (`not an image`)

ImageIO is LENIENT: a half-valid PNG decodes to a real image here and
never reaches the placeholder. The crashing input is a decode that
returns NIL — which the original watched negative's 111400 font bytes
are. WIC on Windows is lenient in exactly the same way (both half-valid
shapes read 2x2 on the VM); gdk-pixbuf is STRICT and reads 0x0 for both.
That divergence is why no scene can freeze an expectation on a half-valid
image, and it is the reason the gallery keeps `not an image`, whose
answer is 0x0 on all four backends. See the wall section below.

### THE FIX, TWO PARTS

1. SEMANTIC (swift/KayaSwiftUI.swift kindImage arm, and its Compose
   twin): a failed decode is PRESENT AND EMPTY — `Color.clear.frame(width:
   0, height: 0)` / `Box(modifier = a11yTag)` — not `EmptyView()` / a
   bare `?.let`. That is what the two WIDGET backends have by
   construction, and the declarative pair had to say it out loud.
2. STRUCTURAL (KayaCell): `subviews.first` with a zero fallback in
   sizeThatFits, `guard let child = subviews.first else { return }` in
   placeSubviews. Kept even though (1) means no image reaches it, because
   "every kind produces one view" is a convention nothing enforces — this
   file's own `default:` arm for an unknown kind produces none.

The decode itself moved into `kayaDecodeImage`, so the negative test
drives the platform's real decoder rather than a copy of the arm.

### THE AUDIT THE ENTRY OWED THE OTHER THREE BACKENDS

Same four byte shapes, same two positions, run for real:

- **GTK** — HONEST, 8/8 cells, in the container under Xvfb. Every
  undecodable shape reads 0x0; no crash, no hang, no diagnostic. Its
  decoder is the STRICT one (truncated and corrupt both refused). Safe by
  construction: `Err(_) => picture.set_paintable(NONE)` keeps the
  GtkPicture, and a widget tree cannot lose a widget by failing to draw
  into it. No fix.
- **WinUI** — HONEST, 8/8 cells, on the VM through the shipped probe.cmd.
  `junk` reads 0x0 in both positions (SELFTEST-OK); the half-valid shapes
  decode to 2x2 (verified by re-running them against a `2x2` expectation,
  SELFTEST-OK). No crash, no hang. Safe for GTK's reason: the Image
  element stays, Source is simply never set. No fix.
- **Compose** — no crash available to it: Row and Column tolerate zero
  children and its ONE custom Layout (the grid) is bounds-safe. But the
  bare `?.let` was a real defect one step down from the crash — the grid
  arm pairs `placeables[i]` with `node.children[i]`, so an undecodable
  image shifted every later cell up a slot and recorded every later
  cell's origin against its neighbour. FIXED with the present-and-empty
  Box. NOT RUN AS A RUNTIME CELL: the APK's scene selector lives in
  guests/rust/milestone2_android.rs, which a concurrent agent owned for
  the whole of this session, so no scratch scene could be added there.
  BitmapFactory's leniency on the two half-valid shapes is therefore
  still unmeasured — the one open thread this entry leaves, and it is a
  question about the DECODER, not about the crash.

### THE WALL

`tools/check-empty-child.sh` (gates.sh, CLAUDE.md rung 2). Clause A is a
RUNTIME negative on macOS: tools/checks/swiftui-empty-child.swift is
compiled into the interpreter's own module and run, driving four byte
shapes through the real `kayaDecodeImage`, `KayaRender` and
`KayaFlex`/`KayaCell` in an NSHostingView. It asserts a nil decode reads
0x0, that the image kind hands its layout EXACTLY ONE subview, and — via
a kind number the interpreter does not know, the one remaining way to
render nothing — that a childless cell measures instead of trapping. Both
fixes were watched failing it INDEPENDENTLY: the image arm reverted gives
`subviews=0` and exit 1, KayaCell reverted gives SIGTRAP at the
unknown-kind case. Clauses B and C are static and run anywhere: all four
backends' image arms are present-and-empty and panic-free, and KayaCell
subscripts nothing it has not checked. Six self-test perturbations, each
printing its substitution count.

THE SCENE DOES NOT GAIN THE ASSERTION, and the decision is the leniency
above. A byte-frozen step CAN express the nil-decode case honestly —
`not an image` reads 0x0 on all four backends, which is what the gallery
already asserts — but expressing it in the CRASHING position means moving
the image out of the growerless row in nine guests, and the guests were
another agent's for this session. A half-valid image cannot be frozen at
all: it reads 2x2 on mac and Windows and 0x0 on Linux. So the unit test
is the wall and the scene stays as it is. The scene-side upgrade —
`tx.image(&BAD[..]).grow(1.0)` in all nine gallery guests, which would
put the crash on every lane's path — is worth doing the next time the
gallery is open for other reasons.

## ~~A Swift guest cannot catch an asset miss~~ — RESOLVED 2026-08-19
KEY: assets, Swift, fatalError, uniform semantics, invariant 1, throws

DIVERGENCE, AND IT IS FIXED. The maintainer ruled that Swift's asset
miss becomes a throw: `init(_ name: String) throws` on `KayaAsset`,
carrying a `KayaAssetMiss` whose `description` and `errorDescription`
are the core's sentence and nothing else. Ruled over a `Result` and over
a failable `init?`, with the reasoning on record: `throws` IS Swift's
Result at the call site, `try?` hands back the optional for free, and
the miss's rich sentence — the census of what the package does carry —
rides the error where an optional would have discarded it. Unhandled it
is still fatal, so the "wall at startup" reading the `fatalError`
carried survives for an app that does not catch; what changed is that
the guest now gets to.

THE CASE FOR IDIOM WAS FALSE ON ITS FACTS, which is worth writing down.
"kaya's Swift surface has no `throws` anywhere" was wrong when it was
written: `KayaPickedFile.open` throws, every handler the binding stores
is a `(KayaAppTx …) throws -> Void`, and `KayaAppTx.build` is `rethrows`
over a throwing body — so `try` was already the shape a Swift guest
writes, and the tx boundary already rolled back on one. Nothing had to
be invented for this ruling; the throw walks a path that was there.

The eight now stand uniform on ONE semantics — the guest may observe a
miss, and the sentence it observes is the core's — in eight spellings:
Rust panics, Python raises RuntimeError, Go panics, C# throws
InvalidOperationException, Java throws IllegalStateException, Swift
throws KayaAssetMiss, OCaml raises Failure, Haskell raises ErrorCall.

WHAT DID NOT CHANGE, AND WHY: `asset_miss_sentence` stays in all eight.
Its stated reason had been Swift, and that reason is spent — but the
assets scene has NINE guests and the C floor catches nothing at all, so
a caught sentence still is not one shape everywhere. It also answers
what no raise can: for a name that RESOLVES it says so, having opened
nothing, which is the second half of what tools/scenes/assets.steps
freezes. The Swift guest now reads the census through the CATCH (which
makes label#1's frozen bytes the wall on the error's payload) and the
resolving-name answer through the query, so both surfaces stay
exercised on mac and iOS.

THE GATE MOVED WITH THE SIGNATURE. check-sugar-surface's Swift asset
pattern was `final class KayaAsset` and would have passed with the
`throws` deleted. It is `init\(_ name: String\) throws` now, because the
CLASS is already held by a compiler (three guests name it) while the
keyword is held by nothing: reverting the initializer to its
pre-ruling `fatalError` shape produces ZERO compiler errors — Swift
answers a `try` with nothing to throw, and a `catch` with nothing to
catch, with a warning, and the guest pass does not compile
-warnings-as-errors. Watched: that perturbation reds the row and passes
the compiler.

~~STILL OPEN, AND IT IS PROSE ONLY: fifteen files argue for the query by
naming SWIFT as the language that cannot catch~~ — SWEPT 2026-08-19 in
`9f8975e` ("the tree sheds a third of its talk"). Re-checked the same
day: a tree-wide search for SWIFT near "cannot catch"/"catches
nothing"/"no way to catch" over the bindings, the core, the guests and
the `.steps` files returns ZERO lines, and every one of those sites now
carries the pointer form instead — "Why a query and not just the raise:
docs/deferred.md, the assets entry" (crates/kaya/src/app.rs:1504,
bindings/go/app.go:1436, and the python/java/csharp/haskell/ocaml twins),
with tools/scenes/assets.steps:20-23 carrying the replacement argument
in the C floor's name rather than Swift's. The file-and-line list this
paragraph used to carry is deliberately not reproduced: it was hundreds
of lines out of date within two days, which is the argument for the
pointer form and not for a better list.

The original entry is kept below for the record.

~~`asset(name)` raises on a miss in every binding, carrying the core's
sentence verbatim. Seven of the eight raise something the guest could
catch — a Python RuntimeError, a Go panic, a JVM IllegalStateException,
an OCaml Failure, a Haskell exception, a C# InvalidOperationException, a
Rust panic. Swift's is `fatalError`, which is the free-function idiom in
bindings/swift/KayaApp.swift and which traps rather than unwinding, so a
Swift guest cannot recover from a missing asset.

Whether that is idiom or divergence is a maintainer question and not an
agent's (the carve-out rule). The case for idiom: kaya's Swift surface
has no `throws` anywhere, and adding one to `asset` alone would make it
the only call in the binding a guest must `try`. The case for
divergence: "the guest may observe the failure" is a semantics, and on
one platform it is not available. Nothing in the tree depends on the
answer today, because no scene catches a miss — which is the assets
conformance scene's job above, and the reason that scene reads the
sentence through a query rather than through a catch.~~


## ~~GAP — six iOS legs the android lane already runs~~ (found 2026-08-19)
KEY: IOS_UNWIRED_SCENES, dirty editor filedialog ranges save undo, run-sim wiring

RESOLVED 2026-08-19, hours after filing, by reading the runner further:
the entry was WRONG. All six scenes already run on the iOS lane — dirty,
save, filedialog, ranges and undo as the rust-swiftui suite's
hand-queued legs (each owning its host plumbing: simdrive watchers,
phone-expressible cuts), editor as a hand-queued Go leg. The mistaken
IOS_UNWIRED_SCENES declaration is deleted; wired() gained the
hand-queued structural form (queue_leg run_swiftui_on <scene>-) so the
truth is machine-checked rather than list-shaped; and what the six
actually lack — SWIFT and GO guest legs, a language-breadth divergence
exactly like the android runner's compose-only trio — is recorded where
that convention lives, in the runner beside its scene lists. The real
work item this entry leaves behind: the two mobile lanes each run five
scenes single-guest, and a breadth fan-out (Swift and Go legs on iOS,
Go legs on android where guests exist) is a milestone of its own, on
the roster whenever the maintainer wants it. (THE iOS HALF LANDED
the same day: undo, ranges, dirty, filedialog and save all run from all
three suites now — plain list entries but dirty, which carries the
documented chrome-close cut; filedialog needed one real fix, the Swift
guest staging in TMPDIR where the picker browses providers, cured with
the clipboard guest's iOS Documents line. Only editor stays single-guest
there, Go by design. THE ANDROID HALF IS A CONVENTION QUESTION, not a
wiring one: its Go suite mirrors the JVM suite entry for entry so the
two stay comparable, and Go legs for dirty/ranges/filedialog/save —
scenes with no Java guest — would make Go wider than the mirror. The
maintainer rules on that trade before anyone wires it.)


## ~~FLAKE — identity-x11 legs exited dirty after an OK verdict~~ (2026-08-19)
KEY: identity-ocaml-x11, identity-csharp-x11, did not exit cleanly, torn KAYA_DIAG, kaya_diag

Two occurrences in one day (ocaml, then csharp — so never one binding's
exit path), each 3s, solo-green on either side. ROOT CAUSE FOUND, AND
FIXED 2026-08-19, via a 300-sample probe of the exact leg stack
running 12-wide UNDER A CONCURRENT MATRIX (0/300 solo and 0/120 with
in-container contention alone — host-wide load is the trigger). The one
dirty sample carried the whole story in its log: the guest exited 0
with verdict OK, and the leg's 1 came from identity-class-leg.py's
route clause — because the guest's `KAYA_DIAG app identity: class ->
"..."` line was TORN, the harness thread's epoch line spliced into its
middle, putting the route name on the wrong line. Rust's stderr is
unbuffered and `eprintln!` writes once per FORMAT FRAGMENT, so under
load another thread lands between fragments. Never an exit-path bug;
the runner note that guessed "finish()/exit-path bug?" was itself the
invariant-3 shape and is reworded in both runners. FIX: `kaya_diag!` in
crates/kaya/src/gtk.rs — the whole line as ONE write — at all 8 diag
sites. The witness's same-line route clause is CORRECT and unchanged:
with atomic lines it reads truth, and its refusal sentence is what
cracked the case.

## ~~Tables — backend and flat-guest breadth landed; residuals below (2026-08-20)~~
KEY: table columns, set_column_headers, sort_requested, header_click, expect_columns, expect_rows, expect_column_edges, column_edges, KayaSynthesizedTable, KayaTableSurface, GtkColumnView, SizeGroup, TABLES thread_local

STRUCK 2026-08-31: every bullet below closed on its own date, and the
tail's "the other six bindings remain open" is FALSE since 2026-08-24
— all eight bindings' template-zone columns/on_sort/keyed
re-declaration are censused (tools/tpl-surfaces.py TABLE_POINTS;
check-sugar-surface's live-zone clauses; docs/tables-plan.md:550
"BREADTH CLOSED 2026-08-24"). Two residuals outlive the strike in
their own homes: the physical-device size-class question is in
docs/traps.md and CLAUDE.md's check-table-tier paragraph; the WinUI
resize hook's reason lives at its site (winui/mod.rs's LayoutUpdated
comment — the entry's "width stamp" detail was stale; idempotency is
`table.stamped == table.rows` plus the dirty flag today).

The plan is docs/tables-plan.md (DESIGN.md's ratified column-props
shape); the wire (TX 45 set_column_headers, APPLY 35, occurrence 19
sort_requested), the core's six walls with watched negatives, the
Rust surface (Tx::columns / rows().columns() / on_sort / Sort), the
three harness verbs in all three implementations, and the SwiftUI
Table lowering are in. The record was renamed set_column_headers
mid-slice: `set_columns` collided with the grid `columns` PROP's
generated per-prop setters in every binding (go builds broke on two
TxSetColumns), and prop-derived names share one namespace with
record-derived names in eight generators — a naming wall worth
remembering. The landing, per backend and surface:

- ~~DEPTH STUB: table on compose~~ (LANDED 2026-08-21: the
  synthesized header over FLOORED-AND-DISTRIBUTED columns — one
  custom Layout takes each column's widest child (header included) as
  its width floor, distributes leftover track width equally, and
  header and cells share the x-positions; the ▲/▼ indicator; taps
  through the new emitSortRequested JNI door; the four verbs are real
  and the phone legs run the shared scene in all three suites. The
  column rule took three cuts in one day, each caught by pixels
  rather than by any observable: equal weights gave Name half a
  1280dp tablet, pure content-hug drew the table in a corner of its
  viewport (Akhil caught it against the mac shots), and
  floors-plus-distribution keeps both properties. The same first cut
  hid headers below 600dp behind an ANDROID_TABLET_ONLY_SCENES
  vocabulary; both died before their first commit when Akhil struck
  the compact degrade — headers render at every width, the observable
  lost its size-class prefix, and the phone legs stopped waiting for
  a panes-style ruling. expect_column_edges holds BOTH halves of the
  geometry rule precisely because its first draft (clusters alone)
  passed the content-hug cut. docs/tables-plan.md decisions 5 and 6
  carry the rulings.)
- ~~DEPTH STUB: table on swiftui/ios~~ (LANDED 2026-08-21: the tier
  switch is KayaTableSurface reading horizontalSizeClass under
  #if !os(macOS) — compact takes KayaSynthesizedTable (decision 5
  revised: the native Table's first-column collapse hides declared
  columns), regular takes the native Table where TableColumnForEach's
  iOS 17.4 floor allows. The four verb arms lost their stubs and
  changed nothing else: every read they make was already
  cross-platform. tools/ios/run-sim.sh wires table in
  IOS_SWIFT_SCENES and IOS_GO_SCENES plus a rust table-swiftui phone
  leg and a table-swiftui-pad leg, the only leg in any lane that runs
  the native Table. THE PAD LEG APPENDS NO EXTRA STEP, unlike the
  menus and listdetail pad legs beside it, and that is decision 5's
  revision showing through: with the size class gone from every table
  observable both tiers present identical bytes, so no assertion
  could name the tier. Which device took which tier was measured
  instead — one tier perturbed at a time, only that device's leg
  reddening; that method note is a docs/traps.md entry, because no
  gate holds the routing.)
- ~~DEPTH STUB: table on gtk~~ (LANDED 2026-08-21: GtkColumnView was
  PROBED and refused — a GtkListItem owns its child, so an
  already-parented stamped widget fails gtk_widget_set_parent's
  parent==NULL assertion, and the factory is driven by the model and
  the recycler rather than by kaya's stamp (docs/traps.md). The
  landing is the synthesized header decision 6 predicted: kaya's own
  header row of flat GtkButtons plus a separator at the head of the
  For's container, one horizontal GtkSizeGroup per column, and
  hexpand on every cell — which the toolkit turns into
  floor-plus-equal-leftover by itself, measured at two widths with
  header and cells sharing an x to the pixel. All four verbs are
  TREE READS: the header's own label text carries the ▲/▼ the
  indicator is read back out of, and column_edges measures
  gtk_widget_compute_bounds against the container's flex track. A
  header click is emit_clicked on a real button, the route press
  already uses. Both halves of expect_column_edges were watched
  failing here — the span sentence "draws 105px of a 498px track"
  with the CLUSTER half staying green through it — plus a third
  negative for the CSS class the header cells share. Seven languages
  x two display protocols on the byte-shared scene.)
- ~~DEPTH STUB: table on winui~~ (LANDED 2026-08-21: the details-view
  lowering — a header Grid of SemiBold Buttons and a 1dip rule as two
  more children of the For's own Grid, the stamped rows shifted down
  two tracks by reindex, which is the only thing that places a
  Column's children. STAR SIZING WAS THE WRONG GUESS and this bullet
  carried it: WinUI's Grid has no SharedSizeGroup — that is WPF only —
  so header and rows cannot share tracks declaratively at all, and
  star-with-MinWidth resolves to EQUAL columns clamped up at content
  rather than to the plan's content-floor-plus-equal-leftover. So each
  column's floor is MEASURED off the real controls and the leftover
  divided here, and both surfaces take the same explicit pixel tracks.
  Two bindgen holes shaped the chrome: FontWeight is a vtable pad and
  Border is not in the filter, so the header cell and the rule are
  parsed with XamlReader (the caption_title_text precedent; the
  cleaner home is three members in tools/winui-bindgen). The four
  verbs read the toolkit: columns_presented takes the header Buttons'
  own Content and recovers the indicator from the ▲/▼ one of them
  carries, row_cells walks Grid.Row/Grid.Column on both levels,
  column_edges clusters TransformToVisual leading edges and compares
  the resolved tracks against the flex track the parent gave the
  container, and header_click invokes the header Button's automation
  peer. Both negatives watched failing on a windows leg — a 30dip
  header skew read "cell edges cluster at [0,30,274,304], wanted 2
  columns", and the distribution switched off read "draws 86dip of a
  508dip track" WITH THE CLUSTERS STILL EXACTLY RIGHT. The trap it
  walked into was already written in the file it was editing: TABLES
  is the third thread_local of XAML handles, its TLS destructor
  released them into the dead apartment, and the first leg printed
  KAYA_SELFTEST: OK and then died 0xC0000409 on the exit code alone —
  now leaked at shutdown beside CORE and APP_ICON_BITMAP, and the
  class is a docs/traps.md entry because it has bitten twice.)
- ~~The seven-language guest fan-out~~ (CLOSED 2026-08-21: all eight
  bindings carry columns/on_sort in their idiom and all eight guests
  pass the byte-shared scene on mac. The fan-out's own generator
  lesson: the occurrence decoders' generic tag fallthrough SKIPPED the
  u32 slot the click family pads, so sort_requested's column was
  silently dropped in every generated parser — now a DERIVED family
  (u32_slot_occurrence_names, keyed on the third field being named
  rather than `reserved`), and the click-shaped C-floor classifier
  tightened to require the pad, so the next such record reaches all
  nine surfaces with zero emitter edits. Go's tplzone parity test also
  caught the missing template-node dispatch sibling — OnSortNode was
  already present before the dynamic-table slice, ready for a stamped
  copy's sort once nested headers landed.)
- Residuals from the 2026-08-21 breadth fan-out, none load-bearing
  today: ~~GTK's column_edges reads header LABELS but cell WIDGETS, an
  asymmetry a future non-label cell would meet first~~ (FIXED
  2026-08-21: one `cell_ink` in crates/kaya/src/gtk.rs unwraps a cell
  that wraps its title in a button, applied to the header line and to
  every body line, so both sides measure the widget that DRAWS.
  Reading the BUTTON on both sides was the other way to be uniform
  and was rejected ON MEASUREMENT: the GTK slice's CSS-class negative
  puts every title 10px inside its column WHILE THE BUTTONS STAY
  EXACTLY ALIGNED, so a button read passes straight through that
  defect. It changes no number today, body cells being labels, which
  is why the evidence is the two GTK-slice negatives re-run — both
  printed their recorded sentences to the pixel — followed by a full
  green lane.); the WinUI
  resize hook is LayoutUpdated (SizeChanged is a vtable pad in the
  generated bindings), made idempotent by a width stamp; ~~the iOS tier
  routing (KayaTableSurface) is held by no gate~~ (GATED 2026-08-21:
  tools/check-table-tier.sh — the routing extracted to the pure
  `kayaTableTier(width:dynamicColumns:)`, a static clause holding
  KayaTableSurface as the only constructor of either tier view, and a
  runtime probe (tools/checks/swiftui-table-tier.swift, the
  pane-ladder shape) driving the whole truth table, self-tested red on
  every run. What remains unheld is only whether a physical device
  reports the size class the simulator did); and ~~a lane
  run from a NESTED WORKTREE has two bring-up hazards the slice
  agents worked around rather than fixed — deploy-win.sh's SSH mux
  ControlPath under $ROOT/target exceeds the 104-byte AF_UNIX limit
  (fix wants a design choice: key a short path under TMPDIR on a hash
  of $ROOT), and third_party/winappsdk is gitignored so a fresh
  worktree has no SDK~~ (BOTH FIXED 2026-08-27. The ControlPath is
  `${KAYA_SSH_MUX_DIR:-$HOME/.ssh/kaya-mux}/m-<16 hex of $ROOT and the
  destination>` — ssh_config(5)'s short-directory-plus-hashed-name
  shape, 52 bytes from a worktree checkout — computed and REFUSED
  ABOVE the check-targets cross-build, since the measured cost of
  failing late was a full one. NOT $TMPDIR, which the design first
  reached for: `nix develop` overwrites it with a per-invocation
  /tmp/nix-shell.XXXXXX it deletes on exit, so no run could reuse
  another's master and the refusal would have had no lever. A % TOKEN
  in the path is refused with its own sentence, because ssh expands
  %r/%h/%C when it BINDS and the shipped expression measured 97
  literal while binding 110 — the length clause alone would have
  passed the very bug it was written for, which is what the watched
  negative found. third_party/winappsdk needs no fix:
  tools/fetch-winappsdk.sh runs clean in a worktree, five packages
  sha256-verified; what actually blocked the SDK's consumer was
  tools/winui-bindgen sharing kaya-bindgen's upward-walk hazard and
  not its cure, so its Cargo.toml now carries the same empty
  [workspace] table.) The kaya-bindgen upward-walk hazard from the
  same runs IS fixed: its Cargo.toml now carries an empty [workspace]
  table.
  KEY: column_edges label asymmetry, LayoutUpdated, ControlPath, winappsdk worktree
  ~~the statement form's missing For handle~~ (CLOSED same day: rows()
  allocates the For id eagerly and the chain reads
  `items.rows(tx).columns(...).on_sort(&msgs, Msg::Sort)` with `.id()`
  for the handler's re-declaration — the guest moved onto it and the
  guest-floor exemption died); and ~~a census clause holding
  `columns`/`on_sort` present in all eight bindings, which no gate
  demands yet~~ (CLOSED 2026-08-21: it is tools/check-sugar-surface.sh's
  table clause, beside the range-verb and capability clauses whose shape
  it copies. A TABLE IS NOT A KIND — a For with a header — so neither
  the constructor sweep nor the window-prop sweep could ever see it,
  while the wire records reach every binding through the generator
  whether or not a guest can spell them. Eight patterns are written out
  per name rather than derived from one casing rule, because python's
  `on_sort` is a KEYWORD on `columns` — its ambient transaction has no
  app-level handler surface — and rust's carries a generic parameter.
  Two built-in fake-name self-tests must fire 8/8 or the gate exits, and
  four watched negatives on copies of the real bindings each named the
  binding that had lost its spelling. This original claim deliberately
  covered the live zone only. The 2026-08-23 dynamic-table depth slice
  extended the census to Rust and Python's nested columns/on_sort and
  keyed re-declaration spellings; ~~the other six bindings remain
  open~~ — all eight closed 2026-08-24 with the dynamic-tables
  breadth, censused in tools/tpl-surfaces.py's TABLE_POINTS.)

## ~~Dynamically created tables — HIGH PRIORITY (maintainer, 2026-08-21)~~
KEY: nested tables, template-zone set_column_headers, per-copy sort, dynamic table instances, forcing app

COMPLETE 2026-08-24: the six-binding breadth closed — Go, C#, Java,
Swift, OCaml and Haskell each spell the template-zone bar, nested
on_sort carrying the copy's key path, and keyed re-declaration, DO on
every point with zero carve-outs; every spelling joined the
tpl-surfaces/check-sugar census in the same change (every language's
watched perturbations run on every invocation; the count grows with
the surface, so the gate's own output is the number) and compiles under a gate that
already runs. Three dispatch loops (C#, Java, Haskell) had silently
dropped keyed sort_requested; each gained its keyed arm. The fan-out
also surfaced and same-day-fixed a core defect: a widget-id/
template-node-id collision misrouted set_column_headers — keys now
resolve in the template space alone and the core refuses the collision
at declaration, both directions watched red first (scene.rs; the
one-id-space follow-up is its own DECISION entry). The full breadth
record lives in docs/tables-plan.md's "BREADTH CLOSED 2026-08-24";
canvas and virtualization remain the forcing app's next milestones,
on the ledger's own entries and the ruled order.

DEPTH SLICE GREEN 2026-08-23: b819423 is the pushed protocol/core
root. Rust and Python now spell nested columns/on_sort plus keyed
re-declaration; the approved `kind@id[key.path]` string-key target
reaches the shared runner, GTK/WinUI stages and both interpreters; and
portfolio.py has deleted its repopulation workaround for one nested
positions collection instance per account. The watched per-copy
divergence scene is green on all three desktop lanes, and its census
walls moved with every spelling. The headline remains open for Go,
C#, Java, Swift, OCaml and Haskell breadth. The depth record is 405
unit tests + 4 runnable docs + 14 compile-fail docs, 42 gates,
validate-mac's 329 legs, and a five-lane matrix ALL PASS: gates 374s,
mac 323s/329, Linux 439s/580, Windows 465s/191, iOS 429s/106 and
Android 252s/112, 467s wall time. The gate-sweep ceiling moved from
390 to 490 against the measured 378/387/391s band created by this
slice's 29 new watched perturbations; its log-retention branch was
watched red before the record run.

The maintainer ranked this high the day the tables fan-out closed, in
plain words: tables whose EXISTENCE is dynamic. A hand-placed table
with fully dynamic rows worked everywhere; before b819423 the core
fenced off, loudly at declaration time, a table created once per data
item: "for every account, a positions table," where three accounts
mean three tables and each copy needs its own working sort arrows.
Nothing half-worked; the shape was simply refused until built.

Why it is a milestone and not a fix: set_column_headers originally
addressed its target by bare widget id — there was no spelling for
"the table inside copy #2." The occurrence half (sort_requested) had
template-id-plus-key-path addressing from day one. b819423 grew the
declaration half's path addressing and regenerated all eight bindings
without changing their existing spellings; the depth slice then made
the four backends' ordinary stamped applies addressable, added the
harness target and pinned per-copy sort state end to end. The open
breadth is the other six languages' template-zone columns/on_sort and
keyed re-declaration spelling, with the census widened alongside each.

THE TRIGGER IS A FORCING APP, and the maintainer picked it the same
day: A PORTFOLIO DASHBOARD — an accounts overview where each account
owns its own sortable positions table (data-driven table instances
dead center), price-history charts that will force the CANVAS widget,
and a transactions view that will force ROW VIRTUALIZATION. Data is
synthetic and deterministic by design, so the scenes stay honest the
way the editor's did. The guest language is RULED (maintainer,
2026-08-21): PYTHON — "worthwhile to invest in one other language
just for diversity's sake," which makes the PACKAGING MILESTONE the
dashboard's prerequisite on the two mobile lanes: CPython 3.13 ships
official iOS and Android support (PEP 730/738) and the
briefcase-style bundling is established upstream, so the work is
kaya's bootstrap (interpreter + binding into the APK and the iOS
bundle), not pioneering. The desktops need nothing — Python runs on
all three today, so the dashboard can start there while packaging
lands. The two formerly open sub-decisions are RULED (maintainer,
2026-08-22): the app's name is
PORTFOLIO — the working name keeps, and every scene, guest and window
title already spells it — and the build order is TABLES ->
VIRTUALIZATION -> CANVAS, both list-shaped features before the
drawing surface.

## Harness copy-target typed keys — deferred grammar decision (found 2026-08-23)
KEY: kind@id[key.path], I64 copy key, numeric-looking string key, typed harness target

The approved untyped copy-target grammar treats every bracket segment
as a string key. That is the only collision-free reading: silently
parsing `3` as I64 would make a copy keyed by the string `"3"`
unaddressable, while stringifying I64 would let two distinct protocol
paths resolve to one widget. Portfolio uses named account keys, so the
dynamic-tables forcing scene loses nothing. An app that needs to target
an I64-keyed copy requires a separately approved typed spelling; dots
and brackets inside string keys need that same escaping decision.
RE-RULED 2026-08-31 (maintainer): DEFERRED ON A TRIGGER — the first
scene or app that keys copies by integer buys the grammar decision
(tag-prefix spelling like `[i64:3]` plus the string-key escaping rule,
decided together). Harness-side only: the three harness
implementations parse the target; guest bindings never see it, and
all eight can already declare I64 keys on the wire.

## ~~GAP — the dynamic portfolio's GTK rows overlap and its macOS tables clip horizontally (found 2026-08-23, by artifact review)~~
KEY: portfolio screenshot overlap, GTK required_grow_pool, accounts.rows align stretch, table viewport containment, cellEdgeRightX

The first post-slice artifact review found two independent pixel bugs
behind a green per-copy scene. GTK showed AAPL colliding with the first
account total: FlexLayout measured three equal-weight cards by summing
their unequal natural requirements (145/100/70px = 315px), then its
flex-basis-zero allocator divided that answer equally. The measure must
instead find the pool whose exact rounded weighted shares satisfy every
child: 435px here, and 7px rather than 6 for the 1/1/2 rounding-dust
case. Both pure cases live in the GTK backend and `check-gtk` runs them;
the old sum was watched returning 315 before the inverse landed.

macOS was one wrapper deeper than the earlier detail-column fix. The
detail filled, but the new accounts For defaulted to start, so each
native table received a 145pt viewport and its cell ink reached 409pt.
The app now requests an 800x600 dashboard and spells
`accounts.rows(grow=1, align="stretch", a11y_id="accounts")`; Python's
ordinary-For surface, trace test, census reader and six independent
watched perturbations moved with those keywords. The scene watched the
old window answer 540x330, the wrapper classify start, and the cells
overflow 409pt/145pt before all three assertions turned green.

RESOLVED 2026-08-23: `expect_column_edges` retains real cell bounds and
rejects content beyond a positioned horizontal viewport on SwiftUI,
GTK, WinUI and Compose (watched diagnostics included 508dip/1dip and
291dp/288dp). The post-fix audit closed its own false greens: current
cell identities and nonzero viewport geometry are required, clustering
does not chain through 2-unit neighbours, and the geometry read repeats
after each header re-declaration and the portfolio tick. A table's
vertical `expect_fills` arm is containment, not exact row fill; the
shared table scene watched Compose's missing measurement and WinUI's
exact rule fail before both adopted that meaning. Exact fill had itself
falsely rejected the corrected short tables at 97/117px on X11 and
105/117px on Wayland. Fresh direct captures were inspected: all four
macOS columns and every row are visible, and GTK's three cards no longer
overlap. The reusable measurements are in docs/traps.md.

FOLLOW-UP VALIDATION 2026-08-24: all 1,318 real scene legs and the gate
sweep passed (mac 320s/329, Linux 474s/580, Windows 533s/191, iOS
493s/106, Android 268s/112, gates 348s; 619s wall). `validate-all`
nevertheless exited 1 on the Linux 470s and Windows 520s duration guards
alone. This supports the resolved visual finding; it is not a replacement
ALL PASS matrix record.

## ~~RESEARCH — macOS native portfolio tables show grey empty-row bands (noticed 2026-08-24)~~
KEY: macOS table filler rows, grey bands, VTI, NSTableView, SwiftUI Table, scrollability, empty viewport

RESOLVED 2026-08-24, same day: the bands are NSTableView's native
alternating empty-row striping inside a viewport taller than its
content — the grown For handed every account table the window's
leftover. Maintainer ruling (option 2 of the researched three): an
ungrown native table hugs header + rows; a grown one stays the
fill-and-scroll viewport. Implemented as the interpreter's
content-height frame, the portfolio guest dropping grow on its nested
tables, and the expect_fills table arm's grow split plus hug clause,
each watched red. The full record is docs/tables-plan.md decision 8
(the 2026-08-24 amendment); docs/handoff-dynamic-tables.md's open
question is closed by it.

The inspected macOS capture shows light-grey blank bands after each
table's authored rows — below VTI, below VXUS and twice below CASH. That
is a pixel observation, not yet a diagnosis. Every authored row and all
four columns are visible, and the geometry assertions are green, but
their contract deliberately permits unused vertical viewport space and
does not say whether native empty space is blank, striped or scrollable.

Research the platform behavior before changing it: use primary Apple
documentation and a focused live AppKit/SwiftUI probe to identify whether
the bands are NSTableView's native filler/alternation, selection material
or kaya placeholders; establish the actual vertical scrolling behavior;
then bring the native-preserve / content-height / suppress-striping options
and their independently-scrollable-table tradeoffs to the maintainer for
a ruling. Do not implement an aesthetic guess. The continuation and exact
code/test locations are in docs/handoff-dynamic-tables.md.

## ~~GAP — a nested SwiftUI container cannot fill its track, so the mac dashboard clips its table (found 2026-08-22, by the first capture)~~
KEY: KayaFlex fillCross, align stretch scene, nested container hugs cross, portfolio table clips, flexStretch textarea-only

Found the day after the dashboard shipped, by pointing a camera at it —
the capture the handoff asked for was the first time anybody SAW the
mac rendering, and every model observable was green while the table
drew a third of itself (tables-plan §8's class, second instance).

Measured, all on the mac leg of the portfolio guest:
- The window is 480pt wide; with `grow=1` declared on the detail
  column, `expect_shares row#0` answers "28,72" — the column's TRACK
  takes the leftover, as the control-in-track ruling says it must.
- The rendered column content stays ~148pt (the widest label),
  leading-aligned inside its 346pt track, and the table renders at
  148pt while its own cell edges reach 257pt — the columns clip AT ANY
  WINDOW SIZE, because a SwiftUI table's natural breadth is NOTHING
  (tables-plan §8) and the hug width is set by the labels beside it.
- Declaring `align="stretch"` on the column changes nothing:
  `expect_aligned column#2` classifies "start" with stretch on the
  wire (the align scene's center mode proves the wire path).
- The mechanism is one line: KayaFlex.sizeThatFits hugs its cross
  axis for every container but the root (`fillCross: isRoot` — the
  comment defends the DEFAULT hug, "a row is as tall as its tallest
  child"). KayaCell proposes the full track and the nested flex
  refuses it. KayaRender already threads a `flexStretch` flag, but
  only the textarea consumes it — the container arms never look.

So on this backend `stretch` is INEXPRESSIBLE for nested containers,
and a grown container's content cannot reach its own track breadth,
while GTK and WinUI impose allocations natively (DESIGN's
control-in-track ruling: "already do this natively"). The same bytes
render differently per backend, and nothing can see it: DESIGN
recorded that end/stretch "have live classification arms ... until a
scene earns them" — no scene ever earned stretch, which is how the
divergence stayed invisible from the align ratification to the first
capture. The app-side declarations (`grow=1, align="stretch"` on the
detail column, guests/python/portfolio.py) are committed as the
CORRECT authoring and currently change nothing on mac.

Needs the maintainer's ruling before code moves, since it is settled
geometry semantics: (a) does a nested container in a stretch cell —
or in any grow track — fill the proposed breadth (wire flexStretch
through to fillCross), or does stretch stay container-local some other
way; (b) does stretch now earn its scene (the gate that keeps four
backends honest about it); (c) is the table's natural breadth still
NOTHING once (a) gives it a track to fill. The dynamic-tables
milestone lands against this same dashboard, so the ruling shapes it.

RESOLVED 2026-08-22, same day, maintainer-ratified on all three: (a)
YES — a container ADOPTS the box its parent hands it. SwiftUI's
KayaFlex fills its cross axis for the root, a stretch cell, or a
cross-oriented grow track (flexStretch wired through at last, plus
the per-axis unspecified fallback that kept natural measurement
honest), and the reader records the stretch frame's box instead of
the hugged content centered inside it, which was the second half of
why stretch classified center. The fan-out found the audit HALF
wrong: Compose had the same defect in its own spelling (Box
propagates no minimum, so content wrapped inside a correctly sized
cell — fixed with boxFill at the column, row and table arms), so the
scene caught two interpreters, not one; GTK and WinUI needed no
lowering change, and WinUI's classifier needed the TextBlock reading
(docs/traps.md, "A stretched WinUI TextBlock arranges text-sized").
(b) YES — align.steps grew the stretch construction (a grown,
stretched nested column beside a hugging label, authored keys
column@root/@centered/@fitcol after Haskell's children-first creation
order proved bare column#0 unstable in a three-column scene;
check-steps' container lint now refuses #0 beside any second
container of the kind, self-tested both directions), portfolio.steps
pins column@detail with the same pair, every classifier answers
spanning geometry "stretch" FIRST (degenerate against the positional
predicates; GTK alone keeps baseline before stretch — BASELINE_FILL
children span too, and the allocated baseline is the discriminator
stretch cannot fake), and expect_fills on a container checks its OWN
box against the track its weight earned, with no verdict ever built
from unrecorded zeros. Every new assertion was watched failing
against the pre-ruling interpreter before it was touched. (c) NO
CHANGE — a table's natural breadth stays NOTHING; the declared
grow+stretch now reaches it. Proven the whole way up the ladder:
42/42 gates, check-gtk, validate-mac ALL PASS, and the five-lane
matrix green on every geometry leg (the one red in the closing run
is save-swiftui, the WATCHED iOS dialog flake, its entry carrying
the sighting). The two divergences the ruling deliberately left open
are the next entry.

## ~~Two breadth asymmetries the stretch ruling left open~~ (recorded 2026-08-22)
KEY: grown leaf control breadth, WinUI crossing carve-out, nested container spans every mode, bezel spans track

Found during the ruling's cross-framework survey and its fan-out; both
are real cross-backend divergences, both currently invisible to every
scene, neither blocks anything. Recorded so the next geometry slice
starts from them instead of rediscovering them.

1. A grown LEAF CONTROL's breadth. GTK stamps Align::Fill on any
   grower and WinUI's un-stamped main axis is Stretch, so a button
   with grow=1 draws its BEZEL across the whole track there — while
   SwiftUI's KayaCell places the natural-width control at the track's
   start, and Compose's boxFill (added with the ruling) spans the
   cell, whose content control still measures natural. Same class as
   the container gap the ruling closed, one tier down. No scene grows
   a bare control today, so nothing observes it; the stretch scene's
   construction deliberately used containers and labels. If a scene
   ever grows a control directly, decide then whether the box or the
   bezel is the child.

2. WinUI's crossing carve-out (winui/mod.rs, the BREADTH rule): a
   nested cross-oriented container spans its parent's breadth under
   EVERY align mode there, because the first start-stamped run broke
   a grow row that hugged its own natural width (31/69). The other
   three backends span it only under stretch or a crossing grow
   track. The divergence is masked by classification degeneracy — a
   spanning child still satisfies center/start/end — and becomes
   VISIBLE only in a container whose children are ALL cross-oriented
   containers under a non-stretch mode: WinUI would classify it
   "stretch", the rest the declared mode. No scene has that shape.
   Narrowing the carve-out to grown children would make WinUI match
   the ruling exactly; do it beside a scene that can see it, not
   before.

RESOLVED 2026-08-22, the same day, by the ruling's SECOND SLICE — the
maintainer refused the parking lot ("is there a reason why you're
gonna be ledgering another divergent thing between them?") and ratified
the unified sentence: A GROWER RENDERS AT ITS TRACK, LEAF OR
CONTAINER; A NESTED CONTAINER MAXIMIZES ITS OWN MAIN AXIS; ALIGN
PLACES CHILDREN AND NEVER SIZES THEM. Item 1 closed by the leaf half:
SwiftUI told per kind (the cell's main-axis frame; KayaMacButton
fillsWidth so the AppKit bezel spans, photographed before and after),
Compose threads boxFill onto every kind's own modifier, GTK's
Align::Fill and WinUI's Stretch already did it — held by grow.steps'
expect_fills label#1 / button#0, watched failing on SwiftUI (23pt of
109, 66 of 327) and on windows (23 of 124, 57 of 372 — the second red
convicting BOTH a lying reader and an unstamped main axis) before the
fixes. Item 2 closed by RATIFICATION rather than narrowing: the
carve-out IS the rule, every backend spans a crossing container under
every align mode, and expect_fills' container arm gained the BREADTH
clause ("spans <n> of its parent's <m> breadth") that says so out
loud. The divergence was NOT invisible on GTK after all — the clause
alone, run against the un-fixed lowering on the real linux container,
caught THREE live legs green before it existed: grow row#0 at 108 of
498px, grid row#0 at 147 of 498px with its spacer pushing nothing, and
portfolio column@detail at 145 of 242px. The 31/69 class is dead by
construction on all four. WinUI's clause is trivially green, which is
the point: it is the gate that keeps it so. Two findings the slice
surfaced have their own entries below (the GTK spacing no-op; Compose's
kayaHugCross pin).

## ~~GAP — a GTK flex container's gap is always 8, and no assertion can see it~~ (found 2026-08-22, FIXED 2026-08-22)
KEY: ensure_flex spacing, FlexLayout::new, gtk_box_layout_set_spacing, Prop::Spacing GtkBox, container_fills max_end min_start, grow.steps spacing conformance

ensure_flex hard-codes `FlexLayout::new(orientation, 8)` and never
reads the box's spacing; flex::measure/allocate read only their own
field; and the Prop::Spacing arm's `GtkBox::set_spacing` hits a
GTK_IS_BOX_LAYOUT assertion once the manager is ours (two Gtk-CRITICAL
lines on every grow leg, visible only when the leg fails). So
`.spacing(12.0)` is a no-op on GTK. grow.steps calls this "the spacing
prop's conformance exercise" and says expect_fills gates it — but
GTK's container_fills spans min_start..max_end from real allocations,
which is gap-agnostic, so the backend is green on the scene written to
fail it. SwiftUI's arm sums tracks plus declared spacing and would
catch it. The fix is two lines in the lowering plus a decision about
whether GTK's observation should sum-and-compare the way SwiftUI's
does. Found by the breadth slice's GTK agent 2026-08-22, mid-proof;
deliberately not fixed in that slice, which was holding a
watch-red/watch-green order it would have broken.

FIXED 2026-08-22, both halves, crates/kaya/src/gtk.rs.
THE OBSERVATION FIRST, and it was watched red on its own: container_fills'
children clause now sums the visible children's main-axis extents and adds
the DECLARED gap * (n-1) — SwiftUI's and Compose's shape — where it used
to span min_start..max_end. That span IS sum(extents) + whatever gap the
layout actually used, so the declared value cancelled and no value of the
prop could make it fail. With that change ALONE, grow's row#0 (which
declares spacing(12.0) over two children, so one gap) read
`row#0 leaves leftover (children span 502px of 498px)` on x11 and
`512px of 508px` on wayland — the 4px miss tools/scenes/grow.steps
predicts in writing — in all seven languages the linux lane runs, both
protocols. grid, align and portfolio stayed green: none of them declares
a non-default gap, so the arithmetic did not simply start failing.
THEN THE LOWERING. A SPACING_KEY object-data value records what kaya was
told (ALIGN_KEY's shape), defaulting to CONTAINER_SPACING = 8 — the value
every Column/Row is created with and the literal ensure_flex used to
hard-code, so no box kaya composes for itself moved. ensure_flex installs
FlexLayout with THAT; FlexLayout gained a set_spacing; and the
Prop::Spacing arm routes by which manager is installed, GtkBox's setter
now reserved for the box's own layout, which is what kills the
GTK_IS_BOX_LAYOUT assertion.
BOTH ARMS ARE LOAD-BEARING, and the bindings decide which: python, csharp
and ocaml emit a container's Spacing prop BEFORE its children's weights
(so ensure_flex must read it), rust, go, haskell and java emit it AFTER
(so the live update must take it). Perturbing one arm reddens exactly one
of those two groups and leaves the other green; the two groups partition
the seven languages with no overlap, and their union is the fourteen legs
that reverting the whole lowering reddens.
44 legs green after: grow, grid and align in seven languages, portfolio
in python, x11 and wayland.
CORRECTION to this entry as first written: the two Gtk-CRITICAL lines
were never on EVERY grow leg — only on the four languages that emit the
prop after the weights. They are gone from a green leg now, measured
against a positive control (the same one-leg probe run directly in the
lane's container reads 2 lines with the lowering reverted, 0 with it in).
STILL OPEN, one backend over: WinUI's own fills clause adds back
`grid.RowSpacing()`, the toolkit property its lowering writes, so it
mirrors rather than compares and could not catch a dropped spacing write
either (crates/kaya/src/winui/mod.rs:14641-14673). Nothing is broken
there today — that lowering does write it — but the guard is not a guard.

AND THE SIBLING ONE BACKEND OVER, same day: WinUI's container_fills
summed with grid.RowSpacing()/ColumnSpacing() — the toolkit property
its own lowering writes — so it MIRRORED rather than compared and
could not have caught a dropped spacing write either. It now sums
with the DECLARED value (core.spacings, default 8, stored beside the
write; the id recovered by COM identity), and the fix was watched
both ways on the VM: the Row arm's SetColumnSpacing dropped (1
substitution, build proven fresh by its Compiling line — the mtime
trap two paragraphs down) read `row#0 leaves leftover (children span
512dip of 508dip)`, the restore (sha-verified) went green. GTK's
declared-vs-rendered discipline now holds on both allocation-imposing
backends; SwiftUI and Compose already summed with the declaration.

## Compose pins a hugging container to its content before it fills (recorded 2026-08-22)
KEY: kayaHugCross, IntrinsicSize, crossing container breadth, unpinned parent, fillMaxWidth constraint

Compose's fillMax*() resolve against the CONSTRAINT a parent handed
down; GTK, WinUI and SwiftUI all fill the size the parent ENDED UP at.
Where a container's own cross axis is unpinned the two differ by
everything the grandparent had left, so KayaCompose.kt's kayaHugCross()
gives such a container width(IntrinsicSize.Max) / height(IntrinsicSize
.Min) before the crossing fill lands on it. Two scenes reach it today
(align.steps' row#1, portfolio's accounts For) and neither can tell the
guard from its absence — the failure it prevents is align.steps'
expect_fills column@fitcol reading "children span 138px of 900px",
which IS observable, but only as a red. NOT a per-node cost: the
intrinsic pass runs only for an unpinned container that actually holds
a crossing child. It would throw on a SubcomposeLayout-based kind
(LazyColumn, BoxWithConstraints); the file has none today.

## WATCH — save-jvm once died to AccessDeniedException on /sdcard/Documents (2026-08-19)
KEY: save-jvm AccessDenied, sdcard Documents, storage state, straggler
back, appResumed, KAYA_DIALOG_SEEN, KAYA_DIALOG_UNSEEN, windowCensus,
dialogReport, wait for adding window timeout, OnPreDrawListener,
first-draw admission, android lane barrier, four-phone Android pool,
greedy makespan, nice -n 10, a11y_hygiene

AMENDED 2026-08-31, three facts newer than the body below. (1) A 14th
sighting, 2026-08-30 02:27 under a matrix: save-jvm FAIL at 27s,
preserved in target/validate-failures/android-save-jvm-* — and it is
a DIFFERENT defect from both the AccessDenied headline and the
lost-result ghost: `KAYA_DIALOG_UNSEEN ms=6472` then `KAYA_DIALOG_SEEN
ms=6983` is DocumentsUI's COLD start against a 5s frame-sized
deadline (dialogs 2 and 3 in the same leg: 1375ms, 285ms). Its wall
shipped the same day: `DIALOG_LAUNCH_BUDGET_NS = 20s` in
KayaCompose.kt, used in both dialog arms, held by
check-harness-ceiling.sh (extension precedes kayaNoteDialogUnseen,
budget may not shrink below 10s), measurement in docs/traps.md. (2)
The ghost proper (lost result / straggler back) is quiet since the
13th sighting 2026-08-27 — 21 android dialog-family leg samples on
2026-08-30, all PASS at 8-37s. (3) The DURATION-ANOMALY HALF IS
CLOSED: three all-at-t0 five-lane matrices on 2026-08-30 put the
android lane at 283s/191s/227s against its 310s ceiling, every leg
green — the "stays open until a real all-five-at-t0 matrix pass"
condition is met, three times over. What keeps the entry open is the
WATCH on the ghost family alone.

One pool device, one matrix run, 4s-green solo on either side. The
validation apps hold NO storage permission BY MEASUREMENT
(tools/android/pickerprobe's manifest carries the finding: the
permissionless shared-collection write was measured succeeding, and a
probe with a wider manifest measures a different app) — so a transient
denial is one emulator's storage state, not a missing grant. If it
repeats, dumpsys the mount and appops state of the DEVICE the leg drew,
not the guest.

Second sighting 2026-08-20, different symptom, same family: on a pool
~12 runs old, save-jvm's dialog answered with a NULL picked file and
the Java guest NPE'd in readBack; a pool cold boot and the next matrix
ran ALL PASS (the docs/traps.md pool-degradation rule, applied).

FOURTH SIGHTING the same day KILLED the pool-degradation story: it
fired one matrix after a cold boot, always save-jvm, always under the
heaviest five-lane contention (the concurrent-matrix shape raised
it) — a real race in which DocumentsUI answers a dialog with
nothing, not a tired emulator. What made every sighting cost an
investigation was the GUESTS: seven of the eight save guests crashed
on the never-filled handle (a raw NPE in Java; DELIBERATE
crash-guards everywhere else — .expect, Option.get, fatalError,
error, panic, throw — resting on "the scene opens a file before
saving", which a swallowed dialog falsifies), and the crash took the
process, ate the 62s timeout, and masked the step that actually
failed. ALL EIGHT now write a sentence instead ("nothing open to
save" / "nothing to reopen"), so a recurrence fails CLEANLY at the
"opened first draft" expect with the dialog trace visible — which is
what the next investigation reads first. The dialog-answers-nothing
race itself is still open, NARROWED BY ONE FALSIFICATION: forcing
activity recreation (always_finish_activities on all four pool
devices, the full lane run under it) passed every save leg — kaya's
result plumbing survives recreation, so that classic is NOT the
cause. What the clean failures show: the second save dialog was live,
renamed, verified, its SAVE pressed and the panel gone — and the
guest's label still read the FIRST cycle's "save cancelled", which
smells like a result that never arrived rather than a fresh cancel.
The next sighting decides it: the runner's on-FAIL dump now keeps the
harness trace (it used to keep only crash-shaped lines, which after
the guest guards is nothing — "Bad arguments" and a one-line verdict
was the whole evidence four times).

FIFTH SIGHTING 2026-08-20, the first with the trace, and it narrowed
hard: the THIRD dialog (cancel cycle, then save-as again) was live,
renamed to "final", verified showing "final", file_save pressed and
returned — and the label stayed on the cancel cycle's "save
cancelled" through 5s of retries. Then the REOPEN button was clicked
and PROCESSED (the guest wrote its "nothing to reopen" guard
sentence), so the activity was alive and handling input the whole
time; only the save result went missing. That leaves exactly two
stories the label cannot split: DocumentsUI answered RESULT_CANCELED
(the guest's cancel arm rewrites the very string already showing), or
the delivery was lost outright. KayaCompose's two result callbacks
now log KAYA_SAVE_RESULT / KAYA_PICK_RESULT with the resultCode on
arrival — in the next sighting's dump, a line with code=0 convicts
DocumentsUI, no line convicts the delivery path.

A CORRECTION BEFORE THE SIXTH SIGHTING'S RECORD, because two pieces
of earlier reasoning turned out unsound. First: "the reopen click was
processed, so the dialog must have been gone" proves nothing — the
harness clicks by ACTION_CLICK on the app's own node, which is
dispatched directly to the view and lands fine THROUGH a covering
window. Second: "am_freeze 10s after the press proves the dialog
finished" also proves nothing — the freezer's debounce means that
process went cached minutes earlier, possibly behind a previous
leg's dialog. What DOES still separate the save sightings from a
swallowed press: file_save's own postcondition (press lands, panel
polled gone, 6s) PASSED in every one — no "panel is still up"
failure in any verdict — so the save panels really closed.

SIXTH AND SEVENTH SIGHTINGS THE SAME DAY (the ghost now fires most
contended matrices — today's speed work raised peak contention, and
peak contention raises it), and the seventh carried both instruments:
KAYA_ACTIVITY_RESULT (an onActivityResult override in milestone2kt's
shell, logging every result the ACTIVITY receives) beside the
registry callbacks. Dialogs 1 and 2 logged both lines 1ms apart;
dialog 3 logged NEITHER. kaya's registry, callbacks and threading are
EXONERATED — the result never reaches the app process. And even a
no-setResult finish or a normal DocumentsUI death hands the caller
RESULT_CANCELED, so a silently-absent record is abnormal one level
up. The events buffer (read ~30min later; the main buffer had
rotated) showed a ROUTINE tail: DocumentsUI cached-frozen
(am_freeze) 10.4s after the press — its dialog activity finished
normally, went cached, froze on the standard timer — so the loss sits
between DocumentsUI's finish and ActivityManager's delivery to a
RESUMED, input-processing caller. The runner's on-FAIL dump now also
keeps the documentsui/am_ slice from events+main AT FAIL TIME (the
window rotates out of main in about a minute). If that slice shows a
clean setResult+finish, this is an AMS-side race the harness may need
to tolerate — a remedy that needs Akhil's ruling, since retrying a
save leg would launder exactly the class of bug kaya's own users
would hit.

A THIRD FACE OF THE SAME ROOT CAUSE (2026-08-21, filedialog-jvm
under the fan-out matrix): the choose click landed, waitForPickerGone
said gone, the result never came — and the at-fail dumpsys showed
PickActivity STILL TOP-RESUMED: the a11y window list had transiently
DROPPED a live window mid-relayout, the one absent read declared it
gone, and the next open died on the one-per-process wall. The window
list lags in BOTH directions, so every gone/present decision is now
DEBOUNCED: waitForPickerGone and dismiss() both demand two
consecutive absences before believing one.

FIRST WINDOWS SIGHTING (2026-08-26, filedialog_rust, five-lane
contended matrix): the choose press swallowed with the native dialog
still up listing both files — the instrumented sentence ("the press
was swallowed, which a backend cannot tell you because nothing
returns an error for it") fired as designed, the downstream expects
and the one-per-process wall followed the known script, and the lane
passed standalone on the immediate rerun. One sighting, logged not
chased; the family now has faces on android, iOS and windows, all
under peak contention.

AND AGAIN ON ANDROID (2026-08-26, save-compose, the canvas-depth
matrix at 627s contended): the known sentences, the at-fail dumps
kept as designed (android-save-compose-* in validate-failures), the
lane green standalone minutes later. Logged, not chased.

AND ON iOS THE NEXT NIGHT (2026-08-27, editor-go, the sanitizer-
wiring matrix at 631s): the picker listed a pid-stamped leftover
("kaya-editor-70208") where the scene's fixture should stand —
simdrive counted 34 clean reads and 0 taps, the row genuinely
absent — cascading into the focus steps; lane green standalone at
50s. The stale-provider-index shape check-steps' iOS admission
clause guards, one directory over. Logged, not chased.

AND TWICE ON WINDOWS THE SAME NIGHT, a different leg each time
(2026-08-26: filedialog_rust's swallowed press at 477s contended,
then ranges_rust reading "0 matches" where 3 stood at 516s
contended — an input never delivered, the same family in a search
field's costume): each lane green standalone minutes later. Logged,
not chased; the family's windows face now has two sightings.

AND A FIRST MAC FACE (2026-08-27, portfolio-python-swiftui, a 817s
cold-rebuild contended matrix): the leg failed one step after a
`back` with

    entries 0, wanted 1

— the navigation stack read as empty where the scene had just
popped to a surface holding one entry. Passed standalone minutes
later, unchanged. Same signature as the rest of the family: a
contended matrix only, an observation taken while the platform had
not yet settled the state the previous step commanded, and green
the moment the machine is quiet. Logged, not chased; the family now
has faces on android, iOS, windows and macOS. If this one recurs,
the thing to instrument is the gap between the back command being
issued and the interpreter's navigation model reflecting it —
`expect_entries` reads that model, and the mac harness has no
debounce of the kind the android window-list reads needed.

THE HUNT'S FIRST CATCH WAS A DIFFERENT GHOST WEARING THE SAME MASK
(2026-08-20, filedialog-jvm, full buffers + an at-fail dumpsys in
hand): the OPEN picker was up with its list unreadable (DocumentsUI's
own debug log showed its provider cache lock contended for its whole
life), the one-shot choose() missed instantly, the failure string sat
unprinted in the scene's list, the scene marched through two more
failed expects into a SECOND file_dialog open, and the core's
one-per-process guard — working exactly as designed — aborted the
process, destroying the failure list. The at-fail activities snapshot
showed PickActivity still top-resumed with resultTo intact: nothing
was ever lost in the framework here; nothing was ever produced.
Fixed in KayaCompose: kayaFileDialogDrive retries choose in six
rounds (simdrive's shape, re-walking the tree each time), and EVERY
failure path of file_choose and file_save now dismisses the picker
before recording its sentence, so the guard can never again eat the
evidence. THE EIGHTH SIGHTING, SAME DAY, WITH EVERYTHING ARMED — AND THE GHOST
IS CAUGHT. save-go, full buffers, WM_DEBUG_STATES live, and the
wm_finish_activity/state log spells the whole chain in four
timestamps: 39.393 the CANCEL cycle's back lands and PickActivity
finishes; 39.533 the app's MainActivity resumes and takes input
focus; 39.949 — one dismiss-loop iteration later — a STRAGGLER BACK
lands on the resumed app and finish()es it, "reason=app-request,
result=0", the launcher resuming behind it; 40.7 the THIRD dialog
(launched from the now-finishing activity, whose process and view
tree live on) finishes WITH its result, which has no live
destination and is dropped with no line anywhere. Every stale label
downstream follows. THE GHOST WAS KAYA'S OWN HARNESS: dismiss()
pressed back in a check-then-press loop whose gone-check reads the
a11y window list, and that list LAGS a dismissal — under a loaded
matrix the lag outgrew the 400ms settle, the stale entry bought one
extra press, and the back went to the app. Solo runs never fired
because the lag never outgrew the settle. The suspected framework
race (Android 14+'s async result post; researched with AOSP line
numbers, preserved at docs/probes/lost-activity-result-android.md)
was NOT the cause here — wm_finish_activity for the app at
"app-request" is the line that separates them, and any future
sighting bearing the framework fingerprint instead (PickActivity
finish present, app finish ABSENT, wm_on_activity_result_called
absent) reopens that file.

THE FIXES, all three on the one mechanism: dismiss() now presses
back only while the picker window HOLDS INPUT FOCUS — focus moves to
the app before the stale span begins, so a focused picker is the one
moment a back cannot miss (KayaHarnessAccessibility.kt, the comment
carries the story); both dialog-present paths refuse a FINISHING
activity honestly, answering cancelled with a KAYA_DIALOG_DOOMED log
line naming the cause, because a result for such a dialog is
undeliverable by OS contract — the wall for the whole
straggler-class, at the choke point nobody can avoid; and the
instruments (KAYA_SAVE_RESULT / KAYA_PICK_RESULT /
KAYA_ACTIVITY_RESULT, the big buffers, the full-buffer on-FAIL
capture) STAY, since they are what turned four one-line sightings
into this paragraph. UNVALIDATED until matrices run clean with the
focus-guarded dismiss; strike this entry's headline only after the
ghost stays quiet through enough contended matrices to clear the old
1-in-3 rate — and the first two sightings (an AccessDeniedException,
a delivered-NULL NPE) are cousins at best, so a recurrence of THOSE
shapes is not this ghost returning.

RELATED SIGHTING 2026-08-21, matrix4: save-COMPOSE (not jvm) failed
with "no save dialog live; DocumentsUI is showing []" — the dialog
never presented at all, a different face from the AccessDenied one but
the same scene under the same kind of load (three lane duration
ceilings tripped the same run; the host was visibly busy). Solo and in
the next matrix the leg passes. If this face recurs, instrument
DocumentsUI presentation latency before blaming the scene.
THIRD FACE THE SAME EVENING, matrix6: save-JVM, "the picker is
showing null" — never presented again — and then the scene's NEXT
dialog request met the one-per-process guard, whose sentence ("file
dialog 1 is already live") rode the new step-failed line into the
verdict list intact: the abort-shape fix's evidence surviving its
first real flake. Three faces in one evening, all under matrix
contention, none solo — and matrix7 added a FOURTH the same night
(filedialog-go, the process dying mid-picker with an input-manager
disposal warning; full buffers kept at
target/validate-failures/android-filedialog-go-buffers.log). The
threshold is crossed: DIALOG PRESENTATION LATENCY INSTRUMENTATION is
the named next investigation, before any more matrix reruns are spent
on this family.

THE THREE FACES ARE READ (2026-08-22, from the preserved buffers), and
two of them convict the harness again. matrix7's filedialog-go and
matrix4's save-compose are the eighth sighting's STRAGGLER BACK with
the whole chain in the log: the cancel was delivered cleanly
(KAYA_PICK_RESULT dialog=2 code=0 at 19:16:54.774, KAYA_SAVE_RESULT
dialog=2 code=0 at 17:19:15.619), the app resumed milliseconds later,
and a back injected into the NO-FOCUS GAP between the picker's window
leaving and the app's arriving was QUEUED by InputDispatcher
("Waiting because no window has focus ... Will wait for 5000ms") and
delivered the moment the app's window became focusable, finishing it
at 19:16:55.027 and 17:19:16.514. save-compose's verdict "no save
dialog live; DocumentsUI is showing []" is DOWNSTREAM of that: dialog
3 met KAYA_DIALOG_DOOMED, so nothing was ever requested of the OS and
the census five seconds later was about a dialog that never was. The
focus guard could not see any of it — it reads isFocused off the same
lagging window list, whose stale span was 1.65s in matrix4 against a
400ms settle.

THE GATE IS THE APP'S OWN LIFECYCLE, which lags nothing: a dialog
activity on top means kaya's activity is PAUSED, and it is resumed
again only after the dialog is done AND its result delivered
(wm_on_activity_result_called precedes wm_on_resume_called in every
trace here). So dismiss() presses back only while the picker is in the
window list AND holds focus AND KayaHarnessAccessibility.appResumed is
false — a @Volatile written on the main thread from the mounted
activity's lifecycle, in the service's own process, read last of the
three because the window read before it costs an IPC per window. Both
measured injections land 126ms and ~140ms AFTER the app's onResume, so
both are refused. WHAT IT DOES NOT CLOSE, said out loud: the window
between the picker's finish and the app's resume, where kaya has no
lag-free signal at all — 13ms in matrix7 but 1.53s in matrix4, where
the result itself took 1.36s to arrive. A back injected THERE still
queues onto the app. If the class returns with the gate in place, that
is where it lives, and the clause available then is refusing the press
once the live dialog's result has already arrived, which covers the
last 275ms of it.

matrix6's save-jvm is NOT that ghost: the OS Displayed PickActivity in
1s57ms at 19:08:19.587 and the picker held input focus, while
pickerState() answered null for the next 7.4 seconds. The dialog
presented; the READER was blind. system_server said so itself in the
same seconds — "AccessibilityManagerService: wait for adding window
timeout: 1791" and "1793", its own complaint that a window was added
and the accessibility bookkeeping never caught up — and every one of
the six preserved failure buffers carries at least one of those lines.
What kaya printed instead was "the picker is showing null" and
"DocumentsUI is showing []", which read as measurements of an empty
screen and were nothing of the kind: windowPackages() maps
root?.packageName, so a window whose ROOT read returns null is
invisible to every reader built on it, and dialogShape() answers []
when no picker window is found at all.

SO THE INSTRUMENTS THIS ENTRY ASKED FOR ARE IN, permanent like
KAYA_PICK_RESULT. Every present records the moment it launch()es; the
first a11y read that sees that dialog logs KAYA_DIALOG_SEEN: dialog=N
kind=open|save ms=<elapsed>, and a reader's budget running out without
one logs KAYA_DIALOG_UNSEEN with the same elapsed AND A WINDOW CENSUS
— every window the service can see, with its a11y id, its package when
the root answered, and root-unreadable plus the window's title when it
did not. The id is there so the census joins to system_server's own
"wait for adding window timeout: <id>". Next sighting settles matrix6's
remaining question in one line: a picker window in the census with an
unreadable root means the read was blind, and no DocumentsUI window at
all means the window list never carried it. Every failure sentence
built on those readers now says which of the two it measured, and
dismiss()'s own refusal says how many backs it pressed and how many the
gate refused. UNVALIDATED until matrices run clean, as before — and
neither new line has ever been printed, so the first contended matrix
is also what makes them believable.
NINTH SIGHTING (2026-08-22 evening, filedialog-jvm under the breadth
slice's matrix; buffers kept), and it is the RESIDUAL WINDOW firing
exactly as written above: KAYA_DIALOG_SEEN 2393ms and 893ms, both
results delivered clean — then the dispatcher's "no window has focus"
wait at 29.295, the app's onActivityResult and onResume at 29.296 (ONE
millisecond later), and the queued straggler finishing the app at
29.531. The press was injected ~20ms BEFORE both in-process signals
existed, inside a 65ms picker-finish-to-result gap — the HEAD of the
window, and the falsification this sighting adds: the
result-already-arrived clause this entry proposed would NOT have
refused it either, since the press predates the result. What remains
is a remedy that needs the maintainer's ruling, because both shapes
change behavior: either a back-in-flight discipline (never press
again until the previous press has been OBSERVED to land — which the
lagging window list cannot attest, so it means a longer settle or an
event-driven read), or retiring injected backs from the cancel path
entirely in favor of an in-process cancellation, which is the remedy
the sixth sighting already flagged as needing that ruling.

RULED 2026-08-22 ("yeah let's do A") AND IMPLEMENTED, sharpened past
the ruling's own sketch because a bare something-changed handshake
would not have stopped the ninth press (the picker's closing fires
events too): the service consumes events as FRESHNESS SIGNALS now.
WINDOWS_CHANGE_REMOVED names the exact window the system removed, and
dismiss() and waitForPickerGone() treat that announcement as
outranking the stale list entry (KAYA_DISMISS_REMOVED logs the
short-circuit); dismiss() additionally presses only after windowEpoch
has moved since its last press, and its refusal sentence counts the
withheld presses beside the resumed-gate refusals. removals are
cleared at each dialog present so a reused id cannot vouch for a live
window. The service stays driven — nothing initiates from an event.
Injected backs stay the cancel mechanism, so the leg keeps exercising
the gesture a user presses; the in-process cancel (option B) is the
RECORDED ESCALATION if this ever fires again. Residual exposure, said
out loud: the gap between the window's actual removal and the removal
event's delivery to the service — system-push rather than
poll-refresh, so far smaller than the lag that bought the stragglers,
and not provably zero. An eleventh straggler would carry
KAYA_DISMISS_REMOVED absent and the withheld count in the refusal
sentence, which is what would falsify this remedy. UNVALIDATED until
matrices run clean, per the family's standing rule.
FIRST MATRIX WITH THE GATE AND INSTRUMENTS, same day: ALL PASS (112
android legs), and KAYA_DIALOG_SEEN was WATCHED PRINTING on the
device — dialog=1 kind=save ms=719, dialog=2 kind=open ms=671 — so
the healthy presentation baseline is ~700ms and the SEEN branch is
believed. KAYA_DIALOG_UNSEEN and the census have still never printed;
the next failure is what makes those branches evidence.
THE CENSUS PRINTED (2026-08-22 late, a filedialog leg under the TX 45
checkpoint matrix; buffers kept), and its first real sentence settles
this entry's remaining question in the direction nobody could have
asserted before: "no DocumentsUI window with a readable root; 0
windows, 0 with an unreadable root: []" — the window list carried
NOTHING AT ALL, not a picker with an unreadable root. getWindows()
answered empty while the dialog was requested, which is the
AccessibilityManagerService bookkeeping outage (the "wait for adding
window timeout" witness family), not a root-read failure. The census
branch is believed now, and the m6 face's mechanism is pinned one
level deeper: the blindness lives in the window LIST's arrival, so
any further remedy waits on a sighting where the list is non-empty
and still wrong.

ELEVENTH SIGHTING (2026-08-23, filedialog-go under the dynamic-table
matrix) falsified the remaining event-handshake window exactly. Three
BACKs navigated out and dismissed PickActivity; cancel and onResume
landed, then a FOURTH BACK — admitted because picker closing itself had
moved `windowEpoch`, with KAYA_DISMISS_REMOVED still absent — was queued
through the no-focus handoff and finish()ed MainActivity. The model-level
`expect "cancelled"` passed and the real-tree `expect_ax` found only the
dead activity's empty root. Full timestamps and the permanent finding
are in docs/traps.md, "A changed event is not a changed picker path."

The implemented A.2 wall replaces the global event with direct picker
state: same window, full breadcrumb trail stable twice, strictly shorter
than the last path that earned a BACK, with every earned path spent
before dispatch. A row or Save press marks the presentation closing so
cleanup cannot start the same race one action over. This is a deliberate
refinement of ruled option A rather than the bridge-Activity expansion
option B would require; B remains the escalation if a picker refuses a
spent BACK and produces the new safe-red. The cancel-path state machine
is self-tested on the path nobody avoids, and deleting both independent
walls was watched crashing filedialog-compose and save-compose with its
exact assertion. Validation results follow in this entry.

TWELFTH SIGHTING, the first standalone run after A.2, was NOT a BACK:
save-compose never reached dismissal. The service connected, then
AccessibilityManagerService timed out adding the app window id 103 and
picker id 105; WindowManager independently showed PickActivity rendered,
resumed and focused while KAYA_DIALOG_UNSEEN measured an empty window
list. The per-leg setup had installed while the old service component was
still enabled, and package replacement auto-started its process AFTER the
runner's force-stop had passed. A working preserved Go trace has the
opposite order and a fresh process. The runner now disarms, force-stops and
waits for the prior service before install, then requires the new bound
service to publish a readable-window handshake before `am start`; the
executable order census holds both boundaries. Its first positive run
caught one more false clear: Android rejects `settings put ... ""` as
`Bad arguments` and retains the old component, so the disarm refused all
JVM legs instead of letting them run blind. Both clear sites use
`settings delete` now. Moving disarm behind install failed the executable
order gate; restoring the empty-string clear failed its new clause; and
removing `flagRetrieveInteractiveWindows` made the live runner re-arm,
reboot, then refuse the scene after 90s with bound=1 and no readable
window. Restored, the full standalone Android lane passed in 154s
(Compose 56s, JVM 36s, Go 42s), including every picker and table leg; one
bound-but-not-ready first arm was re-armed before launch.
The next contended matrix exposed the cost boundary: all 112 legs passed,
but the lane took 415s against its 310s ceiling because disarm plus the
READY arm ran before ordinary in-app scenes too. The service is now
armed only for the `filedialog`, `save` and `editor` scripts; the
executable census derives that set from the shared picker verbs. Removing
`save` from the set and removing the conditional arm were each watched
red with one proven substitution. The unchanged 112-leg standalone lane
passed in 142s (Compose 49s, JVM 32s, Go 36s), including all seven live
DocumentsUI legs.

THIRTEENTH SIGHTING (2026-08-27, save-jvm on emulator-5558 under the
day stack's five-lane matrix; bundle preserved at
~/.local/state/kaya/flightrec/sightings/2026-08-27-save-jvm-13th-*),
and it is a shape none of the twelve had: A PICKER FINISHED ITSELF.
The leg's open dialog was seen slow under contention
(KAYA_DIALOG_UNSEEN at 5150ms with an EMPTY readable list, SEEN at
9188ms); save dialog 2 was seen at 1954ms and took the cancel path's
three earned BACKs (key_back_press 29.480/32.203/33.760 — the first
two consumed inside DocumentsUI, AutofillManagerService logging each,
consistent with the IME eating the first; A.2's breadcrumb rule earned
each one), dying on the third. Then save dialog 3: created 35.054,
SEEN at 877ms, and FINISHED BY APP-REQUEST at 36.110 — 260ms after
the service saw it, BEFORE the harness pressed anything, with NO
key_back_press logged in the gap and no result delivered; DocumentsUI
logged "Content updated." twice at 36.050 and nothing else. The title
expect at 36.937 then failed clean at the guests' post-fourth-sighting
sentence ("no file dialog live, wanted kaya-save-29528"), which is
this entry's walls holding. The armed setResult instrumentation has
nothing to say and that is CONSISTENT, not a miss: nothing was pressed,
so there was no result to lose. WHAT THIS SIGHTING CANNOT SAY: who
finished it — app-request names DocumentsUI's own process, and the log
cannot tell a late internal back-dispatch (the eleventh sighting's
straggler, one layer deeper than injection, which A.2 governs and this
would not be) from DocumentsUI closing over its own content refresh.
The next sighting should read DocumentsUI's back-dispatch and
onProviderChanged paths first. Standalone rerun green (save-jvm 8s,
full jvm suite green), classified with its family.

The next nice-only matrices still took Android 339/333/338s. The last
one exposed the startup boundary: `clipboard-compose` expired its first
five-second label wait as the Activity's first real frame arrived only
10–23ms before the deadline after a 6.774s launch; HWUI reported a
4682ms Davey frame and 234 skipped frames. Its other 21 assertions
passed. Compose now admits selftest from a one-shot
`OnPreDrawListener`; residual accessibility cleanup is one startup
`a11y_hygiene` sweep across the phones and tablet; and validate-all starts
all five platform lanes together, then waits for Android before starting
the niced gate sweep. The order, exact pid provenance, single-sweep shape,
early/double UI admission and one-shot removal perturbations are watched.
The standalone lane passed with Compose/JVM/Go at 52/32/34s.

The first barrier-only matrix made the residual measurable: gates waited
for Android and then passed in 218s, but Android's 112 green legs took
311s against 310. Its exact phase sum was preflight 3 + boot 18 + helper
17 + Compose 103 + JVM 2/68 + Go 4/96; there was no hidden retry to cut.
Nicing the other four runner shells was falsified immediately: Android
worsened to 316s while only mac moved materially, because the Docker,
CoreSimulator and UTM work is daemon-launched. The three-phone log's
actual service demand was Compose/JVM/Go 228/174/232s; greedy makespans
move 80/59/84 -> 61/47/64 with a fourth slot, projecting about 266s with
measured overhead. Runner and environment probe now share a stable
four-phone default, and both restorations to three are watched red. The
first all-five-at-t0 run with it passed every leg but took 350s: exact
phases 3+22+31+102+6+81+4+101, versus 126s standalone. The pool was not
the whole remedy. A staged experiment reserved Android through its final
Compose drain (a 63s standalone prefix) before admitting the other four
lanes; the measured contended JVM+Go suffix projected the lane at 255s.
That was not a matrix pass and the experiment was rejected because all
five platform lanes must launch together. The four-phone default and 310s
ceiling remain; the duration anomaly is open.

The two bounded runner removals are now implemented, while scheduler
acceptance remains open. A source census found 112 per-leg replacements of three
unchanged APKs (38/36/38 legs, 111095703/64911093/74364739 bytes): 9.384 GB
per run. One post-verification install per eligible device would be
5+4+4=13 installs and 1.113 GB, removing 99 replacements and 8.272 GB.
Nine retained Android buffer logs supplied 646/563/563 deduplicated
death-to-install-commit samples with medians 0.734/0.884/0.804s and means
1.114/1.735/1.019s; including commit-to-next-start projects 22-36s off a
four-phone critical path. Separately, the three ranges legs are each
bracketed by a whole-pool drain and four-device IME selection. The
retained phone-leg sums model at 86/67/87s without that barrier against
measured phases of 102/81/101s, a 44s upper bound that also contains adb
and control overhead. Suite-scoped installation now holds verified build
-> every eligible device -> first leg, and ranges selects the helper IME
only after claiming its device slot, held through launch; their topology,
target/verdict refusals and cleanup paths are watched red. The optimized
default four-phone standalone run passed all 112 legs in 105s, exact phases
3+8+11+35+2+21+2+23, versus the prior 126s baseline and the rejected
five-phone experiment's 141s. The measurements and projection boundary are
recorded in docs/traps.md; the duration entry stays open until a real
all-five-at-t0 matrix pass.

FIRST OPTIMIZED-RUNNER ALL-AT-T0 ATTEMPT 2026-08-24: Android passed all
112 real scene legs in 268s, 42s inside its unchanged ceiling. The full
record was refused on Linux and Windows duration alone, so this is
positive scheduler evidence, not the accepted matrix pass required above;
the entry remains open. Per maintainer direction there is no rerun,
ceiling move or scheduler change. Whole-host contention, thermal state
and unrelated applications were uncontrolled variables, not measured
causes.

## ~~WATCH — a windows dialog leg's process is held ~60s from ITS OWN START, intermittently (2026-08-27)~~
KEY: dialog leg 64s, TerminateProcess, harness_exit, exit grace hostage,
FileChoose stall, loader lock, DLL_PROCESS_DETACH, win_exit_tests,
windows duration anomaly

SUPERSEDED 2026-08-27/28 and measured quiet 2026-08-30, struck
2026-08-31. The captor was characterised to the bottom: `ExitProcess`
runs loader shutdown and a wedged thread holds the exit itself, and
below that a synchronous kernel IO holds even `TerminateProcess`
(docs/traps.md "exit() is not final on Windows"). The walls:
`harness_exit` uses TerminateProcess (crates/kaya/src/harness.rs),
proven on the guest against a real FLS-callback wedge by
`harness::win_exit_tests` in deploy-win.sh's unit phase, and the
runner stopped waiting for the corpse (wait-exit.ps1's KAYA_LINGER).
Measured 2026-08-30 over three full windows lane runs (201 legs each,
load1 65.0/7.4/9.4): the seven dialog legs cost 33s/21s/26s COMBINED —
at or under this entry's own 43s-combined healthy baseline, none above
7s — and the contended run's log carries zero KAYA_LINGER lines across
202 EXIT= records. Residual, unclosed but costless: the captor's
identity (which IO — WebDAV or cloud-files) was never named, and the
20.8s mid-scene FileChoose stall class is uncapped — unobserved in 21
dialog-leg samples.

First seen in the 12:28 matrix and in every windows lane run through the
afternoon: all seven dialog-family legs (filedialog x5, save_rust,
editor_go) pinned at 64s where the morning run had them at 43s COMBINED,
every other leg unchanged, host load uncorrelated (the fastest run
carried the highest load). Probe runs of one leg, sampled at 1s from the
host: (1) 64s total — out file growing incrementally, scene done at
+24s including a 20.8s stall between FileChoose and the "reading" label,
process alive doing nothing until +64.4s; (2) same shape; (3) minutes
later, CLEAN — 1.4s scene, prompt exit. So the captor is intermittent,
holds a fresh process ~60s from ITS START (not from the verdict), and
can also surface mid-scene in the picked-file read. Network was clean at
sample time (DNS 478ms, TCP 457ms); no Defender scan; guest session was
11.5 days up.

WHAT IT COSTS NOW: ~verdict+6s per affected leg, not 64 — not because
any exit primitive wins (waypoint-measured: TerminateProcess was CALLED
at +2.3s and the kernel held the terminating process to +63s; the
captor is below user mode) but because the RUNNER stopped waiting for
the corpse: wait-exit.ps1's verdict grace and run_one_suite's
KAYA_LINGER arm (docs/traps.md "exit() is not final on Windows"). The
20.8s mid-scene stall class remains uncapped by that and fits inside
the step ceiling.

NEXT SIGHTING: the discriminating read is the held process's THREAD WAIT
STATES and module list, taken mid-hang via `powershell -EncodedCommand`
(bare -Command quoting eats $ through ssh; docs/traps.md). Check the
WebClient/WebDAV service state and shell cloud-file endpoints beside it.
A sighting where the wait sits in LdrShutdownProcess confirms the
loader-lock half; one where it sits in a network wait names the captor.

## ~~WATCH — the iOS sheets shrug off single taps under a concurrent matrix (2026-08-20)~~
KEY: ios save sheet, presses of Save, rounds of choosing, simdrive
retap, KAYA_SIMDRIVE_LOG, ios-simdrive-logs, LocalStorage, FP -1005,
Index out of sync, empty didPickDocumentURLs, export preflight, simctl
listapps, dev.kaya. bundle cleanup, retained app data

STRUCK 2026-08-31: the tap-dropping reading was FALSIFIED by its own
instruments, and the family has been quiet since 2026-08-27. Every
instrumented sighting showed taps DELIVERED, the runloop alive,
dismissals honest, and the hit-test owner logging named the "extra"
taps as intentional navigation inside the picker (AXButtons "On My
iPhone", "Browse", "Cancel"); the residual FP -1005 / empty
didPickDocumentURLs face was closed by the per-phone `dev.kaya.*`
uninstall census and the known-byte export/reopen admission probe
(tools/ios/run-sim.sh). Measured 2026-08-30: three iOS lane runs (113
legs each, one at load1 62.3), all ten sheet-family legs PASS in each,
and the day's simdrive logs show every `wait_picker ok=yes` in 1-4
tries with `read_timeouts=0` on all 105 reads sampled. The instruments
(KAYA_SIMDRIVE_LOG, per-tap hit-test owner) STAY, so a recurrence
self-diagnoses; the only thing this strike leaves unexplained is the
original uninstrumented 2026-08-20 sighting, which no later evidence
reproduces.

Three matrices in a row, a different leg each time, every one 100%
green solo: save-go's Save tap dropped twice (the sheet stayed up and
the guest later read the teardown's `save cancelled`), then — with the
Save retap in place — filedialog-go's ROW tap dropped the same way.
The panes depth slice running those matrices touches no dialog path.
The diagnosis is savename's own measured finding, one gesture over:
on a machine also running four other lanes, a dispatched HID tap and
a dropped one are the same silence. So the two dismissal-verified taps
now retry the way `savename` always has — `savepress` up to three
presses re-walking the strip each round (a strip no longer offering
Save means the sheet is going, and that round only polls rather than
tapping the app behind it), and `choose` retrying the whole
select-confirm round with re-walked row frames, converging for single-
and multi-selection both. WATCH half: if the signature returns WITH
the retaps in place, the taps are not being dropped — keep the failing
sim booted and read the control frames from simdrive's inventory,
because a stationary control that eats three delivered taps is the
sim's runloop, not the gesture.

THAT BRANCH FIRED 2026-08-20, same day: save-go under the full
matrix, and the failure message carried the inventory this entry
asked for — Save still in the strip, STATIONARY at the same centre,
after three delivered taps across ~18s of dismissal polling, on a leg
stretched 21s -> 99s by contention. A starved sim's runloop stalling
through that window is the conviction; the remedy matched the
mechanism rather than the gesture: savepress and choose both went 3
-> 6 rounds (~36s of window), free when healthy since the first round
exits as soon as the sheet goes. If a sheet survives SIX rounds, stop
raising the cap — that sim's runloop is not coming back, and the leg
should fail into the pool-health question instead.
THIRD SIGHTING 2026-08-21 evening, matrix7: editor-go again, the
save sheet holding through the save press so the title never became
"draft" — same signature, same contended-matrix-only pattern, fourth
dialog-family failure of the evening across both mobile platforms.
SECOND SIGHTING 2026-08-21, matrix4: editor-go's save sheet ate SIX
presses of Save ("the save dialog was still up after 6 presses"), on a
host measurably busier than usual (WindowServer 46%, video decode
active; the same matrix tripped three lane duration ceilings and
android's save-compose lost its dialog the same run). The new
step-failed line carried the driver's full self-diagnosis into the log
— coordinates tapped, what the sheet offered — which is exactly the
evidence the first sighting lacked. Still consistent with
contention-starved sheet animation; still no code suspect.

INSTRUMENTED 2026-08-22, because a fourth rerun would have bought
another one-line sighting. simdrive now writes phase timings to a SIDE
CHANNEL — never to stdout or stderr, which simdrive_watch hands to the
guest as the response it parses — at the file KAYA_SIMDRIVE_LOG names,
one `KAYA_SIMDRIVE: at=<epoch ms> t=<ms> verb= ev=<event>` line per
event. Every wait loop reports its elapsed ms and the phase it reached
(wait_picker, wait_rows and wait_save_sheet split CHROME-SEEN from
ROWS/FIELD-SEEN, the two-phase race waitForRows describes; wait_gone
reports the probe cost and any bridge read that expired during it),
savepress, choose, cancelSheet and savename log every round with what
was tapped or that the strip no longer offered it, and the
navigation-strip sweep reports its wall time against a FIXED hit-test
count, which is a direct reading of what the simulator's accessibility
bridge is managing. Two silences ended: the HID send's completion
Error and its 10s wait were discarded, so a dropped tap could never be
observed from this side, and every accessibility round trip is now
counted and timed — a request that expires at 20s returns nil, which
every caller reads as "nothing is there". run-sim.sh's watcher adds
the half simdrive cannot see, one line per request with rc, total ms
and the pid-resolution ms.

Every failure sentence now ends with that verb's own numbers (reads,
slowest read, timeouts, taps, elapsed), and the sheet sentences say
whether the control sat at ONE FIXED CENTRE across the rounds — this
entry's own question — and WHO holds the screen: pid and host process
name. That last one is a FOURTH CANDIDATE this entry never carried.
pickerRoot calls any non-app pid at the centre probes "the picker",
and the second sighting's own sentence listed "7:18 PM / Cellular /
100% battery power", which is SpringBoard's status bar and not
DocumentsUI's chrome — so a sheet reported "still up" may have been
gone, with a hit test answered by another process (docs/traps.md's
fourth item in "Three ways the iOS picker is not the picker you
measured" is the same trap, one caller over). The next sighting names
the process. Its mirror is a false DISMISSAL: one timed-out read makes
waitForPickerGone say "gone", and a leg whose sheet never really left
is exactly the third sighting's shape (editor-go, the title never
became "draft"). Android's sibling ghost was closed by DEBOUNCING the
same kind of decision — two consecutive absences before believing one
— and if the log shows a wait_gone ok=yes with read_timeouts=1, that
is the fix here too, and NOT another round-cap raise.

TENTH SIGHTING (2026-08-22 evening, save-go under the spacing
slice's matrix), and the DECISIVE COMBINATION fired verbatim: six
taps delivered (down=ok up=ok) to Save at ONE fixed centre (324,92)
across 46303ms, the hit test answered by the real picker process
(pid 76151 com.apple.DocumentManager, root AXApplication/Files), and
the bridge serving 3245 reads with the SLOWEST AT 31ms and zero
timeouts. The sheet was honestly up, the runloop was demonstrably
healthy, and the taps were DELIVERED AND IGNORED — which FALSIFIES
the second sighting's starved-runloop conviction and moves the
investigation to the sheet's own input path, exactly as this entry's
decisive-combination paragraph predicted. The next discriminator is
armed (2026-08-22): savepress's failure path now hit-tests the Save
centre once more and performs an AX-press on the element — a
DISCRIMINATOR, never a driver: the leg fails either way, and the
sentence learns which story survives (AX-press dismissing what six
HID taps could not convicts the input path — a wedged gesture
recognizer or an un-completed presentation transition swallowing
touches; AX-press also ignored convicts the button itself). Eleventh
sighting reads that clause first.
A FIFTH FACE, NOT THE TAPS (2026-08-22 late, editor-go under the TX 45
checkpoint matrix; the timing log kept): the instruments cleared every
prior suspect in one screen — wait_picker ok in 89ms, reads at 13ms
max, zero timeouts, zero taps — and the failure is an AIM MISS:
choose found "no row named notes; the picker lists ['kaya-editor-1116',
'kaya-editor-3931', ...]" — the picker sat at the PARENT directory,
listing THIS run's own kaya-editor-1116 as a row among six stale
siblings from previous runs. The first-picker-after-boot trap's shape
(docs/traps.md; run-sim warms the document stack for exactly this),
recurring mid-run. The retained-container half is now closed: per-phone
preparation uninstalls every exact prior-run `dev.kaya.*` bundle through
`simctl`, which removes its data container before LocalStorage admission.
The remaining follow-up when this face returns is to instrument the AIM:
log the directory goto requested beside the breadcrumb the picker
answered (`currentDirectory` already reads it).

A green run's log is the baseline: target/ios-simdrive-logs/<leg>.log
for each of the four dialog scenes, cleared per run; a failing leg's
copy is kept at target/validate-failures/ios-<leg>-simdrive.log with
its last 40 lines in the lane log. Healthy-versus-starved is a diff of
those two, which is what the next sighting is for. NOT YET WATCHED
PRINTING: every branch that needs a live simulator (this work booted
none). The first iOS lane run after this should confirm the green
baseline is there and the protocol intact — a dialog leg that goes
green with a non-empty log proves both at once.
IT DID, same day: the full matrix ran ALL PASS (106 iOS legs, lane
contended at 401s) with ten non-empty leg logs in
target/ios-simdrive-logs/, so the protocol survived and the baseline
exists. First numbers worth keeping: a green contended save-go leg
shows wait_picker ok=yes ms=3232 tries=4 with bridge_slow lines up to
857ms, and the presence probe now names its answerer
(proc=com.apple.DocumentManager...), which is the fourth candidate's
discriminator doing its job on a healthy run.

FOURTH SIGHTING, THE FIRST WITH THE NUMBERS (2026-08-22 late,
save-swiftui under the geometry slice's contended matrix; evidence
kept at target/validate-failures/ios-save-swiftui-simdrive.log). The
label read "save cancelled" where "saved third draft" was wanted —
the family's exact signature — and the log kills two of the four
candidates outright and wounds a third: every tap was DELIVERED
(down="ok" up="ok" on all of them, so not (A)); the runloop was
ALIVE (1621 reads served in the cancel verb alone, read_max_ms 442,
read_timeouts=0 everywhere, so not (B)); and the dismissals were
HONEST (every wait_gone ok=yes carried read_timeouts=0, so not the
false-gone half of (D)). What the numbers ADD: the cancel cycle took
FOUR delivered taps at (38,92) across 6.2s, the strip still offering
Cancel each round (controls=8,8,8 then 7 — the sheet was changing
under the last one), and the FINAL save press then landed cleanly
(round 1, sheet gone in 859ms) with the result never reaching the
guest. At the time this was read as three extra taps delivered into a
sheet whose dismissal lagged its chrome — the android straggler class
in this platform's spelling. The raw timing remains measured, but the
"extra taps" interpretation is falsified by the instrumented run
below. The leg passes solo; the family's no-rerun rule stands.

RECURRENCE 2026-08-23, save-swiftui under the dynamic-table depth
matrix: the cancel cycle delivered Back/Back/Back/Cancel over 9.633s
with 1621 reads, 64ms slowest and zero timeouts; the next sheet's one
Save tap at (323.8,92) honestly dismissed it in 965ms with zero
timeouts, then `documentPickerWasCancelled` fired and the backend
emitted cancellation. The callback was not lost, so this sighting
falsifies the earlier “result never reaching the guest” reading. The
recorded next instrument is now live: every cancel-cycle and Save tap
logs the hit-test owner's pid, process, role and description immediately
before the HID send. The next contended matrix, not a known-green solo,
is what makes those facts print.

THE INSTRUMENT PRINTED in the next contended matrix, and the iOS lane
passed. All five controls belonged to the same DocumentManager service
(pid 13656 in that run), all were AXButtons, and their descriptions
were `savers-swiftui`, `On My iPhone`, `Browse`, `Cancel`, then `Save`.
The three Back taps were intentional navigation from the app folder to
On My iPhone to Browse before Cancel; none was an extra tap into a
dismissing sheet or the app behind it. The Save tap was likewise the
picker's own Save button. This corrects the fourth sighting's causal
reading without deleting its measurements.

THE NEXT MATRIX CLOSED THE CALLBACK-GENERATION BRANCH (2026-08-23):
105/106 iOS legs passed; save-swiftui's real Save AXButton dismissed in
one tap with zero read timeouts, then UIKit delivered cancellation.
Unified logging measured LocalStorage FP -1005 for `did=8079` ("The file
doesn't exist"), DocumentManager failing to tag it, `Index out of sync.
Forcing reindex`, and an empty `didPickDocumentURLs` because the item
failed preparation/materialization. The failed run's old picker scene
was fully invalidated 57ms before the new controller was ready; a green
sibling overlapped those generations by 15ms, falsifying the proposed
dismissal delay. The passing sibling also carried the destination
file-coordination claim that the failed run never reached.

The lane now admits each phone with a real known-byte export/reopen. An
empty callback or contemporaneous FP -1005 re-seeds only that UDID and
retries the admission once; a second failure refuses before any leg.
The static wall's per-device, two-attempt, one-device, readback and prep
ordering perturbations all printed one substitution and failed. The
live probe's `publish("ok")` was changed once to `publish("empty
watched-negative")`: the real `picker_export_probe` returned its
recoverable 75 on kaya-sim-1, then returned 0 after the one-count restore.
This closes the result-generation suspect, not the WATCH: the older
six-delivered-and-ignored-taps sighting is still a different open face.

RECURRENCE AFTER GREEN PREFLIGHT: editor-go's real Save dismissed in
820ms, then LocalStorage repeated FP -1005, `Index out of sync` and empty
URLs. The failed phone held 101 installed Kaya bundles, 58 old editor
directories in that app, and 503 Kaya scratch directories across 12
retained containers. `simctl install` preserves those containers, so the
probe's separate clean app was the wrong scope. Per-phone preparation
now uninstalls the exact finite `dev.kaya.*` census before warm/probe and
refuses a nonempty recensus. The live skip-one negative removed 100 apps,
named retained `dev.kaya.editorgo`, and the positive cleanup removed it.
The full standalone iOS lane then passed; this still does not close the
distinct six-delivered-and-ignored-taps face.

## ~~The a11y example still embeds its image as source bytes~~ (found 2026-08-19)
KEY: a11y TEST_PNG, inline image bytes, asset icons

guests/rust/a11y.rs:34 draws its image from an inline TEST_PNG byte
array, and its seven siblings do the same. The assets survey ruled the
tree's inline PNGs 'stay' under one blanket reason — a DECODE-assertion
scene must not fail because a file was not staged — but a11y is not a
decode assertion: its image exists so the accessibility read has an
image widget with a label, and the staging risk died when the asset
root became a hash-verified unit on every lane (tools/check-assets.sh).
The example tier should read as the kaya calls an app would make:
asset(name) for the picture, the way the typeface and identity guests
already do. The decode-assertion inlines (the gallery's corrupt PNG and
kin) KEEP their bytes — their subject is the bytes. Closing this:
sweep all nine a11y guests (eight bindings + the C floor's verdict per
invariant 2), land the picture under guests/assets/, and re-run the
matrix — expect_ax reads are stamped observations, so nothing in the
scene moves.

RESOLVED 2026-08-19, same day: image-from-asset landed in all eight
bindings — Rust rides Into&lt;Blob&gt; (an Arc refcount clone), Go grew
ImageAsset beside AppIdentityAsset, Python's image() source slot takes
an Asset the way its identity and typeface keywords already did, C#,
Java and Swift overloaded, OCaml paired ~source_asset with ~source
under the both-named refusal its siblings use, Haskell exported
imageAsset beside imageBytes. All nine a11y guests' inline PNGs are
gone but the C floor's, which KEEPS its bytes as the floor's
documentation (invariant 5) — that is the per-language verdict, not an
omission. The gallery scenes keep theirs everywhere: their bytes are
decode-assertion inputs, the survey's original reason, now scoped to
the scenes it is true of. The picture itself is guests/assets/images/a11y-logo.png
— the guests' old 2x2 TEST_PNG extracted verbatim, NOT the kaya mark,
and that is a measured cliff rather than a taste call: the 64x64 mark
grew the scene ~62px, pushed its last three widgets past the emulator
viewport, and the a11y provider answers offscreen nodes with 20s of
silence per read — the leg timed out with the scene substantively
green. The full story is in the icons README, beside the file a future
hand would swap.


## ~~Multi-column adaptive layout — the unbuilt half, now the ACTIVE milestone (promoted 2026-08-19)~~
KEY: multi-column, adaptive layout, three-pane, NavigationSplitView, pane roles

SHIPPED, struck 2026-08-31: all four backends present a declared
ceiling of three (KayaSplitRoot3 with the mac ladder gate, GTK's
nested split views, WinUI's nested TwoPaneViews, Compose adaptive
1.2.0), `panes` at wprop 6 in all eight bindings, expect_panes in all
three harnesses, the eight-language guest fan-out, every slice
matrix-validated — the body below is the record. The live residue
moved to its own entry below ("Multi-column residue"); the Compose
entrance-animation click-drop WATCH moved to docs/traps.md, whose
copy is now the original.

Promoted out of the struck adaptive entry whose body filed it "rather
than done": the part of adaptive layout that never landed. kaya has the
two-pane list_detail with width-driven collapse; it has no way to
declare a THIRD pane or any pane-role/priority vocabulary, and every
platform ships a native construct for exactly that (NavigationSplitView's
three columns, WinUI's pane patterns, Adw's split views, Compose's
ListDetailPaneScaffold/SupportingPaneScaffold). The maintainer ranked
this FIRST among feature milestones (2026-08-19), tables second. The
plan was ratified 5/5 the same day (docs/multicolumn-plan.md).

Progress: the `panes` wire slice landed 2026-08-19 (fb9ac93 — the
ceiling replaces list_detail at wprop 6, all eight bindings, both
interpreters, observables unchanged). The macOS depth slice landed
2026-08-20 (9fbe4e7: KayaSplitRoot3, the mac ladder with its own gate,
`expect_panes` in all three harness implementations, panes.steps, the
rust guest), then the eight-language guest fan-out and Compose
(2f8e49e), GTK (e42efa7), and WinUI — ALL FOUR BACKENDS now present a
declared ceiling of three, every slice validated by a full matrix, and
DESIGN.md's section is rewritten as "Adaptive panes" with Q5's
authority. The stub records below are the per-backend closes:

- ~~DEPTH STUB: panes on gtk~~ (LANDED 2026-08-20: the nested pair with
  the inner view in the OUTER'S CONTENT slot — probed live first; the
  cumulative rung table makes a non-cumulative breakpoint list
  inexpressible; show-content driven from the stack on both views; the
  back affordance from the reveals-a-covered-surface rule; the lane's
  stages grown to 1600x1000 and its text scale pinned)
- ~~DEPTH STUB: panes on winui~~ (LANDED 2026-08-20: the nested
  TwoPaneViews with the inner in the star-sized Pane2, the PanePriority
  chain spelling D1's order, Tall mode killed by infinity on every
  view — with a check-steps clause holding the kill present, since the
  lane's green otherwise rests on every scene height being 600 — and
  release_split walking the nest depth-first)
- ~~DEPTH STUB: panes on compose~~ (LANDED 2026-08-20: adaptive 1.2.0
  with the Large/XL opt-in, the declared-ceiling cap, the stack-derived
  destination history, the extra pane, and expect_panes reading the
  stashed ThreePaneScaffoldValue role by role)

The residue moved to "Multi-column residue" below (2026-08-31), so
live work is not invisible inside this struck text; the WATCH moved
to docs/traps.md.

## Multi-column residue — phone-lane frozen scenes and the unmeasured floors (carried 2026-08-31 from the shipped milestone)
KEY: panes phone lanes, tablet AVD band ruling, three-pane floor measurement, listdetail three-pane sibling

Carried out of the struck milestone entry above. PHONE-LANE FROZEN
SCENES — panes.steps is desktop-only by policy (it resizes), so the
iPad and android three-pane observations are live probes on the
record (the 1280dp tablet read `regular/0,1,2` from the scaffold's
own value 2026-08-20; the iPad three-column form was measured live at
1032pt during the research pass) rather than frozen legs; a no-resize
three-pane scene in listdetail.steps' mold needs the tablet-AVD/band
ruling first. MEASURED FLOORS — before any shared literal below 1400,
the Windows nest's real three-pane floor and the GTK lane's at pinned
text scale must be measured (the band's 1400 top is safe by
construction; check-steps refuses any literal in the 400..1400 band
meanwhile). LISTDETAIL.STEPS stays at panes 2 deliberately: it is the
two-pane bare-invariant scene and every lane runs it; whether it
grows a three-pane sibling is the same AVD/band decision. The Compose
entrance-animation click-drop signature is in docs/traps.md ("A
Compose click within ~half a second of a pane's ENTRANCE ANIMATION
can drop").

## The refusal affordances are never asserted PRESENT (promoted 2026-08-19)
KEY: affordance presence, refuse-when-absent, four backends

Promoted out of a struck parent for the same reason: filed inside text
that got struck. All four backends implement "refuse the action where
the affordance is absent," and scenes assert the refusals — but nothing
anywhere asserts the affordance EXISTS where it should, so a backend
that lost an affordance entirely would pass every refusal test vacuously.
A presence assertion per affordance closes the loophole. MILESTONE.

## HOLD — Python's Signal comparison operators await a use-case (2026-08-19)
KEY: Signal operators, derived comparison, python sugar, invariant 1

Python's Signal alone carries the comparison-operator vocabulary
(eq/ne/lt/gt/le/ge and friends); the other seven bindings have none of
it — an invariant-1 divergence, HELD deliberately rather than resolved
blind (maintainer, 2026-08-19: "I can see the argument for fanning out
and making all bindings have that sugar provided we find the use-case").
No scene, example, or the editor uses the operators; every guest that
wanted derived state computed it in its own fold. TRIGGER: the first
scene or example that genuinely wants a declared derived comparison
("enable Save when count > 0" as a bound signal rather than guest code).
When it fires: fan the vocabulary out to all eight. If a full milestone
cycle passes without the trigger, strip Python's instead — either way
the divergence ends.

## ~~WATCH — typeface-haskell-wayland segfaulted at exit after an OK verdict (2026-08-19)~~
KEY: haskell segfault, typeface wayland, RTS teardown, exit path

AGED OUT — CLOSED 2026-08-31: one sighting, no recurrence in 11 days.
Measured 2026-08-30 across three linux lane runs (604 legs each,
1,812 legs, zero non-PASS): typeface-haskell-{wayland,x11} passed in
1-2s in every run. Absence is evidence here because a segfault after
an OK verdict is recorded FAIL — run-suites.sh takes run_one's exit
status, tools/linux/a11y-leg.sh propagates the guest's, and
run-suites.sh prints the "verdict was OK but the leg exited nonzero"
note for exactly this shape. The body below is the sole record of the
signature; the recorded next step (core-dump the container, RTS
finalizer ordering vs gtk/pango teardown) stands if it returns.

Once, under a five-lane matrix; 20/20 green solo immediately after. The
reworded runner note plus the leg log carried the whole signature this
time: `KAYA_SELFTEST: OK` then `a11y-leg.sh: line 40: <pid>
Segmentation fault` — the Haskell guest's process died in TEARDOWN, verdict
already printed. The suspects live where Haskell's RTS finalization
meets GTK/pango teardown after the typeface blob registration
(gtk.rs's register_font_blob file is mapped by fontconfig/freetype at
exit). NOT the torn-diag class (fixed, kaya_diag!) and NOT a witness
clause — this leg has no wrapper beyond a11y-leg.sh. If it repeats:
core-dump the container (ulimit -c unlimited, coredumpctl or
/proc/sys/kernel/core_pattern in docker), and look at the RTS's
foreign-finalizer ordering against gtk_main teardown, not at the scene.
## Test-speed profile 2026-08-20 — the measured map; both speedups ratified and landed (headline refreshed 2026-08-31)
KEY: test speed, keyed cache, matrix bound, save panel cost, clipboard prompt cost

HEADLINE REFRESHED 2026-08-31: the old headline said the two speedups
"need a ruling", but the body's own record says both were RATIFIED AND
LANDED 2026-08-20 — it sat stale for eleven days, the check-ledger
class with a softer spelling. What the entry remains open FOR is the
measured map itself (the per-leg cost profile nobody should re-measure
blind) — and its one open thread, the 2026-08-23 scheduler anomaly, is
CLOSED as of 2026-08-30: three all-at-t0 five-lane matrices put
android at 283s/191s/227s against the 310s ceiling with every leg
green (the same evidence is in the save-jvm entry's 2026-08-31
amendment).

The maintainer asked for faster feature iteration; the day's runs were
profiled before anything was touched. The measured map, so nobody
re-measures it blind: the matrix's bound is the mac lane (~500s
contended = the 41-gate sweep ~150s + 320 legs at ~230s wall, only
~1.7x parallel BY DESIGN — the AX-degradation trap). Gate sweep: 148s
cold / 46s warm-keyed; the warm residue is the deliberately-unkeyed
artifact gates (check-abort ~13s, the two interpreter-compiling probes
~5s each). Per-leg medians are healthy everywhere (mac 0-1s, linux
1-2s, windows 1-2s); the whales are SEMANTIC, not waste: the mac save
legs are 2 x ~8.7s of NSSavePanel presentation, the panel service's own
cost on this box (measured 2026-08-09, recorded in
kayaAwaitSavePanelState's comment), and the iOS clipboard legs are ~9s
per pasteboard operation, most of it the foreign-read privacy prompt
dance that IS the thing under test. The stall scenes' 8s is the scene's
own design.

LANDED the same day: the keyed cache now RECORDS on full sweeps
(consults nothing — check-keyed's 5b clauses hold both halves), so the
first KAYA_FAST run after any full sweep is warm; and the windows
caption-centre probe polls for its own "PROVE: done" instead of
sleeping a guessed 50s (60s -> 22s, every windows lane).

BOTH PROPOSALS WERE RATIFIED AND LANDED 2026-08-20, and the landing
measured two defects nobody had seen:
1. THE ARTIFACT GATES ARE KEYED on sources plus the artifact's
   EMBEDDED build-id (never its raw bytes: every relink mints a fresh
   LC_UUID, and gen-guests' every-sweep restore used to touch source
   mtimes and trigger exactly such a relink — a raw-byte key was
   measured never hitting at all. gen-guests now gives byte-identical
   files their pre-check mtimes back, so sweeps stop relinking
   entirely). Warm sweep: 46s -> 23s, 28 of 41 gates keyed;
   check-keyed's 5c clauses hold the marker-follows rule in both
   directions, and the CLAUDE.md sentence moved with the ruling.
SAME-CLAIM OVERLAP AUDIT, 2026-08-20 (the maintainer asked whether
two scenes ever assert the same behavior; surveyed by assertion-verb
inventory across all 40 scenes, then by reading every suspicious
pair's actual claims): the roster is essentially free of it, and each
suspect resolved on the record. identity.steps' expect_toolbar pair
LOOKS like toolbar.steps' opening but is the custom-caption identity
sink's witness (its own comment block says so — a promotion mints the
custom caption that replaces the system-drawn icon, and the assert
proves that arm was reached, not toolbar semantics). window vs panels
both read window sizes — of DIFFERENT windows (primary prop vs aux).
milestone2 re-covers click/label foundations but is seven ~free steps
and the harness's own parse fixture. editor re-asserts save/dirty/
ranges/menus claims deliberately — it is the integration artifact, one
leg per lane. save.steps embeds an open-picker cycle as setup for its
reopen claims (~2s of a leg whose 17s is the panel service). The
expensive legs are expensive for SEMANTIC reasons — NSSavePanel's
presentation, the iOS paste prompt, the stall scene's deliberate block
— not duplication.

2. THE GATE SWEEP IS ITS OWN MATRIX UNIT. The 2026-08-20 landing
   computed a same-tree fingerprint at t0 and launched all five lanes
   plus the sweep together; the mac lane skipped its in-lane sweep while
   the fingerprint matched (a within-run handshake — a hand-run
   validate-mac sees no token and sweeps as always). Putting the sweep
   BEFORE the lanes merely relocated serialization (530s, measured).
   The concurrent shape flushed out two safety fixes: build-dylib now
   holds a lock and replaces the dylib atomically instead of creating a
   ~30s no-dylib hole. Matrix wall: ~504–546s -> 450/452s on consecutive
   ALL PASS runs.

   AMENDED 2026-08-23: six-way-at-t0 contention took Android from 142s
   solo to 373s with a normal sweep, 339s with niceness 10, and 333s in a
   falsified six-job Linux experiment; a later niced run still took
   338s. The first barrier-only matrix passed every leg and the delayed
   sweep but left Android at 311s/310. Nicing the other four runner shells
   was falsified at Android 316s: daemon-launched platform work did not
   inherit the intended priority. The measured three-slot leg makespans
   selected a stable four-phone Android pool, but the all-five-at-t0
   acceptance still passed its 112 legs in 350s/310. Standalone four-phone
   phases were 3+9+11+40+2+27+2+32 = 126s; contended phases were
   3+22+31+102+6+81+4+101. A staged experiment then reserved Android
   through its final Compose drain before admitting the other four lanes;
   its 63s prefix plus measured 192s contended suffix projected 255s. It
   never produced an accepted matrix result and was rejected because it
   broke the ratified all-five-platform concurrency rule. Validate-all's
   contract remains: start all five platform lanes together, wait for
   Android's recorded pid, then launch `nice -n 10 tools/gates.sh` while
   longer lanes continue. The four-phone runner/probe default and 310s
   ceiling remain; the 350s result left the duration anomaly open
   until the 2026-08-30 closure in this entry's head note.
   A follow-up source/log census found two in-run work removals: 112 repeated
   APK installs became 13 suite/device installs, and the ranges IME
   requirement moved inside its claimed device slot instead of draining the
   whole pool. The first guarded implementation run passed all 112 legs in
   105s standalone (3+8+11+35+2+21+2+23), against the prior four-phone 126s
   and rejected five-phone 141s. Their byte counts, retained-event samples
   and projection boundary live in docs/traps.md, "A sixth compile unit can
   starve Android past both its duration ceiling and first draw," and in the
   Android WATCH above. The first all-at-t0 attempt on those removals is
   recorded there: Android passed 112 legs in 268s/310, but Linux and
   Windows duration guards refused the full record. This remained an
   open anomaly until 2026-08-30's three accepted all-at-t0 matrices
   (this entry's head note).

THE BELOW-400 PUSH, 2026-08-20 (the maintainer asked for the matrix
under ~400s; it reached 422 and three lanes now cluster at the bound):
after the iOS phase interleave took the matrix to 438, three
per-second-scale wastes were measured and removed. LINUX: every one of
~280 x11 legs booted its own Xvfb (~0.5s each) and every one of 134
a11y legs slept a FIXED second waiting for the at-spi launcher — the
lane now claims displays from a booted-once pool (one leg per display
at a time keeps xvfb-run's isolation; a failed leg reboots its display
before releasing it) and polls the session bus for org.a11y.Bus
instead of sleeping. Container suites 202s standalone; contended lane
436 -> 319-397 across three matrices. The pool's servers must be
DISOWNED — eight forever-running jobs pushed run()'s jobs-count
throttle past JOBS and deadlocked the first leg, the drain comment's
bare-wait trap through `jobs -rp`. WINDOWS: the per-leg host poll
became a resident waiter on the VM (tools/guest/wait-exit.ps1) after
tightening the host cadence measured BACKWARD (0.3s polling: 439
contended vs 390-397 at 1s — each round pays a cmd.exe spawn on
oversubscribed vCPUs), and with the spawn storm gone the pool width
moved to the VM's own 6 (420 contended vs 434 at width 4 — the old
6-loses-to-4 measurement was the storm's artifact, remeasured). iOS:
clipctl RESIDENCY IS IMPOSSIBLE, measured and recorded at
docs/clipboard-plan.md §8 finding 4 — a resident UIPasteboard proxy
is frozen at first access (types, data AND changeCount), so the
spawn-per-read is structural. The residue: linux 395 / ios 414 /
windows 420 contended, matrix 422 — the three bound lanes are within
25s of each other, and the next second comes from real work on all
three fronts at once (per docs/clipboard-plan.md the iOS prompt dance
is semantic), or from a Windows VM with more cores.


## ~~GAP — ContentUnderfill wants a cell box that IS the column box, and two tiers have ink instead (leading-edge half done 2026-08-25; found 2026-08-24, by the review of 01dd633)~~
KEY: ContentLeftUnderfill, ContentUnderfill, table_horizontal_issue, kayaTableHorizontalIssue, kayaTableLeadingUnderfill, kayaCurrentTableSynthesized, expect_column_edges, leading edge, cell box, natural size

THE LEADING EDGE IS DONE, 2026-08-25, on every backend that can hold
it. gtk.rs convicted ContentLeftUnderfill (min_start > 2.0, cells
indented inside their own viewport) and nobody else did, so a table
whose cells start 40px inside their viewport was RED on Linux and GREEN
on Windows, Android and macOS off the same byte-shared
expect_column_edges. Now: winui and Compose carry the clause, and
SwiftUI carries it on the synthesized tier as
`kayaTableLeadingUnderfill`. WinUI also got the PER-LINE END the old
entry named — its `column_edges` collected one global max right edge —
so `ContentUnderfill` is live there too, and `declare_table`'s own
comment about a reserved scrollbar gutter leaving the rows narrower
than the pinned header, which was FALSE when written, is true.

AND THE PER-LINE END WAS WRONG THE FIRST TIME, on the ink instead of
the track, which the windows lane caught the same day: every
table-bearing leg failed with "draws 289dip of a 508dip viewport" (also
281/293, and 533-of-639 on the portfolio), the number tracking each
row's own text. The premise was that `flush_tracks`' Stretch stamp
reaches table cells; IT DOES NOT — that stamp is for FLEX children,
while `table_stamp` writes explicit pixel tracks onto the header and
every row and the cells sit inside them at their own content width.
The same read PROVED the tables were correct while convicting them:
TrackUnderfill and ColumnsOverflow (renamed ColumnsUnreachable when
tables learned to scroll, 2026-08-29) were both silent on those legs, so
the resolved tracks did span the viewport. `column_edges` now reads
each line's OWN resolved ColumnDefinitions (`TableCellBox`,
`table_line_end`) and the three edge numbers no longer share a basis —
`min_start` and `max_end` stay on the INK, which is what can see
content starting inside or spilling past its track, and `min_end` is
the TRACK, which is the only thing a line's end can mean where cells do
not fill. gtk.rs needs no such split because its cells DO fill.
Two things moved with it. WinUI now classifies in the grid's CONTENT
box (both pads off the frame AND off the ink): TransformToVisual's
origin is the PADDING box where GTK4 gives a widget's own space the
content box, so a table with a declared inset would have convicted
itself of starting inside its own viewport. And all four backends share
ONE precedence — track, then the LEADING edge, then the trailing one —
which moved gtk.rs's two pairs: a table displaced at its start also
ends in the wrong place, so conviction on the end named the symptom.

WHAT REMAINS: `ContentUnderfill` — "a line ends short of the viewport" —
is only measurable where a cell's recorded box IS its column's box. GTK
has that (`build_table`/`reattach_table` give every cell hexpand +
halign Fill) and WinUI has it (`flush_tracks` stamps
HorizontalAlignment::Stretch, and the header cell XAML is Stretch).
THE TWO SYNTHESIZED TIERS DO NOT, and it is the INSTRUMENT that is
missing rather than the clause: Compose measures every cell with a bare
`Constraints()` and records `left + size.width`, and KayaTableLayout
places every cell with `proposal: .unspecified`. Both record INK.
MEASURED 2026-08-25 on a real rendered synthesized table (the mac's
width class perturbed in a copy, 1 substitution): a CORRECT table's
lines end 161–177pt short of the viewport, and the amount varies per
line, because it is the last cell's text. The clause would convict
every android and every compact-iOS table leg.

AND ONE QUESTION FOR THE MAINTAINER, on the mac NATIVE tier, where
BOTH clauses stay out. Measured the same day, real NSTableView, 420pt
window: every line starts at 16.0 and ends at 404.0. That 16pt is the
`.inset` style's row inset (KayaSwiftUI.swift sets `.inset`
deliberately), symmetric, and AppKit publishes `style`/`effectiveStyle`
but NO accessor for the amount (web-checked). So the only reference
kaya has for where the cells SHOULD start is the cells' own leading
edge — which `sizeColumns` already reads and clamps at 32pt to size the
columns — and a clause built on it is either VACUOUS (raw inset:
min_start − inset == 0 by construction) or prints a CLAMP RESIDUE (a
40pt indent prints "8pt"). Invariant 3 forbids both, so
`kayaTableLeadingUnderfill` refuses the native tier in one line.
THE FIX THAT WOULD MAKE IT REAL is `tableView.style = .fullWidth`,
which removes the platform inset so kaya owns the leading edge the way
it does on the other three backends — a VISUAL change to every macOS
table, and therefore the maintainer's call, not an agent's. The same
choice decides ContentUnderfill there: with no inset, a line's end is
the last column's trailing edge against the clip, and `frameOfCell` is
already the column rect. Until then the two SwiftUI tiers answer
different halves of one byte-shared step, which is the residue of this
entry and is stated rather than hidden.

CLOSED 2026-08-25, BY RULING: the maintainer keeps `.inset`. The
native look is the reference aesthetic the card work copied onto the
other platforms, and flattening it to win one clause on one platform
would be backwards; the bug class stays covered by the three backends
that measure a column box. So the residues are the accepted state, on
the record: the mac native tier carries neither clause (the platform
owns the leading edge), and the two synthesized ink tiers (Compose,
iOS) carry the leading clause only. A future entry may reopen the ink
half if a tier learns its column slots; this one is done.

NOTE (the diagnostics half closed 2026-08-24): winui and Compose
discriminate their horizontal-containment causes the way gtk.rs does —
a pure classifier, one sentence per cause, each naming the number that
convicts it, with a truth table pinned in winui::tests (the windows
lane's derived count forces it to run) and in
kayaTableHorizontalSelftest (called from expect_column_edges, so every
android table leg runs it). KayaNode.tableContentW, written and never
read, IS that separation on Compose: tableDrawnW is coerced into the
incoming constraints and cannot exceed the track, so a resolved-column
overflow was invisible in every field the verb read. No scene yet
builds an over- or under-filled table, so no lane has printed one of
these sentences live; a scene that narrows a table below its content
would turn the arithmetic-level watched reds into live ones. The
2026-08-25 half was watched the same way — the classifiers lifted out
of the real files and run (both sit behind `cfg(target_os)`, so
`cargo test` on a mac compiles neither), every new branch made to fail
with its substitution count printed, and the SwiftUI branch made to
PRINT through a real NSWindow with KayaTableLayout's column origin
displaced 40pt: "cells start at 40pt inside a 420pt viewport".
That run also broke a pinned Compose claim, which was the point: the
trailing-edge sentence's case carried a leading edge of 5dp, inert
under the old four-cause classifier and a CONVICTABLE state under the
new one, so it had stopped isolating the cause it pins. The input moved
inside the slack; gtk.rs would have convicted it all along.

## ~~HANG — one wedged emulator at t0 of a staged install cost the matrix its verdict~~
KEY: stage_suite_apk, stage_join, STAGE_DEADLINE, staged install, pm list packages postcondition, matrix wall, gate sweep

FIXED 2026-08-24: stage_suite_apk's join was unbounded over an
unbounded `adb install -r`, and since the gate sweep waits on the
Android lane's pid, one wedged emulator cost the whole matrix its
verdict at t0 of a suite, with no partial record for any of the six
units. stage_join bounds it at 300s, names the device and the staging
phase, prints the processes actually alive under the stuck staging
shell (it cannot tell a hung disarm from a hung install, so it does
not claim to), kills them, and writes a TIMEOUT verdict the existing
refusal reports. The install's `pm list packages` postcondition — the
one cliphelper_prepare keeps — is restored: an install that reported
success is re-read before it is believed. Watched both ways: the
pre-fix join still running after 12s, the pre-fix subshell staging a
lost install as OK.


## ~~GAP — the mac native tier ellipsizes where every synthesized tier widens (found 2026-08-26, by the transactions-view captures)~~ — FIXED 2026-08-26 (maintainer's ruling A)
KEY: native ellipsize, content is the floor, hugging column width, recent table truncation, NSTableView column sizing, tableContentWidth, publishContentWidth, represent

The transactions view's recent table shows "2026…" and "$615…" on
macOS while GTK (325px) and Windows (292px) show every date and amount
in full off the same bytes: the hugging left panel measures ~216pt on
mac because NSTableView sizes columns by its own rules and ellipsizes
overflow, while the synthesized tiers hold content-is-the-floor. One
geometry rule, and the native tier answers it differently — either the
mac column sizing learns the floor (feed the measured content widths
into the native column minimums) or the divergence is ruled acceptable
native behavior. Maintainer's call; the captures are the exhibit.

RULED A, 2026-08-26: the mac native tier honors content-is-the-floor.
Three edits in swift/KayaSwiftUI.swift, the first two the ruling's own
halves and the third one measurement forced:

1. THE MEASURED FLOOR IS THE MINIMUM. `layoutColumns` snapshots the
   content widths before leftover distributes and writes them into
   `column.minWidth` in place of the hard-coded 24. The instrumented
   run is what named the mechanism, and it was not the one the entry
   above guessed: layoutColumns had ALREADY measured and assigned the
   right widths (track 178 against a 267.33 content total, assigned
   [92.5, 52.3, 43.03, 79.5]) — AppKit then COMPRESSED the columns into
   the track it was given, which a 24pt minimum permits and a measured
   one does not.
2. THE CONTENT TOTAL GOES UP. `publishContentWidth` writes the floors'
   total onto `KayaNode.tableContentWidth` and KayaNativeTable's macOS
   branch declares `.frame(minWidth:)` from it, beside the
   `.frame(height:)` that was already there — the native answer to the
   synthesized tier's `columnWidths` total, and what widens a hugging
   container instead of cutting the table off at it.
3. A WIDENED COLUMN RE-PRESENTS ITS CELLS. With 1 and 2 alone the panel
   widened to 300pt and Total came good while Date still drew
   "2026-08…": AppKit resizes the cell VIEW, but the SwiftUI content
   already hosted inside it keeps the ellipsis it chose at the old
   width — measured, a 92.5pt cell asking 76.5 still truncating, the
   ellipsis it had picked while the column was 65.17pt. `represent(_:)`
   sets the root view again over the realized band. The control that
   proves the floor arithmetic itself was right: a standalone probe
   that never narrows draws the same string in full at the same 92.5pt.

PROOF, captured on the same held scene at 900x600 (the state is
portfolio.steps:135's `choose select#0 2`, whose shorter net line is
what still narrows the panel on this base — the unfiltered view stopped
truncating when 56315ce added the net line): the panel goes 210pt ->
300pt, and the first row's Date ink goes 62.5pt ("2026-08…") -> 74.5pt
("2026-08-24" in full, the same ink the grown ledger table draws in the
same capture).

GUARDED: `tools/check-table-tier.sh`. Two RUNTIME clauses in the
real-window probe — no column declares a minimum below its measured
content, and a hugging container widens to the table's content — plus a
static pairing clause for the re-present, because that staleness is INK
and no observable the interpreter exposes can tell a stale cell from a
fresh one (the native-undo shape). Three watched negatives, counts
printed, red demanded on every run.

WINDOWING BAND UNCHANGED, and deliberately: both tiers floor on the
widest REALIZED row (native `visibleRows()`, synthesized's banded
subviews), so a wider row outside the band re-floors when it scrolls
in. A whole-model measure would re-create the 41%-of-main-thread walk
the stored epoch exists to refuse.

## ~~QUESTION — a grown table's card ends three ways at the viewport (found 2026-08-26, by the transactions-view captures)~~
KEY: grown table card end, viewport cut row, fill-and-scroll, card clip bottom

CLOSED 2026-08-26 BY RULING, and it is one rule, not three: a table's height is
min(content, max height) — below the max it hugs its last row, at the
max it clips and scrolls (the maintainer's own statement of intent).
That structure holds on every platform today. What differs mid-scroll
is PRESENTATION, and the maintainer ruled it platform spelling, not a
carve-out: desktop draws the card's finished frame at the viewport
edge with rows clipped inside, because that is what the platform's
own card-framed grids do (PowerToys); iOS rides the card on the
content so mid-scroll shows plain clipping and the rounded end
appears only at the true last row, because that is what Settings
does. No code changed under this ruling.

On GTK (card y 67..578) and WinUI (card y 79..614) the grown
transactions ledger's card ends at the viewport edge and cuts the last
visible row in half — correct fill-and-scroll, but exactly the
arrangement the iOS card was moved to the content layer to avoid, so
the three card platforms now answer "where does a grown table end"
differently in one app: iOS's card scrolls with content and ends at
the true last row, GTK/WinUI's cards frame the viewport and slice
whatever row crosses the edge. Options when ruled: accept (desktop
frames scrolling regions; the sliced row is normal desktop scrolling),
or fade/inset the last partial row, or move desktop cards to the
content layer too. Pixels-only either way.

## ~~GAP — a GTK table's viewport has a flat floor the content does not fill (found 2026-08-25, by the card capture round)~~ — FIXED 2026-08-25
KEY: gtk table viewport floor, empty card space, minimum content height, table hugs content

The card treatment made it visible: in the portfolio capture,
Retirement (2 rows) and Savings (1 row) both draw a ~90px table
viewport, leaving 17px and 41px of empty card under the last row,
while Brokerage (3 rows) hugs its content. The card cannot have
caused it — its four CSS properties are paint-only — and the
2026-08-24 pre-card reference capture shows the same heights, so the
floor predates the virtualization milestone. The geometry rule says
content is the floor; a fixed minimum viewport is not that rule.

THE SUSPECT WAS WRONG, and measuring cost less than believing it:
gtk.rs sets no minimum content height anywhere — the floor is THE
VERTICAL SCROLLBAR'S OWN MINIMUM. `Gtk.Scrollbar(VERTICAL)` measures
(58, 58) on the lane's GTK, and GtkScrolledWindow folds that into its
own MINIMUM wherever the policy may show a bar; a minimum outranks the
natural height `propagate_natural_height` asks for, so the viewport
never hugs below it. Measured in the lane's own container with
build_table's exact configuration, and it reproduces the capture to the
pixel: 1 row 58px against 16px of content (42 empty, the capture's 41),
2 rows 58 against 40 (18 empty, the capture's 17), 3 rows 64 against 64
(hugs, as Brokerage did). AUTOMATIC and ALWAYS both carry the floor;
NEVER and EXTERNAL do not; overlay scrolling does not exempt it; and
`max-content-height` does NOT pull the minimum down — measured, the
candidate fix that failed first.

FIXED: `set_table_scrolling` writes the vertical policy from two
numbers this backend already owns — AUTOMATIC when the container GROWS
(its parent's track decides its height, so it must be able to scroll
inside it) or when the CORE's extent exceeds TABLE_MAX_CONTENT, NEVER
otherwise. A table that cannot need a scrollbar stops claiming one, and
the scroller becomes transparent: minimum and natural both become the
content's. The windowed tier is untouched — the transactions view's
15,000 rows (then ledger.steps', the portfolio's since 2026-08-26)
and varied's grown tables keep AUTOMATIC and their bounded viewports —
and `check-gtk.sh`'s census holds both the policy write and the grow
read, each watched failing. The 58px measurement is in docs/traps.md
("A GTK table's viewport floor is the scrollbar's own minimum"), which
is where the next session will look.

## ~~GAP — only macOS delineates a table's end; GTK and WinUI run CASH straight into the account total (maintainer, 2026-08-24)~~
KEY: table end boundary, closing rule, table card, boxed-list, apron, Account total, synthesized header, inset-grouped, KayaTableCard, segmented grouped container, segmentedShapes, KayaTableSegment, header rule, HorizontalDivider, header hairline

CLOSED 2026-08-25: the maintainer ruled CARDS (flat: fill, 1px
stroke, rounded corners, no shadow, no elevation) after a survey of
shipped GNOME and Windows apps, and inspected and approved the
round-two captures — interior inset 12px per platform metrics, small
GTK tables hugging their rows after the 58px scrollbar-minimum fix
(its own struck entry, one above). Implemented on GTK, WinUI and
Compose, held by tools/check-table-card.sh; macOS keeps the native
interior. THE LAST TWO SPELLINGS WERE RULED THE SAME DAY, both of them
the platform's GROUPED idiom rather than the desktop card: the iOS
synthesized tier takes the INSET-GROUPED card, and Compose the
SEGMENTED GROUPED CONTAINER after the Android research below. Both
implemented — the sections below.

Seen on the first cross-platform portfolio capture set: on GTK and
WinUI the last row's text and the "Account total" label below it read
as one run of text, because those lowerings draw a table's OPENING
grammar (bold header, hairline under it, hairlines between rows) and
never the closing half. macOS delineates only as a side effect of the
native widget — NSTableView's base-color interior against the window
plus the 5pt apron. Ruled a WIDGET issue, not app styling: if the guest
had to add the divider itself, every app would need per-platform
styling knowledge, which is the knowledge the lowering exists to
absorb. The rule when built: a table bounds its own extent — one
semantics, platform spelling (macOS has it; GTK/WinUI/Compose either
complete the hairline grammar with a closing rule and a small bottom
margin, or adopt the platform card idiom — Adwaita boxed-list, Fluent
layer card — with the choice made per platform, not per app). Compose
is in scope on the same reasoning even though the portfolio is not on
mobile yet; table.steps runs there. Pixels-only, so the camera and the
portfolio captures hold it, and the change lands with fresh captures
inspected. DEFERRED by the maintainer until after the six-binding
breadth fan-out.

RULED 2026-08-25: the CARD, on all three, and FLAT — fill, a crisp 1px
stroke, rounded corners, zero blur and zero elevation. The mac tier is
not touched. The card is the CONTAINER only: row heights, cell metrics
and header metrics do not move, because the dense case is the one this
has to survive.

IMPLEMENTED, three spellings of one rule, and in all three the card is
PAINT rather than BOX — nothing it draws is in the layout, which is what
keeps every cell edge where expect_column_edges already found it:
- GTK: `.kaya-table-card` on the For container — `@card_bg_color`, a
  12px radius and a 1px `@borders` outline at `outline-offset: -1px`.
  `outline` and not `border` for two MEASURED reasons, both in
  docs/traps.md ("A GTK table card is paint, never box"): a border here
  costs the content box 2px against a track measured from the parent,
  and a container's `inset` prop is already a border on that same
  widget, where the two do not add — one wins silently.
- WinUI: TABLE_CARD_XAML, a Grid carrying
  CardBackgroundFillColorDefaultBrush, a 1 DIP CardStrokeColorDefaultBrush
  and OverlayCornerRadius (the 8 of Fluent's family, the one the design
  language gives CARDS), inserted at child 0 and spanning the header, the
  rule and the scroll host — behind them, not around them, since a
  BorderThickness on the container itself would take 2 DIP out of the box
  `table_stamp` and `column_edges` divide.
- Compose: `Modifier.background(surfaceContainer, 12.dp)` +
  `Modifier.border(1.dp, outlineVariant, 12.dp)` on KayaTableSurface,
  outside the verticalScroll so the card frames the viewport. Both are
  draw modifiers; neither measures. SUPERSEDED the same day by the
  segmented grouped container — the section at the end of this entry.

NO SCENE CAN FAIL THIS, so tools/check-table-card.sh is the wall: the
card present in all four, flat (strokeless and borderless on the two
grouped tiers), coloured from platform tokens rather than literals, on
the CONTENT layer where iOS and Compose demand it, and held OFF the
mac's native tier, with 58 watched negatives. No .steps file and no
expected string moved.

THE INTERIOR CAME BACK FROM THE FIRST SIGN-OFF (maintainer, 2026-08-25):
"the linux and windows tables don't look good. the cards have no
inset/margin/padding, so the text is flush against the edges. Look at how
macos has that in its natural table." macOS's number is 16pt — the
`.inset` NSTableView's row indent, measured on this host by the
leading-edge underfill work at cells starting 16.0 into a 420pt
viewport. So the card has an interior now, each platform's own:
- GTK 12 horizontal / 8 vertical. 12 is ADWAITA'S, read off a real
  AdwActionRow in a `.boxed-list` (content starts at x=12); the vertical
  is kaya's 8, because Adwaita gets a row's vertical room from
  `min-height: 50px` and row density may not move.
- WinUI 12 all round (Fluent's card content inset; `pad` is one number
  for four sides and splitting it would mean touching every `2.0 * pad`
  in the table's arithmetic).
- Compose 16 horizontal / 8 vertical (Material's own content inset) —
  the two numbers survive the segmented ruling below, one interior per
  segment now instead of one around the whole card.

AND IT GOES THROUGH THE PATH THE INSTRUMENTS SUBTRACT, which is the only
reason a padded card does not convict itself:
- GTK: `padding` on the container. GTK4 puts the widget's coordinate
  origin at its CONTENT box, so the cells stay at 0 and `column.width()`
  shrinks with them (measured). The one outer-box number left is the
  assigned track, and `table_horizontal_track` takes the card's own span
  off it — measured off the widget by `css_inset_span`, never re-derived.
- WinUI: the CONTAINER's Padding, via `container_padding`, because that
  is the number `table_stamp`'s `inner` and `column_edges`' content-box
  frame already subtract. The card is a CHILD of that container, so it
  carries a NEGATIVE margin of the same size and sits back out at the
  box the guest's own inset leaves it.
- Compose: `Modifier.padding` ABOVE the `onGloballyPositioned` that
  reports the viewport, so the viewport IS the padded content box.
  RE-ROUTED by the segmented ruling below — the interior is laid out
  inside each segment now, so the track is corrected instead and the
  reported viewport is inset to the cells' box.
Pinned in all three truth tables — `gtk_table_padded_card_convicts_nothing`,
`a_padded_card_convicts_nothing`, and four Compose self-test claims — each
watched failing against a basis that forgets to subtract.

ROW HAIRLINES SPAN THE PADDED CONTENT WIDTH, not the full card, on all
three. Adwaita's boxed-list bleeds its separators to the card edge, but
the divider is a CHILD of the padded container on every one of these
backends: bleeding it would mean moving the padding somewhere that shifts
every cell off zero, which is the one thing this may not do. Stated so
the next reader knows it was chosen, not inherited. COMPOSE LEFT THIS
RULE ALTOGETHER on 2026-08-26: its table draws no hairline at all now,
because the segment gap is the separator (the section at the end).

THE iOS SYNTHESIZED TIER IS INSET-GROUPED (maintainer, 2026-08-25) — the
Settings look rather than the desktop family's flat card, and the mac is
untouched, its native tier delineating from NSTableView's own interior.
Two modifiers in swift/KayaSwiftUI.swift, worn by KayaSynthesizedTable
alone: `KayaTableCardFace` is the card — a rounded
`secondarySystemGroupedBackground` fill at radius 10 over an interior of
16 horizontal / 8 vertical, NO STROKE, because iOS parts a card from its
page by background contrast and never by an outline — and
`KayaTableCardGround` is the page under it, `systemGroupedBackground`
behind a 16pt band. The colours are the SEMANTIC ones, so dark mode is
free. Every number is zero on macOS, because the instrument subtracts what
they say the card spends.

THE FACE IS CONTENT, NOT VIEWPORT, and that came back from the capture
(maintainer, same day): "is the ios table in this scene meant to have the
white inset background stretch all the way to the bottom of the screen?
like past the bottom of the last row of the table?" It was — the first
implementation painted the card as the scroll viewport's background, so a
three-row grown table ran white to the bottom of the phone while its rows
stopped near the top. An inset-grouped card belongs to the CONTENT layer:
the face goes INSIDE the scroll clip, on the stack the windowing machinery
already sizes to the collection's whole extent (top spacer + band + bottom
spacer), so a short table's card ends at its last row with the grouped
ground below it, and a tall one's card spans the virtual content and
scrolls with the rows — ONE rounded rectangle, so a reader mid-list sees
straight edges and corners only at the true ends. The GROUND stays outside
the clip: the band frames the table's extent and may not scroll away.

THE GROUND IS THE TABLE'S OWN REGION, NOT THE WINDOW'S: painting the
window grouped would move every non-table scene's pixels on the phone, so
the scoped half is the band around the card. That band is not decoration —
`secondarySystemGroupedBackground` IS white in light mode, so a strokeless
card on the default page ground would have no edge at all, and the ground
behind it is the whole boundary.

AND IT TOO GOES THROUGH THE PATH THE INSTRUMENT SUBTRACTS, in two layers
that add up to one pad: an 800pt assigned track gives a 768pt scroll clip
(the band, outside) and a 736pt cells' box (the interior, inside, on the
content), and `kayaTableContentTrack` takes both off the ASSIGNED track —
which KayaTrackReader reads at the flex cell's OUTER box, GTK's trap one
platform over. Because the interior now scrolls INSIDE the clip, the clip
is no longer the cells' box: `kayaTableCellsBox` insets it, and BOTH of a
grown table's viewport writers — KayaTableViewportReporter and
KayaSynthesizedWindow's own report — go through it, or the leading clause
reads a table starting 16pt inside its own viewport. Pinned in the tier's
own truth table (tools/checks/swiftui-table-tier.swift): the clip yields
the cells' box, that box matches the content track, the CLIP does not, an
UNCARDED tier keeps its whole track, cells flush underfill nothing, and
the same cells read at the clip report 16pt of interior. Each watched
failing — the subtraction deleted, the inset deleted, the underfill
silenced — with the substitution count printed.

COMPOSE IS THE SEGMENTED GROUPED CONTAINER (maintainer, 2026-08-25,
after an Android research pass): a card around a table is not what any
current Google phone surface draws. The idiom is the filled, borderless,
shadowless grouped container that HUGS its rows — Settings on Android 16
QPR1, and since material3 1.5.0 a first-class API, `SegmentedListItem` +
`ListItemDefaults.segmentedShapes(index, count)`, with the non-segmented
list item deprecated. A single frame held open around a whole scrolling
list is the treatment Google Drive shipped and then withdrew. So the
Compose bullet above is superseded in three ways at once:

  - THE BORDER DIES. Nothing in the grouped idiom draws one, and
    outlineVariant + 1dp was Compose's OutlinedCard — spec-legal, and the
    one variant no shipped Google phone surface uses as a list frame. Fill
    stays `surfaceContainer` (what Google's own SegmentedListItems sample
    passes) and elevation stays 0, which is two of the three M3 card
    variants' own token anyway.
  - TWO SEGMENTS, corners BY POSITION. The header row is one container,
    then the gap, then ONE container for every body row. The numbers are
    androidx's, read out of the tokens rather than guessed:
    `ListTokens.ContainerShape` = CornerLarge = 16dp for the group's outer
    pair, `ItemContainerExpressiveShape` = CornerExtraSmall = 4dp at the
    boundary between segments (the base shape `segmentedShapes` leaves on
    the middles), and `ListItemDefaults.SegmentedGap` = 2dp between them.
    Spelled with two RoundedCornerShapes and plain background modifiers,
    NOT by adopting the API: android/kaya/build.gradle.kts pins
    compose-bom 2024.10.01 = material3 1.3.1, and a card is not worth a
    dependency bump (tools/check-pins.sh).
  - THE CONTAINER IS CONTENT, iOS's correction one platform over. The two
    segments are laid-out CHILDREN of KayaTableSurface's own Layout — which
    already sizes itself to the collection's whole extent (top spacer +
    realized band + bottom spacer) — so a short table's container ends at
    its last row with the page ground below it inside the table's region,
    and a tall one's spans the virtual content and scrolls with the rows.
    ONE rounded rectangle per segment, so a reader mid-list sees straight
    edges and corners only at the true ends. Nothing on the modifier chain
    paints or pads any more; a fill there is the scroll VIEWPORT's.

CHILDREN AND NOT A MODIFIER because no Compose modifier can draw two
separated shapes, and that costs two invariants a modifier would not have
needed, both held by the gate: the segments are the LAST TWO children
(every index in the measure block — the cells' sublist, the bottom
spacer, the segments themselves — counts from the end) and the FIRST TWO
PLACED (placement order is draw order, so a segment placed after the rows
paints over them and the lane sees a blank table — WinUI's
appended-instead-of-inserted card in this backend's spelling).

AND IT TOO GOES THROUGH THE PATH THE INSTRUMENT SUBTRACTS. The interior
is laid out inside each segment now rather than padded outside the
scroll, so the clip is the segments' outer box and no longer the cells':
`kayaTableCellsBox` insets the reported viewport by the interior, and
`tableTrackW`/`tableDrawnW` take the same span off the track — GTK's
`css_inset_span` and Swift's `kayaTableContentTrack` in this backend's
spelling. A raw track convicts every carded table of a 32dp underfill it
does not have. Pinned in `kayaTableHorizontalSelftest`, which
expect_column_edges runs before it reads any geometry: the carded clip
yields the cells' box, an uncarded one is its own box, that box read in
itself is silent, and the same table read at the CLIP is a TrackUnderfill.
`kayaTableHorizontalIssue`, the windowing machinery, every row density and
every cell and header metric are untouched. ONE NUMBER DOES MOVE, and it
is named here rather than left for someone to find: the interior no longer
pads the scroll clip, so `tableViewportH` and `window.viewportPx` are the
table's whole region now instead of that region minus 16dp — a taller
viewport, which is the true one. The hug clause does not notice (a
hugging table's clip IS its content height, before and after), and the
band the core seeds may realize one more row.

STILL OPEN, and the only thing left: the captures. The entry says the
change lands with fresh captures INSPECTED, and the maintainer signs
those off — the iOS card and the Compose segments included, neither of
which has had its sign-off. The radii are deliberately per-platform (12
GTK / 8 WinUI / 10 iOS, and 16-outer with 4-inner on Compose, where the
corner is a function of position rather than one number), which is the
"per platform, not per app" half of the rule.

AND THE HEADER RULE DIES WITH IT (maintainer, 2026-08-26, off the
round-six capture). The first pass left the `HorizontalDivider` where it
had always been, inside the header segment, and flagged it as a question
because removing it moves `rowsTop`. The capture answered: the phone drew
TWO separators nine pixels apart and of DIFFERENT WIDTHS — the 1px
hairline inset 16dp each side at y=48, then 8px of orphaned header fill,
then the full-bleed 2dp gap. In the Settings idiom the GAP is the
separator and a segment carries no internal hairline, so the divider is
gone from the Compose table's content. GTK's, WinUI's and iOS's hairlines
are native grammar and are untouched.

WHAT MOVED, exactly, and why every instrument stays honest:
  - The content lambda lost one child, so every index in the measure block
    shifted by one: the top spacer is `measurables[cols]`, the cells start
    at `cols + 1`, and the three tail indices (bottom spacer, header
    segment, body segment) are unchanged because they count from the END.
  - `headerSegH` = padY + headerH + padY, where it was padY + headerH +
    rowGap + dividerH + padY. So `rowsTop` and `tableContentH` each shrink
    by rowGap + dividerH — the header segment is now exactly its interior
    and its text, which is the idiom.
  - HORIZONTALLY NOTHING MOVED AT ALL, and that is the load-bearing half:
    the divider carried no `Modifier.edge`, so it was never in
    `cellEdgeX`/`cellEdgeRightX` and never in expect_column_edges' `left`
    or `right`. `tableTrackW`, `tableDrawnW`, `tableContentW`, both
    viewport writers and `kayaTableCellsBox` are byte-identical, so the
    pad != 0 case is the same case (re-proven anyway, by running the truth
    table lifted out of the real file).
  - The window reports stay self-consistent: `rowsTopPx` is written from
    the same `rowsTop` the placement uses, and `contentTopOf` and
    `visibleRange` read only that field and the extents this layout
    measured. Nothing estimates a header height anywhere.
  - expect_fills' hug clause: `tableContentH` and `tableViewportH` both
    shrink together on a hugging table (its clip IS its content height),
    so the clause cannot flip.
tools/check-table-card.sh pins the ABSENCE, read out of the table's own
content lambda so the file's four other HorizontalDividers (menu
separators, section rules) are none of its business, with the rule
spliced back exactly where it stood as the watched negative.


## ~~GAP — Haskell cannot declare a nested RECORD collection (found 2026-08-24, by the breadth fan-out)~~ — CLOSED 2026-08-24
KEY: collectionOf Build-only, RecordCollection, nested record rows, Tpl collection, haskell dynamic tables, CollectionHandle

**Done, both halves, no carve-out.** `collectionOf` is a method of
`Declare` now, so it stands in the TEMPLATE zone as well as the live one
(`collectionOf :: KayaRecord a => Proxy a -> m (RecordCollection a)`) —
which is what a nested collection needs, since it may only be declared
inside the template scope. And `at` is a method of `CollectionHandle`
with instances for `Collection` and `RecordCollection a`, so narrowing a
handle to one stamped copy keeps the element type and
insertRecord/updateRecord/patch/recordItems can address it. Rust's
`Collection<T>::at` and Python's `Collection.at` preserve the type under
one name; a class is Haskell's spelling of the same thing, and it is what
this file's own header asks for ("a constructor identical in both zones
keeps one name and dispatches on it"). No existing call site moved: all
42 Haskell guests typecheck unchanged.

tools/checks/haskell-table/NestedTable.hs now builds a nested table whose
cells are `field @"symbol" @Position` / `field @"shares" @Position` and
fills one copy through `positions \`at\` VStr "brokerage"` — the comment
that named this gap is gone with it.

THE WALL IS ON THE BUILD, not only in a gate: KayaApp.hs carries
`-Werror=missing-methods` beside `-Werror=incomplete-patterns`, because a
`Declare` method left out of ONE instance is a warning in GHC's default
set — it compiles, ships, and dies at the use site. That is exactly how
`collectionOf` could become live-zone-only again. Beside it,
check-sugar-surface's haskell blocks grew five watched reds the compiler
cannot give (a record collection born with the SCALAR schema and a key
silently dropped on the way to the copy both typecheck) plus two more
fixture typechecks; tpl-surfaces gained the two points `nested record
collection` and `record instance addressing` — read for Haskell alone at
first, for ALL EIGHT since 2026-08-25 (`RECORD_ZONES`, the entry below),
which is where `record_haskell` reads them now.

## ~~GAP — five more bindings cannot declare a nested RECORD collection either (found 2026-08-24, closing the Haskell one)~~ — CLOSED 2026-08-25
KEY: CollectionOf Tx-only, collection_of, collection(of:), RecordCollection At, typed instance addressing, nested record rows

**Done, both halves, all eight, no carve-out.** A nested table's rows
carry named fields in every binding now. Nothing moved in a generator —
bindings/go/records.go, bindings/csharp/KayaRecords.cs,
bindings/java/dev/kaya/KayaRecords.java and bindings/swift/KayaRecords.swift
are HAND-WRITTEN: tools/gen-guests.sh's GENERATED list covers only the
per-guest `<Rec>Kaya` files under guests/, never the binding libraries.
- Go: free `TplCollectionOf[K, T](t *Tpl)` beside `CollectionOf`, over
  one shared `newRecordCollection`; `RecordCollection.At` SHADOWS the
  promoted untyped one and keeps K and T.
- C#: `CollectionOf<T>(this Tpl)` beside the `Tx` extension (Tpl.Tx is
  internal for it), plus `RecordCollection<T>.At`.
- Java: `collectionOf(Tpl, Class)` AND `collectionOf(RowSurface, Class)`
  — the row surface is the zone handle a Java scene actually holds —
  plus `KayaRecords.Collection.at`. `KayaApp.Tpl.tx()` is package-private
  for the first.
- Swift: `KayaTpl.collection(of:)`, declared in KayaApp.swift because
  `KayaTpl.tx` is `private` and Swift's private is file-scoped; plus
  `KayaRecordCollection.at`.
- OCaml: `record_at` (no overloading, so the typed narrowing is named),
  and `module Tpl`'s `collection_of` re-export beside `collection`, so
  the zone's own surface carries it rather than only the ambient
  top-level.
- Rust, Python, Haskell were already both-halves; verified in source, not
  assumed.

THE CENSUS READS ALL EIGHT NOW. The two points the Haskell close added
were `TABLE_POINTS["haskell"]` alone; they are `RECORD_POINTS` in
tools/tpl-surfaces.py with a reader per binding (`RECORD_ZONES`), and
table_haskell's two blocks moved verbatim into `record_haskell`. The
failure sentence is unchanged, so check-sugar-surface's (c2c) Haskell
expectations still hold. Its new block (c2e) watches FOURTEEN census reds
— both points in the other seven — each a shape that COMPILES and lies: a
template-zone constructor opening its own transaction, a narrowing that
keeps the type and addresses the PARENT, the promoted untyped `At`, a
Python collection born without the open-For edge.

AND EVERY BINDING HAS A RUNNING OR COMPILING EXERCISER, each watched
failing: Rust's `a_nested_record_collection_carries_its_schema_and_
addresses_the_copy` (cargo test), Python's five checks in
kaya_app_checks.py, Go's `TestANestedRecordCollectionIsDeclaredInThe
TemplateAndAddressedTyped` (check-abort's `go test`), C#'s
`NestedRecordTable` in guests/csharp/AbortCheck.cs, OCaml's block in
bindings/ocaml/checks/abort_check.ml, Java's `nestedRecordTable` in
tools/java-typecheck.sh, Swift's tools/checks/swift-nested-table.swift
(now record-typed end to end) and Haskell's NestedTable.hs.

STILL ONE TIER UP, and not this entry: the KayaGen generators emit the
record-collection FACTORY for the live zone only — `TableItemKaya.
collection(KayaApp.Tx)`, `tableItemCollection(_ tx: KayaAppTx)`,
`<Rec>Kaya.Collection(Tx)`. A guest reaches the template zone through
the binding-level constructor above; the generated sugar has no zone
twin. That is the same shape as the C# entry below's open half and
belongs with it.

The Haskell entry above was written as a Haskell gap. It is not: the
sweep its fix required found the SAME two halves in five more bindings,
each read in the source rather than assumed.
- Go: `CollectionOf[K, T](tx *Tx)` (bindings/go/records.go:129) takes a
  `*Tx`, and `Tpl.tx` is unexported, so a template body cannot reach it;
  `RecordCollection[K, T]` EMBEDS `Collection`, so `rc.At(key)` returns
  the untyped `Collection` and T is gone. Go methods take no type
  parameters, so the fix is a free `TplCollectionOf[K, T](t *Tpl)` beside
  the existing one, plus a type-preserving `At` on RecordCollection.
- C#: `KayaRecords.CollectionOf<T>(this Tx tx)` (KayaRecords.cs:279) is a
  `Tx` extension; `RecordCollection<T>` has no `At`.
- Java: `KayaRecords.collectionOf(KayaApp.Tx tx, Class<T>)`
  (KayaRecords.java:480); `KayaRecords.Collection<K, T>` (:229) has no
  `at` — only the untyped `KayaApp.Collection.at` (KayaApp.java:2169).
- Swift: `collection(of:)` is an `extension KayaAppTx`
  (KayaRecords.swift:253); `KayaRecordCollection<T>` (:117) has no `at`.
- OCaml: HALF ONE IS ALREADY THERE — `collection_of` (kaya_app.ml:1198)
  runs on the ambient `the_tx ()` and records the open-For edge, so it
  stands in the template zone as it is. Half two is missing: nothing
  yields a record collection at a key path, and a guest would have to
  rebuild the record by hand from `record_handle rc`.
Rust (`Tpl::collection<T>` + `Collection<T>::at`), Python
(`kaya.collection(Record)` in both zones + `Collection.at`) and now
Haskell have both halves. Nothing is BLOCKED by this — the untyped
spelling reaches the wire in every language — but a nested table's rows
carry named fields in three of eight, which is invariant 1's question and
not a spelling difference. The Haskell close shows what the census teeth
look like (tpl-surfaces' two new points, and the compile wall that makes
a zone-missing method a build error rather than a warning).

## ~~GAP — C#'s generated row facade cannot spell a nested table (found 2026-08-24, by the breadth fan-out)~~
KEY: <Rec>Row facade, kaya-csgen typed row sugar, nested typed For, NOT_FORWARDED_CSHARP

FIXED 2026-08-24, both halves in one slice. tools/kaya-csgen emits the
nested-For vocabulary onto every `<Rec>Row` — `Collection()`, `Each`,
`ForEach` and the `Columns` that names the Node `Each` hands back — and
a `Each(Tpl t, RecordCollection<T> c, Action<<Rec>Row> body)` twin
beside the live `Each(Tx, …)`, so a nested typed For's body holds the
row façade rather than the raw zone. Those four names left
NOT_FORWARDED_CSHARP, exactly as `forEach` left NOT_FORWARDED_JAVA when
dynamic tables landed and for the same reason. THE CENSUS GREW TWO
TEETH: facade_csharp now reads `Collection`-returning members too
(`Collection()` was invisible on BOTH sides, so a façade missing it read
LEVEL — the name-set-blindness trap keyed by return type instead of
arity), and `twins_csharp` demands `<Rec>Kaya.Each` for BOTH zones in
every generated file carrying a row façade, refusing a verdict below
three surfaces. Seven watched census reds (check-sugar-surface's (c4)
block) and six watched exerciser reds — four of them COMPILE-TIME, since
guests/csharp/AbortCheck.cs's FacadeNestedTable spells the dashboard
shape through the façade alone and does not build without the forwards.
WHAT IS STILL OFF THE LIST, now with a reason of its own rather than a
grouping: `When` and `ContextMenu`, both of which Java's `RowSurface`
forwards. Neither is the nested-table vocabulary; the divergence is
recorded here and in the generated header rather than blessed.
STILL OPEN IN C#, one step up: a typed OUTER For cannot open a typed
NESTED one — the twin takes a `Tpl` and the façade's is private, so from
a `<Rec>Row` the nested body is the raw zone.
JAVA'S HALF CLOSED 2026-08-24 (the idiom ruling: the callback `forEach`
died and the one For form is the eager `rows` Iterable), and the shape
that closed it is available to C# rather than being a maintainer's call
after all: the generated nested overload takes THE ROW SURFACE, not the
zone — `<Rec>Kaya.rows(KayaApp.RowSurface row, Collection c)` — and the
protected `tpl()` is read by `KayaRecords`, which sits in the row
surface's OWN package and so needs nothing published. C# wants the same
move (an `Each(<Rec>Row, …)` overload reaching the façade's private
`Tpl` from inside the assembly) and the entry stays open until it has
one. tpl-surfaces' `twins_java` holds Java's two zones the way
`twins_csharp` holds C#'s.

As filed: two pre-existing halves, both recorded with one-line fixes in
the breadth agent's report: the generated `<Rec>Row` foreach facade has
no Each/ForEach/Collection and a private Tpl, so a nested table cannot
be spelled through it at all; and `kaya-csgen` emits typed row sugar for
the live zone only, so a nested typed For's body falls back to the raw
`Tpl`. The hand-written `Tpl` spelling works — this gap is about the
generated sugar tier reaching parity. `Columns` sits in
NOT_FORWARDED_CSHARP with its reachability reason until then.

## ~~DECISION — one id space for widgets and template nodes? (raised 2026-08-24)~~
KEY: id collision, next_node, separate counters, set_column_headers target, sort_requested tag, one id space

CLOSED 2026-08-24 — decided and built the same day (maintainer: "i agree with
your recommendation so go ahead"): one number sequence per app. The
core's Rust surface and all seven hand-written bindings mint template
nodes from the widget counter; six bindings deleted the node-counter
FIELD outright, so a second sequence no longer compiles. Each binding
carries a contiguous-run proof (1,2,3,4 — not mere inequality, which a
pre-advanced counter satisfies vacuously; measured in Python), watched
red once by construction. Haskell's proof is the deleted field failing
the build — its handles export abstractly, so no runtime probe can see
an id. scene.rs's collision walls stay as the backstop that should
never fire. DESIGN.md's Binding conventions now state the rule. The C
floor's hand-authored guests were renumbered onto it 2026-08-25, and
tools/check-c-ids.sh refuses a re-collision from 2026-08-26 (chore
entry below).

The Haskell breadth probe manufactured a widget-id/template-node-id
collision and showed set_column_headers resolving the wrong space.
FIXED the same day at two levels: keys now resolve in the template
space alone, and the core refuses a live For container and a nested
For template node that share a number, loudly at declaration, both
directions watched red first (scene.rs). What remains is the design
question the walls make visible: bindings allocate widget and node ids
from separate counters over one u64 target field, so the collision is
always one allocation away and only the wall stands between. Unifying
the counters (one id space per app) would delete the class; it touches
every binding's allocator and is the maintainer's call. Until then the
walls hold.


## ~~CHORE — the C floor's hand-authored ids still overlap the two spaces (2026-08-24)~~
KEY: C guests renumber, id space overlap, explicit floor, template-declaring guests

SWEPT 2026-08-25. All eight template-declaring C guests — a11yrows,
entry, feed, menus, milestone2, reorder, todos, undo, found by grepping
guests/c for kaya_tx_template_end rather than from a list — restarted
their N_ run at 1 inside the W_ run; every N_ id now continues the widget
counter, so no number on the floor names both a widget and a node.
Signal, collection and menu-item numbers are untouched, being spaces the
rule exempts. The prose went with the numbers, since the floor is the
documentation: undo.c's comment argued FOR the collision ("a node id and
a widget id may collide as NUMBERS and nothing is wrong"), and all eight
now name the shared space and point at DESIGN.md's Binding conventions.

NO OUTPUT BYTE MOVED, proven rather than asserted. bindings/c/kaya_wire.h
is header-only static inline packers, so each guest was linked against a
stub libkaya and the transaction build_scene submits was captured before
and after the renumber: identical length in all eight, and every differing
byte an 8-byte id field carrying exactly one mapped (old -> new) pair —
no string, kind or record head moved. The comparator was watched red on a
doctored byte first, and refuses a guest showing zero differences.
check-steps.sh passes unchanged; no .steps file or expected string moved.
All 17 C guests build (guests/c/Makefile, the whole SCENES list).

GATED 2026-08-26, the half the renumber left open: nothing refused a C
guest that re-collided the spaces, because scene.rs keeps `widgets` and
`template_nodes` as separate maps and the collision is therefore legal
at the core — it renders correctly and ships, which is exactly how all
eight overlapped for months under green lanes. tools/check-c-ids.sh is
in the fast sweep now. It reads the CALLS, not the `W_`/`N_` names:
comments and string literals are blanked, then create_widget /
create_for / create_when / template_end are walked in source order
against a template-nesting depth, which is scene.rs's own division of
the two maps. A name-keyed census could never have served — the numbers
in guests/c/feed.c's N_POSTS and guests/c/reorder.c's N_ITEMS are row
COUNTS that collide with real widget ids in their own files, so it
would refuse both guests today. Findings name the guest, the number and
both declaration sites; an id that will not fold to a number is a
finding too, never a skip; and the roster and id counts are printed
every run with a floor beneath them. THE FIRST NEGATIVE IS THIS ENTRY'S
OWN BEFORE-STATE — the eight guests one revision before the renumber,
read out of git, all eight refused — beside seven doctored-copy
negatives, one of which plants the collision inside a comment and a
string literal and demands the census stay GREEN.

The one-id-space rule (DESIGN.md Binding conventions) is enforced in
every binding's allocator; the eight template-declaring C guests
hand-author their numbers and overlap the spaces. The lanes are green —
none of the overlaps is the walled live-For/template-node kind — so
this is documentation debt, not a defect: the C floor exists to teach
the explicit calls, and it currently teaches the pre-rule numbering.
Renumbering is mechanical, only the lanes verify it, and it should ride
the next C-floor touch rather than its own matrix run.


## ~~BUG — one build transaction over ~160 table rows ABORTS the app on the interpreter platforms (measured 2026-08-24)~~
KEY: pump buffer 64 KiB, apply batch exceeds, capi.rs abort, interpreter ring cap, chunked inserts, transport wall

FIXED 2026-08-24, the same day, by the repo's own precedent (traps:
"THE FIX WAS TO DELETE THE CAP, NOT RAISE IT"): kaya_next_commands now
hands out a borrowed pointer to the core-owned batch — no buffer, no
cap, and a stale reader fails to compile. All four readers moved; mac
passes 25,000 rows in one transaction (chunking now buys nothing);
three cargo-level guards including a no-size-literal census of both
interpreters' pump bodies, five watched negatives.

Both interpreter dylibs read applies through a fixed 64 KiB pump buffer
(SwiftUI `let cap = 64 * 1024`, Compose `ByteArray(64 * 1024)`), and
crates/kaya/src/capi.rs asserts when a batch exceeds it: one build
transaction inserting 161 four-column rows (408-416 wire bytes each)
kills the process on macOS, iOS and Android before any harness step
runs — byte-exact, load-independent, measured on all three
(docs/measurements/choke-*-2026-08-24.txt). The GTK and WinUI pumps
have no such cap, so the same guest bytes run on Linux and abort on
mac: a uniform-semantics break in the transport, not the For. The fix
direction is a growable or streamed pump (or a core-side batch split);
guest-side chunking is the workaround the choke bench used, not the
answer. FIRST of the pre-virtualization fixes (maintainer 2026-08-24):
the portfolio's transactions view dies on this wall today at 2,645
rows.

## ~~BUG — WinUI's child append is quadratic: reindex on every AddChild (measured 2026-08-24)~~
KEY: reindex RowDefinitions, AddChild quadratic, COM round trips, winui append, N squared

FIXED 2026-08-24: ChildOrder (winui/order.rs) makes the order private
so a structural change cannot skip the mark, and flush_tracks drains
once per batch — also killing the Destroy and grow-prop N² scans and
deferring reflow_grid's. Measured on the lane's VM against a
sha-verified pre-fix dll: N=2500 5.3s -> 0.75s, N=10000 82.9s -> 4.5s,
the old 12,000-row choke now 50,000 in 13.6s. Placement equality
frozen in winui::tests (lane count 10 -> 11), six watched negatives.

`ApplyOp::AddChild` in crates/kaya/src/winui/mod.rs ends every append
with `reindex(core, parent)`, which clears the parent Grid's whole
RowDefinitions, rebuilds one per existing child and re-stamps
Grid::SetRow on every existing child — N appends cost N²/2 WinRT round
trips, measured flat at ~1.5 µs per call pair from N=500 to 10,000
(docs/measurements/choke-windows-2026-08-24.txt). Defer the reindex to
batch end. This is why Windows' choke sits at 12,000 rows; fixing it
moves the platform's whole baseline and must land BEFORE the
virtualization slice so the before/after measures virtualization, not
this bug.

## ~~BUG — a wedged main thread produces NO verdict: the step deadline is consulted only after a blocking hop returns (measured 2026-08-24, four platforms)~~
KEY: POLL_DEADLINE, main.sync, on_ui_read recv no timeout, no verdict, harness loses legibly, wedged main thread

FIXED 2026-08-24 in all three harnesses under one rule: a watchdog
thread gives every step a 60s ceiling and guarantees exit within 3s of
any published verdict (above Android's 20s ax extension, below
validate-mac's 120s kill; KAYA_STEP_CEILING_MS drives the real path in
tests). Every branch watched printing, every silence watched first.
Held by the new tools/check-harness-ceiling.sh — gate 43 — since no
shared scene can fail it.

The harness's expect deadline is checked after an attempt returns, and
an attempt hops to the platform main thread with no timeout (SwiftUI
`DispatchQueue.main.sync`; WinUI `on_ui_read` blocks on a bare
`rx.recv()`; GTK's expect blocks in a main-thread hop). An app whose
main thread is saturated therefore prints NOTHING — no FAILED, no
timeout sentence — until something external kills it (the bench's own
120s cap; on the windows lane wait-exit.ps1's 290s leg deadline).
Measured on macOS, Linux, Windows and iOS
(docs/measurements/choke-*-2026-08-24.txt). The harness must lose
legibly here: a deadline on the HOP (or a watchdog thread that
publishes the timeout verdict) in all three harness implementations.

## ~~BUG — the Swift binding's insert is quadratic (measured 2026-08-24)~~
KEY: modelSet linear scan, swift insert quadratic, bindings/swift KayaApp insert

FIXED 2026-08-24 — and the ledger's cause was the smaller of TWO: the
dominant one was KayaAppTx.tx being a get/set computed property
copying the whole accumulated batch per mutating call. 32,000 inserts:
15,135ms -> 18ms with both fixed, flat per-row. A keyed slots index
with compiler-refused bypass (three watched negatives) plus a _modify
accessor on the tx chokepoint (the underscored-accessor choice is on
the record for the maintainer; nothing observable differs). Wire
proven unmoved by batch sha against saved-copy builds.

bindings/swift/KayaApp.swift's `modelSet` linear-scans every entry
inserted so far on each insert, so N inserts cost N²/2 comparisons —
guest-side, before the wire (docs/measurements/
choke-ios-2026-08-24.txt). A dictionary keyed the way every other
binding keys it. Small, isolated, and it pollutes any large-data
measurement made through Swift guests until fixed.

## ~~PERF — mac's table model cost is dominated by the generation hash re-hashing the whole subtree per body evaluation (measured 2026-08-24)~~
KEY: kayaTableGeometryGeneration recursive hash, ObservationTracking churn, mac model-side choke, 42500 rows

FIXED 2026-08-24: the walk became a stored tableGeometryEpoch — one
read — and the 37% observation bookkeeping died with it (it was caused
by the walk's property reads). Semantics widened, not narrowed:
kayaUserWrite (invalidate, then write) funnels all twelve non-batch
model writes, covering the sibling-only case for the first time. Three
new static clauses + four watched negatives in check-table-tier; bench
N=20000 2.5s -> 1.0s, the 45,000 choke passes at 5.3s, N=100000 is now
bound by the guest's own submission. The residual — one
attribute-graph node per row — is virtualization's job, recorded in
the NOTE entry below.

At 100k rows the mac main thread spends ~41% of its samples inside
`kayaTableGeometryGeneration` — the geometry-generation hash (added
2026-08-24 for stale-geometry rejection) recursively hashes the entire
table subtree and is re-run per SwiftUI body evaluation — and ~37% in
per-child ObservationTracking register/cancel; NSTableView's own row
realization is unmeasurable
(docs/measurements/choke-macos-2026-08-24.txt, sample hot frames in
the report). The native tier's choke (42,500 rows chunked) is
model-side. An incremental or cached generation (bumped at apply
boundaries instead of recomputed by walk) is the fix shape; the
census's stale-geometry guarantees must survive it — the table-tier
probe holds them. Also recorded there: the GTK synthesized table path
is 47× slower than a plain For with identical widget counts, and an
unbounded natural-height For crashes X11 at 1,361 rows (window height
crosses the 32,767px protocol ceiling) — both shape the virtualization
design.


## ~~BUG — the Python binding's insert is quadratic (found 2026-08-24, by the WinUI bench)~~
KEY: python insert quadratic, ambient binding insert scan, large data guests

FIXED 2026-08-25 in 7d13429 (the mac depth slice; this strike is
late — the fix rode that commit and nobody struck the headline, so a
2026-08-25 queue survey repeated the bug to the maintainer as open).
The cost was not a keyed scan like Swift's: the rollback journal took
a whole-model dict snapshot PER MUTATION, so N inserts cost N²/2
copies. `_journal_instances` (bindings/python/kaya/__init__.py) takes
it once per transaction, inside the membership test. The guard is a
measurement, since Python has no compiler to refuse the eager copy:
kaya_app_checks.py's Bulk clause compares per-row cost at 2,000 vs
32,000 inserts and fails on growth (old body spliced back: 9.7-12.6x;
fixed: 0.97-1.01x; bound 3.0 with headroom both sides, numbers printed
every run).

Measured while benching the reindex fix: 2,500 inserts cost 21ms,
50,000 cost 5,162ms — the same class as the Swift entry fixed the same
day (a per-insert scan or copy in the accumulation path), now the
largest remaining term at 50k rows on the Windows bench. The
transactions view is Python, so this sits directly on the
virtualization slice's path; fix with the keyed shape the Swift fix
used, wire proven unmoved the same way.

## NOTE — virtualization design inputs from the fix slice (2026-08-24)
KEY: AG Subgraph per-row attribute node, grid_children chokepoint, row window design inputs

What the fix slice measured and deliberately left: mac's remaining
table cost is one SwiftUI attribute-graph node per row (39% of the
sample in AG::Subgraph::update under the outline coordinator) — no
cheap reduction exists; that is what row-windowing removes on the
native tier. WinUI's grid_children stays a bare HashMap (a chokepoint,
not a compiler guarantee — absorbing it into ChildOrder would change
destroyed-grid-cell behavior, an observable, so it waits for a
ruling). X11's 32,767px window ceiling and the GTK 47x table-path
factor are in the choke reports (docs/measurements/). These are the
design entry's constraints, recorded so the proposal argues from
measurements.


## ~~Row-window breadth (§6.3) — the depth stubs it will strike~~
KEY: depth_stub ledger, depth_stub varied, spacer+band lowering, ledger_python, varied.steps

CLOSED 2026-08-31: all four stubs below closed 2026-08-25 and the
tree agrees — zero `depth_stub(` calls remain in the Rust backends,
varied runs python-only on all three desktop lanes, and the ledger
scene retired into portfolio.steps 2026-08-26.
docs/virtualization-plan.md's §6.2 sentence claiming GTK and WinUI
still carry the stubs was corrected in the same edit.

- ~~**DEPTH STUB: ledger on gtk**~~ — CLOSED 2026-08-25: the spacer+band
  lowering landed; ledger-python runs green on both rings.
- ~~**DEPTH STUB: varied on gtk**~~ — CLOSED 2026-08-25 with the same
  lowering; the corrected path and the anchor run green on both rings.
- ~~**DEPTH STUB: ledger on winui**~~ — CLOSED 2026-08-25: the band
  panel's spacer tracks landed; ledger_python passes at 15,000 rows.
- ~~**DEPTH STUB: varied on winui**~~ — CLOSED 2026-08-25 with the same
  lowering; the corrected path and the anchoring assertion pass.


## ~~GAP — a single-transaction fill realizes every row before any layout can report (found 2026-08-25, by the breadth fan-out, twice)~~
KEY: pre-report stamping, one-transaction fill, pump-side seed, backend declares windowing, model mirror OOM

FIXED 2026-08-25, the same day, by the ruled flag: a windowing backend
DECLARES itself at init (core-internal, four Rust sites, no wire) and
a declared backend's new table seeds its band to WINDOW_SEED_ROWS =
128 — a generous screenful, argued from the tiers that read their
first visible count off realized rows and converge by doubling — with
inserts beyond the seed data-only until the first real report. The
iOS pump hack and Compose's composition cap are deleted; an
undeclared backend keeps the bridge, byte-for-byte, and window_moved
refuses a report from a backend that never declared. Windows'
ledger_python: FAIL at 58s under matrix load before, PASS 9-13s five
times after. 456 core tests, 9/9 watched reds.

AND A GENEROUS SEED WAS NOT ENOUGH BY ITSELF: WinUI's report cycle
echoed the REALIZED BAND's own count back as the visible range whenever
the collection had no measured extent, and the core adds an overscan to
every report — so the band doubled 128 -> 15,000 before the first
layout and the seed bought nothing there. Fixed 2026-08-25
(docs/traps.md, "The band that fed itself"), held by
`winui::tests::a_report_may_not_be_the_band_it_was_given`.

Two tiers hit it independently: on Android, 15,000 rows inserted in
ONE transaction die of the model mirror (~75,000 KayaNodes exist
before the band is ever reported — ART's limit, not composition,
which the band bounds); on iOS the pump resolves 15,000 rows in 152ms
while the main thread is on its first batch, so no layout-triggered
report can bound the first fill — that agent added a PUMP-SIDE SEED
(cross-platform; the mac legs re-ran green under it) and recommends
the clean replacement: a backend DECLARES it windows, and the core
seeds the band instead of stamping everything while unreported. The
compatibility bridge (no report = realize all) is exactly right for
backends that never window and exactly wrong as the transient state
of ones that do. THE DECISION IS THE MAINTAINER'S: the
declares-windowing flag deletes the seed hack and bounds the
single-transaction fill everywhere; until then, guests chunk (the
wired scenes do) and no wired leg inserts at the dying scale.


## ~~GAP — an unrealized row has no nested-collection instance (found 2026-08-25, by the seed slice)~~ — CLOSED 2026-08-25
KEY: nested collection instance, unrealized row write, template-owned collection state, bridge exemption

**Done, by the maintainer's ruling: DATA OUTLIVES WIDGETS, one level
down.** A nested For's collection instance is MODEL DATA keyed by
(collection, the outer row's copy path). It is born with the row's
RECORD (`Scene::birth_nested`, off `insert_entry`), it survives the
copy's widget teardown untouched, and a row entering the band rebuilds
its inner widgets from it through the ordinary
`register_for_site`/`reconcile_window` path — no parallel stamper, and
the band machinery itself is unchanged. Death moved with birth: the row's
own removal reaps it (`reap_nested`, recursive, off `remove_entry` and
off `update_entry`'s variant change), which is also what keeps a same-key
re-insert from inheriting a dead row's lines. THE BRIDGE EXEMPTION IS
GONE — `body_owns_a_collection` and its early return in `seed_window` are
deleted, so a template that owns collection state windows like everything
else. The per-copy HEADER OVERRIDE went the same way in the same edit
(`bar_overrides` is keyed by copy path and read back on every re-stamp;
teardown used to drop it, which under windowing would have reset a nested
table's sort indicator on every scroll).

What it was: a nested For's instance used to be born WITH its stamped
copy, so a row outside the band had none — varied.py's write to row 128
died with "no instance of CollectionId(2) at path [r128]" the moment the
seed made unrealized rows reachable, and the same hole was already open
under any report (a row leaving the band returned with its inner rows
gone; varied.steps asserted identity and totals, never inner content,
which is why nobody had met it). The measurement is kept in
docs/traps.md, under the entry whose ruling this edit rewrote.

Held by three unit tests in crates/kaya/src/scene.rs
(`an_unrealized_rows_inner_list_takes_writes_and_realizes_them`,
`an_inner_list_survives_its_rows_teardown`,
`a_removed_row_takes_its_inner_list_with_it`), each watched red against
its own perturbation, and by tools/scenes/varied.steps, which now reads
one row's inner lines after a scroll away and back and reads an
out-of-band row's lines after scrolling to it. Addressing one copy's
inner For needed the copy's own automation key, so varied.py spells
`lines.rows(a11y_id=row.key)` — the row-sourced a11y_id the prop's own
surface already blessed; the three interpreters' bare-id target arms now
skip DESTROYED registry entries, which the keyed arm had always done and
which a windowed copy's routine death made load-bearing.


## ~~The transactions view lives in its own guest until row windowing reaches every backend~~ — DONE 2026-08-26
KEY: transactions view, ledger.py, ledger.steps, ledger_python, PY_ONLY_SCENES, IOS_UNWIRED_SCENES, ANDROID_UNWIRED_SCENES, push_entry, portfolio.steps

The condition docs/virtualization-plan.md §6.2 named came due when §6.3
landed: `guests/python/ledger.py (gone)` and its scene are gone, and the view
is the portfolio's second screen behind a `push_entry`
(docs/portfolio-plan.md §6). One scene now carries both screens —
dashboard, tick, push, the windowed contract at 15,003 rows, and `back`
proving the covered root kept its numbers and its per-copy sorts. Three
runners lost a leg each (mac, linux, windows), the two mobile UNWIRED
lists lost a name, and check-assets' derivation clause moved to
tools/scenes/portfolio.steps — where it now derives the POST-TICK
ledger, reading RECENT and POSTED out of the guest by ast rather than
keeping a third copy. Six watched negatives on that clause (19 in the
gate, up from 16).

Two questions the move surfaced are entries of their own, below: the
holdings tie-out (ruled and closed 2026-08-26), and the keyed harness
target's one-kind arm.

## ~~An account's holdings are not the sum of its transactions~~ — DONE 2026-08-26
KEY: gen-market tie-out, net position, opening balance, book quantities, CASH ticker, POSTED, label@net

RESOLVED by the maintainer's delegated ruling, 2026-08-26: each account's
holdings MUST equal the sum of its transactions, and the direction is to
synthesize the TRANSACTIONS against the existing positions — the
dashboard's numbers are byte-stable, the stream moved under them. What
was open, for the record: the generator tied PRICE alone (its backward
walk ends at the book's live prices), while quantities were random
buy/sell/div lots, savings traded tickers it did not hold, and CASH — a
book holding — was not among its TICKERS at all.

The obstacle this entry named was the TAIL: the CSV is 15,000 rows kept
from the recent end of a longer walk, so a net over the retained rows is
not the book's. Neither option it foresaw was taken. The file is now the
WHOLE LIFE of every position — the overshoot decides DENSITY only (which
days carry how many lots) and the positions are walked over the retained
rows alone, from zero on the first row — so no opening balance is needed
and ROWS stays declared at 15,000. Three rules carry it: sells never
exceed what is held and buys never run more than one lot above the book,
so positions stay in a narrow band; each (account, ticker) pair's LAST
lot is its settling lot, whatever squares that pair with the book, or a
dividend when the walk already arrived; and the generator refuses itself
if any pair still disagrees after the walk. CASH is a tradeable ticker
now (flat, at its anchor — a unit of account does not walk), which is
what lets savings' $500.00 be a transaction sum. tools/gen-market.py
reads BOOK out of guests/python/portfolio.py by ast rather than keeping
the second copy of it that this entry's "TICKERS" complaint was really
about, and the --ensure stamp keys on the guest's bytes as well.

"Day tick" now posts three DIVIDENDS instead of three buys: a dividend
moves money and not quantity, so the tie survives a tick and the scene
asserts it on a book those rows are part of.

ASSERTED, not merely true: the transactions view carries a `label@net`
line — buys minus sells over the rows showing, per ticker, priced at the
live book. Unfiltered it reads `net AAPL 10, BND 20, CASH 1, NVDA 4,
VTI 6, VXUS 15 = $10023.00`, which is label#0's "Portfolio: $10023.00"
and the six Qty cells the positions tables freeze; filtered to
Retirement it reads `net BND 20, VXUS 15 = $2370.00`, which is label#5's
"Account total: $2370.00". check-assets grew C10, which nets the
ARTIFACT against the guest's BOOK, derives both net lines, and refuses
any net line whose money the dashboard does not also say — four new
watched negatives (N20-N23, 23 in the gate, up from 19).

## OPEN — the keyed harness target answers for `column` alone, so a stamped button cannot be driven (found 2026-08-26)
KEY: resolve_id keyed arm, kind@id[key.path], button@id, stamped button target, winui buttons registry, click tags

`kind@id[key.path]` resolves only when kind is `column`: gtk.rs and
winui/mod.rs both early-return on `if kind != K::Column`, and
KayaSwiftUI.swift guards `kind == "column"` before the keyed lookup.
WinUI additionally answers None for the UNKEYED `button@id` — its
buttons registry stores click tags rather than controls, which that file
records as a documented divergence.

What it cost: the portfolio's natural affordance is a "Transactions"
button on each account card, and no scene can click one, so the view is
reached by one live dashboard button and the account is chosen inside it
by the filter (docs/portfolio-plan.md §5's finding). Any app whose rows
carry actions has the same wall.

The work is one harness slice: give each backend's keyed arm the same
copy-path lookup for every kind that has an id vector, and give WinUI's
buttons registry the controls it needs to answer at all. Three
implementations, one rule, and check-verbs' target census is where it
would be pinned.

## ~~BUG — every Java wire record was capped at 4096 bytes (found 2026-08-26, by the canvas marshal bench)~~
KEY: java-record-ceiling, ByteBuffer.allocate(4096), BufferOverflowException, KayaWire begin, Enc.at grow, LargeRecordCheck exerciser, KayaTx cap, kaya_wire_fits, kaya_tx_ok, kaya_wire_refused, transaction full, check-c-bounds, c-tx-cap, overflow is the caller's

FIXED 2026-08-26 in the GENERATOR — tools/kaya-bindgen/src/java.rs emits
a private `Enc` (a ByteBuffer behind an `at(int extra)` that reallocates
by doubling) and every encode-path write goes through it. The measured
ceilings, which are what this entry exists to keep: **4064 characters in
ANY text prop** and **252 wire values in a set_drawing** — one past
either threw java.nio.BufferOverflowException. The canvas frame that
found it (341 paths, 8296 wire values) is a 132 KB record; Java refused
it outright while python encoded it in 0.93 ms.

Java was the ONLY one of the eight bindings that could not grow, so this
was an invariant-1 divergence hidden in a generator: python joins bytes,
go appends to a slice, C# writes a no-arg MemoryStream, swift a Data,
ocaml a Buffer, haskell a Builder, and Rust never encodes at all (the
core's own language — it pushes TxOp into a Vec in process). All seven
re-read line by line when this was fixed, not taken on the bench's word.

WHY IT SURVIVED EVERY LANE: nothing in the tree ever built a big record.
The longest line in any shared scene is 359 characters, so no scene, no
example and no doc ever promised — or exercised — long text through Java.
The user-visible face was real all the same:
guests/java/dev/kaya/milestone2kt/FileDialog.java reads a picked file
whole and writes it into a signal, so a Java guest opening any file over
~4 KB threw on the app thread. The scene picks a small fixture, so it
never did.

WHY A WRAPPER TYPE AND NOT AN `ensure()` BEFORE EACH WRITE: the three
encode helpers take the buffer as a PARAMETER, and a ByteBuffer
reallocated inside `encodeValue` cannot propagate back to its caller. The
wrapper is also the stronger guard (invariant 3, types over generation) —
a future generator edit that emits one more `b.putX(...)` grows by
construction, with no per-site ensure() to forget. Initial capacity stays
4096, so every record the tree produces today takes the same no-realloc
path the bench measured.

THE GUARD is in tools/java-typecheck.sh, which gains the only clause in
that file that is RUN rather than compiled: an exerciser that encodes and
reads back a 100,000-character text prop and a 20,000-value drawing (a
320,064-byte record), plus the exact boundary — 4064 characters and 4065.
A compile check is blind to this by construction, because the ceiling is
a throw; that is why the gate was green for the whole life of the defect.
Its watched negative removes the growth from a COPY of KayaWire.java,
prints the substitution count, and requires BufferOverflowException
specifically. Six refusal branches, all six watched firing.

~~WHAT THIS DID NOT TOUCH, and is a maintainer call rather than mine: the
C floor has a ceiling too, and a worse one.~~ RULED AND BUILT 2026-08-26,
the day after this entry raised it. As filed: bindings/c/kaya_wire.h's
`KayaTx` was `{uint8_t *buf; size_t len;}` with no capacity field and no
bounds check anywhere on the encode path, so a long string was an
unchecked memcpy into the caller's array — a stack smash, not an
exception. In-tree callers declare 256 to 8192 bytes. It was DECLARED
policy rather than a hidden ceiling (the header said so at its top,
"overflow is the caller's to size against", and guests/c/todos.c repeated
it), which is why it was filed as a contract question and not as a bug.

THE RULING, in the maintainer's own image: `KayaTx{buf,len}` is a Go
slice header missing its third field. It gains `.cap`, and every
`kaya_wire_*` packer bounds-checks against it — overflow becomes a LOUD
REFUSAL instead of undefined behaviour. The caller still owns, sizes and
frees the buffer (the ABI's universal `(ptr, len)` contract; kaya_submit
is read-only and untouched), and a caller wanting a bigger record
allocates bigger. NO owning or growing constructor — that was proposed
and explicitly withdrawn: refusing rather than smashing is precisely what
makes caller-side grow-and-retry possible, and the pattern is written out
in DESIGN.md's Binding conventions.

HOW IT REFUSES: `kaya_wire_fits()` before every write, and nothing is
written when the value does not fit — no partial record, ever. Past cap
`len` goes on counting what the whole transaction WOULD take, snprintf's
return exactly, so it is the size to grow to and `kaya_tx_ok()` is the
caller's predicate. `kaya_wire_end` publishes the sentence ONCE, for the
first record that did not fit, in the C floor's own refusal idiom
(fprintf to stderr, the shape guests/c/assets.c's caller-sized-buffer
check already used) — naming the record kind and both sizes. TWO
branches, because the kind is read back out of the header this record
wrote: where even those 8 bytes were past cap there is no kind to name,
and that sentence says so rather than printing a number nothing recorded
(invariant 3). Both branches watched printing.

THE SWEEP: 17 guests/c files, not the eight the ruling guessed — all 17
declare a KayaTx, and their 61 initializers move to the visible
`{buf, 0, sizeof buf}` form, which is the floor teaching its own
contract. The other seven bindings need nothing: only C hands the packers
a bare pointer (bindings/swift's `KayaTx` is a same-named Swift struct
over a growable Data), so this is a C-floor slice and not a binding
sweep.

NO OUTPUT BYTE MOVED, proven rather than asserted, the way the C-floor
renumber above proved its own: tools/checks/c-tx-cap.c runs the WHOLE
packer repertoire — begin/end, u32, u64, pad, values, variant_schemas and
a value of all five tags, which is everything a guest can emit — into a
generous buffer and hexdumps it, built once against the new header and
once against ee7bc41's pre-cap header. 432 bytes, byte-identical. That is
stronger than per-guest capture and needed no stub link.

THE GUARDS, two of them. `guests/c/Makefile` gains
`-Werror=missing-field-initializers`, so a `KayaTx tx = {buf, 0}` — which
still COMPILES against a three-field struct, reads cap 0 and refuses
every record at run time — now fails the BUILD naming `cap`: the wall on
the path nobody can avoid. And `tools/check-c-bounds.sh`, the 48th gate,
because nothing else can see any of this: every in-tree guest sizes its
buffers correctly, so the wire bytes are identical either way and no
scene, lane or capture is different — which is how the unchecked memcpy
shipped from milestone 0 under green lanes. Its probe is WALLED rather
than sanitized (mmap + mprotect, so a one-byte overrun is a fault and not
a heuristic), and its negative is the shipped bug itself: the same probe
built against ee7bc41's header, which dies of SIGBUS in both modes where
this one prints a sentence. AddressSanitizer, which the ruling asked for,
could not serve THAT DAY — an `-fsanitize=address` binary with no error in
it hung before main on this host (docs/traps.md, measured). It joined as
the gate's COMPANION MODE on 2026-08-27, on a plain malloc rather than a
walled page, once flake.nix put a clang whose ASan starts (22.1.8) in the
dev shell as `kaya-asan-clang`; the wall remains the primary. See the
struck ASan entry at the top of this file.


## HOLD — the mirrored adaptive sugar awaits demand (ruled 2026-08-28)
KEY: row_above, mirrored sugar, stack_below, adaptive layout, mobile-first

`row(stack_below=N)` shipped with the adaptive-layout milestone and
became `row(stack_when=compact)` with the 2026-08-31 size-class slice
(docs/adaptive-layout-plan.md D3, D8); its mirror — `column(row_above)`,
the web's mobile-first direction, a column that widens into a row on
leaving the compact class — was ruled LEDGERED, not built: one adaptive
sugar until a guest wants the other. Both lower to the same wire
record, so closing this entry is one keyword argument in eight
bindings plus its
check-sugar-surface census row, not a mechanism. Closes when a real
scene or app asks for the mobile-first spelling.


## WATCH — the mac portfolio leg's pushed entry popped across the fold round trip, once (2026-08-31)
KEY: portfolio-python-swiftui, entries 0 wanted 1, expect_folded, back push resize, NavigationStack pop, matrix contention

First sighting, one occurrence: the 2026-08-31 end-of-day matrix
(five lanes contended) failed mac's portfolio-python-swiftui leg at
the fold round trip's LAST step — `resize_window 900x600` then
`expect_folded column@summary none` retried its deadline and failed
with `entries 0, wanted 1`: the pushed Transactions entry was GONE
and the harness was reading the dashboard. The leg's own log shows
the shape: the preceding `back` -> `click button#1` ->
`expect_title "Transactions"` cycle had its click retrying ~3.6s
under load before the title matched, then 560-fold PASSED on the
pushed screen, then the resize back to 900 found the stack empty —
so the pop happened between the successful fold assert and the next
observation, around a resize, on an entry pushed ~100ms after a
back. The same tree passed two full matrices earlier that day
(aeb4f3f's and 5b4eddc's records) and three solo reruns back to
back, all with the complete fold round trip; no leaked load beyond
the standing emulator pool. NOTE the day's steps change rides along:
portfolio.steps' stacked assert moved 640 -> 560 with the size-class
slice, so the leg now crosses 600 (the mac chrome form-factor
boundary and the compact class) where 640 never did — recorded as a
premise candidate, not a conviction, since the same crossing was
green in two matrices. IF IT RECURS: instrument the pop at its
chokepoint before any rerun — the interpreter's pop/entries apply
arm and navEntries writes are the place to log WHO removed the
entry (a platform-initiated NavigationStack reset would show as a
path write the core never sent) — an intermittent leg is a correct
verdict over an unpinned premise, and the premise gets instrumented
at its chokepoint, never rerun into the noise. The record-matrix
rerun that followed the sighting was ALL PASS (mac 349, all lanes
under their ceilings), so the sighting stands at ONE, under
contention, watched.


## HOLD — the windows guest-side command scripts convert to python, at some point (Akhil, 2026-08-31)
KEY: tools/guest cmd scripts, windows vm python, schtasks launcher, shot-window ps1, cmd.exe toml

Filed the day the gate-conversion small tier closed (5b4eddc), from
Akhil's own aside: the ~40 tools/guest/*.cmd and *.ps1 scripts that
run ON THE VM (shipped by deploy-win, launched via schtasks /it) are
the same maintained-at-cost shell surface the gate bodies were, one
platform over — and python already exists on the VM, since the lane's
python guests run there. The shape when it happens mirrors the gate
conversion: python bodies, minimal .cmd stubs kept as the schtasks
launchables (cmd.exe stays the LAUNCHER — it cannot read TOML, which
is check-app-identity's recorded exception, and schtasks needs a
plain launchable). The ps1 family's Win32 calls (shot-window.ps1's
Add-Type user32 shapes) port to ctypes. NOT SCHEDULED: "at some
point", verbatim — the trigger is the next time guest-side scripts
need real work, or the runner-conversion boundary being revisited.
Until then deploy-win's shipped-file list and check-shell's coverage
of tools/guest stay as they are.


## HOLD — keyed when/otherwise arms await a use-case (ruled 2026-08-28)
KEY: keyed arms, when otherwise, arrangements, re-parent, keyed unification, different tree

The adaptive-layout design's phase-2 mechanism, ruled to the ledger the
same day it was designed because no scene or app needs it yet: for a
narrow layout that is a DIFFERENT TREE rather than different property
values on one tree (docs/adaptive-layout-plan.md D3 covers the latter),
`when(narrow)`/`otherwise` arms each trace a complete hierarchy, and
SAME-KEY children across arms unify into ONE living widget re-parented
at the switch — an arm-local key is plain presence, making today's
`when` the degenerate case. The novel half is that both worlds are
known at declaration, so the unification is CHECKED at build (same key
= same widget kind, duplicate key in one arm refused) where React's
keyed reconciliation is a runtime gamble. Recorded costs, from the
design session: the key obligation on guests, duplicate constructor
arguments across arms needing an equality rule (which copy wins), and
overlap with the template zone's machinery. Evidence base:
docs/probes/adaptive-layout-2026.md (AdwMultiLayoutView and AnyLayout
are the nearest shipped relatives). Closes when a real narrow layout
that a property diff cannot express exists — the portfolio's phone
dashboard is currently believed to need only the axis flip, and if its
visual iteration proves otherwise this entry is the design to build.


## ~~DESIGN — THE BREAKPOINT IS A RAW NUMBER, WHERE EVERY OTHER TOOLKIT NAMES A CLASS (2026-08-29)~~
KEY: stack_below 700, size class, WindowSizeClass, compact regular expanded, breakpoint vocabulary

BUILT AND LANDED 2026-08-31, the same day the spelling was ratified
(docs/adaptive-layout-plan.md D8 is the record): `stack_when` takes a
TYPED size-class name in all eight bindings, record 48's threshold
became the i64 spec enum "size_class", kaya_window_metrics carries the
platform's class (iOS reports UIKit's own; everyone else reports NONE
and the core derives at the ruled 600), a reported platform class
BEATS the width (the iPad split-view case, unit-proven), and
`stack_below` is GONE — the portfolio's 700 and the adaptive scene's
520 both became `stack_when(compact)`, portfolio.steps' stacked
assert moved 640 -> 560, and Python's refusal names the dead spelling
for anyone who types it. check-verbs grew the metrics-class clause
(the iOS environment read no lane can see, plus the 600 pinned at the
ruled value — the scenes hold it only to (560, 900]), six watched
negatives plus the wiring itself watched red on the real file.
Matrix ALL PASS on the slice: mac 349, linux 604, windows 201, ios
113, android 123, gates 50/50; the linux/windows duration anomalies
were the slice's own cold core rebuild (no leaked load; maintainer
waived them in-session).

RULED 2026-08-31 (maintainer): NAMED CLASSES, and the raw-number
spelling DIES with the slice (churn is free — no compat argument).
The breakpoint speaks the class vocabulary (`stack_when="compact"`
shape, exact spelling decided at design time): iOS reads the
platform's own class; the desktops get kaya-owned thresholds at the
Material boundary (compact below 600), since no desktop platform
defines one.

`stack_below=700` makes the AUTHOR invent the number. Nobody else does
that, and the maintainer's question — "how is the user supposed to know
what the breakpoint value is?" — is the same one that moved the whole
industry off raw pixels:

- APPLE gives two named classes per axis, `compact` and `regular`, and
  never a number in app code.
- MATERIAL 3 names five and owns the thresholds: compact 0-599dp, medium
  600-839, expanded 840-1199, then large and extra-large.
- THE CSS ECOSYSTEM converged the same way — Bootstrap and Tailwind ship
  named tiers (sm/md/lg/xl) and the numbers live in the framework.

KAYA ALREADY HAS THE VOCABULARY AND DOES NOT EXPOSE IT: `KayaTableWidth`
is `compact | regular | noSizeClass | unknown` and the TABLE TIER already
routes on it (`kayaTableTier`). So the backend knows the class the
platform reports and the guest cannot name it. The breakpoint should
speak that vocabulary — `stack_below="compact"` or a `stack_when` taking
the class — leaving the thresholds where the platform defines them, which
is also the only way one number can be right on a phone, a foldable and a
split-screen iPad at once.

NOT THE SAME QUESTION AS THE EXTENT, and the distinction is worth
keeping: a container's EXTENT is never authored. The window hands its own
size to the root and each container passes a share down, so the 596 in
these entries is derived, never typed. The breakpoint is the one number
an author writes, which is exactly why it is the one that should be a
name.

SPELLING RATIFIED 2026-08-31 (maintainer): `stack_when` taking a TYPED
size-class name in every binding's idiom — Rust
`.stack_when(SizeClass::Compact)`, Swift `.stackWhen(.compact)`, Python
`stack_when=kaya.COMPACT` — never a string literal, so a typo is a
compile error in the six compiled languages (precedent: platforms are
already `kaya.Platform.LINUX`, not `"linux"`). `compact` is the only
accepted value day one; the vocabulary can grow. The portfolio's 700
and the adaptive scene's 520 both become the ruled 600 boundary, so
those scenes' frozen widths move with the slice.


## DESIGN — THE NINTH BINDING: JS/TS (Akhil, 2026-08-31; every day-one ruling recorded, integer contract included — BUILD READY)
KEY: js binding, typescript, N-API, worker thread, BigInt, safe integer, 2^53, JSX, kaya-gui npm, event loop

RULED 2026-08-31 (maintainer, design-only session — no code today):

- EMBEDDING: a Node N-API addon (ABI-stable across Node versions, one
  binary per platform, Bun-compatible), a GENERATED TypeScript wire
  layer out of gen-bindings' ninth emitter, hand-written TS sugar,
  shipped as `kaya-gui` on npm (bare `kaya` is squatted; the packaging
  ruling already names this). Desktop-first: Node does not run on the
  phones, so JS starts where Python did before packaging-mobile.
- THREADING: the WORKER-THREAD model. Every platform demands its UI
  loop on the process main thread and Node's JS also lives there —
  NodeGui ships a forked Node binary (Qode) to merge Qt's loop in, and
  Electron does deep libuv integration, both to run app JS on the UI
  thread. kaya refuses the premise instead: the app's JS runs in a
  worker_thread, which IS the kaya-app thread; the main thread is
  surrendered to the platform loop exactly as in every other binding;
  occurrences arrive in the worker as callbacks via thread-safe
  functions. Uniform threading semantics — a wedged handler stalls the
  app thread and the UI stays live — at the cost of a small bootstrap
  dance in the entry module. An ASYNC handler's transaction dies at
  its first await (an async function returns there), and the liveness
  refusal says so — the check-tx-liveness rule, JS spelling.
- JSX/TSX: DESIGNED FOR, SHIPPED LATER. kaya's model is SolidJS's
  model (components run once to build the tree, no virtual DOM,
  signals update in place; Solid's For/Show are kaya's For/when), so
  a run-once JSX factory (`jsxImportSource: "kaya-gui"`) compiles 1:1
  onto the function sugar. Day one is the function sugar, shaped so
  that factory needs nothing changed; React's re-render model is
  ruled out as fighting the retained core.
- Transaction style: AMBIENT (module-level constructors against the
  implicit current transaction, nested arrow bodies) is the
  recommendation consistent with the worker and JSX rulings; confirmed
  at build kickoff.

THE INTEGER CONTRACT — RULED 2026-08-31 (maintainer, same evening):
SAFE-INTEGER. Kaya integers are COUNTS AND QUANTITIES, exact to
±2^53−1, refused beyond that at the root in EVERY binding; identity
rides as strings or tags. The ruling followed the maintainer's own
question ("we're a GUI framework — why would kaya care about database
ids or timestamps?") and the tree's answer: the portfolio, the most
data-heavy app in-tree, sends ZERO integers (every record field is a
string including qty; money lives as integer cents in the app's OWN
book and is formatted before the wire; even row keys are the
app-minted string "t00042", and key_of's docstring notes the scene
grammar's untyped key segment matches string keys only); click tags
are opaque bytes, so a 64-bit backend id already round-trips without
kaya having an opinion; the only integer signal anywhere in-tree is
milestone2's step counter; and the core never computes with app
integers (sorting is app-side). i32 was REJECTED — the tagged value
slot stays 8 bytes so it saves nothing, and it would refuse plausible
raw counts (bytes, cents, ms) for zero benefit. FULL i64 was declined:
it preserves exact >2^53 fields nobody uses at the price of a
permanently BigInt-asymmetric ninth binding. BUILD SHAPE, first step
of the ninth-binding milestone: the spec doc sentence, the root guard
at the value-decode chokepoint (refusal names the fix: identity as
strings/tags), a watched negative, and the eight existing bindings
audited for any path that could emit past 2^53 (none expected).
Ambient tx style stands as the recommendation, to be confirmed at
build kickoff.


## DESIGN — THE LINUX OUT-OF-BOX LOOK: EMBEDDED DEFAULT TYPEFACE + GTK CHROME (2026-08-31)
KEY: linux default typeface, embedded plex, script companions, fontconfig fallback pin, headerbar chrome, windowcontrols

RULED 2026-08-31 (maintainer), scope only — the build is sequenced
behind the breakpoint slice and the JS/TS design work. Two halves,
both LINUX ONLY: every other platform keeps its platform font and its
platform chrome (San Francisco, Segoe UI Variable and Roboto are
deliberate designs, and the mac/windows chrome APIs stop at sanctioned
knobs anyway — caption buttons and traffic lights are system-drawn).

ONE: an app that declares no `brand_typeface` gets kaya's own embedded
default on the GTK backend — IBM Plex Sans, FAMILY ONLY, the user's
font size kept. Linux is the one platform whose "system font" is not
one thing (Adwaita Sans on GNOME 48, DejaVu on a bare box), which is
why a framework default is defensible there and nowhere else. The
maintainer wants the FULL script set, not the Latin core alone: the
Plex superfamily covers CJK completely since late 2024 (Sans JP, KR,
TC, SC), plus Arabic, Hebrew, Thai and Devanagari. AMENDED BY THE
MAINTAINER 2026-08-31, same day: even where kaya bundles nothing,
KAYA PICKS THE FALLBACK FAMILY itself — the framework names the
preference, never the distro default — and the per-script Noto
pinning idea is DROPPED; scripts Plex does not cover take whatever
fontconfig resolves. The mechanism is a fontconfig prefer list
per script beside the installed companions — Pango itemizes text per
script run, so mixed-script text picks each face by script — and the
wire already carries font bytes (`set_brand_typeface`), so the
framework default rides the machinery the brand typeface built. Cost
on the record, accepted by the maintainer: the CJK companions run
~30k glyphs each, tens of MB across weights; where that weight LIVES
(each app bundle vs a shared kaya font pack) belongs to the deferred
distribution story and is the first question the build must answer.
The lane fixture (10fcc83) is the separate, already-shipped half: it
pins the CONTAINER's system font so legs are deterministic, and says
nothing about what a user's app looks like.

TWO: the chrome, GTK ONLY by the maintainer's scope ruling — headerbar
height, window-control (min/max/close) styling and spacing, via the
CSS provider the backend already owns. Client-side decorations mean
kaya draws its own titlebar on Linux, so this is ordinary styling
work, not a platform fight.

Closes when both halves ship with their proofs: the typeface half
wants an `expect_typeface` leg for the undeclared-app default (the
fallback family is kaya's pick, per the amendment above), the chrome
half a frozen observation of the styled headerbar.


## DESIGN — `grow` INSIDE A SCROLL IS SILENTLY ZERO (2026-08-29; the header half CLOSED 2026-08-30)
KEY: grow inside scroll, unbounded main axis, sliver header, tableHeaderView, LazyColumn item, nested scroll, interim portfolio fix

THE SECOND HALF CLOSED 2026-08-30, ratified by the maintainer as the
ADAPTIVE FOLD (docs/adaptive-layout-plan.md D7): a stacked breakpoint
row (`stack_when` since 2026-08-31, D8) whose shape is leading hugging
children then one grown table folds
those children into the table's viewport as scroll-away header content —
DERIVED from the shape, no new spelling in any binding — so "a list
cannot own its header" is no longer true where it mattered, and the
interim two-scroller portfolio shape below is GONE (the guest change was
a DELETION). The FIRST half stands: `grow` along a scroll's own axis is
still silently zero, and the ruling this entry asks for — take the given
extent like a grown table does, or refuse loudly like Flutter and
Compose — is still open.

`grow` means "take a share of the leftover". A `scroll` offers its content
an UNBOUNDED main extent. So `grow` along a scroll's own axis has nothing
to divide, and kaya answers ZERO — silently. Researched 2026-08-29, every
other toolkit does something else:

- FLUTTER refuses: "RenderFlex children have non-zero flex but incoming
  height constraints are unbounded", and states the principle — if a
  parent shrink-wraps its child, the child cannot simultaneously expand
  to fit that parent. The two are mutually exclusive.
- COMPOSE throws: "Vertically scrollable component was measured with an
  infinity maximum height constraints, which is disallowed."
- CSS MAKES IT WORK, because a CSS scroll container has a DEFINITE box
  and overflows internally rather than proposing infinity. `flex: 1` plus
  `overflow-y: auto` is the canonical idiom, and the spec special-cases
  it: a flex item's automatic minimum size is content-based EXCEPT for
  scroll containers, where it is zero, precisely so this composes.

kaya does the one thing nobody chose. THE ASYMMETRY THAT MAKES IT BITE,
from this session's own trace: inside a scroll, `grow` degenerates to the
child's NATURAL size. An ordinary container reports its content (the
dashboard's detail column asks 586 and gets 586, which is why that fix
works), but a GROWN TABLE reports 32 — its header alone — because it is a
viewport built to claim nothing. So containers survive a scroll and
windowed tables vanish inside one.

TWO CHANGES, when this is picked up:
1. A `scroll` should TAKE THE EXTENT IT IS GIVEN and overflow its
   content — which is exactly what a grown table already does. kaya
   already implements the right model for tables and the wrong one for
   `scroll`; making them agree REMOVES a special case rather than adding
   one, and `grow` inside a scroll then means the obvious thing. Failing
   that, refuse loudly like Flutter and Compose. Silent zero is the one
   answer with no defenders.
2. A WINDOWED COLLECTION CANNOT TAKE THE CONTENT ABOVE IT AS ITS HEADER,
   and every mobile toolkit provides exactly that: Compose's
   `LazyColumn { item { header }; items(rows) }`, Flutter's
   `CustomScrollView` with a `SliverToBoxAdapter` over a `SliverList`,
   UIKit's `UITableView.tableHeaderView`. It is the idiom for "summary
   above a long list", and kaya cannot express it at all.

THE PORTFOLIO'S TRANSACTIONS SCREEN SHIPPED AN INTERIM SHAPE because of
this, 2026-08-29 to 2026-08-30: two independently scrolling regions
stacked vertically (a documented anti-pattern — Baymard measures 26% of
inline scroll areas implemented wrong; nested scrollbars penalise
assistive-technology, keyboard, tremor, low-vision, magnification and
mobile users alike). The fold replaced it with one scroll, the summary
scrolling away as the ledger's header, and the scene now DOES see the
difference: `expect_folded` reads which viewport a child renders in on
every lane, both sides of the breakpoint.


## ~~GAP — a GROWN TABLE STACKED ON A PHONE GETS A ZERO-HEIGHT VIEWPORT (found 2026-08-29)~~ CLOSED 2026-08-30 by the adaptive fold
KEY: grown table phone viewport, clip 311x0, KayaScrollBox, txnrow stack_below, leftover 259

CLOSED 2026-08-30: the shape that produced the zero — a hugging summary
worth most of a screen above a grown table dividing the two leftover
points — no longer reaches the flex at all. The adaptive fold
(docs/adaptive-layout-plan.md D7) moves the hugging children into the
table's own viewport when the row stacks, so the table is the row's one
laid-out child and takes the whole track. The interim fix this entry
drove (the summary in its own grown scroll) was deleted with it. The
dead-end list below is kept as the history it is; note the mac-reach
paragraph predates the fold — a FOLDED table now routes to the
synthesized tier on every platform including macOS (check-table-tier's
folded rows), so the mac reaches that tier through the app whenever a
stacked fold is live.

Put `stack_below=700` on the portfolio's Transactions row and the phone
lays the screen out correctly in every respect but one: the grown ledger
table's scroll clip measures `311x0` — a real width, ZERO height — so it
records no viewport, windows nothing, and `expect_window column@ledger`
reads "0 0". The iOS leg fails; the guest change is therefore NOT in the
tree. The same screen on Compose reports `track -32dp, drawn 0dp` and is
the android leg's block.

WHAT IS ALREADY RULED OUT, each measured rather than argued — this
entry's value is the dead ends, because every one of them is a plausible
story that costs a session to re-test:

1. ~~NOT the stacking~~ — THAT CLAIM WAS WRONG, and the way it was wrong
   is the lesson. `bounds=343x596 fixed=328 leftover=259` is the
   DASHBOARD's stacked row. The probe that produced it printed no node
   ids, so the numbers were attributed to the screen being investigated
   rather than the one they came from, and the entry then argued from
   them that the stack was healthy. With ids in the trace the two rows
   are told apart at a glance and disagree completely:
       flex bounds=343x596 ids=[2, 10]  extents=[328, 259]   <- dashboard
       flex bounds=343x596 ids=[22, 38] extents=[594, 0]     <- transactions
   A MEASUREMENT WITHOUT AN IDENTITY IS A GUESS WITH A NUMBER ON IT.
2. NOT the sibling's width, on either platform. Four perturbations left
   Compose's number byte-identical: `net` shortened to one word, all four
   summary labels shortened to one character, the recent table removed
   entirely, and `align="stretch"` removed from the summary column.
3. NOT "the summary is a screenful" — see 1; that was an assumption, and
   the measurement contradicts it.
4. NOT `KayaScrollBox`'s `proposal.height ?? 0` fallback, which was the
   best-looking suspect: making it answer 200 instead of 0 left the clip
   at `311x0`. The box's own `placeSubviews` passes `bounds.height`
   straight through, so the zero arrives from ABOVE it.

THE INSTRUMENTATION EXISTS (2026-08-29). The whole chain speaks under
`KAYA_LAYOUT_TRACE=1` — flex bounds and per-child extents BY NODE ID,
cell proposal/natural/out, scroll-box proposal, and the viewport the
reporter records — so one run shows the sequence instead of one probe per
build. The Compose side has the same channel, gated the same way.

A MAC-SIDE PROBE WAS BUILT AND THEN REMOVED, deliberately, and the
reasoning is worth keeping: `tools/checks/swiftui-stacked-grow.swift` (gone)
rendered the phone's synthesized tier on a Mac in seconds, which needed a
door through `KayaTableSurface`'s tier switch, which in turn needed
check-table-tier's one-caller census to sanction a second construction
site. It answered its question — the pure layout shape is healthy — and
then nothing ran it, so it was an unwired guard plus a hole in a strict
gate, which is a bad trade. Recover it from git history if this tier
needs a fast loop again; the shape is a hugging summary column with a
long label and a grown 40-row table under it at 393 points, rendered
through `KayaSynthesizedTable` directly because the mac's tier arm is
`#if os(macOS)` and never selects it.

TWO THINGS THAT COST HOURS BEFORE THE PROBE EXISTED, both now permanent:
- THE MAC CANNOT REACH THIS CODE THROUGH THE APP. `kayaTableTier` gates
  on TableColumnForEach's AVAILABILITY, not width, and `widthClass` is a
  compile-time `#if os(macOS)` arm returning `.noSizeClass`, so the mac
  always renders the NATIVE tier. A traced run of the real app at 400
  points emitted 2,423 lines and not one from the synthesized tier. An
  `.environment(\.horizontalSizeClass, .compact)` does not help — the mac
  arm never reads one. `kayaSynthesizedTableForProbe` is the sanctioned
  door, and check-table-tier holds it to being a door (its A1 census
  refuses any call from the interpreter, watched firing).
- A PROBE HAS NO CORE, so `visible` is ALWAYS nil there by the tier's own
  early return in `report()`. Asserting it reads as this bug and is not.
  The viewport is the part that is pure layout, and it is what was zero
  on the phone.

ROOT CAUSE, FOUND AND MEASURED (2026-08-29). The Transactions screen's
summary column is 594 POINTS TALL IN A 596-POINT VIEWPORT, so the grown
ledger beside it divides a leftover of two points and gets none. Nothing
is broken in the flex, the cell, the box or the reporter — they do exactly
what they are told. The same row proves it by reviving when there is room:
    ids=[22, 38] bounds=343x596 -> extents=[594, 0]
    ids=[22, 38] bounds=343x780 -> extents=[594, 177]
The 594 is mostly the RECENT TABLE: twelve ungrown rows plus a header,
about 464 points of it, under four summary lines and the account filter.

THE PROBE'S OWN VERDICT IS CONSISTENT with that and worth keeping: given
a container with room (700 points and one short label), the whole chain is
healthy — `extents=[80, 612]`, `box in=393x612 out=393x612`,
`vp clip=413x628`. It reproduces the SHAPE, not the crowding, which is why
it passes. It stays as the regression guard for the shape.

SO THE FIX IS A PRODUCT ONE, and it is the shape of the thing that was
ledgered here from the start: a phone cannot show a twelve-row summary
table stacked above a fifteen-thousand-row ledger and give both room. It
needs the adaptive work to drop `recent` below the breakpoint (D4's keyed
arms, docs/adaptive-layout-plan.md), or the guest must stop declaring it
on this screen. A TOOLKIT-SIDE FLOOR WAS TRIED AND REVERTED: giving any
starved grower a containerful changed track arithmetic wherever a leftover
legitimately reaches zero and cost 16 sizepolicy legs on the mac lane.

ALSO FALSIFIED, with the probe: `KayaScrollBox`'s `proposal.height ?? 0`
fallback. Changed to answer the content height instead and every number
came back byte-identical.

NOT A DESIGN FORK. It was put to the maintainer as one (a `hide_below`
primitive, or a viewport policy) and that framing was withdrawn: nothing
about the layout is over-subscribed, so no product decision is owed.


## ~~GAP — the portfolio's android leg waits on adaptive layout~~ — CLOSED 2026-08-30: the leg is WIRED and the lane is ALL PASS over 123 legs
CLOSED BY three fixes, none of them the adaptive work this entry expected
to wait for. (1) The screen was KILLING THE APP, not merely laying out
badly — Compose refuses to measure a scrollable with an infinite maximum,
and the infinity came from an ancestor's intrinsic pass, so the viewport
clamps an unbounded ask to the display's height (docs/traps.md). (2) The
zero-width track was real and is gone with it. (3) The reason it took a
day is that the android build LIED: the guest is a staged copy and the
extraction is stamp-gated, so a rebuilt APK ran last week's guest and four
conclusions were drawn from a file nobody had edited. `stageGuestPython`
stages and re-stamps on every build now.
ANDROID_UNWIRED_SCENES is EMPTY, and run-emulator queues portfolio-python
beside varied-python.

KEY: portfolio android, zero-width track, constraints model, proposal model, kayaFixedRepresentable, Can't represent, ANDROID_UNWIRED_SCENES

The packaging milestone's android slice brought python up (varied-python
runs; the suite is run-emulator.sh's), and the portfolio was the first
scene to mount a table inside a ZERO-WIDTH track on Compose: at phone
width the dashboard's detail column overflows, SwiftUI's proposal model
lays the overflow out at natural size (clipped, geometry real — the iOS
leg passes), and Compose's constraints model squeezes it to 0, so the
tables record no live viewport geometry and expect_aligned answers "no
container layout recorded". TWO consequences, one fixed and one held:

- FIXED SAME DAY: KayaTableSurface THREW during first composition —
  towering wrapped rows at width 0 made the windowed spacers exceed
  Compose's Constraints packing ("Can't represent a width of 0 and
  height of 358912") and the app died before any verdict. The measure
  sites clamp through kayaFixedRepresentable now
  (Constraints.fitPrioritizingWidth: identical values whenever they
  were representable). ITS STANDING NEGATIVE IS THE FUTURE LEG: no
  wired scene reaches a zero-width table today, so the repro is the
  pyhost APK with the portfolio scene by hand until this entry closes.
- HELD: the leg itself. ANDROID_UNWIRED_SCENES="portfolio" with the
  reason at the declaration. WHAT IS TRUE AS OF 2026-08-28 EVENING, all
  of it measured by hand on the emulator with the shared script:

  THE APP RUNS THERE. From a clean install the guest builds in ~400ms
  and the script's first 100+ steps pass — the dashboard, the sorts, the
  day tick, the push to Transactions, the 15,003-row ledger, windowing,
  scroll_to_row, the account filter and `back`. The whole script reaches
  its last step in ~27s.

  THE DASHBOARD'S STACK WORKS: `stack_below=700` flips the outer row on
  both phones (`row#0 axis vertical` on the iPhone and the emulator).

  ONE COMPOSE DEFECT FOUND AND FIXED (docs/traps.md, this session): a
  re-declared header cleared the table geometry and nothing republished
  it, so every table read after the day tick answered "no live table
  viewport geometry". Three of the leg's four failures were that.

  WHAT STILL BLOCKS IT, both measured, neither a ceiling:
  0. THE CRASH IS FIXED (2026-08-29, docs/traps.md) and the screen now
     fails CLEANLY on the zero-WIDTH track below, which the crash had been
     masking. What is measured since:
       - the ledger table is handed `maxH=608` where it had INFINITY, and
         the recent table 432; the height half is healthy.
       - it is handed `minW=0 maxW=0`, and the track arithmetic is
         `(maxWidth - 2*padX)/density`, so a zero width IS the -32dp.
         The number is not a mystery; the zero is.
       - its CELL receives `maxW=0` while the summary side's cells all
         receive 288.
     TWO CONCLUSIONS DRAWN HERE WERE WRONG, both from targets addressed by
     INDEX. `expect_axis row#1 "vertical"` answered "horizontal" and was
     read as "the entry's row never flips" — but the trace had already
     shown a KIND_ROW rendering with `vert=true` on that screen, so row#1
     was some other row (the mark's, most likely). An `a11y_id` added to
     name it then answered "no such target row@txnrow" on Compose while
     the same spelling resolves on iOS, which is its own unwired-lookup
     question and was NOT chased. NAME THE ROW FIRST, and confirm the name
     resolves, before believing anything about which container flipped.

  1. THE TRANSACTIONS SCREEN'S GROWN LEDGER GETS NO TRACK. THE CAUSE
     RECORDED HERE WAS WRONG, and was disproved 2026-08-29 by four
     experiments that each left the number BYTE-IDENTICAL at `track
     -32dp, drawn 0dp, content 281dp`: shortening the `net` line to one
     word, shortening ALL FOUR summary labels to one character,
     REMOVING the recent table from the summary column entirely, and
     removing that column's `align="stretch"`. The sibling's width is
     therefore not what starves the ledger — nothing about the summary
     column is. A constant -32 is the card inset applied to a track of
     ZERO, i.e. the table is never laid out at all.
     WHAT IS ALSO NOW KNOWN, from the SwiftUI side: stack the same row
     with `stack_below` and iOS loses the ledger's viewport too
     (`rect=311x0` — a real width, zero height), because a grown child
     under a summary that is already a screenful gets no leftover. So
     this is not a Compose-only defect and not a width defect; it is a
     grown table with nowhere to live on a phone. A blunt fix — giving
     any starved grower a containerful — was tried and REVERTED: it
     changed track arithmetic wherever the leftover legitimately reaches
     zero and cost 16 sizepolicy legs on the mac lane.
     KEY: txnrow, grown ledger no track, track -32dp, four falsified
  2. AT 320dp THE ACCOUNT TABLES OVERFLOW: columns resolve to 263dp in a
     256dp track. The pool device's 320dp width is deliberate (the
     lane's compact-class coverage), and kaya has no ruling on what a
     table does when its columns do not fit — today it clamps on Compose
     and clips on iOS. That is a design question, not a bug to fix here,
     and D4's keyed arms (docs/adaptive-layout-plan.md) have their first
     real use case in it.

  AND ONE TRAP THIS COST A SESSION TO FIND: an interrupted extraction
  leaves the pyhost PERMANENTLY broken. MainActivity.extractPython walks
  assets/python and the walk COPIES `kaya-stamp` itself, which sorts
  between `app` and `lib` — so a process killed while the stdlib is
  still copying leaves a stamped, half-extracted tree, and every later
  launch matches the stamp and skips the repair. The app then dies at
  `ModuleNotFoundError: No module named 'importlib'` before any scene
  exists, which reads exactly like a slow or wedged guest. `pm clear` is
  the recovery. The fix is to extract to a sibling directory and rename,
  or to skip the stamp asset in the walk and let the final write be the
  only one.
  KEY: pyhost extraction, kaya-stamp, importlib, extractPython

- ~~**GAP — two iOS legs are INTERMITTENT**~~ — BOTH CLOSED 2026-08-29.
  `varied-python` was a park that mistook its own correction for the
  reader's scroll; `adaptive-swiftui` was a leg whose premise is the
  window's WIDTH on a device whose orientation nothing pinned. Each
  diagnosis is below, and each arithmetic is in docs/traps.md.
  KEY: ios flaky, varied-python band, adaptive-swiftui row@narrow,
  column@varied windows 147, first metrics report

  Across six iOS lane runs on 2026-08-29, two legs alternate:
  `varied-python` reports a row band three short ("column@varied windows
  \"147 300\", wanted \"150 300\"" — also seen as 145 and 148), and
  `adaptive-swiftui` reads "row@narrow axis horizontal, wanted vertical",
  which is the width breakpoint not having fired from the FIRST metrics
  report. Each passes in some runs and fails in others; no run has failed
  both.

  NOT THE TABLE WORK, measured rather than assumed: the same
  `varied-python` failure reproduces on cbcd5f9's KayaSwiftUI.swift —
  the tree BEFORE the iOS synthesized tier learned to scroll its columns
  — with everything else identical. So this predates that change and is
  its own problem.

  Both smell like first-layout timing on a phone that never resizes: the
  band is computed from a viewport the tier reports, and the breakpoint
  waits on a window-metrics report that arrives once.

  THE RATE, measured by running the scene DIRECTLY on a booted simulator
  rather than through the lane (20s a run instead of seven minutes):
  `varied` failed 2 of 5, at 145 and at 147. That loop is how the next
  session should work — not another lane run.

  THE RECORDER NOW COVERS THIS LANE (2026-08-29). tools/lib/flightrec.sh
  was wired into validate-mac and deploy-win only, so the two lanes with
  intermittent legs kept nothing when a rerun went green — which is the
  exact thing the recorder's own header says it exists to stop. run-sim
  now journals EVERY leg and bundles the leg log plus the booted-device
  list on a failure. WHAT IT STILL CANNOT SEE is the tier's own numbers:
  the leg log carries the harness's step timeline, but nothing says WHEN
  the first window-metrics report landed or what viewport height the band
  was computed from. Those two lines are the next increment, and the
  recorder is the pipe they should go into.
  KEY: flightrec ios, run-sim journal, intermittent leg evidence

  `varied-python` IS FIXED (2026-08-29), and the fix came off the pipe
  above within twenty minutes of it existing: two temporary kayaDiag
  lines in the synthesized tier — one per band publish, one per computed
  `visible` — plus the park's own decisions, then `tools/ios/run-sim.sh
  python`, which is TWO legs and 35 seconds, looped until red. THE
  ARITHMETIC IT CAUGHT is in docs/traps.md; in one line, a correction
  above the viewport moves the scroll offset as well as the band, and the
  park read that as the reader scrolling and abandoned its anchor. Ten
  further runs, eight of them consecutive after the fix (the loop's own
  ceiling stopped it, not a failure), zero yields, and the anchoring step
  costs ~880ms where the failing run burned 15,790ms of retry budget.
  The two high-volume diag lines came back OUT; the trap says where to
  put them again.

  WHAT IS STILL OPEN is `adaptive-swiftui` alone. The metrics diagnostic
  STAYED IN for it — `KAYA_DIAG ... metrics window=<id> <w>x<h>` at
  KayaHost.windowMetrics, the one chokepoint both reporters funnel
  through — so the next sighting says when the first report landed and
  what width it carried.

  `adaptive-swiftui` IS FIXED TOO (2026-08-29), and that metrics line is
  what closed it — not by catching a sighting, but by making the width
  readable at all. THE LEG WAS NEVER FLAKY IN THE CODE: its extra step
  asserts an always-narrow truth, `adaptive`'s breakpoint is 520, and the
  bundle declared NO supported orientations, so the app inherited the
  simulator's. The same phone reports 375x734 turned one way and 724x355
  turned the other; 724 is above the threshold, the core correctly
  applied no override, and the leg correctly said "horizontal". The
  verdict was right both times and only the premise moved, which is why
  no rerun could ever explain it. tools/ios/Info.plist.in pins portrait
  for both device families now, and tools/check-staging.sh holds it with
  the missing-key and the two-orientation branches each watched refusing.
  Full arithmetic, the pad canary, and the vacuous-loop lesson are in
  docs/traps.md.
  KEY: adaptive-swiftui narrow, UISupportedInterfaceOrientations,
  ios bundle orientation, check-staging N4 N5

- ~~**GAP — the mac NATIVE table cannot be reached when it overflows**~~ —
  CLOSED 2026-08-29, and the iOS SYNTHESIZED tier with it, so all five
  tiers answer the overflow ruling.
  KEY: mac table reachability, minWidth idealWidth, sizeThatFits,
  hasHorizontalScroller, documentVisibleRect, clip parks at trailing edge,
  KayaMacNativeTable, content 430 in viewport 430

  THE MAC: the representable answers PER PROPOSAL — the offer when there
  is one, its content capped by the WINDOW when there is not. Four earlier
  attempts are worth keeping because each named something: the scroller
  flag alone is inert (the scroll view was as wide as its own document);
  `idealWidth` makes the scroll view the clip and LOSES the hug; a cap in
  KayaFlex works on the mac and changes what a PHONE renders, moving
  varied's frozen band from 150 rows to 147 on iOS alone; and answering
  the fitting size before the table is measured PINS it at ~10pt, which
  leaves its columns no room to be measured in.

  TWO RULES IT LEFT BEHIND: no forced layout inside a harness read
  (gtk.rs's 1630 rule one platform over — the read holds the core and the
  run produced no verdict at all), and a deliberate scroll survives a
  relayout, with the leading-edge park keyed on the CLIP moving because
  AppKit keeps the visible RIGHT edge across a resize.

  RULING A'S GUARD WAS REWRITTEN by the maintainer's call rather than
  worked around: it asked the hug inside a 200pt window, where passing
  required the table's viewport to be wider than its own window. It now
  asks in kaya's own vocabulary — an ungrown column beside a grown
  sibling, in a window with room — and its self-test still reddens it.

  WHAT REMAINS is the shared conformance scene's WIRING: the guest and
  its .steps exist and pass by hand on the mac, but a scene forces a leg
  on every runner, and the two phones need the cut treatment while
  windows needs a launcher and an argument arm.

- ~~**DEPTH STUB: adaptive on winui**~~ — CLOSED 2026-08-28 by the
  adaptive milestone's breadth slice, exactly as this entry described:
  `core.axes` holds the override, `effective_vertical` folds it over the
  creation kind, and every direction decision reads the fold — reindex
  (which now clears the OTHER axis's definitions and stamps both attached
  indices, so a flip leaves no stale placement), the merged spacing arm
  (the gap rides the stacking axis), and the crossing test. The harness
  read answers from the Grid's OWN definitions rather than the variant,
  which is what makes it a render read. The stub is deleted and the
  windows leg wired (deploy-win's resize block, five languages).
  KEY: adaptive winui, axis-state pass, reindex vertical, depth stub adaptive

## CHORE — SYNTHESIZING A PAN INTO THE iOS SIMULATOR (2026-08-30)
KEY: simulator input, simdrive swipe, IndigoHIDMessageForScrollEvent, XCUITest driver, idb-companion

The maintainer asked for host-driven scrolling so visual checks need no
human in the loop. What is MEASURED, so nobody re-derives it:

- Synthetic CGEvents (any source, any tap point) reach the Simulator's
  MAC CHROME — a posted click opens its menus — and the DEVICE CONTENT
  VIEW ignores clicks, drags, wheel and keys alike (macOS 26 / iOS 26.5
  sim). System Events wants an Automation grant nobody has clicked.
  nixpkgs' idb-companion (a 2022 build) NSException-crashes on attach
  against this CoreSimulator.
- simdrive's HID path DELIVERS: every send answers ok, taps land (a
  degenerate `swipe` moved the table's columns drag). The new `swipe`
  verb sends down + interpolated down-state + up — idb's own encoding of
  a moving contact — and this runtime does NOT read it as a pan: a
  SwiftUI vertical scroll does not move. Move-phase values 0/3/4/5/6 in
  the mouse builder's state slot were each tried; none pans.
- `IndigoHIDMessageForScrollEvent` exists in SimulatorKit and its shape
  was read from the prologue: `(i32, i32, f64, f64, f64)` stored at
  +0x30/+0x34/+0x3c/+0x44/+0x4c of a complete 0xc0-byte envelope
  (eventType 1, inner 0xa0, kind 6) that sends as-is. Sends answer ok;
  no permutation moved content — (x,y,delta) ratios, raw values,
  dx/dy-first, phase sequences 1/2…/3 in the first int. The missing
  ingredient is unknown; possibly a display/source id or a runtime gate.

THE GUARANTEED PATH if pan synthesis is ever needed: a resident XCUITest
driver (XCUICoordinate press/drag), the industry answer — a small runner
app in tools/ios beside simdrive. Until a need bigger than screenshot
framing exists, the fold's visual checks get by without it: the shorter
recents (RECENT = 8) puts the seam and the ledger's opening on the FIRST
screen of a phone, which was the capture this hunt was for.

## WATCH — AN iOS GUEST'S PANIC MESSAGE DIES WITH ITS PTY (2026-08-30)
KEY: pyhost panic message, kaya_run abort, ips crash report, panic hook file

pyhost aborted once tonight (SIGABRT, a Rust panic crossing `kaya_run`'s
extern "C" boundary — `panic_cannot_unwind`), seconds after a scripted
click into the folded Transactions screen on a COLD first launch of a
fresh install: ~/Library/Logs/DiagnosticReports/pyhost-2026-08-30-094806.ips.
Six deliberate cold-start repetitions of the same script did not
reproduce it, and the panic MESSAGE is unrecovered because the launch
had no console: on iOS a plain `simctl launch` gives the process no pty,
so a Rust panic's one diagnostic sentence goes nowhere durable. The .ips
names the frame and never the assert. THE FIX SHAPE, when this recurs: a
panic hook (or stderr dup) writing into the app container — the flight
recorder's ONE-FAILURE-IS-ENOUGH rule applied to the guest's own last
words — wired in pyhost-main or the host entry, so the next single
occurrence arrives with its sentence attached.
