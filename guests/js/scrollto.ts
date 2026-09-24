// The scroll-to scene (tools/scenes/scrollto.steps): the app scrolls a
// list of messages to a row by key (docs/scroll-to-plan.md), opening at
// the newest one before the first layout, jumping to one on a click,
// staying put on a key no row holds, and following its own send.
//     KAYA_SELFTEST=scrollto node guests/js/scrollto.ts

import * as kaya from "kaya-gui";

const Message = kaya.record({ text: String }, "Message");

const app = new kaya.App();

let sent = 60;

function onJump(): void {
  list.scrollToRow("m10");
}

function onNowhere(): void {
  list.scrollToRow("m999");
}

function onSend(): void {
  sent += 1;
  messages.insert(`m${sent}`, Message({ text: `message ${sent}` }));
  count.set(`${sent} messages`);
  list.scrollToRow(`m${sent}`);
}

const { messages, list, count } = app.window(() => {
  const messages = kaya.collection(Message);
  const count = kaya.signal("60 messages");

  const list = kaya.column(() => {
    kaya.label({ bind: count }).a11yId("count");
    kaya.row(() => {
      kaya.button("jump", { onClick: onJump }).a11yId("jump");
      kaya.button("nowhere", { onClick: onNowhere }).a11yId("nowhere");
      kaya.button("send", { onClick: onSend }).a11yId("send");
    });
    return kaya.scroll({ grow: 1 }, () => {
      // The For's own container is what a scrollToRow addresses
      // (docs/scroll-to-plan.md S1): its rows loop names it.
      const rows = messages.rows({ a11yId: "messages" });
      for (const message of rows) {
        kaya.label({ bind: message.text });
      }
      return rows.container;
    });
  });

  for (let i = 1; i <= 60; i++) {
    messages.insert(`m${i}`, Message({ text: `message ${i}` }));
  }
  list.scrollToRow("m60");
  return { messages, list, count };
});

app.run();
