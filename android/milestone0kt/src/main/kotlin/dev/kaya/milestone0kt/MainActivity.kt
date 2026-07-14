package dev.kaya.milestone0kt

import android.app.Activity
import android.os.Bundle
import android.system.Os
import dev.kaya.Kaya

class MainActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        // Map KAYA_* intent extras to environment variables; see the
        // milestone0 module for the reasoning.
        intent.extras?.let { extras ->
            for (key in extras.keySet()) {
                if (key.startsWith("KAYA_")) {
                    @Suppress("DEPRECATION")
                    Os.setenv(key, extras.get(key).toString(), true)
                }
            }
        }

        // The JVM app is the guest here: kaya presents, this process's
        // own thread consumes the ring.
        System.loadLibrary("kaya")
        Kaya.nativeRun(this)
        Thread(Milestone0::app, "kaya-app").start()
    }
}
