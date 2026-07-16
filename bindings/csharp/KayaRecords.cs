// Records: the record type is the schema. CollectionOf reflects over
// T's primary constructor once at declaration — parameters of wire
// types (string, bool, long, double) in declaration order become the
// schema; anything else is guest-only, living in the model and never
// reaching the wire. One declaration drives the schema, the
// conversions, and the field tokens, so none can drift. C# records are
// immutable, so a field update reconstructs the model's copy through
// the same constructor.

using System;
using System.Collections.Generic;
using System.Reflection;

/// A typed projection: one field of a record type, by wire position.
/// The type parameter pins the C# type, so BindCheckedField rejects a
/// Field<string> at compile time.
sealed class Field<V>
{
    internal readonly uint Index;

    internal Field(uint index) => Index = index;
}

sealed class RecordInfo
{
    internal uint[] Schema;
    // Wire field -> primary-constructor parameter position, and one
    // getter per constructor parameter (reconstruction needs them all,
    // guest-only included).
    internal int[] WireToCtor;
    internal Func<object, object>[] Getters;
    internal ConstructorInfo Ctor;

    static uint? WireTag(Type t) =>
        t == typeof(string) ? KayaWire.ValueStr
        : t == typeof(bool) ? KayaWire.ValueBool
        : t == typeof(long) ? KayaWire.ValueI64
        : t == typeof(double) ? KayaWire.ValueF64
        : (uint?)null;

    internal static RecordInfo Of(Type t)
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
            fields[i] = Getters[WireToCtor[i]](record);
        return fields;
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

    public void Insert(Tx tx, object key, T value) =>
        tx.InsertRecordRaw(Collection, key, value, Info.WireFields(value));

    public void Update(Tx tx, object key, T value) =>
        tx.UpdateRecordRaw(Collection, key, value, Info.WireFields(value));

    /// One field's delta: the rest of the record never travels; the
    /// model's copy is reconstructed with the new value.
    public void UpdateField<V>(Tx tx, object key, Field<V> f, V value)
    {
        object current = null;
        foreach (var entry in tx.Items(Collection))
            if (Equals(entry.Key, key))
                current = entry.Value;
        if (current == null)
            throw new InvalidOperationException($"kaya: update of missing key {key}");
        tx.UpdateFieldRaw(Collection, key, Info.WithField(current, f.Index, value), f.Index, value);
    }

    /// The typed model: what this guest wrote, in insertion order.
    public List<KeyValuePair<object, T>> Items(Tx tx)
    {
        var items = new List<KeyValuePair<object, T>>();
        foreach (var entry in tx.Items(Collection))
            items.Add(new KeyValuePair<object, T>(entry.Key, (T)entry.Value));
        return items;
    }
}

static class KayaRecords
{
    /// Declare a collection of T records; the record type is the
    /// schema. Returns the typed root handle.
    public static RecordCollection<T> CollectionOf<T>(this Tx tx)
    {
        var info = RecordInfo.Of(typeof(T));
        return new RecordCollection<T>(tx.CollectionWithSchema(info.Schema), info);
    }

    /// The field token for T's field `name`, checked against V at
    /// declaration time (a wrong name or type throws at startup, not
    /// in a handler).
    public static Field<V> FieldOf<T, V>(string name)
    {
        var info = RecordInfo.Of(typeof(T));
        var parameters = info.Ctor.GetParameters();
        for (uint wire = 0; wire < info.WireToCtor.Length; wire++)
        {
            var p = parameters[info.WireToCtor[wire]];
            if (string.Equals(p.Name, name, StringComparison.OrdinalIgnoreCase))
            {
                if (p.ParameterType != typeof(V))
                    throw new ArgumentException(
                        $"kaya: {typeof(T).Name}.{name} is {p.ParameterType.Name}, not {typeof(V).Name}");
                return new Field<V>(wire);
            }
        }
        throw new ArgumentException($"kaya: {typeof(T).Name} has no wire field {name}");
    }
}
