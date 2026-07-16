// The todos scene from Go: records and field projection. The struct is
// the schema — CollectionOf reflects it once at declaration — the
// template binds each field to its own widget through typed field
// tokens, and toggling a row sends one field's delta through
// UpdateField: the title never travels.
//
// Build the library first (cargo build), then, from the repo root:
//
//	KAYA_SELFTEST=todos go run crates/kaya/examples/todos.go
package main

import (
	"fmt"
	"os"
	"runtime"

	kaya "dev.kaya/bindings/go"
)

func init() {
	// The core must own the process main thread.
	runtime.LockOSThread()
}

// Todo is the record type and, by reflection, the schema.
type Todo struct {
	Title string
	Done  bool
}

// The field tokens, checked against the struct at startup.
var (
	fieldTitle = kaya.FieldOf[Todo, string]("Title")
	fieldDone  = kaya.FieldOf[Todo, bool]("Done")
)

func main() {
	app := kaya.NewApp()

	var (
		itemsLeft kaya.Signal
		field     kaya.Widget
		add       kaya.Widget
		todos     kaya.RecordCollection[Todo]
		check     kaya.Node
	)

	itemsLeftText := func(tx *kaya.Tx) string {
		n := 0
		for _, e := range todos.Items(tx) {
			if !e.Value.Done {
				n++
			}
		}
		if n == 1 {
			return "1 item left"
		}
		return fmt.Sprintf("%d items left", n)
	}

	app.Build(func(tx *kaya.Tx) {
		itemsLeft = tx.Signal("0 items left")

		column := tx.Widget(kaya.KindColumn)
		field = tx.Widget(kaya.KindEntry)
		add = tx.Widget(kaya.KindButton)
		tx.SetText(add, "Add")
		status := tx.Widget(kaya.KindLabel)
		tx.BindText(status, itemsLeft)

		todos = kaya.CollectionOf[Todo](tx)
		todoList := tx.ForEach(todos.Collection, func(t *kaya.Tpl) {
			row := t.Widget(kaya.KindRow)
			check = t.Widget(kaya.KindCheckbox)
			t.BindCheckedField(check, 0, fieldDone)
			title := t.Widget(kaya.KindLabel)
			t.BindTextField(title, 0, fieldTitle)
			t.AddChild(row, check)
			t.AddChild(row, title)
		})

		tx.AddChild(column, field)
		tx.AddChild(column, add)
		tx.AddChild(column, status)
		tx.AddChild(column, todoList)
		tx.Mount(column)
	})

	// The fold: widget-owned state arrives as occurrences; the app's
	// copy is this variable, not a widget read.
	draft := ""
	nextKey := 0
	app.OnChange(field, func(tx *kaya.Tx, text string) {
		draft = text
	})
	app.OnClick(add, func(tx *kaya.Tx) {
		nextKey++
		todos.Insert(tx, fmt.Sprintf("t%d", nextKey), Todo{Title: draft})
		tx.Write(itemsLeft, itemsLeftText(tx))
	})
	app.OnToggleNode(check, func(tx *kaya.Tx, keys []any, checked bool) {
		// One field's delta: the title never travels.
		kaya.UpdateField(tx, todos, keys[0], fieldDone, checked)
		tx.Write(itemsLeft, itemsLeftText(tx))
	})

	os.Exit(app.Run())
}
