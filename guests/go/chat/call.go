// C10 (docs/capture-plan.md §8, docs/chat-plan.md): a voice or video call from
// a conversation. The app's own capture is the self-view and its microphone;
// the peer answers over the app's loopback transport with a test pattern and
// a tone (1E5AC8 and 660 Hz, docs/capture-plan.md §7), which the app shows on
// a surface and plays through a voice output. An incoming call is an ordinary
// notification; activating it opens the call screen with Answer and Decline.
package chat

import (
	"bufio"
	"encoding/binary"
	"fmt"
	"io"
	"math"
	"net"
	"sync"
	"time"

	kaya "dev.kaya/bindings/go"
)

// The call screen and the incoming call's are entries above the thread.
const (
	callEntry     = 2
	incomingEntry = 3
)

// callNote is the incoming-call notification for a conversation: its
// message notification's id plus 100.
func callNote(c *conversation) uint64 { return c.note + 100 }

// The media wire on its own connection: the dialer's first line names the
// conversation and the kind ("CALL\tmaya\tvideo"), and then each side sends
// tagged records: 'F' w h (u32 each) then w*h*3/2 NV12 bytes, 'A' 480 s16.
const (
	recFrame = 'F'
	recAudio = 'A'
)

// call is one call's transport and its media objects.
type call struct {
	mu      sync.Mutex
	conn    net.Conn
	closed  bool
	frames  kaya.SurfaceFrames
	voice   kaya.VoiceWriter
	capture kaya.Capture
}

func (c *call) sendAudio(chunk []int16) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.conn == nil || c.closed {
		return
	}
	buf := make([]byte, 1+2*len(chunk))
	buf[0] = recAudio
	for i, s := range chunk {
		binary.LittleEndian.PutUint16(buf[1+2*i:], uint16(s))
	}
	if _, err := c.conn.Write(buf); err != nil {
		c.closed = true
	}
}

// receive reads the peer's records until the call ends: frames onto the
// surface, samples into the voice output, both from this goroutine.
func (c *call) receive(r io.Reader, connected func()) {
	in := bufio.NewReader(r)
	first := true
	chunk := make([]int16, 480)
	raw := make([]byte, 960)
	for {
		tag, err := in.ReadByte()
		if err != nil {
			return
		}
		switch tag {
		case recFrame:
			var head [8]byte
			if _, err := io.ReadFull(in, head[:]); err != nil {
				return
			}
			w, h := binary.LittleEndian.Uint32(head[:4]), binary.LittleEndian.Uint32(head[4:])
			planes := make([]byte, w*h*3/2)
			if _, err := io.ReadFull(in, planes); err != nil {
				return
			}
			c.frames.Submit(kaya.CaptureFrame{Width: w, Height: h, Y: planes[:w*h], UV: planes[w*h:],
				YStride: w, UVStride: w})
		case recAudio:
			if _, err := io.ReadFull(in, raw); err != nil {
				return
			}
			for i := range chunk {
				chunk[i] = int16(binary.LittleEndian.Uint16(raw[2*i:]))
			}
			c.voice.Write(chunk)
		default:
			return
		}
		if first {
			first = false
			connected()
		}
	}
}

func (c *call) hangUp() {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.closed = true
	if c.conn != nil {
		c.conn.Close()
	}
}

