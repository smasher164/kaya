// The Swift binding's media surface (docs/media-plan.md): the player object
// the app holds, the video view that shows one (KayaAppTx.video and
// KayaTpl.video in KayaApp.swift), the one session, the mirror of each
// player's readings and the capability query.

internal import CKaya
import Foundation

/// A media player the app holds (docs/media-plan.md §2): an id in its own
/// space, 0 naming none. A row's player field is this type; `.none` is a row
/// showing nothing.
public struct KayaPlayer: Hashable, Sendable {
    public let id: UInt64

    public static let none = KayaPlayer(id: 0)
}

/// A row's player field read back off the wire (the generated init(values:)).
public func kayaPlayer(packed: Int64) -> KayaPlayer { KayaPlayer(id: UInt64(bitPattern: packed)) }

/// Where a player reads its media from: an asset under the app's asset root,
/// an http(s) URL, or a file the user picked. Never bytes.
public struct KayaMediaSource: Sendable {
    enum Named: Sendable {
        case text(String)
        case picked(UInt64)
    }

    let named: Named

    public static func asset(_ name: String) -> KayaMediaSource { KayaMediaSource(named: .text(name)) }

    public static func url(_ url: String) -> KayaMediaSource { KayaMediaSource(named: .text(url)) }

    /// The picked file itself, which the platform's player opens however the
    /// platform names it: a path, a content:// URI, an iOS URL.
    public static func picked(_ file: KayaPickedFile) -> KayaMediaSource {
        KayaMediaSource(named: .picked(file.handle))
    }

    var value: KayaValue {
        switch named {
        case .text(let s): return .str(s)
        case .picked(let handle): return .i64(Int64(handle))
        }
    }
}

public enum KayaPlayerState: UInt32, Sendable {
    case idle = 0
    case loading = 1
    case ready = 2
    case playing = 3
    case paused = 4
    case ended = 5
    case failed = 6

    /// The wire's own word.
    public var name: String {
        switch self {
        case .idle: return "idle"
        case .loading: return "loading"
        case .ready: return "ready"
        case .playing: return "playing"
        case .paused: return "paused"
        case .ended: return "ended"
        case .failed: return "failed"
        }
    }

    static func fromWire(_ raw: UInt32) -> KayaPlayerState {
        guard let known = KayaPlayerState(rawValue: raw) else {
            fatalError("kaya: a player reports state \(raw), which this build does not know")
        }
        return known
    }
}

/// Why a player cannot play: the closed reason (docs/media-plan.md §7a).
public enum KayaMediaFailure: UInt32, Sendable {
    case unsupportedCodec = 1
    case unsupportedContainer = 2
    case notFound = 3
    case network = 4
    case decodeError = 5
    case resources = 6
    case timeout = 7
    /// A reader's read for a track its source lacks (§8 ruling 4).
    case noTrack = 8

    /// The wire's own word.
    public var name: String {
        switch self {
        case .unsupportedCodec: return "unsupported_codec"
        case .unsupportedContainer: return "unsupported_container"
        case .notFound: return "not_found"
        case .network: return "network"
        case .decodeError: return "decode_error"
        case .resources: return "resources"
        case .timeout: return "timeout"
        case .noTrack: return "no_track"
        }
    }

    static func fromWire(_ raw: UInt32) -> KayaMediaFailure? {
        if raw == UInt32(KAYA_MEDIA_FAILURE_NONE) { return nil }
        guard let known = KayaMediaFailure(rawValue: raw) else {
            fatalError("kaya: a player reports failure \(raw), which this build does not know")
        }
        return known
    }
}

/// How a video view fits its picture (docs/media-plan.md §3).
public enum KayaFit: Int64, Sendable {
    case contain = 0
    case cover = 1
    case fill = 2
}

/// What the system shows while no player is attached to the session.
public enum KayaPlaybackState: UInt32, Sendable {
    case none = 0
    case playing = 1
    case paused = 2
}

/// The actions a session may answer itself (docs/media-plan.md §5).
public enum KayaSessionActionKind: UInt32, Sendable {
    case play = 1
    case pause = 2
    case stop = 3
    case seekTo = 4
    case seekForward = 5
    case seekBackward = 6
    case next = 7
    case previous = 8
}

/// An action the system's media controls sent, `seekTo` with its ms.
public enum KayaSessionAction: Equatable, Sendable {
    case play
    case pause
    case stop
    case seekTo(UInt64)
    case seekForward
    case seekBackward
    case next
    case previous

    public var kind: KayaSessionActionKind {
        switch self {
        case .play: return .play
        case .pause: return .pause
        case .stop: return .stop
        case .seekTo: return .seekTo
        case .seekForward: return .seekForward
        case .seekBackward: return .seekBackward
        case .next: return .next
        case .previous: return .previous
        }
    }

