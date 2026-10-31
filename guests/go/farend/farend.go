// The far end scene, Go port (docs/capture-plan.md §5): a surface showing the
// NV12 frames the app submits from its own goroutine, and a voice output
// playing the samples it writes there. See guests/rust/farend.rs and
// tools/scenes/farend.steps.
package farend

import (
	"math"
	"sync"
	"time"

	kaya "dev.kaya/bindings/go"
)

// peer is what the far end sends: a flat colour at a size and a tone (0:
// silence).
type peer struct {
	sync.Mutex
	sends
}

type sends struct {
	rgb  uint32
	w, h uint32
	hz   float64
	on   bool
}

// nv12 is a flat colour as NV12, video-range BT.601.
func nv12(w, h, rgb uint32) ([]byte, []byte) {
	r, g, b := float64(rgb>>16&0xFF), float64(rgb>>8&0xFF), float64(rgb&0xFF)
	y := byte(math.Round(16 + 0.257*r + 0.504*g + 0.098*b))
	u := byte(math.Round(128 - 0.148*r - 0.291*g + 0.439*b))
	v := byte(math.Round(128 + 0.439*r - 0.368*g - 0.071*b))
	luma := make([]byte, w*h)
	for i := range luma {
		luma[i] = y
	}
	chroma := make([]byte, w*h/2)
	for i := 0; i < len(chroma); i += 2 {
		chroma[i], chroma[i+1] = u, v
	}
	return luma, chroma
}

// run is the peer's goroutine: a frame every 1/15 s and 10 ms of samples every
// 10 ms, paced by the clock, until hung up.
func (p *peer) run(frames kaya.SurfaceFrames, voice kaya.VoiceWriter, done chan<- struct{}) {
	defer close(done)
	start := time.Now()
	var sentFrames, sentSamples int64
	var shown struct {
		rgb, w, h uint32
		y, uv     []byte
	}
	phase := 0.0
	for {
		p.Lock()
		now := p.sends
		p.Unlock()
		if !now.on {
			return
		}
		elapsed := time.Since(start).Microseconds()
		for sentFrames*1_000_000/15 <= elapsed {
			if shown.y == nil || shown.rgb != now.rgb || shown.w != now.w || shown.h != now.h {
				shown.rgb, shown.w, shown.h = now.rgb, now.w, now.h
				shown.y, shown.uv = nv12(now.w, now.h, now.rgb)
			}
			frames.Submit(kaya.CaptureFrame{Width: now.w, Height: now.h, Y: shown.y, UV: shown.uv,
				YStride: now.w, UVStride: now.w, TimestampNs: uint64(elapsed) * 1000})
			sentFrames++
		}
		for sentSamples*1_000/48 <= elapsed {
			chunk := make([]int16, 480)
			for i := range chunk {
				if now.hz > 0 {
					chunk[i] = int16(math.Sin(phase) * 12000)
				}
				phase = math.Mod(phase+2*math.Pi*now.hz/48000, 2*math.Pi)
			}
			voice.Write(chunk)
			sentSamples += 480
		}
		time.Sleep(5 * time.Millisecond)
	}
}

func App() *kaya.App {
	app := kaya.NewApp()
	var route kaya.Signal[string]
	var surface kaya.Widget
	var voice kaya.Voice
	var done chan struct{}
	far := &peer{}
	set := func(rgb, w, h uint32, hz float64) {
		far.Lock()
		far.rgb, far.w, far.h, far.hz = rgb, w, h, hz
		far.Unlock()
	}

	app.Build(func(tx *kaya.Tx) {
		tx.Window(0).Title("far end").Size(520, 640)
		route = tx.Signal("voice none")
		tx.Mount(tx.Column(func() {
			tx.Label(route) // label#0
			tx.Row(func() {
				tx.Button("Connect", func(tx *kaya.Tx) { // button#0
					if !voice.IsZero() {
						return
					}
					voice = tx.Voice().OnRoute(func(tx *kaya.Tx, r kaya.VoiceRoute, _ string) {
						switch r {
						case kaya.VoiceRouteVoice, kaya.VoiceRoutePlain, kaya.VoiceRouteSynthetic:
							tx.Write(route, "voice playing")
						case kaya.VoiceRouteFailed:
							tx.Write(route, "voice failed")
						default:
							tx.Write(route, "voice none")
						}
					}).ID()
					set(0x1E5AC8, 640, 480, 660)
					far.Lock()
					far.on = true
					far.Unlock()
					done = make(chan struct{})
					go far.run(app.SurfaceFrames(surface), app.VoiceWriter(voice), done)
				})
				tx.Button("Change", func(tx *kaya.Tx) { set(0xC83C1E, 1280, 720, 440) }) // button#1
				tx.Button("Quiet", func(tx *kaya.Tx) {                                   // button#2
					far.Lock()
					far.hz = 0
					far.Unlock()
				})
				tx.Button("Hang up", func(tx *kaya.Tx) { // button#3
					if voice.IsZero() {
						return
					}
					far.Lock()
					far.on = false
					far.Unlock()
					<-done
					tx.ReleaseVoice(voice)
					voice = kaya.Voice{}
					tx.Write(route, "voice none")
				})
			})
			surface = tx.Surface().A11yLabel("Peer") // surface#0
		}))
	})
	return app
}
