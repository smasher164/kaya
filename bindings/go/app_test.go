package kaya

// The uniform-abort guard: a handler abort rolls the model mirror
// back, ships nothing, and the app continues — the same observable
// semantics as every other binding (the negative test each language
// carries). Runs headless: the library loads (KAYA_LIB) but the core
// loop is never entered; records queue and the process exits.

import (
	"encoding/binary"
	"os"
	"regexp"
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

// A Tx IS ONLY VALID INSIDE THE Build OR HANDLER THAT MADE IT, and a
// captured one must die loudly. It used to die SILENTLY: Tx.Write
// appended into a record slice Build had already submitted and would
// never submit again, so the write vanished with no panic and no error.
// The `closed` flag existed and the Widget/MenuItem chains checked it;
// the transaction's own methods did not.
//
// Nothing invited that mistake until App.Post, which is precisely a
// reason to hold a Tx near a background thread — so the guard is now
// total, at two chokepoints (Tx.emit for writes, Tx.mirror for model
// reads), and this proves BOTH fire.
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

	// And the app survives all of it: a later transaction still works,
	// so the guard rejects the caller without poisoning the App.
	app.Build(func(tx *Tx) { tx.Write(s, "after all") })
}

// THE CHOKEPOINT MUST STAY A CHOKEPOINT. Tx.emit is the only place that
// appends to a transaction's records, which is what makes the liveness
// check impossible to forget at a new callsite — there were 109 such
// callsites before this, spread over three files, and every one of them
// was a place the check was already missing. A new direct append would
// silently reopen the hole, and no compiler or vet pass would say so.
//
// EVERY SOURCE FILE OF THE PACKAGE, not a list of three: a list is a
// thing to forget, and the file a future surface lands in is exactly the
// one nobody adds. (Undo landed in app.go, but it could as easily have
// been undo.go, and this test would have said nothing about it.)
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
	// A directory read that found nothing would pass this test while
	// checking nothing at all.
	if scanned < 4 {
		t.Fatalf("scanned %d package sources — the walk stopped finding the "+
			"package, so this test proves nothing", scanned)
	}
	// Exactly one, and it is emit's own body.
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

// POST IS THE ONE METHOD SAFE FROM ANOTHER GOROUTINE, and it must QUEUE
// rather than run: a closure executed on the caller's goroutine would
// race the app goroutine's own model and transaction state, which no
// amount of care in the closure could fix.
//
// The first assertion is the one that matters. Everything is still
// unrun after the posting goroutine has finished and been joined, so
// "did not run inline" is a fact here, not a timing accident.
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

// A POST FROM INSIDE A HANDLER QUEUES FOR AFTER; IT NEVER NESTS. The
// handler appends a, posts a closure appending b, appends c. Queued, the
// handler finishes "ac" and the closure then makes it "acb". Nested, the
// closure would run between them and the only reachable answer is "abc"
// — the two strings cannot be confused, which is what makes this the
// discriminator the scene uses too (docs/background-work-plan.md §5).
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

// A CLOSURE THAT POSTS AGAIN LANDS IN THE NEXT BATCH. drainPosted takes
// the queue and drops the lock before running any of it, precisely so
// this cannot loop forever inside one drain and starve the occurrence
// ring — an app that re-posts on a timerish loop would otherwise never
// see another click.
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

// THE GROUP MARKER LEADS THE BATCH WHEREVER THE CALL SITS. A handler
// naturally builds first and names the step once it knows what the step
// was, and the wire admits the marker only as the FIRST record of the
// batch — so Undoable rotates rather than appends, and nothing else
// about the batch may move. A binding that got this wrong would not
// fail loudly: the core reads a group marker mid-batch as a malformed
// transaction, and the shape it is easiest to ship is a group that
// silently covers the wrong ops.
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
		// The rotate must not disturb the rest: the two writes stay in
		// the order the handler made them.
		rest := []uint16{recKind(tx.records[1]), recKind(tx.records[2])}
		if rest[0] != txWriteSignal || rest[1] != txCollectionInsert {
			t.Fatalf("the rotate reordered the batch: kinds after the marker %v", rest)
		}
	})
	// The aux-window spelling names its own ledger.
	app.Build(func(tx *Tx) {
		tx.Write(s, "c")
		tx.UndoableIn(7, "in seven")
		if window := binary.LittleEndian.Uint64(tx.records[0][8:16]); window != 7 {
			t.Fatalf("UndoableIn named window %d, want 7", window)
		}
	})
}

// ONE NAME PER STEP. A second call is a guest bug, not a second group:
// the wire carries one marker per batch, so the alternative to the
// panic is a name silently ignored.
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

