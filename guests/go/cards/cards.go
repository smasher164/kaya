// The cards scene (tools/scenes/cards.steps; docs/styling-pass-plan.md Y4): a
// grid of cards that each take a click as a whole and show the platform's
// hover, a library list whose rows the app selects on activation and whose
// play buttons take their symbol from the row, and a card the app adds to the
// built grid (docs/media-player-plan.md M16).
package cards

import kaya "dev.kaya/bindings/go"

//go:generate go run dev.kaya/cmd/kaya-gen -type Playlist -key string
type Playlist struct {
	Name     string
	Selected bool
	Symbol   kaya.Symbol
}

var cards = [][2]string{{"card1", "Daily Mix 1"}, {"card2", "Daily Mix 2"}, {"card3", "Discover Weekly"}}

// The third card is taller, so the row's cards take its height (M16 (1)).
const tall = "card3"

// Cut at two lines with the platform's ellipsis (M16 (2)).
const blurb = "Fresh picks every Monday, from the artists you play the most and the ones they listen to"

var library = [][2]string{{"p1", "Liked Songs"}, {"p2", "Late Night Jazz"}, {"p3", "Focus"}}

func card(tx *kaya.Tx, status kaya.Signal[string], id, name string) kaya.Widget {
	return tx.Column(func() {
		tx.LabelText(name)
		tx.CaptionText("Made for you")
		if id == tall {
			tx.CaptionText(blurb).MaxLines(2).A11yID("blurb")
		}
	}).Filled(kaya.TintNeutral).A11yID(id).OnActivate(func(tx *kaya.Tx) {
		tx.Write(status, "opened: "+name)
	})
}

func App() *kaya.App {
	app := kaya.NewApp()
	app.Build(func(tx *kaya.Tx) {
		tx.Window(0).Title("cards").Size(520, 520)
		status := tx.Signal("opened: none")
		lib := PlaylistCollection(tx)
		// A section hidden by a When and an empty For take no space (M16 (3)).
		hidden := tx.Signal(false)
		empty := PlaylistCollection(tx)
		tx.Mount(tx.Column(func() {
			grid := tx.Grid(1, func() {
				for _, c := range cards {
					card(tx, status, c[0], c[1])
				}
			}).Spacing(12).ColumnsAuto(140).A11yID("cards")
			tx.Button("More", func(tx *kaya.Tx) {
				tx.Within(grid, func() { card(tx, status, "card4", "Release Radar") })
			}).A11yID("more")
			tx.Label(status).A11yID("status")
			tx.When(hidden, func(t *kaya.Tpl) {
				t.LabelText("never shown")
			})
			for row := range PlaylistRows(tx, empty).All() {
				row.Row(func() {
					row.Label(row.Name())
				})
			}
			tx.LabelText("end").A11yID("end")
			for row := range PlaylistRows(tx, lib).All() {
				var item kaya.Node
				row.Row(func() {
					item = row.Row(func() {
						row.Label(row.Name())
					})
					play := row.ButtonText("Play", func(tx *kaya.Tx, played string) {
						for _, entry := range library {
							symbol := kaya.SymbolPlay
							if entry[0] == played {
								symbol = kaya.SymbolPause
							}
							PlaylistPatch(lib, tx, entry[0]).Symbol(symbol)
						}
					})
					row.BindSymbol(play, row.Symbol())
					row.SetA11yID(play, "go")
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
			lib.Insert(tx, entry[0], Playlist{Name: entry[1], Symbol: kaya.SymbolPlay})
		}
	})
	return app
}
