// The app-identity conformance scene, C# port: an app declares what it
// is called and what it looks like, and the platform shows both.
// Canonical semantics in guests/rust/identity.rs; the byte-frozen
// contract in tools/scenes/identity.steps.
//
// THE MARK IS THE VENDORED ONE (guests/assets/icons/kaya-mark.png, four
// flat quadrants) because no platform's own default icon can land on
// four declared colours, so a lowering that never applied can never read
// as a pass. KAYA_ICON_FILE is how a runner that cannot see the repo
// points at a pushed copy.
//
// THE SECOND WINDOW HAS NO TITLE OF ITS OWN, deliberately: that is the
// blank an app's NAME fills on every platform.

using System;

static class IdentityScene
{
    public static void Run()
    {
        var app = new KayaApp();

        Signal status = default;
        string draft = "";

        app.Build(tx =>
        {
            // BEFORE THE FIRST MOUNT, per the declared-once wall.
            var iconPath =
                Environment.GetEnvironmentVariable("KAYA_ICON_FILE")
                ?? "guests/assets/icons/kaya-mark.png";
            byte[] icon;
            try
            {
                icon = System.IO.File.ReadAllBytes(iconPath);
            }
            catch (Exception e)
                when (e is System.IO.IOException
                      or UnauthorizedAccessException)
            {
                throw new InvalidOperationException(
                    $"kaya: the identity scene needs the vendored mark at " +
                    $"{iconPath} (set KAYA_ICON_FILE or run from the repo " +
                    $"root): {e.Message}", e);
            }
            tx.AppIdentity("Aurora Notes", icon: icon);

            // ONE PROMOTED COMMAND, AND IT IS NOT ABOUT COMMANDS. Windows
            // mints its custom caption from the first promotion and from
            // nothing else, and a custom caption REPLACES the system one
            // — taking the system-drawn app icon with it. That is why the
            // identity has a second Windows sink at all, and a scene with
            // no promotion anywhere would leave that sink's arm unreached.
            var file = tx.Menu("File", items: new[]
            {
                tx.Item("Save", symbol: Symbol.Done, primary: true),
            });
            tx.Window(title: "identity", width: 480, height: 360,
                menus: new[] { file });

            var heading = tx.Signal("identity");
            status = tx.Signal("ready");

            tx.Mount(tx.Column(() =>
            {
                tx.Label(bind: heading);              // label#0
                tx.Label(bind: status);               // label#1
                tx.Entry((t, text) => draft = text);  // entry#0
                tx.Button("Go",                       // button#0
                    onClick: t => t.Write(status, $"clicked {draft}"));
            }));

            // THE UNTITLED WINDOW. It declares no title at all rather
            // than an empty one: an empty string is a title an app
            // WROTE, and the rule under test is what a window with
            // nothing written shows.
            tx.CreateWindow(1, width: 360, height: 240);
            var aux = tx.Column(() =>
            {
                var caption = tx.Signal("no title of its own");
                tx.Label(bind: caption); // label#2
            });
            tx.MountIn(1, aux);
        });

        Environment.Exit(app.Run());
    }
}
