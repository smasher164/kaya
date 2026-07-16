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
)

// Field is a typed projection: one field of a record type, by wire
// position. The type parameter pins the Go type, so BindCheckedField
// rejects a Field[string] at compile time — the earliest of the three
// agreeing layers (the scene re-checks at declaration, the core's
// setters at write).
type Field[V any] struct{ index uint32 }

// RecordCollection is a Collection whose entries are T records. The
// plain Collection rides along embedded, so ForEach and At take it
// unchanged.
type RecordCollection[T any] struct {
	Collection
	info *recordInfo
}

// RecordEntry is one (key, record) pair of the typed model.
type RecordEntry[T any] struct {
	Key   any
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

func recordInfoOf[T any]() *recordInfo {
	t := reflect.TypeFor[T]()
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
	return info
}

// CollectionOf declares a collection of T records; the struct is the
// schema. Returns the typed root handle.
func CollectionOf[T any](tx *Tx) RecordCollection[T] {
	info := recordInfoOf[T]()
	tx.app.c.collection++
	c := Collection{id: tx.app.c.collection}
	tx.app.registerCollection(c.id)
	tx.records = append(tx.records, TxCreateCollection(c.id, info.schema))
	return RecordCollection[T]{c, info}
}

// FieldOf is the field token for T's field `name`, checked against V
// at declaration time (a wrong name or type panics at startup, not in
// a handler). Bind it or update through it.
func FieldOf[T any, V any](name string) Field[V] {
	t := reflect.TypeFor[T]()
	sf, ok := t.FieldByName(name)
	if !ok {
		panic(fmt.Sprintf("kaya: %v has no field %q", t, name))
	}
	if sf.Type != reflect.TypeFor[V]() {
		panic(fmt.Sprintf("kaya: %v.%s is %v, not %v", t, name, sf.Type, reflect.TypeFor[V]()))
	}
	info := recordInfoOf[T]()
	for wire, idx := range info.indexes {
		if t.Field(idx).Name == name {
			return Field[V]{uint32(wire)}
		}
	}
	panic(fmt.Sprintf("kaya: %v.%s is not a wire field", t, name))
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
func (c RecordCollection[T]) Insert(tx *Tx, key any, value T) {
	tx.app.modelSet(c.id, c.path, key, value)
	tx.records = append(tx.records, TxCollectionInsert(c.id, c.path, key, c.info.values(value)))
}

// Update replaces a record wholesale; UpdateField is the one-field way.
func (c RecordCollection[T]) Update(tx *Tx, key any, value T) {
	tx.app.modelSet(c.id, c.path, key, value)
	tx.records = append(tx.records, TxCollectionUpdate(c.id, c.path, key, c.info.values(value)))
}

// Items is the typed model: what this guest wrote, in insertion order.
func (c RecordCollection[T]) Items(tx *Tx) []RecordEntry[T] {
	in := tx.app.instanceOf(c.id, c.path)
	if in == nil {
		return nil
	}
	out := make([]RecordEntry[T], len(in.entries))
	for i, e := range in.entries {
		out[i] = RecordEntry[T]{e.Key, e.Value.(T)}
	}
	return out
}

// UpdateField sends one field's delta — the rest of the record never
// travels — and mutates the same field of the model's copy.
func UpdateField[T any, V any](tx *Tx, c RecordCollection[T], key any, f Field[V], value V) {
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
	tx.records = append(tx.records, TxCollectionUpdateField(c.id, c.path, key, f.index, value))
}

// BindTextField binds a label's text to one field of the element of
// the enclosing For; Field[string] only.
func (t *Tpl) BindTextField(n Node, level uint32, f Field[string]) {
	t.tx.records = append(t.tx.records, TxBindTextElement(n.id, level, f.index))
}

// BindCheckedField binds a checkbox's state to one field of the
// element; Field[bool] only.
func (t *Tpl) BindCheckedField(n Node, level uint32, f Field[bool]) {
	t.tx.records = append(t.tx.records, TxBindCheckedElement(n.id, level, f.index))
}
