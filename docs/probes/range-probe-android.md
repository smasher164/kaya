# TEXT-RANGES probe — ANDROID / Compose arm

Repo HEAD 6a616d6. Measured on the STANDING emulator `kaya-tablet`
(emulator-5560, `sdk_gphone64_arm64`, API 35, 2560x1600 @ 320dpi). No
emulator was booted, killed or reconfigured by this probe (the one
setting touched, the default IME, was recorded and restored — see
Cleanup).

Pins under measurement (`android/kaya/build.gradle.kts`): compose-bom
**2024.10.01** => foundation **1.7.5**, material3 **1.3.1**,
activity-compose 1.9.3, compileSdk 35, minSdk 26. Everything below was
compiled and run at those pins; nothing needed a pin bump.

Probe: `<scratchpad>/androidranges`, a standalone gradle build modelled on
`tools/android/undoprobe`, built `--offline` against the warm `~/.gradle`
cache so no dependency could move. Deleted at the end (sizes reported).

---

## 0. What kaya's text widget sits on today

`android/kaya/src/main/kotlin/dev/kaya/KayaCompose.kt`:

| thing | where |
| --- | --- |
| `KIND_TEXTAREA = 14` / `KIND_ENTRY` | KayaCompose.kt:653 |
| both kinds render through one composable | KayaCompose.kt:4718-4719 |
| **`KayaTextField`** — the whole widget | KayaCompose.kt:4758-4815 |
| `BasicTextField(state = node.textState, …)` | KayaCompose.kt:4781-4811 |
| `lineLimits = MultiLine(minHeightInLines = 3)` (textarea) | KayaCompose.kt:4783-4785 |
| M3 dressing via `TextFieldDefaults.DecorationBox` | KayaCompose.kt:4800-4810 |
| `node.textState: TextFieldState` and why | KayaCompose.kt:150-181 |
| observation = `snapshotFlow { textState.text }` + echo compare | KayaCompose.kt:4764-4780 |
| scroll viewport (`KIND_SCROLL`) = `verticalScroll(node.scrollState)` | KayaCompose.kt:4558-4567 |
| harness reads a REAL `ScrollState` (`expect_at_end`) | KayaCompose.kt:3470-3481 |
| harness reads the REAL semantics tree (`RootForTest.semanticsOwner`), main thread only | KayaCompose.kt:2375-2396, 2686-2692 |

Two structural facts decide everything below.

1. **The field is on the new state-based text API.** The undo milestone
   (docs/undo-plan.md §1.4) moved it off `TextField(value:, onValueChange:)`
   precisely because that path's undo stack is an internal `UndoManager`
   the app cannot see or clear. That migration is what makes D6/D7
   expressible, so it is not revertible for ranges.
2. **The textarea does not scroll.** `MultiLine(minHeightInLines = 3)`
   leaves `maxHeightInLines` at `Int.MAX_VALUE`, so the field GROWS and
   the enclosing kaya `scroll` node is the viewport. Measured: 40 lines
   => `innerSize=2496x1320` and the outer scroll's `maxValue` rose
   1011 -> 2232; 1000 lines (47 892 chars) => the field is simply that
   tall. There is no second, inner scroll offset to reconcile.

---

## 1. HIGHLIGHT (a set of ranges)

### 1a. There is no native styling hook on this field. Compile-proven.

Four candidate routes, all in one file, compiled at kaya's pins
(`gradle :app:compileDebugKotlin`, exit 1 — the errors ARE the finding):

```
Negative.kt:23:9  No parameter with name 'visualTransformation' found.
Negative.kt:28:35 Unresolved reference 'addStyle'.
Negative.kt:38:9  Unresolved reference 'highlight'.
Negative.kt:38:60 Cannot access 'class TextHighlightType : Any': it is internal in file.
```

* `BasicTextField(state=)` has **no `visualTransformation`**. The full
  1.7.5 parameter list (from the artifact, not from memory) is: state,
  modifier, enabled, readOnly, inputTransformation, textStyle,
  keyboardOptions, keyboardActionHandler, lineLimits, **onTextLayout**,
  interactionSource, cursorBrush, outputTransformation, decorator,
  **scrollState**. `visualTransformation` — the legacy path's
  `TransformedText(AnnotatedString, OffsetMapping)` hook, i.e. the classic
  way to colour ranges in a Compose text field — exists only on the
  `value:`/`TextFieldValue:` overloads kaya deliberately left.
