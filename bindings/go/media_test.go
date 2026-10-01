package kaya

// The media occurrences through the GENERATED decoder and into the mirror
// and handlers (docs/media-plan.md §2, §3, §5, §7b). Serve's switch has no
// seam a test can reach — the ring is C memory — so these build each
// record as crates/kaya/src/wire.rs does, decode it with ParseOccurrence
// and hand the result to App.mediaOccurred, which the switch arm calls.

import (
	"encoding/binary"
	"math"
	"reflect"
	"testing"
)

func occRecord(kind uint16, body []byte) []byte {
	for len(body)%8 != 0 {
		body = append(body, 0)
	}
	rec := binary.LittleEndian.AppendUint32(nil, uint32(8+len(body)))
	rec = binary.LittleEndian.AppendUint16(rec, kind)
	rec = binary.LittleEndian.AppendUint16(rec, 0)
	return append(rec, body...)
}

func strValue(b []byte, s string) []byte {
	b = binary.LittleEndian.AppendUint32(b, ValueStr)
	b = binary.LittleEndian.AppendUint32(b, uint32(len(s)))
	b = append(b, s...)
	for len(b)%8 != 0 {
		b = append(b, 0)
	}
	return b
}

func strValues(b []byte, list ...string) []byte {
	b = binary.LittleEndian.AppendUint32(b, uint32(len(list)))
	b = binary.LittleEndian.AppendUint32(b, 0)
	for _, s := range list {
		b = strValue(b, s)
	}
	return b
}

func playerChangedRec(player uint64, state PlayerState, failure MediaFailure, duration uint64, w, h uint32, detail string) []byte {
	b := binary.LittleEndian.AppendUint64(nil, player)
	b = binary.LittleEndian.AppendUint32(b, uint32(state))
	b = binary.LittleEndian.AppendUint32(b, uint32(failure))
	b = binary.LittleEndian.AppendUint64(b, duration)
	b = binary.LittleEndian.AppendUint32(b, w)
	b = binary.LittleEndian.AppendUint32(b, h)
	return occRecord(occPlayerChanged, strValue(b, detail))
}

func pairRec(kind uint16, player, ms uint64) []byte {
	b := binary.LittleEndian.AppendUint64(nil, player)
	return occRecord(kind, binary.LittleEndian.AppendUint64(b, ms))
}

func deliver(t *testing.T, app *App, rec []byte) {
	t.Helper()
	kind, id, keys, payload, ok := ParseOccurrence(rec)
	if !ok || !mediaOccurrence(kind) {
		t.Fatalf("record kind %d did not decode as a media occurrence", kind)
	}
	app.mediaOccurred(kind, id, keys, payload)
}

func TestAPlayerChangedAndItsPositionReachTheMirrorAndTheHandlers(t *testing.T) {
	app := NewApp()
	var p Player
	var states []PlayerState
	var failed []string
	ended := 0
	app.Build(func(tx *Tx) {
		p = tx.Player().Muted(true).
			OnState(func(_ *Tx, s PlayerState) { states = append(states, s) }).
			OnEnded(func(*Tx) { ended++ }).
			OnFailed(func(_ *Tx, why MediaFailure, detail string) {
				failed = append(failed, why.String()+"|"+detail)
			}).ID()
	})
	deliver(t, app, playerChangedRec(p.id, PlayerStateReady, MediaFailureNone, 2000, 160, 90, ""))
	deliver(t, app, pairRec(occPlayerPosition, p.id, 1250))
	r := app.Player(p)
	if r != (PlayerReading{State: PlayerStateReady, PositionMs: 1250, DurationMs: 2000, Width: 160, Height: 90}) {
		t.Fatalf("the mirror read %+v after ready and a position of 1250", r)
	}
	deliver(t, app, playerChangedRec(p.id, PlayerStateEnded, MediaFailureNone, 2000, 160, 90, ""))
	deliver(t, app, playerChangedRec(p.id, PlayerStateLoading, MediaFailureNone, 0, 0, 0, ""))
	if app.Player(p).PositionMs != 0 {
		t.Fatalf("loading kept the old position %d", app.Player(p).PositionMs)
	}
	deliver(t, app, playerChangedRec(p.id, PlayerStateFailed, MediaFailureNotFound, 0, 0, 0, "no such file"))
	want := []PlayerState{PlayerStateReady, PlayerStateEnded, PlayerStateLoading, PlayerStateFailed}
	if !reflect.DeepEqual(states, want) || ended != 1 {
		t.Fatalf("OnState heard %v and OnEnded %d, want %v and 1", states, ended, want)
	}
	if !reflect.DeepEqual(failed, []string{"not_found|no such file"}) || app.Player(p).Failure != MediaFailureNotFound {
		t.Fatalf("OnFailed heard %v, the mirror's failure %v", failed, app.Player(p).Failure)
	}
}

