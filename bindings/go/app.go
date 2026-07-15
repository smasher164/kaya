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

type Collection struct{ id uint64 }

type counters struct {
	signal, widget, collection, node uint64
}

// App owns the id counters (which outlive any one transaction) and the
// dispatch tables.
type App struct {
	c              counters
	widgetHandlers map[uint64]func(*Tx)
	nodeHandlers   map[uint64]func(*Tx, []any)
}

func NewApp() *App {
	Init()
	return &App{
		widgetHandlers: make(map[uint64]func(*Tx)),
		nodeHandlers:   make(map[uint64]func(*Tx, []any)),
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
	c := Collection{tx.app.c.collection}
	tx.records = append(tx.records, TxCreateCollection(c.id))
	return c
}

// ForEach declares a For over c: fn's body declares the template, and
// the For itself (a live container) is returned.
func (tx *Tx) ForEach(c Collection, fn func(*Tpl)) Widget {
	tx.app.c.widget++
	w := Widget{tx.app.c.widget}
	tx.records = append(tx.records, TxCreateFor(w.id, c.id))
	fn(&Tpl{tx: tx})
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

func (tx *Tx) Insert(c Collection, path []any, key, value any) {
	tx.records = append(tx.records, TxCollectionInsert(c.id, path, key, value))
}

func (tx *Tx) Update(c Collection, path []any, key, value any) {
	tx.records = append(tx.records, TxCollectionUpdate(c.id, path, key, value))
}

func (tx *Tx) Remove(c Collection, path []any, key any) {
	tx.records = append(tx.records, TxCollectionRemove(c.id, path, key))
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
	t.tx.app.c.node++
	n := Node{t.tx.app.c.node}
	t.tx.records = append(t.tx.records, TxCreateFor(n.id, c.id))
	fn(&Tpl{tx: t.tx})
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

// Run enters the core on the calling goroutine's thread (which must be
// the process main thread; use runtime.LockOSThread in an init
// function), dispatching occurrences on a second goroutine. Returns the
// exit code.
func (a *App) Run() int {
	done := make(chan struct{})
	go func() {
		defer close(done)
		for {
			id, keys, ok := NextClick()
			if !ok {
				return // shutdown
			}
			if len(keys) == 0 {
				if fn := a.widgetHandlers[id]; fn != nil {
					a.Build(func(tx *Tx) { fn(tx) })
				}
			} else if fn := a.nodeHandlers[id]; fn != nil {
				a.Build(func(tx *Tx) { fn(tx, keys) })
			}
		}
	}()
	code := Run()
	<-done
	return code
}
