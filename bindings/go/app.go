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

import (
	"fmt"
	"os"
	"strings"
	"sync"
)

// Typed handles over the id spaces.
// Scalar is the signal-value constraint: the wire's value types.
// []byte is the blob channel — encoded image bytes; each create or
// write registers the bytes with the core at encode time (handles are
// single-submit), and the guest keeps its own copy.
type Scalar interface {
	~string | ~bool | ~int64 | ~float64 | ~[]byte
}

// Signal carries its value type: writes are checked at compile time,
// and When demands a Signal[bool] instead of panicking in the scene.
// (Generic methods — Go 1.27 — are what let Tx.Signal and Tx.Write
// mint and consume these without free-function detours.)
type Signal[V Scalar] struct{ id uint64 }

// Widget is a live widget: exactly one thing on screen. It carries
// the transaction that minted it so construction chains read
// declaratively (tx.Label(s).Grow(1)); the id alone is the widget's
// name, and a Widget stored past its build transaction keeps naming
// the same widget — only the chain methods die with it.
type Widget struct {
	id uint64
	tx *Tx
}

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
	signal, widget, collection, node, alert, menuItem, fileDialog uint64
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
	widgetToggles  map[uint64]func(*Tx, bool)
	widgetValues   map[uint64]func(*Tx, float64)
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
	// Menu dispatch tables, keyed by MENU ITEM id — their own id
	// space, separate from every widget/node table ("two tables,
	// always" — now N tables, still always). The node flavors receive
	// the stamped copy's key path (the keys ARE the noun).
	menuActivated     map[uint64]func(*Tx)
	menuActivatedNode map[uint64]func(*Tx, []any)
	menuToggled       map[uint64]func(*Tx, bool)
	menuToggledNode   map[uint64]func(*Tx, []any, bool)
	menuSelected      map[uint64]func(*Tx, int)
	menuSelectedNode  map[uint64]func(*Tx, []any, int)
	model          map[uint64][]*instance
	// Collections declared inside a For's template: removing a parent
	// entry tears down the copy and every instance inside it, so the
	// model needs the same edge to purge along.
	children map[uint64][]uint64
	openFors []uint64
	// The ambient parent stack: containers push their id around their
	// body, constructors parent to the top, and 0 is the template-root
	// sentinel (template bodies root themselves; a cross-zone
	// add_child is structurally impossible).
	parents []uint64
	// Signals recomputed from a collection after each of its
	// mutations, written into the same transaction.
	derived map[uint64][]func(*Tx)
	// Non-zero exactly while a template body (For, When, or a row
	// trace) is being declared: the record-time mirror-read guard's
	// arm. openFors is For-only by design (it carries collection ids
	// for nesting), so the guard has its own depth, bumped by every
	// scope opener in both zones.
	tplDepth int
	// How to undo the open transaction's model edits: a deep snapshot
	// per touched collection, taken on first touch. Non-nil exactly
	// while a Build is running; the model methods journal through it
	// so an abandoned transaction restores the mirror to what was
	// actually shipped (the same discipline as every other binding).
	journal map[uint64][]*instance
	// Closures handed to Post from other goroutines, waiting to run as
	// transactions on the app goroutine. THE ONLY FIELD HERE TOUCHED
	// FROM ANOTHER THREAD, and the only reason App carries a mutex at
	// all — everything above is app-goroutine-only by construction.
	postMu sync.Mutex
	posted []func(*Tx)
}

func NewApp() *App {
	Init()
	return &App{
		widgetHandlers: make(map[uint64]func(*Tx)),
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
		nodeToggles:    make(map[uint64]func(*Tx, []any, bool)),
		menuActivated:     make(map[uint64]func(*Tx)),
		menuActivatedNode: make(map[uint64]func(*Tx, []any)),
		menuToggled:       make(map[uint64]func(*Tx, bool)),
		menuToggledNode:   make(map[uint64]func(*Tx, []any, bool)),
		menuSelected:      make(map[uint64]func(*Tx, int)),
		menuSelectedNode:  make(map[uint64]func(*Tx, []any, int)),
		model:          make(map[uint64][]*instance),
		children:       make(map[uint64][]uint64),
		derived:        make(map[uint64][]func(*Tx)),
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

// touch journals a deep snapshot of one collection's instances the
// first time the open transaction mutates it. Deep because instances
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
	// the stack: a missing key or anchor is a guest bug, never a
	// fallback. Both validated before anything mutates.
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
	// Derived-signal registrations made this transaction, promoted into
	// the app registry only on commit — an abandoned transaction
	// abandons its registrations with its records.
	pendingDerived []pendingDerived
	// Set when Build finishes with this transaction, committed or not:
	// a construction chain (Widget.Grow) on a widget that outlived its
	// build must die loudly, not append into an orphaned record list.
	closed bool
}

type pendingDerived struct {
	coll      uint64
	recompute func(*Tx)
}

// emit queues one record, and is the ONE place that appends to a
// transaction. Every constructor, setter and chain method goes through
// it so the closed check above cannot be forgotten at a new callsite —
// the check lived only on the Widget and MenuItem chains, so a write
// through a Tx that had outlived its Build appended into a slice
// already submitted and never submitted again. No panic, no error, the
// write simply vanished. Nothing invited that mistake until App.Post
// arrived; posting is exactly the reason a guest now holds a Tx near a
// background thread, so the guard has to be total.
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
}

// mirror is emit's read-side sibling: the same liveness check plus the
// template-body rule. A read through a transaction that outlived its
// Build is worse than a lost write — it races the app thread's own
// model instead of failing — so it dies here for the same reason.
func (tx *Tx) mirror(c Collection) *instance {
	tx.alive()
	tx.app.guardMirrorRead()
	return tx.app.instanceOf(c.id, c.path)
}

