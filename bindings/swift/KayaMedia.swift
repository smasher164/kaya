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

    /// The wire's own word.
    public var name: String {
        switch self {
        case .unsupportedCodec: return "unsupported_codec"
        case .unsupportedContainer: return "unsupported_container"
        case .notFound: return "not_found"
        case .network: return "network"
        case .decodeError: return "decode_error"
        case .resources: return "resources"
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
