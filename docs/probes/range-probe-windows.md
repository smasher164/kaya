# TEXT-RANGES probe — windows arm (WinUI 3 / Windows App SDK 2.x)

Repo HEAD 6a616d6, tree clean throughout (`git status --porcelain` empty
after every step). VM: akhil@192.168.64.2, Windows 11 10.0.26200.8875,
arm64, console session active. Nothing shipped, nothing committed.

SDK under measurement is the one kaya actually builds against:
`Microsoft.WindowsAppSDK.WinUI 2.2.1` + `Foundation 2.1.0` +
`InteractiveExperiences 2.0.15` (tools/fetch-winappsdk.sh:48-53). That is
App SDK **2.x**, the current generation, so "modern App SDK additions"
are inside every answer below rather than outside it.

Two independent instruments, because an API existing is not the platform
doing the thing:

1. **Metadata** — a winmd reader over the exact `.winmd` files the
   bindgen reads (scratchpad `winmd.py`), giving complete member lists.
2. **A live WinUI 3 app on the VM** (C#, unpackaged, App SDK 2.2.0),
   driven in the console session, which measured timings, edit
   behaviour, automation readback, and left a screenshot whose pixels
   were counted.

---

## VERDICT

**Kaya's textarea is a `TextBox` (winui/mod.rs:80), and TextBox cannot
express HIGHLIGHT at all.** Not awkwardly — there is no API on it that
paints a range it did not select. Confirmed twice: the complete
120-method metadata surface has no `TextHighlighters` and no document
object, and runtime reflection in the live app returned
`TextBox.TextHighlighters: ABSENT`, `TextBox.TextDocument: ABSENT`,
`TextBox.Document: ABSENT`. The one range it can color is *the
selection*, via `SelectionHighlightColor` — the same range SELECT owns.

**RichEditBox can express all three**, through the RichEdit text object
model, and I measured it doing so — including a screenshot in which two
distinct background colors are alive at once, a blue 8-character run
(874 pure-blue pixels) sitting inside a red field.

So the windows arm is a **widget swap for textarea, not a feature add**,
and the swap is not free. The charges are real but all bounded and
individually cheap; the one that is not merely a chore is
**observability**, below.

Also worth stating plainly, because it changes the shape of the design:
**SELECT and REVEAL are available on TextBox today.** Only HIGHLIGHT
forces the swap. A design that lets a widget declare only the primitives
it can serve would leave `entry` on TextBox untouched.

---

## THE THREE-CAPABILITY TABLE

| | **HIGHLIGHT** (set of ranges) | **SELECT** (one range) | **REVEAL** (scroll into view) |
|---|---|---|---|
| **TextBox** (what textarea is today) | **CANNOT.** No `TextHighlighters`, no document object. `SelectionHighlightColor` is one brush for the one selection. | **CAN.** `Select(start,len)`, `SelectionStart/Length`. Measured 802 µs. | **CAN, hand-assembled.** No scroll-to-range API; `GetRectFromCharacterIndex` gives content-relative geometry, drive the template ScrollViewer. Measured 77 µs. `Select()` alone does **not** scroll (offset stayed 0, even focused). |
| **RichEditBox** | **CAN.** `TextDocument.GetRange(a,b).CharacterFormat.BackgroundColor`. Two disjoint ranges distinct and painted (proved by screenshot). ~44 µs/range batched, ~96 µs unbatched. | **CAN.** `TextDocument.Selection.SetRange(a,b)` (ITextSelection extends ITextRange). Measured 674 µs. | **CAN, first-class.** `ITextRange.ScrollIntoView(PointOptions)`. Measured 628 µs, offset 0 → 533. |
| **Observed by a harness leg?** | Only through an **out-of-process UIA client** (`GetAttributeValue(BackgroundColor)`, id 40001) — measured working, boundaries exact. **In-process automation peers cannot see it** (`GetPattern(Text)` returns NULL). Fallback: read the control's own TOM back. | Out-of-process UIA `GetSelection()` — measured. In-process: read `Selection.StartPosition/EndPosition` off the control. | Out-of-process UIA `GetVisibleRanges()` — measured, count=1 on both. In-process: `ScrollViewer.VerticalOffset` (already how kaya asserts scroll). |

---

## 1. What kaya's text widgets sit on today

`crates/kaya/src/winui/mod.rs`:

- :71  `Entry(TextBox)` — :80 `Textarea(TextBox)`
- :141 `entries: Vec<TextBox>` — :163 `textareas: Vec<TextBox>`
- :4288-4341 the `WidgetKind::Textarea` arm: `TextBox::new()` +
  `SetAcceptsReturn(true)`, MinWidth 240 / MinHeight 96, `TextChanged`
  with the swallow counter, GotFocus/LostFocus for paste enablement.
  The comment states the intent: "a TextBox with AcceptsReturn — the
  entry's exact contract".

Entry and textarea being the *same native type* is load-bearing in three
helpers:

- :3624 `focused_editable_id(core)` — one closure `|field: &TextBox|`
  walks entries then textareas.
- :3644 `editable_by_id(core, id) -> Option<TextBox>` — the single
  funnel the clipboard, undo and menu-role paths all go through.
- :3673 `clear_native_undo(field: &TextBox)`.

Text already gets CR-normalized on every escape toward the guest
(:1684-1698, `fn lf`), because "WinUI's TextBox stores every line break
as a bare CR (its Rich Edit heritage)".

---

## 2. HIGHLIGHT

### 2a. TextBox — settled, cannot

Complete `Microsoft.UI.Xaml.Controls.TextBox` member list from
`Microsoft.UI.Xaml.winmd` (120 methods). Everything highlight-adjacent:

    get/put_SelectionHighlightColor
    get/put_SelectionHighlightColorWhenNotFocused
    get/put_SelectionStart, get/put_SelectionLength, get/put_SelectedText
    Select(start,length), SelectAll
    GetRectFromCharacterIndex(index, trailingEdge) -> Rect

Live reflection agreed, and a search for any member matching
"Highlight" returned only the two SelectionHighlightColor properties and
their DependencyProperty accessors.

The mechanism exists in the same winmd but not for editable text:
`TextBlock.TextHighlighters` is present (`IList<TextHighlighter>`, with
`Ranges`/`Foreground`/`Background`). It is on the read-only text
controls only. Occurrence count on TextBox: **0**.

Proved by construction in the live app: `Select(10,12)` then
`Select(30,8)` leaves `start=30 len=8` — the first range is gone. One
range, always.

### 2b. RichEditBox — can, and does paint

    RichEditTextDocument.GetRange(start,end) -> ITextRange
    ITextRange.CharacterFormat -> ITextCharacterFormat   (getter returns a COPY)
    ITextCharacterFormat.BackgroundColor = Windows.UI.Color
    range.CharacterFormat = fmt                          (assign back — 4 COM hops/range)
    RichEditTextDocument.BatchDisplayUpdates() / ApplyDisplayUpdates()

Measured:

    one range (GetRange + get fmt + set color + set fmt)   2529 us (first call, warm-up)
    read back BackgroundColor = #FFFF0000 (wanted #FFFF0000)
    virgin (unpainted) background sentinel = #00000001
    two disjoint ranges: r1=#FFFF0000 r2=#FF0000FF -> DISTINCT
    100 ranges UNBATCHED  9.61 ms   (~96 us/range)
    100 ranges BATCHED    4.42 ms   (~44 us/range)   -> batching is 2.2x
    82,890-char document: clear-all + 200 ranges batched  39.05 / 42.97 ms
    same document, re-declared again                      62.40 / 70.02 ms

**Painting proved, not assumed.** Screenshot of the live window, pixels
counted: `pure-red=80513 pure-blue=874` on a 1824x768 capture. The
screenshot also shows the two controls side by side: the TextBox (left)
with exactly one red run — its selection — and the RichEditBox (right)
with a blue 8-character run sitting inside a red field.

Screenshot kept at `range-probe-windows.png` beside this report.

---

## 3. SELECT

- TextBox: `Select(10,12)` → `start=10 len=12 text='cdefghij klm'`, 802 µs.
- RichEditBox: `Selection.SetRange(10,22)` → `start=10 end=22
  text='cdefghij klm' type=Normal Length=12`, 674 µs.

Both fine. No surprises.

---

## 4. REVEAL

**RichEditBox** has it first-class: `ITextRange.ScrollIntoView(PointOptions)`,
628 µs, template ScrollViewer offset 0 → 533 (scrollable 533).
`PointOptions.Start` → 533, `PointOptions.None` → 369, so the placement
policy is selectable. `ITextRange.GetRect(ClientCoordinates)` also
returns the range's rectangle.

**TextBox** has no scroll-to-range API, but REVEAL is assemblable and I
measured the assembly:

    rect at scroll 0   = 0,820,0,16
    rect at scroll 300 = 0,820,0,16      -> CONTENT-relative (document coords)
    viewport h=467  extent h=1001  scrollable=534
    hand-assembled reveal (GetRectFromCharacterIndex + ScrollViewer.ChangeView)
                            77 us, offset -> 534
    focus + Select(1500,6) -> offset 0   (SELECT DOES NOT REVEAL)

Two things follow. The rect is in document coordinates, so it feeds
`ChangeView` directly. And **selection does not imply reveal on this
platform** — that must be an explicit primitive, which is exactly what
the milestone proposes. Kaya's stripped template already provides the
ScrollViewer this needs (`ENTRY_STYLE_XAML`, :570-585, `x:Name="ContentElement"`),
and a visual-tree walk finds it (`template ScrollViewer found: True`).

---

## 5. Do ranges survive edits? (the app re-declares — what does that cost)

The expected model is "the app re-declares after each change". On
RichEditBox that model has a **trap that must be designed around**:

    after paint:                       bg(5,12)=#FFFF0000
    after SetText(None, same text):    bg(5,12)=#FFFF0000
    after SetText(None, DIFFERENT text): bg(0,10)=#FFFF0000

**`SetText` does not reset character formatting.** New text takes the
ambient format, so a re-declaration that assumes a clean slate
accumulates. That is exactly what the screenshot shows: the entire
RichEditBox is red because an earlier paint left red ambient and the
whole re-set document inherited it — 80,513 red pixels where the app had
only ever asked for 8 characters of red.

Clearing is explicit and cheap: repaint the whole story with the
sentinel (`GetRange(0, TextConstants.MaxUnitCount)`, background
`#00000001`) — verified to restore the unpainted appearance. Budget it
as part of every re-declaration; the 39-70 ms figures above already
include it on an 82 KB document.

Formatting is anchored to the *text*, not to offsets, so it moves
correctly when text is inserted before it (measured: painted run at
20-30 read back at 25-35 after a 5-char insert at 0). Good for
correctness, bad for staleness — old ranges drift rather than vanish.

**Sticky formatting is the user-facing half of the same fact:**

    typed INSIDE a highlight:    text='zz' bg=#FFFF0000  (inherits)
    typed at the TRAILING EDGE:  text='yy' bg=#FFFF0000  (inherits)

A user typing at the edge of a highlight silently extends it, so the
rendering diverges from the app's declaration between the keystroke and
the app's next re-declare. No other backend's highlight mechanism does
this. It is the "RichEditBox's RTF-ish behaviors that bit other
frameworks" — measured, and it is real.

Flicker was not observable by eye at these sizes; `BatchDisplayUpdates`
/`ApplyDisplayUpdates` exists precisely for it and halves the cost, so
use it unconditionally.

---

## 6. The other RichEditBox behaviour differences (all measured, all tamable)

**Text round-trip — the one that breaks a kaya invariant.**
`GetText(TextGetOptions.None)` always appends one paragraph mark:

    set 'abc'(3)   -> get 'abc\r'(4)      TextBox: 'abc'(3)      SAME
    set 'a\nb'(3)  -> get 'a\rb\r'(4)     TextBox: 'a\rb'(3)
    set ''(0)      -> get '\r'(1)         TextBox: ''(0)         SAME

After kaya's `lf()` that becomes a trailing `\n` the guest never wrote,
which violates invariant 6 (scene strings compared byte-for-byte across
all languages). **Fix measured and exact:** `TextGetOptions.AdjustCrlf`
drops it, and every case then matches the source after `lf()`:

    set 'a\nb'   GetText(AdjustCrlf) = 'a\rb'   -> lf() 'a\nb'    MATCHES SOURCE
    set 'a\nb\n' GetText(AdjustCrlf) = 'a\rb\r' -> lf() 'a\nb\n'  MATCHES SOURCE
    set ''       GetText(AdjustCrlf) = ''                          MATCHES SOURCE
    set 'x'      GetText(AdjustCrlf) = 'x'                         MATCHES SOURCE

**Clipboard.** `ClipboardCopyFormat` defaults to `AllFormats` — a kaya
textarea would put RTF on the clipboard and accept formatting on paste,
diverging from every other backend and from the clipboard milestone that
just landed. Enum is `{AllFormats, PlainText}`; setting `PlainText`
verified.

**Formatting accelerators.** `DisabledFormattingAccelerators` defaults to
`None`, meaning **Ctrl+B/I/U actively bold/italic/underline the text** in
a kaya textarea. Enum is `{None, Bold, Italic, Underline, All}`; setting
`All` verified.

**Template.** Kaya's unpackaged guests cannot resource-resolve the
default chrome, which is why `ENTRY_STYLE_XAML` exists — and it is
`TargetType="TextBox"`, so it does not apply to a RichEditBox. A minimal
`TargetType="RichEditBox"` copy (same `ScrollViewer x:Name="ContentElement"`
shape) **parses, applies, and round-trips text** — measured. So this is a
near-copy, not a research problem. (My own probe hit the matching
failure from the other side: built without any XAML, it died with
`0xC000027B` STATUS_STOWED_EXCEPTION, the same fail-fast mod.rs:587-594
documents. The wall is real.)

`IsSpellCheckEnabled` defaults True on RichEditBox, same as TextBox.

---

## 7. IME / composition

Both controls expose the same composition surface:
`TextCompositionStarted`, `TextCompositionChanged`, `TextCompositionEnded`,
`SelectionChanging`, `TextChanging` — present on TextBox **and**
RichEditBox. Plus `DesiredCandidateWindowAlignment` and
`CandidateWindowBoundsChanged` on both.

The mechanism by which a highlight write could break a live composition
is moving the caret out from under it. Measured, and it does not:

    caret before paint = (100,100)  after painting elsewhere = (100,100)  UNMOVED
    caret after painting a range that CONTAINS it = (100,100)             UNMOVED
    TextBox caret 100 -> 100 after setting SelectionHighlightColor

So the format write is caret-neutral, which is the good answer.

**Residual risk, stated honestly:** I did not drive a real IME
composition (no IME installed on the VM, and synthesising one needs
TSF work beyond this probe). Two specific things a design should
re-check when an IME is available: (a) whether re-declaring ranges
*during* an active composition disturbs the composition string, since
the composition is itself rendered with character formatting by the
RichEdit engine; and (b) whether sticky formatting causes composition
text to inherit a highlight color mid-compose. Both are plausible and
neither is settled by what I measured.

---

## 8. OBSERVABILITY — the finding that shapes the design

Kaya's backend carries a written wall at :1929-1951: **"UIA IS THE THING
THAT MUST NOT HAPPEN"**. Attaching a UI Automation *client* makes the
Shell's file dialog fatal to the JVM (uiautomationcore raises an event
during an input-synchronous call, `RPC_E_CANTCALLOUT_ININPUTSYNCCALL`,
NONCONTINUABLE, HotSpot reports it fatal). A helper process was built,
measured and thrown away. Kaya's a11y read therefore goes through
**in-process automation peers** (`CreatePeerForElement`, :6636).

