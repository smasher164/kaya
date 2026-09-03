# Text ranges — WHAT UNIT DOES AN OFFSET COUNT?

UNITS ARM of the text-ranges milestone. Charter: docs/ranges-plan.md.
Repo HEAD 4f40e59. No repo file edited.

Everything below is either MEASURED (probe source and output under
`docs/probes/units/`, cited per claim) or QUOTED from a vendor document
(URL given). Nothing is assumed from memory.

---

## VERDICT

**The wire carries UTF-8 BYTE offsets into the guest-visible text.**
That confirms docs/ranges-plan.md D2's proposal, and the measurements
below say *why* it is right rather than merely convenient — but D2 is
incomplete in three ways, and those three are the actual deliverable:

1. **The core validates, in Rust, at one chokepoint, and REFUSES
   loudly.** Three clauses: `start <= end`, `end <= text.len()`,
   `text.is_char_boundary(start) && text.is_char_boundary(end)`.
   Measured cost of the boundary clause: **69 ns for 100 offsets**
   (`units/conv.rs`) — it is O(1) per offset and it is the *only*
   unit with an O(1) validity predicate.
2. **The core converts to each backend's native unit before lowering,
   in Rust, using its own copy of the text.** No interpreter ever sees
   a byte offset. The core already holds the authoritative text:
   `crates/kaya/src/scene.rs:438 field_text: HashMap<WidgetId, String>`,
   kept current by `note_text_changed` (`:2285`), `absorb_text_writes`
   (`:2213`) and `note_native_undo` (`:2478`). Measured conversion cost
   for 50 ranges over a 34.8 KB mixed-script buffer: **39 µs one-pass**
   (226 µs naive), against platform lowering costs the probes already
   measured at ~44 µs *per range* (RichEditBox highlight),
   674 µs (select), 628 µs (reveal). The conversion is noise.
   Putting it in the core keeps Unicode arithmetic out of
   KayaSwiftUI.swift and KayaCompose.kt — the historic miss layer, which
   is string-matched rather than compile-checked.
3. **A grapheme split is ALLOWED and is a stated carve-out, not a
   refusal.** The core cannot honestly refuse it: the platforms disagree
   about what a grapheme *is*. Measured, same string, same JVM/CLR
   generation: `java.text.BreakIterator` counts the ZWJ family as
   **11** clusters where .NET `StringInfo` and Swift `String.count`
   both count **5** (`units/M.java`, `units/cs/Program.cs`,
   `units/m.swift`). A core that refused by its own table would refuse
   ranges three platforms would honor, and pass ranges one platform
   would widen.

The one-sentence contract, in the shape DESIGN.md's neighbouring
paragraphs already use:

> A range is a pair of UTF-8 byte offsets into the widget's current
> guest-visible text. Both endpoints must fall on a code-point
> boundary and inside the text; kaya refuses a range that does not,
> naming the widget, the offset and the character it splits. An
> endpoint may fall inside a grapheme cluster: the range then covers
> exactly the code points it names, and a platform may widen what it
> *paints* to the whole cluster.

---

## §1 — What kaya's existing text machinery counts: NOTHING, YET

This is the first offset in the protocol. There is no second convention
to be consistent with — but there IS an existing doctrine about what
text *is*, and the byte-offset choice is the one that agrees with it.

- **The wire is UTF-8 and validates on decode.** `crates/kaya/src/wire.rs:267-270`
  decodes a `Str` value as `std::str::from_utf8(payload).expect("kaya:
  string value is not UTF-8")`. Ill-formed text from a guest is a
  loud panic today. **This is the precedent for the refusal shape:
  a malformed offset is the same class of app-programming error as
  malformed text, and gets the same treatment.**
- **DESIGN.md:373-382 already fixes the abstraction**: "String
  observations compare Unicode scalar sequences — implemented as
  code-unit equality in each comparator's native encoding... The wire
  is well-formed UTF-8, so every implementation computes the same
  predicate... Ill-formed platform text (a lone surrogate in a UTF-16
  language) cannot reach a comparison — the FFI boundary repairs it
  before it exists to kaya." A byte offset into well-formed UTF-8
  names a position in that scalar sequence unambiguously; it is the
  same object the equality doctrine already talks about.
