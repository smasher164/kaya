package dev.kaya;

import java.lang.reflect.Constructor;
import java.lang.reflect.Method;
import java.lang.reflect.Parameter;
import java.lang.reflect.RecordComponent;
import java.util.ArrayList;
import java.util.List;

/**
 * Records: the record type is the schema. {@link #collectionOf}
 * reflects over T's record components once at declaration — components
 * of wire types (String, boolean, long, double) in declaration order
 * become the schema; anything else is guest-only, living in the model
 * and never reaching the wire. One declaration drives the schema, the
 * conversions, and the field tokens, so none can drift. Java records
 * are immutable, so a field update reconstructs the model's copy
 * through the canonical constructor.
 */
public final class KayaRecords {
    /**
     * A typed projection: one field of a record type, by wire
     * position. The type parameter pins the Java type, so
     * bindCheckedField rejects a {@code Field<String>} at compile
     * time.
     */
    public static final class Field<V> {
        final int index;

        Field(int index) {
            this.index = index;
        }
    }

    static final class Info {
        final int[] schema;
        final int[] wireToComponent;
        final Method[] accessors; // component order, all of them
        final Constructor<?> ctor;

        Info(int[] schema, int[] wireToComponent, Method[] accessors, Constructor<?> ctor) {
            this.schema = schema;
            this.wireToComponent = wireToComponent;
            this.accessors = accessors;
            this.ctor = ctor;
        }

        static Integer wireTag(Class<?> t) {
            if (t == String.class) return KayaWire.VALUE_STR;
            if (t == boolean.class || t == Boolean.class) return KayaWire.VALUE_BOOL;
            if (t == long.class || t == Long.class) return KayaWire.VALUE_I64;
            if (t == double.class || t == Double.class) return KayaWire.VALUE_F64;
            if (t == byte[].class) return KayaWire.VALUE_BLOB;
            return null;
        }

        // One reflection walk per record type, ever — selectors
        // resolve per event in handlers, so the walk must not re-run
        // there.
        static final java.util.concurrent.ConcurrentHashMap<Class<?>, Info> CACHE =
                new java.util.concurrent.ConcurrentHashMap<>();

        static Info of(Class<?> type) {
            return CACHE.computeIfAbsent(type, Info::build);
        }

        /** Component (name, type) pairs in declaration order, plus the
         * canonical constructor. Real record metadata when the runtime
         * has it; on Android, D8 desugars records — ART never sees
         * record components — so the fallback reads the one declared
         * constructor instead: parameter names (kept by -parameters)
         * name the components, and each accessor is the zero-argument
         * method with the component's name. Both roads describe the
         * same canonical shape. */
        static Info build(Class<?> type) {
            String[] names;
            Class<?>[] types;
            Constructor<?> ctor;
            if (type.isRecord() && type.getRecordComponents() != null) {
                RecordComponent[] components = type.getRecordComponents();
                names = new String[components.length];
                types = new Class<?>[components.length];
                for (int i = 0; i < components.length; i++) {
                    names[i] = components[i].getName();
                    types[i] = components[i].getType();
                }
                try {
                    ctor = type.getDeclaredConstructor(types);
                } catch (NoSuchMethodException e) {
                    throw new IllegalArgumentException(
                            "kaya: " + type.getName() + " has no canonical constructor", e);
                }
            } else {
                Constructor<?>[] ctors = type.getDeclaredConstructors();
                if (ctors.length != 1) {
                    throw new IllegalArgumentException("kaya: " + type.getName()
                            + " is not a record and has no single constructor to read");
                }
                ctor = ctors[0];
                Parameter[] parameters = ctor.getParameters();
                names = new String[parameters.length];
                types = new Class<?>[parameters.length];
                for (int i = 0; i < parameters.length; i++) {
                    if (!parameters[i].isNamePresent()) {
                        throw new IllegalArgumentException("kaya: " + type.getName()
                                + " constructor parameter names are missing — compile with"
                                + " -parameters");
                    }
                    names[i] = parameters[i].getName();
                    types[i] = parameters[i].getType();
                }
            }
            ctor.setAccessible(true);
            Method[] accessors = new Method[names.length];
            List<Integer> schema = new ArrayList<>();
            List<Integer> wireToComponent = new ArrayList<>();
            for (int i = 0; i < names.length; i++) {
                try {
                    accessors[i] = type.getDeclaredMethod(names[i]);
                    accessors[i].setAccessible(true);
                } catch (NoSuchMethodException e) {
                    throw new IllegalArgumentException("kaya: " + type.getName() + "."
                            + names[i] + " has no accessor", e);
                }
                Integer tag = wireTag(types[i]);
                if (tag != null) {
                    schema.add(tag);
                    wireToComponent.add(i);
                }
            }
            if (schema.isEmpty()) {
                throw new IllegalArgumentException(
                        "kaya: " + type.getName() + " has no wire-typed fields");
            }
            return new Info(
                    schema.stream().mapToInt(Integer::intValue).toArray(),
                    wireToComponent.stream().mapToInt(Integer::intValue).toArray(),
                    accessors, ctor);
        }

