// The capture, Swift port — guests/rust/capture.rs,
// tools/scenes/capture.steps and capture_denied.steps, docs/capture-plan.md.

import Foundation
import Kaya
import os

let camera1 = "kaya-synthetic-camera-1"
let camera2 = "kaya-synthetic-camera-2"
let microphone1 = "kaya-synthetic-microphone-1"
let microphone2 = "kaya-synthetic-microphone-2"

func stateLine(_ r: KayaCaptureReading) -> String {
    switch r.state {
    case .running: return "running \(r.width)x\(r.height)@\(r.frameRate)"
    case .failed: return "failed \(r.failure?.name ?? "")"
    case .interrupted: return "interrupted \(r.interruption?.name ?? "")"
    default: return r.state.name
    }
}

/// What the app's code on kaya's capture thread has seen.
struct Seen {
    var frames = "app frames none"
    var chunks = "app chunks none"
    var chunkPosted = false
    var line: String { "\(frames), \(chunks)" }
}

KayaApp.run { app in
    let post = app.post
    var labels: [KayaSignal] = []
    let (call, missing) = app.build { tx in
        tx.window(title: "capture", width: 520, height: 640)
        labels = ["devices", "permissions", "idle", "app frames none, app chunks none", "idle"]
            .map { tx.signal(.str($0)) }
        let call = tx.capture(camera: camera1, microphone: microphone1, size: (600, 400), frameRate: 30)
        let missing = tx.capture(camera: "no-such-camera")
        var selfView: KayaWidget!
        let root = tx.column { root in
            for label in labels {
                tx.label(bind: label)  // label#0..#4
            }
            let buttons = tx.row { buttons in
                tx.button("Ask camera") { tx in tx.requestPermission(.camera) }  // button#0
                tx.button("Start") { tx in tx.startCapture(call) }  // button#1
                tx.button("Switch") { tx in  // button#2
                    tx.captureCamera(call, camera2)
                    tx.captureMicrophone(call, microphone2)
                    tx.captureSize(call, width: 1280, height: 720)
                    tx.captureFrameRate(call, 15)
                }
                tx.button("Mute") { tx in tx.captureMuted(call, true) }  // button#3
                tx.button("Camera off") { tx in tx.captureCamera(call, nil) }  // button#4
                tx.button("Stop") { tx in tx.stopCapture(call) }  // button#5
                tx.button("Open missing") { tx in tx.startCapture(missing) }  // button#6
                tx.button("Wide cover") { tx in  // button#7
                    tx.setAspect(selfView, 16, 9)
                    tx.setFit(selfView, .cover)
                }
                tx.button("Wide contain") { tx in tx.setFit(selfView, .contain) }  // button#8
                return buttons
            }
            tx.setWrap(buttons, true)
            selfView = tx.video(capture: call)  // video#0
            tx.setA11yLabel(selfView, "Self view")
            return root
        }
        tx.mount(root)
        tx.watchCaptureDevices(true)
        return (call, missing)
    }
    app.onCaptureDevices { tx, devices in
        let line = devices.map { d in
            var s = "\(d.kind.name) \(d.id)"
            if d.kind == .camera { s += " \(d.facing.name)" }
            if d.preferred { s += " preferred" }
            return s
        }
        tx.write(labels[0], .str(line.joined(separator: "; ")))
    }
    app.onPermission { tx, _, _ in
        tx.write(labels[1], .str(
            "camera \(app.permission(.camera).name), microphone \(app.permission(.microphone).name)"))
    }
    app.onCaptureState(call) { tx, r in tx.write(labels[2], .str(stateLine(r))) }
    app.onCaptureState(missing) { tx, r in tx.write(labels[4], .str(stateLine(r))) }

    // The app's own code on kaya's capture thread: it checks what it was
    // handed and posts what it saw, as a call's encoder would read it.
    let shown = labels[3]
    let show: @KayaAppActor @Sendable (KayaAppTx, String) -> Void = { tx, line in
        tx.write(shown, .str(line))
    }
    let seen = OSAllocatedUnfairLock(initialState: Seen())
    app.onCaptureFrame(call) { f in
        let whole = f.y.count >= Int(f.yStride) * Int(f.height)
            && f.uv.count >= Int(f.uvStride) * ((Int(f.height) + 1) / 2)
            && f.yStride >= f.width
            && f.uvStride >= f.width
        let now = whole ? "app frames \(f.width)x\(f.height)" : "app frames none"
        seen.withLock { s in
            if s.frames == now { return }
            s.frames = now
            let line = s.line
            post { tx in show(tx, line) }
        }
    }
    app.onCaptureSamples(call) { chunk, _ in
        let n = chunk.count
        seen.withLock { s in
            if s.chunkPosted { return }
            s.chunkPosted = true
            s.chunks = "app chunks of \(n)"
            let line = s.line
            post { tx in show(tx, line) }
        }
    }
}
