# Rich text — the design pass (rulings TAKEN 2026-09-11)

The maintainer's ask, 2026-09-11: rich text editing, in the text editor
the tree already has (docs/editor-plan.md) as a pane or a toggle, toward
a CRDT-backed notes app one day. That last clause shapes everything
below: the document must be able to belong to the app, so the widget
must speak in edits, not in whole strings. Two surveys are the record:
docs/probes/richtext-platforms-2026-09-11.md (what each platform's
control can express and how it reports edits) and
docs/probes/richtext-crdt-2026-09-11.md (the Rust CRDT crates' edit
shapes, units and bindings, and the widget protocol they need). Every
number and claim here points at one of them or at a file in the tree.

The maintainer took R1-R9 as recommended the same day ("run all the
probes you need. im a little out of my depth here so if you can make
things ergonomic without bastardizing the api, im game"), with one
standing condition: every binding-facing spelling goes in front of him
on a review page before it ships, and ergonomics is the standard — a
plain app reads one Document and never meets a delta.

## 0. The mechanism, from zero

**What rich text is, to a program.** A string plus ATTRIBUTE RUNS: "bytes
12 to 20 are bold, bytes 30 to 41 are a link to this URL". Block
structure is a second layer over paragraphs: "this paragraph is a
heading, that one a quote, those three a list". Every platform stores
it that way underneath, whatever it calls it: an NSAttributedString on
macOS and iOS, named tags over a buffer on GTK, the Text Object Model's
character and paragraph formats on Windows, span styles over a
TextFieldState on Compose.

**Who owns the document.** kaya's textarea today is UNCONTROLLED toward
the app: the widget owns its text, `text_changed` carries the whole new
string after each user edit, and a property write never echoes
(crates/kaya/src/spec.rs, `text_changed`). That is the right contract for
a form field and the wrong one for a document an app owns: a CRDT
merges EDITS ("replace bytes 12 to 15 with `foo`"), and handing it two
whole strings to diff loses the information the edit carried and every
concurrent-edit guarantee with it. So rich text needs a second channel
beside the fold: the edit itself, addressed, with its attributes.

**What kaya already has under it.** The 2026-08-06 foundation put a
rich-capable control under every textarea, pinned to plain text with
every rich opinion switched off and watched (docs/textarea-foundation-plan.md).
The ranges milestone added `highlight_ranges`, `select_range` and
`reveal_range` in ONE offset unit, UTF-8 bytes into the widget's text,
validated at one chokepoint in the core and converted per backend
there (docs/ranges-units.md). The undo milestone split undo into a
native text tier and a core-owned app tier (docs/undo-plan.md D1). The
editor app (guests/go/editor) is the consumer.

**What the platform survey found, condensed.** Inline styles are native
on all five: bold, italic, underline, strikethrough, monospace, colour.
Links are native on Apple and Windows, absent from GTK's tag model
(synthesized: a tag plus a side table) and unproven on Compose's
editable field. Block structure is where the platforms disagree:
alignment and indent are native everywhere; a HEADING is native
nowhere (every platform spells it as font size plus weight); quotes and
code blocks exist nowhere; LISTS exist on Apple and Windows with the
marker generated OUTSIDE the character stream, and nowhere on GTK and
Compose, where a marker would be characters INSIDE the buffer. Same
document, different byte offsets: that marker asymmetry is the one
thing that would break kaya's offset contract, and it is ruled below
before any list ships. Compose grew first-party inline styling on an
editable field in foundation 1.12 (stable 1.12.1, September 2026,
experimental API), which costs kaya a pin bump from 1.7.5.

**How edits are reported**, which decides whether kaya can publish
deltas: GTK and Compose hand over complete deltas (the replaced range
and the inserted text); macOS and iOS give the edited range and the
length change from the storage delegate, complete after one
subtraction against the pre-edit string; Windows gives NOTHING but a
boolean "content is changing". So the uniform source of the delta is
the core's own text mirror, which it keeps already (`field_text` in
crates/kaya/src/scene.rs, kept current for the ranges' validation):
diff the mirror against the new text, and use the platform's channel
only to corroborate and to say when an IME composition is live.

**What the CRDT survey found, condensed.** Three maintained Rust rich
text CRDTs: automerge 0.11 (Peritext marks, expand chosen per mark
call, emits addressed patches, UTF-8 by default), loro 1.16 (Peritext,
expand per style key document-wide, emits Quill-style deltas, a UTF-8
twin on every mutation), yrs 0.27 (Yjs's runs-and-attributes model, no
expand choice, bytes by default). No CRDT has bindings in all nine
guests, and OCaml and Haskell have none from anybody, so no CRDT type
may appear in kaya's API: the widget hands the app EDITS and the app
decides what sits behind them. All three take an addressed edit
verbatim, and all three default to kaya's ruled unit, so nothing
converts. Their undo is local-peer and forward (a new change, never a
rollback), which collides with kaya's native undo tier: the platform
stack would revert text the document never moved.

## 1. Rulings proposed

| # | ruling | recommendation |
| --- | --- | --- |
| R1 | **The contract is HYBRID: the textarea stays uncontrolled for typing, and every user edit is ALSO published addressed.** `text_changed` keeps carrying the plain text exactly as today, so no existing app sees a new byte. Beside it, on a textarea declared `rich`, the widget publishes `text_edited { start, end, inserted, runs, source }` for every user edit and `text_formatted { start, end, name, value }` for every toolbar act, and takes `set_rich_text(spans)` (the whole document, a configuration write, echoes nothing) and `apply_edit(start, end, inserted, runs)` (an incremental write that keeps the selection and echoes nothing). Five messages; the round trip is a scene: send an edit in, read the same shape back. THE BINDINGS KEEP THE MIRROR: each binding folds the edits into a `Document` value the app reads, the way signal mirrors work today, so an app that never wants deltas reads one document and an app with a CRDT feeds the deltas through. No wire read anywhere. | TAKEN 2026-09-11 |
| R2 | **Attribute runs travel in the ruled unit** — UTF-8 byte offsets, both ends on a code-point boundary, the grapheme carve-out as stated — validated at the same chokepoint the ranges use and converted per backend in the core. Identity conversion for automerge (`Utf8CodeUnit`, its default), yrs (`OffsetKind::Bytes`, its default) and loro's `_utf8` family. | TAKEN 2026-09-11 |
| R3 | **The v1 vocabulary is what synthesizes UNIFORMLY or is native everywhere.** Inline: `bold`, `italic`, `underline`, `strike`, `code`, `link(url)`. Block, one kind per paragraph: `body`, `heading` 1-3, `quote`, `code_block`. A heading is font size plus weight on every platform anyway, a quote is indent plus a rule and a code block a monospace face plus a ground, all drawn by the backend with NOTHING added to the text, so the bytes stay identical. OUT of v1: colours (a semantic-role question, the canvas palette's shape, its own slice), alignment (no consumer), and LISTS, under one rule stated now for when they come: **kaya's block model owns list semantics and no marker is ever in the guest-visible text**; the GTK and Compose arms draw markers their buffers never hold. Links are a synthesized tier on GTK (a tag plus a side table keyed by run) and measured on Compose before the arm is written. AMENDED BY THE WINDOWS PROBE the same day: Windows joins the synthesized tier — `ITextRange.Link` inserts a hidden HYPERLINK field into the character stream, so a native link is text the guest never sees and TOM offsets count it (docs/measurements/richtext-windows-2026-09-11.md); the WinUI arm draws the link (underline and colour through CharacterFormat) and keeps the URL beside the run, activated by a hit test. | TAKEN 2026-09-11, lists and colour deferred by name; links synthesized on GTK and Windows |
| R4 | **The core derives every delta from its own mirror**, uniformly on five platforms, and the platform's channel corroborates: where a backend reports a range (four of five), a disagreement with the diff is a diagnostic sentence that names both; where it reports nothing (WinUI), the diff is the delta. `source` says `user`, `ime_commit`, `paste`, `native_undo` or `drop`, which closes docs/undo-plan.md A6 (a native undo indistinguishable from typing) for rich widgets. | TAKEN 2026-09-11 |
| R5 | **A remote edit arriving mid-composition is QUEUED, not refused, and a caret at the edit's start ends AFTER the inserted text.** `select_range` refuses during an IME composition because honouring it commits the user's marked text (docs/ranges-plan.md D4); a refused `apply_edit` would instead DROP a collaborator's edit, which is data loss the other way. So the core holds the edit until the composition ends (which `text_changed` announces anyway) and applies it then, transforming the local selection as the survey's rule states: unchanged before the edit, shifted after it, and a caret exactly at the start moves past the insertion (yrs's and automerge's `After` association). | TAKEN 2026-09-11; the association is a stated carve-out like the grapheme one |
| R6 | **The native undo tier is opt-out per widget, and an app that owns the document says so.** docs/undo-plan.md A7 already names the lever; this rules its spelling: `own_undo()` on a rich textarea (a prop) turns the native stack off on that widget (`allowsUndo`, `enable-undo`, `UndoLimit 0`, the Compose undo state — the rich controls can all be told, where the plain TextBox could not), D7's history reset applies to `set_rich_text` and never to `apply_edit`, and D6's routing takes the app's `can_undo`/`can_redo` props for that widget so Edit>Undo reaches the app's own undo (a CRDT's, or the app's) instead of a stack that has been switched off. The core's own log (D3-D5) is untouched: a document the app owns never became core signals. | TAKEN 2026-09-11 (amends docs/undo-plan.md D1/D6/D7 by the maintainer's word) |
| R7 | **Compose takes the first-party path**: foundation 1.12's `addStyle`/`removeStyle`/`getSpanStyles` on the editable buffer, behind its experimental flag, with the pin bump measured on the android lane first (build, the 143 legs, the three unmeasured points in §3). A synthesized tier (an output transformation over the plain buffer) stays the fallback if the measurement says no. AMENDED BY THE PROBE the same day (docs/measurements/richtext-compose-2026-09-11.md): foundation 1.12.1 is a TOOLCHAIN MIGRATION (AGP 9.1, Gradle 9.7, compileSdk 37 the nix SDK does not ship, the standalone Kotlin plugin deleted), while foundation 1.11.4 builds on kaya's pins as they stand and carries display-only `addStyle`; links render nothing in an editable field on either version; undo has no off switch. So the Compose arm takes 1.11.4: the core's mirror drives the display styles through the field's output transformation, the arm draws links (underline and colour) and hit-tests taps itself, and `clearHistory()` after every commit is R6's lever. The 1.12 tracked API is revisited when the toolchain moves for its own reasons. | TAKEN 2026-09-11, amended: foundation 1.11.4, styles driven from the mirror |
| R8 | **Labels get the same inline vocabulary as a second slice.** The roadmap's rich-text row was about labels (a markup subset on label text). One document type serves both: a `rich` label renders the inline runs read-only through AttributedString, Pango attributes, RichTextBlock and AnnotatedString. After the textarea's depth, not before. | TAKEN 2026-09-11, sequenced after |
| R9 | **The harness reads the CORE's document, never the platform's.** `expect_runs <target> "<runs>"` compares the mirror's attribute runs byte for byte on five lanes (the canvas hash's shape); `format <target> <name> <start> <end>` toggles as the user would; `type` and `select_range` already exist; `expect_edit "<last text_edited>"` reads the occurrence. What the PLATFORM holds is verified per backend in check-verbs' gate shape (a read-back at a range, tri-state for a mixed range as Windows answers it), not in a shared scene, because five read-backs answer five ways. The AX words a rich run adds (`heading`, `link`) join the closed word set only after each platform's screen reader is measured saying them. | TAKEN 2026-09-11 |

