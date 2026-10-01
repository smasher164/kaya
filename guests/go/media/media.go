// The media suite (docs/media-plan.md §7a), guests/rust/media.rs's
// scenes: media_formats, media_delivery, media_session, media_tracks and
// media_feed.
package media

import (
	"fmt"
	"strings"

	kaya "dev.kaya/bindings/go"
)

//go:generate go run dev.kaya/cmd/kaya-gen -type Clip -key int64
type Clip struct {
	Name   string
	Player kaya.Player
}

type item struct {
	name   string
	source kaya.MediaSource
	mime   string
	codecs string
}

func local(name, mime, codecs string) item {
	return item{name, kaya.MediaAsset("media/" + name), mime, codecs}
}

func served(base, name, mime, codecs string) item {
	return item{name, kaya.MediaURL(base + "/" + name), mime, codecs}
}

const (
	h264 = "avc1.64000b, mp4a.40.2"
	hevc = "hvc1.1.6.L60.90, mp4a.40.2"
	av1  = "av01.0.00M.08, mp4a.40.2"
)

func formats() []item {
	return []item{
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
	}
}

func mediaURL() string {
	base, ok := kaya.LookupEnv("KAYA_MEDIA_URL")
	if !ok {
		panic("kaya: the media scenes that stream read KAYA_MEDIA_URL, the local server the lane " +
			"starts (tools/lib/media_server.py); a hand run goes through tools/run-leg.py")
	}
	return base
}

// delivery is the local server's items and the three failures: a 404, a
// local file that is not there, and a port nothing listens on.
func delivery() []item {
	base := mediaURL()
	refused := base
	if i := strings.LastIndex(base, ":"); i >= 0 {
		refused = base[:i] + ":9"
	}
	return []item{
		served(base, "h264_aac.mp4", "video/mp4", h264),
		served(base, "hls_fmp4.m3u8", "application/vnd.apple.mpegurl", ""),
		served(base, "hls_mpegts.m3u8", "application/vnd.apple.mpegurl", ""),
		served(base, "dash.mpd", "application/dash+xml", ""),
		served(base, "nope.mp4", "video/mp4", h264),
		local("missing.mp4", "video/mp4", h264),
		{"refused.mp4", kaya.MediaURL(refused + "/h264_aac.mp4"), "video/mp4", h264},
	}
}

func yesNo(b bool) string {
	if b {
		return "yes"
	}
	return "no"
}

// App serves the five scenes, chosen by KAYA_SELFTEST.
func App() *kaya.App {
	switch kaya.Env("KAYA_SELFTEST") {
	case "media_tracks":
		return tracksApp()
	case "media_feed":
		return feedApp()
	case "media_session":
		return playerApp(true, formats())
	case "media_delivery":
		return playerApp(false, delivery())
	}
	return playerApp(false, formats())
}

