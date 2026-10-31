// The far end, Swift port — guests/rust/farend.rs, tools/scenes/farend.steps,
// docs/capture-plan.md §5: a surface showing the NV12 frames the app submits
// from its own thread, and a voice output playing the samples it writes.

import Foundation
import Kaya
import os

/// What the far end sends: a flat colour at a size and a tone (0: silence).
struct Sends: Sendable {
    var rgb: UInt32 = 0x1E5AC8
    var width: UInt32 = 640
    var height: UInt32 = 480
    var hz = 660.0
    var on = false
}

/// A flat colour as NV12, video-range BT.601.
func nv12(_ w: UInt32, _ h: UInt32, _ rgb: UInt32) -> ([UInt8], [UInt8]) {
    let r = Double((rgb >> 16) & 0xFF), g = Double((rgb >> 8) & 0xFF), b = Double(rgb & 0xFF)
    let y = UInt8((16 + 0.257 * r + 0.504 * g + 0.098 * b).rounded())
    let u = UInt8((128 - 0.148 * r - 0.291 * g + 0.439 * b).rounded())
    let v = UInt8((128 + 0.439 * r - 0.368 * g - 0.071 * b).rounded())
    var uv = [UInt8](repeating: u, count: Int(w * h / 2))
    for i in stride(from: 1, to: uv.count, by: 2) { uv[i] = v }
    return ([UInt8](repeating: y, count: Int(w * h)), uv)
}

/// The peer's thread: a frame every 1/15 s and 10 ms of samples every 10 ms,
/// paced by the clock, until hung up.
func runPeer(_ peer: OSAllocatedUnfairLock<Sends>, _ frames: KayaSurfaceFrames, _ voice: KayaVoiceWriter) {
    let start = DispatchTime.now().uptimeNanoseconds
    var sentFrames = 0, sentSamples = 0
    var shown: (UInt32, UInt32, UInt32, [UInt8], [UInt8])?
    var phase = 0.0
    while true {
        let now = peer.withLock { $0 }
        if !now.on { return }
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
        while Double(sentFrames) / 15 <= elapsed {
            if shown == nil || shown!.0 != now.rgb || shown!.1 != now.width || shown!.2 != now.height {
                let (y, uv) = nv12(now.width, now.height, now.rgb)
                shown = (now.rgb, now.width, now.height, y, uv)
            }
            frames.submit(
                width: now.width, height: now.height, y: shown!.3, yStride: now.width, uv: shown!.4,
                uvStride: now.width, timestampNs: UInt64(elapsed * 1e9))
            sentFrames += 1
        }
        while Double(sentSamples) / 48000 <= elapsed {
            var chunk = [Int16](repeating: 0, count: 480)
            for i in 0..<480 {
                if now.hz > 0 { chunk[i] = Int16((sin(phase) * 12000).rounded()) }
                phase = (phase + 2 * Double.pi * now.hz / 48000).truncatingRemainder(dividingBy: 2 * Double.pi)
            }
            voice.write(chunk)
            sentSamples += 480
        }
        Thread.sleep(forTimeInterval: 0.005)
    }
}

KayaApp.run { app in
    let peer = OSAllocatedUnfairLock(initialState: Sends())
    var call: KayaVoice?
    var thread: Thread?
    var view: KayaWidget!
    app.build { tx in
        tx.window(title: "far end", width: 520, height: 640)
        let route = tx.signal(.str("voice none"))
        let root = tx.column { root in
            tx.label(bind: route)  // label#0
            let buttons = tx.row { buttons in
                tx.button("Connect") { tx in  // button#0
                    if call != nil { return }
                    let v = tx.voice { tx, r, _ in
                        let line: String
                        switch r {
                        case .voice, .plain, .synthetic: line = "voice playing"
                        case .failed: line = "voice failed"
                        case .none: line = "voice none"
                        }
                        tx.write(route, .str(line))
                    }
                    call = v
                    peer.withLock { $0 = Sends(on: true) }
                    let frames = app.surfaceFrames(view)
                    let writer = v.writer
                    let t = Thread { runPeer(peer, frames, writer) }
                    thread = t
                    t.start()
                }
                tx.button("Change") { _ in  // button#1
                    peer.withLock {
                        $0.rgb = 0xC83C1E
                        $0.width = 1280
                        $0.height = 720
                        $0.hz = 440
                    }
                }
                tx.button("Quiet") { _ in peer.withLock { $0.hz = 0 } }  // button#2
                tx.button("Hang up") { tx in  // button#3
                    guard let v = call else { return }
                    peer.withLock { $0.on = false }
                    while thread?.isFinished == false { Thread.sleep(forTimeInterval: 0.005) }
                    tx.releaseVoice(v)
                    call = nil
                    tx.write(route, .str("voice none"))
                }
                return buttons
            }
            _ = buttons
            view = tx.surface()  // surface#0
            tx.setA11yLabel(view, "Peer")
            return root
        }
        tx.mount(root)
    }
}