## 2. The protocol, in the spec's terms

Four records and one prop, spec-first (invariant 7), generated into nine
bindings by the existing generator with `highlight_ranges`' count-plus-
Values shape for runs:

- prop `rich` (window prop family, textarea only): the widget accepts
  and publishes attributed content; off, nothing below exists and the
  rich opinions stay pinned as today.
- TX `set_rich_text { widget, spans }` — spans as `(text, attrs)` pairs;
  a configuration write: resets the native undo history under D7 where
  the native tier is on, echoes nothing.
- TX `apply_edit { widget, start, end, inserted, runs }` — the app's or
  a collaborator's edit; keeps the selection by R5's rule; queued
  during a composition; echoes nothing; never resets undo.
- occurrence `text_edited { widget, start, end, inserted, runs, source }`
  — offsets into the text BEFORE the edit; `runs` cover `inserted` only.
- occurrence `text_formatted { widget, start, end, name, value }` — a
  toolbar act over a range; `value` absent means removed. Bold pressed
  on a collapsed caret is widget-local pending state and becomes the
  `runs` of the next `text_edited`, not an occurrence of its own.

The block kinds ride as an attribute named `block` on the runs that
span whole paragraphs, so one run model carries both layers and the
validator has one shape to check (a `block` run must start and end on
paragraph boundaries; refused otherwise, naming the byte).

