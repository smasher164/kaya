# The heading-return probe — the WinUI lane (2026-09-14)

Akhil's ruling question: with the caret at the END of a HEADING paragraph, a
Return — does the new paragraph stay a heading (kaya's one-sentence
inheritance rule: a typed byte copies the styles of the byte before it,
except `link`) or become a normal paragraph (what editors do)? Measured, not
recalled. Machine: the Windows VM at akhil@192.168.64.2,
`Microsoft Windows [Version 10.0.26200.9445]` (Windows 11, arm64).

Three answers up front:

- **A — kaya today, on this lane:** the new paragraph IS a heading. The
  heading's `block` run extends over the Return AND over the letter typed
  after it — `13:24 block=heading1` becomes `13:26 block=heading1` — and the
  edit the core published for the typed text carries `[0:2 block=heading1]`.
  The arm's own run table agreed with the core at every read (no
  `— but the widget holds` clause, no `KAYA_DIAG`).
- **B — a bare RichEditBox, no kaya rules:** (below)
- **C — the platform's reference rich editor:** (below)

## Setting up: the lane's `type` verb now spells Return

`crates/kaya/src/harness.rs`'s `check_typing` admits `\n` as of today, and
Stage's contract point 6 names it. The WinUI key path mapped every character
through `VkKeyScanW`, which has no key for U+000A — the `scan != -1` assert
would have refused the newline by name. One branch added in
`crates/kaya/src/winui/mod.rs`'s `type_text`: `\n` is `0x0d` (VK_RETURN) with
no modifiers, injected by the same `keybd_event` pair, in the same loop, in
the same order as the letters. `keybd_event` rather than `SendInput` because
that is what this file's other two key paths (`shortcut`, the rest of
`type_text`) already use — the same system input queue, one spelling.

THE GUARD THIS CHANGE NAMES: the `assert!(scan != -1, …)` already in that
loop is the wall on the path nobody can avoid — a character the active
layout cannot type panics NAMING the character, which is exactly what `\n`
would have hit before this branch. Its sentence was updated to say Return is
admitted. What no gate holds is the CROSS-BACKEND half: nothing checks that
every backend's `type` path can deliver every character `check_typing`
admits, so the next character added to that set can reach four lanes and
panic on the fifth. Reported for the coordinator; a gate belongs beside
check-verbs' "an action returns once the app has answered it" census, which
already reads the three runners' action arms.

Verification:

| what | result |
| --- | --- |
| `nix develop -c tools/check-targets.py` | rc 0 — `native OK / ios OK / android OK / windows OK / go-android OK`, `ALL OK` |
| `nix develop -c tools/check-verbs.py` | rc 0 — `OK (104 verbs, 169 constants …)` |
| `nix develop -c tools/deploy-win.py akhil@192.168.64.2 richtext_rust` | `richtext_rust: PASS (1s)`, `KAYA_SELFTEST: OK`, `deploy-win: ALL PASS` — the SHARED scene, unchanged, on the VM with this edit |

## A. kaya's arm today

The guest is `guests/rust/richtext.rs`, scene `richtext`, driven by a PRIVATE
steps file: `KAYA_SELFTEST=richtext` with `KAYA_SCENES_DIR=C:\kaya\rtprobe`,
so `crates/kaya/src/harness.rs`'s `script()` reads my file instead of the
lane's. Nothing in tools/scenes moved. Each pass ends in a deliberately wrong
`expect_runs`/`expect_edit`, whose failure sentence is the reading.

The seeded document is the scene's own: `"Héllo world\nSecond line"` with
`0:6 bold|7:12 link=https://kaya.dev|13:24 block=heading2`. Every pass then
runs `format textarea#0 13:24 block=heading1` (the second paragraph becomes a
heading) and `click button#5` (focus).

### P1 — the state before the Return

```
click button#0
format textarea#0 13:24 block=heading1
click button#5
expect_focused textarea#0
expect_runs textarea#0 "?"
```
```
KAYA_HARNESS: step-failed runs "0:6 bold|7:12 link=https://kaya.dev|13:24 block=heading1", wanted "?"
KAYA_SELFTEST: FAILED (runs "0:6 bold|7:12 link=https://kaya.dev|13:24 block=heading1", wanted "?")
```

### P2 — the Return's OWN edit

`type "\n"` then `expect_edit textarea#0 "?"`:
```
KAYA_HARNESS: +134ms Type("\n")
KAYA_HARNESS: step-failed edit "24:24 <\n> user [0:1 block=heading1]", wanted "?"
KAYA_SELFTEST: FAILED (edit "24:24 <\n> user [0:1 block=heading1]", wanted "?")
```
The inserted newline itself carries `block=heading1` — the byte before it is
the heading's last byte, and the core's rule copies it.

