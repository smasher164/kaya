package dev.kaya;

import java.lang.invoke.MethodHandle;
import java.lang.invoke.MethodHandles;
import java.lang.reflect.Field;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.function.BiConsumer;
import java.util.function.Consumer;

/**
 * kaya's idiomatic surface for the JVM: the structural core.
 *
 * Three jobs, layered over KayaRing (the JNI ring access) and the
 * generated wire vocabulary (KayaWire):
 *
 * <ul>
 *   <li>id allocation: signals, widgets, collections, and template
 *       nodes come from per-space counters behind distinct types, so no
 *       app hand-numbers the id spaces — and the compiler keeps
 *       blueprint nodes (Node) from being used where live widgets
 *       (Widget) belong;
 *   <li>template scoping: forEach and when take a Consumer&lt;Tpl&gt;
 *       whose body declares the blueprint, bracketing the records;
 *   <li>occurrence dispatch: handlers register per button; the app loop
 *       consumes the ring with the platform's hand-won recipe (Unsafe
 *       fenced access on raw addresses; see the git history for the ART
 *       findings) and routes each click, handing template-node handlers
 *       the stamped copy's key path. Handlers receive their transaction
 *       explicitly; it submits when the handler returns.
 * </ul>
 */
public final class KayaApp {
    /**
     * A container's cross-axis child placement (the align spec enum;
     * wire values pinned by the generated KayaWire constants).
     * Baseline is rows-only — the scene rejects it on columns.
     */
    public enum Align {
        START(0), CENTER(1), END(2), STRETCH(3), BASELINE(4);

        final long wire;

        Align(long wire) {
            this.wire = wire;
        }
    }

    private long signals, widgets, collections, nodes;
    private final Map<Long, Consumer<Tx>> widgetHandlers = new HashMap<>();
    private final Map<Long, BiConsumer<Tx, List<Object>>> nodeHandlers = new HashMap<>();
    private final Map<Long, BiConsumer<Tx, String>> widgetChanges = new HashMap<>();
    private final Map<Long, ChangeHandler> nodeChanges = new HashMap<>();
    private final Map<Long, BiConsumer<Tx, Boolean>> widgetToggles = new HashMap<>();
    private final Map<Long, BiConsumer<Tx, Double>> widgetValues = new HashMap<>();
    // Window lifecycle: one handler each, receiving the window id.
    final java.util.Map<Long, Consumer<Tx>> closeRequested = new java.util.HashMap<>();
    final java.util.Map<Long, Consumer<Tx>> entryPopped = new java.util.HashMap<>();
    final java.util.Map<Long, Consumer<Tx>> backRequested = new java.util.HashMap<>();
    private final java.util.Map<Long, BiConsumer<Tx, Integer>> alerts =
            new java.util.HashMap<>();
    private long nextAlert;
    final java.util.Map<Long, Consumer<Tx>> windowClosed = new java.util.HashMap<>();
    private final Map<Long, ToggleHandler> nodeToggles = new HashMap<>();
    // The ambient parent stack: containers push their id around their
    // body, constructors parent to the top, and 0 is the template-root
    // sentinel (template bodies root themselves; a cross-zone addChild
    // is structurally impossible). The ambient app/tx pair exists for
    // the generated row traces — an Iterable is static code, and a
    // collection is only an id (one app per guest process, the Python
    // binding's own assumption).
    static KayaApp ambient;
    Tx currentTx;
    final java.util.List<Long> parents = new java.util.ArrayList<>();
    int openTraces;
    // >0 while a template body is being declared (a For body, a When
    // body, or an open row trace). openFors tracks Fors only — when()
    // pushes nothing there — so template-scope detection needs its own
    // counter. The template records once and replays: a model read
    // inside its body would bake one snapshot into every stamp as
    // silently dead data, so mirror reads throw while this is armed;
    // live-zone, handler, and build reads stay legal.
    int tplDepth;
    // Signals recomputed from a collection after each of its
    // mutations, written into the same transaction.
    private final Map<Long, List<Consumer<Tx>>> derived = new HashMap<>();

    /** A template entry's change handler: the stamped copy's keys, then
     * the entry's new text. */
    public interface ChangeHandler {
        void accept(Tx tx, List<Object> keys, String text);
    }

    /** A template checkbox's toggle handler: the stamped copy's keys,
     * then the box's new state. */
    public interface ToggleHandler {
        void accept(Tx tx, List<Object> keys, boolean checked);
    }

    // The collection is the model — the only copy: every mutation op
    // edits it and queues the wire delta in the same call, so reads
    // (items, count) are exactly the writes. childCollections records
    // the declared-inside-a-For edges the model purges along when a
    // parent entry's copy is torn down.
    private final Map<Long, List<Instance>> model = new HashMap<>();
    private final Map<Long, List<Long>> childCollections = new HashMap<>();
    private final List<Long> openFors = new ArrayList<>();

    /** One key/value pair of a collection instance, in insertion order. */
    public static final class Entry {
        public final Object key;
        public final Object value;

        Entry(Object key, Object value) {
            this.key = key;
            this.value = value;
        }
    }

    /**
     * One instance of a collection: the table inside the stamped copy
     * selected by path (the empty path for a live-zone collection).
     */
    private static final class Instance {
        final List<Object> path;
        final List<Entry> entries = new ArrayList<>();

        Instance(List<Object> path) {
            this.path = path;
        }

        Instance copy() {
            Instance c = new Instance(path);
            c.entries.addAll(entries);
            return c;
        }
    }

    private Instance instanceOf(long coll, List<Object> path) {
        for (Instance instance : model.getOrDefault(coll, java.util.Collections.emptyList())) {
            if (instance.path.equals(path)) {
                return instance;
            }
        }
        return null;
    }

    /**
     * A collection declared inside a For's template is torn down with
     * its copies: record the edge so the model purges along it.
     */
    private void registerCollection(long id) {
        if (!openFors.isEmpty()) {
            childCollections
                    .computeIfAbsent(openFors.get(openFors.size() - 1), k -> new ArrayList<>())
                    .add(id);
        }
    }

    /** A signal carrying its value type: writes are checked at compile
     * time, and when() demands a {@code Signal<Boolean>} instead of
     * panicking in the scene. */
    public static final class Signal<V> {
        final long id;

        Signal(long id) {
            this.id = id;
        }
    }

    /**
     * A live widget: exactly one thing on screen. It carries the
     * transaction that minted it so construction chains read
     * declaratively (tx.label(s).grow(1)); the id alone is the
     * widget's name, and a Widget stored past its build keeps naming
     * the same widget — only the chain methods die with it.
     */
    /** The window-prop chain, in the construction-sugar tier. */
    /** The alert chain: accumulates the one atomic SHOW_ALERT record
     * and sends it at show() — a request has a send moment, unlike a
     * window declaration. A chain that never calls show() sends
     * nothing. */
    public static final class AlertRef {
        private final Tx tx;
        private final KayaApp app;
        private final long id;
        private long window;
        private String title = "";
        private String message = "";
        private final java.util.ArrayList<String> actions = new java.util.ArrayList<>();
        private String cancel = "";
        private BiConsumer<Tx, Integer> onResult;

        AlertRef(Tx tx, KayaApp app, long id) {
            this.tx = tx;
            this.app = app;
            this.id = id;
        }

        /** Present over this window instead of the primary. */
        public AlertRef inWindow(long window) {
            this.window = window;
            return this;
        }

        public AlertRef title(String title) {
            this.title = title;
            return this;
        }

        public AlertRef message(String message) {
            this.message = message;
            return this;
        }

