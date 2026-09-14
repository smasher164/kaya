# The heading-return probe — the MACOS lane (2026-09-14)

The ruling in front of the maintainer: with the caret at the end of a
HEADING paragraph and Return pressed, is the new paragraph a heading (kaya's
one inheritance rule: a typed byte copies the styles of the byte before it,
except `link` — crates/kaya/src/scene.rs `typed_runs`) or a normal
paragraph? Three things were measured on this platform: what kaya's mac arm
does today, what a bare NSTextView does with no kaya rules in it, and what
the platform's own editors do.

Everything below was run on swift/KayaSwiftUI.swift's `#if os(macOS)` arm
through tools/lib/lanes/mac.py's own leg env and argv, with
`KAYA_SELFTEST_SCRIPT` replaced by the probe's steps (docs/HACKING.md's Hand
tools table). The scene is tools/scenes/richtext.steps' guest,
guests/rust/richtext.rs, whose document is `"Héllo world\nSecond line"` — 24
UTF-8 bytes, the second paragraph 13:24.

## The runner's Return key, first

`type` admits `\n` as of this day (crates/kaya/src/harness.rs
`check_typing`), and the mac half now sends it as the Return KEY rather than
as the character: `characters` and `charactersIgnoringModifiers` `"\r"` on
keyCode 36, through the same per-window `NSApp.sendEvent` path the letters
take (swift/KayaSwiftUI.swift `kayaTypeAtFocus`).

MEASURED, AND THE HONEST PART: on macOS the change moves NOTHING a scene can
see. The interpreter was built from the PRE-EDIT source and driven with the
same script; every reading below is byte-identical either way, because an
NSTextView reaches `insertNewline:` from both event shapes (the bare-control
probe, §B, prints the selector each one took). The shapes differ in exactly
one place, and it is not in a text view:

```
--- default button, keyEquivalent "\r"
  window isKey=false NSApp.keyWindow=false active=false
  CR/36: through NSApp.sendEvent the button fired 0 time(s); window.performKeyEquivalent answered true (fired 1)
  LF/0: through NSApp.sendEvent the button fired 0 time(s); window.performKeyEquivalent answered false (fired 0)
```

A window's key-equivalent pass matches `"\r"` and not `"\n"`, so a scene
that ever types Return at a window with a default button would diverge; it
cannot be seen today because kaya's guests run `.accessory` and their window
is never key, so `NSApp.sendEvent` does not reach that pass at all (the
probe's own `isKey=false` line). THE GUARD: none exists — no gate and no
scene can tell the two shapes apart on this lane while that stays true.
`tools/check-verbs.py` holds the `type` verb's presence, not its key codes.
Recorded rather than papered over.

## A. kaya's arm today

### A1 — Return then a letter at the end of a heading (mac/a1-end.steps)

```
click button#0
expect_runs textarea#0 "0:6 bold|7:12 link=https://kaya.dev|13:24 block=heading2"
format textarea#0 13:24 block=heading1
expect_runs textarea#0 "0:6 bold|7:12 link=https://kaya.dev|13:24 block=heading1"
click button#5
expect_focused textarea#0
type "\nx"
expect textarea#0 "?"
expect_edit textarea#0 "?"
expect_runs textarea#0 "?"
expect label#0 "?"
expect label#1 "?"
```

The deliberately wrong expectations, and the sentences they printed:

```
KAYA_HARNESS: step-failed textarea#0 reads "Héllo world
Second line
x", wanted "?"
KAYA_HARNESS: step-failed edit "25:25 <x> user [0:1 block=heading1]", wanted "?"
KAYA_HARNESS: step-failed runs "0:6 bold|7:12 link=https://kaya.dev|13:26 block=heading1", wanted "?"
KAYA_HARNESS: step-failed label#0 reads "edit 25:25 <x> [0:1 block=heading1]", wanted "?"
KAYA_HARNESS: step-failed label#1 reads "0:6 bold|7:12 link=https://kaya.dev|13:26 block=heading1", wanted "?"
```

THE ANSWER: the new paragraph is a heading. The block run grew from 13:24 to
13:26 — over the typed newline (byte 24) AND over the letter on the new
paragraph (byte 25) — so one run now spans two whole paragraphs and the
second one is `heading1`.

AND THE WIDGET AGREES WITH THE CORE. `expect_runs` reads the core's document
and, on this arm, the storage's own runs beside it; a disagreement is
printed as `runs "<core> — but the widget holds "<widget>""`
(docs/rich-text-plan.md §7). No reading in this file carries that clause, so
NSTextView's storage spells the same runs the core does at every step.

The app's own `Document` (label#1, folded by the Rust binding from the same
deltas) spells it identically.

