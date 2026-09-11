# loro's offset units, measured

`docs/rich-text-plan.md` §3 unknown 6, and the first of the two caveats
`docs/probes/richtext-crdt-2026-09-11.md` §6 names. The survey could not
verify loro's emitted delta unit — `loro.dev/docs/tutorial/text` answers
HTTP 403 to an automated fetch — and wrote:

> "by symmetry with those defaults the emitted delta lengths are unicode
> scalars in the Rust build and UTF-16 in the wasm/JS build.
> **[INFERENCE — UNVERIFIED, and it is the one number a kaya bridge would
> be wrong about.]**" — `docs/probes/richtext-crdt-2026-09-11.md:192-198`

**The inference was right.** Measured below.

- Probe: `tmp/richtext/probes/loro/src/main.rs`, its own cargo workspace,
  `loro = "=1.16.0"` — still the newest on crates.io
  (`https://crates.io/api/v1/crates/loro`: max_version 1.16.0, published
  2026-09-06; the next one down is 1.13.9, 2026-08-01).
- Full output: `tmp/richtext/probes/loro/output.txt` (178 lines). Every
  line quoted below is from that file.
- Specimen, as the charge named it: `"héllo 👋 世界 e\u{301}"` —
  `22 UTF-8 bytes, 13 unicode scalars, 14 UTF-16 code units`.
- Run: `cd <probe dir> && nix develop -c cargo run --release` from the
  kaya checkout. Nothing in the kaya repository was touched.

```
== loro 1.16.0 (crates.io newest, 2026-09-06), non-wasm Rust build ==
   LORO_VERSION reported by the crate: 1.16.0
```

---

## The answer in one line

**loro's emitted `TextDelta` counts UNICODE SCALARS, on both the local
and the remote side, and so does its cursor — while the write side is
tri-unit and takes kaya's UTF-8 bytes directly. A kaya↔loro bridge
converts on the READ side only; that asymmetry is the whole finding.**

---

## 1. The unit of the write methods

### insert

```
   insert      (3, "X") -> "hélXlo 👋 世界 e\u{301}"   X landed at byte 4; that offset is unicode scalars = UTF-16 units (bytes 4, scalars 3, utf16 3)
   insert      (8, "X") -> "héllo 👋 X世界 e\u{301}"   X landed at byte 12; that offset is unicode scalars (bytes 12, scalars 8, utf16 9)
   insert_utf8 (3, "X") -> "héXllo 👋 世界 e\u{301}"   X landed at byte 3; that offset is UTF-8 bytes (bytes 3, scalars 2, utf16 2)
   insert_utf8 (8, "X") -> REFUSED: Cannot insert or delete utf-8 in the middle of the codepoint in Unicode
   insert_utf16(3, "X") -> "hélXlo 👋 世界 e\u{301}"   X landed at byte 4; that offset is unicode scalars = UTF-16 units (bytes 4, scalars 3, utf16 3)
   insert_utf16(8, "X") -> "héllo 👋X 世界 e\u{301}"   X landed at byte 11; that offset is UTF-16 units (bytes 11, scalars 7, utf16 8)
```

Position 3 alone cannot tell the three apart — at that offset scalars and
UTF-16 units coincide — so the probe also drives position 8, where all
three differ. The plain method is **unicode scalars**, `_utf8` is **UTF-8
bytes**, `_utf16` is **UTF-16 code units**, each exactly as named.

`insert_utf8` at a byte that is not a code-point boundary is **refused**,
by a named error, not silently rounded. That matters for kaya: the core's
own chokepoint already refuses a non-boundary offset
(`docs/ranges-units.md:14`, `:453-492`), so the two refusals agree and a
bridge never has to decide which wins.

### delete

