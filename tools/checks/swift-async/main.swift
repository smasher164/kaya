// tools/check-abort.py; docs/async-dialogs-plan.md
import Foundation
import os
internal import CKaya

enum AsyncProbeError: Error { case failure }
let mode = CommandLine.arguments.dropFirst().first ?? "requests"

@KayaAppActor func requests(_ app: KayaApp, _ owner: pthread_t) async {
    func boundary() {
        precondition(pthread_self() == owner, "async: continuation changed threads")
        precondition(app.currentTx == nil, "async: continuation inherited a transaction")
    }
    for choice in [KayaAlertChoice.action1, .cancel] {
        Task { @KayaAppActor in
            let id = app.liveAlert
            precondition(id != 0 && app.alerts.count == 1, "async: alert was not registered")
            app.alertResult(id, choice)
            precondition(app.liveAlert == 0 && app.alerts.isEmpty, "async: alert did not retire")
            app.alertResult(id, .action0)
        }
        let answer = await app.showAlert(actions: ["one", "two"], cancel: "keep")
        boundary()
        precondition(answer == choice, "async: alert answer changed")
    }
    let file = KayaPickedFile(handle: 7, name: "chosen", localPath: "/chosen")
    for multiple in [false, true] {
        for cancelled in [false, true] {
            Task { @KayaAppActor in
                let id = app.liveFileDialog
                precondition(id != 0 && app.fileDialogs.count == 1, "async: picker was not registered")
                app.fileDialogResult(id, cancelled ? [] : [file])
                precondition(app.liveFileDialog == 0 && app.fileDialogs.isEmpty, "async: file dialog did not retire")
                app.fileDialogResult(id, [])
            }
            let answer = multiple ? await app.pickFiles() : await app.pickFile()
            boundary()
            precondition(answer.count == (cancelled ? 0 : 1), "async: picker cancellation changed")
            if let picked = answer.first {
                precondition(picked.handle == 7 && picked.name == "chosen", "async: picked capability changed")
            }
        }
    }
    for cancelled in [false, true] {
        Task { @KayaAppActor in
            let id = app.liveFileDialog
            precondition(id != 0 && app.fileDialogs.count == 1, "async: save was not registered")
            app.fileDialogResult(id, cancelled ? [] : [file])
            precondition(app.liveFileDialog == 0 && app.fileDialogs.isEmpty, "async: save did not retire")
        }
        let answer = await app.saveFile(suggestedName: "draft")
        boundary()
        precondition((answer == nil) == cancelled, "async: save cancellation changed")
        if let answer { precondition(answer.handle == 7, "async: save capability changed") }
    }
    for cancelled in [false, true] {
        Task { @KayaAppActor in
            precondition(app.clipboardReads.count == 1, "async: clipboard was not registered")
            let id = app.clipboardReads.keys.first!
            app.clipboardResult(id, cancelled ? nil : .text("answer"))
            precondition(app.clipboardReads.isEmpty, "async: clipboard did not retire")
            app.clipboardResult(id, .text("duplicate"))
        }
        let answer = await app.readClipboard(accepting: ["text"])
        boundary()
        if cancelled {
            precondition(answer == nil, "async: clipboard cancellation changed")
        } else if case .text("answer") = answer {
        } else {
            fatalError("async: clipboard answer changed")
        }
    }
}

