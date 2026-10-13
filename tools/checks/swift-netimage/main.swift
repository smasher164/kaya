// tools/check-abort.py; docs/network-images-plan.md N7, N8, N12. Compiled as
// one module with bindings/swift so the mirror is assertable.
import Foundation
internal import CKaya

let mode = CommandLine.arguments.dropFirst().first ?? "all"

struct Song: KayaRecord {
    var title: String
    var artURL: String
    var art: Data
    var phase: KayaImagePhase

    static let prototype = Song(title: "", artURL: "", art: Data(), phase: .shown)

    init(title: String, artURL: String, art: Data, phase: KayaImagePhase) {
        self.title = title
        self.artURL = artURL
        self.art = art
        self.phase = phase
    }

    init(values: [KayaValue]) {
        guard case .str(let title) = values[0], case .str(let url) = values[1],
            case .bytes(let art) = values[2], case .i64(let phase) = values[3]
        else { preconditionFailure("netimage: Song fields out of order") }
        self.init(title: title, artURL: url, art: Data(art), phase: kayaImagePhase(packed: phase))
    }
}

final class Smuggle: @unchecked Sendable {
    let app: KayaApp
    let songs: KayaRecordCollection<Song>
    init(_ app: KayaApp, _ songs: KayaRecordCollection<Song>) {
        self.app = app
        self.songs = songs
    }
}

func check(_ ok: Bool, _ what: String) {
    if !ok {
        print("swift-netimage: FAIL — \(what)")
        exit(1)
    }
}

func patchIfRecords(_ bytes: Data) -> Int {
    var at = 0
    var n = 0
    let b = [UInt8](bytes)
    while at + 8 <= b.count {
        let len = Int(b[at]) | Int(b[at + 1]) << 8 | Int(b[at + 2]) << 16 | Int(b[at + 3]) << 24
        let kind = Int(b[at + 4]) | Int(b[at + 5]) << 8
        if kind == Int(KAYA_TX_COLLECTION_PATCH_IF) { n += 1 }
        if len <= 0 { break }
        at += len
    }
    return n
}

/// A network that answers when told: every fetch waits on its URL.
@KayaAppActor final class Net {
    var fetched: [String] = []
    var cancelled: [String] = []
    var waits: [String: CheckedContinuation<Data, Error>] = [:]

    func fetch(_ url: String) async throws -> Data {
        fetched.append(url)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { waits[url] = $0 }
        } onCancel: {
            Task { @KayaAppActor in self.cancel(url) }
        }
    }

    func cancel(_ url: String) {
        cancelled.append(url)
        waits.removeValue(forKey: url)?.resume(throwing: CancellationError())
    }

    func answer(_ url: String, _ got: Result<Data, Error>) {
        waits.removeValue(forKey: url)!.resume(with: got)
    }
}

struct NotFound: Error {}

@KayaAppActor func until(_ what: String, _ ok: () -> Bool) async {
    for _ in 0..<2000 where !ok() { try? await Task.sleep(nanoseconds: 1_000_000) }
    check(ok(), what)
}

@KayaAppActor func guardCases(_ app: KayaApp) {
    let songs = app.build { tx in
        let songs = tx.collection(of: Song.self)
        songs.insert(tx, .str("a"), Song(title: "A", artURL: "u/1", art: Data(), phase: .loading))
        return songs
    }
    app.build { tx in
        let held = songs.patchIf(tx, .str("a"), \.artURL, equals: "u/1") {
            $0.set(\.art, Data([1, 2])).set(\.phase, .shown)
        }
        let moved = songs.patchIf(tx, .str("a"), \.artURL, equals: "u/0") { $0.set(\.phase, .failed) }
        let gone = songs.patchIf(tx, .str("zz"), \.artURL, equals: "u/1") { $0.set(\.phase, .failed) }
        check(held && !moved && !gone, "guard answers held=\(held) moved=\(moved) gone=\(gone)")
        let records = patchIfRecords(tx.tx.bytes)
        check(records == 3, "each conditional write is ONE record whether or not it held, saw \(records)")
    }
    let row = app.build { tx in songs.items(tx).first { $0.key == .str("a") }!.value }
    check(row.phase == .shown && row.art.count == 2,
          "the mirror took the writes its guard held for and only those, holds \(row.phase) with \(row.art.count) bytes")
    check(app.build { tx in songs.items(tx).count } == 1, "a write whose row was gone created it in the mirror")
    print("swift-netimage: patch_if held once, dropped for a moved guard and a gone row, one record each")
}

