# The third robustness pass's triage of the ledger's open flakes (survey 2026-09-06)

Written by a research agent from docs/deferred.md at 7cf96f42's parent; the input to the exclusive token's design (docs/HACKING.md, "Exclusive legs") — its line numbers are that revision's.


Read-only survey, 2026-09-06. Line numbers are docs/deferred.md at the survey's HEAD
(11,892 lines, tree clean at 7a58125 per the session's git status; the file has moved
since — cite by heading text as well as line).

Classification key:
- (A) load-sensitive leg — would pass on a quiet host; the fix is scheduling, not code.
- (B) real defect with a known fix not yet taken.
- (C) needs measurement first — the instrument is named.
- (D) not a flake (deferred feature) — listed in one line, not triaged.

---
## 1. WATCH — android `dnd-compose` under a matrix: the drag started and was acked, and the destination answered none
(line 10956; heading first 120 chars: "WATCH — android `dnd-compose` under a matrix: the drag started and was acked, and the destination answered none (first")

- KEY: `dnd-compose, drag ended none, KAYA_DRAG_STARTED, KAYA_ACK, matrix contention, android drag`
- Sightings: 25 numbered entries, of which 23 are sightings (the 21st and 25th are instrument/remedy notes). Dates 2026-09-04 (first, pickers matrix #1) through 2026-09-06 (matrix #17). Named matrices: pickers #1/#2/#3, tooltips #1/#3/#4, task-manager #1 (d9346958), #2 (4e3f74fa), #3 (d5b85612), #4 (f65bd32e), #6 (3d132bf7), #7 (75b3b36a), list-row #8/#9, #10, a two-lane run 2026-09-06 01:23, #11 (01:42, load 264), #12 (02:40, 5-min load 96), #14 (04:15), #15, #16, #17.
- Lane / legs: android lane; `dnd-compose`, `dnd-go`, `dnd-jvm`, and once `tasks-compose` (7th sighting). Every sighting green standalone the same hour (compose suite ALL PASS 47/50/135 legs repeatedly).
- Mechanism as stated: MEASURED, in three successive decodes. (i) stale destination box from the previous arrangement — CLOSED by `kayaAwaitSettledBox` (5th sighting's remedy, read green at the 6th: "every destination box printed `settled after 1 frame(s)` — the stale-arrangement cause is closed"). (ii) shape (a) `ended op=0 entered=0` — the gesture entered no target; shape (b) `dropped=1 ended=false` after 20s — ACTION_DRAG_ENDED never reached the app. (iii) FINAL measured cause, 25th entry: "`input draganddrop` runs a FIXED schedule inside one guest-side command … and a loaded emulator starts the system drag session so late that the moves are already spent, which is `KAYA_DRAG_STARTED` followed by `ended op=0 entered=0` with no DRAG_LOCATION ever reaching the app: the twenty-third and twenty-fourth sightings' exact reading".
- Load attribution, quoted: "Neither is a box the verb aimed wrong; both are the emulator's drag session under host contention (five lanes, the android lane's own pool of four)." And, importantly, the 17th sighting weakens it: "The first sighting with fewer than five lanes running, so 'five-lane contention' is no longer the whole premise". Also measured: "the android lane's own four emulators put an otherwise quiet host at a one-minute load of 7.4-8.4, so the lane alone pays the 1500ms it always paid".
- Remedy: **TAKEN** (25th entry, 2026-09-06). tools/android/run-emulator.py scales the injection duration by the host's one-minute load (`asked x load / 8`, capped 4500ms) and prints the number used with the load; and the injection is no longer `input draganddrop` at all but `input motionevent` UP/DOWN/HOLD-on-`KAYA_DRAG_STARTED`(4s)/8 MOVEs/UP-in-finally, with a device-global stale-press release in `kaya_teardown`. Read on the lane ALL PASS at one-minute loads 22-365. Cost recorded: "`dnd-compose` costs 48s at the cap where it costs 18-27s otherwise, and `dnd-jvm`/`dnd-go` 49s each — the drag legs are the android lane's slowest by a wide margin now, which its 520s ceiling has to be re-read against."
- OPEN residue: the android lane's 520s duration ceiling has not been re-read against the new drag-leg cost. No sighting yet under a matrix WITH the new injection.
- **Classification: (A) with the remedy already taken — verify, then re-read the ceiling.** The legs are `dnd-compose`, `dnd-go`, `dnd-jvm` (android lane spelling), plus `tasks-compose` once. Under quiet-host scheduling these have never failed. The one action left is a matrix on the fixed tree plus an android-lane ceiling raise (520s -> the new drag cost) — that is a (B) sub-item: **fix = raise tools/android/run-emulator.py's lane ceiling to cover three ~49s drag legs.**

## 2. WATCH — the dnd scene's keyed drag from a stamped row landed the EARLIER payload (windows `dnd_java`, linux `dnd-js-wayland`)
(line 11549)

- KEY: `dnd_java, dnd-js-wayland, dnd-jvm, windows drag, wayland drag, android drag, item y drag ended none, text target got text hello, touch slop, seven-pixel source, matrix contention`
- Sightings: 3. (1) 2026-09-05, task manager matrix #3 (d5b85612), windows lane, `dnd_java`; the lane at 879s against its 600 ceiling with the core rebuilt cold. (2) 2026-09-05, task manager matrix #7 (75b3b36a), linux lane, `dnd-js-wayland`, byte-identical three readings. (3) 2026-09-06, matrix #15, android lane, `dnd-jvm` — the first one READ, via the new aim line.
- Lane/legs: windows `dnd_java`; linux `dnd-js-wayland`; android `dnd-jvm`. Failing step is `drag label@item[y] to label#1`, seq=2 of the dnd leg.
- Mechanism: MEASURED on android only. "a press 3px inside a SEVEN-PIXEL-WIDE source — the stamped row's one-letter label 'y' — which is narrower than Android's own touch slop (8dp, 8px on this panel)". And: "So 'the earlier payload landed' was never a payload delivered: nothing was dropped, and the text target kept what seq=1 had put there." On windows and wayland the cause is UNREAD (hypothesis only).
- Load attribution: partial. The KEY line ends `matrix contention`; sighting 2 says "the drag FROM the stamped row `y` is the one that does not happen, under load, on whichever lane."
- Remedy: TAKEN on the touch platforms (D12, ruled 2026-09-06): Android takes `Modifier.minimumInteractiveComponentSize()` (48dp) innermost of the DnD surface, iOS a 44pt minimum; held by tools/check-universal-props.py with six watched negatives. Explicitly LEFT OPEN for desktop: "THE DESKTOP SIGHTINGS STAY OPEN. Windows (`dnd_java`) and wayland (`dnd-js-wayland`) read the same three strings from the same step, but a mouse has no touch slop and a 7px source is a legal target there, so their cause is unread: the next sighting on either lane is to be read through that arm's own drag lines before anyone assumes this one."
- **Classification: (C) needs measurement first, on the two desktop lanes.** Instrument named by the entry itself: the WinUI arm's own `KAYA_DRAG_EVENT` lines and the GTK arm's drag lines for that leg, i.e. port the android aim line (source/destination screen box, the aim point, dx/dy to the nearest edge, the resolved node id) to the WinUI and GTK `drag` verbs so the next sighting on `dnd_java` / `dnd-js-wayland` is read rather than classified. The android half is (B)-done.

## 3. WATCH (inside the DRAG AND DROP entry) — `dndwitness-in-x11`
(sightings at lines 10800-10826, inside the "DRAG AND DROP — LANDED…" entry at line 10634 whose own headline is not struck)

- KEY: the parent entry carries no KEY line for this WATCH (it lives inside the GTK depth-stub bullet). Greppable nouns: `dndwitness-in-x11`, `handed over copy`, `no drag yet`, `KAYA_DIAG dragdrive`.
- Sightings: 3. (1) 2026-09-05, task manager matrix #1 (d9346958, host load 3.8 at launch). (2) 2026-09-06, matrix #10 (the text-field fill slice, load 16 at launch), "the only red on the linux lane". (3) 2026-09-06, matrix #20 (the search field's breadth tree, load 7.7 at launch and 56 over five minutes by the verdict, "the windows VM at 102% beside it").
- Lane/leg: linux lane, x11 pool, leg `dndwitness-in-x11`.
- Mechanism: MEASURED at the third sighting, and it relocated the fault: "the failing half is KAYA'S OWN drag, the scene's first step `drag label#0 to label#3` inside kaya's window on x11 (`KAYA_DIAG dragdrive: x11 content at (5, 5); pressed (55, 77), released (73, 161)`, both points inside the 540x330 window), which never raised drag_ended; the witness's handover (`copy` then `none`) is the SECOND half and was never reached. So the press-across-two-windows reading is not the cause".
- Load attribution, quoted: "GTK's own drag under a contended host is (the android dnd class one lane over). Green standalone the same hour on the GTK agent's lane run (739 legs)."
- Remedy: none taken. The entry leaves owed: "The `KAYA_DIAG dragdrive` read the first sighting asked for is still owed." (satisfied for the second half at sighting 3, not for the injection pacing).
- **Classification: (A) load-sensitive leg — `dndwitness-in-x11` (linux lane, x11 pool)** — with a strong (B) candidate beside it: the android remedy's own mechanism (a fixed guest-side gesture schedule spent before the drag session exists) applies verbatim to the GTK/xdotool injection. **Fix = pace kaya's own x11 drag injection against the app's drag-start signal, as tools/android/run-emulator.py now does, instead of a fixed xdotool schedule.**

## 4. WATCH — `save-swiftui` under a matrix: the save sheet's Save was pressed once and the sheet stayed up
(line 7963)

- KEY: `save-swiftui, savepress, still up after 1 presses, savePressWindow, swallowed press, xcuidrive, matrix contention`
- Sightings: 1 (matrix #18, 2026-09-06, the robustness day's second round, five-minute load 77 by the verdict). Leg 118s, "the lane 614s against its 600s ceiling on that leg alone".
- Lane/leg: iOS lane, leg `save-swiftui` (the file_save step).
- Mechanism: PART MEASURED, PART OPEN. Measured and fixed the same hour: the round's own regression — savepress's per-press wait was handed `left(deadline)`, the whole remaining budget, "so the first press waited 44s for a dismissal that never came and the five presses behind it never ran"; now `min(savePressWindow, left(deadline))` (6s), held by tools/check-steps.py with a watched negative. Still open: "why a press on Save is not taken under load."
- Load attribution, quoted: "THE QUIET READING, taken the same hour on the swift suite standalone (ALL PASS): `press 1: Save offered keyboards 1->0 sheet gone` on every save leg — so on an idle host ONE press both drops the keyboard and saves".
- Remedy named: none taken for the swallowed press; the entry names the two candidates and the instrument: "the tap ends the name field's editing (the keyboard drops, the sheet stays) and a second press saves — or the tap is delivered to a bar mid-layout and nothing changes … The per-press line under the next contended matrix is the measurement."
- **Classification: (C) needs measurement first** — but note the six-press retry is now real again, so the practical exposure is one contended matrix away from being self-healing. Instrument: the per-press reading line already in `drive.log` (Save offered/absent, keyboards before and after, sheet gone or up, the name field's text) under the next contended matrix. Secondary: the iOS lane's 600s ceiling was exceeded by this one leg (614s) — a (B) ceiling item.

## 5. (struck heading, OPEN note) — `save-swiftui`: the XCUITest driver exited 65 before the sheet was driven
(line 7910; heading is struck, the CAUSE is measured and fixed, but the entry leaves an explicit OPEN ruling)

- KEY: `save-swiftui, driver exited 65, no file dialog live, file_choose draft, xcuidrive, matrix contention`
- Sightings: 2 (2026-09-05 task manager matrix #4 f65bd32e at one-minute load 3.7; 2026-09-06 matrix #17 at five-minute load 85, the iOS lane 609s).
- Mechanism: MEASURED. "`savename` tapped the save sheet's name field, slept a FIXED `pause(0.3)`, then called `XCUIApplication.typeText` — which RAISES … the raise unwinds out of `testResident`, the resident loop ends, xcodebuild answers 65, and every later leg on that phone is handless. Measured with the driver's own log on an IDLE host: the field takes 0.35-0.43s to become typeable, so the sleep was at its limit with nothing else running and a coin toss at five-minute load 85."
- Load attribution: the fixed sleep "was at its limit with nothing else running and a coin toss at five-minute load 85" — load is the trigger, the fixed sleep the cause; fixed by deadline-based `waitFor`.
- Remedy OPEN, quoted verbatim: "OPEN, for a ruling: nothing restarts a dead driver, so one death still costs the rest of that device's legs — a between-legs restart is a few lines and would make a red lane green with one leg lost."
- **Classification: (B) a real defect with a known fix not yet taken. Fix = restart a dead XCUITest driver between legs in tools/ios/run-sim.py (the entry sizes it at "a few lines").** This is the single highest-leverage robustness item in the file: it converts any one-leg driver death from a whole-device cascade into one lost leg.

## 6. GAP — the dialog, clipboard and gesture verbs still return before the app has answered (twelve verbs)
(line 11402)

- KEY: `ACTION_VERBS, await_answer, kayaAwaitAnswer, alert_choose, file_choose, file_save, clipboard_seed, drag, drag_file, context_open, shortcut, compose, scroll_to_row`
- The twelve: `alert_choose`, `file_dialog_goto`, `file_dialog_name`, `file_choose`, `file_save`, `clipboard_seed`, `drag`, `drag_file`, `context_open`, `shortcut`, `compose`, `scroll_to_row`.
- Sightings: not a sighting entry — it is the named remainder of the wait rule. Its two predecessors are struck and landed: five Compose action verbs (line 11317) and ten action verbs (line 11362), both 2026-09-06.
- Mechanism as stated: "Each is an action; several answer through a platform surface rather than a transaction (a dialog's own presentation, the drag session, the input method's composition), so each wants the same reading the ten had — is the app ASKED, and what answers — before a wait is wrapped around it."
- Load attribution: none in this entry, but it is the structural cause behind several load WATCHes above — an expect's clock starting with the answer still in flight. Note the overlap: `drag` is entry 1/2/3's verb, `clipboard_seed` is entry 7's, `file_save`/`file_choose` are entries 4/5's, `scroll_to_row` is entry 9's.
- Remedy: open by design; the verdicts go in tools/check-verbs.py's ACTION_VERBS, QUIET_ONLY and REFUSALS tables.
- **Classification: (B) a real defect with a known fix not yet taken. Fix = give each of the twelve a per-verb answer-wait (or a QUIET_ONLY/REFUSALS verdict) in all three runners, exactly as the fifteen already took.** This is the structural half of the robustness pass — it removes the "clock started before the app was asked" class from four separate WATCHes at once.

## 7. WATCH — `clipboard-python-wayland` under a contended matrix: every paste read "empty"
(line 11450)

- KEY: `clipboard-python-wayland, reads "empty", wl-copy, clipboard_seed, wayland focus, matrix contention, gtk_window_active, CLIP_GENERATION, clip_note, vtrace clipboard records, app_formats, foreign_targets`
- Sightings: 4. (1) 2026-09-04, pickers matrix #2, five-minute load 33 at launch, `clipboard-python-wayland`. (2) 2026-09-05, tooltips matrix #2, one-minute load 8.5 / five-minute 33, `clipboard-js-wayland`, green alone two minutes later (2s). (3) 2026-09-05, task manager matrix #3 (d5b85612, one-minute load 8.8, fifteen-minute 11.5), `clipboard-rust-wayland`. (4) 2026-09-06, matrix #12 (the `fill` knob, five-minute load 96 by its end), `clipboard-js-x11` — the FIRST paste on x11.
- Lane/legs: linux lane, both pools: `clipboard-python-wayland`, `clipboard-js-wayland`, `clipboard-rust-wayland`, `clipboard-js-x11`.
- Mechanism: MEASURED by reading, and the FIRST hypothesis was REFUTED. Fixed: "`materialize` decides from THE APP'S OWN `formats()` and nothing else, while `clipboard_seed` waited only for the FOREIGN TARGETS list … a read taken there answers None, which every guest renders as `\"empty\"`. That is the x11 twin's shape exactly." The seed now also waits for `CLIP_GENERATION` to move AND the app's own offer to carry the seeded kind. Quiet-host cost `rounds=1 ms=0-2`.
- The refuted premise, quoted: "AND THE PREMISE THIS ENTRY NAMED IS NOT MEASURABLE THE WAY IT ASKED. `gtk_window_is_active()` reads `false` on EVERY record of a GREEN wayland leg … An instrument printing `window_active=false` beside a red wayland leg would have CONFIRMED the focus theory and sent the next reader after focus (docs/traps.md)."
- Load attribution, quoted: sighting 4 — "The linux lane standalone launched right after: ALL PASS, 739 legs, the x11 leg among them — load, not code."
- Remedy: TAKEN for the seed race (guarded by two tools/check-gtk.py census entries, each perturbed into the shipped race on every run). Left named: "ON THE NEXT SIGHTING: read the `seed … settled` line's `rounds`/`ms` … and the failing step's own `offers=`/`answered` pair".
- **Classification: (A) load-sensitive legs with the known race already removed — verify.** Legs, lane spelling: `clipboard-python-wayland`, `clipboard-js-wayland`, `clipboard-rust-wayland`, `clipboard-js-x11` (linux lane; 16 clipboard legs total across both pools). Residue is (C): one contended matrix reading the new records. Note `clipboard_seed` is also one of entry 6's twelve verbs.

## 8. WATCH — the android portfolio leg reads the pre-navigation title
(line 4179; KEY line is at the FOOT of the entry, line 4232)

- KEY: `android portfolio title, wanted Transactions, title propagation`
- Sightings: 5. (1) 2026-08-31, the seventh matrix of a saturated stretch, fifteen-minute load 53.8 (docs/measurements/validate-all-conversion-2026-09-01.md). (2) 2026-09-01 ~12:00, "under an otherwise-clean load-gated matrix, ~30s into the leg". (3)+(4) 2026-09-01 15:26 and 16:04, the JS binding day's second and third matrices. (5) 2026-09-02 02:15, matrix 19, host load 4 at launch.
- Lane/leg: android lane, `portfolio-python`. Same sentence every time: `title "portfolio", wanted "Transactions"`.
- Mechanism: MEASURED at sighting 4 and re-read at 5. "the click landed 240ms after the pop, inside the popped-to pane's entrance animation, which is the shape docs/traps.md's Compose entrance-drop entry measured." At sighting 5, with the fill split off the push: "'no push in 5s' now reads as THE CLICK NEVER REACHED THE HANDLER — the entrance-drop window docs/traps.md measured (~half a second) on a click 145-240ms after a pop."
- Load attribution: mixed and explicitly weakened. Sighting 2 was "under an otherwise-clean load-gated matrix"; sighting 5 at "host load 4 at launch". So this one is NOT primarily a load flake.
- Remedy: TAKEN. "REMEDY TAKEN IN THE SCENE (tools/scenes/portfolio.steps): every `back` settles 600ms past the transition before the scene clicks again, the trap's own measured remedy ('the same click after a settle 800 landed, every time'). The WATCH stays: the next sighting after the settle is a different premise."
- **Classification: (B) real defect, remedy taken at the SCENE but not at the CAUSE.** The cause is that a click inside a Compose/SwiftUI entrance transition is dropped with no error — a real app defect papered over by a scene settle. The proper fix is entry 6's rule applied to `click` past a `back`: `back` is now in the ten-verb wait rule (struck, line 11362), so the residue is the transition window itself. Not a quiet-host item.

## 9. WATCH — the mac portfolio leg's pushed entry popped across the fold round trip, once
(line 9626)

- KEY: `portfolio-python-swiftui, entries 0 wanted 1, expect_folded, back push resize, NavigationStack pop, matrix contention`
- Sightings: 4. (1) 2026-08-31 end-of-day matrix, five lanes contended. (2) 2026-09-01 evening, the ninth matrix of the JS sugar day. (3) 2026-09-01 22:20, the twelfth matrix, WITH the instrument. (4) 2026-09-02 02:15, matrix 19, host load 4 at launch.
- Lane/leg: mac lane, `portfolio-python-swiftui`.
- Mechanism: MEASURED twice, and the first measured cause was superseded. Sighting 3: "`click button#1 145ms after the last pop; entries=0` … no push_entry line between them, so the push NEVER REACHED THE MODEL inside the step ceiling: not a surface lagging, a starved guest." Sighting 4: "byte for byte the third sighting's instrument, on a QUIET host … The starved-host reading no longer fits; what fits both is the click landing inside the pop's transition and being dropped".
- Load attribution, quoted (sighting 3): "the host's fifteen-minute load was 153-189 with a browser at 120% CPU and 4.7 GB of swap beside the five lanes" — then explicitly retracted at sighting 4 ("on a QUIET host").
- Remedy: TWO taken. (a) guests/python/portfolio.py splits the 15,003-row fill out of the push's transaction (measured click +532ms, title +599ms). (b) tools/scenes/portfolio.steps settles 600ms after every `back`. "The WATCH stays for a sighting after the settle."
- **Classification: (B) same defect as #8, same fix, one platform over — a click delivered inside a navigation transition is silently dropped on BOTH SwiftUI and Compose.** The scene settle is a workaround. Not a quiet-host item: sighting 4 was on a quiet host.

## 10. WATCH — iOS varied-python: `scroll_to_row r100` landed the band at 98
(line 10881)

- KEY: `varied-python, scroll_to_row, expect_window, first visible, synthesized tier, variable row heights, "98 300"`
- Sightings: 2. (1) 2026-09-03, the dnd core's second matrix at 10:05 — "the pool free, every other lane green". (2) 2026-09-05, "on a standalone iOS lane (not a matrix)".
- Lane/leg: iOS lane, `varied-python`. Reading `column@varied windows "98 300"` 15ms after `scroll_to_row column@varied r100`, held for the whole retry window.
- Mechanism: HYPOTHESIS, not measured. "varied's rows are VARIABLE HEIGHT … so the premise to pin is the synthesized tier's landing arithmetic when the rows just above the target were never measured: an estimate-based offset for r100 that leaves rows 98-99 inside the viewport reads as '98'."
- Load attribution: NONE — and pointedly the opposite: sighting 1 had "the pool free, every other lane green"; sighting 2 was standalone, not a matrix.
- Remedy: not taken; the instrument is owed. "the instrument (`scroll_to_row`'s settled offset and the measured-versus-estimated heights of the six rows above the target) is owed on the next touch of the synthesized tier."
- **Classification: (C) needs measurement first — and it is NOT a load flake.** Instrument, verbatim: `scroll_to_row`'s own answer with the offset it settled at, plus the measured-versus-estimated heights of the six rows above the target. Note `scroll_to_row` is also one of entry 6's twelve verbs, and a "15 ms after" reading is exactly the no-answer-wait shape.

## 11. WATCH — save-jvm once died to AccessDeniedException on /sdcard/Documents (the android dialog "ghost" family)
(line 7066; the longest open flake entry in the file, ~530 lines)

- KEY: `save-jvm AccessDenied, sdcard Documents, storage state, straggler back, appResumed, KAYA_DIALOG_SEEN, KAYA_DIALOG_UNSEEN, windowCensus, dialogReport, wait for adding window timeout, OnPreDrawListener, first-draw admission, android lane barrier, four-phone Android pool, greedy makespan, nice -n 10, a11y_hygiene`
- Sightings: 14 numbered plus a related save-compose one and two windows-lane faces. Dates 2026-08-19 through 2026-08-30. Legs across the family: android `save-jvm`, `save-compose`, `filedialog-jvm`, `filedialog-go`; windows `filedialog_rust` (2026-08-26, twice).
- Mechanism: MEASURED in several faces, one still open. Closed faces: DocumentsUI cold start against a 5s deadline (fixed, `DIALOG_LAUNCH_BUDGET_NS = 20s`); the a11y window list lagging in both directions (fixed, two-consecutive-absence debounce); the straggler BACK (fixed, WINDOWS_CHANGE_REMOVED as a freshness signal + windowEpoch gate). OPEN face: "the loss sits between DocumentsUI's finish and ActivityManager's delivery to a RESUMED, input-processing caller."
- Load attribution, quoted: "it fired one matrix after a cold boot, always save-jvm, always under the heaviest five-lane contention (the concurrent-matrix shape raised it) — a real race in which DocumentsUI answers a dialog with nothing, not a tired emulator." And on the windows face: "each lane green standalone minutes later. Logged, not chased".
- Remedy: NEEDS A RULING, quoted: "If that slice shows a clean setResult+finish, this is an AMS-side race the harness may need to tolerate — a remedy that needs Akhil's ruling, since retrying a save leg would launder exactly the class of bug kaya's own users would hit." And the recorded escalation: "the in-process cancel (option B) is the RECORDED ESCALATION if this ever fires again."
- Status note: quiet since the 13th sighting 2026-08-27 ("21 android dialog-family leg samples on 2026-08-30, all PASS at 8-37s"); the duration-anomaly half is CLOSED.
- **Classification: (A) load-sensitive legs, with a ruling pending.** Legs, lane spelling: android `save-jvm`, `save-compose`, `filedialog-jvm`, `filedialog-go`; windows `filedialog_rust`. The remedy the entry names (retry / in-process cancel) is deliberately withheld because it would launder a user-visible bug — which makes quiet scheduling the ONLY acceptable mitigation for this family. This is the strongest single argument in the ledger for fine-grained scheduling.

## 12. WATCH — AN iOS GUEST'S PANIC MESSAGE DIES WITH ITS PTY
(line 10586)

- KEY: `pyhost panic message, kaya_run abort, ips crash report, panic hook file`
- Sightings: 1 (2026-08-30, `pyhost` SIGABRT seconds after a scripted click into the folded Transactions screen on a cold first launch of a fresh install; six deliberate cold-start repetitions did not reproduce).
- Lane/leg: iOS lane, the python host (`pyhost`), the portfolio/Transactions script.
- Mechanism: unknown — the panic MESSAGE was unrecoverable ("on iOS a plain `simctl launch` gives the process no pty").
- Load attribution: none stated.
- Remedy: the INSTRUMENT is taken (crates/kaya/src/fault.rs `log_panics`, `KAYA_PANIC_LOG` set per leg through SIMCTL_CHILD_, copied by `pull_container_files`). "The WATCH stays for the sighting itself: the next occurrence arrives with its sentence, and that is what closes it."
- **Classification: (C) needs measurement first — the instrument is already in, so this is a wait-for-sighting, no work.** Note it is the SAME script as entries 8/9 (a click into the folded Transactions screen), so it may be that class's crashing face.

## 13. GAP — `dndwitness-in-x11` (see entry 3) and #14 below share the pacing mechanism

## 14. Struck heading, live residue — the iOS sheets shrug off single taps under a concurrent matrix
(line 7653, heading struck)
(entry 13 above is a cross-reference only; the content is entry 3.)

- KEY: `ios save sheet, presses of Save, rounds of choosing, simdrive retap, KAYA_SIMDRIVE_LOG, ios-simdrive-logs, LocalStorage, FP -1005, Index out of sync, empty didPickDocumentURLs, export preflight, simctl listapps, dev.kaya. bundle cleanup, retained app data`
- Struck 2026-08-31 ("the tap-dropping reading was FALSIFIED by its own instruments"), but the entry records TWO live residues and TWO post-strike sightings:
  - Post-strike sighting 2026-09-01 22:00, matrix #11: iOS `filedialog-go`, `no row named picked; the picker lists ['kaya-picked-33143']`, "on a host whose fifteen-minute load was 143 with 4.7 GB of swap in use and a browser at 120% CPU beside the five lanes; simdrive's own reads logged bridge_slow at 651, 503 and 935ms in the same leg, the starved-runloop face". Verbatim on load: "Every other iOS leg passed and the same leg is green in every quiet matrix; recorded, not rerun for its own sake."
  - Post-strike sighting 2026-09-02 02:15, matrix 19, **host quiet at launch**: the same leg, the same sentence, but "34 reads, slowest 11ms, zero timeouts, zero taps sent" — "An aim miss at the parent directory with a healthy bridge".
  - Named open face, twice: "the older six-delivered-and-ignored-taps sighting is still a different open face" (line 7896) and "this still does not close the distinct six-delivered-and-ignored-taps face" (line 7908). The 10th sighting measured it: "six taps delivered (down=ok up=ok) to Save at ONE fixed centre (324,92) across 46303ms, the hit test answered by the real picker process … and the bridge serving 3245 reads with the SLOWEST AT 31ms and zero timeouts. The sheet was honestly up, the runloop was demonstrably healthy, and the taps were DELIVERED AND IGNORED".
- Note: this whole family predates the XCUITest driver, which SUBSUMED simdrive on 2026-09-02 (line 10493). The delivered-and-ignored face is the direct ancestor of entry 4's open question ("why a press on Save is not taken under load").
- **Classification: mixed. The starved-runloop face is (A) — iOS `filedialog-go`. The delivered-and-ignored face and the quiet-host aim miss are (C)** — and the instrument is entry 4's per-press reading line, which now exists in the XCUI driver. Recommend folding entry 4 and this face into ONE watch, since simdrive is gone and only the XCUI driver's readings can settle it.

## 15. Struck heading, live residue — a windows dialog leg's process is held ~60s from ITS OWN START
(line 7600, heading struck 2026-08-31)

- KEY: `dialog leg 64s, TerminateProcess, harness_exit, exit grace hostage, FileChoose stall, loader lock, DLL_PROCESS_DETACH, win_exit_tests, windows duration anomaly`
- Sightings: many across one afternoon (2026-08-27), all seven windows dialog-family legs (`filedialog` x5, `save_rust`, `editor_go`) pinned at 64s. Measured quiet 2026-08-30 over three full windows lane runs.
- Load attribution: explicitly REFUTED — "host load uncorrelated (the fastest run carried the highest load)".
- Residue, quoted: "Residual, unclosed but costless: the captor's identity (which IO — WebDAV or cloud-files) was never named, and the 20.8s mid-scene FileChoose stall class is uncapped — unobserved in 21 dialog-leg samples."
- **Classification: (C) needs measurement first, and it is explicitly NOT a load flake.** Instrument named: "the held process's THREAD WAIT STATES and module list, taken mid-hang via `powershell -EncodedCommand`", plus WebClient/WebDAV service state. Cost is bounded (~verdict+6s), so low priority.

## 16. The windows caption-centre probe's "honest 10/11 under-run"
(mentioned at line 4054 as a "pre-existing flake class"; line 8204 records its speed fix; it has NO ledger entry of its own)

- KEY: none — this class is not a ledger entry. Greppable: `caption-centre probe`, `PROVE: done`, `center_caption_title` (line 4858).
- Sightings: at least three named in the 2026-09-01 conversion record ("the third such reading in three days, each recorded as a pre-existing class" per commit 7a58125's message), plus the driver-matrix sighting at line 4054.
- Mechanism: MEASURED, and the remedy is already IN per commit 7a58125: "the mechanism is the guest's own `settle 45000` against a probe that took 75s under the matrix, so the eleventh width ran against a window that had left; the settle is 180s (the runner kills the guest the moment the probe is done), the poll covers it, and an expiry prints that the probe was cut off".
- **Classification: (B) fixed, ledger-invisible.** It is worth noting that this class was never given a ledger entry, so a survey of docs/deferred.md alone under-counts the windows lane's flake history by one class.

## 17. Load-adjacent but NOT a flake — Android recording anchors flake under load
(line 2979, a bullet inside "Testing / infrastructure")

- One sighting: "one todos-rust leg failed extraction with 'anchor implausible (leg spans -10106..-6353ms)' — screenrecord buffered its start ~10s, the kill-minus-duration arithmetic drifted by that much, and the plausibility guard rightly refused to fabricate stills (the scene itself passed; a rerun was clean)."
- Mechanism: MEASURED. Remedy named but not taken: "if it recurs, Android earns a content-anchored scheme the way iOS earned its appearance-flip fiducial — the arithmetic anchor is the last one left."
- **Classification: (B) known fix not taken — a content-anchored (fiducial) recording anchor for Android.** Recording mode only; does not affect lane verdicts.

---

# (D) Open entries that are deferred FEATURES, not flakes — listed, not triaged

- line 507 `Next milestones (in rough priority order)` — the roadmap section.
- line 1646 `Protocol / core`; line 2023 `Bindings / ergonomics`; line 2166 `Testing / infrastructure` — the three standing backlog sections.
- line 3836 `Retire the hand-edited shell and cmd scripts` — the .cmd generation half (188-file HOLD).
- line 4234 `MAYBE: read Windows accessibility client-side`; 4265 `MAYBE: the WinUI seed writes once too`; 4292 `MAYBE: the other three backends say nothing when a standard command is inert`; 4327 `MAYBE: identity.toml carries a DEFAULT accent seed`.
- line 4346 / 4367 / 4393 — three `SOLVED:` entries kept for their record.
- line 4880 `The Linux runtime icon route is X11-only until GTK 4.20`.
- line 5100 `The caption mark's system-menu affordance waits on two bindings`; 5115 `The identity scene cannot SEE the promoted caption's mark`; 5166 `iOS identity packaging is proven on the simulator only`; 5176 `The iOS pasteboard witness has its marker; two questions stay open`.
- line 5516 `The typeface scene's depth stubs`; 5753 `Styling follow-ups the fan-out surfaced`.
- line 6737 `Harness copy-target typed keys — deferred grammar decision`.
- line 7049 `Compose pins a hugging container to its content before it fills` — a design note; the guard exists and no scene can see it.
- line 8098 `Multi-column residue — phone-lane frozen scenes and the unmeasured floors` (holds the pointer to the Compose entrance-drop trap that entries 8 and 9 turn on).
- line 8119 `The refusal affordances are never asserted PRESENT` — a real gate gap, MILESTONE-sized, not a flake.
- line 8129 `HOLD — Python's Signal comparison operators await a use-case`.
- line 8171 `Test-speed profile 2026-08-20`.
- line 9266 `NOTE — virtualization design inputs from the fix slice`.
- line 9611 `HOLD — the mirrored adaptive sugar awaits demand`; 9712 `HOLD — the windows guest-side command scripts convert to python`; 9732 `HOLD — keyed when/otherwise arms await a use-case`.
- line 9990 `DESIGN — THE LINUX OUT-OF-BOX LOOK`.
- line 10539 `CHORE — SYNTHESIZING A PAN INTO THE iOS SIMULATOR` (built, opt-in, waiting on the subsumption slice).
- line 10616 `PERF — THE JS WIRE ENCODER ALLOCATES TWICE PER SCALAR` — 15.6x on the table, desktop-only, an unclaimed speedup.
- line 10634 `DRAG AND DROP — LANDED …` — the headline is unstruck only because the mac cross-app witness is owed; the `dndwitness-in-x11` WATCH lives in its body (entry 3).
- line 11829 `GAP — kaya has no filtered view over a collection`.
- line 11852 `DEFERRED — a `submitted` occurrence for text fields`.

---

# CORRECTIONS FROM THE CODE (the ledger is behind the tree in two places)

1. Entry 1's residue is already paid. tools/validate-all.py:252 sets the android ceiling to **660**, not 520, with the reason stated in the table: "660 since 2026-09-06: the drag injection is START-GATED now … so the three dnd legs cost 48-49s each under a matrix where they cost 22-27s, roughly +100s on a lane whose last five matrices read 458-495s; 660 is 1.12x over 590, to be re-read on the next quiet matrices."
2. Entry 4's iOS overshoot is also paid: tools/validate-all.py:236 reads **640** ("640 since 2026-09-06: the roster grew 128 -> 131 legs with the search scene").
3. The android drag remedy is live in tools/android/run-emulator.py (lines ~143-172 carry the load-scaling and the no-retry reasoning, citing this ledger entry by name).
4. tools/linux/dragdrive.py:116 already cites "docs/deferred.md, the dndwitness-in-x11 sightings: under load the …" — so the linux drag driver knows about entry 3's class.

---

# THE INPUT TO A QUIET-SCHEDULING DESIGN: every leg the ledger says failed ONLY under a matrix and passed standalone

Grouped by lane, spelled as the lane spells them. "standalone" = the entry records a green run of the same leg or suite alone, usually the same hour.

## android lane (tools/android/run-emulator.py)
| leg | entry | ledger line | standalone evidence quoted in the entry |
|---|---|---|---|
| `dnd-compose` | 1 | 10956 | "The same suite standalone the same hour: `dnd-compose: PASS (21s)` … 47 legs ALL PASS"; "the compose suite ALL PASS 50 legs standalone four times the same evening" |
| `dnd-go` | 1 | 11016, 11021, 11040, 11052, 11058, 11070, 11075, 11123, 11138 | same suite standalone ALL PASS 50 |
| `dnd-jvm` | 1, 2 | 10994, 11049, 11077, 11118, 11570 | "Green alone the same hour (ALL PASS 135)" |
| `tasks-compose` | 1 (7th sighting) | 11011 | the reorder step alone; "every other step of the new app's scene passed" |
| `portfolio-python` | 8, and the struck sort-click | 4179, 11620 | "The android lane standalone ten minutes after that matrix: ALL PASS, 136 legs, portfolio-python among them — load, not code" |
| `varied-python` | struck (11413) | 11413 | "The android lane standalone ten minutes later, load under 10: ALL PASS, 136 legs, varied-python among them" |
| `save-jvm` | 11 | 7066 | "One pool device, one matrix run, 4s-green solo on either side" |
| `save-compose` | 11 (related sighting) | 7303 | "The standalone lane passed with Compose/JVM/Go at 52/32/34s" |
| `filedialog-jvm` | 11 (9th sighting) | 7393 | the family's standing "green standalone" rule |
| `filedialog-go` | 11 (11th sighting) | 7454 | as above |

## linux lane (tools/linux/run-suites.sh)
| leg | entry | ledger line | standalone evidence |
|---|---|---|---|
| `clipboard-python-wayland` | 7 | 11450 | "the leg passes standalone" |
| `clipboard-js-wayland` | 7 | 11466 | "the leg green alone two minutes later (2s)" |
| `clipboard-rust-wayland` | 7 | 11476 | the family's rule |
| `clipboard-js-x11` | 7 | 11483 | "The linux lane standalone launched right after: ALL PASS, 739 legs, the x11 leg among them — load, not code" |
| `dnd-js-wayland` | 2 | 11561 | (no standalone run recorded for this one; the class's rule) |
| `dndwitness-in-x11` | 3 | 10800 | "Green standalone the same hour on the GTK agent's lane run (739 legs)" |
| `portfolio-python-wayland` | struck (4088) | 4088 | closed 2026-09-01 at the premise (fixed in gtk.rs) |

## windows lane (tools/lib/lanes/win.py)
| leg | entry | ledger line | standalone evidence |
|---|---|---|---|
| `dnd_java` | 2 | 11552 | "Every other dnd leg on the lane green, the lane at 879s against its 600 ceiling with the core rebuilt cold" |
| `filedialog_rust` | 11 (windows faces) | 7196, 7220 | "passed standalone on the immediate rerun"; "each lane green standalone minutes later. Logged, not chased" |
| the seven dialog legs (`filedialog` x5, `save_rust`, `editor_go`) | 15 | 7624 | load explicitly uncorrelated — do NOT put these in a quiet schedule on load grounds |
| the caption-centre probe | 16 | 4054 | "the windows caption-centre probe's honest 10/11 under-run" — remedy already in |

## iOS lane (tools/ios/run-sim.py)
| leg | entry | ledger line | standalone evidence |
|---|---|---|---|
| `save-swiftui` | 4, 5 | 7913, 7922, 7963 | "the same lane read ALL PASS standalone earlier the same day"; "THE QUIET READING, taken the same hour on the swift suite standalone (ALL PASS)" |
| `filedialog-go` | 14 | 7675 | "the same leg is green in every quiet matrix" — but the 2026-09-02 sighting was on a QUIET host, so this leg has two faces |
| `save-go`, `editor-go` | 14 | 7695, 7724, 7779, 7798 | "every one 100% green solo" |
| whole-lane admission (`picker-<udid>`) | struck (11289) | 11289 | "The lane standalone twenty minutes later: ALL PASS, 128 legs, every admission 11s" |
| `varied-python` (iOS) | 10 | 10881 | NOT load — sighting 1 had "the pool free", sighting 2 was standalone |

## mac lane (tools/validate-mac.py)
| leg | entry | ledger line | standalone evidence |
|---|---|---|---|
| `portfolio-python-swiftui` | 9, and the struck sort-click's mac half | 9626, 11684 | "The mac lane had passed this leg standalone minutes before and in the two matrices before that" — but sighting 4 was on a QUIET host |
| `save-c` (the C guest's save leg; mac lane leg names are `<scene>-<language>`, tools/lib/lanes/mac.py) | 4032 (inside the conversion entry) | 4032 | "lane run 1's one red (save-c under a 53.8% WindowServer, the pre-existing contention class)" |

## the gate sweep
| gate | entry | ledger line | standalone evidence |
|---|---|---|---|
| `kaya_app_checks` (bulk-insert growth bound) | struck (11240) | 11240 | "the sweep had passed 55/55 standalone forty minutes earlier on the same tree" — fixed 2026-09-06 by replacing the wall clock with counted work |

**Count: 24 distinct legs still open, plus one gate and three since-closed legs, across all five lanes** (android 10, linux 6, windows 2, iOS 4, mac 2; iOS `varied-python` and the windows dialog family are listed above but explicitly NOT load-sensitive). Every one of them is an input-injection, dialog, drag, clipboard or navigation-timing leg — none is a pure model or layout assertion. That is the shape of the whole class: **kaya's flakes are all in the legs that drive the platform's own input or presentation machinery from outside the process.**

---

# WHAT THE LEDGER ITSELF SAYS ABOUT SCHEDULING (for the maintainer's fine-grained-scheduling question)

## What already exists
- **Intra-lane isolation is already built, per lane.** tools/lib/lanes/win.py:57-63: "pooled where python is pooled, alone where python is alone … the pool DRAINS between blocks, so a one-leg block runs ALONE. The barriers are measured contention fixes, never style, and check-steps' serial clauses read this structure." `alone(leg)` at win.py:347. tools/linux/run-suites.sh has the same idiom ("RUST ALONE, and compiled", "ALONE BETWEEN DRAINS", "clipboard and a seat of its own").
- **Cross-lane isolation does not exist at all.** tools/validate-all.py:136-174 launches all five lanes at t0 unconditionally and only the gate sweep is scheduled (it waits on the android process, then runs at `nice -n 10`). There is no mechanism by which a leg can say "not while another lane is running".
- **The load is measured but never acted on.** tools/validate-all.py:113 reads `os.getloadavg()` at launch and prints it beside every anomaly; nothing consumes it as a scheduling input. The ONE place a load average now steers behaviour is tools/android/run-emulator.py's drag-duration scaling (entry 1's remedy) — and it worked: "READ ON THE LANE, all three suites ALL PASS: quiet, 1500ms and 187ms between moves; at one-minute loads of 22-365, the 4500ms cap".

## The gap this survey found
The 27 legs above are isolated from their OWN lane's neighbours and from nothing else. The android lane's own four emulators already put a quiet host at load 7.4-8.4 (entry 1, measured); five lanes put it at 96-365 (entries 1, 7, 8, 11). So the isolation the barriers buy is spent by the other four lanes.

## The three shapes a fine-grained schedule could take, ranked by what the ledger supports
1. **A cross-lane exclusive token for input-driving legs.** The 27 legs are already marked `alone` inside their lanes; extending that mark to a matrix-wide semaphore (one input-driving leg on the host at a time) would cover entries 1, 2, 3, 4, 7, 11 and 14 without touching any assertion. Cost: the drag/dialog/clipboard legs are the slowest in every lane, so serializing them across lanes lengthens the wall — the windows lane alone carries eight serial legs adding ~220s (validate-all.py:211-214).
2. **Load-scaled budgets rather than load-scaled scheduling.** Already proven once, on the android drag (entry 1's 25th note). Cheap, no wall cost, and it fits the ledger's own preference for measuring the host and adapting rather than waiting. The step deadline was just unified at 15s in all three runners for exactly this reason (struck entry, line 11645-11692).
3. **Do nothing to the schedule and take the named fixes.** Entries 5, 6, 8, 9 and 17 are real defects whose fixes are named and not taken; entries 10 and 15 are not load-sensitive at all. A quiet schedule would hide (5) and (6) rather than fix them.

## The one thing a quiet schedule must NOT do
Entry 11 states it directly: "a remedy that needs Akhil's ruling, since retrying a save leg would launder exactly the class of bug kaya's own users would hit." A scheduler that makes the android dialog ghost disappear has the same laundering property as a retry. The ledger's own doctrine (docs/deferred.md's flakes-are-premises rule) is that an intermittent leg is a correct verdict over an unpinned premise — so the scheduling change is defensible only for the legs whose premise is explicitly "the platform's own input pipeline under contention" (entries 1, 3, 7, 11, 14's starved face) and not for the ones whose cause is unread (entries 2-desktop, 4, 10, 15).

---

# THE RANKED WORK LIST

**(B) — known fix, not taken, no ruling needed**
1. **Restart a dead iOS XCUITest driver between legs** (entry 5, line 7953). The entry sizes it: "a between-legs restart is a few lines and would make a red lane green with one leg lost." Highest leverage in the file.
2. **The twelve verbs take the answer-wait rule** (entry 6, line 11402). Removes the started-clock class from entries 4, 7, 10 and both portfolio WATCHes at once.
3. **Pace kaya's own x11 drag injection against the app's drag-start signal** (entry 3), the android remedy's mechanism one lane over.
4. **A content-anchored Android recording anchor** (entry 17, line 2979).
5. **The click-inside-a-navigation-transition drop** (entries 8 and 9) — the scene settle is a workaround on two platforms; the defect is that a click delivered mid-transition is silently discarded.

**(C) — measurement first, instruments named**
6. Port the android aim line to the WinUI and GTK drag verbs (entry 2's desktop half).
7. The per-press reading under a contended matrix (entry 4), folded together with entry 14's delivered-and-ignored face.
8. `scroll_to_row`'s settled offset and the six rows' measured-vs-estimated heights (entry 10) — not a load flake.
9. The held windows process's thread wait states (entry 15) — not a load flake, bounded cost.
10. The iOS panic sentence (entry 12) — instrument in, nothing to do but wait.

**(A) — the quiet-scheduling candidates, exactly**
android `dnd-compose`, `dnd-go`, `dnd-jvm`, `tasks-compose`, `save-jvm`, `save-compose`, `filedialog-jvm`, `filedialog-go`, `portfolio-python`;
linux `clipboard-python-wayland`, `clipboard-js-wayland`, `clipboard-rust-wayland`, `clipboard-js-x11`, `dnd-js-wayland`, `dndwitness-in-x11`;
windows `dnd_java`, `filedialog_rust`;
iOS `save-swiftui`, `filedialog-go`, `save-go`, `editor-go`;
mac `portfolio-python-swiftui`, `save-c`.

**Ruling owed to the maintainer**
- Entry 11's android dialog ghost: retry / in-process cancel / tolerate — open since 2026-08-21, quiet since 2026-08-27.
- Whether a cross-lane exclusive token for input-driving legs is worth its wall cost (shape 1 above).

---

# STRUCK-OR-OPEN STATUS OF EVERY ENTRY THE CHARGE NAMED

| named in the charge | ledger line | struck? | where it is triaged here |
|---|---|---|---|
| "dnd-compose under a matrix" (android drag) | 10956 | **OPEN** | entry 1 — 23 sightings (25 numbered notes), remedy landed 2026-09-06, unverified under a matrix |
| "the dnd scene's keyed drag from a stamped row landed the EARLIER payload" | 11549 | **OPEN** | entry 2 — android half fixed (D12), desktop half open |
| the dndwitness-in-x11 sightings inside the DND entry's body | 10800-10826 | **OPEN** (parent heading also unstruck) | entry 3 — third sighting relocated the fault to kaya's own in-window x11 drag |
| "save-swiftui under a matrix: the save sheet's Save was pressed once and the sheet stayed up" | 7963 | **OPEN** | entry 4 |
| the driver-exit entry's OPEN note about restarting a dead iOS driver | 7910 (heading struck), note at 7953 | struck heading, **live OPEN note** | entry 5 — the single best-value fix in the file |
| "the dialog, clipboard and gesture verbs still return before the app has answered" (twelve verbs) | 11402 | **OPEN** | entry 6 |
| the wayland clipboard WATCH | 11450 | **OPEN** | entry 7 — seed race fixed 2026-09-06, focus premise refuted |
| the wayland portfolio WATCH | 4088 | **STRUCK** (CLOSED 2026-09-01, fixed in gtk.rs) | not triaged; no residue |
| the android varied-python first-step timeouts | 11413 | **STRUCK** (RESOLVED 2026-09-06, scene-ready wait in all three harnesses) | not triaged; no residue |
| the iOS admission WATCH | 11289 | **STRUCK** (FIXED 2026-09-06, same mechanism as the driver-exit entry) | not triaged; no residue |
| the caption-centre under-run | **no ledger entry** — mentioned at 4054, speed fix at 8204 | n/a | entry 16 — remedy is in commit 7a58125, the class is ledger-invisible |
| the portfolio title WATCHes | android 4179, mac 9626 | both **OPEN** | entries 8 and 9 — both remedied at the SCENE (600ms settle after `back`), the defect itself untouched |
| (also swept and open) iOS `varied-python` scroll_to_row | 10881 | **OPEN** | entry 10 — explicitly not a load flake |
| (also swept and open) android dialog ghost family | 7066 | **OPEN** | entry 11 — ruling owed since 2026-08-21 |
| (also swept and open) iOS guest panic message | 10586 | **OPEN** | entry 12 — instrument in, waiting for a sighting |
| (also swept, struck with live residue) iOS sheets shrug off taps | 7653 | struck, **two named open faces** | entry 14 |
| (also swept, struck with live residue) windows dialog leg held ~60s | 7600 | struck, **residual captor unnamed** | entry 15 |
| (also swept and open) android recording anchors | 2979 | **OPEN** | entry 17 |
| (also swept) android sort-click WATCH | 11620 | **STRUCK** 2026-09-06 (the 5s step deadline was the mac's number on the slowest host; now 15s in all three runners) | not triaged; its "LEFT OPEN" paragraph is entry 6's predecessor and is itself struck at 11317 |
| (also swept) kaya_app_checks growth bound | 11240 | **STRUCK** 2026-09-06 (counted work replaced the wall clock) | not triaged; the cleanest example in the file of a load flake fixed by changing the measurement rather than the schedule |
