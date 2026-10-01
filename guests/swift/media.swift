// The media suite, Swift port — guests/rust/media.rs,
// tools/scenes/media_{formats,delivery,session,tracks,feed}.steps,
// docs/media-plan.md §7a, §7b.

import Foundation
import Kaya

struct Item {
    let name: String
    let source: KayaMediaSource
    let mime: String
    let codecs: String
}

func local(_ name: String, _ mime: String, _ codecs: String) -> Item {
    Item(name: name, source: .asset("media/\(name)"), mime: mime, codecs: codecs)
}

func served(_ base: String, _ name: String, _ mime: String, _ codecs: String) -> Item {
    Item(name: name, source: .url("\(base)/\(name)"), mime: mime, codecs: codecs)
}

let h264 = "avc1.64000b, mp4a.40.2"
let hevc = "hvc1.1.6.L60.90, mp4a.40.2"
let av1 = "av01.0.00M.08, mp4a.40.2"

func formats() -> [Item] {
    [
        local("h264_aac.mp4", "video/mp4", h264),
        local("hevc_aac.mp4", "video/mp4", hevc),
        local("hevc_aac.mov", "video/quicktime", hevc),
        local("vp9_opus.webm", "video/webm", "vp09.00.10.08, opus"),
        local("vp9_aac.mp4", "video/mp4", "vp09.00.10.08, mp4a.40.2"),
        local("av1_aac.mp4", "video/mp4", av1),
        local("av1_opus.webm", "video/webm", "av01.0.00M.08, opus"),
        local("tone.mp3", "audio/mpeg", ""),
        local("tone.m4a", "audio/mp4", "mp4a.40.2"),
        local("tone.ogg", "audio/ogg", "opus"),
        local("tone_opus.webm", "audio/webm", "opus"),
        local("tone.flac", "audio/flac", ""),
        local("tone.wav", "audio/wav", ""),
    ]
}

func mediaURL() -> String {
    guard let base = ProcessInfo.processInfo.environment["KAYA_MEDIA_URL"] else {
        fatalError(
            "kaya: the media scenes that stream read KAYA_MEDIA_URL, the local server the lane "
                + "starts (tools/lib/media_server.py); a hand run goes through tools/run-leg.py")
    }
    return base
}

/// The local server's items, and the three failures: a 404, a local file
/// that is not there, and a port nothing listens on.
func delivery() -> [Item] {
    let base = mediaURL()
    let refused: String
    if let colon = base.lastIndex(of: ":") {
        refused = "\(base[..<colon]):9"
    } else {
        refused = base
    }
    return [
        served(base, "h264_aac.mp4", "video/mp4", h264),
        served(base, "hls_fmp4.m3u8", "application/vnd.apple.mpegurl", ""),
        served(base, "hls_mpegts.m3u8", "application/vnd.apple.mpegurl", ""),
        served(base, "dash.mpd", "application/dash+xml", ""),
        served(base, "nope.mp4", "video/mp4", h264),
        local("missing.mp4", "video/mp4", h264),
        Item(
            name: "refused.mp4", source: .url("\(refused)/h264_aac.mp4"), mime: "video/mp4",
            codecs: h264),
    ]
}

func yesNo(_ b: Bool) -> String { b ? "yes" : "no" }