The sugar, one shape in nine (the sweep verdict is do, in all nine):
a `Document` value (text plus runs) each binding keeps current from the
edits; `textarea.rich()`; `on_edit(|edit| ..)` and `on_format(..)`
beside `on_text_changed`; `set_document(doc)` and `apply(edit)`; a
`Run`/`Edit` record with the language's idiom for the attribute value.
No CRDT anywhere in it: an app with automerge calls
`splice_text(start, end - start, inserted)` from the edit and
`mark(...)` per run; one with loro `delete_utf8`/`insert_utf8`; one
with yrs `remove_range`/`insert_with_attributes`. The expand rule for
marks is the CRDT's and the app's; kaya carries no flag for it.

## 3. What is measured before any arm is written (the unknowns)

Each is half a day on its own lane, its record under docs/measurements,
and the ruling above that depends on it is named:

1. **GTK's undo scope**: whether `GtkTextBuffer`'s history records
   `apply-tag`/`remove-tag`. If not, the native tier is incomplete for
   rich text on Linux and R6's off switch is the only honest state
   there. (R6)
   MEASURED 2026-09-11: it records none, and a tag applied with its
   insert is DESTROYED by an undo-then-redo with no error, so the off
   switch is mandatory on Linux; `enable-undo = FALSE` is complete and
   togglable at runtime (docs/measurements/richtext-gtk-2026-09-11.md).
   AT-SPI carries the five inline traits with ranges and has no link or
   heading word at all. `insert-text`'s length is already bytes.
