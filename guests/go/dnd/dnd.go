// The drag-and-drop scene (tools/scenes/dnd.steps; docs/dnd-plan.md D1, D8).
// THE ROOT IS A ROW so column#0 is the reorderable For's container.
package dnd

import (
	"fmt"
	"io"
	"os"
	"path/filepath"
	"runtime"

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

func keyWord(keys []any) string {
	if len(keys) == 0 {
		return ""
	}
	return fmt.Sprint(keys[0])
}

// Where the harness's $TMP points on each platform, the picker guest's own
// shape (tools/check-go-env.py holds it).
func sceneRoot() string {
	switch runtime.GOOS {
	case "android":
		root := kaya.Env("EXTERNAL_STORAGE")
		if root == "" {
			root = "/sdcard"
		}
		return filepath.Join(root, "Documents")
	case "ios":
		return filepath.Join(kaya.Env("HOME"), "Documents")
	}
	return os.TempDir()
}

// The file the scene drops as a FOREIGN source (D6), written by the guest
// at $TMP/kaya-dnd-$PID/dropped.txt — the picker and clipboard scenes'
// convention.
func writeDroppedFile() {
	dir := filepath.Join(sceneRoot(), fmt.Sprintf("kaya-dnd-%d", os.Getpid()))
	if err := os.MkdirAll(dir, 0o755); err != nil {
		panic(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "dropped.txt"), []byte("dropped bytes"), 0o644); err != nil {
		panic(err)
	}
}

func readBack(f kaya.PickedFile) string {
	handle, _, err := f.Open(kaya.FileModeRead)
	if err != nil {
		return fmt.Sprintf("open failed: %v", err)
	}
	defer handle.Close()
	body, err := io.ReadAll(handle)
	if err != nil {
		return fmt.Sprintf("read failed: %v", err)
	}
	return string(body)
}

func App() *kaya.App {
	writeDroppedFile()
	app := kaya.NewApp()

	app.Build(func(tx *kaya.Tx) {
		items := ItemCollection(tx)
		items2 := ItemCollection(tx)
		dropStatus := tx.Signal("no drop yet")
		dragStatus := tx.Signal("no drag yet")
		sourceText := tx.Signal("hello")
		textTarget := tx.Signal("text target")
		noteTarget := tx.Signal("note target")
		filesTarget := tx.Signal("files target")

		var source, textID, noteID2, filesID kaya.Widget
		var rows *itemRowsFor
		var rowLabel, itemLabel kaya.Node
		tx.Window(0).Title("dnd")
		tx.Mount(tx.Row(func() {
			rows = ItemRows(tx, items)
			for row := range rows.All() {
				rowLabel = row.Label(row.Title())
				row.SetA11yID(rowLabel, "row")
			}
			tx.SetA11yID(rows.Widget(), "rows")
			tx.Column(func() {
				source = tx.Label(sourceText) // label#0
				textID = tx.Label(textTarget).
					Accepts(kaya.AcceptText).
					DropTarget(kaya.OpCopy) // label#1
				noteID2 = tx.Label(noteTarget).
					Accepts(noteID).
					DropTarget(kaya.OpCopy, kaya.OpMove) // label#2
				filesID = tx.Label(filesTarget).
					Accepts(kaya.AcceptFiles).
					DropTarget(kaya.OpCopy) // label#3
				tx.Label(dropStatus) // label#4
				tx.Label(dragStatus) // label#5
			})
			// THE TEMPLATE ZONE (docs/dnd-plan.md §4): every stamped item
			// is a text destination, and its payload IS the row's own
			// field — resolved per copy, re-declared when it changes.
			itemRows := ItemRows(tx, items2)
			for row := range itemRows.All() {
				itemLabel = row.Label(row.Title())
				row.SetA11yID(itemLabel, "item")
				row.SetAccepts(itemLabel, kaya.AcceptText)
				row.SetDropTarget(itemLabel, kaya.OpCopy)
				row.Draggable(itemLabel).Text(row.Title()).Allow(kaya.OpCopy).Declare()
			}
			tx.SetA11yID(itemRows.Widget(), "items")
			tx.Button("rename y", func(tx *kaya.Tx) { // button#0
				items2.Update(tx, "y", Item{Title: "yy"})
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
				case kaya.FilesClip:
					// A dropped file IS a picked file (D6): read it back
					// through the same table the picker fills.
					said := ""
					for i, f := range clip.Files {
						if i > 0 {
							said += ", "
						}
						said += fmt.Sprintf("%s %s", f.Name, readBack(f))
					}
					tx.Write(dropStatus, fmt.Sprintf("%s got %s (%s)", name, said, op))
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
		app.OnDrop(filesID, dropped("files target", filesTarget))
		app.OnDragEnded(source, func(tx *kaya.Tx, op kaya.Op) {
			tx.Write(dragStatus, fmt.Sprintf("drag ended %s", word(op)))
		})
		app.OnDropNode(itemLabel, func(tx *kaya.Tx, keys []any, d kaya.Dropped) {
			op := word(d.Operation)
			if clip, ok := d.Clip.(kaya.TextClip); ok {
				tx.Write(dropStatus, fmt.Sprintf("item %s got text %s (%s)", keyWord(keys), clip.Text, op))
				return
			}
			tx.Write(dropStatus, fmt.Sprintf("item %s got other (%s)", keyWord(keys), op))
		})
		nodeEnded := func(what string) func(*kaya.Tx, []any, kaya.Op) {
			return func(tx *kaya.Tx, keys []any, op kaya.Op) {
				tx.Write(dragStatus, fmt.Sprintf("%s %s drag ended %s", what, keyWord(keys), word(op)))
			}
		}
		app.OnDragEndedNode(itemLabel, nodeEnded("item"))
		app.OnDragEndedNode(rowLabel, nodeEnded("row"))
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
		for _, key := range []string{"x", "y"} {
			items2.Insert(tx, key, Item{Title: key})
		}
	})

	return app
}