```
   delete      (6, 1) -> "héllo  世界 e\u{301}"
   delete      (7, 4) -> "héllo 👋e\u{301}"
   delete      (6, 2) -> "héllo 世界 e\u{301}"
   delete_utf8 (6, 1) -> "héllo👋 世界 e\u{301}"
   delete_utf8 (7, 4) -> "héllo  世界 e\u{301}"
   delete_utf8 (6, 2) -> REFUSED: Cannot insert or delete utf-8 in the middle of the codepoint in Unicode
   delete_utf16(6, 1) -> REFUSED: Cannot insert or delete utf-16 in the middle of the codepoint in Unicode
   delete_utf16(7, 4) -> REFUSED: Cannot insert or delete utf-16 in the middle of the codepoint in Unicode
   delete_utf16(6, 2) -> "héllo  世界 e\u{301}"
```

`delete(6, 1)` removes the emoji — one scalar. `delete_utf8(7, 4)`
removes the same emoji — four bytes. `delete_utf16(6, 2)` removes it
again — two UTF-16 units. Both position *and* length are in the method's
own unit, and a length that would cut a code point in half is refused.

### mark

世界 in the specimen is `bytes 12..18, scalars 8..10, utf16 9..11`, and
each family accepts exactly its own range:

```
   mark      (8..10) -> richtext [{"insert":"héllo 👋 "},{"attributes":{"bold":true},"insert":"世界"},{"insert":" é"}]
   mark      (12..18) -> REFUSED: Index out of bound. The given pos is 18, but the length is 13. Position: /Users/akhilindurti/.cargo/registry/src/index.crates.io-1949cf8c6b5b557f/loro-internal-1.16.0/src/handler.rs:2436
   mark_utf8 (12..18) -> richtext [{"insert":"héllo 👋 "},{"attributes":{"bold":true},"insert":"世界"},{"insert":" é"}]
   mark_utf16(9..11) -> richtext [{"insert":"héllo 👋 "},{"attributes":{"bold":true},"insert":"世界"},{"insert":" é"}]
```

The two wrong-unit ranges that happen to be *in bounds* are accepted and
mark the wrong text, which is the silent failure a bridge has to avoid:

```
   mark      (9..11) -> richtext [{"insert":"héllo 👋 世"},{"attributes":{"bold":true},"insert":"界 "},{"insert":"é"}]
   mark_utf16(8..10) -> richtext [{"insert":"héllo 👋"},{"attributes":{"bold":true},"insert":" 世"},{"insert":"界 é"}]
```

**`mark_utf8` does NOT refuse a range that splits a code point** — unlike
`insert_utf8`/`delete_utf8`:

```
   a mark_utf8 range that SPLITS a code point (bytes 1..2, inside 'é'):
     ACCEPTED -> richtext [{"insert":"h"},{"attributes":{"bold":true},"insert":"é"},{"insert":"llo 👋 世界 é"}]
```

Bytes 1..2 is the first half of `é`; loro widened it to the whole
character rather than refusing. kaya's own validator refuses that range
before it could ever reach loro, so this is a difference in strictness,
not a hazard — but it is one more reason the refusal must stay on kaya's
side and not be delegated.

### unmark — the hole in the tri-unit surface

```
   unmark family: the crate has unmark(Unicode) and unmark_utf16 ONLY —
   there is no unmark_utf8 (and no splice_utf8). Checked by name:
     LoroText::unmark        exists
     LoroText::unmark_utf16  exists
     LoroText::unmark_utf8   DOES NOT EXIST in loro 1.16.0
```

Verified against the crate source
(`~/.cargo/registry/src/index.crates.io-*/loro-1.16.0/src/lib.rs:2680` and
`:2686`): the only two `unmark` methods are the Unicode one and the
UTF-16 one. `splice` has `splice_utf16` and no `splice_utf8` either.

The survey's §1 listing —
`mark_utf8(range, key, value) / mark_utf16(..) / unmark(range, key)`
(`docs/probes/richtext-crdt-2026-09-11.md:164`) — is accurate about what
exists, but §4's conversion table says of loro
"`mark_utf8(range, key, value)`; expand set once via `config_text_style`"
(`:532`) and reads as though the whole mark surface were byte-addressable.
**Removing a mark is not.** A bridge must convert for `unmark`, and loro
ships the converter:

```
   convert_pos(byte 12, Bytes->Unicode) = 8; convert_pos(byte 18, ..) = 10
   unmark(8..10) after the byte->scalar conversion -> richtext [{"insert":"héllo 👋 世界 é"}]
```

