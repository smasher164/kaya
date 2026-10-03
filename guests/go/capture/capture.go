// The capture scene, Go port (docs/capture-plan.md): a camera and a
// microphone in one object, a preview, and the frames and samples the app's
// own code is handed on kaya's capture thread. See guests/rust/capture.rs,
// tools/scenes/capture.steps and capture_denied.steps.
package capture

import (
	"fmt"
	"strings"
	"sync"

	kaya "dev.kaya/bindings/go"
)

const (
	camera1     = "kaya-synthetic-camera-1"
	camera2     = "kaya-synthetic-camera-2"
	microphone1 = "kaya-synthetic-microphone-1"
	microphone2 = "kaya-synthetic-microphone-2"
)

func stateLine(r kaya.CaptureReading) string {
	switch r.State {
	case kaya.CaptureStateRunning:
		return fmt.Sprintf("running %dx%d@%d", r.Width, r.Height, r.FrameRate)
	case kaya.CaptureStateFailed:
		return "failed " + r.Failure.String()
	case kaya.CaptureStateInterrupted:
		return "interrupted " + r.Interruption.String()
	}
	return r.State.String()
}

// seen is what the app's own code saw on the capture thread.
type seen struct {
	sync.Mutex
	frames string
	chunk  int
	posted bool
}

func (s *seen) line() string {
	frames, chunks := "app frames none", "app chunks none"
	if s.frames != "" {
		frames = "app frames " + s.frames
	}
	if s.chunk != 0 {
		chunks = fmt.Sprintf("app chunks of %d", s.chunk)
	}
	return frames + ", " + chunks
}

func App() *kaya.App {
	app := kaya.NewApp()
	var labels []kaya.Signal[string]
	var call, missing kaya.Capture
	evidence := &seen{}

	permissions := func(tx *kaya.Tx) {
		tx.Write(labels[1], fmt.Sprintf("camera %s, microphone %s",
			app.Permission(kaya.CaptureKindCamera), app.Permission(kaya.CaptureKindMicrophone)))
	}

	app.Build(func(tx *kaya.Tx) {
		tx.Window(0).Title("capture").Size(520, 640)
		for _, s := range []string{"devices", "permissions", "idle", evidence.line(), "idle"} {
			labels = append(labels, tx.Signal(s))
		}
		call = tx.Capture().Camera(camera1).Microphone(microphone1).Size(600, 400).FrameRate(30).
			OnState(func(tx *kaya.Tx, r kaya.CaptureReading) { tx.Write(labels[2], stateLine(r)) }).
			// The app's own code on kaya's capture thread: it checks what it
			// was handed and posts what it saw, as a call's encoder reads it.
			OnFrame(func(f kaya.CaptureFrame) {
				whole := len(f.Y) >= int(f.YStride*f.Height) &&
					len(f.UV) >= int(f.UVStride*((f.Height+1)/2)) &&
					f.YStride >= f.Width && f.UVStride >= f.Width
				size := ""
				if whole {
					size = fmt.Sprintf("%dx%d", f.Width, f.Height)
				}
				evidence.Lock()
				defer evidence.Unlock()
				if evidence.frames != size {
					evidence.frames = size
					line := evidence.line()
					app.Post(func(tx *kaya.Tx) { tx.Write(labels[3], line) })
				}
			}).
			OnSamples(func(chunk []int16, _ uint64) {
				evidence.Lock()
				defer evidence.Unlock()
				if evidence.posted {
					return
				}
				evidence.posted = true
				evidence.chunk = len(chunk)
				line := evidence.line()
				app.Post(func(tx *kaya.Tx) { tx.Write(labels[3], line) })
			}).
			ID()
		missing = tx.Capture().Camera("no-such-camera").
			OnState(func(tx *kaya.Tx, r kaya.CaptureReading) { tx.Write(labels[4], stateLine(r)) }).
			ID()
		tx.Mount(tx.Column(func() {
			for _, label := range labels {
				tx.Label(label) // label#0..#4
			}
			tx.VideoCapture(call).A11yLabel("Self view")                                                // video#0
			tx.Button("Ask camera", func(tx *kaya.Tx) { tx.RequestPermission(kaya.CaptureKindCamera) }) // button#0
			tx.Button("Start", func(tx *kaya.Tx) { tx.StartCapture(call) })                             // button#1
			tx.Button("Switch", func(tx *kaya.Tx) {                                                     // button#2
				tx.CaptureCamera(call, camera2)
				tx.CaptureMicrophone(call, microphone2)
				tx.CaptureSize(call, 1280, 720)
				tx.CaptureFrameRate(call, 15)
			})
			tx.Button("Mute", func(tx *kaya.Tx) { tx.CaptureMuted(call, true) })      // button#3
			tx.Button("Camera off", func(tx *kaya.Tx) { tx.CameraOff(call) })         // button#4
			tx.Button("Stop", func(tx *kaya.Tx) { tx.StopCapture(call) })             // button#5
			tx.Button("Open missing", func(tx *kaya.Tx) { tx.StartCapture(missing) }) // button#6
		}))
		tx.WatchCaptureDevices(true)
	})

	app.OnCaptureDevices(func(tx *kaya.Tx, devices []kaya.CaptureDevice) {
		parts := make([]string, 0, len(devices))
		for _, d := range devices {
			s := d.Kind.String() + " " + d.ID
			if d.Kind == kaya.CaptureKindCamera {
				s += " " + d.Facing.String()
			}
			if d.Preferred {
				s += " preferred"
			}
			parts = append(parts, s)
		}
		tx.Write(labels[0], strings.Join(parts, "; "))
	})
	app.OnPermission(func(tx *kaya.Tx, _ kaya.CaptureKind, _ kaya.Permission) { permissions(tx) })

	return app
}
