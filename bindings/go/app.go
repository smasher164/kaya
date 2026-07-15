// kaya's idiomatic surface for Go: the structural core.
//
// Three jobs, layered over the runtime (runtime.go) and the generated
// wire vocabulary (kaya_wire.go):
//
//   - id allocation: signals, widgets, collections, and template nodes
//     come from per-space counters behind distinct types, so no app
//     hand-numbers the id spaces — and the compiler keeps blueprint
//     nodes (Node) from being used where live widgets (Widget) belong;
//   - template scoping: ForEach and When take a func(*Tpl) whose body
//     declares the blueprint, bracketing the records — declaring and
//     instantiating stay visibly different things;
//   - occurrence dispatch: handlers register per button; the app loop
//     routes each click, handing template-node handlers the stamped
//     copy's key path. Handlers receive their transaction explicitly
//     (func(*Tx)), per the binding conventions; it submits when the
//     handler returns. The core never calls into the guest — dispatch
//     runs on the app goroutine after it pulls from the ring.
package kaya

// Typed handles over the id spaces.
type Signal struct{ id uint64 }

// Widget is a live widget: exactly one thing on screen.
type Widget struct{ id uint64 }

// Node is a template node: a blueprint entry, stamped per collection
// entry. Never on screen by itself; clicks on its copies arrive with
// the copy's key path.
type Node struct{ id uint64 }

// Collection is a collection instance handle: the collection plus the
// key path selecting one stamped copy's table. Tx.Collection returns
// the root (empty-path, live-zone) handle; At steps into a copy, one
// key per enclosing For. Mutations and reads take the handle, so the
// target is spelled once.
type Collection struct {
	id   uint64
	path []any
}

// At is the instance of this collection inside the copy keyed by key
// of the next enclosing For; chain for deeper nesting.
func (c Collection) At(key any) Collection {
	path := append(append([]any(nil), c.path...), key)
	return Collection{c.id, path}
}

// A For binds the collection itself — its template stamps per entry of
// every instance — so handing it an At(...) handle is a bug.
func assertRoot(c Collection) {
	if len(c.path) > 0 {
		panic("kaya: ForEach binds the collection itself, not an instance — drop the At(...)")
	}
}

type counters struct {
	signal, widget, collection, node uint64
}

// Entry is one key/value pair of a collection instance, in insertion
// order — what Items returns.
type Entry struct {
	Key, Value any
}

// instance is one collection instance: the table inside the stamped
// copy selected by path (the empty path for a live-zone collection).
type instance struct {
	path    []any
	entries []Entry
}

// App owns the id counters (which outlive any one transaction), the
// dispatch tables, and the collection model. The collection is the
// model — the only copy: every mutation op edits it and queues the wire
// delta in the same call, so reads (Items, Len) are exactly the writes.
type App struct {
	c              counters
	widgetHandlers map[uint64]func(*Tx)
	nodeHandlers   map[uint64]func(*Tx, []any)
	widgetChanges  map[uint64]func(*Tx, string)
	nodeChanges    map[uint64]func(*Tx, []any, string)
	model          map[uint64][]*instance
	// Collections declared inside a For's template: removing a parent
	// entry tears down the copy and every instance inside it, so the
	// model needs the same edge to purge along.
	children map[uint64][]uint64
	openFors []uint64
}

func NewApp() *App {
	Init()
	return &App{
		widgetHandlers: make(map[uint64]func(*Tx)),
		nodeHandlers:   make(map[uint64]func(*Tx, []any)),
		widgetChanges:  make(map[uint64]func(*Tx, string)),
		nodeChanges:    make(map[uint64]func(*Tx, []any, string)),
		model:          make(map[uint64][]*instance),
		children:       make(map[uint64][]uint64),
	}
}

func pathEq(a, b []any) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

func (a *App) instanceOf(coll uint64, path []any) *instance {
	for _, in := range a.model[coll] {
		if pathEq(in.path, path) {
			return in
		}
	}
	return nil
}

func (a *App) modelSet(coll uint64, path []any, key, value any) {
	in := a.instanceOf(coll, path)
	if in == nil {
		in = &instance{path: append([]any(nil), path...)}
		a.model[coll] = append(a.model[coll], in)
	}
	for i := range in.entries {
		if in.entries[i].Key == key {
			in.entries[i].Value = value
			return
		}
	}
	in.entries = append(in.entries, Entry{key, value})
}

