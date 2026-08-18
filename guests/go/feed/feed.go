// The feed scene from Go: sum-typed elements, end to end. The sealed
// marker interface is the sum, the structs its constructors, and
// elimination is Go-shaped on both sides — typed case arms author the
// template blueprints, and handlers type-switch on the model's current
// value, a refinement the witnessed UpdateField checks rather than
// trusts, so a stale occurrence folds into nothing.
package feed

import (
	"fmt"

	kaya "dev.kaya/bindings/go"
)

// Post is the sum. kaya-gen reads this declaration — the implementing
// structs, IN DECLARATION ORDER — and emits post_kaya.go.
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
				for _, e := range feed.Items(tx) {
					if note, ok := e.Value.(Note); ok {
						feed.Update(tx, e.Key, Todo{Title: note.Text, Done: true})
						break
					}
				}
			})
			tx.Label(doneCount)
			// The generated eliminator: one required arm per
			// constructor, so a missing arm is a missing argument.
			PostEachSum(tx, feed,
				func(note kaya.SumCase[string, Note]) {
					note.Label(func(n *Note) *string { return &n.Text })
				},
				func(todo kaya.SumCase[string, Todo]) {
					todo.Row(func() {
						todo.Checkbox(func(td *Todo) *bool { return &td.Done },
							func(tx *kaya.Tx, key string, checked bool) {
								// The generated refined patch: the
								// comma-ok re-eliminates at write
								// time, so a stale occurrence folds
								// into the !ok arm.
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
