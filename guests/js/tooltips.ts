// The tooltips scene (tools/scenes/tooltips.steps; docs/tooltip-plan.md).
//     KAYA_SELFTEST=tooltips node guests/js/tooltips.ts

import * as kaya from "kaya-gui";

const Account = kaya.record({ name: String, note: String }, "Account");

const app = new kaya.App();

let nameHelp!: kaya.Signal<string>;

function onSave(): void {
  nameHelp.set("Your name, as saved");
}

app.window({}, () => {
  nameHelp = kaya.signal("Your full name as it appears on the card");
  const accounts = kaya.collection(Account);
  const settings = kaya.column(() => {
    kaya.button("Save", { onClick: onSave }).help("Saves the draft to disk").a11yId("save"); // button#0
    kaya.button("Discard").help("Throws the draft away").a11yHint("discard every change").a11yId("discard"); // button#1
    kaya.entry().help(nameHelp).a11yId("fullname"); // entry#0
    kaya.slider({ min: 0, max: 1, value: 0.5 }).help("How loud the preview plays").a11yId("volume"); // slider#0
    for (const account of accounts) {
      kaya.label({ bind: account.name }).help(account.note).a11yId(account.name);
    }
  });
  settings.help("The settings for this account").a11yId("settings");

  accounts.insert("a", Account({ name: "a", note: "The first account, opened in March" }));
  accounts.insert("b", Account({ name: "b", note: "The second account, opened in May" }));
});

app.run();
