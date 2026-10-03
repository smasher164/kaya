// The capture (tools/scenes/capture.steps, capture_denied.steps;
// docs/capture-plan.md): a camera and a microphone in one object, a preview,
// and the frames and samples the app's own code is handed in the capture's
// worker (guests/js/capture_worker.ts), on kaya's capture thread's behalf.
// Under the harness the devices are kaya's synthetic ones; the
// `capture_denied` scene answers the camera's prompt no.
//     KAYA_SELFTEST=capture node guests/js/capture.ts

import * as kaya from "kaya-gui";

const CAMERA_1 = "kaya-synthetic-camera-1";
const CAMERA_2 = "kaya-synthetic-camera-2";
const MICROPHONE_1 = "kaya-synthetic-microphone-1";
const MICROPHONE_2 = "kaya-synthetic-microphone-2";

const app = new kaya.App();

function stateLine(r: kaya.CaptureReading): string {
  if (r.state === "running") return `running ${r.width}x${r.height}@${r.frameRate}`;
  if (r.state === "failed") return `failed ${r.failure ?? ""}`;
  if (r.state === "interrupted") return `interrupted ${r.interruption ?? ""}`;
  return r.state;
}

function deviceLine(devices: readonly kaya.CaptureDevice[]): string {
  return devices
    .map((d) => {
      let s = `${d.kind} ${d.id}`;
      if (d.kind === "camera") s += ` ${d.facing}`;
      if (d.preferred) s += " preferred";
      return s;
    })
    .join("; ");
}

function permissionLine(): string {
  return `camera ${kaya.permission("camera")}, microphone ${kaya.permission("microphone")}`;
}

const { labels, call, missing } = app.window({ title: "capture", width: 520, height: 640 }, () => {
  const labels = ["devices", "permissions", "idle", "app frames none, app chunks none", "idle"].map((s) => kaya.signal(s));
  const call = kaya.capture({
    camera: CAMERA_1,
    microphone: MICROPHONE_1,
    size: [600, 400],
    frameRate: 30,
    onState: (r) => labels[2]!.set(stateLine(r)),
    worker: {
      module: new URL("./capture_worker.ts", import.meta.url),
      onMessage: (line) => labels[3]!.set(String(line)),
    },
  });
  const missing = kaya.capture({ camera: "no-such-camera", onState: (r) => labels[4]!.set(stateLine(r)) });
  kaya.column(() => {
    for (const label of labels) kaya.label({ bind: label }); // label#0..#4
    kaya.video(null, { capture: call }).a11yLabel("Self view"); // video#0
    kaya.button("Ask camera", { onClick: () => kaya.requestPermission("camera") }); // button#0
    kaya.button("Start", { onClick: () => call.start() }); // button#1
    kaya.button("Switch", {
      onClick: () => {
        call.setCamera(CAMERA_2);
        call.setMicrophone(MICROPHONE_2);
        call.setSize(1280, 720);
        call.setFrameRate(15);
      },
    }); // button#2
    kaya.button("Mute", { onClick: () => call.setMuted(true) }); // button#3
    kaya.button("Camera off", { onClick: () => call.setCamera(null) }); // button#4
    kaya.button("Stop", { onClick: () => call.stop() }); // button#5
    kaya.button("Open missing", { onClick: () => missing.start() }); // button#6
  });
  kaya.watchCaptureDevices(true);
  return { labels, call, missing };
});

kaya.onCaptureDevices((devices) => labels[0]!.set(deviceLine(devices)));
kaya.onPermission(() => labels[1]!.set(permissionLine()));
void call;
void missing;

app.run();
