// Sum-typed collections: the sealed marker interface is the sum, the
// prototype structs are its constructors. DESIGN.md, Sum-typed elements.

package kaya

import (
	"fmt"
	"reflect"
)

type sumVariant struct {
	typ  reflect.Type
	info *recordInfo
}

// SumCollection is a Collection whose entries are one of several
// constructor structs behind the sealed interface T, keyed by K.
type SumCollection[K Key, T any] struct {
	Collection
	variants []sumVariant
}

// SumOf declares a sum collection: one variant per prototype, in
// order — each prototype's struct is that constructor's schema.
func SumOf[K Key, T any](tx *Tx, prototypes ...T) SumCollection[K, T] {
	if len(prototypes) < 2 {
		panic("kaya: a sum needs two constructors or more (CollectionOf declares a record)")
	}
	variants := make([]sumVariant, len(prototypes))
	schemas := make([][]uint32, len(prototypes))
	for i, p := range prototypes {
		t := reflect.TypeOf(p)
		info := recordInfoOfType(t)
		variants[i] = sumVariant{t, info}
		schemas[i] = info.schema
	}
	tx.app.c.collection++
	c := Collection{id: tx.app.c.collection}
	tx.app.registerCollection(c.id)
	// An undone entry names its own constructor, so the mirror gets the
	// same struct back behind T.
	tx.app.shapes[c.id] = undoShape{
		key: restoreKey[K](),
		value: func(variant uint32, fields []any) any {
			if int(variant) >= len(variants) {
				panic(fmt.Sprintf(
					"kaya: an undone entry names variant %d of a %d-constructor sum",
					variant, len(variants)))
			}
			v := variants[variant]
			return restoreRecord(v.typ, v.info, fields)
		},
	}
	tx.emit(TxCreateCollection(c.id, schemas))
	return SumCollection[K, T]{c, variants}
}

// variantOf is the discriminant of a constructor type.
func (c SumCollection[K, T]) variantOf(t reflect.Type) (uint32, *recordInfo) {
	for i, v := range c.variants {
		if v.typ == t {
			return uint32(i), v.info
		}
	}
	panic(fmt.Sprintf("kaya: %v is not a constructor of this sum", t))
}

// Insert witnesses the value's own constructor onto the wire, through
// Tx.insertEntry — the one insert path, so an explicit numeric key
// reaches the fresh-key minter here too.
func (c SumCollection[K, T]) Insert(tx *Tx, key K, value T) {
	variant, info := c.variantOf(reflect.TypeOf(value))
	tx.insertEntry(c.Collection, key, variant, value, info.values(value))
}

// handle is the plain (collection, path) handle the minter counts per.
func (c SumCollection[K, T]) handle() Collection { return c.Collection }

// Update replaces a record wholesale; a different constructor than the
// entry's current one restamps its copy in place.
func (c SumCollection[K, T]) Update(tx *Tx, key K, value T) {
	variant, info := c.variantOf(reflect.TypeOf(value))
	tx.app.modelSet(c.id, c.path, key, value)
	tx.emit(
		TxCollectionUpdate(c.id, c.path, key, variant, info.values(value)))
	tx.recomputeDerived(c.id, c.path)
}

// Items is the typed model, in insertion order; the values are the
// constructor structs behind T.
func (c SumCollection[K, T]) Items(tx *Tx) []RecordEntry[K, T] {
	tx.app.guardMirrorRead()
	in := tx.app.instanceOf(c.id, c.path)
	if in == nil {
		return nil
	}
	out := make([]RecordEntry[K, T], len(in.entries))
	for i, e := range in.entries {
		out[i] = RecordEntry[K, T]{e.Key.(K), e.Value.(T)}
	}
	return out
}

// Get is the entry's current value. ok is false for a missing key.
func (c SumCollection[K, T]) Get(tx *Tx, key K) (T, bool) {
	tx.app.guardMirrorRead()
	var zero T
	in := tx.app.instanceOf(c.id, c.path)
	if in == nil {
		return zero, false
	}
	for _, e := range in.entries {
		if e.Key == key {
			return e.Value.(T), true
		}
	}
	return zero, false
}

