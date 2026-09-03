# TEXT-RANGES probe — mac arm (SwiftUI backend)

Repo HEAD 6a616d6. Probed 2026-08-06 on this machine. Nothing shipped;
no repo file touched; no commit. Every window ran under the GUI lock,
`.accessory` activation (kaya's own `KAYA_SELFTEST` policy,
`swift/KayaSwiftUIEntry.swift:36-41`), so nothing stole focus.

Verdict up front: **all three primitives are cheap and observable on
macOS — but only if kaya stops using the stock SwiftUI `TextEditor` for
the textarea and owns an `NSTextView` through an `NSViewRepresentable`.**
The blocker is not any missing API. It is that with the stock
`TextEditor` kaya does not control WHEN the text lands in the AppKit
view, and that push — which happens one main-thread turn later, ~11ms
after the app writes — destroys every declared range and resets the
selection to the end of the document. Measured, H2 and G6 below.

---

## 0. Ground truth

### What kaya's text widgets sit on TODAY

- `swift/KayaSwiftUI.swift:7830-7844` — `struct KayaTextarea: View` is a
  bare SwiftUI **`TextEditor`**: uncontrolled binding into `node.text`,
  `.frame(width: 240, height: 96)`, `.border(...)`, `@FocusState`
  mirroring `kayaScene.focusedId`. No `NSViewRepresentable`, no
  NSTextView reference.
- `swift/KayaSwiftUI.swift:7789-7826` — `struct KayaEntry: View` is a
  SwiftUI **`TextField`** with `.textFieldStyle(.roundedBorder)`.
- Dispatch at `swift/KayaSwiftUI.swift:5117-5118`.
- kaya already reaches the AppKit text object, but ONLY for what is
  focused: `kayaFocusedTextResponder(in:)`,
  `swift/KayaSwiftUI.swift:5609-5617` (`window.firstResponder as? NSText`).
  `kayaTypeAtFocus` at `:6295` already writes a selection today
  (`responder.selectedRange = NSRange(location: end, length: 0)`,
  `:6312`) — so "kaya sets a range on macOS" is existing behaviour, just
  not addressable per widget.
- The `NSViewRepresentable` precedent in this same file:
  `KayaWindowAccessor` (`:1946-1995`), `KayaMacButton` (`:5881`).

What the stock `TextEditor` resolves to, measured (E1):

| | |
| --- | --- |
| class | `PlatformTextView` (an `NSTextView` subclass) |
| text system | **TextKit 2** (`textLayoutManager != nil`) |
| container | `AppKitScrollView` → `NSClipView` → the text view |
| flags | `isEditable=true`, `isRichText=false`, `allowsUndo=true`, `usesFindBar=true`, `isIncrementalSearchingEnabled=true` |
| delegate | SwiftUI's own `Coordinator` |
| `NSView.accessibilityIdentifier()` | **empty** — but the AX tree publishes `AXTextArea id=[<a11yId>]`, so `kayaAxFind` (`:3032`) finds it |

### Toolchain

| fact | value |
| --- | --- |
| machine | macOS 26.5.2 (25F84), arm64 |
| compiler | `/Applications/Xcode-26.6.0.app/.../swiftc`, Swift 6.3.3 |
| SDK | `MacOSX26.5.sdk` (resolved by `tools/lib/swift-toolchain.sh:16-44`) |
| default target | `arm64-apple-macosx26.0` — no `-target`, no deployment-target flag in `tools/swiftui/build-dylib.sh` |

So macOS 15 and macOS 26 text APIs are available with **no `@available`
guard**. The nix `apple-sdk-14.4` in the dev shell is a red herring:
`kaya_swiftc` steers `SDKROOT`/`DEVELOPER_DIR` back at Xcode
(`tools/lib/swift-toolchain.sh:49-57 (gone)`).

---

## 1. HIGHLIGHT

### The API surface, verified against MacOSX26.5.sdk

