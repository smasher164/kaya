// The network images affordance scene (tools/scenes/netimage.steps;
// docs/network-images-plan.md §5). No HTTP: each "download" is a job a
// worker goroutine holds until a click releases it, so a write made from
// the wrong thread or a result landing on the wrong row is a wrong reading
// rather than a lucky one.
package netimage

import (
	"fmt"
	"slices"
	"strconv"

	kaya "dev.kaya/bindings/go"
)

//go:generate go run dev.kaya/cmd/kaya-gen -type Track -key string
type Track struct {
	Title  string
	ArtURL string
	Art    []byte
	Phase  kaya.ImagePhase
}

const rows = 300

type job struct {
	live     bool
	bytes    []byte
	key, url string
}

func artURL(t *Track) *string { return &t.ArtURL }

func App() *kaya.App {
	app := kaya.NewApp()
	jobs := make(chan []job, 16)

	var covers [3][]byte
	var tracks kaya.RecordCollection[string, Track]
	var art kaya.Signal[[]byte]
	var phase kaya.Signal[kaya.ImagePhase]

	var live *job
	var pending []job
	needed := map[string]bool{}
	ever := map[string]bool{}
	twice := ""

	app.Build(func(tx *kaya.Tx) {
		for i, name := range []string{"covers/cover-600.jpg", "covers/cover-320.jpg", "covers/cover-1000.jpg"} {
			a := tx.Asset(name)
			covers[i] = a.Bytes()
			a.Close()
		}
		live = &job{live: true, bytes: covers[0]}
		tx.Window(0).Title("netimage").Size(820, 640)
		art = tx.Signal([]byte{})
		phase = tx.Signal(kaya.ImagePhaseLoading)
		band := tx.Signal("band: -")
		released := tx.Signal("released: none")
		again := tx.Signal("again: none")
		tracks = TrackCollection(tx)

		tx.Mount(tx.Column(func() {
			tx.Column(func() {
				tx.ImageSignal(art).MaxWidth(96).MaxHeight(96).Fit(kaya.FitCover).
					BindPhase(phase).A11yID("cover").A11yLabel("Cover")
				tx.Row(func() {
					tx.Button("release", func(tx *kaya.Tx) {
						if live != nil {
							jobs <- []job{*live}
							live = nil
						}
					}).A11yID("release")
					tx.Button("refresh", func(tx *kaya.Tx) {
						live = &job{live: true, bytes: covers[1]}
						tx.Write(phase, kaya.ImagePhaseLoading)
					}).A11yID("refresh")
				})
				tx.Row(func() {
					tx.Button("junk", func(tx *kaya.Tx) {
						tx.Write(art, []byte("not an image"))
						tx.Write(phase, kaya.ImagePhaseShown)
					}).A11yID("junk")
					tx.Button("fail", func(tx *kaya.Tx) {
						live = &job{live: true}
						tx.Write(art, []byte{})
						tx.Write(phase, kaya.ImagePhaseLoading)
					}).A11yID("fail")
				})
				tx.Row(func() {
					tx.Button("rows", func(tx *kaya.Tx) {
						clear(needed)
						jobs <- pending
						pending = nil
					}).A11yID("rows")
					tx.Button("delete", func(tx *kaya.Tx) {
						tracks.Remove(tx, "t299")
					}).A11yID("delete")
					tx.Button("retarget", func(tx *kaya.Tx) {
						pending = slices.Insert(pending, 0, job{key: "t298", url: "u/298b", bytes: covers[2]})
						TrackPatch(tracks, tx, "t298").ArtURL("u/298b")
					}).A11yID("retarget")
				})
				tx.Label(band).A11yID("band")
				tx.Label(released).A11yID("released")
				tx.Label(again).A11yID("again")
			})
			list := TrackRows(tx, tracks).Columns([]string{"Art", "Title"}, kaya.SortNone())
			for row := range list.All() {
				row.Row(func() {
					image := row.Image(row.Art())
					row.SetFit(image, kaya.FitCover)
					row.SetMaxWidth(image, 20)
					row.SetMaxHeight(image, 20)
					row.BindPhase(image, row.Phase())
					row.SetA11yID(image, "art")
					image.OnNeeded(func(tx *kaya.Tx, keys []any) {
						key := keys[0].(string)
						if needed[key] && twice == "" {
							twice = key
						}
						needed[key] = true
						ever[key] = true
						i, _ := strconv.Atoi(key[1:])
						pending = append(pending, job{key: key, url: fmt.Sprintf("u/%d", i), bytes: covers[i%3]})
						if len(ever) < rows {
							tx.Write(band, "band: partial")
						} else {
							tx.Write(band, fmt.Sprintf("band: %d", len(ever)))
						}
						if twice == "" {
							tx.Write(again, "again: none")
						} else {
							tx.Write(again, "again: "+twice)
						}
					}).OnReleased(func(tx *kaya.Tx, keys []any) {
						key := keys[0].(string)
						delete(needed, key)
						pending = slices.DeleteFunc(pending, func(j job) bool { return j.key == key })
						tx.Write(released, "released: some")
					})
					row.Label(row.Title())
				})
			}
			table := list.Widget()
			tx.SetA11yID(table, "tracks")
			tx.SetGrow(table, 1)
		}))
		for i := range rows {
			tracks.Insert(tx, fmt.Sprintf("t%03d", i), Track{
				Title: fmt.Sprintf("Track %d", i), ArtURL: fmt.Sprintf("u/%d", i), Phase: kaya.ImagePhaseLoading,
			})
		}
	})

	go func() {
		for batch := range jobs {
			for _, j := range batch {
				switch {
				case j.live && j.bytes != nil:
					app.Post(func(tx *kaya.Tx) {
						tx.Write(art, j.bytes)
						tx.Write(phase, kaya.ImagePhaseShown)
					})
				case j.live:
					app.Post(func(tx *kaya.Tx) { tx.Write(phase, kaya.ImagePhaseFailed) })
				default:
					app.Post(func(tx *kaya.Tx) {
						TrackPatchIf(tracks, tx, j.key, artURL, j.url).Art(j.bytes).Phase(kaya.ImagePhaseShown)
					})
				}
			}
		}
	}()

	return app
}
