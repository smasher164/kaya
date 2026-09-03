package kaya

// The adaptive surface's wire shape (docs/adaptive-layout-plan.md D2, D3).
// The Go leg of the adaptive scene is not on a lane yet, so these read the
// records rather than re-calling the helpers that wrote them: the defects
// they catch are wrong ARGUMENTS — a threshold that rode as an integer, a
// setter triple out of order, or align's vocabulary where axis's belongs.

import (
	"encoding/binary"
	"strings"
	"testing"
)

// ONE record on the PRIMARY window: an i64 size class, then one setter
// triple flat — widget, prop, value.
func TestStackWhenRidesOneBreakpointRecord(t *testing.T) {
	app := NewApp()
	var row uint64
	recs := queued(t, app, func(tx *Tx) {
		row = tx.Row(func() {}).A11yID("narrow").StackWhen(SizeClassCompact).id
	})

	at := recordsOfKind(recs, txCreateBreakpoint)
	if len(at) != 1 {
		t.Fatalf("StackWhen queued %d breakpoint records, want exactly 1", len(at))
	}
	rec := recs[at[0]]
	if w := binary.LittleEndian.Uint64(rec[8:]); w != 0 {
		t.Fatalf("the breakpoint named window %d, want the primary (0) — it keys "+
			"on WINDOW width, never the container's own", w)
	}
	when, next := parseValue(rec, 16)
	if when != int64(SizeClassCompact) {
		t.Fatalf("size class rode as %#v, want i64 SizeClassCompact — the core "+
			"panics on any other tag", when)
	}
	if n := binary.LittleEndian.Uint32(rec[next:]); n != 1 {
		t.Fatalf("the record declares %d setters, want 1", n)
	}
	if n := binary.LittleEndian.Uint32(rec[next+8:]); n != 3 {
		t.Fatalf("one setter carries %d values, want 3 — the core asserts "+
			"count*3", n)
	}
	want := []any{int64(row), int64(PropAxis), int64(AxisVertical)}
	flat := next + 16
	for i, w := range want {
		var got any
		got, flat = parseValue(rec, flat)
		if got != w {
			t.Fatalf("setter value %d is %#v, want %#v — the thirds are widget, "+
				"prop, value BY POSITION", i, got, w)
		}
	}
}

// The dynamic path writes the same property the breakpoint moves, so a
// handler's flip and a width crossing are one observable.
func TestSetAxisWritesTheAxisPropConstant(t *testing.T) {
	app := NewApp()
	var row uint64
	recs := queued(t, app, func(tx *Tx) {
		w := tx.Row(func() {})
		row = w.id
		tx.SetAxis(w, AxisVertical)
	})

	at := recordsOfKind(recs, txSetProperty)
	if len(at) != 1 {
		t.Fatalf("SetAxis queued %d property records, want exactly 1", len(at))
	}
	p := decodeSetProp(t, recs[at[0]])
	if p.widget != row || p.prop != PropAxis || p.source != SourceConst {
		t.Fatalf("SetAxis wrote widget %d prop %d source %d, want %d/%d/%d",
			p.widget, p.prop, p.source, row, PropAxis, SourceConst)
	}
	if p.tag != ValueI64 || p.i64 != AxisVertical {
		t.Fatalf("the axis rode as tag %d value %d, want i64 AxisVertical (%d)",
			p.tag, p.i64, AxisVertical)
	}
}

// THE SENTENCE IS THE ASSERTION: emit's own chokepoint panics here too, so a
// test that only demanded A panic passed with this guard deleted (measured
// while writing it).
func TestStackWhenOutsideItsBuildPanicsNamingItself(t *testing.T) {
	app := NewApp()
	var row Widget
	app.Build(func(tx *Tx) { row = tx.Row(func() {}) })

	defer func() {
		got, _ := recover().(string)
		if !strings.Contains(got, "StackWhen on a widget outside its build transaction") {
			t.Fatalf("a late StackWhen panicked with %q — the breakpoint would never "+
				"ship and the row would never adapt, so the refusal names the call", got)
		}
	}()
	row.StackWhen(SizeClassCompact)
}