@KayaAppActor func suiteApp(_ app: KayaApp, _ scene: String) {
    let session = scene == "media_session"
    let items = scene == "media_delivery" ? delivery() : formats()
    var at = 0
    var can = false
    var furthest: UInt64 = 0
    var nexts = 0
    app.build { tx in
        tx.window(title: "media")
        let summary = tx.signal(.str("idle"))
        let name = tx.signal(.str(session ? "next 0" : "none"))
        var player = KayaPlayer.none
        player = tx.player(
            muted: true, loop: session,
            onState: { tx, state in
                if session {
                    if state == .playing || state == .paused {
                        tx.write(summary, .str(state.name))
                    }
                    return
                }
                switch state {
                case .ready: tx.play(player)
                case .ended:
                    let r = app.player(player)
                    let played = furthest >= 1000 ? "played past 1s" : "played to \(furthest)ms"
                    let secs = String(format: "%.1f", Double(r.durationMs) / 1000.0)
                    tx.write(
                        summary,
                        .str("ready \(secs)s \(r.width)x\(r.height), \(played), ended, can_play \(yesNo(can))"))
                default: break
                }
            },
            onFailed: { tx, why, _ in
                tx.write(summary, .str("failed \(why.name), can_play \(yesNo(can))"))
            },
            onPosition: { _, ms in furthest = max(furthest, ms) })
        let root = tx.column { root in
            tx.label(bind: summary)  // label#0
            tx.label(bind: name)  // label#1
            let clip = tx.video(player)  // video#0
            tx.setA11yId(clip, "clip")
            tx.setA11yLabel(clip, "Clip")
            tx.button(session ? "play" : "next") { tx in  // button#0
                if session {
                    if app.player(player).state == .idle {
                        tx.playerSource(player, .asset("media/h264_aac.mp4"))
                    }
                    tx.play(player)
                    return
                }
                guard at < items.count else { return }
                let item = items[at]
                at += 1
                can = KayaApp.canPlay(item.mime, codecs: item.codecs)
                furthest = 0
                tx.playerSource(player, item.source)
                tx.write(name, .str(item.name))
                tx.write(summary, .str("loading"))
            }
            return root
        }
        tx.mount(root)
        if session {
            tx.session(
                player: player, title: "kaya media", artist: "kaya", handles: [.next],
                onAction: { tx, action in
                    if action == .next {
                        nexts += 1
                        tx.write(name, .str("next \(nexts)"))
                    }
                })
        }
    }
}

/// One track list as a line: `audio en, fr [2]`, the selection counting
/// from 1, `-` for none; `audio none` for an empty list.
func trackLine(_ what: String, _ tags: [String], _ selected: Int?) -> String {
    if tags.isEmpty { return "\(what) none" }
    let pick = selected.map { String($0 + 1) } ?? "-"
    return "\(what) \(tags.joined(separator: ", ")) [\(pick)]"
}