        Object[] wireFields(Object record) {
            Object[] fields = new Object[wireToComponent.length];
            try {
                for (int i = 0; i < wireToComponent.length; i++) {
                    fields[i] = encodeField(i, accessors[wireToComponent[i]].invoke(record));
                }
            } catch (ReflectiveOperationException e) {
                throw new IllegalStateException("kaya: record accessor failed", e);
            }
            return fields;
        }

        /**
         * One field's wire value. Blob fields (byte[] components)
         * register their bytes with the core here, at encode time —
         * handles are single-submit, so insert, update, and
         * update_field all re-register (one copy into core memory per
         * write; the model keeps the guest's own byte[]). The guards
         * turn the otherwise-obscure failure — a mistyped value
         * encoding under the wrong tag and dying in the core — into an
         * error at the call site.
         */
        Object encodeField(int wireIndex, Object value) {
            if (schema[wireIndex] == KayaWire.VALUE_BLOB) {
                if (!(value instanceof byte[])) {
                    throw new IllegalArgumentException("kaya: "
                            + ctor.getDeclaringClass().getName() + " wire field " + wireIndex
                            + " is a blob — pass byte[] (encoded image bytes), not "
                            + (value == null ? "null" : value.getClass().getName()));
                }
                return new KayaWire.BlobHandle(KayaRing.blobRegister((byte[]) value));
            }
            if (value instanceof byte[]) {
                throw new IllegalArgumentException("kaya: "
                        + ctor.getDeclaringClass().getName() + " wire field " + wireIndex
                        + " is not a blob — byte[] belongs on a byte[] record component");
            }
            return value;
        }

        Object withField(Object record, int wireIndex, Object value) {
            try {
                Object[] args = new Object[accessors.length];
                for (int i = 0; i < accessors.length; i++) {
                    args[i] = accessors[i].invoke(record);
                }
                args[wireToComponent[wireIndex]] = value;
                return ctor.newInstance(args);
            } catch (ReflectiveOperationException e) {
                throw new IllegalStateException("kaya: record reconstruction failed", e);
            }
        }
    }

    /** One (key, record) pair of the typed model. */
    public static final class Entry<K, T> {
        public final K key;
        public final T value;

        Entry(K key, T value) {
            this.key = key;
            this.value = value;
        }
    }

    /**
     * A collection whose entries are T records keyed by K — String or
     * Long, the protocol's identity types (Java has no union bound to
     * say so; the wire validates). The plain handle rides along for
     * forEach and at.
     */
    public static final class Collection<K, T> {
        public final KayaApp.Collection handle;
        final Info info;

        Collection(KayaApp.Collection handle, Info info) {
            this.handle = handle;
            this.info = info;
        }

        public void insert(KayaApp.Tx tx, K key, T value) {
            tx.insertRecordRaw(handle, key, value, 0, info.wireFields(value));
        }

        public void update(KayaApp.Tx tx, K key, T value) {
            tx.updateRecordRaw(handle, key, value, 0, info.wireFields(value));
        }

