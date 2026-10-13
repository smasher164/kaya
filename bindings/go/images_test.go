package kaya

// The network images surface (docs/network-images-plan.md N7, N12): the
// guarded patch's two drops through the mirror, its one record, its
// thread rule, and the helper's coalescing and cancellation.

import (
	"context"
	"errors"
	"runtime"
	"strings"
	"sync"
	"testing"
	"time"
)

type imageRow struct {
	ArtURL string
	Art    []byte
	Phase  ImagePhase
}

func imageURL(t *imageRow) *string { return &t.ArtURL }
func imageArt(t *imageRow) *[]byte { return &t.Art }
func imageRowPhase(t *imageRow) *ImagePhase {
	return &t.Phase
}

func TestPatchIfDropsAMissingRowAndAMovedOnGuard(t *testing.T) {
	app := NewApp()
	var rows RecordCollection[string, imageRow]
	app.Build(func(tx *Tx) {
		rows = CollectionOf[string, imageRow](tx)
		rows.Insert(tx, "a", imageRow{ArtURL: "u/a", Phase: ImagePhaseLoading})
		rows.Insert(tx, "b", imageRow{ArtURL: "u/b2", Phase: ImagePhaseLoading})
	})
	app.Build(func(tx *Tx) {
		rows.PatchIf(tx, "gone", imageURL, "u/gone").Set(imageArt, []byte{1}).Set(imageRowPhase, ImagePhaseShown)
		rows.PatchIf(tx, "b", imageURL, "u/b1").Set(imageArt, []byte{2}).Set(imageRowPhase, ImagePhaseShown)
		tx.flushPatchIf()
		before := len(tx.records)
		rows.PatchIf(tx, "a", imageURL, "u/a").Set(imageArt, []byte{3}).Set(imageRowPhase, ImagePhaseShown)
		tx.flushPatchIf()
		if got := len(tx.records) - before; got != 1 {
			t.Fatalf("a two-setter PatchIf sent %d records, want one collection_patch_if", got)
		}
	})
	app.Build(func(tx *Tx) {
		if _, ok := rows.Get(tx, "gone"); ok {
			t.Fatal("a PatchIf of a missing row inserted it into the mirror")
		}
		if b, _ := rows.Get(tx, "b"); b.Phase != ImagePhaseLoading || b.Art != nil {
			t.Fatalf("a PatchIf whose guard moved on wrote the mirror: %+v", b)
		}
		if a, _ := rows.Get(tx, "a"); a.Phase != ImagePhaseShown || len(a.Art) != 1 || a.Art[0] != 3 {
			t.Fatalf("a PatchIf whose guard held did not write the mirror: %+v", a)
		}
	})
}

func TestAPatchIfChainIsOneStatement(t *testing.T) {
	app := NewApp()
	var rows RecordCollection[string, imageRow]
	var s Signal[string]
	app.Build(func(tx *Tx) {
		rows = CollectionOf[string, imageRow](tx)
		s = tx.Signal("x")
		rows.Insert(tx, "a", imageRow{ArtURL: "u/a"})
	})
	var msg string
	app.Build(func(tx *Tx) {
		p := rows.PatchIf(tx, "a", imageURL, "u/a")
		tx.Write(s, "between")
		func() {
			defer func() { msg, _ = recover().(string) }()
			p.Set(imageRowPhase, ImagePhaseShown)
		}()
	})
	if !strings.Contains(msg, "one statement") {
		t.Fatalf("a Set after the chain's record was sent was answered with %q", msg)
	}
}

func TestPatchIfRefusesAnotherGoroutine(t *testing.T) {
	app := NewApp()
	claimAppThread()
	defer func() {
		appThread.Store(0)
		runtime.UnlockOSThread()
	}()
	var rows RecordCollection[string, imageRow]
	app.Build(func(tx *Tx) {
		rows = CollectionOf[string, imageRow](tx)
		rows.Insert(tx, "a", imageRow{ArtURL: "u/a"})
	})
	var msg string
	app.Build(func(tx *Tx) {
		done := make(chan struct{})
		go func() {
			defer close(done)
			defer func() { msg, _ = recover().(string) }()
			rows.PatchIf(tx, "a", imageURL, "u/a").Set(imageRowPhase, ImagePhaseShown)
		}()
		<-done
	})
	if !strings.Contains(msg, "belongs to the app thread") || !strings.Contains(msg, "App.Post") {
		t.Fatalf("a PatchIf from another goroutine was answered with %q", msg)
	}
}

