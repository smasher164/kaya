# TEXT-RANGES probe — iOS arm (SwiftUI interpreter, simulator)

Probe for the TEXT-RANGES milestone: HIGHLIGHT (a set of ranges), SELECT
(one range), REVEAL (scroll a range into view) on kaya's iOS text
widgets. Nothing ships from this file; the measurement is the
deliverable.

- Repo HEAD at start: 6a616d6
- Xcode 26.6 (17F113), iOS simulator SDK 26.5, device kaya-sim-0 (iOS 26.5)
- Probe sources + build: scratchpad only (`rangeprobe/`), nothing in the repo tree
- Status: IN PROGRESS

## 0. What kaya's iOS text widgets sit on today (read, not assumed)

| thing | where | note |
|---|---|---|
| entry | `swift/KayaSwiftUI.swift:8578` `struct KayaEntry` | SwiftUI `TextField("", text:)` + `.textFieldStyle(.roundedBorder)` + `.frame(maxWidth: 200)`, `@FocusState` |
| textarea | `swift/KayaSwiftUI.swift:8619` `struct KayaTextarea` | SwiftUI `TextEditor(text:)` + `.frame(width: 240, height: 96)` + `.border(...)`, `@FocusState` |
| binding shape | `:8592` / `:8625` | UNCONTROLLED toward the app: get returns `node.text`, set writes the node and emits `text_changed`. Nothing is read back from the app. |
| a11y identifier | `:2967` | `.accessibilityIdentifier(node.a11yId)` applied by the universal wrapper |
| render dispatch | `:5706` `case kindTextarea:` | |
| harness read (iOS) | `:3435` `kayaAxRead` | walks the a11y tree by identifier, returns `role + "/" + (label ?? value)` — a STRING, no range vocabulary |
| role classification | `:3302` | `if element is UITextView \|\| element is UITextField { return "field" }` — the a11y element for both kinds IS the UIKit view |
| first-responder walk | `:6468` `kayaFirstResponderView()` | recursive `isFirstResponder` walk over `UIApplication.shared.connectedScenes` windows — no UIKit API names the first responder |
| focused editable | `:6491` `kayaFocusedTextInput()` | `kayaFirstResponderView() as? (UIView & UITextInput)` — **only reachable while focused** |
| `type` verb (iOS) | `:6545` `kayaTypeAtFocus` | `insertText(_:)` through `UIKeyInput` |

The load-bearing gap before any design exists: **every existing iOS
reach-down into UIKit goes through the FIRST RESPONDER**. Ranges are
declared on a widget whether or not it is focused, so this arm needs a
node-id -> UIView map that does not exist yet. Measured in M1 below.

## 1. SDK survey (verified against the iPhoneSimulator 26.5 SDK, not memory)

Header paths below are relative to
`Xcode-26.6.0.app/Contents/Developer/Platforms/iPhoneSimulator.platform/Developer/SDKs/iPhoneSimulator.sdk/System/Library/Frameworks/`.

### UIKit (`UIKit.framework/Headers/UITextView.h`)

- `:244` `- (void)scrollRangeToVisible:(NSRange)range;` — REVEAL, no availability gate (UITextView since 2.0).
- `:228` `@property(nonatomic) NSRange selectedRange` — now
  `API_DEPRECATED_WITH_REPLACEMENT("selectedRanges", ios(2.0, API_TO_BE_DEPRECATED))`.
- `:232` `@property NSArray<NSValue*> *selectedRanges API_AVAILABLE(ios(26.0)...)` — **multi-range selection is new in iOS 26**; a one-range SELECT does not need it.
- `:241` `attributedText API_AVAILABLE(ios(6.0))`.
- `:271` `textLayoutManager API_AVAILABLE(ios(16.0))`, and the header states in as many words: *"From iOS 16 onwards, UITextViews are, by default, created with a TextKit 2 NSTextLayoutManager"*, and `:273` *"accessing the .layoutManager ... will cause a UITextView that's using TextKit 2 to 'fall back' to TextKit 1 ... any TextKit 2 objects you may have cached will cease functioning"*.

### TextKit 2 rendering attributes (`UIKit.framework/Headers/NSTextLayoutManager.h`)

This is the iOS equivalent of AppKit's temporary attributes, and it is
the only one:

