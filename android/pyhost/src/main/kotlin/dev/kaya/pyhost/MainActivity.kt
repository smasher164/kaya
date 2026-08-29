package dev.kaya.pyhost

import android.os.Bundle
import android.system.Os
import android.view.KeyEvent
import androidx.activity.ComponentActivity
import dev.kaya.KayaCompose
import dev.kaya.KayaPy
import dev.kaya.KayaRing
import java.io.File

/**
 * The PYTHON guests' shell — milestone2go's five lines with the guest
 * tier swapped: python consumes the occurrence ring directly through
 * ctypes over the C ABI, so [KayaRing.attach] and never `Kaya.attach`
 * (the Go shell's reasoning, verbatim). One bundle carries every
 * python scene behind app/main.py's KAYA_SELFTEST dispatch
 * (tools/pyhost-main.py) — the iOS bundle's pattern, which was this
 * platform's pattern first.
 */
class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        // KAYA_* intent extras into libc's live environ BEFORE the
        // interpreter starts: CPython snapshots environ at init, so
        // os.environ sees these (unlike Go's runtime.envs, which reads
        // a process entry a loaded library never gets).
        intent.extras?.let { extras ->
            for (key in extras.keySet()) {
                if (key.startsWith("KAYA_")) {
                    @Suppress("DEPRECATION")
                    Os.setenv(key, extras.get(key).toString(), true)
                }
            }
        }
        // Python needs TMPDIR; Android sets it only from API 33.
        Os.setenv("TMPDIR", cacheDir.toString(), false)

        System.loadLibrary("kaya")
        // libkaya_pyhost's DT_NEEDED pulls libpython3.15.so out of the
        // same jniLibs namespace.
        System.loadLibrary("kaya_pyhost")
        KayaRing.attach(this)
        KayaCompose.mount(this)
        // The guest runs to completion off the UI thread: extraction
        // behind a version stamp (the testbed re-extracts EVERY launch,
        // which pays the full copy each time — invariant 8 says the
        // stamp), then CPython, whose app.run() parks as the occurrence
        // consumer until the core shuts down.
        Thread {
            val home = extractPython()
            KayaPy.run(home.toString(), File(home, "app").toString())
        }.start()
    }

    /**
     * assets/python -> filesDir/python, once per staged version. The
     * stamp is written by the runner's staging step; equal stamps skip
     * the copy. A name ending `.gz-` loses the trailing `-` on the way
     * out (AAPT decompresses real `.gz` assets, so staging renames).
     */
    private fun extractPython(): File {
        val root = File(filesDir, "python")
        // NOT a dotfile: AAPT silently excludes hidden files from
        // assets, and the stamp then fails the open at first launch.
        val stampAsset = assets.open("python/kaya-stamp").readBytes()
        val stampFile = File(root, "kaya-stamp")
        if (stampFile.exists() && stampFile.readBytes().contentEquals(stampAsset)) {
            return root
        }
        root.deleteRecursively()
        val queue = ArrayDeque(listOf("python"))
        while (queue.isNotEmpty()) {
            val dir = queue.removeFirst()
            val entries = assets.list(dir) ?: continue
            if (entries.isEmpty()) continue
            for (name in entries) {
                val path = "$dir/$name"
                val children = assets.list(path)
                if (children != null && children.isNotEmpty()) {
                    queue.addLast(path)
                } else {
                    val outName = path.removePrefix("python/").let {
                        if (it.endsWith(".gz-")) it.dropLast(1) else it
                    }
                    val out = File(root, outName)
                    out.parentFile?.mkdirs()
                    assets.open(path).use { ins ->
                        out.outputStream().use { outs -> ins.copyTo(outs) }
                    }
                }
            }
        }
        stampFile.writeBytes(stampAsset)
        return root
    }

    override fun dispatchKeyShortcutEvent(event: KeyEvent): Boolean =
        KayaCompose.dispatchKeyShortcutEvent(event) || super.dispatchKeyShortcutEvent(event)
}
