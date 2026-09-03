package dev.kaya.guests;

import dev.kaya.KayaApp;

/**
 * The commands scene from the JVM — guests/rust/commands.rs,
 * tools/scenes/commands.steps.
 */
public final class Commands {
    // Java lambdas cannot assign captured locals.
    private static int settingsCount;

    public static void app() {
        KayaApp app = new KayaApp();
        settingsCount = 0;

        app.build(tx -> {
            KayaApp.Signal<String> status = tx.signal("ready");
            KayaApp.Signal<Boolean> details = tx.signal(false);
            KayaApp.Signal<Double> sort = tx.signal(0.0);

            KayaApp.WindowRef win = tx.window(0).title("commands");

            // Reload keeps this menu non-empty once macOS moves Settings out.
            KayaApp.MenuItem file = win.menu("File");
            file.item("Reload");
            file.item("Settings…").shortcut("primary+comma").role(KayaApp.ROLE_SETTINGS)
                    .onActivate(t -> {
                        // Fires twice on purpose: the chord and the declared path.
                        settingsCount++;
                        t.write(status, "settings " + settingsCount);
                    });

            KayaApp.MenuItem view = win.menu("View");
            view.toggle("Details").checked(details).shortcut("primary+backslash")
                    .onToggle((t, on) -> t.write(status, on ? "details on" : "details off"));

            // Option order IS the index vocabulary: Name = 0, Date = 1.
            KayaApp.MenuItem sortGroup = view.radioGroup("Sort");
            sortGroup.option("Name").shortcut("primary+1");
            sortGroup.option("Date").shortcut("primary+2");
            sortGroup.value(sort).onSelect((t, index) ->
                    t.write(status, index == 1 ? "sorted date" : "sorted name"));

            tx.mount(tx.column(() -> {
                tx.label(status); // label#0
            }));
        });

        app.dispatchLoop();
    }
}
