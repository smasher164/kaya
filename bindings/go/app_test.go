package kaya

// Runs headless: the library loads (KAYA_LIB) but the core loop is never
// entered.

import (
	"encoding/binary"
	"os"
	"regexp"
	"runtime"
	"strings"
	"sync"
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

// Blob handles are single-submit, so every encode must register fresh
// bytes: insert, update and update_field each produce their own.
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
		c.Insert(tx, "a", blobRec{"a", []byte{1, 2, 3}})
		c.Update(tx, "a", blobRec{"a", []byte{4, 5}})
		c.UpdateField(tx, "a", func(r *blobRec) *[]byte { return &r.Pic }, []byte{6})
	})
}

func TestBlobGuardRejectsNonBytes(t *testing.T) {
	defer func() {
		if recover() == nil {
			t.Fatal("blobWire accepted a string")
		}
	}()
	blobWire("not bytes")
}

// A template records once and replays, so a model read inside one would
// bake today's value into the blueprint. The final Build pins the abort
// path's zone-state reset.
func TestMirrorReadsPoisonInsideTemplateBodies(t *testing.T) {
	app := NewApp()
	cases := []struct {
		name string
		body func(tx *Tx, c Collection)
	}{
		{"for body", func(tx *Tx, c Collection) {
			for range tx.Rows(c).All() {
				tx.Items(c)
			}
		}},
		{"when body", func(tx *Tx, c Collection) {
			s := tx.Signal(true)
			tx.When(s, func(*Tpl) { tx.Len(c) })
		}},
		// Opening the rows is what enters the zone, before any trace begins.
		{"opened rows", func(tx *Tx, c Collection) {
			tx.Rows(c)
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

// Each frame is u32 length then u16 kind at offset 4, little-endian.
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

// Two chokepoints refuse a closed Tx: Tx.emit for writes, Tx.mirror for
// model reads (tools/check-tx-liveness.py). This proves both fire.
func TestAClosedTransactionRefusesLoudly(t *testing.T) {
	app := NewApp()
	var escaped *Tx
	var s Signal[string]
	var c Collection
	app.Build(func(tx *Tx) {
		escaped, s, c = tx, tx.Signal("before"), tx.Collection()
	})

	panics := func(what string, fn func()) {
		t.Helper()
		defer func() {
			if recover() == nil {
				t.Fatalf("%s through a closed transaction did not panic — "+
					"it was silently accepted, which is the defect this guards", what)
			}
		}()
		fn()
	}
	panics("a write", func() { escaped.Write(s, "after") })
	panics("an undo group", func() { escaped.Undoable("late") })
	panics("a signal declaration", func() { escaped.Signal("late") })
	panics("a widget declaration", func() { escaped.LabelText("late") })
	panics("a collection insert", func() { escaped.Insert(c, "k", "v") })
	panics("a model read", func() { escaped.Items(c) })
	panics("a model length read", func() { escaped.Len(c) })

	app.Build(func(tx *Tx) { tx.Write(s, "after all") })
}

// OPEN IS NOT ENOUGH: `closed` sees neither a goroutine spawned inside a
// handler writing through the transaction it still holds, nor a background
// Build — both race the app goroutine silently (tools/check-tx-liveness.py).
func TestATransactionRefusesAnotherGoroutine(t *testing.T) {
	app := NewApp()
	// The claim is a package global: hand it back, or the package's other
	// tests run against a thread rule nothing else set.
	claimAppThread()
	defer func() {
		appThread.Store(0)
		runtime.UnlockOSThread()
	}()

	var s Signal[string]
	app.Build(func(tx *Tx) { s = tx.Signal("before") })

	elsewhere := func(fn func()) string {
		t.Helper()
		var got any
		done := make(chan struct{})
		go func() {
			defer close(done)
			defer func() { got = recover() }()
			fn()
		}()
		<-done
		if got == nil {
			return ""
		}
		msg, _ := got.(string)
		return msg
	}

	var live string
	app.Build(func(tx *Tx) {
		live = elsewhere(func() { tx.Write(s, "from elsewhere") })
	})
	if !strings.Contains(live, "belongs to the app thread") {
		t.Fatalf("a write through an OPEN transaction from another goroutine "+
			"was answered with %q — it must name the thread rule and App.Post, "+
			"or it lands in tx.records from two goroutines at once", live)
	}
	if !strings.Contains(live, "App.Post") {
		t.Fatalf("the wrong-thread refusal must name the way out: %q", live)
	}

	empty := elsewhere(func() { app.Build(func(*Tx) {}) })
	if !strings.Contains(empty, "belongs to the app thread") {
		t.Fatalf("Build from another goroutine was answered with %q — an empty "+
			"body emits no record, so only Build's own check can see it", empty)
	}

	ran := ""
	done := make(chan struct{})
	go func() {
		defer close(done)
		app.Post(func(tx *Tx) { ran = "posted"; tx.Write(s, "after") })
	}()
	<-done
	app.drainPosted()
	if ran != "posted" {
		t.Fatalf("Post from another goroutine did not reach the app thread: %q", ran)
	}
	app.Build(func(tx *Tx) { tx.Write(s, "after all") })
}

// Tx.emit is the only place that appends to a transaction's records, which
// is what makes the liveness check impossible to forget at a new callsite.
// Scanned over EVERY source file, not a list — the file a future surface
// lands in is exactly the one nobody adds to a list.
func TestEveryRecordGoesThroughTheOneChokepoint(t *testing.T) {
	direct := regexp.MustCompile(`\.records = append\(`)
	found := map[string]int{}
	sources, err := os.ReadDir(".")
	if err != nil {
		t.Fatalf("reading the package directory: %v", err)
	}
	scanned := 0
	for _, entry := range sources {
		name := entry.Name()
		if entry.IsDir() || !strings.HasSuffix(name, ".go") ||
			strings.HasSuffix(name, "_test.go") {
			continue
		}
		scanned++
		src, err := os.ReadFile(name)
		if err != nil {
			t.Fatalf("reading %s: %v", name, err)
		}
		if n := len(direct.FindAll(src, -1)); n > 0 {
			found[name] = n
		}
	}
	if scanned < 4 {
		t.Fatalf("scanned %d package sources — the walk stopped finding the "+
			"package, so this test proves nothing", scanned)
	}
	if len(found) != 1 || found["app.go"] != 1 {
		t.Fatalf("direct appends to a transaction's records: %v — want exactly "+
			"one, in Tx.emit. A callsite that appends directly skips the "+
			"liveness check; that is how a write through a dead Tx used to "+
			"vanish. Route it through tx.emit instead.", found)
	}
	src, err := os.ReadFile("app.go")
	if err != nil {
		t.Fatal(err)
	}
	body := string(src)
	i := strings.Index(body, "func (tx *Tx) emit(")
	if i < 0 {
		t.Fatal("Tx.emit is gone; the chokepoint moved without this test moving")
	}
	if j := strings.Index(body[i:], "\n}\n"); j < 0 || !direct.MatchString(body[i:i+j]) {
		t.Fatal("the one direct append is not inside Tx.emit")
	}
}

// The join before the first assertion is what makes "did not run inline" a
// fact rather than a timing accident.
func TestPostQueuesForTheAppGoroutineInOrder(t *testing.T) {
	app := NewApp()
	var s Signal[string]
	app.Build(func(tx *Tx) { s = tx.Signal("") })

	order := ""
	var wg sync.WaitGroup
	wg.Add(1)
	go func() {
		defer wg.Done()
		for _, c := range []string{"1", "2", "3"} {
			app.Post(func(tx *Tx) {
				order += c
				tx.Write(s, order)
			})
		}
	}()
	wg.Wait()
	if order != "" {
		t.Fatalf("Post ran the closure on the CALLER's goroutine (order %q) — "+
			"it must queue for the app goroutine", order)
	}

	app.drainPosted()
	if order != "123" {
		t.Fatalf("drained %q, want \"123\" — posts run in the order they were made", order)
	}
}

// Queued reads "acb", nested reads "abc" — the discriminator the scene uses
// too (docs/background-work-plan.md §5).
func TestPostFromInsideAHandlerQueuesForAfter(t *testing.T) {
	app := NewApp()
	seq := ""
	app.dispatch(func(tx *Tx) {
		seq += "a"
		app.Post(func(*Tx) { seq += "b" })
		seq += "c"
	})
	if seq != "ac" {
		t.Fatalf("handler saw %q, want \"ac\" — the post nested instead of queueing", seq)
	}
	app.drainPosted()
	if seq != "acb" {
		t.Fatalf("after the drain %q, want \"acb\"", seq)
	}
}

// drainPosted takes the queue and drops the lock before running any of it,
// so a re-posting loop cannot starve the occurrence ring.
func TestASelfPostWaitsForTheNextDrain(t *testing.T) {
	app := NewApp()
	ran := 0
	var again func()
	again = func() {
		app.Post(func(*Tx) {
			ran++
			if ran < 3 {
				again()
			}
		})
	}
	again()
	app.drainPosted()
	if ran != 1 {
		t.Fatalf("one drain ran %d closures, want 1 — a self-post must wait for the next batch", ran)
	}
	app.drainPosted()
	if ran != 2 {
		t.Fatalf("second drain left ran=%d, want 2", ran)
	}
}

// --- Undo (docs/undo-plan.md D2, D5) --------------------------------

// The wire admits the group marker only as the FIRST record of a batch, so
// Undoable rotates rather than appends; a group at the wrong place silently
// covers the wrong ops.
func TestUndoableLeadsTheBatchWhereverItIsCalled(t *testing.T) {
	app := NewApp()
	var s Signal[string]
	var c Collection
	app.Build(func(tx *Tx) {
		s = tx.Signal("a")
		c = tx.Collection()
	})
	app.Build(func(tx *Tx) {
		tx.Write(s, "b")
		tx.Insert(c, "k", "v")
		tx.Undoable("add k") // named LAST, the handler's natural order
		if n := countKind(tx.records, txUndoGroup); n != 1 {
			t.Fatalf("queued %d undo_group records, want exactly 1", n)
		}
		if k := recKind(tx.records[0]); k != txUndoGroup {
			t.Fatalf("the batch leads with kind %d, not the group marker (%d) — "+
				"the wire admits it only at the head", k, txUndoGroup)
		}
		if window := binary.LittleEndian.Uint64(tx.records[0][8:16]); window != 0 {
			t.Fatalf("Undoable named window %d, want the primary (0)", window)
		}
		rest := []uint16{recKind(tx.records[1]), recKind(tx.records[2])}
		if rest[0] != txWriteSignal || rest[1] != txCollectionInsert {
			t.Fatalf("the rotate reordered the batch: kinds after the marker %v", rest)
		}
	})
	app.Build(func(tx *Tx) {
		tx.Write(s, "c")
		tx.UndoableIn(7, "in seven")
		if window := binary.LittleEndian.Uint64(tx.records[0][8:16]); window != 7 {
			t.Fatalf("UndoableIn named window %d, want 7", window)
		}
	})
}

func TestASecondUndoableNameIsRefused(t *testing.T) {
	app := NewApp()
	defer func() {
		r := recover()
		if r == nil {
			t.Fatal("a second Undoable was accepted — one of the two names would " +
				"have vanished with no error")
		}
		if msg, _ := r.(string); !strings.Contains(msg, "already an undo group") {
			t.Fatalf("panicked with %v, want the one-name-per-step message", r)
		}
	}()
	app.Build(func(tx *Tx) {
		tx.Undoable("first")
		tx.Undoable("second")
	})
}

// An undo moves core state WITHOUT a transaction, so the mirror follows the
// payload or every read-back is stale. Entries arrive as statements (present
// or gone), orders as one instance's whole key list.
func TestAnUndoneDeltaReconcilesTheModelMirror(t *testing.T) {
	app := NewApp()
	var c Collection
	app.Build(func(tx *Tx) {
		c = tx.Collection()
		tx.Insert(c, "a", "one")
		tx.Insert(c, "b", "two")
		tx.Insert(c, "c", "three")
	})
	app.absorbUndo(UndoDelta{
		Entries: []UndoEntry{
			{Collection: c.id, Key: "c"},
			{Collection: c.id, Key: "a", Present: true, Record: []any{"ONE"}},
			{Collection: c.id, Key: "z", Present: true, Record: []any{"zed"}},
		},
		Orders: []UndoOrder{{Collection: c.id, Keys: []any{"z", "b", "a"}}},
	})
	app.Build(func(tx *Tx) {
		if got := entryKeys(tx, c); !keysEqual(got, []any{"z", "b", "a"}) {
			t.Fatalf("the mirror holds %v after the undo, want [z b a]", got)
		}
		if n := tx.Len(c); n != 3 {
			t.Fatalf("Len reads %d after the undo, want 3", n)
		}
		items := tx.Items(c)
		if items[2].Value != "ONE" {
			t.Fatalf("a restored entry holds %v, want the payload's value", items[2].Value)
		}
	})
}

// The mirror holds T values and Items type-asserts them: folding an undo
// payload's wire fields verbatim panics on the next READ, not at the fold.
func TestAnUndoneDeltaRestoresRecordsNotWireFields(t *testing.T) {
	app := NewApp()
	var todos RecordCollection[string, checkTodo]
	app.Build(func(tx *Tx) {
		todos = CollectionOf[string, checkTodo](tx)
		todos.Insert(tx, "t1", checkTodo{Title: "milk"})
	})
	app.absorbUndo(UndoDelta{Entries: []UndoEntry{
		{Collection: todos.id, Key: "t1", Present: true, Record: []any{"tea"}},
	}})
	app.Build(func(tx *Tx) {
		items := todos.Items(tx)
		if len(items) != 1 || items[0].Value.Title != "tea" {
			t.Fatalf("the mirror holds %v after the undo, want one checkTodo{tea}", items)
		}
	})
}

// One counter per collection INSTANCE (docs/fresh-key-plan.md). No scene
// observes the RETURN VALUE, so it is pinned here.
func TestFreshKeysAreMintedPerInstanceAndNeverRewind(t *testing.T) {
	app := NewApp()
	var groups, todos Collection
	app.Build(func(tx *Tx) {
		groups = tx.Collection()
		todos = tx.Collection()
		if k := tx.InsertFresh(groups, "Work"); k != int64(1) {
			t.Fatalf("the first mint is %v, want 1", k)
		}
		if k := tx.InsertFresh(groups, "Home"); k != int64(2) {
			t.Fatalf("the second mint is %v, want 2", k)
		}
		g1, g2 := todos.At(int64(1)), todos.At(int64(2))
		if k := tx.InsertFresh(g1, "send report"); k != int64(1) {
			t.Fatalf("the first mint of instance g1 is %v, want 1", k)
		}
		if k := tx.InsertFresh(g1, "buy milk"); k != int64(2) {
			t.Fatalf("the second mint of instance g1 is %v, want 2", k)
		}
		if k := tx.InsertFresh(g2, "water the plants"); k != int64(1) {
			t.Fatalf("the first mint of instance g2 is %v, want 1", k)
		}
	})
	// The rollback journal restores the model, not the counter, so an
	// abandoned transaction does not hand its key back.
	func() {
		defer func() { _ = recover() }()
		app.Build(func(tx *Tx) {
			if k := tx.InsertFresh(groups, "Errands"); k != int64(3) {
				t.Fatalf("the mint inside the doomed tx is %v, want 3", k)
			}
			panic("handler bug")
		})
	}()
	app.Build(func(tx *Tx) {
		if got := entryKeys(tx, groups); !keysEqual(got, []any{int64(1), int64(2)}) {
			t.Fatalf("the abort left %v in the mirror, want [1 2]", got)
		}
		if k := tx.InsertFresh(groups, "Errands"); k != int64(4) {
			t.Fatalf("a spent key came back: the mint is %v, want 4", k)
		}
	})
}

// A numeric key at or above the counter carries it up, so a later mint
// cannot collide with a hand-chosen number. All three insert surfaces absorb
// because there is one insert underneath (Tx.insertEntry).
func TestAnExplicitI64KeyCarriesTheMinterPastIt(t *testing.T) {
	app := NewApp()
	var todos Collection
	var records RecordCollection[int64, checkTodo]
	app.Build(func(tx *Tx) {
		todos = tx.Collection()
		tx.Insert(todos, int64(7), "hand-chosen")
		if k := tx.InsertFresh(todos, "typed"); k != int64(8) {
			t.Fatalf("the mint after an explicit 7 is %v, want 8 (past the explicit key)", k)
		}
		tx.Insert(todos, int64(3), "older")
		if k := tx.InsertFresh(todos, "typed again"); k != int64(9) {
			t.Fatalf("a key below the counter moved it: the mint is %v, want 9", k)
		}
		tx.Insert(todos, int64(9), "collides with the last mint")
		if k := tx.InsertFresh(todos, "and again"); k != int64(10) {
			t.Fatalf("a key at the counter did not carry it: the mint is %v, want 10", k)
		}
		tx.Insert(todos, "t99", "named")
		if k := tx.InsertFresh(todos, "last"); k != int64(11) {
			t.Fatalf("a string key moved the counter: the mint is %v, want 11", k)
		}
		records = CollectionOf[int64, checkTodo](tx)
		records.Insert(tx, int64(4), checkTodo{Title: "hand-chosen"})
		if k := InsertFresh(tx, records, checkTodo{Title: "minted"}); k != int64(5) {
			t.Fatalf("the record surface did not absorb: the mint is %v, want 5", k)
		}
	})
}

// Undo and redo replay captured keys inside the core and never re-enter the
// guest insert path, so a history walk moves no counter.
func TestAMintAfterAnUndoAndARedoIsStillFresh(t *testing.T) {
	app := NewApp()
	var todos Collection
	app.Build(func(tx *Tx) {
		todos = tx.Collection()
		if k := tx.InsertFresh(todos, "milk"); k != int64(1) {
			t.Fatalf("the first mint is %v, want 1", k)
		}
	})
	app.absorbUndo(UndoDelta{Entries: []UndoEntry{{Collection: todos.id, Key: int64(1)}}})
	app.Build(func(tx *Tx) {
		if n := tx.Len(todos); n != 0 {
			t.Fatalf("the undo left %d entries, want 0", n)
		}
		if k := tx.InsertFresh(todos, "tea"); k != int64(2) {
			t.Fatalf("the undo moved the counter: the mint is %v, want 2", k)
		}
	})
	app.absorbUndo(UndoDelta{
		Entries: []UndoEntry{{Collection: todos.id, Key: int64(1), Present: true, Record: []any{"milk"}}},
		Orders:  []UndoOrder{{Collection: todos.id, Keys: []any{int64(1), int64(2)}}},
	})
	app.Build(func(tx *Tx) {
		if got := entryKeys(tx, todos); !keysEqual(got, []any{int64(1), int64(2)}) {
			t.Fatalf("the redo left %v, want [1 2]", got)
		}
		if k := tx.InsertFresh(todos, "buns"); k != int64(3) {
			t.Fatalf("the redo moved the counter: the mint is %v, want 3", k)
		}
	})
}

// Go's int is SIGNED and select_range/reveal_range carry offsets as bare u64:
// an unguarded -1 reaches the core as 18446744073709551615.
//
// THOSE TWO MUST BE DRIVEN FIRST — do not reorder. HighlightRanges' offsets
// ride as I64 Values and the core ABORTS the process while decoding, killing
// the binary before the other two run.
func TestANegativeRangeOffsetIsRefusedByEveryRangeVerb(t *testing.T) {
	app := NewApp()
	var editor Widget
	app.Build(func(tx *Tx) { editor = tx.Textarea(nil) })

	refuses := func(what string, fn func(*Tx)) {
		t.Helper()
		defer func() {
			r := recover()
			if r == nil {
				t.Fatalf("%s with a negative offset was accepted — it would reach "+
					"the core as a u64 near 2^64 and be refused under a number the "+
					"app never wrote", what)
			}
			msg, _ := r.(string)
			if !strings.Contains(msg, "negative offset") {
				t.Fatalf("%s panicked with %v — wanted the negative-offset refusal, "+
					"so this panic is a different bug wearing the guard's clothes",
					what, r)
			}
		}()
		app.Build(fn)
	}
	refuses("SelectRange", func(tx *Tx) { tx.SelectRange(editor, TextRange{Start: 0, End: -1}) })
	refuses("RevealRange", func(tx *Tx) { tx.RevealRange(editor, TextRange{Start: -1, End: -1}) })
	refuses("HighlightRanges", func(tx *Tx) {
		tx.HighlightRanges(editor, []TextRange{{Start: 0, End: 4}, {Start: -1, End: 4}})
	})

	app.Build(func(tx *Tx) {
		tx.HighlightRanges(editor, []TextRange{{Start: 0, End: 4}, {Start: 9, End: 18}})
		tx.HighlightRanges(editor, nil) // the clear
		tx.SelectRange(editor, TextRange{Start: 4, End: 4})
		tx.RevealRange(editor, TextRange{Start: 0, End: 0})
	})
}