        /** Add an action button (at most two — the platform floor). */
        public AlertRef action(String label) {
            if (actions.size() >= 2) {
                throw new IllegalStateException(
                        "kaya: an alert carries at most 2 actions (the platform floor)");
            }
            actions.add(label);
            return this;
        }

        /** Name the always-present cancel slot. Required. */
        public AlertRef cancel(String label) {
            this.cancel = label;
            return this;
        }

        /** Bind the one-shot result handler to THIS request. */
        public AlertRef onResult(BiConsumer<Tx, Integer> handler) {
            this.onResult = handler;
            return this;
        }

        /** Send the request, returning its id; the one answer arrives
         * at the onResult handler. */
        public long show() {
            if (cancel.isEmpty()) {
                throw new IllegalStateException(
                        "kaya: the cancel slot always exists and needs a name — "
                                + "call cancel(label) before show()");
            }
            String action0 = actions.size() >= 1 ? actions.get(0) : "";
            String action1 = actions.size() == 2 ? actions.get(1) : "";
            if (onResult != null) {
                app.alerts.put(id, onResult);
            }
            tx.records.add(KayaWire.txShowAlert(
                    window, id, actions.size(), title, message,
                    action0, action1, cancel));
            return id;
        }
    }

    public static final class WindowRef {
        private final Tx tx;
        private final KayaApp app;
        private final long id;

        WindowRef(Tx tx, KayaApp app, long id) {
            this.tx = tx;
            this.app = app;
            this.id = id;
        }

        /** Binds the close-veto handler to THIS window (per-window —
         * handlers scope to the thing that creates them): fires per
         * chrome close while vetoClose is armed; nothing has closed —
         * answer with tx.destroyWindow to agree. */
        public WindowRef onCloseRequested(Consumer<Tx> handler) {
            app.closeRequested.put(id, handler);
            return this;
        }

        /** Binds the closed handler to THIS window: fires when the
         * non-veto auxiliary is chrome-closed (informational;
         * destroyWindow reconciles), retiring with it. */
        public WindowRef onClosed(Consumer<Tx> handler) {
            app.windowClosed.put(id, handler);
            return this;
        }

        /** The surface's title (title bar / switcher / task label). */
        public WindowRef title(String title) {
            tx.records.add(KayaWire.txSetWindowTitle(id, title));
            return this;
        }

        /** The ADVISORY content-size request in DIP. */
        public WindowRef size(double width, double height) {
            tx.records.add(KayaWire.txSetWindowWidth(id, width));
            tx.records.add(KayaWire.txSetWindowHeight(id, height));
            return this;
        }

        /** Arms the veto class for the chrome close. */
        public WindowRef vetoClose(boolean on) {
            tx.records.add(KayaWire.txSetWindowVetoClose(id, on));
            return this;
        }

        /** The window id, for mountIn. */
        public long id() {
            return id;
        }
    }

    /** Chains navigation-entry props, the construction-sugar tier:
     * tx.pushEntry(7).title("detail").interceptBack(true). */
    public static final class EntryRef {
        private final Tx tx;
        private final KayaApp app;
        private final long id;

        EntryRef(Tx tx, KayaApp app, long id) {
            this.tx = tx;
            this.app = app;
            this.id = id;
        }

        /** The entry's title — the back affordance's label source. */
        public EntryRef title(String title) {
            tx.records.add(KayaWire.txSetEntryTitle(id, title));
            return this;
        }

        /** Arms the close-veto class transplanted to POP: back emits
         * back_requested and nothing pops until popEntry agrees. */
        public EntryRef interceptBack(boolean on) {
            tx.records.add(KayaWire.txSetEntryInterceptBack(id, on));
            return this;
        }

        /** Binds the popped handler to THIS entry (per-entry, the
         * request-bound alert precedent — no id inspection anywhere):
         * fires when the user's back affordance pops it natively
         * (post-fact; a programmatic popEntry does not fire it — its
         * caller already knows), retiring with the one pop. */
        public EntryRef onPopped(Consumer<Tx> handler) {
            app.entryPopped.put(id, handler);
            return this;
        }

        /** Binds the back-veto handler to THIS entry: fires per back
         * request while interceptBack is armed — nothing has popped;
         * answer with tx.popEntry to agree. */
        public EntryRef onBackRequested(Consumer<Tx> handler) {
            app.backRequested.put(id, handler);
            return this;
        }

        /** The entry's surface id, for mountIn. */
        public long id() {
            return id;
        }
    }

    public static final class Widget {
        final long id;
        final Tx tx;

        Widget(long id, Tx tx) {
            this.id = id;
            this.tx = tx;
        }

        /**
         * Weight this widget within its row/column at construction —
         * the declarative chain. Appends to the transaction that
         * minted the widget, so it belongs in the build body; on a
         * Widget that outlived its build it fails loudly — use
         * Tx.setGrow inside a live transaction for dynamic changes.
         */
        public Widget grow(double weight) {
            if (tx == null || tx.closed) {
                throw new IllegalStateException(
                    "kaya: grow on a widget outside its build transaction"
                    + " — use Tx.setGrow inside a live transaction");
            }
            tx.setGrow(this, weight);
            return this;
        }

        /**
         * This container's inter-child gap at construction — the
         * declarative chain: tx.column(() -> {...}).spacing(12).
         * Same transaction discipline as grow.
         */
        public Widget spacing(double gap) {
            if (tx == null || tx.closed) {
                throw new IllegalStateException(
                    "kaya: spacing on a widget outside its build transaction"
                    + " — use Tx.setSpacing inside a live transaction");
            }
            tx.setSpacing(this, gap);
            return this;
        }

        /**
         * This container's cross-axis child placement at construction
         * — the declarative chain:
         * tx.row(() -> {...}).align(Align.BASELINE). Same transaction
         * discipline as grow.
         */
        public Widget align(Align align) {
            if (tx == null || tx.closed) {
                throw new IllegalStateException(
                    "kaya: align on a widget outside its build transaction"
                    + " — use Tx.setAlign inside a live transaction");
            }
            tx.setAlign(this, align);
            return this;
        }
    }

    /**
     * A template node: a blueprint entry, stamped per collection entry.
     * Never on screen by itself; clicks on its copies arrive with the
     * copy's key path.
     */
    public static final class Node {
        final long id;

        Node(long id) {
            this.id = id;
        }
    }

    /**
     * A collection instance handle: the collection plus the key path
     * selecting one stamped copy's table. Tx.collection() returns the
     * root (empty-path, live-zone) handle; at() steps into a copy, one
     * key per enclosing For. Mutations and reads take the handle, so
     * the target is spelled once.
     */
    public static final class Collection {
        final long id;
        final List<Object> path;

        Collection(long id, List<Object> path) {
            this.id = id;
            this.path = path;
        }

        /**
         * The instance of this collection inside the copy keyed by
         * {@code key} of the next enclosing For; chain for deeper
         * nesting.
         */
        public Collection at(Object key) {
            List<Object> deeper = new ArrayList<>(path);
            deeper.add(key);
            return new Collection(id, deeper);
        }

        // A For binds the collection itself — its template stamps per
        // entry of every instance — so handing it an at(...) handle is
        // a bug.
        void assertRoot() {
            if (!path.isEmpty()) {
                throw new IllegalArgumentException(
                        "kaya: forEach binds the collection itself, not an instance"
                                + " — drop the at(...)");
            }
        }
    }

    /**
     * A stamped template: the For/When handle in the enclosing zone
     * plus whatever the body chose to return — the way handles declared
     * inside the template (nested collections, buttons) reach the
     * handlers, since Java lambdas cannot assign captured locals.
     */
    /** An open generated row trace: the Tpl the loop body records
     * against, and the close that ends the template. */
    public static final class RowTrace {
        public final Tpl tpl;
        private final Runnable close;

