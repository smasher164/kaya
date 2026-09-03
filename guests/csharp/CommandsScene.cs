// The commands scene, C# port — guests/rust/commands.rs,
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

            // Reload keeps this menu non-empty once macOS moves Settings out.
            var file = tx.Menu("File", items: new[]
            {
                tx.Item("Reload"),
                tx.Item("Settings…", shortcut: "primary+comma",
                    role: Tx.RoleSettings,
                    onActivate: t =>
                    {
                        // Fires twice on purpose: the chord and the declared path.
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
