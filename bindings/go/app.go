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
	signal, widget, collection, node, alert uint64
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
	nodeToggles    map[uint64]func(*Tx, []any, bool)
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
}

func NewApp() *App {
	Init()
	return &App{
		widgetHandlers: make(map[uint64]func(*Tx)),
		alerts:         make(map[uint64]func(*Tx, uint32)),
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

func (tx *Tx) Signal[V Scalar](initial V) Signal[V] {
	tx.app.c.signal++
	s := Signal[V]{tx.app.c.signal}
	tx.records = append(tx.records, TxCreateSignal(s.id, scalarWire(initial)))
	return s
}

// Write writes a signal's value. A []byte value registers its bytes at
// encode time — handles are single-submit, so every write re-registers
// (one copy into core memory per write).
func (tx *Tx) Write[V Scalar](s Signal[V], value V) {
	tx.records = append(tx.records, TxWriteSignal(s.id, scalarWire(value)))
}

func (tx *Tx) Widget(kind uint32) Widget {
	tx.app.c.widget++
	w := Widget{id: tx.app.c.widget, tx: tx}
	tx.records = append(tx.records, TxCreateWidget(w.id, kind))
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
		tx.records = append(tx.records, TxAddChild(p, id))
	}
}

func (tx *Tx) SetText(w Widget, text string) {
	tx.records = append(tx.records, TxSetText(w.id, text))
}

func (tx *Tx) BindText(w Widget, s Signal[string]) {
	tx.records = append(tx.records, TxBindText(w.id, s.id))
}

func (tx *Tx) SetChecked(w Widget, checked bool) {
	tx.records = append(tx.records, TxSetChecked(w.id, checked))
}

// SetGrow sets a widget's flex weight within its row/column: 0 is
// natural size, positive weights divide the container's leftover
// main-axis space in proportion (see Prop::Grow in the core). The
// dynamic path — collapsing a pane is SetGrow(w, 0) and back; the
// declarative spelling is the Grow chain at construction.
func (tx *Tx) SetGrow(w Widget, weight float64) {
	tx.records = append(tx.records, TxSetGrow(w.id, weight))
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
	tx.records = append(tx.records, TxSetAlign(w.id, mode))
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
	tx.records = append(tx.records, TxSetSpacing(w.id, gap))
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

func (tx *Tx) BindChecked(w Widget, s Signal[bool]) {
	tx.records = append(tx.records, TxBindChecked(w.id, s.id))
}

// SetSource sets an image's encoded bytes: one registration copy into
// core-owned memory; the returned handle is consumed by the next
// submit from this guest, referenced or not, so the caller's bytes are
// free to drop the moment this returns. A later SetSource registers
// again — handles are single-submit.
func (tx *Tx) SetSource(w Widget, data []byte) {
	tx.records = append(tx.records, TxSetSource(w.id, RegisterBlob(data)))
}

// BindSource binds an image's source to a blob signal; each write of
// the signal re-registers its bytes (see Tx.Write).
func (tx *Tx) BindSource(w Widget, s Signal[[]byte]) {
	tx.records = append(tx.records, TxBindSource(w.id, s.id))
}

func (tx *Tx) AddChild(parent, child Widget) {
	tx.records = append(tx.records, TxAddChild(parent.id, child.id))
}

// Clear drops the widget's owned content — a one-shot command:
// momentary verbs into widget-owned state, riding this transaction
// like any write, so the insert and the clear beside it commit
// together or not at all. Fire-and-forget: no state at rest, nothing
// to journal, and the widget answers through its normal occurrence
// path (a clear arrives back as a text change with empty text, so the
// app's draft fold empties itself — never a side assignment).
func (tx *Tx) Clear(w Widget) {
	tx.records = append(tx.records, TxWidgetCommand(w.id, CommandClear))
}

// Focus gives the widget keyboard focus (the post-submit refocus every
// real form wants) — a one-shot command riding the transaction like
// Clear.
func (tx *Tx) Focus(w Widget) {
	tx.records = append(tx.records, TxWidgetCommand(w.id, CommandFocus))
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
	tx.records = append(tx.records, TxSetColumns(parent.id, float64(columns)))
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
	tx.records = append(tx.records, TxSetValue(w.id, value))
	return w
}

// Indeterminate switches a progress bar to the platform's activity
// mode (the fraction is ignored while it is on).
func (w Widget) Indeterminate() Widget {
	w.tx.records = append(w.tx.records, TxSetIndeterminate(w.id, true))
	return w
}

// Slider creates a slider over min..max at value, with its change
// handler co-located (nil for none) — the Fyne shape, like Button.
func (tx *Tx) Slider(min, max, value float64, onChange func(*Tx, float64)) Widget {
	w := tx.Widget(KindSlider)
	tx.records = append(tx.records, TxSetMin(w.id, min))
	tx.records = append(tx.records, TxSetMax(w.id, max))
	tx.records = append(tx.records, TxSetValue(w.id, value))
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
	tx.records = append(tx.records, TxSetMin(w.id, min))
	tx.records = append(tx.records, TxSetMax(w.id, max))
	tx.records = append(tx.records, TxBindValue(w.id, value.id))
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
	tx.records = append(tx.records, TxSetValue(w.id, float64(selected)))
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
	tx.records = append(tx.records, TxSetValue(w.id, float64(selected)))
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
	tx.records = append(tx.records, TxCreateCollection(c.id, [][]uint32{{ValueStr}}))
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
	tx.records = append(tx.records, TxCreateFor(w.id, c.id))
	tx.app.openFors = append(tx.app.openFors, c.id)
	tx.app.parents = append(tx.app.parents, 0)
	tx.app.tplDepth++
	fn(&Tpl{tx: tx})
	tx.app.tplDepth--
	tx.app.parents = tx.app.parents[:len(tx.app.parents)-1]
	tx.app.openFors = tx.app.openFors[:len(tx.app.openFors)-1]
	tx.records = append(tx.records, TxTemplateEnd())
	if parent != 0 {
		tx.records = append(tx.records, TxAddChild(parent, w.id))
	}
	return w
}

// BeginRowTrace opens a For template for a generated row trace
// (`for row := range TodoRows(tx, todos)`): the caller runs the loop
// body once with the returned Tpl, then close() ends the template and
// parents the For into the enclosing scope. Range-over-func makes the
// close structural — the iterator regains control even on break.
func BeginRowTrace(tx *Tx, c Collection) (*Tpl, func()) {
	assertRoot(c)
	tx.app.c.widget++
	w := Widget{id: tx.app.c.widget, tx: tx}
	parent := tx.currentParent()
	tx.records = append(tx.records, TxCreateFor(w.id, c.id))
	tx.app.openFors = append(tx.app.openFors, c.id)
	tx.app.parents = append(tx.app.parents, 0)
	tx.app.tplDepth++
	return &Tpl{tx: tx}, func() {
		tx.app.tplDepth--
		tx.app.parents = tx.app.parents[:len(tx.app.parents)-1]
		tx.app.openFors = tx.app.openFors[:len(tx.app.openFors)-1]
		tx.records = append(tx.records, TxTemplateEnd())
		if parent != 0 {
			tx.records = append(tx.records, TxAddChild(parent, w.id))
		}
	}
}

// When declares a When over a Bool signal: stamps on true, unstamps on
// false.
func (tx *Tx) When(s Signal[bool], fn func(*Tpl)) Widget {
	tx.app.c.widget++
	w := Widget{id: tx.app.c.widget, tx: tx}
	parent := tx.currentParent()
	tx.records = append(tx.records, TxCreateWhen(w.id, s.id))
	tx.app.parents = append(tx.app.parents, 0)
	tx.app.tplDepth++
	fn(&Tpl{tx: tx})
	tx.app.tplDepth--
	tx.app.parents = tx.app.parents[:len(tx.app.parents)-1]
	tx.records = append(tx.records, TxTemplateEnd())
	if parent != 0 {
		tx.records = append(tx.records, TxAddChild(parent, w.id))
	}
	return w
}

func (tx *Tx) Insert(c Collection, key, value any) {
	tx.app.modelSet(c.id, c.path, key, value)
	tx.records = append(tx.records, TxCollectionInsert(c.id, c.path, key, 0, []any{value}))
	tx.recomputeDerived(c.id, c.path)
}

func (tx *Tx) Update(c Collection, key, value any) {
	tx.app.modelSet(c.id, c.path, key, value)
	tx.records = append(tx.records, TxCollectionUpdate(c.id, c.path, key, 0, []any{value}))
	tx.recomputeDerived(c.id, c.path)
}

func (tx *Tx) Remove(c Collection, key any) {
	tx.app.modelRemove(c.id, c.path, key)
	tx.records = append(tx.records, TxCollectionRemove(c.id, c.path, key))
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
	tx.records = append(tx.records, TxCollectionMove(c.id, c.path, key, before))
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
	tx.app.guardMirrorRead()
	if in := tx.app.instanceOf(c.id, c.path); in != nil {
		return append([]Entry(nil), in.entries...)
	}
	return nil
}

func (tx *Tx) Len(c Collection) int {
	tx.app.guardMirrorRead()
	if in := tx.app.instanceOf(c.id, c.path); in != nil {
		return len(in.entries)
	}
	return 0
}

// Mount mounts into the default window; per-window targets arrive with
// the window vocabulary.
// WindowTitle sets the primary surface's title (the title bar on the
// desktops, the switcher label on iOS, the task label on Android).
func (tx *Tx) WindowTitle(title string) {
	tx.records = append(tx.records, TxSetWindowTitle(0, title))
}

// WindowSize requests the primary surface's content size in DIP —
// ADVISORY on every platform: honored where the window manager
// permits, recorded only where the system owns geometry.
func (tx *Tx) WindowSize(width, height float64) {
	tx.records = append(tx.records, TxSetWindowWidth(0, width))
	tx.records = append(tx.records, TxSetWindowHeight(0, height))
}

// CreateWindow creates an auxiliary window (capability-gated: phone
// hosts reject at the root); it materializes hidden and a MountIn
// presents it. Returns the prop chain:
// tx.CreateWindow(1).Title("inspector").Size(480, 320).VetoClose(true).
func (tx *Tx) CreateWindow(id uint64) WindowRef {
	tx.records = append(tx.records, TxCreateWindow(id))
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
	tx.records = append(tx.records, TxDestroyWindow(id))
}

// MountIn mounts a root into a specific window; mounting presents an
// auxiliary.
func (tx *Tx) MountIn(window uint64, root Widget) {
	tx.records = append(tx.records, TxMount(window, root.id))
}

// PushEntry pushes a navigation entry onto the primary surface's
// stack (entry ids are guest-allocated in the shared surface
// namespace, the CreateWindow discipline); it materializes covered
// and a MountIn presents it. Returns the prop chain:
// tx.PushEntry(7).Title("detail").InterceptBack(true).
func (tx *Tx) PushEntry(id uint64) EntryRef {
	tx.records = append(tx.records, TxPushEntry(0, id))
	return EntryRef{tx: tx, id: id}
}

// PushEntryIn pushes onto another window's stack (the System
// Settings shape: a stack inside a desktop auxiliary).
func (tx *Tx) PushEntryIn(window, id uint64) EntryRef {
	tx.records = append(tx.records, TxPushEntry(window, id))
	return EntryRef{tx: tx, id: id}
}

// PopEntry pops the primary stack's top entry and forgets its tree —
// also the back-veto grammar's confirmation after OnBackRequested.
// Popping an empty stack is a scene error.
func (tx *Tx) PopEntry() {
	tx.records = append(tx.records, TxPopEntry(0))
}

func (tx *Tx) PopEntryIn(window uint64) {
	tx.records = append(tx.records, TxPopEntry(window))
}

// AddSection appends a section to the primary window's section set
// (section ids are guest-allocated in the shared surface namespace);
// the set is append-only — sections have no destruction grammar, and
// every section's root is retained while covered (switching is
// SELECTION, not lifecycle). A MountIn fills its pane. Returns the
// prop chain: tx.AddSection(7).Title("Feed").OnSelected(fn).
func (tx *Tx) AddSection(id uint64) SectionRef {
	tx.records = append(tx.records, TxAddSection(0, id))
	return SectionRef{tx: tx, id: id}
}

// AddSectionIn appends onto another window's section set.
func (tx *Tx) AddSectionIn(window, id uint64) SectionRef {
	tx.records = append(tx.records, TxAddSection(window, id))
	return SectionRef{tx: tx, id: id}
}

// SelectSection selects a section programmatically: configuration,
// never echoes OnSelected (the echo doctrine).
func (tx *Tx) SelectSection(id uint64) {
	tx.records = append(tx.records, TxSelectSection(0, id))
}

func (tx *Tx) SelectSectionIn(window, id uint64) {
	tx.records = append(tx.records, TxSelectSection(window, id))
}

// SectionsPresentation sets the window's ADVISORY presentation hint
// (SectionsPresentationAuto/Bar/Sidebar — the width/height
// precedent; the phones ignore it by physics).
func (tx *Tx) SectionsPresentation(hint int64) {
	tx.records = append(tx.records, TxSetWindowSectionsPresentation(0, hint))
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
	r.tx.records = append(r.tx.records, TxShowAlert(
		r.window, r.id, uint32(len(r.actions)),
		r.title, r.message, action0, action1, r.cancel))
	return r.id
}

// WindowRef chains window props, the construction-sugar tier.
type WindowRef struct {
	tx *Tx
	id uint64
}

func (w WindowRef) Title(title string) WindowRef {
	w.tx.records = append(w.tx.records, TxSetWindowTitle(w.id, title))
	return w
}

// Size requests the content size in DIP — advisory on every platform.
func (w WindowRef) Size(width, height float64) WindowRef {
	w.tx.records = append(w.tx.records, TxSetWindowWidth(w.id, width))
	w.tx.records = append(w.tx.records, TxSetWindowHeight(w.id, height))
	return w
}

// VetoClose arms the veto class: the close button emits
// close_requested and nothing closes until DestroyWindow agrees.
func (w WindowRef) VetoClose(on bool) WindowRef {
	w.tx.records = append(w.tx.records, TxSetWindowVetoClose(w.id, on))
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

// EntryRef chains navigation-entry props, the construction-sugar tier.
type EntryRef struct {
	tx *Tx
	id uint64
}

// Title names the entry — the back affordance's label source (the
// iOS back button, the desktop headers).
func (e EntryRef) Title(title string) EntryRef {
	e.tx.records = append(e.tx.records, TxSetEntryTitle(e.id, title))
	return e
}

// InterceptBack arms the close-veto class transplanted to POP: back
// emits back_requested and nothing pops until PopEntry agrees.
func (e EntryRef) InterceptBack(on bool) EntryRef {
	e.tx.records = append(e.tx.records, TxSetEntryInterceptBack(e.id, on))
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
	r.tx.records = append(r.tx.records, TxSetSectionTitle(r.id, title))
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
	t.tx.autoParent(n.id)
	return n
}

func (t *Tpl) SetText(n Node, text string) {
	t.tx.records = append(t.tx.records, TxSetText(n.id, text))
}

// BindTextElement binds text to the element of the enclosing For,
// `level` Fors up (0 = nearest).
func (t *Tpl) BindTextElement(n Node, level uint32) {
	t.tx.records = append(t.tx.records, TxBindTextElement(n.id, level, 0))
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
	t.tx.records = append(t.tx.records, TxAddChild(parent.id, child.id))
}

func (t *Tpl) Collection() Collection {
	return t.tx.Collection()
}

func (t *Tpl) ForEach(c Collection, fn func(*Tpl)) Node {
	assertRoot(c)
	t.tx.app.c.node++
	n := Node{t.tx.app.c.node}
	parent := t.tx.currentParent()
	t.tx.records = append(t.tx.records, TxCreateFor(n.id, c.id))
	t.tx.app.openFors = append(t.tx.app.openFors, c.id)
	t.tx.app.parents = append(t.tx.app.parents, 0)
	t.tx.app.tplDepth++
	fn(&Tpl{tx: t.tx})
	t.tx.app.tplDepth--
	t.tx.app.parents = t.tx.app.parents[:len(t.tx.app.parents)-1]
	t.tx.app.openFors = t.tx.app.openFors[:len(t.tx.app.openFors)-1]
	t.tx.records = append(t.tx.records, TxTemplateEnd())
	if parent != 0 {
		t.tx.records = append(t.tx.records, TxAddChild(parent, n.id))
	}
	return n
}

func (t *Tpl) When(s Signal[bool], fn func(*Tpl)) Node {
	t.tx.app.c.node++
	n := Node{t.tx.app.c.node}
	t.tx.records = append(t.tx.records, TxCreateWhen(n.id, s.id))
	t.tx.app.tplDepth++
	fn(&Tpl{tx: t.tx})
	t.tx.app.tplDepth--
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
			kind, id, keys, payload, ok := NextOccurrence()
			if !ok {
				return // shutdown
			}
			text, _ := payload.(string)
			checked, _ := payload.(bool)
			value, _ := payload.(float64)
			choice, _ := payload.(uint32)
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
			}
		}
	}()
	code := Run()
	<-done
	return code
}
