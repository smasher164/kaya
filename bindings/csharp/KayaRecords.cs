// Records: the record type is the schema. Primary-constructor
// parameters of wire types (string, bool, long, double, byte[]) in
// declaration order are the schema; anything else is guest-only and
// never reaches the wire.

using System;
using System.Collections.Generic;
using System.Linq.Expressions;
using System.Reflection;

/// A typed projection: one field of a record type, by wire position.
/// The type parameter pins the C# type, so BindCheckedField rejects a
/// Field<string> at compile time.
sealed class Field<V>
{
    internal readonly uint Index;

    internal Field(uint index) => Index = index;

    /// The whole element of a scalar collection, as a field token: a
    /// scalar collection has no record, so its element is field 0.
    /// String only — a scalar collection is always strings.
    internal static Field<string> Element => new Field<string>(0);
}

sealed class RecordInfo
{
    internal uint[] Schema;
    // Wire field -> primary-constructor parameter position, and one
    // getter per parameter (reconstruction needs the guest-only ones too).
    internal int[] WireToCtor;
    internal Func<object, object>[] Getters;
    internal ConstructorInfo Ctor;

    static uint? WireTag(Type t) =>
        t == typeof(string) ? KayaWire.ValueStr
        : t == typeof(bool) ? KayaWire.ValueBool
        : t == typeof(long) ? KayaWire.ValueI64
        : t == typeof(double) ? KayaWire.ValueF64
        : t == typeof(byte[]) ? KayaWire.ValueBlob
        : (uint?)null;

    // One reflection walk per record type, ever: FieldOf runs per event
    // in handlers, so the walk must not re-run there.
    static readonly System.Collections.Concurrent.ConcurrentDictionary<Type, RecordInfo> Cache =
        new System.Collections.Concurrent.ConcurrentDictionary<Type, RecordInfo>();

    internal static RecordInfo Of(Type t) => Cache.GetOrAdd(t, Build);

    static RecordInfo Build(Type t)
    {
        var ctors = t.GetConstructors();
        if (ctors.Length != 1)
            throw new ArgumentException($"kaya: {t.Name} needs one primary constructor");
        var ctor = ctors[0];
        var parameters = ctor.GetParameters();
        var schema = new List<uint>();
        var wireToCtor = new List<int>();
        var getters = new Func<object, object>[parameters.Length];
        for (int i = 0; i < parameters.Length; i++)
        {
            var property = t.GetProperty(parameters[i].Name,
                BindingFlags.Public | BindingFlags.Instance | BindingFlags.IgnoreCase)
                ?? throw new ArgumentException(
                    $"kaya: {t.Name}.{parameters[i].Name} has no matching property — use a record");
            getters[i] = property.GetValue;
            var tag = WireTag(parameters[i].ParameterType);
            if (tag is uint wire)
            {
                schema.Add(wire);
                wireToCtor.Add(i);
            }
        }
        if (schema.Count == 0)
            throw new ArgumentException($"kaya: {t.Name} has no wire-typed fields");
        return new RecordInfo
        {
            Schema = schema.ToArray(),
            WireToCtor = wireToCtor.ToArray(),
            Getters = getters,
            Ctor = ctor,
        };
    }

    internal object[] WireFields(object record)
    {
        var fields = new object[WireToCtor.Length];
        for (int i = 0; i < WireToCtor.Length; i++)
            fields[i] = EncodeField((uint)i, Getters[WireToCtor[i]](record));
        return fields;
    }

    /// One field's wire value. A blob field registers its bytes here,
    /// at encode time: handles are single-submit, so every mutation
    /// carrying a blob field re-registers.
    internal object EncodeField(uint wireIndex, object value)
    {
        string name = Ctor.GetParameters()[WireToCtor[wireIndex]].Name;
        if (Schema[wireIndex] == KayaWire.ValueBlob)
        {
            if (value is not byte[] bytes)
                throw new ArgumentException(
                    $"kaya: {name} is a blob field and takes byte[], not "
                    + $"{value?.GetType().Name ?? "null"}");
            return new KayaWire.BlobHandle(Kaya.RegisterBlob(bytes));
        }
        if (value is byte[])
            throw new ArgumentException(
                $"kaya: {name} is not a blob field — image bytes belong in a "
                + "byte[]-typed record field (or Tx.Image)");
        return value;
    }

