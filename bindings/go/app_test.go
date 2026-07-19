package kaya

// The uniform-abort guard: a handler abort rolls the model mirror
// back, ships nothing, and the app continues — the same observable
// semantics as every other binding (the negative test each language
// carries). Runs headless: the library loads (KAYA_LIB) but the core
// loop is never entered; records queue and the process exits.

import "testing"

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