// serveMedia is the simulated peer's side of a call: a frame every 1/15 s
// and 10 ms of tone every 10 ms, paced by the clock, until the caller hangs
// up; what the caller sends is read and dropped, as a peer's decoder would
// consume it.
func serveMedia(listener net.Listener, rings chan<- string) {
	// Sam calls back once, a second after a voice call with Maya ends.
	var ringBack sync.Once
	ended := func(conv, kind string) {
		if conv != "maya" || kind != "voice" {
			return
		}
		ringBack.Do(func() {
			go func() {
				time.Sleep(time.Second)
				rings <- "sam"
			}()
		})
	}
	for {
		conn, err := listener.Accept()
		if err != nil {
			return
		}
		go func(conn net.Conn) {
			defer conn.Close()
			lines := bufio.NewReader(conn)
			head, err := lines.ReadString('\n')
			if err != nil {
				return
			}
			var conv, kind string
			fmt.Sscanf(head, "CALL\t%s\t%s", &conv, &kind)
			go io.Copy(io.Discard, lines)
			video := kind == "video"
			const w, h = 640, 480
			frame := make([]byte, 9+w*h*3/2)
			frame[0] = recFrame
			binary.LittleEndian.PutUint32(frame[1:], w)
			binary.LittleEndian.PutUint32(frame[5:], h)
			y, u, v := nv12Of(0x1E5AC8)
			for i := 0; i < w*h; i++ {
				frame[9+i] = y
			}
			for i := 0; i < w*h/2; i += 2 {
				frame[9+w*h+i], frame[9+w*h+i+1] = u, v
			}
			start := time.Now()
			var sentFrames, sentSamples int64
			phase := 0.0
			audio := make([]byte, 1+960)
			audio[0] = recAudio
			for {
				elapsed := time.Since(start).Microseconds()
				for video && sentFrames*1_000_000/15 <= elapsed {
					if _, err := conn.Write(frame); err != nil {
						ended(conv, kind)
						return
					}
					sentFrames++
				}
				for sentSamples*1_000/48 <= elapsed {
					for i := 0; i < 480; i++ {
						binary.LittleEndian.PutUint16(audio[1+2*i:], uint16(int16(math.Sin(phase)*12000)))
						phase = math.Mod(phase+2*math.Pi*660/48000, 2*math.Pi)
					}
					if _, err := conn.Write(audio); err != nil {
						ended(conv, kind)
						return
					}
					sentSamples += 480
				}
				time.Sleep(5 * time.Millisecond)
			}
		}(conn)
	}
}

// nv12Of is a flat colour's video-range BT.601 samples.
func nv12Of(rgb uint32) (y, u, v byte) {
	r, g, b := float64(rgb>>16&0xFF), float64(rgb>>8&0xFF), float64(rgb&0xFF)
	return byte(math.Round(16 + 0.257*r + 0.504*g + 0.098*b)),
		byte(math.Round(128 - 0.148*r - 0.291*g + 0.439*b)),
		byte(math.Round(128 + 0.439*r - 0.368*g - 0.071*b))
}

// calls is the call screen's half of the app: one call at a time, the
// capture, voice output and surface it holds, and the incoming call's
// notification.
type calls struct {
	app     *kaya.App
	peer    *peer
	convs   map[string]*conversation
	current *call
	voiceID kaya.Voice
}