    /// The wire direction an undo travels: one entry's fields as the
    /// core states them, back into the object the model keeps.
    ///
    /// Guest-only constructor parameters never travelled, so they come
    /// from the entry the mirror still holds, and from the type's
    /// default when there is none (an undone remove).
    internal object FromWire(IReadOnlyList<object> fields, object current)
    {
        var parameters = Ctor.GetParameters();
        var args = new object[parameters.Length];
        bool sameShape = current != null && current.GetType() == Ctor.DeclaringType;
        for (int i = 0; i < args.Length; i++)
            args[i] = sameShape
                ? Getters[i](current)
                : (parameters[i].ParameterType.IsValueType
                    ? Activator.CreateInstance(parameters[i].ParameterType)
                    : null);
        for (int wire = 0; wire < WireToCtor.Length && wire < fields.Count; wire++)
            args[WireToCtor[wire]] = fields[wire];
        return Ctor.Invoke(args);
    }

    internal object WithField(object record, uint wireIndex, object value)
    {
        var args = new object[Getters.Length];
        for (int i = 0; i < Getters.Length; i++)
            args[i] = Getters[i](record);
        args[WireToCtor[wireIndex]] = value;
        return Ctor.Invoke(args);
    }
}

/// A Collection whose entries are T records; the plain handle rides
/// along for ForEach and At.
sealed class RecordCollection<T>
{
    public readonly Collection Collection;
    internal readonly RecordInfo Info;

    internal RecordCollection(Collection c, RecordInfo info)
    {
        Collection = c;
        Info = info;
    }

    /// The instance of this collection inside the copy keyed by `key`
    /// of the next enclosing For; chain for deeper nesting. TYPED: the
    /// plain handle's At hands back a bare Collection, and every record
    /// mutation below takes a RecordCollection<T>.
    public RecordCollection<T> At(object key) =>
        new RecordCollection<T>(Collection.At(key), Info);

    public void Insert(Tx tx, object key, T value) =>
        tx.InsertRecordRaw(Collection, key, value, 0, Info.WireFields(value));

    /// Insert under a key the binding authors, and hand the key back.
    /// The contract, in full, is on Tx.InsertFresh.
    public long InsertFresh(Tx tx, T value)
    {
        long key = tx.MintKey(Collection);
        Insert(tx, key, value);
        return key;
    }

    public void Update(Tx tx, object key, T value) =>
        tx.UpdateRecordRaw(Collection, key, value, 0, Info.WireFields(value));

    /// One field's delta by selector: the rest of the record never
    /// travels.
    public void UpdateField<V>(Tx tx, object key, Expression<Func<T, V>> selector, V value) =>
        UpdateField(tx, key, KayaRecords.FieldOf(selector), value);

    /// UpdateField over a pre-resolved token.
    public void UpdateField<V>(Tx tx, object key, Field<V> f, V value)
    {
        object current = null;
        foreach (var entry in tx.Items(Collection))
            if (Equals(entry.Key, key))
                current = entry.Value;
        if (current == null)
            throw new InvalidOperationException($"kaya: update of missing key {key}");
        tx.UpdateFieldRaw(Collection, key, Info.WithField(current, f.Index, value), 0,
            f.Index, Info.EncodeField(f.Index, value));
    }

    /// MoveBefore repositions an entry before another's. Keys, never
    /// indices. A missing key or anchor throws at the call site; moving
    /// an entry before itself is a no-op.
    public void MoveBefore(Tx tx, object key, object anchor) =>
        tx.MoveBefore(Collection, key, anchor);

    /// MoveToEnd repositions an entry at the end of its collection.
    public void MoveToEnd(Tx tx, object key) => tx.MoveToEnd(Collection, key);

    /// MoveToFront repositions an entry at the front of its collection.
    public void MoveToFront(Tx tx, object key) => tx.MoveToFront(Collection, key);

    /// MoveAfter repositions an entry directly after another's.
    public void MoveAfter(Tx tx, object key, object anchor) =>
        tx.MoveAfter(Collection, key, anchor);

