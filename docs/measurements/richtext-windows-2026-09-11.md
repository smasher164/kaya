# Rich text on Windows — WinUI 3 RichEditBox unpinned, measured

**Probe** `/Users/akhilindurti/.claude/jobs/87aed9b4/tmp/richtext/probes/win/`
(`Program.cs` + `KayaRichProbe.csproj` + `App.xaml` + `drive.cmd` + `uia.ps1` +
`uia3/` + `run.py`), copied from `tools/win/searchprobe/` and run on the shared
Windows 11 arm64 VM (`akhil@192.168.64.2`) on 2026-09-11, staged at
`C:\kaya\richtext-probe`, **deleted at the end** (proof at the foot of this
file). No kaya lane was running: `tasklist` showed no `dotnet`/`kaya`/`python`
process and `schtasks /query` no task in the `Running` state before the first
run.

Everything that measures runs in the guest's **interactive** session as a
scheduled task (`schtasks /create /it /rl highest`), because an ssh session has
its own window station and can neither see windows nor synthesize input into
them (`docs/traps.md`). `run.py` only ships, builds, schedules, polls and reads
the log back.

Windows App SDK **2.2.0** (WinUI runtime 2.2.1), .NET SDK **10.0.301**,
`net10.0-windows10.0.26100.0`, `win-arm64`, unpackaged.

## Artifacts

| file | what |
| --- | --- |
| `win/log-final.txt` | the probe's own log, run 5 (the definitive one) |
| `win/uia-final.txt` | the managed `System.Windows.Automation` client's reading |
| `win/uia3-final.txt` | the UIA3 COM client's reading (the numeric attribute ids) |
| `win/specimen-final.png` | the formatted specimen as the control actually drew it |
| `win/specimen-final.bmp` | the raw 520x220 BGRA capture the probe wrote (`RenderTargetBitmap` + a hand-written BMP header) |
| `win/log-run1..4.txt`, `win/uia-run1..4.txt`, `win/uia3-run4.txt`, `win/out-final.txt` | earlier runs and the probe's stdout, kept because two of them are the evidence for probe defects named below |

Five runs. Runs 1-4 each found a defect **in the probe**, each fixed before the
number was believed: `ITextDocument` is internal in the C# projection (the
public type is `RichEditTextDocument`); `doc.Undo()` returns `void` in WinUI's
projection, not `Int32` as the UWP reference says; PowerShell variables are
case-insensitive, so holding the `TextPattern` **type** in `$TP` and the pattern
**instance** in `$tp` is one variable and the whole UIA half measured nothing
(run 1); the default character format survives a `SetText`, so run 1 read
`bold=On` over every run of the specimen; and offsets captured once before a
`Link` was set are stale, because setting a link **inserts text** (below).

### Reproducing

```
cd .../probes/win && ./run.py akhil@192.168.64.2 --build [--keep]
```

Without `--keep` the staged directory is removed and the task deleted.

---

## 1. The final EOP (R2) — it never left, and `AllowFinalEop` is a no-op here

The headline: **kaya's RichEditBox was never in a plain-text *mode***.
`pin_plain_text` (`crates/kaya/src/winui/mod.rs:9443`) sets
`ClipboardCopyFormat = PlainText`, `DisabledFormattingAccelerators = All` and
cancels the control's own `Paste`. Those are *opinions*, not a mode: the Text
Object Model underneath is the same rich store either way. Two controls were
held side by side — one carrying kaya's three pins exactly, one untouched — and
**every reading below was byte-identical on both**.