        /**
         * One field's delta by selector: the rest of the record never
         * travels. The accessor reference is the field — no token to
         * declare ({@code todos.updateField(tx, key, Todo::done, true)}).
         */
        public <V> void updateField(KayaApp.Tx tx, K key,
                java.util.function.Function<T, V> selector, V value) {
            updateField(tx, key, resolve(selector), value);
        }

        /** updateField over a pre-resolved token. */
        public <V> void updateField(KayaApp.Tx tx, K key, Field<V> f, V value) {
            Object current = null;
            for (KayaApp.Entry entry : tx.items(handle)) {
                if (entry.key.equals(key)) {
                    current = entry.value;
                }
            }
            if (current == null) {
                throw new IllegalStateException("kaya: update of missing key " + key);
            }
            tx.updateFieldRaw(handle, key, info.withField(current, f.index, value), 0,
                    f.index, info.encodeField(f.index, value));
        }

        /**
         * Repositions an entry before another's: order is collection
         * data, so the model reorders and the wire carries the same
         * keys-only delta. Keys, never indices. A missing key or
         * anchor throws at the call site — the same check the scene
         * makes; moving an entry before itself is a no-op.
         */
        public void moveBefore(KayaApp.Tx tx, K key, K anchor) {
            tx.moveBefore(handle, key, anchor);
        }

        /** Repositions an entry at the end of its collection. */
        public void moveToEnd(KayaApp.Tx tx, K key) {
            tx.moveToEnd(handle, key);
        }

        /**
         * Repositions an entry at the front: sugar for moveBefore the
         * current first key, lowering to the same wire op.
         */
        public void moveToFront(KayaApp.Tx tx, K key) {
            tx.moveToFront(handle, key);
        }

        /**
         * Repositions an entry directly after another's: sugar for
         * moveBefore the anchor's successor (moveToEnd when the anchor
         * is last), lowering to the same wire op.
         */
        public void moveAfter(KayaApp.Tx tx, K key, K anchor) {
            tx.moveAfter(handle, key, anchor);
        }

        /** The typed model: what this guest wrote, in insertion order. */
        @SuppressWarnings("unchecked")
        public List<Entry<K, T>> items(KayaApp.Tx tx) {
            List<Entry<K, T>> out = new ArrayList<>();
            for (KayaApp.Entry entry : tx.items(handle)) {
                out.add(new Entry<>((K) entry.key, (T) entry.value));
            }
            return out;
        }

        /** A template checkbox's typed toggle handler: the stamped
         * copy's key (this collection's K), then the new state. */
        public interface ToggleHandler<K> {
            void accept(KayaApp.Tx tx, K key, boolean checked);
        }

        /**
         * A checkbox bound to the field the selector reads, with its
         * toggle handler co-located — the receiver's K types the
         * handler's key (the depth-1 case; deeper nestings keep the
         * List path via app.onToggle on the node).
         */
        @SuppressWarnings("unchecked")
        public KayaApp.Node checkbox(KayaApp.Tpl t,
                java.util.function.Function<T, Boolean> selector, ToggleHandler<K> onToggle) {
            KayaApp.Node n = t.checkbox(resolve(selector));
            if (onToggle != null) {
                t.onToggleNode(n, (tx, keys, checked) ->
                        onToggle.accept(tx, (K) keys.get(0), checked));
            }
            return n;
        }

        /** A label bound to the field the selector reads. */
        public KayaApp.Node label(KayaApp.Tpl t,
                java.util.function.Function<T, String> selector) {
            return t.label(this.<String>resolve(selector));
        }

        /** An image bound to the field the selector reads. */
        public KayaApp.Node image(KayaApp.Tpl t,
                java.util.function.Function<T, byte[]> selector) {
            return t.image(this.<byte[]>resolve(selector));
        }