    static func fromWire(_ raw: UInt32, _ atMs: UInt64) -> KayaSessionAction {
        switch KayaSessionActionKind(rawValue: raw) {
        case .play: return .play
        case .pause: return .pause
        case .stop: return .stop
        case .seekTo: return .seekTo(atMs)
        case .seekForward: return .seekForward
        case .seekBackward: return .seekBackward
        case .next: return .next
        case .previous: return .previous
        case nil: fatalError("kaya: the session sent action \(raw), which this build does not know")
        }
    }
}

/// A player's readings, as the core last published them.
public struct KayaPlayerReading: Sendable {
    public var state: KayaPlayerState = .idle
    public var failure: KayaMediaFailure? = nil
    public var positionMs: UInt64 = 0
    public var durationMs: UInt64 = 0
    /// The picture's size; 0x0 for audio.
    public var width: UInt32 = 0
    public var height: UInt32 = 0
}

/// A player's tracks (docs/media-plan.md §3): BCP 47 tags in the platform's
/// order, a sidecar caption track last, and the selections (0-based).
public struct KayaTracks: Equatable, Sendable {
    public var audio: [String] = []
    public var captions: [String] = []
    public var audioSelected: Int? = nil
    public var captionSelected: Int? = nil
}

/// Each player's mirror and handlers, and the session's.
final class KayaMediaState {
    var nextPlayer: UInt64 = 0
    var readings: [UInt64: KayaPlayerReading] = [:]
    var tracks: [UInt64: KayaTracks] = [:]
    var cues: [UInt64: String] = [:]
    var onState: [UInt64: (KayaAppTx, KayaPlayerState) throws -> Void] = [:]
    var onEnded: [UInt64: (KayaAppTx) throws -> Void] = [:]
    var onFailed: [UInt64: (KayaAppTx, KayaMediaFailure, String) throws -> Void] = [:]
    var onSeekCompleted: [UInt64: (KayaAppTx, UInt64) throws -> Void] = [:]
    var onPosition: [UInt64: (KayaAppTx, UInt64) throws -> Void] = [:]
    var onTracks: [UInt64: (KayaAppTx, KayaTracks) throws -> Void] = [:]
    var onCue: [UInt64: (KayaAppTx, String) throws -> Void] = [:]
    var widgetVisibility: [UInt64: (KayaAppTx, Double) throws -> Void] = [:]
    var nodeVisibility: [UInt64: (KayaAppTx, [KayaValue], Double) throws -> Void] = [:]
    var onSession: ((KayaAppTx, KayaSessionAction) throws -> Void)?
}

func kayaInt(_ v: KayaValue) -> Int64 {
    if case .i64(let n) = v { return n }
    fatalError("kaya: a media record carries \(v) where an integer rides")
}

func kayaStr(_ v: KayaValue) -> String {
    if case .str(let s) = v { return s }
    fatalError("kaya: a media record carries \(v) where a string rides")
}

/// A track list off the flat record's tail: its count, then its tags.
func kayaTrackList(_ tail: [KayaValue], _ at: inout Int) -> [String] {
    let n = Int(kayaInt(tail[at]))
    let tags = tail[(at + 1)..<(at + 1 + n)].map(kayaStr)
    at += 1 + n
    return tags
}

extension KayaApp {
    /// Whether this platform plays `mime` with `codecs` (an RFC 6381 list,
    /// "" for none): true exactly when loading such media would not fail as
    /// unsupportedCodec or unsupportedContainer (docs/media-plan.md §8
    /// ruling 1). Any thread, no transaction.
    public static func canPlay(_ mime: String, codecs: String = "") -> Bool {
        let m = Array(mime.utf8)
        let c = Array(codecs.utf8)
        return m.withUnsafeBufferPointer { mp in
            c.withUnsafeBufferPointer { cp in
                kaya_can_play(mp.baseAddress, UInt(mp.count), cp.baseAddress, UInt(cp.count)) != 0
            }
        }
    }

    func allocPlayer() -> KayaPlayer {
        media.nextPlayer += 1
        return KayaPlayer(id: media.nextPlayer)
    }

    /// A player's readings, as of the last occurrence this loop took.
    public func player(_ p: KayaPlayer) -> KayaPlayerReading {
        media.readings[p.id] ?? KayaPlayerReading()
    }

    /// A player's tracks (docs/media-plan.md §3).
    public func tracks(_ p: KayaPlayer) -> KayaTracks {
        media.tracks[p.id] ?? KayaTracks()
    }

    /// The caption cue current on the player's clock, "" for none.
    public func cue(_ p: KayaPlayer) -> String {
        media.cues[p.id] ?? ""
    }

    /// Every state the player moves to, ended and failed included.
    public func onPlayerState(
        _ p: KayaPlayer, _ handler: @escaping (KayaAppTx, KayaPlayerState) throws -> Void
    ) {
        media.onState[p.id] = handler
    }

    /// The player reached its end (never, while it loops).
    public func onEnded(_ p: KayaPlayer, _ handler: @escaping (KayaAppTx) throws -> Void) {
        media.onEnded[p.id] = handler
    }

