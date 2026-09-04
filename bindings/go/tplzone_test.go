package kaya

import (
	"bytes"
	"encoding/binary"
	"math"
	"os"
	"regexp"
	"sort"
	"strings"
	"testing"
)

// A live arm without a node arm is a SILENT DROP — the stamped copy's
// occurrence matches no case at all (docs/sugar-pass-plan.md §D2).
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

// ONE ID SPACE: a template node draws from the WIDGET counter (DESIGN.md,
// Binding conventions). The CONTIGUOUS RUN is the assertion, not inequality
// — a private node counter restarted at 1 sits under the live ids an app has
// already spent and passes a `!=` while being exactly the defect.
func TestWidgetsAndTemplateNodesDrawFromOneCounter(t *testing.T) {
	app := NewApp()
	var live, site, node, after uint64
	app.Build(func(tx *Tx) {
		live = tx.Widget(KindLabel).id
		items := tx.Collection()
		// The For's own container is a live widget, and its number is spent
		// when the rows OPEN.
		rows := tx.Rows(items)
		site = rows.Widget().id
		for row := range rows.All() {
			node = row.Widget(KindLabel).id
		}
		after = tx.Widget(KindLabel).id
	})
	if got := [4]uint64{live, site, node, after}; got != [4]uint64{1, 2, 3, 4} {
		t.Fatalf("ids %v, want [1 2 3 4] — widgets and template nodes must run "+
			"through one counter", got)
	}
}

// Ranging one rows value twice pops the scope stacks twice, and every widget
// declared after the second loop lands in whatever scope the underflow left
// behind — silently, in the middle of a build.
func TestARowsValueRefusesASecondTrace(t *testing.T) {
	app := NewApp()
	defer func() {
		r := recover()
		if r == nil {
			t.Fatal("a second range over one rows value did not panic")
		}
		if msg, _ := r.(string); !strings.Contains(msg, "traces one template") {
			t.Fatalf("panicked with %v, want the one-trace refusal", r)
		}
	}()
	app.Build(func(tx *Tx) {
		items := tx.Collection()
		rows := tx.Rows(items)
		for row := range rows.All() {
			row.LabelText("once")
		}
		for row := range rows.All() {
			row.LabelText("twice")
		}
	})
}

// templateRecords returns the frames body queues as a template. A FRESH App
// per call, so both runs allocate from the same id counters.
func templateRecords(t *testing.T, body func(*Tpl)) [][]byte {
	t.Helper()
	app := NewApp()
	var out [][]byte
	app.Build(func(tx *Tx) {
		items := tx.Collection()
		for row := range tx.Rows(items).All() {
			body(row.Tpl)
		}
		out = append(out, tx.records...)
	})
	return out
}

// --- the template-node props (docs/tpl-props-plan.md §1) ---------------

type setProp struct {
	widget       uint64
	prop, source uint32
	tag          uint32  // const: the value type it rode as
	text         string  // const, when that type is a string
	i64          int64   // const, when that type is an integer
	f64          float64 // const, when that type is a double
	signal       uint64  // signal
	level, field uint32  // element
}

// decodeSetProp reads the record rather than re-calling the helper that wrote
// it: the defect it catches is a call to the WRONG helper, and seven prop
// writes of one shape sit beside each other on *Tpl.
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
		// The tag AND the value are part of the claim: a setter that reaches
		// the right emitter but drops its argument is invisible to the prop
		// number alone.
		p.tag = binary.LittleEndian.Uint32(rec[24:])
		switch p.tag {
		case ValueStr:
			n := binary.LittleEndian.Uint32(rec[28:])
			p.text = string(rec[32 : 32+n])
		case ValueI64:
			p.i64 = int64(binary.LittleEndian.Uint64(rec[32:]))
		case ValueF64:
			p.f64 = math.Float64frombits(binary.LittleEndian.Uint64(rec[32:]))
		}
	case SourceSignal:
		p.signal = binary.LittleEndian.Uint64(rec[24:])
	case SourceElement:
		p.level = binary.LittleEndian.Uint32(rec[24:])
		p.field = binary.LittleEndian.Uint32(rec[28:])
	}
	return p
}

