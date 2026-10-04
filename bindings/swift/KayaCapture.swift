// The Swift binding's capture surface (docs/capture-plan.md): the capture
// object the app holds, the video view previewing one, the permission and
// device readings, and the frame and sample callbacks that run on kaya's
// capture thread.

internal import CKaya
import Foundation
import os

/// A capture the app holds (docs/capture-plan.md §2): an id in its own space.
public struct KayaCapture: Hashable, Sendable {
    public let id: UInt64
}

public enum KayaCaptureState: UInt32, Sendable {
    case idle = 0
    case starting = 1
    case running = 2
    case interrupted = 3
    case failed = 4

    /// The wire's own word.
    public var name: String {
        switch self {
        case .idle: return "idle"
        case .starting: return "starting"
        case .running: return "running"
        case .interrupted: return "interrupted"
        case .failed: return "failed"
        }
    }

    static func fromWire(_ raw: UInt32) -> KayaCaptureState {
        guard let known = KayaCaptureState(rawValue: raw) else {
            fatalError("kaya: a capture reports state \(raw), which this build does not know")
        }
        return known
    }
}

/// Why a capture cannot run: the closed reason (docs/capture-plan.md §2
/// rule 2), the platform's sentence beside it.
public enum KayaCaptureFailure: UInt32, Sendable {
    case denied = 1
    case notFound = 2
    case inUse = 3
    case disconnected = 4
    case unsupported = 5
    case hardwareError = 6
    case timeout = 7

    /// The wire's own word.
    public var name: String {
        switch self {
        case .denied: return "denied"
        case .notFound: return "not_found"
        case .inUse: return "in_use"
        case .disconnected: return "disconnected"
        case .unsupported: return "unsupported"
        case .hardwareError: return "hardware_error"
        case .timeout: return "timeout"
        }
    }

    static func fromWire(_ raw: UInt32) -> KayaCaptureFailure? {
        if raw == UInt32(KAYA_CAPTURE_FAILURE_NONE) { return nil }
        guard let known = KayaCaptureFailure(rawValue: raw) else {
            fatalError("kaya: a capture reports failure \(raw), which this build does not know")
        }
        return known
    }
}

/// Why a running capture paused (docs/capture-plan.md §2 rule 3): a state
/// that ends by itself, never a failure.
public enum KayaCaptureInterruption: UInt32, Sendable {
    case background = 1
    case anotherApp = 2
    case systemPressure = 3

    /// The wire's own word.
    public var name: String {
        switch self {
        case .background: return "background"
        case .anotherApp: return "another_app"
        case .systemPressure: return "system_pressure"
        }
    }

    static func fromWire(_ raw: UInt32) -> KayaCaptureInterruption? {
        if raw == UInt32(KAYA_CAPTURE_INTERRUPTION_NONE) { return nil }
        guard let known = KayaCaptureInterruption(rawValue: raw) else {
            fatalError("kaya: a capture reports interruption \(raw), which this build does not know")
        }
        return known
    }
}

public enum KayaCaptureKind: UInt32, Sendable {
    case camera = 0
    case microphone = 1

    /// The wire's own word.
    public var name: String {
        switch self {
        case .camera: return "camera"
        case .microphone: return "microphone"
        }
    }

    static func fromWire(_ raw: UInt32) -> KayaCaptureKind {
        guard let known = KayaCaptureKind(rawValue: raw) else {
            fatalError("kaya: a capture names kind \(raw), which this build does not know")
        }
        return known
    }
}

public enum KayaCameraFacing: UInt32, Sendable {
    case unknown = 0
    case front = 1
    case back = 2
    case external = 3

    /// The wire's own word.
    public var name: String {
        switch self {
        case .unknown: return "unknown"
        case .front: return "front"
        case .back: return "back"
        case .external: return "external"
        }
    }

    static func fromWire(_ raw: UInt32) -> KayaCameraFacing {
        guard let known = KayaCameraFacing(rawValue: raw) else {
            fatalError("kaya: a camera faces \(raw), which this build does not know")
        }
        return known
    }
}

/// A kind's permission, the web's three (Apple's restricted is denied).
public enum KayaPermission: UInt32, Sendable {
    case prompt = 0
    case granted = 1
    case denied = 2

    /// The wire's own word.
    public var name: String {
        switch self {
        case .prompt: return "prompt"
        case .granted: return "granted"
        case .denied: return "denied"
        }
    }

