package dev.kaya.milestone2

import android.os.Bundle
import android.system.Os
import androidx.activity.ComponentActivity
import dev.kaya.Kaya
import dev.kaya.KayaCompose

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        // Map KAYA_* intent extras to environment variables, so the
        // library's env-based switches keep one spelling everywhere:
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

        System.loadLibrary("milestone2_android")
        // One backend per platform: attach wires the pump and the
        // Activity mounts the Compose interpreter.
        Kaya.attach(this)
        KayaCompose.mount(this)
    }
}
