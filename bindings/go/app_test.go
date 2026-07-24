package kaya

// The uniform-abort guard: a handler abort rolls the model mirror
// back, ships nothing, and the app continues — the same observable
// semantics as every other binding (the negative test each language
// carries). Runs headless: the library loads (KAYA_LIB) but the core
// loop is never entered; records queue and the process exits.

import (
	"encoding/binary"
	"strings"
	"testing"
)

func entryKeys(tx *Tx, c Collection) []any {
	items := tx.Items(c)
	keys := make([]any, len(items))
	for i, e := range items {
		keys[i] = e.Key
	}
	return keys
}

func keysEqual(a, b []any) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

func TestAbortRestoresModelShipsNothingAndContinues(t *testing.T) {
	app := NewApp()
	var todos Collection
	app.Build(func(tx *Tx) {
		todos = tx.Collection()
		tx.Insert(todos, "a", "one")
		tx.Insert(todos, "b", "two")
	})

	// Abort mid-transaction after mutating: the boundary must restore
	// the mirror and re-panic (rollback + propagate is the tx
	// boundary's contract; surviving is the dispatch loop's).
	func() {
		defer func() {
			if recover() == nil {
				t.Fatal("Build swallowed the panic — the tx boundary must propagate")
			}
		}()
		app.Build(func(tx *Tx) {
			tx.Insert(todos, "c", "three")
			tx.Remove(todos, "a")
			panic("handler bug")
		})
	}()
	app.Build(func(tx *Tx) {
		if got := entryKeys(tx, todos); !keysEqual(got, []any{"a", "b"}) {
			t.Fatalf("abort did not restore the mirror: %v", got)
		}
	})

	// The dispatch discipline: a panicking handler is logged and the
	// loop continues — the next transaction works and sees the
	// restored model.
	app.dispatch(func(tx *Tx) {
		tx.Insert(todos, "d", "four")
		panic("handler bug")
	})
	app.Build(func(tx *Tx) {
		if got := entryKeys(tx, todos); !keysEqual(got, []any{"a", "b"}) {
			t.Fatalf("dispatch abort leaked into the mirror: %v", got)
		}
		tx.Insert(todos, "c", "three")
	})
	app.Build(func(tx *Tx) {
		if got := entryKeys(tx, todos); !keysEqual(got, []any{"a", "b", "c"}) {
			t.Fatalf("post-abort commit broken: %v", got)
		}
	})

	// An aborted transaction abandons its derived registrations with
	// its records: the pending list promotes only on commit.
	var rc RecordCollection[string, checkTodo]
	app.dispatch(func(tx *Tx) {
		rc = CollectionOf[string, checkTodo](tx)
		rc.Derive(tx, func(items []RecordEntry[string, checkTodo]) int64 {
			return int64(len(items))
		})
		panic("handler bug")
	})
	if n := len(app.derived[rc.id]); n != 0 {
		t.Fatalf("aborted tx leaked %d derived registrations", n)
	}
}

type checkTodo struct {
	Title string
}

// The blob channel's record layer: a []byte field maps to ValueBlob in
// the schema, and every encode registers the bytes right then —
// handles are single-submit, so insert, update, and update_field each
// produce a fresh handle. Headless like the rest of the file:
// registration crosses into the library, the core loop never runs.
type blobRec struct {
	Name string
	Pic  []byte
}

func TestBlobFieldsMapAndRegisterAtEncodeTime(t *testing.T) {
	app := NewApp()
	app.Build(func(tx *Tx) {
		c := CollectionOf[string, blobRec](tx)
		if s := c.info.schema; len(s) != 2 || s[0] != ValueStr || s[1] != ValueBlob {
			t.Fatalf("[]byte did not map to ValueBlob: schema %v", s)
		}
		vals := c.info.values(blobRec{"a", []byte{1, 2, 3}})
		if _, ok := vals[1].(BlobHandle); !ok {
			t.Fatalf("blob field encoded as %T, not BlobHandle", vals[1])
		}
		// The whole mutation surface goes through the same encoder.
		c.Insert(tx, "a", blobRec{"a", []byte{1, 2, 3}})
		c.Update(tx, "a", blobRec{"a", []byte{4, 5}})
		c.UpdateField(tx, "a", func(r *blobRec) *[]byte { return &r.Pic }, []byte{6})
	})
}

// The clear-error type guard: anything but a byte slice in a blob
// position fails by name, here, instead of deep in the wire encoder.
func TestBlobGuardRejectsNonBytes(t *testing.T) {
	defer func() {
		if recover() == nil {
			t.Fatal("blobWire accepted a string")
		}
	}()
	blobWire("not bytes")
}

