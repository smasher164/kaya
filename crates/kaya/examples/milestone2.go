// The milestone-2 scene from Go, on the idiomatic surface (app.go):
// typed handles instead of hand-numbered ids, func(*Tpl) closures
// instead of template_end bookkeeping, and click handlers instead of a
// hand-rolled dispatch loop. The wire vocabulary underneath
// (kaya_wire.go) is generated from kaya::spec by kaya-bindgen.
//
// Build the library first (cargo build), then, from the repo root
// (dev.kaya's go.mod lives there):
//     KAYA_SELFTEST=1 go run crates/kaya/examples/milestone2.go
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

func main() {
	app := kaya.NewApp()

	var (
		status, extras kaya.Signal
		step           kaya.Widget
		groups, items  kaya.Collection
		removeButton   kaya.Node
	)

	app.Build(func(tx *kaya.Tx) {
		status = tx.Signal("step 0")
		extras = tx.Signal(false)

		column := tx.Widget(kaya.KindColumn)
		step = tx.Widget(kaya.KindButton)
		tx.SetText(step, "step")
		statusLabel := tx.Widget(kaya.KindLabel)
		tx.BindText(statusLabel, status)

		banner := tx.When(extras, func(t *kaya.Tpl) {
			bannerLabel := t.Widget(kaya.KindLabel)
			t.SetText(bannerLabel, "extras on")
		})

		groups = tx.Collection()
		groupList := tx.ForEach(groups, func(t *kaya.Tpl) {
			groupColumn := t.Widget(kaya.KindColumn)
			name := t.Widget(kaya.KindLabel)
			t.BindTextElement(name, 0)
			t.AddChild(groupColumn, name)

			items = t.Collection()
			itemList := t.ForEach(items, func(item *kaya.Tpl) {
				row := item.Widget(kaya.KindColumn)
				text := item.Widget(kaya.KindLabel)
				item.BindTextElement(text, 0)
				removeButton = item.Widget(kaya.KindButton)
				item.SetText(removeButton, "remove")
				item.AddChild(row, text)
				item.AddChild(row, removeButton)
			})
			t.AddChild(groupColumn, itemList)
		})

		tx.AddChild(column, step)
		tx.AddChild(column, statusLabel)
		tx.AddChild(column, banner)
		tx.AddChild(column, groupList)
		tx.Mount(column)
	})

	steps := 0
	app.OnClick(step, func(tx *kaya.Tx) {
		steps++
		switch steps {
		case 1:
			tx.Insert(groups, nil, "g1", "Work")
			tx.Insert(items, []any{"g1"}, "a", "send report")
			tx.Insert(items, []any{"g1"}, "b", "buy milk")
		case 2:
			tx.Insert(groups, nil, "g2", "Home")
			tx.Insert(items, []any{"g2"}, "a", "water plants")
			tx.Update(groups, nil, "g1", "Office")
		}
		tx.Write(extras, steps == 1)
		tx.Write(status, fmt.Sprintf("step %d", steps))
	})

	app.OnClickNode(removeButton, func(tx *kaya.Tx, keys []any) {
		group, item := keys[0].(string), keys[1].(string)
		tx.Remove(items, []any{group}, item)
		// The collection is the model: the count read here is the fold
		// of the patches, this one included.
		left := tx.Len(items, []any{group})
		tx.Write(status, fmt.Sprintf("removed %s/%s, %d left", group, item, left))
	})

	os.Exit(app.Run())
}
