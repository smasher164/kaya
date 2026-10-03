// The Go binding's capture surface (docs/capture-plan.md): a capture the
// app holds, the video view previewing one, the permission and device
// readings, and the frame and sample callbacks that run on kaya's capture
// thread.
package kaya

/*
// A file carrying //export may hold declarations only (android.go's note).
#include <kaya.h>
extern void kayaGoCaptureFrame(void *ctx, KayaCaptureFrame *frame);
extern void kayaGoCaptureSamples(void *ctx, int16_t *samples, uintptr_t count, uint64_t timestamp_ns);
*/
import "C"

import (
	"fmt"
	"os"
	"strconv"
	"sync"
	"unsafe"
)

// Capture is a camera and a microphone in one object the app holds
// (docs/capture-plan.md §2), with no place in the layout. The zero
// Capture is none.
type Capture struct{ id uint64 }

func (c Capture) IsZero() bool { return c.id == 0 }

// CaptureState is what a capture reads: CaptureStateIdle, Starting,
// Running, Interrupted or Failed.
type CaptureState int64

// CaptureFailure is why a capture cannot run, a closed vocabulary
// (docs/capture-plan.md §2 rule 2); CaptureFailureNone while it can.
type CaptureFailure int64

// CaptureInterruption is why a capture is interrupted (§2 rule 3).
type CaptureInterruption int64

// CaptureKind is CaptureKindCamera or CaptureKindMicrophone.
type CaptureKind int64

// Permission is a kind's permission: PermissionPrompt, Granted, Denied.
type Permission int64

// CameraFacing is where a camera looks.
type CameraFacing int64

func (s CaptureState) String() string {
	switch s {
	case CaptureStateIdle:
		return "idle"
	case CaptureStateStarting:
		return "starting"
	case CaptureStateRunning:
		return "running"
	case CaptureStateInterrupted:
		return "interrupted"
	case CaptureStateFailed:
		return "failed"
	}
	return "CaptureState(" + strconv.FormatInt(int64(s), 10) + ")"
}

func (f CaptureFailure) String() string {
	switch f {
	case CaptureFailureNone:
		return "none"
	case CaptureFailureDenied:
		return "denied"
	case CaptureFailureNotFound:
		return "not_found"
	case CaptureFailureInUse:
		return "in_use"
	case CaptureFailureDisconnected:
		return "disconnected"
	case CaptureFailureUnsupported:
		return "unsupported"
	case CaptureFailureHardwareError:
		return "hardware_error"
	case CaptureFailureTimeout:
		return "timeout"
	}
	return "CaptureFailure(" + strconv.FormatInt(int64(f), 10) + ")"
}

func (i CaptureInterruption) String() string {
	switch i {
	case CaptureInterruptionNone:
		return "none"
	case CaptureInterruptionBackground:
		return "background"
	case CaptureInterruptionAnotherApp:
		return "another_app"
	case CaptureInterruptionSystemPressure:
		return "system_pressure"
	}
	return "CaptureInterruption(" + strconv.FormatInt(int64(i), 10) + ")"
}

func (k CaptureKind) String() string {
	switch k {
	case CaptureKindCamera:
		return "camera"
	case CaptureKindMicrophone:
		return "microphone"
	}
	return "CaptureKind(" + strconv.FormatInt(int64(k), 10) + ")"
}

func (p Permission) String() string {
	switch p {
	case PermissionPrompt:
		return "prompt"
	case PermissionGranted:
		return "granted"
	case PermissionDenied:
		return "denied"
	}
	return "Permission(" + strconv.FormatInt(int64(p), 10) + ")"
}

func (f CameraFacing) String() string {
	switch f {
	case CameraFacingUnknown:
		return "unknown"
	case CameraFacingFront:
		return "front"
	case CameraFacingBack:
		return "back"
	case CameraFacingExternal:
		return "external"
	}
	return "CameraFacing(" + strconv.FormatInt(int64(f), 10) + ")"
}

// CaptureReading is a capture's readings as the core last published them.
// Width, Height and FrameRate are the format the platform chose, 0x0 at 0
// with no camera running.
type CaptureReading struct {
	State                    CaptureState
	Failure                  CaptureFailure
	Interruption             CaptureInterruption
	Width, Height, FrameRate uint32
}

