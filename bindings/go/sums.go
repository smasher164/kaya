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
	tx.records = append(tx.records, TxCreateCollection(c.id, schemas))
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

// Insert witnesses the value's own constructor onto the wire.
func (c SumCollection[K, T]) Insert(tx *Tx, key K, value T) {
	variant, info := c.variantOf(reflect.TypeOf(value))
	tx.app.modelSet(c.id, c.path, key, value)
	tx.records = append(tx.records,
		TxCollectionInsert(c.id, c.path, key, variant, info.values(value)))
	tx.recomputeDerived(c.id, c.path)
}

// Update replaces a record wholesale; a different constructor than the
// entry's current one restamps its copy in place.
func (c SumCollection[K, T]) Update(tx *Tx, key K, value T) {
	variant, info := c.variantOf(reflect.TypeOf(value))
	tx.app.modelSet(c.id, c.path, key, value)
	tx.records = append(tx.records,
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
		tx.records = append(tx.records,
			TxCollectionUpdateField(c.id, c.path, key, f.index, variant, value))
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
	t.tx.records = append(t.tx.records, TxVariantCase(variant))
	arm(SumCase[K, V]{t: t, info: info})
}

// SumCase is the arm's refined vocabulary: field selectors resolve
// against constructor V's schema, on the arm's own template recorder.
type SumCase[K Key, V any] struct {
	t    *Tpl
	info *recordInfo
}

// Row is the template container sugar, on the arm's own recorder:
// the body's constructors parent into it ambiently.
func (sc SumCase[K, V]) Row(body func()) Node { return sc.t.Row(body) }

// Column likewise.
func (sc SumCase[K, V]) Column(body func()) Node { return sc.t.Column(body) }

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
