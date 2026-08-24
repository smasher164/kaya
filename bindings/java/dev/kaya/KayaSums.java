package dev.kaya;

import java.util.List;
import java.util.function.BiConsumer;
import java.util.function.Function;

/**
 * Sum-typed collections: a sealed interface is the sum, its permitted
 * records the constructors. See DESIGN.md's variants section.
 */
public final class KayaSums {
    /** A collection whose entries are one of several record
     * constructors behind the sealed interface T, keyed by K. */
    public static final class SumCollection<K, T> {
        public final KayaApp.Collection handle;
        final Class<?>[] variants;
        final KayaRecords.Info[] infos;

        SumCollection(KayaApp.Collection handle, Class<?>[] variants, KayaRecords.Info[] infos) {
            this.handle = handle;
            this.variants = variants;
            this.infos = infos;
        }

        int variantOf(Class<?> type) {
            for (int i = 0; i < variants.length; i++) {
                if (variants[i] == type) {
                    return i;
                }
            }
            throw new IllegalArgumentException(
                    "kaya: " + type.getName() + " is not a constructor of this sum");
        }

        /** Insert witnesses the value's own constructor onto the wire. */
        public void insert(KayaApp.Tx tx, K key, T value) {
            int variant = variantOf(value.getClass());
            tx.insertRecordRaw(handle, key, value, variant,
                    infos[variant].wireFields(value));
        }

        /** The witnessed insert under a minted key; see
         * {@link KayaSums#insertFresh}, which is where the key type
         * gets checked. */
        long insertMinted(KayaApp.Tx tx, T value) {
            int variant = variantOf(value.getClass());
            long key = tx.mintKeyFor(handle);
            tx.insertRecordRaw(handle, key, value, variant,
                    infos[variant].wireFields(value));
            return key;
        }

        /** Update replaces a record wholesale; a different constructor
         * than the entry's current one restamps its copy in place. */
        public void update(KayaApp.Tx tx, K key, T value) {
            int variant = variantOf(value.getClass());
            tx.updateRecordRaw(handle, key, value, variant,
                    infos[variant].wireFields(value));
        }

        /** The typed model, in insertion order. */
        @SuppressWarnings("unchecked")
        public List<KayaRecords.Entry<K, T>> items(KayaApp.Tx tx) {
            List<KayaRecords.Entry<K, T>> out = new java.util.ArrayList<>();
            for (KayaApp.Entry entry : tx.items(handle)) {
                out.add(new KayaRecords.Entry<>((K) entry.key, (T) entry.value));
            }
            return out;
        }

        /** The entry's current value — the scrutinee for the pattern
         * match that precedes a patch — or null for a missing key. */
        @SuppressWarnings("unchecked")
        public T get(KayaApp.Tx tx, K key) {
            for (KayaApp.Entry entry : tx.items(handle)) {
                if (java.util.Objects.equals(entry.key, key)) {
                    return (T) entry.value;
                }
            }
            return null;
        }

        /**
         * The witnessed field write: V names the constructor the caller
         * just matched, and the write throws if the entry holds a
         * different one.
         */
        public <V extends T, F> void updateField(KayaApp.Tx tx, K key, Class<V> constructor,
                Function<V, F> selector, F value) {
            int variant = variantOf(constructor);
            Object current = get(tx, key);
            if (current == null) {
                throw new IllegalStateException("kaya: update of missing key " + key);
            }
            if (current.getClass() != constructor) {
                throw new IllegalStateException("kaya: update_field witnessed "
                        + constructor.getSimpleName() + " but " + key + " holds "
                        + current.getClass().getSimpleName());
            }
            KayaRecords.Field<F> f = KayaRecords.fieldOf(constructor, selector);
            tx.updateFieldRaw(handle, key,
                    infos[variant].withField(current, f.index, value), variant, f.index,
                    infos[variant].encodeField(f.index, value));
        }

        /** The collection-derived signal, over the sum's entries. */
        public <V> KayaApp.Signal<V> derive(KayaApp.Tx tx,
                Function<List<KayaRecords.Entry<K, T>>, V> compute) {
            KayaApp.Signal<V> s = tx.signal(compute.apply(items(tx)));
            tx.registerDerived(handle.id, t -> t.write(s, compute.apply(items(t))));
            return s;
        }

        /** One arm of the template eliminator, typed by its
         * constructor. */
        public <V extends T> Arm<K, T> arm(Class<V> constructor,
                BiConsumer<KayaApp.Tpl, Case<K, V>> body) {
            int variant = variantOf(constructor);
            KayaRecords.Info info = infos[variant];
            return new Arm<>(variant, t -> body.accept(t, new Case<>(constructor, info)));
        }
    }