- `:120` `- (void)setRenderingAttributes:(NSDictionary<NSAttributedStringKey,id>*)forTextRange:`
- `:123` `- (void)addRenderingAttribute:(NSAttributedStringKey)value:forTextRange:`
- `:126` `- (void)removeRenderingAttribute:(NSAttributedStringKey)forTextRange:`
- `:117` `- (void)enumerateRenderingAttributesFromLocation:reverse:usingBlock:` — **the read-back**, which is what makes a highlight assertable at all
- `:132` `renderingAttributesValidator` block — re-supplies attributes when the layout manager invalidates a fragment

`NSTextLayoutManager` is `API_AVAILABLE(ios(15.0))`; a UITextView only
has one from **iOS 16** (`:271`), which is exactly kaya's iOS floor
(`tools/ios/run-sim.py:101` `IOS_MIN = "16.0"`).

**AppKit's `setTemporaryAttributes:forCharacterRange:` HAS NO iOS
SIBLING.** Grepping `NSLayoutManager.h` in the iOS SDK for
`emporaryAttributes` returns nothing. So on iOS the TextKit 1 path has
no non-destructive styling at all: if a UITextView falls back to TextKit
1 (which merely *touching* `.layoutManager` does), the only remaining
highlight mechanism is mutating `attributedText`/`textStorage`.

### SwiftUI (`SwiftUI.framework/Modules/SwiftUI.swiftmodule/arm64-apple-ios-simulator.swiftinterface`)

- `:2937` `TextEditor.init(text: Binding<String>)` — what kaya uses, iOS 14.
- `:2939` `init(text: Binding<String>, selection: Binding<TextSelection?>)` — **`@available(iOS 18.0, macOS 15.0, visionOS 2.0, *)`**
- `:2943` `init(text: Binding<AttributedString>, selection: Binding<AttributedTextSelection>? = nil)` — **`@available(iOS 26.0, macOS 26.0, *)`**
- `:5128`/`:5144` the same `selection: Binding<TextSelection?>` overloads on `TextField` — iOS 18.
- `:19014` `struct TextSelection` (iOS 18) — `Indices` is `.selection(Range<String.Index>)` or `.multiSelection(RangeSet<String.Index>)`.
- `:14622` `struct AttributedTextSelection` (iOS 26).
- There is **no SwiftUI-level scroll-a-text-range-into-view API** in the
  interface at any availability. REVEAL has no SwiftUI spelling.

