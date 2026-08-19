// Sum-typed collections: the enum is the sum, its cases the
// constructors. Mirror walks one prototype per case, and
// init(variant:values:) is the one hand-written member. Elimination is
// Swift-shaped where the guest holds the value; the template takes a
// product of arms checked complete at declaration, with the scene as the
// second check. Mutation is WITNESSED: a field write names the
// constructor the caller matched, and the model refuses a drifted
// entry.

import Foundation

/// A sum element type. Conform with one prototype per constructor (in
/// declaration order) and init(variant:values:); everything else
/// derives.
protocol KayaSumElement {
    static var prototypes: [Self] { get }
    init(variant: UInt32, values: [KayaValue])
}

extension KayaSumElement {
    /// The case's name, from Mirror: the discriminant's identity.
    fileprivate var kayaCaseName: String {
        Mirror(reflecting: self).children.first?.label ?? String(describing: self)
    }

    /// The case's wire fields, in declaration order: the associated
    /// tuple's wire-typed members (or the single associated value).
    var kayaSumValues: [KayaValue] {
        guard let payload = Mirror(reflecting: self).children.first?.value else {
            return [] // a payload-less constructor
        }
        let inner = Mirror(reflecting: payload)
        if inner.children.isEmpty {
            return wireValue(payload).map { [$0] } ?? []
        }
        return inner.children.compactMap { wireValue($0.value) }
    }

    /// The discriminant this value holds.
    var kayaVariant: UInt32 {
        let name = kayaCaseName
        for (i, prototype) in Self.prototypes.enumerated()
        where prototype.kayaCaseName == name {
            return UInt32(i)
        }
        preconditionFailure("kaya: \(name) is not in \(Self.self).prototypes")
    }

    /// One schema per constructor, from the prototypes.
    static var kayaVariantSchemas: [[UInt32]] {
        prototypes.map { p in
            p.kayaSumValues.map { v in
                switch v {
                case .str: return UInt32(KAYA_VALUE_STR)
                case .bool: return UInt32(KAYA_VALUE_BOOL)
                case .i64: return UInt32(KAYA_VALUE_I64)
                case .f64: return UInt32(KAYA_VALUE_F64)
                case .blob: return UInt32(KAYA_VALUE_BLOB)
                }
            }
        }
    }

    /// The associated-value labels of one constructor, for field
    /// resolution inside its case arm.
    fileprivate static func kayaLabels(variant: UInt32) -> [String] {
        let prototype = prototypes[Int(variant)]
        guard let payload = Mirror(reflecting: prototype).children.first?.value else {
            return []
        }
        let inner = Mirror(reflecting: payload)
        if inner.children.isEmpty {
            return [Mirror(reflecting: prototype).children.first?.label ?? ""]
        }
        var labels: [String] = []
        for child in inner.children where wireValue(child.value) != nil {
            labels.append(child.label ?? "")
        }
        return labels
    }
}

/// A collection whose entries are one of T's constructors, keyed as
/// usual; the plain handle rides along for the template surface.
struct KayaSumCollection<T: KayaSumElement> {
    let collection: KayaCollection

    /// Insert witnesses the value's own constructor onto the wire.
    func insert(_ tx: KayaAppTx, _ key: KayaValue, _ value: T) {
        tx.insertRecordRaw(collection, key, value, value.kayaVariant, value.kayaSumValues)
    }

    /// Insert under a key the binding authors, and hand the key back.
    @discardableResult
    func insertFresh(_ tx: KayaAppTx, _ value: T) -> Int64 {
        tx.insertRecordFresh(collection, value, value.kayaVariant, value.kayaSumValues)
    }

    /// Update replaces a record wholesale; a different constructor
    /// than the entry's current one restamps its copy in place.
    func update(_ tx: KayaAppTx, _ key: KayaValue, _ value: T) {
        tx.updateRecordRaw(collection, key, value, value.kayaVariant, value.kayaSumValues)
    }

    /// Drop an entry, taking its stamped copy and every collection
    /// instance inside it with it.
    func remove(_ tx: KayaAppTx, _ key: KayaValue) {
        tx.remove(collection, key)
    }

    /// The typed model, in insertion order; `if case` / `switch`
    /// eliminates the values.
    func items(_ tx: KayaAppTx) -> [(key: KayaValue, value: T)] {
        tx.recordEntries(collection).map { (key: $0.key, value: $0.value as! T) }
    }

    /// The entry's current value — the scrutinee for the `if case`
    /// that precedes a patch — or nil for a missing key.
    func get(_ tx: KayaAppTx, _ key: KayaValue) -> T? {
        tx.recordEntries(collection).first(where: { $0.key == key })?.value as? T
    }

