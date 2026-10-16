// The shapes scene (tools/scenes/shapes.steps; docs/styling-pass-plan.md
// Y6): one picture clipped three ways, a wider one in a circle, and a stamped
// avatar that is round while it loads. See guests/rust/shapes.rs.

import * as kaya from "kaya-gui";

const Person = kaya.record({ name: String, face: Uint8Array, phase: kaya.ImagePhase }, "Person");

const app = new kaya.App();
const art = kaya.asset("covers/cover-600.jpg").bytes();
const photo = kaya.asset("images/photo.jpg").bytes();

app.window({ title: "shapes", width: 420, height: 360 }, () => {
  const people = kaya.collection(Person);
  kaya.column({ spacing: 16 }, () => {
    kaya.row({ spacing: 16 }, () => {
      for (const shape of ["rect", "rounded", "circle"] as const) {
        kaya.image(art, { fit: "cover", shape }).maxWidth(48).maxHeight(48).a11yId(shape);
      }
      kaya.image(photo, { shape: "circle" }).maxWidth(48).maxHeight(48).a11yId("wide");
    });
    for (const person of people) {
      kaya.row(() => {
        kaya.image(person.face, { fit: "cover", phase: person.phase, shape: "circle" }).maxWidth(48).maxHeight(48).a11yId("avatar");
        kaya.label({ bind: person.name });
      });
    }
  });
  people.insert("a1", Person({ name: "Ada", face: new Uint8Array(), phase: kaya.ImagePhase.LOADING }));
});

app.run();