That route does not work here. Measured:

    TextBox     peer=TextBoxAutomationPeer     type=Edit class=TextBox
                GetPattern(Text) = NULL
    RichEditBox peer=RichEditBoxAutomationPeer type=Edit class=RichEditBox
                GetPattern(Text) = NULL
    every PatternInterface enumerated on both: no Text provider
    peer children: exactly one, a ScrollViewerAutomationPeer, Text-pattern=null

The provider interfaces exist in the winmd (`ITextProvider` with
`GetSelection`/`GetVisibleRanges`/`DocumentRange`, `ITextRangeProvider`
with `GetAttributeValue`), but the WinUI managed peer does not hand them
out. **In-process, kaya cannot see text ranges through automation at all.**

An **out-of-process** UIA client can, and sees everything the milestone
needs. Measured against the live window from a second process:

    UIA: window found class=WinUIDesktopWin32WindowClass, Edit elements = 2
    UIA: BackgroundColorAttribute id = 40001  (TextPatternIdentifiers.BackgroundColorAttribute)

    --- Edit class=TextBox ---
      TextPattern: PRESENT
      GetSelection count = 1, selection text = 'line 00 '
      selection BackgroundColor = 16777215   (0xFFFFFF, the style background —
                                              a selection is NOT a text attribute)
      GetVisibleRanges count = 1
      ValuePattern value len = 1800
      background scan over 60 chars: uniform, one value, no boundaries

    --- Edit class=RichEditBox ---
      TextPattern: PRESENT
      GetSelection count = 1
      GetVisibleRanges count = 1, first visible = 'line 00 abcdefghij klmnopqrst\rline 01 ab'
      background scan reports EXACTLY the painted boundaries:
          char  0 background = 255        (0x0000FF as COLORREF = RED)
          char 30 background = 16711680   (0xFF0000 as COLORREF = BLUE)
          char 38 background = 255        (back to RED)
      ValuePattern: ABSENT