    static func fromWire(_ raw: UInt32) -> KayaPermission {
        guard let known = KayaPermission(rawValue: raw) else {
            fatalError("kaya: a permission reads \(raw), which this build does not know")
        }
        return known
    }
}

/// A capture's readings, as the core last published them; the format the
/// platform chose, 0x0 at 0 with no camera running.
public struct KayaCaptureReading: Sendable, Equatable {
    public var state: KayaCaptureState = .idle
    public var failure: KayaCaptureFailure? = nil
    public var interruption: KayaCaptureInterruption? = nil
    public var width: UInt32 = 0
    public var height: UInt32 = 0
    public var frameRate: UInt32 = 0
}

/// A camera or a microphone as the platform lists it; `preferred` marks the
/// one the user chose for the system.
public struct KayaCaptureDevice: Sendable, Equatable {
    public let id: String
    public let name: String
    public let kind: KayaCaptureKind
    public let facing: KayaCameraFacing
    public let preferred: Bool
}

/// One NV12 frame (docs/capture-plan.md §4): the Y plane `yStride` bytes a
/// row, the interleaved UV plane at half resolution `uvStride` bytes a row,
/// its time on the capture's clock and the rotation that stands it upright.
/// BORROWED FOR THE CALL, as in C and Rust: the planes are kaya's and are
/// gone when the callback returns, so copy (`Array(frame.y)`) to keep them.
public struct KayaCaptureFrame {
    public let width: UInt32
    public let height: UInt32
    public let y: UnsafeBufferPointer<UInt8>
    public let uv: UnsafeBufferPointer<UInt8>
    public let yStride: UInt32
    public let uvStride: UInt32
    public let timestampNs: UInt64
    public let rotation: UInt32

    init(_ f: CKaya.KayaCaptureFrame) {
        width = f.width
        height = f.height
        yStride = f.y_stride
        uvStride = f.uv_stride
        timestampNs = f.timestamp_ns
        rotation = f.rotation
        y = UnsafeBufferPointer(start: f.y, count: Int(f.y_stride) * Int(f.height))
        uv = UnsafeBufferPointer(start: f.uv, count: Int(f.uv_stride) * ((Int(f.height) + 1) / 2))
    }
}

/// The app's frame callback: RUNS ON KAYA'S CAPTURE THREAD, NOT THE APP
/// THREAD, holds no transaction (post to touch the scene), and is handed a
/// frame borrowed for the call. @Sendable, so a callback holding the app or
/// a transaction does not compile.
public typealias KayaCaptureFrameCallback = @Sendable (KayaCaptureFrame) -> Void

/// The app's sample callback: RUNS ON KAYA'S CAPTURE THREAD, NOT THE APP
/// THREAD, holds no transaction (post to touch the scene). 480 samples of
/// 48 kHz mono s16 BORROWED FOR THE CALL, and the first one's time.
public typealias KayaCaptureSamplesCallback = @Sendable (UnsafeBufferPointer<Int16>, UInt64) -> Void

/// The callbacks by capture id, process-wide as the core's sinks are. The
/// core holds the capture's id as the callback's context, never a pointer
/// into this table, so a callback dropped here while a frame is in flight
/// leaves nothing dangling.
struct KayaCaptureSinks: Sendable {
    var frames: [UInt64: KayaCaptureFrameCallback] = [:]
    var samples: [UInt64: KayaCaptureSamplesCallback] = [:]
}

let kayaCaptureSinks = OSAllocatedUnfairLock(initialState: KayaCaptureSinks())

func kayaCaptureContext(_ id: UInt64) -> UnsafeMutableRawPointer? {
    UnsafeMutableRawPointer(bitPattern: UInt(id))
}

func kayaCaptureId(_ ctx: UnsafeMutableRawPointer?) -> UInt64 {
    UInt64(UInt(bitPattern: ctx))
}

/// What kaya's capture thread calls for a frame: the app's callback, if the
/// capture still has one.
func kayaCaptureFrameCall(_ ctx: UnsafeMutableRawPointer?, _ frame: UnsafePointer<CKaya.KayaCaptureFrame>?) {
    let id = kayaCaptureId(ctx)
    guard let frame, let f = kayaCaptureSinks.withLock({ $0.frames[id] }) else { return }
    f(KayaCaptureFrame(frame.pointee))
}

