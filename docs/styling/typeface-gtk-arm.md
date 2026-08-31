# Typeface fan-out — the GTK arm

2026-08-16. Charge: implement `ApplyOp::SetTypeface` in
crates/kaya/src/gtk.rs (linux platform row), replace the loud
`expect_typeface` placeholder with the real resolved-family read, prove
both display legs in the container. NO commits; no tools/** or *.steps
edits.

This is a historical arm record. Its font inventory and default-font
measurements predate the 2026-08-30 system-font fixture; see docs/traps.md,
"The Linux font fixture has two settings routes". They remain here as the
measurements that shaped this arm, not as current-image claims.

Mechanics from the PROBE (docs/styling/typeface-gtk.md): `:root`
at APPLICATION priority in its OWN provider, `ctx.load_font` +
`describe().family()` for the honest read, `ctx.font_description()`
LIES, an unmatched family renders byte-identically to the unbranded
window. Depth: docs/styling/typeface-depth.md.

## VERDICT

The arm is in and green on BOTH linux display backends, hand-run:

```
=== x11 ===      KAYA_SELFTEST: OK (typeface, typeface DejaVu Serif, clicked hi, ax "heading/typeface")
=== wayland ===  KAYA_SELFTEST: OK (typeface, typeface DejaVu Serif, clicked hi, ax "heading/typeface")
```

Five watched negatives, every one red (or falsely green, where that is
the point), counts printed and sha256 restored. The FONT-BYTES form
works end to end too — the first end-to-end proof of that path anywhere
in the tree.

ONE BLOCKER REMAINS AND IT IS NOT THIS ARM'S TO FIX: the scene's
expected family cannot be one byte-frozen string across the lanes. See
§"the one blocker". Until it moves, `tools/linux/run-suites.sh` wires no
`typeface` legs and check-steps says so — the ordinary between-phase
red, held open in docs/deferred.md.

## What landed (crates/kaya/src/gtk.rs, + Cargo.toml, + the rust guest)

- `CoreState.typeface_css` — the typeface's OWN `GtkCssProvider`, made
  and added ONCE in `activate` at `STYLE_PROVIDER_PRIORITY_APPLICATION`,
  empty until a typeface arrives. Never `brand_css`: `load_kaya_css`
  replaces a provider whole and the appearance-notify handler rewrites
  `brand_css` from `brand_css_for()` alone, so a `font-family` parked
  there would vanish on the first light/dark flip with no error
  anywhere. Add-once-rewrite-in-place is the probe's measured lifecycle
  (create-and-swap silently failed to apply on one pass in seven,
  reproducibly).
- `ApplyOp::SetTypeface(request)` — picks its row with
  `request.family_for(wire::this_platform())`, registers font bytes
  first if any, then writes `:root { font-family: "<family>"; }` through
  `load_kaya_css`.
- `typeface_css_for` / `css_string` — `:root`, never `*` (a `*` rule
  matches `.monospace` itself and would swap the editor's face); the
  family is escaped as a CSS string token, and a sheet kaya cannot form
  correctly dies in `load_kaya_css`'s parse watcher rather than
  half-applying.
- `register_font_blob` — the bytes form (below).
- `CoreState.typeface_request` + `walk_typefaces` + `typeface_verdict`
  + `widget_typeface` — the honest read and its diagnosis.
- `crates/kaya/Cargo.toml`: pango named directly with `features =
  ["v1_56"]` (one line + Cargo.lock's one-line dependency edge). Why is
  in §"the bytes form".
- `guests/rust/typeface.rs`: the linux row,
  `brand_typeface_with("Georgia", &[(Platform::Linux, "DejaVu Serif")],
  None)`. Guests are not tools/**; this is the first use of the
  per-platform pairs on any lane, and the guest's own doc comment
  already anticipated it ("a lane joining the scene adds its own pair").

## The read, and what it refuses to say

`typeface()` walks the real widget tree under every window's CONTENT
(not the window: the header bar is kaya's chrome, the mac read draws the
same line), and for each text-bearing leaf — `GtkLabel`, `GtkText`,
`GtkTextView`, `GtkEditableLabel` — loads the font its own
`PangoContext` resolves and asks the FONT what it is. Reaching the leaf
is what covers every kind the scene has without naming them: a button's
title is a Label, an entry's editable is a Text.

- The REQUEST is never the answer. Measured again here, unchanged from
  the probe: a nonsense family echoes back verbatim from
  `font_description()` while the text system is using DejaVu Sans.
- `.monospace` is skipped: it is the one slot libadwaita claims a family
  for, and `:root` is chosen precisely so it keeps it.
- The face name (R3) is cross-checked against the description's (R2);
  they agreed in every run, and a disagreement would be reported AS one.
- Widgets that disagree are reported as `widgets disagree:
  GtkLabel=…, GtkText=…` — a string no scene can assert.
- Nothing on screen answers `no text widget on screen`, which is a
  different state from a font that failed to apply and says so.

### The diagnosis, and the bug the branch-printing rule caught

`KAYA_DIAG brand typeface: asked …, css delivered …, pango resolved … —
<cause>`, printed once per state change (the verb polls for 15s at 20ms;
750 copies would bury the verdict). Both numbers, because on this image
BOTH failures resolve to a DejaVu family and the resolved name alone
cannot tell them apart. Three causes, and **every one of them was made
to print** (invariant 3):

| state | measured output |
|---|---|
| family not installed | `asked "KayaNoSuchFamily-9x", css delivered "KayaNoSuchFamily-9x", pango resolved "DejaVu Sans" — the rule applied and fontconfig has no such family` |
| lowering deleted | `asked "DejaVu Serif", css delivered "Sans", pango resolved "DejaVu Sans" — the :root rule never reached the widget` (wayland says `css delivered "Cantarell"`, the probe's §4 finding, and the sentence still discriminates) |
| nothing on screen | `asked "DejaVu Serif", css delivered "", pango resolved "no text widget on screen" — no text widget was there to be asked — nothing was measured about the rule` |

THE THIRD ROW IS WHY THE RULE EXISTS. The first cut ordered the clauses
`all(|r| r == asked)` first, and `all()` over an EMPTY set is true — so
the nothing-was-measured state printed a confident story about
fontconfig having no such family, for a lookup that never happened.
That is the `kayaOpenPanelWhyNot` shape exactly, written fresh, in a
gate-clean file, and the only thing that found it was making the branch
print. Emptiness is now tested first, and the comment in the source says
why the order is not a style choice.

(The function is NOT named `*_why_not`/`*Reason`: check-diagnostics reads
those names as diagnostics and FAILS OUTRIGHT for a non-Swift one — "a
loud gap, never a silent one". It is `typeface_verdict`, and
check-diagnostics passes.)

## The bytes form — and a probe brief that was wrong

The charge said "blob via fontconfig app-font". **Measured: that route
cannot work here.** `FcConfigAppFontAddFile(NULL, path)`:

| when | returns | family in the realized PangoFontMap | `:root` resolves |
|---|---|---|---|
| before `Application::run()` | 1 | YES | the blob's family — HIT |
| inside `activate`, after `present()` | 1 | no | DejaVu Sans — MISS |
| a frame later | 1 | no | DejaVu Sans — MISS |

`pango_font_map_changed()` does not help. The call reports success and
does nothing, which is the exact silent-success shape this slice exists
to catch — and every position a kaya apply can occupy is on the wrong
side of the line, because a typeface arrives in the first transaction
and that is drained after `activate`.

`pango_font_map_add_font_file()` (Pango 1.56; the lane image ships
1.56.3) adds the file to the realized `PangoCairoFcFontMap` GTK is
already using, at any time — measured HIT in the same position where
fontconfig silently missed. So the arm takes that route, which is why
`crates/kaya/Cargo.toml` now names pango with `features = ["v1_56"]`.

- COST, stated plainly: this sets a Linux floor of pango >= 1.56 (Dec
  2024; the image is 1.56.3, Ubuntu 24.04 LTS is 1.52). A build against
  anything older fails at LINK naming the symbol — loud, not silent.
  Reversible in one line if the coordinator would rather refuse bytes on
  this backend.
- The blob is written to a temp file named after its own content hash
  (Pango's API takes a path, and keeps reading it), so repeated runs
  reuse one file instead of piling up.
- Register-then-resolve: the family the file ADDED is read off the font
  map (a before/after diff), and the ordinary name machinery takes over.
  Three answers, each stated rather than guessed: the app's own row if
  the file put it in the map, else the one family that appeared, else
  the app's name with a KAYA_DIAG naming what the file actually added.

END TO END, measured on both legs (the tree ships no font, so the guest
was perturbed to read one from the environment, watched and restored;
the face is DejaVuSerif.ttf with its `name` table rewritten in place to
a family nothing on the image has):

```
KAYA_SELFTEST: OK (typeface, typeface KayaBlobFace, clicked hi, ax "heading/typeface")   x11
KAYA_SELFTEST: OK (typeface, typeface KayaBlobFace, clicked hi, ax "heading/typeface")   wayland
```

docs/deferred.md still records that no font ships in the tree, so no
SCENE asserts this; the mac arm's blob path remains unasserted, this one
is not.

## The negatives, every one watched (counts printed, sha256 restored)

| # | perturbation | subs | result |
|---|---|---|---|
| 1 | the apply's `load_kaya_css` call deleted | 1 | RED both legs, `typeface DejaVu Sans, wanted DejaVu Serif`, diag "the rule never reached the widget" |
| 2 | the guest's linux row → `KayaNoSuchFamily-9x` (the probe's fallback negative) | 1 | RED both legs, `typeface DejaVu Sans, wanted DejaVu Serif`, diag "applied; no such family" |
| 3 | the read wired to the REQUEST (R1) + nonsense family + a script asserting the request | 1 + 1 | **GREEN** both legs — the false green the honest read exists to prevent, demonstrated rather than asserted |
| 4 | the walk made to find nothing | 1 | printed the WRONG cause (see above), fixed, re-run printed the right one |
| 5 | (regression) styling + textarea scenes, unperturbed | — | still OK on both legs — the fourth provider disturbs nothing |

1 and 2 are the pair the probe demands: they fail with the SAME resolved
family and are told apart only by the diagnosis. 3 is the measurement
that says why `expect_typeface` cannot read the model.

Driver: `docs/styling/gtk-arm/negatives.py` (prints the
substitution count, treats 0 as a failed test, restores and re-hashes),
logs beside it as `neg-*.log`, `green.log`, `blob.log`.

## THE ONE BLOCKER — for the coordinator, not fixable from this arm

`tools/scenes/typeface.steps` asserts `expect_typeface "Georgia"`,
byte-frozen and shared verbatim (invariant 6). **No single family name
can serve every lane**, and this is measured, not predicted:

| lane | requested | RESOLVED family the read reports |
|---|---|---|
| mac | Georgia | `Georgia` (depth report) |
| windows | Georgia | `Georgia` (winui probe: Georgia ships on the VM) |
| linux | `DejaVu Serif` (this arm's row) | `DejaVu Serif` |
| android | georgia | `Noto Serif` (compose probe §"device families") |

The linux lane cannot borrow `Georgia`: `fc-list : family` on the image
is exactly `DejaVu Sans` / `DejaVu Sans Mono` / `DejaVu Serif`. A
DIFFERENT finding from the probe's, worth having: `Georgia` is not an
unmatched name there but an ALIASED one — fontconfig's 30-metric-aliases
+ 45-latin rules resolve it to **DejaVu Serif**, not to the default
sans (`fc-match Georgia` → `DejaVu Serif`; `fc-match
KayaNoSuchFamily-9x` → `DejaVu Sans`). So even with no linux row the
lane would read `DejaVu Serif` and still discriminate. Either way the
expected STRING differs from mac's.

Options, with what each costs:

- **(A) a per-platform expectation in the verb**, e.g.
  `expect_typeface "Georgia" linux="DejaVu Serif" android="Noto Serif"`.
  One shared file, byte-compared, and the expected value stays a family
  name a reader can check by hand. Costs: a harness parse change, and
  each interpreter backend must know its own platform NAME — a
  one-string private constant, which KayaSwiftUI already carries
  (`kayaDepthStub("typeface", on: "ios")`).
- **(B) a sentinel meaning "the family this platform's row asked for"**,
  e.g. `expect_typeface "@brand"`, compared against the family the
  backend applied. One string for every lane; no platform vocabulary
  anywhere. Costs: the scene can no longer name the face it expects, and
  the assertion becomes resolved-vs-requested (still discriminating —
  the fallback negative stays red — but weaker to read).
- **(C) install a font in the lane image** so `Georgia`'s row has a real
  face on linux. tools/linux/Dockerfile is tools/**; Georgia itself is
  not redistributable, so this means a metric-compatible open face under
  a DIFFERENT family name — which lands back in (A) or (B) anyway.

My reading: (A). It mirrors the per-platform rows the guest already
carries, and keeps the scene naming a fact per lane.

WHEN THAT MOVES, the linux runner needs (tools/**, so not mine):

```sh
DEPTH_SCENES="typeface"        # so the example is built
# and, beside the styling block (expect_ax ⇒ the a11y wrapper):
run "$proto" typeface-rust env KAYA_SELFTEST=typeface \
    tools/linux/a11y-leg.sh "$CARGO_TARGET_DIR/debug/examples/typeface"
```

## Gates

| gate | result |
|---|---|
| `cargo test -p kaya --features harness --locked --lib` (mac) | 352 passed |
| `tools/check-gtk.sh` (both feature configs, in the image) | OK |
| `tools/check-targets.sh` | ALL OK |
| `tools/check-pins.sh` | OK |
| `tools/check-diagnostics.sh` | OK |
| `tools/check-shell.sh`, `tools/check-case.sh` | OK |
| `tools/check-steps.sh` | RED, expected: `scene "typeface" has no live legs in tools/linux/run-suites.sh` (also deploy-win.sh and run-emulator.sh, i.e. the winui and compose arms are in the same state). This is the blocker above, and it is the gate doing its job. |
| `tools/check-stubs.sh` | RED, **and not from this arm** — see below |

### check-stubs is red on somebody else's prose

```
check-stubs: crates/kaya/src/protocol.rs:400 declares a depth stub on "typeface", but that file is not one of the backends this gate reads
check-stubs: android/milestone2kt/.../MainActivity.kt:96 declares a depth stub on "typeface", …
```

Both hits are COMMENTS — protocol.rs's `family_for` doc ("the two
Rust-native backends still declare `depth_stub("typeface")`") from the
depth slice, and MainActivity.kt's selector comment from the android
arm. `stub-ledger.py`'s `unrostered()` scan does not skip comment lines,
unlike its sibling `hand-rolled-stubs.py`'s `offenders()`, which skips
`//`-leading lines for exactly this reason. gtk.rs contains no
`depth_stub` at all now (`grep -c` = 0). The fix is one of: those two
comments stop spelling the call literally, or `unrostered()` learns the
comment skip its sibling already has. tools/** — reported, not touched.

docs/deferred.md's gtk bullet is struck through with what landed, what
the two new findings are, and the leg that is still open (`~~` count
balanced, which that gate checks).

## Sweep — every binding, per invariant 2

The GTK arm is a LOWERING, so the binding surface does not move; what
the arm implies for the other guests, when their typeface guests are
written (check-steps holds the scene rust-only today):

The other seven guests LANDED IN THIS SAME WORKFLOW while this arm ran
(they are untracked files in the tree right now), so the sweep is a live
reading rather than a forecast — snapshot taken at the end of this arm:

| guest | linux row | verdict |
|---|---|---|
| `guests/rust/typeface.rs` | `(Platform::Linux, "DejaVu Serif")` | DONE — this arm added it |
| `guests/python/typeface.py` | `kaya.Platform.LINUX: "DejaVu Serif"` | already there |
| `guests/haskell/typeface.hs` | `TFor PlatformLinux "DejaVu Serif"` | already there |
| `guests/java/dev/kaya/milestone2kt/Typeface.java` | `KayaApp.Platform.LINUX, "DejaVu Serif"` | already there |
| `guests/go/typeface/typeface.go` | none — `tx.BrandTypeface("Georgia")` | **NEEDS THE ROW** |
| `guests/swift/typeface.swift` | none — `tx.brandTypeface("Georgia")` | **NEEDS THE ROW** |
| `guests/csharp/TypefaceScene.cs` | none — `tx.BrandTypeface("Georgia")` | **NEEDS THE ROW** |
| `guests/ocaml/typeface.ml` | none — `brand_typeface "Georgia"` | **NEEDS THE ROW** |
| the C floor | no typeface guest yet | ledgered |

Four of eight would run the linux leg on the default row. That is not a
crash and not even a red today (no linux legs are wired yet): `Georgia`
on this image resolves to `DejaVu Serif` through fontconfig's alias
chain, so those four would report the SAME family as the four with the
row — by luck of an alias, on one image, with nothing pinning it. Give
them the row. I did not edit them: those files were being written by
other arms while this one ran, and a concurrent edit is how two agents
clobber each other.

The lowering reads its row through `family_for(this_platform())`, so no
binding needs to know its platform — which is the design, and the linux
row is the first place any lane exercises it.

## Housekeeping

- Every container ran `--rm`; `docker ps -a` empty, checked at the end.
- No host process started; nothing left running.
- Disk: `target-linux/` grew with the ordinary example builds (it is the
  lane's own shared cache, pre-existing). Session scratchpad's own
  gtk-arm dir is ~200K (scripts + logs + one 800K rewritten font in the
  container's /tmp, which died with the container).
- Final state re-proved after the last comment edit: `green-final.log`
  (BUILD_RC=0, both legs OK). gtk.rs sha256 at hand-off, for the
  coordinator to diff against: run `shasum -a 256 crates/kaya/src/gtk.rs`.
- Repo files touched: `crates/kaya/src/gtk.rs`, `crates/kaya/Cargo.toml`,
  `Cargo.lock` (one dependency-edge line), `guests/rust/typeface.rs`,
  `docs/deferred.md`. NO commits. Every perturbed file restored and
  re-hashed; `git status` shows no file this arm did not mean to touch.
