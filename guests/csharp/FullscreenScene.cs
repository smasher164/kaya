// The fullscreen scene, C# port — guests/rust/fullscreen.rs,
// tools/scenes/fullscreen.steps. The app keeps its own copy of the state:
// a toggle writes !on, and the user's door moves the copy through
// onFullscreenChanged.

static class FullscreenScene
{
    public static void Run()
    {
        var app = new KayaApp();
        bool on = false;
        int pinged = 0;

        app.Build(tx =>
        {
            var asked = tx.Signal("windowed");
            var user = tx.Signal("no change from the user");
            var pings = tx.Signal("pings 0");

            tx.Window(title: "fullscreen", onFullscreenChanged: (t, now) =>
            {
                on = now;
                t.Write(user, now ? "the user turned fullscreen on" : "the user turned fullscreen off");
            });

            tx.Mount(tx.Column(root =>
            {
                tx.Label(bind: asked); // label#0
                tx.Label(bind: user);  // label#1
                tx.Label(bind: pings); // label#2
                tx.Button("toggle fullscreen", onClick: t =>
                {
                    on = !on;
                    t.Window(fullscreen: on);
                    t.Write(asked, on ? "asked for fullscreen" : "asked for a window");
                }); // button#0
                tx.Button("ping", onClick: t =>
                {
                    pinged += 1;
                    t.Write(pings, $"pings {pinged}");
                }); // button#1
                return root;
            }));
        });

        System.Environment.Exit(app.Run());
    }
}