### A2 — the Return keystroke alone (mac/a2-return-only.steps)

Same seed, `type "\n"` with no letter after it:

```
KAYA_HARNESS: step-failed edit "24:24 <
> user [0:1 block=heading1]", wanted "?"
KAYA_HARNESS: step-failed runs "0:6 bold|7:12 link=https://kaya.dev|13:25 block=heading1", wanted "?"
```

The newline byte ITSELF carries `block=heading1`. Note what that does to the
arm's own convention: a block act "covers the selection's paragraphs WITHOUT
the trailing newline" (docs/rich-text-plan.md §7), and the inheritance rule
then puts the block back ON the newline the moment the user presses Return.
The run 13:25 ends at the document end, so nothing refuses it; the next
keystroke turns it into the two-paragraph run A1 shows.

### A3 — Return in the MIDDLE of the heading (mac/a3-mid.steps)

THIS ONE CANNOT BE DRIVEN BY THE SHARED HARNESS ON THIS LANE. `type`'s
contract point 3 moves the caret to the end of the text before sending any
key (swift/KayaSwiftUI.swift `kayaTypeAtFocus`), so a caret placed by a
collapsed `format` is gone by the time Return is sent — the control run
below, with the caret left to the contract, lands the newline at byte 24 and
reproduces A2 exactly.

So it was measured with a DOCTORED SCRATCH COPY of the interpreter, built to
the job's scratch path and never to `target/`: one substitution, printed,
making contract point 3 skip when `KAYA_PROBE_KEEP_CARET` is set. Both runs
are on the record (mac/a3-mid-control.log, mac/a3-mid-keptcaret.log); the
doctored dylib was deleted afterwards and the doctored source kept, since a
second interpreter on disk is the stale-artifact hazard this tree spends
gates on.

Steps: the seed, `format textarea#0 13:24 block=heading1`, focus, then
`format textarea#0 16:16 bold` and `format textarea#0 16:16 bold off` to
place the caret at byte 16 (inside `Second`) with nothing armed, then
`type "\n"`.

With the caret kept:

```
KAYA_HARNESS: step-failed textarea#0 reads "Héllo world
Sec
ond line", wanted "?"
KAYA_HARNESS: step-failed edit "16:16 <
> user [0:1 block=heading1]", wanted "?"
KAYA_HARNESS: step-failed runs "0:6 bold|7:12 link=https://kaya.dev|13:25 block=heading1", wanted "?"
```

BOTH HALVES STAY HEADINGS: one run, 13:25, over `Sec\nond line` — the
newline inherits the block and the splice merges the two halves back into a
single `heading1` run. Again no `but the widget holds` clause.

## B. The bare platform control, with no kaya rules

tmp/richtext/return-probe/mac/return-nstextview.swift, compiled with the
lane's `kaya_swiftc` wrapper (`-parse-as-library`): an `NSTextView` with
`isRichText`, one paragraph styled the way `kayaRestyle` draws a heading —
the body ramp scaled 1.6 and rounded, bolded through `NSFontManager`, plus
an `NSMutableParagraphStyle` — and one custom key (`kaya.rich.block`)
carried beside them. The caret goes to the end, one synthesized key, then
the letter `x`.

```
--- returnKey-keyCode36-CR
  seeded  : font=.SFNS-Semibold/21.0/bold paragraph=NSMutableParagraphStyle/headIndent=7.0 kaya.rich.block=heading1
  typing0 : font=.SFNS-Semibold/21.0/bold paragraph=NSMutableParagraphStyle/headIndent=7.0 kaya.rich.block=heading1
  selectors after the key: doCommandBySelector:insertNewline:, insertNewline:, insertText:"\n"
  text    : "Second line\n"
  typing1 : font=.SFNS-Semibold/21.0/bold paragraph=NSMutableParagraphStyle/headIndent=7.0 kaya.rich.block=heading1
  selectors after x      : insertText:"x"
  text    : "Second line\nx"
  at "x" : font=.SFNS-Semibold/21.0/bold paragraph=NSMutableParagraphStyle/headIndent=7.0 kaya.rich.block=heading1
  at "\n": font=.SFNS-Semibold/21.0/bold paragraph=NSMutableParagraphStyle/headIndent=7.0 kaya.rich.block=heading1
--- newlineChar-keyCode0-LF
  (every line identical to the block above)
```