### P3 — the letter after the Return

`type "\nx"` then `expect_edit textarea#0 "?"`:
```
KAYA_HARNESS: +215ms Type("\nx")
KAYA_HARNESS: step-failed edit "24:24 <\nx> user [0:2 block=heading1]", wanted "?"
KAYA_SELFTEST: FAILED (edit "24:24 <\nx> user [0:2 block=heading1]", wanted "?")
```
ONE edit for TWO keystrokes on this backend, which is R4's "the core's diff
IS the delta" showing: WinUI's `TextChanged` carries no range and is raised
asynchronously, so the two keys injected back to back inside one `type` verb
arrive as one diff. The mac, which reports a range per change, publishes two.
Both bytes — the Return and the `x` — carry `block=heading1`.

### P4 — the document after Return + letter

`type "\nx"` then `expect_runs textarea#0 "?"`:
```
KAYA_HARNESS: step-failed runs "0:6 bold|7:12 link=https://kaya.dev|13:26 block=heading1", wanted "?"
KAYA_SELFTEST: FAILED (runs "0:6 bold|7:12 link=https://kaya.dev|13:26 block=heading1", wanted "?")
```
`13:24` became `13:26`: ONE heading run now spans the old paragraph, the
newline and the new paragraph's `x`. **The new paragraph is a heading.**

### P5 — the mid-paragraph case is NOT drivable through `type`

The charge asks for a caret INSIDE the heading (`format textarea#0 16:16
bold` to place it, then `type "\n"`). It cannot be done with this verb on any
lane: Stage's contract point 3 says `type` APPENDS — "the insertion point
goes to the END with nothing selected first" — and the WinUI arm honours it
with `field.set_caret(n)` before the first keystroke. Measured rather than
assumed:
```
KAYA_HARNESS: +138ms Format(… TextRange { start: 16, stop: 16 }, "bold", "true", false)
KAYA_HARNESS: +525ms Type("\n")
KAYA_HARNESS: step-failed runs "0:6 bold|7:12 link=https://kaya.dev|13:25 block=heading1|24:25 bold", wanted "?"
```
The caret went to 24 (the end), not 16, and the pending `bold` the collapsed
format armed SURVIVED that move and was spent on the newline — `24:25 bold`,
the core's pending rule, the mac's "a caret moved elsewhere by the user keeps
them until then" (docs/rich-text-plan.md §7) one act over. So this lane can
say nothing about a mid-paragraph Return; the platform half of that question
is measured in B below, and kaya's half is `RichDoc::splice`'s, which no
runner can reach.

### What the "widget" half read

None of the five sentences carried the `— but the widget holds "<runs>"`
clause, and no `KAYA_DIAG` appeared in any pass: the arm's own byte run table
(a second implementation of the core's splice,
`rich_splice`/`rich_spelling`) agreed with the core's mirror at every read.
NOTE FOR THE READER: on this backend `expect_runs`' widget half reads the
ARM'S TABLE, not TOM's character formats — the corroboration is
splice-against-splice. What the CONTROL itself does with a Return is B's
question, and only a bare control can answer it.

## B. A bare RichEditBox, none of kaya's rules

`KayaReturnProbe`, a WinUI 3 app holding ONE RichEditBox with no kaya pins,
no run table and no arm — built and run on the VM in the interactive session
(`schtasks /it`), so its `keybd_event` Return lands in its own foreground
window. Its shape is the 2026-09-11 probe's
(docs/measurements/richtext-windows-2026-09-11/): same csproj, same App.xaml
(a WinUI app with no XAML gets no template for a RichEditBox), same
`resources.pri` beside the exe.

The document is `"Body line\rHeading line"`. The second paragraph is styled
the way `rich_restyle` draws a heading — `CharacterFormat.Bold =
FormatEffect.On` and `Size = round(base × 1.6)` = 22 — plus a NON-DEFAULT
`ParagraphFormat` (`SetIndents(0, 20, 0)`, `SpaceBefore = 12`) so that the
block layer's inheritance is observable at all: the arm's own heading sets
indents to zero, which is the default, while its `quote` sets exactly this
indent, and the Return question applies to both.

### B1 — Return at the END of the styled paragraph

