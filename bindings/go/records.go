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
	case reflect.Slice:
		// A []byte field is the blob channel: encoded image bytes,
		// registered with the core at encode time.
		if t.Elem().Kind() == reflect.Uint8 {
			return ValueBlob, true
		}
	}
	return 0, false
}

// blobWire registers a blob's bytes at encode time and returns the
// wire handle. Handles are single-submit, so every operation that
// carries blob bytes re-registers: one copy into core memory per
// write; the model keeps the guest's own bytes. The clear-error
// guard: anything but a byte slice in a blob position fails here, by
// name, instead of deep in the wire encoder.
func blobWire(v any) BlobHandle {
	rv := reflect.ValueOf(v)
	if rv.Kind() != reflect.Slice || rv.Type().Elem().Kind() != reflect.Uint8 {
		panic(fmt.Sprintf(
			"kaya: a blob (image source) takes []byte, not %T — text belongs on a label", v))
	}
	return BlobHandle(RegisterBlob(rv.Bytes()))
}

// scalarWire is the signal-value encode step: byte slices become
// registered blob handles (see blobWire); every other scalar rides
// the record as is.
func scalarWire(v any) any {
	if rv := reflect.ValueOf(v); rv.Kind() == reflect.Slice && rv.Type().Elem().Kind() == reflect.Uint8 {
		return blobWire(v)
	}
	return v
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
	// How an undone entry of this collection becomes a T again: the
	// payload is wire values, the mirror holds records, and this
	// declaration is the only place that knows both.
	tx.app.shapes[c.id] = undoShape{
		key: restoreKey[K](),
		value: func(_ uint32, fields []any) any {
			return restoreRecord(reflect.TypeFor[T](), info, fields)
		},
	}
	tx.emit(TxCreateCollection(c.id, [][]uint32{info.schema}))
	return RecordCollection[K, T]{c, info}
}

// restoreKey coerces an undone entry's wire key to the key type this
// collection's model holds: the wire has string and int64, a guest may
// have declared a named type over either, and the mirror compares keys
// with == over boxed values, where string("a") and ID("a") differ.
func restoreKey[K Key]() func(any) any {
	want := reflect.TypeFor[K]()
	return func(key any) any {
		v := reflect.ValueOf(key)
		if !v.IsValid() || v.Type() == want || !v.CanConvert(want) {
			return key
		}
		return v.Convert(want).Interface()
	}
}

// restoreRecord rebuilds one record from an undone entry's wire fields,
// positionally, through the same field indexes the forward encode uses.
// A field the payload cannot fill is a broken encoder, not bad input,
// so it panics naming the field rather than leaving a half-built record
// in the mirror.
func restoreRecord(t reflect.Type, info *recordInfo, fields []any) any {
	if len(fields) != len(info.indexes) {
		panic(fmt.Sprintf(
			"kaya: an undone entry of %v carries %d fields, the schema has %d",
			t, len(fields), len(info.indexes)))
	}
	record := reflect.New(t).Elem()
	for wire, idx := range info.indexes {
		field := record.Field(idx)
		v := reflect.ValueOf(fields[wire])
		if !v.IsValid() {
			panic(fmt.Sprintf("kaya: an undone entry of %v has no value for %s",
				t, t.Field(idx).Name))
		}
		if v.Type() != field.Type() {
			if !v.CanConvert(field.Type()) {
				panic(fmt.Sprintf(
					"kaya: an undone entry of %v carries %T for %s, which is %v",
					t, fields[wire], t.Field(idx).Name, field.Type()))
			}
			v = v.Convert(field.Type())
		}
		field.Set(v)
	}
	return record.Interface()
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
		out[i] = info.encode(uint32(i), v.Field(idx).Interface())
	}
	return out
}

// encode is one field's wire value. Blob fields register their bytes
// now, at encode time — handles are single-submit, so insert, update,
// and update_field all re-register (one copy into core memory per
// write; the model keeps the guest's own bytes).
func (info *recordInfo) encode(field uint32, v any) any {
	if info.schema[field] == ValueBlob {
		return blobWire(v)
	}
	return v
}

// Insert a record; the model keeps the T itself, the wire carries its
// fields positionally. Through Tx.insertEntry, the one insert path — so
// an explicit numeric key is shown to the fresh-key minter here exactly
// as it is on the untyped and sum surfaces.
func (c RecordCollection[K, T]) Insert(tx *Tx, key K, value T) {
	tx.insertEntry(c.Collection, key, 0, value, c.info.values(value))
}

