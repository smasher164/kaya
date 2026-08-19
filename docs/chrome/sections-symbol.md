# expect_section_symbol — the section row's symbol, read from the real tree (progressive report)

Closes docs/deferred.md's **"Sections carry symbols with no harness
assertion" (2026-08-16)**. Tree at start: `64df4c4`, clean.
A concurrent task owns `guests/go/editor/**` — untouched here.

The failure class: during the icons slice the SwiftUI section-symbol
decode read the I64 at `body+20` (alignment padding) instead of `+24`,
NO icon rendered, and every lane stayed green. A capture caught it, not
a gate. The whole point of this slice is that the same perturbation now
goes RED.

## 0. What the scene already declares (read before writing the verb)

`guests/rust/sections.rs` — four symbols, two windows, both presentation
arms:

| window | section | symbol |
|---|---|---|
| primary (`bar`) | Feed | `home` |
| primary (`bar`) | Archive | `star` |
| library aux (`sidebar`) | Shelves | `search` |
| library aux (`sidebar`) | Loans | `lock` |

The two sidebar rows sit in the DESKTOP TAIL (the phone runners cut at
`expect_windows 1` / `click button#1`), so the bar rows are the
everywhere assertions and the sidebar rows are the desktops'.

(Sections appended as the work happens.)

## 1. The verb, everywhere at once (wave A)

- `crates/kaya/src/harness.rs` — `Step::ExpectSectionSymbol(title, name)`,
  the parse arm, `is_assertion`, ONE new Stage method
  `section_symbol(&self, title) -> String` (no default: a backend that
  forgets it fails to compile), the exec arm, three test mocks.
- `crates/kaya/src/gtk.rs` — `section_symbol_read` + the Stage arm.
- `crates/kaya/src/winui/mod.rs` — the Stage arm.
- `swift/KayaSwiftUI.swift` — `KayaSectionLabel` (ONE row body for all
  three switchers), `kayaSectionSymbolIdent`, `kayaSectionRowsMac`,
  `kayaSectionSymbolReadMac`, `kayaSectionRowsIOS`,
  `kayaSectionSymbolReadIOS`, `kayaSectionTrace`, the step arm.
- `android/.../KayaCompose.kt` — `SECTION_TAG_PREFIX`, `kayaSectionTag`,
  the `testTag` on the real `NavigationBarItem`, `kayaSectionRows`,
  `kayaSectionSymbolRead`, the step arm.
- `tools/scenes/sections.steps` — two assertions, ABOVE the phone cut.

ADDRESSED BY TITLE ACROSS EVERY WINDOW, not by index and not by window
number: a section row is what the user sees, and the scene's sidebar
rows live in an aux window.

Verdicts after the wave:

```
check-verbs: OK (63 verbs, 86 constants + the CLIP_* mirrors + spec hash against 2 interpreters)
check-steps: OK
check-targets: ALL OK      (native, ios, android, windows, go-android)
swift-typecheck: OK
check-compose: OK
```

## 2. WHY THE ASSERTIONS SIT ABOVE THE TAIL AND NOT IN IT

The deferred entry proposed "asserted in the sections scene's desktop
tail beside the presentation row" — i.e. on the SIDEBAR rows. Measured,
that is the one place a shared scene cannot assert:

**GTK's sidebar arm draws no symbol at all.** `GtkStackSidebar` binds
only the page's title into a GtkLabel and ignores `icon-name` entirely
(gtk.rs's `refresh_section_symbols`, fact 2, measured on GTK 4.18.6),
and kaya does not hand-build rows inside a component that owns them. So
a sidebar symbol assertion would be red on linux forever while green on
the other four — and scenes are shared verbatim (invariant 6).

The BAR rows are the better place anyway, and by more than one step:

- the historical defect was in ONE decode (`set_section_prop`'s symbol
  value), which feeds both arms — so the bar rows catch exactly it;
- the bar assertions sit above the phones' cut, so FIVE lanes assert
  them where a tail assertion would have reached three.

The macOS SIDEBAR half of the read is implemented and MEASURED anyway
(probe below), so the day GTK grows sidebar icons the scene grows two
lines and nothing else.

## 3. THE MAC READ, measured before it was believed

`KAYA_SECTION_TRACE=1` dumps the whole accessibility tree plus the rows
the read collected (`sections-mac-leg.sh`, log `sect-trace.log`). What
the real tree carries for the BAR arm:

```
    role=AXToolbar sub=nil title=nil desc=nil value=nil ident=nil
     role=AXGroup ...
      role=AXRadioGroup ...
       role=AXRadioButton sub=AXSegment title=nil desc=Feed    value=nil ident=kaya-section-symbol:home
       role=AXRadioButton sub=AXSegment title=nil desc=Archive value=nil ident=kaya-section-symbol:star
```

Three findings:

1. **macOS's TabView publishes its items as `AXRadioButton`/`AXSegment`
   under an `AXRadioGroup` in the window's `AXToolbar`** — not as tabs,
   and nothing like the iOS bottom bar's shape.
2. **The spoken name is `AXDescription`, and `AXTitle` is nil.** So the
   title half of the match reads AppKit's own description while the
   symbol half reads the identifier: two properties, two sources.
3. **There is no glyph object anywhere in the tree** — no AXImage, no
   image attribute on the row. So on macOS the identifier the rendering
   arm publishes IS the answer, exactly as the toolbar arm found one
   construct over, with the same stated limit: it is what the arm said
   it drew, not the pixels.

The sidebar arm was probed the same way (`sect-sidebar-probe.sh`, a
scratch copy of the scene with two extra lines — never the repo scene):

```
KAYA_SELFTEST: OK (..., sections window#1 sidebar, section "Shelves" symbol "search", section "Loans" symbol "lock")
```

So the macOS read answers for BOTH arms and for an AUX window, measured.

## 4. THE REGRESSION PROOF — the reason this slice exists

The historical defect, re-introduced verbatim in a copy-backed
perturbation of the SwiftUI decode (`sections-negative.sh`, which prints
and asserts the substitution count before it builds anything):

`raw.loadUnaligned(fromByteOffset: body + 24, as: Int64.self)`
-> `... body + 20 ...`, `substitutions: 1`

```
--- leg rc=1 (0 would mean the guard did not fire)
KAYA_HARNESS: step-failed section "Feed" symbol "symbol 85899345928 is not in this interpreter's table", wanted "home"
KAYA_HARNESS: step-failed section "Archive" symbol "symbol 73014444040 is not in this interpreter's table", wanted "star"
KAYA_SELFTEST: FAILED (section "Feed" symbol "symbol 85899345928 is not in this interpreter's table", wanted "home"; section "Archive" symbol "symbol 73014444040 is not in this interpreter's table", wanted "star")
swift/KayaSwiftUI.swift: OK
```

THIS IS THE ACCEPTANCE TEST. That perturbation is the bug that shipped
on 2026-08-16 and that the whole matrix stayed green through; the last
line is the restore, `shasum -c` clean. The measured garbage rides the
failure (85899345928 = 0x14_00000008 — the length word and the type tag
read as one I64), which is what tells this apart from a row that drew
nothing.

## 5. WATCHED NEGATIVES — mac arm, verbatim

Driver: `sections-negative.sh <name> <old> <new>` — substitutes, PRINTS
AND ASSERTS the substitution count, rebuilds the interpreter, runs the
sections leg, restores from `sections.FIXED.swift` and verifies with
`shasum -c` (never git). Every run below ends
`swift/KayaSwiftUI.swift: OK`.

### (a) THE SYMBOL DROPPED FROM THE RENDER — the glyph arm made unreachable

`if symbol != 0, let sf = …` -> `if symbol == 999, …`, `substitutions: 1`

```
KAYA_HARNESS: step-failed section "Feed" symbol "SF symbol house does not resolve on this OS", wanted "home"
KAYA_HARNESS: step-failed section "Archive" symbol "SF symbol star does not resolve on this OS", wanted "star"
```

The row falls to the text arm and the read says which of the two causes
the ARM measured. (Under this perturbation the sentence is forced rather
than measured — the branch is reachable only when `drawable(sf)` is
false in the shipped code, which is when that sentence is true.)

### (b) THE READ DECOUPLED — the arm publishes a different identifier

`kayaSectionSymbolIdent + name` -> `"kaya-not-the-section:" + name`,
`substitutions: 1`

```
KAYA_HARNESS: step-failed section "Feed" symbol "no section rows are in the accessibility tree", wanted "home"
KAYA_HARNESS: step-failed section "Archive" symbol "no section rows are in the accessibility tree", wanted "star"
```

Loud, with NO silent fall-back to `section.symbol` — which is what
proves the green run's `"home"`/`"star"` came off the real AX element
and not off the model sitting beside it.

### THE INDEPENDENCE, in all three negatives

Each perturbed run has exactly **2** `step-failed` lines — the two
symbol assertions. `expect_sections`, `expect_sections_presentation`,
every `expect_section` and the whole aux-window tail still PASS. So the
symbol read is not the title read in disguise: two observations, one
switcher.

### (c) THE CUT GUARD ITSELF, watched refusing

The mobile lanes' `keep` argument became a LIST (`expect_section
expect_section_symbol`) in BOTH runners, so a future reshape cannot
slide a symbol assertion into the desktop tail where no phone runs it.
Watched, with the repo scene perturbed from a saved copy and restored:

```
substitutions: 1
run-emulator: cutting …/tools/scenes/sections.steps at `expect_windows` drops ['expect_section_symbol "Archive" "star"'] — the cut may not take an assertion of `expect_section_symbol` with it
tools/scenes/sections.steps: OK
```

## 6. TWO FINDINGS FROM THE PHONES — both caught by the new read

The first run of the two mobile lanes went RED, and neither failure was
a harness bug. This is the verb earning its keep on the day it landed.

### 6.1 iOS: a UITabBar draws the FILLED VARIANT

```
step-failed section "Feed" symbol "the section row Feed renders the glyph house.fill, which is not in this interpreter's table …", wanted "home"
step-failed section "Archive" symbol "the section row Archive renders the glyph star.fill, …", wanted "star"
```

kaya asks for `house`/`star`; the bar's image views publish
`house.fill`/`star.fill` — for the SELECTED tab and the unselected one
in the same run, so it is the bar's dress, not a selection state.

A THIRD naming relationship, and deliberately NOT folded into
`kayaSymbolTable`'s `rendered` column: that column records an alias
SwiftUI resolves before the image exists (`doc.on.doc` ->
`document.on.document`), this records a variant UIKit picks when it
draws. `kayaSectionIOSSemantic` states it as its own rule — invert the
rendered name, and failing that the rendered name minus a trailing
`.fill`. THE NO-FALL-BACK RULE SURVIVES: an off-table glyph still fails
to invert, and the right glyph for the wrong section inverts to the
wrong name. Stripping a suffix cannot invent an answer the render did
not publish.

### 6.2 Compose: a NavigationBarItem does not merge its descendants

```
KAYA_SELFTEST: FAILED (section "Feed" symbol "no icon on the section row", wanted "home"; …)
```

…for a bar that was visibly drawing icons. An `IconButton` merges (which
is why `kayaToolbarItemRead` reads the tagged node's own config and
works); a `NavigationBarItem` does not — the tag lands on the selectable
row and the icon and the label stay separate nodes under it. So the
row's answer is the first one its SUBTREE publishes (`kayaSectionProp`),
which is still the render and still not the model, one node further
down. The miss sentence now carries the subtree's size, so "the row
composed empty" and "the row composed and the icon drew nothing" read
differently.

## 7. LANE VERDICTS (every lane, the same day)

| lane | sections legs | lane verdict |
|---|---|---|
| mac (`validate-mac.sh`) | 8/8 PASS (rust, python, go, csharp, ocaml, haskell, swift, java) | `gates: OK — 34/34`, `TIMING legs 226s`, **validate-mac: ALL PASS** |
| linux (`validate-linux.sh`, both protos) | 7/7 PASS each (x11 + wayland) | **run-suites: ALL PASS**, `validate-linux rc=0` |
| windows (`deploy-win.sh … all`) | 5/5 PASS (rust, python, go, csharp, java) | `windows rc=0`; guest-side unit tests 8/8 |
| android (`run-emulator.sh all`) | sections-compose / -jvm / -go PASS | `rc=0` |
| iOS (`run-sim.sh all`) | sections-swift / sections-go PASS | `ios rc=0` |

`cargo test -p kaya --features harness --locked`: **360 passed** (+2:
`section_symbol_spellings`, `section_symbol_expects_poll_the_real_switcher`),
3 doc-tests, 13 compile-fail doc-tests, 0 failed.

The assertion reads BYTE-IDENTICALLY on every lane, which is the point:

```
KAYA_SELFTEST: OK (2 sections, sections bar, section "Feed" symbol "home", section "Archive" symbol "star", section "Feed", …)
```

(windows/android/iOS/mac all quote that prefix verbatim; the phones' line
stops at `archive: 2 visits` where the cut is.)

ONE RUN OF validate-mac FAILED AND IS RECORDED because the guard was
right: `check-build-id: the built SwiftUI interpreter does not carry this
tree's id … STALE — carries eadd8b46f91a5d4e, but swiftui in this tree is
a8355eb1ebe49659`. I had edited swift/KayaSwiftUI.swift while that lane
was running. The lane was re-run on a quiet tree; the stale-artifact
guard did exactly what it exists for.

## 8. A PRE-EXISTING DRIFT FOUND WHILE COMPARING LANES (ledgered, not fixed)

`expect_sections_presentation`'s window#N verdict is spelled two ways —
`window#1 sections sidebar` from harness.rs (and Compose), `sections
window#1 sidebar` from the SwiftUI interpreter. Nothing catches it: the
tail that runs that form is desktop-only and each lane only requires its
own OK line, so the two spellings never meet. Deliberately NOT fixed in
this slice — it is an unrelated verdict string and this run was
measuring a regression. New docs/deferred.md entry with both readings.

## 9. THE ALL-BINDINGS SWEEP (invariant 2)

The slice adds NO binding surface: `.symbol(Symbol::Home)` on a section
has shipped in every binding since D6, and the scene's guests already
declare it. So:

| language | verdict |
|---|---|
| Rust, Python, Go, C#, Java, Swift, OCaml, Haskell | DO — nothing owed; each language's `sections` guest already declares the symbols, and each ran the new assertions on at least one lane (mac runs all eight) |
| C floor | DEFER — no `sections` guest exists in any lane today, which predates this slice |

Backends: macOS, iOS, GTK, WinUI, Compose all DO — five real arms, no
depth stub anywhere (`sections` has never been a stubbed feature, so a
stub was not an option and the fan-out had to be complete on the day).

## 10. FILES TOUCHED

```
crates/kaya/src/harness.rs                     Step + parse + Stage method + exec + 3 mocks + 2 tests
crates/kaya/src/gtk.rs                         section_symbol_read + the Stage arm
crates/kaya/src/winui/mod.rs                   the Stage arm
swift/KayaSwiftUI.swift                        KayaSectionLabel, the mac + iOS reads, the trace, the step arm, the decode comment
android/.../dev/kaya/KayaCompose.kt            SECTION_TAG_PREFIX, kayaSectionTag, the testTag, the unmerged read, the step arm
tools/scenes/sections.steps                    two assertions
tools/ios/run-sim.sh                           the cut's keep argument is a LIST
tools/android/run-emulator.sh                  the same, same words
docs/deferred.md                               entry struck + 2 new entries
```

Nothing under `guests/go/editor/**` was touched (owned by a concurrent
task).

## 11. CLEANUP

- No leftover processes: every leg driver waits on its guest, and
  `ps -Ao pid,etime,pcpu,command | grep -E "sectionsleg|examples/sections"`
  is empty (checked after the last run).
- The emulator and simulator pools are as they were found — 4 android
  AVDs and 4 iOS sims booted before this session and still booted; none
  was created, booted or shut down by this work.
- The Windows VM is up and answering, as found.
- `target/sectionsleg-guests` (the staged guest directory) removed.
- swift/KayaSwiftUI.swift restored sha-identical after every
  perturbation (`sections.FIXED.sha`), and tools/scenes/sections.steps
  likewise (`sections.steps.sha`).

### 11.1 The cleanup, measured rather than asserted

```
$ rm -rf target/sectionsleg-guests && ls -d target/sectionsleg-guests
ls: cannot access 'target/sectionsleg-guests': No such file or directory

$ ps -Ao pid,etime,pcpu,command | grep -E "sectionsleg|examples/sections|sections-rust" | grep -v grep
(no output)

$ ps -Ao pid,etime,pcpu,command | sort -k3 -rn | head
63625 21-01:29:44  19.0 qemu-system-aarch64-headless -avd kaya-tablet ...
 1859 21-17:07:46   5.4 qemu-system-aarch64-headless -avd kaya ...
```

The only heavy processes are the two android emulators, `etime` 21 days
— they were up before this session and nothing here started or stopped
one.

```
$ tools/probe-env.sh
ios          OK     sim pool warm (4/2 kaya-sims booted)
android      OK     emulator pool warm (4/2)
linux        OK     docker up, image cached
windows      OK     akhil@192.168.64.2 answering; display never sleeps
panel-mode   OK     open panel view mode 3 = icons ...
```

Byte-identical to the probe taken before the lanes ran: same pool
counts, same panel mode, VM up. No simulator or emulator was created,
booted or shut down; the Windows VM was never rebooted.

Disk: `scratchpad/chrome` is 25 MB total; this slice added ~11 MB
(logs plus one 700 KB `sections.FIXED.swift` kept because the negative
driver restores from it). Its PRISTINE twin was deleted after the last
restore verified — git HEAD is that file.