`LoroText::convert_pos(index, from: PosType, to: PosType)` converts
between `Bytes`, `Unicode`, `Utf16`, `Event` and `Entity`.

---

## 2. The unit of the emitted delta — the unknown

The subscription is `doc.subscribe_root`, the payload
`Diff::Text(Vec<TextDelta>)`, and events arrive on `doc.commit()`.

### An insert immediately after the emoji

The caret after `👋` is byte 11, scalar 7, UTF-16 unit 8 — three
different numbers, so the leading `Retain` names the unit outright:

```
   insert_utf8(byte 11, "!")  [immediately after 👋]
     emitted: Retain(7), Insert("!")
     >>> Retain = 7; that is unicode scalars (bytes 11, scalars 7, utf16 8)
```

### A mark over the CJK run

```
   mark_utf8(bytes 13..19, bold) over 世界 in "héllo 👋! 世界 e\u{301}"
     emitted: Retain(9), Retain(2, {bold=true})
     >>> leading Retain = 9; that is unicode scalars (bytes 13, scalars 9, utf16 10)
     >>> marked Retain  = 2 {bold=true}; that is unicode scalars = UTF-16 units (bytes 6, scalars 2, utf16 2)
```

### A delete of the emoji

```
   delete_utf8(byte 7, 4 bytes) removing 👋 from "héllo 👋! 世界 e\u{301}"
     emitted: Retain(6), Delete(1)
     >>> Delete = 1; that is unicode scalars (bytes 4, scalars 1, utf16 2)
```

`Delete` is the sharpest of the three: 4 bytes, 2 UTF-16 units, **1**
scalar, and loro emitted 1.

### The receiving side answers the same

A bridge sees remote edits through `import`, not through its own commit,
so the probe measures that separately — a forked peer makes the same
insert and its update is imported:

```
   the same question on the RECEIVING side (import, not local commit):
     imported: Retain(7), Insert("?")
     >>> Retain = 7; that is unicode scalars (bytes 11, scalars 7, utf16 8)
```

### `to_delta()` and `get_richtext_value()` on a marked document

Neither carries a length at all — both are pure `Insert` sequences, so
the unit question does not arise for them:

```
   the marked document, read back two ways:
     to_delta()            = Insert("héllo ! "), Insert("世界", {bold=true}), Insert(" e\u{301}")
     get_richtext_value()  = [{"insert":"héllo ! "},{"attributes":{"bold":true},"insert":"世界"},{"insert":" é"}]
     to_string()           = "héllo ! 世界 e\u{301}"
     len_utf8 19 / len_unicode 13 / len_utf16 13
```

That is the shape `docs/rich-text-plan.md` R1 calls `set_rich_text(spans)`
— `(text, attrs)` pairs, lengths implied by the strings — so the
whole-document read needs no conversion in either direction. It is only
the *incremental* delta that counts scalars.

`slice_delta(start, end, PosType)` does take an explicit coordinate
system, and all three agree on the content:

```
   slice_delta over the whole document, per PosType:
     Bytes    0..19 -> Insert("héllo ! "), Insert("世界", {bold=true}), Insert(" e\u{301}")
     Unicode  0..13 -> Insert("héllo ! "), Insert("世界", {bold=true}), Insert(" e\u{301}")
     Utf16    0..13 -> Insert("héllo ! "), Insert("世界", {bold=true}), Insert(" e\u{301}")
```

### Why it is scalars, from the source

The measurement is the finding; the mechanism confirms it will not drift.
`TextDelta::from_text_diff` copies `rle_len()` off the `StringSlice`, and
that length is compiled, not configured
(`loro-internal-1.16.0/src/utils/string_slice.rs:197-205`):

```rust
impl HasLength for StringSlice {
    fn rle_len(&self) -> usize {
        if cfg!(feature = "wasm") {
            count_utf16_len(self.bytes())
        } else {
            count_unicode_chars(self.bytes())
        }
    }
}
```