// propWrite returns the ONE set_property record write queued; a case may
// queue other records first (minting the signal it binds).
func propWrite(t *testing.T, write func(*Tx, *Tpl, Node) setProp) (setProp, setProp) {
	t.Helper()
	app := NewApp()
	var want setProp
	var props [][]byte
	app.Build(func(tx *Tx) {
		items := tx.Collection()
		for row := range tx.Rows(items).All() {
			n := row.Widget(KindEntry)
			before := len(tx.records)
			want = write(tx, row.Tpl, n)
			for _, rec := range tx.records[before:] {
				if binary.LittleEndian.Uint16(rec[4:]) == txSetProperty {
					props = append(props, rec)
				}
			}
		}
	})
	if len(props) != 1 {
		t.Fatalf("the prop write queued %d set_property records, want exactly 1",
			len(props))
	}
	return decodeSetProp(t, props[0]), want
}

func TestTemplatePropsCarryTheirOwnPropAndSource(t *testing.T) {
	// A NON-ZERO field index, so an arm that dropped the token and bound
	// field 0 fails here.
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
		{"SetGrow", func(_ *Tx, tp *Tpl, n Node) setProp {
			tp.SetGrow(n, 1)
			return setProp{widget: n.id, prop: PropGrow, source: SourceConst,
				tag: ValueF64, f64: 1}
		}},
		// Role and inset are adjacent integers in one PROPS table (16 and
		// 17), both const, one emit line apart on *Tpl — the prop NUMBER
		// and the value TAG together are what tell them apart.
		{"SetRole", func(_ *Tx, tp *Tpl, n Node) setProp {
			tp.SetRole(n, RoleHeading)
			return setProp{widget: n.id, prop: PropRole, source: SourceConst,
				tag: ValueI64, i64: RoleHeading}
		}},
		{"SetInset", func(_ *Tx, tp *Tpl, n Node) setProp {
			tp.SetInset(n, 8)
			return setProp{widget: n.id, prop: PropInset, source: SourceConst,
				tag: ValueF64, f64: 8}
		}},
	}

	for _, c := range cases {
		got, want := propWrite(t, c.write)
		if got != want {
			t.Errorf("%s recorded %+v, want %+v", c.name, got, want)
		}
	}
}

// The raw field PROJECTION: resolving to the wrong field index binds a row's
// spoken name to a neighbouring column, silently and per row.
type propRec struct {
	Title string
	Note  string
}

func TestRecordSurfaceResolvesAPropProjectionToItsOwnField(t *testing.T) {
	app := NewApp()
	var props []setProp
	app.Build(func(tx *Tx) {
		c := CollectionOf[string, propRec](tx)
		for row := range tx.Rows(c.Collection).All() {
			n := row.Widget(KindEntry)
			before := len(tx.records)
			c.A11yLabel(row.Tpl, n, func(r *propRec) *string { return &r.Note })
			c.A11yID(row.Tpl, n, "row")
			for _, rec := range tx.records[before:] {
				props = append(props, decodeSetProp(t, rec))
			}
		}
	})
	if len(props) != 2 {
		t.Fatalf("the typed prop writes queued %d records, want 2", len(props))
	}
	if props[0].prop != PropA11yLabel || props[0].source != SourceElement ||
		props[0].level != 0 || props[0].field != 1 {
		t.Errorf("the Note projection recorded %+v, want a11y_label bound to "+
			"element field 1 at level 0", props[0])
	}
	// The const arm is the DEFAULT arm here, so a plain string must not
	// fall past the three source arms into nothing.
	if props[1].prop != PropA11yId || props[1].source != SourceConst || props[1].text != "row" {
		t.Errorf("the constant identifier recorded %+v, want a11y_id const \"row\"", props[1])
	}
}