// UpdateField is the witnessed field write: V names the constructor the
// caller just matched, and the model refuses if the entry holds another.
func (c SumCollection[K, T]) UpdateField[V any, F any](tx *Tx, key K, sel func(*V) *F, value F) {
	variant, info := c.variantOf(reflect.TypeFor[V]())
	in := tx.app.instanceOf(c.id, c.path)
	if in == nil {
		panic("kaya: update of a missing instance")
	}
	f := FieldBy(sel)
	for i := range in.entries {
		if in.entries[i].Key != key {
			continue
		}
		record, ok := in.entries[i].Value.(V)
		if !ok {
			panic(fmt.Sprintf(
				"kaya: update_field witnessed %v but key %v holds %v",
				reflect.TypeFor[V](), key, reflect.TypeOf(in.entries[i].Value)))
		}
		rv := reflect.ValueOf(&record).Elem()
		rv.Field(info.indexes[f.index]).Set(reflect.ValueOf(value))
		tx.app.modelSet(c.id, c.path, key, any(record).(T))
		// Through the encoder: a blob field registers its bytes at
		// encode time (handles are single-submit).
		tx.emit(
			TxCollectionUpdateField(c.id, c.path, key, f.index, variant, info.encode(f.index, value)))
		tx.recomputeDerived(c.id, c.path)
		return
	}
	panic(fmt.Sprintf("kaya: update of missing key %v", key))
}

// Derive is the collection-derived signal, over the sum's entries.
func (c SumCollection[K, T]) Derive[V Scalar](tx *Tx, compute func(items []RecordEntry[K, T]) V) Signal[V] {
	s := tx.Signal(compute(c.Items(tx)))
	tx.pendingDerived = append(tx.pendingDerived, pendingDerived{c.id, func(tx *Tx) {
		tx.Write(s, compute(c.Items(tx)))
	}})
	return s
}

// Case declares one arm of the template eliminator: the records the
// arm's body writes are constructor V's blueprint. The head token
// (Case[Note]) is the arm's match label — Go function literals cannot
// infer parameter types, so the SumCase carries the Tpl.
func (c SumCollection[K, T]) Case[V any](t *Tpl, arm func(SumCase[K, V])) {
	variant, info := c.variantOf(reflect.TypeFor[V]())
	t.tx.emit(TxVariantCase(variant))
	arm(SumCase[K, V]{t: t, info: info})
}

// SumCase is the arm's refined vocabulary: field selectors resolve
// against constructor V's schema, on the arm's own template recorder.
type SumCase[K Key, V any] struct {
	t    *Tpl
	info *recordInfo
}

// The arm's construction vocabulary, and it must be the WHOLE of one:
// the *Tpl behind this surface is unexported, so a constructor missing
// here cannot be spelled at any tier, floor included.

// Row is the template container sugar, on the arm's own recorder:
// the body's constructors parent into it ambiently.
func (sc SumCase[K, V]) Row(body func()) Node { return sc.t.Row(body) }

// Column likewise.
func (sc SumCase[K, V]) Column(body func()) Node { return sc.t.Column(body) }

// Scroll is the arm's viewport over exactly one child; see Tpl.Scroll.
func (sc SumCase[K, V]) Scroll(body func()) Node { return sc.t.Scroll(body) }

// Grid lays the arm's children row-major into columns columns; the
// count describes the prototype, so it is constant (see Tpl.Grid).
func (sc SumCase[K, V]) Grid(columns int, body func()) Node { return sc.t.Grid(columns, body) }

// Spacer is the empty grown column between an arm's siblings.
func (sc SumCase[K, V]) Spacer() Node { return sc.t.Spacer() }

// LabelText is a label with constant text.
func (sc SumCase[K, V]) LabelText(text string) Node { return sc.t.LabelText(text) }

// Label bound to the field the selector names.
func (sc SumCase[K, V]) Label(sel func(*V) *string) Node {
	n := sc.t.Widget(KindLabel)
	sc.t.BindTextField(n, 0, FieldBy(sel))
	return n
}

// HeadingText is LabelText wearing the heading role, in one word.
func (sc SumCase[K, V]) HeadingText(text string) Node { return sc.t.HeadingText(text) }

// Heading is Label wearing the heading role.
func (sc SumCase[K, V]) Heading(sel func(*V) *string) Node {
	n := sc.Label(sel)
	sc.t.SetRole(n, RoleHeading)
	return n
}

// CaptionText is LabelText wearing the caption role — the footnote under
// the content it explains.
func (sc SumCase[K, V]) CaptionText(text string) Node { return sc.t.CaptionText(text) }

// Caption is Label wearing the caption role.
func (sc SumCase[K, V]) Caption(sel func(*V) *string) Node {
	n := sc.Label(sel)
	sc.t.SetRole(n, RoleCaption)
	return n
}

// Checkbox bound to the field the selector names, with its toggle
// handler co-located (stamped key first, per the template contract).
func (sc SumCase[K, V]) Checkbox(sel func(*V) *bool, onToggle func(*Tx, K, bool)) Node {
	n := sc.t.Widget(KindCheckbox)
	sc.t.BindCheckedField(n, 0, FieldBy(sel))
	if onToggle != nil {
		sc.t.tx.app.OnToggleNode(n, func(tx *Tx, keys []any, checked bool) {
			onToggle(tx, keys[0].(K), checked)
		})
	}
	return n
}