- **The undo ledger's `texts` run carries whole strings, no offsets**:
  `crates/kaya/src/spec.rs:274` — `texts: groups(i64 size, i64 id,
  i64 path_len, path_len key values, str text)`. The restore is a
  statement of what the text now IS (`spec.rs:1576`). Nothing indexes.
- **The harness verbs carry no offsets.** `set_text(target, text)`
  and `type_text(text)` (`harness.rs:541,594`); `type` is restricted
  to printable ASCII at parse (`harness.rs:1385-1400`,
  `tools/check-steps.py:1296-1352`). `crates/kaya/src/scene.rs:656`
  states outright: "kaya has no selection API".
- **The two existing near-misses are both ASCII-safe by accident,
  and one is a latent unit bug**:
  - `swift/KayaSwiftUI.swift:8395` carries the selection across a text
    push using `(text as NSString).length` — correct, that is UTF-16,
    which is what NSRange wants.
  - `crates/kaya/src/winui/mod.rs:5967-5968` computes a caret with
    `now.chars().count() as i32` (Rust **scalars**) and feeds it to
    `set_caret` → `TextDocument.Selection.SetRange(at, at)` /
    `SetSelectionStart`, both of which take **UTF-16 code units**
    (`winui/mod.rs:311-318`). Today `type` is ASCII-only so the two
    agree; the moment anything non-BMP is in the field the caret lands
    short. **This is a real one-line defect that the ranges milestone
    should fix in passing** (`chars().count()` → `encode_utf16().count()`),
    and it is the miniature of the whole question.

---

## §2 — The four candidate units, on the hazard strings

Measured with `units/table.py`. Offsets are of the character AFTER the
hazard, i.e. how far the four units disagree.

| string | UTF-8 bytes | UTF-16 units | scalars | graphemes |
| --- | --- | --- | --- | --- |
| `a` U+1F600 `b` | 6 | 4 | 3 | 3 |
| `a` `e`+U+0301 `b` | 5 | 4 | 4 | 3 |
| `a` family-ZWJ `b` | 27 | 13 | 9 | 3 |
| `a` 日本語 `b` | 11 | 5 | 5 | 5 |
| `a` CRLF `b` | 4 | 4 | 4 | 3 |
| `a` 🇺🇸 `b` | 10 | 6 | 4 | 3 |

The ZWJ family is the discriminator: 27 / 13 / 9 / 3 for one visible
glyph. Any confusion of units there is a 24-unit error.

---

## §3 — Per backend: unit, validation, conversion owed

### mac (SwiftUI interpreter → NSTextView, per the foundation milestone)

**Unit: UTF-16 code units.** `NSRange` over an `NSString`, by
construction. Confirmed against the live control: for the ZWJ family
string the text view reported 15 UTF-16 units where the UTF-8 length is
29 (`units/appkit.swift` output).

**Validation — measured, and it is the worst of both worlds**
(`units/appkit2.swift`, string `ab😀cd`, 6 UTF-16 units):

| call | result |
| --- | --- |
| `setSelectedRange{3,0}` (caret inside the pair) | snapped to **{2,0}** |
| `setSelectedRange{3,3}` (start inside the pair) | snapped to **{2,4}** |
| `setSelectedRange{0,3}` (**end** inside the pair) | **kept verbatim {0,3}** |
| `setSelectedRange{2,1}` (end inside the pair) | **kept verbatim {2,1}** |
| text of that kept selection | `61 62 ef bf bd` → **U+FFFD** |
| `addAttribute(.backgroundColor, range:{2,1})` (splits the pair) | **accepted**, survives a layout pass, effectiveRange {2,1} |
| `addAttribute` with a range past the end | **process killed**: `NSRangeException … NSMutableRLEArray objectAtIndex:effectiveRange:: Out of bounds`, **exit 134** |
| `setSelectedRange` past the end | clamped to {5,1}, survives |
| `scrollRangeToVisible` past the end | survives |
| `selectionRange(forProposedRange:{11,1}, .selectByCharacter)` past end | returns **{11,-12}** — a negative length |

So AppKit **snaps a bad start, keeps a bad end** (and a copy of that
selection yields U+FFFD, silently), **never validates a highlight
boundary**, and **aborts the whole app** on an out-of-range highlight.
The out-of-range abort alone forces core-side bounds validation: an
app cannot be allowed to reach that call.

