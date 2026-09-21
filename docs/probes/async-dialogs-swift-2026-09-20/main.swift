// docs/measurements/async-dialogs-swift-2026-09-20.md
import Foundation
internal import CKaya

enum ProbeError: Error { case afterScope, insideScope }
let mode = CommandLine.arguments.dropFirst().first ?? "bare"

@KayaAppActor func answer(_ app: KayaApp) async -> KayaAlertChoice {
    let raw: UInt32 = await withCheckedContinuation { continuation in
        app.build { tx -> Void in
            tx.showAlert(title: "probe", actions: ["Accept"], cancel: "Cancel") { _, choice in
                precondition(app.currentTx != nil, "result callback lost its transaction")
                continuation.resume(returning: choice.rawValue)
            }
        }
    }
    return KayaAlertChoice.fromWire(raw)
}

@KayaAppActor func observedTask(
    _ body: @escaping @KayaAppActor () async throws -> Void,
    report: @escaping @KayaAppActor (any Error) -> Void
) {
    Task { @KayaAppActor in
        do { try await body() }
        catch { report(error) }
    }
}

@KayaAppActor func probe(_ app: KayaApp) throws {
    let owner = pthread_self()
    var completed = false
    var reports = 0
    let (first, second) = app.build { tx in
        (tx.signal(.i64(0)), tx.signal(.i64(0)))
    }
    let body: @KayaAppActor () async throws -> Void = {
        defer { completed = true }
        precondition(app.currentTx == nil, "task began in a transaction")
        let choice = await answer(app)
        precondition(choice == .action0, "wrong dialog answer")
        precondition(pthread_self() == owner, "continuation changed threads")
        precondition(app.currentTx == nil, "continuation inherited result transaction")
        app.build { tx in tx.write(first, .i64(1)) }
        if mode == "inside" {
            try app.build { tx in
                tx.write(second, .i64(2))
                throw ProbeError.insideScope
            }
        }
        throw ProbeError.afterScope
    }
    let report: @KayaAppActor (any Error) -> Void = { error in
        precondition(pthread_self() == owner, "reporter changed threads")
        precondition(app.currentTx == nil, "reporter opened a transaction")
        reports += 1
        FileHandle.standardError.write(Data("probe error: \(error)\n".utf8))
        FileHandle.standardError.write(Data("kaya: async handler failed; no transaction was rolled back by this reporter; completed transactions remain committed\n".utf8))
    }
    let button = app.build { tx in
        let button = tx.button("probe") { _ in
            precondition(app.currentTx != nil, "click handler lost its transaction")
            if mode == "bare" {
                Task { try await body() }
            } else if mode == "result" {
                let task = Task { try await body() }
                Task { @KayaAppActor in
                    switch await task.result {
                    case .success: fatalError("throwing task succeeded")
                    case .failure(let error): report(error)
                    }
                }
            } else {
                observedTask(body, report: report)
            }
        }
        tx.mount(button)
        return button
    }
    var tag = button.id.littleEndian
    var bytes = withUnsafeBytes(of: &tag) { Array($0) }
    bytes += [UInt8](repeating: 0, count: 8)
    bytes.withUnsafeBufferPointer { kaya_emit_clicked($0.baseAddress, UInt($0.count)) }
    Task { @KayaAppActor in
        try await Task.sleep(nanoseconds: 500_000_000)
        precondition(completed, "task did not unwind")
        precondition(app.signalMirrors[first.id] == .i64(1), "completed scope was rolled back")
        precondition(app.signalMirrors[second.id] == .i64(0), "throwing scope was committed")
        precondition(reports == (mode == "bare" ? 0 : 1), "report count mismatch")
        print("swift-async-probe: mode=\(mode) same-thread=true ambient-tx=false first=1 second=0 reports=\(reports) unwound=true")
        exit(0)
    }
}

KayaApp.start(probe)
Thread {
    var batch: UnsafePointer<UInt8>?
    while true {
        let length = Int(kaya_next_commands(&batch))
        precondition(length > 0, "presentation pump stopped")
        let data = UnsafeRawPointer(batch!)
        var offset = 0
        while offset < length {
            let size = Int(UInt32(littleEndian: data.loadUnaligned(fromByteOffset: offset, as: UInt32.self)))
            let kind = UInt16(littleEndian: data.loadUnaligned(fromByteOffset: offset + 4, as: UInt16.self))
            precondition(size >= 8 && offset + size <= length, "malformed apply record")
            if kind == UInt16(KAYA_APPLY_PRESENT_ALERT) {
                precondition(size >= 24, "short alert record")
                let id = UInt64(littleEndian: data.loadUnaligned(fromByteOffset: offset + 16, as: UInt64.self))
                kaya_emit_alert_result(id, 0)
            }
            offset += size
        }
    }
}.start()
Thread.sleep(forTimeInterval: 5)
fatalError("swift-async-probe: timed out")
