// docs/measurements/swift-executor-2026-09-18.md
import Foundation
internal import CKaya

final class KayaAppQueue<Item: Sendable>: @unchecked Sendable {
    private let ready = NSCondition()
    private var items: [Item] = []
    private var started = false

    func append(_ item: Item) {
        ready.lock()
        items.append(item)
        ready.signal()
        ready.unlock()
        kaya_wake()
    }

    func claim() {
        ready.lock()
        precondition(!started, "kaya: the Swift app executor may only start once")
        started = true
        ready.unlock()
    }

    func wait() -> Item {
        ready.lock()
        while items.isEmpty { ready.wait() }
        let item = items.removeFirst()
        ready.unlock()
        return item
    }

    func takeAll() -> [Item] {
        ready.lock()
        let batch = items
        items = []
        ready.unlock()
        return batch
    }
}

final class KayaAppExecutor: SerialExecutor {
    static let shared = KayaAppExecutor()
    private let jobs = KayaAppQueue<UnownedJob>()

    func enqueue(_ job: UnownedJob) { jobs.append(job) }

    func asUnownedSerialExecutor() -> UnownedSerialExecutor {
        UnownedSerialExecutor(ordinary: self)
    }

    func serve() {
        jobs.claim()
        while true {
            let job = jobs.wait()
            job.runSynchronously(on: asUnownedSerialExecutor())
        }
    }

    @KayaAppActor func drain() {
        for job in jobs.takeAll() { job.runSynchronously(on: asUnownedSerialExecutor()) }
    }
}

@globalActor public actor KayaAppActor {
    public static let shared = KayaAppActor()
    nonisolated public var unownedExecutor: UnownedSerialExecutor {
        KayaAppExecutor.shared.asUnownedSerialExecutor()
    }
}