        RowTrace(Tpl tpl, Runnable close) {
            this.tpl = tpl;
            this.close = close;
        }

        public void close() {
            close.run();
        }
    }

    public static final class Stamped<H, R> {
        public final H handle;
        public final R out;

        Stamped(H handle, R out) {
            this.handle = handle;
            this.out = out;
        }
    }

    /**
     * One transaction: everything queued inside build (or a handler)
     * applies atomically when it returns.
     */
    public final class Tx {
        /**
         * Set when the enclosing build finishes with this transaction,
         * committed or rolled back: a construction chain
         * (Widget.grow) on a widget that outlived its build must die
         * loudly, not append into an orphaned record list.
         */
        boolean closed;

        private final List<byte[]> records = new ArrayList<>();

        // How to undo this transaction's model edits: a snapshot per
        // touched collection, taken on first touch.
        private final Map<Long, List<Instance>> journal = new HashMap<>();

        // Deriveds registered in this transaction: promoted to the app
        // registry on submit, abandoned with a rolled-back Tx (their
        // signals were never created).
        private final List<Map.Entry<Long, Consumer<Tx>>> pendingDerived = new ArrayList<>();

        void registerDerived(long coll, Consumer<Tx> recompute) {
            pendingDerived.add(Map.entry(coll, recompute));
        }

        /** Every derived signal rooted at this collection, recomputed
         * and written into this transaction. Deriveds hang off root
         * handles, so nested-instance mutations cannot change their
         * input. */
        private void recomputeDerived(Collection c) {
            if (!c.path.isEmpty()) {
                return;
            }
            for (Consumer<Tx> recompute : derived.getOrDefault(c.id, java.util.Collections.emptyList())) {
                recompute.accept(this);
            }
            for (Map.Entry<Long, Consumer<Tx>> entry : pendingDerived) {
                if (entry.getKey() == c.id) {
                    entry.getValue().accept(this);
                }
            }
        }

        void submitIfAny() {
            if (openTraces != 0) {
                openTraces = 0;
                // The open trace also left the template-scope counter
                // armed; a stuck counter would poison later reads.
                tplDepth = 0;
                throw new IllegalStateException(
                        "kaya: a for-each over rows was exited early (break?)"
                                + " — the template never closed");
            }
            for (Map.Entry<Long, Consumer<Tx>> entry : pendingDerived) {
                derived.computeIfAbsent(entry.getKey(), k -> new ArrayList<>()).add(entry.getValue());
            }
            pendingDerived.clear();
            if (!records.isEmpty()) {
                KayaRing.submit(KayaWire.tx(records.toArray(new byte[0][])));
            }
        }

        void rollback() {
            openTraces = 0;
            // App state, not tx state: an aborted build is abandoned
            // but the app continues, and a stuck counter would poison
            // every later mirror read.
            tplDepth = 0;
            parents.clear();
            model.putAll(journal);
        }

        private void touch(long coll) {
            if (journal.containsKey(coll)) {
                return;
            }
            List<Instance> snapshot = new ArrayList<>();
            for (Instance instance : model.getOrDefault(coll, java.util.Collections.emptyList())) {
                snapshot.add(instance.copy());
            }
            journal.put(coll, snapshot);
        }

        private void modelSet(long coll, List<Object> path, Object key, Object value) {
            touch(coll);
            Instance instance = instanceOf(coll, path);
            if (instance == null) {
                instance = new Instance(path);
                model.computeIfAbsent(coll, k -> new ArrayList<>()).add(instance);
            }
            for (int i = 0; i < instance.entries.size(); i++) {
                if (java.util.Objects.equals(instance.entries.get(i).key, key)) {
                    instance.entries.set(i, new Entry(key, value));
                    return;
                }
            }
            instance.entries.add(new Entry(key, value));
        }

        private void modelRemove(long coll, List<Object> path, Object key) {
            touch(coll);
            Instance instance = instanceOf(coll, path);
            if (instance != null) {
                instance.entries.removeIf(e -> java.util.Objects.equals(e.key, key));
            }
            // The core tears down the copy, taking descendant collection
            // instances with it; the model follows.
            List<Object> prefix = new ArrayList<>(path);
            prefix.add(key);
            purgeChildren(coll, prefix);
        }

        private void modelMove(long coll, List<Object> path, Object key, Object[] before) {
            touch(coll);
            Instance instance = instanceOf(coll, path);
            // The same checks the scene makes, made where the guest
            // can see the stack: a missing key or anchor is a guest
            // bug, never a fallback. Both validated before anything
            // mutates.
            int pos = -1;
            if (instance != null) {
                for (int i = 0; i < instance.entries.size(); i++) {
                    if (java.util.Objects.equals(instance.entries.get(i).key, key)) {
                        pos = i;
                        break;
                    }
                }
            }
            if (pos < 0) {
                throw new IllegalStateException("kaya: move of missing key " + key);
            }
            if (before.length > 0) {
                boolean found = false;
                for (Entry entry : instance.entries) {
                    if (java.util.Objects.equals(entry.key, before[0])) {
                        found = true;
                        break;
                    }
                }
                if (!found) {
                    throw new IllegalStateException("kaya: move before missing key " + before[0]);
                }
            }
            Entry entry = instance.entries.remove(pos);
            int at = instance.entries.size();
            if (before.length > 0) {
                for (int i = 0; i < instance.entries.size(); i++) {
                    if (java.util.Objects.equals(instance.entries.get(i).key, before[0])) {
                        at = i;
                        break;
                    }
                }
            }
            instance.entries.add(at, entry);
        }

        private List<Object> keysOf(Collection c) {
            List<Object> keys = new ArrayList<>();
            Instance instance = instanceOf(c.id, c.path);
            if (instance != null) {
                for (Entry entry : instance.entries) {
                    keys.add(entry.key);
                }
            }
            return keys;
        }

        private void purgeChildren(long coll, List<Object> prefix) {
            for (long kid : childCollections.getOrDefault(coll, java.util.Collections.emptyList())) {
                touch(kid);
                List<Instance> instances = model.get(kid);
                if (instances != null) {
                    instances.removeIf(i -> i.path.size() >= prefix.size()
                            && i.path.subList(0, prefix.size()).equals(prefix));
                }
                purgeChildren(kid, prefix);
            }
        }

        public <V> Signal<V> signal(V initial) {
            Signal s = new Signal<>(++signals);
            records.add(KayaWire.txCreateSignal(s.id, initial));
            return s;
        }

        public <V> void write(Signal<V> s, V value) {
            records.add(KayaWire.txWriteSignal(s.id, value));
        }

        public Widget widget(int kind) {
            Widget w = new Widget(++widgets, this);
            records.add(KayaWire.txCreateWidget(w.id, kind));
            autoParent(w.id);
            return w;
        }

        // The current ambient parent (0 when the scope roots itself:
        // template bodies, or no open container).
        long currentParent() {
            return parents.isEmpty() ? 0 : parents.get(parents.size() - 1);
        }

        void autoParent(long id) {
            long p = currentParent();
            if (p != 0) {
                records.add(KayaWire.txAddChild(p, id));
            }
        }

        public void setText(Widget w, String text) {
            records.add(KayaWire.txSetText(w.id, text));
        }

        public void setChecked(Widget w, boolean checked) {
            records.add(KayaWire.txSetChecked(w.id, checked));
        }

