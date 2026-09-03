// Records: the struct is the schema. Mirror walks a prototype once at
// declaration — stored properties of wire types in declaration order —
// and cannot CONSTRUCT, so init(values:) is the one hand-written member.

import Foundation

/// The generator's marker: kaya-swift-gen reads the declaration — the
/// shape decides record or sum — and emits the runtime conformance.
protocol KayaGen {}

/// A collection element type. Conform with a prototype (any instance — Mirror
/// needs one to walk) and init(values:); everything else derives.
protocol KayaRecord {
    static var prototype: Self { get }
    init(values: [KayaValue])
}

/// A typed projection: one field of a record type, by wire position.
struct KayaField<V> {
    let index: UInt32
}

extension KayaField where V == String {
    /// THE WHOLE ELEMENT OF A SCALAR COLLECTION, as a field token: a scalar
    /// collection has no record, so its element IS the value.
    static var element: KayaField<String> { KayaField<String>(index: 0) }
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
/// its bytes now, at encode time. Handles are SINGLE-SUBMIT, so every
/// write that carries a blob field re-registers.
func kayaEncode(_ any: Any) -> KayaValue? {
    if let data = any as? Data { return .blob(kayaRegisterBlob(data)) }
    return wireValue(any)
}

extension KayaRecord {
    /// The wire schema: one type tag per wire-typed stored property,
    /// declaration order.
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

    /// The record's wire fields, in schema order. Encoding REGISTERS
    /// blob fields' bytes, so call this to ship a record, never to
    /// inspect one.
    var kayaValues: [KayaValue] {
        Mirror(reflecting: self).children.compactMap { kayaEncode($0.value) }
    }

    /// The pure projection field() diffs: like kayaValues but a blob
    /// field maps to its byte count. Probe resolution MUST NOT MINT
    /// HANDLES — two registrations of the same bytes get distinct
    /// handles, which would break the diff.
    private var kayaProbeValues: [KayaValue] {
        Mirror(reflecting: self).children.compactMap { child in
            if let data = child.value as? Data { return .blob(UInt64(data.count)) }
            return wireValue(child.value)
        }
    }

    /// The field token for the field a key path selects. Resolution
    /// writes a sentinel through the key path on a probe copy and diffs
    /// the wire values — CACHED, because handlers resolve per event and
    /// the Mirror walks must not re-run there.
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

/// Key path -> wire index, all record types together. APP-THREAD ONLY,
/// like every guest-side structure.
private var kayaFieldIndexes: [AnyKeyPath: UInt32] = [:]

/// A collection whose entries are T records; the plain handle rides
/// along for forEach and at.
struct KayaRecordCollection<T: KayaRecord> {
    let collection: KayaCollection

    /// The instance of this collection inside the copy keyed by `key` of
    /// the next enclosing For; chain for deeper nesting. TYPED: the
    /// plain handle's `at` hands back a bare KayaCollection, and every
    /// record mutation below takes this one.
    func at(_ key: KayaValue) -> KayaRecordCollection<T> {
        KayaRecordCollection(collection: collection.at(key))
    }

    func insert(_ tx: KayaAppTx, _ key: KayaValue, _ value: T) {
        tx.insertRecordRaw(collection, key, value, 0, value.kayaValues)
    }

    /// Insert under a key the binding authors, and hand the key back.
    @discardableResult
    func insertFresh(_ tx: KayaAppTx, _ value: T) -> Int64 {
        tx.insertRecordFresh(collection, value, 0, value.kayaValues)
    }

    func update(_ tx: KayaAppTx, _ key: KayaValue, _ value: T) {
        tx.updateRecordRaw(collection, key, value, 0, value.kayaValues)
    }

    /// Drop an entry, taking its stamped copy and every collection
    /// instance inside it with it.
    func remove(_ tx: KayaAppTx, _ key: KayaValue) {
        tx.remove(collection, key)
    }

    /// One field's delta by key path: the rest of the record never
    /// travels. It writes the model entry IN PLACE, so a blob field's
    /// bytes stay native and the wire carries only the handle.
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

    /// updateField over a pre-resolved token. This form REBUILDS the
    /// model entry from wire values, which cannot resurrect a blob
    /// field's bytes — a record with one patches through the key-path
    /// form, and the guard below holds that.
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

    /// Repositions an entry before another's; the wire carries a keys-only
    /// delta. KEYS, NEVER INDICES.
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

    /// A signal the binding recomputes from this collection's entries after
    /// every mutation, written into the same transaction.
    func derive(
        _ tx: KayaAppTx, _ compute: @escaping ([(key: KayaValue, value: T)]) -> KayaValue
    ) -> KayaSignal {
        let s = tx.signal(compute(items(tx)))
        tx.pendingDerived.append((collection.id, { t in
            t.write(s, compute(self.items(t)))
        }))
        return s
    }

    /// Typed field writes with the key spelled once: todos.patch(tx,
    /// key).set(\.done, true).
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
    func collection<T: KayaRecord>(of _: T.Type) -> KayaRecordCollection<T> {
        let c = collectionWithSchema(T.kayaSchema)
        // How an undo rebuilds this collection's model entries: its
        // payload carries wire fields, and this declaration is the ONLY
        // place T is known.
        app.registerDecoder(c.id) { _, values in T(values: values) }
        return KayaRecordCollection(collection: c)
    }
}
