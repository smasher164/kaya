// The scroll conformance scene, JS port — the viewport grows so the
// enclosing track constrains it (an unconstrained viewport hugs its
// content and nothing overflows); the bottom button, reachable only by
// scrolling, proves the scrolled-to content is live. See
// guests/rust/scroll.rs and tools/scenes/scroll.steps.

import * as kaya from "kaya-gui";

const app = new kaya.App();

function bottomClicked(): void {
  status.set("bottom clicked");
}

let status!: kaya.Signal<string>;

app.window({ title: "scroll" }, () => {
  status = kaya.signal("at top");
  kaya.column(() => {
    kaya.label({ bind: status }); // label#0
    kaya.scroll({ grow: 1 }, () => {
      // scroll#0
      kaya.column(() => {
        for (let i = 1; i < 30; i++) {
          kaya.label({ bind: kaya.signal(`row ${i}`) });
        }
        kaya.button("bottom", { onClick: bottomClicked }); // button#0
      });
    });
  });
});

app.run();
