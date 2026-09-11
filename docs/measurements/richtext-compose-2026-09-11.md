# Compose rich text — the measured probe (2026-09-11)

Feeds docs/rich-text-plan.md §3.2 (the three Compose unknowns) and the
rulings R3, R6, R7, R9. Everything below was run on ONE emulator
(`emulator-5554`, API 35, 360x800 @160dpi) against a standalone probe app
built outside the kaya tree; no file in the kaya repository was touched
and kaya's android lane was never run.

The build tree (2.1 GB: two gradle projects, a private gradle user home,
a downloaded Gradle 9.7.1 and an SDK root carrying `platforms;android-37.0`)
was deleted at the end. What survives it is 388 KB under
`…/tmp/richtext/probes/compose-artifacts/`:

- `proj-1.12.1/` — the probe app's `MainActivity.kt` plus its
  `build.gradle.kts`, `settings.gradle.kts` and manifest: foundation
  **1.12.1**, AGP 9.1.0, Gradle 9.7.1, compileSdk 37.
- `proj-1.11.4/` — the second probe: foundation **1.11.4** at kaya's own
  pins (AGP 8.7.3, Kotlin 2.0.21, compose plugin 2.0.21, compileSdk 35,
  the nix shell's Gradle 8.14.4).
- `gen.py` (writes the gradle files at given pins), `drive.py` (the driver),
  `build-kayapins.log` and `build-bumped.log` (the two verbatim build
  outputs), `shots/*.png` (every screenshot this report cites).

Driven by broadcast (`am broadcast -a dev.kayaprobe.RT --es cmd '…'`),
read back with `adb logcat -s RTPROBE:I`, typed into with
`adb shell input text`, photographed with `screencap`.

---

## 1. The pin bump: what it costs (R7)

### kaya's pins today

| what | value | where |
| --- | --- | --- |
| AGP | 8.7.3 | `android/build.gradle.kts:2` |
| Kotlin + compose compiler plugin | 2.0.21 | `android/build.gradle.kts:4-5` |
| compileSdk / buildTools / minSdk | 35 / 37.0.0 / 26 | `android/kaya/build.gradle.kts` |
| compose BOM | 2024.10.01 → **foundation 1.7.5** | `android/kaya/build.gradle.kts` |
| Gradle | 8.14.4 (nix dev shell, no wrapper) | `nix develop -c gradle --version` |
| SDK platforms available | **android-35 only** | `ls $ANDROID_HOME/platforms` |

### What foundation 1.12.1 demands

`foundation-android-1.12.1.aar!/META-INF/com/android/build/gradle/aar-metadata.properties`:

```
minCompileSdk=37
minCompileMinorSdk=0
minAndroidGradlePluginVersion=9.1.0
```

Kotlin metadata version in its classes is `mv={2,1,0}` (javap on
`TextFieldBuffer.class`), so Kotlin 2.0.21 can still *read* it — the
metadata is not the blocker. AGP and compileSdk are.

**Measured at kaya's exact pins** (`build-kayapins.log`, AGP 8.7.3 /
Kotlin 2.0.21 / compileSdk 35 / Gradle 8.14.4, `assembleDebug`): FAILS,
with 16 numbered complaints — eight artifacts (`foundation-android`,
`foundation-layout-android`, `ui-android`, `ui-text-android`,
`ui-graphics-android`, `animation-android`, `animation-core-android`,
`runtime-saveable-android`), each twice:

```
Dependency 'androidx.compose.foundation:foundation-android:1.12.1' requires libraries and applications that
depend on it to compile against version 37 or later of the Android APIs.
:app is currently compiled against android-35.
Also, the maximum recommended compile SDK version for Android Gradle plugin 8.7.3 is 35.
…
Dependency 'androidx.compose.foundation:foundation-android:1.12.1' requires Android Gradle plugin 9.1.0 or higher.
```

### What it took to make it build

`BUILD SUCCESSFUL` only after ALL of:

