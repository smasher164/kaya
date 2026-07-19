// Records: the struct is the schema. CollectionOf reflects over T once
// at declaration — exported wire-typed fields (string, bool, int64,
// float64) in declaration order become the schema; anything else (a
// handler, say) is guest-only, living in the model and never reaching
// the wire. The precomputed field indexes make the per-insert path a
// loop over cached accessors, and one declaration drives the schema,
// the conversions, and the field tokens, so none can drift.
package kaya

import (
	"fmt"
	"reflect"
	"sync"
)

// Field is a typed projection: one field of a record type, by wire
// position. The type parameter pins the Go type, so BindCheckedField
// rejects a Field[string] at compile time — the earliest of the three
// agreeing layers (the scene re-checks at declaration, the core's
// setters at write).
type Field[V any] struct{ index uint32 }

// FieldAt mints the token at a known wire index, for generated code
// only (kaya-gen computes indices from the struct declaration;
// hand-written code should use the checked selector forms instead —
// a hand-minted index is unchecked).
func FieldAt[V any](index uint32) Field[V] { return Field[V]{index: index} }

// Key is the collection-key constraint: the protocol admits string and
// int64 identities (a float is not an identity; a bool key is a When
// in disguise).
type Key interface {
	~string | ~int64
}

// RecordCollection is a Collection whose entries are T records keyed
// by K — the key type rides the handle, so inserts, reads, and handler
// keys are typed end to end (methods lean on the receiver's type
// parameters; Go still has no parameterized methods as of 1.26). The
// plain Collection rides along embedded, so ForEach and At take it
// unchanged.
type RecordCollection[K Key, T any] struct {
	Collection
	info *recordInfo
}

// RecordEntry is one (key, record) pair of the typed model.
type RecordEntry[K Key, T any] struct {
	Key   K
	Value T
}

type recordInfo struct {
	schema  []uint32
	indexes []int // struct field index per wire field, wire order
}

func wireTag(t reflect.Type) (uint32, bool) {
	switch t.Kind() {
	case reflect.Bool:
		return ValueBool, true
	case reflect.Int64:
		return ValueI64, true
	case reflect.Float64:
		return ValueF64, true
	case reflect.String:
		return ValueStr, true
	}
	return 0, false
}

// One reflection walk per record type, ever — UpdateField and the
// template constructors resolve projections per event, so the walk
// must not re-run there.
var recordInfos sync.Map // reflect.Type -> *recordInfo

func recordInfoOf[T any]() *recordInfo {
	return recordInfoOfType(reflect.TypeFor[T]())
}

func recordInfoOfType(t reflect.Type) *recordInfo {
	if cached, ok := recordInfos.Load(t); ok {
		return cached.(*recordInfo)
	}
	if t.Kind() != reflect.Struct {
		panic(fmt.Sprintf("kaya: %v is not a struct", t))
	}
	info := &recordInfo{}
	for i := 0; i < t.NumField(); i++ {
		f := t.Field(i)
		if !f.IsExported() {
			continue
		}
		tag, ok := wireTag(f.Type)
		if !ok {
			continue // guest-only field
		}
		info.schema = append(info.schema, tag)
		info.indexes = append(info.indexes, i)
	}
	if len(info.schema) == 0 {
		panic(fmt.Sprintf("kaya: %v has no wire-typed fields", t))
	}
	recordInfos.Store(t, info)
	return info
}

// CollectionOf declares a collection of T records keyed by K; the
// struct is the schema. Returns the typed root handle.
func CollectionOf[K Key, T any](tx *Tx) RecordCollection[K, T] {
	info := recordInfoOf[T]()
	tx.app.c.collection++
	c := Collection{id: tx.app.c.collection}
	tx.app.registerCollection(c.id)
	tx.records = append(tx.records, TxCreateCollection(c.id, [][]uint32{info.schema}))
	return RecordCollection[K, T]{c, info}
}

