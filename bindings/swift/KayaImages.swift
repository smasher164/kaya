// Images from the network (docs/network-images-plan.md): the phase (N2), the
// conditional write (N7), the two row handlers (N8) and N12's helper, whose
// reference is crates/kaya/src/app/images.rs. Its fetches run in tasks on
// KayaAppActor, so every completion resumes on the app thread.

internal import CKaya
import Foundation

/// What an image shows while its bytes are the app's to fetch: its picture,
/// the loading look, or the failed look. Settable, bindable to a signal, and
/// a row field.
public enum KayaImagePhase: Int64, Sendable {
    case shown = 0
    case loading = 1
    case failed = 2
}

/// A row's phase as the wire carries it.
public func kayaImagePhase(packed: Int64) -> KayaImagePhase {
    guard let phase = KayaImagePhase(rawValue: packed) else {
        preconditionFailure("kaya: an image phase field holds \(packed), which is no phase")
    }
    return phase
}

extension KayaValue {
    /// An image phase on the wire — what a phase signal carries.
    public static func phase(_ p: KayaImagePhase) -> KayaValue { .i64(p.rawValue) }

    /// Encoded image bytes for a signal of bytes: registered now, consumed by
    /// the submit of the transaction that writes them.
    public static func data(_ d: Data) -> KayaValue { .blob(kayaRegisterBlob(d)) }
}

/// The two row handlers and the helpers' feeds, by template node.
final class KayaImageState {
    var needed: [UInt64: (KayaAppTx, [KayaValue]) throws -> Void] = [:]
    var released: [UInt64: (KayaAppTx, [KayaValue]) throws -> Void] = [:]
    var feeds: [UInt64: [(needed: (KayaAppTx, [KayaValue]) -> Void,
                          released: (KayaAppTx, [KayaValue]) -> Void)]] = [:]
}

extension KayaApp {
    /// A stamped image realized `.loading` with no source: the row's bytes
    /// are wanted now, about a screen before it is seen. Once per row until
    /// onReleased fires for it (N8). The keys are the copy's, outermost first.
    public func onNeeded(
        _ image: KayaNodeHandle, _ handler: @escaping (KayaAppTx, [KayaValue]) throws -> Void
    ) {
        images.needed[image.id] = handler
    }

    /// The last realized copy of a row's image was torn down while still
    /// loading: its fetch may stop.
    public func onReleased(
        _ image: KayaNodeHandle, _ handler: @escaping (KayaAppTx, [KayaValue]) throws -> Void
    ) {
        images.released[image.id] = handler
    }

    /// The ring loop's arm for the two N8 occurrences: the helpers' feeds,
    /// then the app's handler, in one transaction, so a later onNeeded never
    /// shadows a helper.
    func imageOccurrence(
        _ kind: UInt16, _ id: UInt64, _ keys: [KayaValue],
        _ run: (@escaping (KayaAppTx) throws -> Void) -> Void
    ) -> Bool {
        let needed: Bool
        switch kind {
        case UInt16(KAYA_OCCURRENCE_IMAGE_NEEDED): needed = true
        case UInt16(KAYA_OCCURRENCE_IMAGE_RELEASED): needed = false
        default: return false
        }
        let feeds = images.feeds[id] ?? []
        let handler = needed ? images.needed[id] : images.released[id]
        if feeds.isEmpty && handler == nil { return true }
        run { tx in
            for feed in feeds { (needed ? feed.needed : feed.released)(tx, keys) }
            try handler?(tx, keys)
        }
        return true
    }
}

extension KayaAppTx {
    /// An image's phase: `.loading` keeps any source it has on screen,
    /// `.failed` draws the failed look whatever the source.
    public func setPhase(_ w: KayaWidget, _ phase: KayaImagePhase) {
        tx.setPhase(w.id, phase.rawValue)
    }

    public func setPhase(_ w: KayaWidget, _ s: KayaSignal) {
        tx.bindPhase(w.id, s.id)
    }
}

/// The gathered changes of one conditional write; `set` chains.
public final class KayaRecordPatchIf<T: KayaRecord> {
    var changes: [(index: UInt32, wire: KayaValue, apply: (inout T) -> Void)] = []

