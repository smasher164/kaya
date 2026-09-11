# Rich text on Apple — what the controls actually do, measured

Probe record for docs/rich-text-plan.md §3, feeding R4 (edit reporting),
R6 (native undo suppression) and R9 (the AX word set). Nothing in the kaya
repository was edited. Sources and raw output live beside this file under
`probes/apple/`:

| file | what it is |
| --- | --- |
| `probes/apple/macprobe.swift` | the macOS probe, five modes (`edits`, `undo`, `undokey`, `typing`, `rtf`, `axhold`) |
| `probes/apple/axread.swift` | the SEPARATE-PROCESS accessibility reader (`axread <pid>`) |
| `probes/apple/iosprobe/` | the iOS simulator bundle and its sources |
| `probes/apple/out-*.txt` | the raw runs quoted below, verbatim |

Host: macOS 26.6.2 (25G83), Xcode 26.6.0, `kaya_swiftc` through
`tools/lib/swift-toolchain.sh` (docs/HACKING.md's Hand tools table).
The macOS fixture is kaya's own: `NSTextContentStorage` +
`NSTextLayoutManager` + `NSTextContainer` assembled by name (TextKit 2,
confirmed `view.textLayoutManager != nil`), with `kayaPinPlainText`'s pin
set copied verbatim from `swift/KayaSwiftUI.swift`.

The host's own UI was never driven: the probe opens its OWN window and its
OWN Edit menu, the pasteboard used is a PRIVATE `NSPasteboard(name:)` and
never `.general`, and the input source was never switched (see §2.5). The
host had been idle 12h (`HIDIdleTime` 43,920s) before the one mode that
activates the probe's app.

---

## 1. UNDO SCOPE AND SUPPRESSION — R6

### 1.1 macOS, `allowsUndo = true`

A toolbar Bold applied the way the text system wants it — `shouldChangeText(in:replacementString: nil)`,
then `textStorage.addAttribute(.font, bold, range:)`, then `didChangeText()` —
**registers undo, and undo reverts the attribute** (`out-undo.txt`):

```
-- allowsUndo=true, ATTRIBUTE-ONLY through shouldChangeText(nil)/didChangeText
  shouldChangeText(nil) returned true; font at 0 = .SFNS-Bold/13.0[bold]
  canUndo=true undoActionName=
  after undo(): font at 0 = .AppleSystemUIFont/13.0 string="hello world"
  canRedo=true
  after redo(): font at 0 = .SFNS-Bold/13.0[bold]
```

Redo restores it. `undoActionName` is EMPTY — AppKit registers the action
but names it nothing, so a menu item would read plain "Undo".

Two negatives beside it, both measured, both load-bearing for `apply_edit`:

```
-- allowsUndo=true, attribute change WITHOUT shouldChangeText/didChangeText
  canUndo=false
-- allowsUndo=true, setTextColor: (an AppKit rich-text action)
  canUndo=false undoActionName=
  after undo(): foregroundColor at 0 = Catalog color: System systemRedColor
```

So the undo tier is **entered by the `shouldChangeText`/`didChangeText`
bracket and by nothing else**. A programmatic write straight to the storage
registers nothing even with `allowsUndo = true`; `NSTextView.setTextColor(_:range:)`
registers nothing either. That is the lever `apply_edit` needs: a remote or
app-owned edit applied without the bracket cannot be undone by the native
stack, and no new switch is required for it.

### 1.2 macOS, `allowsUndo = false` — the off switch, with the negative watched

`allowsUndo = false` does more than stop registration: **`view.undoManager`
becomes `nil`**. With it true, the view's manager and the window's are the
SAME object (`ObjectIdentifier(0x…4fc0)` for both).

The first run of this probe could not tell the switch from a dead channel,
because the app was `.accessory` and inactive, so no Cmd-Z reached the view
at all. A POSITIVE CONTROL was added (`undokey` mode: the probe activates
its OWN app, own menu, own window) and watched succeeding before the
negative was believed (`out-undokey.txt`):

```
activated: isKeyWindow=true NSApp.isActive=true
-- POSITIVE CONTROL: Cmd-Z with allowsUndo=TRUE, the same three channels
  typed: string="hello worldK" canUndo=true
  [control, allowsUndo=true] view.tryToPerform(undo:) -> true; string="hello world"
  [control, allowsUndo=true] mainMenu.performKeyEquivalent -> true; string="hello world"
  [control, allowsUndo=true] NSApp.sendAction(undo:) -> true; string="hello world"
  [control, allowsUndo=true] text moved=true font moved=false
  CONTROL VERDICT: Cmd-Z DOES reach the view in this fixture
```

Then, on the same fixture, with the switch off:

```
-- flipping allowsUndo to FALSE at runtime
  text after the flip = "hello world" unchanged=true
  view.undoManager still = nil
  typed with allowsUndo=false: string="hello worldZ" view.undoManager?.canUndo=false
  and the WINDOW's manager: present canUndo=false (the chain above the view)
  attribute act with allowsUndo=false: shouldChangeText=true view.undoManager?.canUndo=false window canUndo=false
-- Cmd-Z with allowsUndo=false, three channels, none of them the host UI
  [allowsUndo=false] view.tryToPerform(undo:) -> true; string="hello worldZ"
  [allowsUndo=false] mainMenu.performKeyEquivalent -> true; string="hello worldZ"
  [allowsUndo=false] NSApp.sendEvent(Cmd-Z); string="hello worldZ"
  [allowsUndo=false] NSApp.sendAction(undo:) -> true; string="hello worldZ"
  [allowsUndo=false] text moved=false font moved=false
```

Four facts: neither text nor attributes move; the window's manager records
nothing either (so the chain above the view is not a back door); every
channel still returns `true` — **the Edit>Undo item stays enabled-looking
while doing nothing**, which is exactly why R6's D6 routing has to take the
app's `can_undo` for that widget; and `shouldChangeText` still returns
`true`, so the bracket is not a veto path for suppression.

The flip is free in both directions and per view:

```
-- flipping allowsUndo back to TRUE
  text after the flip back = "hello worldZ" unchanged=true
  view.undoManager back to Optional(ObjectIdentifier(0x…0620))
  typed: string="hello worldZQ" canUndo=true
  after undo(): string="hello worldZ"
-- per-view: a SECOND text view in the same window with allowsUndo=false
  view2.undoManager identity = nil
  view2 typed with allowsUndo=false: canUndo=false string="second2"
  view1 typed with allowsUndo=true:  canUndo=true string="hello worldZ1"
```

Text survives the flip byte for byte in both directions, the caret is not
disturbed, and two views in ONE window hold opposite settings at the same
time. R6's `own_undo()` is `allowsUndo = false` on macOS, and nothing else.

### 1.3 iOS — there is no `allowsUndo`, and the obvious substitute is a decoy

`UITextView` gets its OWN manager, a private `_UITextUndoManager`, and it is
**not** the window's (`out-ios-undo.txt`):

```
view.undoManager = Optional(ObjectIdentifier(0x…3bf0)) class=_UITextUndoManager
window.undoManager = Optional(ObjectIdentifier(0x…3b80))
same object = false
```

**Attribute changes made through `textStorage` are NOT undoable on iOS**,
with or without the `beginEditing`/`endEditing` bracket — the opposite of
macOS's `shouldChangeText(nil)` path:

```
-- attribute-only through textStorage, NO begin/endEditing
   font at 0 = .SFUI-Semibold/15.0[bold] canUndo=false
   after undo(): font at 0 = .SFUI-Semibold/15.0[bold]
-- attribute-only INSIDE beginEditing/endEditing
   font at 0 = .SFUI-Semibold/15.0[bold] canUndo=false
   after undo(): font at 0 = .SFUI-Semibold/15.0[bold]
```

The ONE attribute route that IS undoable on iOS is UIKit's own formatting
command, and it even names itself:

```
-- toggleBoldface: (UIKit's own formatting command)
   font at 0 = .SFUI-Semibold/15.0[bold] canUndo=true name=Bold
   after undo(): font at 0 = .SFUI-Regular/15.0 string="hello world"
```

**The decoy.** The obvious per-view lever is a subclass overriding
`UIResponder.undoManager` to return nil. It looks like it works — the
property answers nil, the window's manager stays empty, typing still
works — and it does not. The follow-up run undid the edit and settled it
(`out-ios-undo2.txt`):

```
-- A: override to nil, type, lift, then UNDO
   stack empty before: canUndo=false
   typed under the override: string="hello worldZ" view.undoManager=nil
   lifted: canUndo=true name=Typing
   after undo(): string="hello world"
   VERDICT: the override is a HIDING ONLY — registration continued
```

UITextView registers through its own private reference, not through the
responder-chain property. A kaya arm that shipped this would have a widget
whose undo stack quietly fills up behind an app that thinks it owns the
document, and the first Cmd-Z from a hardware keyboard would rewrite it.

**What does work** is `UndoManager.disableUndoRegistration()` on the view's
own manager. It suppresses typing AND UIKit's formatting command, it is per
view, and it survives a first-responder cycle:

```
-- B: disableUndoRegistration, then a first-responder cycle
   typed while disabled: canUndo=false
   manager identity before=…d10 after the cycle=…d10 same=true
   isUndoRegistrationEnabled after the cycle = false
   typed after the cycle: string="hello worldDE" canUndo=false
-- D: does a fresh UITextView start with registration enabled?
   fresh.undoManager=present class=_UITextUndoManager enabled=true
   typed: canUndo=true
-- E: does disableUndoRegistration also cover UIKit's OWN formatting command?
   font at 0 = .SFUI-Semibold/15.0[bold] canUndo=false
   POSITIVE CONTROL: the same act with registration ENABLED
   font at 0 = .SFUI-Semibold/15.0[bold] canUndo=true
```

`removeAllActions()` after every edit is the brute-force alternative and
also holds (`string="hello worldabc" canUndo=false`), but it is a rule
someone has to remember at every mutation site; the disable is a state.

So R6's `own_undo()` is `allowsUndo = false` on macOS and
`undoManager.disableUndoRegistration()` on iOS — two spellings, one
semantics, and on iOS the switch must be re-asserted for any text view
created later (a fresh one starts enabled).

---

## 2. EDIT REPORTING — R4

### 2.1 The formula, and it holds

`NSTextStorageDelegate` fires AFTER the storage is mutated, so the delegate
sees the NEW string with `editedRange` in NEW coordinates plus
`changeInLength`. With the pre-edit mirror in hand — which the core already
keeps (`field_text`, crates/kaya/src/scene.rs) — the delta is one
subtraction:

```
replaced range, in PRE-edit coordinates = { editedRange.location,
                                            editedRange.length - changeInLength }
inserted text                           = post[editedRange]
```

The probe folds that over the pre-edit string for every action and compares
the result with the post-edit string. **Every single action on both
platforms folded to MATCHES** — typing, backspace, replacing a selection,
plain paste, RTF paste, `replaceCharacters`, a whole-string push, and all
three stages of an IME composition. The formula is correct.

One refinement it forces: **a single user act can produce SEVERAL delegate
events**, so the fold is per event against the string as of THAT event, not
per act. macOS's IME emits two (`editedCharacters` then `editedAttributes`);
iOS's typing emits two (`editedCharacters|editedAttributes` at the insertion,
then a bare `editedAttributes` over the whole text).

