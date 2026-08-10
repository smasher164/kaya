// The feed scene from Go: sum-typed elements, end to end. The sealed
// marker interface is the sum, the structs its constructors, and
// elimination is Go-shaped on both sides: typed case arms author the
// template blueprints (the scene holds them to totality at
// declaration), and handlers type-switch on the model's current value
// — a refinement the witnessed UpdateField checks rather than trusts,
// so a stale occurrence folds into nothing.
//
// Build the library first (cargo build), then, from the repo root:
//
//	KAYA_SELFTEST=feed go run dev.kaya/guests/go/feed
package feed

import (
	"fmt"

	kaya "dev.kaya/bindings/go"
)

// Post is the sum: a sealed marker interface over its constructors.
// kaya-gen reads this declaration — the implementing structs, in
// declaration order — and emits post_kaya.go: the collection factory
// (the one spelling of the constructor order) and the compile-total
// PostEachSum eliminator.
//
//go:generate go run dev.kaya/cmd/kaya-gen -type Post -key string
type Post interface{ isPost() }

type Note struct{ Text string }

type Todo struct {
	Title string
	Done  bool
}

func (Note) isPost() {}
func (Todo) isPost() {}

// App builds the scene and hands it back ready to be served.
//
// THE TAIL IS THE ONLY THING THAT DIFFERS BY PLATFORM, and it differs
// because the hosting does: a desktop or iOS guest owns the process
// main thread and lends it to kaya (guests/go/cmd/main_desktop.go),
// while on Android the OS owns main and kaya starts the guest on a
// thread of its own (guests/go/cmd/main_android.go). Both tails are
// one package over one scene table, so everything above them — the
// transaction, the handlers, the strings — is compiled into every
// platform's artifact from these bytes.
func App() *kaya.App {
	app := kaya.NewApp()

	app.Build(func(tx *kaya.Tx) {
		feed := PostCollection(tx)
		doneCount := feed.Derive(tx, func(items []kaya.RecordEntry[string, Post]) string {
			n := 0
			for _, e := range items {
				if todo, ok := e.Value.(Todo); ok && todo.Done {
					n++
				}
			}
			return fmt.Sprintf("%d done", n)
		})

		tx.Mount(tx.Row(func() {
			tx.Button("promote", func(tx *kaya.Tx) {
				// The first note, promoted to a finished todo: the
				// model is asked which entry is a Note — the handler
				// never counts widgets — and the update's new
				// constructor restamps that key's copy in place.
				for _, e := range feed.Items(tx) {
					if note, ok := e.Value.(Note); ok {
						feed.Update(tx, e.Key, Todo{Title: note.Text, Done: true})
						break
					}
				}
			})
			tx.Label(doneCount)
			// The generated eliminator: one required arm per
			// constructor, so a missing arm is a missing argument — a
			// compile error. The literals' parameter types are the arm
			// labels.
			PostEachSum(tx, feed,
				func(note kaya.SumCase[string, Note]) {
					note.Label(func(n *Note) *string { return &n.Text })
				},
				func(todo kaya.SumCase[string, Todo]) {
					todo.Row(func() {
						todo.Checkbox(func(td *Todo) *bool { return &td.Done },
							func(tx *kaya.Tx, key string, checked bool) {
								// The generated refined patch: the
								// comma-ok re-eliminates at write time
								// (a stale occurrence folds into the
								// !ok arm), and the update stays
								// witnessed underneath.
								if todo, ok := PostAsTodo(tx, feed, key); ok {
									todo.Done(checked)
								}
							})
						todo.Label(func(td *Todo) *string { return &td.Title })
					})
				},
			)
		}))
		for _, ins := range []struct {
			key  string
			post Post
		}{
			{"a", Note{Text: "jot one"}},
			{"b", Todo{Title: "buy milk"}},
			{"c", Note{Text: "jot two"}},
		} {
			feed.Insert(tx, ins.key, ins.post)
		}
	})

	return app
}
