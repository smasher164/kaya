// The restoration scene (tools/scenes/restore.steps,
// docs/restoration-plan.md SR15): the draft lives in the session store and
// comes back through the ordinary build; the list's scroll and the text's
// caret come back on their own.

import * as kaya from "kaya-gui";

const Message = kaya.record({ text: String }, "Message");

const app = new kaya.App();
const store = kaya.appSession();

const { messages } = app.window({ title: "restore" }, () => {
  const messages = kaya.collection(Message);
  kaya.column(() => {
    kaya.label({ bind: kaya.signal(`launch ${kaya.restored()}`) });
    kaya.entry({ onChange: (text: string) => store.setString("draft", text) }).setText(store.getString("draft", ""));
    kaya.row(() => {
      kaya.button("jump", { onClick: () => list.scrollToRow("m30") }).a11yId("jump");
      kaya.button("select", { onClick: () => doc.selectRange([4, 9]) }).a11yId("select");
    });
    const doc = kaya.textarea();
    doc.a11yId("doc").setText("the quick brown fox");
    const list = kaya.scroll({ grow: 1 }, (scroll) => {
      scroll.a11yId("list");
      const rows = messages.rows({ a11yId: "messages" });
      for (const message of rows) {
        kaya.label({ bind: message.text });
      }
      return rows.container;
    });
  });
  return { messages };
});

app.build(() => {
  for (let i = 1; i <= 60; i++) {
    messages.insert(`m${i}`, Message({ text: `message ${i}` }));
  }
});

app.run();
