// The identity scene, C# port — guests/rust/identity.rs,
// tools/scenes/identity.steps.

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
            using var icon = tx.Asset("icons/kaya-mark.png");
            tx.AppIdentity("Aurora Notes", icon);

            // ONE PROMOTED COMMAND, and not about commands: Windows mints its
            // custom caption from the first promotion, taking the system icon.
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

            // No title at all rather than an empty one: an empty string is a
            // title an app WROTE.
            if (KayaApp.Capabilities().AuxWindows)
            {
                tx.CreateWindow(1, width: 360, height: 240);
                var aux = tx.Column(() =>
                {
                    var caption = tx.Signal("no title of its own");
                    tx.Label(bind: caption); // label#2
                });
                tx.MountIn(1, aux);
            }
        });

        Environment.Exit(app.Run());
    }
}
