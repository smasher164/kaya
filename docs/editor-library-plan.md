# The editor's library: absorbing the notes demo (the design pass, 2026-11-15)

Status: PROPOSED 2026-11-15, rulings open (L1 to L12, §11). Nothing is built.
The feasibility measurements (§1) were made first, in a scratch directory
outside the repo, and their builds were deleted afterwards.

The maintainer, 2026-11-15: "i didn't realize we had a notes demo separately
from the writing mode in the editor. i imagine we can just absorb that
behavior into the editor ala RD9 and RD10." RD9 (RULED A) put a notes app's
LIBRARY in SQLite in the app's own storage, one row per note holding
Automerge's snapshot and incremental chunks, with full-text search; RD10
(RULED) maps kaya's paragraphs onto Automerge's block markers
(docs/rich-document-plan.md §3, §4, §10). The notes demo is
guests/rust/notes.rs with tools/scenes/notes.steps, built 2026-09-15 in Rust
only by the maintainer's word at the time (docs/rich-text-plan.md §16, §17).
The editor is guests/go/editor/editor.go, written in Go on purpose
(docs/editor-plan.md: an editor in Rust would be kaya testing itself). This
plan moves the demo's behaviour into the Go editor, which reverses the
2026-09-15 "one language" word for this one app, by the maintainer's new
word.

## §0. The mechanism, from zero

