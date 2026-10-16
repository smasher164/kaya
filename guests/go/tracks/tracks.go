// The tracks scene (tools/scenes/tracks.steps; docs/styling-pass-plan.md Y5,
// Y6, Y7): a playlist's table whose title cell is rounded art beside the
// track's name over its artist, the playing track's name in the accent.
package tracks

import (
	"fmt"
	"strconv"

	kaya "dev.kaya/bindings/go"
)

//go:generate go run dev.kaya/cmd/kaya-gen -type Track -key string
type Track struct {
	Number string
	Title  string
	Artist string
	Album  string
	Art    []byte
	Tint   kaya.Tint
}

const playlist = 60
const playing = 3

var names = [][3]string{
	{"Blue in Green", "Miles Davis", "Kind of Blue"},
	{"So What", "Miles Davis", "Kind of Blue"},
	{"Naima", "John Coltrane", "Giant Steps"},
}

func table(tx *kaya.Tx, tracks kaya.RecordCollection[string, Track], id, rowID string) kaya.Widget {
	rows := TrackRows(tx, tracks).Columns([]string{"#", "Title", "Album"}, kaya.SortNone())
	for row := range rows.All() {
		line := row.Row(func() {
			row.Label(row.Number())
			row.Row(func() {
				image := row.Image(row.Art())
				row.SetFit(image, kaya.FitCover)
				row.SetMaxWidth(image, 40)
				row.SetMaxHeight(image, 40)
				row.SetShape(image, kaya.ShapeRounded)
				row.SetA11yID(image, "art")
				row.Column(func() {
					title := row.Label(row.Title())
					row.BindTint(title, row.Tint())
					row.SetA11yID(title, "name")
					row.Caption(row.Artist())
				})
			})
			row.Label(row.Album())
		})
		row.SetA11yID(line, rowID)
	}
	return rows.Widget().A11yID(id)
}

func track(i int, art []byte) Track {
	n := names[i%len(names)]
	tint := kaya.TintNone
	if i+1 == playing {
		tint = kaya.TintAccent
	}
	return Track{Number: strconv.Itoa(i + 1), Title: n[0], Artist: n[1], Album: n[2], Art: art, Tint: tint}
}

func App() *kaya.App {
	app := kaya.NewApp()
	app.Build(func(tx *kaya.Tx) {
		tx.Window(0).Title("tracks").Size(720, 640)
		a := tx.Asset("covers/cover-600.jpg")
		art := a.Bytes()
		a.Close()
		album := TrackCollection(tx)
		list := TrackCollection(tx)
		tx.Mount(tx.Column(func() {
			table(tx, album, "album", "a")
			long := table(tx, list, "tracks", "t")
			tx.SetGrow(long, 1)
		}).Spacing(12))
		for i := range names {
			album.Insert(tx, fmt.Sprintf("a%d", i+1), track(i, art))
		}
		for i := range playlist {
			list.Insert(tx, fmt.Sprintf("t%d", i+1), track(i, art))
		}
	})
	return app
}