2. **Compose, three points**: a `LinkAnnotation` on editable
   `TextFieldState` content; whether `addStyle`/`removeStyle` appear in
   `TextFieldBuffer.changes`; the pin bump to foundation 1.12 building
   and the lane green. (R3, R7)
   MEASURED 2026-09-11: a link in an editable field renders and taps
   nothing on 1.11.4 and 1.12.1 alike (it works on read-only text);
   `addStyle` posts itself to `changes` as a same-text replace and
   coalesces with a real one, so the change list cannot say whether
   text moved (R4's diff stands); offsets are UTF-16 code units; the
   1.12.1 build needs the toolchain migration named in R7's amendment,
   and 1.11.4 builds on the pins as they stand. Undo: a programmatic
   `edit {}` ADDS an entry and a style-only edit enters as a text no-op
   whose undo removes the style, so the arm clears the history after
   every commit. Accessibility exposes no formatting on the editable
   tier.
3. **RichEditBox unpinned**: the undeletable final paragraph mark
   returns when the plain-text pin comes off, and kaya's
   `StoryLength - 1` arithmetic was derived under the pin. (R2, R4)
   MEASURED 2026-09-11: the control was never in a plain-text MODE (the
   pin sets three opinions on a model that is rich either way), so
   pinned and unpinned read byte-identically and the arithmetic
   survives — as long as every `GetText` carries `AdjustCrlf` (and
   `NoHidden` once links exist), which wants one chokepoint helper in
   the WinUI arm. A split surrogate pair snaps OUTWARD at every TOM door.
   `UndoLimit = 0` is a complete off switch; the events cannot name an
   edit's source (a programmatic SetText looks like a keystroke), which
   is R4's diff again; read-back is a true tri-state; UIA exposes
   weight, italic, underline, strikethrough and font name per run, a
   link as a Hyperlink child, and nothing for a heading.
4. **The screen readers**: what each of the five announces for bold, a
   link and a heading, so the AX words can be added to the closed set
   rather than assumed. (R9)
   MEASURED 2026-09-11 as what a client can FETCH (no screen reader was
   enabled): underline and strike are booleans on Apple and attributes
   on GTK and UIA; bold, italic and code are font identity everywhere; a
   link is an AXLink element on macOS, a bare token on iOS, a Hyperlink
   child on Windows and nothing on GTK; a heading exists on iOS only
   when written. So R9 mints no new AX word in v1.
5. **Native undo suppression per platform** for R6's off switch:
   `allowsUndo`, `enable-undo`, `UndoLimit`, Compose's undo state, each
   watched actually holding.
   MEASURED 2026-09-11 on four: macOS `allowsUndo = false` complete
   (and a change straight on the storage registers nothing, so
   apply_edit is suppressed for free); iOS `undoManager.
   disableUndoRegistration()` per view, the nil override being a decoy;
   GTK `enable-undo = FALSE`; Windows `UndoLimit = 0` (dropping it
   destroys the stack). Compose: see the android record.
6. **loro's emitted delta unit**, a 60-line probe, before anything is
   said about loro in a binding's example. (R2)
   MEASURED 2026-09-11: unicode scalars on the read side, bytes on the
   write side (no `unmark_utf8`), so a loro bridge converts reads
   through `convert_pos`; its expand rule governs only insertions that
   happen-after a mark (docs/measurements/richtext-loro-2026-09-11.md).
7. **The diff-derived delta against the native channel**, on the four
   platforms that report one: the diagnostic in R4 has to be made to
   print before it is trusted (invariant 3).

## 4. Sequencing

Depth then breadth, the standing pattern:

1. **Probes** (§3), on their lanes, records landed. About three days
   across the five lanes, in parallel.
2. **Depth on the mac**: the spec records and the prop, the core's
   mirror growing runs and the diff-derived delta at the ranges'
   chokepoint, the Rust sugar and `Document`, the NSTextView arm
   unpinned for the v1 vocabulary only (every other opinion stays
   pinned and watched), the editor's rich toggle (a toolbar switch:
   plain or rich, one buffer), and `richtext.steps` asserting runs, an
   edit round trip, a format act and the queue rule. Cost L.
