# The rendered-name column, measured (progressive report)

Closes docs/deferred.md's "The SF symbol table wants a rendered-name
column (iOS, found 2026-08-17)". Tree at start: ae43a7d (plus other
agents' in-flight edits to crates/kaya/src/wire.rs and guests/go/**,
which this arm does not touch). Working file: swift/KayaSwiftUI.swift,
pristine copy + sha beside this report as `sf-rendered.PRISTINE.swift`
/ `.sha`; every perturbation is restored from a saved copy and verified
with `shasum -c`, never git.

The charge's four parts: (1) measure the rendered identifier for all 20
symbols, (2) grow kayaSymbolTable with a rendered column, (3) move
expect_menu_symbol's promoted half off the stamp onto the real
navigation-bar tree and retire the stamp if nothing else reads it,
(4) watched negatives.

## 1. THE MEASUREMENT

Probe: `sfprobe/main.swift` + `sfprobe/build.sh` beside this report; raw
output in `sfprobe/sfprobe.log`. Device kaya-sim-0
(8F0680C5-7FD8-4C3B-977E-79CE84F150FA, iPhone, **iOS 26.5**), booted
before this session and still booted after it.

It renders each row THE WAY THE PROMOTED BAR DOES — `Label(name,
systemImage: sf)` inside a `Button` inside
`ToolbarItemGroup(placement: .primaryAction)` inside a `NavigationStack`
— and reads back the identifier UIKit publishes on the UIImageView it
built, through the same walk `kayaToolbarIOSButtons` makes (automation
switch, accessibility children, outermost button element, first
UIImageView under it).

Two things it does that a simpler loop would not:

- **One row per pass in a FRESH UIHostingController.** A shared
  controller lets SwiftUI reuse the image view across rows, and a stale
  identifier read as a fresh one is the exact failure this exercise is
  about.
- **THE PAIRING IS CHECKED, not assumed.** The row's semantic name is
  the button's accessibility label, and a pass whose bar carries no
  button by that name prints `MISSING` with what the bar does carry.
  No row printed MISSING, so every line below is this row's glyph.

### 1.1 The 20 rows, request -> rendered (all measured, iOS 26.5)

| # | kaya symbol | requested SF name | rendered identifier | verdict |
|---|---|---|---|---|
| 1 | add | `plus` | `plus` | measured, SAME |
| 2 | remove | `minus` | `minus` | measured, SAME |
| 3 | delete | `trash` | `trash` | measured, SAME |
| 4 | edit | `pencil` | `pencil` | measured, SAME |
| 5 | done | `checkmark` | `checkmark` | measured, SAME |
| 6 | close | `xmark` | `xmark` | measured, SAME |
| 7 | search | `magnifyingglass` | `magnifyingglass` | measured, SAME |
| 8 | settings | `gearshape` | `gearshape` | measured, SAME |
| 9 | refresh | `arrow.clockwise` | `arrow.clockwise` | measured, SAME |
| 10 | info | `info.circle` | `info.circle` | measured, SAME |
| 11 | warning | `exclamationmark.triangle` | `exclamationmark.triangle` | measured, SAME |
| 12 | back | `chevron.backward` | `chevron.backward` | measured, SAME |
| 13 | forward | `chevron.forward` | `chevron.forward` | measured, SAME |
| 14 | more | `ellipsis.circle` | `ellipsis.circle` | measured, SAME |
| 15 | **copy** | `doc.on.doc` | **`document.on.document`** | measured, RENAMED |
| 16 | **paste** | `doc.on.clipboard` | **`document.on.clipboard`** | measured, RENAMED |
| 17 | star | `star` | `star` | measured, SAME |
| 18 | lock | `lock` | `lock` | measured, SAME |
| 19 | person | `person` | `person` | measured, SAME |
| 20 | home | `house` | `house` | measured, SAME |

**2 of 20 differ, and they are exactly the two rows the symbols research
flagged as the SF Symbols 6 rename family** (`doc.*` -> `document.*`).
Nothing else in kaya's vocabulary is renamed on this OS — including
`gearshape`, `chevron.backward/forward` and `line.3.horizontal`'s
neighbours, which the research listed as the only other rows touching a
version boundary.

### 1.2 The canaries (a probe on which everything agrees proves nothing)