// CaptureDevice is one camera or microphone; Preferred marks the one the
// user chose in the platform's settings.
type CaptureDevice struct {
	ID, Name  string
	Kind      CaptureKind
	Facing    CameraFacing
	Preferred bool
}

// CaptureFrame is one NV12 frame (docs/capture-plan.md §4): the Y plane
// YStride bytes a row, then the interleaved UV plane at half resolution
// UVStride bytes a row; its time on the capture's monotonic clock and the
// rotation (0, 90, 180, 270) that stands it upright. Y and UV are
// BORROWED for the call, as C and Rust hand them: copy what you keep.
type CaptureFrame struct {
	Width, Height     uint32
	Y, UV             []byte
	YStride, UVStride uint32
	TimestampNs       uint64
	Rotation          uint32
}

type captureMirror struct {
	reading   CaptureReading
	onState   func(*Tx, CaptureReading)
	onFailed  func(*Tx, CaptureFailure, string)
	onOverrun func(*Tx, uint64)
}

type captureState struct {
	next         uint64
	captures     map[uint64]*captureMirror
	permissions  map[CaptureKind]Permission
	devices      []CaptureDevice
	onPermission func(*Tx, CaptureKind, Permission)
	onDevices    func(*Tx, []CaptureDevice)
}

func (a *App) captureMirror(id uint64) *captureMirror {
	if a.capture.captures == nil {
		a.capture.captures = map[uint64]*captureMirror{}
	}
	m := a.capture.captures[id]
	if m == nil {
		m = &captureMirror{}
		a.capture.captures[id] = m
	}
	return m
}

// Capture is a capture's readings as of the last occurrence this loop took.
func (a *App) Capture(c Capture) CaptureReading { return a.captureMirror(c.id).reading }

// Permission is a kind's permission as last heard: PermissionPrompt until
// the platform says.
func (a *App) Permission(kind CaptureKind) Permission { return a.capture.permissions[kind] }

// CaptureDevices is the cameras and microphones as last listed (watch them
// with Tx.WatchCaptureDevices).
func (a *App) CaptureDevices() []CaptureDevice {
	return append([]CaptureDevice(nil), a.capture.devices...)
}

// OnPermission hears a kind's permission move or be asked about.
func (a *App) OnPermission(fn func(*Tx, CaptureKind, Permission)) { a.capture.onPermission = fn }

// OnCaptureDevices hears the device list, as watching starts and whenever
// it changes.
func (a *App) OnCaptureDevices(fn func(*Tx, []CaptureDevice)) { a.capture.onDevices = fn }

// The app's frame and sample callbacks, by capture id. kaya's ctx for
// both is the capture id itself: the core calls a sink it took under its
// lock, so a released or replaced callback can be looked up once more, and
// an id that answers nothing is the safe late answer where a deleted
// cgo.Handle would panic.
var captureSinks struct {
	sync.RWMutex
	frames  map[uint64]func(CaptureFrame)
	samples map[uint64]func([]int16, uint64)
}

func captureContext(id uint64) unsafe.Pointer { return unsafe.Pointer(uintptr(id)) }

// OnCaptureFrame runs fn ON KAYA'S CAPTURE THREAD, NOT THE APP THREAD, for
// each frame of c, the next frame dropped while fn still runs
// (docs/capture-plan.md §4). fn holds no transaction: Build from it is
// refused, and to touch the scene it posts (App.Post). The frame's planes
// are borrowed for the call (no copy). A panic out of fn is logged naming
// the capture, which keeps running. Any goroutine; nil drops it, and a
// released capture's is dropped with it.
func (a *App) OnCaptureFrame(c Capture, fn func(CaptureFrame)) {
	captureSinks.Lock()
	if captureSinks.frames == nil {
		captureSinks.frames = map[uint64]func(CaptureFrame){}
	}
	if fn == nil {
		delete(captureSinks.frames, c.id)
	} else {
		captureSinks.frames[c.id] = fn
	}
	captureSinks.Unlock()
	if fn == nil {
		C.kaya_capture_on_frame(C.uint64_t(c.id), nil, nil)
		return
	}
	C.kaya_capture_on_frame(C.uint64_t(c.id), C.KayaCaptureFrameFn(C.kayaGoCaptureFrame), captureContext(c.id))
}