### 2.2 The range is CORRECT but NOT MINIMAL, and macOS is the bad case

This is the finding that matters most for R4, and it was invisible until
the minimal diff was computed beside the reported one.

macOS, typing one character into "hello world" at offset 5
(`out-edits.txt`):

```
--- action typed character (insertText, the path a key event ends in)
  pre="hello world" post="helloX world"
  shouldChangeTextIn {5,0} replacement="X"
  did mask=editedAttributes|editedCharacters editedRange={5,7} changeInLength=1
    -> replaced pre-range {5,6} with "X world"
  fold MATCHES the post-edit string
  minimal diff: replace {5,0} with "X"
  reported vs minimal: reported {5,6} IS WIDER THAN minimal {5,0}
```

The character edit is one byte; the reported edit is "replace ` world` with
`X world`". AppKit unions the character range with the range its attribute
fixing touched, and both bits arrive in ONE event, so the two cannot be
separated. Replacing a selection is worse — `reported {0,12} IS WIDER THAN
minimal {0,5}` on a 12-character string, i.e. the whole document.

**A CRDT fed the reported range would delete and re-insert text the user
never touched**, and every concurrent edit inside that span would lose.
This is the direct, measured argument for R4's ruling: the core's own
mirror diff is the delta, and the platform channel corroborates.

