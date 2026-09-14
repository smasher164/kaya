# The heading-return probe — the iOS lane (2026-09-14)

The question Akhil asked for measurements on: with the caret at the end of a
HEADING paragraph, should Return start another heading (kaya's one-sentence
inheritance rule today — a typed byte copies the styles of the byte before it,
except `link`) or a normal paragraph (what every editor does)?

This file records what the iOS lane answers. Lane: the SwiftUI interpreter's
`#else` arm (swift/KayaSwiftUI.swift) on the simulator pool, runner
`tools/ios/run-sim.py`, hands `tools/ios/xcuidrive/KayaDrive.swift`. Device
kaya-sim-0 / kaya-sim-1 (iPhone 11 Pro, iOS 26.5, runtime 23F77); the pool was
booted before this work and nothing in it was erased, rebooted or created.

## The three answers in one line each

- **A — kaya today**: the new paragraph IS a heading, in the core's mirror and
  in the widget's own storage alike: `type "\nx"` at the end of a heading1
  paragraph leaves `13:26 block=heading1`, the block run grown over both the
  newline and the letter, with the core and the widget agreeing byte for byte.
- **B — the platform's own control**: a bare `UITextView` inherits the heading
  too. UIKit rebuilds `typingAttributes` from the character before the caret,
  so the `\n` and the `x` after it both carry the heading's 27pt semibold font
  and its paragraph style — kaya's custom key `kaya.rich.block` is the one
  thing UIKit drops. So on iOS the exception would work AGAINST the control:
  the arm would have to strip a heading the toolkit had already inherited.
- **C — the platform's reference editor**: THERE IS NONE ON THE SIMULATOR.
  Notes, Freeform, Journal and Mail are resource-only stubs in the iOS 26.5
  runtime (no executable, no Info.plist) and every launch is refused.

## The `type` verb's Return key on this lane

The charge's lane task was to make `\n` reach the control as a real Return.
**No change was needed, and that is measured rather than assumed.** The path is

    the interpreter's `case "type"` -> `kayaTypeThroughHost`
      -> `KayaSimdrive.ask("type_b64 <base64>")`
      -> run-sim.py's watcher -> `xcuidrive(udid, "type_b64 …")`
      -> the driver's `a.typeText(text)`

and the text rides it base64-framed, so a `\n` arrives at `typeText` as a real
LF byte with nothing to escape. XCUITest types it as the keyboard's Return: the
B probe's bare view recorded

    PROBE shouldChangeTextIn {22,0} replacementText="\n"

which is UIKit's own delegate call for a Return keystroke — the same call a
letter arrives through, on the same path, with no programmatic write anywhere.
`tools/ios/xcuidrive/KayaDrive.swift` is therefore unchanged by this probe.

Two things worth knowing beside it:

- The SwiftUI interpreter parses the `.steps` script ITSELF (`kayaQuoted` turns
  `\n` into U+000A), so harness.rs's `check_typing` — which learned `\n` today —
  is not in this lane's path. The iOS lane admitted `type "\nx"` already.
- `type` has no target and goes to whatever holds focus. Everything below was
  measured on a TEXTAREA; what the same `\n` does to a focused single-line
  `entry` on iOS is NOT measured here, and a Return on a single-line field is
  the keyboard's action rather than an insertion on every platform, so a scene
  that ever types one at an entry wants its own reading first.

## A. kaya's arm today

### A1 — the caret at the end of a heading paragraph

Run: `tools/ios/run-sim.py`'s own machinery through a scratch copy that narrows
the rust-swiftui suite to `richtext` and swaps the scene script for the one
below (the copy also refuses to erase a pool device and skips the LocalStorage
admission, which this leg does not need). Leg `richtext-swiftui` on kaya-sim-0.

