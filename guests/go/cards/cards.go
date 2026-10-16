// The cards scene (tools/scenes/cards.steps; docs/styling-pass-plan.md Y4): a
// grid of cards that each take a click as a whole and show the platform's
// hover, and a library list whose rows the app selects on activation.
package cards

import kaya "dev.kaya/bindings/go"

//go:generate go run dev.kaya/cmd/kaya-gen -type Playlist -key string
type Playlist struct {
	Name     string
	Selected bool
}

var cards = [][2]string{{"card1", "Daily Mix 1"}, {"card2", "Daily Mix 2"}, {"card3", "Discover Weekly"}}
var library = [][2]string{{"p1", "Liked Songs"}, {"p2", "Late Night Jazz"}, {"p3", "Focus"}}

func App() *kaya.App {
	app := kaya.NewApp()
	app.Build(func(tx *kaya.Tx) {
		tx.Window(0).Title("cards").Size(520, 520)
		status := tx.Signal("opened: none")
		lib := PlaylistCollection(tx)
		tx.Mount(tx.Column(func() {
			tx.Grid(3, func() {
				for _, card := range cards {
					name := card[1]
					tx.Column(func() {
						tx.LabelText(name)
						tx.CaptionText("Made for you")
					}).Filled(kaya.TintNeutral).A11yID(card[0]).OnActivate(func(tx *kaya.Tx) {
						tx.Write(status, "opened: "+name)
					})
				}
			}).Spacing(12)
			tx.Label(status).A11yID("status")
			for row := range PlaylistRows(tx, lib).All() {
				item := row.Row(func() {
					row.Label(row.Name())
				})
				row.SetA11yID(item, "lib")
				row.BindSelected(item, row.Selected())
				item.OnActivate(func(tx *kaya.Tx, keys []any) {
					picked := keys[0].(string)
					for _, entry := range library {
						PlaylistPatch(lib, tx, entry[0]).Selected(entry[0] == picked)
					}
				})
			}
		}).Spacing(16))
		for _, entry := range library {
			lib.Insert(tx, entry[0], Playlist{Name: entry[1]})
		}
	})
	return app
}
