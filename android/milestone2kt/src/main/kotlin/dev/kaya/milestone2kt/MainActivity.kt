package dev.kaya.milestone2kt

import android.app.Activity
import android.os.Bundle
import android.system.Os
import dev.kaya.KayaRing

class MainActivity : Activity() {
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
        val scene = if (System.getenv("KAYA_SELFTEST") == "entry") Entry::app else Milestone2::app
        Thread(scene, "kaya-app").start()
    }
}
