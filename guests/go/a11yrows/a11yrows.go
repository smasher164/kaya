// The stamped-accessibility scene, Go port: two entries stamped from ONE
// template, each carrying its OWN ROW's accessibility identity, read back
// out of the platform's real tree. The a11y scene proves the wrap-native
// bet for LIVE widgets; this one proves it for COPIES — the case none of
// the accessibility milestone's 719 legs ever exercised, because until
// the template zone could spell the props (docs/tpl-props-plan.md P1) no
// guest could author a stamped widget's name at all.
//
// A SEPARATE SCENE BY DESIGN, not by size: a For materializes as a
// column, harness registries are creation-order, and container creation
// order differs by language — statement-shaped construction is
// parent-first, expression trees are children-first
// (guests/haskell/reorder.hs documents the rule). The a11y scene asserts
// every container kind ORDINALLY, so a For anywhere inside it would make
// `column#0` name different widgets on different lanes. This scene
// asserts no container at all, so the For's column may land at either end
// of the registry and both targets below still mean the same thing
// everywhere.
//
// See guests/rust/a11yrows.rs; the byte-frozen contract is
// tools/scenes/a11yrows.steps.
package a11yrows

import (
	kaya "dev.kaya/bindings/go"
)

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
		tx.Mount(tx.Column(func() {
			notes := tx.Collection()
			// The statement IS the For: the body runs ONCE, authoring the
			// blueprint every row is stamped from.
			for row := range notes.Rows(tx) {
				field := row.Entry()
				// BOTH PROPS ELEMENT-SOURCED, over the row's own value.
				// The LABEL is the point — a list row announcing its own
				// name to assistive tech, which is the whole reason a
				// template label can be sourced at all.
				//
				// The ID is forced, and the steps say why: expect_ax
				// resolves its target to the authored identifier and then
				// searches the REAL tree by it, so copies sharing one
				// const id are indistinguishable to that verb — the read
				// now refuses the ambiguity with the measured count
				// rather than answering with whichever it found first,
				// which is what it did when these two assertions were
				// first run. A shared const id stays legal in the core
				// (nothing deduplicates); it is just not a thing this
				// verb can read back.
				row.BindA11yID(field, row.Value())
				row.BindA11yLabel(field, row.Value())
			}
			// No identity of their own, so the binding names them —
			// the keys are never asserted, only the two copies' order.
			tx.InsertFresh(notes, "First note")  // entry#0
			tx.InsertFresh(notes, "Second note") // entry#last

			// THE STAMPED STYLING PROPS. A second collection rather than
			// two more widgets in the first, because expect_ax addresses
			// the real tree by AUTHORED IDENTIFIER and refuses an
			// ambiguous one — a scalar row has exactly one field to spend
			// on an id, so a second readable stamped element needs its
			// own strings.
			//
			// Both props are CONST here and const in every binding: what
			// a copy MEANS, and how far its prototype holds children off
			// its edge, are facts about the PROTOTYPE, not about the
			// row's data (SetAccepts's rule, one prop over).
			heads := tx.Collection()
			for head := range heads.Rows(tx) {
				// Go's Row EMBEDS *Tpl rather than forwarding to it by
				// hand, so the row surface and the base surface are one
				// method set and the pair cannot drift. That is why both
				// props are spelled off `head` here: writing them any
				// other way would be theatre about a forward the language
				// makes for us. The sealed surfaces — SumCase and the
				// generated <name>Row — are the ones that must forward,
				// and bindings/go/tplzone_test.go holds them level.
				var title kaya.Node
				bar := head.Row(func() {
					title = head.Label(head.Value())
					head.SetRole(title, kaya.RoleHeading)
					head.BindA11yID(title, head.Value())
				})
				head.SetInset(bar, 8)
			}
			tx.InsertFresh(heads, "Heading one") // label#0, row#0
			tx.InsertFresh(heads, "Heading two") // label#last
		}))
	})

	return app
}