// Button with a constant caption and its click handler co-located.
func (sc SumCase[K, V]) Button(text string, onClick func(*Tx, K)) Node {
	n := sc.t.Button(text)
	sc.onClick(n, onClick)
	return n
}

// ButtonBound is Button with the caption from the field the selector
// names.
func (sc SumCase[K, V]) ButtonBound(sel func(*V) *string, onClick func(*Tx, K)) Node {
	n := sc.t.Widget(KindButton)
	sc.t.BindTextField(n, 0, FieldBy(sel))
	sc.onClick(n, onClick)
	return n
}

func (sc SumCase[K, V]) onClick(n Node, onClick func(*Tx, K)) {
	if onClick == nil {
		return
	}
	sc.t.tx.app.OnClickNode(n, func(tx *Tx, keys []any) { onClick(tx, keys[0].(K)) })
}

// Entry is an EMPTY text field with its change handler co-located:
// uncontrolled, so every stamped copy of this arm starts empty and owns
// its text (Tpl.Entry has the contract).
func (sc SumCase[K, V]) Entry(onChange func(*Tx, K, string)) Node {
	n := sc.t.Widget(KindEntry)
	sc.onChange(n, onChange)
	return n
}

// EntryBound seeds each copy's field from the field the selector names;
// the copy owns its text afterwards (see Tpl.EntryBound).
func (sc SumCase[K, V]) EntryBound(sel func(*V) *string, onChange func(*Tx, K, string)) Node {
	n := sc.t.Widget(KindEntry)
	sc.t.BindTextField(n, 0, FieldBy(sel))
	sc.onChange(n, onChange)
	return n
}

// Textarea is Entry's contract over the multi-line control.
func (sc SumCase[K, V]) Textarea(onChange func(*Tx, K, string)) Node {
	n := sc.t.Widget(KindTextarea)
	sc.onChange(n, onChange)
	return n
}

// TextareaBound is EntryBound one kind over.
func (sc SumCase[K, V]) TextareaBound(sel func(*V) *string, onChange func(*Tx, K, string)) Node {
	n := sc.t.Widget(KindTextarea)
	sc.t.BindTextField(n, 0, FieldBy(sel))
	sc.onChange(n, onChange)
	return n
}

func (sc SumCase[K, V]) onChange(n Node, onChange func(*Tx, K, string)) {
	if onChange == nil {
		return
	}
	sc.t.tx.app.OnChangeNode(n, func(tx *Tx, keys []any, text string) {
		onChange(tx, keys[0].(K), text)
	})
}

// Image bound to the blob field the selector names.
func (sc SumCase[K, V]) Image(sel func(*V) *[]byte) Node {
	n := sc.t.Widget(KindImage)
	sc.t.BindSourceField(n, 0, FieldBy(sel))
	return n
}

// Progress bound to the fraction field the selector names: display-only
// (0..=1, domain-checked at the root).
func (sc SumCase[K, V]) Progress(sel func(*V) *float64) Node {
	n := sc.t.Widget(KindProgress)
	sc.t.BindValueField(n, 0, FieldBy(sel))
	return n
}

// Slider over min..max whose position is the field the selector names.
// The range describes the prototype and stays constant (Tpl.Slider).
func (sc SumCase[K, V]) Slider(min, max float64, sel func(*V) *float64, onChange func(*Tx, K, float64)) Node {
	n := sc.t.Widget(KindSlider)
	sc.t.tx.emit(TxSetMin(n.id, min))
	sc.t.tx.emit(TxSetMax(n.id, max))
	sc.t.BindValueField(n, 0, FieldBy(sel))
	sc.onValue(n, onChange)
	return n
}

// Select over fixed options whose 0-based index is the field the
// selector names. The option list stays constant (Tpl.Select) and the
// index field is float64 (Tpl.BindValueField).
func (sc SumCase[K, V]) Select(options []string, sel func(*V) *float64, onSelect func(*Tx, K, int)) Node {
	return sc.choice(KindSelect, options, sel, onSelect)
}

// Radio is Select's inline presentation: same children, same index.
func (sc SumCase[K, V]) Radio(options []string, sel func(*V) *float64, onSelect func(*Tx, K, int)) Node {
	return sc.choice(KindRadio, options, sel, onSelect)
}

func (sc SumCase[K, V]) choice(kind uint32, options []string, sel func(*V) *float64, onSelect func(*Tx, K, int)) Node {
	n := sc.t.choiceOf(kind, options)
	sc.t.BindValueField(n, 0, FieldBy(sel))
	if onSelect != nil {
		sc.onValue(n, func(tx *Tx, key K, v float64) { onSelect(tx, key, int(v)) })
	}
	return n
}