THE ANSWER: AppKit inherits everything across a Return. `typingAttributes`
is UNCHANGED by the Return — the font, the paragraph style and a custom
attribute key all survive it — and the letter typed on the new paragraph
carries all three. The newline character carries them too.

So on macOS the proposed exception would work AGAINST the platform: to give
the new paragraph `body`, kaya's arm would have to STRIP the block attribute
(and re-derive the display from the body ramp) at the moment the Return is
seen, rather than let AppKit's own inheritance stand.

The probe also answers the routing question the runner's key path raised:
both event shapes reach `insertNewline:` through
`doCommandBySelector:insertNewline:`, and `insertNewline:` then calls
`insertText:"\n"`.

## C. The reference editors on this machine

### TextEdit — MEASURED, and it inherits

`/System/Applications/TextEdit.app`. An RTF seeded with one 21pt bold
paragraph (`\f0\b\fs42 Second line`) was opened, the caret moved to the end
of the document (Cmd+Down), Return pressed, `x` typed, the file saved and
the app quit — driven through System Events with the host idle (`HIDIdleTime`
8384s, so the maintainer was not at the machine). The file TextEdit wrote
back:

```
\f0\b\fs42 \cf0 Second line\
x}
```

`\` + newline is RTF's paragraph mark: the `x` on the new paragraph is
inside the SAME `\b\fs42` run, with no new formatting group. TextEdit
carries the styling across Return, which is §B's answer — TextEdit is an
NSTextView and has no heading concept of its own, so it is corroboration
rather than an independent reading.

(Trap for the next session: `tell application "TextEdit" to close every
document saving no` does not return here — it hung twice, once inside the
driving script and once alone under a 30s timeout. `quit` returns
immediately and takes the documents with it.)

### Apple Notes — NOT MEASURED, and why

`/System/Applications/Notes.app` is the one editor on this Mac with a real
heading style, and it was not driven:

- `tell application "Notes" to return name of default account` did not
  return inside 60s — Terminal has no Automation authorization for Notes,
  and forcing one raises an approval dialog on the maintainer's own desktop
  that only he can answer. (TextEdit and System Events are already
  authorized, which is why §C's TextEdit run worked.)
- Notes was already running on his session with its window titled
  `Search – Found 1 notes`: a state he left behind, holding his own data.
  Driving it by keystroke risks typing the probe's text into an existing
  note, which is data loss, and any note created would sync to iCloud.

SECONDARY SOURCE, LABELLED AS SUCH: Apple's own user guide page for
formatting notes on the Mac says NOTHING about what Return does after a
Title/Heading/Subheading line (fetched 2026-09-14,
https://support.apple.com/guide/notes/format-notes-not9474646a9/mac). So
there is no Apple-documented behaviour to lean on either; the question is
open on this platform until someone with the machine's own approval spends
a minute in Notes.

Pages is on this Mac too (`/Applications/Pages Creator Studio.app`, bundle
`com.apple.Pages`) and has real paragraph styles, but reading a paragraph's
style back needs either Automation authorization it also lacks or a
multi-step export dialog; not attempted.

## What this says for the ruling

- kaya on macOS today: the new paragraph is a HEADING, at the end of a
  heading and in the middle of one alike, and the core and the widget agree
  on it. The inherited block also lands on the newline byte itself, so a
  block run stops being "one paragraph without its trailing newline" the
  moment a user presses Return inside a document.
- The platform is on the side of inheritance: an NSTextView carries the
  font, the paragraph style AND an arbitrary attribute key across Return
  with no help. The exception costs this arm a deliberate strip.
- The reference editors here could not settle it: the only one that could be
  driven has no heading concept, and Apple documents nothing.

## Files

- the probes' steps and logs, the bare-control probe and the doctored
  interpreter: the job's `tmp/richtext/return-probe/mac/`
- the arm: `swift/KayaSwiftUI.swift`, `kayaTypeAtFocus` and `kayaRestyle`
- the rule: `crates/kaya/src/scene.rs`, `RichDoc::typed_runs`