        /** The token routes, for the generated row surface: exact-index
         * tokens, no probe resolution. */
        @SuppressWarnings("unchecked")
        public KayaApp.Node checkbox(KayaApp.Tpl t, Field<Boolean> f,
                ToggleHandler<K> onToggle) {
            KayaApp.Node n = t.checkbox(f);
            if (onToggle != null) {
                t.onToggleNode(n, (tx, keys, checked) ->
                        onToggle.accept(tx, (K) keys.get(0), checked));
            }
            return n;
        }

        public KayaApp.Node label(KayaApp.Tpl t, Field<String> f) {
            return t.label(f);
        }

        public KayaApp.Node image(KayaApp.Tpl t, Field<byte[]> f) {
            return t.image(f);
        }

        @SuppressWarnings("unchecked")
        private <V> Field<V> resolve(java.util.function.Function<T, V> selector) {
            return fieldOf((Class<T>) info.ctor.getDeclaringClass(), selector);
        }

        /**
         * A signal the binding recomputes from this collection's
         * entries after every mutation, written into the same
         * transaction — the items-left label with no handler
         * remembering to update it. The function is pure presentation:
         * entries in, one value out; the core sees an ordinary signal.
         */
        public <V> KayaApp.Signal<V> derive(KayaApp.Tx tx,
                java.util.function.Function<List<Entry<K, T>>, V> compute) {
            KayaApp.Signal<V> s = tx.signal(compute.apply(items(tx)));
            tx.registerDerived(handle.id, t -> t.write(s, compute.apply(items(t))));
            return s;
        }

        /**
         * Typed field writes with the key spelled once:
         * {@code todos.patch(tx, key).set(Todo::done, true)}. Each set
         * records one update_field — a patch is recorded writes, never
         * a diff.
         */
        public Patch<K, T> patch(KayaApp.Tx tx, K key) {
            return new Patch<>(this, tx, key);
        }
    }

    /** An open patch on one entry; set chains. */
    public static final class Patch<K, T> {
        final Collection<K, T> c;
        final KayaApp.Tx tx;
        final K key;

        Patch(Collection<K, T> c, KayaApp.Tx tx, K key) {
            this.c = c;
            this.tx = tx;
            this.key = key;
        }

        /** Writes the field the selector reads; chainable. */
        public <V> Patch<K, T> set(java.util.function.Function<T, V> selector, V value) {
            c.updateField(tx, key, selector, value);
            return this;
        }

        /** Writes the field a pre-resolved token names; chainable. */
        public <V> Patch<K, T> set(Field<V> f, V value) {
            c.updateField(tx, key, f, value);
            return this;
        }
    }

    /**
     * The generic machinery behind the generated {@code rows()}
     * Iterables: a one-element iterator that opens the For template on
     * the first next(), closes it — parenting the For into the
     * enclosing container scope — when the loop asks again, and makes
     * the row from the template handle. A break leaves the trace open;
     * the transaction refuses to submit.
     */
    public static <K, T, R> Iterable<R> rowTrace(
            Collection<K, T> c, java.util.function.Function<KayaApp.Tpl, R> makeRow) {
        return () -> new java.util.Iterator<R>() {
            int state;
            KayaApp.RowTrace trace;

            @Override
            public boolean hasNext() {
                if (state == 0) {
                    return true;
                }
                if (state == 1) {
                    state = 2;
                    trace.close();
                }
                return false;
            }

            @Override
            public R next() {
                if (state != 0) {
                    throw new java.util.NoSuchElementException();
                }
                state = 1;
                KayaApp app = KayaApp.ambient;
                if (app == null || app.currentTx == null) {
                    throw new IllegalStateException(
                            "kaya: rows() iterates at record time, inside a transaction");
                }
                trace = app.currentTx.beginRowTrace(c.handle);
                return makeRow.apply(trace.tpl);
            }
        };
    }

    /**
     * Declare a collection of T records; the record type is the
     * schema. Returns the typed root handle.
     */
    public static <K, T> Collection<K, T> collectionOf(KayaApp.Tx tx, Class<T> type) {
        Info info = Info.of(type);
        return new Collection<>(tx.collectionWithSchema(info.schema), info);
    }

