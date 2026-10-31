// The far end of a call (tools/scenes/farend.steps; docs/capture-plan.md §5):
// a surface showing the NV12 frames the app submits, and a voice output
// playing the samples it writes. The peer is a timer of the app's own,
// standing in for a transport.
//     KAYA_SELFTEST=farend node guests/js/farend.ts

import * as kaya from "kaya-gui";

const app = new kaya.App();

/** A flat colour as NV12, video-range BT.601. */
function nv12(width: number, height: number, rgb: number): [Uint8Array, Uint8Array] {
  const r = (rgb >> 16) & 0xff, g = (rgb >> 8) & 0xff, b = rgb & 0xff;
  const y = Math.round(16 + 0.257 * r + 0.504 * g + 0.098 * b);
  const u = Math.round(128 - 0.148 * r - 0.291 * g + 0.439 * b);
  const v = Math.round(128 + 0.439 * r - 0.368 * g - 0.071 * b);
  const uv = new Uint8Array((width * height) / 2);
  for (let i = 0; i < uv.length; i += 2) {
    uv[i] = u;
    uv[i + 1] = v;
  }
  return [new Uint8Array(width * height).fill(y), uv];
}

/** What the far end sends: a flat colour at a size and a tone (0: silence). */
const peer = { rgb: 0x1e5ac8, width: 640, height: 480, hz: 660 };
let timer: ReturnType<typeof setInterval> | null = null;
let call: kaya.Voice | null = null;

/** A frame every 1/15 s and 10 ms of samples every 10 ms, paced by the clock. */
function startPeer(frames: kaya.SurfaceFrames, writer: kaya.VoiceWriter): void {
  const start = performance.now();
  let sentFrames = 0, sentSamples = 0, phase = 0;
  let shown: { key: string; y: Uint8Array; uv: Uint8Array } | null = null;
  timer = setInterval(() => {
    const elapsed = (performance.now() - start) / 1000;
    while (sentFrames / 15 <= elapsed) {
      const key = `${peer.rgb} ${peer.width} ${peer.height}`;
      if (shown === null || shown.key !== key) {
        const [y, uv] = nv12(peer.width, peer.height, peer.rgb);
        shown = { key, y, uv };
      }
      frames.submit({ width: peer.width, height: peer.height, y: shown.y, yStride: peer.width, uv: shown.uv, uvStride: peer.width, timestampNs: BigInt(Math.round(elapsed * 1e9)), rotation: 0 });
      sentFrames += 1;
    }
    while (sentSamples / 48000 <= elapsed) {
      const chunk = new Int16Array(480);
      for (let i = 0; i < 480; i++) {
        chunk[i] = peer.hz > 0 ? Math.round(Math.sin(phase) * 12000) : 0;
        phase = (phase + (2 * Math.PI * peer.hz) / 48000) % (2 * Math.PI);
      }
      writer.write(chunk);
      sentSamples += 480;
    }
  }, 5);
}

const { line, view } = app.window({ title: "far end", width: 520, height: 640 }, () => {
  const line = kaya.signal("voice none");
  let view: kaya.Widget | null = null;
  kaya.column(() => {
    kaya.label({ bind: line }); // label#0
    kaya.row(() => {
      kaya.button("Connect", {
        onClick: () => {
          if (call !== null || view === null) return;
          call = kaya.voice({
            onRoute: (route) => line.set(route === "failed" ? "voice failed" : route === "none" ? "voice none" : "voice playing"),
          });
          Object.assign(peer, { rgb: 0x1e5ac8, width: 640, height: 480, hz: 660 });
          startPeer(kaya.surfaceFrames(view), call.writer());
        },
      }); // button#0
      kaya.button("Change", { onClick: () => Object.assign(peer, { rgb: 0xc83c1e, width: 1280, height: 720, hz: 440 }) }); // button#1
      kaya.button("Quiet", { onClick: () => (peer.hz = 0) }); // button#2
      kaya.button("Hang up", {
        onClick: () => {
          if (call === null) return;
          if (timer !== null) clearInterval(timer);
          timer = null;
          call.release();
          call = null;
          line.set("voice none");
        },
      }); // button#3
    });
    view = kaya.surface().a11yLabel("Peer"); // surface#0
  });
  return { line, view };
});
void line;
void view;

app.run();