// AN UNDO MOVED CORE STATE WITHOUT A TRANSACTION, so the mirror follows
// the payload or every read-back is stale — Tx.Len is what the undo
// scene's "undid add milk, 0 total" is computed from. Entries arrive as
// statements (present or gone) and orders as one instance's whole key
// list, exactly as the Rust binding's absorb_undo folds them.
func TestAnUndoneDeltaReconcilesTheModelMirror(t *testing.T) {
	app := NewApp()
	var c Collection
	app.Build(func(tx *Tx) {
		c = tx.Collection()
		tx.Insert(c, "a", "one")
		tx.Insert(c, "b", "two")
		tx.Insert(c, "c", "three")
	})
	// What the core would send after undoing "insert c, retitle a" and
	// putting the order back to c, b, a.
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

// AND A RECORD COLLECTION GETS ITS RECORDS BACK, not the wire's fields:
// the mirror holds T values and Items type-asserts them, so a binding
// that folded the payload verbatim would panic on the next read rather
// than at the fold. Registered where the type is known (CollectionOf),
// used where it is not (the occurrence loop).
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

// THE FRESH-KEY MINTER: one counter per collection INSTANCE, mint is
// counter+1, and nothing writes it downwards (docs/fresh-key-plan.md).
// The undo scene observes the sequence through its keys label, but not
// the RETURN VALUE — its app has no use for a name — so the value the
// contract says an app can select a row with is pinned here.
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
		// A COUNTER PER INSTANCE, not per collection: an instance is a
		// table and keys are unique within one, so the todos of two
		// different groups both start at 1.
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
	// AND AN ABANDONED TRANSACTION DOES NOT HAND THE KEY BACK. The
	// rollback journal restores the model, not the counter: a minted key
	// is spent, or two todos could be handed one name.
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

// ABSORPTION, on the one path every explicit key travels: a numeric key
// at or above the counter carries it up, so a later mint cannot collide
// with a hand-chosen number. All three insert surfaces absorb, because
// there is one insert underneath them (Tx.insertEntry).
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
		// BELOW the counter moves nothing.
		tx.Insert(todos, int64(3), "older")
		if k := tx.InsertFresh(todos, "typed again"); k != int64(9) {
			t.Fatalf("a key below the counter moved it: the mint is %v, want 9", k)
		}
		// AT the counter still carries it past: 9 is spent.
		tx.Insert(todos, int64(9), "collides with the last mint")
		if k := tx.InsertFresh(todos, "and again"); k != int64(10) {
			t.Fatalf("a key at the counter did not carry it: the mint is %v, want 10", k)
		}
		// A NON-NUMERIC KEY MOVES NOTHING, having no way to collide.
		tx.Insert(todos, "t99", "named")
		if k := tx.InsertFresh(todos, "last"); k != int64(11) {
			t.Fatalf("a string key moved the counter: the mint is %v, want 11", k)
		}
		// The typed surface absorbs through the same path.
		records = CollectionOf[int64, checkTodo](tx)
		records.Insert(tx, int64(4), checkTodo{Title: "hand-chosen"})
		if k := InsertFresh(tx, records, checkTodo{Title: "minted"}); k != int64(5) {
			t.Fatalf("the record surface did not absorb: the mint is %v, want 5", k)
		}
	})
}

// A FRESH KEY IS FRESH FOREVER. Undo and redo replay captured keys
// inside the core and never re-enter the guest insert path, so a history
// walk moves no counter — the claim the undo scene reads as "keys 1,2"
// where a rewinding counter would mint 1 again and collide with the
// entry that is still there.
func TestAMintAfterAnUndoAndARedoIsStillFresh(t *testing.T) {
	app := NewApp()
	var todos Collection
	app.Build(func(tx *Tx) {
		todos = tx.Collection()
		if k := tx.InsertFresh(todos, "milk"); k != int64(1) {
			t.Fatalf("the first mint is %v, want 1", k)
		}
	})
	// The undo empties the table (the core's own replay, not an insert).
	app.absorbUndo(UndoDelta{Entries: []UndoEntry{{Collection: todos.id, Key: int64(1)}}})
	app.Build(func(tx *Tx) {
		if n := tx.Len(todos); n != 0 {
			t.Fatalf("the undo left %d entries, want 0", n)
		}
		if k := tx.InsertFresh(todos, "tea"); k != int64(2) {
			t.Fatalf("the undo moved the counter: the mint is %v, want 2", k)
		}
	})
	// The redo puts key 1 back on top of a table that now holds 2.
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