| mechanism | API | availability |
| --- | --- | --- |
| TextKit 2 rendering attributes | `NSTextLayoutManager.addRenderingAttribute(_:value:for:)` / `setRenderingAttributes(_:forTextRange:)` / `removeRenderingAttribute(_:for:)` — `NSTextLayoutManager.h:123-129` | always |
| document attributes | `NSTextStorage.addAttribute(.backgroundColor, …)` | always |
| system highlight style | `NSTextHighlightStyleAttributeName` + `NSTextHighlightColorSchemeAttributeName` (`NSAttributedString.h:48-98`), rendered via `NSTextView.textHighlightAttributes` / `drawTextHighlightBackgroundForTextRange:origin:` (`NSTextView.h:557-560`) | macOS 15+, **TextKit 2 only** (header says so) |
| TextKit 1 temporary attributes | `NSLayoutManager.addTemporaryAttribute(_:value:forCharacterRange:)` (`NSLayoutManager.h:352-360`) | always, but see the trap |
| highlight-as-value | `TextEditor(text: Binding<AttributedString>, selection:)` (SwiftUI.swiftinterface:3061-3064) | macOS 26+ |

### Measured

| what | result |
| --- | --- |
| rendering attributes, 60 ranges | applied in **0.44ms**; visible in the layout manager; **invisible to AX** |
| storage `.backgroundColor`, 60 ranges | applied in **0.87ms**; **visible to AX as `AXBackgroundColor`** |
| `NSTextHighlightStyle`, 60 ranges | applied in 0.92ms; renders; **invisible to AX** |
| TextKit 1 temporary attributes | 3.30ms — 5× slower, and see the trap below |
| clear+re-apply cycle, n=1/10/60 | 0.6–1.1ms, flat in n |
| 66,899-char document, 500 ranges | apply **1.01ms** |
| undo pollution (clean undo manager) | `canUndo=false` after storage highlight, after rendering highlight, after select, after reveal — **none of the three primitives registers a native undo action** (H1) |

### The TextKit 1 trap (found the hard way, run 1)

Reading `NSTextView.layoutManager` **silently and permanently converts a
TextKit 2 view to TextKit 1**. In run 1 the first widget's read of
`.layoutManager` made the *second* widget report `textLayoutManager ==
nil`; the two reads were the same object, and one probe of the temporary
attributes downgraded the view for the whole process. Anything kaya
writes must never touch `layoutManager` on a TextKit 2 view — including
diagnostics. This deserves a `docs/traps.md` entry whatever the design
turns out to be.

### Do ranges survive text edits? (F1, J3)

Yes, and sanely — for a **user** edit:

- Typing 3 characters at offset 0 moved a highlight at `{20,5}` to
  `{23,5}`, still covering `"gamma"`. True for **both** rendering
  attributes and storage attributes (F1).
- Undo of a typed edit moved it back to `{20,5}`, both layers intact
  (G1).
- An insertion **inside** a highlighted run splits it (`{20,5}` became
  `{20,2}`+`{23,3}`) and the inserted character does **not** inherit the
  highlight (J3). No bleed.

And not at all for an **app-driven** text change:

- `model.text = <different string>` wipes every attribute layer —
  rendering, storage, highlight-style, temporary (E2, G2).
- A **byte-identical** app write wipes nothing (G2), so the common
  echo case is free.

### The flicker window (H2) — the finding that decides the design

Declare a highlight, then have the app change the text, then sample the
AppKit view on every main-queue turn:

```
t0          len=1919 bg=3    (view still old, highlight intact)
afterWrite  len=1919 bg=3    (the app's write has NOT reached the view)
turn1 +11.09ms len=1927 bg=0 (SwiftUI pushed; highlight gone)
turn2..8    len=1927 bg=0    (and it stays gone)
```

The push lands on a **later turn**, so a re-declare issued in the same
apply batch as the text change is applied to the OLD document and then
destroyed. Selection behaves identically (G6): re-applied in-turn it
reads `{100,5}`, and after the commit it is `{1925,0}` — SwiftUI resets
the caret to the end of the document.