AppKit's user-selection path snaps to the whole cluster —
`selectionRange(forProposedRange:granularity:.selectByCharacter)` and
`NSString.rangeOfComposedCharacterSequence(at:)` both return **{2,11}**
for any location inside the ZWJ family, and **{2,2}** for the combining
sequence. That is the widening the carve-out refers to.

**Conversion owed: byte → UTF-16.** In the core, one pass. If the mac
arm ever wanted it Swift-side instead, Swift can do it *and detect a
bad boundary exactly*: `s.utf8.index(...).samePosition(in:
s.unicodeScalars)` returns nil precisely on the bytes Rust's
`is_char_boundary` rejects — measured identical on both hazard strings
(`units/s2u.swift` vs `units/conv.rs`: bytes 3,4,5 refuse; byte 6 → 4).

### ios (SwiftUI interpreter → UITextView)

**Unit: UTF-16 code units**, same Foundation `NSRange`. The iOS probe
drove exactly these APIs — `scrollRangeToVisible:(NSRange)`
(range-probe-ios.md:40), `@property NSRange selectedRange` (:41),
`setRenderingAttributes:forTextRange:` (:52) — and read
`hit.selectedRange={12,7}` back (:358).

**Conversion owed: byte → UTF-16**, identical to mac; one conversion
serves both, which matters because one Swift file serves both platforms.

**NOT MEASURED, and the iOS arm must**: whether `UITextView`'s
`selectedRange` setter snaps like AppKit's (Foundation is shared, UIKit's
selection machinery is not), and whether `UITextInput`'s
`offset(from:to:)` — which the probe used at :358 — counts UTF-16
units or "visible characters". If it is the latter it is a *different*
unit inside the same file and must not be used for range lowering.

### linux (GTK4 GtkTextView + GtkTextTag)

**Unit: code points (Unicode scalars), NOT bytes.** Measured live in
the kaya-linux container, GTK 4.18.6 (`units/gtkunits.c`):
`gtk_text_buffer_get_char_count` = 5 for `ab😀cd` (8 bytes), and buffer
offset 3 lands at byte 6. `gtk_editable_select_region(0,-1)` on the
entry reads back **{0,5}** — code points, not the 8 bytes.

**Validation:**
- offsets past the end **clamp** to the end iterator
  (`get_iter_at_offset(9999)` → offset = char_count, `is_end=1`).
- `select_range` and `apply_tag` over a mid-grapheme range are
  **accepted verbatim** — {2,3} reads back {2,3} on the ZWJ family,
  i.e. GTK will happily tag one code point of an 8-code-point cluster.
  No snapping (unlike AppKit and Compose).
- **The byte-addressed door exists and GTK itself calls it fatal.**
  `gtk_text_buffer_get_iter_at_line_index(buf, &it, 0, 3)` with a byte
  index inside a UTF-8 sequence printed, in GTK's own words:
  `Gtk-WARNING: Incorrect byte offset 3 falls in the middle of a UTF-8
  character; this will crash the text buffer. Byte indexes must refer
  to the start of a character.` The iterator it returned is
  self-inconsistent (`get_offset`=2 while `get_line_index`=3). **This
  is the single strongest argument for the boundary clause: the
  platform documents that a mid-character byte index corrupts the
  buffer.**
- GTK's *cursor positions* are grapheme clusters and agree with
  Swift/.NET: 4 `forward_cursor_position` steps end-to-end for the ZWJ
  family (5 positions) where char_count is 11; 4 steps for the
  combining sequence where char_count is 6; and CRLF is **one** cursor
  position.
