# The heading-return probe — the Compose lane (2026-09-14)

Akhil's ruling question: with the caret at the END of a HEADING paragraph, a
Return — does the new paragraph stay a heading (kaya's one-sentence
inheritance rule: a typed byte copies the styles of the byte before it,
except `link`) or become a normal paragraph (what editors do)? Measured, not
recalled. Machine: `emulator-5554` from the android lane's warm pool
(API 35, 360x800 @160dpi), against the tree's own `dev.kaya.rusthost` APK
built by `tools/android/run-emulator.py`.

Three answers up front:

- **A — kaya today, on this lane:** the new paragraph IS a heading, in both
  positions. At the END of the heading the block run extends over the Return
  AND over the letter after it (`13:24 block=heading1` -> `13:26
  block=heading1`); MID-heading the Return splits nothing — the one run
  widens to cover the inserted newline, so both halves stay heading. The
  arm's own table agreed with the core at every read (no `— but the widget
  holds` clause anywhere).
- **B — a bare BasicTextField, no kaya rules:** the control carries NOTHING.
  At kaya's pin (foundation 1.11.4) `addStyle` outside an
  `OutputTransformation` throws by name, and `TextFieldState` has no style,
  span or annotation member at all — so whether the new paragraph looks like
  a heading is decided ENTIRELY by the arm's own run table, in both
  directions, photographed below. The Return itself is one ordinary
  insertion (`new=TextRange(12, 13) orig=TextRange(12, 12)`), it moves the
  caret onto the new line, and it COMMITS a live composing region first.
- **C — the platform's reference rich editor:** there is none on the image —
  no Google Keep, no stock notes app, no Docs editor (the 24 launchable
  activities are listed below). The nearest reference actually on the device
  is the Android System WebView's own editing engine (Chromium
  124.0.6367.219), and Blink DISCRIMINATES: Return at the END of an `<h1>`
  opens a `<div>` — a normal paragraph — while a MID-heading Return splits it
  into two `<h1>`s.

---

## 0. Setting up: the lane's `type` verb already spells Return

`crates/kaya/src/harness.rs`'s `check_typing` admits `\n` as of today, and
Stage's contract point 6 names it. **The Compose key path needed no change,
and that was measured rather than assumed.**

`kayaTypeAtFocus` (KayaCompose.kt) maps every character through
`KeyCharacterMap.load(VIRTUAL_KEYBOARD).getEvents(charArrayOf(c))` and
rebuilds each event with `SOURCE_KEYBOARD` before `activity.dispatchKeyEvent`,
one UI-thread hop per character. A temporary log inside that loop (a scratch
perturbation, restored and `shasum`-verified — see §4) printed, for
`type "\nx"`, exactly:

```
KAYA_PROBE_KEYS: char=10 -> 0/66/0,1/66/0
KAYA_PROBE_KEYS: char=120 -> 0/52/0,1/52/0
```

`action/keyCode/metaState`: 66 is `KEYCODE_ENTER`, 52 is `KEYCODE_X`. So the
newline is already an ACTION_DOWN/ACTION_UP pair on the Return key, with no
modifiers, dispatched down the same path, in the same loop, in the same order
as the letters — contract points 1 and 5. The field's text then reads

```
textarea#0 reads "Héllo world
Second line
x", wanted "PROBE"
```

— the verdict line breaking at the newline is itself the proof the key
inserted U+000A and not a space.

**THE GUARD THIS NON-CHANGE NAMES.** `kayaKeyLanded`, the retry that re-sends
a key nothing consumed, keys on the FIELD'S OWN LENGTH growing by one. That
holds for Return in a `textarea` (`TextFieldLineLimits.MultiLine`) and NOT in
an `entry` or `search` field (`SingleLine`), where Enter fires the IME action
and inserts nothing: `type "\n"` at a single-line field would dispatch ENTER
ten times and then log `KAYA_UNDO_TRACE: the keystroke … was dispatched 10
times and the focused field's text never moved`. No scene does that today and
none of tools/scenes types a newline into a single-line field. Two walls are
possible and neither is this charge's file: a `check_steps` clause refusing
`type` with a `\n` at a non-textarea target, and the cross-backend one the
WinUI record also asks for — nothing checks that every backend's `type` path
can deliver every character `check_typing` admits. **Reported for the
coordinator.**

---

## A. kaya's arm today