func TestTracksCueSeekAndSessionDecode(t *testing.T) {
	app := NewApp()
	var p Player
	var heard []any
	app.OnSession(func(_ *Tx, a SessionAction) { heard = append(heard, a) })
	app.Build(func(tx *Tx) {
		p = tx.Player().
			OnTracks(func(_ *Tx, tr PlayerTracks) { heard = append(heard, tr) }).
			OnCue(func(_ *Tx, cue string) { heard = append(heard, cue) }).
			OnSeekCompleted(func(_ *Tx, ms uint64) { heard = append(heard, ms) }).ID()
	})
	b := binary.LittleEndian.AppendUint64(nil, p.id)
	b = binary.LittleEndian.AppendUint32(b, 2)
	b = binary.LittleEndian.AppendUint32(b, 0)
	b = strValues(b, "en", "fr")
	b = strValues(b, "en")
	deliver(t, app, occRecord(occPlayerTracks, b))
	cue := strValue(binary.LittleEndian.AppendUint64(nil, p.id), "first cue")
	deliver(t, app, occRecord(occCaptionCue, cue))
	deliver(t, app, pairRec(occSeekCompleted, p.id, 500))
	s := binary.LittleEndian.AppendUint32(nil, uint32(SessionActionSeekTo))
	s = binary.LittleEndian.AppendUint32(s, 0)
	deliver(t, app, occRecord(occSessionAction, binary.LittleEndian.AppendUint64(s, 700)))

	tracks := PlayerTracks{Audio: []string{"en", "fr"}, Captions: []string{"en"}, AudioSelected: 1, CaptionSelected: -1}
	want := []any{tracks, "first cue", uint64(500), SessionAction{Kind: SessionActionSeekTo, AtMs: 700}}
	if !reflect.DeepEqual(heard, want) {
		t.Fatalf("heard %#v, want %#v", heard, want)
	}
	if !reflect.DeepEqual(app.Tracks(p), tracks) || app.Cue(p) != "first cue" || app.Player(p).PositionMs != 500 {
		t.Fatalf("the mirror read tracks %+v, cue %q, position %d", app.Tracks(p), app.Cue(p), app.Player(p).PositionMs)
	}
}

func TestAStampedVideoViewBindsTheRowsPlayerFieldAndHearsItsVisibility(t *testing.T) {
	token := FieldAt[Player](1)
	got, _ := propWrite(t, func(tx *Tx, tpl *Tpl, _ Node) setProp {
		tpl.VideoBound(token)
		return setProp{}
	})
	if got.prop != PropPlayer || got.source != SourceElement || got.field != 1 {
		t.Fatalf("a stamped video bound prop %d source %d field %d, want the player prop (%d) from element field 1",
			got.prop, got.source, got.field, PropPlayer)
	}

	app := NewApp()
	var shown []float64
	var keysHeard []any
	app.Build(func(tx *Tx) {
		items := tx.Collection()
		for row := range tx.Rows(items).All() {
			row.VideoBound(token).OnVisibility(func(_ *Tx, keys []any, f float64) {
				keysHeard = append(keysHeard, keys...)
				shown = append(shown, f)
			})
		}
	})
	b := binary.LittleEndian.AppendUint64(nil, app.c.widget)
	b = binary.LittleEndian.AppendUint32(b, 1)
	b = binary.LittleEndian.AppendUint32(b, 0)
	b = binary.LittleEndian.AppendUint32(b, ValueI64)
	b = binary.LittleEndian.AppendUint32(b, 8)
	b = binary.LittleEndian.AppendUint64(b, 9)
	b = binary.LittleEndian.AppendUint32(b, ValueF64)
	b = binary.LittleEndian.AppendUint32(b, 8)
	b = binary.LittleEndian.AppendUint64(b, math.Float64bits(0.5))
	deliver(t, app, occRecord(occVideoVisibility, b))
	if !reflect.DeepEqual(keysHeard, []any{int64(9)}) || !reflect.DeepEqual(shown, []float64{0.5}) {
		t.Fatalf("the stamped video's handler heard keys %v shown %v, want [9] [0.5]", keysHeard, shown)
	}
}

func TestAPlayerFieldRidesTheWireAsItsID(t *testing.T) {
	type clip struct {
		Name   string
		Player Player
	}
	tag, ok := wireTag(reflect.TypeFor[Player]())
	if !ok || tag != ValueI64 {
		t.Fatalf("a Player field's wire tag is %d (%v), want I64", tag, ok)
	}
	info := recordInfoOf[clip]()
	back := restoreRecord(reflect.TypeFor[clip](), info, []any{"r0", int64(7)}).(clip)
	if back.Player != (Player{7}) {
		t.Fatalf("a restored row's player is %+v, want id 7", back.Player)
	}
}
