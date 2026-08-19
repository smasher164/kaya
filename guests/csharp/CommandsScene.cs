// The standard-commands scene, C# port: a chord on every leaf kind, the
// punctuation keys those chords need, and the `settings` role — which
// macOS shows in the application menu while the item stays addressable
// where it was declared. See guests/rust/commands.rs and
// tools/scenes/commands.steps.

using System;

static class CommandsScene
{
    public static void Run()
    {
        var app = new KayaApp();
        int settingsCount = 0;

        app.Build(tx =>
        {
            var status = tx.Signal("ready");
            var details = tx.Signal(false);
            var sort = tx.Signal(0.0);

            // Reload sits beside Settings so this menu is not left empty
            // once a platform moves the settings item elsewhere.
            var file = tx.Menu("File", items: new[]
            {
                tx.Item("Reload"),
                tx.Item("Settings…", shortcut: "primary+comma",
                    role: Tx.RoleSettings,
                    onActivate: t =>
                    {
                        // Fires twice on purpose: once by the chord, once
                        // by activating the item at its DECLARED path.
                        settingsCount++;
                        t.Write(status, $"settings {settingsCount}");
                    }),
            });

            // Option order IS the index vocabulary: Name = 0, Date = 1.
            var view = tx.Menu("View", items: new[]
            {
                tx.Toggle("Details", isChecked: details, shortcut: "primary+backslash",
                    onToggle: (t, on) => t.Write(status, on ? "details on" : "details off")),
                tx.RadioGroup("Sort",
                    options: new[]
                    {
                        tx.Option("Name", shortcut: "primary+1"),
                        tx.Option("Date", shortcut: "primary+2"),
                    },
                    value: sort,
                    onSelect: (t, index) =>
                        t.Write(status, index == 1 ? "sorted date" : "sorted name")),
            });
            tx.Window(title: "commands", menus: new[] { file, view });

            tx.Mount(tx.Column(() =>
            {
                tx.Label(bind: status); // label#0
            }));
        });

        Environment.Exit(app.Run());
    }
}
