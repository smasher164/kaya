package dev.kaya.milestone2go

import android.os.Bundle
import android.system.Os
import android.view.KeyEvent
import androidx.activity.ComponentActivity
import dev.kaya.KayaCompose
import dev.kaya.KayaGo
import dev.kaya.KayaRing

/**
 * The Go guest's shell. This is milestone2kt's Activity with ONE line
 * changed, and the one line is the whole difference between the two
 * languages on this platform: the JVM shell ends by starting the guest
 * itself (`Thread(scene, "kaya-app").start()`), which it can do because
 * the guest is Java. The JVM cannot call a Go function, so here the
 * guest's own library is asked to start its thread — [KayaGo.attach].
 *
 * Everything above that line is identical to the JVM shell's, including
 * why: [KayaRing.attach] and not `Kaya.attach`, because Go consumes the
 * occurrence ring directly through the C ABI and `Kaya.attach` would
 * replace the ring sink with a channel into a Rust AppCtx.
 */
class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        // Map KAYA_* intent extras to environment variables; see the
        // milestone2 module for the reasoning. THIS IS THE C
        // ENVIRONMENT, and on this host that distinction is the whole
        // milestone: Os.setenv writes libc's live `environ`, which a Go
        // library loaded into a running process can only read through
        // C (kaya.Env). Go's own os.Getenv answers from a copy made at
        // process entry that this library never saw, so it is empty
        // here forever — see bindings/go/runtime.go and
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
        // Go's ELF constructors run inside this call: the Go runtime
        // boots on threads it makes, and every package init in the guest
        // has run by the time it returns — which is what makes
        // kaya.AndroidMain's registration (an init) visible to the
        // attach below.
        System.loadLibrary("milestone2go")
        KayaRing.attach(this)
        KayaCompose.mount(this)
        KayaGo.attach(this)
    }

    // The hardware-keyboard route for menu shortcuts; identical in all
    // three hosts on purpose — the guest language never changes how a
    // chord reaches the catalog.
    override fun dispatchKeyShortcutEvent(event: KeyEvent): Boolean =
        KayaCompose.dispatchKeyShortcutEvent(event) || super.dispatchKeyShortcutEvent(event)
}
