package kaya

// The capture's occurrences through the GENERATED decoder into the mirror
// and handlers, and the capture-thread callbacks' two rules: no
// transaction from the capture thread, and a released capture's callbacks
// dropped (docs/capture-plan.md §2, §4). The callbacks are driven through
// the same function the exported trampoline calls, from another OS thread.

import (
	"encoding/binary"
	"runtime"
	"strings"
	"testing"
)

func captureChangedRec(capture uint64, state CaptureState, failure CaptureFailure, w, h, fps uint32, detail string) []byte {
	b := binary.LittleEndian.AppendUint64(nil, capture)
	for _, v := range []uint32{uint32(state), uint32(failure), 0, w, h, fps} {
		b = binary.LittleEndian.AppendUint32(b, v)
	}
	return occRecord(occCaptureChanged, strValue(b, detail))
}

func deliverCapture(t *testing.T, app *App, rec []byte) {
	t.Helper()
	kind, id, _, payload, ok := ParseOccurrence(rec)
	if !ok || !captureOccurrence(kind) {
		t.Fatalf("record kind %d did not decode as a capture occurrence", kind)
	}
	app.captureOccurred(kind, id, payload)
}

func TestACaptureIsDeclaredAndHeard(t *testing.T) {
	app := NewApp()
	var call Capture
	var states []string
	var failed, perms, devices string
	var overrun uint64
	app.Build(func(tx *Tx) {
		call = tx.Capture().Camera("cam").Microphone("mic").Size(640, 480).
			OnState(func(_ *Tx, r CaptureReading) { states = append(states, r.State.String()) }).
			OnFailed(func(_ *Tx, why CaptureFailure, detail string) { failed = why.String() + " " + detail }).
			OnOverrun(func(_ *Tx, ms uint64) { overrun = ms }).
			ID()
	})
	app.OnPermission(func(_ *Tx, k CaptureKind, p Permission) { perms = k.String() + " " + p.String() })
	app.OnCaptureDevices(func(_ *Tx, list []CaptureDevice) {
		devices = list[0].ID + " " + list[0].Facing.String()
	})

	if got := app.Permission(CaptureKindMicrophone); got != PermissionPrompt {
		t.Fatalf("an unheard permission reads %v, want prompt", got)
	}
	b := binary.LittleEndian.AppendUint32(nil, uint32(CaptureKindCamera))
	b = binary.LittleEndian.AppendUint32(b, uint32(PermissionGranted))
	deliverCapture(t, app, occRecord(occCapturePermission, strValue(b, "")))
	if perms != "camera granted" || app.Permission(CaptureKindCamera) != PermissionGranted {
		t.Fatalf("permission heard %q, read %v", perms, app.Permission(CaptureKindCamera))
	}

	deliverCapture(t, app, captureChangedRec(call.id, CaptureStateRunning, CaptureFailureNone, 640, 480, 30, ""))
	if r := app.Capture(call); r.State != CaptureStateRunning || r.Width != 640 || r.FrameRate != 30 {
		t.Fatalf("the mirror reads %+v after running 640x480@30", r)
	}

	pair := binary.LittleEndian.AppendUint64(nil, call.id)
	deliverCapture(t, app, occRecord(occCaptureOverrun, binary.LittleEndian.AppendUint64(pair, 250)))
	if overrun != 250 {
		t.Fatalf("overrun heard %d, want 250", overrun)
	}

	d := binary.LittleEndian.AppendUint32(nil, 5)
	d = binary.LittleEndian.AppendUint32(d, 0)
	d = strValue(d, "cam")
	d = strValue(d, "Camera")
	d = binary.LittleEndian.AppendUint32(d, ValueI64)
	d = binary.LittleEndian.AppendUint32(d, 8)
	d = binary.LittleEndian.AppendUint64(d, uint64(CaptureKindCamera))
	d = binary.LittleEndian.AppendUint32(d, ValueI64)
	d = binary.LittleEndian.AppendUint32(d, 8)
	d = binary.LittleEndian.AppendUint64(d, uint64(CameraFacingFront))
	d = binary.LittleEndian.AppendUint32(d, ValueBool)
	d = binary.LittleEndian.AppendUint32(d, 1)
	d = append(d, 1, 0, 0, 0, 0, 0, 0, 0)
	deliverCapture(t, app, occRecord(occCaptureDevices, d))
	if devices != "cam front" || len(app.CaptureDevices()) != 1 || !app.CaptureDevices()[0].Preferred {
		t.Fatalf("devices heard %q, read %+v", devices, app.CaptureDevices())
	}

	deliverCapture(t, app, captureChangedRec(call.id, CaptureStateFailed, CaptureFailureInUse, 0, 0, 0, "the platform's words"))
	if failed != "in_use the platform's words" {
		t.Fatalf("failed heard %q", failed)
	}
	if strings.Join(states, ",") != "running,failed" {
		t.Fatalf("states heard %v, want running then failed", states)
	}
}

