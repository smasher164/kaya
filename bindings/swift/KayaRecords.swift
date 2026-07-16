// Records: the struct is the schema. KayaRecord reflects a prototype
// instance with Mirror once at declaration — stored properties of wire
// types (String, Bool, Int64, Double) in declaration order become the
// schema; anything else is guest-only, living in the model and never
// reaching the wire. Mirror cannot construct values, so the one
// hand-written member is init(values:) — a line per field; the schema,
// the outbound conversion, and the field tokens all derive.

import Foundation

/// A collection element type. Conform with a prototype (any instance —
/// Mirror needs one to walk) and init(values:); everything else
/// derives.
protocol KayaRecord {
    static var prototype: Self { get }
    init(values: [KayaValue])
}

/// A typed projection: one field of a record type, by wire position.
/// The type parameter pins the Swift type, so bindCheckedField rejects
/// a KayaField<String> at compile time.
struct KayaField<V> {
    let index: UInt32
}

private func wireValue(_ any: Any) -> KayaValue? {
    switch any {
    case let s as String: return .str(s)
    case let b as Bool: return .bool(b)
    case let n as Int64: return .i64(n)
    case let x as Double: return .f64(x)
    default: return nil
    }
}

extension KayaRecord {
    /// The wire schema: one type tag per wire-typed stored property,
    /// declaration order.
    static var kayaSchema: [UInt32] {
        Mirror(reflecting: prototype).children.compactMap { child in
            switch wireValue(child.value) {
            case .some(.str): return UInt32(KAYA_VALUE_STR)
            case .some(.bool): return UInt32(KAYA_VALUE_BOOL)
            case .some(.i64): return UInt32(KAYA_VALUE_I64)
            case .some(.f64): return UInt32(KAYA_VALUE_F64)
            default: return nil
            }
        }
    }

    /// The record's wire fields, in schema order.
    var kayaValues: [KayaValue] {
        Mirror(reflecting: self).children.compactMap { wireValue($0.value) }
    }

    /// The field token for the property `name`, checked against V at
    /// declaration time (a wrong name or type traps at startup, not in
    /// a handler).
    static func field<V>(_ name: String, _: V.Type) -> KayaField<V> {
        var index: UInt32 = 0
        for child in Mirror(reflecting: prototype).children {
            guard let value = wireValue(child.value) else { continue }
            if child.label == name {
                precondition(
                    type(of: child.value) == V.self,
                    "kaya: \(Self.self).\(name) is \(type(of: child.value)), not \(V.self)")
                _ = value
                return KayaField<V>(index: index)
            }
            index += 1
        }
        preconditionFailure("kaya: \(Self.self) has no wire field \(name)")
    }
}

/// A collection whose entries are T records; the plain handle rides
/// along for forEach and at.
struct KayaRecordCollection<T: KayaRecord> {
    let collection: KayaCollection

    func insert(_ tx: KayaAppTx, _ key: KayaValue, _ value: T) {
        tx.insertRecordRaw(collection, key, value, value.kayaValues)
    }

    func update(_ tx: KayaAppTx, _ key: KayaValue, _ value: T) {
        tx.updateRecordRaw(collection, key, value, value.kayaValues)
    }

    /// One field's delta: the rest of the record never travels; the
    /// model's copy is rebuilt from its updated wire fields.
    func updateField<V>(_ tx: KayaAppTx, _ key: KayaValue, _ f: KayaField<V>, _ value: V) {
        guard let current = tx.recordEntries(collection).first(where: { $0.key == key })?.value as? T
        else {
            preconditionFailure("kaya: update of missing key \(key)")
        }
        var fields = current.kayaValues
        guard let wire = wireValue(value) else {
            preconditionFailure("kaya: \(V.self) is not a wire type")
        }
        fields[Int(f.index)] = wire
        tx.updateFieldRaw(collection, key, T(values: fields), f.index, wire)
    }

    /// The typed model: what this guest wrote, in insertion order.
    func items(_ tx: KayaAppTx) -> [(key: KayaValue, value: T)] {
        tx.recordEntries(collection).map { (key: $0.key, value: $0.value as! T) }
    }
}

extension KayaAppTx {
    /// Declare a collection of T records; the struct is the schema.
    /// Returns the typed root handle.
    func collection<T: KayaRecord>(of _: T.Type) -> KayaRecordCollection<T> {
        KayaRecordCollection(collection: collectionWithSchema(T.kayaSchema))
    }
}