3. **Breadth**: iOS (the same file), GTK (tags, the link side table,
   the drawn block kinds), WinUI (TOM formats, the diff as the only
   delta), Compose (the 1.12 path); the eight bindings' sugar; the
   sweep's rows in check-sugar-surface and check-verbs; the matrix.
   Cost XL across five, each arm its own measurement first.
4. **Undo amendments** (R6): the off switch, D6's app answer, the
   editor asserting both routes. Cost M.
5. **Labels** (R8). Cost M.

## 7. The depth build, as it landed (2026-09-11)

The root and the mac arm are on the tree (docs/deferred.md's rich text
entry carries the open stubs). Three things were decided while building
and are recorded here for the review:

- **The app formats the widget's SELECTION through the widget's own act**:
  a fifth record, TX `format_text { widget, removed, attr: [name, value] }`
  (apply 45), lowered verbatim to the backend, which applies it over its
  current selection — or arms its typing attributes when the selection is
  collapsed — and answers with `text_formatted` exactly as for a user's
  act. That is the toolbar: an app draws Bold as a kaya button and its
  handler sends `tx.format(editor, "bold", "true")`, `tx.unformat(editor,
  "bold")` or `tx.set_block(editor, Block::Heading1)`, and reads the range
  back from `on_format`. The alternative, eleven menu roles (bold, italic,
  … heading1-3, quote, code_block) routed focused-text-first the way undo
  is, was refused: it puts the whole vocabulary into MENU_ROLES, into all
  four backends' enablement and dispatch and into nine bindings' role
  constants, for a mechanism the app can spell with the widgets it has.
  A native act (iOS's edit menu, WinUI's Ctrl+B) reaches the same answer
  when those arms land.
