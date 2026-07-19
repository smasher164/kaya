// Records: the struct is the schema. KayaRecord reflects a prototype
// instance with Mirror once at declaration — stored properties of wire
// types (String, Bool, Int64, Double, and Data for blob fields) in
// declaration order become the schema; anything else is guest-only,
// living in the model and never reaching the wire. Mirror cannot construct values, so the one
// hand-written member is init(values:) — a line per field; the schema,
// the outbound conversion, and the field tokens all derive.

import Foundation

/// The generator's marker, the one KayaGen story every language
/// tells: conform a struct or enum to KayaGen and kaya-swift-gen
/// reads the declaration — the shape decides record or sum — and
/// emits the runtime conformance (KayaRecord or KayaSumElement) in a
/// generated extension, beside the factory and the typed surface.
/// Nothing is restated: the declaration is the schema.
protocol KayaGen {}

/// A collection element type. Conform with a prototype (any instance —
/// Mirror needs one to walk) and init(values:); everything else
/// derives. Under KayaGen both members are generated.
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

func wireValue(_ any: Any) -> KayaValue? {
    switch any {
    case let s as String: return .str(s)
    case let b as Bool: return .bool(b)
    case let n as Int64: return .i64(n)
    case let x as Double: return .f64(x)
    default: return nil
    }
}

/// The outbound encoder wireValue is not: a blob field (Data) registers
/// its bytes now, at encode time — handles are single-submit, so every
/// write that carries a blob field re-registers (insert, update, and
/// update_field alike: one copy into core memory per write; the model
/// keeps the guest's own bytes).
func kayaEncode(_ any: Any) -> KayaValue? {
    if let data = any as? Data { return .blob(kayaRegisterBlob(data)) }
    return wireValue(any)
}

extension KayaRecord {
    /// The wire schema: one type tag per wire-typed stored property,
    /// declaration order. A Data property is a blob field: the bytes
    /// travel out of band, the record slot carries the handle.
    static var kayaSchema: [UInt32] {
        Mirror(reflecting: prototype).children.compactMap { child in
            if child.value is Data { return UInt32(KAYA_VALUE_BLOB) }
            switch wireValue(child.value) {
            case .some(.str): return UInt32(KAYA_VALUE_STR)
            case .some(.bool): return UInt32(KAYA_VALUE_BOOL)
            case .some(.i64): return UInt32(KAYA_VALUE_I64)
            case .some(.f64): return UInt32(KAYA_VALUE_F64)
            default: return nil
            }
        }
    }

    /// The record's wire fields, in schema order. Encoding registers
    /// blob fields' bytes (see kayaEncode) — call this to ship a
    /// record, never to inspect one.
    var kayaValues: [KayaValue] {
        Mirror(reflecting: self).children.compactMap { kayaEncode($0.value) }
    }

    /// The pure projection field() diffs: like kayaValues but a blob
    /// field maps to its byte count — probe resolution must not mint
    /// handles (two registrations of the same bytes get distinct
    /// handles, which would break the diff), and appending a probe
    /// byte changes the count, so the diff still finds the field.
    private var kayaProbeValues: [KayaValue] {
        Mirror(reflecting: self).children.compactMap { child in
            if let data = child.value as? Data { return .blob(UInt64(data.count)) }
            return wireValue(child.value)
        }
    }

    /// The field token for the field a key path selects:
    /// Todo.field(\.done). The name and type are the struct's own,
    /// compiler-checked — no strings restating the declaration (the
    /// SwiftUI shape). Resolution writes a sentinel through the key
    /// path on a probe copy and diffs the wire values — once per key
    /// path: handlers resolve per event, so the Mirror walks must not
    /// re-run there. Key paths of distinct record types are distinct
    /// keys, so one cache serves all.
    static func field<V>(_ keyPath: WritableKeyPath<Self, V>) -> KayaField<V> {
        if let cached = kayaFieldIndexes[keyPath] {
            return KayaField<V>(index: cached)
        }
        var probe = prototype
        switch probe[keyPath: keyPath] {
        case let s as String: probe[keyPath: keyPath] = (s + "\u{0}kaya") as! V
        case let b as Bool: probe[keyPath: keyPath] = (!b) as! V
        case let n as Int64: probe[keyPath: keyPath] = (n &+ 0x5eed) as! V
        case let x as Double: probe[keyPath: keyPath] = (x.isNaN ? 0 : x + 1) as! V
        case let d as Data: probe[keyPath: keyPath] = (d + Data([0x6b])) as! V
        default: preconditionFailure("kaya: \(V.self) is not a wire type")
        }
        for (i, (a, b)) in zip(prototype.kayaProbeValues, probe.kayaProbeValues).enumerated()
        where a != b {
            kayaFieldIndexes[keyPath] = UInt32(i)
            return KayaField<V>(index: UInt32(i))
        }
        preconditionFailure("kaya: key path does not select a wire field of \(Self.self)")
    }
}

/// Key path -> wire index, all record types together (key paths carry
/// their root type, so entries cannot collide). App-thread only, like
/// every guest-side structure.
private var kayaFieldIndexes: [AnyKeyPath: UInt32] = [:]

/// A collection whose entries are T records; the plain handle rides
/// along for forEach and at.
struct KayaRecordCollection<T: KayaRecord> {
    let collection: KayaCollection

    func insert(_ tx: KayaAppTx, _ key: KayaValue, _ value: T) {
        tx.insertRecordRaw(collection, key, value, 0, value.kayaValues)
    }

    func update(_ tx: KayaAppTx, _ key: KayaValue, _ value: T) {
        tx.updateRecordRaw(collection, key, value, 0, value.kayaValues)
    }