    /// The player cannot play: the closed reason, and the platform's sentence.
    public func onFailed(
        _ p: KayaPlayer, _ handler: @escaping (KayaAppTx, KayaMediaFailure, String) throws -> Void
    ) {
        media.onFailed[p.id] = handler
    }

    /// Where a seek the app asked for landed, in ms.
    public func onSeekCompleted(_ p: KayaPlayer, _ handler: @escaping (KayaAppTx, UInt64) throws -> Void) {
        media.onSeekCompleted[p.id] = handler
    }

    /// The playhead, every KAYA_MEDIA_POSITION_TICK_MS while playing.
    public func onPosition(_ p: KayaPlayer, _ handler: @escaping (KayaAppTx, UInt64) throws -> Void) {
        media.onPosition[p.id] = handler
    }

    /// The player's track listing or a selection moved.
    public func onTracks(_ p: KayaPlayer, _ handler: @escaping (KayaAppTx, KayaTracks) throws -> Void) {
        media.onTracks[p.id] = handler
    }

    /// The current caption cue changed ("" between cues), whoever draws it.
    public func onCue(_ p: KayaPlayer, _ handler: @escaping (KayaAppTx, String) throws -> Void) {
        media.onCue[p.id] = handler
    }

    /// How much of a live video view shows, 0 to 1, as it enters, leaves,
    /// moves by a tenth and shows whole (docs/media-plan.md §7b).
    public func onVisibility(_ w: KayaWidget, _ handler: @escaping (KayaAppTx, Double) throws -> Void) {
        media.widgetVisibility[w.id] = handler
    }

    /// A stamped video view's visibility, the copy's keys first.
    public func onVisibility(
        _ n: KayaNodeHandle, _ handler: @escaping (KayaAppTx, [KayaValue], Double) throws -> Void
    ) {
        media.nodeVisibility[n.id] = handler
    }

    /// The actions the declared session handles, from the system's media
    /// controls (docs/media-plan.md §5).
    public func onSessionAction(_ handler: @escaping (KayaAppTx, KayaSessionAction) throws -> Void) {
        media.onSession = handler
    }

    /// The ring loop's media arm: the mirror is folded BEFORE any handler
    /// runs, so a handler reads the readings its occurrence brought.
    /// Answers false for a record that is not the media family's.
    func mediaOccurrence(
        _ kind: UInt16, _ id: UInt64, _ keys: [KayaValue], _ payload: KayaValue?,
        _ tail: [KayaValue], _ run: (@escaping (KayaAppTx) throws -> Void) -> Void
    ) -> Bool {
        switch kind {
        case UInt16(KAYA_OCCURRENCE_PLAYER_CHANGED):
            let state = KayaPlayerState.fromWire(UInt32(kayaInt(tail[0])))
            let failure = KayaMediaFailure.fromWire(UInt32(kayaInt(tail[1])))
            let detail = kayaStr(tail[5])
            var r = media.readings[id] ?? KayaPlayerReading()
            r.state = state
            r.failure = failure
            r.durationMs = UInt64(kayaInt(tail[2]))
            r.width = UInt32(kayaInt(tail[3]))
            r.height = UInt32(kayaInt(tail[4]))
            if state == .loading || state == .idle { r.positionMs = 0 }
            media.readings[id] = r
            if let h = media.onState[id] { run { tx in try h(tx, state) } }
            if state == .ended, let h = media.onEnded[id] { run { tx in try h(tx) } }
            if state == .failed, let why = failure, let h = media.onFailed[id] {
                run { tx in try h(tx, why, detail) }
            }
        case UInt16(KAYA_OCCURRENCE_PLAYER_POSITION), UInt16(KAYA_OCCURRENCE_SEEK_COMPLETED):
            // The surface-pair class: the SECOND u64 keys it, so `id` is the
            // position and the player rides as the payload.
            guard case .i64(let raw) = payload else { return true }
            let player = UInt64(bitPattern: raw)
            let ms = id
            media.readings[player, default: KayaPlayerReading()].positionMs = ms
            let table = kind == UInt16(KAYA_OCCURRENCE_PLAYER_POSITION)
                ? media.onPosition : media.onSeekCompleted
            if let h = table[player] { run { tx in try h(tx, ms) } }
        case UInt16(KAYA_OCCURRENCE_PLAYER_TRACKS):
            var at = 2
            var t = KayaTracks()
            t.audio = kayaTrackList(tail, &at)
            t.captions = kayaTrackList(tail, &at)
            let audioSel = kayaInt(tail[0])
            let captionSel = kayaInt(tail[1])
            t.audioSelected = audioSel > 0 ? Int(audioSel) - 1 : nil
            t.captionSelected = captionSel > 0 ? Int(captionSel) - 1 : nil
            media.tracks[id] = t
            if let h = media.onTracks[id] { run { tx in try h(tx, t) } }
        case UInt16(KAYA_OCCURRENCE_CAPTION_CUE):
            let text: String
            if case .str(let s) = payload { text = s } else { text = "" }
            media.cues[id] = text
            if let h = media.onCue[id] { run { tx in try h(tx, text) } }
        case UInt16(KAYA_OCCURRENCE_VIDEO_VISIBILITY):
            guard case .f64(let shown) = payload else { return true }
            if keys.isEmpty {
                if let h = media.widgetVisibility[id] { run { tx in try h(tx, shown) } }
            } else if let h = media.nodeVisibility[id] {
                run { tx in try h(tx, keys, shown) }
            }
        case UInt16(KAYA_OCCURRENCE_SESSION_ACTION):
            let action = KayaSessionAction.fromWire(
                UInt32(kayaInt(tail[0])), UInt64(kayaInt(tail[1])))
            if let h = media.onSession { run { tx in try h(tx, action) } }
        default:
            return false
        }
        return true
    }
}