func playerApp(session bool, items []item) *kaya.App {
	app := kaya.NewApp()
	at := 0
	can := false
	var furthest uint64
	nexts := 0

	app.Build(func(tx *kaya.Tx) {
		tx.Window(0).Title("media")
		summary := tx.Signal("idle")
		nameText := "none"
		if session {
			nameText = "next 0"
		}
		name := tx.Signal(nameText)
		var player kaya.Player
		player = tx.Player().Muted(true).Loop(session).
			OnState(func(tx *kaya.Tx, state kaya.PlayerState) {
				if session {
					if state == kaya.PlayerStatePlaying || state == kaya.PlayerStatePaused {
						tx.Write(summary, state.String())
					}
					return
				}
				switch state {
				case kaya.PlayerStateReady:
					tx.Play(player)
				case kaya.PlayerStateEnded:
					r := app.Player(player)
					played := "played past 1s"
					if furthest < 1000 {
						played = fmt.Sprintf("played to %dms", furthest)
					}
					tx.Write(summary, fmt.Sprintf("ready %.1fs %dx%d, %s, ended, can_play %s",
						float64(r.DurationMs)/1000.0, r.Width, r.Height, played, yesNo(can)))
				}
			}).
			OnFailed(func(tx *kaya.Tx, why kaya.MediaFailure, _ string) {
				tx.Write(summary, fmt.Sprintf("failed %v, can_play %s", why, yesNo(can)))
			}).
			OnPosition(func(_ *kaya.Tx, ms uint64) {
				furthest = max(furthest, ms)
			}).
			ID()
		tx.Mount(tx.Column(func() {
			tx.Label(summary)                                 // label#0
			tx.Label(name)                                    // label#1
			tx.Video(player).A11yID("clip").A11yLabel("Clip") // video#0
			if session {
				tx.Button("play", func(tx *kaya.Tx) {
					if app.Player(player).State == kaya.PlayerStateIdle {
						tx.PlayerSource(player, kaya.MediaAsset("media/h264_aac.mp4"))
					}
					tx.Play(player)
				}) // button#0
			} else {
				tx.Button("next", func(tx *kaya.Tx) {
					if at >= len(items) {
						return
					}
					it := items[at]
					at++
					can = kaya.CanPlay(it.mime, it.codecs)
					furthest = 0
					tx.PlayerSource(player, it.source)
					tx.Write(name, it.name)
					tx.Write(summary, "loading")
				}) // button#0
			}
		}))
		if session {
			tx.Session().Player(player).Title("kaya media").Artist("kaya").
				Handles(kaya.SessionActionNext).Declare()
		}
		app.OnSession(func(tx *kaya.Tx, action kaya.SessionAction) {
			if action.Kind == kaya.SessionActionNext {
				nexts++
				tx.Write(name, fmt.Sprintf("next %d", nexts))
			}
		})
	})
	return app
}

// trackLine is one track list as a line: `audio en, fr [2]`, the
// selection counting from 1, `-` for none; `audio none` for an empty list.
func trackLine(what string, tags []string, selected int) string {
	if len(tags) == 0 {
		return what + " none"
	}
	pick := "-"
	if selected >= 0 {
		pick = fmt.Sprint(selected + 1)
	}
	return fmt.Sprintf("%s %s [%s]", what, strings.Join(tags, ", "), pick)
}

type trackItem struct {
	item
	sidecar kaya.MediaSource
	hasSide bool
}