- **Pango attributes (the ENTRY's highlight path) take BYTE indices
  and validate nothing** — an attribute over bytes {2,3}, mid-sequence,
  laid out with no error return and no warning. The entry is deferred
  this milestone (D1), but if it is ever un-deferred this is its
  hazard.

**Conversion owed: byte → code point**, one `g_utf8_pointer_to_offset`
(or, in the core, `s[..b].chars().count()` — measured 18 µs for 100
offsets) **plus a line-ending correction that no other backend needs**:
`crates/kaya/src/gtk.rs:40-46` collapses `\r\n` → `\n` wherever text
escapes toward the guest, and GTK stores pasted CR/CRLF verbatim
(`gtk.rs:36-39`). Measured: the buffer holds 6 code points for
`ab␍␊cd` while the guest's text is 5. **After one pasted CRLF every
declared range lands one position early, and nothing says so.** This is
the "ships silently" case of this milestone on linux, and it is
independent of Unicode.

### windows (RichEditBox / TOM, per the foundation milestone)

**Unit: UTF-16 code units** ("character positions", cp). The TOM
reference is explicit that a cp can land inside a surrogate pair —
`ITextRange2::GetChar2` tabulates what happens when an offset
"accesses the middle of a surrogate pair" (negative → the pair's UTF-32
character, positive → the character *following* the pair)
(learn.microsoft.com/.../nf-tom-itextrange2-getchar2). A unit that can
be half a character is a UTF-16 code unit.

**Validation: clamps, never throws.** ITextRange's reference states:
"If a *cp* argument has a value greater than the number of characters
in the story, the number of characters in the story is used instead. If
a *cp* argument is negative, zero is used instead", and the invariant
`0 <= cpFirst <= cpLim <= #characters in story`
(learn.microsoft.com/.../nn-tom-itextrange). Nothing in `SetRange`'s
own page mentions surrogates
(learn.microsoft.com/.../nf-tom-itextrange-setrange). So Windows will
silently accept a split range and paint half an emoji.

**Two Windows-only offset facts the depth arm must carry:**
- **Every story ends in an undeletable CR** — "all stories contain an
  undeletable final CR (0xD) character at the end. So even an empty
  story has a single character" (ITextRange reference). StoryLength is
  therefore guest-length + 1, and `r.End <= StoryLength - 1`.
- **Line breaks are 1:1, so `lf()` does not shift offsets here.**
  Measured by the windows arm: `set 'a\nb' → GetText(AdjustCrlf) =
  'a\rb'` (range-probe-windows.md:240), and `crates/kaya/src/winui/mod.rs:1577-1598`
  documents the CR storage with `TextGetOptions::AdjustCrlf` on the
  read. One CR per LF, same count — unlike GTK, where the pair
  survives. **This asymmetry between the two CR-storing backends is
  exactly the kind of thing that gets assumed wrong; it is measured
  here in both directions.**

**Conversion owed: byte → UTF-16**, plus the trailing-CR awareness
above.

### android (Compose, TextFieldState / TextRange)

**Unit: UTF-16 code units.** `TextRange` indexes a Kotlin
`CharSequence`, whose `Char` is a UTF-16 code unit. The android probe
already flagged this and punted the cross-binding question here
(range-probe-android.md:353: "Compose offsets are UTF-16 code units,
which is a cross-binding question, not an Android one").

**Validation — documented precisely, and it is the third distinct
policy of the five.** From androidx-main
`compose/foundation/.../text/input/TextFieldBuffer.kt`:
- `selection`'s setter calls `requireValidRange`, which checks **bounds
  only** (`TextRange(0, length)`), throwing `IllegalArgumentException`
  via `requirePrecondition`.
- Its KDoc: *"If the start or end of TextRange fall inside surrogate
  pairs or other invalid runs, the values will be adjusted to the
  nearest earlier and later characters, respectively."* The same
  sentence appears on `placeCursorBeforeCharAt` ("nearest earlier
  index") and `placeCursorAfterCharAt` ("nearest later index").

So Compose **throws on out-of-bounds** and **snaps outward on a split**
— where AppKit snaps the start only and Windows clamps silently and GTK
does nothing.

**Conversion owed: byte → UTF-16.** In the core, so that KayaCompose.kt
carries no Unicode arithmetic.

**NOT MEASURED, and the android arm must**: what an `AnnotatedString`
`SpanStyle` does when its range splits a surrogate pair (the highlight
path, not the selection path — the snapping sentence above is
documented for the *selection*, not for spans).

### Summary table

| backend | offset unit | out of range | splits a code point | splits a grapheme |
| --- | --- | --- | --- | --- |
| mac (NSTextView) | UTF-16 | select clamps; **highlight ABORTS the app (exit 134)** | start snapped, **end kept → copies U+FFFD** | selection snaps to the whole cluster |
| ios (UITextView) | UTF-16 | not measured | not measured | not measured |
| linux (GtkTextView) | **code points** | clamps to end | not expressible via offsets; **expressible via byte index, GTK warns "will crash the text buffer"** | accepted verbatim, no snap |
| windows (RichEditBox) | UTF-16 | **clamps** (documented) | expressible, accepted | not measured |
| android (Compose) | UTF-16 | **throws IllegalArgumentException** | **snaps outward** (documented) | "other invalid runs" — snaps |

Five backends, **four different policies** for the same malformed
input. That is invariant 1's problem statement: if the core forwards a
malformed offset, "the same declaration" means five different things.
The core must therefore refuse before lowering — the divergence cannot
be papered over downstream.

---

## §4 — The hazard cases, end to end

**4-byte emoji (U+1F600), `ab😀cd`.** Byte offsets of `c`: 6. UTF-16: 4.
Bytes 3, 4, 5 are inside the character. Core refuses all three in O(1)
(`units/conv.rs`: ` 3:REFUSE 4:REFUSE 5:REFUSE`). If one reached the
platform: mac keeps a split *end* and the selection copies as U+FFFD;
Java's `substring(0,3)` encodes to UTF-8 as `3f` — a literal `?`;
.NET's encodes as `EF BF BD` — U+FFFD. **Two runtimes, two different
silent corruptions, neither an error** (`units/M.java`, `units/cs/`).
Go and OCaml and C slice a mid-sequence byte without a murmur
(`ab\xf0`, `valid_utf8=false`). Rust is the only guest language that
stops it by itself: *"end byte index 3 is not a char boundary; it is
inside '😀' (bytes 2..6 of string)"*.

**Combining sequence (`e` + U+0301).** No unit but graphemes can keep
it whole. An offset between them is a legal code-point boundary
everywhere, so the core MUST accept it. mac snaps a selection there to
the whole cluster ({3,1} → {2,2}); GTK keeps it ({2,3} verbatim);
Compose snaps outward. This is the carve-out case, and it is why the
carve-out must be *written down* rather than discovered.

**ZWJ family (U+1F468 ZWJ U+1F469 ZWJ U+1F467 ZWJ U+1F466).** 25 bytes,
11 UTF-16 units, 7 scalars, 1 grapheme. mac's
`rangeOfComposedCharacterSequence` at any interior location returns the
whole {2,11}; GTK's cursor walk crosses it in one step while its
offsets count 7; Java's stdlib segmenter does **not** merge it (11
clusters where .NET and Swift say 1). A range declared "over the
family" is 25 bytes in kaya's unit and unambiguous; a range declared
"3 characters in" means four different things.

**CJK (日本語).** The benign case, and worth stating precisely because
it is where an author's intuition is safest: 3 bytes each, 1 UTF-16
unit each, 1 scalar each, 1 grapheme each. Every unit agrees except
bytes, and the byte factor is a clean 3×. No snapping anywhere in the
measurements (mac: `select{3,1}` → `{3,1}`; GTK: offsets 1,4,7).

**CRLF, the fifth hazard nobody listed.** Not a Unicode question and
the more likely one to ship: GTK stores a pasted CRLF as two
characters and kaya's `lf()` (`gtk.rs:40`) hands the guest one, so
guest offsets and buffer offsets differ by one per pasted break;
WinUI stores one CR per LF so its `lf()` (`winui/mod.rs:1916`) is
length-preserving. Swift additionally treats CRLF as a **single
Character** — already a trap in this repo (docs/traps.md:1325-1336),
already the cause of one platform-specific false pass.

---

## §5 — What the 9 guest languages natively produce

Measured (`units/m.*`), on `ab` + ZWJ-family + `cd` — "what integer
does the language's own index-of return for `cd`":

| language | natural unit | index of `cd` | its own length | detects a split? |
| --- | --- | --- | --- | --- |
| **Rust** | **UTF-8 bytes** | 27 | 29 | **YES — panics, naming the character** |
| **Go** | **UTF-8 bytes** | 27 | 29 | no — `s[:3]` yields invalid UTF-8 silently |
| **OCaml** | **UTF-8 bytes** | 27 | 29 | not by default (`String.get_utf_8_uchar` can, opt-in) |
| **C** | **UTF-8 bytes** | 27 | 29 | no |
| **Python** | scalars | 9 | 11 | n/a (cannot split a scalar) |
| **Haskell** | scalars | 9 | 11 | n/a |
| **Java** | UTF-16 | 13 | 15 | no — `substring` gives a lone surrogate, UTF-8 encodes it as `?` |
| **C#** | UTF-16 | 13 | 15 | no — encodes it as U+FFFD |
| **Swift** | **graphemes** | **3** | **5** | n/a for `String`, and it silently rounds a UTF-16 offset: `String.Index(utf16Offset: 3, in: "ab😀cd")` slices to `"ab"` yet reports `utf16Offset == 3` |

Four of nine give byte offsets for free — more than any other unit —
and, decisively, **the four that do not are exactly the four whose
runtimes cannot produce a malformed byte offset by accident**: a Python
or Haskell scalar index and a Java or C# UTF-16 index both convert to a
byte offset that is a code-point boundary by construction (a lone
surrogate cannot survive the UTF-8 encode the wire already performs —
DESIGN.md:380-382, and Swift cannot even *spell* one: `UnicodeScalar(0xD83D)`
is nil, measured `units/appkit.swift`). The malformed byte offset is
reachable in practice only from the byte languages, where it is a slice
of the app's own string — and Rust, the reference binding, refuses it
itself.

**Stdlib grapheme segmentation exists in 3 of 9 (Swift, Java, C#), and
two of the three disagree.** Rust, Go, Python, Haskell, OCaml and C
would each need a third-party segmenter. That alone ends the grapheme
candidacy.

**Per-binding sugar this implies** (a sweep item, invariant 2): each
binding should ship the conversion so no app hand-rolls it —
`byte_offset(text, native_index)` and back. Rust/Go/OCaml/C: identity.
Python: `len(s[:i].encode())`. Java/C#: `getBytes(UTF_8).length` of the
prefix. Swift: `s.utf8.distance(...)` / `String.Index.utf8Offset`.
Haskell: `BS.length . TE.encodeUtf8 . T.take i`. All one-liners, all
stdlib. `tools/check-sugar-surface.py` is the natural home for the
"all 8 have it" clause.

---

## §6 — Why not the other three

**UTF-16 code units** (native to 4 of 5 backends — the tempting
answer). Rejected: it is native to *no* part of kaya. The core's text
is a Rust `String`; the wire is UTF-8; four bindings have no UTF-16
view of their strings without an explicit re-encode; and validity
becomes O(n) (you must decode to know whether index k is a low
surrogate). It also *imports* the failure it is supposed to avoid: a
UTF-16 offset can split a character just as a byte offset can, but the
core would have to build a UTF-16 image of the text to find out. The
only thing it buys is skipping a 39 µs conversion.

**Unicode scalars / code points** (native to GTK, to Python and
Haskell). The strongest rival, because a scalar offset **cannot split a
code point** — the illegal state is unrepresentable, which is the kind
of argument this repo likes. Rejected on three measurements:
(a) it removes one failure mode of three — out-of-bounds and
mid-grapheme remain, so validation is still required, and validation
becomes O(n) instead of 69 ns;
(b) it makes the wire's unit differ from the wire's encoding, so the
four byte-native bindings must walk their own string to convert, and
that walk is where the bug would live — in 4 languages instead of 1;
(c) the core would still have to convert to UTF-16 for 4 of 5 backends,
so it buys a conversion only on linux.

**Extended grapheme clusters** (what a user calls a character).
Rejected by measurement, not taste: `java.text.BreakIterator` says
**11** where .NET `StringInfo` and Swift say **5** for the identical
string; six of nine bindings have no segmenter at all; and the
segmentation depends on the Unicode version each runtime shipped, so
the *same* kaya build would mean different things on two Androids. A
unit whose definition is a per-runtime data table cannot be the wire's
unit. (It remains the right unit for a *user-facing* API someday —
"select the word", "extend by a character" — where each platform's own
notion is what the user wants. That is a different milestone.)

---

## §7 — The rule, and where it sits

**WHERE.** One chokepoint in the core, in the apply path where the
range op meets `field_text` — the same place `absorb_text_writes`
already reaches for that widget's text (`scene.rs:2200-2217`). Not in
the bindings (8 copies), not in the backends (5 copies, two of them in
string-matched interpreters). A guest that never calls a validator
still cannot get past it. This is invariant 3's "wall where someone
walks into it by doing something basic": the basic thing is declaring
a range at all.

**WHAT.** In order, so the message is the most specific true thing:

1. `start <= end` — else refuse: *"kaya: highlight_ranges on <widget>:
   start 12 is after end 4"*.
2. `end <= text.len()` — else refuse, naming both: *"kaya: … end 40 is
   past the end of the text (29 bytes)"*. **This clause is not
   optional politeness: an out-of-range highlight on mac aborts the
   process with NSRangeException (measured, exit 134).**
3. `text.is_char_boundary(start)` and `…(end)` — else refuse, in
   Rust's own idiom, which is the best error message in this space:
   *"kaya: … byte offset 3 is not a character boundary; it is inside
   '😀' (bytes 2..6)"*. The core can name the character because it has
   the text.

**HOW IT REFUSES: it panics, like the wire's UTF-8 check.** Not a
silently dropped op, not a snap. Justification, in the repo's own
terms: (a) it is the same class as `wire.rs:278`'s
`expect("kaya: string value is not UTF-8")` — an app-programming error,
not a user event; (b) CLAUDE.md's guard doctrine already prices this
("a wrong scene name panics the guest"); (c) snapping is what the
platforms do, and the measurements show snapping is *not one behavior*
— adopting it would mean adopting whichever platform ran first;
(d) a dropped op is the failure that ships, because the app sees a
highlight that did not appear and blames the backend.
**Uniformity note (invariant 1):** the refusal must be spelled in each
language's idiom and be observable in all 8 — this is the shape
`tools/check-abort.py` already enforces for abort, and the ranges
milestone should extend that gate rather than invent a new one.

**WHAT IT DOES NOT REFUSE.** A grapheme split (carve-out, §VERDICT.3);
a zero-length range (that is a caret, and `select_range` needs it —
TOM calls it degenerate and supports it explicitly); a range that
covers the trailing newline; an empty set of ranges.

**WHAT THE BACKENDS THEN GET.** Offsets already in their own unit,
converted by the core against the same text it validated:
mac/ios/windows/android UTF-16, linux code points **and** the CRLF
correction. Each backend's arm should carry a one-line assertion that
it received the unit it expects (e.g. the lowering signature takes a
distinct type — `Utf16Offset(u32)` / `CharOffset(u32)` newtypes —
so a backend physically cannot be handed the wrong unit; types over
generation over runtime checks).

---

## §8 — The negative tests this rule needs

The rule from CLAUDE.md applies with force here: **watch each one fail,
and prove the perturbation applied.** Two of this repo's guards have
misfired by passing vacuously.

**In the core (`cargo test -p kaya`), table-driven over the five hazard
strings:**

1. **Refusal, one test per clause**, asserting the panic *message*, not
   just the panic: start > end; end past the text; start mid-code-point;
   end mid-code-point. Negative proof: delete the clause, watch the
   test fail — and since all four share one chokepoint, delete each
   clause separately (the check-tx-liveness lesson: one grep-shaped
   assertion passed with the guard deleted).
2. **Acceptance**, so the refusal cannot be over-broad: a range that
   splits the combining sequence between `e` and U+0301 is ACCEPTED
   (it is a legal code-point boundary), and a range covering the whole
   ZWJ family is accepted. **A guard that refuses these would be worse
   than none — it would make the framework unable to express a
   correct range.**
3. **The conversion table itself**, pinned: for each hazard string, the
   full byte→UTF-16 and byte→code-point maps (the tables in §2 and
   `units/conv.rs`'s output are the fixtures). A conversion regression
   then fails the first rung of the ladder. Include the ZWJ family,
   whose 27/13/9 spread catches any off-by-one that CJK would hide.
4. **The two implementations agree**: naive per-offset conversion and
   the one-pass conversion must return identical results for a random
   set of offsets (`units/conv.rs` already asserts this — `naive ==
   one-pass: true`).

**In the gates:**

5. **No offset arithmetic in the interpreters.** A grep-shaped check
   that KayaSwiftUI.swift and KayaCompose.kt contain no byte→unit
   conversion for range offsets (they receive native units). Negative
   test: add a `utf8` count in one of them and watch the gate fail.
   This belongs beside `tools/check-verbs.py`, which already knows
   both files are the historic miss layer.
6. **Every binding ships the conversion helper** — a clause in
   `tools/check-sugar-surface.py`, which already enforces "all 8 have
   it" for constructors and window props.

**In the scenes (shared verbatim, invariant 6):**

7. **The hazard scene.** `set_text` accepts arbitrary UTF-8 (only
   `type` is ASCII-restricted — `check-steps.py:1391-1397`, harness
   `unescape` at `harness.rs:1339` passes non-ASCII through), so the
   scene can seed `ab😀cd` and the ZWJ family literally. Declare a
   range over the whole emoji and assert the read-back; declare one
   over the ZWJ family whole. **Depth-arm caveat to confirm first:**
   all three step interpreters must decode the .steps file as UTF-8 —
   only the Rust one is proven (`harness.rs:95 read_to_string`) — and
   `check-steps.py`'s own lint opens the file with Python's *default*
   encoding, which is locale-dependent.
8. **The CRLF leg on linux**, the one that would otherwise ship: paste
   (or `set_text` with `\r\n` — the escape exists for exactly this,
   `harness.rs:1333-1338`) then declare a range *after* the break and
   assert it lands on the right characters. Negative test: remove the
   line-ending correction from the GTK conversion and watch this leg
   fail. Nothing else in the matrix would catch it.
9. **The refusal is observable in all 8 bindings** — the check-abort
   shape, one leg per language, so the "refuse loudly" semantics is
   uniform rather than Rust-only.

---

## §9 — Findings in passing (for the depth arm)

- **A live defect, one line**: `crates/kaya/src/winui/mod.rs:5967`
  computes a caret with `chars().count()` (scalars) and passes it to
  `SetRange`/`SetSelectionStart` (UTF-16). ASCII-safe today because
  `type` is ASCII-only; wrong the moment a non-BMP character precedes
  the caret. Fix with the milestone, and let the newtype in §7 make it
  unrepresentable.
- **The GTK CRLF coordinate divergence** (§3 linux, §4) is arguably a
  pre-existing wart, like the missing viewport the linux probe found:
  the guest's text and the widget's buffer are already in different
  coordinate spaces on that backend, and ranges are simply the first
  feature that can observe it.
- **`lf()` is duplicated verbatim** in `gtk.rs:40-46` and
  `winui/mod.rs:1916-1922` — two backends, one function, and now a
  third consumer (offset correction) that must agree with both. Worth a
  shared home when the correction lands.
- **Not measured anywhere yet, and someone must**: what each platform
  *paints* for a mid-grapheme highlight (the carve-out says the range
  covers the code points it names and the platform may widen the
  paint — that "may" should become a measured "does/does not" per
  backend before it is written into DESIGN.md).

---

## §10 — Evidence index

All under `docs/probes/units/` (recovered there 2026-08-19; originally a session scratch directory):

| file | what it measures |
| --- | --- |
| `table.py` | the four-unit offset table for six hazard strings |
| `m.rs` `m.go` `m.py` `m.c` `m.ml` `M.hs` `M.java` `m.cs` `m.swift` | what each guest language's own index-of returns, and what its slice at a split offset produces (the C# one was run as `Program.cs` of a throwaway `dotnet new console`, since deleted) |
| `appkit.swift` | NSTextView/NSString units, snapping, `rangeOfComposedCharacterSequence`, highlight acceptance, out-of-range proposal |
| `appkit2.swift` (+ `out.*.txt`) | which endpoint AppKit snaps, what a split selection copies as, and the exit-134 NSRangeException abort |
| `s2u.swift` | Swift-side byte→UTF-16 conversion with exact boundary detection |
| `gtkunits.c` | GTK4 4.18.6 live: buffer char counts, offset→byte map, the mid-character byte-index warning, cursor positions, tag/select snapping, pango byte attrs, entry select_region |
| `conv.rs` | core-side conversion cost and O(1) validation cost, two implementations cross-checked |

Vendor documents quoted: ITextRange (tom.h) reference — cp clamping,
the story invariant, the final CR; ITextRange::SetRange; ITextRange2::GetChar2
— a cp inside a surrogate pair; androidx-main `TextFieldBuffer.kt` —
`requireValidRange` bounds-only, and the surrogate-snapping KDoc on
`selection`, `placeCursorBeforeCharAt`, `placeCursorAfterCharAt`.

Repo evidence quoted by file:line throughout §1, §3 and §9.
