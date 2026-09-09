package dev.kaya.rusthost

import android.content.Intent
import android.os.Bundle
import android.system.Os
import android.view.KeyEvent
import androidx.activity.ComponentActivity
import androidx.core.splashscreen.SplashScreen.Companion.installSplashScreen
import dev.kaya.Kaya
import dev.kaya.KayaCompose

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

        // Map KAYA_* intent extras to environment variables, so the
        // library's env switches keep one spelling everywhere:
        //   am start ... --ez KAYA_SELFTEST true
        // is this platform's KAYA_SELFTEST=1 ./app.
        intent.extras?.let { extras ->
            for (key in extras.keySet()) {
                if (key.startsWith("KAYA_")) {
                    @Suppress("DEPRECATION")
                    Os.setenv(key, extras.get(key).toString(), true)
                }
            }
        }

        System.loadLibrary("rusthost")
        Kaya.attach(this, filesDir.absolutePath)
        KayaCompose.mount(this)
    }

    // A TAP ON A DELIVERED NOTIFICATION reaches a running app here
    // (docs/tasks-s3-plan.md §3): the content PendingIntent is addressed
    // to this component with SINGLE_TOP, so the platform delivers the
    // id as a new intent rather than re-creating the Activity. A COLD
    // launch by tap is read by KayaCompose.mount off `getIntent()`.
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        KayaCompose.notificationIntent(intent)
    }

    // The hardware-keyboard route for menu shortcuts (ChromeOS/DeX):
    // the shell Activity is where Android delivers a modified chord, and
    // this forwards without deciding, so an unclaimed chord falls
    // through to the platform unchanged.
    override fun dispatchKeyShortcutEvent(event: KeyEvent): Boolean =
        KayaCompose.dispatchKeyShortcutEvent(event) || super.dispatchKeyShortcutEvent(event)
}
