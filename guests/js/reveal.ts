// The reveal toggle scene (tools/scenes/reveal.steps; docs/reveal-plan.md
// §5): a password field with its own show/hide toggle, the app's own Show
// and Hide buttons, and a stamped field each row reveals by its own field.
//     KAYA_SELFTEST=reveal node guests/js/reveal.ts

import * as kaya from "kaya-gui";

const Account = kaya.record({ name: String, shown: Boolean }, "Account");

const PASSWORD = "Rv4tNbHy2mQc";

const app = new kaya.App();

function status(text: string): string {
  const n = [...text].length;
  if (n === 0) return "empty";
  if (text === PASSWORD) return `${n} characters, match`;
  return `${n} characters, no match`;
}

function shown(on: boolean): string {
  return on ? "shown" : "hidden";
}

function onTyped(text: string): void {
  statusText.set(status(text));
}

function onSubmitted(text: string): void {
  sentText.set(`sent: ${status(text)}`);
}

function onToggled(on: boolean): void {
  heardText.set(`heard: ${shown(on)}`);
}

function onShow(): void {
  password.revealed(true);
}

function onHide(): void {
  password.revealed(false);
}

function onClear(): void {
  password.clear();
}

function onPin(account: kaya.RowHandle<kaya.Fields<typeof Account.schema>>, text: string): void {
  pinText.set(`pin ${String(account.key)}: ${[...text].length}`);
}

function onPinToggled(account: kaya.RowHandle<kaya.Fields<typeof Account.schema>>, on: boolean): void {
  pinText.set(`pin ${String(account.key)}: ${shown(on)}`);
}

const { statusText, sentText, heardText, pinText, password } = app.window(() => {
  const statusText = kaya.signal("empty");
  const sentText = kaya.signal("sent: -");
  const heardText = kaya.signal("heard: -");
  const pinText = kaya.signal("pin: -");
  const accounts = kaya.collection(Account);
  const password = kaya.column(() => {
    const password = kaya
      .secureField({
        placeholder: "Password",
        contentType: "password",
        revealable: true,
        onChange: onTyped,
        onSubmit: onSubmitted,
        onToggle: onToggled,
      })
      .a11yId("password")
      .a11yLabel("Password");
    kaya.label({ bind: statusText }).a11yId("status");
    kaya.label({ bind: sentText }).a11yId("sent");
    kaya.label({ bind: heardText }).a11yId("heard");
    kaya.button("Show", { onClick: onShow }).a11yId("show");
    kaya.button("Hide", { onClick: onHide }).a11yId("hide");
    kaya.button("Clear", { onClick: onClear }).a11yId("clear");
    kaya.label({ bind: pinText }).a11yId("pin_status");
    for (const account of accounts) {
      kaya.label({ bind: account.name });
      kaya
        .secureField({ revealed: account.shown, revealable: true, onChange: onPin, onToggle: onPinToggled })
        .a11yId("pin");
    }
    return password;
  });

  accounts.insert("b", Account({ name: "b", shown: true }));
  return { statusText, sentText, heardText, pinText, password };
});

app.run();
