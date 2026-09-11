# Rich text CRDTs and what a kaya rich-text widget must hand the app

Research report. Every claim carries a URL or `file:line`. Lines marked
**[INFERENCE]** are mine, not a source's.
Written 2026-09-11 against crate versions current on that day.

## §0 — The unit kaya already ruled, so I speak it

kaya's ranges milestone ruled the offset unit and it is not negotiable
by this report:

> "The wire carries UTF-8 BYTE offsets into the guest-visible text."
> — `docs/ranges-units.md:14`

with three qualifications (`docs/ranges-units.md:12-58`): the core
validates `start <= end`, `end <= text.len()` and `is_char_boundary` at
**one** chokepoint and **panics** on a breach (`:453-492`); the core
**converts to each backend's native unit before lowering** (mac/iOS/
Windows/Android UTF-16, GTK code points plus a CRLF correction) from its
own `field_text`, measured at 39 µs for 50 ranges over 34.8 KB
(`:29-38`, `:479-492`); and a grapheme split is an allowed, stated
carve-out, because BreakIterator counts 11 clusters where `StringInfo`
and Swift count 5 (`:39-50`).

Two more existing rulings constrain anything proposed here:

- **Ranges are app-owned and re-declared; a text edit clears them.**
  "No range tracking/adjustment machinery in the core: tracking is
  editor-component territory" (`docs/ranges-plan.md:75-86`).
- **Undo is two tiers, one surface.** Text-local undo *delegates to the
  platform's native stack*; app-state undo is core-owned; Edit>Undo asks
  the focused widget first (`docs/undo-plan.md:62-72`, `:144-162`). A
  programmatic write **resets** the widget's native undo history (D7,
  `docs/undo-plan.md:163-178`). §5 below is where this collides with a
  CRDT's own UndoManager.

"kaya unit" below means **UTF-8 byte offsets into the widget's current
guest-visible text, both endpoints on a code-point boundary**.

---

## §1 — The Rust rich-text CRDT crates, as of 2026-09-11

### Summary table

| crate | newest | released | rich text? | change it EMITS | change it CONSUMES | native offset unit |
|---|---|---|---|---|---|---|
| `automerge` | 0.11.0 | 2026-08-12 | yes, Peritext-style marks + blocks | `Patch { obj, path, action }` with `PatchAction::{SpliceText, DeleteSeq, Mark, …}` | `splice_text(obj,pos,del,&str)`, `mark(obj, Mark, ExpandMark)`, `unmark`, `update_spans` | **configurable**: `TextEncoding::{UnicodeCodePoint, Utf8CodeUnit, Utf16CodeUnit, GraphemeCluster}` |
| `loro` | 1.16.0 | 2026-09-06 | yes, Peritext-derived marks | event `Diff::Text(Vec<TextDelta>)` — Quill-shaped `Retain/Insert/Delete` with `attributes` | `insert/delete/mark/unmark` (+ `_utf8`/`_utf16` twins), `apply_delta(&[TextDelta])` | **Unicode scalars by default, with UTF-8 and UTF-16 twins on every method** |
| `yrs` | 0.27.4 | 2026-08-22 | yes, Yjs formatting attributes | `TextEvent` → `Vec<Delta<Out>>` (`Inserted/Retain/Deleted`, each with `Option<Box<Attrs>>`) | `insert`, `insert_with_attributes`, `format`, `remove_range`, `apply_delta` | **doc-wide `OffsetKind::{Bytes, Utf16}`, default `Bytes`** |
| `diamond-types` | 1.0.0 | 2022-08-25 | **no** — plain text only | — | — | — |
| `cola` | 0.5.1 | 2025-07-06 | **no** — plain text only | — | — | — |

Versions, dates and download counts from the crates.io API
(`https://crates.io/api/v1/crates/<name>`): automerge 0.11.0 /
2026-08-12 / 581,490 (repo automerge/automerge); loro 1.16.0 /
2026-09-06 / 649,554 (loro-dev/loro); yrs 0.27.4 / 2026-08-22 /
2,968,144 (y-crdt/y-crdt); diamond-types 1.0.0 / **2022-08-25** /
34,781; cola 0.5.1 / 2025-07-06 / 21,272 (nomad/cola).

### automerge 0.11.0