- **The harness verbs (R9)**: `format <target> <start:end> <name>[=<value>]
  [off]` in bytes — the runner selects the range and takes the widget's act,
  so the widget reports as for a user — `expect_runs <target> "<runs>"`
  reads the CORE's document as `start:stop name[=value]`, `|`-joined in the
  mirror's normal order (a flag's `true` is its name alone), and
  `expect_edit <target> "<edit>"` reads the last text_edited the core
  published as `start:stop <inserted> source [runs]`, with angle brackets
  because a `.steps` string cannot carry a quote. The mac runner reads the
  storage's own runs beside the core's and prints a KAYA_DIAG naming both
  when they disagree; that is R9's "per backend" half until check-verbs
  holds a row for it. The scene is tools/scenes/richtext.steps, its guest
  guests/rust/richtext.rs, and the guest's second label is the binding's
  Document spelled the same way, so the fold is compared to the mirror
  byte for byte.
- **The mac arm keeps kaya's attributes under its own keys**
  (`kaya.rich.<name>`) and DERIVES the display from them on every change
  — font traits and heading sizes, underline and strike styles, the link
  colour and `.link`, a quote's indent — so a read-back never guesses a
  name from a font. `isRichText` is the one pin lifted, and the view's
  paste goes through `pasteAsPlainText` under the typing attributes so
  RTF's own attributes never enter (source `paste`). A block act covers
  the selection's paragraphs WITHOUT the trailing newline. Pending typing
  attributes survive AppKit's re-derivation and are spent by the next
  insertion, the core's rule; a caret moved elsewhere by the user keeps
  them until then, which most editors do not — a ruling if it matters.
  Not drawn yet: a code run's ground (the highlight ground owns
  `.backgroundColor` on this view) and a quote's rule; a link click takes
  AppKit's default rather than kaya's link door.

- **A composition is the widget's alone, and the app's own edits are the
  app's at once.** Measured on the leg: `setMarkedText` notifies no
  delegate, so marked text never reaches text_changed, the core's mirror
  or the app — the composition commits as ONE edit when it ends, which is
  what R5 assumed and A's open item 3 asked about (a held edit cannot be
  stale against marked text the core never saw). And the binding folds an
  `apply_edit` into the app's `Document` as it SENDS it, while the widget
  and the core's mirror take it when the composition ends, so the two are
  the edit's length apart until then; the scene asserts exactly that.

- **`body` is the block attribute taken off, and never a run.** The WinUI
  agent found `set_block(editor, Block::Body)` aborting the core on every
  backend that mirrors the mac: the arm reported the act as a removal and
  the core refused a `block` with no value. The core now reads a `block`
  act with `body` or with no value as one act — the block runs over the
  range go — and `normalize` drops any `block=body` run a declaration
  carries, so a paragraph's body kind is the absence of a run on every
  lane; the scene pins it with a `block off` step.

Open after this step, beside the platform arms: the `Edit` the Rust sugar
hands an app carries no `source` (the core's text_edited does; the harness
reads it); `own_undo` (R6) is the undo step's and the mac's native undo
stack stays on under a rich textarea until then; and the editor's rich
toggle (§4 step 2) moves to the breadth step, since guests/go/editor needs
the Go sugar first.

## 8. The breadth, as it landed (2026-09-11, the same day)

Eight agents in parallel, each on its own files, folded by the coordinator
(the notes are the job's record; what a future session needs is here and
in docs/traps.md). Every arm answers tools/scenes/richtext.steps byte for
byte, every binding's richtext guest prints the Rust guest's labels, and
`expect_runs` on every runner FAILS when the widget's own runs disagree
with the core's document, naming both — the corroboration is a wall now,
not a diagnostic.

- **iOS**: UIKit rebuilds `typingAttributes` with its own keys only, so the
  arm re-derives kaya's keys at every re-derivation point by the core's
  `typed_runs` rule; `textViewDidChange` returns early on marked text for
  rich nodes (UITextView notifies during a composition, NSTextView does
  not); both Apple arms take the body ramp from `kayaPlatformFont(.body)`,
  never the view's font, which answers the selection's.