```
  styled paragraph (10,22) CF: bold=On italic=Off size=22 name=Segoe UI underline=None
  styled paragraph (10,22) PF: leftIndent=20 firstLine=-0 rightIndent=0 spaceBefore=12 spaceAfter=0 align=Left style=Normal
  caret at the styled paragraph's end: sel=(22,22)
  TOM's INSERTION format BEFORE the Return (Selection): bold=On size=22 name=Segoe UI | leftIndent=20 spaceBefore=12 style=Normal
  after the Return text="Body line\rHeading line\r\r" storyLength=24 sel=(23,23)
  TOM's INSERTION format after the Return (Selection): bold=On size=22 name=Segoe UI | leftIndent=20 spaceBefore=12 style=Normal
  after the letter text="Body line\rHeading line\rz\r" storyLength=25 sel=(24,24)
  the letter typed in the NEW paragraph (23,24) CF: bold=On italic=Off size=22 name=Segoe UI underline=None
  the letter typed in the NEW paragraph (23,24) PF: leftIndent=20 firstLine=-0 rightIndent=0 spaceBefore=12 spaceAfter=0 align=Left style=Normal
```

**The control CARRIES THE STYLE FORWARD, at both layers.** The insertion
format after the Return is still bold 22pt; the letter typed into the new
paragraph comes out bold 22pt; and the new paragraph's own ParagraphFormat
carries the indent and the space-before. Nothing is dropped.

TOM's `ParagraphFormat.Style` read `Normal` at every position in every
reading — the control has no notion of a heading STYLE to drop even in
principle. Its paragraph identity is the numbers (indents, spacing,
alignment) and its character identity is the font, and a Return clones both.

A READING TRAP, recorded because it is the one that makes this look like the
opposite answer: `GetRange(23,23).CharacterFormat` — the collapsed range at
the brand-new paragraph — reads `bold=Off size=14`, the format of the new
PARAGRAPH MARK, which was cloned from the old unstyled mark. That is NOT
what the next character will wear. The instrument that answers the question
is `Document.Selection.CharacterFormat`, TOM's insertion format, which reads
bold 22pt — and the typed letter agrees with it.

### B2 — Return in the MIDDLE of the styled paragraph

```
  caret mid-paragraph: sel=(17,17)
  after the Return text="Body line\rHeading\r line\r" storyLength=24 sel=(18,18)
  first half, the text alone (10,17) CF: bold=On italic=Off size=22 …
  first half, the text alone (10,17) PF: leftIndent=20 … spaceBefore=12 … style=Normal
  second half, the text alone (18,23) CF: bold=On italic=Off size=22 …
  second half, the text alone (18,23) PF: leftIndent=20 … spaceBefore=12 … style=Normal
  the letter typed at the split (18,19) CF: bold=On italic=Off size=22 …
```
Both halves stay fully styled at both layers, and a letter typed at the split
is styled too. The control splits a paragraph by cloning it.

### B3 — the baseline

Return at the end of the UNSTYLED first paragraph, then a letter: the letter
reads `bold=Off size=14`, `leftIndent=0 spaceBefore=0`. So B1's readings are
the STYLE being carried, not a floor the control applies to everything.

**What this means for the ruling on this platform:** the exception (a
Return after a heading starts a NORMAL paragraph) would work AGAINST the
control here, not with it. The arm would have to STRIP what the RichEditBox
inherited — clear Bold, put Size back to the base, put the indents back —
at every Return, on both the character and the paragraph layer. kaya's arm
already restyles the whole changed span from its own run table after every
published edit, so the strip has a place to live and costs no new mechanism:
the core's rule would decide, and `rich_restyle` would write the answer.
What it is NOT is free — "the control already drops it" is false on Windows.

## C. The platform's reference rich editor

WordPad is GONE from this machine and Word is not installed — measured, not
recalled:

```
== classic editors on disk ==
ABSENT  C:\Program Files\Windows NT\Accessories\wordpad.exe
ABSENT  C:\Program Files (x86)\Windows NT\Accessories\wordpad.exe
ABSENT  C:\WINDOWS\System32\write.exe
PRESENT C:\WINDOWS\System32\notepad.exe
ABSENT  C:\WINDOWS\System32\wordpad.exe
== WordPad as a Windows capability ==
(empty — not installable here either)
```
`Get-AppxPackage` finds `Microsoft.MicrosoftOfficeHub` (the Store tile, not
Word), `Microsoft.MicrosoftStickyNotes 4.0.6105.0` (bold/italic/underline,
NO headings, so the question does not arise there) and
`Microsoft.WindowsNotepad 11.2607.14.0`.

