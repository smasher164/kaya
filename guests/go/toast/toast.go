// The toast scene (tools/scenes/toast.steps; docs/toast-plan.md §5).
package toast

import (
	"fmt"
	"strings"

	kaya "dev.kaya/bindings/go"
)

//go:generate go run dev.kaya/cmd/kaya-gen -type Item -key string
type Item struct {
	Title string
}

func outcome(o kaya.ToastOutcome) string {
	switch o {
	case kaya.ToastOutcomeAction:
		return "action"
	default:
		return "closed"
	}
}

func titles(tx *kaya.Tx, items kaya.RecordCollection[string, Item]) string {
	all := []string{}
	for _, e := range items.Items(tx) {
		all = append(all, e.Value.Title)
	}
	if len(all) == 0 {
		return "empty"
	}
	return strings.Join(all, ", ")
}

func App() *kaya.App {
	app := kaya.NewApp()
	answers, undos := 0, 0
	var held uint64

	app.Build(func(tx *kaya.Tx) {
		last := tx.Signal("no answer yet")
		count := tx.Signal("answers 0")
		undone := tx.Signal("nothing undone")
		rows := tx.Signal("Milk, Eggs, Bread")
		items := ItemCollection(tx)

		win := tx.Window(0).Title("toast").
			OnUndone(func(tx *kaya.Tx, label string, _ kaya.UndoDelta) {
				undos++
				tx.Write(undone, fmt.Sprintf("undone %d: %s", undos, label))
				tx.Write(rows, titles(tx, items))
			})
		edit := win.Menu("Edit")
		edit.Item("Undo").Role(kaya.RoleUndo)
		edit.Item("Redo").Role(kaya.RoleRedo)

		answer := func(text string) func(*kaya.Tx, kaya.ToastOutcome) {
			return func(tx *kaya.Tx, o kaya.ToastOutcome) {
				answers++
				tx.Write(count, fmt.Sprintf("answers %d", answers))
				tx.Write(last, text+": "+outcome(o))
			}
		}

		tx.Mount(tx.Column(func() {
			tx.Label(last)                        // label#0
			tx.Label(count)                       // label#1
			tx.Label(undone)                      // label#2
			tx.Label(rows)                        // label#3
			tx.Button("show", func(tx *kaya.Tx) { // button#0
				tx.ShowToast("Saved").OnResult(answer("Saved")).Show()
			})
			tx.Button("first", func(tx *kaya.Tx) { // button#1
				tx.ShowToast("First").Action("Open").OnResult(answer("First")).Show()
			})
			tx.Button("second", func(tx *kaya.Tx) { // button#2
				tx.ShowToast("Second").Action("Open").OnResult(answer("Second")).Show()
			})
			tx.Button("delete", func(tx *kaya.Tx) { // button#3
				all := items.Items(tx)
				if len(all) == 0 {
					return
				}
				first := all[0]
				tx.Undoable("delete " + first.Value.Title)
				items.Remove(tx, first.Key)
				tx.Write(rows, titles(tx, items))
				text := "Deleted " + first.Value.Title
				tx.ShowToast(text).Action("Undo").Undo().OnResult(answer(text)).Show()
			})
			tx.Button("hold", func(tx *kaya.Tx) { // button#4
				held = tx.ShowToast("Working").Long().OnResult(answer("Working")).Show()
			})
			tx.Button("dismiss", func(tx *kaya.Tx) { // button#5
				if held != 0 {
					tx.DismissToast(held)
					held = 0
				}
			})
			for row := range ItemRows(tx, items).All() {
				row.Row(func() {
					row.Label(row.Title())
				})
			}
		}))

		for _, title := range []string{"Milk", "Eggs", "Bread"} {
			items.Insert(tx, title, Item{Title: title})
		}
	})

	return app
}