Consequence: with the stock `TextEditor`, kaya can only re-declare on a
turn AFTER SwiftUI's push, which means at least one rendered frame with
the new text and no highlight and the caret at the end. That is visible
flicker on every app-driven text write, and it is not fixable from
outside the view.

### What the system find bar itself uses — it uses none of these

The SDK answers this in its own words. `NSTextFinder.h:83-89`:

> "If YES, then when an incremental search begins, the findBarContainer's
> contentView will be **dimmed, except for the locations of the
> incremental matches**. If NO, then the incremental matches will not be
> highlighted automatically, but you can use `incrementalMatchRanges` to
> highlight the matches yourself."

Measured to match (F2): after a real find-next on kaya's textarea the
selection moved to the first match `{20,5}` and the document had **zero**
rendering runs, **zero** storage runs and zero temporary runs.
`showFindIndicator(for:)` (the yellow bubble, `NSTextView.h:405`) also
leaves no attributes. `NSTextFinder.incrementalSearchingShouldDimContentView`
defaults to `true`.

So the platform's own find highlight is a **drawing effect over the
content view**, plus a KVO-observable `incrementalMatchRanges` array for
clients that want to draw their own. It is not an attribute, and it is
not published to accessibility. kaya cannot imitate it and cannot assert
it; kaya must own the highlight, which is what the milestone intends
anyway.

### The one path where the highlight is part of the value (H4, J2)

`TextEditor(text: Binding<AttributedString>, selection:)` (macOS 26)
DOES work, with a caveat about scope:

- **AppKit-scope** attributes (`AttributeScopes.AppKitAttributes.BackgroundColorAttribute`)
  are kept in the model but **not rendered and not published to AX** (G4).
- **SwiftUI-scope** attributes (`a[range].backgroundColor = Color.yellow`)
  render and **are published to AX**: `bgRuns=3 [{20,5},{52,5},{84,5}]` (H4, J2).

Because the highlight is part of the value, it survives every push by
construction. But it is not usable here, for two reasons: it changes
kaya's text prop from `String` to `AttributedString` in all 8 bindings
(and no other backend has an equivalent), and **it cannot REVEAL** — see
below. Rejected, but it is the only stock-SwiftUI way to get a persistent
highlight, and it is worth recording that it exists.

---

## 2. SELECT

| what | API | measured |
| --- | --- | --- |
| set one range | `NSTextView.setSelectedRange(_:)` | 0.56ms; AX reads it back exactly |
| set many ranges | `NSTextView.selectedRanges` (array of `NSValue`) | 3 ranges kept; **`AXSelectedTextRanges` reads all 3 back** |
| SwiftUI-native, plain | `TextEditor(text:selection:)` + `TextSelection(range:)` / `TextSelection(ranges: RangeSet)` (macOS 15, SwiftUI.swiftinterface:3059-3060, 19500-19516) | works; 5-range `RangeSet` renders as 5 discontiguous selections |
| SwiftUI-native, attributed | `AttributedTextSelection(range:)` (macOS 26, :15105-15118) | works |
| AX write (an out-of-process driver) | `AXUIElementSetAttributeValue(el, kAXSelectedTextRange, …)` | `err=0`, read-back exact |

Survival: an app-driven text change resets the selection to the end of
the document one turn later (G6, above). A byte-identical write leaves it
alone.

IME: **a SELECT arriving mid-composition commits the composition.**
Measured (E7): with marked text `"にほ"` at `{0,2}`, a
`setSelectedRange({40,5})` left `hasMarkedText() == false` and the two
kana **committed into the document and into the app's model** — which
also shifts every subsequent offset by the committed length. A REVEAL
(scroll) and a HIGHLIGHT do **not** disturb a composition (F6: marked
text survived both). So the composition rule is SELECT-only, and it is a
real semantic question for the milestone: refuse a select while
`hasMarkedText()`, or let it commit. It must be decided once for all
backends, not per platform.

