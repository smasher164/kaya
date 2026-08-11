// Sum-typed collections: the sealed marker interface is the sum, the
// prototype structs are its constructors, and elimination happens the
// Go way — a type switch where the guest holds the value, a record of
// typed case arms where the core does. Totality of the template arms
// is the scene's declaration-time check (Go has no exhaustiveness to
// borrow); mutation is witnessed — a field write names the constructor
// the caller matched, and the model refuses if the entry disagrees.

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
// order — each prototype's struct is that constructor's schema. A
// one-constructor sum is what CollectionOf already declares; ask for
// at least two.
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
	// An undone entry names its own constructor: the variant is the
	// discriminant the forward insert witnessed, so the mirror gets the
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

// Insert witnesses the value's own constructor onto the wire. Through
// Tx.insertEntry, the one insert path — so an explicit numeric key is
// shown to the fresh-key minter here exactly as it is on the untyped and
// record surfaces.
func (c SumCollection[K, T]) Insert(tx *Tx, key K, value T) {
	variant, info := c.variantOf(reflect.TypeOf(value))
	tx.insertEntry(c.Collection, key, variant, value, info.values(value))
}

// handle is the plain (collection, path) handle behind this typed
// collection: what the minter counts per (see FreshCollection).
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
// constructor structs behind T — a type switch eliminates them.
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

// Get is the entry's current value — the scrutinee for the type
// switch that precedes a patch. ok is false for a missing key.
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

// UpdateField is the witnessed field write: V names the constructor
// the caller just matched (the type switch is the refinement), the
// selector names the field, and the model refuses if the entry holds
// a different constructor — so the guard is checked, not trusted.
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
		// Through the encoder, like the record path and every other
		// language's sum path: a blob field registers its bytes at
		// encode time (handles are single-submit); scalars pass
		// through unchanged.
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
// arm's body writes are constructor V's blueprint. The scene holds
// the arms to totality at template_end — a missing constructor is a
// startup error naming it, and an empty body renders one as nothing,
// explicitly. The head token (Case[Note]) is the arm's match label —
// keep it; Go function literals cannot infer their parameter types,
// so the SumCase carries the Tpl to keep the closure down to the one
// parameter the head already named.
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

// The arm's construction vocabulary. IT IS THE WHOLE OF ONE, because an
// arm body holds a SumCase and nothing else — the *Tpl behind it is
// unexported, deliberately, so an arm cannot reach past its own
// refinement. That makes this surface the one place where a missing
// constructor is not a matter of ergonomics: before 2026-08-10 a sum
// arm could build a label, a checkbox and two containers, and there was
// no spelling for an entry inside one at any tier, floor included.
//
// Every constructor here is its *Tpl twin with the arm's refinement
// substituted for the source: where the base surface takes a signal or
// a resolved token, this one takes the FIELD SELECTOR, resolved against
// constructor V's own schema — that is what an arm is for, and a
// constant there would throw the match away. Structure and captions,
// which name the prototype rather than the row, stay plain values and
// pass straight through. Handlers are co-located because the receiver's
// K types the stamped copy's key.

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

// LabelText is a label with constant text — the arm's chrome, the
// caption that says which constructor this is.
func (sc SumCase[K, V]) LabelText(text string) Node { return sc.t.LabelText(text) }

// Label bound to the field the selector names.
func (sc SumCase[K, V]) Label(sel func(*V) *string) Node {
	n := sc.t.Widget(KindLabel)
	sc.t.BindTextField(n, 0, FieldBy(sel))
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
// names — the row's own noun on the button that acts on it.
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
// its text (Tpl.Entry has the contract). EntryBound seeds from a field.
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

// Image bound to the blob field the selector names — the arm's own
// picture, one per stamped copy.
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

// Slider over min..max whose position is the field the selector names,
// with its change handler co-located. The range describes the prototype
// and stays constant; see Tpl.Slider.
func (sc SumCase[K, V]) Slider(min, max float64, sel func(*V) *float64, onChange func(*Tx, K, float64)) Node {
	n := sc.t.Widget(KindSlider)
	sc.t.tx.emit(TxSetMin(n.id, min))
	sc.t.tx.emit(TxSetMax(n.id, max))
	sc.t.BindValueField(n, 0, FieldBy(sel))
	sc.onValue(n, onChange)
	return n
}

// Select over fixed options whose 0-based index is the field the
// selector names, with its pick handler co-located. The option list
// stays constant (Tpl.Select says why it cannot be otherwise) and the
// index field is float64 (Tpl.BindValueField says why).
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