The colors are COLORREF-ordered `Int32` (0x00BBGGRR), and the boundaries
land exactly where the app painted them (blue at 30-38). So all three
capabilities are assertable through UIA: HIGHLIGHT via
`GetAttributeValue(40001)`, SELECT via `GetSelection()`, REVEAL via
`GetVisibleRanges()`.

Note also `ValuePattern: ABSENT` on RichEditBox where TextBox has it —
a screen reader reads a RichEditBox through TextPattern instead. Kaya's
own text read is `field.Text()` in-process, so this does not break the
existing harness, but it is a real a11y-surface change. The automation
control type stays `Edit` for both, so the a11y role read (:6643-6650)
is unaffected.

**So the windows arm has three candidate observability stories, and the
design has to pick one:**

1. **Out-of-process UIA client** — the strongest (it is what a screen
   reader sees, and it proves the platform, not kaya's bookkeeping). But
   it runs straight at the documented wall. The recorded fatality was
   specific to the Shell's DirectUI file dialog, so a client attached
   only during a text-ranges scene may well be safe; that is a claim
   that must be *measured* (run the filedialog scene with a client
   attached and watch the java leg) before anyone relies on it. It also
   needs a second process, which this repo built once and deleted.
2. **Read the control's own text object model in-process** —
   `GetRange(a,b).CharacterFormat.BackgroundColor`,
   `Selection.StartPosition/EndPosition`, `ScrollViewer.VerticalOffset`.
   No UIA, no wall, works today (I measured every one of these). It is a
   genuine read of RichEdit's own model rather than kaya's bookkeeping,
   but it cannot prove *painting*.
3. **Pixels** — what I did for this probe. Strong, and this repo already
   has recording-mode machinery, but it is a poor fit for a per-leg
   assertion.

My recommendation, stated as a probe finding rather than a design
decision: **(2) for the harness legs, plus (1) once, as a gate that
proves the platform actually publishes what kaya claims.** Option 2 keeps
every lane on the safe side of the wall; option 1 run once (or in a
dedicated leg) buys the "a primitive nobody can assert does not ship"
guarantee at its strongest, and is the only route that demonstrates the
highlight reaches assistive technology at all.

---

## 9. Cost of the switch, itemized

**Binding layer (measured, not estimated).** I ran kaya's own bindgen
into the scratchpad with RichEditBox and the text object model added:

- Needs a **new `--in`**: `Microsoft.UI.Text.winmd`. It ships inside the
  WinUI 2.2.1 package kaya already fetches but is **not** in the
  bindgen's input list today (tools/winui-bindgen/src/main.rs:13-21).
- 22 new filter entries. **No transitivity trap** — it generated clean
  on the first attempt, which is not the usual experience with this
  filter list.
- Generated file: 147,372 → 159,265 lines, **+11,893 lines (+7.7%)**,
  29 new public types.
- Every method the design needs is present in the output: `ScrollIntoView`,
  `GetRange`, `CharacterFormat`/`SetCharacterFormat`, `BackgroundColor`/
  `SetBackgroundColor`, `BatchDisplayUpdates`, `ApplyDisplayUpdates`,
  `Selection`, `SetRange`, `StartPosition`, `EndPosition`, `StoryLength`,
  `GetText`, `SetText`, `SetClipboardCopyFormat`,
  `SetDisabledFormattingAccelerators`.

**Backend code.** RichEditBox is **not** a drop-in: it has no `Text`
property and none of the editing commands kaya calls. Every one of these
moves to `TextDocument` or `ITextRange`:

| kaya call site | TextBox method | RichEditBox replacement |
|---|---|---|
| :3674 | `ClearUndoRedoHistory()` | `TextDocument.ClearUndoRedoHistory()` |
| :3751, :3962 | `CanUndo()` | `TextDocument.CanUndo()` |
| :3759 | `CanRedo()` | `TextDocument.CanRedo()` |
| :3956 | `Undo()` / `Redo()` | `TextDocument.Undo()` / `.Redo()` |
| :3961, :5127, :5472, :7088, :7157, :7194, :6701, :7254 | `Text()` | `TextDocument.GetText(AdjustCrlf, &mut s)` |
| :4028 | `CutSelectionToClipboard()` | `TextDocument.Selection.Cut()` |
| :4030 | `CopySelectionToClipboard()` | `TextDocument.Selection.Copy()` |
| :4042 | `PasteFromClipboard()` | `TextDocument.Selection.Paste(0)` |
| :3827 | `CanPasteClipboardContent()` | `TextDocument.CanPaste()` |

That is 14 call sites, plus the structural one: `editable_by_id` returns
`Option<TextBox>` (:3644) and `focused_editable_id` closes over
`|field: &TextBox|` (:3625). Those two funnels serve entry *and*
textarea, so a RichEditBox textarea forces an enum (or a small trait)
through the undo, clipboard and menu-role paths — the paths the last two
milestones just landed on. This is the single largest cost item and it
is a refactor, not a discovery.

**Plus:** a minimal `TargetType="RichEditBox"` ControlTemplate (verified
to work), `ClipboardCopyFormat = PlainText`,
`DisabledFormattingAccelerators = All`, `GetText(AdjustCrlf)` everywhere,
and an explicit whole-story clear before every re-declaration.

**Alternative worth pricing before committing:** keep textarea on
TextBox, serve SELECT and REVEAL there (both measured working), and let
HIGHLIGHT be the one primitive a widget may not support on this
platform. That costs zero refactor and zero behaviour change, at the
price of a carve-out in a milestone whose whole point is uniformity.
Stated here because the measurement supports it, not because I am
recommending it — a carve-out on the one primitive that motivated the
milestone is a poor trade unless the other arms hit the same wall.

---

## 10. What I did not measure

- A real IME composition in flight (section 7). The caret-neutrality
  proxy passed; the composition itself is untested.
- Whether an out-of-process UIA client attached during a text-ranges
  scene re-triggers the file-dialog fatality on the java leg. This is
  the load-bearing unknown for observability option 1, and it is
  measurable: run the filedialog scene with a client attached.
- Screen-reader end-to-end (Narrator announcing a highlighted range).
  UIA publishes the attribute; whether Narrator speaks it is separate.
- Behaviour with very large documents beyond 82 KB, and highlight counts
  beyond 200.

---

## Cleanup (proven, not asserted)

VM, after the run:

    rangeprobe processes: 0
    dotnet/MSBuild/VBCSCompiler processes: 0
    kaya_rp* scheduled tasks: NONE          (all four created tasks deleted)
    C:\kaya rp_*/rangeprobe* leftovers: 0/0
    C:\kaya\rangeprobe (38.2 MB) deleted; C:\kaya\rp (37.4 MB) deleted
    nuget package cache: 770.1 MB  == baseline 770.1 MB
      (850 MB of App SDK packages + 168 MB ML/tensors + 74.6 MB SDK.NET.ref removed)
    nuget http cache cleared: 347.7 MB
    free space: 9.41 GB   (baseline before the probe: 9.22 GB)

The VM was never force-cycled and never wedged. Repo tree clean
(`git status --porcelain` empty); nothing under crates/ or tools/ was
modified — the augmented bindgen ran from a scratchpad copy writing to a
scratchpad path.

Scratchpad artifacts remaining beside this report: `winmd.py` (the
metadata reader), `rangeprobe/` (the C# probe source, ~30 KB),
`range-probe-windows.png` (the pixel evidence), and the driver scripts.
The scratchpad cargo target dir for the bindgen run (148 MB) is deleted.
