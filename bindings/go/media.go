// The Go binding's media surface (docs/media-plan.md): a player the app
// holds, the video view that shows one, the one session, the mirror of
// each player's readings and the capability query.
package kaya

/*
#include <kaya.h>
#include <stdlib.h>
*/
import "C"

import (
	"fmt"
	"unsafe"
)

// Player is a media player the app holds (docs/media-plan.md §2): an
// object with no place in the layout, shown by a video view or by none
// (then it is audio). The zero Player is none, which is what a row's
// Player field holds when the row shows nothing.
type Player struct{ id uint64 }

// IsZero reports the none player.
func (p Player) IsZero() bool { return p.id == 0 }

// PlayerState is what a player reads.
type PlayerState int64

// MediaFailure is why a player cannot play, a closed vocabulary
// (docs/media-plan.md §7a); MediaFailureNone while it can.
type MediaFailure int64

// SessionActionKind names an action the system's media controls send
// (docs/media-plan.md §5).
type SessionActionKind int64

// SessionAction is one action from the system's media controls; AtMs is
// where a seek_to goes, 0 for the rest.
type SessionAction struct {
	Kind SessionActionKind
	AtMs uint64
}

// PlaybackState is what the session states while no player is attached.
type PlaybackState int64

// Fit is how a video view fits its picture: FitContain, FitCover, FitFill.
type Fit int64

// MediaSource is where a player reads its media from: an asset under the
// app's asset root, an http(s) URL, or a file the user picked. Never
// bytes (docs/media-plan.md §2).
type MediaSource struct {
	path   string
	picked uint64
}

// MediaAsset names an asset, e.g. MediaAsset("media/h264_aac.mp4").
func MediaAsset(name string) MediaSource { return MediaSource{path: name} }

// MediaURL is an http(s) URL.
func MediaURL(url string) MediaSource { return MediaSource{path: url} }

// MediaPicked is a file the user picked, which the platform's player
// opens however the platform names it: a path, a content:// URI, an iOS
// URL.
func MediaPicked(file PickedFile) MediaSource { return MediaSource{picked: file.Handle} }

func (s MediaSource) value() any {
	if s.picked != 0 {
		return int64(s.picked)
	}
	return s.path
}

// PlayerReading is a player's readings as the core last published them.
type PlayerReading struct {
	State      PlayerState
	Failure    MediaFailure
	PositionMs uint64
	DurationMs uint64
	// The picture's size; 0x0 for audio.
	Width, Height uint32
}

// PlayerTracks is a player's track listing (docs/media-plan.md §3): BCP
// 47 tags in the platform's order, a sidecar caption track last; the
// selections count from 0, -1 for none.
type PlayerTracks struct {
	Audio           []string
	Captions        []string
	AudioSelected   int
	CaptionSelected int
}

type playerMirror struct {
	reading PlayerReading
	tracks  PlayerTracks
	cue     string
	onState func(*Tx, PlayerState)
	onEnded func(*Tx)
	onFail  func(*Tx, MediaFailure, string)
	onSeek  func(*Tx, uint64)
	onPos   func(*Tx, uint64)
	onTrack func(*Tx, PlayerTracks)
	onCue   func(*Tx, string)
}

type mediaState struct {
	nextPlayer  uint64
	players     map[uint64]*playerMirror
	widgetShown map[uint64]func(*Tx, float64)
	nodeShown   map[uint64]func(*Tx, []any, float64)
	session     func(*Tx, SessionAction)
}

func (a *App) mirror(id uint64) *playerMirror {
	if a.media.players == nil {
		a.media.players = map[uint64]*playerMirror{}
	}
	m := a.media.players[id]
	if m == nil {
		m = &playerMirror{tracks: PlayerTracks{AudioSelected: -1, CaptionSelected: -1}}
		a.media.players[id] = m
	}
	return m
}

