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

    public static final class Collection {
        final long id;

        Collection(long id) {
            this.id = id;
        }
    }

    /**
     * One transaction: everything queued inside build (or a handler)
     * applies atomically when it returns.
     */
    public final class Tx {
        private final List<byte[]> records = new ArrayList<>();

        void submitIfAny() {
            if (!records.isEmpty()) {
                KayaRing.submit(KayaWire.tx(records.toArray(new byte[0][])));
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
            Collection c = new Collection(++collections);
            records.add(KayaWire.txCreateCollection(c.id));
            return c;
        }

        /**
         * A For over {@code c}: the body declares the template; the For
         * itself (a live container) is returned.
         */
        public Widget forEach(Collection c, Consumer<Tpl> body) {
            Widget w = new Widget(++widgets);
            records.add(KayaWire.txCreateFor(w.id, c.id));
            body.accept(new Tpl(this));
            records.add(KayaWire.txTemplateEnd());
            return w;
        }

        /** A When over a Bool signal: stamps on true, unstamps on false. */
        public Widget when(Signal s, Consumer<Tpl> body) {
            Widget w = new Widget(++widgets);
            records.add(KayaWire.txCreateWhen(w.id, s.id));
            body.accept(new Tpl(this));
            records.add(KayaWire.txTemplateEnd());
            return w;
        }

        public void insert(Collection c, Object[] path, Object key, Object value) {
            records.add(KayaWire.txCollectionInsert(c.id, path, key, value));
        }

        public void update(Collection c, Object[] path, Object key, Object value) {
            records.add(KayaWire.txCollectionUpdate(c.id, path, key, value));
        }

        public void remove(Collection c, Object[] path, Object key) {
            records.add(KayaWire.txCollectionRemove(c.id, path, key));
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
            Node n = new Node(++nodes);
            tx.records.add(KayaWire.txCreateFor(n.id, c.id));
            body.accept(new Tpl(tx));
            tx.records.add(KayaWire.txTemplateEnd());
            return n;
        }

        public Node when(Signal s, Consumer<Tpl> body) {
            Node n = new Node(++nodes);
            tx.records.add(KayaWire.txCreateWhen(n.id, s.id));
            body.accept(new Tpl(tx));
            tx.records.add(KayaWire.txTemplateEnd());
            return n;
        }
    }

    /** Run {@code build} with a fresh transaction and submit it atomically. */
    public void build(Consumer<Tx> build) {
        Tx tx = new Tx();
        build.accept(tx);
        tx.submitIfAny();
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

            KayaWire.Click click = KayaWire.parseClick(rec);
            if (click == null) {
                continue;
            }
            if (click.keys.isEmpty()) {
                Consumer<Tx> handler = widgetHandlers.get(click.id);
                if (handler != null) {
                    build(handler);
                }
            } else {
                BiConsumer<Tx, List<Object>> handler = nodeHandlers.get(click.id);
                if (handler != null) {
                    build(tx -> handler.accept(tx, click.keys));
                }
            }
        }
    }
}