    /// The field the key path selects takes `value` if the guard holds.
    @discardableResult
    public func set<V>(_ keyPath: WritableKeyPath<T, V>, _ value: V) -> KayaRecordPatchIf<T> {
        guard let wire = kayaEncode(value) else {
            preconditionFailure("kaya: \(V.self) is not a wire type")
        }
        changes.append((T.field(keyPath).index, wire, { $0[keyPath: keyPath] = value }))
        return self
    }
}

/// Two field values equal as the wire would carry them; bytes by content.
func kayaSameWire(_ a: Any, _ b: Any) -> Bool {
    if let x = a as? Data, let y = b as? Data { return x == y }
    if a is Data || b is Data { return false }
    guard let x = wireValue(a), let y = wireValue(b) else { return false }
    return x == y
}

extension KayaRecordCollection {
    /// The patch made only while the entry at `key` exists and its `guard`
    /// field still holds `expected`; otherwise nothing, and no trap
    /// (docs/network-images-plan.md N7). ONE record, so the core checks the
    /// guard against the model it commits to; the mirror takes the writes
    /// under the same guard. Answers whether the guard held here.
    @discardableResult
    public func patchIf<G>(
        _ tx: KayaAppTx, _ key: KayaValue, _ guard: WritableKeyPath<T, G>, equals expected: G,
        _ changes: (KayaRecordPatchIf<T>) -> Void
    ) -> Bool {
        let p = KayaRecordPatchIf<T>()
        changes(p)
        guard let guardWire = kayaEncode(expected) else {
            preconditionFailure("kaya: \(G.self) is not a wire type")
        }
        var model: T?
        if var current = tx.recordEntries(collection).first(where: { $0.key == key })?.value as? T,
            kayaSameWire(current[keyPath: `guard`], expected)
        {
            for change in p.changes { change.apply(&current) }
            model = current
        }
        tx.patchIfRaw(
            collection, key, model, 0, T.field(`guard`).index, guardWire,
            p.changes.map(\.index), p.changes.map(\.wire))
        return model != nil
    }
}

/// The app's fetch: the bytes at a URL, or a thrown error. Cancelled through
/// the task when no realized row waits on its URL.
public typealias KayaImageFetch = @Sendable (String) async throws -> Data

/// The default fetch: URLSession, the status checked.
public let kayaURLSessionFetch: KayaImageFetch = { url in
    guard let u = URL(string: url) else { throw URLError(.badURL) }
    let (data, response) = try await URLSession.shared.data(from: u)
    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
        throw KayaImageFetchFailed(status: http.statusCode)
    }
    return data
}

/// A fetch whose answer was not a picture's bytes: the status, by number.
public struct KayaImageFetchFailed: Error, CustomStringConvertible {
    public let status: Int
    public var description: String { "HTTP \(status)" }
}

// docs/traps.md, "The sockets a stale freeze destroyed": one write, the
// same line in all nine bindings.
func kayaRowImageFetchFailed(_ u: String, _ why: String) {
    let flat = why.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
    FileHandle.standardError.write(Data("kaya: row image fetch failed: \(u): \(flat)\n".utf8))
}

/// Rows whose image loads on demand (N12). Each row holds the URL it wants,
/// its bytes and its phase; a row realized `.loading` with no bytes is
/// fetched, at most `limit` at a time, rows sharing a URL share one fetch,
/// and a URL no realized row waits on any longer is not fetched, or is
/// cancelled. Every write is one patchIf guarded on the URL field.
@KayaAppActor
public final class KayaRowImages<T: KayaRecord> {
    nonisolated public static var limit: Int { 6 }

    /// The encoded bytes kept by URL, least recently used out past this.
    nonisolated public static var cacheBudget: Int { 32 << 20 }


    let app: KayaApp
    let rows: KayaRecordCollection<T>
    let url: WritableKeyPath<T, String>
    let art: WritableKeyPath<T, Data>
    let phase: WritableKeyPath<T, KayaImagePhase>
    let fetch: KayaImageFetch
    var onError: ((KayaAppTx, [KayaValue], String) -> Void)?

    var queue: [String] = []
    var waiting: [String: [[KayaValue]]] = [:]
    var inFlight: [String: (id: Int, task: Task<Void, Never>)] = [:]
    var cache: [String: (bytes: Data, used: Int)] = [:]
    var cachedBytes = 0
    var tick = 0
    var started = 0
    var running = 0