extension KayaAppTx {
    /// A media player (docs/media-plan.md §2): an object with no place in
    /// the layout. Show it with `video`; shown by none it is audio. The
    /// handlers register as the player is made.
    @discardableResult
    public func player(
        source: KayaMediaSource? = nil, speed: Double? = nil, volume: Double? = nil,
        muted: Bool? = nil, loop: Bool? = nil,
        captions: KayaMediaSource? = nil, captionsLanguage: String = "und",
        onState: ((KayaAppTx, KayaPlayerState) throws -> Void)? = nil,
        onEnded: ((KayaAppTx) throws -> Void)? = nil,
        onFailed: ((KayaAppTx, KayaMediaFailure, String) throws -> Void)? = nil,
        onSeekCompleted: ((KayaAppTx, UInt64) throws -> Void)? = nil,
        onPosition: ((KayaAppTx, UInt64) throws -> Void)? = nil,
        onTracks: ((KayaAppTx, KayaTracks) throws -> Void)? = nil,
        onCue: ((KayaAppTx, String) throws -> Void)? = nil
    ) -> KayaPlayer {
        let p = app.allocPlayer()
        tx.createPlayer(p.id)
        if let speed { playerSpeed(p, speed) }
        if let volume { playerVolume(p, volume) }
        if let muted { playerMuted(p, muted) }
        if let loop { playerLoop(p, loop) }
        if let captions { playerCaptions(p, captions, language: captionsLanguage) }
        if let source { playerSource(p, source) }
        if let onState { app.onPlayerState(p, onState) }
        if let onEnded { app.onEnded(p, onEnded) }
        if let onFailed { app.onFailed(p, onFailed) }
        if let onSeekCompleted { app.onSeekCompleted(p, onSeekCompleted) }
        if let onPosition { app.onPosition(p, onPosition) }
        if let onTracks { app.onTracks(p, onTracks) }
        if let onCue { app.onCue(p, onCue) }
        return p
    }

    func playerProp(_ p: KayaPlayer, _ prop: Int32, _ value: KayaValue) {
        tx.setPlayerProp(p.id, UInt32(prop), value)
    }

    /// Load `source`, replacing what the player held; it reads loading
    /// until the platform answers.
    public func playerSource(_ p: KayaPlayer, _ source: KayaMediaSource) {
        playerProp(p, KAYA_PPROP_SOURCE, source.value)
    }

    /// Unload, back to idle.
    public func clearPlayer(_ p: KayaPlayer) {
        playerProp(p, KAYA_PPROP_SOURCE, .str(""))
    }

    public func playerSpeed(_ p: KayaPlayer, _ rate: Double) {
        playerProp(p, KAYA_PPROP_SPEED, .f64(rate))
    }

    /// 0...1, relative to the system volume.
    public func playerVolume(_ p: KayaPlayer, _ volume: Double) {
        playerProp(p, KAYA_PPROP_VOLUME, .f64(volume))
    }

    public func playerMuted(_ p: KayaPlayer, _ on: Bool) {
        playerProp(p, KAYA_PPROP_MUTED, .bool(on))
    }

    public func playerLoop(_ p: KayaPlayer, _ on: Bool) {
        playerProp(p, KAYA_PPROP_LOOP, .bool(on))
    }

    /// A sidecar WebVTT file for the player (an asset, a picked file or an
    /// http(s) URL), `language` its BCP 47 tag: kaya parses it and draws its
    /// cues, listed as the last caption track (docs/media-plan.md §3).
    public func playerCaptions(_ p: KayaPlayer, _ source: KayaMediaSource, language: String) {
        playerProp(p, KAYA_PPROP_CAPTIONS_LANGUAGE, .str(language))
        playerProp(p, KAYA_PPROP_CAPTIONS, source.value)
    }

    /// No sidecar captions.
    public func clearCaptions(_ p: KayaPlayer) {
        playerProp(p, KAYA_PPROP_CAPTIONS, .str(""))
    }