| canary | requested | rendered | what it proves |
|---|---|---|---|
| bogus name | `kaya.definitely.not.a.symbol` | `NOGLYPH` (asked=nil) | the read reports ABSENCE rather than inventing a name; a run of 22 SAMEs would have been a broken probe |
| off-table real symbol | `star.circle` | `star.circle` | an unrenamed name outside kaya's 20 passes through unchanged, so "SAME" is a measurement and not a default |

### 1.3 WHERE THE RENAME HAPPENS, measured a second way

The probe also prints the rendered `UIImage`'s own description beside
the one `UIImage(systemName: sf)` returns for the same string. For the
18 SAME rows the two are **the same object** (identical pointer — UIKit's
image cache hands back one instance). For the two renamed rows they are
**different objects with different names**:

```
copy   rendered <UIImage:0x115ffb7a0 symbol(system: document.on.document) ...>
       asked    <UIImage:0x115ff8320 symbol(system: doc.on.doc) ...>
paste  rendered <UIImage:0x105ccdcc0 symbol(system: document.on.clipboard) ...>
       asked    <UIImage:0x116cf8500 symbol(system: doc.on.clipboard) ...>
```

So the normalization is not the identifier being relabeled — SwiftUI
resolves the alias to the canonical symbol and builds a DIFFERENT image
than `UIImage(systemName:)` would, which is why the two are not
`isEqual` (toolbar-ios-arm.md §1.3 tried that route). The rendered
identifier is UIKit's honest name for the object on screen.

### 1.4 The rule the column states

`sf` is what kaya ASKS FOR and must stay the deployment-floor spelling —
`document.on.document` does not exist below iOS 18 and fails as a blank
image with no diagnostic. `rendered` is what THIS OS's SwiftUI drew for
that ask, and it is filled in ONLY where it differs. A read that inverts
a glyph matches **the request OR the rendered name**; a row whose
rendered column is nil matches on the request alone.

## 2. THE TABLE GREW A COLUMN

`kayaSymbolTable` is now
`[(value: Int64, name: String, sf: String, rendered: String?)]`. The
`sf` column is untouched — it is what kaya ASKS FOR and must stay the
deployment-floor spelling, because `document.on.document` does not exist
below iOS 18 and fails there as a blank image with no diagnostic. The new
column is nil on 18 rows and carries the measured canonical spelling on
`copy` and `paste`.

THE RULE, stated at the table and at the reader: an inversion matches
**the request OR the rendered name**.

```swift
func kayaToolbarIOSSemantic(_ rendered: String) -> String? {
    kayaSymbolTable.first { $0.sf == rendered || $0.rendered == rendered }?.name
}
```

It still returns nil for a glyph neither column spells, which is the
point — that is a picture this vocabulary does not describe, and the
caller reports the name it measured rather than calling it an absence.
The failure sentence names the two causes it cannot tell apart, and the
second one now names its own remedy: "a glyph outside the vocabulary, or
a row this OS renames to a spelling the table has not measured".

## 3. THE PROMOTED READ IS ON THE REAL TREE, AND THE STAMP IS RETIRED

`kayaMenuSymbolRead`'s iOS rendered half was the last consumer of the
`promotedRendered` stamp. It now ends in one line:

```swift
return kayaToolbarIOSItemRead(0, item.label, "symbol")
```

THE TOOLBAR VERB'S READ IS CALLED, NOT COPIED. Addressing the button by
the label UIKit publishes, the automation switch, the trace, the
outermost-button walk, the glyph inversion and the sentences for a bar
that is missing or carries other buttons are one implementation, so a
promoted item cannot read one way through `expect_toolbar_item` and
another through `expect_menu_symbol`. The two gate conditions are
unchanged and are still observations rather than derivations
(`.overflow` stamped by the chrome body that took the compact arm,
promotion recomputed by the helper the bar itself consumes) — what
answers is now the bar.

**THE STAMP IS RETIRED (y).** Grepped first, across the whole tree, and
`promotedRendered` had exactly one reader (this function) and one writer
(`KayaPromotedStamp.record`). Both are gone, together with the
`KayaWindowModel` field, the `KayaPromotedStamp` modifier and
`KayaPromotedLabel`'s now-unused `windowId`. Nothing in tools/ ever named
it — including check-verbs' STAMPED list, which it was deliberately not
in.

