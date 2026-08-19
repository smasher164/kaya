package dev.kaya.milestone2go

import android.os.Bundle
import android.system.Os
import android.view.KeyEvent
import androidx.activity.ComponentActivity
import dev.kaya.KayaCompose
import dev.kaya.KayaGo
import dev.kaya.KayaRing

/**
 * The Go guest's shell. The JVM cannot call a Go function, so the
 * guest's own library is asked to start its thread ([KayaGo.attach])
 * where the JVM shell would call `Thread(scene).start()`.
 *
 * [KayaRing.attach] and not `Kaya.attach`: Go consumes the occurrence
 * ring directly through the C ABI, and `Kaya.attach` would replace the
 * ring sink with a channel into a Rust AppCtx.
 */
class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        // Map KAYA_* intent extras to environment variables. THIS IS
        // THE C ENVIRONMENT: Os.setenv writes libc's live `environ`,
        // which a Go library loaded into a running process reads only
        // through C (kaya.Env). Go's os.Getenv is empty here forever —
        // tools/check-go-env.sh.
        intent.extras?.let { extras ->
            for (key in extras.keySet()) {
                if (key.startsWith("KAYA_")) {
                    @Suppress("DEPRECATION")
                    Os.setenv(key, extras.get(key).toString(), true)
                }
            }
        }

        System.loadLibrary("kaya")
        // Go's ELF constructors run inside this call, so every package
        // init in the guest has run by the time it returns — which is
        // what makes kaya.AndroidMain's registration visible to the
        // attach below.
        System.loadLibrary("milestone2go")
        KayaRing.attach(this)
        KayaCompose.mount(this)
        KayaGo.attach(this)
    }

    override fun dispatchKeyShortcutEvent(event: KeyEvent): Boolean =
        KayaCompose.dispatchKeyShortcutEvent(event) || super.dispatchKeyShortcutEvent(event)
}
