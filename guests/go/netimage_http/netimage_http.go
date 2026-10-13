// The network images scene over HTTP (tools/scenes/netimage_http.steps;
// docs/network-images-plan.md §5, N12): kaya's row-image helper fetching
// from the lane's media server with net/http. Twelve rows share three
// covers, the album case; four rows fail or wait in the ways a real
// catalogue does.
package netimagehttp

import (
	"fmt"

	kaya "dev.kaya/bindings/go"
)

//go:generate go run dev.kaya/cmd/kaya-gen -type Track -key string
type Track struct {
	Title  string
	ArtURL string
	Art    []byte
	Phase  kaya.ImagePhase
}

var covers = []string{"covers/cover-600.jpg", "covers/cover-320.jpg", "covers/cover-1000.jpg"}

func App() *kaya.App {
	base, ok := kaya.LookupEnv("KAYA_MEDIA_URL")
	if !ok {
		panic("kaya: the netimage_http scene reads KAYA_MEDIA_URL, the local server the lane " +
			"starts (tools/lib/media_server.py)")
	}
	app := kaya.NewApp()
	failures := 0

	app.Build(func(tx *kaya.Tx) {
		tx.Window(0).Title("netimage_http").Size(640, 560)
		errors := tx.Signal("errors: 0")
		tracks := TrackCollection(tx)
		images := kaya.NewRowImages(app, tracks,
			func(t *Track) *string { return &t.ArtURL },
			func(t *Track) *[]byte { return &t.Art },
			func(t *Track) *kaya.ImagePhase { return &t.Phase },
			nil,
		).OnError(func(tx *kaya.Tx, _ []any, _ error) {
			failures++
			tx.Write(errors, fmt.Sprintf("errors: %d", failures))
		})

		tx.Mount(tx.Row(func() {
			tx.Label(errors).A11yID("errors")
			list := TrackRows(tx, tracks).Columns([]string{"Art", "Title"}, kaya.SortNone())
			for row := range list.All() {
				row.Row(func() {
					image := row.Image(row.Art())
					row.SetFit(image, kaya.FitCover)
					row.SetMaxWidth(image, 20)
					row.SetMaxHeight(image, 20)
					row.BindPhase(image, row.Phase())
					row.SetA11yID(image, "art")
					image.FetchedBy(images)
					row.Label(row.Title())
				})
			}
			tx.SetGrow(list.Widget(), 1)
		}))
		for _, special := range [][2]string{
			{"missing", "status/404/"},
			{"broken", "status/500/"},
			{"junk", "covers/README.md"},
			{"slow", "trickle/covers/cover-600.jpg"},
		} {
			tracks.Insert(tx, special[0], Track{
				Title: special[0], ArtURL: base + "/" + special[1], Phase: kaya.ImagePhaseLoading,
			})
		}
		for i := range 12 {
			tracks.Insert(tx, fmt.Sprintf("a%02d", i), Track{
				Title: fmt.Sprintf("Track %d", i), ArtURL: base + "/" + covers[i%3], Phase: kaya.ImagePhaseLoading,
			})
		}
	})

	return app
}