Same switch on `len_event()`
(`loro-internal-1.16.0/src/container/richtext/richtext_state.rs:2859-2867`)
and on `PosType::Event`, whose doc comment says so:

```rust
    /// The index is based on the length of the text in events.
    /// It is determined by the `wasm` feature.
    Event,
```

**And a Rust consumer cannot reach that switch.** The `loro` façade crate
declares no `wasm` feature at all —

```
   the `loro` crate exposes NO `wasm` feature (Cargo.toml features: counter, default, jsonpath, logging),
   so a Rust consumer cannot switch the event coordinate that loro-internal's `wasm` feature switches.
```

— so for anything built on `loro 1.16.0` the emitted unit is scalars, and
for `loro-crdt` in the browser it is UTF-16. Neither is kaya's byte.

---

## 3. `config_text_style` / `ExpandType` at a run's boundary

**loro already ships kaya's v1 expand policy as its default.** A bare
`LoroDoc::new()` carries `StyleConfigMap::default_rich_text_config()`
(`loro-internal-1.16.0/src/container/richtext/config.rs:52-105`):

```
     bold/italic/underline = After; link/highlight/comment/code = None
```

which is exactly the split `docs/rich-text-plan.md` R3 assumes (typing
grows an inline style; a link never grows by typing). Note `code` is
`None` there, so a `code` run does **not** grow by typing, unlike the
other inline styles — worth a ruling if kaya's `code` is meant to behave
like `bold`.

An unconfigured key is **refused**, which is a good wall and a trap for
kaya's `strike`, `block`, `heading` and `code_block`, none of which is in
loro's default map:

```
   an UNCONFIGURED key ('strike') on a default doc: REFUSED: Style configuration missing for "(InternalString("strike"))". Please provide the style configuration using `configTextStyle` on your Loro doc.
```

With `bold = After` and `link = None` set explicitly:

```
     insert at the END of the bold run   -> [{"attributes":{"bold":true},"insert":"boldX"},{"insert":" plain"}]
     insert at the END of the link run   -> [{"attributes":{"link":"https://kaya.dev"},"insert":"link"},{"insert":"X plain"}]
     insert at the START of the bold run -> [{"insert":"xxY"},{"attributes":{"bold":true},"insert":"bold"},{"insert":" plain"}]
     insert at the START of the link run -> [{"insert":"xxY"},{"attributes":{"link":"https://kaya.dev"},"insert":"link"},{"insert":" plain"}]
```

Typing at the end of the bold run inherits bold; typing at the end of the
link run does not inherit the link. That is the behaviour
`tools/richtext/automerge-probe` models by hand in `Mirror::user_edit`
(it strips `link` from the inherited attributes and marks the rest with
`ExpandMark::After`); **loro gives it for free, from configuration
rather than from per-call reconciliation.**

The whole table, local sequential inserts, bold only:

```
     After    end-insert   [{"insert":"xx"},{"attributes":{"bold":true},"insert":"boldE"},{"insert":"xx"}]
              start-insert [{"insert":"xxS"},{"attributes":{"bold":true},"insert":"bold"},{"insert":"xx"}]
     Before   end-insert   [{"insert":"xx"},{"attributes":{"bold":true},"insert":"bold"},{"insert":"Exx"}]
              start-insert [{"insert":"xx"},{"attributes":{"bold":true},"insert":"Sbold"},{"insert":"xx"}]
     Both     end-insert   [{"insert":"xx"},{"attributes":{"bold":true},"insert":"boldE"},{"insert":"xx"}]
              start-insert [{"insert":"xx"},{"attributes":{"bold":true},"insert":"Sbold"},{"insert":"xx"}]
     None     end-insert   [{"insert":"xx"},{"attributes":{"bold":true},"insert":"bold"},{"insert":"Exx"}]
              start-insert [{"insert":"xxS"},{"attributes":{"bold":true},"insert":"bold"},{"insert":"xx"}]
```

Four for four with the documented sentence: `After` grows at the end
only, `Before` at the start only, `Both` at both, `None` at neither.

---

## 4. Two docs: a concurrent insert at the START of a bold run

