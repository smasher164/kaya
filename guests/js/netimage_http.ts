// The network images scene over HTTP (tools/scenes/netimage_http.steps;
// docs/network-images-plan.md §5, N12): kaya.RowImages fetching from the
// lane's media server with its default fetch, the platform's own `fetch`.
// Twelve rows share three covers, the album case; four rows fail or wait in
// the ways a real catalogue does. See guests/rust/netimage_http.rs.

import * as kaya from "kaya-gui";

const Track = kaya.record({ title: String, artUrl: String, art: Uint8Array, phase: kaya.ImagePhase }, "Track");

const COVERS = ["covers/cover-600.jpg", "covers/cover-320.jpg", "covers/cover-1000.jpg"];

const base = process.env.KAYA_MEDIA_URL;
if (base === undefined || base === "") {
  throw new Error("kaya: the netimage_http scene reads KAYA_MEDIA_URL, the local server the lane starts (tools/lib/media_server.py)");
}

const app = new kaya.App();
let failures = 0;

app.window({ title: "netimage_http", width: 640, height: 560 }, () => {
  const errors = kaya.signal("errors: 0");
  const tracks = kaya.collection(Track);
  const images = new kaya.RowImages(tracks, {
    url: "artUrl",
    art: "art",
    phase: "phase",
    onError: () => {
      failures += 1;
      errors.set(`errors: ${failures}`);
    },
  });
  kaya.row(() => {
    kaya.label({ bind: errors }).a11yId("errors");
    for (const track of tracks.columns(["Art", "Title"], { grow: 1 })) {
      kaya.row(() => {
        kaya.image(track.art, { fit: "cover", phase: track.phase, onNeeded: images.needed, onReleased: images.released })
          .maxWidth(20)
          .maxHeight(20)
          .a11yId("art");
        kaya.label({ bind: track.title });
      });
    }
  });
  const special = [
    ["missing", "status/404/"],
    ["broken", "status/500/"],
    ["junk", "covers/README.md"],
    ["slow", "trickle/covers/cover-600.jpg"],
  ] as const;
  for (const [key, path] of special) {
    tracks.insert(key, Track({ title: key, artUrl: `${base}/${path}`, art: new Uint8Array(), phase: kaya.ImagePhase.LOADING }));
  }
  for (let i = 0; i < 12; i++) {
    const key = `a${String(i).padStart(2, "0")}`;
    tracks.insert(key, Track({ title: `Track ${i}`, artUrl: `${base}/${COVERS[i % 3]}`, art: new Uint8Array(), phase: kaya.ImagePhase.LOADING }));
  }
});

app.run();
