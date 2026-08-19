package dev.kaya.milestone2kt;

import dev.kaya.KayaApp;

/**
 * The app-identity conformance scene from the JVM: an app declares what
 * it is called and what it looks like, and the platform shows both.
 * Canonical semantics in guests/rust/identity.rs; the byte-frozen
 * contract in tools/scenes/identity.steps.
 *
 * <p>THE MARK IS THE VENDORED ONE (four flat quadrants) because no
 * platform's own default icon can land on four declared colours, so a
 * lowering that never applied can never read as a pass.
 *
 * <p>THE MARK IS AN ASSET NOW (docs/assets-plan.md, ratified
 * 2026-08-18). This scene used to resolve its own path from an
 * environment override with a repo-relative default and throw in its
 * own words, as its seven siblings each did in their own language.
 * (The variable is not spelled here: tools/check-assets.sh's C3 does
 * not strip block comments, deliberately — a stray delimiter once ate
 * the region holding the thing it was reading for.) {@code KayaApp.asset(name)}
 * is the whole thing now: WHERE the file lives is the core's knowledge —
 * a repo checkout, a bundle's Resources, an APK's packaged assets/ with
 * no path at all — and the four quadrants the scene reads back are the
 * same four wherever it was found. That matters most on the compilation
 * this file shares with Android, where the mark has no path to read.
 *
 * <p>THE SECOND WINDOW HAS NO TITLE OF ITS OWN, deliberately: that is
 * the blank an app's NAME fills on every platform.
 */
final class Identity {
    private static String draft = "";

    static void app() {
        KayaApp app = new KayaApp();

        app.build(tx -> {
            // BEFORE THE FIRST MOUNT, per the declared-once wall.
            //
            // ONE CALL, AND NO FILE I/O IN THE GUEST. The path, the
            // environment override and the sentence for a miss were all
            // hand-written here (and in seven sibling scenes) until
            // asset() arrived; they live in the core now
            // (crates/kaya/src/assets.rs), which is also why the bytes
            // never enter this JVM's heap — the handle goes straight to
            // the blob channel. This file is the one compiled twice,
            // once by javac and once by gradle, and the java.nio.file
            // dance it used to do here was written for the Android half;
            // the name has no path to resolve on either.
            //
            // try-with-resources because the release is explicit here
            // and the redemption has already happened: appIdentity
            // registered the bytes into the pending blob table, which
            // keeps its own reference, so letting go of the asset at the
            // brace costs the transaction nothing.
            try (KayaApp.Asset icon = KayaApp.asset("icons/kaya-mark.png")) {
                tx.appIdentity("Aurora Notes", icon);
            }
            KayaApp.WindowRef win = tx.window(0).title("identity").size(480.0, 360.0);
            // ONE PROMOTED COMMAND, AND IT IS NOT ABOUT COMMANDS.
            // Windows mints its custom caption from the first promotion
            // and from nothing else, and a custom caption REPLACES the
            // system one — taking the system-drawn app icon with it.
            // That is why the identity has a second Windows sink at all,
            // and a scene with no promotion anywhere would leave that
            // sink's arm unreached.
            win.menu("File").item("Save")
                    .symbol(KayaApp.Symbol.DONE)
                    .primary(true);

            KayaApp.Signal<String> heading = tx.signal("identity");
            KayaApp.Signal<String> status = tx.signal("ready");

            tx.mount(tx.column(() -> {
                tx.label(heading); // label#0
                tx.label(status); // label#1
                tx.entry((t, text) -> draft = text); // entry#0
                tx.button("Go", t -> t.write(status, "clicked " + draft)); // button#0
            }));

            // THE UNTITLED WINDOW, and it is DESKTOP-ONLY: a phone host
            // rejects createWindow AT THE ROOT (KAYA_CAP_AUX_WINDOWS is
            // unset there — crates/kaya/src/capi.rs), so a guest that
            // built it aborts before it ever mounts, with the identity
            // already declared. It declares no title at all rather than
            // an empty one: an empty string is a title an app WROTE, and
            // the rule under test is what a window with nothing written
            // shows. The android leg drops the one step that reads it;
            // the NAME's reader there is the APK's own android:label
            // (docs/app-identity-plan.md ruling 3).
            if (onAHostWithAuxiliaryWindows()) {
                tx.createWindow(1).size(360.0, 240.0);
                tx.mountIn(1, tx.column(() -> {
                    KayaApp.Signal<String> caption = tx.signal("no title of its own");
                    tx.label(caption); // label#2
                }));
            }
            return null;
        });

        app.dispatchLoop();
    }

    /**
     * The core's own predicate, asked at RUNTIME because Java has no
     * conditional compilation and this one source is compiled twice —
     * once by javac for the desktop, once by gradle for Android. The
     * other two guests that reach a phone spell the same predicate at
     * compile time (guests/rust/identity.rs's {@code #[cfg]},
     * guests/go/identity's build-tag pair, guests/swift/identity.swift's
     * {@code #if !os(iOS)}); the observable semantics is the one they
     * have, which is invariant 1's whole rule — the idiom decides the
     * spelling, never the behavior.
     *
     * <p>IT MEASURES THE PLATFORM RATHER THAN READING A STRING ABOUT IT.
     * {@code android.os.Build} is part of the Android framework and is
     * loadable on every Android runtime and on no desktop JVM, so this
     * is an observation and not a convention that could be renamed —
     * where {@code java.vm.name} would have been the latter.
     *
     * <p>NOT A CAPABILITY CALL, and the reason is worth writing down:
     * {@code kaya_capabilities()} is a real C export
     * (crates/kaya/include/kaya.h) that answers exactly this question,
     * and NO binding wraps it in any of the eight languages. Wrapping it
     * is an eight-language surface decision, not this guest's to take.
     *
     * <p>A WRONG ANSWER HERE FAILS LOUDLY IN BOTH DIRECTIONS, which is
     * what makes a runtime read tolerable: wrong on Android and the
     * guest aborts at the root exactly as it does today; wrong on the
     * desktop and {@code expect_title window#1} goes red with no window
     * to read. Neither can pass vacuously.
     */
    private static boolean onAHostWithAuxiliaryWindows() {
        try {
            Class.forName("android.os.Build");
            return false;
        } catch (ClassNotFoundException absent) {
            return true;
        }
    }

    private Identity() {}
}