---

## 3. REVEAL

| what | API | measured |
| --- | --- | --- |
| scroll a range into view | `NSTextView.scrollRangeToVisible(_:)` | 2.45ms; selection untouched |
| centred reveal | `NSTextLayoutManager.enumerateTextSegments` + `NSView.scrollToVisible(_:)` | works, lands the range mid-viewport |
| SwiftUI-native | **none** | setting `TextSelection` / `AttributedTextSelection` moves the selection and does **not** scroll (E5: `ax.vis={0,256}` before and after; J2: `vis={0,192}` before and after) |

`TextEditor`'s scroll view is internal AppKit, not a SwiftUI
`ScrollView`, so `ScrollViewReader`/`scrollPosition` cannot reach it.
**REVEAL has no stock-SwiftUI mechanism at all.** On its own, this
forces the owned-view design regardless of what HIGHLIGHT chooses.

Reveal is measurable end to end (J3, on the owned view):
`vis={0,226}` → `scrollRangeToVisible({1500,5})` → `vis={1378,224}`,
with `sel={0,0}` unchanged throughout.

---

## 4. OBSERVABILITY — how a harness leg reads each one back

All three read out of the platform's accessibility tree, same-process,
on the main thread — the exact discipline kaya's `kayaAxRead` already
uses (`swift/KayaSwiftUI.swift:2759-2806`), including the
`AXManualAccessibility`/`AXEnhancedUserInterface` announcement made once
per process and the `AXUIElementSetMessagingTimeout(app, 2.0)` bound. The
existing `expect_ax` verb (`:4823`) is the shape to copy.

| primitive | AX attribute | measured |
| --- | --- | --- |
| SELECT | `AXSelectedTextRange` (`AXAttributeConstants.h:709`), `AXSelectedTextRanges` (`:723`) for multi | exact round-trip, single and 3-range |
| REVEAL | `AXVisibleCharacterRange` (`:740`) | tracks every scroll; assertion = "the declared range is contained in the visible range" |
| HIGHLIGHT | `AXAttributedStringForRange` (`:1314`) → enumerate `AXBackgroundColor` (`NSAccessibilityConstants.h:140`) | **only for textStorage-backed highlights** |

Cost, measured:

- 1,919-char document, 60 highlighted ranges: whole-document
  `AXAttributedStringForRange` + run enumeration = **0.58ms**, all 60
  ranges recovered exactly (F5).
- 66,899-char document, 500 ranges: **6.94ms** (G5).
- A single entry's field editor: 0.20ms (G3).

That is a real, out-of-band assertion: the harness reads what an
assistive client reads, so a leg cannot pass because kaya remembered its
own intent.

**The observability constraint that picks the mechanism:** rendering
attributes (TextKit 2) and `NSTextHighlightStyle` are **invisible to
accessibility** — measured, both report `bg=false` through
`AXAttributedStringForRange`. Only `NSTextStorage.backgroundColor`
surfaces. If mac wants HIGHLIGHT asserted the way `expect_ax` asserts
today, the lowering must write **document attributes**, not rendering
attributes. The alternatives are asserting interpreter state (kaya's own
declared-range map, which is the vacuous shape this project keeps paying
for — it would pass with the lowering deleted) or pixel comparison
(recording mode only).

Note the AX identifier placement, measured (J1): with an owned
`NSViewRepresentable`, `.accessibilityIdentifier(...)` applied to the
SwiftUI wrapper lands on the enclosing **`AXScrollArea`** and wins
`kayaAxFind`'s first-hit search, which would break `expect_ax` (it would
report `AXScrollArea` where the a11y milestone pinned `AXTextArea`).
Setting it with `NSView.setAccessibilityIdentifier` on the text view
itself puts it back on the `AXTextArea` — `role=AXTextArea chars=1919
sel={100,5} vis={1184,224} bgRuns=3` (J1). This is a landmine for
whoever writes the arm.

