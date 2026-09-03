package kaya

// The canvas SIZE POLICY (docs/canvas-plan.md §3.2.1).

import (
	"encoding/binary"
	"testing"
)

// The policy a set_size_policy record carries: id at 8, policy at 16.
func policyOf(rec []byte) (uint64, uint32) {
	return binary.LittleEndian.Uint64(rec[8:]), binary.LittleEndian.Uint32(rec[16:])
}

func policies(records [][]byte) []uint32 {
	got := []uint32{}
	for _, r := range records {
		if recKind(r) == txSetSizePolicy {
			_, p := policyOf(r)
			got = append(got, p)
		}
	}
	return got
}

// REGISTERING AND DECLARING ARE ONE ACT: a handler that reached no wire
// record is a handler nothing ever calls, and `scale` is spelled by writing
// nothing at all.
func TestEachSizePolicyRidesItsDeclaration(t *testing.T) {
	app := NewApp()
	var scale, fixed, redraw, tick uint64
	app.Build(func(tx *Tx) {
		box := Viewbox{W: 300, H: 120}

		scale = tx.Canvas(box).id
		if got := policies(tx.records); len(got) != 0 {
			t.Fatalf("a bare canvas declared %v — `scale` is written by writing "+
				"nothing, so the wire must carry no policy for it", got)
		}

		fixed = tx.Canvas(box).Fixed().id
		redraw = tx.Canvas(box).OnDraw(func(*Draw, Viewbox) {}).id
		tick = tx.Canvas(box).OnTick(func(*Draw, Viewbox, float64) {}).id

		want := []uint32{SizePolicyFixed, SizePolicyRedraw, SizePolicyTick}
		got := policies(tx.records)
		if len(got) != len(want) {
			t.Fatalf("policies on the wire: %v, want %v", got, want)
		}
		for i := range want {
			if got[i] != want[i] {
				t.Fatalf("policies on the wire: %v, want %v", got, want)
			}
		}
	})

	if app.draws[scale] != nil || app.draws[fixed] != nil {
		t.Fatal("a canvas with no handler registered one — `scale` and `fixed` " +
			"declare the drawing CONSTANT and the core never asks them")
	}
	if app.draws[redraw] == nil || app.draws[tick] == nil {
		t.Fatal("OnDraw/OnTick put the policy on the wire without registering the " +
			"closure — the ask would arrive with nobody to answer it")
	}
}

// THE HANDLER ARITY IS THE REGISTERED POLICY'S, NEVER THE RECORD KIND'S: a
// tick canvas is a redraw canvas too, asked once as a draw_requested BEFORE
// its first frame (docs/canvas-plan.md: WIDEN THE HANDLER AT REGISTRATION,
// do not switch on the record).
func TestATickCanvasIsAskedAsARedrawCanvasToo(t *testing.T) {
	app := NewApp()
	var canvas uint64
	type call struct {
		size    Viewbox
		time    float64
		viewbox Viewbox
	}
	var calls []call
	app.Build(func(tx *Tx) {
		canvas = tx.Canvas(Viewbox{W: 300, H: 120}).
			OnTick(func(d *Draw, size Viewbox, time float64) {
				calls = append(calls, call{size, time, d.Viewbox()})
			}).id
	})

	// A draw_requested's tail is the size alone; a frame's carries the
	// platform's time as well.
	app.answerCanvasAsk(occDrawRequested, canvas, nil, []any{461.0, 87.0})
	app.answerCanvasAsk(occTick, canvas, nil, []any{461.0, 87.0, 0.05})

	if len(calls) != 2 {
		t.Fatalf("the tick handler ran %d times, want 2 — the draw_requested that "+
			"precedes the first frame must reach it too", len(calls))
	}
	if calls[0].time != 0 {
		t.Fatalf("the pre-frame draw_requested handed the tick handler time %v, "+
			"want 0", calls[0].time)
	}
	if calls[1].time != 0.05 {
		t.Fatalf("the frame handed the tick handler time %v, want 0.05 — the time "+
			"is the platform's and rides the record", calls[1].time)
	}
	for i, c := range calls {
		if c.size != (Viewbox{W: 461, H: 87}) {
			t.Fatalf("ask %d handed the handler %v, want the assigned 461x87", i, c.size)
		}
		// THE ASSIGNED SIZE IS THE NEXT VIEWBOX: the drawing the binding
		// submits is written in it, so the guest's fractions land on the track
		// it was given.
		if c.viewbox != c.size {
			t.Fatalf("ask %d drew into viewbox %v while it was assigned %v",
				i, c.viewbox, c.size)
		}
	}
	app.Build(func(tx *Tx) {
		tx.Draw(Widget{id: canvas, tx: tx}, func(d *Draw) {
			if d.Viewbox() != (Viewbox{W: 461, H: 87}) {
				t.Errorf("a plain Draw after an ask is written in %v, want the "+
					"assigned 461x87", d.Viewbox())
			}
		})
	})
}

// docs/deferred.md, the template-zone size policy entry.
func TestAnUnclaimedAskDropsAndAStampedOneIsRefused(t *testing.T) {
	app := NewApp()
	app.answerCanvasAsk(occDrawRequested, 99, nil, []any{10.0, 10.0})

	defer func() {
		got, _ := recover().(string)
		if got == "" {
			t.Fatal("an ask naming a template node was accepted — the size policy " +
				"is a live-zone declaration in this slice")
		}
	}()
	app.answerCanvasAsk(occDrawRequested, 99, []any{"row"}, []any{10.0, 10.0})
}

// The emit comes FIRST, so a registration through a dead transaction dies
// before the table moves and nothing is left registered against a canvas
// whose declaration never shipped.
func TestARegistrationThroughAClosedTransactionLeavesNothingBehind(t *testing.T) {
	app := NewApp()
	var canvas Widget
	app.Build(func(tx *Tx) { canvas = tx.Canvas(Viewbox{W: 10, H: 10}) })

	func() {
		defer func() {
			if recover() == nil {
				t.Fatal("OnDraw through a closed transaction was silently accepted")
			}
		}()
		canvas.OnDraw(func(*Draw, Viewbox) {})
	}()
	if app.draws[canvas.id] != nil {
		t.Fatal("the closure landed in the table anyway — the policy record never " +
			"shipped, so the core would never ask and the handler is dead code")
	}
}
