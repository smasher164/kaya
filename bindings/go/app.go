// kaya's idiomatic surface for Go: the structural core, over the
// runtime (runtime.go) and the generated wire vocabulary
// (kaya_wire.go). Id allocation, template scoping and occurrence
// dispatch. The core never calls into the guest — dispatch runs on the
// app goroutine after it pulls from the ring.
package kaya

import (
	"fmt"
	"iter"
	"os"
	"strings"
	"sync"
	"sync/atomic"
)

// Scalar is the signal-value constraint: the wire's value types.
// []byte is the blob channel — each write registers the bytes with the
// core at encode time (handles are single-submit).
type Scalar interface {
	~string | ~bool | ~int64 | ~float64 | ~[]byte
}

// Signal carries its value type: writes are checked at compile time,
// and When demands a Signal[bool] instead of panicking in the scene.
type Signal[V Scalar] struct{ id uint64 }

// Widget is a live widget: exactly one thing on screen. It carries the
// transaction that minted it so construction chains read declaratively;
// a Widget stored past its build transaction still names the same
// widget — only the chain methods die with it.
type Widget struct {
	id uint64
	tx *Tx
}

// Node is a template node: a blueprint entry, stamped per collection
// entry. Never on screen by itself; clicks on its copies arrive with
// the copy's key path.
type Node struct{ id uint64 }

// Collection is a collection instance handle: the collection plus the
// key path selecting one stamped copy's table. Tx.Collection returns the
// root handle; At steps into a copy, one key per enclosing For.
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
		panic("kaya: Rows binds the collection itself, not an instance — drop the At(...)")
	}
}