    /// Play; from the start when the player had ended.
    public func play(_ p: KayaPlayer) {
        tx.playerCommand(p.id, UInt32(KAYA_PLAYER_COMMAND_PLAY), 0)
    }

    public func pause(_ p: KayaPlayer) {
        tx.playerCommand(p.id, UInt32(KAYA_PLAYER_COMMAND_PAUSE), 0)
    }

    /// To `ms` from the start; onSeekCompleted hears where it landed.
    public func seek(_ p: KayaPlayer, to ms: UInt64) {
        tx.playerCommand(p.id, UInt32(KAYA_PLAYER_COMMAND_SEEK), ms)
    }

    public func releasePlayer(_ p: KayaPlayer) {
        tx.releasePlayer(p.id)
    }

    /// Show another player in a live video view, or none (nil). A player is
    /// shown by one video view at a time (docs/media-plan.md §7b).
    public func showPlayer(_ video: KayaWidget, _ p: KayaPlayer?) {
        tx.setPlayer(video.id, Int64(bitPattern: p?.id ?? 0))
    }

    /// How a live video view fits its picture.
    public func setFit(_ video: KayaWidget, _ fit: KayaFit) {
        tx.setFit(video.id, fit.rawValue)
    }

    /// Select audio track `index` (0-based in `app.tracks`).
    public func selectAudio(_ p: KayaPlayer, _ index: Int) {
        tx.selectTrack(p.id, UInt32(KAYA_TRACK_KIND_AUDIO), UInt32(index + 1))
    }

    /// Select a caption track (0-based in `app.tracks`), or none (nil); a
    /// sidecar file's track is selected the same way.
    public func selectCaptions(_ p: KayaPlayer, _ index: Int?) {
        tx.selectTrack(p.id, UInt32(KAYA_TRACK_KIND_CAPTION), index.map { UInt32($0 + 1) } ?? 0)
    }

    /// Declare the app's one media session, replacing the last
    /// (docs/media-plan.md §5): the player the system's controls speak to,
    /// the metadata, the actions the app answers itself through `onAction`
    /// (play, pause and seekTo it leaves out apply to the attached player),
    /// and what the system shows while no player is attached.
    public func session(
        player: KayaPlayer? = nil, title: String = "", artist: String = "", album: String = "",
        artwork: String = "", handles: [KayaSessionActionKind] = [],
        playbackState: KayaPlaybackState = .none,
        onAction: ((KayaAppTx, KayaSessionAction) throws -> Void)? = nil
    ) {
        let mask = handles.reduce(UInt32(0)) { $0 | (1 << $1.rawValue) }
        tx.setSession(
            player?.id ?? 0, mask, playbackState.rawValue,
            .str(title), .str(artist), .str(album), .str(artwork))
        if let onAction { app.onSessionAction(onAction) }
    }
}

extension KayaValue {
    /// A player on the wire — what a row's player field carries.
    public static func player(_ p: KayaPlayer) -> KayaValue { .i64(Int64(bitPattern: p.id)) }
}

// The reader and the core-held images (docs/media-plan.md §8 rulings 3, 4).

/// A media reader: frames and peaks without a player, an id in its own space.
public struct KayaReader: Hashable, Sendable {
    public let id: UInt64
}

/// One read on a reader, an id in its own space.
public struct KayaRead: Hashable, Sendable {
    public let id: UInt64
}

/// A core-held premultiplied RGBA8 image, the app's until it releases it;
/// the canvas's `KayaDraw.image` draws it.
public struct KayaImage: Hashable, Sendable {
    public let id: UInt64
}

/// Which picture answers a time: the keyframe at or before it, or the frame
/// shown at it.
public enum KayaFrameAccuracy: Sendable {
    case keyframe
    case exact

    var wire: UInt32 {
        switch self {
        case .keyframe: return UInt32(KAYA_FRAME_ACCURACY_KEYFRAME)
        case .exact: return UInt32(KAYA_FRAME_ACCURACY_EXACT)
        }
    }
}

/// One requested time answered: which of the times it is, the time asked,
/// the time of the picture the platform returned, and its image.
public struct KayaFrame: Equatable, Sendable {
    public let index: Int
    public let requestedMs: UInt64
    public let actualMs: UInt64
    public let image: KayaImage
    public let width: UInt32
    public let height: UInt32
}

/// A peaks read's answer: a min/max pair per channel per `samplesPerPair`
/// frames, pair-major.
public struct KayaPeaks: Equatable, Sendable {
    public let sampleRate: UInt32
    public let samplesPerPair: UInt32
    public let channels: UInt32
    public let data: [Int16]

    /// How many pairs per channel.
    public var count: Int { channels == 0 ? 0 : data.count / (2 * Int(channels)) }

    /// One pair's (min, max) on one channel.
    public func pair(_ i: Int, channel: Int = 0) -> (min: Int16, max: Int16) {
        let at = (i * Int(channels) + channel) * 2
        return (data[at], data[at + 1])
    }
}

