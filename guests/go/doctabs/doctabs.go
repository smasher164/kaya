// The document-tabs scene (tools/scenes/doctabs.steps; docs/doctabs-plan.md
// §5): three documents, one of them armed against a close, a shared region
// beside them, the "+", and a programmatic select that echoes nothing.
package doctabs

import (
	"fmt"
	"strings"

	kaya "dev.kaya/bindings/go"
)

const (
	a     = 10
	b     = 11
	c     = 12
	notes = 30
)

var names = map[uint64]string{a: "a", b: "b", c: "c"}

func App() *kaya.App {
	app := kaya.NewApp()

	var status kaya.Signal[string]
	untitled := uint64(0)
	regions := uint64(0)

	// THE ONE BUILDER every window's shared region comes from, the first
	// window's and a torn-out one's alike (docs/doctabs-plan.md §1.2).
	region := func(tx *kaya.Tx, window, id uint64) {
		tx.AddRegionIn(window, id, kaya.RegionEdgeLeading)
		tx.MountIn(id, tx.Column(func() {
			tx.Label(status).A11yID("status")
			tx.Entry(nil).A11yID("note")
			tx.Button("to a", func(tx *kaya.Tx) { tx.SelectDocument(a) }).A11yID("first")
		}))
	}

	app.Build(func(tx *kaya.Tx) {
		status = tx.Signal("ready")
		tx.Window(0).Title("doctabs").Size(640, 420).NewDocument(true).
			OnNewDocument(func(tx *kaya.Tx) {
				untitled++
				name := fmt.Sprintf("untitled %d", untitled)
				id := 100 + untitled
				tx.AddDocument(id).Title(name).Select()
				caption := tx.Signal(name + " body")
				tx.MountIn(id, tx.Column(func() { tx.Label(caption) }))
				tx.Write(status, "new "+name)
			}).
			OnDocumentsCloseRequested(func(tx *kaya.Tx, documents []uint64) {
				tx.Write(status, fmt.Sprintf("asked about %d", len(documents)))
			}).
			OnDocumentsDetached(func(tx *kaya.Tx, window uint64, documents []uint64) {
				regions++
				region(tx, window, 300+regions)
				moved := make([]string, 0, len(documents))
				for _, d := range documents {
					name, ok := names[d]
					if !ok {
						name = "untitled"
					}
					moved = append(moved, name)
				}
				tx.Write(status, "detached "+strings.Join(moved, " "))
			})

		for _, id := range []uint64{a, b, c} {
			name := names[id]
			doc := tx.AddDocument(id).Title(name).Tooltip("/documents/" + name).
				OnSelected(func(tx *kaya.Tx) { tx.Write(status, "selected "+name) }).
				OnClosed(func(tx *kaya.Tx) { tx.Write(status, "closed "+name) }).
				OnMoved(func(tx *kaya.Tx, _ uint64, index uint32) {
					tx.Write(status, fmt.Sprintf("moved %s to %d", name, index))
				})
			caption := tx.Signal(name + " body")
			tx.MountIn(id, tx.Column(func() {
				tx.Label(caption).A11yID("body-" + name)
				tx.Entry(nil).A11yID("field-" + name)
				if id == b {
					tx.Button("mark b", func(tx *kaya.Tx) {
						tx.Document(b).Dirty(true)
						tx.Write(status, "marked b")
					}).A11yID("mark")
				}
			}))
			if id == b {
				doc.InterceptClose(true).OnCloseRequested(func(tx *kaya.Tx) {
					tx.ShowAlert().
						Title("unsaved changes").
						Message("b has unsaved changes").
						Action("Discard").
						Cancel("Keep Editing").
						OnResult(func(tx *kaya.Tx, choice kaya.AlertChoice) {
							if choice == kaya.AlertChoiceCancel {
								tx.Write(status, "kept b")
								return
							}
							tx.CloseDocument(b)
							tx.Write(status, "discarded b")
						}).
						Show()
				})
			}
		}
		region(tx, 0, notes)
	})

	return app
}