        /**
         * Set a widget's flex weight within its row/column: 0 is
         * natural size, positive weights divide the container's
         * leftover main-axis space in proportion (see Prop::Grow in
         * the core). Java has no named or optional arguments, so the
         * setter directly after construction is both the declarative
         * spelling and the dynamic path.
         */
        public void setGrow(Widget w, double weight) {
            records.add(KayaWire.txSetGrow(w.id, weight));
        }

        /**
         * A container's inter-child gap (main axis, DIP; the
         * normalized default is 8). Containers only — the scene
         * rejects it anywhere else.
         */
        public void setSpacing(Widget w, double gap) {
            records.add(KayaWire.txSetSpacing(w.id, gap));
        }

        /**
         * A container's cross-axis child placement. Containers only;
         * baseline is rows-only — the scene rejects misuse at the
         * root.
         */
        public void setAlign(Widget w, Align align) {
            records.add(KayaWire.txSetAlign(w.id, align.wire));
        }

        public void bindChecked(Widget w, Signal<Boolean> s) {
            records.add(KayaWire.txBindChecked(w.id, s.id));
        }

        public void bindText(Widget w, Signal<String> s) {
            records.add(KayaWire.txBindText(w.id, s.id));
        }

        /**
         * Point an image at encoded bytes (PNG, JPEG, ...): registers
         * them with the core now — one copy into core memory; the u64
         * handle is consumed by this transaction's submit, so the
         * caller's array is free to change the moment this returns.
         * Handles are single-submit: setting again re-registers.
         */
        public void setSource(Widget w, byte[] source) {
            records.add(KayaWire.txSetSource(w.id, KayaRing.blobRegister(source)));
        }

        public void bindSource(Widget w, Signal<byte[]> s) {
            records.add(KayaWire.txBindSource(w.id, s.id));
        }

        // Construction sugar: containers take their body as a
        // Runnable and parent everything declared inside it (the
        // ambient stack); the common constructors carry their
        // essential prop, so the build body reads as the tree.
        // Statement position is the point: a for-each over a generated
        // row trace stands between siblings. Handler registration
        // stays explicit (app.onClick), the Java idiom.
        public Widget column(Runnable body) {
            return containerOf(KayaWire.KIND_COLUMN, body);
        }

        public Widget row(Runnable body) {
            return containerOf(KayaWire.KIND_ROW, body);
        }

        /** A vertical scroll viewport over EXACTLY ONE child (declare
         * it in the body; the scene rejects a second). Chain .grow(1)
         * so the enclosing track CONSTRAINS it — an unconstrained
         * viewport hugs its content and nothing overflows. */
        public Widget scroll(Runnable body) {
            return containerOf(KayaWire.KIND_SCROLL, body);
        }

        private Widget containerOf(int kind, Runnable body) {
            Widget parent = widget(kind);
            parents.add(parent.id);
            if (body != null) {
                body.run();
            }
            parents.remove(parents.size() - 1);
            return parent;
        }

        /** A button with its caption. */
        public Widget button(String text) {
            Widget w = widget(KayaWire.KIND_BUTTON);
            setText(w, text);
            return w;
        }

        /** A button with its caption and click handler — the Swing
         * JButton(Action) shape. */
        public Widget button(String text, Consumer<Tx> onClick) {
            Widget w = button(text);
            KayaApp.this.onClick(w, onClick);
            return w;
        }

        /** A labeled checkbox with its toggle handler co-located
         * (null for none). */
        public Widget checkbox(String text, BiConsumer<Tx, Boolean> onToggle) {
            Widget w = widget(KayaWire.KIND_CHECKBOX);
            setText(w, text);
            if (onToggle != null) {
                KayaApp.this.onToggle(w, onToggle);
            }
            return w;
        }

        /** A progress bar: display-only, like label and image.
         * value is the determinate fraction (0..=1);
         * progressIndeterminate is the activity-mode arm. */
        public Widget progress(double value) {
            Widget w = widget(KayaWire.KIND_PROGRESS);
            records.add(KayaWire.txSetValue(w.id, value));
            return w;
        }

        /** A progress bar in the platform's activity mode. */
        public Widget progressIndeterminate() {
            Widget w = widget(KayaWire.KIND_PROGRESS);
            records.add(KayaWire.txSetIndeterminate(w.id, true));
            return w;
        }

        /** A slider whose position binds a float signal — the
         * programmatic write path (write fans out to the control;
         * property writes never echo an occurrence, so a handler's
         * own writes cannot loop back at it). */
        public Widget slider(double min, double max, Signal<Double> value,
                BiConsumer<Tx, Double> onChange) {
            Widget w = widget(KayaWire.KIND_SLIDER);
            records.add(KayaWire.txSetMin(w.id, min));
            records.add(KayaWire.txSetMax(w.id, max));
            records.add(KayaWire.txBindValue(w.id, value.id));
            if (onChange != null) {
                KayaApp.this.onValueChanged(w, onChange);
            }
            return w;
        }

        /** A slider over min..max at value, with its change handler
         * co-located (null for none). */
        public Widget slider(double min, double max, double value,
                BiConsumer<Tx, Double> onChange) {
            Widget w = widget(KayaWire.KIND_SLIDER);
            records.add(KayaWire.txSetMin(w.id, min));
            records.add(KayaWire.txSetMax(w.id, max));
            records.add(KayaWire.txSetValue(w.id, value));
            if (onChange != null) {
                KayaApp.this.onValueChanged(w, onChange);
            }
            return w;
        }

        /** A dropdown select over fixed options — each option
         * becomes a label child (labels only, scene-checked) — at
         * selected, the initial 0-based index (domain-checked at the
         * root against the option count), with its pick handler
         * co-located (null for none): onSelect receives each USER
         * pick's new 0-based index (programmatic writes never echo)
         * — the slider's uncontrolled contract. */
        public Widget select(String[] options, int selected,
                BiConsumer<Tx, Integer> onSelect) {
            Widget w = widget(KayaWire.KIND_SELECT);
            parents.add(w.id);
            for (String option : options) {
                Widget o = widget(KayaWire.KIND_LABEL);
                setText(o, option);
            }
            parents.remove(parents.size() - 1);
            records.add(KayaWire.txSetValue(w.id, selected));
            if (onSelect != null) {
                KayaApp.this.onValueChanged(w,
                        (tx, v) -> onSelect.accept(tx, (int) (double) v));
            }
            return w;
        }

        /** A radio group over fixed options — the choice contract
         * (see select) in its inline presentation: same option
         * children, same 0-based selected index, same pick handler
         * (null for none). */
        public Widget radio(String[] options, int selected,
                BiConsumer<Tx, Integer> onSelect) {
            Widget w = widget(KayaWire.KIND_RADIO);
            parents.add(w.id);
            for (String option : options) {
                Widget o = widget(KayaWire.KIND_LABEL);
                setText(o, option);
            }
            parents.remove(parents.size() - 1);
            records.add(KayaWire.txSetValue(w.id, selected));
            if (onSelect != null) {
                KayaApp.this.onValueChanged(w,
                        (tx, v) -> onSelect.accept(tx, (int) (double) v));
            }
            return w;
        }

        /** A label bound to a signal. */
        public Widget label(Signal<String> s) {
            Widget w = widget(KayaWire.KIND_LABEL);
            bindText(w, s);
            return w;
        }

        /** A text field; register its handler with app.onChange. */
        public Widget entry() {
            return widget(KayaWire.KIND_ENTRY);
        }

        /** A text field with its change handler. */
        public Widget entry(BiConsumer<Tx, String> onChange) {
            Widget w = entry();
            KayaApp.this.onChange(w, onChange);
            return w;
        }