// Player is a player's readings: its state, where it is, how long it is
// and its picture's size, as of the last occurrence this loop took.
func (a *App) Player(p Player) PlayerReading { return a.mirror(p.id).reading }

// Tracks is a player's track listing and selections.
func (a *App) Tracks(p Player) PlayerTracks { return a.mirror(p.id).tracks }

// Cue is the caption cue current on the player's clock, "" for none.
func (a *App) Cue(p Player) string { return a.mirror(p.id).cue }

// OnSession registers the handler for the actions the declared session
// handles (SessionRef.Handles), from the system's media controls.
func (a *App) OnSession(fn func(*Tx, SessionAction)) { a.media.session = fn }

// CanPlay reports whether this platform plays mime with codecs (an RFC
// 6381 list, "" for none): true exactly when such a source would not fail
// as unsupported_codec or unsupported_container (docs/media-plan.md §8
// ruling 1). Any goroutine, no transaction.
func CanPlay(mime, codecs string) bool {
	cm := C.CString(mime)
	defer C.free(unsafe.Pointer(cm))
	cc := C.CString(codecs)
	defer C.free(unsafe.Pointer(cc))
	return C.kaya_can_play((*C.uint8_t)(unsafe.Pointer(cm)), C.uintptr_t(len(mime)),
		(*C.uint8_t)(unsafe.Pointer(cc)), C.uintptr_t(len(codecs))) != 0
}

// PlayerRef is a player being declared: its settings and handlers chain,
// and ID hands the Player back.
type PlayerRef struct {
	tx *Tx
	p  Player
}

// Player creates a media player (docs/media-plan.md §2). Show it with
// Tx.Video; shown by none it is audio.
func (tx *Tx) Player() PlayerRef {
	tx.app.media.nextPlayer++
	p := Player{tx.app.media.nextPlayer}
	tx.emit(TxCreatePlayer(p.id))
	tx.app.mirror(p.id)
	return PlayerRef{tx, p}
}

func (r PlayerRef) ID() Player { return r.p }

func (r PlayerRef) Source(src MediaSource) PlayerRef { r.tx.PlayerSource(r.p, src); return r }
func (r PlayerRef) Speed(rate float64) PlayerRef     { r.tx.PlayerSpeed(r.p, rate); return r }
func (r PlayerRef) Volume(v float64) PlayerRef       { r.tx.PlayerVolume(r.p, v); return r }
func (r PlayerRef) Muted(on bool) PlayerRef          { r.tx.PlayerMuted(r.p, on); return r }
func (r PlayerRef) Loop(on bool) PlayerRef           { r.tx.PlayerLoop(r.p, on); return r }

func (r PlayerRef) Captions(src MediaSource, language string) PlayerRef {
	r.tx.PlayerCaptions(r.p, src, language)
	return r
}

// OnState hears every state the player moves to, ended and failed included.
func (r PlayerRef) OnState(fn func(*Tx, PlayerState)) PlayerRef {
	r.tx.app.mirror(r.p.id).onState = fn
	return r
}

// OnEnded hears the player reach its end (never, while it loops).
func (r PlayerRef) OnEnded(fn func(*Tx)) PlayerRef {
	r.tx.app.mirror(r.p.id).onEnded = fn
	return r
}

// OnFailed hears why the player cannot play, and the platform's sentence,
// which no two platforms word alike.
func (r PlayerRef) OnFailed(fn func(*Tx, MediaFailure, string)) PlayerRef {
	r.tx.app.mirror(r.p.id).onFail = fn
	return r
}

// OnSeekCompleted hears where a seek the app asked for landed, in ms.
func (r PlayerRef) OnSeekCompleted(fn func(*Tx, uint64)) PlayerRef {
	r.tx.app.mirror(r.p.id).onSeek = fn
	return r
}

// OnPosition hears the playhead while the player plays.
func (r PlayerRef) OnPosition(fn func(*Tx, uint64)) PlayerRef {
	r.tx.app.mirror(r.p.id).onPos = fn
	return r
}

