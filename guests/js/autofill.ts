// The content type scene (tools/scenes/autofill.steps;
// docs/autofill-plan.md §5): a sign-in form, a sign-up form, a code field
// and a phone field, each saying what it holds; a button that turns the
// sign-in name into an email address and back; and a stamped code field.
//     KAYA_SELFTEST=autofill node guests/js/autofill.ts

import * as kaya from "kaya-gui";

const Account = kaya.record({ name: String }, "Account");

const app = new kaya.App();
let email = false;

function onSwitch(): void {
  email = !email;
  if (email) {
    user.contentType("email");
    mode.set("sign in with an email address");
  } else {
    user.contentType("username");
    mode.set("sign in with a username");
  }
}

const { mode, user } = app.window(() => {
  const mode = kaya.signal("sign in with a username");
  const accounts = kaya.collection(Account);
  const user = kaya.column(() => {
    const user = kaya.entry({ placeholder: "Username", contentType: "username" }).a11yId("user");
    kaya.secureField({ placeholder: "Password", contentType: "password" }).a11yId("password");
    kaya.label({ bind: mode }).a11yId("mode");
    kaya.button("Use email", { onClick: onSwitch }).a11yId("switch");
    kaya.entry({ placeholder: "Email", contentType: "email" }).a11yId("email");
    kaya.secureField({ placeholder: "New password", contentType: "new_password" }).a11yId("new");
    kaya.entry({ placeholder: "Code", contentType: "one_time_code" }).a11yId("code");
    kaya.entry({ placeholder: "Phone", contentType: "phone" }).a11yId("phone");
    kaya.entry({ placeholder: "Note" }).a11yId("note");
    for (const account of accounts) {
      kaya.label({ bind: account.name });
      kaya.secureField({ contentType: "one_time_code" }).a11yId("pin");
    }
    return user;
  });

  accounts.insert("a", Account({ name: "a" }));
  return { mode, user };
});

app.run();
