// Sum-typed collections: an abstract record is the sum, its derived
// records the constructors. Elimination is C#-shaped on both sides —
// pattern matching where the guest holds the value, a product of
// typed arms where the core does. The arms are checked complete at
// declaration (one per constructor, any order) with the scene as the
// second check; mutation is witnessed — a field write names the
// constructor the caller matched, and the model refuses a drifted
// entry.

using System;
using System.Collections.Generic;
using System.Linq.Expressions;

sealed class SumCollection<T>
{
    public readonly Collection Collection;
    internal readonly Type[] Variants;
    internal readonly RecordInfo[] Infos;

    internal SumCollection(Collection c, Type[] variants, RecordInfo[] infos)
    {
        Collection = c;
        Variants = variants;
        Infos = infos;
    }

    internal (uint, RecordInfo) VariantOf(Type t)
    {
        for (int i = 0; i < Variants.Length; i++)
            if (Variants[i] == t)
                return ((uint)i, Infos[i]);
        throw new ArgumentException($"kaya: {t.Name} is not a constructor of this sum");
    }

    /// Insert witnesses the value's own constructor onto the wire.
    public void Insert(Tx tx, object key, T value) =>
        InsertOrUpdate(tx, key, value, insert: true);

    /// Update replaces a record wholesale; a different constructor
    /// than the entry's current one restamps its copy in place.
    public void Update(Tx tx, object key, T value) =>
        InsertOrUpdate(tx, key, value, insert: false);

    void InsertOrUpdate(Tx tx, object key, T value, bool insert)
    {
        var (variant, info) = VariantOf(value.GetType());
        if (insert)
            tx.InsertRecordRaw(Collection, key, value, variant, info.WireFields(value));
        else
            tx.UpdateRecordRaw(Collection, key, value, variant, info.WireFields(value));
    }

    /// The typed model, in insertion order; a switch on the entry's
    /// runtime type eliminates it.
    public List<KeyValuePair<object, T>> Items(Tx tx)
    {
        var items = new List<KeyValuePair<object, T>>();
        foreach (var entry in tx.Items(Collection))
            items.Add(new KeyValuePair<object, T>(entry.Key, (T)entry.Value));
        return items;
    }

    /// The entry's current value — the scrutinee for the pattern match
    /// that precedes a patch — or default for a missing key.
    public T Get(Tx tx, object key)
    {
        foreach (var entry in tx.Items(Collection))
            if (Equals(entry.Key, key))
                return (T)entry.Value;
        return default;
    }

    /// The witnessed field write: V names the constructor the caller
    /// just matched (`if (feed.Get(tx, k) is Todo)` is the
    /// refinement), and the model refuses if the entry holds a
    /// different constructor — the guard is checked, not trusted.
    public void UpdateField<V, F>(Tx tx, object key, Expression<Func<V, F>> selector, F value)
        where V : T
    {
        var (variant, info) = VariantOf(typeof(V));
        object current = Get(tx, key);
        if (current == null)
            throw new InvalidOperationException($"kaya: update of missing key {key}");
        if (current.GetType() != typeof(V))
            throw new InvalidOperationException(
                $"kaya: update_field witnessed {typeof(V).Name} but {key} holds {current.GetType().Name}");
        var f = KayaRecords.FieldOf(selector);
        // The model keeps the guest's own value; the wire value is
        // encoded (a blob field re-registers its bytes — handles are
        // single-submit).
        tx.UpdateFieldRaw(Collection, key, info.WithField(current, f.Index, value), variant,
            f.Index, info.EncodeField(f.Index, value));
    }

    /// The collection-derived signal, over the sum's entries.
    public Signal Derive(Tx tx, Func<List<KeyValuePair<object, T>>, object> compute)
    {
        var s = tx.Signal(compute(Items(tx)));
        tx.RegisterDerived(Collection.Id, t => t.Write(s, compute(Items(t))));
        return s;
    }

    /// One arm of the template eliminator, typed by its constructor.
    public SumArm<T> Arm<V>(Action<Tpl, SumCase<V>> body) where V : T
    {
        var (variant, info) = VariantOf(typeof(V));
        return new SumArm<T>(variant,
            t => body(t, new SumCase<V>(info)));
    }
}

/// One declared arm: the constructor's discriminant plus its blueprint
/// author.
sealed class SumArm<T>
{
    internal readonly uint Variant;
    internal readonly Action<Tpl> Body;

    internal SumArm(uint variant, Action<Tpl> body)
    {
        Variant = variant;
        Body = body;
    }
}

/// The arm's refined vocabulary: selectors resolve against constructor
/// V's schema.
sealed class SumCase<V>
{
    internal readonly RecordInfo Info;

    internal SumCase(RecordInfo info) => Info = info;

    /// A label bound to the field the selector names.
    public Node Label(Tpl t, Expression<Func<V, string>> selector) =>
        t.Label(KayaRecords.FieldOf(selector));

    /// A checkbox bound to the field the selector names, with its
    /// toggle handler co-located (stamped key first).
    public Node Checkbox(Tpl t, Expression<Func<V, bool>> selector,
        Action<Tx, List<object>, bool> onToggle = null) =>
        t.Checkbox(KayaRecords.FieldOf(selector), onToggle);
}

static class KayaSums
{
    /// Declare a sum collection: one variant per constructor type, in
    /// order — each derived record is that constructor's schema. A
    /// one-constructor sum is what CollectionOf already declares.
    public static SumCollection<T> SumOf<T>(this Tx tx, params Type[] constructors)
    {
        if (constructors.Length < 2)
            throw new ArgumentException(
                "kaya: a sum needs two constructors or more (CollectionOf declares a record)");
        var infos = new RecordInfo[constructors.Length];
        var schemas = new uint[constructors.Length][];
        for (int i = 0; i < constructors.Length; i++)
        {
            if (!typeof(T).IsAssignableFrom(constructors[i]))
                throw new ArgumentException(
                    $"kaya: {constructors[i].Name} is not a {typeof(T).Name}");
            infos[i] = RecordInfo.Of(constructors[i]);
            schemas[i] = infos[i].Schema;
        }
        var c = tx.CollectionWithVariants(schemas);
        return new SumCollection<T>(c, constructors, infos);
    }

    /// The template eliminator: a product of arms, one per
    /// constructor, handed over whole. Completeness is checked here at
    /// declaration (one arm per constructor, any order), and the scene
    /// checks it again — an omitted constructor never waits for its
    /// first insert to fail.
    public static Widget EachSum<T>(this Tx tx, SumCollection<T> c, params SumArm<T>[] arms)
    {
        if (arms.Length != c.Variants.Length)
            throw new ArgumentException(
                $"kaya: the eliminator needs {c.Variants.Length} arms, got {arms.Length}");
        var seen = new bool[c.Variants.Length];
        foreach (var arm in arms)
        {
            if (seen[arm.Variant])
                throw new ArgumentException(
                    $"kaya: two arms for {c.Variants[arm.Variant].Name}");
            seen[arm.Variant] = true;
        }
        return tx.Each(c.Collection, t =>
        {
            foreach (var arm in arms)
            {
                tx.EmitVariantCase(arm.Variant);
                arm.Body(t);
            }
        });
    }
}