// FieldBy is the field token for the field a projection selects:
// kaya.FieldBy(func(t *Todo) *bool { return &t.Done }). The projection
// is a real field access, so the name and type are compiler-checked
// and renames refactor with the code — no strings restating what the
// struct already declares. Resolution compares the projected address
// against each field's on a prototype, once, at declaration.
func FieldBy[T any, V any](project func(*T) *V) Field[V] {
	prototype := new(T)
	target := reflect.ValueOf(project(prototype)).Pointer()
	rv := reflect.ValueOf(prototype).Elem()
	info := recordInfoOf[T]()
	for wire, idx := range info.indexes {
		if rv.Field(idx).Addr().Pointer() == target {
			return Field[V]{uint32(wire)}
		}
	}
	panic(fmt.Sprintf("kaya: projection does not select a wire field of %v",
		reflect.TypeFor[T]()))
}

func (info *recordInfo) values(value any) []any {
	v := reflect.ValueOf(value)
	out := make([]any, len(info.indexes))
	for i, idx := range info.indexes {
		out[i] = v.Field(idx).Interface()
	}
	return out
}

// Insert a record; the model keeps the T itself, the wire carries its
// fields positionally.
func (c RecordCollection[K, T]) Insert(tx *Tx, key K, value T) {
	tx.app.modelSet(c.id, c.path, key, value)
	tx.records = append(tx.records, TxCollectionInsert(c.id, c.path, key, 0, c.info.values(value)))
	tx.recomputeDerived(c.id, c.path)
}

// Update replaces a record wholesale; UpdateField is the one-field way.
func (c RecordCollection[K, T]) Update(tx *Tx, key K, value T) {
	tx.app.modelSet(c.id, c.path, key, value)
	tx.records = append(tx.records, TxCollectionUpdate(c.id, c.path, key, 0, c.info.values(value)))
	tx.recomputeDerived(c.id, c.path)
}

// MoveBefore repositions an entry before another's: order is
// collection data, so the model reorders and the wire carries the
// same keys-only delta. Keys, never indices. A missing key or anchor
// panics at the call site — the same check the scene makes; moving an
// entry before itself is a no-op, and nothing travels.
func (c RecordCollection[K, T]) MoveBefore(tx *Tx, key, anchor K) {
	tx.MoveBefore(c.Collection, key, anchor)
}

// MoveToEnd repositions an entry at the end of its collection.
func (c RecordCollection[K, T]) MoveToEnd(tx *Tx, key K) {
	tx.MoveToEnd(c.Collection, key)
}

// MoveToFront repositions an entry at the front: sugar for MoveBefore
// the current first key, lowering to the same wire op.
func (c RecordCollection[K, T]) MoveToFront(tx *Tx, key K) {
	tx.MoveToFront(c.Collection, key)
}

// MoveAfter repositions an entry directly after another's: sugar for
// MoveBefore the anchor's successor (MoveToEnd when the anchor is
// last), lowering to the same wire op.
func (c RecordCollection[K, T]) MoveAfter(tx *Tx, key, anchor K) {
	tx.MoveAfter(c.Collection, key, anchor)
}