        /**
         * An image displaying encoded bytes (PNG, JPEG, ...): the
         * toolkit decodes natively, and decode failure renders the
         * placeholder, never a crash. Registration semantics per
         * setSource: one copy into core memory, the handle consumed by
         * this transaction's submit.
         */
        public Widget image(byte[] source) {
            Widget w = widget(KayaWire.KIND_IMAGE);
            setSource(w, source);
            return w;
        }

        /** An image bound to a blob signal. */
        public Widget image(Signal<byte[]> s) {
            Widget w = widget(KayaWire.KIND_IMAGE);
            bindSource(w, s);
            return w;
        }

        public void addChild(Widget parent, Widget child) {
            records.add(KayaWire.txAddChild(parent.id, child.id));
        }

        /**
         * Drop the widget's owned content — a one-shot command:
         * momentary verbs into widget-owned state, riding this
         * transaction like any write, so the insert and the clear
         * beside it commit together or not at all. Fire-and-forget: no
         * state at rest, nothing to journal, and the widget answers
         * through its normal occurrence path (a clear arrives back as
         * a text change with empty text, so the app's draft fold
         * empties itself — never a side assignment).
         */
        public void clear(Widget w) {
            records.add(KayaWire.txWidgetCommand(w.id, KayaWire.COMMAND_CLEAR));
        }

        /** Give the widget keyboard focus (the post-submit refocus
         * every real form wants) — a one-shot command riding the
         * transaction like clear. */
        public void focus(Widget w) {
            records.add(KayaWire.txWidgetCommand(w.id, KayaWire.COMMAND_FOCUS));
        }

        public Collection collection() {
            Collection c = new Collection(++collections, java.util.Collections.emptyList());
            registerCollection(c.id);
            records.add(KayaWire.txCreateCollection(c.id, new int[][] { { KayaWire.VALUE_STR } }));
            return c;
        }

        /**
         * A For over {@code c}: the body declares the template; the For
         * itself (a live container) is returned.
         */
        public Widget forEach(Collection c, Consumer<Tpl> body) {
            return forEach(c, t -> {
                body.accept(t);
                return null;
            }).handle;
        }

        /**
         * A For whose body returns the handles it declared — they come
         * back alongside the For itself.
         */
        public <R> Stamped<Widget, R> forEach(
                Collection c, java.util.function.Function<Tpl, R> body) {
            c.assertRoot();
            Widget w = new Widget(++widgets, this);
            // The For parents into the enclosing scope, but the record
            // must land after template_end — an addChild inside the
            // blueprint would cross zones.
            long parent = currentParent();
            records.add(KayaWire.txCreateFor(w.id, c.id));
            openFors.add(c.id);
            parents.add(0L);
            // try/finally: a throwing body abandons the tx but the app
            // survives, and a stuck counter would poison later reads.
            tplDepth++;
            R out;
            try {
                out = body.apply(new Tpl(this));
            } finally {
                tplDepth--;
            }
            parents.remove(parents.size() - 1);
            openFors.remove(openFors.size() - 1);
            records.add(KayaWire.txTemplateEnd());
            if (parent != 0) {
                records.add(KayaWire.txAddChild(parent, w.id));
            }
            return new Stamped<>(w, out);
        }

        /** Open a For template for a generated row trace; the trace
         * hands the loop body the Tpl once, then close() ends the
         * template and parents the For into the enclosing scope. A
         * break leaves the trace open — caught at submit. */
        RowTrace beginRowTrace(Collection c) {
            c.assertRoot();
            Widget w = new Widget(++widgets, this);
            long parent = currentParent();
            records.add(KayaWire.txCreateFor(w.id, c.id));
            openFors.add(c.id);
            parents.add(0L);
            openTraces++;
            // The counter drops in close(); a break leaves it armed
            // alongside openTraces, and submitIfAny resets both.
            tplDepth++;
            return new RowTrace(new Tpl(this), () -> {
                tplDepth--;
                parents.remove(parents.size() - 1);
                openFors.remove(openFors.size() - 1);
                records.add(KayaWire.txTemplateEnd());
                openTraces--;
                if (parent != 0) {
                    records.add(KayaWire.txAddChild(parent, w.id));
                }
            });
        }

        /** A When over a Bool signal: stamps on true, unstamps on false. */
        public Widget when(Signal<Boolean> s, Consumer<Tpl> body) {
            return when(s, t -> {
                body.accept(t);
                return null;
            }).handle;
        }

        public <R> Stamped<Widget, R> when(Signal s, java.util.function.Function<Tpl, R> body) {
            Widget w = new Widget(++widgets, this);
            long parent = currentParent();
            records.add(KayaWire.txCreateWhen(w.id, s.id));
            parents.add(0L);
            tplDepth++;
            R out;
            try {
                out = body.apply(new Tpl(this));
            } finally {
                tplDepth--;
            }
            parents.remove(parents.size() - 1);
            records.add(KayaWire.txTemplateEnd());
            if (parent != 0) {
                records.add(KayaWire.txAddChild(parent, w.id));
            }
            return new Stamped<>(w, out);
        }

        public void insert(Collection c, Object key, Object value) {
            modelSet(c.id, c.path, key, value);
            records.add(KayaWire.txCollectionInsert(c.id, c.path.toArray(), key, 0, new Object[] { value }));
            recomputeDerived(c);
        }

        public void update(Collection c, Object key, Object value) {
            modelSet(c.id, c.path, key, value);
            records.add(KayaWire.txCollectionUpdate(c.id, c.path.toArray(), key, 0, new Object[] { value }));
            recomputeDerived(c);
        }

        // The raw record paths KayaRecords builds on: the model keeps
        // the record object itself; only the wire fields travel.
        Collection collectionWithSchema(int[] schema) {
            return collectionWithVariants(new int[][] { schema });
        }

        Collection collectionWithVariants(int[][] variants) {
            Collection c = new Collection(++collections, java.util.Collections.emptyList());
            registerCollection(c.id);
            records.add(KayaWire.txCreateCollection(c.id, variants));
            return c;
        }

        void emitVariantCase(int variant) {
            records.add(KayaWire.txVariantCase(variant));
        }

        void insertRecordRaw(Collection c, Object key, Object model, int variant, Object[] fields) {
            modelSet(c.id, c.path, key, model);
            records.add(KayaWire.txCollectionInsert(c.id, c.path.toArray(), key, variant, fields));
            recomputeDerived(c);
        }

        void updateRecordRaw(Collection c, Object key, Object model, int variant, Object[] fields) {
            modelSet(c.id, c.path, key, model);
            records.add(KayaWire.txCollectionUpdate(c.id, c.path.toArray(), key, variant, fields));
            recomputeDerived(c);
        }

        void updateFieldRaw(Collection c, Object key, Object model, int variant, int field, Object value) {
            modelSet(c.id, c.path, key, model);
            records.add(KayaWire.txCollectionUpdateField(c.id, c.path.toArray(), key, field, variant, value));
            recomputeDerived(c);
        }

        /**
         * Repositions an entry before another's: order is collection
         * data, so the model reorders and the wire carries the same
         * keys-only delta. Keys, never indices. A missing key or
         * anchor throws here, at the call site — the same check the
         * scene makes; moving an entry before itself is a no-op, and
         * nothing travels.
         */
        public void moveBefore(Collection c, Object key, Object anchor) {
            moveEntry(c, key, new Object[] { anchor });
        }

        /** Repositions an entry at the end of its collection. */
        public void moveToEnd(Collection c, Object key) {
            moveEntry(c, key, new Object[0]);
        }

        /**
         * Repositions an entry at the front: sugar for moveBefore the
         * current first key, lowering to the same wire op.
         */
        public void moveToFront(Collection c, Object key) {
            List<Object> keys = keysOf(c);
            if (keys.isEmpty()) {
                throw new IllegalStateException("kaya: move of missing key " + key);
            }
            moveEntry(c, key, new Object[] { keys.get(0) });
        }

