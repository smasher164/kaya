package dev.kaya;

import java.lang.reflect.Constructor;
import java.lang.reflect.Method;
import java.lang.reflect.Parameter;
import java.lang.reflect.RecordComponent;
import java.util.ArrayList;
import java.util.List;

/**
 * Records: the record type is the schema. Record components of wire
 * types (String, boolean, long, double, byte[]) in declaration order
 * are the schema; anything else is guest-only and never reaches the
 * wire.
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

        /**
         * The whole element of a scalar collection, as a field token: a
         * scalar collection has no record, so its element is field 0.
         * String only — a scalar collection is always strings.
         */
        public static Field<String> element() {
            return new Field<>(0);
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

        // One reflection walk per record type, ever: selectors resolve
        // per event in handlers, so the walk must not re-run there.
        static final java.util.concurrent.ConcurrentHashMap<Class<?>, Info> CACHE =
                new java.util.concurrent.ConcurrentHashMap<>();

        static Info of(Class<?> type) {
            return CACHE.computeIfAbsent(type, Info::build);
        }

        /** Component (name, type) pairs in declaration order, plus the
         * canonical constructor. The second road — the single
         * constructor's parameter names, kept by {@code -parameters} —
         * is Android's: D8 desugars records, so {@code isRecord()} is
         * false there (docs/traps.md). */
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
         * One field's wire value. A blob field registers its bytes here,
         * at encode time: handles are single-submit, so every mutation
         * carrying a blob field re-registers.
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

        /**
         * Rebuild a record from the wire fields an undo hands back. A
         * guest-only component was never on the wire, so it comes back
         * at its default.
         */
        Object fromWire(List<Object> fields) {
            Parameter[] parameters = ctor.getParameters();
            Object[] args = new Object[parameters.length];
            for (int i = 0; i < parameters.length; i++) {
                args[i] = defaultValue(parameters[i].getType());
            }
            int n = Math.min(wireToComponent.length, fields.size());
            for (int wire = 0; wire < n; wire++) {
                args[wireToComponent[wire]] = fields.get(wire);
            }
            try {
                return ctor.newInstance(args);
            } catch (ReflectiveOperationException e) {
                throw new IllegalStateException("kaya: record reconstruction failed", e);
            }
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
     * say so; the wire validates).
     */
    public static final class Collection<K, T> {
        public final KayaApp.Collection handle;
        final Info info;

        Collection(KayaApp.Collection handle, Info info) {
            this.handle = handle;
            this.info = info;
        }

        /**
         * The instance of this collection inside the copy keyed by
         * {@code key} of the next enclosing For; chain for deeper
         * nesting. TYPED: {@code handle.at} hands back a bare
         * {@link KayaApp.Collection}, and every record mutation below
         * takes this one.
         */
        public Collection<K, T> at(Object key) {
            return new Collection<>(handle.at(key), info);
        }

        public void insert(KayaApp.Tx tx, K key, T value) {
            tx.insertRecordRaw(handle, key, value, 0, info.wireFields(value));
        }

        /** The typed insert under a minted key; see
         * {@link KayaRecords#insertFresh}, which is where the key type
         * gets checked. */
        long insertMinted(KayaApp.Tx tx, T value) {
            long key = tx.mintKeyFor(handle);
            tx.insertRecordRaw(handle, key, value, 0, info.wireFields(value));
            return key;
        }

        public void update(KayaApp.Tx tx, K key, T value) {
            tx.updateRecordRaw(handle, key, value, 0, info.wireFields(value));
        }

        /**
         * One field's delta by selector: the rest of the record never
         * travels ({@code todos.updateField(tx, key, Todo::done, true)}).
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
         * Repositions an entry before another's. Keys, never indices. A
         * missing key or anchor throws at the call site; moving an entry
         * before itself is a no-op.
         */
        public void moveBefore(KayaApp.Tx tx, K key, K anchor) {
            tx.moveBefore(handle, key, anchor);
        }

        /** Repositions an entry at the end of its collection. */
        public void moveToEnd(KayaApp.Tx tx, K key) {
            tx.moveToEnd(handle, key);
        }

        /** Repositions an entry at the front of its collection. */
        public void moveToFront(KayaApp.Tx tx, K key) {
            tx.moveToFront(handle, key);
        }

        /** Repositions an entry directly after another's. */
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
         * A checkbox bound to the field the selector reads. The
         * receiver's K types the handler's key, which is the depth-1
         * case; deeper nestings keep the List path via app.onToggle.
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
         * transaction.
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
         * records one update_field; a patch is recorded writes, never a
         * diff.
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
     * The generic machinery behind the generated {@code rows()}: opens
     * the For in the zone it is handed and wraps each traced row in the
     * generated surface. ONE PER ZONE, because the For's container is
     * the zone's own handle — a live Widget at the top, a template Node
     * inside a row — and a generator that emitted only the first would
     * leave a nested typed For unspellable.
     */
    public static <K, T, R> KayaApp.Rows<KayaApp.Widget, R> rowTrace(
            KayaApp.Tx tx, Collection<K, T> c,
            java.util.function.Function<KayaApp.Tpl, R> makeRow) {
        return tx.rows(c.handle, makeRow);
    }

    public static <K, T, R> KayaApp.Rows<KayaApp.Node, R> rowTrace(
            KayaApp.RowSurface row, Collection<K, T> c,
            java.util.function.Function<KayaApp.Tpl, R> makeRow) {
        return row.tpl().rows(c.handle, makeRow);
    }

    /**
     * Insert a record under a key the binding authors, and hand the key
     * back. The contract, in full, is on {@link KayaApp.Tx#insertFresh}.
     *
     * <p>KEEP IT A STATIC. The minted key is I64, so the collection must
     * be {@code Collection<Long, T>}; Java cannot constrain an instance
     * method to one instantiation of its own class's type parameters, so
     * as a method this would silently accept a String-keyed collection.
     * As a function the parameter type is the wall.
     */
    public static <T> long insertFresh(KayaApp.Tx tx, Collection<Long, T> c, T value) {
        return c.insertMinted(tx, value);
    }

    /**
     * Declare a collection of T records; the record type is the
     * schema. Returns the typed root handle.
     */
    public static <K, T> Collection<K, T> collectionOf(KayaApp.Tx tx, Class<T> type) {
        Info info = Info.of(type);
        KayaApp.Collection handle = tx.collectionWithSchema(info.schema);
        // Registered here because this is the one place T is known.
        tx.registerRebuild(handle.id, (variant, fields) -> info.fromWire(fields));
        return new Collection<>(handle, info);
    }

    /**
     * collectionOf inside a template body: a nested collection may only
     * be declared in the template scope, so a table whose rows carry
     * named fields needs the constructor there too (docs/deferred.md,
     * the nested-record-collection gap).
     */
    public static <K, T> Collection<K, T> collectionOf(KayaApp.Tpl t, Class<T> type) {
        return collectionOf(t.tx(), type);
    }

    /**
     * collectionOf inside a ROW body — the handle {@code tx.rows(c)}
     * hands out, and the only zone handle most Java scenes ever hold.
     * The twin of {@link KayaApp.RowSurface#collection()}.
     */
    public static <K, T> Collection<K, T> collectionOf(KayaApp.RowSurface row, Class<T> type) {
        return collectionOf(row.tpl(), type);
    }

    /**
     * The field token at a known wire index, for generated code only: a
     * hand-minted index is unchecked, so hand-written code uses
     * {@link #fieldOf}.
     */
    public static <V> Field<V> fieldAt(int index) {
        return new Field<>(index);
    }

    /**
     * The field token for the component a selector reads:
     * {@code fieldOf(Todo.class, Todo::done)}. Resolution probes: it
     * builds a default-valued prototype, then one variant per wire field
     * with a sentinel in that field, and the probe whose selector result
     * changes names the field. Probes rather than SerializedLambda
     * because D8-desugared lambdas carry no writeReplace on Android
     * (docs/traps.md).
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
                // would grow the map without bound.
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

    /** Selector instance -> resolved token, by identity: the probe run
     * is the expensive path and handlers resolve per event. */
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