/// What kaya's capture thread calls for a chunk.
func kayaCaptureSamplesCall(
    _ ctx: UnsafeMutableRawPointer?, _ samples: UnsafePointer<Int16>?, _ count: UInt, _ at: UInt64
) {
    let id = kayaCaptureId(ctx)
    guard let f = kayaCaptureSinks.withLock({ $0.samples[id] }) else { return }
    f(UnsafeBufferPointer(start: samples, count: Int(count)), at)
}

/// Each capture's mirror and handlers.
final class KayaCaptureMirror {
    var nextCapture: UInt64 = 0
    var readings: [UInt64: KayaCaptureReading] = [:]
    var permissions: [KayaCaptureKind: KayaPermission] = [:]
    var devices: [KayaCaptureDevice] = []
    var onState: [UInt64: (KayaAppTx, KayaCaptureReading) throws -> Void] = [:]
    var onFailed: [UInt64: (KayaAppTx, KayaCaptureFailure, String) throws -> Void] = [:]
    var onOverrun: [UInt64: (KayaAppTx, UInt64) throws -> Void] = [:]
    var onPermission: ((KayaAppTx, KayaCaptureKind, KayaPermission) throws -> Void)?
    var onDevices: ((KayaAppTx, [KayaCaptureDevice]) throws -> Void)?
}

extension KayaApp {
    func allocCapture() -> KayaCapture {
        captures.nextCapture += 1
        return KayaCapture(id: captures.nextCapture)
    }

    /// A capture's readings, as of the last occurrence this loop took.
    public func capture(_ c: KayaCapture) -> KayaCaptureReading {
        captures.readings[c.id] ?? KayaCaptureReading()
    }

    /// A kind's permission as last heard: `prompt` until the platform says.
    public func permission(_ kind: KayaCaptureKind) -> KayaPermission {
        captures.permissions[kind] ?? .prompt
    }

    /// The cameras and microphones as last listed (watch them with
    /// `watchCaptureDevices`).
    public var captureDevices: [KayaCaptureDevice] { captures.devices }

    /// Every state the capture moves to, failed included.
    public func onCaptureState(
        _ c: KayaCapture, _ handler: @escaping (KayaAppTx, KayaCaptureReading) throws -> Void
    ) {
        captures.onState[c.id] = handler
    }

    /// The capture cannot run: the closed reason, and the platform's sentence.
    public func onCaptureFailed(
        _ c: KayaCapture, _ handler: @escaping (KayaAppTx, KayaCaptureFailure, String) throws -> Void
    ) {
        captures.onFailed[c.id] = handler
    }

    /// The sample callback fell this many ms behind the microphone.
    public func onCaptureOverrun(_ c: KayaCapture, _ handler: @escaping (KayaAppTx, UInt64) throws -> Void) {
        captures.onOverrun[c.id] = handler
    }

    /// A kind's permission moved or was asked about.
    public func onPermission(_ handler: @escaping (KayaAppTx, KayaCaptureKind, KayaPermission) throws -> Void) {
        captures.onPermission = handler
    }

    /// The device list, as watching starts and whenever it changes.
    public func onCaptureDevices(_ handler: @escaping (KayaAppTx, [KayaCaptureDevice]) throws -> Void) {
        captures.onDevices = handler
    }

    /// Run `f` for each frame of `c` (docs/capture-plan.md §4). IT RUNS ON
    /// KAYA'S CAPTURE THREAD, NOT THE APP THREAD, and holds no transaction:
    /// to touch the scene, `post`. The frame is borrowed for the call; the
    /// next one is dropped while `f` still runs. nil drops the callback, as
    /// releasing the capture does.
    public func onCaptureFrame(_ c: KayaCapture, _ f: KayaCaptureFrameCallback?) {
        KayaApp.requireAppThread()
        kayaCaptureSinks.withLock { $0.frames[c.id] = f }
        if f == nil {
            kaya_capture_on_frame(c.id, nil, nil)
        } else {
            kaya_capture_on_frame(c.id, { ctx, frame in kayaCaptureFrameCall(ctx, frame) }, kayaCaptureContext(c.id))
        }
    }

