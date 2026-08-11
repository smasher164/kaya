package kaya

// The template zone's two guards: the occurrence dispatch's live/node
// PAIRING, and the claim that the new sugar emits exactly the floor it
// replaces. Both run headless, like the rest of this package's tests.

import (
	"bytes"
	"encoding/binary"
	"os"
	"regexp"
	"sort"
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

// --- the template-node props (docs/tpl-props-plan.md §1) ---------------

// setProp is a decoded set_property record: the header every prop write
// shares, plus whatever its source flavor puts after it.
type setProp struct {
	widget       uint64
	prop, source uint32
	tag          uint32 // const: the value type it rode as
	text         string // const, when that type is a string
	signal       uint64 // signal
	level, field uint32 // element
}

// decodeSetProp reads the record rather than re-calling the helper that
// wrote it, because the defect it exists to catch is a call to the
// WRONG helper: seven prop writes of one shape sit beside each other on
// *Tpl, and BindA11yLabel emitting the a11y_id op would compile,
// record, stamp, and tell assistive tech the wrong name for every row.
func decodeSetProp(t *testing.T, rec []byte) setProp {
	t.Helper()
	if kind := binary.LittleEndian.Uint16(rec[4:]); kind != txSetProperty {
		t.Fatalf("record kind %d, want set_property (%d)", kind, txSetProperty)
	}
	p := setProp{
		widget: binary.LittleEndian.Uint64(rec[8:]),
		prop:   binary.LittleEndian.Uint32(rec[16:]),
		source: binary.LittleEndian.Uint32(rec[20:]),
	}
	switch p.source {
	case SourceConst:
		// The tag is part of the claim: the four string props ride a
		// ValueStr, and a prop that reached the wire as some other type
		// would be refused by the root rather than misread here.
		p.tag = binary.LittleEndian.Uint32(rec[24:])
		if p.tag == ValueStr {
			n := binary.LittleEndian.Uint32(rec[28:])
			p.text = string(rec[32 : 32+n])
		}
	case SourceSignal:
		p.signal = binary.LittleEndian.Uint64(rec[24:])
	case SourceElement:
		p.level = binary.LittleEndian.Uint32(rec[24:])
		p.field = binary.LittleEndian.Uint32(rec[28:])
	}
	return p
}

// propWrite runs write inside a template over a fresh entry node and
// returns the ONE set_property record it queued. A case may queue other
// records first (minting the signal it binds); exactly one property
// write is the claim.
func propWrite(t *testing.T, write func(*Tx, *Tpl, Node) setProp) (setProp, setProp) {
	t.Helper()
	app := NewApp()
	var want setProp
	var props [][]byte
	app.Build(func(tx *Tx) {
		items := tx.Collection()
		tx.ForEach(items, func(tp *Tpl) {
			n := tp.Widget(KindEntry)
			before := len(tx.records)
			want = write(tx, tp, n)
			for _, rec := range tx.records[before:] {
				if binary.LittleEndian.Uint16(rec[4:]) == txSetProperty {
					props = append(props, rec)
				}
			}
		})
	})
	if len(props) != 1 {
		t.Fatalf("the prop write queued %d set_property records, want exactly 1",
			len(props))
	}
	return decodeSetProp(t, props[0]), want
}

func TestTemplatePropsCarryTheirOwnPropAndSource(t *testing.T) {
	// A NON-ZERO FIELD INDEX, so an arm that dropped the token and bound
	// field 0 — the scalar row's own value, and the index every other
	// element binding in this zone happens to use — fails here.
	token := FieldAt[string](3)

	cases := []struct {
		name  string
		write func(*Tx, *Tpl, Node) setProp
	}{
		{"SetA11yID", func(_ *Tx, tp *Tpl, n Node) setProp {
			tp.SetA11yID(n, "row-entry")
			return setProp{widget: n.id, prop: PropA11yId, source: SourceConst,
				tag: ValueStr, text: "row-entry"}
		}},
		{"BindA11yID signal", func(tx *Tx, tp *Tpl, n Node) setProp {
			s := tx.Signal("id")
			tp.BindA11yID(n, s)
			return setProp{widget: n.id, prop: PropA11yId, source: SourceSignal, signal: s.id}
		}},
		{"BindA11yID field", func(_ *Tx, tp *Tpl, n Node) setProp {
			tp.BindA11yID(n, token)
			return setProp{widget: n.id, prop: PropA11yId, source: SourceElement, field: 3}
		}},
		{"SetA11yLabel", func(_ *Tx, tp *Tpl, n Node) setProp {
			tp.SetA11yLabel(n, "Milk")
			return setProp{widget: n.id, prop: PropA11yLabel, source: SourceConst,
				tag: ValueStr, text: "Milk"}
		}},
		{"BindA11yLabel signal", func(tx *Tx, tp *Tpl, n Node) setProp {
			s := tx.Signal("spoken")
			tp.BindA11yLabel(n, s)
			return setProp{widget: n.id, prop: PropA11yLabel, source: SourceSignal, signal: s.id}
		}},
		{"BindA11yLabel field", func(_ *Tx, tp *Tpl, n Node) setProp {
			tp.BindA11yLabel(n, token)
			return setProp{widget: n.id, prop: PropA11yLabel, source: SourceElement, field: 3}
		}},
		{"SetA11yHint", func(_ *Tx, tp *Tpl, n Node) setProp {
			tp.SetA11yHint(n, "delete this row")
			return setProp{widget: n.id, prop: PropA11yHint, source: SourceConst,
				tag: ValueStr, text: "delete this row"}
		}},
		{"BindA11yHint signal", func(tx *Tx, tp *Tpl, n Node) setProp {
			s := tx.Signal("hint")
			tp.BindA11yHint(n, s)
			return setProp{widget: n.id, prop: PropA11yHint, source: SourceSignal, signal: s.id}
		}},
		{"BindA11yHint field", func(_ *Tx, tp *Tpl, n Node) setProp {
			tp.BindA11yHint(n, token)
			return setProp{widget: n.id, prop: PropA11yHint, source: SourceElement, field: 3}
		}},
		// The accept list is the live path's own join, so a spaced or
		// empty entry panics there rather than reaching a backend.
		{"SetAccepts", func(_ *Tx, tp *Tpl, n Node) setProp {
			tp.SetAccepts(n, AcceptText, "com.example.note")
			return setProp{widget: n.id, prop: PropAccepts, source: SourceConst,
				tag: ValueStr, text: "text com.example.note"}
		}},
		// The grow weight rides the same header; it is here so the table
		// covers every prop the zone carries rather than the new ones
		// alone.
		{"SetGrow", func(_ *Tx, tp *Tpl, n Node) setProp {
			tp.SetGrow(n, 1)
			return setProp{widget: n.id, prop: PropGrow, source: SourceConst, tag: ValueF64}
		}},
	}

	for _, c := range cases {
		got, want := propWrite(t, c.write)
		if got != want {
			t.Errorf("%s recorded %+v, want %+v", c.name, got, want)
		}
	}
}

// The typed surface's third arm — the raw field PROJECTION — is the
// whole of what RecordCollection adds to a prop, so it is pinned where
// it can go wrong: resolving to the wrong field index binds a stamped
// copy's spoken name to a neighbouring column, silently and per row.
type propRec struct {
	Title string
	Note  string
}

func TestRecordSurfaceResolvesAPropProjectionToItsOwnField(t *testing.T) {
	app := NewApp()
	var props []setProp
	app.Build(func(tx *Tx) {
		c := CollectionOf[string, propRec](tx)
		tx.ForEach(c.Collection, func(tp *Tpl) {
			n := tp.Widget(KindEntry)
			before := len(tx.records)
			c.A11yLabel(tp, n, func(r *propRec) *string { return &r.Note })
			c.A11yID(tp, n, "row")
			for _, rec := range tx.records[before:] {
				props = append(props, decodeSetProp(t, rec))
			}
		})
	})
	if len(props) != 2 {
		t.Fatalf("the typed prop writes queued %d records, want 2", len(props))
	}
	if props[0].prop != PropA11yLabel || props[0].source != SourceElement ||
		props[0].level != 0 || props[0].field != 1 {
		t.Errorf("the Note projection recorded %+v, want a11y_label bound to "+
			"element field 1 at level 0", props[0])
	}
	// The const arm is the DEFAULT arm on this surface, so a plain
	// string must not fall past the three source arms into nothing —
	// the silent-drop failure applyRecordText was fixed for.
	if props[1].prop != PropA11yId || props[1].source != SourceConst || props[1].text != "row" {
		t.Errorf("the constant identifier recorded %+v, want a11y_id const \"row\"", props[1])
	}
}

// --- the props reach the two SEALED surfaces ---------------------------
//
// The template zone hands a guest five surfaces, and three of them can
// always fall back on the recorder: Row EMBEDS *Tpl, RecordCollection
// TAKES one, and *Tpl is one. The other two are sealed on purpose —
// SumCase keeps its *Tpl unexported so an arm cannot reach past its own
// refinement (sums.go), and the generated <name>Row keeps its as a
// private struct field — so on those two a prop that is not forwarded
// cannot be spelled at ANY tier, floor included. Grow spent a milestone
// in exactly that state, reachable on three surfaces of five, and
// nothing in the tree said so.

// Prop writes that a refined surface deliberately does not forward.
// Each is the FLOOR spelling of a constructor's element binding, and a
// refined surface offers the constructor instead (SumCase.Label takes
// the field selector; the generated row takes the token).
var notForwarded = map[string]string{
	"TextElement":  "Tpl.BindTextElement, the floor under Label",
	"TextField":    "Tpl.BindTextField, the floor under Label",
	"CheckedField": "Tpl.BindCheckedField, the floor under Checkbox",
	"ValueField":   "Tpl.BindValueField, the floor under Slider/Select/Radio",
	"SourceField":  "Tpl.BindSourceField, the floor under Image",
}

// props reads the prop writes a surface declares: a method whose FIRST
// PARAMETER IS THE NODE it writes to, which is what makes it a prop
// write rather than a constructor. Each is filed under its prop AND the
// flavor its name declares — Set is the constant, Bind is the source —
// because a prop reachable in one flavor only is still a hole: an arm
// that can give every copy the same spoken name but cannot give it the
// row's own has lost the case the a11y pair exists for.
func props(src, decl string) map[string]bool {
	re := regexp.MustCompile(`(?m)^` + decl + `(?:\[[^()]*?\])?\(n (?:kaya\.)?Node[,)]`)
	out := map[string]bool{}
	for _, m := range re.FindAllStringSubmatch(src, -1) {
		name, flavor := m[1], "sourced"
		if strings.HasPrefix(name, "Set") {
			name, flavor = strings.TrimPrefix(name, "Set"), "const"
		} else {
			name = strings.TrimPrefix(name, "Bind")
		}
		if _, skip := notForwarded[name]; !skip {
			out[name+" ("+flavor+")"] = true
		}
	}
	return out
}

// missingProps is the pairing itself, over sources rather than over the
// package, so the negative test below can ask it about a doctored copy.
func missingProps(base, refined, decl string) []string {
	var gap []string
	for name := range props(base, baseDecl) {
		if !props(refined, decl)[name] {
			gap = append(gap, name)
		}
	}
	sort.Strings(gap)
	return gap
}

// The base surface and the two sealed ones, each with the declaration
// it spells a prop write with. The generated one is read from the
// EMITTER: its outputs are checked-in files in the guests' own
// packages, and the emitter is the one place they all agree.
const (
	baseDecl    = `func \(t \*Tpl\) ((?:Set|Bind)[A-Za-z0-9]*)`
	sumCaseDecl = `func \(sc SumCase\[K, V\]\) ((?:Set|Bind)[A-Za-z0-9]*)`
	// The generated row drops the Bind prefix on its sourced flavors,
	// as its constructors do (Label(f), not LabelBound), so a bare name
	// there is read as the sourced one.
	genRowDecl = `\tw\("func \(r %sRow\) ((?:Set|Bind)?[A-Za-z0-9]*)`
)

func TestEveryTemplatePropReachesTheSealedSurfaces(t *testing.T) {
	base := readSource(t, "app.go") + readSource(t, "records.go")
	arm := readSource(t, "sums.go")
	gen := readSource(t, "../../cmd/kaya-gen/main.go")

	// THE READER IS WATCHED FIRST. A pattern that stopped matching the
	// base surface would find no props, demand nothing of either sealed
	// surface, and agree with everything.
	if n := len(props(base, baseDecl)); n < 8 {
		t.Fatalf("found %d prop writes on *Tpl, fewer than the 8 the zone is "+
			"known to carry (grow and accepts as constants, the a11y trio in "+
			"both flavors) — the pattern has stopped seeing the surface it "+
			"exists to compare against", n)
	}

	for _, s := range []struct{ what, src, decl string }{
		{"SumCase (bindings/go/sums.go)", arm, sumCaseDecl},
		{"the generated <name>Row (cmd/kaya-gen/main.go)", gen, genRowDecl},
	} {
		if gap := missingProps(base, s.src, s.decl); len(gap) > 0 {
			t.Errorf("%s does not carry the template props %v. That surface "+
				"seals its *Tpl away, so a guest there cannot spell them at any "+
				"tier — forward them, or name them in notForwarded with a reason",
				s.what, gap)
		}
	}

	// AND THE GUARD IS WATCHED FAILING, once per surface, against a copy
	// with one forward cut back out.
	for _, p := range []struct {
		what, src, decl, cut, want string
	}{
		{"SumCase", arm, sumCaseDecl,
			"func (sc SumCase[K, V]) SetAccepts(n Node, kinds ...string) { sc.t.SetAccepts(n, kinds...) }\n",
			"Accepts (const)"},
		// The SOURCED half alone, cut from the surface that keeps the two
		// under one name: the const forward stays, and the prop is still
		// short of the flavor the row's own field needs.
		{"the generated row", gen, genRowDecl,
			"\tw(\"func (r %sRow) A11yLabel(n kaya.Node, f kaya.Field[string]) { r.c.A11yLabel(r.t, n, f) }\", lowerFirst(name))\n",
			"A11yLabel (sourced)"},
	} {
		if n := strings.Count(p.src, p.cut); n != 1 {
			t.Fatalf("the %s perturbation matched %d times, want 1 — it has "+
				"stopped describing the forward it removes, so the negative test "+
				"would pass without perturbing anything", p.what, n)
		}
		gap := missingProps(base, strings.Replace(p.src, p.cut, "", 1), p.decl)
		if len(gap) != 1 || gap[0] != p.want {
			t.Fatalf("with %s's %s forward removed the pairing reported %v, want "+
				"exactly [%s] — it does not detect the defect it was written for",
				p.what, p.want, gap, p.want)
		}
	}
}

func readSource(t *testing.T, path string) string {
	t.Helper()
	src, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("reading %s: %v", path, err)
	}
	return string(src)
}
