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
	"math"
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
	// The reader's three id spaces (docs/media-plan.md §8 ruling 4), the
	// read each reader has in flight, the reads the app gave up on, and the
	// one-shot registrations, retired by the read's end or the image's load.
	nextReader, nextRead, nextImage uint64
	inFlight                        map[uint64]uint64
	abandoned                       map[uint64]bool
	reads                           map[uint64]*readHandlers
	images                          map[uint64]*imageHandlers
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

// aspectWire packs a width:height ratio as kaya::Aspect::pack does; the
// core refuses a part outside 1..=65535, so nothing is checked here.
func aspectWire(width, height int) int64 {
	part := func(x int) int32 {
		switch {
		case x < math.MinInt32:
			return math.MinInt32
		case x > math.MaxInt32:
			return math.MaxInt32
		}
		return int32(x)
	}
	return int64(part(width))<<32 | int64(uint32(part(height)))
}

// SetAspect is the width:height ratio of a video view's box, whatever its
// picture's shape; SetFit places the picture in it (docs/media-plan.md §3).
func (tx *Tx) SetAspect(w Widget, width, height int) {
	tx.emit(TxSetAspect(w.id, aspectWire(width, height)))
}

// Aspect is SetAspect's chain.
func (w Widget) Aspect(width, height int) Widget {
	w.tx.SetAspect(w, width, height)
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

// SetAspect is the width:height ratio of every stamped copy's video view
// box.
func (t *Tpl) SetAspect(n Node, width, height int) {
	t.tx.emit(TxSetAspect(n.id, aspectWire(width, height)))
}

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
		occCaptionCue, occVideoVisibility, occSessionAction,
		occReaderFrame, occReaderProgress, occReaderPeaks, occReaderDone, occImageLoaded:
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
	case occReaderFrame, occReaderProgress, occReaderPeaks, occReaderDone, occImageLoaded:
		tail, _ := payload.([]any)
		a.readerOccurred(kind, id, tail)
	}
}

// Reader is a media reader the app holds (docs/media-plan.md §8 ruling 4):
// frames and peaks from a source, with no player.
type Reader struct{ id uint64 }

// Read is one frames or peaks request on a reader.
type Read struct{ id uint64 }

// Image is a core-held picture, a frame a read answered or a LoadImage,
// which Draw.Image draws. It is the app's until ReleaseImage.
type Image struct{ id uint64 }

// FrameAccuracy is FrameAccuracyKeyframe, the keyframe at or before the
// time, or FrameAccuracyExact, the frame shown at it.
type FrameAccuracy int64

// ReadOutcomeKind is ReadOutcomeCompleted, ReadOutcomeCancelled or
// ReadOutcomeFailed.
type ReadOutcomeKind int64

// ReadOutcome is how a read ended; Failure and Detail, the platform's
// sentence, are set when it failed.
type ReadOutcome struct {
	Kind    ReadOutcomeKind
	Failure MediaFailure
	Detail  string
}

// Frame is one requested time answered: which of the times it is, the
// time asked, the time of the picture the platform returned, and the
// image holding it.
type Frame struct {
	Index       int
	RequestedMs uint64
	ActualMs    uint64
	Image       Image
	Width       uint32
	Height      uint32
}

// Peaks is a read's audio peaks: a min/max pair per channel for every
// SamplesPerPair frames (audiowaveform's .dat shape).
type Peaks struct {
	SampleRate     uint32
	SamplesPerPair uint32
	Channels       uint32
	length         int
	pairs          []int16
}

// Len is the number of pairs per channel.
func (p Peaks) Len() int { return p.length }

// Pair is pair i of channel's (min, max).
func (p Peaks) Pair(i, channel int) (min, max int16) {
	at := (i*int(p.Channels) + channel) * 2
	return p.pairs[at], p.pairs[at+1]
}

type readHandlers struct {
	onFrame    func(*Tx, Frame)
	onProgress func(*Tx, uint64, uint64)
	onPeaks    func(*Tx, Peaks)
	onDone     func(*Tx, ReadOutcome)
}

type imageHandlers struct {
	onLoaded func(*Tx, uint32, uint32)
	onFailed func(*Tx, MediaFailure, string)
}

// Reader opens a media reader on src: an asset, a URL or a picked file,
// as a player takes.
func (tx *Tx) Reader(src MediaSource) Reader {
	tx.app.media.nextReader++
	r := Reader{tx.app.media.nextReader}
	tx.emit(TxOpenReader(r.id, src.value()))
	return r
}

// ReadRef is a read just asked for: its handlers chain, and ID hands the
// Read back. They retire with the read's end.
type ReadRef struct {
	tx   *Tx
	read Read
}