This is the case the charge names, the one
`tools/richtext/automerge-probe` measured for automerge. **The answer is
that for loro the expand rule does not decide it at all.**

Doc A writes `"Hello world"`; B forks *before* the mark; A then bolds
`world` (6..11) while B, concurrently, inserts `"NEW"` at 6 — the start
of what A bolded. Peer ids pinned at A=1, B=2 so the record is
reproducible:

```
   bold expand=After
     A after merge: [{"insert":"Hello "},{"attributes":{"bold":true},"insert":"NEWworld"}]
     B after merge: [{"insert":"Hello "},{"attributes":{"bold":true},"insert":"NEWworld"}]
     converged: true
   bold expand=Before
     A after merge: [{"insert":"Hello "},{"attributes":{"bold":true},"insert":"NEWworld"}]
     B after merge: [{"insert":"Hello "},{"attributes":{"bold":true},"insert":"NEWworld"}]
     converged: true
   bold expand=Both
     A after merge: [{"insert":"Hello "},{"attributes":{"bold":true},"insert":"NEWworld"}]
     B after merge: [{"insert":"Hello "},{"attributes":{"bold":true},"insert":"NEWworld"}]
     converged: true
   bold expand=None
     A after merge: [{"insert":"Hello "},{"attributes":{"bold":true},"insert":"NEWworld"}]
     B after merge: [{"insert":"Hello "},{"attributes":{"bold":true},"insert":"NEWworld"}]
     converged: true
```

All four `ExpandType`s give the same answer — including `None`, which is
the one that must not expand. The probe then asks whether the peer-id
tie-break is what is really deciding, by running each expand type with
the two peer orderings:

```
   is the concurrent outcome the EXPAND RULE, or the peer-id tie-break?
   the same concurrent case with A's and B's peer ids set explicitly, both ways round:
     After    marker=1 inserter=2: NEW came out BOLD   |   marker=2 inserter=1: NEW came out plain
     Before   marker=1 inserter=2: NEW came out BOLD   |   marker=2 inserter=1: NEW came out plain
     Both     marker=1 inserter=2: NEW came out BOLD   |   marker=2 inserter=1: NEW came out plain
     None     marker=1 inserter=2: NEW came out BOLD   |   marker=2 inserter=1: NEW came out plain
```

**The outcome tracks the peer ids and ignores the expand type entirely.**
The sequential control — B forks *after* the mark, so the insert happens
after it rather than concurrently — puts the expand rule back in charge,
and it is correct on all four:

```
   and the SEQUENTIAL control (B forked AFTER the mark, inserts at the start):
   bold expand=After  -> [{"insert":"Hello NEW"},{"attributes":{"bold":true},"insert":"world"}]
   bold expand=Before  -> [{"insert":"Hello "},{"attributes":{"bold":true},"insert":"NEWworld"}]
   bold expand=Both  -> [{"insert":"Hello "},{"attributes":{"bold":true},"insert":"NEWworld"}]
   bold expand=None  -> [{"insert":"Hello NEW"},{"attributes":{"bold":true},"insert":"world"}]
```

So the rule loro actually implements is: **`ExpandType` governs an
insertion that happens-after the mark; an insertion CONCURRENT with the
mark is placed by the sequence CRDT's own tie-break, and the mark's
anchors then simply contain whatever landed inside them.** Both replicas
converge in every case (`converged: true` on all four), so this is a
semantics question, not a correctness bug — but "a link does not grow by
typing" is only true against a mark the typist had already seen.

Nothing here touches kaya: `docs/rich-text-plan.md` §2 already rules that
kaya carries no expand flag on the wire, and this measurement is one more
argument for that — the flag would not even be authoritative.

---

## 5. Cursor: `get_cursor(pos, Side)` and `get_cursor_pos`

**loro's `Side` is `Left(-1)` / `Middle(0, default)` / `Right(1)`**, not
the `Before`/`After` that automerge's `MoveCursor` and yrs's `Assoc` use
(`loro-internal-1.16.0/src/cursor.rs:20-25`). `get_cursor_pos` answers a
`PosQueryResult { update, current: AbsolutePosition { pos, side } }`.