WHAT DID NOT GO: the `kaya-toolbar-symbol:` accessibility identifier each
arm publishes. That is a DIAGNOSTIC and it has a second consumer — the
no-glyph branch of `kayaToolbarIOSSymbolOf`, where it names which of the
three text arms drew. It moved from a ViewModifier to a plain
`.accessibilityIdentifier` on each arm, which keeps the property that
matters: the publication is made by the view that arm renders, never
from a decision computed once and used twice.

The macOS half of the verb is untouched (it reads the real NSMenuItem's
image description), and so is the iOS UNRENDERED half, which still
answers with the SF name and only resolves to the semantic name when
`UIImage(systemName:)` really produces an image.

## 4. WATCHED NEGATIVES — verbatim

Driver: `sf-negative.sh <name> <scope-anchor> <old> <new>`. It
substitutes WITHIN one declaration, prints and asserts the count,
rebuilds the iOS interpreter, runs the menus leg on kaya-sim-0, then
restores from `sf-rendered.FIXED.swift` and verifies with `shasum -c`.
Every run below ends `swift/KayaSwiftUI.swift: OK`.

### (a) THE NORMALIZATION ROW REMOVED — the false red the column prevents

`(symbolCopy, "copy", "doc.on.doc", "document.on.document")` ->
`(symbolCopy, "copy", "doc.on.doc", nil)`, inside the table's own
declaration. `substitutions: 1   (scope 12301..13372, 1071 bytes)`

```
KAYA_HARNESS: +188ms expect_menu_symbol "File>Save" "done"
KAYA_HARNESS: +188ms expect_menu_symbol "File>Export" "forward"
KAYA_HARNESS: +189ms expect_menu_symbol "View>Details" "info"
KAYA_HARNESS: +1086ms expect_menu_symbol "Document>Publish" "copy"
KAYA_HARNESS: step-failed menu "Document>Publish" symbol "the toolbar button
Publish renders the glyph document.on.document, which no row of this
interpreter's table spells (a glyph outside the vocabulary, or a row this OS
renames to a spelling the table has not measured)", wanted "copy"
```

This is the deferred entry's stated blocker, reproduced on demand: a
CORRECT button reported as an unknown glyph. The three unrendered-half
steps above it pass in the same run, so the red is the promoted read's
and not the verb's.

### (b) THE PROMOTED READ DECOUPLED FROM THE RENDER

`Label(item.label, systemImage: sf)` -> `Text(item.label)` inside
`struct KayaPromotedLabel: View`.
`substitutions: 1` (`note: 3 occurrences file-wide, 1 in scope` — the
other two are the macOS promoted label and are deliberately untouched).

```
KAYA_HARNESS: step-failed menu "Document>Publish" symbol "the toolbar button
Publish renders no symbol image (copy)", wanted "copy"
```

LOUD RED, NO MODEL ECHO. The arm still runs, the item still declares
`copy`, the identifier still says `copy` — and the read goes red anyway,
because it followed the image and there is no image. The `(copy)` in the
sentence is the arm's own claim, REPORTED so the reader can see the
disagreement, never used as the answer.

### (c) THE SAME PERTURBATION AGAINST THE PRE-CHANGE CODE — the false green, measured

Because (b) only proves the new read is honest, not that the old one was
not. Same substitution, applied to `sf-rendered.PRISTINE.swift` (the
stamp still in place), same leg:

```
--- leg rc=0 (0 would mean the guard did not fire)
KAYA_SELFTEST: OK (..., menu "Document>Publish" symbol "copy", ...)
```

The whole menus scene PASSES with the promoted symbol arm drawing plain
text and no glyph anywhere on screen. That is what the stamp was worth:
it recorded which arm the code MEANT to take, so a perturbation inside
that arm kept it. The move off it is not a tidy-up.

## 5. THE LADDER

```
tools/swift-typecheck.sh            OK
tools/swiftui/build-dylib.sh        built target/swiftui/libkaya_swiftui.dylib
tools/check-verbs.py                OK (62 verbs, 86 constants + CLIP_* + spec hash)
tools/check-stubs.py                OK
tools/check-steps.py                OK
tools/check-diagnostics.py          OK (kayaPromotedSymbolWhyNot answers=2 measured=2)
```

Legs, all from the restored (fixed) tree, `shasum -c` verified before
each block:

