package dev.kaya;

import java.lang.reflect.Constructor;
import java.time.LocalDate;
import java.time.LocalTime;
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
    /** A typed projection: one field of a record type, by wire
     * position. */
    public static final class Field<V> {
        final int index;

        Field(int index) {
            this.index = index;
        }

        /** The wire position, for the template-zone binders. */
        public int index() {
            return index;
        }

        /**
         * The whole element of a scalar collection, as a field token.
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
            // A stamped copy's document is a Blob field whose bytes are
            // the document's own value list (docs/rich-text-plan.md §19).
            if (t == KayaApp.Document.class) return KayaWire.VALUE_BLOB;
            // The picker types ride the I64 tag in packed decimal
            // (docs/datetime-plan.md D10).
            if (t == LocalDate.class || t == LocalTime.class) return KayaWire.VALUE_I64;
            if (t == KayaApp.Color.class) return KayaWire.VALUE_I64;
            // A row's player: its id, 0 for none (docs/media-plan.md §7b).
            if (t == KayaApp.Player.class) return KayaWire.VALUE_I64;
            // An image's phase (docs/network-images-plan.md N2).
            if (t == KayaApp.ImagePhase.class) return KayaWire.VALUE_I64;
            // A label's tint (docs/styling-pass-plan.md Y7).
            if (t == KayaApp.Tint.class) return KayaWire.VALUE_I64;
            if (t == KayaApp.Symbol.class) return KayaWire.VALUE_I64;
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
            if (value == null
                    && accessors[wireToComponent[wireIndex]].getReturnType() == KayaApp.Player.class) {
                return 0L;
            }
            if (value instanceof LocalDate || value instanceof LocalTime
                    || value instanceof KayaApp.Color || value instanceof KayaApp.Player
                    || value instanceof KayaApp.ImagePhase || value instanceof KayaApp.Tint
                    || value instanceof KayaApp.Symbol) {
                return scalarWire(value);
            }
            if (schema[wireIndex] == KayaWire.VALUE_BLOB) {
                if (value instanceof KayaApp.Document document) {
                    return new KayaWire.BlobHandle(
                            KayaRing.blobRegister(KayaApp.documentBlob(document)));
                }
                if (!(value instanceof byte[])) {
                    throw new IllegalArgumentException("kaya: "
                            + ctor.getDeclaringClass().getName() + " wire field " + wireIndex
                            + " is a blob — pass byte[] (encoded image bytes) or a Document, not "
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
                int at = wireToComponent[wire];
                Class<?> want = parameters[at].getType();
                // A packed I64 comes back as the picker type it was
                // written from, never as the long it travelled as.
                if (want == LocalDate.class) {
                    args[at] = dateOf(fields.get(wire));
                } else if (want == LocalTime.class) {
                    args[at] = timeOf(fields.get(wire));
                } else if (want == KayaApp.Color.class) {
                    args[at] = colorOf(fields.get(wire));
                } else if (want == KayaApp.Player.class) {
                    args[at] = playerOf(fields.get(wire));
                } else if (want == KayaApp.ImagePhase.class) {
                    args[at] = KayaApp.ImagePhase.ofWire((Long) fields.get(wire));
                } else if (want == KayaApp.Tint.class) {
                    args[at] = KayaApp.Tint.ofWire((Long) fields.get(wire));
                } else if (want == KayaApp.Symbol.class) {
                    args[at] = KayaApp.Symbol.ofWire((Long) fields.get(wire));
                } else if (want == KayaApp.Document.class) {
                    // A restored Document field is the blob's BYTES,
                    // redeemed by KayaWire.parseValue
                    // (crates/kaya/src/wire.rs, undo_body).
                    args[at] = KayaApp.documentOfBlob(fields.get(wire));
                } else {
                    args[at] = fields.get(wire);
                }
            }
            try {
                return ctor.newInstance(args);
            } catch (ReflectiveOperationException e) {
                throw new IllegalStateException("kaya: record reconstruction failed", e);
            }
        }

        /** One wire field's value as the record holds it — the read
         * half of withField, which the row-document fold needs
         * (docs/rich-text-plan.md §19). */
        Object fieldOfWire(Object record, int wireIndex) {
            try {
                return accessors[wireToComponent[wireIndex]].invoke(record);
            } catch (ReflectiveOperationException e) {
                throw new IllegalStateException("kaya: record accessor failed", e);
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
         * nesting. Typed, unlike {@code handle.at}, which every record
         * mutation below needs.
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

        /** The entry at {@code key}, or empty for a missing one.
         * Optional as a RETURN type is the use the JDK's own guidance
         * sanctions, and the shape the other eight bindings' keyed read
         * translates to (Rust's Option, Go's comma-ok, C#'s TryGet). */
        @SuppressWarnings("unchecked")
        public java.util.Optional<T> find(KayaApp.Tx tx, K key) {
            for (KayaApp.Entry entry : tx.items(handle)) {
                if (java.util.Objects.equals(entry.key, key)) {
                    return java.util.Optional.ofNullable((T) entry.value);
                }
            }
            return java.util.Optional.empty();
        }

        /** The entry at {@code key}; throws naming it if there is none.
         * {@link #find} is the spelling for a key that may be absent. */
        public T get(KayaApp.Tx tx, K key) {
            return find(tx, key).orElseThrow(() ->
                    new IllegalStateException("kaya: no entry at key " + key));
        }

        /**
         * One field's delta by selector: the rest of the record never
         * travels.
         */
        public <V> void updateField(KayaApp.Tx tx, K key,
                java.util.function.Function<T, V> selector, V value) {
            updateField(tx, key, resolve(selector), value);
        }

        /** updateField over a pre-resolved token. */
        public <V> void updateField(KayaApp.Tx tx, K key, Field<V> f, V value) {
            Object current = find(tx, key).orElseThrow(() ->
                    new IllegalStateException("kaya: update of missing key " + key));
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
        @FunctionalInterface
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

        /** A template date picker's typed pick handler: the stamped
         * copy's key (this collection's K), then the committed date. */
        @FunctionalInterface
        public interface DateHandler<K> {
            void accept(KayaApp.Tx tx, K key, LocalDate date);
        }

        /** A template colour picker's typed handler: the copy's key,
         * then the settled colour. */
        @FunctionalInterface
        public interface ColorHandler<K> {
            void accept(KayaApp.Tx tx, K key, KayaApp.Color color);
        }

        /** A template time picker's typed pick handler. */
        @FunctionalInterface
        public interface TimeHandler<K> {
            void accept(KayaApp.Tx tx, K key, LocalTime time);
        }

        /** A date picker bound to the field the selector reads. */
        @SuppressWarnings("unchecked")
        public KayaApp.Node datePicker(KayaApp.Tpl t,
                java.util.function.Function<T, LocalDate> selector, DateHandler<K> onDate) {
            return datePicker(t, this.<LocalDate>resolve(selector), onDate);
        }

        /** A colour picker bound to the field the selector reads. */
        public KayaApp.Node colorPicker(KayaApp.Tpl t,
                java.util.function.Function<T, KayaApp.Color> selector, ColorHandler<K> onColor) {
            return colorPicker(t, this.<KayaApp.Color>resolve(selector), onColor);
        }

        @SuppressWarnings("unchecked")
        public KayaApp.Node colorPicker(KayaApp.Tpl t, Field<KayaApp.Color> f,
                ColorHandler<K> onColor) {
            KayaApp.Node n = t.colorPicker(f);
            if (onColor != null) {
                t.onColorNode(n, (tx, keys, color) ->
                        onColor.accept(tx, (K) keys.get(0), color));
            }
            return n;
        }

        /** A time picker bound to the field the selector reads. */
        public KayaApp.Node timePicker(KayaApp.Tpl t,
                java.util.function.Function<T, LocalTime> selector, TimeHandler<K> onTime) {
            return timePicker(t, this.<LocalTime>resolve(selector), onTime);
        }

        @SuppressWarnings("unchecked")
        public KayaApp.Node datePicker(KayaApp.Tpl t, Field<LocalDate> f,
                DateHandler<K> onDate) {
            KayaApp.Node n = t.datePicker(f);
            if (onDate != null) {
                t.onDateNode(n, (tx, keys, date) ->
                        onDate.accept(tx, (K) keys.get(0), date));
            }
            return n;
        }

        @SuppressWarnings("unchecked")
        public KayaApp.Node timePicker(KayaApp.Tpl t, Field<LocalTime> f,
                TimeHandler<K> onTime) {
            KayaApp.Node n = t.timePicker(f);
            if (onTime != null) {
                t.onTimeNode(n, (tx, keys, time) ->
                        onTime.accept(tx, (K) keys.get(0), time));
            }
            return n;
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

        /**
         * The same writes, made only while row {@code key} exists and its
         * {@code guard} field still holds {@code expected}; otherwise
         * nothing, and no exception (docs/network-images-plan.md N7). The
         * chain is ONE record, sent with the transaction's next record or
         * when its build ends:
         * {@code tracks.patchIf(tx, key, Track::artUrl, url).set(Track::art, bytes)}.
         */
        public <V> PatchIf<K, T> patchIf(KayaApp.Tx tx, K key,
                java.util.function.Function<T, V> guard, V expected) {
            return patchIf(tx, key, resolve(guard), expected);
        }

        /** patchIf over a pre-resolved token. */
        public <V> PatchIf<K, T> patchIf(KayaApp.Tx tx, K key, Field<V> guard, V expected) {
            tx.alive();
            Object current = find(tx, key).orElse(null);
            boolean holds = current != null && java.util.Objects.equals(
                    info.fieldOfWire(current, guard.index), expected);
            return new PatchIf<>(this, tx, key, tx.openPatchIf(handle, key, guard.index,
                    info.encodeField(guard.index, expected), holds));
        }
    }

    /** An open guarded patch on one entry; set chains within the one
     * statement. */
    public static final class PatchIf<K, T> {
        final Collection<K, T> c;
        final KayaApp.Tx tx;
        final K key;
        final KayaApp.PatchIfRecord record;

        PatchIf(Collection<K, T> c, KayaApp.Tx tx, K key, KayaApp.PatchIfRecord record) {
            this.c = c;
            this.tx = tx;
            this.key = key;
            this.record = record;
        }

        /** Writes the field the selector reads when the guard holds. */
        public <V> PatchIf<K, T> set(java.util.function.Function<T, V> selector, V value) {
            return set(c.resolve(selector), value);
        }

        /** Writes the field a pre-resolved token names when the guard
         * holds. */
        public <V> PatchIf<K, T> set(Field<V> f, V value) {
            Object model = record.holds
                    ? c.info.withField(c.find(tx, key).orElseThrow(), f.index, value)
                    : null;
            tx.patchIfSet(record, f.index, c.info.encodeField(f.index, value), model);
            return this;
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
     * generated surface. ONE OVERLOAD PER ZONE: the For's container is
     * the zone's own handle, a live Widget at the top and a template
     * Node inside a row.
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
     * Insert a record under a key the binding authors, and hand it back
     * ({@link KayaApp.Tx#insertFresh} has the contract). KEEP IT A
     * STATIC: the key is I64, and Java cannot constrain an instance
     * method to one instantiation of its class's type parameters, so as
     * a method this would silently accept a String-keyed collection.
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
     * hands out. The twin of {@link KayaApp.RowSurface#collection()}.
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
     * {@code fieldOf(Todo.class, Todo::done)}. Probes rather than
     * SerializedLambda because D8-desugared lambdas carry no
     * writeReplace on Android (docs/traps.md).
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

    /** Selector instance -> resolved token, by identity. */
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
    private static final LocalDate DEFAULT_DATE = LocalDate.of(1970, 1, 1);
    private static final LocalDate SENTINEL_DATE = LocalDate.of(2345, 6, 7);
    private static final LocalTime DEFAULT_TIME = LocalTime.of(0, 0);
    private static final LocalTime SENTINEL_TIME = LocalTime.of(23, 45);
    private static final KayaApp.Color DEFAULT_COLOR = KayaApp.Color.fromHex(0x000000FF);
    private static final KayaApp.Color SENTINEL_COLOR = KayaApp.Color.fromHex(0x5EED5EED);
    private static final KayaApp.Player SENTINEL_PLAYER = new KayaApp.Player(0x5eedL, null);

    /** A scalar's wire value: a civil date or time packs, everything
     * else travels as itself (docs/datetime-plan.md D2). */
    static Object scalarWire(Object v) {
        if (v instanceof LocalDate d) {
            return KayaWire.packDate(d.getYear(), d.getMonthValue(), d.getDayOfMonth());
        }
        if (v instanceof LocalTime t) {
            return KayaWire.packTime(t.getHour(), t.getMinute());
        }
        if (v instanceof KayaApp.Color c) {
            return KayaWire.packColor(c.r(), c.g(), c.b(), c.a());
        }
        if (v instanceof KayaApp.Player p) {
            return p.id;
        }
        if (v instanceof KayaApp.ImagePhase p) {
            return (long) p.wire;
        }
        if (v instanceof KayaApp.Tint t) {
            return t.wire;
        }
        if (v instanceof KayaApp.Symbol s) {
            return s.wire;
        }
        // A signal of bytes: handles are single-submit, so every write
        // registers its own copy (docs/traps.md, a blob signal).
        if (v instanceof byte[] bytes) {
            return new KayaWire.BlobHandle(KayaRing.blobRegister(bytes));
        }
        return v;
    }

    static LocalDate dateOf(Object packed) {
        KayaWire.CivilDate d = KayaWire.unpackDate(packed instanceof Long l ? l : 0L);
        return LocalDate.of(d.year(), d.month(), d.day());
    }

    static KayaApp.Color colorOf(Object packed) {
        KayaWire.ColorChannels c = KayaWire.unpackColor(packed instanceof Long l ? l : 0L);
        return new KayaApp.Color(c.r(), c.g(), c.b(), c.a());
    }

    /** A row's player field off the wire: null for 0, the row showing
     * none. */
    static KayaApp.Player playerOf(Object id) {
        long n = id instanceof Long l ? l : 0L;
        return n == 0 ? null : new KayaApp.Player(n, null);
    }

    static LocalTime timeOf(Object packed) {
        KayaWire.CivilTime t = KayaWire.unpackTime(packed instanceof Long l ? l : 0L);
        return LocalTime.of(t.hour(), t.minute());
    }

    private static Object defaultValue(Class<?> t) {
        if (t == String.class) return "";
        if (t == boolean.class || t == Boolean.class) return false;
        if (t == long.class || t == Long.class) return 0L;
        if (t == double.class || t == Double.class) return 0.0;
        if (t == byte[].class) return DEFAULT_BLOB;
        if (t == LocalDate.class) return DEFAULT_DATE;
        if (t == LocalTime.class) return DEFAULT_TIME;
        if (t == KayaApp.Color.class) return DEFAULT_COLOR;
        if (t == KayaApp.ImagePhase.class) return KayaApp.ImagePhase.SHOWN;
        if (t == KayaApp.Tint.class) return KayaApp.Tint.NONE;
        if (t == KayaApp.Symbol.class) return KayaApp.Symbol.ADD;
        if (t == int.class) return 0;
        return null; // guest-only reference fields
    }

    private static Object sentinelValue(Class<?> t) {
        if (t == String.class) return "\u0000kaya";
        if (t == boolean.class || t == Boolean.class) return true;
        if (t == long.class || t == Long.class) return 0x5eedL;
        if (t == double.class || t == Double.class) return 1.0;
        if (t == byte[].class) return SENTINEL_BLOB;
        if (t == LocalDate.class) return SENTINEL_DATE;
        if (t == LocalTime.class) return SENTINEL_TIME;
        if (t == KayaApp.Color.class) return SENTINEL_COLOR;
        if (t == KayaApp.Player.class) return SENTINEL_PLAYER;
        if (t == KayaApp.ImagePhase.class) return KayaApp.ImagePhase.FAILED;
        if (t == KayaApp.Tint.class) return KayaApp.Tint.OVERLAY;
        if (t == KayaApp.Symbol.class) return KayaApp.Symbol.REMOVE;
        throw new IllegalStateException("kaya: no sentinel for " + t.getName());
    }

    /** What KayaApp hands a template image's needed and released rows
     * to: a {@link RowImages}. */
    interface ImageFeed {
        void needed(KayaApp.Tx tx, List<Object> keys);

        void released(List<Object> keys);
    }

    /**
     * A row's image loaded on demand (docs/network-images-plan.md N12):
     * each row holds the URL it wants, its bytes and its phase; a row
     * realized LOADING with no bytes is fetched, at most {@link #LIMIT} at
     * a time, rows sharing a URL share one fetch, a released row's URL
     * nobody else waits on is dropped from the queue or its fetch
     * cancelled, and every result is one {@link Collection#patchIf}
     * guarded on the URL, written through {@link KayaApp#post}.
     */
    public static final class RowImages<K, T> implements ImageFeed {
        /** The app's fetch: a future of the bytes at a URL. It must
         * return at once; cancelling the future should stop the fetch. */
        @FunctionalInterface
        public interface Fetch {
            java.util.concurrent.CompletableFuture<byte[]> fetch(String url);
        }

        /** Runs on the app thread inside the transaction that writes
         * FAILED, with the row's keys and why. */
        @FunctionalInterface
        public interface ErrorHandler {
            void accept(KayaApp.Tx tx, List<Object> keys, Throwable error);
        }

        public static final int LIMIT = 6;

        private final KayaApp app;
        private final Collection<K, T> rows;
        private final Field<String> url;
        private final Field<byte[]> art;
        private final Field<KayaApp.ImagePhase> phase;
        private final Fetch fetch;
        private volatile ErrorHandler onError;

        private final java.util.Map<String, Job> jobs = new java.util.HashMap<>();
        private final java.util.ArrayDeque<Job> queue = new java.util.ArrayDeque<>();
        private int running;
        private final java.util.LinkedHashMap<String, byte[]> cache =
                new java.util.LinkedHashMap<>(16, 0.75f, true);
        private long cached;
        private static final long CACHE_BUDGET = 32L << 20;

        private static final class Job {
            final String url;
            final List<List<Object>> waiting = new ArrayList<>();
            java.util.concurrent.CompletableFuture<byte[]> future;

            Job(String url) {
                this.url = url;
            }
        }

        /** Rows' images through {@link #http}. */
        public RowImages(KayaApp app, Collection<K, T> rows,
                java.util.function.Function<T, String> url,
                java.util.function.Function<T, byte[]> art,
                java.util.function.Function<T, KayaApp.ImagePhase> phase) {
            this(app, rows, url, art, phase, http());
        }

        public RowImages(KayaApp app, Collection<K, T> rows,
                java.util.function.Function<T, String> url,
                java.util.function.Function<T, byte[]> art,
                java.util.function.Function<T, KayaApp.ImagePhase> phase, Fetch fetch) {
            this.app = app;
            this.rows = rows;
            this.url = rows.resolve(url);
            this.art = rows.resolve(art);
            this.phase = rows.resolve(phase);
            this.fetch = java.util.Objects.requireNonNull(fetch, "kaya: RowImages needs a fetch");
        }

        public RowImages<K, T> onError(ErrorHandler handler) {
            onError = handler;
            return this;
        }

        /** Fetch for the stamped copies of template image {@code image},
         * before and whatever {@link KayaApp#onNeeded} does. */
        public void attach(KayaApp.Node image) {
            app.imageFeed(image, this);
        }

        /**
         * The default fetch, java.net's HttpURLConnection on a daemon pool:
         * a status outside 2xx fails, and so does {@link #IDLE_MS} with no
         * byte (OkHttp's default read timeout). Not java.net.http:
         * android.jar has none, and this binding is compiled into the
         * Android hosts. A cancel completes the future at once; the
         * reading thread stops at its next byte or timeout (docs/traps.md,
         * a cancelled HttpURLConnection keeps its socket).
         */
        public static Fetch http() {
            return target -> {
                java.util.concurrent.CompletableFuture<byte[]> out =
                        new java.util.concurrent.CompletableFuture<>();
                HTTP.execute(() -> {
                    java.net.HttpURLConnection c = null;
                    try {
                        c = (java.net.HttpURLConnection)
                                java.net.URI.create(target).toURL().openConnection();
                        c.setRequestProperty("Connection", "close");
                        c.setRequestProperty("User-Agent", "kaya/" + KayaWire.VERSION);
                        c.setReadTimeout(IDLE_MS);
                        int status = c.getResponseCode();
                        if (status < 200 || status > 299) {
                            throw new java.io.IOException(target + " answered " + status);
                        }
                        java.io.ByteArrayOutputStream body = new java.io.ByteArrayOutputStream();
                        byte[] chunk = new byte[16384];
                        try (java.io.InputStream in = c.getInputStream()) {
                            int n;
                            while (!out.isCancelled() && (n = in.read(chunk)) >= 0) {
                                body.write(chunk, 0, n);
                            }
                        }
                        out.complete(body.toByteArray());
                    } catch (java.io.IOException | RuntimeException e) {
                        out.completeExceptionally(e);
                    } finally {
                        if (c != null) {
                            c.disconnect();
                        }
                    }
                });
                return out;
            };
        }

        /** How long the default fetch waits for a byte. */
        static final int IDLE_MS = 10_000;

        private static final java.util.concurrent.ExecutorService HTTP =
                java.util.concurrent.Executors.newCachedThreadPool(r -> {
                    Thread t = new Thread(r, "kaya-row-images");
                    t.setDaemon(true);
                    return t;
                });

        @SuppressWarnings("unchecked")
        private Collection<K, T> instance(List<Object> keys) {
            Collection<K, T> c = rows;
            for (Object k : keys.subList(0, keys.size() - 1)) {
                c = c.at(k);
            }
            return c;
        }

        @Override
        @SuppressWarnings("unchecked")
        public void needed(KayaApp.Tx tx, List<Object> keys) {
            if (keys.isEmpty()) {
                return;
            }
            K key = (K) keys.get(keys.size() - 1);
            T record = instance(keys).find(tx, key).orElse(null);
            String want = record == null ? "" : (String) rows.info.fieldOfWire(record, url.index);
            if (want.isEmpty()) {
                return;
            }
            byte[] hit;
            synchronized (this) {
                hit = cache.get(want);
                if (hit == null) {
                    Job job = jobs.get(want);
                    if (job != null) {
                        job.waiting.add(keys);
                        return;
                    }
                    job = new Job(want);
                    job.waiting.add(keys);
                    jobs.put(want, job);
                    queue.add(job);
                    pump();
                    return;
                }
            }
            write(tx, List.of(keys), want, hit, null);
        }

        @Override
        public synchronized void released(List<Object> keys) {
            for (var it = jobs.values().iterator(); it.hasNext();) {
                Job job = it.next();
                job.waiting.removeIf(keys::equals);
                if (!job.waiting.isEmpty()) {
                    continue;
                }
                it.remove();
                if (job.future != null) {
                    job.future.cancel(true);
                } else {
                    queue.remove(job);
                }
            }
        }

        private synchronized void pump() {
            while (running < LIMIT && !queue.isEmpty()) {
                Job job = queue.poll();
                running++;
                job.future = fetch.fetch(job.url);
                job.future.whenComplete((bytes, error) -> done(job, bytes, error));
            }
        }

        private void done(Job job, byte[] bytes, Throwable error) {
            List<List<Object>> waiting;
            synchronized (this) {
                running--;
                if (error == null) {
                    byte[] old = cache.put(job.url, bytes);
                    cached += bytes.length - (old == null ? 0 : old.length);
                    for (var it = cache.entrySet().iterator();
                            cached > CACHE_BUDGET && cache.size() > 1 && it.hasNext();) {
                        cached -= it.next().getValue().length;
                        it.remove();
                    }
                }
                if (jobs.get(job.url) == job) {
                    jobs.remove(job.url);
                }
                waiting = new ArrayList<>(job.waiting);
                job.waiting.clear();
                pump();
            }
            Throwable why = error instanceof java.util.concurrent.CompletionException
                    && error.getCause() != null ? error.getCause() : error;
            if (why != null && !(why instanceof java.util.concurrent.CancellationException)) {
                fetchFailed(job.url, why);
            }
            if (!waiting.isEmpty()) {
                app.post(tx -> write(tx, waiting, job.url, bytes, why));
            }
        }

        /** docs/traps.md, "The sockets a stale freeze destroyed": one write,
         * the same line in all nine bindings. */
        private static void fetchFailed(String url, Throwable error) {
            String why = error.getMessage() != null ? error.getMessage()
                    : error.getClass().getSimpleName();
            System.err.print("kaya: row image fetch failed: " + url + ": "
                    + why.replace('\n', ' ').replace('\r', ' ') + "\n");
            System.err.flush();
        }

        @SuppressWarnings("unchecked")
        private void write(KayaApp.Tx tx, List<List<Object>> keysList, String fetched,
                byte[] bytes, Throwable error) {
            for (List<Object> keys : keysList) {
                K key = (K) keys.get(keys.size() - 1);
                PatchIf<K, T> p = instance(keys).patchIf(tx, key, url, fetched);
                if (error == null) {
                    p.set(art, bytes).set(phase, KayaApp.ImagePhase.SHOWN);
                    continue;
                }
                p.set(phase, KayaApp.ImagePhase.FAILED);
                ErrorHandler handler = onError;
                if (handler != null) {
                    handler.accept(tx, keys, error);
                }
            }
        }
    }

    private KayaRecords() {}
}
