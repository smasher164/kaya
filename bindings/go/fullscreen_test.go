package kaya

// Fullscreen (docs/fullscreen-plan.md): the prop rides the window construct,
// and fullscreen_changed reaches the handler bound on THAT window's
// construct with the Bool, persistently. The switch arm's own call is held by
// tools/scenes/fullscreen.steps on every desktop lane.

import (
	"bytes"
	"testing"
)

func TestFullscreenRidesTheWindowConstruct(t *testing.T) {
	app := NewApp()
	recs := queued(t, app, func(tx *Tx) {
		tx.Window(0).Fullscreen(true)
		tx.CreateWindow(1950).Fullscreen(false)
	})
	want := [][]byte{TxSetWindowFullscreen(0, true), TxSetWindowFullscreen(1950, false)}
	for _, w := range want {
		found := false
		for _, rec := range recs {
			found = found || bytes.Equal(rec, w)
		}
		if !found {
			t.Fatalf("no record %x among %d queued", w, len(recs))
		}
	}
}

func TestEachWindowsFullscreenChangedReachesItsOwnHandler(t *testing.T) {
	app := NewApp()
	type seen struct {
		window uint64
		on     bool
	}
	var got []seen
	app.Build(func(tx *Tx) {
		tx.Window(0).OnFullscreenChanged(func(tx *Tx, on bool) { got = append(got, seen{0, on}) })
		tx.CreateWindow(1950).OnFullscreenChanged(func(tx *Tx, on bool) { got = append(got, seen{1950, on}) })
	})
	app.fullscreenChangedTo(0, false)
	app.fullscreenChangedTo(1950, true)
	app.fullscreenChangedTo(0, true)
	app.fullscreenChangedTo(77, false)
	want := []seen{{0, false}, {1950, true}, {0, true}}
	if len(got) != len(want) {
		t.Fatalf("fullscreen_changed reached %v, wanted %v", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("fullscreen_changed reached %v, wanted %v", got, want)
		}
	}
}