**Notepad on this build is NOT plain.** Its UIA tree carries a formatting
toolbar and its status bar says `Formatted`:
```
  [ControlType.Button] name="Headings" id=
  [ControlType.Button] name="Lists" id=
  [ControlType.Button] name="Bold (Ctrl+B)" id=
  [ControlType.Button] name="Italic (Ctrl+I)" id=
  [ControlType.Button] name="Strikethrough (Ctrl+Shift+X)" id=
  [ControlType.Button] name="Link (Ctrl+K)" id=
  [ControlType.Text] name="Formatted" id=ContentButtonText
```
and the document a Markdown file renders as carries no `#` in its visible
text — `text="Body line\rHeading line"` for a file holding `Body line\r\n#
Heading line`. So Windows 11's own shipped editor IS the reference editor
here, and its formatting is Markdown, which makes the SAVED FILE an
unambiguous second instrument beside the rendered font size.

The measurement — real keystrokes into the real app, in the interactive
session, with the caret put at the document's end by Ctrl+End:
```
FILE BEFORE: Body line\r\n# Heading line
mode + caret BEFORE: Line 1, Column 1 / 22 characters / … / [Formatted]
visible text BEFORE: "Body line\rHeading line"
caret at the document's END: Line 2, Column 13 / …
lines BEFORE the Return: "Body line\r" size=11 weight=400 | "Heading line" size=28 weight=400
after the RETURN: Line 3, Column 1 / 23 characters / …
after the LETTER: Line 3, Column 2 / 24 characters / …
visible text AFTER: "Body line\rHeading line\rx"
lines AFTER: "Body line\r" size=11 weight=400 | "Heading line\r" size=28 weight=400 | "x" size=11 weight=400
FILE AFTER:  Body line\r\n\r\n# Heading line\r\n\r\nx\r\n\r\n
```

**Notepad DROPS the heading.** The heading line renders at font size 28 and
the line typed after the Return renders at 11 — the body size, the same as
the unstyled first line — and the saved Markdown spells it `x`, not `# x`.
Two independent instruments, one answer.

(The file comes back with blank lines between blocks: Notepad re-serializes
the Markdown on save. Irrelevant to the question, recorded so the next reader
does not chase it.)

## The three answers

- **A.** On this lane today, a Return at the end of a heading keeps the
  heading: `13:24 block=heading1` becomes `13:26 block=heading1` across the
  newline and the letter typed after it, and the published edit carries
  `[0:2 block=heading1]`.
- **B.** A bare RichEditBox does the same and more — TOM's insertion format
  after the Return is still the heading's bold 22pt, the typed letter is bold
  22pt, and the new paragraph carries the old one's indents — so the
  "new paragraph is normal" exception would have to STRIP what the control
  inherited, on both layers, rather than lean on the platform.
- **C.** Windows 11's own Notepad, in its Formatted (Markdown) mode, DROPS
  the heading: the line after the Return renders at the body's 11pt, not the
  heading's 28pt, and saves as `x` rather than `# x`. WordPad is not on this
  build and Word is not installed; Sticky Notes has no headings.

## Files, and what was left behind

Everything of this probe's is scratch outside the repo — the job's
`tmp/richtext/return-probe/winui/` (the steps files, the drivers, the probe
project, the logs). On the VM: `C:\kaya\rtprobe`, `C:\kaya\run_rtprobe.cmd`,
`C:\kaya\legs\rtprobe`, `C:\kaya\return-probe`, `C:\kaya\editors.ps1` and the
three `kaya_cprobe*` / `kaya_rtprobe` scheduled tasks, all removed at the end
(the listing is at the foot of the job's notes file). Notepad was ALREADY
RUNNING on the VM when this probe started, with a `kaya dirty probe` tab open
from earlier work; the two tabs this probe opened were closed and that one was
left exactly as found.

The one repo file changed is `crates/kaya/src/winui/mod.rs` (`type_text`'s
`\n` branch and its doc line).

## Nothing left running

```
== every path this probe created on the VM
gone  C:\kaya\return-probe
gone  C:\kaya\rtprobe
gone  C:\kaya\legs\rtprobe
gone  C:\kaya\run_rtprobe.cmd
gone  C:\kaya\out_rtprobe.txt
gone  C:\kaya\editors.ps1
gone  C:\kaya\n-close.ps1
gone  C:\kaya\n-drive.cmd
gone  C:\kaya\n-log.txt
== processes
no probe, guest or Notepad process is running
== scheduled tasks
no scheduled task of this probe remains
== any kaya task in the Running state
no kaya task is Running
```
Notepad turned out to be THIS PROBE's process after all — its command line
carries `/SESSION:…` whose base64 decodes to
`C:\kaya\return-probe\c-notepad.md` — so it was closed with
`CloseMainWindow()`, never `taskkill /f`: the window also carried a
`kaya dirty probe` tab restored from somebody's earlier session, and Notepad
persists unsaved tabs across a graceful close. That tab was not this probe's
to discard and it was not discarded. The VM was never rebooted.