/// A read's end.
public enum KayaReadOutcome: Equatable, Sendable {
    case completed
    case cancelled
    case failed(KayaMediaFailure, String)
}

/// Why an awaited read gave no answer: the reader was closed or the read
/// cancelled under it, or the platform failed it with the player's reason.
/// A cancelled awaiting task throws CancellationError instead.
public enum KayaReadError: Error, Equatable, Sendable {
    case cancelled
    case failed(KayaMediaFailure, String)
}

/// A load_image's answer.
public enum KayaImageLoad: Equatable, Sendable {
    case loaded(width: UInt32, height: UInt32)
    case failed(KayaMediaFailure, String)
}

final class KayaReadHandlers {
    var onFrame: ((KayaAppTx, KayaFrame) throws -> Void)?
    var onProgress: ((KayaAppTx, UInt64, UInt64) throws -> Void)?
    var onPeaks: ((KayaAppTx, KayaPeaks) throws -> Void)?
    var onDone: ((KayaAppTx, KayaReadOutcome) throws -> Void)?
}

final class KayaReadWaiter {
    var frames: [KayaFrame] = []
    var peaks: KayaPeaks?
    var continuation: CheckedContinuation<Void, Error>?
}

/// The reader's ids, its reads in flight, the reads the app gave up on, the
/// handlers and awaiting tasks per read, and the releases the next commit
/// carries.
final class KayaReaderState {
    var nextReader: UInt64 = 0
    var nextRead: UInt64 = 0
    var nextImage: UInt64 = 0
    var inFlight: [UInt64: UInt64] = [:]
    var abandoned: Set<UInt64> = []
    var handlers: [UInt64: KayaReadHandlers] = [:]
    var waiters: [UInt64: KayaReadWaiter] = [:]
    var imageLoads: [UInt64: (KayaAppTx, KayaImageLoad) throws -> Void] = [:]
    var pendingReleases = KayaTx()
}

extension KayaApp {
    /// The releases of images the app never heard, taken and cleared: they
    /// ride the next transaction's bytes.
    func takePendingReleases() -> Data {
        let bytes = readers.pendingReleases.bytes
        readers.pendingReleases = KayaTx()
        return bytes
    }

    /// An image's premultiplied RGBA8 bytes and size; nil for an image
    /// holding none.
    public func imagePixels(_ image: KayaImage) -> (width: UInt32, height: UInt32, bytes: [UInt8])? {
        var w: UInt32 = 0
        var h: UInt32 = 0
        let n = Int(kaya_image_pixels(image.id, nil, 0, &w, &h))
        if n == 0 { return nil }
        var bytes = [UInt8](repeating: 0, count: n)
        let got = bytes.withUnsafeMutableBufferPointer { buf in
            Int(kaya_image_pixels(image.id, buf.baseAddress, UInt(n), &w, &h))
        }
        if got != n { return nil }
        return (w, h, bytes)
    }