// A capture callback runs on kaya's capture thread: a transaction opened
// from it is refused by the binding's wrong-thread refusal, and a post is
// the way to the scene.
func TestACaptureCallbackHoldsNoTransaction(t *testing.T) {
	app := NewApp()
	claimAppThread()
	defer func() {
		appThread.Store(0)
		runtime.UnlockOSThread()
	}()
	var call Capture
	var s Signal[string]
	app.Build(func(tx *Tx) {
		s = tx.Signal("before")
		call = tx.Capture().ID()
	})
	var refused any
	ran := ""
	app.OnCaptureFrame(call, func(CaptureFrame) {
		func() {
			defer func() { refused = recover() }()
			app.Build(func(tx *Tx) { tx.Write(s, "from the capture thread") })
		}()
		app.Post(func(tx *Tx) { ran = "posted"; tx.Write(s, "posted") })
	})
	done := make(chan struct{})
	go func() {
		defer close(done)
		runtime.LockOSThread()
		defer runtime.UnlockOSThread()
		deliverCaptureFrame(call.id, CaptureFrame{Width: 2, Height: 2, Y: make([]byte, 4), UV: make([]byte, 2),
			YStride: 2, UVStride: 2})
	}()
	<-done
	msg, _ := refused.(string)
	if !strings.Contains(msg, "belongs to the app thread") || !strings.Contains(msg, "App.Post") {
		t.Fatalf("a transaction from the capture thread was answered with %v — it must be the "+
			"wrong-thread refusal naming App.Post", refused)
	}
	app.drainPosted()
	if ran != "posted" {
		t.Fatalf("the callback's post did not reach the app thread: %q", ran)
	}
	app.OnCaptureFrame(call, nil)
}

// A released capture's callbacks are dropped by the binding once the
// release commits; a release rolled back keeps them.
func TestAReleasedCaptureDropsItsCallbacks(t *testing.T) {
	app := NewApp()
	var call Capture
	app.Build(func(tx *Tx) { call = tx.Capture().ID() })
	frames, chunks := 0, 0
	app.OnCaptureFrame(call, func(CaptureFrame) { frames++ })
	app.OnCaptureSamples(call, func([]int16, uint64) { chunks++ })
	func() {
		defer func() { _ = recover() }()
		app.Build(func(tx *Tx) {
			tx.ReleaseCapture(call)
			panic("abandoned")
		})
	}()
	deliverCaptureFrame(call.id, CaptureFrame{})
	deliverCaptureSamples(call.id, make([]int16, 480), 0)
	if frames != 1 || chunks != 1 {
		t.Fatalf("a rolled-back release dropped the callbacks (frames %d, chunks %d)", frames, chunks)
	}
	app.Build(func(tx *Tx) { tx.ReleaseCapture(call) })
	deliverCaptureFrame(call.id, CaptureFrame{})
	deliverCaptureSamples(call.id, make([]int16, 480), 0)
	if frames != 1 || chunks != 1 {
		t.Fatalf("a released capture's callbacks still ran (frames %d, chunks %d)", frames, chunks)
	}
	captureSinks.RLock()
	_, f := captureSinks.frames[call.id]
	_, c := captureSinks.samples[call.id]
	captureSinks.RUnlock()
	if f || c {
		t.Fatalf("the binding still holds a released capture's callbacks (frame %v, samples %v)", f, c)
	}
}

// DESIGN.md's abort rule on the capture thread: a callback that panics is
// logged and the capture keeps running, its next frame and chunk still
// delivered.
func TestAPanickingCaptureCallbackIsSurvived(t *testing.T) {
	app := NewApp()
	var call Capture
	app.Build(func(tx *Tx) { call = tx.Capture().ID() })
	frames, chunks := 0, 0
	app.OnCaptureFrame(call, func(CaptureFrame) {
		frames++
		if frames == 1 {
			panic("the app's first frame")
		}
	})
	app.OnCaptureSamples(call, func([]int16, uint64) {
		chunks++
		if chunks == 1 {
			panic("the app's first chunk")
		}
	})
	for i := 0; i < 2; i++ {
		deliverCaptureFrame(call.id, CaptureFrame{})
		deliverCaptureSamples(call.id, make([]int16, 480), 0)
	}
	if frames != 2 || chunks != 2 {
		t.Fatalf("after a panicking call the callbacks ran %d frame(s) and %d chunk(s), want 2 each", frames, chunks)
	}
	app.OnCaptureFrame(call, nil)
	app.OnCaptureSamples(call, nil)
}