        /**
         * Repositions an entry directly after another's: sugar for
         * moveBefore the anchor's successor (moveToEnd when the anchor
         * is last), lowering to the same wire op.
         */
        public void moveAfter(Collection c, Object key, Object anchor) {
            List<Object> keys = keysOf(c);
            if (!keys.contains(key)) {
                throw new IllegalStateException("kaya: move of missing key " + key);
            }
            int at = keys.indexOf(anchor);
            if (at < 0) {
                throw new IllegalStateException("kaya: move after missing key " + anchor);
            }
            if (java.util.Objects.equals(key, anchor)) {
                return;
            }
            if (at + 1 == keys.size()) {
                moveEntry(c, key, new Object[0]);
                return;
            }
            if (java.util.Objects.equals(keys.get(at + 1), key)) {
                return; // already directly after the anchor
            }
            moveEntry(c, key, new Object[] { keys.get(at + 1) });
        }

        private void moveEntry(Collection c, Object key, Object[] before) {
            if (before.length > 0 && java.util.Objects.equals(before[0], key)) {
                // Moving before itself: order unchanged and nothing
                // travels — but the key must exist, the check the
                // scene would make.
                if (!keysOf(c).contains(key)) {
                    throw new IllegalStateException("kaya: move of missing key " + key);
                }
                return;
            }
            modelMove(c.id, c.path, key, before);
            records.add(KayaWire.txCollectionMove(c.id, c.path.toArray(), key, before));
            recomputeDerived(c);
        }

        public void remove(Collection c, Object key) {
            modelRemove(c.id, c.path, key);
            records.add(KayaWire.txCollectionRemove(c.id, c.path.toArray(), key));
            recomputeDerived(c);
        }

        // The record-time mirror-read guard: the template records once
        // and replays, so a read inside a template body is one snapshot
        // baked into every stamp — silently dead data. The typed
        // surfaces (KayaRecords, KayaSums) route through items, so this
        // is the single choke point.
        private void guardMirrorRead() {
            if (tplDepth > 0) {
                throw new IllegalStateException(
                        "kaya: model read inside a template body — the template records once"
                                + " and replays; bind a signal, use the element's field, or"
                                + " derive() for computed values");
            }
        }

        /**
         * The model: what this guest wrote, exactly — the fold of every
         * patch so far (this transaction's included), in insertion
         * order.
         */
        public List<Entry> items(Collection c) {
            guardMirrorRead();
            Instance instance = instanceOf(c.id, c.path);
            return instance == null
                    ? java.util.Collections.emptyList()
                    : new ArrayList<>(instance.entries);
        }

        public int count(Collection c) {
            guardMirrorRead();
            Instance instance = instanceOf(c.id, c.path);
            return instance == null ? 0 : instance.entries.size();
        }

        /**
         * Mount into the default window; per-window targets arrive with
         * the window vocabulary.
         */
        public void mount(Widget root) {
            records.add(KayaWire.txMount(0, root.id));
        }

        /**
         * Create an auxiliary window (capability-gated: phone hosts
         * reject at the root); materializes hidden, mountIn presents.
         * Chains are the Java spelling:
         * tx.createWindow(1).title("inspector").size(480, 320).vetoClose(true).
         */
        /**
         * Request a modal alert (the request/result grammar), the
         * chain spelling:
         * tx.showAlert().title("delete item?").message("…")
         *     .action("Delete").action("Archive").cancel("Keep")
         *     .onResult((tx, choice) -> …).show().
         * The result handler rides the REQUEST (the widget-handler
         * precedent) and retires with its one answer — choice is an
         * action index (0 or 1) or KayaWire.ALERT_CHOICE_CANCEL (-1
         * in java-int terms), every platform-native dismissal. Ids
         * are binding-allocated; show() returns the id. Up to two
         * actions (the platform floor); the cancel label is required.
         * One alert may be live per process; show the next from the
         * handler.
         */
        public AlertRef showAlert() {
            return new AlertRef(this, KayaApp.this, ++nextAlert);
        }

        public WindowRef createWindow(long id) {
            records.add(KayaWire.txCreateWindow(id));
            return new WindowRef(this, KayaApp.this, id);
        }

        /** The prop chain for an existing window (0 = the primary). */
        public WindowRef window(long id) {
            return new WindowRef(this, KayaApp.this, id);
        }

        /**
         * Close and forget an auxiliary window — also the veto
         * grammar's confirmation and the reconciliation after a
         * chrome close.
         */
        public void destroyWindow(long id) {
            records.add(KayaWire.txDestroyWindow(id));
        }

        /** Mount a root into a specific window; mounting presents. */
        public void mountIn(long window, Widget root) {
            records.add(KayaWire.txMount(window, root.id));
        }

        /**
         * Push a navigation entry onto the primary surface's stack
         * (entry ids are guest-allocated in the shared surface
         * namespace, the createWindow discipline); materializes
         * covered, mountIn presents it. Chains are the JVM spelling:
         * tx.pushEntry(7).title("detail").interceptBack(true).
         */
        public EntryRef pushEntry(long id) {
            records.add(KayaWire.txPushEntry(0, id));
            return new EntryRef(this, KayaApp.this, id);
        }

        /** Push onto another window's stack (the System Settings
         * shape: a stack inside a desktop auxiliary). */
        public EntryRef pushEntryIn(long window, long id) {
            records.add(KayaWire.txPushEntry(window, id));
            return new EntryRef(this, KayaApp.this, id);
        }

        /**
         * Pop the primary stack's top entry and forget its tree —
         * also the back-veto grammar's confirmation after
         * onBackRequested. Popping an empty stack is a scene error.
         */
        public void popEntry() {
            records.add(KayaWire.txPopEntry(0));
        }

        public void popEntryIn(long window) {
            records.add(KayaWire.txPopEntry(window));
        }

        /**
         * Set the primary surface's title (the title bar on the
         * desktops, the switcher label on iOS, the task label on
         * Android).
         */
        public void windowTitle(String title) {
            records.add(KayaWire.txSetWindowTitle(0, title));
        }

        /**
         * Request the primary surface's content size in DIP —
         * ADVISORY on every platform: honored where the window
         * manager permits, recorded only where the system owns
         * geometry.
         */
        public void windowSize(double width, double height) {
            records.add(KayaWire.txSetWindowWidth(0, width));
            records.add(KayaWire.txSetWindowHeight(0, height));
        }
    }

    /**
     * A template body: the same declaration vocabulary with
     * template-node ids, plus element bindings.
     */
    public final class Tpl {
        private final Tx tx;

        Tpl(Tx tx) {
            this.tx = tx;
        }

        public Node widget(int kind) {
            Node n = new Node(++nodes);
            tx.records.add(KayaWire.txCreateWidget(n.id, kind));
            tx.autoParent(n.id);
            return n;
        }

        public void setText(Node n, String text) {
            tx.records.add(KayaWire.txSetText(n.id, text));
        }

        /**
         * Bind text to the element of the enclosing For, {@code level}
         * Fors up (0 = nearest).
         */
        public void bindTextElement(Node n, int level) {
            tx.records.add(KayaWire.txBindTextElement(n.id, level, 0));
        }

        /** Bind a label's text to one field of the element; a String
         * field token only — the type pins it at compile time. */
        public void bindTextField(Node n, int level, KayaRecords.Field<String> f) {
            tx.records.add(KayaWire.txBindTextElement(n.id, level, f.index));
        }