    /// The witnessed field write: `of` is a prototype of the constructor the
    /// caller just matched, the field named by its associated-value label.
    func updateField(
        _ tx: KayaAppTx, _ key: KayaValue, of prototype: T, _ fieldName: String,
        _ value: KayaValue
    ) {
        let variant = prototype.kayaVariant
        guard let current = get(tx, key) else {
            preconditionFailure("kaya: update of missing key \(key)")
        }
        precondition(
            current.kayaVariant == variant,
            "kaya: update_field witnessed \(prototype.kayaCaseName) but \(key) holds \(current.kayaCaseName)")
        let labels = T.kayaLabels(variant: variant)
        guard let index = labels.firstIndex(of: fieldName) else {
            preconditionFailure(
                "kaya: \(prototype.kayaCaseName) has no wire field \(fieldName)")
        }
        var fields = current.kayaSumValues
        fields[index] = value
        tx.updateFieldRaw(
            collection, key, T(variant: variant, values: fields), variant,
            UInt32(index), value)
    }

    /// The witnessed field write, token form: the generated field
    /// tokens (kaya-swift-gen) carry the index and the wire type, so
    /// nothing resolves by label at run time.
    func updateField<F>(
        _ tx: KayaAppTx, _ key: KayaValue, of prototype: T, _ field: KayaField<F>,
        _ value: KayaValue
    ) {
        let variant = prototype.kayaVariant
        guard let current = get(tx, key) else {
            preconditionFailure("kaya: update of missing key \(key)")
        }
        precondition(
            current.kayaVariant == variant,
            "kaya: update_field witnessed \(prototype.kayaCaseName) but \(key) holds \(current.kayaCaseName)")
        var fields = current.kayaSumValues
        fields[Int(field.index)] = value
        tx.updateFieldRaw(
            collection, key, T(variant: variant, values: fields), variant,
            field.index, value)
    }

    /// The collection-derived signal, over the sum's entries.
    func derive(
        _ tx: KayaAppTx, _ compute: @escaping ([(key: KayaValue, value: T)]) -> KayaValue
    ) -> KayaSignal {
        let s = tx.signal(compute(items(tx)))
        tx.pendingDerived.append((collection.id, { t in
            t.write(s, compute(self.items(t)))
        }))
        return s
    }

    /// One arm of the template eliminator: `of` is the constructor's
    /// prototype, the body its blueprint author.
    func arm(
        _ prototype: T, _ body: @escaping (KayaTpl, KayaSumCase<T>) -> Void
    ) -> KayaSumArm<T> {
        let variant = prototype.kayaVariant
        return KayaSumArm(variant: variant) { t in
            body(t, KayaSumCase(variant: variant, labels: T.kayaLabels(variant: variant)))
        }
    }
}

/// One declared arm: the constructor's discriminant plus its blueprint
/// author.
struct KayaSumArm<T: KayaSumElement> {
    let variant: UInt32
    let body: (KayaTpl) -> Void
}

/// The arm's refined vocabulary: field names resolve against the
/// constructor's associated-value labels, loudly, at declaration.
struct KayaSumCase<T: KayaSumElement> {
    let variant: UInt32
    let labels: [String]

    private func index(of fieldName: String) -> UInt32 {
        guard let index = labels.firstIndex(of: fieldName) else {
            preconditionFailure("kaya: no wire field \(fieldName) in this constructor")
        }
        return UInt32(index)
    }

    /// A label bound to the field named by its associated-value label.
    func label(_ t: KayaTpl, _ fieldName: String) -> KayaNodeHandle {
        t.label(KayaField<String>(index: index(of: fieldName)))
    }

    /// A checkbox bound to the named field, with its toggle handler
    /// co-located (stamped keys first).
    func checkbox(
        _ t: KayaTpl, _ fieldName: String,
        onToggle: ((KayaAppTx, [KayaValue], Bool) throws -> Void)? = nil
    ) -> KayaNodeHandle {
        t.checkbox(KayaField<Bool>(index: index(of: fieldName)), onToggle: onToggle)
    }
}

extension KayaAppTx {
    /// Declare a sum collection: T's prototypes are its constructors, in
    /// order.
    func sumCollection<T: KayaSumElement>(of type: T.Type) -> KayaSumCollection<T> {
        let schemas = T.kayaVariantSchemas
        precondition(
            schemas.count >= 2,
            "kaya: a sum needs two constructors or more (collection(of:) declares a record)")
        let c = collectionWithVariants(schemas)
        // The record factory's decoder, variant-aware: an undo's
        // payload names the constructor it restored (see
        // KayaApp.registerDecoder).
        app.registerDecoder(c.id) { variant, values in T(variant: variant, values: values) }
        return KayaSumCollection(collection: c)
    }

    /// The template eliminator: a product of arms, one per constructor,
    /// handed over whole.
    func eachSum<T: KayaSumElement>(
        _ c: KayaSumCollection<T>, arms: [KayaSumArm<T>]
    ) -> KayaWidget {
        let count = T.prototypes.count
        precondition(
            arms.count == count,
            "kaya: the eliminator needs \(count) arms, got \(arms.count)")
        var seen = [Bool](repeating: false, count: count)
        for arm in arms {
            precondition(!seen[Int(arm.variant)], "kaya: two arms for one constructor")
            seen[Int(arm.variant)] = true
        }
        return each(c.collection) { t in
            for arm in arms {
                emitVariantCase(arm.variant)
                arm.body(t)
            }
        }
    }
}