iOS does NOT have the problem — it splits the two masks into separate
events and the character event is minimal:

```
--- action typed character (insertText, UIKeyInput's own path)
  did mask=editedAttributes|editedCharacters editedRange={5,1} changeInLength=1
    -> replaced pre-range {5,0} with "X"
  did mask=editedAttributes editedRange={0,12} changeInLength=0
  reported vs minimal: reported {5,0} EQUALS minimal {5,0}
```

So R4's diagnostic ("a disagreement with the diff names both") **will print
on macOS on almost every keystroke** if it compares extents. It has to
compare the RESULT (does the reported delta reproduce the mirror?) and
report the extent difference at most as information, or it is noise.

The full table, macOS left, iOS right, reported-vs-minimal in the last
column (`out-edits.txt`, `out-ios-edits.txt`, `out-ios-paste.txt`):

| act | macOS mask / editedRange / Δ | vs minimal | iOS mask / editedRange / Δ | vs minimal |
| --- | --- | --- | --- | --- |
| type one char mid-text | `attrs\|chars` {5,7} +1 | WIDER | `attrs\|chars` {5,1} +1, then `attrs` {0,12} 0 | EQUALS |
| type at the end | `attrs\|chars` {6,7} +1 | WIDER | `attrs\|chars` {12,1} +1 | EQUALS |
| backspace | `chars` {6,0} −1 | EQUALS | `attrs\|chars` {12,0} −1 | EQUALS |
| type over a selection | `attrs\|chars` {0,9} −3 | WIDER | `attrs\|chars` {0,2} −3 | EQUALS |
| paste plain text | `attrs\|chars` {5,6} +6 | EQUALS | `attrs\|chars` {5,13} +7 | WIDER (see below) |
| paste RTF, pinned | `attrs\|chars` {5,50} +50 | EQUALS | `attrs\|chars` {5,69} +63 | WIDER |
| paste RTF, unpinned | `attrs\|chars` {5,56} +50 | WIDER | `attrs\|chars` {5,69} +63 | WIDER |
| `replaceCharacters` | `chars` {0,5} 0 | EQUALS | `chars` {0,5} 0 | EQUALS |
| whole-string push | `chars` {0,13} +2 | WIDER | `attrs\|chars` {0,13} +2 | WIDER |
| attribute-only, plain | `attrs` {0,5} 0 | — | `attrs` {0,5} 0 | — |
| attribute-only, begin/endEditing | `attrs` {0,11} 0 (the UNION) | — | `attrs` {0,11} 0 (the UNION) | — |
| toolbar Bold | `attrs` {0,5} 0 | — | `attrs` {0,5} 0 | — |

Two rows deserve a sentence. `beginEditing`/`endEditing` **coalesces every
attribute change in the block into ONE event over their union** — the probe
set bold on {0,5} and underline on {6,5} and got one `editedAttributes`
{0,11}: an attribute-only delta cannot be recovered from the mask, only the
affected span. And iOS's plain paste is WIDER because **UIKit smart-inserted
a space**: `"hello world"` with the caret at 5 and `PASTED` on the
pasteboard became `"hello PASTED world"`, not `"helloPASTED world"`. The
bytes that land are not the bytes on the pasteboard, which is another
reason the delta must come from the mirror.

### 2.3 Attribute-only edits are distinguishable, on both

macOS reports them as `editedAttributes` alone, and the pre-commit delegate
hook reports them with a **nil** replacement string:

```
--- action attribute-only through shouldChangeText(nil)/didChangeText (the toolbar path)
  shouldChangeTextIn {0,5} replacement=nil
  did mask=editedAttributes editedRange={0,5} changeInLength=0
  textDidChange fired 1x, textViewDidChangeSelection 0x
```

iOS has no nil case in its delegate (`replacementText` is a non-optional
`String`, confirmed in the SDK header) but the storage mask is the same, so
`text_formatted` has a channel on both.

### 2.4 `textDidChange` is the wrong channel for a rich widget

kaya's Coordinator listens to `textDidChange` today. Measured, it fires:

- 1x for every user act (typing, backspace, paste, and the toolbar Bold),
- **0x for every programmatic write** (`replaceCharacters`, `view.string =`),
  which is why the echo doctrine works today, and