type counters struct {
	// No `node`: template nodes draw from `widget`, one sequence per app
	// (DESIGN.md, Binding conventions). Deleting the field is the guard —
	// a future c.node does not compile.
	signal, widget, collection, alert, menuItem, fileDialog uint64
	// Clipboard reads share the alert's request/result grammar, so
	// they share its id shape: one counter, one-shot registrations.
	clipboard uint64
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

// minter is one collection INSTANCE's fresh-key counter (docs/
// fresh-key-plan.md): the highest I64 key that table has minted or been
// handed. NOT a field on instance, and that is the safety argument: a
// counter outlives the entries, and instance is what the rollback
// journal restores — an abandoned transaction would carry the counter
// backwards with it.
type minter struct {
	path    []any
	counter int64
}

// Caps is WHAT THIS HOST CAN DO (crates/kaya/src/app.rs carries the
// canonical note). Named booleans, never the bits: the core is free to
// renumber. CAPABILITIES INFORM; WALLS REFUSE — a false here does not
// make a call illegal, the root does, but it lets a guest ask first.
type Caps struct {
	// The host can materialize a surface beside the primary one. False
	// on iOS and Android, where CreateWindow aborts at the root.
	AuxWindows bool
}

// Capabilities answers what this host can do. Constant for the life of
// the process, so asking once and remembering is fine.
func Capabilities() Caps {
	bits := capabilityBits()
	return Caps{AuxWindows: bits&capAuxWindows != 0}
}

// App owns the id counters, the dispatch tables and the collection
// model. The collection IS the model, the only copy: every mutation
// edits it and queues the wire delta in the same call.
type App struct {
	c              counters
	widgetHandlers map[uint64]func(*Tx)
	// Table sort requests, keyed by the For container's widget id
	// (docs/tables-plan.md): the handler receives the 0-based column.
	sortHandlers map[uint64]func(*Tx, uint32)
	// The stamped-copy twin: a nested For's node id, the copy's keys.
	nodeSorts map[uint64]func(*Tx, []any, uint32)
	nodeHandlers   map[uint64]func(*Tx, []any)
	widgetChanges  map[uint64]func(*Tx, string)
	nodeChanges    map[uint64]func(*Tx, []any, string)
	widgetToggles  map[uint64]func(*Tx, bool)
	widgetValues   map[uint64]func(*Tx, float64)
	nodeValues     map[uint64]func(*Tx, []any, float64)
	// Window lifecycle: one handler each, receiving the window id.
	closeRequested map[uint64]func(*Tx)
	windowClosed   map[uint64]func(*Tx)
	entryPopped    map[uint64]func(*Tx)
	backRequested  map[uint64]func(*Tx)
	sectionSelected map[uint64]func(*Tx)
	alerts         map[uint64]func(*Tx, uint32)
	fileDialogs    map[uint64]func(*Tx, []PickedFile)
	clipboardReads map[uint64]func(*Tx, Representation)
	widgetPastes   map[uint64]func(*Tx, Representation)
	nodePastes     map[uint64]func(*Tx, []any, Representation)
	nodeToggles    map[uint64]func(*Tx, []any, bool)
	// Menu dispatch tables, keyed by MENU ITEM id — their own id space,
	// separate from every widget/node table. The node flavors receive
	// the stamped copy's key path.
	menuActivated     map[uint64]func(*Tx)
	menuActivatedNode map[uint64]func(*Tx, []any)
	menuToggled       map[uint64]func(*Tx, bool)
	menuToggledNode   map[uint64]func(*Tx, []any, bool)
	menuSelected      map[uint64]func(*Tx, int)
	menuSelectedNode  map[uint64]func(*Tx, []any, int)
	// Keyed by WINDOW and never one-shot: a history is walked as often
	// as the user likes, and each window has its own ledger
	// (docs/undo-plan.md §3).
	undone         map[uint64]func(*Tx, string, UndoDelta)
	redone         map[uint64]func(*Tx, string, UndoDelta)
	// How each collection's entries come BACK from an undo: recorded
	// where the type is known (declaration), used where it is not (the
	// occurrence loop).
	shapes         map[uint64]undoShape
	model          map[uint64][]*instance
	// One per collection INSTANCE, because an instance is a table and
	// keys are unique within one.
	fresh          map[uint64][]*minter
	// Collections declared inside a For's template: removing a parent
	// entry tears down the copy and every instance inside it, so the
	// model needs the same edge to purge along.
	children map[uint64][]uint64
	openFors []uint64
	// The ambient parent stack: containers push their id around their
	// body, constructors parent to the top, and 0 is the template-root
	// sentinel.
	parents []uint64
	// Signals recomputed from a collection after each of its
	// mutations, written into the same transaction.
	derived map[uint64][]func(*Tx)
	// Each canvas's declared viewbox, so a redraw in a LATER transaction
	// does not have to repeat it (docs/canvas-plan.md §2.2).
	canvasViewboxes map[uint64]Viewbox
	// Non-zero exactly while a template body is being declared: the
	// record-time mirror-read guard's arm. openFors is For-only (it
	// carries collection ids for nesting), so the guard has its own
	// depth, bumped by every scope opener in both zones.
	tplDepth int
	// How to undo the open transaction's model edits: a deep snapshot
	// per touched collection, taken on first touch. Non-nil exactly
	// while a Build is running.
	journal map[uint64][]*instance
	// THE ONLY FIELD HERE TOUCHED FROM ANOTHER THREAD, and the only
	// reason App carries a mutex — everything above is
	// app-goroutine-only by construction.
	postMu sync.Mutex
	posted []func(*Tx)
}

func NewApp() *App {
	Init()
	return &App{
		widgetHandlers: make(map[uint64]func(*Tx)),
		sortHandlers:   make(map[uint64]func(*Tx, uint32)),
		nodeSorts:      make(map[uint64]func(*Tx, []any, uint32)),
		alerts:         make(map[uint64]func(*Tx, uint32)),
		fileDialogs:    make(map[uint64]func(*Tx, []PickedFile)),
		clipboardReads: make(map[uint64]func(*Tx, Representation)),
		widgetPastes:   make(map[uint64]func(*Tx, Representation)),
		nodePastes:     make(map[uint64]func(*Tx, []any, Representation)),
		entryPopped:    make(map[uint64]func(*Tx)),
		backRequested:  make(map[uint64]func(*Tx)),
		sectionSelected: make(map[uint64]func(*Tx)),
		closeRequested: make(map[uint64]func(*Tx)),
		windowClosed:   make(map[uint64]func(*Tx)),
		nodeHandlers:   make(map[uint64]func(*Tx, []any)),
		widgetChanges:  make(map[uint64]func(*Tx, string)),
		nodeChanges:    make(map[uint64]func(*Tx, []any, string)),
		widgetToggles:  make(map[uint64]func(*Tx, bool)),
		widgetValues:   make(map[uint64]func(*Tx, float64)),
		nodeValues:     make(map[uint64]func(*Tx, []any, float64)),
		nodeToggles:    make(map[uint64]func(*Tx, []any, bool)),
		menuActivated:     make(map[uint64]func(*Tx)),
		menuActivatedNode: make(map[uint64]func(*Tx, []any)),
		menuToggled:       make(map[uint64]func(*Tx, bool)),
		menuToggledNode:   make(map[uint64]func(*Tx, []any, bool)),
		menuSelected:      make(map[uint64]func(*Tx, int)),
		menuSelectedNode:  make(map[uint64]func(*Tx, []any, int)),
		undone:         make(map[uint64]func(*Tx, string, UndoDelta)),
		redone:         make(map[uint64]func(*Tx, string, UndoDelta)),
		shapes:         make(map[uint64]undoShape),
		model:          make(map[uint64][]*instance),
		fresh:          make(map[uint64][]*minter),
		children:       make(map[uint64][]uint64),
		derived:        make(map[uint64][]func(*Tx)),
		canvasViewboxes: make(map[uint64]Viewbox),
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

// counterOf is one instance's fresh-key counter, created at 0 the first
// time that table is minted into or inserted into.
func (a *App) counterOf(coll uint64, path []any) *minter {
	for _, m := range a.fresh[coll] {
		if pathEq(m.path, path) {
			return m
		}
	}
	m := &minter{path: append([]any(nil), path...)}
	a.fresh[coll] = append(a.fresh[coll], m)
	return m
}

// mintKey is the next fresh key for one instance: counter+1, and the
// counter keeps it. Monotonic by construction — nothing in the binding
// writes it downwards (see Tx.InsertFresh).
func (a *App) mintKey(coll uint64, path []any) int64 {
	m := a.counterOf(coll, path)
	m.counter++
	return m.counter
}

// absorbKey shows the minter an explicit key on its way into the table.
// A numeric key at or above the counter carries it up; anything else
// moves nothing. int and int64 are exactly what encodeValue writes as
// ValueI64, so what absorbs here is what the core sees as a number.
func (a *App) absorbKey(coll uint64, path []any, key any) {
	var n int64
	switch k := key.(type) {
	case int64:
		n = k
	case int:
		n = int64(k)
	default:
		return
	}
	if m := a.counterOf(coll, path); n > m.counter {
		m.counter = n
	}
}

// touch journals a deep snapshot of one collection's instances the
// first time the open transaction mutates it. DEEP because instances
// are pointers and their entry slices mutate in place.
func (a *App) touch(coll uint64) {
	if a.journal == nil {
		return
	}
	if _, done := a.journal[coll]; done {
		return
	}
	saved := make([]*instance, len(a.model[coll]))
	for i, in := range a.model[coll] {
		saved[i] = &instance{
			path:    append([]any(nil), in.path...),
			entries: append([]Entry(nil), in.entries...),
		}
	}
	a.journal[coll] = saved
}

func (a *App) modelSet(coll uint64, path []any, key, value any) {
	a.touch(coll)
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
	a.touch(coll)
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

func (a *App) keysOf(coll uint64, path []any) []any {
	in := a.instanceOf(coll, path)
	if in == nil {
		return nil
	}
	keys := make([]any, len(in.entries))
	for i := range in.entries {
		keys[i] = in.entries[i].Key
	}
	return keys
}

func (a *App) modelMove(coll uint64, path []any, key any, before []any) {
	a.touch(coll)
	in := a.instanceOf(coll, path)
	pos := -1
	if in != nil {
		for i := range in.entries {
			if in.entries[i].Key == key {
				pos = i
				break
			}
		}
	}
	// The same checks the scene makes, made where the guest can see
	// the stack. Both validated before anything mutates.
	if pos < 0 {
		panic(fmt.Sprintf("kaya: move of missing key %v", key))
	}
	if len(before) > 0 {
		found := false
		for i := range in.entries {
			if in.entries[i].Key == before[0] {
				found = true
				break
			}
		}
		if !found {
			panic(fmt.Sprintf("kaya: move before missing key %v", before[0]))
		}
	}
	entry := in.entries[pos]
	in.entries = append(in.entries[:pos], in.entries[pos+1:]...)
	at := len(in.entries)
	if len(before) > 0 {
		for i := range in.entries {
			if in.entries[i].Key == before[0] {
				at = i
				break
			}
		}
	}
	in.entries = append(in.entries, Entry{})
	copy(in.entries[at+1:], in.entries[at:])
	in.entries[at] = entry
}

func (a *App) purgeChildren(coll uint64, prefix []any) {
	for _, kid := range a.children[coll] {
		a.touch(kid)
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
// copies: record the edge so the model purges along it. Also records
// HOW ITS ENTRIES COME BACK from an undo — the scalar shape by default,
// overwritten by CollectionOf/SumOf the moment they know T.
func (a *App) registerCollection(id uint64) {
	if len(a.openFors) > 0 {
		parent := a.openFors[len(a.openFors)-1]
		a.children[parent] = append(a.children[parent], id)
	}
	a.shapes[id] = scalarShape
}

// Tx is one transaction: everything queued inside Build (or a handler)
// applies atomically when it returns.
type Tx struct {
	app     *App
	records [][]byte
	// Derived-signal registrations made this transaction, promoted into
	// the app registry only on commit — an abandoned transaction
	// abandons its registrations with its records.
	pendingDerived []pendingDerived
	// Set when Build finishes with this transaction, committed or not: a
	// late construction chain must die loudly, not append into an
	// orphaned record list.
	closed bool
	// Set by Undoable: the wire admits one head-of-batch marker per
	// batch, so a second name is a guest bug.
	undoGroup bool
}

type pendingDerived struct {
	coll      uint64
	recompute func(*Tx)
}

// emit queues one record, and is the ONE place that appends to a
// transaction. Every constructor, setter and chain method goes through
// it so the closed check cannot be forgotten at a new callsite; a write
// through a Tx that outlived its Build vanishes silently otherwise.
//
// A Tx is valid ONLY inside the Build or handler that made it, on the
// app thread. To mutate from anywhere else, post.
func (tx *Tx) emit(rec []byte) {
	tx.alive()
	tx.records = append(tx.records, rec)
}

// alive is the one panic, shared by the write chokepoint above and the
// read chokepoint below so the two cannot drift in what they say.
func (tx *Tx) alive() {
	if tx == nil || tx.closed {
		panic("kaya: transaction is over — a Tx is only usable inside the Build or handler that created it; to mutate from a background thread use App.Post")
	}
	requireAppThread()
}

// requireAppThread is the other half of the rule alive() states: OPEN is
// not enough, the transaction also belongs to the app thread. A closed
// flag cannot see a goroutine spawned inside a handler writing through
// the transaction the handler is still holding, nor a background Build
// opening one of its own — both race the app goroutine's model.
//
// The three ambient bindings check exactly this at their build entry and
// spell it the same (python's _require_app_thread, ocaml's
// require_app_thread, haskell's requireAppThread); the handle bindings
// check it here AND at Build, since a Build with no records reaches no
// chokepoint. tools/check-tx-liveness.sh holds both halves.
func requireAppThread() {
	owner := appThread.Load()
	if owner == 0 {
		// The dispatch loop has not claimed it yet: the guest's opening
		// Build, on the main goroutine, before Run.
		return
	}
	if here := threadID(); here != owner {
		panic(fmt.Sprintf(
			"kaya: a transaction belongs to the app thread — this is thread %d, "+
				"the app thread is %d. To mutate from a background thread use "+
				"App.Post, which runs your function as a transaction over there.",
			here, owner))
	}
}

// mirror is emit's read-side sibling: the same liveness check plus the
// template-body rule. A read through a transaction that outlived its
// Build RACES the app thread's own model instead of failing.
func (tx *Tx) mirror(c Collection) *instance {
	tx.alive()
	tx.app.guardMirrorRead()
	return tx.app.instanceOf(c.id, c.path)
}

// Build runs fn with a fresh transaction and submits it. A panic out of
// fn abandons the transaction — the records never ship and the journal
// restores the mirror — then the panic continues to the caller. The tx
// boundary rolls back and propagates; surviving is dispatch's job.
func (a *App) Build(fn func(*Tx)) {
	requireAppThread()
	if a.journal != nil {
		panic("kaya: Build inside Build — one transaction at a time")
	}
	tx := &Tx{app: a}
	a.journal = make(map[uint64][]*instance)
	committed := false
	defer func() {
		if !committed {
			for id, saved := range a.journal {
				a.model[id] = saved
			}
			// A panic mid-declaration leaves the ambient stacks and the
			// template depth dirty, and the app survives the abort.
			a.parents = a.parents[:0]
			a.openFors = a.openFors[:0]
			a.tplDepth = 0
		}
		a.journal = nil
		// Committed or abandoned, this transaction is over: late
		// construction chains must die loudly either way.
		tx.closed = true
	}()
	fn(tx)
	committed = true
	for _, p := range tx.pendingDerived {
		a.derived[p.coll] = append(a.derived[p.coll], p.recompute)
	}
	if len(tx.records) > 0 {
		Submit(tx.records...)
	}
}

// dispatch runs one handler inside its own Build and survives a panic
// out of it: by the time the panic crosses the boundary the model is
// restored and the records dropped. Aborts the runtime cannot recover
// still die, uniformly with every other binding's fatal floor.





func (a *App) dispatch(fn func(*Tx)) {
	defer func() {
		if r := recover(); r != nil {
			fmt.Fprintf(os.Stderr, "kaya: handler panicked (transaction rolled back): %v\n", r)
		}
	}()
	a.Build(fn)
}

// Post runs fn as a transaction on the app goroutine, soon. It is the
// ONE method safe to call from another goroutine.
//
//	go func() {
//		data, err := os.ReadFile(name)      // blocks this goroutine
//		app.Post(func(tx *kaya.Tx) {        // back on the app goroutine
//			tx.Write(content, string(data))
//		})
//	}()
//
// What must NOT cross is a *Tx: it belongs to the Build or handler that
// made it, and capturing one is refused (Tx.emit). Ids are values and
// are meant to be captured.
//
// A posted closure runs in its OWN transaction, after whatever is
// running now: posting from inside a handler queues for AFTER, never
// nests.
func (a *App) Post(fn func(*Tx)) {
	if fn == nil {
		return
	}
	a.postMu.Lock()
	a.posted = append(a.posted, fn)
	a.postMu.Unlock()
	// The app goroutine may be parked in C waiting on the ring, and
	// posted work never enters that ring.
	Wake()
}

// drainPosted runs everything queued, each as its own transaction, in
// the order it was posted. It takes the batch and releases the lock
// BEFORE running any of it, so a closure that posts again lands in the
// NEXT batch and cannot starve the occurrence loop.
func (a *App) drainPosted() {
	a.postMu.Lock()
	batch := a.posted
	a.posted = nil
	a.postMu.Unlock()
	for _, fn := range batch {
		a.dispatch(fn)
	}
}

func (tx *Tx) Signal[V Scalar](initial V) Signal[V] {
	tx.app.c.signal++
	s := Signal[V]{tx.app.c.signal}
	tx.emit(TxCreateSignal(s.id, scalarWire(initial)))
	return s
}

// Write writes a signal's value. A []byte value registers its bytes at
// encode time — handles are single-submit, so every write re-registers
// (one copy into core memory per write).
func (tx *Tx) Write[V Scalar](s Signal[V], value V) {
	tx.emit(TxWriteSignal(s.id, scalarWire(value)))
}

func (tx *Tx) Widget(kind uint32) Widget {
	tx.app.c.widget++
	w := Widget{id: tx.app.c.widget, tx: tx}
	tx.emit(TxCreateWidget(w.id, kind))
	tx.autoParent(w.id)
	return w
}

// The current ambient parent (0 when the scope roots itself: template
// bodies, or no open container).
func (tx *Tx) currentParent() uint64 {
	if n := len(tx.app.parents); n > 0 {
		return tx.app.parents[n-1]
	}
	return 0
}

func (tx *Tx) autoParent(id uint64) {
	if p := tx.currentParent(); p != 0 {
		tx.emit(TxAddChild(p, id))
	}
}

// SetText writes a widget's text — a label's caption, and on a text
// field or textarea the "open a document into the editor" write.
//
// THE TEXT WIDGETS ARE UNCONTROLLED: this is one write, not a binding
// the app keeps pushing. A write that CHANGES the text drops whatever
// the app declared over it (Tx.HighlightRanges) and spends the field's
// native undo history.
func (tx *Tx) SetText(w Widget, text string) {
	tx.emit(TxSetText(w.id, text))
}

func (tx *Tx) BindText(w Widget, s Signal[string]) {
	tx.emit(TxBindText(w.id, s.id))
}

func (tx *Tx) SetChecked(w Widget, checked bool) {
	tx.emit(TxSetChecked(w.id, checked))
}

// SetGrow sets a widget's flex weight within its row/column: 0 is
// natural size, positive weights divide the leftover main-axis space.
// The dynamic path; the declarative spelling is the Grow chain.
func (tx *Tx) SetGrow(w Widget, weight float64) {
	tx.emit(TxSetGrow(w.id, weight))
}

// SetInset sets a container's own padding — DIP between its bounds and
// its children, uniform on all four sides (docs/styling-plan.md D3).
// Containers only. The dynamic path; the chain is the declarative one.
func (tx *Tx) SetInset(w Widget, pad float64) {
	tx.emit(TxSetInset(w.id, pad))
}

// Inset pads this container at construction — the declarative chain:
// tx.Row(...).Inset(8). Same transaction discipline as Grow.
func (w Widget) Inset(pad float64) Widget {
	if w.tx == nil || w.tx.closed {
		panic("kaya: Inset on a widget outside its build transaction — use Tx.SetInset inside a live transaction")
	}
	w.tx.SetInset(w, pad)
	return w
}

// Grow weights this widget within its row/column at construction — the
// declarative chain: tx.Label(s).Grow(1). It appends to the transaction
// that minted the widget, so it belongs in the build expression and
// fails loudly on a Widget that outlived its build.
func (w Widget) Grow(weight float64) Widget {
	if w.tx == nil || w.tx.closed {
		panic("kaya: Grow on a widget outside its build transaction — use Tx.SetGrow inside a live transaction")
	}
	w.tx.SetGrow(w, weight)
	return w
}

// SetAlign sets a container's cross-axis child placement — one of the
// generated align constants. Containers only; baseline is rows-only,
// and the root rejects misuse. The chain is the declarative spelling.
func (tx *Tx) SetAlign(w Widget, mode int64) {
	tx.emit(TxSetAlign(w.id, mode))
}

// Align sets this container's cross-axis child placement at
// construction. Same transaction discipline as Grow.
func (w Widget) Align(mode int64) Widget {
	if w.tx == nil || w.tx.closed {
		panic("kaya: Align on a widget outside its build transaction — use Tx.SetAlign inside a live transaction")
	}
	w.tx.SetAlign(w, mode)
	return w
}

// SetSpacing sets a container's inter-child gap (main axis, DIP;
// normalized default 8). Containers only. The chain is the declarative
// spelling.
func (tx *Tx) SetSpacing(w Widget, gap float64) {
	tx.emit(TxSetSpacing(w.id, gap))
}

// Spacing sets this container's inter-child gap at construction. Same
// transaction discipline as Grow.
func (w Widget) Spacing(gap float64) Widget {
	if w.tx == nil || w.tx.closed {
		panic("kaya: Spacing on a widget outside its build transaction — use Tx.SetSpacing inside a live transaction")
	}
	w.tx.SetSpacing(w, gap)
	return w
}

// SetA11yID sets a widget's accessibility IDENTIFIER: a stable authored
// key that automation addresses it by, and which is NEVER spoken.
// Universal. The chain is the declarative spelling.
func (tx *Tx) SetA11yID(w Widget, id string) {
	tx.emit(TxSetA11yId(w.id, id))
}

// A11yID sets this widget's accessibility identifier at construction.
// Same transaction discipline as Grow.
func (w Widget) A11yID(id string) Widget {
	if w.tx == nil || w.tx.closed {
		panic("kaya: A11yID on a widget outside its build transaction — use Tx.SetA11yID inside a live transaction")
	}
	w.tx.SetA11yID(w, id)
	return w
}

// SetA11yLabel sets what an assistive client SPEAKS for a widget.
// Universal, and separate from the identifier. Leave it unset to keep
// what the platform derives from the control's own content; setting it
// OVERRIDES that. The chain is the declarative spelling.
func (tx *Tx) SetA11yLabel(w Widget, label string) {
	tx.emit(TxSetA11yLabel(w.id, label))
}

// A11yLabel sets this widget's spoken label at construction. Same
// transaction discipline as Grow.
func (w Widget) A11yLabel(label string) Widget {
	if w.tx == nil || w.tx.closed {
		panic("kaya: A11yLabel on a widget outside its build transaction — use Tx.SetA11yLabel inside a live transaction")
	}
	w.tx.SetA11yLabel(w, label)
	return w
}

// SetA11yHint sets what ACTIVATING a widget does. Write a VERB PHRASE:
// VoiceOver speaks it as written, TalkBack prefixes "double tap to".
// Activation kinds only; the root rejects it elsewhere.
func (tx *Tx) SetA11yHint(w Widget, hint string) {
	tx.emit(TxSetA11yHint(w.id, hint))
}

// A11yHint sets this widget's hint at construction. Same transaction
// discipline as Grow.
func (w Widget) A11yHint(hint string) Widget {
	if w.tx == nil || w.tx.closed {
		panic("kaya: A11yHint on a widget outside its build transaction — use Tx.SetA11yHint inside a live transaction")
	}
	w.tx.SetA11yHint(w, hint)
	return w
}

// SetRole sets a widget's SEMANTIC EMPHASIS — what it MEANS, never how
// it looks (docs/styling-plan.md D4). The vocabulary is closed and the
// root refuses a misfit at declare time. (The Role* STRING constants
// further down are the MENU tier's; the types keep them apart.)
func (tx *Tx) SetRole(w Widget, role int64) {
	tx.emit(TxSetRole(w.id, role))
}

// Role sets this widget's semantic emphasis at construction. Same
// transaction discipline as Grow.
func (w Widget) Role(role int64) Widget {
	if w.tx == nil || w.tx.closed {
		panic("kaya: Role on a widget outside its build transaction — use Tx.SetRole inside a live transaction")
	}
	w.tx.SetRole(w, role)
	return w
}

func (tx *Tx) BindChecked(w Widget, s Signal[bool]) {
	tx.emit(TxBindChecked(w.id, s.id))
}

// SetSource sets an image's encoded bytes: one registration copy into
// core memory, consumed by the next submit whether referenced or not,
// so the caller's bytes may be dropped on return.
func (tx *Tx) SetSource(w Widget, data []byte) {
	tx.emit(TxSetSource(w.id, RegisterBlob(data)))
}

// BindSource binds an image's source to a blob signal; each write of
// the signal re-registers its bytes (see Tx.Write).
func (tx *Tx) BindSource(w Widget, s Signal[[]byte]) {
	tx.emit(TxBindSource(w.id, s.id))
}

func (tx *Tx) AddChild(parent, child Widget) {
	tx.emit(TxAddChild(parent.id, child.id))
}

// Clear drops the widget's owned content — a one-shot command riding
// this transaction like any write, so the insert and the clear beside
// it commit together or not at all. The widget answers through its
// normal occurrence path (a clear arrives back as an empty text
// change), never a side assignment.
func (tx *Tx) Clear(w Widget) {
	tx.emit(TxWidgetCommand(w.id, CommandClear))
}

// Focus gives the widget keyboard focus (the post-submit refocus every
// real form wants) — a one-shot command riding the transaction like
// Clear.
func (tx *Tx) Focus(w Widget) {
	tx.emit(TxWidgetCommand(w.id, CommandFocus))
}

// TextRange is a half-open span of a text widget's content: Start and
// End are UTF-8 BYTE offsets, which is what Go's own string indexing
// already produces. THE UNIT IS THE WIRE'S, NEVER THE PLATFORM'S — four
// backends count UTF-16 units and one counts code points, and the core
// converts against its own copy before lowering.
type TextRange struct{ Start, End int }

// check is the ONE thing this binding checks about a range, and it is a
// GO REPRESENTATION matter: Go's int is signed and the wire's offset is
// not, so a strings.Index miss (-1) would reach the core as
// 18446744073709551615 and be refused under a number the app never
// wrote. Everything else — start <= end, end inside the text,
// code-point boundaries — is the CORE's, checked against the text it
// holds; this binding has no copy and could not check them honestly.
func (r TextRange) check(verb string, w Widget) {
	if r.Start < 0 || r.End < 0 {
		panic(fmt.Sprintf("kaya: %s on widget %d: the range %d:%d has a negative "+
			"offset — a kaya range is a pair of UTF-8 byte offsets into the "+
			"widget's text, and strings.Index answers -1 when there is no match",
			verb, w.id, r.Start, r.End))
	}
}

// HighlightRanges DECLARES the decorated ranges of a textarea, replacing
// whatever was declared before; a nil or empty slice is the clear.
//
// APP-OWNED AND NEVER TRACKED: the first edit of any kind drops the set,
// and the app re-declares from the fold its change handler already
// drives. A malformed offset fails loudly in the CORE rather than in a
// backend, where one of the five aborts the process.
func (tx *Tx) HighlightRanges(w Widget, ranges []TextRange) {
	// The offsets ride as one flat Values list read in pairs, so the
	// declared count and the list length must agree.
	flat := make([]any, 0, 2*len(ranges))
	for _, r := range ranges {
		r.check("HighlightRanges", w)
		flat = append(flat, int64(r.Start), int64(r.End))
	}
	tx.emit(TxHighlightRanges(w.id, uint32(len(ranges)), flat))
}

// SelectRange puts the textarea's selection at one range; an empty range
// is a caret. Same offsets and validation as HighlightRanges.
//
// REFUSED WHILE THE USER IS COMPOSING through an input method, in every
// backend: honouring it commits the composition mid-word — measured on
// macOS, where the half-typed kana land in the document and in the app's
// own model. The refusal is a no-op, not an error: composition state is
// on no kaya channel, so an app cannot avoid the race.
func (tx *Tx) SelectRange(w Widget, r TextRange) {
	r.check("SelectRange", w)
	tx.emit(TxSelectRange(w.id, uint64(r.Start), uint64(r.End)))
}

// RevealRange scrolls the textarea so a range is inside the viewport. A
// pure effect: no state moves, the selection is untouched, and undo does
// not put the scroll position back. Containment is the observable kaya
// fixes; how much context lands around it is the platform's.
func (tx *Tx) RevealRange(w Widget, r TextRange) {
	r.check("RevealRange", w)
	tx.emit(TxRevealRange(w.id, uint64(r.Start), uint64(r.End)))
}

// Construction sugar: containers take their body as a closure and parent
// everything declared inside it; constructors carry their props and
// handlers, nil meaning none. Everything lowers EAGERLY.

func (tx *Tx) Column(body func()) Widget {
	return tx.containerOf(KindColumn, body)
}

func (tx *Tx) Row(body func()) Widget {
	return tx.containerOf(KindRow, body)
}

// Scroll is a vertical scroll viewport over EXACTLY ONE child (the scene
// rejects a second). Chain .Grow(1) so the enclosing track CONSTRAINS
// it — an unconstrained viewport hugs its content and nothing overflows.
func (tx *Tx) Scroll(body func()) Widget {
	return tx.containerOf(KindScroll, body)
}

// Grid lays its children out row-major into columns columns — each
// column takes its NATURAL width, aligned across rows.
func (tx *Tx) Grid(columns int, body func()) Widget {
	parent := tx.Widget(KindGrid)
	tx.emit(TxSetColumns(parent.id, float64(columns)))
	tx.app.parents = append(tx.app.parents, parent.id)
	if body != nil {
		body()
	}
	tx.app.parents = tx.app.parents[:len(tx.app.parents)-1]
	return parent
}

// Spacer is an empty grown column: it consumes the leftover main-axis
// space between its siblings.
func (tx *Tx) Spacer() Widget {
	w := tx.Widget(KindColumn)
	return w.Grow(1)
}

func (tx *Tx) containerOf(kind uint32, body func()) Widget {
	parent := tx.Widget(kind)
	tx.app.parents = append(tx.app.parents, parent.id)
	if body != nil {
		body()
	}
	tx.app.parents = tx.app.parents[:len(tx.app.parents)-1]
	return parent
}

// Button creates a button with its caption and click handler (nil for
// none).
func (tx *Tx) Button(text string, onClick func(*Tx)) Widget {
	w := tx.Widget(KindButton)
	tx.SetText(w, text)
	if onClick != nil {
		tx.app.OnClick(w, onClick)
	}
	return w
}

// Sort is the header bar's indicator (docs/tables-plan.md): which
// column shows it, in which direction — the GUEST's declaration,
// re-sent with the new state after it handles a sort request.
type Sort struct {
	sorted    uint32
	direction uint32
}

// SortNone is the no-indicator bar.
func SortNone() Sort { return Sort{sorted: sortNoneValue} }

// SortAsc puts the ascending indicator on column (0-based).
func SortAsc(column uint32) Sort { return Sort{sorted: column} }

// SortDesc puts the descending indicator on column.
func SortDesc(column uint32) Sort { return Sort{sorted: column, direction: 1} }

// Columns RE-DECLARES a live For's header bar — the Widget
// Rows.Widget hands out — after a sort request has moved the indicator.
// The build-time declaration is Rows.Columns, which is where the arity
// rule is stated (docs/tables-plan.md).
func (tx *Tx) Columns(w Widget, titles []string, sort Sort) {
	// pathLen 0: no key path, so the values are titles alone
	// (docs/tables-plan.md, dynamic tables).
	tx.emit(TxSetColumnHeaders(w.id, sort.sorted, sort.direction,
		uint32(len(titles)), 0, titleValues(titles)))
}

// ColumnsAt re-declares ONE stamped copy's header bar: the nested For's
// Node, then that copy's keys outermost first — the per-copy sort
// indicator OnSortNode asks for. Empty keys re-declare the
// template-wide bar for every copy, which is what NodeRows.Columns
// spells at build time. The core walls the rest (a template bar must
// exist first,
// the keys must name a live copy).
func (tx *Tx) ColumnsAt(n Node, keys []any, titles []string, sort Sort) {
	values := make([]any, 0, len(keys)+len(titles))
	values = append(values, keys...)
	for _, title := range titles {
		values = append(values, title)
	}
	tx.emit(TxSetColumnHeaders(n.id, sort.sorted, sort.direction,
		uint32(len(titles)), uint32(len(keys)), values))
}

// Textarea creates a multi-line text editor with its change handler
// (nil for none): Entry's uncontrolled contract, one kind over.
func (tx *Tx) Textarea(onChange func(*Tx, string)) Widget {
	w := tx.Widget(KindTextarea)
	if onChange != nil {
		tx.app.OnChange(w, onChange)
	}
	return w
}

// LabelText creates a label with constant text; Label is the
// signal-bound flavor.
func (tx *Tx) LabelText(text string) Widget {
	w := tx.Widget(KindLabel)
	tx.SetText(w, text)
	return w
}

// Label creates a label bound to a signal.
func (tx *Tx) Label(s Signal[string]) Widget {
	w := tx.Widget(KindLabel)
	tx.BindText(w, s)
	return w
}

// Entry creates a text field with its change handler (nil for none).
func (tx *Tx) Entry(onChange func(*Tx, string)) Widget {
	w := tx.Widget(KindEntry)
	if onChange != nil {
		tx.app.OnChange(w, onChange)
	}
	return w
}

// Progress is a progress bar: display-only. value is the determinate
// fraction (0..=1, domain-checked at the root); chain .Indeterminate()
// for the platform's activity mode.
func (tx *Tx) Progress(value float64) Widget {
	w := tx.Widget(KindProgress)
	tx.emit(TxSetValue(w.id, value))
	return w
}

// Indeterminate switches a progress bar to the platform's activity
// mode (the fraction is ignored while it is on).
func (w Widget) Indeterminate() Widget {
	w.tx.emit(TxSetIndeterminate(w.id, true))
	return w
}

// Viewbox is a canvas's coordinate system AND its natural size in
// device-independent points (docs/canvas-plan.md §3.2). The op stream is
// written in these units on every platform and in every language, so a
// scene can freeze it.
type Viewbox struct{ W, H float64 }

// The paint ROLE an op names, never RGB: the roles resolve in the core
// per appearance (§3.4). The values are the generated PaintX constants.
type Paint int64

// Which way a fill resolves its own crossings: FillRuleNonzero or
// FillRuleEvenOdd.
type FillRule int64

// SVG's text-anchor: TextAlignStart, TextAlignMiddle, TextAlignEnd.
type TextAlign int64

// SVG's dominant-baseline: TextBaselineAlphabetic, TextBaselineMiddle,
// TextBaselineTop, TextBaselineBottom.
type TextBaseline int64

// Draw is the drawing scope's recorder. The calls read as immediate-mode
// drawing; they are recorded, and ONE record is submitted when the scope
// closes — the For template trace's fiction with a drawing scope instead
// of a loop (docs/canvas-plan.md §2.1).
type Draw struct {
	viewbox Viewbox
	ops     []any
}

// Viewbox is the box this drawing is written in, so a chart can compute
// its own extents without the app carrying the numbers twice.
func (d *Draw) Viewbox() Viewbox { return d.viewbox }

func (d *Draw) op(code int64, operands ...any) *Draw {
	d.ops = append(d.ops, code)
	d.ops = append(d.ops, operands...)
	return d
}

// MoveTo starts a subpath at (x, y).
func (d *Draw) MoveTo(x, y float64) *Draw { return d.op(DrawOpMoveTo, x, y) }

// LineTo extends the current subpath to (x, y).
func (d *Draw) LineTo(x, y float64) *Draw { return d.op(DrawOpLineTo, x, y) }

// Close closes the current subpath.
func (d *Draw) Close() *Draw { return d.op(DrawOpClose) }

// Polyline moves to the first point and lines to the rest — the chart's
// own shape, spelled once.
func (d *Draw) Polyline(points [][2]float64) *Draw {
	for i, p := range points {
		if i == 0 {
			d.MoveTo(p[0], p[1])
		} else {
			d.LineTo(p[0], p[1])
		}
	}
	return d
}

// Stroke strokes the built path and clears it. width is in
// device-independent points and does NOT carry the viewbox stretch, so a
// 1pt gridline is 1pt at every canvas size (docs/canvas-plan.md §3.2).
func (d *Draw) Stroke(paint Paint, width float64) *Draw {
	return d.op(DrawOpStroke, int64(paint), width)
}

// Fill fills the built path and clears it.
func (d *Draw) Fill(paint Paint, rule FillRule) *Draw {
	return d.op(DrawOpFill, int64(paint), int64(rule))
}

// Font selects the face for subsequent text ops. asset is an ordinary
// asset name; "" is kaya's own embedded default face, which is why a
// canvas can always draw text (§4.2). size is in device-independent
// points.
func (d *Draw) Font(asset string, size float64, weight int64) *Draw {
	return d.op(DrawOpFont, asset, size, weight)
}

// Text draws ONE LINE with its anchor at (x, y). A line break in s is
// refused by the core (docs/canvas-plan.md §3.3).
func (d *Draw) Text(x, y float64, s string, paint Paint, align TextAlign,
	baseline TextBaseline) *Draw {
	return d.op(DrawOpText, x, y, int64(paint), int64(align), int64(baseline), s)
}

// Canvas creates a drawing surface. vb is the coordinate system the ops
// are written in AND the canvas's natural size in points, which is what
// keeps one op stream identical on five platforms
// (docs/canvas-plan.md §3.2). Declare what it draws with Tx.Draw; until
// then it is present and empty.
func (tx *Tx) Canvas(vb Viewbox) Widget {
	w := tx.Widget(KindCanvas)
	// The viewbox rides the DRAWING on the wire, not a prop, so a canvas
	// with no declaration yet has nothing to be inconsistent about; the
	// guest side remembers it so a redraw in a later handler does not
	// repeat it.
	tx.app.canvasViewboxes[w.id] = vb
	return w
}

// Draw DECLARES the whole drawing on a canvas, replacing whatever was
// declared before. The closure reads as immediate-mode drawing and
// records: one atomic record is submitted when it returns.
func (tx *Tx) Draw(w Widget, body func(d *Draw)) {
	tx.alive()
	vb, ok := tx.app.canvasViewboxes[w.id]
	if !ok {
		panic("kaya: Draw on a widget that is not a canvas this app declared — a drawing is a declaration against the canvas it draws on (docs/canvas-plan.md §2.1)")
	}
	d := &Draw{viewbox: vb}
	body(d)
	tx.emit(TxSetDrawing(w.id, vb.W, vb.H, uint32(len(d.ops)), 0, d.ops))
}

// DrawAt re-declares ONE stamped copy's drawing: the canvas template
// Node, then that copy's keys outermost first. Empty keys re-declare the
// drawing every copy is born with, which is what Tpl.Canvas spells at
// declaration time (docs/canvas-plan.md §3.1).
func (tx *Tx) DrawAt(n Node, keys []any, vb Viewbox, body func(d *Draw)) {
	d := &Draw{viewbox: vb}
	body(d)
	values := make([]any, 0, len(keys)+len(d.ops))
	values = append(values, keys...)
	values = append(values, d.ops...)
	tx.emit(TxSetDrawing(n.id, vb.W, vb.H, uint32(len(d.ops)),
		uint32(len(keys)), values))
}

// Slider creates a slider over min..max at value, with its change
// handler co-located (nil for none).
func (tx *Tx) Slider(min, max, value float64, onChange func(*Tx, float64)) Widget {
	w := tx.Widget(KindSlider)
	tx.emit(TxSetMin(w.id, min))
	tx.emit(TxSetMax(w.id, max))
	tx.emit(TxSetValue(w.id, value))
	if onChange != nil {
		tx.app.OnValueChanged(w, onChange)
	}
	return w
}

// SliderBound creates a slider over min..max whose position binds a
// float signal — the programmatic write path. Property writes never
// echo an occurrence, so a handler's own writes cannot loop back at it.
func (tx *Tx) SliderBound(min, max float64, value Signal[float64], onChange func(*Tx, float64)) Widget {
	w := tx.Widget(KindSlider)
	tx.emit(TxSetMin(w.id, min))
	tx.emit(TxSetMax(w.id, max))
	tx.emit(TxBindValue(w.id, value.id))
	if onChange != nil {
		tx.app.OnValueChanged(w, onChange)
	}
	return w
}

// Select creates a dropdown over fixed options — each becomes a label
// child — at selected, the initial 0-based index (domain-checked at the
// root), with its pick handler co-located. onSelect receives each USER
// pick's index; programmatic writes never echo.
func (tx *Tx) Select(options []string, selected int, onSelect func(*Tx, int)) Widget {
	w := tx.Widget(KindSelect)
	tx.app.parents = append(tx.app.parents, w.id)
	for _, option := range options {
		o := tx.Widget(KindLabel)
		tx.SetText(o, option)
	}
	tx.app.parents = tx.app.parents[:len(tx.app.parents)-1]
	tx.emit(TxSetValue(w.id, float64(selected)))
	if onSelect != nil {
		tx.app.OnValueChanged(w, func(tx *Tx, v float64) { onSelect(tx, int(v)) })
	}
	return w
}

// Radio is Select's inline presentation: same option children, same
// 0-based index, same pick handler.
func (tx *Tx) Radio(options []string, selected int, onSelect func(*Tx, int)) Widget {
	w := tx.Widget(KindRadio)
	tx.app.parents = append(tx.app.parents, w.id)
	for _, option := range options {
		o := tx.Widget(KindLabel)
		tx.SetText(o, option)
	}
	tx.app.parents = tx.app.parents[:len(tx.app.parents)-1]
	tx.emit(TxSetValue(w.id, float64(selected)))
	if onSelect != nil {
		tx.app.OnValueChanged(w, func(tx *Tx, v float64) { onSelect(tx, int(v)) })
	}
	return w
}

// Checkbox creates a labeled box with its toggle handler (nil for
// none).
func (tx *Tx) Checkbox(text string, onToggle func(*Tx, bool)) Widget {
	w := tx.Widget(KindCheckbox)
	if text != "" {
		tx.SetText(w, text)
	}
	if onToggle != nil {
		tx.app.OnToggle(w, onToggle)
	}
	return w
}

// Image displays encoded bytes: the toolkit decodes natively, and a
// decode failure renders the placeholder, never a crash. One
// registration copy into core memory, consumed by the next submit.
// ImageSignal is the signal-bound flavor.
func (tx *Tx) Image(source []byte) Widget {
	w := tx.Widget(KindImage)
	tx.SetSource(w, source)
	return w
}

// ImageAsset displays the picture THE APP'S OWN BUILD PUT BESIDE IT —
// Image's request by a different route: the bytes never enter Go, and
// the redemption clones one refcount into the blob table (FontAsset's
// mechanics, one widget over).
func (tx *Tx) ImageAsset(a *Asset) Widget {
	if a == nil {
		panic("kaya: ImageAsset got no asset — open one with tx.Asset(\"icons/...\")")
	}
	w := tx.Widget(KindImage)
	tx.emit(TxSetSource(w.id, a.blobHandle()))
	return w
}

// ImageSignal creates an image whose source is bound to a blob signal;
// each write of the signal re-registers its bytes (see Tx.Write).
func (tx *Tx) ImageSignal(s Signal[[]byte]) Widget {
	w := tx.Widget(KindImage)
	tx.BindSource(w, s)
	return w
}

func (tx *Tx) Collection() Collection {
	tx.app.c.collection++
	c := Collection{id: tx.app.c.collection}
	tx.app.registerCollection(c.id)
	tx.emit(TxCreateCollection(c.id, [][]uint32{{ValueStr}}))
	return c
}

// rowsState is one For traced as a for statement, shared by the value
// Rows/NodeRows hand out and by every value their chain returns: the
// eagerly minted id, the scope the For folds into, and the header bar
// the chain records for the trace's end.
type rowsState struct {
	tx     *Tx
	id     uint64
	parent uint64
	bar    *headerBar
	traced bool
}

type headerBar struct {
	titles []string
	sort   Sort
}

// openRows mints the For and OPENS ITS TEMPLATE SCOPE — the id and the
// create_for land where the callback form put them, so a rows value the
// guest never ranges leaves the scope open and dies at submit
// ("kaya: template scope left open at end of transaction") rather than
// vanishing.
func (tx *Tx) openRows(c Collection) *rowsState {
	assertRoot(c)
	tx.app.c.widget++
	// The For parents into the enclosing scope, but the record must land
	// after template_end — an add_child inside the blueprint would cross
	// zones.
	st := &rowsState{tx: tx, id: tx.app.c.widget, parent: tx.currentParent()}
	tx.emit(TxCreateFor(st.id, c.id))
	tx.app.openFors = append(tx.app.openFors, c.id)
	tx.app.parents = append(tx.app.parents, 0)
	tx.app.tplDepth++
	return st
}

// all is the trace: the body runs ONCE, and closing is structural —
// range-over-func regains control on break, so template_end and the
// declarations deferred behind it are emitted either way.
func (st *rowsState) all(yield func(Row) bool) {
	if st.traced {
		panic("kaya: a rows value traces one template — range it in exactly one for statement")
	}
	st.traced = true
	tx := st.tx
	yield(Row{&Tpl{tx: tx}})
	tx.app.tplDepth--
	tx.app.parents = tx.app.parents[:len(tx.app.parents)-1]
	tx.app.openFors = tx.app.openFors[:len(tx.app.openFors)-1]
	tx.emit(TxTemplateEnd())
	if st.parent != 0 {
		tx.emit(TxAddChild(st.parent, st.id))
	}
	// After template_end, so the core holds the row template to the
	// declared arity the moment this arrives (docs/tables-plan.md).
	if st.bar != nil {
		// pathLen 0: a live For's flat bar, or a nested For's
		// template-scoped one (every copy) — the core tells them apart by
		// the id's zone.
		tx.emit(TxSetColumnHeaders(st.id, st.bar.sort.sorted, st.bar.sort.direction,
			uint32(len(st.bar.titles)), 0, titleValues(st.bar.titles)))
	}
}

func titleValues(titles []string) []any {
	values := make([]any, len(titles))
	for i, title := range titles {
		values[i] = title
	}
	return values
}

// Rows is a live For traced as a for statement: the container exists
// from here on, the chain declares the table, and the loop body runs
// once to author the blueprint.
//
//	rows := tx.Rows(items).Columns([]string{"Name"}, kaya.SortNone())
//	for row := range rows.All() { … }
//	tx.SetGrow(rows.Widget(), 1)
type Rows struct{ st *rowsState }

// Rows opens a For over c in the live tree.
func (tx *Tx) Rows(c Collection) *Rows { return &Rows{tx.openRows(c)} }

// Widget is the For's container: the handle every live-zone verb takes.
func (r *Rows) Widget() Widget { return Widget{id: r.st.id, tx: r.st.tx} }

// Columns declares the column header bar: one title per column, plus the
// indicator. The row template's root must be a Row of exactly one cell
// per column, refused loudly otherwise. Recorded here and emitted when
// the trace ends; Tx.Columns re-declares it after a sort
// (docs/tables-plan.md).
func (r *Rows) Columns(titles []string, sort Sort) *Rows {
	r.st.bar = &headerBar{titles, sort}
	return r
}

// OnSort registers the header-click handler at this For — handlers scope
// to their creator. The handler receives the 0-based column of a sort
// REQUEST: nothing has changed on screen; reorder the collection by key
// and re-declare the bar with Tx.Columns.
func (r *Rows) OnSort(fn func(*Tx, uint32)) *Rows {
	r.st.tx.app.OnSort(r.Widget(), fn)
	return r
}

// All traces the template: `for row := range rows.All()` runs the body
// ONCE, authoring the blueprint; stamping is the core's replay.
func (r *Rows) All() iter.Seq[Row] { return r.st.all }

// NodeRows is Rows one zone in: a For declared inside another template,
// whose handle is a template node shared by every stamped copy.
type NodeRows struct{ st *rowsState }

// Rows opens a nested For over c inside this template.
func (t *Tpl) Rows(c Collection) *NodeRows { return &NodeRows{t.tx.openRows(c)} }

// Node is the nested For's template node — what Tx.ColumnsAt takes back
// to re-declare ONE stamped copy's bar.
func (r *NodeRows) Node() Node { return Node{r.st.id} }

// Columns declares the header bar of this nested For for EVERY copy the
// enclosing template stamps. The record lands after template_end, in the
// still-open parent scope, which is where the header op finds its For
// (docs/tables-plan.md, MEASURED IN SLICE 1).
func (r *NodeRows) Columns(titles []string, sort Sort) *NodeRows {
	r.st.bar = &headerBar{titles, sort}
	return r
}

// OnSort registers this nested table's header-click handler at its For
// node. The keys are the clicking copy's, outermost first, and they are
// what Tx.ColumnsAt takes back to move THAT copy's indicator.
func (r *NodeRows) OnSort(fn func(*Tx, []any, uint32)) *NodeRows {
	r.st.tx.app.OnSortNode(r.Node(), fn)
	return r
}

// All traces the nested template; the body runs once, as the live zone's
// does.
func (r *NodeRows) All() iter.Seq[Row] { return r.st.all }

// Row is the row surface a trace yields: the whole template vocabulary
// (the embedded Tpl) plus the element's own token. A scalar collection
// has exactly one field; a record collection's typed row surface comes
// from the generator instead (cmd/kaya-gen).
type Row struct{ *Tpl }

// Value is the element's token: what a stamped copy's bindings read.
func (r Row) Value() Field[string] { return FieldAt[string](0) }

// Label creates a label bound to the element's token.
func (r Row) Label(f Field[string]) Node {
	n := r.Tpl.Widget(KindLabel)
	r.Tpl.BindTextField(n, 0, f)
	return n
}

// When declares a When over a Bool signal: stamps on true, unstamps on
// false.
func (tx *Tx) When(s Signal[bool], fn func(*Tpl)) Widget {
	tx.app.c.widget++
	w := Widget{id: tx.app.c.widget, tx: tx}
	parent := tx.currentParent()
	tx.emit(TxCreateWhen(w.id, s.id))
	tx.app.parents = append(tx.app.parents, 0)
	tx.app.tplDepth++
	fn(&Tpl{tx: tx})
	tx.app.tplDepth--
	tx.app.parents = tx.app.parents[:len(tx.app.parents)-1]
	tx.emit(TxTemplateEnd())
	if parent != 0 {
		tx.emit(TxAddChild(parent, w.id))
	}
	return w
}

func (tx *Tx) Insert(c Collection, key, value any) {
	tx.insertEntry(c, key, 0, value, []any{value})
}

// insertEntry is THE insert: the model write, the wire record, the
// derived recompute, and the fresh-key minter shown every explicit key
// on its way past. All three public inserts land here, so ABSORPTION
// SITS ON THE PATH rather than beside it (Tx.InsertFresh).
func (tx *Tx) insertEntry(c Collection, key any, variant uint32, value any, fields []any) {
	tx.app.absorbKey(c.id, c.path, key)
	tx.app.modelSet(c.id, c.path, key, value)
	tx.emit(TxCollectionInsert(c.id, c.path, key, variant, fields))
	tx.recomputeDerived(c.id, c.path)
}

// InsertFresh inserts a value under a key the binding authors, and hands
// the key back — FOR DATA THAT HAS NO IDENTITY OF ITS OWN.
//
// ONE COUNTER PER COLLECTION INSTANCE, starting at 0; the minted key is
// counter+1 as an I64. MIXING IS SAFE BY ABSORPTION: an explicit Insert
// whose key is a number at or above the counter carries it up.
//
// NO DECREMENT IS EXPRESSIBLE, and that is the whole safety argument:
// undo and redo replay captured keys inside the core and never re-enter
// this path, and an abandoned transaction restores the model, not the
// counter. A fresh key is fresh forever.
func (tx *Tx) InsertFresh(c Collection, value any) int64 {
	key := tx.app.mintKey(c.id, c.path)
	tx.Insert(c, key, value)
	return key
}

func (tx *Tx) Update(c Collection, key, value any) {
	tx.app.modelSet(c.id, c.path, key, value)
	tx.emit(TxCollectionUpdate(c.id, c.path, key, 0, []any{value}))
	tx.recomputeDerived(c.id, c.path)
}

func (tx *Tx) Remove(c Collection, key any) {
	tx.app.modelRemove(c.id, c.path, key)
	tx.emit(TxCollectionRemove(c.id, c.path, key))
	tx.recomputeDerived(c.id, c.path)
}

// MoveBefore repositions an entry before another's. Keys, never
// indices; a missing key or anchor panics at the call site, and moving
// an entry before itself is a no-op.
func (tx *Tx) MoveBefore(c Collection, key, anchor any) {
	tx.moveEntry(c, key, []any{anchor})
}

// MoveToEnd repositions an entry at the end of its collection.
func (tx *Tx) MoveToEnd(c Collection, key any) {
	tx.moveEntry(c, key, nil)
}

// MoveToFront repositions an entry at the front.
func (tx *Tx) MoveToFront(c Collection, key any) {
	keys := tx.app.keysOf(c.id, c.path)
	if len(keys) == 0 {
		panic(fmt.Sprintf("kaya: move of missing key %v", key))
	}
	tx.moveEntry(c, key, []any{keys[0]})
}

// MoveAfter repositions an entry directly after another's.
func (tx *Tx) MoveAfter(c Collection, key, anchor any) {
	keys := tx.app.keysOf(c.id, c.path)
	has, at := false, -1
	for i, k := range keys {
		if k == key {
			has = true
		}
		if k == anchor {
			at = i
		}
	}
	if !has {
		panic(fmt.Sprintf("kaya: move of missing key %v", key))
	}
	if at < 0 {
		panic(fmt.Sprintf("kaya: move after missing key %v", anchor))
	}
	if key == anchor {
		return
	}
	if at+1 == len(keys) {
		tx.moveEntry(c, key, nil)
		return
	}
	if keys[at+1] == key {
		return // already directly after the anchor
	}
	tx.moveEntry(c, key, []any{keys[at+1]})
}

func (tx *Tx) moveEntry(c Collection, key any, before []any) {
	if len(before) > 0 && before[0] == key {
		// Moving before itself changes no order, but the key must still
		// exist — the check the scene would make.
		for _, k := range tx.app.keysOf(c.id, c.path) {
			if k == key {
				return
			}
		}
		panic(fmt.Sprintf("kaya: move of missing key %v", key))
	}
	tx.app.modelMove(c.id, c.path, key, before)
	tx.emit(TxCollectionMove(c.id, c.path, key, before))
	tx.recomputeDerived(c.id, c.path)
}

// recomputeDerived runs every derived signal rooted at this collection
// and writes each into this transaction. Deriveds hang off ROOT
// handles, so nested-instance mutations cannot change their input.
func (tx *Tx) recomputeDerived(coll uint64, path []any) {
	if len(path) != 0 {
		return
	}
	for _, recompute := range tx.app.derived[coll] {
		recompute(tx)
	}
}

// guardMirrorRead panics on a model read inside a template body: the
// template records once and replays, so the read would bake today's
// value into the blueprint. Bind a signal, use the element's field, or
// Derive. Handler and build reads stay legal.
func (a *App) guardMirrorRead() {
	if a.tplDepth > 0 {
		panic("kaya: model read inside a template body — the template records " +
			"once and replays; bind a signal, use the element's field, or " +
			"Derive for computed values")
	}
}

// Items is the model: the fold of every patch so far, this
// transaction's included, in insertion order.
func (tx *Tx) Items(c Collection) []Entry {
	if in := tx.mirror(c); in != nil {
		return append([]Entry(nil), in.entries...)
	}
	return nil
}

func (tx *Tx) Len(c Collection) int {
	if in := tx.mirror(c); in != nil {
		return len(in.entries)
	}
	return 0
}

// CreateWindow creates an auxiliary window (capability-gated: phone
// hosts reject at the root); it materializes hidden and a MountIn
// presents it. Returns the prop chain.
func (tx *Tx) CreateWindow(id uint64) WindowRef {
	tx.emit(TxCreateWindow(id))
	return WindowRef{tx: tx, id: id}
}

// AccentOverride is one per-appearance brand override, made by
// LightAccent or DarkAccent. The zero value is "unstated": the seed
// fills every appearance it does not hear about.
type AccentOverride struct {
	// mask is the wire's presence bit — 1 light, 2 dark — so a
	// hand-made zero AccentOverride carries nothing and is ignored.
	mask uint32
	hex  uint32
}

// LightAccent overrides the accent for the LIGHT appearance only.
func LightAccent(hex uint32) AccentOverride { return AccentOverride{mask: 1, hex: hex} }

// DarkAccent overrides the accent for the DARK appearance only.
func DarkAccent(hex uint32) AccentOverride { return AccentOverride{mask: 2, hex: hex} }

// BrandAccent REQUESTS the app's brand accent (docs/styling-plan.md
// D1/D2): one packed sRGB hex (0xRRGGBB) is the whole call.
//
//	tx.BrandAccent(0x3584E4)
//	tx.BrandAccent(0x3584E4, kaya.DarkAccent(0x62A0EA))
//
// NAMED OVERRIDES RATHER THAN TWO POSITIONAL ARGUMENTS: light and dark
// are the same type, so a positional pair lets a caller swap them with
// nothing able to notice.
//
// SET ONCE, BEFORE THE FIRST MOUNT; the root refuses a second write and
// a late one. A REQUEST, uniformly: a platform may let its user override
// it. The app NEVER writes a foreground or contrast variants — one could
// be illegible with nothing to catch it.
func (tx *Tx) BrandAccent(seed uint32, overrides ...AccentOverride) {
	var mask, light, dark uint32
	for _, o := range overrides {
		if o.mask&mask != 0 {
			// Last-wins would shadow a brand book's real value with no
			// error anywhere.
			panic("kaya: BrandAccent got the same appearance override twice — light and dark are set at most once each")
		}
		mask |= o.mask
		switch o.mask {
		case 1:
			light = o.hex
		case 2:
			dark = o.hex
		}
	}
	tx.emit(TxSetBrandAccent(seed, mask, light, dark))
}

// Asset opens an asset — a file the app's own BUILD shipped beside it,
// named by a relative path under the asset root:
//
//	font := tx.Asset("fonts/sora-wght.ttf")
//	defer font.Close()
//
// Queues no record: opening one is a read. A MISS PANICS, WITH THE
// CORE'S SENTENCE AND NOTHING ADDED, so a Go guest and a Haskell guest
// are handed the same bytes. EACH CALL READS: no cache, no reload.
func (tx *Tx) Asset(name string) *Asset {
	// The transaction's liveness, asked because Go can: Rust gets it
	// from the borrow checker, which makes a dead Tx unnameable.
	tx.alive()
	if asset := openAsset(name); asset != nil {
		return asset
	}
	sentence := assetMissSentence(name)
	if sentence == "" {
		// Reachable only if the two calls disagree: the open answered a
		// miss and the why-not answered that it resolves. Both facts
		// were measured; this binding invents no third.
		sentence = fmt.Sprintf("kaya: asset(%q) did not open, and the core's own "+
			"why-not answers that it resolves — those two facts were measured a "+
			"moment apart, and this binding has nothing further to report", name)
	}
	panic(sentence)
}

// AssetMissSentence is why Tx.Asset(name) would panic — the sentence it
// would carry, handed over without panicking. "" means the name resolves.
// Line 1 (name, rule, census) is the same on every platform and is the
// line a scene freezes; line 2 names the resolved place, which three
// platforms spell three ways.
//
// Why a query and not just the panic: docs/deferred.md, the assets entry.
func (tx *Tx) AssetMissSentence(name string) string {
	// The transaction's liveness, for Tx.Asset's reason.
	tx.alive()
	return assetMissSentence(name)
}

// TypefaceOverride is one optional part of a brand typeface request,
// made by PlatformFamily or FontBytes. Most apps pass none.
//
// A ZERO TypefaceOverride IS NOT "UNSTATED", unlike AccentOverride's: a
// platform row either names a platform or is one the author failed to
// fill, so it rides as written and the ROOT refuses it by name.
type TypefaceOverride struct {
	// isFont distinguishes the blob form from a platform row: nil bytes
	// are a legal (if pointless) font and would otherwise read as "no
	// font here".
	platform int64
	family   string
	font     []byte
	isFont   bool
	// asset is the font-FILE form, redeemed without a copy. Never set
	// together with font: the two constructors are the only builders.
	asset *Asset
}

// PlatformFamily overrides the default family on ONE platform, named by
// the generated platform constants. THE CONSTANT RATHER THAN FIVE NAMED
// CONSTRUCTORS, because the vocabulary is a SPEC ENUM that regenerates.
// The pairs travel UNRESOLVED: this binding cannot know its platform
// (the JVM says "Linux" on Android), but every lowering IS one.
func PlatformFamily(platform int64, family string) TypefaceOverride {
	return TypefaceOverride{platform: platform, family: family}
}

// FontBytes ships a font FILE with the app: the backend hands the bytes
// to its platform's app-font API and reads back the family that
// registration produced. A registered blob's own family wins over the
// name on the backend that registered it.
func FontBytes(font []byte) TypefaceOverride {
	return TypefaceOverride{font: font, isFont: true}
}

// FontAsset ships the font FILE THE APP'S OWN BUILD PUT BESIDE IT —
// FontBytes's request by a different route: the bytes never enter Go,
// and the redemption clones one refcount into the blob table.
func FontAsset(asset *Asset) TypefaceOverride {
	if asset == nil {
		// Caught HERE rather than at the redemption inside
		// BrandTypeface, because here is where the caller's mistake is.
		panic("kaya: FontAsset got no asset — open one with tx.Asset(\"fonts/...\"), or pass a family name alone")
	}
	return TypefaceOverride{asset: asset, isFont: true}
}

// BrandTypeface REQUESTS the app's brand typeface (docs/styling-plan.md
// D6, Slice 2b): one family name is the whole call.
//
//	tx.BrandTypeface("Georgia")
//	tx.BrandTypeface("Georgia", kaya.PlatformFamily(kaya.PlatformLinux, "DejaVu Serif"))
//	tx.BrandTypeface("Inter", kaya.FontBytes(interRegular))
//
// THE FAMILY, NEVER THE SCALE (ratified DESIGN.md): sizes, weights and
// the whole type ramp stay the platform's, which is what makes the swap
// safe. Emphasis is the role tier's, never a font size.
//
// SET ONCE, BEFORE THE FIRST MOUNT, the accent's wall verbatim: the root
// refuses a second write and a late one.
//
// A FAMILY A PLATFORM DOES NOT HAVE leaves that platform's own typeface
// in place, deliberately and silently — every font API renders SOMETHING
// for a name it cannot match — which is why the conformance scene reads
// the RESOLVED family off the real text system.
func (tx *Tx) BrandTypeface(family string, overrides ...TypefaceOverride) {
	var (
		mask      uint32
		platforms []any
		// The font slot is written either way — an absent font rides as
		// an empty Str — so the record's field count never varies with
		// the payload (the accent's mask, verbatim).
		font any = ""
	)
	for _, o := range overrides {
		if !o.isFont {
			// FLAT PAIRS, tag then family, read back in twos. Duplicate
			// rows and unknown tags are the ROOT's to refuse.
			platforms = append(platforms, o.platform, o.family)
			continue
		}
		if mask&1 != 0 {
			// ONE BLOB SLOT ON THE WIRE, so a second font cannot ride:
			// last-wins would drop one with no error anywhere.
			panic("kaya: BrandTypeface got two fonts (FontBytes/FontAsset) — one font blob rides per request, so the second would silently replace the first")
		}
		mask |= 1
		if o.asset != nil {
			// The asset route: the core's own bytes into the pending
			// table, no copy through Go.
			font = BlobHandle(o.asset.blobHandle())
		} else {
			font = BlobHandle(RegisterBlob(o.font))
		}
	}
	tx.emit(TxSetBrandTypeface(mask, family, platforms, font))
}

// AppIdentity DECLARES the app's identity (docs/app-identity-plan.md):
// the name it goes by and the picture that stands for it.
//
//	tx.AppIdentity("Aurora Notes", markPNG)
//
// ONE PICTURE, FIVE PLATFORMS. The same bytes become the macOS Dock
// tile, the Windows taskbar icon and an X11 window's icon; the same
// FILE, read at build time, becomes the Android launcher and iOS Home
// Screen icons. Send a PNG: each lowering converts.
//
// SET ONCE, BEFORE THE FIRST MOUNT. The root refuses a second write, a
// late one, and an empty name.
//
// THE BYTES ARE NEVER INSPECTED between here and the platform's own
// decoder, so bytes that are not an image leave every platform's default
// in place — which is why the conformance scene reads what the DECODER
// produced. Nil bytes die at the root as the empty blob they are.
func (tx *Tx) AppIdentity(name string, icon []byte) {
	// The bytes go to the core ONCE, by handle, exactly as an image's
	// do — the record carries the handle, never the picture itself.
	tx.emit(TxSetAppIdentity(1, name, BlobHandle(RegisterBlob(icon))))
}

// AppIdentityAsset is AppIdentity with the mark THE APP'S OWN BUILD
// SHIPPED, opened by name through the core:
//
//	mark := tx.Asset("icons/kaya-mark.png")
//	defer mark.Close()
//	tx.AppIdentityAsset("Aurora Notes", mark)
//
// Same declaration by a different route: the picture never enters Go.
func (tx *Tx) AppIdentityAsset(name string, icon *Asset) {
	if icon == nil {
		panic("kaya: AppIdentityAsset got no asset — open one with tx.Asset(\"icons/...\"), or declare the name alone with AppIdentityNamed")
	}
	tx.emit(TxSetAppIdentity(1, name, BlobHandle(icon.blobHandle())))
}

// AppIdentityNamed is the NAME-ONLY form. Its identity still reaches
// every surface a name reaches, and every icon surface keeps the
// platform's own default, honestly and visibly.
func (tx *Tx) AppIdentityNamed(name string) {
	// The icon slot is written either way — an absent icon rides as an
	// empty Str — so the record's field count never varies with the
	// payload (the brand mask's discipline, verbatim).
	tx.emit(TxSetAppIdentity(0, name, ""))
}

// Window is the prop chain for an existing window (0 = the primary).
func (tx *Tx) Window(id uint64) WindowRef {
	return WindowRef{tx: tx, id: id}
}

// DestroyWindow closes and forgets an auxiliary window — also the
// veto grammar's confirmation and the reconciliation after a chrome
// close.
func (tx *Tx) DestroyWindow(id uint64) {
	tx.emit(TxDestroyWindow(id))
}

// MountIn mounts a root into a specific window; mounting presents an
// auxiliary.
func (tx *Tx) MountIn(window uint64, root Widget) {
	tx.emit(TxMount(window, root.id))
}

// PushEntry pushes a navigation entry onto the primary surface's stack
// (entry ids are guest-allocated in the shared surface namespace); it
// materializes covered and a MountIn presents it. Returns the prop
// chain.
func (tx *Tx) PushEntry(id uint64) EntryRef {
	tx.emit(TxPushEntry(0, id))
	return EntryRef{tx: tx, id: id}
}

// PushEntryIn pushes onto another window's stack (the System
// Settings shape: a stack inside a desktop auxiliary).
func (tx *Tx) PushEntryIn(window, id uint64) EntryRef {
	tx.emit(TxPushEntry(window, id))
	return EntryRef{tx: tx, id: id}
}

// PopEntry pops the primary stack's top entry and forgets its tree —
// also the back-veto grammar's confirmation after OnBackRequested.
// Popping an empty stack is a scene error.
func (tx *Tx) PopEntry() {
	tx.emit(TxPopEntry(0))
}

func (tx *Tx) PopEntryIn(window uint64) {
	tx.emit(TxPopEntry(window))
}

// AddSection appends a section to the primary window's section set. The
// set is APPEND-ONLY, and every section's root is retained while covered
// — switching is SELECTION, not lifecycle. A MountIn fills its pane.
func (tx *Tx) AddSection(id uint64) SectionRef {
	tx.emit(TxAddSection(0, id))
	return SectionRef{tx: tx, id: id}
}

// AddSectionIn appends onto another window's section set.
func (tx *Tx) AddSectionIn(window, id uint64) SectionRef {
	tx.emit(TxAddSection(window, id))
	return SectionRef{tx: tx, id: id}
}

// SelectSection selects a section programmatically: configuration,
// never echoes OnSelected (the echo doctrine).
func (tx *Tx) SelectSection(id uint64) {
	tx.emit(TxSelectSection(0, id))
}

func (tx *Tx) SelectSectionIn(window, id uint64) {
	tx.emit(TxSelectSection(window, id))
}

// ShowAlert requests a modal alert: a chain ending in Show, which sends
// the one atomic record. The result handler rides the REQUEST and
// retires with its one answer. Up to two actions (the platform floor);
// the cancel label is REQUIRED and explicit. One alert may be live per
// process; show the next from the handler.
func (tx *Tx) ShowAlert() AlertRef {
	tx.app.c.alert++
	return AlertRef{tx: tx, id: tx.app.c.alert}
}

// AlertRef accumulates the one atomic SHOW_ALERT record; nothing is
// sent until Show (a request has a send moment, unlike a window
// declaration).
type AlertRef struct {
	tx       *Tx
	id       uint64
	window   uint64
	title    string
	message  string
	actions  []string
	cancel   string
	onResult func(*Tx, uint32)
}

// InWindow presents over this window instead of the primary.
func (r AlertRef) InWindow(window uint64) AlertRef {
	r.window = window
	return r
}

func (r AlertRef) Title(title string) AlertRef {
	r.title = title
	return r
}

func (r AlertRef) Message(message string) AlertRef {
	r.message = message
	return r
}

// Action adds an action button (at most two — the platform floor;
// the third panics at construction, matching the scene gate).
func (r AlertRef) Action(label string) AlertRef {
	if len(r.actions) >= 2 {
		panic("kaya: an alert carries at most 2 actions (the platform floor)")
	}
	r.actions = append(r.actions, label)
	return r
}

// Cancel names the always-present cancel slot. Required.
func (r AlertRef) Cancel(label string) AlertRef {
	r.cancel = label
	return r
}

// OnResult binds the one-shot result handler to THIS request: choice
// is an action index (0 or 1) or AlertChoiceCancel — every
// platform-native dismissal. The registration retires with the
// result.
func (r AlertRef) OnResult(fn func(*Tx, uint32)) AlertRef {
	r.onResult = fn
	return r
}

// Show sends the request, returning its id; the one answer arrives
// at the OnResult handler.
func (r AlertRef) Show() uint64 {
	if r.cancel == "" {
		panic("kaya: the cancel slot always exists and needs a name — call Cancel(label) before Show()")
	}
	if r.onResult != nil {
		r.tx.app.alerts[r.id] = r.onResult
	}
	action0, action1 := "", ""
	if len(r.actions) >= 1 {
		action0 = r.actions[0]
	}
	if len(r.actions) == 2 {
		action1 = r.actions[1]
	}
	r.tx.emit(TxShowAlert(
		r.window, r.id, uint32(len(r.actions)),
		r.title, r.message, action0, action1, r.cancel))
	return r.id
}

// PickFiles asks the platform for files. THE PICK, NOT THE OPEN — the
// result carries handles you redeem later (DESIGN.md, File dialogs). A
// chain ending in Show, like ShowAlert. One dialog may be live per
// process; show the next from the first's result handler.
func (tx *Tx) PickFiles() FileDialogRef {
	tx.app.c.fileDialog++
	return FileDialogRef{tx: tx, id: tx.app.c.fileDialog, multiple: true}
}

// PickFile is the single-file spelling. The floor always returns a
// LIST; this only asks the platform for one, so the handler receives
// zero or one file.
func (tx *Tx) PickFile() FileDialogRef {
	r := tx.PickFiles()
	r.multiple = false
	return r
}

// FileDialogRef accumulates the one atomic SHOW_FILE_DIALOG record;
// nothing is sent until Show (a request has a send moment, unlike a
// window declaration).
type FileDialogRef struct {
	tx       *Tx
	id       uint64
	window   uint64
	multiple bool
	filters  []string
	onResult func(*Tx, []PickedFile)
}

// In targets an auxiliary window (0 = primary).
func (r FileDialogRef) In(window uint64) FileDialogRef {
	r.window = window
	return r
}

// Filter adds one advisory (label, extensions) pair — extensions
// space-separated. ADVISORY on every platform: they set a default view
// rather than a guarantee, so the guest still validates what it got.
func (r FileDialogRef) Filter(label, extensions string) FileDialogRef {
	r.filters = append(r.filters, label, extensions)
	return r
}

// OnResult binds the one-shot result handler to THIS request. The
// registration retires with the answer; CANCEL IS THE EMPTY LIST.
func (r FileDialogRef) OnResult(fn func(*Tx, []PickedFile)) FileDialogRef {
	r.onResult = fn
	return r
}

// Show sends the request, returning its id; the one answer arrives at
// the OnResult handler.
func (r FileDialogRef) Show() uint64 {
	if r.onResult != nil {
		r.tx.app.fileDialogs[r.id] = r.onResult
	}
	multiple := uint32(0)
	if r.multiple {
		multiple = 1
	}
	values := make([]any, 0, len(r.filters))
	for _, f := range r.filters {
		values = append(values, f)
	}
	r.tx.emit(TxShowFileDialog(r.window, r.id, multiple, values))
	return r.id
}

// SaveFile asks the platform WHERE TO SAVE. The picker's twin: the same
// chain, the same one id space, the same one-live-dialog rule
// (docs/save-plan.md D2).
//
//	tx.SaveFile("notes").OnResult(func(tx *kaya.Tx, file *kaya.PickedFile) {
//	    if file == nil { return } // the user cancelled
//	    …
//	}).Show()
//
// suggestedName rides the CONSTRUCTOR rather than the chain because a
// save dialog with an empty name box is one no platform lets the user
// complete. Every platform takes it and none guarantees it — Android may
// append an extension — so READ THE NAME YOU GOT.
//
// WHAT COMES BACK OPENS EMPTY: the handle's Open CREATES, so
// FileModeWrite yields an empty file on every platform
// (docs/save-plan.md D1).
func (tx *Tx) SaveFile(suggestedName string) SaveDialogRef {
	tx.app.c.fileDialog++
	return SaveDialogRef{tx: tx, id: tx.app.c.fileDialog, name: suggestedName}
}

// SaveDialogRef accumulates the one atomic SHOW_SAVE_DIALOG record;
// nothing is sent until Show, exactly like the picker's chain.
type SaveDialogRef struct {
	tx       *Tx
	id       uint64
	window   uint64
	name     string
	filters  []string
	onResult func(*Tx, *PickedFile)
}

// In targets an auxiliary window (0 = primary).
func (r SaveDialogRef) In(window uint64) SaveDialogRef {
	r.window = window
	return r
}

// Filter adds one advisory (label, extensions) pair — extensions
// space-separated, the picker's rule verbatim: a default view, never a
// guarantee.
//
// AND IT IS NOT FREE ON A SAVE DIALOG the way it is on a picker: with an
// allowed type set, NSSavePanel APPENDS the first extension to a name
// that has none, so a filter changes the name the user gets rather than
// only what they see (measured — docs/probes/save-probe-mac.md).
func (r SaveDialogRef) Filter(label, extensions string) SaveDialogRef {
	r.filters = append(r.filters, label, extensions)
	return r
}

// OnResult binds the one-shot result handler to THIS request. The
// registration retires with the answer; CANCEL IS A NIL FILE.
//
// One file or none, and the narrowing happens HERE: "exactly one locator
// or none" is a fact of the REQUEST, not something every app should
// re-derive from the length of a list.
func (r SaveDialogRef) OnResult(fn func(*Tx, *PickedFile)) SaveDialogRef {
	r.onResult = fn
	return r
}

// Show sends the request, returning its id; the one answer arrives at
// the OnResult handler.
func (r SaveDialogRef) Show() uint64 {
	if r.onResult != nil {
		// ONE TABLE FOR BOTH DIALOG KINDS: the result record is a
		// file_dialog_result whichever dialog asked, so a second table
		// would be two ways to answer the same id.
		fn := r.onResult
		r.tx.app.fileDialogs[r.id] = func(tx *Tx, files []PickedFile) {
			if len(files) == 0 {
				fn(tx, nil)
				return
			}
			file := files[0]
			fn(tx, &file)
		}
	}
	values := make([]any, 0, len(r.filters))
	for _, f := range r.filters {
		values = append(values, f)
	}
	r.tx.emit(TxShowSaveDialog(r.window, r.id, r.name, values))
	return r.id
}

// --- The clipboard (DESIGN.md, Clipboard) --------------------------
//
// A clip is not a string: every host models it as ONE item available in
// several types, with the consumer taking the richest it understands. So
// COPY TAKES A RECORD and the two answers are a SUM.
//
// kaya DERIVES NOTHING between representations: a bad auto-derivation
// degrades every paste into a plain field silently.

// Representation is one representation, arriving — the sum a copy is the
// record of, as a sealed interface with one struct per constructor:
//
//	switch clip := clip.(type) {
//	case nil:                 // the universal empty answer
//	case kaya.TextClip:       _ = clip.Text
//	case kaya.FilesClip:      _ = clip.Files
//	}
type Representation interface{ isRepresentation() }

// TextClip is plain text.
type TextClip struct{ Text string }

// HTMLClip is an html fragment.
type HTMLClip struct{ HTML string }

// ClipImage is encoded image bytes. WHAT COMES BACK MAY BE A RE-ENCODE
// — the hosts convert freely between image types — so compare what the
// image IS, never the bytes it arrived in.
type ImageClip struct{ Bytes []byte }

// ClipFiles is files, plural INSIDE one representation — the nesting
// text/uri-list and CF_HDROP already have. A pasted file opens with the
// call the picker already has.
type FilesClip struct{ Files []PickedFile }

// ClipCustom is an app-defined format, round-tripped verbatim.
type CustomClip struct {
	ID    string
	Bytes []byte
}

func (TextClip) isRepresentation()   {}
func (HTMLClip) isRepresentation()   {}
func (ImageClip) isRepresentation()  {}
func (FilesClip) isRepresentation()  {}
func (CustomClip) isRepresentation() {}

// representation turns the decoder's kind-and-values into the sum, or
// nil. EMPTY IS THE UNIVERSAL NO: a denied prompt on iOS, an unfocused
// reader on Android or Wayland, an empty clipboard, and content in no
// representation this read accepted. The platforms do not say which.
func representation(clip ClipValues) Representation {
	str := func(i int) string {
		if i < len(clip.Values) {
			s, _ := clip.Values[i].(string)
			return s
		}
		return ""
	}
	blob := func(i int) []byte {
		if i < len(clip.Values) {
			b, _ := clip.Values[i].([]byte)
			return b
		}
		return nil
	}
	switch clip.Kind {
	case ClipText:
		return TextClip{Text: str(0)}
	case ClipHtml:
		return HTMLClip{HTML: str(0)}
	case ClipImage:
		return ImageClip{Bytes: blob(0)}
	case ClipCustom:
		return CustomClip{ID: str(0), Bytes: blob(1)}
	case ClipFiles:
		// The picker's own three-per-file grouping, so a guest that
		// decodes a dialog result decodes this with the same loop.
		files := make([]PickedFile, 0, len(clip.Values)/3)
		for i := 0; i+2 < len(clip.Values); i += 3 {
			handle, _ := clip.Values[i].(int64)
			files = append(files, PickedFile{
				Handle: uint64(handle), Name: str(i + 1), LocalPath: str(i + 2)})
		}
		return FilesClip{Files: files}
	}
	return nil
}

// acceptList joins an accept list: the closed kinds by name plus any
// custom ids, space separated. A LIST AND NOT A MASK, because half the
// set is open-ended. Ids reach every platform's registry verbatim, so
// they carry NO SPACES — which is what makes the join unambiguous.
func acceptList(kinds []string) string {
	for _, kind := range kinds {
		if kind == "" || strings.Contains(kind, " ") {
			panic(fmt.Sprintf(
				"kaya: %q is not an accept-list entry — the closed kinds are "+
					"\"text\", \"html\", \"image\" and \"files\", and a custom "+
					"format id reaches the platform's own registry verbatim, "+
					"so it carries no spaces", kind))
		}
	}
	return strings.Join(kinds, " ")
}

// Copy begins a clip: fill in as many representations as the app wants
// to offer, and Send puts it on the system clipboard. A RECORD AND NOT A
// LIST — at most one per kind is structural.
func (tx *Tx) Copy() CopyRef {
	return CopyRef{tx: tx}
}

// CopyRef accumulates the one atomic COPY record; nothing reaches the
// clipboard until Send.
type CopyRef struct {
	tx     *Tx
	text   *string
	html   *string
	image  []byte
	files  []uint64
	custom [][2]any // id, bytes
}

func (r CopyRef) Text(text string) CopyRef {
	r.text = &text
	return r
}

func (r CopyRef) HTML(html string) CopyRef {
	r.html = &html
	return r
}

// Image offers encoded image bytes — the same currency the image
// property takes.
func (r CopyRef) Image(bytes []byte) CopyRef {
	r.image = bytes
	return r
}

// File offers a picked file, the picker's own capability put straight
// on the clipboard. The bytes never move through kaya.
func (r CopyRef) File(f PickedFile) CopyRef {
	r.files = append(r.files, f.Handle)
	return r
}

// Custom offers an app-defined format, round-tripped verbatim. The id
// reaches every platform's own registry unchanged, so it carries no
// spaces, and kaya does nothing clever with the bytes.
func (r CopyRef) Custom(id string, bytes []byte) CopyRef {
	acceptList([]string{id})
	r.custom = append(r.custom, [2]any{id, bytes})
	return r
}

// Send puts the clip on the system clipboard. The wire order is kaya's,
// not this chain's — descending richness, which is preference order on
// every host that has one, so a backend writes what it is handed in the
// order it is handed.
func (r CopyRef) Send() {
	var present uint32
	values := make([]any, 0, 8)
	for _, pair := range r.custom {
		values = append(values, pair[0])
		values = append(values, BlobHandle(RegisterBlob(pair[1].([]byte))))
	}
	for _, handle := range r.files {
		values = append(values, int64(handle))
	}
	if r.image != nil {
		present |= ClipImage
		values = append(values, BlobHandle(RegisterBlob(r.image)))
	}
	if r.html != nil {
		present |= ClipHtml
		values = append(values, *r.html)
	}
	if r.text != nil {
		present |= ClipText
		values = append(values, *r.text)
	}
	r.tx.emit(TxCopy(present, uint32(len(r.files)), uint32(len(r.custom)), values))
}

// ReadClipboard begins the privileged read.
//
// A user's paste costs nothing; this asks without a gesture, which the
// platforms have made expensive: iOS 16 PROMPTS when the content came
// from another app and blocks until the user answers, Android returns
// nothing unless the app has focus, and Wayland delivers no offer to an
// unfocused client. Never to implement Paste — that is the Paste
// command, and it is free.
func (tx *Tx) ReadClipboard() ClipReadRef {
	tx.app.c.clipboard++
	return ClipReadRef{tx: tx, id: tx.app.c.clipboard}
}

// ClipReadRef accumulates which representations the read can use, and
// the request id its one answer arrives under.
type ClipReadRef struct {
	tx        *Tx
	id        uint64
	accepting []string
	onResult  func(*Tx, Representation)
}

func (r ClipReadRef) Text() ClipReadRef  { return r.accept("text") }
func (r ClipReadRef) HTML() ClipReadRef  { return r.accept("html") }
func (r ClipReadRef) Image() ClipReadRef { return r.accept("image") }
func (r ClipReadRef) Files() ClipReadRef { return r.accept("files") }

// Custom accepts an app-defined format by id. Custom formats are tried
// FIRST, in the order named: an app's own format round-trips its data
// losslessly, which is the only reason to have one.
func (r ClipReadRef) Custom(id string) ClipReadRef { return r.accept(id) }

func (r ClipReadRef) accept(kind string) ClipReadRef {
	r.accepting = append(append([]string{}, r.accepting...), kind)
	return r
}

// OnResult binds the one-shot handler to THIS request. The registration
// retires with the answer, which is nil when the clipboard had nothing
// this read accepted — and nil equally when the read was denied or the
// app was unfocused, because no platform says which.
func (r ClipReadRef) OnResult(fn func(*Tx, Representation)) ClipReadRef {
	r.onResult = fn
	return r
}

// Send asks, returning the request id; the one answer arrives at the
// OnResult handler.
func (r ClipReadRef) Send() uint64 {
	if r.onResult != nil {
		r.tx.app.clipboardReads[r.id] = r.onResult
	}
	r.tx.emit(TxReadClipboard(r.id, acceptList(r.accepting)))
	return r.id
}

// SetAccepts declares what a widget takes from a paste — the closed
// kinds by name ("text", "html", "image", "files") plus any custom
// format ids. The dynamic path; the declarative spelling is the Accepts
// chain at construction.
func (tx *Tx) SetAccepts(w Widget, kinds ...string) {
	tx.emit(TxSetAccepts(w.id, acceptList(kinds)))
}

// Accepts declares what this widget takes from a paste, at construction:
// tx.Entry(nil).Accepts("text").
//
// ONE DECLARATION, THREE JOBS: it drives whether the Paste command is
// live while this widget is focused, it filters what can reach the paste
// hook, and on Android it IS the native registration. Per-widget because
// Paste's enablement is the INTERSECTION of what the clipboard offers
// and what the FOCUSED target takes.
//
// DECLARING IS HOW AN APP OVERRIDES THE DEFAULT: a widget that declares
// nothing gets the platform's own insertion and reports it through the
// ordinary change path.
func (w Widget) Accepts(kinds ...string) Widget {
	if w.tx == nil || w.tx.closed {
		panic("kaya: Accepts on a widget outside its build transaction — use Tx.SetAccepts inside a live transaction")
	}
	w.tx.SetAccepts(w, kinds...)
	return w
}

// OnPaste registers where pasted content lands for a live widget.
//
// COSTS NOTHING ON ANY PLATFORM, unlike ReadClipboard: a paste is a
// user gesture, so it is its own authorisation — iOS raises no prompt
// and the focus rules are satisfied by construction. Only fires for a
// widget that declared what it Accepts.
func (a *App) OnPaste(w Widget, fn func(*Tx, Representation)) {
	a.widgetPastes[w.id] = fn
}

// OnPasteNode registers a paste handler for a template node; the handler
// also receives the stamped copy's keys, outermost first.
//
// FIRES ONLY FOR COPIES WHOSE TEMPLATE DECLARED WHAT IT ACCEPTS
// (Tpl.SetAccepts), like the live hook (docs/tpl-props-plan.md §1). A
// copy that declares nothing gets the platform's own insertion.
func (a *App) OnPasteNode(n Node, fn func(*Tx, []any, Representation)) {
	a.nodePastes[n.id] = fn
}

// WindowRef chains window props, the construction-sugar tier.
type WindowRef struct {
	tx *Tx
	id uint64
}

func (w WindowRef) Title(title string) WindowRef {
	w.tx.emit(TxSetWindowTitle(w.id, title))
	return w
}

// Size requests the content size in DIP — advisory on every platform.
func (w WindowRef) Size(width, height float64) WindowRef {
	w.tx.emit(TxSetWindowWidth(w.id, width))
	w.tx.emit(TxSetWindowHeight(w.id, height))
	return w
}

// SectionsPresentation sets the window's ADVISORY sections hint
// (SectionsPresentationAuto/Bar/Sidebar — the width/height
// precedent; the phones ignore it by physics).
func (w WindowRef) SectionsPresentation(hint int64) WindowRef {
	w.tx.emit(TxSetWindowSectionsPresentation(w.id, hint))
	return w
}

// VetoClose arms the veto class: the close button emits
// close_requested and nothing closes until DestroyWindow agrees.
func (w WindowRef) VetoClose(on bool) WindowRef {
	w.tx.emit(TxSetWindowVetoClose(w.id, on))
	return w
}

// Panes is the CEILING on how many of this window's stack entries
// present side by side: 1 is the serial stack, 2 and 3 are columns on a
// window wide enough, the shallowest shed first as it narrows
// (docs/multicolumn-plan.md carries the ruling and the measured
// mechanics). There is deliberately no argument for WHICH entries show —
// the stack's order is the priority order — and the live count is the
// platform's own judgment where it has one. The root refuses 0 and
// anything above 3.
func (w WindowRef) Panes(ceiling uint32) WindowRef {
	w.tx.emit(TxSetWindowPanes(w.id, int64(ceiling)))
	return w
}

// Dirty says this surface holds UNSAVED WORK: each backend shows its
// platform's own affordance, and the phones have none
// (docs/dirty-plan.md D2/D4).
//
// STATE, NOT CHROME: the title you declared is left alone. It ARMS
// NOTHING either — "unsaved changes, close anyway?" is VetoClose plus a
// dialog, which is yours to compose.
func (w WindowRef) Dirty(on bool) WindowRef {
	w.tx.emit(TxSetWindowDirty(w.id, on))
	return w
}

// Inset sets the window's CONTENT INSET in layout units — LAYOUT, not
// appearance (docs/styling-plan.md D3). 16 unless you say otherwise; 0
// is full bleed, honored unconditionally because the inset is kaya's
// own padding.
//
// A platform's SAFE AREA is a separate fact and is not removed by it:
// a phone keeps its notch and home indicator whatever this says.
func (w WindowRef) Inset(units float64) WindowRef {
	w.tx.emit(TxSetWindowInset(w.id, units))
	return w
}

// OnCloseRequested binds the close-veto handler to THIS window: fires
// per chrome close while VetoClose is armed, and NOTHING HAS CLOSED —
// answer with tx.DestroyWindow to agree.
func (w WindowRef) OnCloseRequested(fn func(*Tx)) WindowRef {
	w.tx.app.closeRequested[w.id] = fn
	return w
}

// OnClosed binds the closed handler to THIS window: fires when the
// non-veto auxiliary is chrome-closed (informational; DestroyWindow
// reconciles), and retires with it.
func (w WindowRef) OnClosed(fn func(*Tx)) WindowRef {
	w.tx.app.windowClosed[w.id] = fn
	return w
}

// OnUndone binds the undone handler to THIS window: it fires each time
// kaya routes an undo there, with the group's label (EMPTY for a typing
// episode — kaya invents no user-facing strings) and what the core put
// back. NOT one-shot: a history is walked as often as the user likes.
//
// THE DELTA IS THE ONLY NOTIFICATION. Applying an inverse is a
// programmatic write, so the echo doctrine silences every occurrence it
// would cause. The binding has already folded this payload into its own
// mirror before the handler runs; this is where an app folds it into
// ITS model.
func (w WindowRef) OnUndone(fn func(*Tx, string, UndoDelta)) WindowRef {
	w.tx.app.undone[w.id] = fn
	return w
}

// OnRedone is the OnUndone twin. A frontier typing episode redoes on the
// platform's own stack and reports itself as an ordinary edit, so it
// does not arrive here.
func (w WindowRef) OnRedone(fn func(*Tx, string, UndoDelta)) WindowRef {
	w.tx.app.redone[w.id] = fn
	return w
}

// Id returns the window id, for MountIn.
func (w WindowRef) Id() uint64 {
	return w.id
}

// Menu declares a top-level menu in this window's command catalog — the
// menubar rides the window construct (DESIGN.md, Menus). Returns the
// retained grouping handle; reopen it in a later transaction with
// tx.Menu(file).
func (w WindowRef) Menu(label string) MenuItem {
	m := newMenuItem(w.tx, MenuKindMenu, label, false)
	w.tx.emit(TxMenubarAppend(w.id, m.id))
	return m
}

// RadioGroup declares a BAR-LEVEL radio group. Declare only Option
// children and chain BindValue/Value AFTER them; programmatic writes
// are quiet, and OnSelect gets each USER pick's new index.
func (w WindowRef) RadioGroup(label string) MenuItem {
	m := newMenuItem(w.tx, MenuKindRadioGroup, label, false)
	w.tx.emit(TxMenubarAppend(w.id, m.id))
	return m
}

// EntryRef chains navigation-entry props, the construction-sugar tier.
type EntryRef struct {
	tx *Tx
	id uint64
}

// Title names the entry — the back affordance's label source.
func (e EntryRef) Title(title string) EntryRef {
	e.tx.emit(TxSetEntryTitle(e.id, title))
	return e
}

// InterceptBack arms the close-veto class transplanted to POP: back
// emits back_requested and nothing pops until PopEntry agrees.
func (e EntryRef) InterceptBack(on bool) EntryRef {
	e.tx.emit(TxSetEntryInterceptBack(e.id, on))
	return e
}

// OnPopped binds the popped handler to THIS entry: fires when the user's
// back affordance pops it natively (post-fact; a programmatic PopEntry
// does not fire it), and retires with the one pop.
func (e EntryRef) OnPopped(fn func(*Tx)) EntryRef {
	e.tx.app.entryPopped[e.id] = fn
	return e
}

// OnBackRequested binds the back-veto handler to THIS entry: fires each
// time the user drives back while intercept_back is armed, and NOTHING
// HAS POPPED — answer with tx.PopEntry to agree.
func (e EntryRef) OnBackRequested(fn func(*Tx)) EntryRef {
	e.tx.app.backRequested[e.id] = fn
	return e
}

// Id returns the entry's surface id, for MountIn.
func (e EntryRef) Id() uint64 {
	return e.id
}

// SectionRef is the prop chain an AddSection rides.
type SectionRef struct {
	tx *Tx
	id uint64
}

// Title names the switcher item — the tab title on every platform.
func (r SectionRef) Title(title string) SectionRef {
	r.tx.emit(TxSetSectionTitle(r.id, title))
	return r
}

// Symbol sets the switcher item's SEMANTIC ICON, the same closed
// vocabulary MenuItem.Symbol takes. Const-only.
func (r SectionRef) Symbol(symbol int64) SectionRef {
	r.tx.emit(TxSetSectionSymbol(r.id, symbol))
	return r
}

// OnSelected binds the selected handler to THIS section: fires each
// time the USER switches to it — post-fact and NOT one-shot. A
// programmatic SelectSection does not fire it (the echo doctrine).
func (r SectionRef) OnSelected(fn func(*Tx)) SectionRef {
	r.tx.app.sectionSelected[r.id] = fn
	return r
}

// Id returns the section's surface id, for MountIn.
func (r SectionRef) Id() uint64 {
	return r.id
}

// --- Menus: the command vocabulary (DESIGN.md, Menus) ---------------
//
// MenuItem is a live menu item in its OWN id space behind its own type,
// so cross-use with widget or node ids is a compile error. The chain
// methods ride the transaction that minted the value and die with it;
// tx.Menu(item) reopens a retained handle in a later transaction.
type MenuItem struct {
	id uint64
	tx *Tx
	// ctx marks a context-anchored chain: a shortcut needs a window
	// catalog as its native dispatch home, so Shortcut panics here at
	// record time.
	ctx bool
}

func (m MenuItem) chain() *Tx {
	if m.tx == nil || m.tx.closed {
		panic("kaya: menu chain outside its transaction — reopen the retained handle with Tx.Menu inside a live transaction")
	}
	return m.tx
}

// newMenuItem creates one item in the menu-item id space. Menu records
// are LIVE-ZONE ONLY: items are shared across stamped copies, so build
// the catalog outside (Tx.ContextCatalog) and attach it inside the
// template with Tpl.ContextMenu.
func newMenuItem(tx *Tx, kind uint32, label string, ctx bool) MenuItem {
	if tx == nil || tx.closed {
		panic("kaya: menu declaration outside its transaction")
	}
	if tx.app.tplDepth > 0 {
		panic("kaya: menu items are live — build the context catalog in the live zone (Tx.ContextCatalog) and attach it inside the template with Tpl.ContextMenu")
	}
	tx.app.c.menuItem++
	m := MenuItem{id: tx.app.c.menuItem, tx: tx, ctx: ctx}
	tx.emit(TxMenuItemCreate(m.id, kind))
	if kind != MenuKindSeparator {
		tx.emit(TxSetMenuLabel(m.id, label))
	}
	return m
}

// child creates and appends one child under this grouping node (the
// closed parent/child grammar and the depth cap are root errors).
func (m MenuItem) child(kind uint32, label string) MenuItem {
	c := newMenuItem(m.chain(), kind, label, m.ctx)
	m.tx.emit(TxMenuItemAppend(m.id, c.id))
	return c
}

// Item appends an action — a leaf command firing exactly one
// menu_activated occurrence, whether from a click or its shortcut.
func (m MenuItem) Item(label string) MenuItem {
	return m.child(MenuKindAction, label)
}

// Toggle appends a stateful leaf on the Checkbox contract: user flips
// emit menu_toggled; programmatic checked writes are quiet.
func (m MenuItem) Toggle(label string) MenuItem {
	return m.child(MenuKindToggle, label)
}

// Menu appends a NESTED menu — grouping, never navigation. One nested
// grouping level is the cap (root-checked).
func (m MenuItem) Menu(label string) MenuItem {
	return m.child(MenuKindMenu, label)
}

// RadioGroup appends a NESTED radio group — the Choice contract
// inline, with the platform's checkmark idiom. Only Option children.
func (m MenuItem) RadioGroup(label string) MenuItem {
	return m.child(MenuKindRadioGroup, label)
}

// Option appends one labeled option (radio groups only) in declaration
// order: the order IS the index vocabulary the group's value selects
// over.
func (m MenuItem) Option(label string) MenuItem {
	return m.child(MenuKindRadioOption, label)
}

// Separator appends native grouping chrome: no label, no props, no
// handle kept.
func (m MenuItem) Separator() {
	c := newMenuItem(m.chain(), MenuKindSeparator, "", m.ctx)
	m.tx.emit(TxMenuItemAppend(m.id, c.id))
}

// Label renames the item to constant text; never emits an occurrence.
func (m MenuItem) Label(text string) MenuItem {
	m.chain().emit(TxSetMenuLabel(m.id, text))
	return m
}

// BindLabel binds the item's label to a Str signal.
func (m MenuItem) BindLabel(s Signal[string]) MenuItem {
	m.chain().emit(TxBindMenuLabel(m.id, s.id))
	return m
}

// Enabled sets whether the item is enabled (default true); never emits.
// Disabling a grouping node disables its subtree everywhere.
func (m MenuItem) Enabled(on bool) MenuItem {
	m.chain().emit(TxSetMenuEnabled(m.id, on))
	return m
}

// BindEnabled binds the item's enablement to a Bool signal.
func (m MenuItem) BindEnabled(s Signal[bool]) MenuItem {
	m.chain().emit(TxBindMenuEnabled(m.id, s.id))
	return m
}

// Checked sets a toggle's state (toggle items only). QUIET: no
// menu_toggled echo.
func (m MenuItem) Checked(on bool) MenuItem {
	m.chain().emit(TxSetMenuChecked(m.id, on))
	return m
}

// BindChecked binds a toggle's state to a Bool signal, both ways.
func (m MenuItem) BindChecked(s Signal[bool]) MenuItem {
	m.chain().emit(TxBindMenuChecked(m.id, s.id))
	return m
}

// Value sets a radio group's selected option index. QUIET, like Checked.
func (m MenuItem) Value(index int) MenuItem {
	m.chain().emit(TxSetMenuValue(m.id, float64(index)))
	return m
}

// BindValue binds a radio group's selected index to a float signal,
// both ways.
func (m MenuItem) BindValue(s Signal[float64]) MenuItem {
	m.chain().emit(TxBindMenuValue(m.id, s.id))
	return m
}

// Icon sets the item's icon (the blob channel): used by phone promotion,
// ignored where native menu dress has no icons. Const-only.
func (m MenuItem) Icon(data []byte) MenuItem {
	m.chain().emit(TxSetMenuIcon(m.id, RegisterBlob(data)))
	return m
}

// Symbol sets the item's SEMANTIC ICON (docs/styling-plan.md D6). The app
// names a CONCEPT and each backend draws its own platform's glyph — SF
// Symbols are license-locked to Apple, so a shared asset is not even
// legal. BESIDE Icon, not instead of it.
//
// SymbolBack and SymbolForward mean BACKWARD and FORWARD in READING
// ORDER, never left and right. SymbolDelete is the wastebasket,
// SymbolRemove takes an item out of a list, SymbolClose is the ✕.
//
// The vocabulary is CLOSED and an out-of-vocabulary number dies AT THE
// ROOT at declare time. Const-only.
func (m MenuItem) Symbol(symbol int64) MenuItem {
	m.chain().emit(TxSetMenuSymbol(m.id, symbol))
	return m
}

// Primary sets the phone-bar promotion hint (actions only). INERT on
// desktops — not a toolbar grammar. Const-only.
func (m MenuItem) Primary(on bool) MenuItem {
	m.chain().emit(TxSetMenuPrimary(m.id, on))
	return m
}

// RoleSettings names the app's settings command — the closed
// standard-command vocabulary (DESIGN.md, Menus).
//
// A NAMED VOCABULARY FOR THE CLOSED HALF. A MISTYPED BARE STRING IS
// SILENT: it becomes a custom format id no clipboard will ever offer,
// so Paste stays dead and the paste hook never fires.
const (
	AcceptText = "text"
	AcceptHtml = "html"
	AcceptImage = "image"
	AcceptFiles = "files"
)

const RoleSettings = "settings"

// The three clipboard commands. They lower to the platform's own, act on
// the FOCUSED widget, and work out their own enablement.
//
// GESTURES ARE COMMANDS BECAUSE KAYA HAS NO SELECTION API: only the
// widget knows what is selected. Tx.Copy and Tx.ReadClipboard are for
// overriding that default and for targets with no native behaviour.
const (
	RoleCut   = "cut"
	RoleCopy  = "copy"
	RolePaste = "paste"
)

// The two history commands: they ask the FOCUSED widget FIRST, so
// mid-typing Undo means the typing and after an app action it means the
// action (docs/undo-plan.md D6). An app that names no group still gets
// working text undo from these items.
const (
	RoleUndo = "undo"
	RoleRedo = "redo"
)

// Role declares this action a standard command (actions only). The
// declaration is uniform; PLACEMENT is each host's business. One item
// per role, and a role NEVER invents a chord — spell Shortcut too if
// the app wants one. Const-only.
func (m MenuItem) Role(name string) MenuItem {
	if m.ctx {
		panic("kaya: a context item takes no role — a role names a standard command in the window catalog")
	}
	m.chain().emit(TxSetMenuRole(m.id, name))
	return m
}

// Shortcut sets the shortcut of any LEAF command (window-anchored only),
// canonicalized by CanonicalizeShortcut. It fires the SAME
// menu_activated occurrence as a click. Const-only.
func (m MenuItem) Shortcut(spelling string) MenuItem {
	if m.ctx {
		panic("kaya: a context item takes no shortcut — a shortcut needs a window catalog as its native dispatch home")
	}
	m.chain().emit(TxSetMenuShortcut(m.id, spelling))
	return m
}

// OnActivate binds this action's handler. A click and its shortcut are
// ONE occurrence on one dispatch path, so it covers both.
func (m MenuItem) OnActivate(fn func(*Tx)) MenuItem {
	m.chain().app.menuActivated[m.id] = fn
	return m
}

// OnActivateNode is the template-node flavor: the copy's key path,
// outermost first — the keys ARE the noun the command acts on.
func (m MenuItem) OnActivateNode(fn func(*Tx, []any)) MenuItem {
	m.chain().app.menuActivatedNode[m.id] = fn
	return m
}

// OnToggle binds a toggle's handler: each USER flip's new state.
// Programmatic Checked writes are quiet.
func (m MenuItem) OnToggle(fn func(*Tx, bool)) MenuItem {
	m.chain().app.menuToggled[m.id] = fn
	return m
}

// OnToggleNode is the template-node flavor: the copy's keys, then the
// new state.
func (m MenuItem) OnToggleNode(fn func(*Tx, []any, bool)) MenuItem {
	m.chain().app.menuToggledNode[m.id] = fn
	return m
}

// OnSelect binds a radio group's handler, registered on the GROUP: each
// USER pick's new 0-based index. Programmatic Value writes are quiet.
func (m MenuItem) OnSelect(fn func(*Tx, int)) MenuItem {
	m.chain().app.menuSelected[m.id] = fn
	return m
}

// OnSelectNode is the template-node flavor: the copy's keys, then the
// new index.
func (m MenuItem) OnSelectNode(fn func(*Tx, []any, int)) MenuItem {
	m.chain().app.menuSelectedNode[m.id] = fn
	return m
}

// Menu reopens a RETAINED menu item — the append-at-any-time discipline:
// tx.Menu(file).Label("Document").Item("Publish"). The root judges a
// misapplied prop exactly as at construction.
func (tx *Tx) Menu(item MenuItem) MenuItem {
	return MenuItem{id: item.id, tx: tx}
}

// ContextRef is a live widget's context anchor: the same item vocabulary
// as the bar, scoped to a NOUN. No shortcuts here (record-time checked).
type ContextRef struct {
	tx     *Tx
	widget uint64
}

// ContextMenu opens the context anchor on a live widget; the platform's
// own gesture presents the catalog. Calling it again appends more roots.
func (tx *Tx) ContextMenu(w Widget) ContextRef {
	return ContextRef{tx: tx, widget: w.id}
}

func (c ContextRef) root(kind uint32, label string) MenuItem {
	m := newMenuItem(c.tx, kind, label, true)
	c.tx.emit(TxContextAttach(c.widget, m.id))
	return m
}

// Item attaches an action root; chain OnActivate beside it.
func (c ContextRef) Item(label string) MenuItem { return c.root(MenuKindAction, label) }

// Toggle attaches a toggle root; chain OnToggle beside it.
func (c ContextRef) Toggle(label string) MenuItem { return c.root(MenuKindToggle, label) }

// Menu attaches a grouping root (one nested grouping level — the
// context depth cap is root-checked).
func (c ContextRef) Menu(label string) MenuItem { return c.root(MenuKindMenu, label) }

// RadioGroup attaches a radio-group root; declare only Option
// children.
func (c ContextRef) RadioGroup(label string) MenuItem { return c.root(MenuKindRadioGroup, label) }

// Separator attaches native grouping chrome.
func (c ContextRef) Separator() { c.root(MenuKindSeparator, "") }

// ContextCatalog is a context catalog built UNANCHORED for a template
// node: menu items are live and shared across stamped copies, so it is
// built in the LIVE zone and Tpl.ContextMenu attaches it inside the
// template. An item takes exactly one anchor — a second attach panics.
type ContextCatalog struct {
	tx       *Tx
	roots    []uint64
	attached bool
}

// ContextCatalog builds free context roots for a later template-node
// attach.
func (tx *Tx) ContextCatalog() *ContextCatalog {
	return &ContextCatalog{tx: tx}
}

func (c *ContextCatalog) root(kind uint32, label string) MenuItem {
	m := newMenuItem(c.tx, kind, label, true)
	c.roots = append(c.roots, m.id)
	return m
}

// Item collects an action root; chain OnActivateNode beside it.
func (c *ContextCatalog) Item(label string) MenuItem { return c.root(MenuKindAction, label) }

// Toggle collects a toggle root; chain OnToggleNode beside it.
func (c *ContextCatalog) Toggle(label string) MenuItem { return c.root(MenuKindToggle, label) }

// Menu collects a grouping root.
func (c *ContextCatalog) Menu(label string) MenuItem { return c.root(MenuKindMenu, label) }

// RadioGroup collects a radio-group root; chain OnSelectNode.
func (c *ContextCatalog) RadioGroup(label string) MenuItem { return c.root(MenuKindRadioGroup, label) }

// Separator collects native grouping chrome.
func (c *ContextCatalog) Separator() { c.root(MenuKindSeparator, "") }

func (tx *Tx) Mount(root Widget) {
	tx.emit(TxMount(0, root.id))
}

// Tpl is a template body: the same declaration vocabulary with
// template-node ids, plus element bindings.
type Tpl struct {
	tx *Tx
}

func (t *Tpl) Widget(kind uint32) Node {
	t.tx.app.c.widget++
	n := Node{t.tx.app.c.widget}
	t.tx.emit(TxCreateWidget(n.id, kind))
	t.tx.autoParent(n.id)
	return n
}

// setText is the template zone's FLOOR prop write, UNEXPORTED so the
// floor gate can tell it from the live verb Tx.SetText — the two were
// both spelled SetText, and no line-oriented reader sees a receiver
// type. A guest reaching for it now fails to compile
// (docs/tpl-props-plan.md F3).
func (t *Tpl) setText(n Node, text string) {
	t.tx.emit(TxSetText(n.id, text))
}

// BindTextElement binds text to the element of the enclosing For,
// `level` Fors up (0 = nearest).
func (t *Tpl) BindTextElement(n Node, level uint32) {
	t.tx.emit(TxBindTextElement(n.id, level, 0))
}

// SetGrow weights a template node within its stamped row or column —
// the template twin of Tx.SetGrow, spelled as a METHOD rather than a
// chain because a Node is a plain id with no transaction to chain from.
// EVERY PROP BELOW FOLLOWS THAT SENTENCE.
//
// Scroll needs it: an unconstrained viewport hugs its content, so a
// template scroll without a grow weight cannot scroll.
//
// Spacing and align stay unreachable on a Node and stay ledgered
// (docs/deferred.md).
func (t *Tpl) SetGrow(n Node, weight float64) {
	t.tx.emit(TxSetGrow(n.id, weight))
}

// SetA11yID gives every stamped copy THE SAME accessibility identifier.
// A CONSTANT IS OFTEN THE WRONG HALF HERE: an identifier is an
// automation KEY, so N copies sharing one leave a harness with N
// indistinguishable targets. Duplicates are legal and sometimes right,
// but BindA11yID over the row's own field is what a list wants.
func (t *Tpl) SetA11yID(n Node, id string) {
	t.tx.emit(TxSetA11yId(n.id, id))
}

// BindA11yID sources each stamped copy's identifier from a VARYING
// source: a signal every copy follows, or a field of the row the copy
// was stamped for.
func (t *Tpl) BindA11yID[S interface {
	Signal[string] | Field[string]
}](n Node, src S) {
	t.applyStrProp(n, src, TxBindA11yId, TxBindA11yIdElement)
}

// SetA11yLabel gives every stamped copy the same SPOKEN name, with
// Tx.SetA11yLabel's override contract: unset keeps what the platform
// derives from the control's own content.
func (t *Tpl) SetA11yLabel(n Node, label string) {
	t.tx.emit(TxSetA11yLabel(n.id, label))
}

// BindA11yLabel sources each stamped copy's spoken name from a varying
// source — the row's own field being the case it exists for:
//
//	row.BindA11yLabel(done, row.Value()) // "Milk", not "checkbox"
//
// The binding is LIVE rather than a one-shot seed: a later UpdateField
// on that field re-speaks the copy.
func (t *Tpl) BindA11yLabel[S interface {
	Signal[string] | Field[string]
}](n Node, src S) {
	t.applyStrProp(n, src, TxBindA11yLabel, TxBindA11yLabelElement)
}

// SetA11yHint sets what ACTIVATING each stamped copy does — a verb
// phrase, spoken as written by VoiceOver and prefixed "double tap to"
// by TalkBack.
//
// ACTIVATION KINDS ONLY, and no wall here DELIBERATELY: a Node is a bare
// id and carries no kind, so a kind table here would be the root's list
// written a second time. The root rejects a misfit at DECLARE time.
func (t *Tpl) SetA11yHint(n Node, hint string) {
	t.tx.emit(TxSetA11yHint(n.id, hint))
}

// BindA11yHint sources the hint per copy — "delete Milk" rather than
// "delete", which is the row-aware half of the same contract.
// Activation kinds only; see SetA11yHint.
func (t *Tpl) BindA11yHint[S interface {
	Signal[string] | Field[string]
}](n Node, src S) {
	t.applyStrProp(n, src, TxBindA11yHint, TxBindA11yHintElement)
}

// SetAccepts declares what each stamped copy takes from a paste. Entry
// and textarea only, checked at the root.
//
// CONST ONLY: an accept list describes the PROTOTYPE, not the row. THIS
// IS THE DECLARATION THAT TURNS App.OnPasteNode ON — every backend gates
// the paste occurrence on the focused widget's accept list
// (docs/tpl-props-plan.md §1).
func (t *Tpl) SetAccepts(n Node, kinds ...string) {
	t.tx.emit(TxSetAccepts(n.id, acceptList(kinds)))
}

// SetRole declares what each stamped copy MEANS — semantic emphasis,
// never appearance (docs/styling-plan.md D4). int64 because Go's closed
// vocabularies are untyped integer constants in the generated wire
// file, and a named type here would make the two tiers of one binding
// disagree about one prop's type.
//
// CONST ONLY, like SetAccepts: what a copy MEANS is a fact about the
// PROTOTYPE. No kind wall here deliberately — the root refuses a misfit
// at DECLARE time, naming both the role and the kind.
func (t *Tpl) SetRole(n Node, role int64) {
	t.tx.emit(TxSetRole(n.id, role))
}

// SetInset pads a stamped CONTAINER — DIP between its bounds and its
// children, uniform on all four sides (docs/styling-plan.md D3). Const
// for SetRole's reason; containers only, and the root says so at
// declare time.
func (t *Tpl) SetInset(n Node, pad float64) {
	t.tx.emit(TxSetInset(n.id, pad))
}

// LabelText creates a label with constant text in the blueprint. The
// bound flavors are the ELEMENT ones — Row.Label, RecordCollection.Label
// — since a blueprint's variable text comes from the element it is
// stamped for.
func (t *Tpl) LabelText(text string) Node {
	n := t.Widget(KindLabel)
	t.setText(n, text)
	return n
}

// LabelBound creates a label whose text comes from a VARYING source — a
// signal every stamped copy follows, or a field of the row the copy was
// stamped for. The const flavor is LabelText.
//
// The BASE surface takes no field PROJECTION, only a resolved token: a
// projection is func(*T) *string and *Tpl knows no T. The typed
// surfaces do, and that is the whole of what they add here.
func (t *Tpl) LabelBound[S interface {
	Signal[string] | Field[string]
}](src S) Node {
	n := t.Widget(KindLabel)
	t.applyText(n, src)
	return n
}

// Button creates a button with its caption in the blueprint.
//
// IT TAKES NO HANDLER, and the omission is the design: a click names
// WHICH copy by key path, so the app registers one handler centrally
// against the template node (App.OnClickNode). The live zone's
// func(*Tx) has nowhere to put the keys.
func (t *Tpl) Button(text string) Node {
	n := t.Widget(KindButton)
	t.setText(n, text)
	return n
}

// ButtonBound creates a button whose CAPTION comes from a varying
// source. Clicks still register centrally against the node
// (App.OnClickNode); see Tpl.Button.
func (t *Tpl) ButtonBound[S interface {
	Signal[string] | Field[string]
}](src S) Node {
	n := t.Widget(KindButton)
	t.applyText(n, src)
	return n
}

// Entry creates an empty text field in the blueprint, UNCONTROLLED the
// same way Tx.Entry is: every stamped copy starts empty and owns its own
// text from the first keystroke. EntryBound seeds each copy from its row.
//
// IT TAKES NO HANDLER, for Tpl.Button's reason: the app registers once
// against the node (App.OnChangeNode).
func (t *Tpl) Entry() Node {
	return t.Widget(KindEntry)
}

// EntryBound creates a text field whose INITIAL text comes from a
// varying source: one write per stamped copy, not a leash — the copy
// owns its text afterwards.
//
// The copy's edits do NOT flow back to the field, and a later
// UpdateField on that row WILL overwrite what the user typed, because
// the seed is recorded as a real element binding. Same rule in all
// eight bindings.
func (t *Tpl) EntryBound[S interface {
	Signal[string] | Field[string]
}](src S) Node {
	n := t.Widget(KindEntry)
	t.applyText(n, src)
	return n
}

// Textarea creates an empty multi-line editor in the blueprint: the
// template twin of Tx.Textarea, with Tpl.Entry's uncontrolled contract
// over the platform's real multi-line control.
func (t *Tpl) Textarea() Node {
	return t.Widget(KindTextarea)
}

// TextareaBound seeds each stamped copy's editor from a varying source
// — Tpl.EntryBound's reasoning, one kind over.
func (t *Tpl) TextareaBound[S interface {
	Signal[string] | Field[string]
}](src S) Node {
	n := t.Widget(KindTextarea)
	t.applyText(n, src)
	return n
}

// Checkbox creates a checkbox at a constant checked state in the
// blueprint; CheckboxBound reads the row's own bit.
//
// THE SOURCE IS THE CHECKED BIT, NOT THE CAPTION, where the live
// Tx.Checkbox takes text: a prototype's caption is one string for every
// copy while its checked state is exactly the per-row datum.
func (t *Tpl) Checkbox(checked bool) Node {
	n := t.Widget(KindCheckbox)
	t.tx.emit(TxSetChecked(n.id, checked))
	return n
}

// CheckboxBound creates a checkbox whose state comes from a varying
// source. Toggles register against the node (App.OnToggleNode); the
// typed surfaces co-locate the handler because they can type its key.
func (t *Tpl) CheckboxBound[S interface {
	Signal[bool] | Field[bool]
}](src S) Node {
	n := t.Widget(KindCheckbox)
	t.applyChecked(n, src)
	return n
}

// Progress creates a progress bar at a constant fraction in the
// blueprint: display-only, like Label and Image. value is the
// determinate fraction (0..=1, domain-checked at the root);
// ProgressBound reads the row's own, and ProgressIndeterminate is the
// activity mode.
func (t *Tpl) Progress(value float64) Node {
	n := t.Widget(KindProgress)
	t.tx.emit(TxSetValue(n.id, value))
	return n
}

// ProgressBound creates a progress bar whose fraction comes from a
// varying source — the per-row case this zone exists for, one bar per
// row showing that row's own progress.
func (t *Tpl) ProgressBound[S interface {
	Signal[float64] | Field[float64]
}](src S) Node {
	n := t.Widget(KindProgress)
	t.applyValue(n, src)
	return n
}

// ProgressIndeterminate creates a progress bar in the platform's
// activity mode: no fraction, so nothing to source. A statement rather
// than a chain, because a Node carries no transaction.
func (t *Tpl) ProgressIndeterminate() Node {
	n := t.Widget(KindProgress)
	t.tx.emit(TxSetIndeterminate(n.id, true))
	return n
}

// Slider creates a slider over min..max at a constant position in the
// blueprint. THE RANGE DESCRIBES THE PROTOTYPE and stays constant; only
// the position is per-row (SliderBound). No handler, for Tpl.Button's
// reason — register against the node (App.OnValueChangedNode).
func (t *Tpl) Slider(min, max, value float64) Node {
	n := t.Widget(KindSlider)
	t.tx.emit(TxSetMin(n.id, min))
	t.tx.emit(TxSetMax(n.id, max))
	t.tx.emit(TxSetValue(n.id, value))
	return n
}

// SliderBound creates a slider over min..max whose POSITION comes from
// a varying source.
func (t *Tpl) SliderBound[S interface {
	Signal[float64] | Field[float64]
}](min, max float64, src S) Node {
	n := t.Widget(KindSlider)
	t.tx.emit(TxSetMin(n.id, min))
	t.tx.emit(TxSetMax(n.id, max))
	t.applyValue(n, src)
	return n
}

// Select creates a dropdown over fixed options in the blueprint at
// selected, the initial 0-based index. SelectBound sources the index
// per row; picks register against the node (App.OnValueChangedNode).
//
// THE OPTION LIST CANNOT VARY PER ROW — the protocol's limit, not this
// surface's: a choice widget's options are its label CHILDREN and a
// blueprint's children are fixed at declaration. The selected INDEX is
// the part that varies (docs/sugar-pass-plan.md §2).
func (t *Tpl) Select(options []string, selected int) Node {
	n := t.choiceOf(KindSelect, options)
	t.tx.emit(TxSetValue(n.id, float64(selected)))
	return n
}

// SelectBound creates a dropdown whose selected index comes from a
// varying source. THE INDEX RIDES A float64, so a record field backing
// one is declared float64: the scene checks a bound field's wire type
// against the property's exactly, and `value` is F64 there.
func (t *Tpl) SelectBound[S interface {
	Signal[float64] | Field[float64]
}](options []string, src S) Node {
	n := t.choiceOf(KindSelect, options)
	t.applyValue(n, src)
	return n
}

// Radio is Tpl.Select's inline presentation: same option children, same
// 0-based selected index.
func (t *Tpl) Radio(options []string, selected int) Node {
	n := t.choiceOf(KindRadio, options)
	t.tx.emit(TxSetValue(n.id, float64(selected)))
	return n
}

// RadioBound is Tpl.SelectBound's inline presentation: same option
// children, same F64-sourced 0-based index.
func (t *Tpl) RadioBound[S interface {
	Signal[float64] | Field[float64]
}](options []string, src S) Node {
	n := t.choiceOf(KindRadio, options)
	t.applyValue(n, src)
	return n
}

// Image displays constant encoded bytes in the blueprint: ONE
// registration at declaration, shared by every stamped copy.
// ImageBound is the per-row flavor.
func (t *Tpl) Image(source []byte) Node {
	n := t.Widget(KindImage)
	t.tx.emit(TxSetSource(n.id, uint64(blobWire(source))))
	return n
}

// Canvas creates a canvas per stamped copy — a sparkline in a table
// cell, which is the case set_drawing grew its keys-first addressing for
// (docs/canvas-plan.md §3.1). The drawing is declared with the node, so
// every copy is born with it; Tx.DrawAt re-declares one copy's
// afterwards.
func (t *Tpl) Canvas(vb Viewbox, body func(d *Draw)) Node {
	n := t.Widget(KindCanvas)
	d := &Draw{viewbox: vb}
	body(d)
	t.tx.emit(TxSetDrawing(n.id, vb.W, vb.H, uint32(len(d.ops)), 0, d.ops))
	return n
}

// ImageBound creates an image whose bytes come from a varying source. A
// blob signal re-registers its bytes on every write; a blob FIELD is the
// per-row case.
func (t *Tpl) ImageBound[S interface {
	Signal[[]byte] | Field[[]byte]
}](src S) Node {
	n := t.Widget(KindImage)
	t.applyBlob(n, src)
	return n
}

// The template flavor of the containers.
func (t *Tpl) Row(body func()) Node {
	return t.containerOf(KindRow, body)
}

func (t *Tpl) Column(body func()) Node {
	return t.containerOf(KindColumn, body)
}

// Scroll is a vertical scroll viewport over exactly one child per
// stamped copy. A Node has no chain, so the template spelling of the
// live zone's .Grow(1) is t.SetGrow(n, 1) beside the constructor — a
// stamped viewport WITHOUT one cannot scroll. The "exactly one child"
// rule is checked on the live AddChild arm only, so nothing rejects a
// second child in a blueprint.
func (t *Tpl) Scroll(body func()) Node {
	return t.containerOf(KindScroll, body)
}

// Grid lays each stamped copy's children row-major into columns
// columns. THE COLUMN COUNT DESCRIBES THE PROTOTYPE, so it is a
// constant: a shape that varied per copy would not be one grid.
func (t *Tpl) Grid(columns int, body func()) Node {
	parent := t.Widget(KindGrid)
	// The columns write lands BEFORE the body opens, as in the live twin.
	t.tx.emit(TxSetColumns(parent.id, float64(columns)))
	t.tx.app.parents = append(t.tx.app.parents, parent.id)
	if body != nil {
		body()
	}
	t.tx.app.parents = t.tx.app.parents[:len(t.tx.app.parents)-1]
	return parent
}

// Spacer is an empty grown column in the blueprint, consuming the
// leftover main-axis space between its siblings.
func (t *Tpl) Spacer() Node {
	n := t.Widget(KindColumn)
	t.tx.emit(TxSetGrow(n.id, 1))
	return n
}

func (t *Tpl) containerOf(kind uint32, body func()) Node {
	parent := t.Widget(kind)
	t.tx.app.parents = append(t.tx.app.parents, parent.id)
	if body != nil {
		body()
	}
	t.tx.app.parents = t.tx.app.parents[:len(t.tx.app.parents)-1]
	return parent
}

// choiceOf builds a choice widget's option children, shared by Select
// and Radio. The caller writes the index AFTER this returns, so the
// const and sourced flavors share one construction.
func (t *Tpl) choiceOf(kind uint32, options []string) Node {
	n := t.Widget(kind)
	t.tx.app.parents = append(t.tx.app.parents, n.id)
	for _, option := range options {
		o := t.Widget(KindLabel)
		t.setText(o, option)
	}
	t.tx.app.parents = t.tx.app.parents[:len(t.tx.app.parents)-1]
	return n
}

// The four lowerings the *Bound constructors share, one per wire value
// type: a signal every copy follows, or a field of the row the copy was
// stamped for. The third arm — a raw field PROJECTION — needs the
// record type and lives on RecordCollection and SumCase.

func (t *Tpl) applyText[S interface {
	Signal[string] | Field[string]
}](n Node, src S) {
	switch v := any(src).(type) {
	case Signal[string]:
		t.tx.emit(TxBindText(n.id, v.id))
	case Field[string]:
		t.BindTextField(n, 0, v)
	}
}

func (t *Tpl) applyChecked[S interface {
	Signal[bool] | Field[bool]
}](n Node, src S) {
	switch v := any(src).(type) {
	case Signal[bool]:
		t.tx.emit(TxBindChecked(n.id, v.id))
	case Field[bool]:
		t.BindCheckedField(n, 0, v)
	}
}

func (t *Tpl) applyValue[S interface {
	Signal[float64] | Field[float64]
}](n Node, src S) {
	switch v := any(src).(type) {
	case Signal[float64]:
		t.tx.emit(TxBindValue(n.id, v.id))
	case Field[float64]:
		t.BindValueField(n, 0, v)
	}
}

func (t *Tpl) applyBlob[S interface {
	Signal[[]byte] | Field[[]byte]
}](n Node, src S) {
	switch v := any(src).(type) {
	case Signal[[]byte]:
		t.tx.emit(TxBindSource(n.id, v.id))
	case Field[[]byte]:
		t.BindSourceField(n, 0, v)
	}
}

// applyStrProp is the same lowering for the STRING PROPS — the a11y
// trio — which differ only in their two wire ops, so the ops arrive as
// arguments. The four above cannot share that shape: their arms end in
// a named BindXField whose signature carries the value type.
func (t *Tpl) applyStrProp[S interface {
	Signal[string] | Field[string]
}](n Node, src S,
	bindSignal func(uint64, uint64) []byte,
	bindElement func(uint64, uint32, uint32) []byte,
) {
	switch v := any(src).(type) {
	case Signal[string]:
		t.tx.emit(bindSignal(n.id, v.id))
	case Field[string]:
		t.tx.emit(bindElement(n.id, 0, v.index))
	}
}

func (t *Tpl) AddChild(parent, child Node) {
	t.tx.emit(TxAddChild(parent.id, child.id))
}

func (t *Tpl) Collection() Collection {
	return t.tx.Collection()
}

// ContextMenu attaches a live-built context catalog to a template node:
// every stamped copy shows the same catalog, and each activation
// carries that copy's key path. An item takes exactly ONE anchor, so a
// second attach of the same catalog panics here.
func (t *Tpl) ContextMenu(n Node, c *ContextCatalog) {
	if c.attached {
		panic("kaya: a context catalog takes exactly one anchor")
	}
	c.attached = true
	for _, root := range c.roots {
		t.tx.emit(TxContextAttachNode(n.id, root))
	}
}

func (t *Tpl) When(s Signal[bool], fn func(*Tpl)) Node {
	t.tx.app.c.widget++
	n := Node{t.tx.app.c.widget}
	t.tx.emit(TxCreateWhen(n.id, s.id))
	t.tx.app.tplDepth++
	fn(&Tpl{tx: t.tx})
	t.tx.app.tplDepth--
	t.tx.emit(TxTemplateEnd())
	return n
}

// --- Undo: one history over two tiers (docs/undo-plan.md D1-D6, §3) ---

// Undoable makes this transaction ONE undoable step, under label. The
// unit of undo is a NAMED GROUP, so grouping is opt-in
// (docs/undo-plan.md D2, D8).
//
// CALLABLE ANYWHERE IN THE CHAIN, and the marker still rides at the head.
//
// WHAT A GROUP MAY HOLD is the reactive half — signal writes and
// collection deltas. Focus rides along and is not restored. Anything
// else fails AT APPLY, naming the op.
func (tx *Tx) Undoable(label string) {
	tx.UndoableIn(0, label)
}

// UndoableIn is Undoable against an auxiliary window's ledger; each
// window has its own history.
func (tx *Tx) UndoableIn(window uint64, label string) {
	if tx.undoGroup {
		panic("kaya: this transaction is already an undo group — one name per step")
	}
	// Through the ONE chokepoint, so a dead transaction refuses this like
	// every other write; the rotate below moves what emit queued.
	tx.emit(TxUndoGroup(window, label))
	head := tx.records[len(tx.records)-1]
	copy(tx.records[1:], tx.records[:len(tx.records)-1])
	tx.records[0] = head
	tx.undoGroup = true
}

// UndoDelta is what an undo or a redo PUT BACK: the core-authoritative
// statement of the restored state (docs/undo-plan.md D5).
//
// A STATEMENT, NOT A REPLAY: every member says what a thing now IS, so
// a mirror that applies one twice is still correct.
type UndoDelta struct {
	// Signals restored to a value.
	Signals []UndoSignal
	// Fields whose text the core put back. A coarse episode restore is a
	// programmatic write, so nothing else tells an app that folds
	// text_changed into its model.
	Texts []UndoText
	// Collection entries, present or gone.
	Entries []UndoEntry
	// Instance orders, for the instances whose order the step changed:
	// position is the one thing per-entry statements cannot carry.
	Orders []UndoOrder
}

// UndoSignal is one signal's restored value.
type UndoSignal struct {
	Signal uint64
	Value  any
}

// UndoText is one text field's restored text.
//
// THE IDENTITY IS THE OCCURRENCE'S, not the core's bookkeeping: an empty
// Path means ID is a live widget's id, a non-empty Path means ID is a
// TEMPLATE NODE and Path is the stamped copy's keys — the same pair
// OnChangeNode hands that copy's own edits. The core's internal widget
// id for a copy never leaves the core.
type UndoText struct {
	ID   uint64
	Path []any
	Text string
}

// UndoEntry is one collection entry's restored state. Present is false
// when the restored state does not have this entry at all; Record then
// carries no fields.
type UndoEntry struct {
	Collection uint64
	// The instance path: one key per enclosing For, empty at top level.
	Path    []any
	Key     any
	Present bool
	Variant uint32
	Record  []any
}

// UndoOrder is one collection instance's restored key order.
type UndoOrder struct {
	Collection uint64
	Path       []any
	Keys       []any
}

// undoShape is how one collection's entries come back from an undo: the
// payload is wire values and the mirror holds guest values, so the
// translation is recorded at the declaration that knows the type.
type undoShape struct {
	key   func(any) any
	value func(variant uint32, fields []any) any
}

// The untyped handle's shape: one Str field, and the mirror holds it as
// it arrived.
var scalarShape = undoShape{
	key: func(k any) any { return k },
	value: func(_ uint32, fields []any) any {
		if len(fields) == 0 {
			return nil
		}
		return fields[0]
	},
}

// undoReport is one decoded step: what ParseOccurrence hands the loop
// for the two undo records, with the window riding the tuple's id.
// Unexported — an app hears the label and the delta as OnUndone's
// arguments.
type undoReport struct {
	label string
	delta UndoDelta
}

// absorbUndo folds an undo's payload into the collection mirror — the
// rollback journal in reverse, and the payload is core-authoritative so
// nothing here re-derives anything. Signals and text are not mirrored
// by this binding and pass straight to the app's handler.
//
// NO DERIVED RECOMPUTE HERE, DELIBERATELY. A derived signal's write rode
// the SAME transaction as the mutation that caused it, so a named step
// banked the derived value in both directions and the core has already
// restored it. A recompute added here would write a value the ledger
// never banked, and where it disagreed the screen and the ledger's
// record of the step would part company (docs/deferred.md's residual).
func (a *App) absorbUndo(delta UndoDelta) {
	for _, e := range delta.Entries {
		shape, known := a.shapes[e.Collection]
		if !known {
			shape = scalarShape
		}
		key := shape.key(e.Key)
		in := a.instanceOf(e.Collection, e.Path)
		if in == nil {
			if !e.Present {
				continue
			}
			in = &instance{path: append([]any(nil), e.Path...)}
			a.model[e.Collection] = append(a.model[e.Collection], in)
		}
		if !e.Present {
			kept := in.entries[:0]
			for _, entry := range in.entries {
				if entry.Key != key {
					kept = append(kept, entry)
				}
			}
			in.entries = kept
			continue
		}
		value := shape.value(e.Variant, e.Record)
		replaced := false
		for i := range in.entries {
			if in.entries[i].Key == key {
				in.entries[i].Value = value
				replaced = true
				break
			}
		}
		if !replaced {
			in.entries = append(in.entries, Entry{key, value})
		}
	}
	for _, o := range delta.Orders {
		shape, known := a.shapes[o.Collection]
		if !known {
			shape = scalarShape
		}
		in := a.instanceOf(o.Collection, o.Path)
		if in == nil {
			continue
		}
		// Position by the payload's list, keeping anything it does not
		// name at the end: an entry the delta never mentions is one this
		// undo did not touch.
		sorted := make([]Entry, 0, len(in.entries))
		for _, k := range o.Keys {
			key := shape.key(k)
			for i := range in.entries {
				if in.entries[i].Key == key {
					sorted = append(sorted, in.entries[i])
					in.entries = append(in.entries[:i], in.entries[i+1:]...)
					break
				}
			}
		}
		in.entries = append(sorted, in.entries...)
	}
}

// OnClick registers a handler for a live widget's clicks.
func (a *App) OnClick(w Widget, fn func(*Tx)) {
	a.widgetHandlers[w.id] = fn
}

// OnSort registers the table's header-click handler at its For — the
// handler receives the 0-based column of a sort REQUEST: nothing has
// changed on screen; reorder the collection by key and re-declare the
// header with Columns (docs/tables-plan.md). Rows.OnSort is the same
// registration co-located with the For that stamps the rows.
func (a *App) OnSort(w Widget, fn func(*Tx, uint32)) {
	a.sortHandlers[w.id] = fn
}

// OnSortNode registers a nested table's header-click handler at its For
// node — the Node NodeRows.Node hands out, whose bar NodeRows.Columns
// declares. The keys are the clicking copy's, outermost first, and they
// are what Tx.ColumnsAt takes back to move THAT copy's indicator
// (docs/tables-plan.md).
func (a *App) OnSortNode(n Node, fn func(*Tx, []any, uint32)) {
	a.nodeSorts[n.id] = fn
}

// OnClickNode registers a handler for a template node's clicks; the
// handler also receives the stamped copy's keys, outermost first.
func (a *App) OnClickNode(n Node, fn func(*Tx, []any)) {
	a.nodeHandlers[n.id] = fn
}

// OnChange registers a handler for a live entry's edits: the widget owns
// its text and reports each edit here. There is no read-back.
func (a *App) OnChange(w Widget, fn func(*Tx, string)) {
	a.widgetChanges[w.id] = fn
}

// OnChangeNode registers a change handler for a template entry; the
// handler also receives the stamped copy's keys, outermost first.
func (a *App) OnChangeNode(n Node, fn func(*Tx, []any, string)) {
	a.nodeChanges[n.id] = fn
}

// OnValueChanged registers a handler for a live slider's moves, or a
// select's picks (same record, the index as a float64).
func (a *App) OnValueChanged(w Widget, fn func(*Tx, float64)) {
	a.widgetValues[w.id] = fn
}

// OnValueChangedNode registers a value handler for a template slider,
// select or radio group; the handler also receives the stamped copy's
// keys, outermost first. The live/node pairing this completes is
// docs/sugar-pass-plan.md §D2, and tplzone_test.go holds it.
func (a *App) OnValueChangedNode(n Node, fn func(*Tx, []any, float64)) {
	a.nodeValues[n.id] = fn
}

// OnToggle registers a handler for a live checkbox's toggles: the box
// owns its checked bit and reports each flip here.
func (a *App) OnToggle(w Widget, fn func(*Tx, bool)) {
	a.widgetToggles[w.id] = fn
}

// OnToggleNode registers a toggle handler for a template checkbox; the
// handler also receives the stamped copy's keys, outermost first.
func (a *App) OnToggleNode(n Node, fn func(*Tx, []any, bool)) {
	a.nodeToggles[n.id] = fn
}

// Serve dispatches occurrences ON THE CALLING GOROUTINE and returns when
// the core has shut down. Separate from Run because WHO OWNS THE PROCESS
// ENTRY differs by platform and nothing else does
// (docs/go-mobile-plan.md §D3).
//
// A guest never calls this directly on a platform where Run works.
func (a *App) Serve() {
	// From here on this goroutine IS the app thread, and every
	// transaction gate compares against it (requireAppThread).
	claimAppThread()
	// The one fact Android's attach cannot learn any other way: this
	// guest reached its dispatch loop. bindings/go/android.go's app
	// goroutine is the only reader, telling "the app ended" from "the
	// app never started".
	served.Store(true)
	for {
		// Posted work first, then the ring, then park. Draining at the
		// TOP is what makes a wake sufficient. Posts queued after the
		// core shuts down are dropped.
		a.drainPosted()
		kind, id, keys, payload, ready := PollOccurrence()
		if !ready {
			if !WaitOccurrences() {
				return // shutdown
			}
			continue
		}
		text, _ := payload.(string)
		checked, _ := payload.(bool)
		value, _ := payload.(float64)
		column, _ := payload.(uint32)
		choice, _ := payload.(uint32)
		files, _ := payload.([]PickedFile)
		clipValues, isClip := payload.(ClipValues)
		undo, isUndo := payload.(undoReport)
		switch {
		case kind == occButtonClicked && len(keys) == 0:
			if fn := a.widgetHandlers[id]; fn != nil {
				a.dispatch(func(tx *Tx) { fn(tx) })
			}
		case kind == occButtonClicked:
			if fn := a.nodeHandlers[id]; fn != nil {
				a.dispatch(func(tx *Tx) { fn(tx, keys) })
			}
		case kind == occTextChanged && len(keys) == 0:
			if fn := a.widgetChanges[id]; fn != nil {
				a.dispatch(func(tx *Tx) { fn(tx, text) })
			}
		case kind == occTextChanged:
			if fn := a.nodeChanges[id]; fn != nil {
				a.dispatch(func(tx *Tx) { fn(tx, keys, text) })
			}
		case kind == occToggled && len(keys) == 0:
			if fn := a.widgetToggles[id]; fn != nil {
				a.dispatch(func(tx *Tx) { fn(tx, checked) })
			}
		case kind == occToggled:
			if fn := a.nodeToggles[id]; fn != nil {
				a.dispatch(func(tx *Tx) { fn(tx, keys, checked) })
			}
		case kind == occValueChanged && len(keys) == 0:
			if fn := a.widgetValues[id]; fn != nil {
				a.dispatch(func(tx *Tx) { fn(tx, value) })
			}
		case kind == occValueChanged:
			if fn := a.nodeValues[id]; fn != nil {
				a.dispatch(func(tx *Tx) { fn(tx, keys, value) })
			}
		case kind == occSortRequested && len(keys) == 0:
			if fn := a.sortHandlers[id]; fn != nil {
				a.dispatch(func(tx *Tx) { fn(tx, column) })
			}
		case kind == occSortRequested:
			if fn := a.nodeSorts[id]; fn != nil {
				a.dispatch(func(tx *Tx) { fn(tx, keys, column) })
			}
		case kind == occCloseRequested:
			if fn := a.closeRequested[id]; fn != nil {
				a.dispatch(func(tx *Tx) { fn(tx) })
			}
		case kind == occWindowClosed:
			// One-shot: the window is gone; both registrations
			// retire with it.
			delete(a.closeRequested, id)
			if fn := a.windowClosed[id]; fn != nil {
				delete(a.windowClosed, id)
				a.dispatch(func(tx *Tx) { fn(tx) })
			}
		case kind == occEntryPopped:
			// One-shot: the entry is gone; both registrations
			// retire with it.
			delete(a.backRequested, id)
			if fn := a.entryPopped[id]; fn != nil {
				delete(a.entryPopped, id)
				a.dispatch(func(tx *Tx) { fn(tx) })
			}
		case kind == occSectionSelected:
			// NOT one-shot: sections never die. A programmatic
			// SelectSection never lands here (the echo doctrine).
			if fn := a.sectionSelected[id]; fn != nil {
				a.dispatch(func(tx *Tx) { fn(tx) })
			}
		case kind == occBackRequested:
			if fn := a.backRequested[id]; fn != nil {
				a.dispatch(func(tx *Tx) { fn(tx) })
			}
		case kind == occAlertResult:
			// One-shot: the registration retires with the result.
			if fn := a.alerts[id]; fn != nil {
				delete(a.alerts, id)
				a.dispatch(func(tx *Tx) { fn(tx, choice) })
			}
		case kind == occClipboardResult:
			// One-shot. EMPTY IS THE UNIVERSAL NO and arrives as a nil
			// Representation — denied, unfocused, absent and
			// nothing-we-accept alike, because no platform says which.
			if fn := a.clipboardReads[id]; fn != nil {
				delete(a.clipboardReads, id)
				clip := representation(clipValues)
				a.dispatch(func(tx *Tx) { fn(tx, clip) })
			}
		// A paste rides a click tag verbatim, so it arrives on the
		// ordinary widget/node split. Never empty: a paste that
		// delivered nothing is not an occurrence.
		case kind == occPasted && len(keys) == 0:
			if fn := a.widgetPastes[id]; fn != nil && isClip {
				clip := representation(clipValues)
				a.dispatch(func(tx *Tx) { fn(tx, clip) })
			}
		case kind == occPasted:
			if fn := a.nodePastes[id]; fn != nil && isClip {
				clip := representation(clipValues)
				a.dispatch(func(tx *Tx) { fn(tx, keys, clip) })
			}
		// An undo moved core state without a transaction, so the mirror
		// follows HERE — before any handler, and whether or not one is
		// registered. The window is the id; the ledger is per window.
		case (kind == occUndone || kind == occRedone) && isUndo:
			a.absorbUndo(undo.delta)
			table := a.undone
			if kind == occRedone {
				table = a.redone
			}
			if fn := table[id]; fn != nil {
				a.dispatch(func(tx *Tx) { fn(tx, undo.label, undo.delta) })
			}
		case kind == occFileDialogResult:
			// One-shot. EMPTY IS CANCEL — no platform can confirm an
			// empty selection, so there is no sentinel to invent.
			if fn := a.fileDialogs[id]; fn != nil {
				delete(a.fileDialogs, id)
				a.dispatch(func(tx *Tx) { fn(tx, files) })
			}
		// Menu occurrences key the menu-item tables — their own id
		// space, so neither widget nor node ids can collide with them.
		case kind == occMenuActivated && len(keys) == 0:
			if fn := a.menuActivated[id]; fn != nil {
				a.dispatch(func(tx *Tx) { fn(tx) })
			}
		case kind == occMenuActivated:
			if fn := a.menuActivatedNode[id]; fn != nil {
				a.dispatch(func(tx *Tx) { fn(tx, keys) })
			}
		case kind == occMenuToggled && len(keys) == 0:
			if fn := a.menuToggled[id]; fn != nil {
				a.dispatch(func(tx *Tx) { fn(tx, checked) })
			}
		case kind == occMenuToggled:
			if fn := a.menuToggledNode[id]; fn != nil {
				a.dispatch(func(tx *Tx) { fn(tx, keys, checked) })
			}
		case kind == occMenuValueChanged && len(keys) == 0:
			if fn := a.menuSelected[id]; fn != nil {
				a.dispatch(func(tx *Tx) { fn(tx, int(value)) })
			}
		case kind == occMenuValueChanged:
			if fn := a.menuSelectedNode[id]; fn != nil {
				a.dispatch(func(tx *Tx) { fn(tx, keys, int(value)) })
			}
		}
	}
}

// served records that some App reached its dispatch loop. PACKAGE-LEVEL
// because its reader is the Android attach entry, which holds no App.
// Written from Serve, read from the app goroutine after the guest's
// entry returns — different goroutines, so atomic rather than a bool.
var served atomic.Bool

// Run gives kaya the calling goroutine and RETURNS WHEN THE APP IS OVER,
// on every platform, with the app's exit code. A guest's last line is
//
//	os.Exit(build().Run())
//
// and that line is the same on mac, linux, windows, iOS and Android.
// What differs per platform is WHICH THREAD kaya was given, never
// whether this call comes back (docs/go-mobile-plan.md §D3, which also
// carries the Gio wart this refuses).
//
// runtime.GOOS IS A CONSTANT, so exactly one arm survives compilation
// while BOTH are type-checked by every `go build` on every platform.
func (a *App) Run() int {
	return a.runWith(hostedEntry, a.Serve, Run)
}

// runWith is Run's body with its two blocking halves injected, so the
// contract above is TESTED rather than asserted: a test on any host can
// drive the hosted arm (entry_test.go). `hosted` means the OS owns the
// process entry, which is Android and nothing else today.
func (a *App) runWith(hosted bool, serve func(), enterCore func() int) int {
	if hosted {
		// SERVE ON THE CALLING GOROUTINE — not `go serve()`. The caller
		// is the locked OS thread the attach entry made for exactly
		// this, and the occurrence ring has one consumer.
		serve()
		return 0
	}
	done := make(chan struct{})
	go func() {
		defer close(done)
		serve()
	}()
	code := enterCore()
	<-done
	return code
}