**What it consumes.** `Transactable` is the write surface
(<https://docs.rs/automerge/0.11.0/automerge/transaction/trait.Transactable.html>):

```rust
fn splice_text<O: AsRef<ExId>>(&mut self, obj: O, pos: usize, del: isize, text: &str)
    -> Result<(), AutomergeError>;          // "Like Self::splice but for text."
fn update_text<S: AsRef<str>>(&mut self, obj: &ExId, new_text: S) -> Result<(), AutomergeError>;
fn mark<O: AsRef<ExId>>(&mut self, obj: O, mark: Mark, expand: ExpandMark)
    -> Result<(), AutomergeError>;          // "Mark a sequence"
fn unmark<O: AsRef<ExId>>(&mut self, obj: O, key: &str, start: usize, end: usize,
    expand: ExpandMark) -> Result<(), AutomergeError>;   // "Remove a Mark from a sequence"
```

`splice` (the general one) documents the `del` sign: "If `del` is
positive then N values are deleted after position `pos` and the new
values inserted" (same page). So **one automerge edit is already
replace-shaped**: position, delete count, inserted string. That is the
single most useful fact in this report for kaya's protocol design.

`Mark` is flat — `pub struct Mark { pub start: usize, pub end: usize,
pub name: SmolStr, pub value: ScalarValue }` — and "each position in a
sequence can have only one mark with the same name, and concurrent marks
with conflicting values are resolved consistently by automerge"
(<https://docs.rs/automerge/0.11.0/automerge/marks/struct.Mark.html>).

**What it emits.** `automerge::patches::PatchAction`
(<https://docs.rs/automerge/0.11.0/automerge/patches/enum.PatchAction.html>):

```
SpliceText{ index: usize, value: ConcreteTextValue, marks: Option<MarkSet> }
DeleteSeq { index: usize, length: usize }
Mark      { marks: Vec<Mark> }
PutMap    { key: String, value: (Value<'static>, ObjId), conflict: bool }
PutSeq    { index: usize, value: (Value<'static>, ObjId), conflict: bool }
Insert    { index: usize, values: SequenceTree<(Value<'static>, ObjId, bool)> }
Increment { prop: Prop, value: i64 } | Conflict { prop: Prop }
DeleteMap { key: String }
```

A text patch stream is therefore `SpliceText` for an insertion (carrying
the marks the inserted run inherited), `DeleteSeq` for a deletion,
`Mark` for a formatting change. It is **not** a Quill delta — there is
no `Retain`, and positions are absolute indices into the current text.
**[INFERENCE]** Converting between the two is bookkeeping, but it is not
free and the direction matters (a delta is a cursor walk; a patch is an
addressed edit).

**Offset unit — the important one.** automerge is *configurable per
document*, `automerge::TextEncoding`
(<https://docs.rs/automerge/0.11.0/automerge/enum.TextEncoding.html>):

`UnicodeCodePoint` ("Each unicode code point counts as one unit"),
`Utf8CodeUnit` ("…each byte in the utf-8 encoding of the string counts
as one unit"), `Utf16CodeUnit`, `GraphemeCluster`; `platform_default()`
returns UTF-8 code units with the `utf8-indexing` feature, UTF-16 with
`utf16-indexing` ("default for automerge-wasm"), code points with
neither (same page).

**This is the one crate drivable in kaya's ruled unit with no conversion
at all**: with `TextEncoding::Utf8CodeUnit` every `pos`,
`Mark.start/end`, `SpliceText.index` and `DeleteSeq.index/length` is a
UTF-8 byte offset — exactly `docs/ranges-units.md:14`.

**Marks at a boundary.** `ExpandMark::{Before, After, Both, None}` lets
"you decide whether new text inserted at the start/end of your mark
should also inherit the mark", and the page "references the Peritext
specification"
(<https://docs.rs/automerge/0.11.0/automerge/marks/enum.ExpandMark.html>).
The expand rule is **per mark operation**, chosen by the caller. See §3.

**Reading back.** `ReadDoc`
(<https://docs.rs/automerge/0.11.0/automerge/trait.ReadDoc.html>):
`text(obj) -> String`, `marks(obj) -> Vec<Mark>`, `get_marks(obj, index,
heads) -> MarkSet`, and `spans(obj) -> Spans`, "Return the sequence of
text and block markers in the text object `obj`". `automerge::iter::Span`
(<https://docs.rs/automerge/0.11.0/automerge/iter/enum.Span.html>):

```rust
Span::Text { text: String, marks: Option<Arc<MarkSet>> }  // "A span of text and the marks that were active for that span"
Span::Block(Map)                                          // "A block marker"
```

That is exactly the shape a widget needs to *paint* a rich document.
`update_spans` is the write-side twin, configured by `UpdateSpansConfig
{ default_expand, per_mark_expands }` — "The expand flag to use when the
mark does not have a flag set in `Self::per_mark_expands`"
(<https://docs.rs/automerge/0.11.0/automerge/marks/struct.UpdateSpansConfig.html>).

### loro 1.16.0

**What it consumes.** `LoroText`
(<https://docs.rs/loro/1.16.0/loro/struct.LoroText.html>) offers every
mutation in *three units*, which is unusual and decisive for kaya:

```rust
insert(pos, s)       // "Insert a string at the given unicode position."
insert_utf8(pos, s)  // "Insert a string at the given utf-8 position."
insert_utf16(pos, s) // "…UTF-16 code unit position. …useful when working with JavaScript"
delete(pos, len) / delete_utf8(pos, len) / delete_utf16(pos, len)
mark(range: Range<usize>, key, value)  // "The range uses Unicode scalar indices;
                                       //  use [mark_utf8] for UTF-8 byte offsets."
mark_utf8(range, key, value) / mark_utf16(..) / unmark(range, key)
splice(pos, len, s) -> LoroResult<String>   // delete+insert, unicode position
apply_delta(delta: &[TextDelta])            // "Apply a delta to the text container."
update(text, options)                       // "calculate the minimal difference and apply it"
len_utf8() / len_unicode() / len_utf16()
```

So loro takes kaya's ruled unit **directly** on the write side, through
`insert_utf8` / `delete_utf8` / `mark_utf8`.

**What it emits.** `to_delta() -> Vec<TextDelta>` ("Get the text in
Delta format"), `get_richtext_value() -> LoroValue` ("Get the rich text
value in Delta format"), and on the event side
`loro::event::Diff::Text(Vec<TextDelta>)`
(<https://docs.rs/loro/1.16.0/loro/event/enum.Diff.html>).
`TextDelta` is Quill-shaped
(<https://docs.rs/loro/1.16.0/loro/enum.TextDelta.html>):

```rust
Retain { retain: usize, attributes: Option<HashMap<String, LoroValue, FxBuildHasher>> }
Insert { insert: String, attributes: Option<HashMap<String, LoroValue, FxBuildHasher>> }
Delete { delete: usize }
```

**Offset unit caveat — READ THIS.** The *write* methods are explicitly
tri-unit, but `TextDelta`'s own docs page does **not** state the unit of
`retain`/`delete`. The crate root's documentation says "Rust APIs
default to Unicode scalar positions for `insert`/`delete` and `slice`"
(<https://raw.githubusercontent.com/loro-dev/loro/main/crates/loro/src/lib.rs>),
and by symmetry with those defaults the emitted delta lengths are
unicode scalars in the Rust build and UTF-16 in the wasm/JS build.
**[INFERENCE — UNVERIFIED, and it is the one number a kaya bridge would
be wrong about.]** This must be measured before anything is built on
it: a 60-line probe that inserts an emoji and a CJK character, commits,
and prints the emitted `Retain`/`Delete` lengths settles it in minutes.
I could not verify it from a primary source — `loro.dev/docs/tutorial/text`
returns HTTP 403 to an automated fetch, and `loro/crates/loro-wasm/src/lib.rs`
truncates before the `LoroText` impl.

**Events fire on commit**, not per call: "Events are emitted after a
transaction commits. Transactions finalize when `doc.commit()` is
explicitly called, `doc.export(mode)` executes, `doc.import(data)`
processes incoming updates, `doc.checkout(version)` switches document
state" (<https://docs.rs/loro/1.16.0/loro/struct.LoroDoc.html>).
Subscription surface: `subscribe(&ContainerID, Subscriber)`,
`subscribe_root`, `subscribe_local_update`, `subscribe_pre_commit`
(same page). **[INFERENCE]** that batching maps cleanly onto kaya's
transaction model, where a batch is already the unit of apply.

### yrs 0.27.4

**What it consumes / emits.** The `Text` trait
(<https://docs.rs/yrs/0.27.4/yrs/types/text/trait.Text.html>):

```rust
fn insert(&self, txn: &mut TransactionMut, index: u32, chunk: &str);
fn insert_with_attributes(&self, txn: &mut TransactionMut, index: u32, chunk: &str, attributes: Attrs);
fn insert_embed<V>(&self, txn: &mut TransactionMut, index: u32, content: V) -> V::Return;
fn format(&self, txn: &mut TransactionMut, index: u32, len: u32, attributes: Attrs);
fn remove_range(&self, txn: &mut TransactionMut, index: u32, len: u32);
fn diff<T, D, F>(&self, _txn: &T, compute_ychange: F) -> Vec<Diff<D>>;
fn apply_delta<D, P>(&self, txn: &mut TransactionMut, delta: D);
fn len<T: ReadTxn>(&self, _txn: &T) -> u32;
```

and `yrs::types::Delta<T>`
(<https://docs.rs/yrs/0.27.4/yrs/types/enum.Delta.html>) is Quill-shaped
too:

```rust
Inserted(T, Option<Box<Attrs>>)   // "insertion of a piece of text, which optionally could have been formatted"
Deleted(u32)                      // "removing a consecutive range of characters"
Retain(u32, Option<Box<Attrs>>)   // "a number of consecutive unchanged characters … Can contain an optional set of
                                  //  attributes, which have been used to format an existing piece of text"
```

`TextEvent` (`yrs::types::text::TextEvent`) is the observer payload;
`XmlTextRef`/`XmlTextEvent` are the same machinery inside an XML tree
(<https://docs.rs/yrs/0.27.4/yrs/all.html>).

**Offset unit.** Doc-wide, not per-call:
`yrs::doc::OffsetKind`
(<https://docs.rs/yrs/0.27.4/yrs/doc/enum.OffsetKind.html>) —
`Bytes` = "Compute editable strings length and offset using UTF-8 byte
count", `Utf16` = "…using UTF-16 chars count". There are only those
two. `Options::offset_kind` is documented "How to we count offsets and
lengths used in text operations" and **defaults to `OffsetKind::Bytes`**
(<https://docs.rs/yrs/0.27.4/yrs/doc/struct.Options.html>).

So yrs, in its Rust default configuration, *also* speaks kaya's ruled
unit. (Yjs in the browser is UTF-16 and the `Utf16` setting exists so a
yrs server can interoperate with y.js clients — **[INFERENCE]** from the
two variants' wording plus Yjs's JS-string heritage.)

### diamond-types 1.0.0 — plain text only, and stale on crates.io

<https://crates.io/api/v1/crates/diamond-types>: the last published
version is **1.0.0, 2022-08-25**. The repo
(<https://github.com/josephg/diamond-types>) is not archived and shows
~1,295 commits on master, but the README states: "This version of
diamond types only supports plain text editing. Work is underway to add
support for other JSON-style data types." **No marks, no attributes.**
It is the fastest plain-text CRDT in the survey and irrelevant to a
rich-text widget except as a baseline.

### cola 0.5.1 — plain text only

<https://crates.io/api/v1/crates/cola>, newest 0.5.1, **2025-07-06**,
repo <https://github.com/nomad/cola>. "Cola is a Conflict-free
Replicated Data Type (CRDT) for real-time collaborative editing of
**plain text** documents"; its types are `Replica`, `Insertion`,
`Deletion`, `Anchor`, and `Length` is "the length of a piece of text
according to some user-defined metric"; the example keeps the `String`
buffer in the application, not in cola
(<https://docs.rs/cola/0.5.1/cola/>). **No marks.** An app could layer
its own, but that is *building* a rich-text CRDT, not using one.

Crate-level doc quote worth pinning, because it contradicts a common
belief: automerge's own root page says **"Text is encoded in UTF-8 by
default but uses UTF-16 when using the wasm target, you can configure it
with the feature `utf16-indexing`"**
(<https://docs.rs/automerge/0.11.0/automerge/index.html>).

### Others considered

- `crdt-richtext` (loro-dev) — "Rich text CRDT that implements Peritext
  and Fugue", Rust, 308 stars, **last push 2024-12-30**
  (<https://api.github.com/orgs/loro-dev/repos>). Superseded by loro
  itself; do not build on it.
- Other Yjs-compatible Rust ports (y-octo and kin) — not surveyed; yrs
  is the reference Rust Yjs and owns the binding ecosystem.
- The Peritext reference implementation is **TypeScript**, not Rust
  (<https://www.inkandswitch.com/peritext/>).

### Cursors / anchors — every rich CRDT has one, and kaya will need it

All three ship a stable position anchor — the thing that makes "apply a
remote edit without destroying the local caret" possible:

- automerge: `enum Cursor`, "An identifier of a position in a Sequence",
  plus `CursorPosition` and `MoveCursor::{Before, After}` — on deletion
  of the pointed-at character the cursor "will shift to the previous
  item that was visible at the time of cursor creation" / "the next
  item…", falling back to `0` and `sequence.length`
  (<https://docs.rs/automerge/0.11.0/automerge/index.html>,
  <https://docs.rs/automerge/0.11.0/automerge/enum.MoveCursor.html>).
- loro: `get_cursor(pos, side) -> Option<Cursor>`
  (<https://docs.rs/loro/1.16.0/loro/struct.LoroText.html>).
- yrs: `StickyIndex` — "not affected by document changes… If you place a
  sticky index before a certain character, it will always point to this
  character" — with `assoc: Assoc` and `get_offset(&txn)`
  (<https://docs.rs/yrs/0.27.4/yrs/struct.StickyIndex.html>).

---

## §2 — Bindings, per kaya guest language

kaya's nine guests are Rust, Python, Go, C#, Java, Swift, OCaml,
Haskell, JS (CLAUDE.md invariant 1). `O` = official (published by the
project org), `C` = community, `—` = none found.

| guest | automerge | loro | yrs / Yjs |
|---|---|---|---|
| **Rust** | O — the crate itself, `automerge` 0.11.0 | O — `loro` 1.16.0 | O — `yrs` 0.27.4 |
| **JS** | O — `@automerge/automerge` **3.4.1** npm, "backed by @automerge/automerge-wasm" | O — `loro-crdt` **1.16.1** npm, repo loro-dev/loro | O — Yjs itself (the reference impl is JS); `ywasm/` in the y-crdt monorepo for the Rust port |
| **Python** | O — `automerge/automerge-py`, pushed 2026-06-19 | O — `loro-dev/loro-py`, pushed 2026-07-21 | **`ypy` is ARCHIVED** (2025-04-19); maintained successor is `pycrdt` (y-crdt org, pushed 2026-09-10) |
| **Swift** | O — `automerge/automerge-swift`, pushed 2026-04-02 (+ `automerge-repo-swift`) | O — `loro-dev/loro-swift`, pushed 2026-07-21 | `y-crdt/yswift`, **pushed 2024-07-20** (stale) |
| **Go** | O — `automerge/automerge-go`, **pushed 2024-10-30** (stale) | C — `aholstenson/loro-go`, pushed 2026-06-24, 22 stars | — |
| **Java** | O — `automerge/automerge-java`, pushed 2026-04-22 | — (only via `loro-ffi`/UniFFI Kotlin, **[INFERENCE]**) | `y-crdt/ykt` (Kotlin) **pushed 2023-01-17** (dead) |
| **C#** | — none found in the automerge org | — | `y-crdt/ydotnet`, pushed 2026-05-04, 73 stars |
| **C** (the floor) | O — `rust/automerge-c` in the main repo (verified in the repo tree) | C — `gsfjohnson/loro-c`, 1 star, pushed 2026-09-03; plus official `loro-dev/loro-ffi` (UniFFI), pushed 2026-09-06 | O — `yffi/` in the y-crdt monorepo (verified in the repo tree) |
| **OCaml** | — | — | — |
| **Haskell** | — | — | — |

Sources: <https://api.github.com/repos/y-crdt/y-crdt/contents/>,
<https://api.github.com/repos/automerge/automerge/contents/rust>,
<https://registry.npmjs.org/@automerge/automerge/latest>, the three
orgs' repo listings via
<https://api.github.com/orgs/{automerge,loro-dev,y-crdt}/repos>,
<https://api.github.com/search/repositories?q=loro-crdt>, and
<https://registry.npmjs.org/loro-crdt/latest>.

**The conclusion that matters.** No CRDT has bindings for all nine
guests, and **OCaml and Haskell have none from anybody**. So kaya must
not put a CRDT type anywhere near its widget API: the widget hands the
app *edits*, and the app decides whether a CRDT is behind it — which is
what invariant 1 forces anyway. **[INFERENCE]** Every binding above is
an FFI wrapper over the same Rust core, so the edit protocol only has to
be *expressible* in every guest (scalars, a string, a run list), never
the CRDT's own types.

---

## §3 — How editors actually bind to these CRDTs

### The invariant shared by every binding: an ORIGIN tag breaks the echo

y-quill is the shortest complete example. From
<https://raw.githubusercontent.com/yjs/y-quill/master/src/y-quill.js>:

```javascript
this._typeObserver = (_events, tr) => {
  if (tr.origin !== this) {              // remote (or another origin) only
    const appliedDelta = quill.updateContents(delta, this)   // pass self as origin
  }
}
this._quillObserver = (_eventType, delta, _state, origin) => {
  if (delta && delta.ops) {
    if (origin !== this) {               // user typing only, not our own writeback
      doc.transact(() => { type.applyDelta(changes.ops) }, this)   // tag the txn
    }
  }
}
```

Both directions carry the *same* origin token and both test it. That is
the whole loop-prevention mechanism — and it is the echo doctrine kaya
already states five times in `spec.rs`: "a programmatic write never
echoes; only the user's act emits" (`docs/undo-plan.md:99-111`). **kaya
gets this for free**: the widget's `text_changed`-family occurrence
fires only for user acts, so an app writing a remote delta in does not
get it back.

### The three editor bindings, and the one hard part

**y-prosemirror**
(<https://raw.githubusercontent.com/yjs/y-prosemirror/master/README.md>):
`ySyncPlugin` (document sync), `yCursorPlugin` (remote carets over the
Awareness protocol), `yUndoPlugin`. Its own summary of the hard part is
that the binding "translates between three position representations:
ProseMirror positions (integer offsets), delta positions (tree paths),
and relative positions (anchored to content identity)", and it
"successfully recovers when concurrent edits result in an invalid
document schema". Undo is per client — "each client has its own
undo-/redo-history" via `Y.UndoManager`, and a transaction opts out with
the `addToHistory` meta property. **The third position space is the
cursor mechanism** — Yjs's `RelativePosition`, yrs's `StickyIndex`
(§1): convert the local selection to an anchor *before* applying a
remote update, convert back *after*. **[INFERENCE — the README names the
three spaces but does not spell the conversion; this is the standard
Yjs recipe.]**

**automerge-prosemirror**
(<https://github.com/automerge/automerge-prosemirror>): "Collaborate on
rich text documents which follow the rich text schema using
ProseMirror." Public surface is `init`, a plugin, and a `SchemaAdapter`
mapping ProseMirror node/mark names onto automerge block/mark names via
an `automerge: { markName }` key. The README does **not** document the
transaction↔patch mechanics or selection preservation, so I do not claim
them; crate-side the pair it must use is `Transactable::{splice_text,
mark, unmark}` inbound and `PatchAction::{SpliceText, DeleteSeq, Mark}`
+ `ReadDoc::spans()` outbound (§1).

**loro-prosemirror** (144 stars, pushed 2026-08-22) and
**loro-codemirror** (41 stars, pushed 2026-05-25)
(<https://api.github.com/orgs/loro-dev/repos>). Three plugins:
`LoroSyncPlugin` ("Sync document state with Loro"), `LoroUndoPlugin`
("Undo/Redo in collaborative editing") and `LoroEphemeralCursorPlugin`,
which keeps cursor presence in "Loro's EphemeralStore (preferred) or
legacy Awareness"
(<https://raw.githubusercontent.com/loro-dev/loro-prosemirror/main/README.md>).
The split that matters for a widget API: **cursor presence lives OUTSIDE
the document**, never in the CRDT text.

### Mark boundaries: the Peritext rule, and who implements it

Peritext (Litt, Lim, Kleppmann, van Hardenberg, 2022,
<https://www.inkandswitch.com/peritext/>) is the source of the
semantics all three crates implement. Its core:

- Marks are anchored to *characters*, not offsets: each character stores
  "the opId of the operation that inserted it" and mark operation sets.
- Anchors are **before/after a character**, and that choice *is* the
  expand rule: "a formatting operation will be extended when new text is
  inserted on the boundary", while for a mark that must not grow — "a
  link or comment span does not grow in the same way" — you use
  `type: "after"` anchors.
- The output to the editor is a *patch*, not a new document: patches
  describe "what _changed_ in the document, not just produce a new
  document state."

Crate-side implementations of that rule:

- **automerge**: `ExpandMark::{Before, After, Both, None}`, chosen
  per call on `mark`/`unmark`; its doc "references the Peritext
  specification for guidance on selecting appropriate values for
  different rich text editor operations"
  (<https://docs.rs/automerge/0.11.0/automerge/marks/enum.ExpandMark.html>).
  Bulk writes get `UpdateSpansConfig { default_expand, per_mark_expands }`
  (<https://docs.rs/automerge/0.11.0/automerge/marks/struct.UpdateSpansConfig.html>).
- **loro**: lineage is loro-dev's `crdt-richtext`, "Rich text CRDT that
  implements Peritext and Fugue"
  (<https://api.github.com/orgs/loro-dev/repos>). Expand is **per style
  key, document-wide**: `LoroDoc::config_text_style(StyleConfigMap)` —
  "Configure the `expand` behavior for marks used by
  `LoroText::mark`/`LoroText::unmark`" — plus
  `config_default_text_style(Option<StyleConfig>)`
  (<https://docs.rs/loro/1.16.0/loro/struct.LoroDoc.html>);
  `StyleConfig { pub expand: ExpandType }` with `ExpandType::{Before,
  After, Both, None}` — `Before` = "when inserting new text before this
  style, the new text should inherit this style", `None` = "should
  **not** inherit"
  (<https://docs.rs/loro/1.16.0/loro/enum.ExpandType.html>,
  <https://docs.rs/loro/1.16.0/loro/struct.StyleConfigMap.html>).
- **yrs**: Yjs's model is *attributed runs*, not Peritext anchors —
  `format(txn, index, len, attributes)` and `Delta::Retain(n, attrs)`.
  No `ExpandMark` equivalent is in the public API; boundary behaviour is
  decided by where the format op's endpoints land, and
  `Options::cleanup_formatting` prunes redundant format markers
  (<https://docs.rs/yrs/0.27.4/yrs/doc/struct.Options.html>).
  **[INFERENCE on the absence — I read the `Text` trait's full method
  list; no expand parameter appears.]**

**So the three rich crates differ exactly here**, and a widget API must
not bake either choice in: automerge chooses expand **per mark call**,
loro chooses it **per style key, document-wide**, yrs does not expose
the choice at all.

---

## §4 — What this means for a kaya rich-text widget API

### The shape every one of these bridges needs

A widget can feed all three if it publishes an edit as **(replaced
range, inserted text, attribute runs of the inserted text)** and accepts
the same back. That is automerge's `splice_text(obj, pos, del, text)`
almost literally, loro's `splice(pos, len, s)` /
`insert_utf8`+`delete_utf8`, and a two-element Quill delta for yrs.

The Quill delta (`retain/insert/delete`) is the other candidate and is
what loro and yrs emit natively. It is more general (many edits and
pure-formatting ops in one) and harder for a toolkit to produce, because
a delta is a *cursor walk over the whole document* while a platform text
callback hands you an *addressed* replacement. **[INFERENCE]** Every
kaya platform reports the addressed form — NSTextView's
`textView:shouldChangeTextInRange:replacementString:`, GTK's
`insert-text`/`delete-range`, WinUI's `TextChanging`, Android's
`TextWatcher.onTextChanged(s, start, before, count)` — so a delta would
be synthesized by the core from it anyway.

### (a) The edit occurrence

Minimum sufficient payload, in kaya's ruled unit:

```
text_edited {
  widget, start: u64, end: u64,        # UTF-8 byte offsets into the text BEFORE the edit
  inserted: String,                    # may be empty (a pure deletion)
  runs: [ { len: u64, attrs: [(name, value)] } ],   # attribute runs covering `inserted`
  source: user | ime_commit | paste | native_undo | drop
}
```

`start`/`end` obey `docs/ranges-units.md:14` verbatim, so the existing
one-chokepoint validator (`:453-492`) covers them with no new code.
`runs` covers the inserted text only — the surrounding text's attributes
are the document's business. `source` is what lets an app tell a native
undo from typing, which `docs/undo-plan.md:459` records as an open
protocol gap ("A6 — … A NATIVE UNDO IS INDISTINGUISHABLE FROM TYPING");
a rich-text widget makes that gap far more expensive, so it should be
closed by this milestone, not inherited.

Conversion cost per CRDT, from an occurrence in this shape:

| target | inserted text | positions | attributes |
|---|---|---|---|
| automerge (`TextEncoding::Utf8CodeUnit`) | `splice_text(obj, start, end-start, &inserted)` | **identity** | `mark(Mark{start,end,name,value}, ExpandMark::…)` per run, app picks expand |
| loro | `delete_utf8(start, end-start)` + `insert_utf8(start, &inserted)` | **identity** | `mark_utf8(range, key, value)`; expand set once via `config_text_style` |
| yrs (`OffsetKind::Bytes`, the default) | `remove_range(txn, start, end-start)` + `insert_with_attributes(txn, start, &inserted, attrs)` | **identity** | attrs ride the insert; `format(index,len,attrs)` for retro-formatting |
| yrs (`OffsetKind::Utf16`, for y.js interop) | same | core converts bytes→UTF-16, which it **already does** for four backends (`docs/ranges-units.md:479-492`) | same |
| diamond-types / cola | plain text only | identity (byte-ish) | n/a |

**Nothing needs converting in the default configuration of all three
rich crates.** kaya's ruled unit — UTF-8 bytes — is automerge's
documented default ("Text is encoded in UTF-8 by default",
<https://docs.rs/automerge/0.11.0/automerge/index.html>), is yrs's
`Options` default (`OffsetKind::Bytes`,
<https://docs.rs/yrs/0.27.4/yrs/doc/struct.Options.html>), and is a
first-class twin on every loro mutation. The unit ruled for platform
reasons happens to be the CRDT-friendliest one available.

### (b) Applying a remote edit without eating the caret or the composition

This is the part a widget must *own*, because the app cannot. Three
requirements, each with a source:

1. **Anchor the local selection before applying, restore after** — the
   "third position space" (§3), what `StickyIndex`/`Cursor` exist for.
   The widget's version needs no CRDT: given `(start, end,
   inserted_len)`, transform the caret as OT does — unchanged before
   `start`, shifted by `inserted_len - (end-start)` after `end`, clamped
   to `start + inserted_len` inside. **[INFERENCE]** The association
   question is real, though: a caret exactly at `start` must choose left
   or right — `Assoc::{Before, After}`
   (<https://docs.rs/yrs/0.27.4/yrs/struct.StickyIndex.html>),
   `MoveCursor::{Before, After}`
   (<https://docs.rs/automerge/0.11.0/automerge/enum.MoveCursor.html>).
   kaya should pick one and state it, as it stated the grapheme
   carve-out.
2. **Refuse — or queue — while an IME composition is live.** kaya ruled
   this for selection already: a `select_range` during composition is
   "refused at apply with a named reason (measured: honoring it cancels
   the user's composition mid-word — data loss shaped like a feature)"
   (`docs/ranges-plan.md:88-95`). A remote *text* apply mid-composition
   is the same hazard, worse. Refuse-loudly matches kaya's doctrine;
   holding the delta until `composition_end` is better for a
   collaborative editor. **[INFERENCE]** That is a ruling for the
   maintainer, not an implementer's choice.
3. **Apply must not echo** — free in kaya (the echo doctrine,
   `docs/undo-plan.md:99-111`), which is the `origin !== this` dance
   y-quill does by hand.

### (c) Toolbar attribute toggling is an EDIT, not a widget mode

A Bold button over a selection must reach the app as an occurrence, not
mutate the widget silently, or the app's document and the widget's text
diverge at the first remote merge:

```
text_formatted { widget, start, end, name, value: Option<...> }   # None = remove
```

— `mark`/`unmark` in automerge and loro, `format(index, len, attrs)` in
yrs (<https://docs.rs/yrs/0.27.4/yrs/types/text/trait.Text.html>).
**Do not put an expand flag in kaya's occurrence**: automerge wants it
per call, loro per style key on the document, yrs has none, so a flag
kaya invented would be right for one crate in three.

**Zero-length formatting** (Bold pressed with a collapsed caret, then
typing) is widget-local pending state, not an edit — no document change
has happened yet. It becomes the `runs` payload of the next
`text_edited`. **[INFERENCE]**, but it is what makes (a) and (c) compose.

### (d) The smallest protocol that bridges all of them

```
DOWN  (app -> widget)   set_rich_text(widget, spans: [ { text, attrs } ])
                        apply_edit(widget, start, end, inserted, runs)   # incremental
UP    (widget -> app)   text_edited     { start, end, inserted, runs, source }
                        text_formatted  { start, end, name, value }
                        selection_changed { anchor, head }               # already ranges-shaped
```

Five messages. `set_rich_text` is the full re-render, and all three
CRDTs already hand the app exactly that run list: `ReadDoc::spans()`
(`Span::Text { text, marks }`) in automerge, `to_delta()` /
`get_richtext_value()` in loro, `Text::diff()` in yrs. `apply_edit`
carries the same payload as `text_edited`, which makes the round trip
provable by a scene: send an edit in, read the same shape back.

**What each CRDT still needs from the app, not from kaya:** automerge,
an `ExpandMark` per call and a document built with
`TextEncoding::Utf8CodeUnit`; loro, one `config_text_style` call and the
`_utf8` method family throughout; yrs, `OffsetKind` left at `Bytes` and
attribute runs mapped onto `Attrs`. None is a kaya concern — that is the
design goal.

---

## §5 — Undo, where the CRDT and kaya's own log meet

### What the crates give

- **yrs `UndoManager`** (<https://docs.rs/yrs/0.27.4/yrs/undo/struct.UndoManager.html>):
  scoped to a shared type and document; `undo()`/`redo()`;
  `include_origin`/`exclude_origin` ("Origin markers can be assigned to
  updates executing in a scope of a particular transaction") — how "each
  client has its own undo-/redo-history" is implemented; `reset()`
  breaks the merge window, which merges "stack items if they were
  created withing the time gap smaller than `capture_timeout_millis`".
- **loro `UndoManager`** (<https://docs.rs/loro/1.16.0/loro/struct.UndoManager.html>):
  "Undo the last change made by the peer"; explicitly local —
  "undo/redo affects only local operations from the bound peer; it does
  not revert remote edits"; `set_merge_interval` ("The default value is
  0, which means no merge"); `add_exclude_origin_prefix` ("If a local
  event's origin matches the given prefix, it will not be recorded in
  the undo stack"); `group_start`/`group_end` ("all subsequent changes
  will be merged into a new item on the undo stack"); `set_on_push` /
  `set_on_pop` listeners; `record_new_checkpoint`.
- **automerge**: no `UndoManager` in the crate index
  (<https://docs.rs/automerge/0.11.0/automerge/index.html>). Undo is the
  app's: `ChangeHash` heads plus `text_at`/`spans_at`/`marks_at` read a
  past version
  (<https://docs.rs/automerge/0.11.0/automerge/trait.ReadDoc.html>), and
  an inverse is applied as a new change. **[INFERENCE from the absent
  type plus the `_at` family; I found no document stating automerge's
  undo recipe this session.]**

The universal rule, stated by two of three explicitly: **CRDT undo is
local-peer-scoped and is implemented as a new forward change, never as a
rollback of the log.**

### The collision with kaya's ruling table

`docs/undo-plan.md` D1 ratifies two tiers: "Text-local undo DELEGATES to
the platform's native stacks… App-state undo is CORE-OWNED"
(`:62-72`), D6 routes Edit>Undo "focused-text-first" (`:144-162`), and
D7 says "A PROGRAMMATIC WRITE RESETS THE WIDGET'S NATIVE UNDO HISTORY"
(`:163-178`).

For a CRDT-backed rich text widget **all three are wrong by default**,
and this is the single largest design finding in this report:

1. **D1's native tier is unusable.** The platform's own undo stack
   reverts the *widget's* text without telling the app. The app's
   document — the CRDT — would not move, and the next remote patch or
   the next `set_rich_text` would resurrect the undone text. The native
   tier must be **opted out** for a CRDT-backed widget; `docs/undo-plan.md:472`
   already provides the lever — "A7 — THE NATIVE TIER IS OPT-OUT-ABLE PER
   WIDGET".
2. **D7 then fires constantly.** Every remote patch is a programmatic
   write, so every remote patch would clear the native history
   (`docs/undo-plan.md:414` narrows it to writes that change the text —
   A3 — which does not help here, since remote patches change the text
   by definition). With the native tier off (point 1) D7 becomes a
   no-op, which is the coherent state.
3. **D6's routing needs a third answer.** With native off and the
   document app-owned, "can the focused widget undo?"
   (`docs/undo-plan.md:423`, A4's named core query) must be answered *by
   the app* — the CRDT's `can_undo()`. **[INFERENCE]** that is a query
   direction kaya lacks today; the cheapest honest version is an
   app-declared boolean prop kept current from `UndoManager::can_undo()`
   and refreshed the way paste's `offer ∩ accepts` already is
   (`docs/undo-plan.md:152-156`).

What does *not* collide: kaya's core undo log (D3/D4/D5,
`docs/undo-plan.md:99-143`) is untouched, because a CRDT-backed document
is app state that never became core signals — and D5's `undone`/`redone`
occurrence "carrying the delta" is the same protocol shape §4 proposes
for text. **[INFERENCE]** Worth spelling the two consistently.

---

## §6 — Recommendation

**kaya's widget-side edit protocol should be the addressed edit, not the
delta, and its unit should be the one already ruled: UTF-8 byte offsets
into the widget's guest-visible text, both endpoints on a code-point
boundary (`docs/ranges-units.md:14`).** Concretely: `text_edited
{ start, end, inserted, runs, source }` up, `apply_edit(start, end,
inserted, runs)` and `set_rich_text(spans)` down, plus `text_formatted
{ start, end, name, value }` for toolbar marks and the existing
selection occurrence — five messages, no CRDT type anywhere near the
API, no expand flag on the wire (automerge wants it per call, loro per
style key, yrs not at all, so any flag kaya invented would be right for
one crate in three). The addressed form is what every platform text
control actually reports and what automerge's `splice_text(obj, pos,
del, text)` and loro's `splice(pos, len, s)` take verbatim, while a
Quill delta is a whole-document cursor walk that the core would have to
synthesize from the addressed form anyway — and a delta is recoverable
from a sequence of addressed edits, whereas the reverse needs the
document. The first crate to measure it against is **automerge 0.11.0
with `TextEncoding::Utf8CodeUnit`**, for four reasons: its documented
default is already kaya's unit ("Text is encoded in UTF-8 by default",
<https://docs.rs/automerge/0.11.0/automerge/index.html>); its emitted
`PatchAction::{SpliceText, DeleteSeq, Mark}` is addressed rather than
delta-shaped, so a mismatch in kaya's protocol shows up as a shape
error rather than as an arithmetic bug; its `ExpandMark` is the explicit
Peritext rule, so mark-boundary behaviour is *testable* rather than
implicit; and it is the only surveyed CRDT with official bindings in
five of kaya's nine guests (Rust, JS, Python, Swift, Java) plus a C
floor at `rust/automerge-c`, which is the closest anything gets to
invariant 2's sweep. loro 1.16.0 is the immediate second — it is the
most actively released (2026-09-06), it takes UTF-8 offsets on every
mutation, and its `Vec<TextDelta>` event is the delta-shaped counter-
example that would prove the protocol is not accidentally automerge's.

### The two caveats that would change this recommendation

1. **loro's emitted delta unit is unverified.** `TextDelta`'s
   `retain`/`delete` lengths are documented with no unit
   (<https://docs.rs/loro/1.16.0/loro/enum.TextDelta.html>); the write
   side is explicitly tri-unit, but the *event* side is not, and the
   crate root says the Rust default is unicode scalars. If the emitted
   deltas are scalars while the writes are bytes, a kaya↔loro bridge
   converts on one side only — the classic off-by-emoji. A 60-line probe
   settles it; nothing should be built on the assumption.
2. **No CRDT reaches all nine guests, and the undo tiers collide.**
   OCaml and Haskell have no binding to any of them, and §5 shows that a
   CRDT-backed widget must opt OUT of `docs/undo-plan.md`'s native undo
   tier (D1/D7) and needs a new "can the app undo?" answer for D6's
   routing. Both are maintainer rulings, not implementation details, and
   the second one changes an already-ratified decision table.