    /// The occurrence half of the reader: a read the app gave up on is
    /// heard only by its end, the images its unheard frames carried
    /// released by the next commit; an awaited read's answers go to its
    /// task. Answers false for a record that is not the reader's.
    func readerOccurrence(
        _ kind: UInt16, _ id: UInt64, _ tail: [KayaValue],
        _ run: (@escaping (KayaAppTx) throws -> Void) -> Void
    ) -> Bool {
        let st = readers
        if kind == UInt16(KAYA_OCCURRENCE_IMAGE_LOADED) {
            let failure = KayaMediaFailure.fromWire(UInt32(kayaInt(tail[2])))
            let answer: KayaImageLoad = failure.map { .failed($0, kayaStr(tail[3])) }
                ?? .loaded(width: UInt32(kayaInt(tail[0])), height: UInt32(kayaInt(tail[1])))
            if let h = st.imageLoads.removeValue(forKey: id) { run { tx in try h(tx, answer) } }
            return true
        }
        guard kind == UInt16(KAYA_OCCURRENCE_READER_FRAME)
            || kind == UInt16(KAYA_OCCURRENCE_READER_PROGRESS)
            || kind == UInt16(KAYA_OCCURRENCE_READER_PEAKS)
            || kind == UInt16(KAYA_OCCURRENCE_READER_DONE)
        else { return false }
        let reader = id
        let read = UInt64(bitPattern: kayaInt(tail[0]))
        let done = kind == UInt16(KAYA_OCCURRENCE_READER_DONE)
        if done, st.inFlight[reader] == read { st.inFlight.removeValue(forKey: reader) }
        if st.abandoned.contains(read) {
            if kind == UInt16(KAYA_OCCURRENCE_READER_FRAME) {
                st.pendingReleases.releaseImage(UInt64(bitPattern: kayaInt(tail[1])))
            }
            guard done else { return true }
            st.abandoned.remove(read)
        }
        let waiter = st.waiters[read]
        let handlers = done ? st.handlers.removeValue(forKey: read) : st.handlers[read]
        switch kind {
        case UInt16(KAYA_OCCURRENCE_READER_FRAME):
            let frame = KayaFrame(
                index: Int(kayaInt(tail[2])), requestedMs: UInt64(kayaInt(tail[5])),
                actualMs: UInt64(kayaInt(tail[6])), image: KayaImage(id: UInt64(bitPattern: kayaInt(tail[1]))),
                width: UInt32(kayaInt(tail[3])), height: UInt32(kayaInt(tail[4])))
            if let waiter {
                waiter.frames.append(frame)
            } else if let h = handlers?.onFrame {
                run { tx in try h(tx, frame) }
            }
        case UInt16(KAYA_OCCURRENCE_READER_PROGRESS):
            let doneMs = UInt64(kayaInt(tail[1]))
            let totalMs = UInt64(kayaInt(tail[2]))
            if waiter == nil, let h = handlers?.onProgress { run { tx in try h(tx, doneMs, totalMs) } }
        case UInt16(KAYA_OCCURRENCE_READER_PEAKS):
            let channels = UInt32(kayaInt(tail[3]))
            let length = Int(kayaInt(tail[4]))
            var data = [Int16](repeating: 0, count: length * Int(channels) * 2)
            let n = data.withUnsafeMutableBufferPointer { buf in
                Int(kaya_reader_peaks(reader, read, buf.baseAddress, UInt(buf.count)))
            }
            precondition(
                n == data.count,
                "kaya: read \(read)'s peaks hold \(n) values where its record names \(data.count)")
            let peaks = KayaPeaks(
                sampleRate: UInt32(kayaInt(tail[1])), samplesPerPair: UInt32(kayaInt(tail[2])),
                channels: channels, data: data)
            if let waiter {
                waiter.peaks = peaks
            } else if let h = handlers?.onPeaks {
                run { tx in try h(tx, peaks) }
            }
        default:
            let outcome: KayaReadOutcome
            switch UInt32(kayaInt(tail[1])) {
            case UInt32(KAYA_READ_OUTCOME_COMPLETED): outcome = .completed
            case UInt32(KAYA_READ_OUTCOME_CANCELLED): outcome = .cancelled
            default:
                let why = KayaMediaFailure.fromWire(UInt32(kayaInt(tail[2]))) ?? .decodeError
                outcome = .failed(why, kayaStr(tail[3]))
            }
            if let waiter {
                st.waiters.removeValue(forKey: read)
                switch outcome {
                case .completed:
                    waiter.continuation?.resume()
                case .cancelled:
                    for f in waiter.frames { st.pendingReleases.releaseImage(f.image.id) }
                    waiter.continuation?.resume(throwing: KayaReadError.cancelled)
                case .failed(let why, let detail):
                    for f in waiter.frames { st.pendingReleases.releaseImage(f.image.id) }
                    waiter.continuation?.resume(throwing: KayaReadError.failed(why, detail))
                }
            } else if let h = handlers?.onDone {
                run { tx in try h(tx, outcome) }
            }
        }
        return true
    }

    @KayaAppActor private func awaitRead(
        _ reader: KayaReader, _ send: (KayaAppTx) -> KayaRead
    ) async throws -> KayaReadWaiter {
        requireAsyncBoundary()
        let waiter = KayaReadWaiter()
        let read = build { tx in send(tx) }
        readers.waiters[read.id] = waiter
        let post = self.post
        let readerID = reader.id
        let readID = read.id
        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                    waiter.continuation = c
                }
            } onCancel: {
                post { tx in tx.abandonAwaited(readerID, readID) }
            }
        } catch {
            requireAsyncBoundary()
            throw error
        }
        requireAsyncBoundary()
        return waiter
    }

    /// The pictures at `times` as one awaited read, in index order. A
    /// cancelled task cancels the read and releases the images it carried;
    /// a read that fails or is cancelled releases them too.
    @KayaAppActor public func frames(
        _ reader: KayaReader, at times: [UInt64], maxWidth: UInt32 = 0, maxHeight: UInt32 = 0,
        accuracy: KayaFrameAccuracy = .exact
    ) async throws -> [KayaFrame] {
        let waiter = try await awaitRead(reader) { tx in
            tx.readFrames(reader, at: times, maxWidth: maxWidth, maxHeight: maxHeight, accuracy: accuracy)
        }
        return waiter.frames.sorted { $0.index < $1.index }
    }

    /// The reader's peaks as one awaited read.
    @KayaAppActor public func peaks(_ reader: KayaReader, samplesPerPair: UInt32) async throws -> KayaPeaks {
        let waiter = try await awaitRead(reader) { tx in tx.readPeaks(reader, samplesPerPair: samplesPerPair) }
        return waiter.peaks ?? KayaPeaks(sampleRate: 0, samplesPerPair: samplesPerPair, channels: 0, data: [])
    }
}

