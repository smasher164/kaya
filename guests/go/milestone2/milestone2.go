// The milestone-2 scene from Go, on the construction sugar.
//
// WHAT THIS SCENE DOCUMENTS IS HOW OCCURRENCES REACH AN APP, and only
// that. The remove button is a STAMPED copy, so its handler is
// registered CENTRALLY against the template node and receives that
// copy's key path; the live step button rides its constructor.
//
// AND THE APP NAMES EVERY KEY HERE, on purpose: "g1" and "a" are this
// app's own identity for a group and an item, re-addressed later by
// name. That is exactly what InsertFresh is NOT for
// (docs/fresh-key-plan.md).
//
//	KAYA_SELFTEST=1 go run dev.kaya/guests/go/cmd
package milestone2

import (
	"fmt"

	kaya "dev.kaya/bindings/go"
)

func App() *kaya.App {
	app := kaya.NewApp()

	// The handles the central registration below needs: a node parents
	// into its container AT CREATION, so both are built inside the
	// template bodies that hold them and escape through these.
	var (
		status       kaya.Signal[string]
		items        kaya.Collection
		removeButton kaya.Node
	)

	steps := 0
	app.Build(func(tx *kaya.Tx) {
		status = tx.Signal("step 0")
		extras := tx.Signal(false)

		groups := tx.Collection()

		tx.Mount(tx.Column(func() {
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
			})
			tx.Label(status)
			tx.When(extras, func(t *kaya.Tpl) {
				t.LabelText("extras on")
			})
			for group := range tx.Rows(groups).All() {
				group.Column(func() {
					group.Label(group.Value())

					items = group.Collection()
					for item := range group.Rows(items).All() {
						item.Column(func() {
							item.Label(item.Value())
							removeButton = item.Button("remove")
						})
					}
				})
			}
		}))
	})

	app.OnClickNode(removeButton, func(tx *kaya.Tx, keys []any) {
		group, item := keys[0].(string), keys[1].(string)
		todos := items.At(group)
		tx.Remove(todos, item)
		left := tx.Len(todos)
		tx.Write(status, fmt.Sprintf("removed %s/%s, %d left", group, item, left))
	})

	return app
}