    /**
     * The field token at a known wire index, for generated code only
     * (the kaya annotation processor computes indices from the record
     * declaration; hand-written code should use the checked
     * {@link #fieldOf} instead — a hand-minted index is unchecked).
     */
    public static <V> Field<V> fieldAt(int index) {
        return new Field<>(index);
    }

    /**
     * The field token for the component a selector reads:
     * {@code fieldOf(Todo.class, Todo::done)}. The name and type are
     * the record's own, compiler-checked and rename-safe — no strings
     * restating the declaration. Resolution probes: it builds a
     * default-valued prototype, then one variant per wire field with a
     * sentinel in that field, and the probe whose selector result
     * changes names the field. (SerializedLambda would read the method
     * name directly, but D8-desugared lambdas carry no writeReplace on
     * Android, where this code actually runs.)
     */
    @SuppressWarnings("unchecked")
    public static <T, V> Field<V> fieldOf(Class<T> type, java.util.function.Function<T, V> selector) {
        // Non-capturing selectors (Todo::done at a call site) are
        // per-site singletons under invokedynamic, so identity hits.
        Field<V> cached = (Field<V>) SELECTORS.get(selector);
        if (cached != null) {
            return cached;
        }
        Info info = Info.of(type);
        T prototype = instantiate(type, info, -1);
        V base = selector.apply(prototype);
        for (int wire = 0; wire < info.wireToComponent.length; wire++) {
            T probe = instantiate(type, info, wire);
            if (!java.util.Objects.equals(selector.apply(probe), base)) {
                Field<V> f = new Field<>(wire);
                // A capturing selector is a fresh object per event and
                // would grow the map without bound; resetting keeps
                // the cache a cache.
                if (SELECTORS.size() > 1024) {
                    SELECTORS.clear();
                }
                SELECTORS.put(selector, f);
                return f;
            }
        }
        throw new IllegalArgumentException(
                "kaya: selector does not read a wire field of " + type.getName());
    }

    /** Selector instance -> resolved token, by identity (a selector's
     * probe run is the expensive path; handlers resolve per event). */
    private static final java.util.Map<Object, Field<?>> SELECTORS =
            java.util.Collections.synchronizedMap(new java.util.IdentityHashMap<>());

    @SuppressWarnings("unchecked")
    private static <T> T instantiate(Class<T> type, Info info, int sentinelWire) {
        Parameter[] parameters = info.ctor.getParameters();
        Object[] args = new Object[parameters.length];
        for (int i = 0; i < parameters.length; i++) {
            args[i] = defaultValue(parameters[i].getType());
        }
        if (sentinelWire >= 0) {
            int at = info.wireToComponent[sentinelWire];
            args[at] = sentinelValue(parameters[at].getType());
        }
        try {
            return (T) info.ctor.newInstance(args);
        } catch (ReflectiveOperationException e) {
            throw new IllegalStateException("kaya: cannot instantiate " + type.getName(), e);
        }
    }

    // Identity-stable singletons: probe resolution compares selector
    // results with Objects.equals, which is identity for arrays — a
    // fresh array per probe would read as a change in every field.
    private static final byte[] DEFAULT_BLOB = new byte[0];
    private static final byte[] SENTINEL_BLOB = {0x5e};

    private static Object defaultValue(Class<?> t) {
        if (t == String.class) return "";
        if (t == boolean.class || t == Boolean.class) return false;
        if (t == long.class || t == Long.class) return 0L;
        if (t == double.class || t == Double.class) return 0.0;
        if (t == byte[].class) return DEFAULT_BLOB;
        if (t == int.class) return 0;
        return null; // guest-only reference fields
    }

    private static Object sentinelValue(Class<?> t) {
        if (t == String.class) return "\u0000kaya";
        if (t == boolean.class || t == Boolean.class) return true;
        if (t == long.class || t == Long.class) return 0x5eedL;
        if (t == double.class || t == Double.class) return 1.0;
        if (t == byte[].class) return SENTINEL_BLOB;
        throw new IllegalStateException("kaya: no sentinel for " + t.getName());
    }

    private KayaRecords() {}
}
