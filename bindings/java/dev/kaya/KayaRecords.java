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
            return null;
        }

        /** Component (name, type) pairs in declaration order, plus the
         * canonical constructor. Real record metadata when the runtime
         * has it; on Android, D8 desugars records — ART never sees
         * record components — so the fallback reads the one declared
         * constructor instead: parameter names (kept by -parameters)
         * name the components, and each accessor is the zero-argument
         * method with the component's name. Both roads describe the
         * same canonical shape. */
        static Info of(Class<?> type) {
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
                    fields[i] = accessors[wireToComponent[i]].invoke(record);
                }
            } catch (ReflectiveOperationException e) {
                throw new IllegalStateException("kaya: record accessor failed", e);
            }
            return fields;
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
    public static final class Entry<T> {
        public final Object key;
        public final T value;

        Entry(Object key, T value) {
            this.key = key;
            this.value = value;
        }
    }

    /**
     * A collection whose entries are T records; the plain handle rides
     * along for forEach and at.
     */
    public static final class Collection<T> {
        public final KayaApp.Collection handle;
        final Info info;

        Collection(KayaApp.Collection handle, Info info) {
            this.handle = handle;
            this.info = info;
        }

        public void insert(KayaApp.Tx tx, Object key, T value) {
            tx.insertRecordRaw(handle, key, value, info.wireFields(value));
        }

        public void update(KayaApp.Tx tx, Object key, T value) {
            tx.updateRecordRaw(handle, key, value, info.wireFields(value));
        }

        /**
         * One field's delta: the rest of the record never travels; the
         * model's copy is reconstructed with the new value.
         */
        public <V> void updateField(KayaApp.Tx tx, Object key, Field<V> f, V value) {
            Object current = null;
            for (KayaApp.Entry entry : tx.items(handle)) {
                if (entry.key.equals(key)) {
                    current = entry.value;
                }
            }
            if (current == null) {
                throw new IllegalStateException("kaya: update of missing key " + key);
            }
            tx.updateFieldRaw(handle, key, info.withField(current, f.index, value), f.index, value);
        }

        /** The typed model: what this guest wrote, in insertion order. */
        @SuppressWarnings("unchecked")
        public List<Entry<T>> items(KayaApp.Tx tx) {
            List<Entry<T>> out = new ArrayList<>();
            for (KayaApp.Entry entry : tx.items(handle)) {
                out.add(new Entry<>(entry.key, (T) entry.value));
            }
            return out;
        }
    }

    /**
     * Declare a collection of T records; the record type is the
     * schema. Returns the typed root handle.
     */
    public static <T> Collection<T> collectionOf(KayaApp.Tx tx, Class<T> type) {
        Info info = Info.of(type);
        return new Collection<>(tx.collectionWithSchema(info.schema), info);
    }

    /**
     * The field token for T's component {@code name}, checked against
     * V at declaration time (a wrong name or type throws at startup,
     * not in a handler). Primitive components use their boxed class
     * ({@code fieldOf(Todo.class, "done", Boolean.class)}).
     */
    public static <T, V> Field<V> fieldOf(Class<T> type, String name, Class<V> valueType) {
        Info info = Info.of(type);
        for (int wire = 0; wire < info.wireToComponent.length; wire++) {
            Method accessor = info.accessors[info.wireToComponent[wire]];
            if (accessor.getName().equals(name)) {
                Class<?> boxed = box(accessor.getReturnType());
                if (boxed != valueType) {
                    throw new IllegalArgumentException("kaya: " + type.getName() + "." + name
                            + " is " + boxed.getName() + ", not " + valueType.getName());
                }
                return new Field<>(wire);
            }
        }
        throw new IllegalArgumentException(
                "kaya: " + type.getName() + " has no wire field " + name);
    }

    private static Class<?> box(Class<?> t) {
        if (t == boolean.class) return Boolean.class;
        if (t == long.class) return Long.class;
        if (t == double.class) return Double.class;
        return t;
    }

    private KayaRecords() {}
}