        /** Bind a checkbox's state to one field of the element; a
         * Boolean field token only. */
        public void bindCheckedField(Node n, int level, KayaRecords.Field<Boolean> f) {
            tx.records.add(KayaWire.txBindCheckedElement(n.id, level, f.index));
        }

        /** Bind an image's source to one field of the element; a
         * byte[] field token only — the type pins it at compile time. */
        public void bindSourceField(Node n, int level, KayaRecords.Field<byte[]> f) {
            tx.records.add(KayaWire.txBindSourceElement(n.id, level, f.index));
        }

        // The template flavor of the sugar: bindings take field
        // tokens, containers take their body.
        public Node row(Runnable body) {
            return containerOf(KayaWire.KIND_ROW, body);
        }

        public Node column(Runnable body) {
            return containerOf(KayaWire.KIND_COLUMN, body);
        }

        private Node containerOf(int kind, Runnable body) {
            Node parent = widget(kind);
            parents.add(parent.id);
            if (body != null) {
                body.run();
            }
            parents.remove(parents.size() - 1);
            return parent;
        }

        // One name per widget; the argument's type picks the
        // addressable source (constant, signal, or element field).
        public Node label(String text) {
            Node n = widget(KayaWire.KIND_LABEL);
            setText(n, text);
            return n;
        }

        public Node label(Signal<String> s) {
            Node n = widget(KayaWire.KIND_LABEL);
            tx.records.add(KayaWire.txBindText(n.id, s.id));
            return n;
        }

        public Node label(KayaRecords.Field<String> f) {
            Node n = widget(KayaWire.KIND_LABEL);
            bindTextField(n, 0, f);
            return n;
        }

        /** A constant image in the blueprint: the bytes register once,
         * at record time, and every stamp shows them. */
        public Node image(byte[] source) {
            Node n = widget(KayaWire.KIND_IMAGE);
            tx.records.add(KayaWire.txSetSource(n.id, KayaRing.blobRegister(source)));
            return n;
        }

        public Node image(Signal<byte[]> s) {
            Node n = widget(KayaWire.KIND_IMAGE);
            tx.records.add(KayaWire.txBindSource(n.id, s.id));
            return n;
        }

        /** An image bound to one field of the element. */
        public Node image(KayaRecords.Field<byte[]> f) {
            Node n = widget(KayaWire.KIND_IMAGE);
            bindSourceField(n, 0, f);
            return n;
        }

        /** Register a toggle handler on a template node — the bridge
         * the typed record sugar routes through. */
        public void onToggleNode(Node n, ToggleHandler handler) {
            KayaApp.this.onToggle(n, handler);
        }

        /** A checkbox bound to one field; register its handler with
         * app.onToggle. */
        public Node checkbox(KayaRecords.Field<Boolean> f) {
            Node n = widget(KayaWire.KIND_CHECKBOX);
            bindCheckedField(n, 0, f);
            return n;
        }

        public void addChild(Node parent, Node child) {
            tx.records.add(KayaWire.txAddChild(parent.id, child.id));
        }

        public Collection collection() {
            return tx.collection();
        }

        public Node forEach(Collection c, Consumer<Tpl> body) {
            return forEach(c, t -> {
                body.accept(t);
                return null;
            }).handle;
        }

        public <R> Stamped<Node, R> forEach(
                Collection c, java.util.function.Function<Tpl, R> body) {
            c.assertRoot();
            Node n = new Node(++nodes);
            long parent = tx.currentParent();
            tx.records.add(KayaWire.txCreateFor(n.id, c.id));
            openFors.add(c.id);
            parents.add(0L);
            tplDepth++;
            R out;
            try {
                out = body.apply(new Tpl(tx));
            } finally {
                tplDepth--;
            }
            parents.remove(parents.size() - 1);
            openFors.remove(openFors.size() - 1);
            tx.records.add(KayaWire.txTemplateEnd());
            if (parent != 0) {
                tx.records.add(KayaWire.txAddChild(parent, n.id));
            }
            return new Stamped<>(n, out);
        }

        public Node when(Signal<Boolean> s, Consumer<Tpl> body) {
            return when(s, t -> {
                body.accept(t);
                return null;
            }).handle;
        }

        public <R> Stamped<Node, R> when(Signal s, java.util.function.Function<Tpl, R> body) {
            Node n = new Node(++nodes);
            long parent = tx.currentParent();
            tx.records.add(KayaWire.txCreateWhen(n.id, s.id));
            parents.add(0L);
            tplDepth++;
            R out;
            try {
                out = body.apply(new Tpl(tx));
            } finally {
                tplDepth--;
            }
            parents.remove(parents.size() - 1);
            tx.records.add(KayaWire.txTemplateEnd());
            if (parent != 0) {
                tx.records.add(KayaWire.txAddChild(parent, n.id));
            }
            return new Stamped<>(n, out);
        }
    }

    /**
     * Run {@code build} with a fresh transaction and submit it
     * atomically. A handler that throws abandons its records, and the
     * model abandons the same writes before the exception continues.
     */
    public void build(Consumer<Tx> build) {
        build(tx -> {
            build.accept(tx);
            return null;
        });
    }

    /**
     * build whose body returns the handles it declared — the way a
     * scene's signals, collections, and buttons reach the handlers
     * without static fields.
     */
    public <R> R build(java.util.function.Function<Tx, R> build) {
        Tx tx = new Tx();
        ambient = this;
        currentTx = tx;
        R out;
        try {
            out = build.apply(tx);
        } catch (RuntimeException | Error e) {
            tx.rollback();
            throw e;
        } finally {
            // Every exit clears the ambient slot — a stale currentTx
            // would let the operator sugar reach a closed transaction
            // (the divergence the other bindings never had) — and
            // marks the transaction over, so late construction chains
            // (Widget.grow) die loudly on either exit path.
            currentTx = null;
            tx.closed = true;
        }
        tx.submitIfAny();
        return out;
    }

    /** Register a click handler for a live widget. */
    public void onClick(Widget w, Consumer<Tx> handler) {
        widgetHandlers.put(w.id, handler);
    }

    /**
     * Register a click handler for a template node; it also receives
     * the stamped copy's keys, outermost first.
     */
    public void onClick(Node n, BiConsumer<Tx, List<Object>> handler) {
        nodeHandlers.put(n.id, handler);
    }

    /**
     * Register a change handler for a live entry: the widget owns its
     * text and reports each edit here; the app folds the text into its
     * own state — there is no read-back, by doctrine.
     */
    public void onChange(Widget w, BiConsumer<Tx, String> handler) {
        widgetChanges.put(w.id, handler);
    }

    /**
     * Register a change handler for a template entry; it also receives
     * the stamped copy's keys, outermost first.
     */
    public void onChange(Node n, ChangeHandler handler) {
        nodeChanges.put(n.id, handler);
    }

    /**
     * Register a toggle handler for a live checkbox: the box owns its
     * checked bit and reports each flip here; the app folds it into its
     * own state.
     */
    public void onToggle(Widget w, BiConsumer<Tx, Boolean> handler) {
        widgetToggles.put(w.id, handler);
    }

    /** Register a change handler for a live slider: the bar owns its
     * position and reports each move with the new value — the entry's
     * uncontrolled contract, with a double. */
    public void onValueChanged(Widget w, BiConsumer<Tx, Double> handler) {
        widgetValues.put(w.id, handler);
    }

    /**
     * Register a toggle handler for a template checkbox; it also
     * receives the stamped copy's keys, outermost first.
     */
    public void onToggle(Node n, ToggleHandler handler) {
        nodeToggles.put(n.id, handler);
    }