- **0x during an IME composition on macOS, 1x per composition step on iOS.**

That last line is kaya's own in-repo measurement (`swift/KayaSwiftUI.swift`
lines 6318-6322: "A MEASURED DIVERGENCE FROM macOS — UITextView DOES notify
its delegate for marked text") confirmed from the other side, and it is
*more precise* than the note: on macOS the **storage delegate DOES fire for
marked text and `shouldChangeTextIn` IS called** — it is only
`textDidChange` that stays silent.

```
macOS --- action setMarkedText (composition begins)
  shouldChangeTextIn {3,0} replacement="にほん"
  did mask=editedAttributes|editedCharacters editedRange={3,3} changeInLength=3
  did mask=editedAttributes editedRange={3,3} changeInLength=0
  textDidChange fired 0x, textViewDidChangeSelection 3x
  hasMarkedText=true markedRange={3,3}
```

So a rich widget that publishes `text_edited` from the storage delegate
would publish composition churn on BOTH platforms, and the marked range is
the only thing that tells it apart: `hasMarkedText()` / `markedTextRange`
is live and correct throughout, and false the instant the commit lands
(`hasMarkedText after commit=false`). That is where R4's `source =
ime_commit` and R5's queue rule get their signal.

The commit itself is clean and multi-byte-safe on both: `にほんご` →
`日本語` reported `{3,3} changeInLength=-1`, derived pre-range `{3,4}`,
EQUALS minimal, `NSString length=6 utf8=12`.

### 2.5 The IME, honestly

**The input source was not switched.** `NSTextInputContext.selectedKeyboardInputSource`
drives Text Input Services, which is host-wide while an app is active, and
the charge forbids moving the host's own state; the probe's own context
listed only `["com.apple.keylayout.US"]`, so no Japanese input source is
installed on this host anyway. Instead the probe calls
`setMarkedText(_:selectedRange:replacementRange:)` directly — that is the
`NSTextInputClient` / `UITextInput` method a Japanese IME itself calls, so
the storage-delegate answer above is the real one. What is NOT established
this way: whether a real input source produces additional intermediate
events (candidate-window churn, reconversion), and whether a real IME's
`replacementRange` ever differs from the marked range.

---

## 3. ACCESSIBILITY ATTRIBUTES — R9

### 3.1 macOS, read from a SEPARATE process

`axread <pid>` against a held probe window, with `AXIsProcessTrusted = true`
(the lane shell's grant). The text view carries bold, italic, underline,
strikethrough, monospace, a `.link` and a 24pt bold heading-sized run.
`kAXAttributedStringForRangeParameterizedAttribute` came back rc=0, 57
characters, and the keys per run are (`out-ax.txt`):

```
  run [0,11) "Heading one" -> AXATextAlignmentValue=0 AXFont={AXFontFamily=".AppleSystemUIFont" AXFontName=".AppleSystemUIFontBold" AXFontSize=24 AXVisibleName="System Font Bold"}
  run [18,22) "bold"       -> AXFont={… AXFontName=".SFNS-Bold" AXFontSize=13 AXVisibleName="System Font Emphasized"}
  run [23,29) "italic"     -> AXFont={… AXFontName=".SFNS-RegularItalic" AXVisibleName="System Font Italic"}
  run [30,35) "under"      -> AXFont={…} AXUnderline=1
  run [36,42) "strike"     -> AXFont={…} AXStrikethrough=1
  run [43,47) "mono"       -> AXFont={AXFontFamily=".AppleSystemUIFontMonospaced" AXFontName=".AppleSystemUIFontMonospaced-Regular" AXVisibleName=".SF NS Mono Light Regular"}
  run [48,52) "link"       -> AXFont={…} AXLink=AXUIElement(role=AXLink url=Optional(https://kaya.dev/probe))
  run [53,56) "end"        -> AXFont={…} AXForegroundColor=sRGB(1.00,0.32,0.30)
```

and beside the attributed string:

```
AXLinks attribute absent
text area children = ["AXLink"]
  AXLink child url=Optional(https://kaya.dev/probe)
```

Four readings:

1. **A link IS an element.** `AXLink` is not a flag — it is an
   `AXUIElement` of role `AXLink` carrying `AXURL`, published both as a run
   attribute AND as a CHILD of the text area. An assistive client can
   activate it. This is the one rich-text trait macOS exposes as first-class
   structure.
2. **Underline and strikethrough are booleans** (`AXUnderline=1`,
   `AXStrikethrough=1`), and colour is `AXForegroundColor`. Those three are
   assertable words.
3. **Bold, italic and monospace have NO trait bit.** All three are only
   `AXFont`, and the only human-readable discriminator is `AXVisibleName` —
   which is *unstable for the same trait*: the 24pt heading resolved to
   `"System Font Bold"` and the 13pt bold run to `"System Font Emphasized"`,
   because one came from `NSFont.boldSystemFont` and the other from
   `NSFontManager.convert(toHaveTrait:)`. A byte-compared kaya assertion on
   that string would be a trap.
4. **There is no heading anywhere.** The 24pt bold run publishes a bigger
   `AXFontSize` and nothing else. macOS's text area has no
   heading-level attribute for text runs, so `heading` cannot join the
   closed AX word set from this platform.

The text area's parameterized attributes (worth recording, because
`AXRTFForRange` is a whole interchange channel kaya gets for free):
`AXAttributedStringForRange, AXBoundsForRange, AXLineForIndex, AXRTFForRange,
AXRangeForIndex, AXRangeForLine, AXRangeForPosition, AXReplaceRangeWithText,
AXSharedTextElementForIndex, AXStringForRange, AXStyleRangeForIndex`.

### 3.2 iOS, in process, with the automation runtime up

UIKit's accessibility implementation is NOT loaded in a process with no
assistive technology attached. The first run measured
`accessibilityValue = ""`, `accessibilityAttributedValue is NIL`,
`isAccessibilityElement = false`, `traits = 0` — all unloaded defaults, and
a reading of nothing. kaya's own iOS harness already knows this and flips
the automation switch (`swift/KayaSwiftUI.swift`, `kayaAxEnableAutomation`:
`_AXSSetAutomationEnabled(true)` out of `/usr/lib/libAccessibility.dylib` —
**not VoiceOver**, which was never enabled and reads
`UIAccessibility.isVoiceOverRunning = false` throughout). The probe does the
same and waits 3s for the tree to materialize, and then the answer is real
(`out-ios-ax.txt`):

```
accessibilityTraits = 140737490714624
accessibilityValue = "Heading one\nplain bold italic under strike mono link end\n"
accessibilityAttributedValue length = 57
  run [0,11) "Heading one" -> NSFont=.SFUI-Semibold/26.0[bold]
  run [18,22) "bold"       -> NSFont=.SFUI-Semibold/15.0[bold]
  run [23,29) "italic"     -> NSFont=.SFUI-RegularItalic/15.0[italic]
  run [30,35) "under"      -> NSFont=… NSUnderline=1
  run [36,42) "strike"     -> NSFont=… NSStrikethrough=1
  run [43,47) "mono"       -> NSFont=.AppleSystemUIFontMonospaced-Regular/15.0[monoSpace]
  run [48,52) "link"       -> NSFont=… UIAccessibilityTokenLink=1
  run [53,56) "end"        -> NSColor=__NSCFType NSFont=…
```

**iOS translates `.link` into `UIAccessibilityTokenLink = 1` and DROPS the
URL.** There is no AXLink element and no child: `accessibilityElementCount`
is `NSNotFound` (the text view is itself the element). So the two Apple
platforms expose the same document's links two different ways — an element
with a URL on macOS, a boolean token on iOS.

Underline and strikethrough pass through as the ORIGINAL `NSUnderline` /
`NSStrikethrough` keys (not renamed), bold/italic/mono are again font-only
with no trait, and colour survives as `NSColor`.

**The heading has an answer on iOS, and only if the app writes it.**
Declaring the documented keys by hand on the same string, both survive into
`accessibilityAttributedValue`:

```
  run [0,11) "Heading one" keys=["NSFont", "UIAccessibilityTextAttributeHeadingLevel"] -> … UIAccessibilityTextAttributeHeadingLevel=1
  run [43,47) "mono" keys=["NSFont", "UIAccessibilitySpeechAttributeTextualContext"] -> … UIAccessibilitySpeechAttributeTextualContext="AXSSVoiceOverTextualContextSourceCode"
```

`UIAccessibilityTextAttributeContext` is TRANSLATED on the way out into
`UIAccessibilitySpeechAttributeTextualContext` with the value
`AXSSVoiceOverTextualContextSourceCode` — so kaya's `code_block` and `code`
runs have a real, spoken AX identity on iOS, and headings have one too, but
only because the backend declares it. Nothing derives either from the font.

### 3.3 What this means for the closed word set

| kaya v1 run | macOS, cross-process | iOS, in process |
| --- | --- | --- |
| `bold` | `AXFont.AXFontName` / `AXVisibleName` only, and the name is unstable | `NSFont` traits only |
| `italic` | `AXFont` only | `NSFont` only |
| `underline` | **`AXUnderline=1`** | **`NSUnderline=1`** |
| `strike` | **`AXStrikethrough=1`** | **`NSStrikethrough=1`** |
| `code` | `AXFont` family `.AppleSystemUIFontMonospaced` only | `NSFont` only, **unless** the arm writes `UIAccessibilityTextAttributeContext` → then a real spoken context |
| `link(url)` | **`AXLink` element with `AXURL`, and an `AXLink` CHILD** | **`UIAccessibilityTokenLink=1`, URL dropped, no element** |
| `heading` 1-3 | **nothing** — font size only | **`UIAccessibilityTextAttributeHeadingLevel`, if the arm writes it** |
| `quote`, `code_block`, `body` | nothing | nothing (except the code context above) |

R9 says the words join the set "only after each platform's screen reader is
measured saying them". On Apple, `underline` and `strike` are ready;
`link` and `heading` are askable only if kaya's own backends WRITE the
platform's accessibility keys (and even then `link` reads two different
shapes on the two platforms, so one byte-compared verdict cannot serve
both); `bold`, `italic` and `code` have no word to assert at all today and
would need kaya to publish `accessibilityFont`-family keys or the iOS
context key itself.

---

## 4. TYPING ATTRIBUTES — does a run extend?

Same fixture on both: "hello world" with bold on `[0,5)` and
`.link` + `.underlineStyle` on `[6,11)`.

**macOS** (`out-typing.txt`) — the caret's typing attributes, and then what
actually landed:

```
caret at 3 (inside the bold run):     NSFont=.SFNS-Bold/13.0[bold]
caret at 5 (at the END of the bold run): NSFont=.SFNS-Bold/13.0[bold]
caret at 8 (inside the link run):     NSFont=… NSLink=URL(https://kaya.dev/probe) NSUnderline=1
caret at 11 (at the END of the link run): NSFont=… NSUnderline=1
caret at 6 (at the START of the link run): NSFont=… (no link)
-- typing at the end of the bold run
   inserted at 5; font there = .SFNS-Bold/13.0[bold]
-- typing at the end of the link run
   inserted at 12; link there = nil underlineStyle = 1
-- typing INSIDE the link run
   inserted at 8; link there = https://kaya.dev/probe
```

**macOS already implements kaya's mirror rule**: inline styles inherit at
the end of a run, the link does NOT, and typing inside a link still gets the
link. But note the third line of that block — **the UNDERLINE inherited
while the link did not**. If the arm draws a link as `link` + `underline`,
the character typed after a link is a bare underlined run with no URL.

**iOS** (`out-ios-typing.txt`) — the same fixture, one line different and it
is the important one:

```
caret at 11 (at the END of the link run): NSFont=… NSLink=URL(https://kaya.dev/probe) NSUnderline=1
-- typing at the end of the link run (index 12)
   link at 12 = https://kaya.dev/probe underline = 1
runs of after:
  [7,13) "worldL" -> NSFont=… NSLink=URL(https://kaya.dev/probe) NSUnderline=1
```

**UITextView extends the link; NSTextView does not.** Two platforms, one
file in kaya, opposite defaults. The iOS arm must strip `.link` from
`typingAttributes` whenever the caret sits at the end of a link run, or the
uniform-semantics invariant is broken on the platform that ships with it
broken.

One fixture artefact worth recording because it is a live trap for kaya's
own push path: `view.string = X` on macOS applies the view's CURRENT
`typingAttributes` to the whole new string. A rich kaya that kept
`view.string = text` in `updateNSView` would not merely wipe the runs — it
would stamp whatever the caret last inherited over every character.

---

## 5. RTF PASTE WITH THE RICH OPINIONS UNPINNED

The sample carries every attribute kaya's v1 vocabulary does NOT have plus
the ones it does: background colour, foreground colour, a 22pt Times New
Roman family run, bold, italic, underline, strikethrough, a link, and two
extra paragraphs — one with `alignment=.center`, `headIndent=36`,
`firstLineHeadIndent=18` and `NSTextList(markerFormat: .disc)`, one with
`alignment=.right`, `headIndent=48`. 1,415 bytes of RTF, pasted through
`readSelection(from:)` (the method `paste:` itself calls) off a PRIVATE
pasteboard.

**Pinned, as kaya ships today** (`isRichText=false`): one run, everything
gone.

```
runs of isRichText=false importsGraphics=false (kaya today): length=83
  [0,83) "plain red Times bold …" -> NSColor=sRGB(0,0,0,1) NSFont=.AppleSystemUIFont/13.0
```

**Unpinned** (`isRichText=true`, `importsGraphics=false`), what lands:

| attribute | landed? | kaya v1 vocabulary |
| --- | --- | --- |
| `NSFont` bold / italic | yes (`HelveticaNeue-Bold`, `HelveticaNeue-Italic`) | **in** (`bold`, `italic`) |
| `NSUnderline=1` | yes | **in** (`underline`) |
| `NSStrikethrough=1` | yes, **plus `NSStrikethroughColor`** | `strike` is in, the colour is **not** |
| `NSLink` | yes, URL intact | **in** (`link`) |
| `NSColor` (foreground) | yes, `sRGB(1.00,0.22,0.24)` | **OUT** — R3 defers colour |
| `NSBackgroundColor` | yes, `sRGB(1.00,0.80,0.00)` | **OUT**, and it COLLIDES with `highlight_ranges`, which is `.backgroundColor` |
| font FAMILY and SIZE | yes — `TimesNewRomanPSMT/22.0`, and **every other run became `HelveticaNeue/13.0`**, not the view's font | **OUT** |
| `NSParagraphStyle` alignment | yes (`align=1` centre, `align=2` right) | **OUT** — R3 defers alignment |
| `NSParagraphStyle` indents | yes (`headIndent=36`, `firstLineHeadIndent=18`) | **OUT**, and `quote` is drawn AS an indent |
| `NSTextList` | yes — `textLists=["{disc}"]` survived the RTF round trip | **OUT** — R3 defers lists |
| attachment / `U+FFFC` | **no**, see below | must stay out: it would put a character in the text |

So the arm's strip list on paste is: **every font attribute except the
bold/italic/monospace traits** (the family and size must be re-derived from
kaya's own ramp, because the paste replaces them wholesale even on runs the
source had left plain), **both colours**, `NSStrikethroughColor`, and the
whole `NSParagraphStyle` except whatever kaya re-derives from its own
`block` attribute.

**`importsGraphics = false` is the pin that must survive unpinning**, and it
is proven rather than assumed. The same RTFD pasted twice:

```
-- isRichText=true importsGraphics=false
   string = "before  after" (U+FFFC present = false)
   NSString length = 13, utf8 = 13
-- isRichText=true importsGraphics=true
   string = "before \u{FFFC} after" (U+FFFC present = true)
   NSString length = 14, utf8 = 16
   [7,8) "\u{FFFC}" -> NSAttachment=NSTextAttachment …
```

An attachment adds a real character to the string — three UTF-8 bytes that
every offset in the document then has to step over, and that no guest can
see the meaning of. `importsGraphics = false` keeps it out with the rich
side on. (`readablePasteboardTypes` goes from 8 to **195** when graphics are
allowed, which is the size of the door that pin closes.)

**iOS's equivalent pin is `allowsEditingTextAttributes`** (default `false`,
confirmed). False: the RTF arrives as one plain run. True: colour,
background, `TimesNewRomanPSMT/24.0`, bold, italic, underline, strikethrough
+ colour, `NSLink` and the paragraph style with `textLists=["{disc}"]` all
land, exactly as on macOS — with one extra hazard macOS did not show:

```
  [52,68) "bullet paragraph" -> … NSParagraphStyle(align=1 headIndent=36.0 textLists=["{disc}"])
  [68,74) " world"           -> … NSParagraphStyle(align=1 headIndent=36.0 textLists=["{disc}"])
```

The trailing `" world"` — text that was in the document before the paste and
that the edit did not touch — took the pasted paragraph's style, because
paragraph attributes belong to the whole paragraph and the paste's last
paragraph merged with it. **A paste can change the formatting of text
outside its own edited range**, so `text_edited`'s `runs` (which cover
`inserted` only, per §2 of the plan) cannot describe a paste's full effect
on a rich document.

---

## 6. The reading

**1. Undo scope and suppression (R6).** On macOS the native tier behaves
exactly as R6 hoped and better: a toolbar Bold applied through
`shouldChangeText(in:replacementString: nil)` / `didChangeText()` registers
undo and undo reverts the attribute (redo restores it), while the SAME
attribute change made straight on the storage registers nothing — so
`apply_edit` gets its "never enters the native stack" behaviour for free by
simply not using the bracket, and no new switch is needed for it.
`allowsUndo = false` is a complete off switch: the view's `undoManager`
becomes nil, neither text nor attributes move for any Cmd-Z channel, the
window's manager above it records nothing, it flips both ways at runtime
without touching a byte of the text or the caret, and two views in one
window hold opposite settings — all of which was believed only after a
positive control was watched succeeding, because the first run's negative
was a dead channel, not a working switch. iOS is the same semantics with a
different spelling and one decoy in the way: there is no `allowsUndo`,
attribute changes through `textStorage` are not undoable at all (only
UIKit's own `toggleBoldface` is, and it names itself "Bold"), overriding
`UIResponder.undoManager` to nil merely HIDES the manager while UITextView
keeps registering through its private reference — proven by lifting the
override and undoing the edit — and the real lever is
`undoManager.disableUndoRegistration()`, which is per view, covers typing
and UIKit's formatting commands alike, and survives a first-responder cycle,
but must be re-asserted on any text view created later because a fresh one
starts enabled.

**2. Edit reporting (R4).** The one subtraction is right and the fold proves
it: replaced range in pre-edit coordinates is `{editedRange.location,
editedRange.length − changeInLength}` and the inserted text is the post-edit
substring at `editedRange`, applied per delegate EVENT rather than per user
act (one act can emit two), and it reproduced the post-edit string for every
action on both platforms including all three stages of an IME composition
and multi-byte commits. What the survey could not have known is that the
range is correct but **not minimal**, and macOS is the bad case: AppKit
unions the character edit with its attribute fixing into one event, so a
single typed character reports "replace ` world` with `X world`" and typing
over a selection reports the whole document — a delta a CRDT would apply as
a delete-and-reinsert of untouched text. iOS splits the masks and is minimal
for typing but not for pastes or pushes, and UIKit's smart insert can add a
space the pasteboard never held. Attribute-only edits are distinguishable on
both (`editedAttributes` alone; on macOS also a nil `replacementString` in
the pre-commit hook) but `beginEditing`/`endEditing` coalesces every change
in the block into one event over their UNION, so an attribute delta is never
recoverable from the channel — only its span. And the channel kaya listens
to today, `textDidChange`, is silent for every programmatic write (which is
what makes the echo doctrine work), silent throughout a macOS composition
and loud throughout an iOS one; the storage delegate, by contrast, fires for
marked text on BOTH, which sharpens kaya's own in-repo note — the macOS
divergence is `textDidChange`'s, not the delegate's. All of which says R4
stands as ruled: derive from the mirror, corroborate with the platform, and
write the diagnostic to compare the RESULT rather than the extent, or it
will fire on almost every macOS keystroke.

**3. Accessibility (R9).** Read from a separate process on macOS and with
the automation runtime up on iOS, the two platforms agree on exactly two
words and disagree on everything else. `underline` and `strike` come back as
booleans on both (`AXUnderline=1` / `AXStrikethrough=1` on macOS,
`NSUnderline` / `NSStrikethrough` passed through on iOS) and can join the
closed set today. `bold`, `italic` and `code` have no trait bit anywhere —
they are font identity only, and macOS's one human-readable discriminator,
`AXVisibleName`, gave "System Font Bold" and "System Font Emphasized" for
two runs that are both bold, so it cannot be byte-compared. A link is
first-class on macOS — an `AXLink` element carrying `AXURL`, published both
as a run attribute and as a CHILD of the text area — and a bare
`UIAccessibilityTokenLink = 1` with the URL discarded on iOS, so one shared
verdict cannot describe both. A heading has NO representation on macOS at
all (a 24pt bold run publishes a bigger `AXFontSize` and nothing else) and
has one on iOS only if the backend writes
`UIAccessibilityTextAttributeHeadingLevel` itself, which does survive into
`accessibilityAttributedValue`; the same is true of `code`, where
`UIAccessibilityTextAttributeContext` is translated on the way out into
`UIAccessibilitySpeechAttributeTextualContext =
AXSSVoiceOverTextualContextSourceCode`. So R9's "only after each platform's
screen reader is measured saying them" already has its Apple answer for two
of the seven words, and the other five need kaya's own backends to publish
accessibility keys before there is anything to measure.

**4. Typing attributes.** macOS implements kaya's mirror rule by itself:
`typingAttributes` at the end of a bold run carries the bold and the typed
character gets it, `typingAttributes` at the end of a link run has dropped
the `.link` and the typed character does not get it, and typing inside a
link still inherits it. iOS does NOT: `typingAttributes` at the end of a
link run still carries `NSLink`, and the character typed there joined the
link run. That is a real divergence in the one file that serves both arms,
and the iOS side has to strip `.link` from the typing attributes at a run's
trailing edge or ship the uniform-semantics invariant broken. One more line
for the arm on both: the underline that decorates a link DOES extend even
where the link does not, so a link drawn as link-plus-underline leaves a
bare underlined character behind it; and on macOS `view.string = X` stamps
the view's current typing attributes across the whole new string, which
makes today's push path unusable as-is for a rich widget.

**5. RTF paste unpinned.** With `isRichText = true` (and
`allowsEditingTextAttributes = true`, its iOS twin) a pasted RTF brings in,
intact: bold and italic through the font, underline, strikethrough AND
`NSStrikethroughColor`, the link with its URL, foreground colour, background
colour, the font FAMILY and SIZE — which replace the view's own font on
EVERY pasted run, not just the styled ones — and a full `NSParagraphStyle`
carrying alignment, `headIndent`, `firstLineHeadIndent` and a surviving
`NSTextList(.disc)`. So the arm's strip list on paste is: font family and
size (re-derive from kaya's ramp, keep only the bold/italic/monospace
traits), both colours, the strikethrough colour, and the entire paragraph
style except what kaya re-derives from its own `block` attribute — and the
background colour matters twice over, because it is the same attribute
`highlight_ranges` already paints with. `importsGraphics = false` survives
the unpinning and is the pin that must never come off: with it on, an RTFD
attachment lands a real `U+FFFC` in the string (13 characters becomes 14,
13 UTF-8 bytes becomes 16) and the readable pasteboard types go from 8 to
195. The paragraph-style finding has a sting the byte counts hide: on iOS
the text AFTER the pasted run inherited the pasted paragraph's list style,
because the paste's last paragraph merged with the existing one — a paste
changes formatting outside its own edited range, which `text_edited`'s
`runs` (covering `inserted` only) cannot express.

## 7. The two most important caveats

**A. Every "the platform does X" here was driven through the API an
input method or a menu item would call, not through the input method or the
menu item.** Typing is `insertText(_:replacementRange:)`, a paste is
`readSelection(from:)` / `UIResponder.paste(_:)`, a composition is
`setMarkedText(...)`, and the Japanese input source was deliberately NOT
selected (`NSTextInputContext.selectedKeyboardInputSource` drives host-wide
Text Input Services, and no Japanese source is installed on this host
anyway — the probe's context listed only `com.apple.keylayout.US`). Those
are the entry points AppKit and UIKit document for exactly these callers, so
the storage-delegate numbers are the real ones, but what is NOT established
is whether a real IME emits additional intermediate events (candidate
churn, reconversion, a `replacementRange` that differs from the marked
range) and whether a hardware Cmd-Z on iOS consults the view's private
undo manager or the responder-chain property that the nil override hides.
The second of those is the one to close before R6's iOS arm ships, because
it is the difference between "suppressed" and "suppressed until someone
plugs in a keyboard".

**B. The accessibility readings are what an AX CLIENT can fetch, not what
VoiceOver SAYS.** VoiceOver was never enabled (forbidden by the charge, and
`UIAccessibility.isVoiceOverRunning` reads false in every iOS run); the
macOS side is a real cross-process `AXUIElement` read and the iOS side is an
in-process read with kaya's own `_AXSSetAutomationEnabled(true)` switch
flipped — the same route the shipped iOS harness uses, and one that took a
3-second wait before the tree existed, which is itself a caveat for any gate
built on it. The gap between "the attribute is published" and "the screen
reader announces it" is exactly where R9's ruling lives: `AXUnderline=1` is
fetchable, but whether VoiceOver speaks the word "underline" for it, and
what Narrator, Orca and TalkBack do with their platforms' equivalents, is
still unmeasured, and kaya's word set is closed across all five.

---

## 8. Reproducing, and the cleanup proof

```
source tools/lib/swift-toolchain.sh
kaya_swiftc -o macprobe macprobe.swift && kaya_swiftc -o axread axread.swift
./macprobe edits | ./macprobe undo | ./macprobe undokey | ./macprobe typing | ./macprobe rtf
./macprobe axhold &   # prints "axhold pid=<n> READY", then ./axread <n>

iosprobe/build.sh                                  # prints the .app
DEVELOPER_DIR=/Applications/Xcode-26.6.0.app/Contents/Developer SDKROOT= \
  xcrun simctl install <kaya-sim-2> iosprobe/build/RichTextProbe.app
SIMCTL_CHILD_KAYA_RTPROBE_MODE=edits|undo|undo2|typing|ax|paste \
  xcrun simctl launch --console-pty <kaya-sim-2> dev.kaya.richtextprobe
```

Left running: nothing.

```
$ pgrep -fl "macprobe|axread|RichTextProbe"      # rc=1, no output
$ xcrun simctl uninstall 3CD1C302-… dev.kaya.richtextprobe
uninstalled
$ xcrun simctl get_app_container 3CD1C302-… dev.kaya.richtextprobe
An error was encountered processing the command (domain=NSPOSIXErrorDomain, code=2)
```

The same `get_app_container` check was run against all four pooled
simulators (kaya-sim-0/1/2/pad) and failed on every one, so the bundle is
installed nowhere. The probe directory is 960K. The host clipboard was never
written (`pbpaste | shasum` is `da39a3ee5e6b`, the empty hash, before and
after); the macOS probe used a private `NSPasteboard(name:)` throughout, and
the simulator's pasteboard was proven not to sync to the host before it was
used (a sentinel written to kaya-sim-2's pasteboard left the host hash
unmoved) and was cleared by the probe at the end.