// OnCaptureSamples runs fn on kaya's capture thread, not the app thread,
// for every 10 ms of c's microphone: 480 samples of 48 kHz mono s16 and the
// first one's time on the capture's clock. None is dropped; a callback
// slower than the microphone is told through CaptureRef.OnOverrun. fn
// holds no transaction and posts to touch the scene; the samples are
// borrowed for the call (no copy). Any goroutine; nil drops it.
func (a *App) OnCaptureSamples(c Capture, fn func(samples []int16, timestampNs uint64)) {
	captureSinks.Lock()
	if captureSinks.samples == nil {
		captureSinks.samples = map[uint64]func([]int16, uint64){}
	}
	if fn == nil {
		delete(captureSinks.samples, c.id)
	} else {
		captureSinks.samples[c.id] = fn
	}
	captureSinks.Unlock()
	if fn == nil {
		C.kaya_capture_on_samples(C.uint64_t(c.id), nil, nil)
		return
	}
	C.kaya_capture_on_samples(C.uint64_t(c.id), C.KayaCaptureSamplesFn(C.kayaGoCaptureSamples), captureContext(c.id))
}

// dropCaptureSinks forgets a released capture's callbacks; the core drops
// its own references at the release.
func dropCaptureSinks(id uint64) {
	captureSinks.Lock()
	delete(captureSinks.frames, id)
	delete(captureSinks.samples, id)
	captureSinks.Unlock()
}

// survive is DESIGN.md's abort rule on the capture thread (the core's
// crate::capture::survive): a callback that panics is logged naming the
// capture and the capture keeps running. The recover sits here, before the
// trampoline returns into C, where a panic would kill the process.
func survive(id uint64, what string) {
	if r := recover(); r != nil {
		fmt.Fprintf(os.Stderr, "kaya: capture %d's %s callback panicked (%v); the capture keeps running\n",
			id, what, r)
	}
}

func deliverCaptureFrame(id uint64, f CaptureFrame) {
	captureSinks.RLock()
	fn := captureSinks.frames[id]
	captureSinks.RUnlock()
	if fn != nil {
		defer survive(id, "frame")
		fn(f)
	}
}

func deliverCaptureSamples(id uint64, samples []int16, at uint64) {
	captureSinks.RLock()
	fn := captureSinks.samples[id]
	captureSinks.RUnlock()
	if fn != nil {
		defer survive(id, "samples")
		fn(samples, at)
	}
}

//export kayaGoCaptureFrame
func kayaGoCaptureFrame(ctx unsafe.Pointer, frame *C.KayaCaptureFrame) {
	h := uint32(frame.height)
	deliverCaptureFrame(uint64(uintptr(ctx)), CaptureFrame{
		Width:       uint32(frame.width),
		Height:      h,
		Y:           unsafe.Slice((*byte)(unsafe.Pointer(frame.y)), int(frame.y_stride)*int(h)),
		UV:          unsafe.Slice((*byte)(unsafe.Pointer(frame.uv)), int(frame.uv_stride)*int((h+1)/2)),
		YStride:     uint32(frame.y_stride),
		UVStride:    uint32(frame.uv_stride),
		TimestampNs: uint64(frame.timestamp_ns),
		Rotation:    uint32(frame.rotation),
	})
}

//export kayaGoCaptureSamples
func kayaGoCaptureSamples(ctx unsafe.Pointer, samples *C.int16_t, count C.uintptr_t, timestampNs C.uint64_t) {
	deliverCaptureSamples(uint64(uintptr(ctx)), unsafe.Slice((*int16)(unsafe.Pointer(samples)), int(count)),
		uint64(timestampNs))
}

// CaptureRef is a capture being declared: its settings and handlers chain,
// and ID hands the Capture back.
type CaptureRef struct {
	tx *Tx
	c  Capture
}

// Capture creates a capture (docs/capture-plan.md §2): at most one camera
// and one microphone, with no place in the layout. Preview it with
// Tx.VideoCapture; StartCapture it once its devices are set.
func (tx *Tx) Capture() CaptureRef {
	tx.app.capture.next++
	c := Capture{tx.app.capture.next}
	tx.emit(TxCreateCapture(c.id))
	tx.app.captureMirror(c.id)
	return CaptureRef{tx, c}
}