- **GTK**: one GtkTextTag per attribute value, named so the tag is the key
  (`kaya-rich-bold`, `kaya-rich-block-heading2`, `kaya-rich-link-<n>` with
  the URL in a side table); the display derived from the tag; inheritance
  applied by the arm inside `insert-text`'s after-phase since GTK does not
  extend a tag at a run's end; preedit never reaches text_changed (it lives
  in the IM context, not the buffer); `body` is the attribute taken off.
- **WinUI**: TOM character and paragraph formats as the display over the
  arm's own byte run table as the truth; links drawn, never `SetLink`
  (check-steps' hidden-text lint); no reported edit, the core's diff is the
  delta; `SetCharacterFormat` on a collapsed selection re-raises
  SelectionChanged, so nothing writes back to the control from that event
  (docs/traps.md); the bindgen filter widened for FormatEffect,
  UnderlineType and ITextParagraphFormat, held by check-winui-bindings.
- **Compose**: foundation 1.11.4 is one line after the BOM; the mirror
  drives the display through the field's OutputTransformation; links are a
  look plus kaya's own hit test on the pointer's initial pass; heading
  sizes in `em`; pending attributes are kaya's state (a zero-length
  addStyle is dropped by Compose); `clearHistory()` after every commit
  including apply_edit (D7 cannot be honoured there, measured); a plain
  Compose field still reports marked text (ledger).
- **The eight bindings**: the Rust surface in each idiom. Ambient bindings
  (Python, JS, OCaml) put the writes on the widget as their other verbs are;
  registry-family bindings (C#, Java, Swift, Haskell) register `on_edit`
  and `on_format` on the app; Go's run record is `TextRun` (the package's
  `Run` is its entry point), OCaml's act is `format_act` (`format` is the
  printf type), C#'s kind is `BlockKind`; Haskell's `Rich` is a GADT
  attribute with `formatText` as its act. Every binding folds delivered
  edits and its own `apply_edit` into `document(widget)` with the core's
  splice and normal form. tools/check-sugar-surface.py holds fourteen parts
  in all nine.
- **The generator**: a tx record's payload is one trailing `text` parameter
  in all nine wire files (docs/traps.md), and the Haskell wire reader
  decodes UTF-8 (`wireUtf8`).

Pushed as d1f23d22; the matrix on that tree ALL PASS on all five lanes and
59 gates, 1,773 legs in 1285s.

Open after the breadth: the marked-text divergence on plain Compose fields;
a shared scene step that round-trips non-ASCII text through a guest's label
(the Haskell decoder's wall); the template zone (`rich` is a live-zone
spelling; JS refuses `document()` on a template node in its own words, no
gate holds the other eight); `own_undo` (R6); labels (R8); the editor's
rich toggle, now that the Go sugar exists; and the five rulings on the
review page.

## 5. What this plan does not do

- It does not put a CRDT, a delta format or a markup language on the
  wire. Interchange (Markdown, HTML, RTF) is the app's, and a helper
  in a binding is a later convenience, not a kaya concept.
- It does not ship lists or colours in v1; both are named with the rule
  they will come under.
- It does not add a wire read. The mirror is the binding's, as every
  other mirror is.
- It does not adopt SwiftUI's iOS 26 attributed TextEditor: kaya's
  floor is iOS 16, and the NSTextView/UITextView path underneath is the
  foundation already paid for.

## 6. The automerge benchmark, measured the same day

The maintainer named automerge the benchmark, so the protocol was
driven against it before any arm: tools/richtext/automerge-probe, its
record docs/measurements/richtext-automerge-2026-09-11.txt. A model of
the mirror beside an automerge 0.11 document in kaya's unit, through
local typing and toolbar acts, multi-byte text, two peers editing
concurrently and merging, and the caret transform with automerge's own
cursor as the oracle: every check agreed, offsets never converted,
automerge's three text patches map one to one onto `apply_edit` and
format, and a bridged edit costs 0.024ms when the app reads the
splice's own patch (0.63ms when it walks the document instead, which is
the note for a binding's bridge). R1, R2 and R5 stand as measured; what
remains to measure is the platforms (§3).