/// docs/media-plan.md §8 ruling 4, rule 4: after cancel_read or close_reader
/// the app hears only the read's end, and an unheard frame's image is
/// released by the next commit; an awaited read the same, by task
/// cancellation or a failed end.
@KayaAppActor func readerRule(_ app: KayaApp) async {
    func run(_ h: @escaping (KayaAppTx) throws -> Void) { try! app.build(h) }
    func frame(_ reader: KayaReader, _ read: UInt64, _ index: Int64, _ image: UInt64) {
        _ = app.readerOccurrence(
            UInt16(KAYA_OCCURRENCE_READER_FRAME), reader.id,
            [.i64(Int64(read)), .i64(Int64(image)), .i64(index), .i64(2), .i64(1), .i64(40), .i64(40)], run)
    }
    func done(_ reader: KayaReader, _ read: UInt64, _ outcome: Int32, _ failure: Int32 = 0) {
        _ = app.readerOccurrence(
            UInt16(KAYA_OCCURRENCE_READER_DONE), reader.id,
            [.i64(Int64(read)), .i64(Int64(outcome)), .i64(Int64(failure)), .str("why")], run)
    }
    func released(_ images: [UInt64]) -> Bool {
        var want = KayaTx()
        for image in images { want.releaseImage(image) }
        return app.readers.pendingReleases.bytes == want.bytes
    }
    for closing in [false, true] {
        var heard: [String] = []
        let (reader, read, image) = app.build { tx -> (KayaReader, KayaRead, UInt64) in
            let reader = tx.reader(.asset("media/h264_frames.mp4"))
            let read = tx.readFrames(
                reader, at: [0, 40], onFrame: { _, f in heard.append("frame \(f.index)") },
                onDone: { _, o in heard.append("done \(o)") })
            return (reader, read, app.readers.nextImage - 1)
        }
        frame(reader, read.id, 0, image)
        app.build { tx in if closing { tx.closeReader(reader) } else { tx.cancelRead(reader, read) } }
        frame(reader, read.id, 1, image + 1)
        precondition(heard == ["frame 0"], "reader: a late answer after cancel or close was heard: \(heard)")
        precondition(released([image + 1]), "reader: the unheard frame's image was not queued for release")
        done(reader, read.id, KAYA_READ_OUTCOME_CANCELLED)
        precondition(heard == ["frame 0", "done cancelled"], "reader: the end was not heard: \(heard)")
        precondition(app.readers.pendingReleases.bytes.isEmpty, "reader: the release did not ride the next commit")
        precondition(app.readers.handlers.isEmpty, "reader: the read's handlers did not retire")
    }
    let (clip, first) = app.build { tx -> (KayaReader, UInt64) in
        (tx.reader(.asset("media/h264_frames.mp4")), app.readers.nextImage + 1)
    }
    let task = Task { @KayaAppActor in try await app.frames(clip, at: [0, 40], accuracy: .exact) }
    while app.readers.waiters.isEmpty { await Task.yield() }
    let awaited = app.readers.waiters.keys.first!
    frame(clip, awaited, 0, first)
    task.cancel()
    switch await task.result {
    case .failure(let e) where e is CancellationError: break
    default: fatalError("reader: a cancelled awaiting task did not throw CancellationError")
    }
    precondition(app.readers.waiters.isEmpty, "reader: the cancelled await stayed registered")
    frame(clip, awaited, 1, first + 1)
    precondition(released([first + 1]), "reader: the cancelled await's late image was not queued for release")
    done(clip, awaited, KAYA_READ_OUTCOME_CANCELLED)
    app.build { _ in }
    let failing = Task { @KayaAppActor in try await app.frames(clip, at: [0, 40], accuracy: .exact) }
    while app.readers.waiters.isEmpty { await Task.yield() }
    let failed = app.readers.waiters.keys.first!
    frame(clip, failed, 0, first + 2)
    done(clip, failed, KAYA_READ_OUTCOME_FAILED, Int32(KAYA_MEDIA_FAILURE_NOT_FOUND))
    switch await failing.result {
    case .failure(let e as KayaReadError) where e == .failed(.notFound, "why"): break
    default: fatalError("reader: a failed awaited read did not throw its reason")
    }
    precondition(released([first + 2]), "reader: a failed awaited read's image was not queued for release")
    app.build { _ in }
}

@KayaAppActor func rollback(_ app: KayaApp) {
    for kind in 0..<5 {
        do {
            try app.build { tx in
                switch kind {
                case 0: tx.showAlert(cancel: "keep") { _, _ in fatalError("async: aborted alert answered") }
                case 1: tx.pickFile { _, _ in fatalError("async: aborted picker answered") }
                case 2: tx.pickFiles { _, _ in fatalError("async: aborted pickers answered") }
                case 3: tx.saveFile(suggestedName: "draft") { _, _ in fatalError("async: aborted save answered") }
                default: tx.readClipboard().text().onResult { _, _ in fatalError("async: aborted clipboard answered") }.send()
                }
                throw AsyncProbeError.failure
            }
            fatalError("async: throwing scope returned")
        } catch {}
        precondition(app.liveAlert == 0 && app.alerts.isEmpty, "async: rollback leaked alert")
        precondition(app.liveFileDialog == 0 && app.fileDialogs.isEmpty, "async: rollback leaked file dialog")
        precondition(app.clipboardReads.isEmpty, "async: rollback leaked clipboard")
    }
    var calls = 0
    let id = app.build { tx in
        tx.showAlert(cancel: "keep") { tx, _ in
            calls += 1
            tx.showAlert(cancel: "next")
        }
    }
    app.alertResult(id, .cancel)
    precondition(calls == 1 && app.liveAlert != 0, "async: callback could not show next alert")
    app.alertResult(id, .cancel)
    precondition(calls == 1, "async: callback ran twice")
    app.alertResult(app.liveAlert, .cancel)
    precondition(app.liveAlert == 0, "async: handlerless alert did not retire")
    let pick = app.build { tx in tx.pickFile() }
    let alert = app.build { tx in tx.showAlert(cancel: "keep") }
    precondition(app.liveFileDialog == pick && app.liveAlert == alert, "async: alert and file slots collided")
    app.fileDialogResult(pick, [])
    app.alertResult(alert, .cancel)
    precondition(app.liveFileDialog == 0 && app.liveAlert == 0, "async: handlerless slots did not retire")
}