Script (`a1-end-of-heading.steps`):

    click button#0
    expect_runs textarea#0 "0:6 bold|7:12 link=https://kaya.dev|13:24 block=heading2"
    format textarea#0 13:24 block=heading1
    expect label#0 "format 13:24 block=heading1"
    expect_runs textarea#0 "0:6 bold|7:12 link=https://kaya.dev|13:24 block=heading1"
    click button#5
    expect_focused textarea#0
    type "\nx"
    expect_runs textarea#0 "?A-RUNS-AFTER-RETURN?"
    expect_edit textarea#0 "?A-EDIT-AFTER-RETURN?"
    expect label#0 "?A-LABEL0-LAST-DELTA?"
    expect label#1 "?A-LABEL1-APP-DOCUMENT?"
    expect textarea#0 "?A-TEXT?"

The document is "Héllo world\nSecond line" in UTF-8 bytes; its second
paragraph is 13:24, and `format textarea#0 13:24 block=heading1` makes that
paragraph a heading1 through the widget's own act. The last five steps assert
deliberately wrong strings so the harness prints what it read.

What the harness printed, in one verdict (leg `richtext-swiftui`, FAIL by
construction, 78s — five deliberately wrong expects each spend the 15s step
deadline):

    KAYA_SELFTEST: FAILED (runs "0:6 bold|7:12 link=https://kaya.dev|13:26 block=heading1", wanted "?A-RUNS-AFTER-RETURN?"; edit "25:25 <x> user [0:1 block=heading1]", wanted "?A-EDIT-AFTER-RETURN?"; label#0 reads "edit 25:25 <x> [0:1 block=heading1]", wanted "?A-LABEL0-LAST-DELTA?"; label#1 reads "0:6 bold|7:12 link=https://kaya.dev|13:26 block=heading1", wanted "?A-LABEL1-APP-DOCUMENT?"; textarea#0 reads "Héllo world
    Second line
    x", wanted "?A-TEXT?")

Everything before those five passed, including `format 13:24 block=heading1`,
`expect label#0 "format 13:24 block=heading1"` and
`expect_runs … "…|13:24 block=heading1"`, so the document really was a heading1
paragraph when Return was pressed.

The driver's own record of the keystrokes (one `typeText` for both characters,
`Cng=` is base64 for `"\nx"`):

    1789411282.144 verb `type_b64 Cng=`
    1789411282.160 got a keyboard for the app after 0.02s of 45s
    1789411282.176 typing into the app: safe, focused=<not asked> keyboards=1
    1789411282.470 verb `type_b64` -> ok in 0.33s

**The new paragraph is a heading, on both sides of the corroboration.**

- `13:24 block=heading1` became `13:26 block=heading1`: byte 24 is the `\n`
  itself and byte 25 is the `x`, and the block run covers both.
- The `runs` sentence carries ONE reading. `expect_runs` prints
  `runs "<core> — but the widget holds "<widget>""` whenever the widget's own
  storage disagrees with the core's mirror, so a single reading means the
  UITextView's `kaya.rich.block` attributes say exactly what the core says.
  The heading is inherited in the widget as well as in the model.
- The edit published for the letter is `25:25 <x> user [0:1 block=heading1]` —
  the byte typed AFTER the Return carries the heading. The Return was its own
  earlier edit (one keystroke, one edit), which `expect_edit` reads as the last
  one published.
- The app's own `Document`, folded by the binding from the same deltas
  (`label#1`), spells the identical string.

A capture taken while the leg ran (`ios-a1-end-of-heading.png` in the job's
scratch, since this probe adds no files to the tree) shows the same thing on
the screen: "Second line" and the new "x" paragraph are drawn at the same
heading size, with the app's own two labels under them reading
`edit 25:25 <x> [0:1 block=heading1]` and
`0:6 bold|7:12 link=https://kaya.dev|13:26 block=heading1`.

### A2 — the caret inside the heading

THE CHARGE'S RECIPE CANNOT BE DRIVEN BY THE `type` VERB, on either Apple arm.
Contract point 3 says typing APPENDS, and `kayaTypeThroughHost` enforces it by
setting `input.selectedTextRange` to the end of the document before every
`type` (the mac's `kayaTypeAtFocus` sets `responder.selectedRange` the same
way, for the same stated reason: macOS selects a field's whole contents at
first responder, so keys would REPLACE). So `format textarea#0 16:16 bold`
followed by `type "\n"` types the newline at the END, not at byte 16.