| leg | host | verdict |
|---|---|---|
| menus-swiftui (rust) | kaya-sim-0 | PASS |
| menus-swiftui-pad (rust) | kaya-sim-pad | PASS |
| menus-swift (swift) | kaya-sim-0 | PASS |
| toolbar-swiftui (rust) | kaya-sim-0 | PASS |
| toolbar-swift (swift) | kaya-sim-0 | PASS |
| menus-rust | macOS | PASS |
| menus-swift | macOS | PASS |
| toolbar-rust-swiftui | macOS | PASS |

THE MAC READ DID NOT MOVE: the macOS menus verdict line is byte-identical
to the iOS one, including `menu "Document>Publish" symbol "copy"`, which
is the scene's whole point (tools/scenes/*.steps are compared
byte-for-byte across lanes).

The full gates sweep was NOT run: three other agents are mid-slice in
crates/kaya/src/{gtk.rs,winui/**,wire.rs} and guests/go/**, so a sweep
now would report their in-flight state, not this arm's. The gates this
arm can move are the six above.

## 6. THE ALL-BINDINGS SWEEP (invariant 2)

No binding surface moved: one backend file plus one struck ledger entry.
The symbol vocabulary itself is unchanged — same 20 values, same wire
numbers, same `sf` spellings.

| language | verdict |
|---|---|
| Rust, Swift | DO — the legs that assert symbols run in both and are green on iOS and macOS |
| Go | DO by construction — same interpreter, same scene; no guest-side surface involved |
| Python, C#, Java, OCaml, Haskell | DEFER — no iOS/macOS runner roster for them; unchanged by this arm |
| C floor | DEFER — unchanged |

Backends: SwiftUI DO (mac unchanged, iOS moved onto the real tree).
GTK / WinUI / Compose CAN'T APPLY — the rename is an SF Symbols fact and
those backends invert their own icon channels; none of them reads a
UIImageView identifier. The uniform semantics the invariant protects is
`expect_menu_symbol` answering the item's real icon in every backend,
which is what this change strengthens rather than changes.

## 7. WHAT WOULD CATCH THE NEXT RENAME

The column is this OS's answer, and a future OS that renames another
family would make one row un-invertible. That failure lands on the path
everyone already walks — the iOS menus/toolbar legs, on every matrix run
— and the sentence it prints names the measured glyph and says the table
may not have measured it. The probe beside this report re-measures all
20 in about 25 seconds. What it deliberately does NOT do is fall back to
kaya's own published identifier, which would answer green for an arm
drawing the wrong picture (toolbar-ios-arm.md §1.3).

## 8. CLEANUP (proven, not asserted)

- **Boot states untouched.** kaya-sim-0/-1/-2/-pad were all Booted before
  this arm and all four are Booted after it. Nothing was booted, nothing
  was shut down, nothing was created or erased.
- **No processes.** `ps -Ao pid,etime,pcpu,command` matches none of
  `simctl launch|menus-leg|toolbar-ios-leg|sfprobe|*leg-guests|examples/menus|examples/toolbar`
  on the host, and `launchctl list` on each of the four booted devices
  matches 0 of my five bundle ids.
- **My bundles uninstalled**, checked by exact id rather than substring:
  `dev.kaya.menusswiftui`, `dev.kaya.menusswift`,
  `dev.kaya.toolbarswiftui`, `dev.kaya.toolbarswift`, `dev.kaya.sfprobe`
  -> 0 on kaya-sim-0 and kaya-sim-pad (the only two devices this arm
  installed to). The probe's own script uninstalls itself; the count
  above is the second check, taken afterwards.
  DELIBERATELY LEFT ALONE: the dozens of other `dev.kaya.*` bundles on
  sim-0/-1/-2 (and `dev.kaya.menusswiftui` on sim-2, which this arm never
  installed — it installs only to the phone and the pad). They are
  earlier full run-sim runs' and not mine to remove.
- **Disk.** Everything this arm built under target/ is gone:
  `ios-sfprobe` (160K), `ios-bundles-menusleg` (13M),
  `ios-bundles-toolbarleg` (13M), `menusleg-guests` (5.7M),
  `toolbarleg-guests` (4.8M) — 37M, all five removed and their absence
  checked. This report's directory, scratchpad/chrome (gone), is 20M in total,
  most of it earlier stages'.