// OnTracks hears the track listing or a selection move.
func (r PlayerRef) OnTracks(fn func(*Tx, PlayerTracks)) PlayerRef {
	r.tx.app.mirror(r.p.id).onTrack = fn
	return r
}

// OnCue hears the current caption cue change ("" between cues).
func (r PlayerRef) OnCue(fn func(*Tx, string)) PlayerRef {
	r.tx.app.mirror(r.p.id).onCue = fn
	return r
}

func (tx *Tx) playerProp(p Player, prop uint32, value any) {
	tx.emit(TxSetPlayerProp(p.id, prop, value))
}

// PlayerSource loads src, replacing what the player held; it reads
// loading until the platform answers.
func (tx *Tx) PlayerSource(p Player, src MediaSource) { tx.playerProp(p, PpropSource, src.value()) }

// ClearPlayer unloads the player, back to idle.
func (tx *Tx) ClearPlayer(p Player) { tx.playerProp(p, PpropSource, "") }

func (tx *Tx) PlayerSpeed(p Player, rate float64) { tx.playerProp(p, PpropSpeed, rate) }

// PlayerVolume is 0..1, relative to the system volume.
func (tx *Tx) PlayerVolume(p Player, v float64) { tx.playerProp(p, PpropVolume, v) }

func (tx *Tx) PlayerMuted(p Player, on bool) { tx.playerProp(p, PpropMuted, on) }

func (tx *Tx) PlayerLoop(p Player, on bool) { tx.playerProp(p, PpropLoop, on) }

// PlayerCaptions gives the player a sidecar WebVTT file, language its
// BCP 47 tag: kaya parses it and draws its cues, listed as the last
// caption track (docs/media-plan.md §3).
func (tx *Tx) PlayerCaptions(p Player, src MediaSource, language string) {
	tx.playerProp(p, PpropCaptionsLanguage, language)
	tx.playerProp(p, PpropCaptions, src.value())
}

// ClearCaptions drops the sidecar captions.
func (tx *Tx) ClearCaptions(p Player) { tx.playerProp(p, PpropCaptions, "") }

// Play plays, from the start when the player had ended.
func (tx *Tx) Play(p Player) { tx.emit(TxPlayerCommand(p.id, PlayerCommandPlay, 0)) }

func (tx *Tx) Pause(p Player) { tx.emit(TxPlayerCommand(p.id, PlayerCommandPause, 0)) }

// Seek goes to ms from the start; OnSeekCompleted hears where it landed.
func (tx *Tx) Seek(p Player, ms uint64) { tx.emit(TxPlayerCommand(p.id, PlayerCommandSeek, ms)) }

func (tx *Tx) ReleasePlayer(p Player) { tx.emit(TxReleasePlayer(p.id)) }

// SelectAudio selects audio track index (0-based in App.Tracks).
func (tx *Tx) SelectAudio(p Player, index int) {
	if index < 0 {
		panic(fmt.Sprintf("kaya: SelectAudio(%d): an audio track is always selected", index))
	}
	tx.emit(TxSelectTrack(p.id, TrackKindAudio, uint32(index)+1))
}

// SelectCaptions selects a caption track (0-based in App.Tracks); a
// sidecar file's track is selected the same way.
func (tx *Tx) SelectCaptions(p Player, index int) {
	if index < 0 {
		panic(fmt.Sprintf("kaya: SelectCaptions(%d): CaptionsOff selects none", index))
	}
	tx.emit(TxSelectTrack(p.id, TrackKindCaption, uint32(index)+1))
}

// CaptionsOff selects no caption track.
func (tx *Tx) CaptionsOff(p Player) { tx.emit(TxSelectTrack(p.id, TrackKindCaption, 0)) }

// ShowPlayer shows another player in a live video view, or none (the zero
// Player).
func (tx *Tx) ShowPlayer(w Widget, p Player) { tx.emit(TxSetPlayer(w.id, int64(p.id))) }