    /// `url`, `art` and `phase` are the row's fields; `rows` is the root
    /// handle of the collection the template image's For stamps.
    public init(
        _ app: KayaApp, _ rows: KayaRecordCollection<T>, url: WritableKeyPath<T, String>,
        art: WritableKeyPath<T, Data>, phase: WritableKeyPath<T, KayaImagePhase>,
        fetch: @escaping KayaImageFetch = kayaURLSessionFetch
    ) {
        self.app = app
        self.rows = rows
        self.url = url
        self.art = art
        self.phase = phase
        self.fetch = fetch
    }

    /// Run inside the transaction that writes `.failed`, with the copy's
    /// keys and why.
    public func onError(_ handler: @escaping (KayaAppTx, [KayaValue], String) -> Void) {
        onError = handler
    }

    /// Fetch for the stamped copies of template image `image`.
    public func attach(_ image: KayaNodeHandle) {
        app.images.feeds[image.id, default: []].append((
            needed: { tx, keys in self.needed(tx, keys) },
            released: { _, keys in self.released(keys) }))
    }

    var queued: Int { queue.count }

    func instance(_ keys: [KayaValue]) -> (KayaRecordCollection<T>, KayaValue)? {
        guard let key = keys.last else { return nil }
        var c = rows
        for k in keys.dropLast() { c = c.at(k) }
        return (c, key)
    }

    func needed(_ tx: KayaAppTx, _ keys: [KayaValue]) {
        guard let (c, key) = instance(keys),
            let row = c.items(tx).first(where: { $0.key == key })?.value
        else { return }
        let wanted = row[keyPath: url]
        if wanted.isEmpty { return }
        if let hit = cache[wanted] {
            tick += 1
            cache[wanted]?.used = tick
            write(tx, [keys], wanted, .success(hit.bytes))
            return
        }
        waiting[wanted, default: []].append(keys)
        if waiting[wanted]!.count > 1 { return }
        queue.append(wanted)
        pump()
    }

    /// A released row stops waiting; a URL nobody waits on leaves the queue,
    /// and a running fetch for it is cancelled.
    func released(_ keys: [KayaValue]) {
        for u in Array(waiting.keys) {
            waiting[u]!.removeAll { $0 == keys }
            if waiting[u]!.isEmpty {
                waiting[u] = nil
                queue.removeAll { $0 == u }
                inFlight.removeValue(forKey: u)?.task.cancel()
            }
        }
    }

    func pump() {
        while running < Self.limit, !queue.isEmpty {
            let u = queue.removeFirst()
            running += 1
            started += 1
            let id = started
            let fetch = self.fetch
            let task = Task { @KayaAppActor in
                let got: Result<Data, Error>
                do { got = .success(try await fetch(u)) } catch {
                    got = .failure(error)
                    if !Task.isCancelled { kayaRowImageFetchFailed(u, "\(error)") }
                }
                self.landed(u, id, got)
            }
            inFlight[u] = (id, task)
        }
    }

    func landed(_ u: String, _ id: Int, _ got: Result<Data, Error>) {
        running -= 1
        let current = inFlight[u]?.id == id
        if current { inFlight[u] = nil }
        if current, let rowsWaiting = waiting.removeValue(forKey: u) {
            if case .success(let bytes) = got { keep(u, bytes) }
            // A completion never lands inside a transaction: tasks resume on
            // the executor's own turn, between occurrences.
            app.build { tx in write(tx, rowsWaiting, u, got) }
        }
        pump()
    }

    func write(_ tx: KayaAppTx, _ keysList: [[KayaValue]], _ u: String, _ got: Result<Data, Error>) {
        for keys in keysList {
            guard let (c, key) = instance(keys) else { continue }
            switch got {
            case .success(let bytes):
                c.patchIf(tx, key, url, equals: u) { $0.set(art, bytes).set(phase, .shown) }
            case .failure(let error):
                c.patchIf(tx, key, url, equals: u) { $0.set(phase, .failed) }
                onError?(tx, keys, "\(error)")
            }
        }
    }

    func keep(_ u: String, _ bytes: Data) {
        tick += 1
        if let old = cache.updateValue((bytes, tick), forKey: u) { cachedBytes -= old.bytes.count }
        cachedBytes += bytes.count
        while cachedBytes > Self.cacheBudget, cache.count > 1,
            let oldest = cache.min(by: { $0.value.used < $1.value.used })
        {
            cache[oldest.key] = nil
            cachedBytes -= oldest.value.bytes.count
        }
    }
}