func (sc SumCase[K, V]) onValue(n Node, onChange func(*Tx, K, float64)) {
	if onChange == nil {
		return
	}
	sc.t.tx.app.OnValueChangedNode(n, func(tx *Tx, keys []any, v float64) {
		onChange(tx, keys[0].(K), v)
	})
}

// The arm's PROPS, forwarded one at a time for the constructors' reason:
// a prop missing here cannot be spelled at any tier.

// SetGrow weights this arm's node within its stamped row or column.
func (sc SumCase[K, V]) SetGrow(n Node, weight float64) { sc.t.SetGrow(n, weight) }

// SetStep is the granularity a slider this arm stamps rests on; const
// only, like the range (Tpl.SetStep).
func (sc SumCase[K, V]) SetStep(n Node, step float64) { sc.t.SetStep(n, step) }

// SetTickSpacing is the distance between that slider's drawn ticks
// (Tpl.SetTickSpacing).
func (sc SumCase[K, V]) SetTickSpacing(n Node, spacing float64) {
	sc.t.SetTickSpacing(n, spacing)
}

// SetA11yID gives every stamped copy of this arm the same identifier.
func (sc SumCase[K, V]) SetA11yID(n Node, id string) { sc.t.SetA11yID(n, id) }

// BindA11yID takes the identifier from the field the selector names.
func (sc SumCase[K, V]) BindA11yID(n Node, sel func(*V) *string) {
	sc.t.BindA11yID(n, FieldBy(sel))
}

// SetA11yLabel gives every stamped copy of this arm the same spoken
// name.
func (sc SumCase[K, V]) SetA11yLabel(n Node, label string) { sc.t.SetA11yLabel(n, label) }

// BindA11yLabel speaks the field the selector names, per copy.
func (sc SumCase[K, V]) BindA11yLabel(n Node, sel func(*V) *string) {
	sc.t.BindA11yLabel(n, FieldBy(sel))
}

// SetA11yHint says what activating a copy does; activation kinds only
// (Tpl.SetA11yHint).
func (sc SumCase[K, V]) SetA11yHint(n Node, hint string) { sc.t.SetA11yHint(n, hint) }

// BindA11yHint takes the hint from the field the selector names.
func (sc SumCase[K, V]) BindA11yHint(n Node, sel func(*V) *string) {
	sc.t.BindA11yHint(n, FieldBy(sel))
}

// SetHelp gives every stamped copy of this arm the same help text
// (Tpl.SetHelp).
func (sc SumCase[K, V]) SetHelp(n Node, text string) { sc.t.SetHelp(n, text) }

// BindHelp takes the help text from the field the selector names.
func (sc SumCase[K, V]) BindHelp(n Node, sel func(*V) *string) {
	sc.t.BindHelp(n, FieldBy(sel))
}

// SetFill gives every stamped copy of this arm the same cross-axis
// stretch (Tpl.SetFill; docs/layout-knobs-plan.md §1).
func (sc SumCase[K, V]) SetFill(n Node, on bool) { sc.t.SetFill(n, on) }

// SetColumnsAuto gives every stamped grid of this arm as many columns as
// fit its width at minWidth DIP each (Tpl.SetColumnsAuto;
// docs/layout-knobs-plan.md §3).
func (sc SumCase[K, V]) SetColumnsAuto(n Node, minWidth float64) { sc.t.SetColumnsAuto(n, minWidth) }

// SetWrap makes every stamped copy of this arm's row flow onto new lines
// (Tpl.SetWrap; docs/layout-knobs-plan.md §2).
func (sc SumCase[K, V]) SetWrap(n Node, on bool) { sc.t.SetWrap(n, on) }

// SetAccepts declares what a copy of this arm takes from a paste; const
// only, and the declaration App.OnPasteNode needs (Tpl.SetAccepts).
func (sc SumCase[K, V]) SetAccepts(n Node, kinds ...string) { sc.t.SetAccepts(n, kinds...) }

// Draggable begins the drag declaration every copy of this arm is born
// with (Tpl.Draggable); a copy's own payload is Tx.DraggableAt.
func (sc SumCase[K, V]) Draggable(n Node) TplDragRef { return sc.t.Draggable(n) }

// SetDropTarget declares that every copy of this arm receives drops with
// these operations, taking what SetAccepts names (Tpl.SetDropTarget).
func (sc SumCase[K, V]) SetDropTarget(n Node, ops ...Op) { sc.t.SetDropTarget(n, ops...) }

// SetRole declares what a copy of this arm MEANS; const only, since an
// arm is the shape its rows share (Tpl.SetRole).
func (sc SumCase[K, V]) SetRole(n Node, role int64) { sc.t.SetRole(n, role) }

// SetInset pads a container this arm stamps; containers only, const
// only (Tpl.SetInset).
func (sc SumCase[K, V]) SetInset(n Node, pad float64) { sc.t.SetInset(n, pad) }