    // The ring consumer: Unsafe absolute loads plus explicit fences,
    // bound once as MethodHandles and invoked through invokeExact so the
    // per-record path stays free of boxing and reflection. Raw addresses
    // rather than direct ByteBuffers because of the ART VarHandle
    // truncation; see KayaRing.
    private static final MethodHandle GET_INT;
    private static final MethodHandle GET_BYTE;
    private static final MethodHandle PUT_INT;
    private static final MethodHandle LOAD_FENCE;
    private static final MethodHandle STORE_FENCE;

    static {
        try {
            Class<?> unsafeClass = Class.forName("sun.misc.Unsafe");
            Field theUnsafe = unsafeClass.getDeclaredField("theUnsafe");
            theUnsafe.setAccessible(true);
            Object unsafe = theUnsafe.get(null);
            MethodHandles.Lookup lookup = MethodHandles.lookup();
            GET_INT = lookup.unreflect(unsafeClass.getMethod("getInt", long.class)).bindTo(unsafe);
            GET_BYTE =
                    lookup.unreflect(unsafeClass.getMethod("getByte", long.class)).bindTo(unsafe);
            PUT_INT = lookup
                    .unreflect(unsafeClass.getMethod("putInt", long.class, int.class))
                    .bindTo(unsafe);
            LOAD_FENCE = lookup.unreflect(unsafeClass.getMethod("loadFence")).bindTo(unsafe);
            STORE_FENCE = lookup.unreflect(unsafeClass.getMethod("storeFence")).bindTo(unsafe);
        } catch (ReflectiveOperationException e) {
            throw new ExceptionInInitializerError(e);
        }
    }

    /**
     * Consume the ring and dispatch until shutdown. Call on the app
     * thread after the scene is built and handlers are registered (on
     * Android, after KayaRing.attach set the core up).
     */
    public void dispatchLoop() {
        // The stale-artifact guard: this binding was generated from one
        // spec revision; the loaded library must speak the same one.
        if (KayaRing.specHash() != KayaWire.SPEC_HASH) {
            throw new IllegalStateException(String.format(
                    "kaya: library speaks spec %#x, this binding was generated from %#x"
                            + " — rebuild the library or regenerate bindings",
                    KayaRing.specHash(), KayaWire.SPEC_HASH));
        }
        try {
            loop();
        } catch (Throwable t) {
            // invokeExact declares Throwable; nothing here throws in practice.
            throw new RuntimeException(t);
        }
    }

    /**
     * One handler dispatch: an exception crosses the build boundary
     * (which rolled the model back and dropped the records), is
     * logged, and the loop moves to the next occurrence — the uniform
     * dispatch discipline across every binding. VM-fatal errors still
     * die.
     */


    private void dispatch(Consumer<Tx> handler) {
        try {
            build(handler);
        } catch (RuntimeException e) {
            System.err.println("kaya: handler threw (transaction rolled back): " + e);
        }
    }

    private void loop() throws Throwable {
        long data = KayaRing.dataAddress();
        long headAddr = KayaRing.headAddress();
        long tailAddr = KayaRing.tailAddress();
        int mask = KayaRing.capacity() - 1;

        int h = (int) GET_INT.invokeExact(headAddr);
        while (true) {
            int t = (int) GET_INT.invokeExact(tailAddr);
            LOAD_FENCE.invokeExact(); // acquire: record reads stay below the tail load
            if (h == t) {
                if (!KayaRing.waitOccurrences()) {
                    return; // shutdown
                }
                continue;
            }
            long at = data + (h & mask);
            int size = (int) GET_INT.invokeExact(at);
            byte[] rec = new byte[size];
            for (int i = 0; i < size; i++) {
                rec[i] = (byte) GET_BYTE.invokeExact(at + i);
            }
            h += size;
            STORE_FENCE.invokeExact(); // release: reads complete before the hand-back
            PUT_INT.invokeExact(headAddr, h);

            KayaWire.Occ occ = KayaWire.parseOccurrence(rec);
            if (occ == null) {
                continue;
            }
            if (occ.kind == KayaWire.OCC_KIND_BUTTON_CLICKED && occ.keys.isEmpty()) {
                Consumer<Tx> handler = widgetHandlers.get(occ.id);
                if (handler != null) {
                    dispatch(handler);
                }
            } else if (occ.kind == KayaWire.OCC_KIND_BUTTON_CLICKED) {
                BiConsumer<Tx, List<Object>> handler = nodeHandlers.get(occ.id);
                if (handler != null) {
                    dispatch(tx -> {
                        handler.accept(tx, occ.keys);
                    });
                }
            } else if (occ.kind == KayaWire.OCC_KIND_TEXT_CHANGED && occ.keys.isEmpty()) {
                BiConsumer<Tx, String> handler = widgetChanges.get(occ.id);
                if (handler != null) {
                    dispatch(tx -> {
                        handler.accept(tx, (String) occ.payload);
                    });
                }
            } else if (occ.kind == KayaWire.OCC_KIND_TEXT_CHANGED) {
                ChangeHandler handler = nodeChanges.get(occ.id);
                if (handler != null) {
                    dispatch(tx -> {
                        handler.accept(tx, occ.keys, (String) occ.payload);
                    });
                }
            } else if (occ.kind == KayaWire.OCC_KIND_TOGGLED && occ.keys.isEmpty()) {
                BiConsumer<Tx, Boolean> handler = widgetToggles.get(occ.id);
                if (handler != null) {
                    dispatch(tx -> {
                        handler.accept(tx, (Boolean) occ.payload);
                    });
                }
            } else if (occ.kind == KayaWire.OCC_KIND_TOGGLED) {
                ToggleHandler handler = nodeToggles.get(occ.id);
                if (handler != null) {
                    dispatch(tx -> {
                        handler.accept(tx, occ.keys, (Boolean) occ.payload);
                    });
                }
            } else if (occ.kind == KayaWire.OCC_KIND_VALUE_CHANGED && occ.keys.isEmpty()) {
                BiConsumer<Tx, Double> handler = widgetValues.get(occ.id);
                if (handler != null) {
                    dispatch(tx -> {
                        handler.accept(tx, (Double) occ.payload);
                    });
                }
            } else if (occ.kind == KayaWire.OCC_KIND_CLOSE_REQUESTED) {
                Consumer<Tx> handler = closeRequested.get(occ.id);
                if (handler != null) {
                    dispatch(handler);
                }
            } else if (occ.kind == KayaWire.OCC_KIND_WINDOW_CLOSED) {
                // One-shot: the window is gone; both registrations
                // retire with it.
                closeRequested.remove(occ.id);
                Consumer<Tx> handler = windowClosed.remove(occ.id);
                if (handler != null) {
                    dispatch(handler);
                }
            } else if (occ.kind == KayaWire.OCC_KIND_ENTRY_POPPED) {
                // One-shot: the entry is gone; both registrations
                // retire with it.
                backRequested.remove(occ.id);
                Consumer<Tx> handler = entryPopped.remove(occ.id);
                if (handler != null) {
                    dispatch(handler);
                }
            } else if (occ.kind == KayaWire.OCC_KIND_BACK_REQUESTED) {
                Consumer<Tx> handler = backRequested.get(occ.id);
                if (handler != null) {
                    dispatch(handler);
                }
            } else if (occ.kind == KayaWire.OCC_KIND_ALERT_RESULT) {
                // One-shot: the registration retires with the result;
                // payload is the parsed choice (Integer).
                BiConsumer<Tx, Integer> handler = alerts.remove(occ.id);
                if (handler != null) {
                    dispatch(tx -> handler.accept(tx, (Integer) occ.payload));
                }
            }
        }
    }
}