func (r ReadRef) ID() Read { return r.read }

func (r ReadRef) handlers() *readHandlers {
	m := &r.tx.app.media
	if m.reads == nil {
		m.reads = map[uint64]*readHandlers{}
	}
	h := m.reads[r.read.id]
	if h == nil {
		h = &readHandlers{}
		m.reads[r.read.id] = h
	}
	return h
}

// OnFrame hears each time of a ReadFrames as it is answered, in the
// platform's order.
func (r ReadRef) OnFrame(fn func(*Tx, Frame)) ReadRef { r.handlers().onFrame = fn; return r }

// OnProgress hears how far a ReadPeaks has decoded, in ms of the total.
func (r ReadRef) OnProgress(fn func(tx *Tx, doneMs, totalMs uint64)) ReadRef {
	r.handlers().onProgress = fn
	return r
}

// OnPeaks hears a ReadPeaks' answer, just before its end.
func (r ReadRef) OnPeaks(fn func(*Tx, Peaks)) ReadRef { r.handlers().onPeaks = fn; return r }

// OnDone hears the read's end: completed, cancelled or failed.
func (r ReadRef) OnDone(fn func(*Tx, ReadOutcome)) ReadRef { r.handlers().onDone = fn; return r }

func (tx *Tx) newRead(r Reader) Read {
	m := &tx.app.media
	m.nextRead++
	if m.inFlight == nil {
		m.inFlight = map[uint64]uint64{}
	}
	m.inFlight[r.id] = m.nextRead
	return Read{m.nextRead}
}

// ReadFrames asks for one picture per time in timesMs, bounded by
// maxWidth x maxHeight with the aspect kept (0: no bound on that axis).
// One read in flight per reader.
func (tx *Tx) ReadFrames(r Reader, timesMs []uint64, maxWidth, maxHeight uint32, accuracy FrameAccuracy) ReadRef {
	read := tx.newRead(r)
	m := &tx.app.media
	first := m.nextImage + 1
	m.nextImage += uint64(len(timesMs))
	times := make([]any, len(timesMs))
	for i, t := range timesMs {
		times[i] = int64(t)
	}
	tx.emit(TxReadFrames(r.id, read.id, first, uint32(accuracy), maxWidth, maxHeight, times))
	return ReadRef{tx, read}
}

// ReadPeaks asks for the first audio track's peaks, a min/max pair per
// channel per samplesPerPair frames.
func (tx *Tx) ReadPeaks(r Reader, samplesPerPair uint32) ReadRef {
	read := tx.newRead(r)
	tx.emit(TxReadPeaks(r.id, read.id, samplesPerPair))
	return ReadRef{tx, read}
}

func (a *App) abandon(read uint64) {
	m := &a.media
	if m.abandoned == nil {
		m.abandoned = map[uint64]bool{}
	}
	m.abandoned[read] = true
	for reader, r := range m.inFlight {
		if r == read {
			delete(m.inFlight, reader)
		}
	}
}

// CancelRead stops a read: OnDone hears it cancelled and nothing else of
// it is heard.
func (tx *Tx) CancelRead(r Reader, read Read) {
	tx.app.abandon(read.id)
	tx.emit(TxCancelRead(r.id, read.id))
}

// CloseReader forgets a reader, cancelling its read in flight the same
// way. The images it answered with stay the app's.
func (tx *Tx) CloseReader(r Reader) {
	if read, ok := tx.app.media.inFlight[r.id]; ok {
		tx.app.abandon(read)
	}
	tx.emit(TxCloseReader(r.id))
}

// ImageRef is an image being loaded: its handlers chain, and ID hands the
// Image back, which a drawing may name in the same transaction.
type ImageRef struct {
	tx    *Tx
	image Image
}

func (r ImageRef) ID() Image { return r.image }

func (r ImageRef) handlers() *imageHandlers {
	m := &r.tx.app.media
	if m.images == nil {
		m.images = map[uint64]*imageHandlers{}
	}
	h := m.images[r.image.id]
	if h == nil {
		h = &imageHandlers{}
		m.images[r.image.id] = h
	}
	return h
}

// OnLoaded hears the decoded size.
func (r ImageRef) OnLoaded(fn func(tx *Tx, width, height uint32)) ImageRef {
	r.handlers().onLoaded = fn
	return r
}

// OnFailed hears why the image did not decode, and the decoder's sentence.
func (r ImageRef) OnFailed(fn func(*Tx, MediaFailure, string)) ImageRef {
	r.handlers().onFailed = fn
	return r
}

// LoadImage decodes a PNG or JPEG asset or picked file in kaya.
func (tx *Tx) LoadImage(src MediaSource) ImageRef {
	tx.app.media.nextImage++
	img := Image{tx.app.media.nextImage}
	tx.emit(TxLoadImage(img.id, src.value()))
	return ImageRef{tx, img}
}