// docs/capture-plan.md §4: a capture callback runs on kaya's capture thread,
// where a transaction it opens is refused; it is handed the core's frame
// BORROWED; a released capture's callbacks are dropped by the binding.
final class CaptureTracker: Sendable {}

// What @Sendable refuses at compile time, forced, so the runtime refusal is
// the one under test (the child mode below).
final class CaptureSmuggle: @unchecked Sendable {
    let app: KayaApp
    init(_ app: KayaApp) { self.app = app }
}

func onCaptureThread(_ body: @escaping @Sendable () -> Void) {
    let done = DispatchSemaphore(value: 0)
    Thread.detachNewThread {
        body()
        done.signal()
    }
    done.wait()
}

/// The core's two calls into the binding, made as capi.rs makes them: the
/// capture id as the context, the frame and chunk in memory the "core" owns.
func captureDeliver(_ id: UInt64, _ y: UInt, _ uv: UInt, _ pcm: UInt) {
    var frame = CKaya.KayaCaptureFrame(
        width: 2, height: 2, y: UnsafePointer(bitPattern: y), uv: UnsafePointer(bitPattern: uv),
        y_stride: 4, uv_stride: 4, timestamp_ns: 77, rotation: 0, reserved: 0)
    withUnsafePointer(to: &frame) { kayaCaptureFrameCall(kayaCaptureContext(id), $0) }
    kayaCaptureSamplesCall(kayaCaptureContext(id), UnsafePointer(bitPattern: pcm), 480, 78)
}

@KayaAppActor func captureRule(_ app: KayaApp) {
    let y = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: 8)
    let uv = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: 4)
    let pcm = UnsafeMutableBufferPointer<Int16>.allocate(capacity: 480)
    defer {
        y.deallocate()
        uv.deallocate()
        pcm.deallocate()
    }
    for i in 0..<8 { y[i] = UInt8(i + 1) }
    for i in 0..<4 { uv[i] = UInt8(i + 11) }
    for i in 0..<480 { pcm[i] = Int16(i) }
    let at = (UInt(bitPattern: y.baseAddress), UInt(bitPattern: uv.baseAddress), UInt(bitPattern: pcm.baseAddress))

    let c = app.build { tx in tx.capture(camera: "cam") }
    let heard = OSAllocatedUnfairLock(initialState: [String]())
    weak var watched: CaptureTracker?
    do {
        let held = CaptureTracker()
        watched = held
        app.onCaptureFrame(c) { f in
            _ = held
            let borrowed = UInt(bitPattern: f.y.baseAddress) == at.0 && UInt(bitPattern: f.uv.baseAddress) == at.1
            let line = "frame \(f.width)x\(f.height) \(f.y.count) \(f.uv.count) \(f.timestampNs) borrowed \(borrowed)"
            heard.withLock { $0.append(line) }
        }
        app.onCaptureSamples(c) { chunk, ns in
            _ = held
            let borrowed = UInt(bitPattern: chunk.baseAddress) == at.2
            let line = "chunk \(chunk.count) \(ns) borrowed \(borrowed)"
            heard.withLock { $0.append(line) }
        }
    }
    let id = c.id
    onCaptureThread { captureDeliver(id, at.0, at.1, at.2) }
    let first = heard.withLock { $0 }
    precondition(first == ["frame 2x2 8 4 77 borrowed true", "chunk 480 78 borrowed true"],
                 "capture: the callbacks heard \(first)")

    do {
        try app.build { tx in
            tx.releaseCapture(c)
            throw AsyncProbeError.failure
        }
    } catch {}
    precondition(kayaCaptureSinks.withLock { $0.frames[c.id] != nil && $0.samples[c.id] != nil },
                 "capture: a rolled-back release dropped the callbacks anyway")
    app.build { tx in tx.releaseCapture(c) }
    precondition(kayaCaptureSinks.withLock { $0.frames[c.id] == nil && $0.samples[c.id] == nil },
                 "capture: a released capture's callbacks were kept by the binding")
    precondition(watched == nil, "capture: a released capture's callbacks are still alive")
    onCaptureThread { captureDeliver(id, at.0, at.1, at.2) }
    precondition(heard.withLock { $0.count } == 2, "capture: a released capture's callback still ran")

    let child = Process()
    child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    child.arguments = ["capture-wrong-thread"]
    let said = Pipe()
    child.standardError = said
    child.standardOutput = FileHandle.nullDevice
    do { try child.run() } catch { preconditionFailure("capture: the wrong-thread child did not start: \(error)") }
    let text = String(decoding: said.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    child.waitUntilExit()
    precondition(child.terminationStatus != 0 && text.contains("a transaction belongs to the app thread"),
                 "capture: a transaction opened in a frame callback was not refused by the wrong-thread"
                    + " refusal (status \(child.terminationStatus)): \(text)")
}

