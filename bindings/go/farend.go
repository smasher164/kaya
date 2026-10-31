// The Go binding's far end of a call (docs/capture-plan.md §5): a surface
// showing the frames the app submits and a voice output playing the samples
// it writes, both fed from any goroutine.
package kaya

/*
#include <kaya.h>
*/
import "C"

import (
	"strconv"
	"unsafe"
)

// Voice is a voice output the app holds (docs/capture-plan.md §5), with no
// place in the layout. The zero Voice is none.
type Voice struct{ id uint64 }

func (v Voice) IsZero() bool { return v.id == 0 }

// VoiceRoute is where a voice output plays: VoiceRouteVoice on the
// platform's voice path, VoiceRoutePlain where no echo canceller hears it,
// VoiceRouteSynthetic the harness's own engine, VoiceRouteFailed not at all,
// VoiceRouteNone until the platform opens it.
type VoiceRoute int64

func (r VoiceRoute) String() string {
	switch r {
	case VoiceRouteNone:
		return "none"
	case VoiceRouteVoice:
		return "voice"
	case VoiceRoutePlain:
		return "plain"
	case VoiceRouteSynthetic:
		return "synthetic"
	case VoiceRouteFailed:
		return "failed"
	}
	return "VoiceRoute(" + strconv.FormatInt(int64(r), 10) + ")"
}

type voiceMirror struct {
	route   VoiceRoute
	onRoute func(*Tx, VoiceRoute, string)
}

type voiceState struct {
	next   uint64
	voices map[uint64]*voiceMirror
}

func (a *App) voiceMirror(id uint64) *voiceMirror {
	if a.voice.voices == nil {
		a.voice.voices = map[uint64]*voiceMirror{}
	}
	m := a.voice.voices[id]
	if m == nil {
		m = &voiceMirror{}
		a.voice.voices[id] = m
	}
	return m
}

// VoiceRoute is the voice output's route as last heard: VoiceRouteNone
// until the platform opens it.
func (a *App) VoiceRoute(v Voice) VoiceRoute { return a.voiceMirror(v.id).route }

// VoiceRef is a voice output being declared: its handler chains, and ID
// hands the Voice back.
type VoiceRef struct {
	tx *Tx
	v  Voice
}

// Voice creates a voice output (docs/capture-plan.md §5): it plays what
// App.VoiceWriter writes on the platform's voice path, where its echo
// canceller hears it.
func (tx *Tx) Voice() VoiceRef {
	tx.app.voice.next++
	v := Voice{tx.app.voice.next}
	tx.emit(TxCreateVoice(v.id))
	tx.app.voiceMirror(v.id)
	return VoiceRef{tx, v}
}

func (r VoiceRef) ID() Voice { return r.v }

// OnRoute hears the route the platform opened the voice output on, and
// what the backend measured of it.
func (r VoiceRef) OnRoute(fn func(*Tx, VoiceRoute, string)) VoiceRef {
	r.tx.app.voiceMirror(r.v.id).onRoute = fn
	return r
}

// ReleaseVoice stops and forgets a voice output; what it still holds is
// dropped.
func (tx *Tx) ReleaseVoice(v Voice) { tx.emit(TxReleaseVoice(v.id)) }

// VoiceWriter is where a voice output's samples go, from any goroutine.
type VoiceWriter struct{ id uint64 }

// VoiceWriter is v's sample handle, for the goroutine the samples arrive on.
func (a *App) VoiceWriter(v Voice) VoiceWriter { return VoiceWriter{v.id} }

// Write queues 48 kHz mono s16 samples for the platform's voice path; past
// 200 ms ahead of it the oldest are dropped. False once the voice output is
// released. Any goroutine; no transaction.
func (w VoiceWriter) Write(samples []int16) bool {
	if len(samples) == 0 {
		return C.kaya_voice_write(C.uint64_t(w.id), nil, 0) == 1
	}
	return C.kaya_voice_write(C.uint64_t(w.id), (*C.int16_t)(unsafe.Pointer(&samples[0])), C.uintptr_t(len(samples))) == 1
}

// SurfaceFrames is where a surface's frames go, from any goroutine.
type SurfaceFrames struct{ id uint64 }

// SurfaceFrames is w's frame handle, for the goroutine the frames arrive on.
func (a *App) SurfaceFrames(w Widget) SurfaceFrames { return SurfaceFrames{w.id} }

// Submit shows f (NV12, as a capture hands one) once the surface's display
// clock next ticks, replacing any frame not yet shown; the planes are
// copied before it returns. False when the surface is gone. Any goroutine;
// no transaction.
func (s SurfaceFrames) Submit(f CaptureFrame) bool {
	if uint64(len(f.Y)) < uint64(f.YStride)*uint64(f.Height) || uint64(len(f.UV)) < uint64(f.UVStride)*uint64(f.Height/2) ||
		f.Height == 0 {
		panic("kaya: a surface frame's planes are shorter than its strides and height say (docs/capture-plan.md §4)")
	}
	return C.kaya_surface_submit(C.uint64_t(s.id), C.uint32_t(f.Width), C.uint32_t(f.Height),
		(*C.uint8_t)(unsafe.Pointer(&f.Y[0])), C.uint32_t(f.YStride),
		(*C.uint8_t)(unsafe.Pointer(&f.UV[0])), C.uint32_t(f.UVStride),
		C.uint64_t(f.TimestampNs), C.uint32_t(f.Rotation)) == 1
}

// voiceOccurred absorbs a voice_changed into the mirror FIRST, then runs
// its handler in one transaction.
func (a *App) voiceOccurred(id uint64, tail []any) {
	m := a.voiceMirror(id)
	m.route = VoiceRoute(tailInt(tail, 0))
	detail := ""
	if len(tail) > 1 {
		detail, _ = tail[1].(string)
	}
	if fn := m.onRoute; fn != nil {
		route := m.route
		a.dispatch(func(tx *Tx) { fn(tx, route, detail) })
	}
}