So the SwiftUI-native surface gives SELECT at iOS 18 and HIGHLIGHT only
at iOS 26 (via an `AttributedString`-bound editor, which would also
change kaya's model type from `String`), and gives REVEAL never. Against
kaya's declared floor of iOS 16 all three are below the line today.

---

(measurements appended below as they are taken)

---

# The measurements

Five probe builds on **kaya-sim-0 (iPhone, iOS 26.5)**, each a SwiftUI app
whose `ProbeEntry`/`ProbeTextarea` mirror `KayaEntry`/`KayaTextarea`
exactly in shape (@Observable node, uncontrolled binding whose setter
writes the node and emits, `@FocusState`, the same frames and styles, the
universal `.accessibilityIdentifier`). Raw logs: `rangeprobe/clean{,2,3,4,5}.log`.

"drawn=N" is a pixel count of the highlight colour in what the view
ACTUALLY DRAWS, taken in-process by rendering `view.layer` into a bitmap
and counting matches. An in-process render beats a host screenshot: it is
numeric, needs no image library on the host, and it is the same layer
tree the screen composites.

## M1 — what is actually under the two SwiftUI views

```
found=UITextField          chain=UITextField < UIKitPlatformViewHost<PlatformViewRepresentableAdaptor<PlatformTextFieldAdaptor>> < _UIHostingView<...> < UIWindow
found=TextEditorTextView   chain=TextEditorTextView < UIKitPlatformViewHost<PlatformViewRepresentableAdaptor<UIKitTextViewAdaptor>> < _UIHostingView<...> < UIWindow
textview.textLayoutManager=TK2      textview.isScrollEnabled=true
textview.contentSize=(240,1781)  bounds=(240,96)   (both found while UNFOCUSED)
```

- The textarea is a real `UITextView` subclass (`TextEditorTextView`),
  **TextKit 2**, scroll-enabled, reachable in the view tree with nothing
  focused. It is the scroller itself — no enclosing UIScrollView.
- The entry is a plain `UITextField`.
- kaya's existing reach-down (`kayaFocusedTextInput`, `:6491`) gates on
  first responder; the plain class walk does not, and both views are
  found unfocused.

## M2 / N1 / S1 — HIGHLIGHT on the textarea (TextKit 2 rendering attributes)

Applying, reading and clearing are all **sub-millisecond**:

| operation | cost |
|---|---|
| `addRenderingAttribute(.backgroundColor,…)` × 2 | 0.08 ms |
| × 50 | 0.49 ms |
| `enumerateRenderingAttributes` read-back of 50 | 0.14 ms |
| `removeRenderingAttribute` over the whole document | 0.11 ms |

Read-back is exact: `readback=["5,5", "30,11"]`, `readback50.count=50`.

**The one non-obvious cost: THE ATTRIBUTE DOES NOT REPAINT ON ITS OWN.**

```
N1|t0.drawn=0 … turn1..turn6.drawn=0        (6 settle rounds, ~150 ms, attribute present in the read-back)
N1|setNeedsDisplay.drawn=765
S1|afterInvalidateOnly.drawn=0 … turn1..turn4.drawn=0   (invalidateRenderingAttributes(for:) alone)
S1|afterSetNeedsDisplay.drawn=765
```

`invalidateRenderingAttributesForTextRange:` — the API whose name says it
should be the lever — changes nothing. `setNeedsDisplay()` on the text
view is the lever, and it is required. A lowering that omits it applies a
highlight that is real to every read-back and invisible on screen until
some unrelated SwiftUI update happens to redraw the view. That is the
worst possible failure shape: green harness, blank screen.

## M6 / R2 — HIGHLIGHT on the entry (attributedText only)

`UITextField` has no TextKit at all: `tf.responds(to: "textLayoutManager") = false`.
So `attributedText` is the only lever, and it is **conditioned on focus**:

```
R2|fr=false
R2|unfocused.survived=true  drawn=473        <- set while unfocused: sticks and paints
R2|afterFocus.survived=false drawn=0         <- becoming first responder WIPES it
R2|focusedSet.immediate=true
R2|focusedSet.settled=false drawn=0          <- set while focused: reverted a turn later
R2|afterInsert.settled=true drawn=477        <- ...unless an edit follows, which re-commits it
```

The mechanism is visible in the subtree dump: a focused `UITextField`
installs a `UIFieldEditor` (a `UIScrollView`) with its own
`_UITextLayoutCanvasView` / `_UITextLayoutFragmentView`, and the
attributed string is re-derived from `text` when it does. Highlight on a
FOCUSED entry through `attributedText` is not dependable on iOS 26.

Setting `attributedText` is otherwise clean: `emitsDelta=0`,
`modelChanged=false`, no scroll jump (`offset` unchanged), the text view
stays on TextKit 2, typing attributes intact.

## M3 / N4 / R5 — do ranges survive edits?

Two different edits, two different answers, and the difference is the
whole story:

| edit | rendering attributes after |
|---|---|
| USER edit (`insertText("Q")` at 0 — kaya's `type` verb path, `:6545`) | `["5,8","30,6"]` -> `["6,8","31,6"]` — **survive and shift correctly** |
| MODEL write (`node.text = "X" + node.text`, SwiftUI pushes it down) | `[]`, `drawn=0` — **wiped** |

A user's own typing mutates the view's text storage in place and TextKit
2 carries the rendering attributes through it. A programmatic model
change makes SwiftUI replace the whole string, and the rendering
attributes go with the old storage. So the "app re-declares after each
change" model is not merely the expected one here — for programmatic
edits it is the ONLY one.

**And the naive re-declare is wrong.** Measured:

```
R5|afterEdit         = ["6,8"]     (the user typed one char at 0; the range shifted)
R5|naiveRedeclare    = ["5,9"]     (app re-declares 5,8 — UNIONED with the stale shifted one)
R5|clearedRedeclare  = ["5,8"]     (clear the document's attribute first, then apply)
```

A lowering that applies without clearing produces a range that is wrong
at both ends and drifts one character further wrong per keystroke. The
clear costs 0.11 ms.

### flicker: none, either way

Re-declaring inside the binding setter (the shape of "the app re-declares
inside its own `text_changed` handler") and re-declaring on the next
main-queue turn both hold the highlight continuously — 14 consecutive
main-runloop samples, no zero in either sequence:

```
N5|inSetter.frames  = [1764 × 14]
N5|nextTurn.frames  = [1293 × 14]
```

There is no window in which the highlight is missing, because the user
edit never removed it in the first place. The re-declare is a correction,
not a repaint.

## M4 / S3 — SELECT

```
M4|unfocused.set -> read={10, 12} firstResponder=false     <- settable and retained while unfocused
S3|unfocused.drawnSelection=0                              <- and INVISIBLE
S3|focused.drawnSelection=2255  read={10, 20}              <- paints once the view is first responder
M4|focused.selectedTextRange=10,12                         <- same fact through UITextInput
M4|afterRerender.read={10, 12}                             <- survives a SwiftUI body pass
M4|afterModelWrite.read={1552, 0}                          <- COLLAPSED to the end by a model write
```

`selectedRange` is settable and readable with nothing focused, and it
survives a re-render, but **iOS paints no selection in an unfocused text
view** — unlike AppKit, which draws an unfocused selection in a secondary
colour. So on this platform SELECT is either accompanied by focus or it
is a fact with no pixels. That is a semantics question for the milestone,
not a platform limit: the write always lands and always reads back.

A model write collapses the selection to a caret at the end, so SELECT
needs the same re-declare-after-edit treatment as HIGHLIGHT.

`selectedRange` is now `API_DEPRECATED_WITH_REPLACEMENT("selectedRanges")`
as of iOS 26 (`UITextView.h:228`) — still functional, but a one-range
SELECT lowering should expect to move to `selectedRanges` (iOS 26,
`:232`) eventually. Deprecation is not removal and the floor is iOS 16,
so `selectedRange` is the spelling for now.

## M5 / N2 / R1 — REVEAL on the textarea

`scrollRangeToVisible(_:)` works, is unavailable on the entry
(`tf.responds(to:"scrollRangeToVisible:") = false`), and has one trap:
**it is ANIMATED**, so it reads as a no-op if sampled at the call site.

```
N2|call.ms=0.53  offsetImmediately=0.0
N2|poll1 t=37ms  offset=32     visible=false
N2|poll4 t=148ms offset=762    visible=false
N2|poll8 t=299ms offset=1653   visible=true       <- ~300 ms, standard UIKit curve
N2|poll12 t=450ms offset=1654.67 visible=true
```

Wrapped in `UIView.performWithoutAnimation` it lands synchronously:

```
R1|performWithoutAnimation.ms=3.95  offsetNow=1654.67   visible=true (immediately, and every poll after)
```

The computed alternative — `firstRect(for:)` then
`setContentOffset(_:animated:false)` — also lands synchronously in
1.81 ms and gives centring control:

```
R1|computed.ms=1.81 rect=(75,1701,160,23) offsetNow=1664.67 visible=true
```

Reveal does **not** require focus: `N3|unfocused.after=983.0 fr=false`
(sampled mid-animation, climbing to the target). Probe 1's
`M5|unfocused.reveal.offset=(0,0)` was my own artefact — sampled at the
call site, before the animation had run a frame.

## T1–T3 / S2 — REVEAL on the entry

The entry's story is entirely different and depends on focus:

```
T1|editor=none                                    <- UNFOCUSED: no field editor exists
T1|x@0=0.0  x@60=0.0  x@120=0.0                   <- and firstRect answers 0 for EVERY offset
T2|onFocus.offset=823.0 size=1009.0 w=186.0       <- FOCUSED: a UIFieldEditor (UIScrollView) appears
T2|caret0.offset=0.0     visible0=true
T2|caret120.offset=743.3 visible120=true          <- setting the selection AUTO-SCROLLS to it
T2|range100_110.offset=588.3 visible100=true
T3|reset.offset=0.0      visible120=false
T3|scrollRectToVisible.ms=0.40 offset=776.7 visible120=true   <- explicit reveal works, on the field editor
T3|afterBlur.editor=gone
```

So on the entry:
- unfocused, there is **no text geometry and nothing to scroll** — REVEAL
  is not merely unavailable, it is unanswerable (`firstRect` = 0 everywhere);
- focused, **SELECT gives REVEAL for free** (setting `selectedTextRange`
  scrolls the caret into view);
- focused, an independent REVEAL is possible by finding the field's
  descendant `UIScrollView` (the `UIFieldEditor`) and calling
  `scrollRectToVisible(firstRect(for:))` — public API on a
  privately-named class, found by `as? UIScrollView`, the same shape as
  kaya's existing first-responder walk but one step more fragile.

## M8 — composition / IME

Marked text set with `setMarkedText("にほんご", selectedRange:)`, then each
primitive applied on top:

```
M8|marked.set markedRange=true  marked.at=0,4
M8|afterHighlight.marked=true      (addRenderingAttribute)
M8|afterReveal.marked=true         (scrollRangeToVisible)
M8|afterSelect.marked=true  sel={30,4}  len unchanged   (selectedRange, OUTSIDE the marked range)
M8|final.marked=true  text.head=にほんごZYXline
M8|afterModelWriteDuringComposition.marked=false        (node.text = … + "#")
```

**None of the three primitives disturbs an in-flight composition.** The
one thing that does is the mechanism kaya already has: a programmatic
model write drops `markedTextRange` and commits the composed text. That
is a pre-existing property of the uncontrolled binding, not something
this milestone introduces — but it means an app that re-declares ranges
by ALSO rewriting the text will end compositions, and an app that
re-declares ranges only is safe.

Not measured: whether a rendering-attribute background *underneath* the
marked-text underline is visually confusing. The underline is drawn by
`_UITextUnderlineView` (visible in the entry subtree dump), i.e. a
separate view, so the two compose rather than conflict.

## R4 — OBSERVABILITY (the deciding measurement)

kaya's iOS harness read is `kayaAxRead` (`:3435`): flip the AX automation
switch, then `kayaAxFind` (`:3343`) walks the accessibility tree by
identifier. I ran **kaya's own find, copied verbatim**, against the probe:

```
R4|hit=TextEditorTextView  isUITextView=true  ident=probe-textarea
R4|hit.selectedRange={12, 7}
R4|hit.contentOffset=1664.67  contentSize=1776.0  bounds=96.0
R4|hit.highlights=["5,8", "40,4"]
R4|hit.revealVisible(0,4)=false
R4|directIdentifier=probe-textarea  sameObject=true
R4|entryHit=UITextField  isUITextField=true
R4|entryHit.sel=120,0
```

**The object kaya's existing harness find returns IS the UITextView** (and
for the entry, IS the UITextField). Every read the three primitives need
hangs off that same object, in public API, with no new plumbing:

| primitive | read-back | evidence |
|---|---|---|
| HIGHLIGHT | `textLayoutManager.enumerateRenderingAttributes(from:reverse:)` filtered to the key, offsets via `textContentManager.offset(from:to:)` | `hit.highlights=["5,8","40,4"]` — exactly what was declared |
| SELECT | `selectedRange` (or `selectedTextRange` + `offset(from:to:)`, which works on both kinds) | `hit.selectedRange={12,7}`, `entryHit.sel=120,0` |
| REVEAL | `bounds.intersects(firstRect(for:))` on the textarea; on the entry, the caret x against the field editor's `contentOffset.x … +bounds.width` | `revealVisible(0,4)=false` with the view scrolled to the bottom |

One caveat, measured: the identifier is **nil on the UIView until the
accessibility tree has been built** (`N8|textview.perform=nil` when read
by a bare subview walk; `R4|directIdentifier=probe-textarea` after
`kayaAxFind` has walked the container tree with automation on). This does
not affect the harness — `kayaAxRead` enables automation and walks the
container tree, which is what materializes it — but it does mean **the
identifier cannot be the lowering's node -> view map**, because lowering
runs in a shipped app with no assistive client.

### the lowering's node -> view problem

Nothing in the existing interpreter maps a kaya node id to its UIKit
view except through the first responder (`:6491`), and range primitives
are declared on widgets that are not focused. The precedent for solving
it is already in this file: `KayaWindowAccessor` (`:8511`), a
representable installed with `.background(...)` purely to reach the
platform object. The same shape — a zero-size `UIViewRepresentable`
alongside the TextField/TextEditor whose `updateUIView` walks to the
sibling `UITextView`/`UITextField` — is the honest route, and matches the
ratified gap policy (interpreter-internal Representable drop-downs).
Whether kaya instead replaces `TextEditor` with its own representable is
a design question this probe does not answer, but note that doing so
would give a supported handle and cost the SwiftUI-native behaviours
(Writing Tools, the iOS 26 text effects, whatever ships next).

## Availability against kaya's floor

kaya's iOS floor is **16.0** (`tools/ios/run-sim.py:101`); the interpreter
is typechecked at 17.0 (`tools/swift-typecheck.sh:117`).

| route | needs | verdict at floor 16 |
|---|---|---|
| UITextView rendering attributes + `selectedRange` + `scrollRangeToVisible` | UITextView TK2 = iOS 16 | **usable, whole surface** |
| SwiftUI `TextEditor(text:selection:)` | iOS 18 | above the floor |
| SwiftUI `TextEditor(text: Binding<AttributedString>, selection:)` | iOS 26 | far above the floor, and it changes kaya's model type from `String` |
| SwiftUI reveal-a-range | does not exist at any version | n/a |

The UIKit route is the only one that covers all three at the floor, and
it is also the only one that covers REVEAL at all.

---

# Verdict — iOS arm

**All three primitives are affordable on the textarea and land on public
API at kaya's iOS floor. The entry is where the divergence is**, and it is
not one gap but three different ones, so the uniform-semantics question
this milestone has to answer is "what does a kaya entry promise", not
"does iOS support ranges".

## The three-capability table

| capability | textarea (`TextEditor` -> `TextEditorTextView`) | entry (`TextField` -> `UITextField`) |
|---|---|---|
| **HIGHLIGHT** (set of ranges) | **DO.** `NSTextLayoutManager.addRenderingAttribute(.backgroundColor,…)` per range, TextKit 2, iOS 16. 0.08 ms for 2, **0.49 ms for 50**. Non-destructive: no emit, no model change, text storage untouched. **Requires `setNeedsDisplay()`** — nothing else repaints it, `invalidateRenderingAttributes` included. | **DEFER / can't cleanly.** No TextKit at all (`responds(to:"textLayoutManager")=false`); `attributedText` is the only lever, and a focused field **wipes it on focus and reverts it a turn after being set**. Reliable only while unfocused. |
| **SELECT** (one range) | **DO.** `selectedRange` (or `selectedTextRange`, shared with the entry). Settable and readable unfocused, survives a re-render. **Paints nothing until the view is first responder** (0 px vs 2255 px) — iOS has no unfocused-selection colour, unlike AppKit. | **DO.** `selectedTextRange` via `UITextInput`; reads back exactly (`entryHit.sel=120,0`). Same focus-to-paint rule. |
| **REVEAL** (scroll a range into view) | **DO, with a wrapper.** `scrollRangeToVisible(_:)`. **It is ANIMATED (~300 ms)** and reads as a no-op at the call site; `UIView.performWithoutAnimation { … }` lands it synchronously (3.95 ms). Works unfocused. Alternative: `firstRect(for:)` + `setContentOffset(animated:false)`, 1.81 ms, gives centring control. | **CAN'T unfocused; DO focused.** No `scrollRangeToVisible` (`responds=false`); unfocused there is no field editor and `firstRect` answers 0 for every offset — nothing to scroll and nothing to measure. Focused, setting the selection auto-reveals for free, and an independent reveal needs `scrollRectToVisible` on the field's descendant `UIScrollView` (the privately-named `UIFieldEditor`, reached by public superclass). |

## Ranges through edits

- **User typing preserves and shifts rendering attributes correctly**
  (`["5,8","30,6"]` -> `["6,8","31,6"]` after one insert at 0). A model
  write wipes them (SwiftUI replaces the string). Selection is collapsed
  to the end by a model write either way.
- The re-declare model is right, and **it must clear before it applies**:
  a naive re-apply unions with the stale shifted range
  (`["5,8"]` + shifted `["6,8"]` = `["5,9"]`) and drifts one character
  further wrong per keystroke. Clearing the document's attribute first
  costs 0.11 ms.
- **No flicker at either timing** — synchronous in the handler or on the
  next main-queue turn, 14 consecutive samples with the highlight
  continuously present.
- Total per-edit cost of a full re-declare of 50 ranges:
  ~0.6 ms (clear 0.11 + apply 0.49) + one `setNeedsDisplay`. Not a budget
  question.

## Composition / IME

**None of the three primitives disturbs an in-flight composition** —
marked text survived a highlight, a reveal, and even a selection change
outside the marked range. The one thing that ends a composition is a
programmatic model write, which is kaya's existing binding behaviour, not
something this milestone adds. An app that re-declares ranges only is
safe; an app that re-declares ranges by rewriting the text will commit
whatever the user is composing.

## Observability — the primitives are assertable

Not through an accessibility attribute: **iOS has no AX vocabulary for
text ranges**. `accessibilityAttributedValue` sees an `attributedText`
highlight (`bgAt6=true`) and is BLIND to rendering attributes
(`bgAt42=false`), and there is no AX selected-range or scroll-position
read at all. The `accessibilityTextInputResponder` hook (iOS 18.1) reads
false here.

It does not matter, because on iOS the harness read is in-process and
**kaya's existing `kayaAxFind` returns the `UITextView`/`UITextField`
object itself** (`hit=TextEditorTextView isUITextView=true
ident=probe-textarea`, `sameObject=true` against the plain view walk).
Every read hangs off that object in public API:

- HIGHLIGHT — `enumerateRenderingAttributes` filtered to the key; returned
  exactly `["5,8","40,4"]`, the declared set. On the entry, enumerate
  `attributedText`'s `.backgroundColor` runs instead.
- SELECT — `selectedRange`, or `selectedTextRange` + `offset(from:to:)`
  for one spelling across both kinds.
- REVEAL — `bounds.intersects(firstRect(for:))` on the textarea; on the
  entry, the caret x against the field editor's visible x window (the
  field's own bounds are the WRONG oracle — probe 4 got a false negative
  that way, `firstRect` there is in the editor's content space).

A harness verb reading "highlights", "selection", "reveal-visible" off a
target is therefore a small addition to the same `kayaAxRead` shape that
already exists, returning strings the shared `.steps` scripts can compare
byte-for-byte.

## What this arm needs from the design that it does not have

1. **A node-id -> UIView map that does not go through the first
   responder.** Every existing iOS reach-down is `kayaFirstResponderView()`
   -gated (`:6468`, `:6491`), and ranges are declared on unfocused
   widgets. The accessibility identifier cannot serve — it is nil on the
   view until an assistive client builds the tree (measured), and a
   shipped app has none. The precedent in this file is
   `KayaWindowAccessor` (`:8511`): a representable installed with
   `.background(...)` purely to capture the platform object.
2. **A ruling on SELECT without focus.** The write lands and reads back;
   iOS paints nothing. Either SELECT implies focus (uniform, costs a
   focus change the app did not ask for) or SELECT is declared to be
   invisible until focus arrives (uniform in semantics, divergent in
   pixels — AppKit paints an unfocused selection).
3. **A ruling on the entry.** Three separate answers on one platform:
   HIGHLIGHT unreliable when focused, SELECT fine, REVEAL impossible
   unfocused. If the milestone wants one semantics for both kinds, the
   entry is the constraint that decides it.

## Guard candidates this probe would put on a path nobody can avoid

- **The missing `setNeedsDisplay`.** A highlight that reads back and
  never paints is the exact failure shape kaya's doctrine calls out
  (green harness, blank screen). The read-back oracle CANNOT catch it —
  it queries the same layout manager. The assertion has to be a drawn
  fact, and the probe's in-process layer render (count the highlight
  colour in `view.layer.render(in:)`) is a cheap way to make the harness
  read the pixels rather than the model.
- **The unioned stale range.** `["5,9"]` after a naive re-declare is a
  silent one-character-per-keystroke drift. A negative test that types
  one character and asserts the range is exactly what was re-declared
  catches it; it must be watched failing with the clear removed.
- **The animated reveal.** A leg that asserts immediately after
  `scrollRangeToVisible` fails; a leg that sleeps 300 ms passes for the
  wrong reason. `performWithoutAnimation` at the lowering makes the
  assertion synchronous and the behaviour deterministic.
