package dev.kaya.rusthost

import android.content.Intent
import android.os.Bundle
import android.view.KeyEvent
import androidx.activity.ComponentActivity
import androidx.core.splashscreen.SplashScreen.Companion.installSplashScreen
import dev.kaya.Kaya
import dev.kaya.KayaCompose
import dev.kaya.KayaEnv

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        // The launch slot's other half: the manifest names
        // Theme.Kaya.Launch and THIS swaps the activity onto
        // postSplashScreenTheme. Without it the window background
        // stays the launch colour for the app's whole life
        // (docs/tasks-s2-plan.md T4; tools/check-app-identity.py
        // holds every app module to making the call).
        installSplashScreen()
        super.onCreate(savedInstanceState)

        // The KAYA_* extras into the live environment (KayaEnv, which
        // says why it is called from BOTH doors).
        KayaEnv.fromIntent(intent)

        System.loadLibrary("rusthost")
        Kaya.attach(this, filesDir.absolutePath)
        KayaCompose.mount(this)
    }

    // EVERY WARM ARRIVAL COMES THROUGH HERE, since the activity is
    // `launchMode="singleTask"` for app links: a tapped notification
    // (docs/tasks-s3-plan.md §3), a tapped link (docs/app-links-plan.md
    // §4) and a plain explicit start with extras all land on this one
    // door. `setIntent` FIRST — `getIntent()` answers the LAUNCH intent
    // until it is called (docs/traps.md, measured on the probe) — then
    // the env extras, then the two one-shot readers, each of which drops
    // an intent that is not its own. The COLD halves are read by
    // KayaCompose.mount off the activity's own intent.
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        KayaEnv.fromIntent(intent)
        KayaCompose.notificationIntent(intent)
        KayaCompose.linkIntent(intent)
    }

    // The hardware-keyboard route for menu shortcuts (ChromeOS/DeX):
    // the shell Activity is where Android delivers a modified chord, and
    // this forwards without deciding, so an unclaimed chord falls
    // through to the platform unchanged.
    override fun dispatchKeyShortcutEvent(event: KeyEvent): Boolean =
        KayaCompose.dispatchKeyShortcutEvent(event) || super.dispatchKeyShortcutEvent(event)
}