// handle is the plain (collection, path) handle behind a typed
// collection: what the minter counts per. Unexported, so FreshCollection
// below is closed to kaya's own collections.
func (c RecordCollection[K, T]) handle() Collection { return c.Collection }

// FreshCollection is a typed collection InsertFresh can mint into: one
// whose keys ARE the minted I64. THE KEY TYPE IS THE WALL — a
// RecordCollection[string, T] does not satisfy this, so a collection
// declared with string identities fails to compile at the call rather
// than growing a second kind of name for the same datum. The untyped
// scalar surface has its own spelling, Tx.InsertFresh.
type FreshCollection[T any] interface {
	Insert(tx *Tx, key int64, value T)
	handle() Collection
}

// InsertFresh inserts a value under a key the binding authors, and hands
// the key back: the typed twin of Tx.InsertFresh, over records and sums
// alike, and the same contract in every particular (one counter per
// collection instance, counter+1, absorption on every explicit insert,
// no decrement — see Tx.InsertFresh for the whole of it).
//
// A FREE FUNCTION BECAUSE THE KEY TYPE IS THE POINT. Go cannot constrain
// a method to one instantiation of its receiver's type parameters, and a
// method returning K would have to convert the minted number into
// whatever K is — which for a string key is a silent one-rune key, the
// exact class of quiet wrongness the minter exists to remove. Written as
// a function, the constraint is checked where the guest writes it.
//
// A RECORD COLLECTION INFERS BOTH PARAMETERS from the arguments. A SUM
// COLLECTION NAMES ITS SUM — kaya.InsertFresh[Feed](tx, items, Note{…})
// — because the value is one constructor and T is the sealed interface
// they share: inference reads T off the value and would fix it to the
// constructor. Insert has the same shape and takes it from the receiver;
// here the sum is spelled once, at the call.
func InsertFresh[T any, C FreshCollection[T]](tx *Tx, c C, value T) int64 {
	h := c.handle()
	key := tx.app.mintKey(h.id, h.path)
	c.Insert(tx, key, value)
	return key
}

// Update replaces a record wholesale; UpdateField is the one-field way.
func (c RecordCollection[K, T]) Update(tx *Tx, key K, value T) {
	tx.app.modelSet(c.id, c.path, key, value)
	tx.emit(TxCollectionUpdate(c.id, c.path, key, 0, c.info.values(value)))
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
	tx.emit(TxCollectionUpdateField(c.id, c.path, key, f.index, 0, c.info.encode(f.index, value)))
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
	t.tx.emit(TxBindTextElement(n.id, level, f.index))
}

// BindCheckedField binds a checkbox's state to one field of the
// element; Field[bool] only.
func (t *Tpl) BindCheckedField(n Node, level uint32, f Field[bool]) {
	t.tx.emit(TxBindCheckedElement(n.id, level, f.index))
}

// BindValueField binds a slider's position, a progress bar's fraction
// or a choice widget's selected index to one field of the element;
// Field[float64] only. THE INDEX RIDES A float64 like every other
// number on this property: the scene checks a bound field's wire type
// against the property's exactly, and `value` is F64 there, so a
// select's 0-based index is a float64 field and an int64 one dies at
// startup. The constraint refuses it at compile time instead.
func (t *Tpl) BindValueField(n Node, level uint32, f Field[float64]) {
	t.tx.emit(TxBindValueElement(n.id, level, f.index))
}

// BindSourceField binds an image's source to one field of the element
// of the enclosing For; Field[[]byte] only.
func (t *Tpl) BindSourceField(n Node, level uint32, f Field[[]byte]) {
	t.tx.emit(TxBindSourceElement(n.id, level, f.index))
}

// The record surface's four lowerings, one per wire value type: the
// protocol's whole binding universe as one union-constrained argument
// (Go 1.27 generic methods; the type switch discriminates). They are
// the *Tpl.apply* helpers plus the arm only a record type can offer —
// the raw field PROJECTION, func(*T) *V, resolved once at declaration
// by FieldBy.
//
// ARM ORDER IS FIXED and the CONSTANT ARM IS THE DEFAULT, in all four.
// The constraint approximates (~string, not string), so a guest's named
// type — `type Title string` — is admitted by the signature and matches
// no `case string:`; before 2026-08-10 Label and Checkbox each had one,
// and such a value fell past every arm to produce a widget with no text
// and no error. That is this zone's own silent-drop failure class, so
// the const arm goes last and catches whatever the bindings did not.
// T appears only inside S's constraint, which is a union and so has no
// core type: inference cannot reach it, and every caller spells it —
// t.applyRecordText[T](n, src).