func (a *App) modelRemove(coll uint64, path []any, key any) {
	if in := a.instanceOf(coll, path); in != nil {
		kept := in.entries[:0]
		for _, e := range in.entries {
			if e.Key != key {
				kept = append(kept, e)
			}
		}
		in.entries = kept
	}
	// The core tears down the copy, taking descendant collection
	// instances with it; the model follows.
	a.purgeChildren(coll, append(append([]any(nil), path...), key))
}

func (a *App) purgeChildren(coll uint64, prefix []any) {
	for _, kid := range a.children[coll] {
		kept := a.model[kid][:0]
		for _, in := range a.model[kid] {
			if len(in.path) < len(prefix) || !pathEq(in.path[:len(prefix)], prefix) {
				kept = append(kept, in)
			}
		}
		a.model[kid] = kept
		a.purgeChildren(kid, prefix)
	}
}

// A collection declared inside a For's template is torn down with its
// copies: record the edge so the model purges along it.
func (a *App) registerCollection(id uint64) {
	if len(a.openFors) > 0 {
		parent := a.openFors[len(a.openFors)-1]
		a.children[parent] = append(a.children[parent], id)
	}
}

// Tx is one transaction: everything queued inside Build (or a handler)
// applies atomically when it returns.
type Tx struct {
	app     *App
	records [][]byte
}

// Build runs fn with a fresh transaction and submits it.
func (a *App) Build(fn func(*Tx)) {
	tx := &Tx{app: a}
	fn(tx)
	if len(tx.records) > 0 {
		Submit(tx.records...)
	}
}

func (tx *Tx) Signal(initial any) Signal {
	tx.app.c.signal++
	s := Signal{tx.app.c.signal}
	tx.records = append(tx.records, TxCreateSignal(s.id, initial))
	return s
}

func (tx *Tx) Write(s Signal, value any) {
	tx.records = append(tx.records, TxWriteSignal(s.id, value))
}

func (tx *Tx) Widget(kind uint32) Widget {
	tx.app.c.widget++
	w := Widget{tx.app.c.widget}
	tx.records = append(tx.records, TxCreateWidget(w.id, kind))
	return w
}

func (tx *Tx) SetText(w Widget, text string) {
	tx.records = append(tx.records, TxSetText(w.id, text))
}

func (tx *Tx) BindText(w Widget, s Signal) {
	tx.records = append(tx.records, TxBindText(w.id, s.id))
}

func (tx *Tx) AddChild(parent, child Widget) {
	tx.records = append(tx.records, TxAddChild(parent.id, child.id))
}

func (tx *Tx) Collection() Collection {
	tx.app.c.collection++
	c := Collection{id: tx.app.c.collection}
	tx.app.registerCollection(c.id)
	tx.records = append(tx.records, TxCreateCollection(c.id))
	return c
}

// ForEach declares a For over c: fn's body declares the template, and
// the For itself (a live container) is returned.
func (tx *Tx) ForEach(c Collection, fn func(*Tpl)) Widget {
	assertRoot(c)
	tx.app.c.widget++
	w := Widget{tx.app.c.widget}
	tx.records = append(tx.records, TxCreateFor(w.id, c.id))
	tx.app.openFors = append(tx.app.openFors, c.id)
	fn(&Tpl{tx: tx})
	tx.app.openFors = tx.app.openFors[:len(tx.app.openFors)-1]
	tx.records = append(tx.records, TxTemplateEnd())
	return w
}

// When declares a When over a Bool signal: stamps on true, unstamps on
// false.
func (tx *Tx) When(s Signal, fn func(*Tpl)) Widget {
	tx.app.c.widget++
	w := Widget{tx.app.c.widget}
	tx.records = append(tx.records, TxCreateWhen(w.id, s.id))
	fn(&Tpl{tx: tx})
	tx.records = append(tx.records, TxTemplateEnd())
	return w
}

func (tx *Tx) Insert(c Collection, key, value any) {
	tx.app.modelSet(c.id, c.path, key, value)
	tx.records = append(tx.records, TxCollectionInsert(c.id, c.path, key, value))
}

func (tx *Tx) Update(c Collection, key, value any) {
	tx.app.modelSet(c.id, c.path, key, value)
	tx.records = append(tx.records, TxCollectionUpdate(c.id, c.path, key, value))
}

func (tx *Tx) Remove(c Collection, key any) {
	tx.app.modelRemove(c.id, c.path, key)
	tx.records = append(tx.records, TxCollectionRemove(c.id, c.path, key))
}

// Items is the model: what this guest wrote, exactly — the fold of
// every patch so far (this transaction's included), in insertion order.
func (tx *Tx) Items(c Collection) []Entry {
	if in := tx.app.instanceOf(c.id, c.path); in != nil {
		return append([]Entry(nil), in.entries...)
	}
	return nil
}