// SetFit is how a video view fits its picture.
func (tx *Tx) SetFit(w Widget, fit Fit) { tx.emit(TxSetFit(w.id, int64(fit))) }

// Fit is SetFit's chain.
func (w Widget) Fit(fit Fit) Widget {
	w.tx.SetFit(w, fit)
	return w
}

// OnVisibility hears how much of a live video view shows, 0 to 1, as it
// enters, leaves, moves by a tenth and shows whole (docs/media-plan.md §7b).
func (w Widget) OnVisibility(fn func(*Tx, float64)) Widget {
	if w.tx.app.media.widgetShown == nil {
		w.tx.app.media.widgetShown = map[uint64]func(*Tx, float64){}
	}
	w.tx.app.media.widgetShown[w.id] = fn
	return w
}

// OnVisibility hears a stamped video view's visibility, the copy's keys
// first, outermost first.
func (n Node) OnVisibility(fn func(*Tx, []any, float64)) Node {
	if n.tx.app.media.nodeShown == nil {
		n.tx.app.media.nodeShown = map[uint64]func(*Tx, []any, float64){}
	}
	n.tx.app.media.nodeShown[n.id] = fn
	return n
}

// SetFit is how every stamped copy of a video view fits its picture.
func (t *Tpl) SetFit(n Node, fit Fit) { t.tx.emit(TxSetFit(n.id, int64(fit))) }

// BindPlayerField binds a video view's player to one field of the
// element; Field[Player] only.
func (t *Tpl) BindPlayerField(n Node, level uint32, f Field[Player]) {
	t.tx.emit(TxBindPlayerElement(n.id, level, f.index))
}

// Video creates a video view whose player comes from a constant or the
// row's own Player field.
func (c RecordCollection[K, T]) Video[S interface {
	Player | func(*T) *Player | Field[Player]
}](t *Tpl, src S) Node {
	switch v := any(src).(type) {
	case Player:
		return t.Video(v)
	case func(*T) *Player:
		return t.VideoBound(FieldBy(v))
	case Field[Player]:
		return t.VideoBound(v)
	}
	panic("unreachable")
}

// SessionRef is the app's one media session being declared
// (docs/media-plan.md §5); Declare sends it, replacing the last.
type SessionRef struct {
	tx                        *Tx
	player                    Player
	actions                   uint32
	state                     PlaybackState
	title, artist, album, art string
}

// Session starts the declaration of the app's one media session.
func (tx *Tx) Session() SessionRef { return SessionRef{tx: tx} }

// Player attaches the player the system's controls speak to; without one,
// the app's own handlers are all there is.
func (s SessionRef) Player(p Player) SessionRef { s.player = p; return s }

func (s SessionRef) Title(title string) SessionRef   { s.title = title; return s }
func (s SessionRef) Artist(artist string) SessionRef { s.artist = artist; return s }
func (s SessionRef) Album(album string) SessionRef   { s.album = album; return s }

// Artwork is an asset name.
func (s SessionRef) Artwork(asset string) SessionRef { s.art = asset; return s }

// Handles names the actions the app answers itself through App.OnSession;
// play, pause and seek_to it leaves out apply to the attached player.
func (s SessionRef) Handles(actions ...SessionActionKind) SessionRef {
	for _, a := range actions {
		s.actions |= 1 << uint32(a)
	}
	return s
}

// PlaybackState is what the system shows while no player is attached.
func (s SessionRef) PlaybackState(state PlaybackState) SessionRef { s.state = state; return s }

func (s SessionRef) Declare() {
	s.tx.emit(TxSetSession(s.player.id, s.actions, uint32(s.state), s.title, s.artist, s.album, s.art))
}

func mediaOccurrence(kind uint16) bool {
	switch kind {
	case occPlayerChanged, occPlayerPosition, occSeekCompleted, occPlayerTracks,
		occCaptionCue, occVideoVisibility, occSessionAction:
		return true
	}
	return false
}

