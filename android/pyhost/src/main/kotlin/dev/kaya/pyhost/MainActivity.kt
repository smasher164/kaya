package dev.kaya.pyhost

import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.system.Os
import android.view.KeyEvent
import androidx.activity.ComponentActivity
import androidx.core.splashscreen.SplashScreen.Companion.installSplashScreen
import dev.kaya.KayaCompose
import dev.kaya.KayaEnv
import dev.kaya.KayaGuestStart
import dev.kaya.KayaPy
import dev.kaya.KayaRing
import java.io.File

/** The window-free half of the start, which a notification reply's
 * receiver runs in a process with no Activity (dev.kaya.KayaGuestStart). */
object GuestStart : KayaGuestStart {
    /** One interpreter per process: a later onCreate only re-mounts. */
    private var started = false

    override fun start(context: Context) {
        // Python needs TMPDIR; Android sets it only from API 33.
        Os.setenv("TMPDIR", context.cacheDir.toString(), false)
        System.loadLibrary("kaya")
        // libkaya_pyhost's DT_NEEDED pulls libpython3.15.so out of the
        // same jniLibs namespace.
        System.loadLibrary("kaya_pyhost")
        KayaRing.attach(context, context.filesDir.absolutePath)
        KayaCompose.startHeadless(context)
        if (started) return
        started = true
        // The guest runs to completion off the UI thread: extraction
        // behind a version stamp, then CPython, whose app.run() parks as
        // the occurrence consumer until the core shuts down.
        val app = context.applicationContext
        Thread {
            val home = extractPython(app)
            KayaPy.run(home.toString(), File(home, "app").toString())
        }.start()
    }

    /**
     * assets/python -> filesDir/python, once per staged version. The
     * stamp is written by the runner's staging step; equal stamps skip
     * the copy. A name ending `.gz-` loses the trailing `-` on the way
     * out (AAPT decompresses real `.gz` assets, so staging renames).
     */
    fun extractPython(context: Context): File {
        val root = File(context.filesDir, "python")
        // NOT a dotfile: AAPT silently excludes hidden files from
        // assets, and the stamp then fails the open at first launch.
        val stampAsset = context.assets.open("python/kaya-stamp").readBytes()
        val stampFile = File(root, "kaya-stamp")
        if (stampFile.exists() && stampFile.readBytes().contentEquals(stampAsset)) {
            return root
        }
        root.deleteRecursively()
        val queue = ArrayDeque(listOf("python"))
        while (queue.isNotEmpty()) {
            val dir = queue.removeFirst()
            val entries = context.assets.list(dir) ?: continue
            if (entries.isEmpty()) continue
            for (name in entries) {
                val path = "$dir/$name"
                val children = context.assets.list(path)
                if (children != null && children.isNotEmpty()) {
                    queue.addLast(path)
                } else if (path != "python/kaya-stamp") {
                    // THE STAMP IS WRITTEN ONCE, AT THE END, AND THE WALK
                    // MAY NOT COPY IT: it sorts between `app` and `lib`, so
                    // a process killed mid-copy would otherwise leave a
                    // STAMPED half-tree that every later launch matches and
                    // skips (docs/traps.md).
                    val outName = path.removePrefix("python/").let {
                        if (it.endsWith(".gz-")) it.dropLast(1) else it
                    }
                    val out = File(root, outName)
                    out.parentFile?.mkdirs()
                    context.assets.open(path).use { ins ->
                        out.outputStream().use { outs -> ins.copyTo(outs) }
                    }
                }
            }
        }
        stampFile.writeBytes(stampAsset)
        return root
    }
}

/**
 * The PYTHON guests' shell — gohost's five lines with the guest tier
 * swapped: python consumes the occurrence ring directly through ctypes
 * over the C ABI, so [KayaRing.attach] and never `Kaya.attach` (the Go
 * shell's reasoning). One bundle carries every python scene behind
 * app/main.py's KAYA_SELFTEST dispatch (tools/pyhost-main.py).
 */
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

        GuestStart.start(this)
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

    override fun dispatchKeyShortcutEvent(event: KeyEvent): Boolean =
        KayaCompose.dispatchKeyShortcutEvent(event) || super.dispatchKeyShortcutEvent(event)
}