* `OutputTransformation.transformOutput(TextFieldBuffer)` can only
  **edit text** (replace/append/setSelection). `TextFieldBuffer` has no
  style API at all.
* `TextFieldState`/`TextFieldCharSequence` DO carry a
  `Pair<TextHighlightType, TextRange>` — but it is ONE range, its two
  types are `HandwritingSelectPreview`/`HandwritingDeletePreview`
  (stylus preview), the class is Kotlin-`internal`, and no public
  mutator reaches it. Not a route, now or by accident.

**The silent trap.** An `AnnotatedString` IS a `CharSequence`, so
`state.edit { replace(0, length, annotatedString) }` **compiles clean**.
Measured: the state stores it as a plain `String`
(`class in state=String`) and the span is not painted — a screen read of
the field found **0** highlight pixels. A binding that "supports"
highlight by pushing an AnnotatedString would pass every compile gate and
paint nothing.

### 1b. The route that works: draw the ranges from the platform's own layout.

`BasicTextField(state=)` hands out `onTextLayout: Density.(() ->
TextLayoutResult?) -> Unit`. Keep the provider; inside a
`Modifier.drawBehind` on the box that wraps `innerTextField`, call
`TextLayoutResult.getPathForRange(start, end)` and `drawPath`. Roughly 12
lines. Geometry comes from `getPathForRange` / `getBoundingBox` /
`getLineForOffset` / `getLineTop|Bottom` / `getHorizontalPosition`.

Verified against pixels, not by eye. Range 0-9 declared; the app reported
the rect it drew as `[0,0,107,33]` with the inner text origin at
`(32,632)`; a raw framebuffer read found the highlight colour in bbox
`(32,632)-(138,664)` — agreement to a pixel. A wrapped range (100-140,
crossing a line break) painted two line segments spanning the wrap,
matching `getPathForRange`, which my own per-line rect helper got
subtly wrong — evidence that the path primitive, not hand-rolled rects,
is the thing to lower onto.

Under the enclosing scroll the highlight tracks the text exactly: after
`scrollTo(400)` the painted bbox moved by exactly -400px with an
identical pixel count. Because the field never scrolls internally
(§0.2), there is no scroll offset to correct — the coordinate hazard
that would exist with a bounded `maxHeightInLines` does not exist in
kaya's configuration today.

### 1c. Ranges vs edits, and what re-declaring costs

The expected model (the app re-declares after every change) is right for
this backend, and it is nearly free.

A stale range is a WRONG range, not a crash: after prepending 3 chars the
old offsets kept painting at the old glyph positions until re-declared.
There is no offset mapping to inherit — `TextFieldState` has no
`OffsetMappingCalculator` the app can reach.

Cost, on a 47 892-char (1000-line) document, 100 vsync-locked frames per
row, floor = 16.60 ms/frame:

| what changes per frame | ms/frame | recompositions | text re-layouts | draws |
| --- | --- | --- | --- | --- |
| nothing (floor) | 16.60 | 0 | 0 | 0 |
| 1 range re-declared | 16.70 | **0** | **0** | 100 |
| 50 ranges re-declared | 16.67 | **0** | **0** | 100 |
| 200 ranges re-declared | 19.18 | **0** | **0** | 100 |
| one text edit, no ranges | **40.32** | 100 | 100 | 100 |
| one text edit + ranges | 38.96 | 100 | 100 | 100 |

Read that bottom pair against the rest: **the expensive thing on this
backend is the edit itself** (re-laying out a 48k-char paragraph, ~24 ms),
which the app already pays for with no ranges in play. Re-declaring
ranges costs a DRAW-phase invalidation only — `layoutCalls` stayed at 3
across a 200-range × 100-frame benchmark, and recompositions stayed at 0
— about 12 µs per range per frame at 200 ranges.

That 0 is conditional on **phase discipline**: the declared ranges must be
read inside the draw lambda. The naive spelling (read them in the
composable body, pass them down) recomposed the field 200 times in 200
frames. At 40 lines both stayed inside the frame budget, so this will not
show up as a lane failure — it is the kind of thing that only ever shows
up on someone's real document. If kaya lowers highlight here, the rule
"the range list is read in the draw scope, never in composition" wants to
be written where the lowering is.

Flicker: none observable, and structurally none available — no
recomposition, no re-layout, the text is not re-measured, only the paint
behind it changes.

---

## 2. SELECT (one range)

Two routes, both measured, and **they differ in ways kaya has to choose
between**.

