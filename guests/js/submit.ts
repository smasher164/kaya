// The submit scene (tools/scenes/submit.steps): Return in an entry, a
// search field and a `submits` textarea publishes `submitted` with the
// field's text (docs/submit-plan.md); a plain textarea's Return is its
// newline. The app writes each submit into one label.
//     KAYA_SELFTEST=submit node guests/js/submit.ts

import * as kaya from "kaya-gui";

const Thread = kaya.record({ title: String }, "Thread");

const app = new kaya.App();

function onSent(text: string): void {
  sent.set(`sent: ${text}`);
}

/** The stamped row arrives first, as a handle, then the text. */
function onReplied(thread: kaya.RowHandle<kaya.Fields<typeof Thread.schema>>, text: string): void {
  sent.set(`sent: ${String(thread.key)}: ${text}`);
}

const { sent } = app.window(() => {
  const threads = kaya.collection(Thread);
  const sent = kaya.signal("sent: -");

  kaya.column(() => {
    kaya.label({ bind: sent }).a11yId("sent");
    kaya.entry({ placeholder: "Name", onSubmit: onSent }).a11yId("name");
    kaya.search({ placeholder: "Search", onSubmit: onSent }).a11yId("find");
    kaya.textarea({ onSubmit: onSent }).a11yId("plain");
    kaya.textarea({ submits: true, onSubmit: onSent }).a11yId("compose");
    for (const thread of threads) {
      kaya.label({ bind: thread.title });
      kaya.entry({ onSubmit: onReplied }).a11yId("reply");
    }
  });

  threads.insert("r1", Thread({ title: "First" }));
  threads.insert("r2", Thread({ title: "Second" }));
  return { sent };
});

app.run();