The measurement was taken with the same keystroke delivered the same way,
around the verb instead of through it: the scene places the caret with a
collapsed `format`, then sits in a `settle`, and the host asks the SAME
resident driver for the SAME `type_b64` of `"\n"` while it sits there. It is
the identical key path — `XCUIApplication.typeText`, the simulator's keyboard,
UIKit's `insertText` — with only the interpreter's caret reset left out.

Script (`a2-mid-heading.steps`), the injection fired 12s after launch:

    click button#0
    expect_runs textarea#0 "0:6 bold|7:12 link=https://kaya.dev|13:24 block=heading2"
    format textarea#0 13:24 block=heading1
    click button#5
    expect_focused textarea#0
    format textarea#0 16:16 bold
    format textarea#0 16:16 bold off
    settle 20000
    expect_runs textarea#0 "?A2-RUNS-AFTER-MID-RETURN?"
    expect_edit textarea#0 "?A2-EDIT-AFTER-MID-RETURN?"
    expect textarea#0 "?A2-TEXT?"

Byte 16 is the `o` of "Second", mid-word and mid-paragraph. The two collapsed
formats put the caret there and leave `bold` PENDING-OFF, so the newline
carries the paragraph's own attributes and nothing borrowed from the probe.

The verdict (leg `richtext-swiftui`, FAIL by construction, 68s); the `<` and
`>` hold the inserted newline, so the sentence is split across three lines:

    hand-sim: inject: attach ok=True state=4 frame=0,0,375,812 | type_b64 ok=True typed 1 character(s)
    KAYA_SELFTEST: FAILED (runs "0:6 bold|7:12 link=https://kaya.dev|13:25 block=heading1", wanted "?A2-RUNS-AFTER-MID-RETURN?"; edit "16:16 <
    > user [0:1 block=heading1]", wanted "?A2-EDIT-AFTER-MID-RETURN?"; textarea#0 reads "Héllo world
    Sec
    ond line", wanted "?A2-TEXT?")

and the driver's own line for the keystroke (`Cg==` is base64 for `"\n"`):

    1789411496.925 verb `type_b64 Cg==`
    1789411496.940 got a keyboard for the app after 0.02s of 45s
    1789411496.955 typing into the app: safe, focused=<not asked> keyboards=1
    1789411497.232 verb `type_b64` -> ok in 0.31s

**Both halves stay headings.**

- The newline landed where the caret was: `edit "16:16 <\n> user"`, mid-word,
  and the text is now `"Héllo world\nSec\nond line"`.
- The typed byte inherits: the edit's own runs are `[0:1 block=heading1]`, so
  the `\n` IS a heading1 byte. (`bold` is absent, which is the pending-off
  half of the same rule working.)
- The block run went `13:24` -> `13:25`: it grew by the newline and still
  spans the whole of what is now two paragraphs, so "Sec" and "ond line" are
  both heading1 — the core's runs are byte ranges, and a paragraph split does
  not divide them.
- Again one reading, no `— but the widget holds …`: the UITextView agrees.

The capture `ios-a2-mid-heading.png` (job scratch) shows it on screen: the
heading is split into "Sec" and "ond line", both at heading size, with the app
reading `edit 16:16 <\n> [0:1 block=heading1]` and
`0:6 bold|7:12 link=https://kaya.dev|13:25 block=heading1`.

**Why this matters to the ruling.** A "Return starts a body paragraph"
exception has to be an END-OF-PARAGRAPH rule. The same rule applied to a caret
INSIDE a heading would take the heading off the tail that moves down — "ond
line" would become body while "Sec" stayed a heading — which is not what any
editor does either. So the exception, if it is taken, is a rule about the
inserted newline at the END of a block run, not about newlines generally.

## B. The platform's own control, without kaya's rules

`ReturnProbe.app`, a minimal simulator bundle on the 2026-09-11 iosprobe shape
(docs/measurements/richtext-apple-2026-09-11/iosprobe): one bare `UITextView`,
TextKit 2, first responder, with the arm's plain-text pins on
(`autocorrectionType = .no`, `smartQuotesType = .no`,
`allowsEditingTextAttributes = false`) and NOTHING of kaya's in it — no
`kayaRearmTyping`, no restyle, no delegate that writes attributes.

The document is `"Body line\nHeading line"` with the second paragraph styled
exactly as `kayaRestyle`'s heading1 branch draws it — base body font 17pt,
size `(17 * 1.6).rounded()` = 27pt, bold, `.label`, a fresh
`NSMutableParagraphStyle` — plus the arm's own `kaya.rich.block = "heading1"`
key over the same range, so the custom key can be watched surviving or not.

The caret starts at the end of the heading paragraph. The Return and the letter
after it are REAL keystrokes from the resident XCUITest driver
(`attach dev.kayaprobe.returnprobe`, then `type_b64` of `"\n"` and of `"x"`).

Seeded:

    PROBE runs of the seeded document: length=22 string="Body line\nHeading line"
    PROBE   [0,10) "Body line\n" -> NSColor=rgba(0.00,0.00,0.00,1.00) NSFont=.SFUI-Regular/17.0
    PROBE   [10,22) "Heading line" -> NSColor=rgba(0.00,0.00,0.00,1.00) NSFont=.SFUI-Semibold/27.0[bold] NSParagraphStyle=NSParagraphStyle(align=4 headIndent=0.0 firstLineHeadIndent=0.0 paragraphSpacing=0.0) kaya.rich.block="heading1"
    PROBE typingAttributes at the caret (end of the heading paragraph) = NSColor=rgba(0.00,0.00,0.00,1.00) NSFont=.SFUI-Semibold/27.0[bold] NSParagraphStyle=NSParagraphStyle(align=4 headIndent=0.0 firstLineHeadIndent=0.0 paragraphSpacing=0.0)

The Return:

    PROBE shouldChangeTextIn {22,0} replacementText="\n"
    PROBE --- textViewDidChange #1
    PROBE   text="Body line\nHeading line\n"
    PROBE   typingAttributes NOW = NSColor=rgba(0.00,0.00,0.00,1.00) NSFont=.SFUI-Semibold/27.0[bold] NSParagraphStyle=NSParagraphStyle(align=4 headIndent=0.0 firstLineHeadIndent=0.0 paragraphSpacing=0.0)
    PROBE   [22,23) "\n" -> NSColor=rgba(0.00,0.00,0.00,1.00) NSFont=.SFUI-Semibold/27.0[bold] NSParagraphStyle=NSParagraphStyle(align=4 headIndent=0.0 firstLineHeadIndent=0.0 paragraphSpacing=0.0)

The letter after it:

    PROBE shouldChangeTextIn {23,0} replacementText="x"
    PROBE --- textViewDidChange #2
    PROBE   text="Body line\nHeading line\nx"
    PROBE   [22,24) "\nx" -> NSColor=rgba(0.00,0.00,0.00,1.00) NSFont=.SFUI-Semibold/27.0[bold] NSParagraphStyle=NSParagraphStyle(align=4 headIndent=0.0 firstLineHeadIndent=0.0 paragraphSpacing=0.0)

Read it as three facts:

1. **UIKit inherits the heading across Return.** The new paragraph's font is
   `.SFUI-Semibold/27.0[bold]` — the heading's, not the body's 17pt regular —
   and it carries the heading's paragraph style too. Nothing in the probe put
   it there: `typingAttributes` is UIKit's own re-derivation from the character
   before the caret, and the character before the caret is the heading's last.
2. **The custom key does not survive.** `kaya.rich.block` is on the heading run
   and on NEITHER the `\n` nor the `x`. This is the 2026-09-11 breadth
   finding — UIKit rebuilds `typingAttributes` from the neighbour and carries
   only its OWN keys, where AppKit carries the whole dictionary — measured
   again here on a view with no kaya code in it at all, which is why the iOS
   arm derives kaya's keys itself in `kayaRearmTyping`.
3. So on iOS the two candidate rulings are not symmetric in cost. Keeping the
   heading is what the toolkit does by itself. Making the new paragraph body
   means the arm must ACT — reset the font, the colour and the paragraph style
   that UIKit already inherited — at exactly the moment the core says the new
   byte is body. It is perfectly doable (`kayaRearmTyping` is already the one
   place that owns typing attributes and already fights UIKit's NSLink there),
   but it is a strip, not an omission.

Log: the job's `tmp/richtext/return-probe/ios/probe-b.log`; the probe's source
is `tmp/richtext/return-probe/ios/probe/main.swift`.

## C. The reference editor on this platform

**Notes is not on the iOS simulator, and neither is any other flagship rich
editor.** Measured three ways on the iOS 26.5 runtime (23F77):

- `xcrun simctl listapps` on kaya-sim-0 lists 25 `com.apple.*` bundles —
  Safari, Maps, Health, Reminders, Files, Preview, Shortcuts and so on — with
  no Notes, Freeform, Journal, Mail or Pages among them.
- In the runtime root's `Applications/`, `MobileNotes.app` holds only
  `Extensions` and `PlugIns` (plus `.lproj` resources): no executable and no
  `Info.plist`. `Freeform.app`, `Journal.app` and `MobileMail.app` are the same
  kind of stub. `MobileSafari.app`, for contrast, is a real bundle with an
  executable, an `Info.plist` and `Assets.car`.
- Launching them is refused:

      com.apple.mobilenotes -> An error was encountered processing the command (domain=FBSOpenApplicationServiceErrorDomain, code=4):
      Simulator device failed to launch com.apple.mobilenotes.

  and the same for `com.apple.freeform`, `com.apple.Journal` and
  `com.apple.mobilemail`.

So the iOS half of question C cannot be answered on this lane's hardware. What
CAN be said from iOS, and is section B above, is what the platform's own
CONTROL does with no editor's policy on top of it: it inherits. Apple's own
answer for Notes therefore lives in Notes' own code, not in UIKit — and the mac
lane's TextEdit/Notes reading is the one that can speak to it.

## Two things the ruling will want to know

1. **Nothing guards the `\n` key path on any lane today.** No scene types a
   newline, so a runner whose Return stopped being a Return would leave every
   lane green. Whichever way the ruling goes, a Return step in
   tools/scenes/richtext.steps IS that guard, on all five lanes at once, and
   until there is one this file is the only proof the path works.
2. **Contract point 3 keeps the mid-paragraph case out of reach of a shared
   scene.** `type` moves the caret to the end of the document before typing on
   both Apple arms, so no .steps file can assert a Return INSIDE a paragraph.
   If the ruling needs that case asserted rather than merely measured, the
   harness wants either a verb that types where the caret is or a rule that a
   preceding collapsed `format` pins it. Nothing here touched that contract.

## How it was run, and what it left behind

The lane's own runner does all of this; only two things about it are hand-made.
A scratch copy of `tools/ios/run-sim.py` (generated by a script that prints the
count of every substitution and refuses an unchanged file) narrows the
rust-swiftui suite to `richtext`, takes the scene script from an environment
variable, can ask the resident driver for one keystroke mid-leg, SKIPS the
LocalStorage admission this leg does not need and REFUSES to erase a pool
device. Nothing in the repo was edited for it. The probe bundle for section B
is its own minimal `.app` under a `dev.kayaprobe.` id — deliberately not
`dev.kaya.`, since the lane's device preparation uninstalls and refuses those.

Verification, every exit code named:

| command | rc |
| --- | --- |
| `tools/swift-typecheck.sh` | 0 (6 passes; the 5th is the interpreter under the iphonesimulator SDK, the 6th is the XCUITest driver) |
| `tools/check-doc-refs.py` | 0 |
| the unmodified `richtext` scene on the iOS lane | `richtext-swiftui: PASS (4s)`, `run-sim: ALL PASS` |
| the A1 leg (five deliberately wrong expects) | FAIL by construction, 78s |
| the A2 leg (three deliberately wrong expects) | FAIL by construction, 68s |
| the B probe | launch rc 0, `PROBE DONE` |

Left behind: nothing running (`run-sim: xcui drivers stopped (2); runner
processes left: none` on every leg run), the probe app uninstalled from
kaya-sim-1 and the leg's bundle from kaya-sim-0, no simulator erased, rebooted
or created, and no file added to the tree but this one.