    /// A signal the binding recomputes from this collection's entries
    /// after every mutation, written into the same transaction.
    public Signal Derive(Tx tx, Func<List<KeyValuePair<object, T>>, object> compute)
    {
        var s = tx.Signal(compute(Items(tx)));
        tx.RegisterDerived(Collection.Id, t => t.Write(s, compute(Items(t))));
        return s;
    }

    /// Typed field writes with the key spelled once:
    /// todos.Patch(tx, key).Set(x => x.Done, true).Set(x => x.Title, "x").
    /// Each Set records one update_field; a patch is recorded writes,
    /// never a diff.
    public RecordPatch<T> Patch(Tx tx, object key) => new RecordPatch<T>(this, tx, key);

    /// A label bound to the field the selector names.
    public Node Label(Tpl t, Expression<Func<T, string>> selector) =>
        t.Label(KayaRecords.FieldOf(selector));

    /// A checkbox bound to the field the selector names.
    public Node Checkbox(Tpl t, Expression<Func<T, bool>> selector,
        Action<Tx, List<object>, bool> onToggle = null) =>
        t.Checkbox(KayaRecords.FieldOf(selector), onToggle);

    /// An image bound to the byte[] field the selector names.
    public Node Image(Tpl t, Expression<Func<T, byte[]>> selector) =>
        t.Image(KayaRecords.FieldOf(selector));

    /// The typed model: what this guest wrote, in insertion order.
    public List<KeyValuePair<object, T>> Items(Tx tx)
    {
        var items = new List<KeyValuePair<object, T>>();
        foreach (var entry in tx.Items(Collection))
            items.Add(new KeyValuePair<object, T>(entry.Key, (T)entry.Value));
        return items;
    }
}

/// An open patch on one entry; Set chains.
sealed class RecordPatch<T>
{
    readonly RecordCollection<T> c;
    readonly Tx tx;
    readonly object key;

    internal RecordPatch(RecordCollection<T> c, Tx tx, object key)
    {
        this.c = c;
        this.tx = tx;
        this.key = key;
    }

    /// Writes the field the selector names; chainable.
    public RecordPatch<T> Set<V>(Expression<Func<T, V>> selector, V value)
    {
        c.UpdateField(tx, key, selector, value);
        return this;
    }

    /// Writes the field a pre-resolved token names; chainable.
    public RecordPatch<T> Set<V>(Field<V> f, V value)
    {
        c.UpdateField(tx, key, f, value);
        return this;
    }
}

static class KayaRecords
{
    /// Declare a collection of T records; the record type is the
    /// schema. Returns the typed root handle.
    public static RecordCollection<T> CollectionOf<T>(this Tx tx) => Declare<T>(tx);

    /// CollectionOf inside a template body: a nested collection may only
    /// be declared in the template scope, so a table whose rows carry
    /// named fields needs the constructor there too (docs/deferred.md,
    /// the nested-record-collection gap). Tpl.Tx is internal, which is
    /// why nothing outside this assembly can spell it.
    public static RecordCollection<T> CollectionOf<T>(this Tpl t) => Declare<T>(t.Tx);

    static RecordCollection<T> Declare<T>(Tx tx)
    {
        var info = RecordInfo.Of(typeof(T));
        var c = tx.CollectionWithSchema(info.Schema);
        tx.App.Rehydrate[c.Id] = (_, fields, current) => info.FromWire(fields, current);
        return new RecordCollection<T>(c, info);
    }

    /// The field token at a known wire index, for generated code only:
    /// a hand-minted index is unchecked, so hand-written code uses
    /// FieldOf.
    public static Field<V> FieldAt<V>(uint index) => new Field<V>(index);

    public static Field<V> FieldOf<T, V>(Expression<Func<T, V>> selector)
    {
        if (selector.Body is not MemberExpression member)
            throw new ArgumentException("kaya: selector must be a plain property access");
        var name = member.Member.Name;
        var info = RecordInfo.Of(typeof(T));
        var parameters = info.Ctor.GetParameters();
        for (uint wire = 0; wire < info.WireToCtor.Length; wire++)
        {
            var p = parameters[info.WireToCtor[wire]];
            if (string.Equals(p.Name, name, StringComparison.OrdinalIgnoreCase))
                return new Field<V>(wire);
        }
        throw new ArgumentException($"kaya: {typeof(T).Name} has no wire field {name}");
    }
}