The guest is `guests/rust/richtext.rs`, the scene's own; the document is
`"Héllo world\nSecond line"`, 24 bytes, the second paragraph 13:24. Every
script below was handed to the app through
`am start … --es KAYA_SELFTEST richtext --es KAYA_SELFTEST_SCRIPT '<folded>'`
(docs/HACKING.md's hand-run row), the wrong expectation being the instrument:
the failure sentence carries the reading.

### A1 — Return at the END of a heading paragraph

```
click button#0
format textarea#0 13:24 block=heading1
click button#5
expect_focused textarea#0
type "\nx"
expect_runs textarea#0 "PROBE"
expect_edit textarea#0 "PROBE"
expect textarea#0 "PROBE"
```

Verbatim verdict, on the tree's own build:

```
KAYA_SELFTEST: FAILED (runs "0:6 bold|7:12 link=https://kaya.dev|13:26 block=heading1", wanted "PROBE";
 edit "25:25 <x> user [0:1 block=heading1]", wanted "PROBE";
 textarea#0 reads "Héllo world
Second line
x", wanted "PROBE")
```

Read it: the heading's block run was `13:24` before the Return and is `13:26`
after the Return AND the letter — **the newline byte itself took the heading,
and so did the `x` after it**. The edit the core published for the typed
letter carries `[0:1 block=heading1]`: the new paragraph's first real
character is a heading character. **The new paragraph is a heading.**

`expect_runs` printed no `— but the widget holds "…"` clause, which is the
arm's own table agreeing with the core's mirror byte for byte (the
corroboration wall of docs/rich-text-plan.md §8). No `KAYA_DIAG` beyond the
step-failed echoes.

### A2 — Return INSIDE the heading paragraph

Contract point 3 (`type` APPENDS: the caret is collapsed to the end before
the keys) makes this case undrivable through `type` as the harness ships, so
it was measured under a scratch perturbation: the collapse in
`kayaTypeAtFocus` put behind a `KAYA_PROBE_NO_APPEND` env check, the build
run once, the file restored from a copy and `shasum`-verified (§4). Nothing
else in the file moved, and the ordinary `richtext-compose` leg passed on
that same doctored build.

```
click button#0
format textarea#0 13:24 block=heading1
click button#5
expect_focused textarea#0
format textarea#0 16:16 bold      # a collapsed format: this is how the caret is placed
type "\n"
expect_runs textarea#0 "PROBE-AFTER-RETURN"
type "z"
expect_runs textarea#0 "PROBE-AFTER-LETTER"
expect_edit textarea#0 "PROBE-EDIT"
```

Byte 16 is inside `"Second line"` (between `Sec` and `ond line`). Verbatim:

```
runs "0:6 bold|7:12 link=https://kaya.dev|13:25 block=heading1|16:17 bold", wanted "PROBE-AFTER-RETURN"
runs "0:6 bold|7:12 link=https://kaya.dev|13:26 block=heading1|16:18 bold", wanted "PROBE-AFTER-LETTER"
edit "17:17 <z> user [0:1 block=heading1|0:1 bold]", wanted "PROBE-EDIT"
```

**Both halves stay headings**: `13:24` widened to `13:25`, one run spanning
the newline and the text on either side of it. There is no split and no
second run — a block attribute is a byte range in the mirror, not a
per-paragraph object, so a Return inside it is just another inherited byte.

The pending `bold` from the collapsed format rode the NEWLINE (`16:17 bold`)
and then the `z` after it (`16:18 bold`), which is the same inheritance rule
one attribute over: **the Return character is a character, and it carries
runs.** Worth saying out loud for the ruling — an exception phrased as "the
paragraph AFTER a Return does not inherit" still has to say what the newline
byte itself carries.

---

## B. The platform's own control, without kaya's rules

`BasicTextField` + `OutputTransformation` IS kaya's own construction — the
Compose arm's display is the arm's run table drawn through the field's
transformation, and nothing native inherits. So what follows measures the
closest thing the platform offers, on a standalone probe app at kaya's exact
pins (foundation 1.11.4, AGP 8.7.3, Kotlin 2.0.21, compileSdk 35 — the same
project shape as docs/measurements/richtext-compose-2026-09-11.md's), no kaya
code in it, driven by broadcast and real `input keyevent 66`.

### B1 — the editable tier carries no styles at all

Reflecting over the two classes for any member naming style, span, annotation,
rich or attribute:

```
SURFACE androidx.compose.foundation.text.input.TextFieldState -> getMainBuffer$foundation$annotations,getUndoState$annotations
SURFACE androidx.compose.foundation.text.input.TextFieldBuffer -> addAnnotation$foundation,addStyle,canCallAddStyle,composingAnnotations,composingAnnotations$lambda$0,getCanCallAddStyle$foundation,getChanges$annotations,getComposingAnnotations$foundation,getOutputTransformationAnnotations$foundation,outputTransformationAnnotations,setCanCallAddStyle$foundation,setOutputTransformationAnnotations$foundation
```

The STATE has nothing. The BUFFER has `addStyle` — and a `canCallAddStyle`
flag beside `outputTransformationAnnotations`, which says where those styles
live. Asked for real inside `state.edit {}`:

```
STYLEDIT2 addStyle inside state.edit threw java.lang.IllegalStateException:
  You can add styling to a [TextFieldBuffer] only from an [OutputTransformation].
```

**Nothing but the arm's table could carry a style across the Return**, because
at this pin nothing but the transformation may carry a style at all. (The
2026-09-11 record measured the same wall from the other side: at 1.12.1 a
tracked `addStyle` with `ExpandPolicy.AtEnd` DOES expand over an insertion at
its end — E2.1/E2.2 — so a future pin would give the character half of the
inheritance rule natively, with `AtEnd` the policy that agrees with kaya's
rule and `InsideOnly` the one that would not. kaya is not on that pin.)

### B2 — what the field does with the Return, the caret and the composition

Text `"Heading line"`, the app's run `[0,12) heading` (a `SpanStyle` of
1.6 em + bold and a `ParagraphStyle`, which is how the arm draws heading1),
caret at 12, then a real `input keyevent 66` and then `z`:

```
DUMP before      text="Heading line"     len16=12 sel=TextRange(12, 12) composition=null canUndo=false appRuns=[0,12)heading
IN changeCount=1 new=TextRange(12, 13) orig=TextRange(12, 12) originalText="Heading line" newText="Heading line\n" sel=TextRange(13, 13)
DUMP afterReturn text="Heading line\n"   len16=13 sel=TextRange(13, 13) composition=null canUndo=true  appRuns=[0,12)heading
IN changeCount=1 new=TextRange(13, 14) orig=TextRange(13, 13) originalText="Heading line\n" newText="Heading line\nz" sel=TextRange(14, 14)
DUMP afterLetter text="Heading line\nz"  len16=14 sel=TextRange(14, 14) composition=null canUndo=true  appRuns=[0,12)heading
```

The Return is ONE change of one code unit, the caret follows it onto the new
line, no composition is opened or closed, and **the app's run is untouched by
anything the control did** — `[0,12) heading` before and after. The control
has no opinion about the new paragraph; the table decides, and both answers
are drawable:

- run left at `[0,12)` — stops at the Return — `b-run-stops-at-return.png`:
  "Heading line" large and bold, `z` at body size on the line under it.
- run extended to `[0,14)` — kaya's rule, covering the Return and the typed
  letter — `b-run-covers-return.png`: `z` drawn large and bold, the second
  paragraph reading as a heading.

(The two shots live in the job's own scratch directory for this probe,
outside the tree.) So the visual difference
the ruling decides is entirely a difference in the run table's end offset.
One detail for whoever writes the exception: a `ParagraphStyle` added over
`[0,12)` makes the styled range its own paragraph, so a run that stops BEFORE
the newline already draws the new paragraph unstyled — no second mechanism is
needed on this backend to make the exception visible.

### B3 — a Return with a live composing region

The composition can only be opened through the connection the compose view
hands out (no adb route opens one — 2026-09-11 §5), and a region left open
across a UI turn is reset by the live keyboard. Opened and the Return sent
down the SAME connection in one turn, which is what an IME does:

```
IN changeCount=1 new=TextRange(12, 14) orig=TextRange(12, 12) originalText="Heading line" newText="Heading lineab" sel=TextRange(14, 14)
CR composing=TextRange(12, 14) text="Heading lineab"
CR after-return composing=TextRange(12, 14) text="Heading lineab" sel=TextRange(14, 14)
IN changeCount=1 new=TextRange(14, 15) orig=TextRange(14, 14) originalText="Heading lineab" newText="Heading lineab\n" sel=TextRange(15, 15)
DUMP after text="Heading lineab\n" len16=15 sel=TextRange(15, 15) composition=null canUndo=true appRuns=[0,12)heading
```

**The Return ENDS the composition and then inserts**, as a change of its own
after the committed text — it never splits the marked region. So an exception
that reads the byte before the caret is reading committed text by the time it
runs, which is what R5 already assumes.

---

## C. The reference editor on the platform: there is none on this image

Every launchable activity on `emulator-5554`
(`cmd package query-activities -a android.intent.action.MAIN -c
android.intent.category.LAUNCHER`, 24 of them): camera2, chrome, settings,
`com.google.android.apps.docs` (Drive's storage app — the Docs EDITOR,
`…docs.editors.docs`, is not installed), maps, messaging, photos, youtube
music, calendar, contacts, deskclock, dialer, gm, youtube, stk, safetyhub,
documentsui, two googlequicksearchbox entries, and kaya's own five hosts.
**No Google Keep. No stock notes app. No word processor.** `pm list packages`
matching `keep|note|docs|word|office|memo|writer` returns only
`com.android.role.notes.enabled` (a role-holder stub, not an app) and Drive.
Nothing was installed to change that: the pool is the lane's.

What IS on the device, and is the engine most rich editors on Earth run on,
is the Android System WebView — **Chromium 124.0.6367.219**, read from
`WebView.getCurrentWebViewPackage()`. Blink's `contenteditable` was driven in
it with real key events (`input keyevent 66`), the caret placed through the
platform's own Selection API, the answer read back as `innerHTML`. This is
labelled for what it is: the platform's web editing engine, not a notes app.

Page: `<div contenteditable><h1 id=h>Heading line</h1><p>Body line</p></div>`.

**Return at the END of the heading**, then `q`:

```
before: "\n<h1 id="h">Heading line</h1>\n<p>Body line</p>\n"
after : "\n<h1 id="h">Heading line</h1><div>q</div>\n<p>Body line</p>\n"
caret : "caret now in <DIV>"
```

**Return INSIDE the heading** (after `Head`), then `q`, on a fresh page:

```
after : "\n<h1 id="h">Head</h1><h1 id="h">qing line</h1>\n<p>Body line</p>\n"
```

So Blink does BOTH things, and the position is what tells them apart: a
mid-paragraph Return SPLITS the heading and both halves stay `<h1>`; a Return
at the END of the heading opens a NEW, PLAIN block (`<div>`, the
`defaultParagraphSeparator`) and the letter typed after it is body text.
That is exactly the discrimination Akhil's question is about, from the one
reference implementation this machine actually has — and kaya's A2 already
agrees with Blink on the mid-paragraph half.

---

## 4. Nothing left behind, shown

- **The tree.** `android/kaya/src/main/kotlin/dev/kaya/KayaCompose.kt` was
  doctored twice (the keycode log; the `KAYA_PROBE_NO_APPEND` collapse
  bypass), each time restored from a copy taken before the first edit, never
  by `git checkout`. Its sha256 is
  `e0b74ac51d5b9c2751962f69a78a4015994cf08fc1e2c5592826270bec70f8a4`, equal to
  the copy's, and `git status --porcelain` names no file of this lane's. This
  record is the only file this probe adds to the tree.
- **The gates, after the restore.** `KAYA_ONLY=richtext
  tools/android/run-emulator.py compose` -> **rc 0**, `richtext-compose: PASS`,
  `run-emulator: ALL PASS` (the APK rebuilt from the restored source and
  restaged on all five devices); `tools/check-compose.py` -> **rc 0**,
  `check-compose: OK`.
- **The emulators.** The five of the lane's warm pool, all pre-existing
  (`emulator-5554/5556/5558/5560/5562`); this probe started none and stopped
  none. `pm list packages -3` on 5554 lists kaya's five hosts and nothing
  else — the probe app `dev.kayaprobe.rt2` was uninstalled (`Success`), and
  its four screencaps were removed from `/sdcard`.
- **Disk.** The probe's gradle build tree was 57 MB (it reused the shell's
  gradle caches rather than a private home, so it cost no download); deleted.
  What survives is 32 KB of probe sources plus 200 KB of screenshots in the
  job's own scratch directory for this probe, which totals 960 KB.