func (tx *Tx) Len(c Collection) int {
	if in := tx.app.instanceOf(c.id, c.path); in != nil {
		return len(in.entries)
	}
	return 0
}

// Mount mounts into the default window; per-window targets arrive with
// the window vocabulary.
func (tx *Tx) Mount(root Widget) {
	tx.records = append(tx.records, TxMount(0, root.id))
}

// Tpl is a template body: the same declaration vocabulary with
// template-node ids, plus element bindings.
type Tpl struct {
	tx *Tx
}

func (t *Tpl) Widget(kind uint32) Node {
	t.tx.app.c.node++
	n := Node{t.tx.app.c.node}
	t.tx.records = append(t.tx.records, TxCreateWidget(n.id, kind))
	return n
}

func (t *Tpl) SetText(n Node, text string) {
	t.tx.records = append(t.tx.records, TxSetText(n.id, text))
}

// BindTextElement binds text to the element of the enclosing For,
// `level` Fors up (0 = nearest).
func (t *Tpl) BindTextElement(n Node, level uint32) {
	t.tx.records = append(t.tx.records, TxBindTextElement(n.id, level))
}

func (t *Tpl) AddChild(parent, child Node) {
	t.tx.records = append(t.tx.records, TxAddChild(parent.id, child.id))
}

func (t *Tpl) Collection() Collection {
	return t.tx.Collection()
}

func (t *Tpl) ForEach(c Collection, fn func(*Tpl)) Node {
	assertRoot(c)
	t.tx.app.c.node++
	n := Node{t.tx.app.c.node}
	t.tx.records = append(t.tx.records, TxCreateFor(n.id, c.id))
	t.tx.app.openFors = append(t.tx.app.openFors, c.id)
	fn(&Tpl{tx: t.tx})
	t.tx.app.openFors = t.tx.app.openFors[:len(t.tx.app.openFors)-1]
	t.tx.records = append(t.tx.records, TxTemplateEnd())
	return n
}

func (t *Tpl) When(s Signal, fn func(*Tpl)) Node {
	t.tx.app.c.node++
	n := Node{t.tx.app.c.node}
	t.tx.records = append(t.tx.records, TxCreateWhen(n.id, s.id))
	fn(&Tpl{tx: t.tx})
	t.tx.records = append(t.tx.records, TxTemplateEnd())
	return n
}

// OnClick registers a handler for a live widget's clicks.
func (a *App) OnClick(w Widget, fn func(*Tx)) {
	a.widgetHandlers[w.id] = fn
}

// OnClickNode registers a handler for a template node's clicks; the
// handler also receives the stamped copy's keys, outermost first.
func (a *App) OnClickNode(n Node, fn func(*Tx, []any)) {
	a.nodeHandlers[n.id] = fn
}

// OnChange registers a handler for a live entry's edits: the widget
// owns its text and reports each edit here; the app folds the text
// into its own state — there is no read-back, by doctrine.
func (a *App) OnChange(w Widget, fn func(*Tx, string)) {
	a.widgetChanges[w.id] = fn
}

// OnChangeNode registers a change handler for a template entry; the
// handler also receives the stamped copy's keys, outermost first.
func (a *App) OnChangeNode(n Node, fn func(*Tx, []any, string)) {
	a.nodeChanges[n.id] = fn
}

// Run enters the core on the calling goroutine's thread (which must be
// the process main thread; use runtime.LockOSThread in an init
// function), dispatching occurrences on a second goroutine. Returns the
// exit code.
func (a *App) Run() int {
	done := make(chan struct{})
	go func() {
		defer close(done)
		for {
			kind, id, keys, text, ok := NextOccurrence()
			if !ok {
				return // shutdown
			}
			switch {
			case kind == occButtonClicked && len(keys) == 0:
				if fn := a.widgetHandlers[id]; fn != nil {
					a.Build(func(tx *Tx) { fn(tx) })
				}
			case kind == occButtonClicked:
				if fn := a.nodeHandlers[id]; fn != nil {
					a.Build(func(tx *Tx) { fn(tx, keys) })
				}
			case kind == occTextChanged && len(keys) == 0:
				if fn := a.widgetChanges[id]; fn != nil {
					a.Build(func(tx *Tx) { fn(tx, text) })
				}
			case kind == occTextChanged:
				if fn := a.nodeChanges[id]; fn != nil {
					a.Build(func(tx *Tx) { fn(tx, keys, text) })
				}
			}
		}
	}()
	code := Run()
	<-done
	return code
}