---

## 5. The ENTRY is a separate, harder problem (G3)

kaya's entry is a SwiftUI `TextField` → `AppKitTextField` (an
`NSTextField`). An `NSTextField` has **no text view of its own**: it
borrows the window's shared field editor only while focused.

| state | measured |
| --- | --- |
| unfocused | `currentEditor() == nil`. AX role `AXTextField`, `AXSelectedTextRange` readable (`{0,0}`), `AXAttributedStringForRange` readable. **Nothing to attach a highlight to.** |
| focused | field editor appears (`_SystemTextFieldFieldEditor`, TextKit 2). Selection settable, storage highlight applies, AX reads the run `{11,5}` in 0.20ms |
| after blur | field editor gone, `cell.attributedStringValue` has **0** background runs, AX has **0** — the highlight is destroyed |

So on macOS, HIGHLIGHT on an entry is either "only while focused" (a
divergence no other platform will share) or kaya owns the entry control
too. SELECT and REVEAL have the same shape: settable only through the
field editor, i.e. only while focused. (REVEAL inside a single-line entry
is horizontal scrolling; it exists but is nearly meaningless at kaya's
200pt entry width.)

This is the sweep-relevant part: whatever the milestone decides,
"textarea does X, entry does X too" costs more on mac than on any
platform whose entry is a first-class editable view.

---

## 6. What it would take — the owned NSTextView (H3, J1, J3)

Measured with a working `NSViewRepresentable` over
`NSTextView.scrollableTextView()`, a delegate reporting edits up the same
uncontrolled binding kaya already uses, and `updateNSView` re-applying
the declared ranges in the same pass that pushes the text:

| after an app-driven text change | stock `TextEditor` | owned `NSTextView` |
| --- | --- | --- |
| declared highlights | **0** (wiped) | **3** (preserved) |
| selection | `{1925,0}` (reset to end) | `{100,5}` (preserved) |
| re-declare cost | n/a — destroyed | 0.12ms |
| AX role / id | `AXTextArea id=[ta1]` | `AXTextArea id=[owned]` **if the id is set on the text view, not the wrapper** |
| AX select / reveal / highlight reads | all work | all work |

The bill for the mac arm, itemised:

1. Replace `KayaTextarea`'s `TextEditor` with an `NSViewRepresentable`
   (macOS) / `UIViewRepresentable` (iOS) — one struct each, roughly the
   shape already in this file at `:1946` and `:5881`. This is the whole
   cost, and everything else follows.
2. Re-implement what `TextEditor` gave for free: the uncontrolled
   binding + `KayaHost.emitText` (delegate `textDidChange`), the
   `@FocusState` mirror of `kayaScene.focusedId` (`becomeFirstResponder`
   + `NSTextViewDelegate` didBeginEditing), the border and frame, and
   the universal a11y props, which currently ride SwiftUI modifiers
   (`kayaApplyA11y`, `:2938-2978`) — `check-universal-props.py` will
   police that, correctly.
3. Set the a11y identifier on the text view itself, or `expect_ax`
   regresses to `AXScrollArea` (J1).
4. Keep the widget-id → text-view map. The natural place is the
   representable's `Coordinator` keyed by `node.id`; the `.background()`
   accessor + geometry trick this probe used works but is a hack that
   only exists because the stock view can't be reached — with an owned
   view it is unnecessary.
5. Never read `.layoutManager` (TextKit 1 conversion trap).
6. Decide the composition rule (SELECT commits marked text; HIGHLIGHT
   and REVEAL do not disturb it).
7. Undo: nothing to do. None of the three registers an undo action
   (H1), so the native-undo tier (`:6190-6234`) and
   `tools/check-native-undo.py` are untouched.