func (r CaptureRef) ID() Capture { return r.c }

func (r CaptureRef) Camera(device string) CaptureRef { r.tx.CaptureCamera(r.c, device); return r }
func (r CaptureRef) Microphone(device string) CaptureRef {
	r.tx.CaptureMicrophone(r.c, device)
	return r
}
func (r CaptureRef) Size(width, height float64) CaptureRef {
	r.tx.CaptureSize(r.c, width, height)
	return r
}
func (r CaptureRef) FrameRate(rate float64) CaptureRef { r.tx.CaptureFrameRate(r.c, rate); return r }
func (r CaptureRef) Muted(on bool) CaptureRef          { r.tx.CaptureMuted(r.c, on); return r }

// OnState hears every state the capture moves to, failed included.
func (r CaptureRef) OnState(fn func(*Tx, CaptureReading)) CaptureRef {
	r.tx.app.captureMirror(r.c.id).onState = fn
	return r
}

// OnFailed hears why the capture cannot run, and the platform's sentence,
// which no two platforms word alike.
func (r CaptureRef) OnFailed(fn func(*Tx, CaptureFailure, string)) CaptureRef {
	r.tx.app.captureMirror(r.c.id).onFailed = fn
	return r
}

// OnOverrun hears how many ms the sample callback fell behind.
func (r CaptureRef) OnOverrun(fn func(*Tx, uint64)) CaptureRef {
	r.tx.app.captureMirror(r.c.id).onOverrun = fn
	return r
}

// OnFrame is App.OnCaptureFrame's chain: fn runs on kaya's capture thread,
// not the app thread; it holds no transaction, posts to touch the scene,
// and the frame is borrowed for the call (no copy).
func (r CaptureRef) OnFrame(fn func(CaptureFrame)) CaptureRef {
	r.tx.app.OnCaptureFrame(r.c, fn)
	return r
}

// OnSamples is App.OnCaptureSamples' chain, under the same thread rule.
func (r CaptureRef) OnSamples(fn func(samples []int16, timestampNs uint64)) CaptureRef {
	r.tx.app.OnCaptureSamples(r.c, fn)
	return r
}

func (tx *Tx) captureProp(c Capture, prop uint32, value any) {
	tx.emit(TxSetCaptureProp(c.id, prop, value))
}

// CaptureCamera opens device, an id from App.CaptureDevices, as the camera.
func (tx *Tx) CaptureCamera(c Capture, device string) { tx.captureProp(c, CpropCamera, device) }

// CameraOff closes the camera and puts its indicator out.
func (tx *Tx) CameraOff(c Capture) { tx.captureProp(c, CpropCamera, "") }

// CaptureMicrophone opens device as the microphone.
func (tx *Tx) CaptureMicrophone(c Capture, device string) {
	tx.captureProp(c, CpropMicrophone, device)
}

// MicrophoneOff closes the microphone.
func (tx *Tx) MicrophoneOff(c Capture) { tx.captureProp(c, CpropMicrophone, "") }

// CaptureSize is the picture size wished for, met by the platform's
// nearest format.
func (tx *Tx) CaptureSize(c Capture, width, height float64) {
	tx.captureProp(c, CpropWidth, width)
	tx.captureProp(c, CpropHeight, height)
}

func (tx *Tx) CaptureFrameRate(c Capture, rate float64) { tx.captureProp(c, CpropFrameRate, rate) }

// CaptureMuted keeps the microphone open delivering silence, as a call's
// mute.
func (tx *Tx) CaptureMuted(c Capture, on bool) { tx.captureProp(c, CpropMuted, on) }

// StartCapture opens the devices, asking for each kind's permission still
// at prompt; the answer is the capture's own state.
func (tx *Tx) StartCapture(c Capture) { tx.emit(TxCaptureCommand(c.id, CaptureCommandStart)) }

func (tx *Tx) StopCapture(c Capture) { tx.emit(TxCaptureCommand(c.id, CaptureCommandStop)) }

// ReleaseCapture stops and forgets a capture; its callbacks are dropped
// with it once the transaction commits.
func (tx *Tx) ReleaseCapture(c Capture) {
	tx.emit(TxReleaseCapture(c.id))
	tx.releasedCaptures = append(tx.releasedCaptures, c.id)
}