1. **AGP 9.1.0** (8.7.3 → 9.1.0, a major).
2. **Gradle 9.7.1** — AGP 9 will not run on Gradle 8. The nix shell ships
   8.14.4, so the probe ran a hand-downloaded distribution
   (sha256 `acd53f1e…`, matching services.gradle.org's published checksum).
3. **Dropping `org.jetbrains.kotlin.android`.** AGP 9 refuses it outright:
   > The 'org.jetbrains.kotlin.android' plugin is no longer required for Kotlin
   > support since AGP 9.0. Solution: Remove the 'org.jetbrains.kotlin.android'
   > plugin from this project's build file.

   Kotlin comes from AGP's built-in support instead, which also removes the
   `kotlinOptions`/`kotlin { compilerOptions }` route the kaya modules use
   for `jvmTarget`.
4. **`org.jetbrains.kotlin.plugin.compose` 2.3.10** (the compose compiler
   plugin still applies, but at the built-in Kotlin's version, not 2.0.21).
5. **compileSdk 37** with an **`platforms;android-37.0`** package — which the
   nix `androidsdk` derivation does not contain (`platforms/` holds
   `android-35` alone) and cannot gain at build time
   (`android.builder.sdkDownload=false`, store read-only). The probe
   installed android-37.0 into a private SDK root composed of symlinks to
   the nix one. **For kaya this is a flake.nix change, not a gradle change.**

Nothing else moved: minSdk 26, buildTools 37.0.0, JDK 17 and the API-35
emulator all stayed, and the built APK installs and runs on API 35.

### The cheaper pin nobody had priced: foundation 1.11.4

| version | minCompileSdk | minAGP | `addStyle` overloads | tracked styles |
| --- | --- | --- | --- | --- |
| 1.7.5 (kaya today) | 34 | 1.0.0 | **none** | no |
| 1.11.0 … 1.11.4 | **35** | **8.6.0** | 2 (SpanStyle, ParagraphStyle) | **no — display only** |
| 1.12.0-beta01, 1.12.0, 1.12.1 | 37 | 9.1.0 | 4 (+ TextRange/ExpandPolicy) | yes |
| 1.13.0-alpha03 | 37 | 9.1.0 | 4 | yes |

**Measured**: `proj11` — foundation **1.11.4**, AGP 8.7.3, Kotlin 2.0.21,
compose plugin 2.0.21, compileSdk 35, nix Gradle 8.14.4 — `BUILD
SUCCESSFUL`, installs, runs, and styles text. But its `addStyle` is the
display-only route: called from `TextFieldState.edit {}` it throws

```
java.lang.IllegalStateException: You can add styling to a [TextFieldBuffer]
only from an [OutputTransformation].
```

and applied from an `OutputTransformation` the runs are NOT tracked across
edits (§2 below, F2). 1.11 has no `getSpanStyles`, no `removeStyle`, no
`TrackedRange`, no `ExpandPolicy`, no `TextFieldTextStyles`.

So R7's two tiers price out as: **first-party tracked tier = 1.12.1 =
AGP 9 + Gradle 9 + compileSdk 37 + a flake change + losing the standalone
Kotlin plugin**; **synthesized tier (kaya owns the runs, Compose draws
them) = 1.11.4 = today's toolchain, no toolchain move at all**.

### One more thing 1.12 introduced: a global flag

`ComposeFoundationFlags.isBasicTextFieldStyledTextEnabled` — `true` by
default in 1.12.1 (verified two ways: `javap -c` on the class shows
`iconst_1; putstatic isBasicTextFieldStyledTextEnabled` in `<clinit>`, and
the running app logs `styledFlag=true`). It is a public `var`, and it
decides which `addStyle` means what:

- **on**: `addStyle` from any buffer scope (`state.edit`,
  `InputTransformation`, `OutputTransformation`) writes a TRACKED style
  into the state; ranges follow the text.
- **off**: `addStyle` is permitted only inside an `OutputTransformation`
  and is display-only — the 1.11 behaviour, verbatim.

A kaya arm that depends on tracked styles must therefore also depend on a
process-wide mutable flag somebody else can flip.

---

## 2. Editable styles: what the widget does to a run while you type (R3)

Setup in every case: `state.edit { addStyle(SpanStyle(fontWeight = Bold), TextRange(s, e), policy) }`,
then focus, then `select`, then `adb shell input text "…"`. Read back
through `TextFieldState.textStyles.getSpanStyles(TextRange(0, len))` and,
inside `state.edit {}`, through `getSpanStyles` + `TrackedRange.textRange`.

| # | text | run | policy | caret | typed | run after |
| --- | --- | --- | --- | --- | --- | --- |
| E2.1 | `Hello world` | [0,5) bold | AtEnd (default) | 5 | `X` | **[0,6) — inherits** |
| E2.2 | `Hello world` | [0,5) | AtEnd | 2 (inside) | `Y` | **[0,6) — inherits** |
| E2.3 | `Hello world` | [6,11) | AtEnd | 6 (its start) | `Z` | [7,12) — **does not** inherit, shifts |
| E2.4 | `Hello world` | [0,5) | InsideOnly | 5 | `Q` | [0,5) — **does not** inherit |
| E2.5 | `Hello world` | [0,5) | AtBoth | 0 | `A` | **[0,6) — inherits at the start** |
| E2.6 | `Hello world` | [0,5) | AtEnd | select [3,8), DEL | — | [0,3) — truncated |
| E2.7 | `Hello world` | [0,5) | AtEnd | select [0,5), DEL | — | **gone** (`spanCount=0`) |

The KDoc's claim that the `(SpanStyle, start, end)` overload "behaves as if
called with `ExpandPolicy.AtEnd`" is what E2.1 measures, and the policy
vocabulary is exactly four values: `InsideOnly`, `AtStart`, `AtEnd`,
`AtBoth` (`TrackedRange.kt`). The IME/key-event path makes no difference to
any of this — the expansion is decided by the tracked interval, not by the
input route.

`removeStyle` works and is addressed by handle, not by range (E2.9):

```
BUF S1 trackedCount=2 [0,5)w=700/AtEnd/valid=true [6,11)style=Italic/AtEnd/valid=true
RMSTYLE i=0 ok=true
BUF S2 trackedCount=1 [6,11)style=Italic/AtEnd/valid=true
```

**A COLLAPSED RANGE IS SILENTLY DROPPED** (E2.8) — this is the one that
bites R1. `addStyle(bold, TextRange(5,5), AtEnd)` returns a TrackedRange
that reads back as `TextRange(0, 0) policy=InsideOnly` (a dead handle), the
state's span count stays 0, and typing at 5 afterwards produces unstyled
text. **Compose has no pending-format-at-the-caret concept**: R1's "Bold
pressed on a collapsed caret is widget-local pending state" has to be
kaya's own state on this backend, held in the core and turned into a real
run when the next insertion arrives.

A style range that splits a surrogate pair is accepted verbatim (E3.4):
on `héllo 👋 world`, `addStyle(bold, TextRange(6,7))` — the high surrogate
alone — stores `[6,7)` and stays `valid=true`. No snapping outward (unlike
`TextRange` selection, which the KDoc says snaps), no refusal. kaya's
chokepoint (R2) is the only thing that will keep a run on a code-point
boundary here.

**1.11.4, the fallback tier** (F1/F2): the app holds the runs itself and an
`OutputTransformation { runs.forEach { addStyle(styleOf(it.kind), it.start, it.end) } }`
draws them. It renders correctly (`shot-1114-display.png`: "Hello" bold,
"world" blue underlined) — and after typing `XX` at offset 0 the app's runs
`[0,5)`/`[6,11)` decorate `XXHel` and `o wor` (`shot-1114-untracked.png`).
Display-only means display-only; every remap is kaya's.

---

## 3. Do style edits ride the ChangeList? (R4)

**Yes, and indistinguishably from a text edit.** `TextFieldBuffer.addStyle`
calls `changeTracker.trackChange(start, end, end - start, false)` with the
comment *"We treat it as replace the original text with newly styled
text."* (`TextFieldBuffer.kt:573-574`). Measured inside one `state.edit {}`
block (E3.1):

```
SC before changeCount=0
SC after  changeCount=1 new=TextRange(0, 5) orig=TextRange(0, 5) tr=TextRange(0, 5) valid=true
          originalText="Hello world" text="Hello world"
```

So a style-only edit is one change whose new range EQUALS its original
range — but so is a same-length text replace. E3.2 puts both in one block
(`replace(0,5,"Howdy")` then `addStyle(bold,0,5)`) and the ChangeList
coalesces them into a single `new=(0,5) orig=(0,5)`. **A reader of
`changes` alone cannot tell a format from a same-length retype**; only the
text tells them apart, and `originalText` is right there to compare
against. This is an argument FOR R4's rule (the core's own mirror is the
delta) rather than against it: the platform channel is a corroborator that
can report a phantom edit when nothing textual moved.

For a typed insertion the ChangeList is the complete delta the plan
assumes, one change per commit:

```
IN changeCount=1 new=TextRange(11, 12) orig=TextRange(11, 11)
   originalText="Hello world" newText="Hello worlda" sel=TextRange(12, 12)
```

**Offsets are UTF-16 code units.** On `héllo 👋 world` the probe logs
`len16=14 cps=13 utf8=17` (the emoji is 2 code units, 4 bytes; `é` is 1
unit, 2 bytes), and typing `K` at offset 9 — one unit past the space that
follows the emoji — reports `new=TextRange(9, 10) orig=TextRange(9, 9)`.
Byte offsets and code points are both different numbers here (9 vs UTF-8
byte 12), so R2's conversion has to happen on this backend for every
offset in both directions.

---

## 4. Links on an editable field: NO (R3)

Three routes tried, all on 1.12.1, and the 1.11.4 twin for the last one.

1. **`addStyle(LinkAnnotation…)`** — refused by the type system. The four
   overloads take `SpanStyle` or `ParagraphStyle` only
   (`TextFieldBuffer.kt:608, 642, 674, 708`); `LinkAnnotation` is an
   `AnnotatedString.Annotation`, not a style. Nothing in foundation 1.12.1's
   `text/input` package mentions `LinkAnnotation` at all (grep of the
   published sources jar: zero hits).
2. **`TextFieldBuffer.addAnnotation(annotation, start, end)`** — exists, is
   `internal` (JVM name `addAnnotation$foundation`), and is reachable only
   from an `OutputTransformation` (`checkPrecondition(canCallAddStyle)`).
   Called reflectively from an OutputTransformation with
   `LinkAnnotation.Url("https://example.com", TextLinkStyles(blue+underline))`
   over the whole text: the call SUCCEEDS
   (`LINK addAnnotation(addAnnotation$foundation) ok [0,18)`) and then
   **nothing happens** — the text renders plain
   (`shot-linkann.png`), a tap at the link's own pixels only moves the
   caret (`sel=TextRange(13, 13)`, the `LinkInteractionListener` never
   fires), and the accessibility node carries no clickable span. Same with
   the styled-text flag **off** (`shot-linkann-flagoff.png`), and same on
   **1.11.4** (`shot-1114-link.png`).
3. **The same OutputTransformation with a plain `SpanStyle`** — renders
   (`shot-outbold-flagoff.png`, "Visit" bold). So the output-annotation
   pipeline is alive and consumed; it is LINK annotations specifically that
   a text field drops.

For contrast, the identical link on a **read-only** `BasicText` in the same
app works completely: it draws blue and underlined
(`shot-ax2.png`), the tap fires (`LINK clicked on BasicText`), and its
accessibility node carries `AccessibilityClickableSpan[5,9)`.

**So on Android a link inside an editable rich field can only be a
LOOK** — `SpanStyle(color, underline)` over the run, with kaya's own hit
testing if the link must be followable while editing — and a real
`LinkAnnotation` is available only when the same document is rendered
read-only (which is exactly R8's label tier). Worth re-measuring at 1.13:
its release notes ("`TextFieldState` now saves and restores text style
information. `AnnotatedString.Annotation.Saver` is now public", b/135556699)
are the first sign that annotations are moving toward the field.

---

## 5. Undo suppression (R6)

**There is no off switch.** `UndoState` (the whole public surface) is
`canUndo`, `canRedo`, `undo()`, `redo()`, `clearHistory()` —
`UndoState.kt`; `BasicTextField` has no undo parameter, and nothing in
`TextFieldState` takes an undo policy. What is measurable:

- **`clearHistory()` works**: `canUndo=false` right after, and the native
  route then does nothing.
- **The native route is real and reachable**: with a hardware keyboard
  Ctrl+Z (`adb shell input keycombination 113 54`) the field reverted the
  typed `zz` on its own — `canUndo=true → text back to "Hello world",
  canUndo=false canRedo=true` (E5.3). Neutralising it means calling
  `clearHistory()` after every commit, which is a policy kaya can hold
  (call it in the same place `set_rich_text` and each applied edit land),
  not a flag it can set once.
- **A programmatic `edit {}` does NOT clear the history — it ADDS to it.**
  `commitEdit` records `TextFieldEditUndoBehavior.NeverMerge` whenever
  `changes.changeCount > 0` (`TextFieldState.kt:265-273`), and the probe
  sees `canUndo=true` after `setTextAndPlaceCursorAtEnd` and after every
  programmatic insert. So R6's D7 ("`set_rich_text` resets the history,
  `apply_edit` never does") is kaya's own discipline on this backend: the
  widget's default is the opposite of both halves.
- **The undo history DOES record `addStyle`** — and mangles it. From a
  clean history (E5.2): a style-only `edit {}` flips `canUndo` to true;
  `undo()` leaves the text untouched and **removes the style**
  (`spanCount 1 → 0`); `redo()` does **not** bring it back
  (`spanCount=0`, `canUndo=true` again). `TextUndoOperation` carries text
  and selection only — nothing in the undo files touches the style buffer —
  so a style edit enters the stack as a no-op text entry whose redo loses
  the formatting. **A rich field left on the native undo tier can lose a
  user's formatting to a single undo/redo round trip**, which is the
  sharpest argument in this report for R6's off switch, and here the off
  switch has to be spelled `clearHistory()`.

---

## 6. Accessibility: the styling is not exposed (R9)

Read from inside the app through the REAL node provider —
`AndroidComposeView.getAccessibilityNodeProvider().createAccessibilityNodeInfo(id)`,
walked over ids, dumping `info.text`'s concrete class and every span on it
— with TalkBack neither installed nor enabled. Field content:
`Bold LINK Head` with bold `[0,4)`, blue+underline `[5,9)`, 28sp bold
`[10,14)`; the same three runs plus a real `LinkAnnotation` on a read-only
`BasicText` above it.

```
AX id=4 cls=android.widget.TextView  textClass=android.text.SpannableStringBuilder
      text="Bold LINK Head" editable=false
      spans=ForegroundColorSpan[5,9) UnderlineSpan[5,9) StyleSpan[0,4)
            AbsoluteSizeSpan[10,14) StyleSpan[10,14) AccessibilityClickableSpan[5,9)
AX id=6 cls=android.widget.EditText  textClass=android.text.SpannableString
      text="Bold LINK Head" editable=true
      spans=                       <-- empty
```

`uiautomator dump` agrees from the outside: the EditText node's `text` is
the plain string `Bold LINK Head` and carries nothing else.

So: **a read-only Compose Text publishes its formatting to the
accessibility layer** (bold as `StyleSpan`, underline and colour as their
spans, a link as `AccessibilityClickableSpan`, which is what TalkBack reads
as "link"), **and the 1.12 editable field publishes none of it** — the
styles live in a side buffer that never reaches the semantics
`AnnotatedString`. Note also that a "heading" is `AbsoluteSizeSpan` +
`StyleSpan` on the Text tier: font size and weight, never Android's own
heading semantics (`AccessibilityNodeInfo.isHeading` /
`SemanticsProperties.Heading`), so R9's `heading` word cannot be earned on
Android by styling alone — it needs the heading semantics set by the arm.

---

## The reading, one paragraph per point

**1 (the pin bump).** Foundation 1.12.1 is not a dependency bump on this
tree, it is a toolchain migration: its own metadata demands compileSdk 37
and AGP 9.1.0, and getting there measured out as AGP 8.7.3 → 9.1.0,
Gradle 8.14.4 → 9.7.1, the standalone Kotlin Android plugin DELETED in
favour of AGP's built-in Kotlin, the compose compiler plugin re-pinned to
2.3.10, and an `platforms;android-37.0` package the nix `androidsdk` does
not ship — so flake.nix moves before gradle does. Everything else (minSdk
26, buildTools 37.0.0, JDK 17, an API-35 emulator) stayed put and the APK
ran. The unexpected result is that **foundation 1.11.4 builds on kaya's
pins exactly as they stand** and already has `addStyle`, so the
"synthesized tier" R7 named as the fallback costs nothing at all in
toolchain terms — the choice is not "bump or no rich text", it is "bump for
tracked ranges, or keep today's toolchain and own every offset".

**2 (editable styles).** With the tracked API the widget behaves the way
the plan's mirror wants: a run is a handle, typing inside it always
inherits, typing at its edges inherits or not by an explicit four-value
`ExpandPolicy` chosen per run (the default `AtEnd` gives the familiar
"typing at the end of bold stays bold, typing at its start does not"),
deleting across the end truncates, deleting the whole run drops it, and
`removeStyle` takes the handle. Two carve-outs matter for kaya: a
zero-length range is silently dropped (so a pending format at a collapsed
caret is kaya's state to hold, not the widget's), and a range that splits a
surrogate pair is stored as given without snapping or refusal, so the
boundary validation R2 promises has no help from this platform.

**3 (changes and style edits).** `addStyle` deliberately posts itself to
the ChangeList as "replace [start,end) with the same text", so style edits
ARE in `changes` and are shaped exactly like a same-length retype — and
when a text replace and a style add share one edit block the two coalesce
into one change. A typed insertion reports the clean
`new`/`originalRange` pair the plan expects, in UTF-16 code units
(`héllo 👋` puts the insertion at 9 where kaya's byte offset is 12). This
is why R4's "the core derives the delta from its own mirror" is the right
call for Compose too: the platform channel is the best of the five, and it
still cannot say by itself whether any text moved.

**4 (links).** There is no way to put a real link in an editable Compose
field in 1.12.1: `addStyle` takes styles only, the internal
`addAnnotation` accepts a `LinkAnnotation` from an `OutputTransformation`
and then renders nothing and clicks nothing (flag on or off, 1.12.1 and
1.11.4 alike), while the same annotation on a read-only `BasicText` renders
blue, is tappable and reaches accessibility as a clickable span. So a link
inside the editor is a LOOK plus kaya's own hit testing on Android, and the
honest link — drawn, tappable, announced — exists only on the read-only
tier, which is R8's slice.

**5 (undo).** Compose gives no per-field undo switch — `UndoState` is five
members and none of them is "off" — so R6's opt-out is spelled
`clearHistory()`, called after every commit, with the native Ctrl+Z route
(measured live) thereby reduced to a no-op. Two defaults run against the
plan and must be overridden deliberately: a programmatic `edit {}` ADDS an
undo entry rather than leaving the stack alone, and a style-only edit
enters the stack as a text no-op whose `undo()` silently deletes the style
and whose `redo()` never restores it — a rich field left on the native tier
can lose formatting to one undo/redo round trip.

**6 (accessibility).** Nothing about the formatting of an editable field
reaches the accessibility layer: its node is an `EditText` whose text is a
span-free `SpannableString`, while the identical content in a read-only
`BasicText` arrives as a `SpannableStringBuilder` carrying `StyleSpan`,
`UnderlineSpan`, `ForegroundColorSpan`, `AbsoluteSizeSpan` and
`AccessibilityClickableSpan`. R9's "the AX words join the closed set only
after each platform's screen reader is measured saying them" gets a firm
Android answer in advance: on the editable tier there is nothing for
TalkBack to say, and even on the read-only tier a heading is only size and
weight — Android's heading semantics is a separate property the arm must
set.

## The two caveats that matter most

1. **The typing was key events, not an IME composition.** `adb shell input
   text` injects `KeyEvent`s; a soft keyboard's `setComposingText` /
   `finishComposingText` path was never exercised, and 1.12's buffer has a
   whole composing-annotation mechanism beside the style buffer
   (`composingAnnotations`, `setComposition(start, end, annotations)`).
   Everything in §2 is decided by the tracked interval and should not
   care, but R5's queue-during-composition rule and the interaction between
   a live composing region and a style run remain unmeasured on this
   backend — that needs a test IME installed, and it is the first thing to
   probe before the Compose arm is written.

2. **Two of this report's sharpest facts sit on API that is not kaya's to
   keep.** `TextFieldBuffer.addStyle` and friends are
   `@ExperimentalFoundationApi`, and the whole tracked behaviour hangs off
   `ComposeFoundationFlags.isBasicTextFieldStyledTextEnabled` — a public,
   process-wide, mutable `var` that defaults true in 1.12.1 and can be
   flipped by any code in the process (the probe flipped it at runtime and
   watched the semantics change underneath a live field). The link finding
   is also a negative measured through reflection into an `internal`
   method: it says today's foundation will not carry a link in a field, not
   that it never will — 1.13's alpha notes point the other way, and that
   line should be re-read when the arm is written.

---

## Cleanup, proven

- `adb -s emulator-5554 shell pm list packages | grep -i kayaprobe` → empty;
  both `dev.kayaprobe.richtext` and `dev.kayaprobe.richtext11` uninstalled
  (`Success` twice), the emulator sent HOME, and the probe's `/sdcard`
  screenshots and uiautomator dumps deleted (`ls /sdcard/*.png /sdcard/w*.xml`
  → nothing).
- Both gradle daemons the probe started (9.7.1 and the nix 8.14.4, both
  registered in the probe's own GRADLE_USER_HOME) stopped with
  `gradle --stop`; `pgrep -fl GradleDaemon` now prints nothing at all.
- The build tree measured **2.1 GB** (`gh` gradle home 1.7 GB,
  gradle-9.7.1 165 MB, sdk 153 MB, proj11 56 MB, proj 39 MB) and was
  deleted; `du -sh …/probes/` is now 2.5 MB for all five probes' records.
- `adb devices` still lists emulator-5554, -5556, -5558, -5560, -5562; only
  5554 was touched, and no kaya file was modified.