func (tx *Tx) ReleaseImage(img Image) { tx.emit(TxReleaseImage(img.id)) }

// ImagePixels is an image's size and premultiplied RGBA8 bytes; ok is
// false for an image holding no picture. Any goroutine, no transaction.
func ImagePixels(img Image) (width, height uint32, pixels []byte, ok bool) {
	var w, h C.uint32_t
	n := int(C.kaya_image_pixels(C.uint64_t(img.id), nil, 0, &w, &h))
	if n == 0 {
		return 0, 0, nil, false
	}
	buf := make([]byte, n)
	got := int(C.kaya_image_pixels(C.uint64_t(img.id), (*C.uint8_t)(unsafe.Pointer(&buf[0])),
		C.uintptr_t(n), &w, &h))
	return uint32(w), uint32(h), buf[:min(n, got)], true
}

func pulledPeaks(reader, read uint64, tail []any) Peaks {
	p := Peaks{
		SampleRate:     uint32(tailInt(tail, 1)),
		SamplesPerPair: uint32(tailInt(tail, 2)),
		Channels:       uint32(tailInt(tail, 3)),
		length:         int(tailInt(tail, 4)),
	}
	want := p.length * int(p.Channels) * 2
	if want == 0 {
		return p
	}
	p.pairs = make([]int16, want)
	got := int(C.kaya_reader_peaks(C.uint64_t(reader), C.uint64_t(read),
		(*C.int16_t)(unsafe.Pointer(&p.pairs[0])), C.uintptr_t(want)))
	if got != want {
		panic(fmt.Sprintf("kaya: read %d's peaks hold %d values, its reader_peaks promised %d", read, got, want))
	}
	return p
}

// readerOccurred is the reader's half of mediaOccurred. A read the app gave
// up on is heard only at its end, and an image one of its late answers
// carried is released at the next commit, since the app never learned it.
func (a *App) readerOccurred(kind uint16, id uint64, tail []any) {
	m := &a.media
	if kind == occImageLoaded {
		h := m.images[id]
		delete(m.images, id)
		if h == nil {
			return
		}
		w, ht := uint32(tailInt(tail, 0)), uint32(tailInt(tail, 1))
		why := MediaFailure(tailInt(tail, 2))
		detail, _ := tail[3].(string)
		if why == MediaFailureNone && h.onLoaded != nil {
			a.dispatch(func(tx *Tx) { h.onLoaded(tx, w, ht) })
		} else if why != MediaFailureNone && h.onFailed != nil {
			a.dispatch(func(tx *Tx) { h.onFailed(tx, why, detail) })
		}
		return
	}
	read := uint64(tailInt(tail, 0))
	if kind == occReaderDone {
		if m.inFlight[id] == read {
			delete(m.inFlight, id)
		}
		delete(m.abandoned, read)
		h := m.reads[read]
		delete(m.reads, read)
		if h == nil || h.onDone == nil {
			return
		}
		outcome := ReadOutcome{Kind: ReadOutcomeKind(tailInt(tail, 1))}
		if outcome.Kind == ReadOutcomeFailed {
			outcome.Failure = MediaFailure(tailInt(tail, 2))
			outcome.Detail, _ = tail[3].(string)
		}
		a.dispatch(func(tx *Tx) { h.onDone(tx, outcome) })
		return
	}
	if m.abandoned[read] {
		if kind == occReaderFrame {
			a.pendingRecords = append(a.pendingRecords, TxReleaseImage(uint64(tailInt(tail, 1))))
		}
		return
	}
	h := m.reads[read]
	if h == nil {
		return
	}
	switch kind {
	case occReaderFrame:
		f := Frame{
			Image: Image{uint64(tailInt(tail, 1))}, Index: int(tailInt(tail, 2)),
			Width: uint32(tailInt(tail, 3)), Height: uint32(tailInt(tail, 4)),
			RequestedMs: uint64(tailInt(tail, 5)), ActualMs: uint64(tailInt(tail, 6)),
		}
		if h.onFrame != nil {
			a.dispatch(func(tx *Tx) { h.onFrame(tx, f) })
		}
	case occReaderProgress:
		done, total := uint64(tailInt(tail, 1)), uint64(tailInt(tail, 2))
		if h.onProgress != nil {
			a.dispatch(func(tx *Tx) { h.onProgress(tx, done, total) })
		}
	case occReaderPeaks:
		if h.onPeaks != nil {
			p := pulledPeaks(id, read, tail)
			a.dispatch(func(tx *Tx) { h.onPeaks(tx, p) })
		}
	}
}