// The record-time mirror-read guard: a model read inside a template
// body panics — the template records once and replays, so the read
// would bake today's value into the blueprint as silently dead data.
// For bodies, When bodies, and the row trace all arm it. Each case
// aborts its Build (the panic crosses the boundary), which also pins
// the abort path's zone-state reset: the final Build proves reads
// outside template scopes stay legal afterward.
func TestMirrorReadsPoisonInsideTemplateBodies(t *testing.T) {
	app := NewApp()
	cases := []struct {
		name string
		body func(tx *Tx, c Collection)
	}{
		{"for body", func(tx *Tx, c Collection) {
			tx.ForEach(c, func(*Tpl) { tx.Items(c) })
		}},
		{"when body", func(tx *Tx, c Collection) {
			s := tx.Signal(true)
			tx.When(s, func(*Tpl) { tx.Len(c) })
		}},
		{"row trace", func(tx *Tx, c Collection) {
			_, _ = BeginRowTrace(tx, c)
			tx.Items(c)
		}},
	}
	for _, tc := range cases {
		func() {
			defer func() {
				if recover() == nil {
					t.Fatalf("%s: template-body read did not panic", tc.name)
				}
			}()
			app.Build(func(tx *Tx) {
				c := tx.Collection()
				tx.Insert(c, "a", "one")
				tc.body(tx, c)
			})
		}()
	}
	app.Build(func(tx *Tx) {
		c := tx.Collection()
		tx.Insert(c, "b", "two")
		if n := tx.Len(c); n != 1 {
			t.Fatalf("post-abort live read broken: %d", n)
		}
	})
}

// The menu construction surface must REACH the record stream — the
// wire-dropped-write class: a constructor that emits nothing passes
// every surface gate until a scene fails live (the dropped-spacing
// lesson; Python's kaya_app_checks.py is the pattern). In-package,
// so the queued records are countable before submit; each frame is
// u32 length then u16 kind at offset 4, little-endian.
func recKind(rec []byte) uint16 {
	return binary.LittleEndian.Uint16(rec[4:6])
}

func countKind(records [][]byte, kind uint16) int {
	n := 0
	for _, r := range records {
		if recKind(r) == kind {
			n++
		}
	}
	return n
}

func TestMenuConstructionEmitsAndAbortsWithTheTx(t *testing.T) {
	app := NewApp()
	var file MenuItem
	app.Build(func(tx *Tx) {
		before := len(tx.records)
		file = tx.Window(0).Menu("File")
		file.Item("Save").Shortcut("PRIMARY+S")
		sort := tx.Window(0).RadioGroup("Sort")
		sort.Option("Name")
		sort.Option("Date")
		sort.Value(1)
		noun := tx.LabelText("noun")
		tx.ContextMenu(noun).Item("Rename")
		queued := tx.records[before:]
		// File, Save, Sort, Name, Date, Rename.
		if n := countKind(queued, txMenuItemCreate); n != 6 {
			t.Fatalf("menu constructors queued %d creates, want 6", n)
		}
		if n := countKind(queued, txMenubarAppend); n != 2 {
			t.Fatalf("bar anchors queued %d menubar appends, want 2", n)
		}
		if n := countKind(queued, txMenuItemAppend); n != 3 {
			t.Fatalf("children queued %d item appends, want 3", n)
		}
		if n := countKind(queued, txContextAttach); n != 1 {
			t.Fatalf("context anchor queued %d attaches, want 1", n)
		}
		canonical := false
		for _, r := range queued {
			if recKind(r) == txSetMenuProp && strings.Contains(string(r), "primary+s") {
				canonical = true
			}
		}
		if !canonical {
			t.Fatal("Shortcut did not reach the records canonicalized")
		}
	})

	// Append-at-any-time: the retained handle reopens in a later
	// transaction — one create plus one append under the RETAINED
	// parent, and never a new bar anchor.
	app.Build(func(tx *Tx) {
		before := len(tx.records)
		tx.Menu(file).Item("Publish")
		queued := tx.records[before:]
		if n := countKind(queued, txMenuItemCreate); n != 1 {
			t.Fatalf("reopen queued %d creates, want 1", n)
		}
		var appendRec []byte
		for _, r := range queued {
			if recKind(r) == txMenuItemAppend {
				appendRec = r
			}
		}
		if appendRec == nil {
			t.Fatal("reopen queued no append")
		}
		if parent := binary.LittleEndian.Uint64(appendRec[8:16]); parent != file.id {
			t.Fatalf("reopen seated under %d, want the retained parent %d", parent, file.id)
		}
		if countKind(queued, txMenubarAppend) != 0 {
			t.Fatal("reopen re-anchored the bar")
		}
	})

	// An aborted append drops its menu records with everything else
	// (records die with the tx; nothing ships) and the app continues.
	func() {
		defer func() {
			if recover() == nil {
				t.Fatal("Build swallowed the panic — the tx boundary must propagate")
			}
		}()
		app.Build(func(tx *Tx) {
			tx.Menu(file).Item("Doomed")
			panic("handler bug")
		})
	}()
	app.Build(func(tx *Tx) {
		tx.Menu(file).Item("Recovered")
	})
}
