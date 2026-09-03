package dev.kaya.rusthost

import android.os.Bundle
import android.system.Os
import android.view.KeyEvent
import androidx.activity.ComponentActivity
import dev.kaya.Kaya
import dev.kaya.KayaCompose

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
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
        Kaya.attach(this)
        KayaCompose.mount(this)
    }

    // The hardware-keyboard route for menu shortcuts (ChromeOS/DeX):
    // the shell Activity is where Android delivers a modified chord, and
    // this forwards without deciding, so an unclaimed chord falls
    // through to the platform unchanged.
    override fun dispatchKeyShortcutEvent(event: KeyEvent): Boolean =
        KayaCompose.dispatchKeyShortcutEvent(event) || super.dispatchKeyShortcutEvent(event)
}
