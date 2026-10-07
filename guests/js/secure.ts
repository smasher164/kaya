// The secure field scene (tools/scenes/secure.steps;
// docs/secure-entry-plan.md §5): a password field whose text the app
// receives whole and answers only as a length and a match, a clear button,
// and a stamped field per account whose edits name the row.
//     KAYA_SELFTEST=secure node guests/js/secure.ts

import * as kaya from "kaya-gui";

const Account = kaya.record({ name: String }, "Account");

const PASSWORD = "Zq7vKeXw9pLm";

const app = new kaya.App();

function status(text: string): string {
  const n = [...text].length;
  if (n === 0) return "empty";
  if (text === PASSWORD) return `${n} characters, match`;
  return `${n} characters, no match`;
}

function onTyped(text: string): void {
  statusText.set(status(text));
}

function onSubmitted(text: string): void {
  sentText.set(`sent: ${status(text)}`);
}

function onClear(): void {
  password.clear();
}

function onPin(account: kaya.RowHandle<kaya.Fields<typeof Account.schema>>, text: string): void {
  pinText.set(`pin ${String(account.key)}: ${[...text].length}`);
}

const { statusText, sentText, pinText, password } = app.window(() => {
  const statusText = kaya.signal("empty");
  const sentText = kaya.signal("sent: -");
  const pinText = kaya.signal("pin: -");
  const accounts = kaya.collection(Account);
  const password = kaya.column(() => {
    const password = kaya
      .secureField({ placeholder: "Password", onChange: onTyped, onSubmit: onSubmitted })
      .a11yId("password")
      .a11yLabel("Password");
    kaya.label({ bind: statusText }).a11yId("status");
    kaya.label({ bind: sentText }).a11yId("sent");
    kaya.button("Clear", { onClick: onClear }).a11yId("clear");
    kaya.label({ bind: pinText }).a11yId("pin_status");
    for (const account of accounts) {
      kaya.label({ bind: account.name });
      kaya.secureField({ onChange: onPin }).a11yId("pin");
    }
    return password;
  });

  accounts.insert("a", Account({ name: "a" }));
  accounts.insert("b", Account({ name: "b" }));
  return { statusText, sentText, pinText, password };
});

app.run();
