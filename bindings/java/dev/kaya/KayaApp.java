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
    private long signals, widgets, collections, nodes;
    private final Map<Long, Consumer<Tx>> widgetHandlers = new HashMap<>();
    private final Map<Long, BiConsumer<Tx, List<Object>>> nodeHandlers = new HashMap<>();
    private final Map<Long, BiConsumer<Tx, String>> widgetChanges = new HashMap<>();
    private final Map<Long, ChangeHandler> nodeChanges = new HashMap<>();

    /** A template entry's change handler: the stamped copy's keys, then
     * the entry's new text. */
    public interface ChangeHandler {
        void accept(Tx tx, List<Object> keys, String text);
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

    public static final class Signal {
        final long id;

        Signal(long id) {
            this.id = id;
        }
    }

    /** A live widget: exactly one thing on screen. */
    public static final class Widget {
        final long id;

        Widget(long id) {
            this.id = id;
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
        private final List<byte[]> records = new ArrayList<>();

        // How to undo this transaction's model edits: a snapshot per
        // touched collection, taken on first touch.
        private final Map<Long, List<Instance>> journal = new HashMap<>();

        void submitIfAny() {
            if (!records.isEmpty()) {
                KayaRing.submit(KayaWire.tx(records.toArray(new byte[0][])));
            }
        }

        void rollback() {
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

        public Signal signal(Object initial) {
            Signal s = new Signal(++signals);
            records.add(KayaWire.txCreateSignal(s.id, initial));
            return s;
        }

        public void write(Signal s, Object value) {
            records.add(KayaWire.txWriteSignal(s.id, value));
        }

        public Widget widget(int kind) {
            Widget w = new Widget(++widgets);
            records.add(KayaWire.txCreateWidget(w.id, kind));
            return w;
        }

        public void setText(Widget w, String text) {
            records.add(KayaWire.txSetText(w.id, text));
        }

        public void bindText(Widget w, Signal s) {
            records.add(KayaWire.txBindText(w.id, s.id));
        }

        public void addChild(Widget parent, Widget child) {
            records.add(KayaWire.txAddChild(parent.id, child.id));
        }

        public Collection collection() {
            Collection c = new Collection(++collections, java.util.Collections.emptyList());
            registerCollection(c.id);
            records.add(KayaWire.txCreateCollection(c.id));
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
            Widget w = new Widget(++widgets);
            records.add(KayaWire.txCreateFor(w.id, c.id));
            openFors.add(c.id);
            R out = body.apply(new Tpl(this));
            openFors.remove(openFors.size() - 1);
            records.add(KayaWire.txTemplateEnd());
            return new Stamped<>(w, out);
        }

        /** A When over a Bool signal: stamps on true, unstamps on false. */
        public Widget when(Signal s, Consumer<Tpl> body) {
            return when(s, t -> {
                body.accept(t);
                return null;
            }).handle;
        }

        public <R> Stamped<Widget, R> when(Signal s, java.util.function.Function<Tpl, R> body) {
            Widget w = new Widget(++widgets);
            records.add(KayaWire.txCreateWhen(w.id, s.id));
            R out = body.apply(new Tpl(this));
            records.add(KayaWire.txTemplateEnd());
            return new Stamped<>(w, out);
        }

        public void insert(Collection c, Object key, Object value) {
            modelSet(c.id, c.path, key, value);
            records.add(KayaWire.txCollectionInsert(c.id, c.path.toArray(), key, value));
        }

        public void update(Collection c, Object key, Object value) {
            modelSet(c.id, c.path, key, value);
            records.add(KayaWire.txCollectionUpdate(c.id, c.path.toArray(), key, value));
        }

        public void remove(Collection c, Object key) {
            modelRemove(c.id, c.path, key);
            records.add(KayaWire.txCollectionRemove(c.id, c.path.toArray(), key));
        }

        /**
         * The model: what this guest wrote, exactly — the fold of every
         * patch so far (this transaction's included), in insertion
         * order.
         */
        public List<Entry> items(Collection c) {
            Instance instance = instanceOf(c.id, c.path);
            return instance == null
                    ? java.util.Collections.emptyList()
                    : new ArrayList<>(instance.entries);
        }

        public int count(Collection c) {
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
            tx.records.add(KayaWire.txBindTextElement(n.id, level));
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
            tx.records.add(KayaWire.txCreateFor(n.id, c.id));
            openFors.add(c.id);
            R out = body.apply(new Tpl(tx));
            openFors.remove(openFors.size() - 1);
            tx.records.add(KayaWire.txTemplateEnd());
            return new Stamped<>(n, out);
        }

        public Node when(Signal s, Consumer<Tpl> body) {
            return when(s, t -> {
                body.accept(t);
                return null;
            }).handle;
        }

        public <R> Stamped<Node, R> when(Signal s, java.util.function.Function<Tpl, R> body) {
            Node n = new Node(++nodes);
            tx.records.add(KayaWire.txCreateWhen(n.id, s.id));
            R out = body.apply(new Tpl(tx));
            tx.records.add(KayaWire.txTemplateEnd());
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
        R out;
        try {
            out = build.apply(tx);
        } catch (RuntimeException | Error e) {
            tx.rollback();
            throw e;
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
        try {
            loop();
        } catch (Throwable t) {
            // invokeExact declares Throwable; nothing here throws in practice.
            throw new RuntimeException(t);
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
                    build(handler);
                }
            } else if (occ.kind == KayaWire.OCC_KIND_BUTTON_CLICKED) {
                BiConsumer<Tx, List<Object>> handler = nodeHandlers.get(occ.id);
                if (handler != null) {
                    build(tx -> {
                        handler.accept(tx, occ.keys);
                    });
                }
            } else if (occ.kind == KayaWire.OCC_KIND_TEXT_CHANGED && occ.keys.isEmpty()) {
                BiConsumer<Tx, String> handler = widgetChanges.get(occ.id);
                if (handler != null) {
                    build(tx -> {
                        handler.accept(tx, occ.text);
                    });
                }
            } else if (occ.kind == KayaWire.OCC_KIND_TEXT_CHANGED) {
                ChangeHandler handler = nodeChanges.get(occ.id);
                if (handler != null) {
                    build(tx -> {
                        handler.accept(tx, occ.keys, occ.text);
                    });
                }
            }
        }
    }
}