// Build runs fn with a fresh transaction and submits it. A panic out
// of fn abandons the transaction: the records never ship, and the
// journal restores the model mirror to exactly what was shipped —
// then the panic continues to the caller. The tx boundary rolls back
// and propagates; whether the app survives is the caller's decision
// (the dispatch loop survives; see dispatch).
func (a *App) Build(fn func(*Tx)) {
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
			// A panic mid-declaration leaves the ambient stacks and
			// the template depth dirty; the app survives the abort,
			// so reset them or every later transaction inherits a
			// poisoned zone state.
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
// out of it: by the time the panic crosses the Build boundary the
// model is restored and the records are dropped, so the loop logs and
// moves to the next occurrence. Aborts the runtime cannot recover
// still die — uniformly with every other binding's fatal floor.





func (a *App) dispatch(fn func(*Tx)) {
	defer func() {
		if r := recover(); r != nil {
			fmt.Fprintf(os.Stderr, "kaya: handler panicked (transaction rolled back): %v\n", r)
		}
	}()
	a.Build(fn)
}

// Post runs fn as a transaction on the app goroutine, soon. It is the
// ONE method safe to call from another goroutine, and the answer to
// "how does background work reach the UI".
//
// Build is a transaction NOW on the calling goroutine; Post is the same
// transaction SOON on the app goroutine. Same shape, same *Tx, and the
// *Tx is made where it is used — so a background goroutine writes
// ordinary blocking Go and hands back only the result:
//
//	go func() {
//		data, err := os.ReadFile(name)      // blocks this goroutine
//		app.Post(func(tx *kaya.Tx) {        // back on the app goroutine
//			if err != nil {
//				tx.Write(status, err.Error())
//				return
//			}
//			tx.Write(content, string(data))
//		})
//	}()
//
// What must NOT cross is a *Tx: it belongs to the Build or handler that
// made it, and capturing one is refused (see Tx.emit). Ids — signals,
// widgets — are values and are meant to be captured; that is how the
// posted closure names what to write.
//
// A posted closure runs in its OWN transaction, after whatever is
// running now. Posting from inside a handler therefore queues for
// after; it never nests.
func (a *App) Post(fn func(*Tx)) {
	if fn == nil {
		return
	}
	a.postMu.Lock()
	a.posted = append(a.posted, fn)
	a.postMu.Unlock()
	// The app goroutine may be parked in C waiting on the ring. Posted
	// work is not an occurrence and never enters that ring, so this is
	// the only way it hears about it.
	Wake()
}

// drainPosted runs everything queued, each as its own transaction, in
// the order it was posted.
//
// It takes the batch and releases the lock BEFORE running any of it, so
// a closure that posts again lands in the NEXT batch rather than this
// one. That is what stops a self-posting closure from starving the
// occurrence loop — hold the batch open and Post becomes an infinite
// drain that never returns to the ring.
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
// natural size, positive weights divide the container's leftover
// main-axis space in proportion (see Prop::Grow in the core). The
// dynamic path — collapsing a pane is SetGrow(w, 0) and back; the
// declarative spelling is the Grow chain at construction.
func (tx *Tx) SetGrow(w Widget, weight float64) {
	tx.emit(TxSetGrow(w.id, weight))
}

// Grow weights this widget within its row/column at construction —
// the declarative chain: tx.Label(s).Grow(1). It appends to the
// transaction that minted the widget, so it belongs in the build
// expression; on a Widget that outlived its build, it fails loudly —
// use Tx.SetGrow inside a live transaction for dynamic changes.
func (w Widget) Grow(weight float64) Widget {
	if w.tx == nil || w.tx.closed {
		panic("kaya: Grow on a widget outside its build transaction — use Tx.SetGrow inside a live transaction")
	}
	w.tx.SetGrow(w, weight)
	return w
}

// SetAlign sets a container's cross-axis child placement — one of the
// generated align constants (AlignStart..AlignBaseline), Go's enum
// idiom. Containers only; baseline is rows-only — the scene rejects
// misuse at the root. The dynamic path; the declarative spelling is
// the Align chain at construction.
func (tx *Tx) SetAlign(w Widget, mode int64) {
	tx.emit(TxSetAlign(w.id, mode))
}

// Align sets this container's cross-axis child placement at
// construction — the declarative chain:
// tx.Row(...).Align(AlignBaseline). Same transaction discipline as
// Grow.
func (w Widget) Align(mode int64) Widget {
	if w.tx == nil || w.tx.closed {
		panic("kaya: Align on a widget outside its build transaction — use Tx.SetAlign inside a live transaction")
	}
	w.tx.SetAlign(w, mode)
	return w
}

// SetSpacing sets a container's inter-child gap (main axis, DIP; the
// normalized default is 8). Containers only — the scene rejects it
// anywhere else. The dynamic path; the declarative spelling is the
// Spacing chain at construction.
func (tx *Tx) SetSpacing(w Widget, gap float64) {
	tx.emit(TxSetSpacing(w.id, gap))
}

// Spacing sets this container's inter-child gap at construction — the
// declarative chain: tx.Column(...).Spacing(12). Same transaction
// discipline as Grow.
func (w Widget) Spacing(gap float64) Widget {
	if w.tx == nil || w.tx.closed {
		panic("kaya: Spacing on a widget outside its build transaction — use Tx.SetSpacing inside a live transaction")
	}
	w.tx.SetSpacing(w, gap)
	return w
}

// SetA11yID sets a widget's accessibility IDENTIFIER: a stable authored
// key that assistive tooling and UI automation address it by, and which
// is NEVER spoken. Universal — every kind carries one. The dynamic
// path; the declarative spelling is the A11yID chain at construction.
func (tx *Tx) SetA11yID(w Widget, id string) {
	tx.emit(TxSetA11yId(w.id, id))
}

// A11yID sets this widget's accessibility identifier at construction —
// the declarative chain: tx.Entry().A11yID("name"). Same transaction
// discipline as Grow.
func (w Widget) A11yID(id string) Widget {
	if w.tx == nil || w.tx.closed {
		panic("kaya: A11yID on a widget outside its build transaction — use Tx.SetA11yID inside a live transaction")
	}
	w.tx.SetA11yID(w, id)
	return w
}

// SetA11yLabel sets what an assistive client SPEAKS for a widget.
// Universal, and deliberately separate from the identifier — an
// automation key is not a spoken name. Leave it unset to keep whatever
// the platform derives from the control's own content; setting it
// OVERRIDES that, so a button whose caption already reads well needs
// nothing here. The dynamic path; the declarative spelling is the
// A11yLabel chain at construction.
func (tx *Tx) SetA11yLabel(w Widget, label string) {
	tx.emit(TxSetA11yLabel(w.id, label))
}

// A11yLabel sets this widget's spoken label at construction — the
// declarative chain: tx.Entry().A11yID("name").A11yLabel("Full name").
// Same transaction discipline as Grow.
func (w Widget) A11yLabel(label string) Widget {
	if w.tx == nil || w.tx.closed {
		panic("kaya: A11yLabel on a widget outside its build transaction — use Tx.SetA11yLabel inside a live transaction")
	}
	w.tx.SetA11yLabel(w, label)
	return w
}

// SetA11yHint sets what ACTIVATING a widget does — the platforms'
// hint (Apple defines it as the result of performing an action;
// Android carries it as the click action's label). Write a VERB
// PHRASE: VoiceOver speaks it as written, TalkBack prefixes "double
// tap to". Activation kinds only; the root rejects it elsewhere.
func (tx *Tx) SetA11yHint(w Widget, hint string) {
	tx.emit(TxSetA11yHint(w.id, hint))
}

// A11yHint sets this widget's hint at construction — the declarative
// chain: tx.Button("Save", nil).A11yHint("save the draft"). Same
// transaction discipline as Grow.
func (w Widget) A11yHint(hint string) Widget {
	if w.tx == nil || w.tx.closed {
		panic("kaya: A11yHint on a widget outside its build transaction — use Tx.SetA11yHint inside a live transaction")
	}
	w.tx.SetA11yHint(w, hint)
	return w
}

func (tx *Tx) BindChecked(w Widget, s Signal[bool]) {
	tx.emit(TxBindChecked(w.id, s.id))
}

// SetSource sets an image's encoded bytes: one registration copy into
// core-owned memory; the returned handle is consumed by the next
// submit from this guest, referenced or not, so the caller's bytes are
// free to drop the moment this returns. A later SetSource registers
// again — handles are single-submit.
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

// Clear drops the widget's owned content — a one-shot command:
// momentary verbs into widget-owned state, riding this transaction
// like any write, so the insert and the clear beside it commit
// together or not at all. Fire-and-forget: no state at rest, nothing
// to journal, and the widget answers through its normal occurrence
// path (a clear arrives back as a text change with empty text, so the
// app's draft fold empties itself — never a side assignment).
func (tx *Tx) Clear(w Widget) {
	tx.emit(TxWidgetCommand(w.id, CommandClear))
}

// Focus gives the widget keyboard focus (the post-submit refocus every
// real form wants) — a one-shot command riding the transaction like
// Clear.
func (tx *Tx) Focus(w Widget) {
	tx.emit(TxWidgetCommand(w.id, CommandFocus))
}

// Construction sugar: containers take their body as a closure and
// parent everything declared inside it (the ambient stack), and
// constructors carry their props and handlers — the Fyne shape
// (widget.NewButton("Add", tapped)); nil means no handler. Everything
// lowers eagerly to the same records; never a scene value interpreted
// later. Statement position is the point: a for statement over a
// generated row trace stands between siblings.

func (tx *Tx) Column(body func()) Widget {
	return tx.containerOf(KindColumn, body)
}

func (tx *Tx) Row(body func()) Widget {
	return tx.containerOf(KindRow, body)
}

// Scroll is a vertical scroll viewport over EXACTLY ONE child
// (declare it in the body; the scene rejects a second). Chain
// .Grow(1) so the enclosing track CONSTRAINS it — an unconstrained
// viewport hugs its content and nothing overflows.
func (tx *Tx) Scroll(body func()) Widget {
	return tx.containerOf(KindScroll, body)
}

// Grid creates a grid laying its children out row-major into columns
// columns — each column takes its NATURAL width, aligned across rows
// (the thing nested rows cannot express).
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

// Spacer is PURE SUGAR for an empty grown column: it consumes the
// leftover main-axis space between its siblings (the grow contract;
// no new vocabulary).
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

// Textarea creates a multi-line text editor with its change handler
// (nil for none): the entry's uncontrolled contract over the
// platform's real multi-line editor.
func (tx *Tx) Textarea(onChange func(*Tx, string)) Widget {
	w := tx.Widget(KindTextarea)
	if onChange != nil {
		tx.app.OnChange(w, onChange)
	}
	return w
}

// LabelText creates a label with constant text (Label is the
// signal-bound flavor) — the const-label sugar every other binding
// already had.
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

// Progress is a progress bar: display-only, like Label and Image.
// value is the determinate fraction (0..=1, domain-checked at the
// root); chain .Indeterminate() for the platform's activity mode.
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

// Slider creates a slider over min..max at value, with its change
// handler co-located (nil for none) — the Fyne shape, like Button.
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
// float signal — the programmatic write path (Tx.Write fans out to
// the control; property writes never echo an occurrence, so a
// handler's own writes cannot loop back at it).
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

// Select creates a dropdown select over fixed options — each option
// becomes a label child (labels only, scene-checked) — at selected,
// the initial 0-based index (domain-checked at the root against the
// option count), with its pick handler co-located (nil for none):
// onSelect receives each USER pick's new 0-based index (programmatic
// writes never echo) — the slider's uncontrolled contract.
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

// Radio creates a radio group over fixed options — the choice
// contract (see Select) in its inline presentation: same option
// children, same 0-based selected index, same pick handler.
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

// Image creates an image displaying encoded bytes (PNG, JPEG, ...):
// the toolkit decodes natively, and decode failure renders the
// placeholder, never a crash. source is the encoded bytes — one
// registration copy into core memory; the handle is consumed by the
// next submit, and the guest's bytes are free to drop the moment this
// returns. ImageSignal is the signal-bound flavor — separate methods,
// like SetText/BindText, per the Tx surface's convention.
func (tx *Tx) Image(source []byte) Widget {
	w := tx.Widget(KindImage)
	tx.SetSource(w, source)
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

// ForEach declares a For over c: fn's body declares the template, and
// the For itself (a live container) is returned.
func (tx *Tx) ForEach(c Collection, fn func(*Tpl)) Widget {
	assertRoot(c)
	tx.app.c.widget++
	w := Widget{id: tx.app.c.widget, tx: tx}
	// The For parents into the enclosing scope, but the record must
	// land after template_end — an add_child inside the blueprint
	// would cross zones.
	parent := tx.currentParent()
	tx.emit(TxCreateFor(w.id, c.id))
	tx.app.openFors = append(tx.app.openFors, c.id)
	tx.app.parents = append(tx.app.parents, 0)
	tx.app.tplDepth++
	fn(&Tpl{tx: tx})
	tx.app.tplDepth--
	tx.app.parents = tx.app.parents[:len(tx.app.parents)-1]
	tx.app.openFors = tx.app.openFors[:len(tx.app.openFors)-1]
	tx.emit(TxTemplateEnd())
	if parent != 0 {
		tx.emit(TxAddChild(parent, w.id))
	}
	return w
}

// BeginRowTrace opens a For template for a generated row trace
// (`for row := range TodoRows(tx, todos)`): the caller runs the loop
// body once with the returned Tpl, then close() ends the template and
// parents the For into the enclosing scope. Range-over-func makes the
// close structural — the iterator regains control even on break.
// The For rides the zone it opens in: the widget id space in the live
// zone, the node space inside an enclosing template (a nested trace).
func BeginRowTrace(tx *Tx, c Collection) (*Tpl, func()) {
	assertRoot(c)
	var id uint64
	if tx.app.tplDepth > 0 {
		tx.app.c.node++
		id = tx.app.c.node
	} else {
		tx.app.c.widget++
		id = tx.app.c.widget
	}
	parent := tx.currentParent()
	tx.emit(TxCreateFor(id, c.id))
	tx.app.openFors = append(tx.app.openFors, c.id)
	tx.app.parents = append(tx.app.parents, 0)
	tx.app.tplDepth++
	return &Tpl{tx: tx}, func() {
		tx.app.tplDepth--
		tx.app.parents = tx.app.parents[:len(tx.app.parents)-1]
		tx.app.openFors = tx.app.openFors[:len(tx.app.openFors)-1]
		tx.emit(TxTemplateEnd())
		if parent != 0 {
			tx.emit(TxAddChild(parent, id))
		}
	}
}

// Row is the scalar-collection row surface a Rows trace yields: the
// whole template vocabulary (the embedded Tpl) plus the element's own
// token — a scalar collection has exactly one field, the element
// itself, and Value() is that token (the generated record twin mints
// one token per struct field).
type Row struct{ *Tpl }

// Value is the element's token: what a stamped copy's bindings read.
func (r Row) Value() Field[string] { return FieldAt[string](0) }

// Label creates a label bound to the element's token.
func (r Row) Label(f Field[string]) Node {
	n := r.Tpl.Widget(KindLabel)
	r.Tpl.BindTextField(n, 0, f)
	return n
}

// Rows traces this scalar collection's template as a for statement:
// `for row := range items.Rows(tx)` runs the body ONCE, authoring the
// blueprint over the row surface, and range-over-func makes the close
// structural — even on break. The statement IS the For in both tiers;
// the record twin is the generated <Type>Rows surface (todos).
func (c Collection) Rows(tx *Tx) func(func(Row) bool) {
	return func(yield func(Row) bool) {
		t, done := BeginRowTrace(tx, c)
		yield(Row{t})
		done()
	}
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
	tx.app.modelSet(c.id, c.path, key, value)
	tx.emit(TxCollectionInsert(c.id, c.path, key, 0, []any{value}))
	tx.recomputeDerived(c.id, c.path)
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

// MoveBefore repositions an entry before another's: order is
// collection data, so the model reorders and the wire carries the
// same keys-only delta. Keys, never indices. A missing key or anchor
// panics here, at the call site — the same check the scene makes;
// moving an entry before itself is a no-op, and nothing travels.
func (tx *Tx) MoveBefore(c Collection, key, anchor any) {
	tx.moveEntry(c, key, []any{anchor})
}

// MoveToEnd repositions an entry at the end of its collection.
func (tx *Tx) MoveToEnd(c Collection, key any) {
	tx.moveEntry(c, key, nil)
}

// MoveToFront repositions an entry at the front: sugar for MoveBefore
// the current first key, lowering to the same wire op.
func (tx *Tx) MoveToFront(c Collection, key any) {
	keys := tx.app.keysOf(c.id, c.path)
	if len(keys) == 0 {
		panic(fmt.Sprintf("kaya: move of missing key %v", key))
	}
	tx.moveEntry(c, key, []any{keys[0]})
}

// MoveAfter repositions an entry directly after another's: sugar for
// MoveBefore the anchor's successor (MoveToEnd when the anchor is
// last), lowering to the same wire op.
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
		// Moving before itself: order unchanged and nothing travels —
		// but the key must exist, the check the scene would make.
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
// and writes each into this transaction. Deriveds hang off root
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
// template records once and replays — the read would bake today's
// value into the blueprint as silently dead data. Bind a signal, use
// the element's field, or Derive for computed values. (Handler and
// build reads stay legal; read-your-writes is the model's contract.)
func (a *App) guardMirrorRead() {
	if a.tplDepth > 0 {
		panic("kaya: model read inside a template body — the template records " +
			"once and replays; bind a signal, use the element's field, or " +
			"Derive for computed values")
	}
}

// Items is the model: what this guest wrote, exactly — the fold of
// every patch so far (this transaction's included), in insertion order.
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
// presents it. Returns the prop chain:
// tx.CreateWindow(1).Title("inspector").Size(480, 320).VetoClose(true).
func (tx *Tx) CreateWindow(id uint64) WindowRef {
	tx.emit(TxCreateWindow(id))
	return WindowRef{tx: tx, id: id}
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

// PushEntry pushes a navigation entry onto the primary surface's
// stack (entry ids are guest-allocated in the shared surface
// namespace, the CreateWindow discipline); it materializes covered
// and a MountIn presents it. Returns the prop chain:
// tx.PushEntry(7).Title("detail").InterceptBack(true).
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

// AddSection appends a section to the primary window's section set
// (section ids are guest-allocated in the shared surface namespace);
// the set is append-only — sections have no destruction grammar, and
// every section's root is retained while covered (switching is
// SELECTION, not lifecycle). A MountIn fills its pane. Returns the
// prop chain: tx.AddSection(7).Title("Feed").OnSelected(fn).
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

// ShowAlert requests a modal alert (the request/result grammar): a
// chain that ends in Show, which sends the one atomic record —
// tx.ShowAlert().Title("delete item?").Message("…").Action("Delete").
// Action("Archive").Cancel("Keep").OnResult(func(tx *Tx, choice
// uint32) { … }).Show(). The result handler rides the REQUEST (the
// widget-handler precedent) and retires with its one answer; ids are
// binding-allocated, like widget ids. Up to two actions (the
// platform floor); the cancel label is required and explicit (no
// binding invents a default). One alert may be live per process;
// show the next from the handler.
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
// result carries handles you redeem later, so the name says Pick
// (DESIGN.md, File dialogs).
//
// A chain that ends in Show, like ShowAlert:
// tx.PickFiles().Filter("Text", "txt").OnResult(func(tx *kaya.Tx, files
// []kaya.PickedFile) { … }).Show(). One dialog may be live per process;
// show the next from the first's result handler.
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

// --- The clipboard (DESIGN.md, Clipboard) --------------------------
//
// A clip is not a string: every host models it as ONE item available in
// several types, with the consumer taking the richest it understands.
// So COPY TAKES A RECORD — spelled as a chain here, where a second
// Text simply replaces the field rather than needing a duplicate check
// — and the two answers are a SUM, because you offer many and receive
// one.
//
// kaya DERIVES NOTHING between representations. Whether list bullets
// survive html-to-text is the app's decision, and a bad
// auto-derivation degrades every paste into a plain field silently.

// Representation is one representation, arriving — the sum a copy is
// the record of. Go has no sum type, so it is a sealed interface with
// one struct per constructor: a type switch is the elimination, which
// is how Go spells a match.
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

// ClipFiles is files, plural INSIDE one representation — the same
// nesting text/uri-list and CF_HDROP already have. A pasted file is the
// picker's own capability arriving through a second door, so it opens
// with the call that already exists.
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
// nil.
//
// EMPTY IS THE UNIVERSAL NO: nil covers a denied prompt on iOS, an
// unfocused reader on Android or Wayland, an empty clipboard, and
// content in no representation this read accepted. The guest is not
// told which, because the platforms deliberately do not say.
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
// custom ids, space separated.
//
// A LIST AND NOT A MASK, because half the set is open-ended. A custom
// format that could be written and never accepted would be an escape
// hatch that only opens outward, and round-tripping an app's own data
// is the whole reason to have one. Ids reach every platform's registry
// verbatim, so they carry no spaces — which is what makes the join
// unambiguous, and what this refuses to let you break.
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
// to offer, and Send puts it on the system clipboard.
//
// A RECORD AND NOT A LIST is the whole shape — at most one per kind is
// structural, since a second Text replaces the field rather than
// needing a duplicate check the root has to run.
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
// reaches every platform's own registry unchanged — a UTI on Apple,
// RegisterClipboardFormat on Windows, a target atom on X11 and
// Wayland, a MIME type on Android — so it carries no spaces, and kaya
// does nothing clever with the bytes.
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

// ReadClipboard begins the privileged read — THE ONE NAMED FOR WHAT IT
// IS rather than for pasting.
//
// A user's paste arrives at the widget's hook and costs nothing; this
// asks without a gesture, which the platforms have deliberately made
// expensive: iOS 16 PROMPTS when the content came from another app and
// blocks until the user answers, Android returns nothing unless the app
// has focus, and Wayland delivers no offer to an unfocused client.
// Reach for this to detect a URL or import from the clipboard, never to
// implement Paste — that is the Paste command, and it is free.
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

// Accepts declares what this widget takes from a paste, at
// construction: tx.Entry(nil).Accepts("text").
//
// ONE DECLARATION, THREE JOBS: it drives whether the Paste command is
// live while this widget is focused, it filters what can reach the
// paste hook, and on Android it IS the native registration
// (setOnReceiveContentListener takes the mime types on the view).
// Per-widget because whether Paste should be enabled is the
// INTERSECTION of what the clipboard offers and what the FOCUSED target
// takes — a search field wants plain text, a rich editor also wants
// images.
//
// DECLARING IS HOW AN APP OVERRIDES THE DEFAULT. A widget that declares
// nothing gets the platform's own insertion and reports it through the
// ordinary change path, which is why a plain text editor writes none of
// this and has working cut, copy and paste.
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

// OnPasteNode registers a paste handler for a template node; the
// handler also receives the stamped copy's keys, outermost first. A
// paste onto a stamped row is the same event as a paste onto a live
// one, exactly as a click is.
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

// VetoClose arms the veto class: the close button emits
// close_requested and nothing closes until DestroyWindow agrees.
// SectionsPresentation sets the window's ADVISORY sections hint
// (SectionsPresentationAuto/Bar/Sidebar — the width/height
// precedent; the phones ignore it by physics).
func (w WindowRef) SectionsPresentation(hint int64) WindowRef {
	w.tx.emit(TxSetWindowSectionsPresentation(w.id, hint))
	return w
}

func (w WindowRef) VetoClose(on bool) WindowRef {
	w.tx.emit(TxSetWindowVetoClose(w.id, on))
	return w
}

// ListDetail asks this window to present its entry stack as
// list-detail: on a REGULAR window the base root takes the leading
// pane and the top of the stack the trailing one; on a COMPACT one
// nothing changes. There is no argument for WHICH way it presents —
// that is the size class's answer, not the app's.
func (w WindowRef) ListDetail(on bool) WindowRef {
	w.tx.emit(TxSetWindowListDetail(w.id, on))
	return w
}

// OnCloseRequested binds the close-veto handler to THIS window
// (per-window — handlers scope to the thing that creates them):
// fires per chrome close while VetoClose is armed; nothing has
// closed — answer with tx.DestroyWindow to agree.
func (w WindowRef) OnCloseRequested(fn func(*Tx)) WindowRef {
	w.tx.app.closeRequested[w.id] = fn
	return w
}

// OnClosed binds the closed handler to THIS window: fires when the
// non-veto auxiliary is chrome-closed (informational; DestroyWindow
// reconciles), retiring with it — a window closes at most once.
func (w WindowRef) OnClosed(fn func(*Tx)) WindowRef {
	w.tx.app.windowClosed[w.id] = fn
	return w
}

// Id returns the window id, for MountIn.
func (w WindowRef) Id() uint64 {
	return w.id
}

// Menu declares a top-level menu in this window's command catalog —
// the menubar rides the window construct (DESIGN.md, Menus):
// tx.Window(0).Menu("File") returns the retained grouping handle,
// whose creators (Item/Toggle/Menu/RadioGroup/Separator) append the
// children: file.Item("Save").Shortcut("primary+s").OnActivate(fn).
// Append-at-any-time: reopen the retained handle in a later
// transaction with tx.Menu(file).
func (w WindowRef) Menu(label string) MenuItem {
	m := newMenuItem(w.tx, MenuKindMenu, label, false)
	w.tx.emit(TxMenubarAppend(w.id, m.id))
	return m
}

// RadioGroup declares a BAR-LEVEL radio group — admissible wherever a
// menu grouping node is (it materializes as a top-level menu with the
// platform's checkmark idiom). Declare only Option children; chain
// BindValue/Value AFTER them (the Choice contract: the selected
// 0-based index; programmatic writes are quiet) and OnSelect for each
// USER pick's new index.
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

// Title names the entry — the back affordance's label source (the
// iOS back button, the desktop headers).
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

// OnPopped binds the popped handler to THIS entry (per-entry, the
// request-bound alert precedent — no id inspection anywhere): fires
// when the user's back affordance pops it natively (post-fact; a
// programmatic PopEntry does not fire it — its caller already
// knows), and the registration retires with the one pop.
func (e EntryRef) OnPopped(fn func(*Tx)) EntryRef {
	e.tx.app.entryPopped[e.id] = fn
	return e
}

// OnBackRequested binds the back-veto handler to THIS entry: fires
// each time the user drives back on it while intercept_back is armed
// — nothing has popped; answer with tx.PopEntry to agree.
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

// OnSelected binds the selected handler to THIS section (per-section,
// the entry-handler precedent): fires each time the USER switches to
// it through the platform's switcher — post-fact and NOT one-shot. A
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
// MenuItem is a live menu item: its OWN id space (the c_menu_item
// counter) behind its own type, so cross-use with widget or node ids
// is a compile error. The id alone is the item's durable name; the
// chain methods (props, creators, handlers) ride the transaction that
// minted the value and die with it — the Widget.Grow discipline —
// and tx.Menu(item) reopens a retained handle in a later transaction
// (append-at-any-time; props mutate freely; nothing is ever removed
// in v1).
type MenuItem struct {
	id uint64
	tx *Tx
	// ctx marks a context-anchored chain: a shortcut needs a window
	// catalog as its native dispatch home, so Shortcut panics here at
	// record time — the root remains the floor beneath.
	ctx bool
}

func (m MenuItem) chain() *Tx {
	if m.tx == nil || m.tx.closed {
		panic("kaya: menu chain outside its transaction — reopen the retained handle with Tx.Menu inside a live transaction")
	}
	return m.tx
}

// newMenuItem creates one item in the menu-item id space. Menu
// records are live-zone only: a template body records a blueprint,
// and items are live and shared across stamped copies — build the
// catalog outside (Tx.ContextCatalog) and attach it inside the
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
// menu_activated occurrence (menu click OR its shortcut: ONE
// occurrence, one dispatch path). Chain OnActivate beside it.
func (m MenuItem) Item(label string) MenuItem {
	return m.child(MenuKindAction, label)
}

// Toggle appends a stateful leaf reusing the Checkbox contract: user
// flips emit menu_toggled (chain OnToggle); programmatic checked
// writes are quiet.
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

// Option appends one labeled option (radio groups only — root
// checked), in declaration order: the order IS the index vocabulary
// the group's value selects over.
func (m MenuItem) Option(label string) MenuItem {
	return m.child(MenuKindRadioOption, label)
}

// Separator appends native grouping chrome: no label, no props, no
// handle kept.
func (m MenuItem) Separator() {
	c := newMenuItem(m.chain(), MenuKindSeparator, "", m.ctx)
	m.tx.emit(TxMenuItemAppend(m.id, c.id))
}

// Label renames the item to constant text. Label writes never emit
// anything.
func (m MenuItem) Label(text string) MenuItem {
	m.chain().emit(TxSetMenuLabel(m.id, text))
	return m
}

// BindLabel binds the item's label to a Str signal.
func (m MenuItem) BindLabel(s Signal[string]) MenuItem {
	m.chain().emit(TxBindMenuLabel(m.id, s.id))
	return m
}

// Enabled sets whether the item is enabled (default true). Enablement
// writes never emit anything; disabling a grouping node disables its
// subtree everywhere (the inherited-disabled contract).
func (m MenuItem) Enabled(on bool) MenuItem {
	m.chain().emit(TxSetMenuEnabled(m.id, on))
	return m
}

// BindEnabled binds the item's enablement to a Bool signal.
func (m MenuItem) BindEnabled(s Signal[bool]) MenuItem {
	m.chain().emit(TxBindMenuEnabled(m.id, s.id))
	return m
}

// Checked sets a toggle's state (toggle items only — root-checked):
// the Checkbox contract. The programmatic write is configuration —
// QUIET, no menu_toggled echo (the echo doctrine).
func (m MenuItem) Checked(on bool) MenuItem {
	m.chain().emit(TxSetMenuChecked(m.id, on))
	return m
}

// BindChecked binds a toggle's state to a Bool signal, both ways.
func (m MenuItem) BindChecked(s Signal[bool]) MenuItem {
	m.chain().emit(TxBindMenuChecked(m.id, s.id))
	return m
}

// Value sets a radio group's selected option index (radio groups only
// — root-checked): the Choice contract. QUIET, like Checked.
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

// Icon sets the item's icon (the blob channel): used by phone
// promotion, ignored where native menu dress has no icons. Const-only.
func (m MenuItem) Icon(data []byte) MenuItem {
	m.chain().emit(TxSetMenuIcon(m.id, RegisterBlob(data)))
	return m
}

// Primary sets the phone-bar promotion hint (actions only —
// root-checked). Flipping it recomputes the promoted set
// deterministically; INERT on desktops — not a toolbar grammar.
// Const-only.
func (m MenuItem) Primary(on bool) MenuItem {
	m.chain().emit(TxSetMenuPrimary(m.id, on))
	return m
}

// RoleSettings names the app's settings command — the closed
// standard-command vocabulary (DESIGN.md, Menus).
// A NAMED VOCABULARY FOR THE CLOSED HALF, exactly as the menu roles
// are. The accept list is open-ended — a custom format id is any
// app-chosen string — so the four closed kinds cannot be a mask; but
// they can be spelled once here instead of quoted at every call site.
// A MISTYPED BARE STRING IS SILENT: it becomes a custom format id no
// clipboard will ever offer, so Paste stays dead and the paste hook
// never fires, with nothing to see anywhere. A custom id has no
// constant by nature — the app that defines it names it.
const (
	AcceptText = "text"
	AcceptHtml = "html"
	AcceptImage = "image"
	AcceptFiles = "files"
)

const RoleSettings = "settings"

// The three clipboard commands. They lower to the platform's own, act
// on the FOCUSED widget, and work out their own enablement from what
// the clipboard offers and what that widget accepts.
//
// GESTURES ARE COMMANDS BECAUSE KAYA HAS NO SELECTION API: only the
// widget knows what is selected, so an app cannot assemble the payload
// for "copy the selected text" out of the data layer. Copy of a
// selection is therefore necessarily a command, and Paste is its
// mirror. Tx.Copy and Tx.ReadClipboard are for overriding that default
// and for targets with no native behaviour.
const (
	RoleCut   = "cut"
	RoleCopy  = "copy"
	RolePaste = "paste"
)

// Role declares this action a standard command (actions only —
// root-checked). The declaration is uniform; PLACEMENT is each host's
// business: macOS shows RoleSettings in the application menu, everyone
// else leaves the item where it was declared. One item per role, and a
// role never invents a chord — spell Shortcut too if the app wants one.
// Const-only.
func (m MenuItem) Role(name string) MenuItem {
	if m.ctx {
		panic("kaya: a context item takes no role — a role names a standard command in the window catalog")
	}
	m.chain().emit(TxSetMenuRole(m.id, name))
	return m
}

// Shortcut sets the shortcut of any LEAF command — an action, a
// toggle, or one option of a group (window-anchored only).
// Canonicalized by the binding's one parser (CanonicalizeShortcut);
// the shortcut is another affordance of the same item — it fires the
// SAME menu_activated occurrence as a click. Const-only.
func (m MenuItem) Shortcut(spelling string) MenuItem {
	if m.ctx {
		panic("kaya: a context item takes no shortcut — a shortcut needs a window catalog as its native dispatch home")
	}
	m.chain().emit(TxSetMenuShortcut(m.id, spelling))
	return m
}

// OnActivate binds this action's handler — it rides the declaration
// (no app-global menu dispatcher exists), and the action's click and
// its shortcut are ONE occurrence on one dispatch path, so it covers
// both.
func (m MenuItem) OnActivate(fn func(*Tx)) MenuItem {
	m.chain().app.menuActivated[m.id] = fn
	return m
}

// OnActivateNode is the template-node flavor: an item attached to a
// stamped copy reports the copy's key path, outermost first — the
// keys ARE the noun the command acts on.
func (m MenuItem) OnActivateNode(fn func(*Tx, []any)) MenuItem {
	m.chain().app.menuActivatedNode[m.id] = fn
	return m
}

// OnToggle binds a toggle's handler: each USER flip's new state.
// Programmatic Checked writes are quiet, so a handler's own writes
// cannot loop back at it.
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

// OnSelect binds a radio group's handler (registered on the GROUP):
// each USER pick's new 0-based option index. Programmatic Value
// writes are quiet.
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

// Menu reopens a RETAINED menu item — the append-at-any-time
// discipline: tx.Menu(file).Label("Document").Item("Publish"). Props
// mutate freely on every kind the prop applies to; the root judges a
// misapplied prop (kind and anchor rules) exactly as at construction.
func (tx *Tx) Menu(item MenuItem) MenuItem {
	return MenuItem{id: item.id, tx: tx}
}

// ContextRef is a live widget's context anchor (Tx.ContextMenu): the
// same item vocabulary as the bar, scoped to a NOUN — each creator
// attaches another root. No shortcuts here (record-time checked; the
// editable text controls reject attachment at the root).
type ContextRef struct {
	tx     *Tx
	widget uint64
}

// ContextMenu opens the context anchor on a live widget: the
// platform's own gesture (right-click, long-press) presents the
// catalog. Calling it again appends more roots.
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

// ContextCatalog is a context catalog built UNANCHORED
// (Tx.ContextCatalog) for a template node: menu items are live and
// shared across stamped copies, so the catalog is built in the live
// zone and Tpl.ContextMenu attaches it inside the template, where
// each activation carries the copy's key path. An item takes exactly
// one anchor — a second attach panics.
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
	t.tx.app.c.node++
	n := Node{t.tx.app.c.node}
	t.tx.emit(TxCreateWidget(n.id, kind))
	t.tx.autoParent(n.id)
	return n
}

func (t *Tpl) SetText(n Node, text string) {
	t.tx.emit(TxSetText(n.id, text))
}

// BindTextElement binds text to the element of the enclosing For,
// `level` Fors up (0 = nearest).
func (t *Tpl) BindTextElement(n Node, level uint32) {
	t.tx.emit(TxBindTextElement(n.id, level, 0))
}

// The template flavor of the containers.
func (t *Tpl) Row(body func()) Node {
	return t.containerOf(KindRow, body)
}

func (t *Tpl) Column(body func()) Node {
	return t.containerOf(KindColumn, body)
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

func (t *Tpl) AddChild(parent, child Node) {
	t.tx.emit(TxAddChild(parent.id, child.id))
}

func (t *Tpl) Collection() Collection {
	return t.tx.Collection()
}

func (t *Tpl) ForEach(c Collection, fn func(*Tpl)) Node {
	assertRoot(c)
	t.tx.app.c.node++
	n := Node{t.tx.app.c.node}
	parent := t.tx.currentParent()
	t.tx.emit(TxCreateFor(n.id, c.id))
	t.tx.app.openFors = append(t.tx.app.openFors, c.id)
	t.tx.app.parents = append(t.tx.app.parents, 0)
	t.tx.app.tplDepth++
	fn(&Tpl{tx: t.tx})
	t.tx.app.tplDepth--
	t.tx.app.parents = t.tx.app.parents[:len(t.tx.app.parents)-1]
	t.tx.app.openFors = t.tx.app.openFors[:len(t.tx.app.openFors)-1]
	t.tx.emit(TxTemplateEnd())
	if parent != 0 {
		t.tx.emit(TxAddChild(parent, n.id))
	}
	return n
}

// ContextMenu attaches a live-built context catalog (Tx.ContextCatalog)
// to a template node: every stamped copy shows the same catalog, and
// each activation carries that copy's key path — the keys ARE the
// noun (the OnClickNode encoding, received by the OnActivateNode
// handler flavors). An item takes exactly one anchor, so a second
// attach of the same catalog panics here.
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
	t.tx.app.c.node++
	n := Node{t.tx.app.c.node}
	t.tx.emit(TxCreateWhen(n.id, s.id))
	t.tx.app.tplDepth++
	fn(&Tpl{tx: t.tx})
	t.tx.app.tplDepth--
	t.tx.emit(TxTemplateEnd())
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

// OnValueChanged registers a handler for a live slider's moves (or a
// select's picks — same record, the index as a float64): the widget
// owns its position and reports each change with the new value — the
// entry's uncontrolled contract.
func (a *App) OnValueChanged(w Widget, fn func(*Tx, float64)) {
	a.widgetValues[w.id] = fn
}

// OnToggle registers a handler for a live checkbox's toggles: the box
// owns its checked bit and reports each flip here; the app folds it
// into its own state.
func (a *App) OnToggle(w Widget, fn func(*Tx, bool)) {
	a.widgetToggles[w.id] = fn
}

// OnToggleNode registers a toggle handler for a template checkbox; the
// handler also receives the stamped copy's keys, outermost first.
func (a *App) OnToggleNode(n Node, fn func(*Tx, []any, bool)) {
	a.nodeToggles[n.id] = fn
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
			// Posted work first, then the ring, then park. Draining at
			// the TOP is what makes a wake sufficient: whatever reason
			// the goroutine came back for, it looks here before it looks
			// anywhere else. Posts queued after the core shuts down are
			// dropped — the last drain before the false below is the
			// last one there is.
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
			choice, _ := payload.(uint32)
			files, _ := payload.([]PickedFile)
			clipValues, isClip := payload.(ClipValues)
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
				// NOT one-shot: sections never die, and the user can
				// return any number of times (id is the section; the
				// window rides as the payload). A programmatic
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
				// One-shot like the alert, and the request retires with
				// it. EMPTY IS THE UNIVERSAL NO and arrives as a nil
				// Representation — denied, unfocused, absent and
				// nothing-we-accept alike, because no platform says which.
				if fn := a.clipboardReads[id]; fn != nil {
					delete(a.clipboardReads, id)
					clip := representation(clipValues)
					a.dispatch(func(tx *Tx) { fn(tx, clip) })
				}
			// A paste rides a click tag verbatim, so it arrives on the
			// ordinary widget/node split — one record kind, the key path
			// deciding. Never empty: a paste that delivered nothing is
			// not an occurrence.
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
			case kind == occFileDialogResult:
				// One-shot like the alert, and the id retires with it.
				// EMPTY IS CANCEL — no platform can confirm an empty
				// selection, so there is no sentinel to invent.
				if fn := a.fileDialogs[id]; fn != nil {
					delete(a.fileDialogs, id)
					a.dispatch(func(tx *Tx) { fn(tx, files) })
				}
			// Menu occurrences key the menu-item tables — their own
			// id space, so neither widget nor node ids can collide
			// with them. Node-anchored context items carry the
			// stamped copy's keys (the keys ARE the noun); toggles
			// carry the new state, radio groups the new 0-based
			// index.
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
	}()
	code := Run()
	<-done
	return code
}
