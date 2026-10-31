// The Swift binding's far end of a call (docs/capture-plan.md §5): a surface
// showing the frames the app submits and a voice output playing the samples
// it writes, both fed from any thread through a Sendable handle.

internal import CKaya
import Foundation

/// A voice output the app holds: an id in its own space.
public struct KayaVoice: Hashable, Sendable {
    public let id: UInt64

    /// The sample handle, for the thread the samples arrive on.
    public var writer: KayaVoiceWriter { KayaVoiceWriter(id: id) }
}

/// Where a voice output plays: `voice` on the platform's voice path,
/// `plain` where no echo canceller hears it, `synthetic` the harness's own
/// engine, `failed` not at all, `none` until the platform opens it.
public enum KayaVoiceRoute: UInt32, Sendable {
    case none = 0
    case voice = 1
    case plain = 2
    case synthetic = 3
    case failed = 4

    /// The wire's own word.
    public var name: String {
        switch self {
        case .none: return "none"
        case .voice: return "voice"
        case .plain: return "plain"
        case .synthetic: return "synthetic"
        case .failed: return "failed"
        }
    }

    static func fromWire(_ raw: UInt32) -> KayaVoiceRoute {
        guard let known = KayaVoiceRoute(rawValue: raw) else {
            fatalError("kaya: a voice output reports route \(raw), which this build does not know")
        }
        return known
    }
}

/// Where a voice output's samples go, from any thread.
public struct KayaVoiceWriter: Sendable {
    public let id: UInt64

    /// Queue 48 kHz mono s16 samples for the platform's voice path; past
    /// 200 ms ahead of it the oldest are dropped. False once released. Any
    /// thread; no transaction.
    @discardableResult
    public func write(_ samples: [Int16]) -> Bool {
        samples.withUnsafeBufferPointer { kaya_voice_write(id, $0.baseAddress, UInt($0.count)) == 1 }
    }
}

/// Where a surface's frames go, from any thread.
public struct KayaSurfaceFrames: Sendable {
    public let id: UInt64

    /// Show an NV12 frame (the planes with their strides, the time and the
    /// rotation that stands it upright) once the surface's display clock
    /// next ticks, replacing any frame not yet shown; the planes are copied
    /// before it returns. False when the surface is gone. Any thread.
    @discardableResult
    public func submit(
        width: UInt32, height: UInt32, y: [UInt8], yStride: UInt32, uv: [UInt8], uvStride: UInt32,
        timestampNs: UInt64 = 0, rotation: UInt32 = 0
    ) -> Bool {
        precondition(
            y.count >= Int(yStride) * Int(height) && uv.count >= Int(uvStride) * Int(height / 2),
            "kaya: a surface frame's planes are shorter than its strides and height say (docs/capture-plan.md §4)")
        return y.withUnsafeBufferPointer { yp in
            uv.withUnsafeBufferPointer { uvp in
                kaya_surface_submit(
                    id, width, height, yp.baseAddress, yStride, uvp.baseAddress, uvStride, timestampNs, rotation)
                    == 1
            }
        }
    }
}

/// Each voice output's mirror and handler.
final class KayaVoiceMirror {
    var nextVoice: UInt64 = 0
    var routes: [UInt64: KayaVoiceRoute] = [:]
    var onRoute: [UInt64: (KayaAppTx, KayaVoiceRoute, String) throws -> Void] = [:]
}

extension KayaApp {
    /// A voice output's route as last heard: `none` until the platform opens it.
    public func voiceRoute(_ v: KayaVoice) -> KayaVoiceRoute {
        voices.routes[v.id] ?? .none
    }

    /// The route the platform opened the voice output on, and what the
    /// backend measured of it.
    public func onVoiceRoute(_ v: KayaVoice, _ handler: @escaping (KayaAppTx, KayaVoiceRoute, String) throws -> Void) {
        voices.onRoute[v.id] = handler
    }

    /// A surface's frame handle, for the thread the frames arrive on.
    public func surfaceFrames(_ surface: KayaWidget) -> KayaSurfaceFrames {
        KayaSurfaceFrames(id: surface.id)
    }

    /// The ring loop's voice arm: the mirror first, then the handler.
    func voiceOccurrence(
        _ kind: UInt16, _ id: UInt64, _ tail: [KayaValue], _ run: (@escaping (KayaAppTx) throws -> Void) -> Void
    ) -> Bool {
        guard kind == UInt16(KAYA_OCCURRENCE_VOICE_CHANGED) else { return false }
        let route = KayaVoiceRoute.fromWire(UInt32(kayaInt(tail[0])))
        let detail = kayaStr(tail[1])
        voices.routes[id] = route
        if let h = voices.onRoute[id] { run { tx in try h(tx, route, detail) } }
        return true
    }
}

extension KayaAppTx {
    /// A voice output (docs/capture-plan.md §5): it plays what its writer
    /// writes on the platform's voice path, where its echo canceller hears
    /// it. `onRoute` hears the route the platform opened it on.
    @discardableResult
    public func voice(onRoute: ((KayaAppTx, KayaVoiceRoute, String) throws -> Void)? = nil) -> KayaVoice {
        app.voices.nextVoice += 1
        let v = KayaVoice(id: app.voices.nextVoice)
        tx.createVoice(v.id)
        if let onRoute { app.onVoiceRoute(v, onRoute) }
        return v
    }

    /// Stop and forget a voice output; what it still holds is dropped.
    public func releaseVoice(_ v: KayaVoice) {
        tx.releaseVoice(v.id)
    }
}
