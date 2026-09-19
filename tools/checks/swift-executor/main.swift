// tools/check-abort.py; docs/measurements/swift-executor-2026-09-18.md
import Foundation
internal import CKaya

enum ProbeError: Error { case setup, handler }
let mode = CommandLine.arguments.dropFirst().first ?? "normal"

@KayaAppActor func probe(_ app: KayaApp) throws {
    if mode == "setup-throw" { throw ProbeError.setup }
    if mode == "double-start" {
        Thread { KayaAppExecutor.shared.serve() }.start()
    }
    let owner = pthread_self()
    precondition(!Thread.isMainThread, "executor: construction ran on main")
    var clicks = 0
    var posted = 0
    var retained: KayaAppTx?
    let (signal, button) = app.build { tx in
        retained = tx
        let signal = tx.signal(.i64(0))
        let button = tx.button("probe") { tx in
            precondition(pthread_self() == owner, "executor: handler changed threads")
            clicks += 1
            tx.write(signal, .i64(1))
        }
        return (signal, button)
    }
    var tag = button.id.littleEndian
    var bytes = withUnsafeBytes(of: &tag) { Array($0) }
    bytes += [UInt8](repeating: 0, count: 8)
    bytes.withUnsafeBufferPointer { kaya_emit_clicked($0.baseAddress, UInt($0.count)) }
    app.post { tx in
        tx.write(signal, .i64(99))
        throw ProbeError.handler
    }
    app.post { _ in
        precondition(pthread_self() == owner, "executor: post changed threads")
        precondition(app.signalMirrors[signal.id] == .i64(0), "executor: thrown post was not rolled back")
        posted += 1
    }
    Task { @KayaAppActor in
        try await Task.sleep(nanoseconds: 200_000_000)
        precondition(pthread_self() == owner, "executor: continuation changed threads")
        if mode == "closed" {
            retained!.write(signal, .i64(2))
            fatalError("executor: closed transaction was accepted")
        }
        precondition(clicks == 1, "executor: handler did not run once")
        precondition(posted == 1, "executor: post did not survive the throw")
        precondition(app.signalMirrors[signal.id] == .i64(1), "executor: mirror was not rolled back")
        app.build { tx in tx.write(signal, .i64(2)) }
        precondition(app.signalMirrors[signal.id] == .i64(2), "executor: continuation write was lost")
        print("swift-executor: OK construction handler post continuation same-thread rollback wake")
        exit(0)
    }
}
KayaApp.start(probe)
Thread.sleep(forTimeInterval: 5)
fatalError("executor: timed out waiting for the app loop")