@KayaAppActor func probe(_ app: KayaApp) throws {
    let owner = pthread_self()
    precondition(!Thread.isMainThread, "async: construction ran on main")
    if mode == "capture-wrong-thread" {
        let c = app.build { tx in tx.capture(camera: "cam") }
        let smuggled = CaptureSmuggle(app)
        app.onCaptureFrame(c) { _ in
            smuggled.app.build { tx in _ = tx.signal(.i64(0)) }
        }
        let y = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: 8)
        let uv = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: 4)
        let pcm = UnsafeMutableBufferPointer<Int16>.allocate(capacity: 480)
        let at = (UInt(bitPattern: y.baseAddress), UInt(bitPattern: uv.baseAddress), UInt(bitPattern: pcm.baseAddress))
        let id = c.id
        onCaptureThread { captureDeliver(id, at.0, at.1, at.2) }
        fatalError("capture: a transaction opened in a frame callback was accepted off the app thread")
    }
    if mode.hasPrefix("async-overlap-") {
        for _ in 0..<2 {
            app.task {
                switch mode {
                case "async-overlap-alert": _ = await app.showAlert(cancel: "keep")
                case "async-overlap-file": _ = await app.pickFiles()
                default: _ = await app.saveFile(suggestedName: "draft")
                }
            }
        }
        return
    }
    if mode == "overlap-alert" {
        app.build { tx -> Void in
            tx.showAlert(cancel: "keep")
            tx.showAlert(cancel: "again")
        }
        fatalError("async: overlapping alert was accepted")
    }
    if mode == "overlap-file" || mode == "overlap-save" {
        app.build { tx -> Void in
            if mode == "overlap-file" { tx.pickFile() }
            else { tx.saveFile(suggestedName: "draft") }
            tx.pickFiles()
        }
        fatalError("async: overlapping file dialog was accepted")
    }
    if mode == "template" {
        app.build { tx in
            let rows = tx.collection()
            tx.each(rows) { _ in app.task {} }
        }
        fatalError("async: task in template was accepted")
    }
    if mode == "boundary" {
        app.build { _ in app.requireAsyncBoundary() }
        fatalError("async: open transaction was accepted")
    }
    if mode == "rollback" {
        rollback(app)
        print("swift-async: OK rollback callback retirement separate slots")
        exit(0)
    }
    var completed = false
    var retained: KayaAppTx?
    let signal = app.build { tx in
        retained = tx
        return tx.signal(.i64(0))
    }
    app.task {
        defer { completed = true }
        precondition(app.currentTx == nil, "async: task began inside a transaction")
        if mode == "requests" {
            await requests(app, owner)
            await readerRule(app)
            captureRule(app)
            return
        }
        Task { @KayaAppActor in app.alertResult(app.liveAlert, .action0) }
        let answer = await app.showAlert(actions: ["go"], cancel: "keep")
        precondition(answer == .action0, "async: scope probe answer changed")
        precondition(pthread_self() == owner, "async: scope continuation changed threads")
        precondition(app.currentTx == nil, "async: scope continuation inherited a transaction")
        if mode == "closed" {
            retained!.write(signal, .i64(1))
            fatalError("async: closed transaction was accepted")
        }
        if mode == "before" { throw AsyncProbeError.failure }
        app.build { tx in tx.write(signal, .i64(1)) }
        if mode == "outside" { throw AsyncProbeError.failure }
        if mode == "inside" {
            try app.build { tx in
                tx.write(signal, .i64(2))
                throw AsyncProbeError.failure
            }
        }
        if mode == "caught" {
            do {
                try app.build { tx in
                    tx.write(signal, .i64(2))
                    throw AsyncProbeError.failure
                }
            } catch {}
            precondition(app.signalMirrors[signal.id] == .i64(1), "async: caught scope did not roll back")
            app.build { tx in tx.write(signal, .i64(3)) }
        }
    }
    Task { @KayaAppActor in
        while !completed { try await Task.sleep(nanoseconds: 1_000_000) }
        precondition(app.currentTx == nil, "async: reporter left a transaction open")
        let expected: Int64 = mode == "caught" ? 3 : (mode == "requests" || mode == "before" ? 0 : 1)
        precondition(app.signalMirrors[signal.id] == .i64(expected), "async: scope atomicity changed")
        print("swift-async: OK \(mode) same-thread no-ambient explicit-scopes")
        exit(0)
    }
}

KayaApp.start(probe)
Thread.sleep(forTimeInterval: 5)
fatalError("swift-async: timed out waiting for result or task")
