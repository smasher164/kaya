package dev.kaya.milestone2kt

import android.os.Bundle
import android.system.Os
import android.view.KeyEvent
import androidx.activity.ComponentActivity
import dev.kaya.KayaCompose
import dev.kaya.KayaRing

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        // Map KAYA_* intent extras to environment variables; see the
        // milestone2 module for the reasoning.
        intent.extras?.let { extras ->
            for (key in extras.keySet()) {
                if (key.startsWith("KAYA_")) {
                    @Suppress("DEPRECATION")
                    Os.setenv(key, extras.get(key).toString(), true)
                }
            }
        }

        // The JVM app is the guest here: kaya attaches its scene to this
        // Activity, and this process's own thread consumes the ring.
        // One APK hosts both scenes; the selftest script doubles as the
        // scene selector (see the rust example's android shim).
        System.loadLibrary("kaya")
        KayaRing.attach(this)
        // The JVM guest presents through the same Compose interpreter
        // as every Android app: attach registered the pump natives and
        // left the core ends for it; occurrences reach this process
        // through the ring.
        KayaCompose.mount(this)
        val scene = when (System.getenv("KAYA_SELFTEST")) {
            "a11y" -> A11y::app
            // Same rule as undo and ranges below: the JVM guest for the
            // stamped-accessibility scene is language-complete, and
            // whether a leg RUNS it is the Compose arm's question
            // (tools/check-stubs.sh reads the backend, not this
            // selector). Registered so the leg has a scene to select the
            // moment that arm lands, rather than silently running
            // milestone2 against the a11yrows script.
            "a11yrows" -> A11yRows::app
            "entry" -> Entry::app
            "gallery" -> Gallery::app
            "todos" -> Todos::app
            "reorder" -> Reorder::app
            "feed" -> Feed::app
            "align" -> Align::app
            "grow" -> Grow::app
            "layout" -> Layout::app
            // Alerts are phone-native; confirm runs here for real.
            "confirm" -> Confirm::app
            // The stall diagnostic: the watchdog is core-side, so this
            // host needs no arm — see the compose tier's note.
            "stall" -> Stall::app
            // Navigation is phone-native too: predictive back IS the
            // affordance; nav runs here for real.
            "nav" -> Nav::app
            // One app behind both list-detail scripts. `split` itself
            // is desktop-only (it drives resize_window, which this host
            // rejects), so only `listdetail` is wired — the bare
            // invariant, at the width the device picked.
            "listdetail" -> Split::app
            "scroll" -> Scroll::app
            "progress" -> Progress::app
            "select" -> Select::app
            "radio" -> Radio::app
            "grid" -> GridScene::app
            "textarea" -> TextareaScene::app
            "sections" -> Sections::app
            "menus" -> Menus::app
            "commands" -> Commands::app
            "clipboard" -> Clipboard::app
            // The undo scene's guest is language-complete here; whether
            // a leg RUNS it is the Compose arm's question, not this
            // selector's (tools/check-stubs.sh reads the backend, not
            // the switch). Registered so the leg has a scene to select
            // the moment that arm lands, rather than silently running
            // milestone2 against the undo script.
            "undo" -> Undo::app
            // Same rule as undo above: the JVM guest for the ranges
            // scene is language-complete, and whether a leg RUNS it is
            // the Compose arm's question (tools/check-stubs.sh reads the
            // backend, not this switch). Registered so the leg has a
            // scene to select the moment that arm lands, rather than
            // silently running milestone2 against the ranges script.
            "ranges" -> Ranges::app
            "styling" -> Styling::app
            // The typeface scene: the JVM guest is language-complete,
            // the Compose arm applies a brand typeface and reads the
            // resolved family back (2026-08-16), and the scene now
            // requests the VENDORED font's bytes — "Sora", a family no
            // platform preinstalls — so nothing holds the legs off and
            // tools/android/run-emulator.sh runs them. The one thing
            // this host supplies from outside is WHERE the asset root
            // is: the guest names `fonts/sora-wght.ttf` and nothing
            // else, and the leg pushes the whole root and names it in
            // KAYA_ASSET_DIR, which arrives as an extra and reaches the
            // core through the Os.setenv loop above.
            "typeface" -> Typeface::app
            // The toolbar scene (docs/chrome-plan.md C2): the `primary`
            // bit as real window chrome. Nothing new is spelled here —
            // the guest is the menus guest with a promotion bit — and
            // this host's chrome is the one the phones already had, the
            // TopAppBar's actions slot plus the ⋮. What landed
            // 2026-08-17 is the READ off that composed bar, which is
            // what took the compose depth stub away and let
            // tools/android/run-emulator.sh wire the legs.
            "toolbar" -> Toolbar::app
            // The identity scene (docs/app-identity-plan.md, rulings 3
            // and 4). NOTHING IS LOWERED AT RUNTIME on this host: the
            // launcher icon and the app's name are the INSTALLED
            // PACKAGE's, compiled from guests/assets/identity.toml by
            // android/build.gradle.kts, and `expect_app_icon` reads that
            // package's icon back through the system PackageManager. The
            // guest names the mark the same way the typeface guest names
            // the font — one asset name, no path and no environment
            // read — and the leg supplies the ROOT it lives in.
            //
            // Its untitled window is desktop-only and Identity.java says
            // so in its own words: a phone rejects createWindow at the
            // root, so the guest skips it and the runner drops the one
            // step that reads it (scene_script_drop).
            "identity" -> Identity::app
            // The assets conformance scene (docs/assets-plan.md). This
            // tier's leg is the one that keeps the STAGED-DIRECTORY
            // route exercised on this platform: it arrives with a
            // KAYA_ASSET_DIR, while the compose and go legs arrive with
            // none and resolve out of the APK's own assets/ through the
            // AssetManager. The same byte-frozen census has to come out
            // of both routes, on the same device.
            "assets" -> Assets::app
            // Desktop-only scenes, registered for the honest failure:
            // selecting one here dies on the capability gate at
            // create_window, never by silently running milestone2.
            "window" -> Window::app
            "panels" -> Panels::app
            else -> Milestone2::app
        }
        Thread(scene, "kaya-app").start()
    }

    // The hardware-keyboard route for menu shortcuts; see the
    // milestone2 module for the reasoning. Identical in both hosts on
    // purpose: the guest language never changes how a chord reaches
    // the catalog.
    override fun dispatchKeyShortcutEvent(event: KeyEvent): Boolean =
        KayaCompose.dispatchKeyShortcutEvent(event) || super.dispatchKeyShortcutEvent(event)
}