**Route A — `state.edit { selection = TextRange(a, b) }`.** The only
public mutator on the state API (`TextFieldBuffer.setSelection`).
Applies whether or not the field has focus; `TextFieldState.selection`
reads it back.

**Route B — the platform's own `SemanticsActions.SetSelection`**, invoked
on the field's merged semantics node. This is the same channel
KayaCompose already uses for cut/copy (KayaCompose.kt:2375-2384: "the
platform's command reaching the platform's selection, with nothing of
kaya's invented in between"), and it is what TalkBack drives. Measured
`invoked=true`, selection applied.

| | edit{} (A) | SetSelection (B) |
| --- | --- | --- |
| applies the selection | yes | yes |
| needs focus | no | no |
| **undo history after** | **preserved** | **preserved** |
| **IME composing region** | **destroyed (null)** | **preserved** |
| reveals as a side effect (focused field) | **yes, scrolls** | not measured separately |

The undo answer corrects a fear recorded in the source. KayaCompose.kt:
2358-2361 says reaching for `edit {}` would be wrong because "`edit {}`
commits, and a commit CLEARS the field's undo history — D7's clear firing
for a read". Measured: after real typing (`canUndo=true`), a
**selection-only** `edit {}` left `canUndo=true, canRedo=false`. The
contrast case pins it — an `edit {}` that CHANGES TEXT does clear the
history (`canUndo` true -> false, and a subsequent `undo()` refuses). So
**the D7 clear is keyed on the text changing, not on `edit {}` being
called**, and SELECT can be lowered on route A without touching D7. That
comment should be narrowed when this lands.

Two consequences for a uniform semantics:

* **On Android, SELECT implies REVEAL when the field is focused.** With
  the field focused and the viewport scrolled to the far end, setting the
  selection scrolled it back (2232 -> 1556) with no reveal request. With
  the field NOT focused it did not scroll (2232 -> 2232). If kaya wants
  SELECT and REVEAL to be independent primitives, Android is where that
  independence breaks, and it breaks *conditionally on focus* — the worst
  kind. (Focusing the field alone also scrolls: 0 -> 384.)
* **Order matters against a text write.** kaya's own write path moves the
  cursor to the end (`setTextAndPlaceCursorAtEnd`), so a declared
  selection must be applied AFTER the text of the same transaction.

---

## 3. REVEAL (scroll a range into view)

Because the textarea grows rather than scrolls (§0.2), reveal is a
request on the ENCLOSING scroller, not on the field. The API that spans
both cases is `BringIntoViewRequester` /
`Modifier.bringIntoViewRequester` (`androidx.compose.foundation.relocation`,
`@ExperimentalFoundationApi` at 1.7.5): the requester takes a `Rect` in
the requesting node's local coordinates and every scrollable ancestor
responds. It would also keep working unchanged if kaya ever bounds the
textarea's height, which is the reason to prefer it over computing a
`ScrollState` target by hand.

Measured on a 40-line field inside kaya's `verticalScroll` shape:

| scenario | scroll before | after |
| --- | --- | --- |
| reveal chars 1200-1260 from the bottom | 2232 | **1490** |
| reveal chars 0-20 from the bottom | 2232 | **632** |
| set selection 1200-1260, field NOT focused | 2232 | 2232 (no reveal) |
| set selection 1200-1260, field focused | 2232 | **1556** |

It scrolls minimally — the range lands at the viewport edge, not
centred. If kaya's REVEAL is specified as "make it visible" that is a
match; if it is specified as "centre it", that is extra work here.

The cost is a **third experimental opt-in** for KayaCompose.kt, which
today pays exactly two and documents each as proven-required
(KayaCompose.kt:4752-4756). `BringIntoViewRequester` is the only
API in this whole probe that is not stable at kaya's pins.

---

## 4. OBSERVABILITY — how a harness leg asserts each one

kaya's Compose harness reads real toolkit state on the UI thread
(`onUi(activity) { … }`), and already has both precedents it needs: a
real `ScrollState` read (`expect_at_end`, KayaCompose.kt:3470) and a real
semantics-tree read (`kayaAx`, KayaCompose.kt:2375). All three
capabilities are assertable, and the strongest channel for each is
platform-side, not kaya's own bookkeeping.

**SELECT — `SemanticsProperties.TextSelectionRange`.** The field
publishes its selection into the semantics tree; the harness reads it off
the same merged node `kayaAxName` already walks. Measured: after route A,
`TextSelectionRange=5..10`; after route B, `TextSelectionRange=3..8` —
the platform's answer, matching the model. This is the exact analogue of
macOS's `kAXSelectedTextRange` and AT-SPI's Text interface, so a uniform
`expect_selection` verb has a real backing on this platform. (Note: it is
NOT in a `uiautomator dump` — the XML has no selection attribute — so the
in-process read is the channel, which is what kaya does anyway.)

**REVEAL — the real `ScrollState`.** `scrollTarget(target)?.scrollState`
already exists; `value`, `maxValue` and `viewportSize` are all readable,
and `TextLayoutResult.getBoundingBox(offset)` gives the range's y. A leg
can assert the honest geometric predicate — the range's box lies within
`[scroll, scroll + viewport]` — rather than "we called reveal". Every
number in the §3 table came out of that read.

**HIGHLIGHT — two channels, and the second one is the good one.**

1. *The platform's layout.* `SemanticsActions.GetTextLayoutResult` hands
   the harness the field's own `TextLayoutResult` through the semantics
   tree (measured working: `lines=1 textLen=152`, boxes matching the
   draw side). That proves where a range IS, but not that kaya painted it.
2. *The painted pixels, in-process.* `PixelCopy.request(window, rect,
   bitmap, …)` (API 24+, kaya's floor is 26) reads the field's own
   pixels with no adb and no screenshot tool. Measured, and it
   discriminates exactly:

   | | highlighted px / total |
   | --- | --- |
   | range 100-140, nothing declared | **0 / 13530** |
   | range 100-140, that range declared | **10427 / 13530** |
   | range 200-240, while 100-140 is declared | **0 / 8052** |

   (The rest of the 13530 is the glyphs drawn on top.) That is a verb
   that cannot pass without the feature really working — it fails if the
   lowering silently drops the ranges, which is precisely the failure
   mode the AnnotatedString trap in §1a produces. Android has no
   accessibility channel that carries a background span, so this is the
   honest assertion; note it must run on the UI thread with the window
   attached, like every other read in this backend.

---

## 5. IME and composition

Measured with a purpose-built IME (no adb command can open a composing
region — `input text` injects key events and never calls
`setComposingText`). The probe's IME was enabled and made default for the
scenario only; the previous default was recorded and restored (proven in
Cleanup).

With a live composing region (`composition=11..14` after
`setComposingText("abc")`):

| action while composing | composing region after |
| --- | --- |
| `state.edit { selection = … }` | **null — destroyed** |
| `SemanticsActions.SetSelection` | **2..5 — intact** |
| re-declare highlight ranges | **2..5 — intact** |

This is the one real user-visible hazard on this backend. An app-driven
SELECT through `edit {}` cancels whatever the user is mid-composition on:
for Latin input the half-typed word is committed and its underline
vanishes; for Japanese/Chinese/Korean input an in-progress conversion is
force-committed. Anything that re-declares a selection on a timer or on
every keystroke would do this repeatedly. The semantics route does not,
which is a second reason to weigh route B, and highlight is untouchable
by construction — it never enters the text pipeline at all.

---

## 6. Verdict, risks, and what a design has to decide

**All three are doable on Android at kaya's current pins, with no pin
bump and no backend rewrite.** Highlight needs ~12 lines of draw code
inside the existing `decorator`; select is one call; reveal costs one
experimental opt-in. Nothing here argues for touching the
`TextFieldState` migration.

Open decisions this arm cannot make alone:

1. **SELECT vs REVEAL are not independent here** when the field is
   focused. Either the uniform semantics says "SELECT reveals" (which
   Android gives free and other backends must then match), or REVEAL is
   the only sanctioned scroller and Android's implicit one has to be
   documented as unavoidable.
2. **Route A vs route B for selection.** A preserves nothing the IME
   cares about; B preserves the composing region and is the same
   "platform's own command" idiom kaya already chose for cut/copy. B is
   only reachable while the node is in the semantics tree.
3. **Phase discipline for highlight** (draw-scope reads) is a real rule
   with no compile-time enforcement — a natural candidate for the
   guard-on-a-path-nobody-can-avoid treatment if it lands.
4. `getPathForRange` handles wrapped ranges and bidi; hand-rolled rects
   do not. Lower onto the path.

Deferred / not measured: RTL and bidi ranges; surrogate pairs and
grapheme clusters at range boundaries (Compose offsets are UTF-16 code
units, which is a cross-binding question, not an Android one); behaviour
with a bounded `maxHeightInLines` (an inner `ScrollState` appears and
highlight coordinates would then need its offset — kaya has no such
field today).