If instead the milestone wants to keep the stock `TextEditor`: SELECT
works (`TextSelection`, macOS 15) but is reset by every app text write;
HIGHLIGHT works only as `AttributedString` value attributes (macOS 26,
SwiftUI scope), which changes the text prop in all 8 bindings; and
**REVEAL cannot be done at all**. That is not a viable arm.

---

## 7. Three-capability table (mac / SwiftUI)

| | HIGHLIGHT (set of ranges) | SELECT (one range) | REVEAL (scroll into view) |
| --- | --- | --- | --- |
| **API** | `NSTextStorage.addAttribute(.backgroundColor,…)` for an AX-readable highlight; `NSTextLayoutManager.addRenderingAttribute` for a non-document one; `NSTextHighlightStyleAttributeName` for the system look (macOS 15+, TextKit 2) | `NSTextView.setSelectedRange(_:)`; `selectedRanges` for many; SwiftUI `TextSelection` (macOS 15) | `NSTextView.scrollRangeToVisible(_:)`; centred via `enumerateTextSegments` + `scrollToVisible` |
| **kaya sits on today** | SwiftUI `TextEditor` → `PlatformTextView` (TextKit 2, in `AppKitScrollView`), `swift/KayaSwiftUI.swift:7830` — no handle to it | same view; kaya already sets a selection at `:6312` but only on the FOCUSED responder (`:6226`) | same view; no reveal anywhere today |
| **survives edits?** | user edit: **yes**, ranges shift and split correctly, no bleed. app text write: **no** — wiped one turn (~11ms) later, and a same-turn re-declare is destroyed too | user edit: yes. app text write: **no** — caret reset to end of document | n/a (scroll position, not a range) |
| **cost** | 0.44–0.92ms for 60 ranges; 1.01ms for 500 ranges over 66k chars; flat in n | 0.56ms | 2.45ms |
| **flicker** | one frame per app text write with the stock view; **none** with an owned view (re-declared in the same pass) | same | none |
| **IME risk** | none — a highlight does not disturb marked text | **commits the composition**, shifting all later offsets | none — a scroll does not disturb marked text |
| **observability** | `AXAttributedStringForRange` → `AXBackgroundColor` runs. **Only for textStorage attributes**; rendering attributes and `NSTextHighlightStyle` are invisible to AX. 0.58ms for 60 runs over 1.9k chars, 6.94ms for 500 over 67k | `AXSelectedTextRange`; `AXSelectedTextRanges` for multi. Exact round-trip | `AXVisibleCharacterRange`; assert containment of the declared range. Moves on every scroll, selection untouched |
| **verdict** | DO, on document attributes, in an owned view | DO | DO |

---

## 8. Notes the other arms may want

- The find-bar answer generalises: macOS publishes **no** accessibility
  surface for "highlighted ranges" as distinct from selection. If another
  platform's AT layer does (AT-SPI has text attributes; UIA has
  `TextRange`/`GetAttributeValue` and annotations), the uniform
  assertion has to be the intersection, and on mac that intersection is
  "a background colour attribute on the text runs".
- macOS's multi-range SELECT is real and AX-readable
  (`AXSelectedTextRanges`), so if some platform can only select one
  range, the carve-out is theirs, not mac's.
- The iOS arm shares this file. `TextEditor` on iOS is `UITextView`, and
  the same push-order argument applies to `UIViewRepresentable`; the AX
  read differs (UIKit has no role vocabulary — see the existing arm at
  `swift/KayaSwiftUI.swift:2916+`), and `UITextRange`/
  `UIAccessibilityTextRange` would need its own measurement. Not probed
  here.

---

## 9. Probe artifacts and cleanup

Sources and logs lived in
`/private/tmp/claude-501/-Users-akhilindurti-Projects-kaya/24aa5ebf-e439-4206-9ba0-de67540e4b06/scratchpad/range-probe-mac/ (gone)`
(5 Swift probes, 5 binaries, 5 logs, one GUI-locked runner). See the
cleanup section appended below for the proof they are gone.