| `SetText` | `GetText(None)` | `AdjustCrlf` | `AllowFinalEop` | `NoHidden` | `UseCrlf` | StoryLength |
| --- | --- | --- | --- | --- | --- | --- |
| `""` | `"\r"` (1) | `""` (0) | `"\r"` (1) | `""` (0) | `""` (0) | 1 |
| `"abc"` | `"abc\r"` (4) | `"abc"` (3) | `"abc\r"` (4) | `"abc"` (3) | `"abc"` (3) | 4 |
| `"abc\r"` | `"abc\r\r"` (5) | `"abc\r"` (4) | `"abc\r\r"` (5) | `"abc\r"` (4) | `"abc\r\n"` (5) | 5 |
| `"abc\rdef"` | `"abc\rdef\r"` (8) | `"abc\rdef"` (7) | `"abc\rdef\r"` (8) | `"abc\rdef"` (7) | `"abc\r\ndef"` (8) | 8 |
| `"a\nb"` | `"a\rb\r"` (4) | `"a\rb"` (3) | `"a\rb\r"` (4) | `"a\rb"` (3) | `"a\r\nb"` (4) | 4 |

Readings, all three spellings of StoryLength agreeing
(`GetRange(0,0).StoryLength`, `Selection.StoryLength`,
`GetRange(0, TextConstants.MaxUnitCount).EndPosition`, and
`GetRange(0, int.MaxValue).EndPosition`; `MaxUnitCount` is **1073741823**):

- **`StoryLength - 1 == GetText(None).Length` is FALSE in every case.**
  `GetText(TextGetOptions.None)` **includes** the undeletable final CR.
- **`StoryLength - 1 == GetText(AdjustCrlf).Length` is TRUE in every case**,
  empty story included. `AdjustCrlf` is the read that drops the final EOP —
  and it is the read kaya already uses (`crates/kaya/src/winui/mod.rs:1577-1598`).
- **`AllowFinalEop` (8) does nothing on this control.** Documented as the flag
  that *allows* the final end-of-paragraph, it produces exactly `None`'s string,
  and `AdjustCrlf|AllowFinalEop` produces `None`'s string too — i.e. the flag's
  only observable effect is to cancel `AdjustCrlf`'s stripping.
- `UseCrlf` (2) expands every stored CR to CRLF, so it **changes the length**
  and must never be used for offset arithmetic.
- The line break stays 1:1: `"a\nb"` stores as `a\rb`, three characters, as
  `docs/ranges-units.md:261-268` records.

The pinned control is still a rich control underneath, proven rather than
asserted: a programmatic `Bold On` over cp (0,2) of `"abc"` took —
`bold(0,2)=On(1) bold(2,3)=Off(0) bold(0,3)=Undefined(3)` — and
`GetText(FormatRtf)` returned 226 characters of RTF ending
`\pard\tx720\cf1\b\f0\fs21 ab\b0 c\par`.

## 2. Unit arithmetic (R2) — UTF-16 code units, and ranges SNAP OUTWARD

`SetText(None, "héllo 👋 世界")`: 11 UTF-16 units, **18 UTF-8 bytes**, 10 text
elements. `StoryLength = 12` (11 + the final EOP). `GetText(AdjustCrlf)`
round-trips the string exactly; `GetText(None)` does not, because of the CR.

| cp | `GetRange(cp, cp+1)` answers | text | UTF-8 byte offset of that unit |
| --- | --- | --- | --- |
| 0 | (0,1) | `h` | 0 |
| 1 | (1,2) | `é` U+00E9 | 1 |
| 2 | (2,3) | `l` | 3 |
| 3 | (3,4) | `l` | 4 |
| 4 | (4,5) | `o` | 5 |
| 5 | (5,6) | ` ` | 6 |
| 6 | **(6,8)** | `👋` (both units) | 7 |
| 7 | **(6,8)** | `👋` (both units) | — |
| 8 | (8,9) | ` ` | 11 |
| 9 | (9,10) | `世` U+4E16 | 12 |
| 10 | (10,11) | `界` U+754C | 15 |
| 11 | (11,12) | the final `\r` | (end = 18) |

So cp offsets are UTF-16 code units, confirmed by the emoji occupying cp 6 and
cp 7; kaya's byte→cp conversion is the ordinary UTF-8→UTF-16 one with **no
Windows-specific fudge**, and the trailing EOP sits one unit past the guest's
last unit.

