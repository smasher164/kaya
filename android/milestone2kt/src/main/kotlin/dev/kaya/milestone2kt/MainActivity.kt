package dev.kaya.milestone2kt

import android.os.Bundle
import android.system.Os
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
            "entry" -> Entry::app
            "gallery" -> Gallery::app
            "todos" -> Todos::app
            "reorder" -> Reorder::app
            "feed" -> Feed::app
            "grow" -> Grow::app
            "layout" -> Layout::app
            else -> Milestone2::app
        }
        Thread(scene, "kaya-app").start()
    }
}