func (t *Tpl) applyRecordText[T any, S interface {
	~string | Signal[string] | func(*T) *string | Field[string]
}](n Node, src S) {
	switch v := any(src).(type) {
	case Signal[string]:
		t.tx.emit(TxBindText(n.id, v.id))
	case func(*T) *string:
		t.BindTextField(n, 0, FieldBy(v))
	case Field[string]:
		t.BindTextField(n, 0, v)
	default:
		t.setText(n, reflect.ValueOf(v).String())
	}
}

func (t *Tpl) applyRecordChecked[T any, S interface {
	~bool | Signal[bool] | func(*T) *bool | Field[bool]
}](n Node, src S) {
	switch v := any(src).(type) {
	case Signal[bool]:
		t.tx.emit(TxBindChecked(n.id, v.id))
	case func(*T) *bool:
		t.BindCheckedField(n, 0, FieldBy(v))
	case Field[bool]:
		t.BindCheckedField(n, 0, v)
	default:
		t.tx.emit(TxSetChecked(n.id, reflect.ValueOf(v).Bool()))
	}
}

func (t *Tpl) applyRecordValue[T any, S interface {
	~float64 | Signal[float64] | func(*T) *float64 | Field[float64]
}](n Node, src S) {
	switch v := any(src).(type) {
	case Signal[float64]:
		t.tx.emit(TxBindValue(n.id, v.id))
	case func(*T) *float64:
		t.BindValueField(n, 0, FieldBy(v))
	case Field[float64]:
		t.BindValueField(n, 0, v)
	default:
		t.tx.emit(TxSetValue(n.id, reflect.ValueOf(v).Float()))
	}
}

func (t *Tpl) applyRecordBlob[T any, S interface {
	~[]byte | Signal[[]byte] | func(*T) *[]byte | Field[[]byte]
}](n Node, src S) {
	switch v := any(src).(type) {
	case Signal[[]byte]:
		t.tx.emit(TxBindSource(n.id, v.id))
	case func(*T) *[]byte:
		t.BindSourceField(n, 0, FieldBy(v))
	case Field[[]byte]:
		t.BindSourceField(n, 0, v)
	default:
		// ~[]byte, named byte-slice types included: register now.
		t.tx.emit(TxSetSource(n.id, uint64(blobWire(v))))
	}
}

// applyRecordStrProp is those same four arms for a string PROP rather
// than a constructor's value: the three wire ops arrive as arguments,
// because the a11y props differ from each other in nothing else. It is
// Tpl.applyStrProp with the two arms this surface adds anywhere — the
// projection, and the constant that must go LAST for ~string's sake.
func (t *Tpl) applyRecordStrProp[T any, S interface {
	~string | Signal[string] | func(*T) *string | Field[string]
}](n Node, src S,
	set func(uint64, string) []byte,
	bindSignal func(uint64, uint64) []byte,
	bindElement func(uint64, uint32, uint32) []byte,
) {
	switch v := any(src).(type) {
	case Signal[string]:
		t.tx.emit(bindSignal(n.id, v.id))
	case func(*T) *string:
		t.tx.emit(bindElement(n.id, 0, FieldBy(v).index))
	case Field[string]:
		t.tx.emit(bindElement(n.id, 0, v.index))
	default:
		t.tx.emit(set(n.id, reflect.ValueOf(v).String()))
	}
}

// The typed template constructors. Each takes the *Tpl as its first
// argument rather than being a method on it, because the record type T
// must come from THIS receiver for a field projection to resolve
// against a schema; the plain *Tpl twins of all of these are on the
// base surface (Tpl.LabelBound, Tpl.Slider, ...), and what these add is
// exactly two things — the projection arm, and a handler whose key is
// the receiver's K instead of an []any the guest has to cast.

// Label creates a label bound to any addressable source: a constant, a
// signal, a field projection, or a pre-resolved token.
func (c RecordCollection[K, T]) Label[S interface {
	~string | Signal[string] | func(*T) *string | Field[string]
}](t *Tpl, src S) Node {
	n := t.Widget(KindLabel)
	t.applyRecordText[T](n, src)
	return n
}