    /// Run `f` for every 10 ms of `c`'s microphone: 480 samples of 48 kHz
    /// mono s16, borrowed for the call, and the first one's time. IT RUNS ON
    /// KAYA'S CAPTURE THREAD, NOT THE APP THREAD, and holds no transaction:
    /// to touch the scene, `post`. None is dropped; a callback slower than
    /// the microphone is told through `onCaptureOverrun`.
    public func onCaptureSamples(_ c: KayaCapture, _ f: KayaCaptureSamplesCallback?) {
        KayaApp.requireAppThread()
        kayaCaptureSinks.withLock { $0.samples[c.id] = f }
        if f == nil {
            kaya_capture_on_samples(c.id, nil, nil)
        } else {
            kaya_capture_on_samples(
                c.id, { ctx, samples, count, at in kayaCaptureSamplesCall(ctx, samples, count, at) },
                kayaCaptureContext(c.id))
        }
    }

    /// The ring loop's capture arm: the mirror is folded BEFORE any handler
    /// runs. Answers false for a record that is not the capture family's.
    func captureOccurrence(
        _ kind: UInt16, _ id: UInt64, _ payload: KayaValue?, _ tail: [KayaValue],
        _ run: (@escaping (KayaAppTx) throws -> Void) -> Void
    ) -> Bool {
        switch kind {
        case UInt16(KAYA_OCCURRENCE_CAPTURE_CHANGED):
            let r = KayaCaptureReading(
                state: KayaCaptureState.fromWire(UInt32(kayaInt(tail[0]))),
                failure: KayaCaptureFailure.fromWire(UInt32(kayaInt(tail[1]))),
                interruption: KayaCaptureInterruption.fromWire(UInt32(kayaInt(tail[2]))),
                width: UInt32(kayaInt(tail[3])), height: UInt32(kayaInt(tail[4])),
                frameRate: UInt32(kayaInt(tail[5])))
            let detail = kayaStr(tail[6])
            captures.readings[id] = r
            if let h = captures.onState[id] { run { tx in try h(tx, r) } }
            if r.state == .failed, let why = r.failure, let h = captures.onFailed[id] {
                run { tx in try h(tx, why, detail) }
            }
        case UInt16(KAYA_OCCURRENCE_CAPTURE_PERMISSION):
            let k = KayaCaptureKind.fromWire(UInt32(kayaInt(tail[0])))
            let p = KayaPermission.fromWire(UInt32(kayaInt(tail[1])))
            captures.permissions[k] = p
            if let h = captures.onPermission { run { tx in try h(tx, k, p) } }
        case UInt16(KAYA_OCCURRENCE_CAPTURE_DEVICES):
            var list: [KayaCaptureDevice] = []
            var at = 1
            while at + 5 <= tail.count {
                guard case .bool(let preferred) = tail[at + 4] else {
                    fatalError("kaya: a capture device's preferred mark rides as \(tail[at + 4])")
                }
                list.append(KayaCaptureDevice(
                    id: kayaStr(tail[at]), name: kayaStr(tail[at + 1]),
                    kind: KayaCaptureKind.fromWire(UInt32(kayaInt(tail[at + 2]))),
                    facing: KayaCameraFacing.fromWire(UInt32(kayaInt(tail[at + 3]))),
                    preferred: preferred))
                at += 5
            }
            captures.devices = list
            if let h = captures.onDevices { run { tx in try h(tx, list) } }
        case UInt16(KAYA_OCCURRENCE_CAPTURE_OVERRUN):
            // The surface-pair class: `id` is behind_ms, the capture rides.
            guard case .i64(let raw) = payload else { return true }
            let capture = UInt64(bitPattern: raw)
            let behind = id
            if let h = captures.onOverrun[capture] { run { tx in try h(tx, behind) } }
        default:
            return false
        }
        return true
    }
}

extension KayaAppTx {
    /// A capture (docs/capture-plan.md §2): at most one camera and one
    /// microphone, with no place in the layout. Preview it with
    /// `video(capture:)`; `startCapture` it once its devices are set.
    @discardableResult
    public func capture(
        camera: String? = nil, microphone: String? = nil, size: (Double, Double)? = nil,
        frameRate: Double? = nil, muted: Bool? = nil,
        onState: ((KayaAppTx, KayaCaptureReading) throws -> Void)? = nil,
        onFailed: ((KayaAppTx, KayaCaptureFailure, String) throws -> Void)? = nil,
        onOverrun: ((KayaAppTx, UInt64) throws -> Void)? = nil
    ) -> KayaCapture {
        let c = app.allocCapture()
        tx.createCapture(c.id)
        if let camera { captureCamera(c, camera) }
        if let microphone { captureMicrophone(c, microphone) }
        if let size { captureSize(c, width: size.0, height: size.1) }
        if let frameRate { captureFrameRate(c, frameRate) }
        if let muted { captureMuted(c, muted) }
        if let onState { app.onCaptureState(c, onState) }
        if let onFailed { app.onCaptureFailed(c, onFailed) }
        if let onOverrun { app.onCaptureOverrun(c, onOverrun) }
        return c
    }