// --- the props reach the two SEALED surfaces ---------------------------
//
// SumCase and the generated <name>Row seal their *Tpl away, so on those a
// prop that is not forwarded cannot be spelled at ANY tier, floor included.

// Prop writes a refined surface deliberately does not forward: each is the
// FLOOR spelling of a constructor's element binding, and a refined surface
// offers the constructor instead.
var notForwarded = map[string]string{
	"TextElement":  "Tpl.BindTextElement, the floor under Label",
	"TextField":    "Tpl.BindTextField, the floor under Label",
	"CheckedField": "Tpl.BindCheckedField, the floor under Checkbox",
	"ValueField":   "Tpl.BindValueField, the floor under Slider/Select/Radio",
	"SourceField":  "Tpl.BindSourceField, the floor under Image",
}

// props reads the prop writes a surface declares: a method whose FIRST
// PARAMETER IS THE NODE it writes to, filed under its prop AND its flavor,
// because a prop reachable in one flavor only is still a hole.
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

// Over sources rather than over the package, so the negative test below can
// ask it about a doctored copy.
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

// The generated one is read from the EMITTER, the one place its checked-in
// outputs all agree.
const (
	baseDecl    = `func \(t \*Tpl\) ((?:Set|Bind)[A-Za-z0-9]*)`
	sumCaseDecl = `func \(sc SumCase\[K, V\]\) ((?:Set|Bind)[A-Za-z0-9]*)`
	// The generated row drops the Bind prefix on its sourced flavors, as its
	// constructors do (Label(f), not LabelBound), so a bare name is sourced.
	genRowDecl = `\tw\("func \(r %sRow\) ((?:Set|Bind)?[A-Za-z0-9]*)`
)

func TestEveryTemplatePropReachesTheSealedSurfaces(t *testing.T) {
	base := readSource(t, "app.go") + readSource(t, "records.go")
	arm := readSource(t, "sums.go")
	gen := readSource(t, "../../cmd/kaya-gen/main.go")

	if n := len(props(base, baseDecl)); n < 10 {
		t.Fatalf("found %d prop writes on *Tpl, fewer than the 10 the zone is "+
			"known to carry (grow, accepts, role and inset as constants, the "+
			"a11y trio in both flavors) — the pattern has stopped seeing the "+
			"surface it exists to compare against", n)
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

	for _, p := range []struct {
		what, src, decl, cut, want string
	}{
		{"SumCase", arm, sumCaseDecl,
			"func (sc SumCase[K, V]) SetAccepts(n Node, kinds ...string) { sc.t.SetAccepts(n, kinds...) }\n",
			"Accepts (const)"},
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

// A REGISTRATION IS ADDITIVE ACROSS OCCURRENCE KINDS (docs/traps.md): a
// widget is legitimately a drag source AND a drop target, and a stamped
// row answers its drop and its drag_ended through two registrations on
// one template node. A map from id to ONE closure loses the first.
func TestADropAndADragEndedRegistrationCoexistOnOneID(t *testing.T) {
	app := NewApp()
	w := Widget{id: 7}
	n := Node{id: 7}
	app.OnDrop(w, func(*Tx, Dropped) {})
	app.OnDragEnded(w, func(*Tx, Op) {})
	app.OnDropNode(n, func(*Tx, []any, Dropped) {})
	app.OnDragEndedNode(n, func(*Tx, []any, Op) {})
	for what, present := range map[string]bool{
		"widget drop":   app.widgetDrops[w.id] != nil,
		"widget end":    app.dragEnded[w.id] != nil,
		"node drop":     app.nodeDrops[n.id] != nil,
		"node drag end": app.nodeDragEnded[n.id] != nil,
	} {
		if !present {
			t.Errorf("the %s registration was lost — a second registration on "+
				"one id replaced the first (docs/traps.md)", what)
		}
	}
}