    /** One declared arm: the constructor's discriminant plus its
     * blueprint author. */
    public static final class Arm<K, T> {
        final int variant;
        final java.util.function.Consumer<KayaApp.Tpl> body;

        Arm(int variant, java.util.function.Consumer<KayaApp.Tpl> body) {
            this.variant = variant;
            this.body = body;
        }
    }

    /** The arm's refined vocabulary: selectors resolve against
     * constructor V's schema. */
    public static final class Case<K, V> {
        final Class<V> constructor;
        final KayaRecords.Info info;

        Case(Class<V> constructor, KayaRecords.Info info) {
            this.constructor = constructor;
            this.info = info;
        }

        /** A label bound to the field the selector names. */
        public KayaApp.Node label(KayaApp.Tpl t, Function<V, String> selector) {
            return t.label(KayaRecords.fieldOf(constructor, selector));
        }

        /** A toggle handler's shape: the stamped copy's key, then the
         * new state. */
        public interface ToggleHandler<K> {
            void accept(KayaApp.Tx tx, K key, boolean checked);
        }

        /** A checkbox bound to the field the selector names. */
        @SuppressWarnings("unchecked")
        public <K2> KayaApp.Node checkbox(KayaApp.Tpl t, Function<V, Boolean> selector,
                ToggleHandler<K2> onToggle) {
            KayaApp.Node n = t.checkbox(KayaRecords.fieldOf(constructor, selector));
            if (onToggle != null) {
                t.onToggleNode(n, (tx, keys, checked) ->
                        onToggle.accept(tx, (K2) keys.get(0), checked));
            }
            return n;
        }
    }

    /**
     * Insert under a key the binding authors, and hand it back — the
     * sum twin of {@link KayaRecords#insertFresh}. The contract is on
     * {@link KayaApp.Tx#insertFresh}.
     *
     * <p>KEEP IT A STATIC, for the reason its record twin gives.
     */
    public static <T> long insertFresh(KayaApp.Tx tx, SumCollection<Long, T> c, T value) {
        return c.insertMinted(tx, value);
    }

    /**
     * Declare a sum collection: one variant per constructor class, in
     * order — each record is that constructor's schema.
     */
    @SafeVarargs
    public static <K, T> SumCollection<K, T> sumOf(KayaApp.Tx tx, Class<T> sum,
            Class<? extends T>... constructors) {
        if (constructors.length < 2) {
            throw new IllegalArgumentException(
                    "kaya: a sum needs two constructors or more (collectionOf declares a record)");
        }
        Class<?>[] variants = new Class<?>[constructors.length];
        KayaRecords.Info[] infos = new KayaRecords.Info[constructors.length];
        int[][] schemas = new int[constructors.length][];
        for (int i = 0; i < constructors.length; i++) {
            variants[i] = constructors[i];
            infos[i] = KayaRecords.Info.of(constructors[i]);
            schemas[i] = infos[i].schema;
        }
        KayaApp.Collection handle = tx.collectionWithVariants(schemas);
        tx.registerRebuild(handle.id, (variant, fields) -> infos[variant].fromWire(fields));
        return new SumCollection<>(handle, variants, infos);
    }

    /**
     * The template eliminator: a product of arms, one per constructor,
     * checked complete here at declaration (any order).
     */
    @SafeVarargs
    public static <K, T> KayaApp.Widget eachSum(KayaApp.Tx tx, SumCollection<K, T> c,
            Arm<K, T>... arms) {
        if (arms.length != c.variants.length) {
            throw new IllegalArgumentException("kaya: the eliminator needs "
                    + c.variants.length + " arms, got " + arms.length);
        }
        boolean[] seen = new boolean[c.variants.length];
        for (Arm<K, T> arm : arms) {
            if (seen[arm.variant]) {
                throw new IllegalArgumentException(
                        "kaya: two arms for " + c.variants[arm.variant].getSimpleName());
            }
            seen[arm.variant] = true;
        }
        // The arms are the eliminator's shape, so this stays a
        // combinator; what changed is the For under it, whose one pass
        // now declares every arm in turn.
        KayaApp.Rows<KayaApp.Widget, KayaApp.Tpl> rows = tx.rows(c.handle, t -> t);
        for (KayaApp.Tpl t : rows) {
            for (Arm<K, T> arm : arms) {
                tx.emitVariantCase(arm.variant);
                arm.body.accept(t);
            }
        }
        return rows.handle;
    }

    private KayaSums() {}
}