func tailInt(tail []any, i int) int64 {
	n, ok := tail[i].(int64)
	if !ok {
		panic(fmt.Sprintf("kaya: a media record's field %d is %T, wanted an integer", i, tail[i]))
	}
	return n
}

func tailStrings(tail []any, at int) ([]string, int) {
	count := int(tailInt(tail, at))
	out := make([]string, 0, count)
	for i := 0; i < count; i++ {
		s, _ := tail[at+1+i].(string)
		out = append(out, s)
	}
	return out, at + 1 + count
}

// mediaOccurred absorbs one media occurrence into the mirror FIRST, then
// runs the handlers in one transaction. Its own method because Serve's
// switch has no seam a test can reach (App.linkOpened's reason).
func (a *App) mediaOccurred(kind uint16, id uint64, keys []any, payload any) {
	switch kind {
	case occPlayerChanged:
		tail, _ := payload.([]any)
		m := a.mirror(id)
		r := &m.reading
		r.State = PlayerState(tailInt(tail, 0))
		r.Failure = MediaFailure(tailInt(tail, 1))
		r.DurationMs = uint64(tailInt(tail, 2))
		r.Width = uint32(tailInt(tail, 3))
		r.Height = uint32(tailInt(tail, 4))
		detail, _ := tail[5].(string)
		if r.State == PlayerStateLoading || r.State == PlayerStateIdle {
			r.PositionMs = 0
		}
		state, failure := r.State, r.Failure
		if m.onState == nil && m.onEnded == nil && m.onFail == nil {
			return
		}
		a.dispatch(func(tx *Tx) {
			if m.onState != nil {
				m.onState(tx, state)
			}
			if state == PlayerStateEnded && m.onEnded != nil {
				m.onEnded(tx)
			}
			if state == PlayerStateFailed && m.onFail != nil {
				m.onFail(tx, failure, detail)
			}
		})
	case occPlayerPosition, occSeekCompleted:
		// The surface-pair decode: the position keys it, the player rides
		// as the payload (kaya_wire.go's arm).
		player, _ := payload.(uint64)
		m := a.mirror(player)
		m.reading.PositionMs = id
		fn := m.onPos
		if kind == occSeekCompleted {
			fn = m.onSeek
		}
		if fn != nil {
			a.dispatch(func(tx *Tx) { fn(tx, id) })
		}
	case occPlayerTracks:
		tail, _ := payload.([]any)
		m := a.mirror(id)
		audio, at := tailStrings(tail, 2)
		captions, _ := tailStrings(tail, at)
		m.tracks = PlayerTracks{
			Audio: audio, Captions: captions,
			AudioSelected: int(tailInt(tail, 0)) - 1, CaptionSelected: int(tailInt(tail, 1)) - 1,
		}
		if fn := m.onTrack; fn != nil {
			tracks := m.tracks
			a.dispatch(func(tx *Tx) { fn(tx, tracks) })
		}
	case occCaptionCue:
		m := a.mirror(id)
		m.cue, _ = payload.(string)
		if fn := m.onCue; fn != nil {
			cue := m.cue
			a.dispatch(func(tx *Tx) { fn(tx, cue) })
		}
	case occVideoVisibility:
		shown, _ := payload.(float64)
		if len(keys) == 0 {
			if fn := a.media.widgetShown[id]; fn != nil {
				a.dispatch(func(tx *Tx) { fn(tx, shown) })
			}
		} else if fn := a.media.nodeShown[id]; fn != nil {
			a.dispatch(func(tx *Tx) { fn(tx, keys, shown) })
		}
	case occSessionAction:
		tail, _ := payload.([]any)
		action := SessionAction{Kind: SessionActionKind(tailInt(tail, 0)), AtMs: uint64(tailInt(tail, 1))}
		if fn := a.media.session; fn != nil {
			a.dispatch(func(tx *Tx) { fn(tx, action) })
		}
	}
}
