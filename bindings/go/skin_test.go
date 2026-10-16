package kaya

// docs/styling-pass-plan.md Y2-Y8: what the skin's sugar queues. The pixels
// are the scenes' (tools/scenes/{grounds,shapes,cards,tracks,dock}.steps).

import (
	"bytes"
	"image"
	"image/color"
	"image/png"
	"testing"
)

func skinRecords(t *testing.T, build func(tx *Tx)) [][]byte {
	t.Helper()
	app := NewApp()
	var got [][]byte
	app.Build(func(tx *Tx) {
		build(tx)
		got = append(got, tx.records...)
	})
	return got
}

func holds(recs [][]byte, want []byte) bool {
	for _, r := range recs {
		if bytes.Equal(r, want) {
			return true
		}
	}
	return false
}

// Registering a handler without declaring the container activatable would
// draw a plain container that never emits.
func TestOnActivateDeclaresActivatable(t *testing.T) {
	var w Widget
	var n Node
	app := NewApp()
	var recs [][]byte
	app.Build(func(tx *Tx) {
		w = tx.Column(func() {}).OnActivate(func(*Tx) {})
		tx.When(tx.Signal(true), func(tp *Tpl) {
			n = tp.Row(func() {}).OnActivate(func(*Tx, []any) {})
		})
		recs = append(recs, tx.records...)
	})
	if !holds(recs, TxSetActivatable(w.id, true)) || app.widgetActivates[w.id] == nil {
		t.Fatal("a live OnActivate queued no activatable record or kept no handler")
	}
	if !holds(recs, TxSetActivatable(n.id, true)) || app.nodeActivates[n.id] == nil {
		t.Fatal("a template OnActivate queued no activatable record or kept no handler")
	}
}

// A gradient whose colour rides without its ground (or the reverse) is
// refused at the root; both ride together.
func TestGroundsQueueTheirPair(t *testing.T) {
	var g, img Widget
	c := ColorRGB(0x5B, 0x2A, 0x86)
	recs := skinRecords(t, func(tx *Tx) {
		g = tx.Column(func() {}).GroundGradient(c)
		img = tx.Column(func() {}).GroundImage([]byte("x"))
	})
	if !holds(recs, TxSetGround(g.id, GroundGradient)) || !holds(recs, TxSetColor(g.id, c.R, c.G, c.B, c.A)) {
		t.Fatal("GroundGradient did not queue the gradient ground with its colour")
	}
	if !holds(recs, TxSetGround(img.id, GroundImage)) {
		t.Fatal("GroundImage did not queue the image ground")
	}
}

func TestDockAttachesThenMounts(t *testing.T) {
	var root Widget
	recs := skinRecords(t, func(tx *Tx) {
		tx.Window(0).Dock(40, func() Widget {
			root = tx.Column(func() {})
			return root
		})
	})
	attach, mount := -1, -1
	for i, r := range recs {
		if bytes.Equal(r, TxAttachDock(0, 40)) {
			attach = i
		}
		if bytes.Equal(r, TxMount(40, root.id)) {
			mount = i
		}
	}
	if attach < 0 || mount < attach {
		t.Fatalf("the dock attached at %d and mounted at %d; the mount needs the surface first", attach, mount)
	}
}

// The core's one quantizer: a picture that is 70% one colour answers that
// colour, and bytes that do not decode answer false.
func TestImageDominantThroughTheCore(t *testing.T) {
	pic := image.NewRGBA(image.Rect(0, 0, 10, 10))
	for y := 0; y < 10; y++ {
		for x := 0; x < 10; x++ {
			c := color.RGBA{0x1D, 0xB9, 0x54, 0xFF}
			if x >= 7 {
				c = color.RGBA{0x30, 0x40, 0xC0, 0xFF}
			}
			pic.Set(x, y, c)
		}
	}
	var buf bytes.Buffer
	if err := png.Encode(&buf, pic); err != nil {
		t.Fatal(err)
	}
	c, ok := ImageDominant(buf.Bytes())
	if !ok || c.G < c.R || c.G < c.B || c.A != 0xFF {
		t.Fatalf("a picture 70%% green answered %v (ok %v)", c, ok)
	}
	if _, ok := ImageDominant([]byte("not an image")); ok {
		t.Fatal("undecodable bytes answered a colour")
	}
}