    /// One field's delta by key path: the rest of the record never
    /// travels. The key path is the field reference — no token to
    /// declare — and it writes the model entry in place, so a blob
    /// field's bytes stay native (the wire carries only the handle
    /// kayaEncode registers at encode time; handles are single-submit,
    /// so every update_field that carries a blob re-registers).
    func updateField<V>(
        _ tx: KayaAppTx, _ key: KayaValue, _ keyPath: WritableKeyPath<T, V>, _ value: V
    ) {
        guard var current = tx.recordEntries(collection).first(where: { $0.key == key })?.value as? T
        else {
            preconditionFailure("kaya: update of missing key \(key)")
        }
        current[keyPath: keyPath] = value
        guard let wire = kayaEncode(value) else {
            preconditionFailure("kaya: \(V.self) is not a wire type")
        }
        tx.updateFieldRaw(collection, key, current, 0, T.field(keyPath).index, wire)
    }

    /// updateField over a pre-resolved token. This form rebuilds the
    /// model entry from wire values, which cannot resurrect a blob
    /// field's bytes — a record with a blob field patches through the
    /// key-path form, and the guard holds that structurally.
    func updateField<V>(_ tx: KayaAppTx, _ key: KayaValue, _ f: KayaField<V>, _ value: V) {
        precondition(
            !T.kayaSchema.contains(UInt32(KAYA_VALUE_BLOB)),
            "kaya: token updateField cannot rebuild \(T.self)'s blob bytes — patch through the key-path form")
        guard let current = tx.recordEntries(collection).first(where: { $0.key == key })?.value as? T
        else {
            preconditionFailure("kaya: update of missing key \(key)")
        }
        var fields = current.kayaValues
        guard let wire = wireValue(value) else {
            preconditionFailure("kaya: \(V.self) is not a wire type")
        }
        fields[Int(f.index)] = wire
        tx.updateFieldRaw(collection, key, T(values: fields), 0, f.index, wire)
    }

    /// Repositions an entry before another's: order is collection
    /// data, so the model reorders and the wire carries the same
    /// keys-only delta. Keys, never indices. A missing key or anchor
    /// traps at the call site — the same check the scene makes; moving
    /// an entry before itself is a no-op.
    func moveBefore(_ tx: KayaAppTx, _ key: KayaValue, _ anchor: KayaValue) {
        tx.moveBefore(collection, key, anchor)
    }

    /// Repositions an entry at the end of its collection.
    func moveToEnd(_ tx: KayaAppTx, _ key: KayaValue) {
        tx.moveToEnd(collection, key)
    }

    /// Repositions an entry at the front: sugar for moveBefore the
    /// current first key, lowering to the same wire op.
    func moveToFront(_ tx: KayaAppTx, _ key: KayaValue) {
        tx.moveToFront(collection, key)
    }

    /// Repositions an entry directly after another's: sugar for
    /// moveBefore the anchor's successor (moveToEnd when the anchor is
    /// last), lowering to the same wire op.
    func moveAfter(_ tx: KayaAppTx, _ key: KayaValue, _ anchor: KayaValue) {
        tx.moveAfter(collection, key, anchor)
    }

    /// A label bound to the field the key path selects.
    func label(_ t: KayaTpl, _ keyPath: WritableKeyPath<T, String>) -> KayaNodeHandle {
        t.label(T.field(keyPath))
    }

    /// A checkbox bound to the field the key path selects, with its
    /// toggle handler co-located.
    func checkbox(
        _ t: KayaTpl, _ keyPath: WritableKeyPath<T, Bool>,
        onToggle: ((KayaAppTx, [KayaValue], Bool) throws -> Void)? = nil
    ) -> KayaNodeHandle {
        t.checkbox(T.field(keyPath), onToggle: onToggle)
    }

    /// The typed model: what this guest wrote, in insertion order.
    func items(_ tx: KayaAppTx) -> [(key: KayaValue, value: T)] {
        tx.recordEntries(collection).map { (key: $0.key, value: $0.value as! T) }
    }

    /// A signal the binding recomputes from this collection's entries
    /// after every mutation, written into the same transaction — the
    /// items-left label with no handler remembering to update it. The
    /// closure is pure presentation: entries in, one value out; the
    /// core sees an ordinary signal.
    func derive(
        _ tx: KayaAppTx, _ compute: @escaping ([(key: KayaValue, value: T)]) -> KayaValue
    ) -> KayaSignal {
        let s = tx.signal(compute(items(tx)))
        tx.pendingDerived.append((collection.id, { t in
            t.write(s, compute(self.items(t)))
        }))
        return s
    }

    /// Typed field writes with the key spelled once:
    /// todos.patch(tx, key).set(\.done, true).set(\.title, "x").
    /// Each set records one update_field — a patch is recorded writes,
    /// never a diff.
    func patch(_ tx: KayaAppTx, _ key: KayaValue) -> KayaRecordPatch<T> {
        KayaRecordPatch(c: self, tx: tx, key: key)
    }
}

/// An open patch on one entry; set chains.
struct KayaRecordPatch<T: KayaRecord> {
    let c: KayaRecordCollection<T>
    let tx: KayaAppTx
    let key: KayaValue

    /// Writes the field the key path selects; chainable.
    @discardableResult
    func set<V>(_ keyPath: WritableKeyPath<T, V>, _ value: V) -> KayaRecordPatch<T> {
        c.updateField(tx, key, keyPath, value)
        return self
    }
}

extension KayaAppTx {
    /// Declare a collection of T records; the struct is the schema.
    /// Returns the typed root handle.
    func collection<T: KayaRecord>(of _: T.Type) -> KayaRecordCollection<T> {
        KayaRecordCollection(collection: collectionWithSchema(T.kayaSchema))
    }
}
