package dev.kaya.milestone2kt

import android.content.Intent
import android.os.Bundle
import android.system.Os
import android.util.Log
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

        System.loadLibrary("kaya")
        KayaRing.attach(this)
        KayaCompose.mount(this)
        // A SCENE IS REGISTERED HERE AS SOON AS ITS GUEST EXISTS, even
        // when no leg runs it yet: whether a leg runs is the Compose
        // arm's question (tools/check-stubs.sh reads the backend, not
        // this selector), and an unregistered name silently runs
        // milestone2 against the other scene's script.
        val scene = when (System.getenv("KAYA_SELFTEST")) {
            "a11y" -> A11y::app
            "a11yrows" -> A11yRows::app
            "entry" -> Entry::app
            "gallery" -> Gallery::app
            "todos" -> Todos::app
            "reorder" -> Reorder::app
            "feed" -> Feed::app
            "align" -> Align::app
            "grow" -> Grow::app
            "layout" -> Layout::app
            "confirm" -> Confirm::app
            "stall" -> Stall::app
            "nav" -> Nav::app
            // One app behind both list-detail scripts. `split` itself
            // is desktop-only (it drives resize_window, which this host
            // rejects), so only `listdetail` is wired.
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
            "background" -> Background::app
            "undo" -> Undo::app
            "ranges" -> Ranges::app
            "dirty" -> Dirty::app
            "save" -> Save::app
            "filedialog" -> FileDialog::app
            "styling" -> Styling::app
            // The asset root arrives from outside: the leg pushes it and
            // names it in KAYA_ASSET_DIR, an extra that reaches the core
            // through the Os.setenv loop above.
            "typeface" -> Typeface::app
            "toolbar" -> Toolbar::app
            "table" -> Table::app
            // NOTHING IS LOWERED AT RUNTIME on this host: the launcher
            // icon and the app's name are the INSTALLED PACKAGE's,
            // compiled by android/build.gradle.kts
            // (docs/app-identity-plan.md, rulings 3 and 4).
            "identity" -> Identity::app
            // THIS TIER'S LEG IS THE STAGED-DIRECTORY ROUTE: it arrives
            // with a KAYA_ASSET_DIR where the compose and go legs arrive
            // with none and resolve out of the APK's own assets/. The
            // same byte-frozen census must come out of both.
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

    override fun dispatchKeyShortcutEvent(event: KeyEvent): Boolean =
        KayaCompose.dispatchKeyShortcutEvent(event) || super.dispatchKeyShortcutEvent(event)

    // The save-jvm WATCH's second discriminator (docs/deferred.md): the
    // fifth sighting proved the registered callback never runs for the
    // lost save. This logs every result the ACTIVITY receives — a line
    // here without a KAYA_SAVE_RESULT beside it convicts the registry's
    // dispatch; no line at all convicts delivery upstream of the app.
    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        Log.i("kaya", "KAYA_ACTIVITY_RESULT: rc=$requestCode code=$resultCode data=${data != null}")
        @Suppress("DEPRECATION")
        super.onActivityResult(requestCode, resultCode, data)
    }
}