// Items is the typed model: what this guest wrote, in insertion order.
func (c RecordCollection[K, T]) Items(tx *Tx) []RecordEntry[K, T] {
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

// UpdateField sends one field's delta — the rest of the record never
// travels — and mutates the same field of the model's copy. A generic
// method (Go 1.27): V comes from the projection, K and T from the
// receiver. The projection is the field reference — no token to
// declare; hoist one with FieldBy if you prefer a name.
func (c RecordCollection[K, T]) UpdateField[V any](tx *Tx, key K, project func(*T) *V, value V) {
	c.UpdateFieldAt(tx, key, FieldBy(project), value)
}

// UpdateFieldAt is UpdateField over a pre-resolved token.
func (c RecordCollection[K, T]) UpdateFieldAt[V any](tx *Tx, key K, f Field[V], value V) {
	in := tx.app.instanceOf(c.id, c.path)
	if in == nil {
		panic("kaya: update of a missing instance")
	}
	for i := range in.entries {
		if in.entries[i].Key == key {
			record := in.entries[i].Value.(T)
			rv := reflect.ValueOf(&record).Elem()
			rv.Field(c.info.indexes[f.index]).Set(reflect.ValueOf(value))
			// Through modelSet so the journal snapshots the collection
			// before this transaction's first touch.
			tx.app.modelSet(c.id, c.path, key, record)
			break
		}
	}
	tx.records = append(tx.records, TxCollectionUpdateField(c.id, c.path, key, f.index, 0, value))
	tx.recomputeDerived(c.id, c.path)
}

// Derive returns a signal the binding recomputes from this
// collection's entries after every mutation, written into the same
// transaction — the items-left label with no handler remembering to
// update it. The compute is pure presentation: entries in, one value
// out; the core sees an ordinary signal (a Go 1.27 generic method).
func (c RecordCollection[K, T]) Derive[V Scalar](tx *Tx, compute func(items []RecordEntry[K, T]) V) Signal[V] {
	s := tx.Signal(compute(c.Items(tx)))
	tx.pendingDerived = append(tx.pendingDerived, pendingDerived{c.id, func(tx *Tx) {
		tx.Write(s, compute(c.Items(tx)))
	}})
	return s
}

// RecordPatch is typed field writes with the key spelled once:
// todos.Patch(tx, key).Set(done, true).Set(title, "x"). Each Set
// records one update_field — a patch is recorded writes, never a diff.
type RecordPatch[K Key, T any] struct {
	c   RecordCollection[K, T]
	tx  *Tx
	key K
}

// Patch opens a patch on one entry.
func (c RecordCollection[K, T]) Patch(tx *Tx, key K) RecordPatch[K, T] {
	return RecordPatch[K, T]{c, tx, key}
}

// Set writes the field the projection selects; chainable.
func (p RecordPatch[K, T]) Set[V any](project func(*T) *V, value V) RecordPatch[K, T] {
	p.c.UpdateField(p.tx, p.key, project, value)
	return p
}

// SetAt is Set over a pre-resolved token.
func (p RecordPatch[K, T]) SetAt[V any](f Field[V], value V) RecordPatch[K, T] {
	p.c.UpdateFieldAt(p.tx, p.key, f, value)
	return p
}

// BindTextField binds a label's text to one field of the element of
// the enclosing For; Field[string] only.
func (t *Tpl) BindTextField(n Node, level uint32, f Field[string]) {
	t.tx.records = append(t.tx.records, TxBindTextElement(n.id, level, f.index))
}

// Label creates a label bound to any addressable source: a constant,
// a signal, a field projection, or a pre-resolved token — the
// protocol's whole binding universe as one union-constrained argument
// (a Go 1.27 generic method; the type switch discriminates).
func (c RecordCollection[K, T]) Label[S interface {
	~string | Signal[string] | func(*T) *string | Field[string]
}](t *Tpl, src S) Node {
	n := t.Widget(KindLabel)
	switch v := any(src).(type) {
	case string:
		t.SetText(n, v)
	case Signal[string]:
		t.tx.records = append(t.tx.records, TxBindText(n.id, v.id))
	case func(*T) *string:
		t.BindTextField(n, 0, FieldBy(v))
	case Field[string]:
		t.BindTextField(n, 0, v)
	}
	return n
}

// Checkbox creates a checkbox bound to any addressable source, with
// its toggle handler (nil for none). The receiver's K types the
// handler's key — the copy the toggle came from (the depth-1 case;
// deeper nestings keep the []any path via OnToggleNode).
func (c RecordCollection[K, T]) Checkbox[S interface {
	~bool | Signal[bool] | func(*T) *bool | Field[bool]
}](t *Tpl, src S, onToggle func(*Tx, K, bool)) Node {
	n := t.Widget(KindCheckbox)
	switch v := any(src).(type) {
	case bool:
		t.tx.records = append(t.tx.records, TxSetChecked(n.id, v))
	case Signal[bool]:
		t.tx.records = append(t.tx.records, TxBindChecked(n.id, v.id))
	case func(*T) *bool:
		t.BindCheckedField(n, 0, FieldBy(v))
	case Field[bool]:
		t.BindCheckedField(n, 0, v)
	}
	if onToggle != nil {
		t.tx.app.OnToggleNode(n, func(tx *Tx, keys []any, checked bool) {
			onToggle(tx, keys[0].(K), checked)
		})
	}
	return n
}

// BindCheckedField binds a checkbox's state to one field of the
// element; Field[bool] only.
func (t *Tpl) BindCheckedField(n Node, level uint32, f Field[bool]) {
	t.tx.records = append(t.tx.records, TxBindCheckedElement(n.id, level, f.index))
}
