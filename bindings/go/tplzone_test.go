package kaya

// The template zone's two guards: the occurrence dispatch's live/node
// PAIRING, and the claim that the new sugar emits exactly the floor it
// replaces. Both run headless, like the rest of this package's tests.

import (
	"bytes"
	"os"
	"regexp"
	"strings"
	"testing"
)

// A LIVE ARM WITHOUT A NODE ARM IS A SILENT DROP, and it is invisible.
//
// The dispatch loop splits every occurrence that a template can produce
// into two cases on the same record kind: `len(keys) == 0` is the live
// widget, and the bare case is the stamped copy, whose key path names
// which copy it was. Written that way the two look like a pair, but
// nothing holds them to it — and until 2026-08-10 value changes had
// only the live half. A stamped slider's move, or a stamped select's
// pick, therefore matched NO case at all: not a missing handler, not an
// error, not a log line. It fell out of the switch.
//
// Nothing found it for months because no scene puts a slider inside a
// collection — because until the same day there was no template slider
// constructor to put there. That is the shape this guard exists for: a
// hole one surface wide, held open by a second surface's absence, which
// no scene can fail and no compiler can see.
//
// So the rule is mechanical and needs no list: whatever occurrence
// kinds this loop learns to route, a live arm gated on an empty key
// path obliges a node arm on the same kind.
func armlessKinds(src string) []string {
	live := regexp.MustCompile(`case kind == (occ[A-Za-z]+) && len\(keys\) == 0:`)
	found := live.FindAllStringSubmatch(src, -1)
	var missing []string
	for _, m := range found {
		if !strings.Contains(src, "case kind == "+m[1]+":") {
			missing = append(missing, m[1])
		}
	}
	return missing
}

func liveArmCount(src string) int {
	live := regexp.MustCompile(`case kind == occ[A-Za-z]+ && len\(keys\) == 0:`)
	return len(live.FindAllString(src, -1))
}

func TestEveryLiveDispatchArmHasATemplateNodeSibling(t *testing.T) {
	src, err := os.ReadFile("app.go")
	if err != nil {
		t.Fatalf("reading app.go: %v", err)
	}
	body := string(src)

	// THE READER IS WATCHED FIRST. A pattern that stopped matching the
	// switch would report no missing arms and agree with everything,
	// which is the one shape a guard must never have.
	if n := liveArmCount(body); n < 4 {
		t.Fatalf("found %d live dispatch arms in app.go, fewer than the 4 this "+
			"loop is known to have — the pattern has stopped seeing the switch "+
			"it exists to read and can no longer fail", n)
	}
	if missing := armlessKinds(body); len(missing) > 0 {
		t.Fatalf("occurrence kinds with a live arm and no template-node arm: %v. "+
			"A stamped copy's occurrence of that kind matches no case and is "+
			"dropped with no error anywhere — add the `case kind == <kind>:` "+
			"sibling and the map it reads (see OnValueChangedNode).",
			missing)
	}

	// AND THE GUARD IS WATCHED FAILING. A pairing check nobody has seen
	// go red is a belief, not a test: this one is asked the same
	// question about a source with the value-changed node arm cut back
	// out, which is exactly the state the binding shipped in.
	cut := "\t\tcase kind == occValueChanged:\n"
	perturbed := strings.Replace(body, cut, "", 1)
	if n := strings.Count(body, cut); n != 1 {
		t.Fatalf("the perturbation matched %d times, want 1 — it has stopped "+
			"describing the arm it removes, so the negative test below would "+
			"pass without perturbing anything", n)
	}
	missing := armlessKinds(perturbed)
	if len(missing) != 1 || missing[0] != "occValueChanged" {
		t.Fatalf("with the value-changed node arm removed the guard reported %v, "+
			"want exactly [occValueChanged] — it does not detect the defect it "+
			"was written for", missing)
	}
}

// THE SUGAR IS A SPELLING CHANGE AND NOTHING ELSE, which is a claim
// about bytes rather than about intent. tools/scenes/*.steps are shared
// verbatim across every platform and their expected strings are
// compared byte-for-byte, so the undo scene's per-row field and the
// text editor's find bar may move off `Widget(KindEntry)` onto `Entry()`
// only if the two record the same thing. They do, by construction —
// Entry's whole body is that call — and this pins it, because "by
// construction" is what a future body silently stops being.
func TestTemplateEntrySugarRecordsWhatTheFloorRecorded(t *testing.T) {
	floor := templateRecords(t, func(t *Tpl) { t.Widget(KindEntry) })
	sugar := templateRecords(t, func(t *Tpl) { t.Entry() })
	if len(floor) == 0 {
		t.Fatal("the floor spelling queued no records — the probe built nothing")
	}
	if len(floor) != len(sugar) {
		t.Fatalf("Tpl.Entry queued %d records where the floor queued %d",
			len(sugar), len(floor))
	}
	for i := range floor {
		if !bytes.Equal(floor[i], sugar[i]) {
			t.Fatalf("record %d differs: floor %x, sugar %x — Tpl.Entry is no "+
				"longer the floor call it replaced, so the two guests that now "+
				"spell it that way have changed what their scenes emit",
				i, floor[i], sugar[i])
		}
	}
}

// templateRecords queues one collection and one For over it, runs body
// as the template, and returns the frames. A FRESH App per call, so
// both runs allocate from the same id counters and the comparison is
// over the records rather than over the numbering.
func templateRecords(t *testing.T, body func(*Tpl)) [][]byte {
	t.Helper()
	app := NewApp()
	var out [][]byte
	app.Build(func(tx *Tx) {
		items := tx.Collection()
		tx.ForEach(items, body)
		out = append(out, tx.records...)
	})
	return out
}