### The cursor's unit is the delta's unit

```
   the caret sitting immediately after 👋 is byte 11, scalar 7, utf16 8.
     get_cursor(11, Middle) -> get_cursor_pos = 11 (side Middle); as a byte offset that is Some(19)
     get_cursor(7, Middle) -> get_cursor_pos = 7 (side Middle); as a byte offset that is Some(11)
     get_cursor(8, Middle) -> get_cursor_pos = 8 (side Middle); as a byte offset that is Some(12)
```

Ask for 7 and you get 7 back, and its byte offset is 11 — the caret you
meant. Ask for 11 and you get a cursor 19 bytes in. The parameter and the
result are both **event indices**, which in this build are scalars: the
crate's own internals name it (`handler.rs:2701`,
`pub fn get_cursor(&self, event_index: usize, side: Side)`). Same
coordinate as the delta, which is the tidy half of the finding — one
conversion covers both.

### The caret rule, against R5

R5 rules: "a caret exactly at the start moves past the insertion"
(`docs/rich-text-plan.md:R5`). Caret at 3 in `"abcdef"`, then `"XYZ"`
arrives at 3, local and remote:

```
     Side::Left   before 3 -> LOCAL insert 6 (moves AFTER the insertion), REMOTE insert 6 (moves AFTER the insertion)
     Side::Middle before 3 -> LOCAL insert 6 (moves AFTER the insertion), REMOTE insert 6 (moves AFTER the insertion)
     Side::Right  before 3 -> LOCAL insert 6 (moves AFTER the insertion), REMOTE insert 6 (moves AFTER the insertion)
```

**All three sides agree with R5, and none of them can express the other
choice.** The mechanism is in the source: `get_cursor` anchors to the id
of the character *at* `index` — the one to the right
(`richtext_state.rs:2844-2857`, `get_text_entity_ranges(pos, 1, kind)`
then `a.id_start`) — and `get_relative_position` consults `pos.side`
**only when the cursor has no anchored id at all**
(`state.rs:2125-2151`). So for any caret inside the text, `Side` is
carried along and ignored.

That is convenient for kaya — the ruled rule is the only one loro has —
but it means a kaya↔loro bridge cannot get "stay before the insertion"
out of loro's cursor if a future ruling ever wanted it.

### The two edges where `Side` does something

At the end of a non-empty document, `get_cursor` **overrides** the
requested side to `Right` (`handler.rs:2743-2750`), so a caret at the end
always follows appended text:

```
   a caret at the END of "abcdef" (pos 6), then "XYZ" is appended:
     Side::Left   before pos 6 side Right -> after append pos 9 (moves AFTER the appended text)
     Side::Middle before pos 6 side Right -> after append pos 9 (moves AFTER the appended text)
     Side::Right  before pos 6 side Right -> after append pos 9 (moves AFTER the appended text)
```

On an **empty** document — the one case with no character to anchor to —
`Side` is finally load-bearing, and `Middle` is normalised to `Left`:

```
   a caret on an EMPTY document, then "abc" is inserted:
     Side::Left   before pos 0 side Left -> after insert pos 0
     Side::Middle before pos 0 side Left -> after insert pos 0
     Side::Right  before pos 0 side Right -> after insert pos 3
```

### Deletion of the pointed-at character

```
   deletion of the pointed-at character ("abcdef", caret 3, delete 2..4):
     Side::Left -> "abef", pos 2 side Left
     Side::Middle -> "abef", pos 2 side Left
     Side::Right -> "abef", pos 2 side Left
```

The cursor survives the deletion of its anchor and reports the deletion
point with `side: Left` — the analogue of automerge's `MoveCursor`
fallback, and again not selectable.

---

## 6. Cost, beside automerge's 0.024 ms

A 51 KB document with 40 bold runs, the same shape
`tools/richtext/automerge-probe` benchmarks. Median of 1000, with mean,
p95 and max beside it because a median alone hides a CRDT's rebalancing:

```
   document: 52200 bytes (51.0 KB), 52200 unicode scalars, 40 bold runs
   insert_utf8 + commit + the emitted delta read back, over 1000 edits:
     median 0.0024ms  mean 0.0024ms  p95 0.0032ms  max 0.0146ms   (1000 events seen, one per edit)
   insert_utf8 + commit with NO subscriber, over 1000 edits:
     median 0.0009ms  mean 0.0011ms  p95 0.0016ms  max 0.0139ms
   import(one remote edit) + the emitted delta read back, over 1000 edits:
     median 0.0267ms  mean 0.0265ms  p95 0.0467ms  max 0.0970ms   (1000 events seen)
   to_delta() over the whole document,            median of 20:   0.1324ms
   get_richtext_value() over the whole document,  median of 20:   0.1202ms
   (automerge 0.11.0, same shape, docs/measurements/richtext-automerge-2026-09-11.txt:
    bridged edit from its own patch 0.024ms; a spans() document walk 0.63ms)
```

- **A local edit with its delta read back costs 0.0024 ms** — about 10×
  cheaper than automerge's 0.024 ms for the same job. Part of that gap is
  that automerge's bridged edit also *reconciles* the inserted run's
  marks against what expand produced, which loro does not need because
  expand is configured per key (§3).
- The subscription's own work is most of that: 0.0009 ms with no
  subscriber, 0.0024 ms with one. `tools/richtext/automerge-probe`
  reports a MEAN over 2000 edits, and loro's mean here equals its median
  (0.0024 ms), so the two figures compare directly.
- **Applying a remote edit costs 0.0267 ms**, roughly 11× a local one,
  and that is the number a collaborative bridge actually lives on.
- The document walk is **0.13 ms**, against automerge's 0.63 ms `spans()`
  — so even loro's *slow* path is cheaper than automerge's. Both are far
  too slow to run per keystroke; `docs/rich-text-plan.md` R1's incremental
  `apply_edit` is the right shape for both crates.

Measured on the maintainer's mac inside the dev shell, release profile,
with other work on the host — treat the ratios as the finding, not the
absolute microseconds (CLAUDE.md invariant 8's usual caveat).

---

## What this changes in the plan

- **§3 unknown 6 is closed.** The emitted unit is unicode scalars.
- **R2 needs one sentence amended.** It reads "Identity conversion for
  automerge (`Utf8CodeUnit`, its default), yrs (`OffsetKind::Bytes`, its
  default) and loro's `_utf8` family." That is true of loro's **write**
  side and false of its **read** side: a loro bridge writes kaya's bytes
  unconverted and must convert every `Retain`/`Delete` length it reads
  back, plus every `unmark` range it writes. automerge and yrs remain
  identity in both directions; loro is identity in one.
- **§6's first caveat is resolved in the direction it feared** — "If the
  emitted deltas are scalars while the writes are bytes, a kaya↔loro
  bridge converts on one side only — the classic off-by-emoji." It does,
  and it is. The recommendation of automerge as the first crate to
  measure against stands, and is strengthened.
- **Nothing kaya-side moves.** Everything above is the app's business
  (`docs/rich-text-plan.md` §2: "No CRDT anywhere in it"), and the
  conversion a loro app needs is one `convert_pos` call per delta item
  against a `LoroText` it already holds. The plan's own protocol — bytes,
  addressed, no expand flag — is unaffected, and §4's measurement is a
  third argument for the no-expand-flag ruling.

## Caveats on this measurement

1. **This is the Rust build only.** `loro-crdt` on npm is the same core
   with `wasm` on, which makes every number above UTF-16 instead. A kaya
   JS guest bridging to loro converts differently from a Rust guest
   bridging to loro — from the *same* kaya bytes. Invariant 1 is not
   threatened (kaya's own surface is unchanged), but any example or doc
   that shows the conversion must show it per language.
2. **The concurrent expand result is a semantics statement, not a bug
   report.** Both replicas converged in every case; what was measured is
   that `ExpandType` governs happens-after insertions and not concurrent
   ones. Reproducing it needs pinned peer ids — with random ones the
   outcome flips run to run, which is how the first pass of this probe
   read `Before` and `None` as inverted before the tie-break was isolated.