// Rows sharing a URL share one fetch; a released row's queued URL is never
// fetched and a running one is cancelled; every result is one guarded write.
func TestRowImagesCoalescesAndCancels(t *testing.T) {
	app := NewApp()
	var mu sync.Mutex
	calls := map[string]int{}
	release := make(chan struct{})
	cancelled := make(chan string, 4)
	fetch := func(ctx context.Context, url string) ([]byte, error) {
		mu.Lock()
		calls[url]++
		mu.Unlock()
		if url == "u/slow" {
			<-ctx.Done()
			cancelled <- url
			return nil, ctx.Err()
		}
		<-release
		if url == "u/bad" {
			return nil, errors.New("404")
		}
		return []byte(url), nil
	}
	var rows RecordCollection[string, imageRow]
	var images *RowImages[string, imageRow]
	var failed []string
	app.Build(func(tx *Tx) {
		rows = CollectionOf[string, imageRow](tx)
		for key, url := range map[string]string{"a": "u/x", "b": "u/x", "c": "u/bad", "d": "u/slow"} {
			rows.Insert(tx, key, imageRow{ArtURL: url, Phase: ImagePhaseLoading})
		}
		images = NewRowImages(app, rows, imageURL, imageArt, imageRowPhase, fetch).
			OnError(func(_ *Tx, keys []any, err error) { failed = append(failed, keys[0].(string)+":"+err.Error()) })
	})
	app.Build(func(tx *Tx) {
		for _, key := range []string{"a", "b", "c", "d"} {
			images.imageNeeded(tx, []any{key})
		}
	})
	deadline := time.Now().Add(5 * time.Second)
	for {
		mu.Lock()
		n := calls["u/slow"]
		mu.Unlock()
		if n == 1 || time.Now().After(deadline) {
			break
		}
		time.Sleep(time.Millisecond)
	}
	images.imageReleased([]any{"d"})
	select {
	case <-cancelled:
	case <-time.After(5 * time.Second):
		t.Fatal("releasing the only row waiting on a running fetch did not cancel it")
	}
	close(release)
	deadline = time.Now().Add(5 * time.Second)
	for {
		app.drainPosted()
		done := false
		app.Build(func(tx *Tx) {
			a, _ := rows.Get(tx, "a")
			b, _ := rows.Get(tx, "b")
			c, _ := rows.Get(tx, "c")
			done = a.Phase == ImagePhaseShown && b.Phase == ImagePhaseShown && c.Phase == ImagePhaseFailed
		})
		if done {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("the helper's results never reached the rows")
		}
		time.Sleep(time.Millisecond)
	}
	mu.Lock()
	defer mu.Unlock()
	if calls["u/x"] != 1 {
		t.Fatalf("two rows sharing a URL made %d fetches, want one", calls["u/x"])
	}
	if len(failed) != 1 || failed[0] != "c:404" {
		t.Fatalf("the error callback heard %v, want [c:404]", failed)
	}
	app.Build(func(tx *Tx) {
		if d, _ := rows.Get(tx, "d"); d.Phase != ImagePhaseLoading {
			t.Fatalf("a released row's cancelled fetch wrote it: %+v", d)
		}
	})
	app.Build(func(tx *Tx) {
		rows.Insert(tx, "e", imageRow{ArtURL: "u/x", Phase: ImagePhaseLoading})
		images.imageNeeded(tx, []any{"e"})
		if e, _ := rows.Get(tx, "e"); e.Phase != ImagePhaseShown || string(e.Art) != "u/x" {
			t.Fatalf("a URL already in the cache was not written in the same transaction: %+v", e)
		}
	})
	if calls["u/x"] != 1 {
		t.Fatalf("a cached URL was fetched again: %d", calls["u/x"])
	}
}