// RequestPermission asks for a kind's permission before any capture
// starts; the answer arrives through App.OnPermission.
func (tx *Tx) RequestPermission(kind CaptureKind) { tx.emit(TxRequestPermission(uint32(kind))) }

// WatchCaptureDevices lists the cameras and microphones now and whenever
// one comes or goes (App.OnCaptureDevices); false stops.
func (tx *Tx) WatchCaptureDevices(on bool) {
	var word uint32
	if on {
		word = 1
	}
	tx.emit(TxWatchCaptureDevices(word))
}

// VideoCapture creates a video view previewing c (docs/capture-plan.md §3):
// the player's view one source over, mirrored for a front camera. Live
// zone only: a row template shows no capture.
func (tx *Tx) VideoCapture(c Capture) Widget {
	w := tx.Widget(KindVideo)
	tx.emit(TxSetCapture(w.id, int64(c.id)))
	return w
}

// ShowCapture previews another capture in a live video view, or none (the
// zero Capture).
func (tx *Tx) ShowCapture(w Widget, c Capture) { tx.emit(TxSetCapture(w.id, int64(c.id))) }

func captureOccurrence(kind uint16) bool {
	switch kind {
	case occCaptureChanged, occCapturePermission, occCaptureDevices, occCaptureOverrun:
		return true
	}
	return false
}

// captureOccurred absorbs one capture occurrence into the mirror FIRST,
// then runs the handlers in one transaction (mediaOccurred's shape).
func (a *App) captureOccurred(kind uint16, id uint64, payload any) {
	switch kind {
	case occCaptureChanged:
		tail, _ := payload.([]any)
		m := a.captureMirror(id)
		m.reading = CaptureReading{
			State:        CaptureState(tailInt(tail, 0)),
			Failure:      CaptureFailure(tailInt(tail, 1)),
			Interruption: CaptureInterruption(tailInt(tail, 2)),
			Width:        uint32(tailInt(tail, 3)),
			Height:       uint32(tailInt(tail, 4)),
			FrameRate:    uint32(tailInt(tail, 5)),
		}
		detail, _ := tail[6].(string)
		reading := m.reading
		onFailed := m.onFailed
		if reading.State != CaptureStateFailed || reading.Failure == CaptureFailureNone {
			onFailed = nil
		}
		if m.onState == nil && onFailed == nil {
			return
		}
		onState := m.onState
		a.dispatch(func(tx *Tx) {
			if onState != nil {
				onState(tx, reading)
			}
			if onFailed != nil {
				onFailed(tx, reading.Failure, detail)
			}
		})
	case occCaptureOverrun:
		// The surface-pair decode: behind_ms keys it, the capture rides
		// as the payload.
		capture, _ := payload.(uint64)
		if fn := a.captureMirror(capture).onOverrun; fn != nil {
			a.dispatch(func(tx *Tx) { fn(tx, id) })
		}
	case occCapturePermission:
		tail, _ := payload.([]any)
		kind, permission := CaptureKind(tailInt(tail, 0)), Permission(tailInt(tail, 1))
		if a.capture.permissions == nil {
			a.capture.permissions = map[CaptureKind]Permission{}
		}
		a.capture.permissions[kind] = permission
		if fn := a.capture.onPermission; fn != nil {
			a.dispatch(func(tx *Tx) { fn(tx, kind, permission) })
		}
	case occCaptureDevices:
		tail, _ := payload.([]any)
		count := int(tailInt(tail, 0))
		devices := make([]CaptureDevice, 0, count/5)
		for at := 1; at+4 <= count && at+4 < len(tail); at += 5 {
			id, _ := tail[at].(string)
			name, _ := tail[at+1].(string)
			preferred, _ := tail[at+4].(bool)
			devices = append(devices, CaptureDevice{
				ID: id, Name: name, Kind: CaptureKind(tailInt(tail, at+2)),
				Facing: CameraFacing(tailInt(tail, at+3)), Preferred: preferred,
			})
		}
		a.capture.devices = devices
		if fn := a.capture.onDevices; fn != nil {
			list := a.CaptureDevices()
			a.dispatch(func(tx *Tx) { fn(tx, list) })
		}
	}
}
