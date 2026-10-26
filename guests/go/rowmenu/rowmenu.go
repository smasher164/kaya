// The row menu scene (tools/scenes/rowmenu.steps; docs/media-player-plan.md
// M26). Canonical semantics in guests/rust/rowmenu.rs.
package rowmenu

import (
	"fmt"

	kaya "dev.kaya/bindings/go"
)

//go:generate go run dev.kaya/cmd/kaya-gen -type Entry -key string
type Entry struct {
	Title string
	Mark  string
}

func App() *kaya.App {
	app := kaya.NewApp()

	app.Build(func(tx *kaya.Tx) {
		tx.Window(0).Title("rowmenu")
		status := tx.Signal("ready")
		notes := EntryCollection(tx)
		files := EntryCollection(tx)
		toggle := func(c kaya.RecordCollection[string, Entry], on, off, did, undid string) func(*kaya.Tx, []any) {
			return func(tx *kaya.Tx, keys []any) {
				key := keys[0].(string)
				entry, _ := c.Get(tx, key)
				set := entry.Mark == on
				next, word := on, undid
				if set {
					next, word = off, did
				}
				EntryPatch(c, tx, key).Mark(next)
				tx.Write(status, fmt.Sprintf("%s %s", word, key))
			}
		}
		open := func(tx *kaya.Tx, keys []any) {
			tx.Write(status, fmt.Sprintf("opened %s", keys[0].(string)))
		}
		noteMenu := tx.ContextCatalog()
		star := noteMenu.Item("Star").OnActivateNode(toggle(notes, "Star", "Unstar", "starred", "unstarred"))
		noteMenu.Separator()
		noteMenu.Item("Open").OnActivateNode(open)
		fileMenu := tx.ContextCatalog()
		pin := fileMenu.Item("Pin").OnActivateNode(toggle(files, "Pin", "Unpin", "pinned", "unpinned"))
		fileMenu.Separator()
		fileMenu.Item("Open").OnActivateNode(open)

		tx.Mount(tx.Column(func() {
			tx.Label(status)
			for note := range EntryRows(tx, notes).All() {
				line := note.Row(func() {
					note.Label(note.Title())
				})
				note.SetA11yID(line, "note")
				note.ContextMenu(line, noteMenu)
				note.ContextLabel(line, star, note.Mark())
			}
			rows := EntryRows(tx, files).Columns([]string{"Name"}, kaya.SortNone())
			for file := range rows.All() {
				line := file.Row(func() {
					file.Label(file.Title())
				})
				file.SetA11yID(line, "file")
				file.ContextMenu(line, fileMenu)
				file.ContextLabel(line, pin, file.Mark())
			}
			tx.SetGrow(rows.Widget(), 1)
		}))
		for _, seed := range []struct{ key, title, mark string }{
			{"a", "apples", "Star"}, {"b", "bread", "Unstar"},
		} {
			notes.Insert(tx, seed.key, Entry{Title: seed.title, Mark: seed.mark})
		}
		for _, seed := range []struct{ key, title, mark string }{
			{"x", "x.txt", "Pin"}, {"y", "y.txt", "Unpin"},
		} {
			files.Insert(tx, seed.key, Entry{Title: seed.title, Mark: seed.mark})
		}
	})

	return app
}
