package dev.kaya.milestone2kt;

import dev.kaya.KayaApp;

/**
 * The standard-commands scene, JVM port: a chord on every leaf kind (a
 * checkable command, one option of a group, a plain command), the
 * punctuation keys those chords need, and the `settings` role — which
 * macOS shows in the application menu while the item stays addressable
 * where it was declared. Canonical semantics in
 * guests/rust/commands.rs; the byte-frozen contract in
 * tools/scenes/commands.steps.
 */
final class Commands {
    // Java lambdas cannot assign captured locals; the settings counter
    // lives here.
    private static int settingsCount;

    static void app() {
        KayaApp app = new KayaApp();
        settingsCount = 0;

        app.build(tx -> {
            KayaApp.Signal<String> status = tx.signal("ready");
            KayaApp.Signal<Boolean> details = tx.signal(false);
            KayaApp.Signal<Double> sort = tx.signal(0.0);

            KayaApp.WindowRef win = tx.window(0).title("commands");

            // The settings command declares its own punctuation chord
            // and the role that tells macOS where users look for it. An
            // ordinary command sits beside it so the menu that declared
            // it is not left empty once the platform moves it.
            KayaApp.MenuItem file = win.menu("File");
            file.item("Reload");
            file.item("Settings…").shortcut("primary+comma").role(KayaApp.ROLE_SETTINGS)
                    .onActivate(t -> {
                        // Fires twice on purpose: once by the chord,
                        // once by activating the item at its DECLARED
                        // path — which on macOS lives in the
                        // application menu by then.
                        settingsCount++;
                        t.write(status, "settings " + settingsCount);
                    });

            // A checkable command carrying its own key, and a group
            // whose options each answer their own chord.
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