**The split-pair behaviour contradicts `docs/ranges-units.md:312`** ("windows —
expressible, accepted"). Every door snaps outward to the whole pair:

```
GetRange(6,7)           -> (6,8)   "👋"
GetRange(7,8)           -> (6,8)   "👋"
SetRange(6,7)           -> (6,8)   "👋"
SetRange(7,8)           -> (6,8)   "👋"
Selection.SetRange(6,7) -> (6,8)   "👋"
GetRange(0,7)           -> (0,8)   "héllo 👋"     (the END splits and is pushed out)
GetRange(-5,9999)       -> (0,12)                (clamps, as documented)
```

Windows therefore behaves like Compose here (snap outward), not like the
"accepts a split range and paints half an emoji" row the units doc carries.

## 3. Undo suppression (R6) — `UndoLimit = 0` holds, and it is one-way

| measurement | result |
| --- | --- |
| `UndoLimit = 0`, three real keystrokes, real **Ctrl+Z** | text unchanged (`"seedXYZ"`), `CanUndo=False` |
| the same, then a programmatic `doc.Undo()` | text unchanged |
| `UndoLimit = 0`, then `Selection.CharacterFormat.Bold = On`, then real Ctrl+Z | `bold(0,6)=On(1)` still — the format is **not** rolled back |
| `UndoLimit = 0`, then a **real Ctrl+B** (accelerators enabled: `DisabledFormattingAccelerators=None`), then Ctrl+Z | bolds, and Ctrl+Z does **not** revert it |
| raise `UndoLimit` 0 → 100 at runtime, type, Ctrl+Z | undoes (`"baseQRS"` → `"base"`) — **the limit can be raised back** |
| drop `UndoLimit` 100 → 0 with a stack already present | `CanUndo` True → **False**: the existing stack is **destroyed** |
| raise it back to 100 afterwards | `CanUndo` still **False** — the cleared stack does not come back |
| a programmatic `CharacterFormat.Bold = On` at limit 100, then `doc.Undo()` | reverts to `Off` — **format changes are undoable when the stack is on** |
| `BeginUndoGroup()` / `TypeText("INS")` + `Bold On` / `EndUndoGroup()`, then ONE `doc.Undo()` | **both** reverted in one step: `"group INS"` → `"group "` and `bold(0,5)` On → Off |

So R6's Windows lever is real and complete: `UndoLimit = 0` silences the native
tier for typing, for programmatic formatting and for the control's own
Ctrl+B/Ctrl+Z accelerators alike. And `BeginUndoGroup`/`EndUndoGroup` is
genuine explicit grouping — Windows is the one backend that can put an insert
and its attributes into a single undo step, which is the spelling
`docs/undo-plan.md` D2 wanted.

The one-way part matters for D7: `UndoLimit = 0` is not a pause. It empties the
stack, and raising the limit again does not restore it. A kaya widget that
toggles `own_undo()` at runtime would leave the user with no history either way.

## 4. Edit reporting (R4) — no range, but a usable content/attribute discriminator

`RichEditBoxTextChangingEventArgs` carries exactly `IsContentChanging`, and
`TextChanged` a bare `RoutedEventArgs`, as the survey said. `SelectionChanging`
does carry `SelectionStart` and `SelectionLength` — a range, but of the
*selection*, sampled **before** the edit, not of the edit.

Event order, measured (sequence numbers are the probe's own counter):

| stimulus | events, in order |
| --- | --- |
| one keystroke `x` at the end | `SelectionChanging start=4 len=0` → `TextChanging IsContentChanging=True` → `SelectionChanged start=4 end=4` → `TextChanged` |
| **Ctrl+V** of plain text `"PQ"` | `Paste(handled=False)` → `SelectionChanging start=6 len=0` → `TextChanging True` → `SelectionChanged` → `TextChanged` — **one** pair for the whole paste |
| programmatic `SetText(None, "programmatic")` | `SelectionChanging start=0 len=0` → `TextChanging True` → `SelectionChanged` → `TextChanged` — **identical in shape to a keystroke** |
| attribute-only `CharacterFormat.Bold = On` over (0,4) | `TextChanging IsContentChanging=**False**` → `TextChanged`. **No selection events.** |
| `ParagraphFormat.Alignment = Center` | `TextChanging False` → `TextChanged` |
| a format re-apply that changes nothing | `TextChanging False` → `TextChanged` — it still fires |
| a programmatic `Selection.SetRange(2,5)` | `SelectionChanging start=2 len=3` → `SelectionChanged start=2 end=5`. **No text events.** |
| a real Backspace | same shape as a keystroke |

Three consequences for R4:

- **Attribute-only changes DO raise `TextChanged`**, and `IsContentChanging` is
  the discriminator: `True` for a content edit, `False` for a character- or
  paragraph-format change. That is more than "a boolean 'content is changing'":
  it is exactly the bit that tells kaya's diff to skip.
- **A programmatic write is indistinguishable from user input by events alone.**
  The WinUI arm keeps its existing swallow counter or equivalent; the events
  cannot serve as `source`.
- `TextCompositionStarted/Changed/Ended` never fired in this probe (no IME was
  driven), so the bracketing claim is still untested; the handlers are wired in
  `Program.cs` for whoever drives one.

One mechanical finding worth carrying: the object
`ITextRange.CharacterFormat` hands back is **live** — mutating it applies
immediately. The idiomatic `var cf = r.CharacterFormat; cf.Bold = On;
r.CharacterFormat = cf;` therefore applies **twice** and fires two
`TextChanging`/`TextChanged` pairs; assigning nothing back fires one.

## 5. Read-back — a real tri-state, and a Link that is TEXT

`FormatEffect` is `Off(0) / On(1) / Toggle(2) / Undefined(3)`. Over
`"abcdefghij"` with bold on cp (0,5):

| range | `CharacterFormat.Bold` |
| --- | --- |
| (0,5) fully bold | `On(1)` |
| (5,10) fully plain | `Off(0)` |
| (0,10) mixed | **`Undefined(3)`** |
| (4,6) straddling the seam | **`Undefined(3)`** |
| (0,0) collapsed, bold half | `On(1)` |
| (7,7) collapsed, plain half | `Off(0)` |
| (5,5) collapsed, on the seam | `On(1)` — a caret takes the character **before** it |

Italic behaves the same. The non-`FormatEffect` properties are less uniform:

- `Weight`: 700 / 400, mixed → **`-9999999`** (`TextConstants.UndefinedInt32Value`).
- `Size`: 12 / 24, mixed → **`-9999999`** (`TextConstants.UndefinedFloatValue`).
- `Underline` (a `UnderlineType`, not a `FormatEffect`): `Single` / mixed → `Undefined`.
- `Name` (font face): `"Consolas"` / `"Courier New"`, mixed → **`"Courier New"`** —
  *not* a sentinel. A mixed font name answers with one of the two faces, so a
  toolbar cannot tell "all Courier" from "mixed". Kaya's `code` run read-back
  on Windows must be derived from the runs, not from a range query.

### `ITextRange.Link` puts the URL INTO the story

This is the load-bearing finding of the whole probe.

```csharp
doc.SetText(TextSetOptions.None, "see example here");   // StoryLength 17
var lr = doc.GetRange(4, 11);                            // "example"
lr.Link = "\"https://example.com/\"";                    // the quotes are REQUIRED
```

A bare URL throws: `ArgumentException: Value does not fall within the expected
range.` With the quotes it succeeds — and:

```
StoryLength           17  ->  49
GetText(None)         "see HYPERLINK \"https://example.com/\"example here\r"   (49)
GetText(AdjustCrlf)   "see HYPERLINK \"https://example.com/\"example here"     (48)
GetText(NoHidden)     "see example here"                                       (16)  <- unchanged
the range (4,11)  ->  (4,43), Text = "HYPERLINK \"https://example.com/\"example"
```

Per character: cp 4-35, the 32 characters `HYPERLINK "https://example.com/"`,
are `Hidden=On(1)` with `LinkType=FriendlyLinkAddress`; cp 36-42, the seven
visible characters `example`, are `Hidden=Off(0)` with
`LinkType=FriendlyLinkName`. Setting `Link = ""` removes the field and puts
`StoryLength` back to 17. Setting the same link through
`SetText(TextGetOptions.FormatRtf, …)` with a real `{\field{\*\fldinst{HYPERLINK
…}}{\fldrslt{…}}}` produces the identical story.

So on Windows a link is a RichEdit **field**: its instruction lives in the
character stream as hidden text, and TOM cp offsets count it while the
guest-visible text does not. `GetText(NoHidden)` is the only read that agrees
with what the user sees. `CharacterFormat.LinkType` answers `NotALink` off a
link and is get-only, as the survey said; `Link` read back returns the quoted
form verbatim.

The specimen (`win/specimen-final.png`) shows how it draws: bold, italic,
underline, strikethrough and Consolas all render; the link renders
**underlined in the ordinary text colour** (its `ForegroundColor` reads 0 =
black), not in an accent colour; the "heading" is simply 24pt bold.

## 6. UIA attributes (R9) — rich enough for weight/italic/underline/strike/face, nothing for headings

Two clients were used, because one of them cannot ask the questions that
matter. The managed `System.Windows.Automation` client (`uia.ps1`, PowerShell
5.1.26100.9444) answers `AutomationTextAttribute.LookupById` with **null** for
`StyleName(40033)`, `StyleId(40034)`, `Link(40035)`, `AnnotationTypes(40031)`
and `CaretPosition(40038)` — it has no identifier for them at all. The
WinUI `RichEditBox`'s own XAML automation peer has **no `ITextProvider`**
(`peer.GetPattern(PatternInterface.Text)` is null), so the provider side cannot
be asked in process either. A UIA3 COM client (`uia3/`, the
`Interop.UIAutomationClient` 10.19041.0 package) asks the numeric ids directly.

**The element.** `ControlType.Edit`, class `RichEditBox`, localized control
type `"edit"`, `Name=""`, keyboard focusable, `IsPassword=False`. Supported
patterns: `TextPatternIdentifiers.Pattern`, `ScrollItemPatternIdentifiers.Pattern`.
`SupportedTextSelection = Single`.

**The text.** `DocumentRange.GetText(-1)` is
`plain run\rbold run\ritalic run\runder run\rstrike run\rmono run\rlink run\rheading run`
— **80 characters, the `NoHidden` text**. The link's field instruction is not in
the UIA text, while it *is* in the TOM story (117 cp). UIA offsets and TOM cp
offsets differ by 36 in this document.

**Per run** (identical from both clients):

| run | FontWeight | IsItalic | UnderlineStyle | StrikethroughStyle | FontName | FontSize |
| --- | --- | --- | --- | --- | --- | --- |
| plain | 400 | False | None (0) | None (0) | Segoe UI Variable | 14 |
| bold | **700** | False | None | None | Segoe UI Variable | 14 |
| italic | 400 | **True** | None | None | Segoe UI Variable | 14 |
| underline | 400 | False | **Single (1)** | None | Segoe UI Variable | 14 |
| strike | 400 | False | None | **Single (1)** | Segoe UI Variable | 14 |
| mono | 400 | False | None | None | **Consolas** | 14 |
| link | 400 | False | None | None | Segoe UI Variable | 14 |
| heading | **700** | False | None | None | Segoe UI Variable | **24** |

`ForegroundColor=0`, `BackgroundColor=16777215`, `IsHidden=False`,
`IsReadOnly=False`, `HorizontalTextAlignment=Left`, `BulletStyle=None`,
`IndentationLeading=0` everywhere. Over the whole document every varying
attribute answers `TextPattern.MixedAttributeValue` / the COM client's
`ReservedMixedAttributeValue`. `OverlineStyle`, `StrikethroughColor` and
`UnderlineColor` answer `NotSupported` except where the run actually carries one.

**Links.** `Link(40035)` is **`NotSupported`** from the real UIA3 client. But
the link *is* exposed as a child element: `TextRange.GetChildren()` over the
link run returns one `ControlType.Hyperlink` (50005, localized `"link"`) whose
`Name` is the link text `"link run"`; `DocumentRange.GetChildren()` returns that
same single child; and it appears in the window's element tree beside the two
`RichEditBox` elements. That is what Narrator has: a hyperlink element inside
the text, not a Link text attribute.

**Headings.** `StyleName(40033)` and `StyleId(40034)` are **`NotSupported`**.
A 24pt bold run exposes `FontSize=24` and `FontWeight=700` and nothing else —
there is no heading semantics on this control at all, from either client.

**Run boundaries.** The `TextUnit.Format` walk segments exactly at attribute
boundaries — 16 runs for the 8-line specimen, each paragraph's CR its own run —
so a screen reader finds kaya's runs without help.

---

## The reading, one paragraph per point

**1. The final EOP.** It never went away, because kaya's RichEditBox was never
in plain-text *mode* — `pin_plain_text` sets three opinions on a control whose
Text Object Model is rich either way, and the pinned and unpinned controls
returned byte-identical readings for every text tried. `GetText(None)` always
carries the undeletable final CR, `AllowFinalEop` is a no-op on this control
(its only effect is to cancel `AdjustCrlf`'s stripping), and the read kaya
already uses, `AdjustCrlf`, is the one that drops it. So `StoryLength - 1 ==
len(GetText(AdjustCrlf))` held in all five cases including the empty story, and
**R2's arithmetic survives the unpinning unchanged** — the §3.3 unknown closes
green, with the hidden-text caveat below.

**2. Unit arithmetic.** cp offsets are UTF-16 code units, confirmed by the emoji
occupying cp 6 and cp 7 of an 11-unit / 18-byte string whose story is 12 long;
so kaya's byte→cp conversion is the plain UTF-8→UTF-16 one with the EOP sitting
one unit past the end. The surprise is validation: every door — `GetRange`,
`SetRange`, `Selection.SetRange` — **snaps a split surrogate pair outward** to
the whole pair rather than accepting it, which is the opposite of what
`docs/ranges-units.md`'s summary table records for Windows and should be
corrected there.

**3. Undo suppression.** `UndoLimit = 0` is a complete off switch: real
keystrokes, programmatic `CharacterFormat` writes and the control's own Ctrl+B
accelerator all survive a real Ctrl+Z, and `CanUndo` stays false. The limit can
be raised again at runtime and typing then undoes normally — but dropping it to
zero **destroys** the stack that was there and raising it back does not restore
it, so `own_undo()` is a one-way lever per widget, not a pause.
`BeginUndoGroup`/`EndUndoGroup` genuinely groups: one `Undo()` reverted both a
`TypeText` insert and a bold applied inside the same group, which makes Windows
the only backend that can offer D2's named group for free.

**4. Edit reporting.** Confirmed: `TextChanging` carries only
`IsContentChanging`, `TextChanged` carries nothing, and neither carries a range,
so the core's mirror diff is the only delta available — R4's premise holds. Two
things are better than the survey assumed: `IsContentChanging` is a genuine
discriminator (`True` for a content edit, `False` for a character- or
paragraph-format change, which also raises `TextChanged`), and the event order
is stable — `SelectionChanging` → `TextChanging` → `SelectionChanged` →
`TextChanged` for a keystroke, a paste and a Backspace alike, a paste producing
exactly one pair. One thing is worse: a programmatic `SetText` produces that
identical shape, so the events cannot supply R4's `source` and the WinUI arm
must keep its own swallow accounting.

**5. Read-back.** The tri-state is real and is the right semantics to put on the
wire: `On(1)` / `Off(0)` / `Undefined(3)` for `Bold`, `Italic` and the rest, with
a straddling range answering `Undefined` and a collapsed caret taking the
character before it. The non-`FormatEffect` properties are not uniform —
`Weight` and `Size` answer the sentinel `-9999999` when mixed, `Underline`
answers `Undefined`, but a mixed **font name** answers with one of the two
faces, so kaya's `code` read-back must come from the run model rather than from
a range query. `ITextRange.Link` works but demands the URL wrapped in quotes and
is **not an attribute**: it inserts `HYPERLINK "url"` into the story as 32
hidden characters, taking `StoryLength` from 17 to 49 while the visible text
stays 16, and the link then renders underlined in the ordinary text colour.

**6. UIA attributes.** Narrator gets a good inline vocabulary and no block
vocabulary at all. `FontWeightAttribute` (400/700), `IsItalicAttribute`,
`UnderlineStyleAttribute`, `StrikethroughStyleAttribute` and `FontNameAttribute`
(`Consolas`) all read correctly per run, mixed ranges answer
`MixedAttributeValue`, and a `TextUnit.Format` walk segments exactly at kaya's
run boundaries. A link is **not** a `LinkAttribute` — that id answers
`NotSupported` — but it *is* a `ControlType.Hyperlink` child element returned by
`TextRange.GetChildren()` and present in the element tree with the link text as
its `Name`, which is the route a screen reader actually takes. A heading-sized
run exposes `FontSize=24` and `FontWeight=700` and nothing more:
`StyleId`/`StyleName` are `NotSupported`, so R9's `heading` AX word has **no
Windows source** and would have to be synthesized by kaya if it is to be
announced at all.

## The two most important caveats

**1. A Windows link is TEXT, and it breaks the offset contract.** `ITextRange.Link`
is not an attribute over a range — it inserts a RichEdit *field* whose
instruction (`HYPERLINK "https://example.com/"`, 32 characters here) lives in
the character stream as hidden text. TOM cp offsets count those characters and
the guest-visible text does not: one link took `StoryLength` from 17 to 49 with
`GetText(NoHidden)` unchanged at 16, and in the eight-line specimen TOM cp and
UIA offsets differed by 36. Every offset kaya sends or receives on Windows is a
cp offset, so as soon as a rich link exists the WinUI arm needs a hidden-text
map between the two spaces — or Windows joins GTK in R3's *synthesized* link
tier (a formatted run plus a side table keyed by run, nothing in the buffer),
which is the option that keeps five platforms agreeing on byte offsets. This is
the ruling R3 leaves open for Windows and it should be taken before the arm is
written.

**2. `StoryLength - 1` is only true for the read kaya happens to use, and only
while nothing hidden is in the story.** The identity that survives the unpinning
is `StoryLength - 1 == len(GetText(AdjustCrlf))`, not
`StoryLength - 1 == len(GetText(None))` — `None` includes the final CR and
`AllowFinalEop` changes nothing. It is therefore an invariant about a *flag
combination*, not about the control, and any new read added to the WinUI arm
that forgets `AdjustCrlf` will be off by one with no error anywhere. And the
identity fails outright the moment hidden text (a link field, a hidden run)
enters the story: there `StoryLength - 1` counts characters the guest cannot
see. A guard is cheap and belongs on the path nobody can avoid — one helper in
`crates/kaya/src/winui/mod.rs` that is the only place `GetText` is called, with
`AdjustCrlf|NoHidden` baked in and an assertion that the length it returns
matches the core's mirror.

## Nothing left running on the guest

```
$ ssh akhil@192.168.64.2 'cmd /c tasklist /fi "imagename eq KayaRichProbe.exe"'
INFO: No tasks are running which match the specified criteria.
$ ssh akhil@192.168.64.2 'cmd /c tasklist /fi "imagename eq Uia3Probe.exe"'
INFO: No tasks are running which match the specified criteria.
$ ssh akhil@192.168.64.2 'cmd /c tasklist /fi "imagename eq dotnet.exe"'
INFO: No tasks are running which match the specified criteria.
$ ssh akhil@192.168.64.2 'cmd /c tasklist /fi "imagename eq powershell.exe"'
INFO: No tasks are running which match the specified criteria.
$ ssh akhil@192.168.64.2 'schtasks /query /fo csv /nh' | grep -i kaya_rt
(no output)
$ ssh akhil@192.168.64.2 'cmd /c dir C:\kaya\richtext-probe'
 Directory of C:\kaya
File Not Found
```

The staged directory `C:\kaya\richtext-probe` (sources, `bin`, the `uia3`
project and its NuGet output, the logs and the specimen bitmap) was removed with
`rmdir /s /q`; the scheduled task `kaya_rt` was deleted with `schtasks /delete`.
Nothing was written anywhere else on the guest, and no file in the kaya
repository was touched.
