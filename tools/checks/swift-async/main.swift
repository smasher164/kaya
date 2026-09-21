// tools/check-abort.py; docs/async-dialogs-plan.md
import Foundation

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

@KayaAppActor func probe(_ app: KayaApp) throws {
    let owner = pthread_self()
    precondition(!Thread.isMainThread, "async: construction ran on main")
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