**A file and a library.** Today the editor edits FILES: the user picks a
path (or, on a phone, a document the system's picker hands over), the editor
reads the bytes, and Save writes them back. A LIBRARY is the other shape
note apps use (Apple Notes, Bear, Things): the app keeps every note in one
database in its own storage, the user never sees a file, and there is no
Save, because every change is written as it happens. RD9 ruled both: a
`.kdoc` file for documents the user opens and saves, and a SQLite library
for a notes app.

**SQLite, FTS5.** SQLite is a database engine that lives in one file and is
linked into the app. FTS5 is SQLite's full-text search module: a virtual
table that keeps an INVERTED INDEX (for every word, the rows that contain
it), so "find every note that mentions cafe" is one query. Its `unicode61`
TOKENIZER (the rule that splits text into words) can fold diacritics, so
"cafe" finds "Café".

**A CRDT, a peer, a merge.** A CRDT (a conflict-free replicated data type)
is a data structure that two copies can edit apart and then MERGE, ending
with the same document on both sides without a server deciding. Each copy
is a PEER, named by an ACTOR id. Automerge is the CRDT kaya measured
against (docs/rich-text-plan.md §6). Its rich text is plain text with MARKS
(an attribute over a range, such as bold) and BLOCK MARKERS (a small map
object inserted into the text where a paragraph begins, holding the
paragraph's kind; RD10). A merge hands the app PATCHES: "text inserted at
index 12", "mark bold over 4 to 9", which the app turns into kaya's
`apply_edit` and `format_range`.

**Snapshot and incremental chunks.** Automerge's file format is a sequence
of self-checksummed CHUNKS. `save()` writes the whole document compactly
(a SNAPSHOT); `save_incremental()` writes only the changes since the last
save (an INCREMENTAL chunk); a snapshot followed by any number of
incremental chunks is itself a valid document, and a torn last chunk loads
with the tail ignored. automerge-repo stores a document as one snapshot plus
incremental chunks and COMPACTS them into a fresh snapshot now and then.
That is the row shape RD9 ruled.

**cgo, a static archive, a C ABI.** Go reaches C code through cgo: a Go file
declares C functions and the Go toolchain compiles and links C beside it.
kaya's Go binding is cgo on every lane already (bindings/go/runtime.go).
Rust code is reachable from Go the same way when it exports a C ABI (plain C
function signatures); built as a STATIC ARCHIVE (`.a`, linked into the
program) or a shared library (`.so`, `.dll`, `.dylib`). libkaya itself is
reached this way.

## §1. What was measured (feasibility first)

All on 2026-11-15, in the dev shell (Go 1.27.0, rustc 1.97.0), with every
build, cache and module download in a scratch directory outside the repo.
"Built" below means compiled and linked for that target; nothing was RUN on
a phone, the simulator, the linux container or the Windows VM, which the
charge kept out of reach. The repo's own artifacts were only read.

### §1.1 Automerge from Go

| Candidate | What it is | Found |
|---|---|---|
| automerge-go | the official Go wrapper, cgo over a prebuilt Rust core | Latest is `v0.0.0-20241030180337-6fb4f2d08244` (2024-10-30), no commit since; module zip 3,227,865 bytes. Its `deps/` carries prebuilt cores for darwin and linux, amd64 and arm64, ONLY: no iOS, Android or Windows. Its `Text` has `Len`, `Get`, `Set`, `Insert`, `Delete`, `Append`, `Splice`: no marks, no cursors, no block markers, no patches. Positions are code points. docs/rich-text-plan.md §16's 2026-09-15 reading stands. |
| automerge-c | the official C API, in the automerge repo (HEAD `09b19d50`, 2026-11-13; crate 0.2.2) | Has `AMspliceText`, `AMmarkCreate`, `AMmarks`, `AMgetCursor`. Has NO `split_block`, `join_block`, `update_spans`, `spans`, `diff` or `diff_incremental` (zero hits in its source). `AMcreate` uses Automerge's default encoding, code points, unless the core is built with its `utf8-indexing` feature. RD10's block markers and a patch-driven bridge cannot be written over it as published. |
| the automerge Rust crate | what notes.rs uses | crates.io's newest is 0.12.0 (2026-09-16); kaya pins `=0.11.0` (crates/kaya/Cargo.toml, a dev-dependency). 0.11.0 has `new_with_encoding(Utf8CodeUnit)`, `split_block`, `update_spans`, `spans`, `diff_incremental` and `update_diff_cursor`. |
| an app-owned bridge | a small Rust crate over the 0.11.0 crate, exporting a C ABI, wrapped by cgo in the editor | BUILT AND RUN on the Mac host, beside the REAL kaya Go binding in one program: block markers written by `split_block` and a `type` key, a forked peer's insert and mark merged, `diff_incremental`'s patches read in Go, a snapshot (310 bytes) plus an incremental chunk (133 bytes) reloaded, and a half-torn incremental chunk reloaded to the snapshot. Cross-built release, about 7 s each with dependencies cached: aarch64-apple-ios-sim (static archive 24,146,624 bytes), aarch64-linux-android through cargo ndk at API 26 (`.a` and a 3,158,312-byte `.so`), aarch64-pc-windows-msvc through cargo xwin (a 1,796,096-byte DLL with its import library, the shape of kaya.dll). |

**Two Rust static archives in one iOS program.** iOS is the one lane where
libkaya is a static archive (bindings/go/runtime.go's ios line), so a
second Rust archive (the bridge) could have collided with it, since each
carries a copy of Rust's standard library. MEASURED: a `GOOS=ios` build of
the probe linked against the repo's own debug `libkaya.a` and the bridge's
`libambridge.a` with no duplicate symbol; the program holds 13 bridge and
191 kaya text symbols and one `rust_eh_personality`. The Android
`c-shared` build linked too, needing `libkaya.so` dynamically and holding
the bridge statically. The iOS cdylib half of the bridge needs Xcode's
clang as its linker (`CARGO_TARGET_AARCH64_APPLE_IOS_SIM_LINKER`), for the
reason tools/ios/run-sim.py already records for `cc-rs`; a staticlib-only
crate type avoids the question.

Not measured: the Go link on the Windows VM (llvm-mingw against the
bridge's DLL, the same shape as `-lkaya` against kaya.dll), and the bridge
inside the linux container, whose toolchain already builds automerge 0.11.0
for notes.rs on every matrix.

### §1.2 A correction to rich-document-plan §3: a block marker is three units wide

MEASURED on automerge 0.11.0 and 0.12.0 alike: in `TextEncoding::Utf8CodeUnit`,
kaya's unit, a block marker occupies THREE index units, the UTF-8 width of
the U+FFFC character Automerge reports for it. `"ab"` with `split_block(1)`
grows from length 2 to 5; under `UnicodeCodePoint` and `Utf16CodeUnit` it
grows to 3. An insert at an index inside a marker lands after it.

So §3's table ("the bridge adds one to every offset and turns each `"\n"`
into a marker one for one") holds for the count of markers but not for the
offsets. In kaya's unit the bridge translates:

- kaya byte `b`, with `k` newlines before it, is Automerge index
  `3 + b + 2k` (the first paragraph's marker takes 0 to 2, and each
  newline, one byte in kaya, becomes a three-unit marker);
- an Automerge patch at index `i` with `m` markers before it is kaya byte
  `i - 2m - 1` (each marker after the first stands for one newline
  byte).

The offset identity of docs/rich-text-plan.md §6 still holds inside a
paragraph, which is all notes.rs ever needed (it maps paragraphs to marks,
RD10's option B). This finding belongs in docs/traps.md and in §3 itself
when the build starts; this plan records it first because this pass may
commit only its own two files.

### §1.3 SQLite for Go

The probe program opened a file database in WAL mode, made a table and an
external-content FTS5 table with `tokenize='unicode61 remove_diacritics 2'`,
and found "Café walks" by `MATCH 'cafe'`.

| Driver | Kind | Found |
|---|---|---|
| modernc.org/sqlite v1.62.0 (2026-11-07) | pure Go, SQLite translated from C | SQLite 3.54.1 with FTS5 compiled in; ran on the host. Built for ios/arm64 (simulator, Xcode clang, 6,964,514 bytes), android/arm64 `c-shared` (NDK clang), windows/arm64 and linux/arm64 (no C compiler needed). Brings nine more modules (modernc.org/libc v1.80.1, mathutil, memory, golang.org/x/sys v0.49.0 and five small ones); 20 go.sum lines; 247 MB of source extracted (sqlite 152 MB, libc 95 MB), 48 MB of module zips. Host binary 9,988,770 bytes. |
| github.com/mattn/go-sqlite3 v1.14.53 (2026-11-05) | cgo over SQLite's C amalgamation | SQLite 3.54.1; FTS5 needs `-tags sqlite_fts5`; ran on the host (7,755,954 bytes; 13.7 s for the C compile). Built for the iOS simulator (4,290,786 bytes, one `gethostuuid()` warning) and Android `c-shared`. Windows needs the VM's llvm-mingw for its C, not measured; its `CGO_ENABLED=0` builds compile only to a stub that fails at run time, so they prove nothing. 11 MB of source. |
| github.com/ncruces/go-sqlite3 v0.37.0 | SQLite compiled to WebAssembly, run by the wazero runtime | Not built: it adds a second runtime under the app, and wazero cannot generate code on iOS, where it would interpret. |
| zombiezen.com/go/sqlite v1.4.2 | an API over modernc | Not separately built. |

### §1.4 What the tree has today

- One go.mod (module `dev.kaya`, go 1.27) and NO go.sum: no Go guest has a
  module dependency yet. tools/check-pins.py has no Go clause. The editor
  would carry the first.
- The editor writes a picked file with `PickedFile.Open(FileModeWrite)` and
  reads it back (`writeDoc`); it does not use the safe save,
  `PickedFile.Save`, built 2026-11-14 (docs/rich-document-plan.md §4.1).
- Shared regions (docs/doctabs-plan.md §1.7) are built on all five lanes and
  in Go (`AddRegion`, `RegionEdgeLeading`); on a phone a leading region is
  shown in the open-documents sheet above the list (ruled 2026-10-28).
- App data is SQLite through the language's own binding in
  `app_data_dir()`, scratch under the harness and kept across
  `relaunch launch` (DESIGN.md, App data and preferences;
  tools/scenes/taskspersist.steps is the precedent).
- `own_undo` is per widget (`Widget.OwnUndo` in Go), so one tab can own its
  undo while another keeps the platform's.

## §2. The proposed shape

**The window (L1).** On the desktops the library is a LEADING SHARED REGION
beside the document tabs: a search field over the list of notes, newest
first, each row its title and its date, a "+" for a new note. Clicking a
note opens it in a tab, or selects its tab when it is already open. This is
the sidebar docs/doctabs-plan.md §1.7 was ruled for ("a sidebar could be
implemented in the same way it would on gnome and windows"), and the shape
of Apple Notes, Bear and Obsidian. On a phone the same region is drawn in
the open-documents sheet above the open documents, as ruled; the sheet is
then the library's door.

**A note in a tab (L2).** A note tab is the rich tab of RD11 with three
differences: it is AUTOSAVED (no Save, no unsaved mark, Close never asks),
its title is its first paragraph's text (Notes' rule, "New Note" while
empty), and it owns its undo (L7). Save is disabled on a note tab and
Save As… reads "Export…" there (§4). Find, the Format menu, Writing Mode's
look, the colour presets and the status line are the rich tab's, unchanged.

**Launch and New (L3).** The editor still opens with an empty untitled
buffer (docs/editor-plan.md §0, ratified) and File > New still makes a file
tab. File > New Note, and the region's "+", make a library note.

## §3. The library on disk (L8)

`<app_data_dir>/library.sqlite`, through the Go driver of L6:

```sql
PRAGMA application_id = 0x6B4C4942;   -- "kLIB", the editor's library
PRAGMA user_version = 1;
PRAGMA journal_mode = WAL;
PRAGMA synchronous = FULL;            -- a write is durable when it returns
PRAGMA foreign_keys = ON;

CREATE TABLE note (
  id       TEXT PRIMARY KEY,          -- a random UUID
  created  INTEGER NOT NULL,          -- Unix milliseconds
  modified INTEGER NOT NULL,
  title    TEXT NOT NULL,             -- the first paragraph, as the list shows it
  plain    TEXT NOT NULL              -- the text without marks, for search
);
CREATE TABLE chunk (
  note  TEXT NOT NULL REFERENCES note(id) ON DELETE CASCADE,
  seq   INTEGER NOT NULL,             -- 0 is the snapshot; 1.. incremental, in order
  bytes BLOB NOT NULL,
  PRIMARY KEY (note, seq)
);
CREATE VIRTUAL TABLE note_fts USING fts5(
  title, plain, content = 'note', content_rowid = 'rowid',
  tokenize = 'unicode61 remove_diacritics 2');
-- the three triggers that keep note_fts in step with note (insert, update, delete)
```

- A note's document is its chunks concatenated in `seq` order and loaded
  once, with a torn last chunk ignored (measured, §1.1).
- The changes the bridge holds are written as one incremental chunk, in
  the same transaction as the note's new `modified`, `title` and `plain`:
  at most every 500 ms while the user types, and at once on a tab switch,
  a close, a quit and the phone's move to the background.
- COMPACTION, automerge-repo's rule: when a note's incremental chunks
  together outgrow its snapshot, one transaction writes a fresh snapshot as
  `seq` 0 and deletes the rest.
- No attachments table: kaya's document has no embeds yet (§2 of
  docs/rich-document-plan.md reserves them), and a table with no writer is
  dead schema. `user_version` 2 adds it beside the embeds (L8).
- Under the harness the store is scratch and kept across `relaunch launch`,
  so a scene proves persistence with the tasks app's door.

## §4. Files and notes (L9)

- **Open…** keeps today's rule: a `.kdoc` opens a rich FILE tab, anything
  else a plain one. Opening a file never adds it to the library.
- **Import into Library…** (File menu, and the region's context menu) reads
  a `.kdoc` and makes a NEW note from it: a fresh Automerge document whose
  markers and marks the bridge writes from the document's paragraphs and
  runs (§3's mapping with §1.2's offsets). A file tab offers the same act
  over its current content; the file on disk is untouched.
- **Export…** on a note tab writes a `.kdoc` through a save panel and
  `PickedFile.Save`, the safe save. The file is a snapshot of the text and
  runs: no `history` member, so no deleted word leaves the library in an
  emailed file (docs/rich-document-plan.md §4's named cost).
- **The safe save** applies wherever the editor writes a picked file: Save,
  Save As… and Export. This slice moves `writeDoc` to `PickedFile.Save`. The
  library itself is SQLite's transaction in the app's own storage, where
  its WAL file has a directory to live in (RD9's reason for keeping SQLite
  out of picked files), so it needs no safe save.

## §5. The two-peer merge (L4)

The notes demo's peer is a FORK of the local document under a second actor
that takes scripted steps and merges both ways; every step's patches reach
the widget as `apply_edit` and `format_range`, and four views must agree
after each: the widget's runs, the core's, the binding's `Document` and the
CRDT's own spans (tools/scenes/notes.steps).

What the editor's user sees in this slice: no second peer. A note's value
from the CRDT is that every edit is a small durable chunk (no Save, no lost
work on a crash) and that its history is kept for undo and for any sync
later. Live sync between devices needs a transport and a ruling of its own
(where the chunks travel, who may join), and this plan does not design it.

The merge is still proven, on every lane, by the notes demo's replayed
peer moved into the editor: under the harness only, the editor names a
peer for the note in front (a fork under actor `02…`), and the scene steps
it through a hidden-to-users door, a View > Peer Step item the editor adds
only when `kaya.Env("KAYA_SELFTEST")` is set. Every patch takes the same
path a sync would: bridge, translation, `apply_edit`/`format_range`, fold.

**The wall, on the path every merge walks.** After applying a merge's
patches the editor compares the bridge's spans, translated into kaya's
runs, with `app.Document(buffer)`, and on any difference panics naming
both, which reddens the leg wherever it happens and in a user's build
stops before a wrong document reaches the library. That replaces
notes.rs's `label#1` and `label#2`, which a scene had to read.

## §6. The bridge (L5)

A Rust crate beside the editor (a member of the repo's cargo workspace, so
Cargo.lock pins automerge `=0.11.0` and every build carries `--locked`),
built per lane next to libkaya: a static archive on the Mac, iOS, linux and
Android, the DLL and its import library on Windows. Its C ABI is shaped
around kaya's records, not Automerge's object model; about fifteen calls:

| Call | Does |
|---|---|
| `new`, `load(bytes)`, `free` | a note's document in `Utf8CodeUnit`, its first marker at index 0 |
| `edit(start, end, text, runs)` | a kaya `text_edited`: the splice, a marker per `"\n"`, the runs as marks with each mark's expand rule (docs/rich-document-plan.md §11's table) |
| `format(start, end, name, value)` | a kaya `text_formatted`: a mark, or a paragraph attribute through `update_spans` (the per-key path, never `replace_block`, §1.1's merge trap) |
| `save`, `save_incremental` | the chunk bytes for §3 |
| `fork(actor)`, `merge(other)` | the scene's peer, and a sync's later |
| `patches()` | `diff_incremental` since the last call, already in kaya's bytes: edits with their runs, paragraph attribute acts, ranged marks |
| `spans()` | the whole document as kaya text and runs, for §5's wall and for Export |
| `cursor(byte)`, `cursor_byte(c)` | Automerge cursors in kaya's bytes, for L7's undo |

The offset translation of §1.2 lives in this crate and nowhere else, and
the crate's unit tests hold it.

## §7. The notes demo (L10)

Recommended: FOLD. The editor's scene takes notes.steps' checks (the
caret's transform under a peer insert, the greeting arriving bold by the
expand rule, a concurrent insert ordered by actor, the peer's ranged italic
and unbold, the emoji's byte offsets), with paragraph kinds added now that
the bridge writes block markers; then guests/rust/notes.rs,
tools/scenes/notes.steps and their five lanes' legs are deleted in the same
change, and `automerge` leaves crates/kaya/Cargo.toml's dev-dependencies
(tools/richtext/automerge-probe keeps its own manifest). The ranged format
act keeps a consumer through the editor's peer steps; the Rust label path
of `format_range` keeps its unit test.

## §8. Guards and scenes (invariant 3)

Scenes, Go, on all five lanes:

- A new scene, `editorlibrary.steps`: New Note, typing, a list, an indent,
  a preset colour, the title following the first paragraph, the row in the
  region (the sheet on phones), search by a folded diacritic, a second
  note, delete with its question; `relaunch launch`; the notes read back
  byte for byte with `expect_runs`; Import of the essay `.kdoc` and Export
  of a note, read back through the picked file; the peer steps of §5 with
  `expect_runs` and `expect_selection` after each.
- editor.steps keeps its file tabs, and its Save now goes through
  `PickedFile.Save`; save.steps already proves that call in ten languages.

Walls and gates:

- §5's merge wall (a panic on the path every merge walks).
- The bridge's unit tests: §1.2's offsets both ways with multi-byte text
  and empty paragraphs; every kaya attribute and mark through §3's mapping
  and back; two concurrent paragraph-kind changes leaving one marker
  (the per-key path); a torn tail loading. One test pins the three-unit
  marker width, so an automerge upgrade that changes it fails `cargo test`.
- The library's Go tests (schema creation, a refused higher `user_version`
  in one sentence naming both numbers, the FTS triggers, compaction keeping
  the document equal), run by tools/go-typecheck.py's sweep beside `go vet`.
- tools/check-pins.py grows a Go clause: every module in go.mod at an exact
  version with its go.sum line (go.sum's `h1:` hashes are the bytes), the
  lanes building with `-mod=readonly` and `GOTOOLCHAIN=local`; watched red
  against a go.mod line with no go.sum entry and a `replace` to a path.
- tools/build-id.py: the bridge's artifact carries its sources' id and
  every lane `--verify`s it before linking; tools/check-build-id.py and
  tools/check-staging.py hold it the way they hold libkaya.

## §9. The binding sweep (invariant 2)

No binding surface changes. The library, the CRDT and the bridge are the
app's (docs/rich-text-plan.md §5: no CRDT or store in kaya's API; DESIGN.md:
the app keeps its own SQLite). Verdict per language: Rust, Python, Go, C#,
Java, Swift, OCaml, Haskell, JS and the C floor, NO CHANGE. If the build
finds a kaya gap (say, a region the editor cannot fill on a phone), that gap
is assessed then in all nine.

## §10. The build, depth then breadth

1. The bridge crate with its unit tests; the docs/traps.md entry and the
   §3 correction of §1.2.
2. The Mac: the library, the region, note tabs, import and export, the
   peer door, `editorlibrary.steps` green on the Mac lane.
3. Breadth: iOS and Android (the bridge archive in each runner's build,
   the Go module cache on the host), linux in the container, Windows (the
   bridge DLL staged, the VM's Go fetching modules through the proxy against
   go.sum); `editorlibrary` legs on every lane.
4. notes.rs and its legs deleted; the matrix.
5. The review page: the library on every lane, light and dark, each capture
   viewed before it is published.

## §11. The rulings

### L1. Where the library lives in the window

- A. A leading shared region beside the tabs on the desktops (search, list,
  "+"); on phones the same region in the open-documents sheet.
- B. A library tab: a document of its own listing the notes, the same on
  every platform, no region.
- C. A separate library window (Notes' main window), with notes opening
  into the editor's tabs; phones have one window and would need A or B.

RECOMMEND A. It is the sidebar the shared regions were ruled for, every
lane already draws it, and a list beside the documents is where every notes
app keeps it. B puts the list where the user's documents are and has to be
pinned against Close.

### L2. What a note tab is

- A. Notes' model: autosaved, no unsaved mark, Close never asks, title from
  the first paragraph; Save disabled, Save As… becomes Export….
- B. A note behaves like a file: edits are kept until Save writes them into
  the library.

RECOMMEND A. B keeps a document's unsaved state inside an app whose store
is built to need none, and every incremental chunk is already a save.

### L3. Launch and New

- A. Unchanged: launch opens an empty untitled file buffer and File > New
  makes a file tab; File > New Note and the region's "+" make a note.
- B. Notes first: launch opens the most recent note and primary+n makes a
  note; files come only through Open… and File > New File.

RECOMMEND A. The empty buffer at launch is ratified (docs/editor-plan.md
§0), and the editor stays a file editor that also keeps notes. A chord for
New Note is the maintainer's choice; primary+alt+n is free in the editor
today.

### L4. What the two-peer merge is, for the user and for the scene

- A. The user meets no second peer in this slice; the scene's proof is the
  replayed peer of §5, reached through a door the editor adds only under
  the harness, with the merge wall on every merge.
- B. A, plus a user-facing merge without a server: a note exported WITH
  its history and edited on another device merges back when imported
  (the `history` member of docs/rich-document-plan.md §4).
- C. Two desktop windows over one note, each its own peer, merging live.

RECOMMEND A. B ships every deleted word in a file the user may send and
asks for a ruling on that cost first; C is a demonstration no user needs
(one person, one note, two windows). Device sync is the real user-facing
merge and wants its own design pass.

### L5. How the editor reaches Automerge

- A. An app-owned Rust bridge over automerge `=0.11.0` with a C ABI shaped
  around kaya's records, built per lane, wrapped by cgo (§6).
- B. automerge-go.
- C. A fork of automerge-c (and automerge-go over it) growing block
  markers, patches and UTF-8 indexing.
- D. A CRDT of the editor's own, in Go.

RECOMMEND A. B is measured impossible (no marks, markers, patches or
cursors; code points; no iOS, Android or Windows core). C is A's Rust plus a
fork's upkeep and Automerge's object-model API, which the editor does not
need. D throws away RD10's point, that other Automerge tools read kaya's
paragraphs. A builds on four targets here and links beside static libkaya
on iOS (§1.1); the bridge's Rust is not kaya testing itself, since the
editor still reaches kaya only through the Go binding.

### L6. Which SQLite the Go editor uses

- A. modernc.org/sqlite v1.62.0, pure Go.
- B. github.com/mattn/go-sqlite3 v1.14.53, cgo over the C amalgamation.
- C. github.com/ncruces/go-sqlite3, SQLite in WebAssembly.
- D. SQLite inside the Rust bridge (rusqlite, already built on five lanes
  for the tasks app), behind more C calls.

RECOMMEND A. It is the only candidate that compiled for all five targets
here, and on the Windows VM, the lane least easy to observe, it adds no C
compile. Its costs are named: nine more modules, 48 MB of module zips in
the cache, about 7 MB in the binary. B is smaller and as fast or faster, but
its Windows build is unmeasured. D is "a worse SQL than any of theirs",
DESIGN.md's own reason kaya has no database API, moved into the app.

### L7. Undo in a note tab

- A. The note's widget is `own_undo`, and Undo takes back the user's OWN
  edits only: each entry keeps Automerge cursors at its ends, so a peer's
  later edits move it and are never undone (Google Docs' and Yjs's
  UndoManager rule). A typing run is one entry, as in notes.rs.
- B. The notes demo's walk over Automerge's heads, where Undo can take a
  merge back as well.
- C. The platform's native undo.

RECOMMEND A. B undoes another person's work, which no collaborative editor
does; C is wrong the moment a merge rewrites the text under the platform's
stack. A is not measured: the depth step measures it against notes.steps'
undo, undo, redo before anything else is built on it.

### L8. The schema's reach

- A. §3 as written: notes, chunks and FTS5, no attachments table until
  kaya's document has embeds; `user_version` moves when they come.
- B. §3 plus an attachments table now, empty.

RECOMMEND A, for the dead-schema reason in §3.

### L9. How a `.kdoc` file and a note relate

- A. Separate, joined by Import into Library… and Export…; an exported file
  carries no history; Open… never adds to the library.
- B. A, but Export carries the history (L4's B).
- C. The library is a folder of `.kdoc` files (Obsidian's shape).

RECOMMEND A. C contradicts RD9's ruling, and B is L4's question.

### L10. What happens to the notes demo

- A. Fold: the editor's scene takes notes.steps' checks; notes.rs, its
  scene and legs, and the kaya crate's automerge dev-dependency go in the
  same change (§7).
- B. Keep notes.rs as the Rust proof and move it to block markers, as RD10
  said it would.
- C. Keep it as it is.

RECOMMEND A. Two CRDT guests would test the same protocol twice and the
Rust one would be kaya testing itself again; C leaves a demo on RD10's
rejected mapping.

### L11. Deleting a note

- A. Delete Note asks first ("Delete "<title>"? This cannot be undone.")
  and removes the note and its chunks in one transaction.
- B. Apple Notes' Recently Deleted: a deleted note is kept 30 days in a
  section of its own, then purged.

RECOMMEND A for this slice. A delete that propagates is a sync question
(L4), and B's 30 days belong with it; A's question is the editor's existing
shape for losing work.

### L12. How the Go modules reach every lane

The editor would carry the repo's first Go module dependencies (§1.4), and
check-pins holds every network dependency to an exact version and bytes.
A Go module's version in go.mod is always exact, and go.sum records each
module's hash (`h1:`, a SHA-256 over its files), which the toolchain checks
on every download.

- A. go.mod and go.sum committed; every lane builds with `-mod=readonly`
  and `GOTOOLCHAIN=local`; the host's lanes use the host's module cache,
  and the Windows VM downloads through proxy.golang.org on its first build,
  checked against go.sum; check-pins' new Go clause holds both files (§8).
- B. The modules vendored into the repo (`go mod vendor`).
- C. A, but the deploy ships the host's verified module cache to the VM, so
  the VM never fetches.

RECOMMEND A. B puts 141 MB in 2,174 files into the tree (measured `go mod vendor` with modernc; 11 MB with mattn). C is the answer
if the Windows step measures the VM's fetch as slow or unreliable, and costs
a 48 MB copy per clean VM.