    func captureProp(_ c: KayaCapture, _ prop: Int32, _ value: KayaValue) {
        tx.setCaptureProp(c.id, UInt32(prop), value)
    }

    /// The camera, by a device's id; nil closes it and puts its indicator out.
    public func captureCamera(_ c: KayaCapture, _ device: String?) {
        captureProp(c, KAYA_CPROP_CAMERA, .str(device ?? ""))
    }

    /// The microphone, as `captureCamera`.
    public func captureMicrophone(_ c: KayaCapture, _ device: String?) {
        captureProp(c, KAYA_CPROP_MICROPHONE, .str(device ?? ""))
    }

    /// The picture size wished for, met by the platform's nearest format.
    public func captureSize(_ c: KayaCapture, width: Double, height: Double) {
        captureProp(c, KAYA_CPROP_WIDTH, .f64(width))
        captureProp(c, KAYA_CPROP_HEIGHT, .f64(height))
    }

    public func captureFrameRate(_ c: KayaCapture, _ rate: Double) {
        captureProp(c, KAYA_CPROP_FRAME_RATE, .f64(rate))
    }

    /// The microphone stays open and delivers silence, as a call's mute.
    public func captureMuted(_ c: KayaCapture, _ on: Bool) {
        captureProp(c, KAYA_CPROP_MUTED, .bool(on))
    }

    /// Open the devices, asking for each kind's permission still at
    /// `prompt`; the answer is the capture's own state.
    public func startCapture(_ c: KayaCapture) {
        tx.captureCommand(c.id, UInt32(KAYA_CAPTURE_COMMAND_START))
    }

    public func stopCapture(_ c: KayaCapture) {
        tx.captureCommand(c.id, UInt32(KAYA_CAPTURE_COMMAND_STOP))
    }

    /// Stop and forget a capture; its frame and sample callbacks are dropped
    /// with it (put back if this transaction rolls back).
    public func releaseCapture(_ c: KayaCapture) {
        tx.releaseCapture(c.id)
        let dropped = kayaCaptureSinks.withLock { sinks in
            (sinks.frames.removeValue(forKey: c.id), sinks.samples.removeValue(forKey: c.id))
        }
        rollbackActions.append {
            kayaCaptureSinks.withLock { sinks in
                if let f = dropped.0 { sinks.frames[c.id] = f }
                if let s = dropped.1 { sinks.samples[c.id] = s }
            }
        }
    }

    /// Ask for a kind's permission before any capture starts; the answer
    /// arrives through `onPermission`.
    public func requestPermission(_ kind: KayaCaptureKind) {
        tx.requestPermission(kind.rawValue)
    }

    /// List the cameras and microphones now and whenever one comes or goes
    /// (`onCaptureDevices`); false stops.
    public func watchCaptureDevices(_ on: Bool) {
        tx.watchCaptureDevices(on ? 1 : 0)
    }

    /// A video view previewing `capture` (docs/capture-plan.md §3): the
    /// player's view one source over, mirrored for a front camera. Live zone
    /// only; a view shows a player or a capture.
    @discardableResult
    public func video(
        capture: KayaCapture, fit: KayaFit? = nil, aspect: (Int, Int)? = nil,
        onVisibility: ((KayaAppTx, Double) throws -> Void)? = nil, grow: Double? = nil
    ) -> KayaWidget {
        let w = widget(UInt32(KAYA_KIND_VIDEO))
        tx.setCapture(w.id, Int64(bitPattern: capture.id))
        if let fit { tx.setFit(w.id, fit.rawValue) }
        if let aspect { tx.setAspect(w.id, kayaAspect(aspect.0, aspect.1)) }
        if let onVisibility { app.onVisibility(w, onVisibility) }
        if let grow { setGrow(w, grow) }
        return w
    }

    /// Preview another capture in a live video view, or none (nil).
    public func showCapture(_ video: KayaWidget, _ c: KayaCapture?) {
        tx.setCapture(video.id, Int64(bitPattern: c?.id ?? 0))
    }
}