@KayaAppActor func helper(_ app: KayaApp) async {
    let net = Net()
    let (songs, node) = app.build { tx -> (KayaRecordCollection<Song>, KayaNodeHandle) in
        let songs = tx.collection(of: Song.self)
        var node: KayaNodeHandle?
        tx.each(songs.collection) { t in node = t.image(KayaField<Data>(index: 2)) }
        for i in 0..<12 {
            songs.insert(tx, .str(String(format: "r%02d", i)),
                         Song(title: "", artURL: i < 3 ? "u/shared" : "u/\(i)", art: Data(), phase: .loading))
        }
        return (songs, node!)
    }
    let images = KayaRowImages(app, songs, url: \.artURL, art: \.art, phase: \.phase) { url in
        try await net.fetch(url)
    }
    var errors = 0
    images.onError { _, _, _ in errors += 1 }
    images.attach(node)
    func run(_ h: @escaping (KayaAppTx) throws -> Void) { try! app.build(h) }
    func occur(_ kind: Int32, _ key: String) {
        _ = app.imageOccurrence(UInt16(kind), node.id, [.str(key)], run)
    }
    for i in 0..<12 { occur(KAYA_OCCURRENCE_IMAGE_NEEDED, String(format: "r%02d", i)) }
    await until("six fetches start") { net.fetched.count == 6 }
    check(net.fetched.filter { $0 == "u/shared" }.count == 1,
          "three rows sharing a URL make one fetch and at most six run, fetched \(net.fetched)")
    check(images.queued == 4, "the four past the cap wait, \(images.queued) queued")
    occur(KAYA_OCCURRENCE_IMAGE_RELEASED, "r11")
    check(images.queued == 3, "a released row's URL leaves the queue, \(images.queued) queued")
    occur(KAYA_OCCURRENCE_IMAGE_RELEASED, "r03")
    await until("a released row's running fetch is cancelled and the queue moves up, cancelled \(net.cancelled)") {
        net.cancelled.contains("u/3") && net.fetched.contains("u/8")
    }
    net.answer("u/shared", .success(Data([7, 7, 7])))
    net.answer("u/4", .failure(NotFound()))
    func phase(_ key: String) -> KayaImagePhase {
        app.build { tx in songs.items(tx).first { $0.key == .str(key) }!.value.phase }
    }
    await until("r00..r02 read shown after their shared fetch, r04 failed") {
        (0..<3).allSatisfy { phase(String(format: "r%02d", $0)) == .shown } && phase("r04") == .failed
    }
    check(errors == 1, "a failed fetch tells the app once, \(errors) errors")
    check(phase("r03") == .loading, "a cancelled fetch wrote its row")
    await until("the queue moved up as fetches ended and skipped the released URL, fetched \(net.fetched)") {
        net.fetched.contains("u/9") && net.fetched.contains("u/10")
    }
    check(!net.fetched.contains("u/11"), "the released URL was fetched, \(net.fetched)")
    print("swift-netimage: the helper coalesced a shared URL, held six, released a queued URL, cancelled a running one, wrote shown and failed")
}

@KayaAppActor func probe(_ app: KayaApp) throws {
    if mode == "foreign" {
        let songs = app.build { tx in tx.collection(of: Song.self) }
        let smuggled = Smuggle(app, songs)
        Thread {
            _ = smuggled.app.build { tx in
                smuggled.songs.patchIf(tx, .str("a"), \.artURL, equals: "u/1") { $0.set(\.phase, .failed) }
            }
            print("swift-netimage: FAIL — a conditional write from a foreign thread was not refused")
            exit(1)
        }.start()
        return
    }
    guardCases(app)
    Task { @KayaAppActor in
        await helper(app)
        print("swift-netimage: OK")
        exit(0)
    }
}

KayaApp.start(probe)
Thread.sleep(forTimeInterval: 10)
fatalError("swift-netimage: timed out")
