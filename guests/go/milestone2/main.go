// The milestone-2 scene from Go, on the construction sugar: typed
// handles, constructors carrying their captions and handlers,
// containers taking their children, and for statements instead of
// template_end bookkeeping. The wire vocabulary underneath
// (kaya_wire.go) is generated from kaya::spec by kaya-bindgen.
//
// WHAT THIS SCENE DOCUMENTS IS HOW OCCURRENCES REACH AN APP, and only
// that (DESIGN.md, the scope ratified 2026-08-05). The remove button
// is a STAMPED copy, so its handler is registered CENTRALLY, after the
// build, against the template node the build handed back — and it
// receives that copy's key path, which is the only way to know WHICH
// remove was clicked. The live step button spells the other half of
// the same registry: its handler rides its constructor, because a live
// widget is its own noun. Both spellings put the same closure in the
// same table. Construction is the ordinary sugar every example that is
// not a C guest uses.
//
// AND THE APP NAMES EVERY KEY HERE, on purpose. "g1" and "a" are this
// app's own identity for a group and an item — the driver re-addresses
// g1 to rename it ("Work" -> "Office") and the verdict reads "removed
// g2/a" back out loud, so the names are data the app chose and still
// knows. That is exactly what InsertFresh is NOT for: the minted key
// answers "this row has no identity of its own" (entry, todos,
// docs/fresh-key-plan.md), and minting one here would only force the
// app to remember a name it already had.
//
// Build the library first (cargo build), then, from the repo root
// (dev.kaya's go.mod lives there):
//
//	KAYA_SELFTEST=1 go run dev.kaya/guests/go/milestone2
package main

import (
	"fmt"

	kaya "dev.kaya/bindings/go"
)

// milestone2 builds the scene and hands it back ready to be served.
// THE TAIL IS THE ONLY THING THAT DIFFERS BY PLATFORM, and it differs
// because the hosting does: a desktop or iOS guest owns the process main
// thread and lends it to kaya (main_desktop.go), while on Android the OS
// owns main and kaya starts the guest on a thread of its own
// (main_android.go). Everything above the tail — the transaction, the
// handlers, the strings — is one body, compiled into every platform's
// artifact from these bytes.
func milestone2() *kaya.App {
	app := kaya.NewApp()

	// The two handles the central registration below needs, plus the
	// status signal: a node parents into its container AT CREATION, so
	// both are built inside the template bodies that hold them and
	// escape through these — never declared outside and named within,
	// which parents nothing.
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

		// Auto-parenting puts the templates where they stand: the When
		// and the For are declared inside the column, between their
		// siblings, and parent themselves there.
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
			// The tracing tier, nested the way the data nests: each for
			// statement IS a For — the body runs once, authoring the
			// blueprint, and range-over-func makes the close structural,
			// even on break. A scalar collection has exactly one field,
			// the element itself, so Value() is the token an index used
			// to spell. The traces nest because a trace rides the zone
			// it opens in: the widget id space out here, the node space
			// inside the group's template.
			for group := range groups.Rows(tx) {
				group.Column(func() {
					group.Label(group.Value())

					items = group.Collection()
					for item := range items.Rows(tx) {
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
		// The instance handle names the target once; mutation and read
		// hang off the same value. The collection is the model: the
		// count read is the fold of the patches, this one included.
		todos := items.At(group)
		tx.Remove(todos, item)
		left := tx.Len(todos)
		tx.Write(status, fmt.Sprintf("removed %s/%s, %d left", group, item, left))
	})

	return app
}