// Button creates a button whose caption comes from any addressable
// source, with its click handler (nil for none) — the per-row action
// button, whose caption can name the row it acts on.
func (c RecordCollection[K, T]) Button[S interface {
	~string | Signal[string] | func(*T) *string | Field[string]
}](t *Tpl, src S, onClick func(*Tx, K)) Node {
	n := t.Widget(KindButton)
	t.applyRecordText[T](n, src)
	if onClick != nil {
		t.tx.app.OnClickNode(n, func(tx *Tx, keys []any) {
			onClick(tx, keys[0].(K))
		})
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
	t.applyRecordChecked[T](n, src)
	if onToggle != nil {
		t.tx.app.OnToggleNode(n, func(tx *Tx, keys []any, checked bool) {
			onToggle(tx, keys[0].(K), checked)
		})
	}
	return n
}

// Entry creates an EMPTY text field with its change handler (nil for
// none): Tpl.Entry's uncontrolled contract with the key already cast.
// EntryBound seeds each copy from its row instead.
func (c RecordCollection[K, T]) Entry(t *Tpl, onChange func(*Tx, K, string)) Node {
	n := t.Widget(KindEntry)
	c.onChangeOf(t, n, onChange)
	return n
}

// EntryBound creates a text field whose INITIAL text comes from any
// addressable source, with its change handler (nil for none). The seed
// is one write per stamped copy and the copy owns its text afterwards
// (Tpl.EntryBound has the whole contract, including what a later
// UpdateField on the same field does to it).
func (c RecordCollection[K, T]) EntryBound[S interface {
	~string | Signal[string] | func(*T) *string | Field[string]
}](t *Tpl, src S, onChange func(*Tx, K, string)) Node {
	n := t.Widget(KindEntry)
	t.applyRecordText[T](n, src)
	c.onChangeOf(t, n, onChange)
	return n
}

// Textarea creates an empty multi-line editor with its change handler
// (nil for none) — Entry's contract over the platform's real
// multi-line control.
func (c RecordCollection[K, T]) Textarea(t *Tpl, onChange func(*Tx, K, string)) Node {
	n := t.Widget(KindTextarea)
	c.onChangeOf(t, n, onChange)
	return n
}

// TextareaBound seeds each copy's editor from any addressable source —
// EntryBound's reasoning, one kind over.
func (c RecordCollection[K, T]) TextareaBound[S interface {
	~string | Signal[string] | func(*T) *string | Field[string]
}](t *Tpl, src S, onChange func(*Tx, K, string)) Node {
	n := t.Widget(KindTextarea)
	t.applyRecordText[T](n, src)
	c.onChangeOf(t, n, onChange)
	return n
}

// onChangeOf is the text-edit registration the four text constructors
// share: the copy's keys arrive as an []any and the receiver's K names
// the depth-1 one, which is the cast this surface exists to make once.
func (c RecordCollection[K, T]) onChangeOf(t *Tpl, n Node, onChange func(*Tx, K, string)) {
	if onChange == nil {
		return
	}
	t.tx.app.OnChangeNode(n, func(tx *Tx, keys []any, text string) {
		onChange(tx, keys[0].(K), text)
	})
}

// Progress creates a progress bar bound to any addressable source:
// display-only, like Label and Image, and the per-row fraction is the
// reading a list of them is for. 0..=1, domain-checked at the root.
func (c RecordCollection[K, T]) Progress[S interface {
	~float64 | Signal[float64] | func(*T) *float64 | Field[float64]
}](t *Tpl, src S) Node {
	n := t.Widget(KindProgress)
	t.applyRecordValue[T](n, src)
	return n
}

// Slider creates a slider over min..max whose POSITION comes from any
// addressable source, with its change handler (nil for none). The
// range describes the prototype and stays constant; see Tpl.Slider.
func (c RecordCollection[K, T]) Slider[S interface {
	~float64 | Signal[float64] | func(*T) *float64 | Field[float64]
}](t *Tpl, min, max float64, src S, onChange func(*Tx, K, float64)) Node {
	n := t.Widget(KindSlider)
	t.tx.emit(TxSetMin(n.id, min))
	t.tx.emit(TxSetMax(n.id, max))
	t.applyRecordValue[T](n, src)
	c.onValueOf(t, n, onChange)
	return n
}

// Select creates a dropdown over fixed options whose SELECTED INDEX
// comes from any addressable source, with its pick handler (nil for
// none): onSelect receives each USER pick's new 0-based index for the
// copy K names (programmatic writes never echo). The option list stays
// constant — see Tpl.Select for why it cannot be otherwise — and the
// index rides a float64 field; see Tpl.BindValueField.
func (c RecordCollection[K, T]) Select[S interface {
	~float64 | Signal[float64] | func(*T) *float64 | Field[float64]
}](t *Tpl, options []string, src S, onSelect func(*Tx, K, int)) Node {
	return c.choice(t, KindSelect, options, src, onSelect)
}

// Radio is Select's inline presentation: same option children, same
// F64-sourced 0-based index, same pick handler.
func (c RecordCollection[K, T]) Radio[S interface {
	~float64 | Signal[float64] | func(*T) *float64 | Field[float64]
}](t *Tpl, options []string, src S, onSelect func(*Tx, K, int)) Node {
	return c.choice(t, KindRadio, options, src, onSelect)
}

// choice is the shared body of the two choice constructors: the option
// children, then the sourced index, then the pick handler with its
// float64 narrowed to the index it always was.
func (c RecordCollection[K, T]) choice[S interface {
	~float64 | Signal[float64] | func(*T) *float64 | Field[float64]
}](t *Tpl, kind uint32, options []string, src S, onSelect func(*Tx, K, int)) Node {
	n := t.choiceOf(kind, options)
	t.applyRecordValue[T](n, src)
	if onSelect != nil {
		c.onValueOf(t, n, func(tx *Tx, key K, v float64) { onSelect(tx, key, int(v)) })
	}
	return n
}

// onValueOf is the value-change registration the slider and the two
// choice constructors share — App.OnValueChangedNode with the depth-1
// key cast, the node twin the dispatch loop gained in this same pass.
func (c RecordCollection[K, T]) onValueOf(t *Tpl, n Node, onChange func(*Tx, K, float64)) {
	if onChange == nil {
		return
	}
	t.tx.app.OnValueChangedNode(n, func(tx *Tx, keys []any, v float64) {
		onChange(tx, keys[0].(K), v)
	})
}

// Image creates an image bound to any addressable source: encoded
// bytes (registered once, at declaration — the blueprint's stamped
// copies share the value), a blob signal, a field projection, or a
// pre-resolved token — the same union-constrained shape as Label.
func (c RecordCollection[K, T]) Image[S interface {
	~[]byte | Signal[[]byte] | func(*T) *[]byte | Field[[]byte]
}](t *Tpl, src S) Node {
	n := t.Widget(KindImage)
	t.applyRecordBlob[T](n, src)
	return n
}

// The typed template PROPS. They take the node the constructors handed
// back, so they read as a second statement rather than as a chain —
// Tpl.SetGrow's shape, for its reason (a Node is a plain id and has no
// transaction to chain from). One union method per prop rather than the
// base surface's Set/Bind pair, because the projection arm is what
// makes this surface worth reaching for and a union already admits the
// constant:
//
//	todos.A11yLabel(t, done, func(x *Todo) *string { return &x.Title })
//
// Accepts has no method here, and its absence is the design: it is
// CONST ONLY (Tpl.SetAccepts says why), so this surface would add
// nothing to it — a guest holding this collection holds the *Tpl too,
// and spells it t.SetAccepts(n, kaya.AcceptText).

// A11yID addresses each stamped copy from any addressable source; see
// Tpl.SetA11yID on why a constant here is usually the wrong half.
func (c RecordCollection[K, T]) A11yID[S interface {
	~string | Signal[string] | func(*T) *string | Field[string]
}](t *Tpl, n Node, src S) {
	t.applyRecordStrProp[T](n, src, TxSetA11yId, TxBindA11yId, TxBindA11yIdElement)
}

// A11yLabel speaks each stamped copy from any addressable source — the
// row's own field being the case the prop exists for (Tpl.BindA11yLabel
// has the example).
func (c RecordCollection[K, T]) A11yLabel[S interface {
	~string | Signal[string] | func(*T) *string | Field[string]
}](t *Tpl, n Node, src S) {
	t.applyRecordStrProp[T](n, src, TxSetA11yLabel, TxBindA11yLabel, TxBindA11yLabelElement)
}

// A11yHint says what activating each stamped copy does — activation
// kinds only, refused by the root at declare time (Tpl.SetA11yHint).
func (c RecordCollection[K, T]) A11yHint[S interface {
	~string | Signal[string] | func(*T) *string | Field[string]
}](t *Tpl, n Node, src S) {
	t.applyRecordStrProp[T](n, src, TxSetA11yHint, TxBindA11yHint, TxBindA11yHintElement)
}
