// The milestone-2 scene from Go, on the construction sugar: typed
// handles, constructors carrying their handlers, containers taking
// their children, and func(*Tpl) closures instead of template_end
// bookkeeping. The wire vocabulary underneath (kaya_wire.go) is
// generated from kaya::spec by kaya-bindgen.
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
		status       kaya.Signal[string]
		items        kaya.Collection
		removeButton kaya.Node
	)

	steps := 0
	app.Build(func(tx *kaya.Tx) {
		status = tx.Signal("step 0")
		extras := tx.Signal(false)

		banner := tx.When(extras, func(t *kaya.Tpl) {
			bannerLabel := t.Widget(kaya.KindLabel)
			t.SetText(bannerLabel, "extras on")
		})

		groups := tx.Collection()
		groupList := tx.ForEach(groups, func(t *kaya.Tpl) {
			name := t.Widget(kaya.KindLabel)
			t.BindTextElement(name, 0)

			items = t.Collection()
			itemList := t.ForEach(items, func(item *kaya.Tpl) {
				text := item.Widget(kaya.KindLabel)
				item.BindTextElement(text, 0)
				removeButton = item.Widget(kaya.KindButton)
				item.SetText(removeButton, "remove")
				item.Column(text, removeButton)
			})
			t.Column(name, itemList)
		})

		tx.Mount(tx.Column(
			tx.Button("step", func(tx *kaya.Tx) {
				steps++
				switch steps {
				case 1:
					tx.Insert(groups, "g1", "Work")
					todos := items.At("g1")
					tx.Insert(todos, "a", "send report")
					tx.Insert(todos, "b", "buy milk")
				case 2:
					tx.Insert(groups, "g2", "Home")
					tx.Insert(items.At("g2"), "a", "water plants")
					tx.Update(groups, "g1", "Office")
				}
				tx.Write(extras, steps == 1)
				tx.Write(status, fmt.Sprintf("step %d", steps))
			}),
			tx.Label(status),
			banner,
			groupList,
		))
	})

	app.OnClickNode(removeButton, func(tx *kaya.Tx, keys []any) {
		group, item := keys[0].(string), keys[1].(string)
		// The instance handle names the target once; mutation and read
		// hang off the same value. The collection is the model: the
		// count read is the fold of the patches, this one included.
		todos := items.At(group)
		tx.Remove(todos, item)
		left := tx.Len(todos)
		tx.Write(status, fmt.Sprintf("removed %s/%s, %d left", group, item, left))
	})

	os.Exit(app.Run())
}