// start opens the call screen for c and dials the peer: the app's camera
// (for a video call) and microphone, the peer's picture and voice.
func (k *calls) start(tx *kaya.Tx, c *conversation, video bool) {
	if k.current != nil {
		return
	}
	cl := &call{}
	k.current = cl
	state := tx.Signal(c.name + " · calling")
	var cameras, microphones []kaya.CaptureDevice
	for _, d := range k.app.CaptureDevices() {
		if d.Kind == kaya.CaptureKindCamera {
			cameras = append(cameras, d)
		} else {
			microphones = append(microphones, d)
		}
	}
	ref := tx.Capture().Size(640, 480).OnSamples(func(chunk []int16, _ uint64) { cl.sendAudio(chunk) })
	camera := ""
	if video && len(cameras) > 0 {
		camera = cameras[0].ID
		ref = ref.Camera(camera)
	}
	if len(microphones) > 0 {
		ref = ref.Microphone(microphones[0].ID)
	}
	cl.capture = ref.OnFailed(func(tx *kaya.Tx, why kaya.CaptureFailure, _ string) {
		tx.Write(state, c.name+" · "+why.String())
	}).ID()
	k.voiceID = tx.Voice().OnRoute(func(tx *kaya.Tx, r kaya.VoiceRoute, _ string) {
		if r == kaya.VoiceRouteFailed {
			tx.Write(state, c.name+" · no audio")
		}
	}).ID()
	cl.voice = k.app.VoiceWriter(k.voiceID)
	muted, cameraOn := false, video
	var mute, cameraButton kaya.Widget
	entry := tx.PushEntry(callEntry).Title(c.name).OnPopped(func(tx *kaya.Tx) { k.end(tx) }).Id()
	pane := tx.Column(func() {
		tx.Label(state).A11yID("callstate")
		if video {
			peerView := tx.Surface().A11yLabel(c.name).A11yID("peer").Grow(1)
			cl.frames = k.app.SurfaceFrames(peerView)
			tx.VideoCapture(cl.capture).A11yLabel("You").A11yID("selfview")
		}
		tx.Row(func() {
			if video {
				names := make([]string, len(cameras))
				for i, d := range cameras {
					names[i] = d.Name
				}
				tx.Select(names, 0, func(tx *kaya.Tx, i int) {
					camera = cameras[i].ID
					if cameraOn {
						tx.CaptureCamera(cl.capture, camera)
					}
				}).A11yID("camera")
			}
			names := make([]string, len(microphones))
			for i, d := range microphones {
				names[i] = d.Name
			}
			tx.Select(names, 0, func(tx *kaya.Tx, i int) {
				tx.CaptureMicrophone(cl.capture, microphones[i].ID)
			}).A11yID("microphone")
		}).Wrap(true)
		tx.Row(func() {
			mute = tx.Button("Mute", func(tx *kaya.Tx) {
				muted = !muted
				tx.CaptureMuted(cl.capture, muted)
				tx.SetText(mute, map[bool]string{true: "Unmute", false: "Mute"}[muted])
			}).A11yID("mute")
			if video {
				cameraButton = tx.Button("Camera off", func(tx *kaya.Tx) {
					cameraOn = !cameraOn
					if cameraOn {
						tx.CaptureCamera(cl.capture, camera)
						tx.SetText(cameraButton, "Camera off")
					} else {
						tx.CameraOff(cl.capture)
						tx.SetText(cameraButton, "Camera on")
					}
				}).A11yID("cameraoff")
			}
			tx.Button("Hang up", func(tx *kaya.Tx) {
				k.end(tx)
				tx.PopEntry()
			}).Role(kaya.RoleDestructive).A11yID("hangup")
		}).Wrap(true)
	})
	tx.MountIn(entry, pane)
	tx.StartCapture(cl.capture)
	kind := "voice"
	if video {
		kind = "video"
	}
	conn, err := net.Dial("tcp", k.peer.mediaAddr)
	if err != nil {
		tx.Write(state, c.name+" · unreachable")
		return
	}
	fmt.Fprintf(conn, "CALL\t%s\t%s\n", c.id, kind)
	cl.mu.Lock()
	cl.conn = conn
	cl.mu.Unlock()
	go cl.receive(conn, func() {
		k.app.Post(func(tx *kaya.Tx) { tx.Write(state, c.name+" · connected") })
	})
}

// end hangs up: the transport closes and the capture and voice output go.
func (k *calls) end(tx *kaya.Tx) {
	cl := k.current
	if cl == nil {
		return
	}
	k.current = nil
	cl.hangUp()
	tx.ReleaseCapture(cl.capture)
	tx.ReleaseVoice(k.voiceID)
}

// ring is the peer calling: an ordinary notification keyed by the
// conversation; activating it opens the incoming call (k.incoming).
func (k *calls) ring(tx *kaya.Tx, conv string) {
	c := k.convs[conv]
	if c == nil {
		return
	}
	tx.ShowNotification(callNote(c)).Title(c.name).Body("Incoming call").Show()
}

// incoming is the screen an activated call notification opens: the app's
// own Answer and Decline.
func (k *calls) incoming(tx *kaya.Tx, c *conversation) {
	tx.CancelNotification(callNote(c))
	entry := tx.PushEntry(incomingEntry).Title(c.name).Id()
	pane := tx.Column(func() {
		tx.Label(tx.Signal(c.name + " · incoming call")).A11yID("callstate")
		tx.Row(func() {
			tx.Button("Answer", func(tx *kaya.Tx) {
				tx.PopEntry()
				k.start(tx, c, false)
			}).Role(kaya.RoleProminent).A11yID("answer")
			tx.Button("Decline", func(tx *kaya.Tx) { tx.PopEntry() }).Role(kaya.RoleDestructive).A11yID("decline")
		})
	})
	tx.MountIn(entry, pane)
}
