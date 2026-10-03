// guests/js/capture.ts's capture worker: the app's own code for the call's
// frames and samples (docs/capture-plan.md §4). It checks what it was handed
// and posts what it saw, as a call's encoder would read it.

import * as kaya from "kaya-gui";

let frames: [number, number] | null = null;
let chunk: number | null = null;

function evidence(): string {
  const seen = frames === null ? "app frames none" : `app frames ${frames[0]}x${frames[1]}`;
  const heard = chunk === null ? "app chunks none" : `app chunks of ${chunk}`;
  return `${seen}, ${heard}`;
}

kaya.onCaptureFrame((f) => {
  const whole =
    f.y.length >= f.yStride * f.height &&
    f.uv.length >= f.uvStride * Math.ceil(f.height / 2) &&
    f.yStride >= f.width &&
    f.uvStride >= f.width;
  const size: [number, number] | null = whole ? [f.width, f.height] : null;
  if (frames?.[0] !== size?.[0] || frames?.[1] !== size?.[1]) {
    frames = size;
    kaya.postToApp(evidence());
  }
});

kaya.onCaptureSamples((samples) => {
  if (chunk !== null) return;
  chunk = samples.length;
  kaya.postToApp(evidence());
});
