// The drag-and-drop scene (tools/scenes/dnd.steps; docs/dnd-plan.md D1, D8).
// THE ROOT IS A ROW so column#0 is the reorderable For's container.
package dnd

import (
	"fmt"

	kaya "dev.kaya/bindings/go"
)

//go:generate go run dev.kaya/cmd/kaya-gen -type Item -key string
type Item struct {
	Title string
}

const noteID = "dev.kaya/note"

func word(op kaya.Op) string {
	switch op {
	case kaya.OpCopy:
		return "copy"
	case kaya.OpMove:
		return "move"
	default:
		return "none"
	}
}

func App() *kaya.App {
	app := kaya.NewApp()

	app.Build(func(tx *kaya.Tx) {
		items := ItemCollection(tx)
		dropStatus := tx.Signal("no drop yet")
		dragStatus := tx.Signal("no drag yet")
		sourceText := tx.Signal("hello")
		textTarget := tx.Signal("text target")
		noteTarget := tx.Signal("note target")
		filesTarget := tx.Signal("files target")

		var source, textID, noteID2 kaya.Widget
		var rows *itemRowsFor
		tx.Window(0).Title("dnd")
		tx.Mount(tx.Row(func() {
			rows = ItemRows(tx, items)
			for row := range rows.All() {
				row.SetA11yID(row.Label(row.Title()), "row")
			}
			tx.Column(func() {
				source = tx.Label(sourceText) // label#0
				textID = tx.Label(textTarget).
					Accepts(kaya.AcceptText).
					DropTarget(kaya.OpCopy) // label#1
				noteID2 = tx.Label(noteTarget).
					Accepts(noteID).
					DropTarget(kaya.OpCopy, kaya.OpMove) // label#2
				tx.Label(filesTarget).
					Accepts(kaya.AcceptFiles).
					DropTarget(kaya.OpCopy) // label#3
				tx.Label(dropStatus)        // label#4
				tx.Label(dragStatus)        // label#5
			})
		}))
		tx.Draggable(source).
			Text("hello").
			Custom(noteID, []byte("note!")).
			Allow(kaya.OpCopy).
			Allow(kaya.OpMove).
			Declare()
		rows.Reorderable(true)

		dropped := func(name string, target kaya.Signal[string]) func(*kaya.Tx, kaya.Dropped) {
			return func(tx *kaya.Tx, d kaya.Dropped) {
				op := word(d.Operation)
				switch clip := d.Clip.(type) {
				case kaya.TextClip:
					tx.Write(dropStatus, fmt.Sprintf("%s got text %s (%s)", name, clip.Text, op))
					tx.Write(target, clip.Text)
				case kaya.CustomClip:
					tx.Write(dropStatus, fmt.Sprintf("%s got %s %d bytes (%s)", name, clip.ID, len(clip.Bytes), op))
				default:
					tx.Write(dropStatus, fmt.Sprintf("%s got other (%s)", name, op))
				}
				// A same-app MOVE removes its original in the same batch (D2).
				if d.Operation == kaya.OpMove {
					tx.Write(sourceText, "moved out")
					tx.Draggable(source).Declare()
				}
			}
		}
		app.OnDrop(textID, dropped("text target", textTarget))
		app.OnDrop(noteID2, dropped("note target", noteTarget))
		app.OnDragEnded(source, func(tx *kaya.Tx, op kaya.Op) {
			tx.Write(dragStatus, fmt.Sprintf("drag ended %s", word(op)))
		})
		// The moved row's key rides as the kaya-private custom
		// representation; the anchor is the row it landed on (D8).
		rows.OnDrop(func(tx *kaya.Tx, d kaya.Dropped) {
			clip, ok := d.Clip.(kaya.CustomClip)
			if !ok || len(d.Anchor) == 0 {
				return
			}
			anchor, ok := d.Anchor[0].(string)
			if !ok {
				return
			}
			if d.Before {
				items.MoveBefore(tx, string(clip.Bytes), anchor)
			} else {
				items.MoveAfter(tx, string(clip.Bytes), anchor)
			}
		})

		for _, key := range []string{"a", "b", "c"} {
			items.Insert(tx, key, Item{Title: key})
		}
	})

	return app
}