extension KayaAppTx {
    /// A media reader on `source` (docs/media-plan.md §8 ruling 4).
    @discardableResult
    public func reader(_ source: KayaMediaSource) -> KayaReader {
        let st = app.readers
        st.nextReader += 1
        let reader = KayaReader(id: st.nextReader)
        tx.openReader(reader.id, source.value)
        return reader
    }

    private func beginRead(
        _ reader: KayaReader, _ handlers: KayaReadHandlers
    ) -> KayaRead {
        let st = app.readers
        st.nextRead += 1
        let read = st.nextRead
        st.inFlight[reader.id] = read
        st.handlers[read] = handlers
        rollbackActions.append {
            st.handlers.removeValue(forKey: read)
            st.waiters.removeValue(forKey: read)
            if st.inFlight[reader.id] == read { st.inFlight.removeValue(forKey: reader.id) }
        }
        return KayaRead(id: read)
    }

    /// One picture per time in `times`, each heard by `onFrame` in the
    /// platform's order and the read's end by `onDone`. A bound of 0 is no
    /// bound on that axis; the aspect is kept. One read in flight per reader.
    @discardableResult
    public func readFrames(
        _ reader: KayaReader, at times: [UInt64], maxWidth: UInt32 = 0, maxHeight: UInt32 = 0,
        accuracy: KayaFrameAccuracy = .exact,
        onFrame: ((KayaAppTx, KayaFrame) throws -> Void)? = nil,
        onDone: ((KayaAppTx, KayaReadOutcome) throws -> Void)? = nil
    ) -> KayaRead {
        let handlers = KayaReadHandlers()
        handlers.onFrame = onFrame
        handlers.onDone = onDone
        let read = beginRead(reader, handlers)
        let st = app.readers
        let first = st.nextImage + 1
        st.nextImage += UInt64(times.count)
        tx.readFrames(
            reader.id, read.id, first, accuracy.wire, maxWidth, maxHeight,
            times.map { .i64(Int64(bitPattern: $0)) })
        return read
    }

    /// The first audio track's peaks, a min/max pair per channel per
    /// `samplesPerPair` frames: progress, then the peaks, then the end.
    @discardableResult
    public func readPeaks(
        _ reader: KayaReader, samplesPerPair: UInt32,
        onProgress: ((KayaAppTx, UInt64, UInt64) throws -> Void)? = nil,
        onPeaks: ((KayaAppTx, KayaPeaks) throws -> Void)? = nil,
        onDone: ((KayaAppTx, KayaReadOutcome) throws -> Void)? = nil
    ) -> KayaRead {
        let handlers = KayaReadHandlers()
        handlers.onProgress = onProgress
        handlers.onPeaks = onPeaks
        handlers.onDone = onDone
        let read = beginRead(reader, handlers)
        tx.readPeaks(reader.id, read.id, samplesPerPair)
        return read
    }

    private func abandon(_ reader: UInt64, _ read: UInt64) {
        let st = app.readers
        let added = st.abandoned.insert(read).inserted
        let wasInFlight = st.inFlight[reader] == read
        if wasInFlight { st.inFlight.removeValue(forKey: reader) }
        rollbackActions.append {
            if added { st.abandoned.remove(read) }
            if wasInFlight { st.inFlight[reader] = read }
        }
    }

    /// Stop a read: it ends cancelled, and nothing else of it is heard.
    public func cancelRead(_ reader: KayaReader, _ read: KayaRead) {
        abandon(reader.id, read.id)
        tx.cancelRead(reader.id, read.id)
    }

    /// Forget a reader, cancelling its read in flight: that read is heard
    /// only by its end. The images it answered with stay the app's.
    public func closeReader(_ reader: KayaReader) {
        if let read = app.readers.inFlight[reader.id] { abandon(reader.id, read) }
        tx.closeReader(reader.id)
    }

    /// An awaiting task was cancelled: its read is cancelled and the images
    /// it carried go back.
    func abandonAwaited(_ reader: UInt64, _ read: UInt64) {
        let st = app.readers
        guard let waiter = st.waiters.removeValue(forKey: read) else { return }
        for f in waiter.frames { tx.releaseImage(f.image.id) }
        abandon(reader, read)
        tx.cancelRead(reader, read)
        waiter.continuation?.resume(throwing: CancellationError())
    }

    /// An image decoded by kaya from an asset or a picked file, heard by
    /// `onLoaded`; a drawing may name it in the same transaction.
    @discardableResult
    public func loadImage(
        _ source: KayaMediaSource, onLoaded: ((KayaAppTx, KayaImageLoad) throws -> Void)? = nil
    ) -> KayaImage {
        let st = app.readers
        st.nextImage += 1
        let image = st.nextImage
        if let onLoaded {
            st.imageLoads[image] = onLoaded
            rollbackActions.append { st.imageLoads.removeValue(forKey: image) }
        }
        tx.loadImage(image, source.value)
        return KayaImage(id: image)
    }

    public func releaseImage(_ image: KayaImage) {
        tx.releaseImage(image.id)
    }
}