/// media_tracks (docs/media-plan.md §3, §7a): each item's audio and caption
/// listing, a second audio track selected, the last caption track selected,
/// and the cue read at 0.5 s and 1.5 s with the player paused there. The
/// sidecar items are the floor file with captions.vtt: an asset, then fetched
/// from the local server, then a 404 there.
@KayaAppActor func tracksApp(_ app: KayaApp) {
    let base = mediaURL()
    func floor(_ label: String) -> Item {
        Item(name: label, source: .asset("media/h264_aac.mp4"), mime: "video/mp4", codecs: h264)
    }
    let items: [(Item, KayaMediaSource?)] = [
        (local("h264_2audio.mp4", "video/mp4", h264), nil),
        (local("vp9_2audio.webm", "video/webm", "vp09.00.10.08, opus"), nil),
        (served(base, "hls_fmp4.m3u8", "application/vnd.apple.mpegurl", ""), nil),
        (served(base, "hls_mpegts.m3u8", "application/vnd.apple.mpegurl", ""), nil),
        (local("h264_tx3g.mp4", "video/mp4", h264), nil),
        (floor("h264_aac.mp4 + captions.vtt"), .asset("media/captions.vtt")),
        (floor("h264_aac.mp4 + http captions.vtt"), .url("\(base)/captions.vtt")),
        (floor("h264_aac.mp4 + http nope.vtt"), .url("\(base)/nope.vtt")),
    ]
    var at = 0
    var can = false
    app.build { tx in
        tx.window(title: "media tracks")
        let summary = tx.signal(.str("idle"))
        let name = tx.signal(.str("none"))
        let audio = tx.signal(.str("audio none"))
        let captions = tx.signal(.str("captions none"))
        let cue = tx.signal(.str(""))
        let player = tx.player(
            muted: true,
            onState: { tx, state in
                if state == .ready {
                    tx.write(summary, .str("ready, can_play \(yesNo(can))"))
                }
            },
            onFailed: { tx, why, _ in
                let line = "failed \(why.name), can_play \(yesNo(can))"
                tx.write(summary, .str(line))
                tx.write(audio, .str(line))
            },
            onTracks: { tx, t in
                tx.write(audio, .str(trackLine("audio", t.audio, t.audioSelected)))
                tx.write(captions, .str(trackLine("captions", t.captions, t.captionSelected)))
            },
            onCue: { tx, text in tx.write(cue, .str(text)) })
        let root = tx.column { root in
            tx.label(bind: summary)  // label#0
            tx.label(bind: name)  // label#1
            tx.label(bind: audio)  // label#2
            tx.label(bind: captions)  // label#3
            tx.label(bind: cue)  // label#4
            let clip = tx.video(player)  // video#0
            tx.setA11yId(clip, "clip")
            tx.setA11yLabel(clip, "Clip")
            tx.button("next") { tx in  // button#0
                guard at < items.count else { return }
                let (item, sidecar) = items[at]
                at += 1
                can = KayaApp.canPlay(item.mime, codecs: item.codecs)
                if let sidecar {
                    tx.playerCaptions(player, sidecar, language: "en")
                } else {
                    tx.clearCaptions(player)
                }
                tx.playerSource(player, item.source)
                tx.write(name, .str(item.name))
                tx.write(summary, .str("loading"))
                tx.write(cue, .str(""))
            }
            tx.button("audio 2") { tx in tx.selectAudio(player, 1) }  // button#1
            tx.button("captions") { tx in  // button#2
                let listed = app.tracks(player).captions.count
                if listed == 0 {
                    tx.write(cue, .str("captions none"))
                } else {
                    tx.selectCaptions(player, listed - 1)
                }
            }
            for (caption, ms) in [("at 0.5s", UInt64(500)), ("at 1.5s", UInt64(1500))] {
                tx.button(caption) { tx in  // button#3, button#4
                    tx.pause(player)
                    tx.seek(player, to: ms)
                }
            }
            tx.button("captions off") { tx in tx.selectCaptions(player, nil) }  // button#5
            tx.button("play") { tx in  // button#6
                tx.seek(player, to: 0)
                tx.play(player)
            }
            return root
        }
        tx.mount(root)
    }
}

struct Clip: KayaGen {
    var name: String
    var player: KayaPlayer
}

let feedRows = 10

/// media_feed (docs/media-plan.md §7b): a scroll of rows, each a video view
/// showing its row's own player, paused on its first frame; the first and
/// last rows' visibility in label#0 and label#1.
@KayaAppActor func feedApp(_ app: KayaApp) {
    app.build { tx in
        tx.window(title: "media feed", width: 420, height: 480)
        let first = tx.signal(.str("r0 out"))
        let last = tx.signal(.str("r\(feedRows - 1) out"))
        let clips = clipCollection(tx)
        let root = tx.column { root in
            tx.label(bind: first)  // label#0
            tx.label(bind: last)  // label#1
            tx.scroll(grow: 1.0) { _ in
                tx.column { col in
                    for row in clips.rows {
                        row.label(row.name)
                        row.video(row.player) { tx, keys, shown in
                            guard case .i64(let key) = keys[0] else { return }
                            let word = shown >= 0.999 ? "whole" : (shown > 0 ? "in" : "out")
                            if key == 0 { tx.write(first, .str("r0 \(word)")) }
                            if key == Int64(feedRows - 1) { tx.write(last, .str("r\(key) \(word)")) }
                        }
                    }
                    return col
                }
            }
            return root
        }
        tx.mount(root)
        for i in 0..<feedRows {
            let player = tx.player(source: .asset("media/h264_aac.mp4"), muted: true)
            clips.insert(tx, .i64(Int64(i)), Clip(name: "r\(i)", player: player))
        }
    }
}

KayaApp.run { app in
    let scene = ProcessInfo.processInfo.environment["KAYA_SELFTEST"] ?? ""
    switch scene {
    case "media_tracks": tracksApp(app)
    case "media_feed": feedApp(app)
    default: suiteApp(app, scene)
    }
}