func tracksApp() *kaya.App {
	base := mediaURL()
	h264Named := func(name string) item {
		it := local("h264_aac.mp4", "video/mp4", h264)
		it.name = name
		return it
	}
	items := []trackItem{
		{item: local("h264_2audio.mp4", "video/mp4", h264)},
		{item: local("vp9_2audio.webm", "video/webm", "vp09.00.10.08, opus")},
		{item: served(base, "hls_fmp4.m3u8", "application/vnd.apple.mpegurl", "")},
		{item: served(base, "hls_mpegts.m3u8", "application/vnd.apple.mpegurl", "")},
		{item: local("h264_tx3g.mp4", "video/mp4", h264)},
		{h264Named("h264_aac.mp4 + captions.vtt"), kaya.MediaAsset("media/captions.vtt"), true},
		{h264Named("h264_aac.mp4 + http captions.vtt"), kaya.MediaURL(base + "/captions.vtt"), true},
		{h264Named("h264_aac.mp4 + http nope.vtt"), kaya.MediaURL(base + "/nope.vtt"), true},
	}
	app := kaya.NewApp()
	at := 0
	can := false

	app.Build(func(tx *kaya.Tx) {
		tx.Window(0).Title("media tracks")
		summary := tx.Signal("idle")
		name := tx.Signal("none")
		audio := tx.Signal("audio none")
		captions := tx.Signal("captions none")
		cue := tx.Signal("")
		player := tx.Player().Muted(true).
			OnState(func(tx *kaya.Tx, state kaya.PlayerState) {
				if state == kaya.PlayerStateReady {
					tx.Write(summary, "ready, can_play "+yesNo(can))
				}
			}).
			OnFailed(func(tx *kaya.Tx, why kaya.MediaFailure, _ string) {
				line := fmt.Sprintf("failed %v, can_play %s", why, yesNo(can))
				tx.Write(summary, line)
				tx.Write(audio, line)
			}).
			OnTracks(func(tx *kaya.Tx, t kaya.PlayerTracks) {
				tx.Write(audio, trackLine("audio", t.Audio, t.AudioSelected))
				tx.Write(captions, trackLine("captions", t.Captions, t.CaptionSelected))
			}).
			OnCue(func(tx *kaya.Tx, text string) {
				tx.Write(cue, text)
			}).
			ID()
		pausedAt := func(ms uint64) func(*kaya.Tx) {
			return func(tx *kaya.Tx) {
				tx.Pause(player)
				tx.Seek(player, ms)
			}
		}
		tx.Mount(tx.Column(func() {
			tx.Label(summary)                                 // label#0
			tx.Label(name)                                    // label#1
			tx.Label(audio)                                   // label#2
			tx.Label(captions)                                // label#3
			tx.Label(cue)                                     // label#4
			tx.Video(player).A11yID("clip").A11yLabel("Clip") // video#0
			tx.Button("next", func(tx *kaya.Tx) {
				if at >= len(items) {
					return
				}
				it := items[at]
				at++
				can = kaya.CanPlay(it.mime, it.codecs)
				if it.hasSide {
					tx.PlayerCaptions(player, it.sidecar, "en")
				} else {
					tx.ClearCaptions(player)
				}
				tx.PlayerSource(player, it.source)
				tx.Write(name, it.name)
				tx.Write(summary, "loading")
				tx.Write(cue, "")
			}) // button#0
			tx.Button("audio 2", func(tx *kaya.Tx) { tx.SelectAudio(player, 1) }) // button#1
			tx.Button("captions", func(tx *kaya.Tx) {
				listed := len(app.Tracks(player).Captions)
				if listed == 0 {
					tx.Write(cue, "captions none")
				} else {
					tx.SelectCaptions(player, listed-1)
				}
			}) // button#2
			tx.Button("at 0.5s", pausedAt(500))                                     // button#3
			tx.Button("at 1.5s", pausedAt(1500))                                    // button#4
			tx.Button("captions off", func(tx *kaya.Tx) { tx.CaptionsOff(player) }) // button#5
			tx.Button("play", func(tx *kaya.Tx) {
				tx.Seek(player, 0)
				tx.Play(player)
			}) // button#6
		}))
	})
	return app
}

const feedRows = 10

// feedApp is media_feed (docs/media-plan.md §7b): a scroll of rows, each
// a video view showing its row's own player, paused on its first frame;
// the first and last rows' visibility in label#0 and label#1.
func feedApp() *kaya.App {
	app := kaya.NewApp()

	app.Build(func(tx *kaya.Tx) {
		tx.Window(0).Title("media feed").Size(420, 480)
		first := tx.Signal("r0 out")
		last := tx.Signal(fmt.Sprintf("r%d out", feedRows-1))
		clips := ClipCollection(tx)
		var video kaya.Node
		tx.Mount(tx.Column(func() {
			tx.Label(first) // label#0
			tx.Label(last)  // label#1
			tx.Scroll(func() {
				tx.Column(func() {
					for row := range ClipRows(tx, clips).All() {
						row.Label(row.Name())
						video = row.Video(row.Player())
					}
				})
			}).Grow(1)
		}))
		for i := 0; i < feedRows; i++ {
			p := tx.Player().Muted(true).Source(kaya.MediaAsset("media/h264_aac.mp4")).ID()
			clips.Insert(tx, int64(i), Clip{Name: fmt.Sprintf("r%d", i), Player: p})
		}
		video.OnVisibility(func(tx *kaya.Tx, keys []any, shown float64) {
			row := keys[0].(int64)
			word := "out"
			if shown >= 0.999 {
				word = "whole"
			} else if shown > 0 {
				word = "in"
			}
			if row == 0 {
				tx.Write(first, "r0 "+word)
			}
			if row == feedRows-1 {
				tx.Write(last, fmt.Sprintf("r%d %s", row, word))
			}
		})
	})
	return app
}
