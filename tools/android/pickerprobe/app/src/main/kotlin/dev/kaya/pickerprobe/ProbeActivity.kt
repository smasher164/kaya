package dev.kaya.pickerprobe

import android.accessibilityservice.AccessibilityService
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.provider.DocumentsContract
import android.provider.OpenableColumns
import android.system.Os
import android.system.OsConstants
import android.view.accessibility.AccessibilityNodeInfo
import androidx.activity.ComponentActivity
import androidx.activity.result.contract.ActivityResultContracts
import java.io.File
import java.io.FileInputStream

/**
 * Measures every Android assumption the Compose picker arm rests on, in
 * one install, logging under the tag `kayaprobe`. NOT A LANE — see
 * run.sh. The questions are the Q-labels in the log lines below; the
 * answers are docs/file-dialogs-plan.md §6d and docs/traps.md.
 */
class ProbeActivity : ComponentActivity() {
    private val main = Handler(Looper.getMainLooper())
    private var picked: Uri? = null

    /**
     * One run answers ONE shape, because the picker is modal: basic /
     * multi / filter / cancel, the four the scene needs.
     */
    private val variant: String by lazy { intent.getStringExtra("variant") ?: "basic" }

    private fun log(s: String) = android.util.Log.i(ProbeA11y.TAG, "PROBE[$variant] $s")

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        log("==== begin, sdk=${Build.VERSION.SDK_INT} pid=${android.os.Process.myPid()}")

        // Q2: the two halves' idea of "temp".
        log("Q2 java.io.tmpdir=${System.getProperty("java.io.tmpdir")}")
        log("Q2 env TMPDIR=${System.getenv("TMPDIR")}")
        log("Q2 rust std::env::temp_dir would be TMPDIR or /data/local/tmp")
        log("Q2 cacheDir=$cacheDir")
        // Can a guest with no JNI find the shared root WITHOUT
        // hardcoding /storage/emulated/0?
        log("Q8 env EXTERNAL_STORAGE=${System.getenv("EXTERNAL_STORAGE")}")
        log("Q8 env ANDROID_STORAGE=${System.getenv("ANDROID_STORAGE")}")
        log("Q8 Environment.getExternalStorageDirectory=" +
            "${Environment.getExternalStorageDirectory()}")
        log("Q8 publicDocuments=" +
            "${Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOCUMENTS)}")
        log("Q2 externalFilesDir=${getExternalFilesDir(null)}")

        // Q1: which candidate directories this process can make and
        // fill. `isExternalStorageManager` is the appops state the
        // runner would have to grant.
        log("Q1 isExternalStorageManager=${Environment.isExternalStorageManager()}")
        val pid = android.os.Process.myPid()
        val candidates = listOf(
            "data-local-tmp" to "/data/local/tmp/kaya-probe-$pid",
            "cache" to "$cacheDir/kaya-probe-$pid",
            "ext-files" to "${getExternalFilesDir(null)}/kaya-probe-$pid",
            "shared-documents" to
                "${Environment.getExternalStorageDirectory()}/Documents/kaya-probe-$pid",
            "shared-download" to
                "${Environment.getExternalStorageDirectory()}/Download/kaya-probe-$pid",
        )
        var aimAt: String? = null
        for ((label, path) in candidates) {
            val ok = tryWrite(path)
            log("Q1 $label $path -> $ok")
            // ONLY the shared collections: aiming at Android/data/ is
            // accepted and silently lands on Recent (docs/traps.md).
            if (ok == "OK" && aimAt == null && label == "shared-documents") aimAt = path
        }

        // Q3/Q4: register and launch LATE, the way the apply pump would.
        main.postDelayed({ launchPicker(aimAt) }, 1500)
    }

    /** mkdirs plus the scene's two files; the outcome, never a throw. */
    private fun tryWrite(path: String): String = try {
        val dir = File(path)
        if (!dir.mkdirs() && !dir.isDirectory) {
            "MKDIR-FAILED"
        } else {
            File(dir, "picked.txt").writeText("picked bytes")
            File(dir, "decoy.txt").writeText("decoy")
            if (File(dir, "picked.txt").readText() == "picked bytes") "OK" else "READBACK-WRONG"
        }
    } catch (e: Throwable) {
        "${e.javaClass.simpleName}: ${e.message}"
    }

    /**
     * Q3/Q4. StartActivityForResult rather than the OpenDocument
     * contract: the real arm needs the intent verbatim, since the
     * initial directory rides as an extra and WRITE must be asked for.
     */
    private fun launchPicker(aimAt: String?) {
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT)
            .addCategory(Intent.CATEGORY_OPENABLE)
            .setType("*/*")
            .addFlags(
                Intent.FLAG_GRANT_READ_URI_PERMISSION or
                    Intent.FLAG_GRANT_WRITE_URI_PERMISSION,
            )
        if (variant == "multi") {
            intent.putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
        }
        if (variant == "filter") {
            // The scene's advisory filter is an EXTENSION ("txt"); the
            // intent wants MIME types, so the extension has to be mapped.
            val mimes = listOf("txt").mapNotNull {
                android.webkit.MimeTypeMap.getSingleton().getMimeTypeFromExtension(it)
            }
            log("Q9 extensions [txt] -> mimes $mimes")
            intent.putExtra(Intent.EXTRA_MIME_TYPES, mimes.toTypedArray())
        }
        if (aimAt != null) {
            // primary:Documents/kaya-probe-<pid> — the ExternalStorage
            // provider's document id for a path under the primary volume.
            val rel = aimAt.removePrefix("${Environment.getExternalStorageDirectory()}/")
            val docId = "primary:$rel"
            val uri = DocumentsContract.buildDocumentUri(
                "com.android.externalstorage.documents", docId,
            )
            log("Q3 aiming at $uri")
            intent.putExtra(DocumentsContract.EXTRA_INITIAL_URI, uri)
        } else {
            log("Q3 NOTHING WRITABLE ON SHARED STORAGE — cannot aim")
        }

        val launcher = activityResultRegistry.register(
            "probe-picker",
            ActivityResultContracts.StartActivityForResult(),
        ) { result ->
            val clip = result.data?.clipData
            val clipUris = (0 until (clip?.itemCount ?: 0)).map { clip!!.getItemAt(it).uri }
            log("Q4 result code=${result.resultCode} data=${result.data?.data} " +
                "clip=${clipUris.size} $clipUris")
            picked = result.data?.data ?: clipUris.firstOrNull()
            picked?.let { onPicked(it) } ?: log("Q4 no uri — cancelled or failed")
        }
        try {
            launcher.launch(intent)
            log("Q4 launched from a RESUMED activity through activityResultRegistry")
        } catch (e: Throwable) {
            log("Q4 LAUNCH THREW ${e.javaClass.simpleName}: ${e.message}")
        }
        // Q5: let the picker come up, then read and drive it — FROM A
        // WORKER THREAD, which is where the harness's verbs run and
        // which the frozen-window-list trap requires (docs/traps.md).
        main.postDelayed({ Thread { readAndDrivePicker() }.start() }, 3000)
    }

    /** Q5: what the service sees, and whether a click on a row answers. */
    private fun readAndDrivePicker() {
        val svc = ProbeA11y.live
        if (svc == null) {
            log("Q5 NO SERVICE — enable it with adb before running")
            return
        }
        log("Q5 window packages=${svc.windowPackages()}")
        for (pkg in listOf("com.google.android.documentsui", "com.android.documentsui")) {
            val nodes = svc.nodesIn(pkg)
            log("Q5 $pkg -> ${nodes.size} nodes")
            if (nodes.isEmpty()) continue
            for (n in nodes) {
                val id = n.viewIdResourceName ?: ""
                val t = n.text?.toString() ?: ""
                val d = n.contentDescription?.toString() ?: ""
                if (id.isNotEmpty() || t.isNotEmpty() || d.isNotEmpty()) {
                    log("Q5   id=${id.substringAfterLast('/')} cls=${n.className} " +
                        "text=${t} desc=${d} click=${n.isClickable}")
                }
            }
            // The two reads expect_file_dialog needs, in the three
            // spellings the tree offers for "where".
            log("Q5 rows=${allRowTitles(nodes)}")
            log("Q5 where header_title=${textOf(nodes, "header_title")} " +
                "breadcrumbs=${allTexts(nodes, "breadcrumb_text")}")
            if (variant == "cancel") {
                // The scene's `file_choose cancel`. There is no Cancel
                // button — dismissal is BACK, and ONE IS NOT ENOUGH
                // (docs/traps.md). Bounded, with the picker being gone
                // as the only proof.
                var backs = 0
                while (backs < 8) {
                    if (!ProbeA11y.live?.windowPackages().orEmpty().contains(pkg)) break
                    svc.performGlobalAction(AccessibilityService.GLOBAL_ACTION_BACK)
                    backs += 1
                    Thread.sleep(400)
                }
                log("Q10 backs=$backs gone=${
                    !ProbeA11y.live?.windowPackages().orEmpty().contains(pkg)
                }")
            } else {
                // An item_root whose subtree carries the basename.
                val row = nodes.firstOrNull { n ->
                    n.viewIdResourceName?.endsWith("/item_root") == true &&
                        titlesUnder(n).contains("picked.txt")
                }
                if (row == null) {
                    log("Q5 NO ROW for picked.txt — rows are ${allRowTitles(nodes)}")
                } else {
                    val ok = row.performAction(AccessibilityNodeInfo.ACTION_CLICK)
                    log("Q5 performAction(ACTION_CLICK) on item_root -> $ok")
                }
            }
            // THE PRESS MUST HAVE LANDED. A click that arrives before
            // the picker is interactive is swallowed with no error.
            Thread.sleep(1500)
            log("Q5 picker still up 1500ms after the drive: " +
                "${ProbeA11y.live?.windowPackages().orEmpty().contains(pkg)}")
            return
        }
        log("Q5 the picker's package was not among the windows")
    }

    private fun textOf(nodes: List<AccessibilityNodeInfo>, id: String): String? =
        nodes.firstOrNull { it.viewIdResourceName?.endsWith("/$id") == true }
            ?.text?.toString()

    private fun allTexts(nodes: List<AccessibilityNodeInfo>, id: String): List<String> =
        nodes.filter { it.viewIdResourceName?.endsWith("/$id") == true }
            .mapNotNull { it.text?.toString() }

    /** Every row the picker is showing — what expect_file_dialog reads. */
    private fun allRowTitles(nodes: List<AccessibilityNodeInfo>): List<String> =
        nodes.filter { it.viewIdResourceName?.endsWith("/item_root") == true }
            .mapNotNull { titlesUnder(it).firstOrNull() }

    private fun titlesUnder(node: AccessibilityNodeInfo): List<String> {
        val out = mutableListOf<String>()
        fun walk(n: AccessibilityNodeInfo) {
            n.text?.toString()?.let { if (it.isNotEmpty()) out.add(it) }
            for (i in 0 until n.childCount) walk(n.getChild(i) ?: continue)
        }
        walk(node)
        return out
    }

    /** Q6/Q7: the properties the source design was chosen for. */
    private fun onPicked(uri: Uri) {
        // The display name PickedFile.name must carry.
        try {
            contentResolver.query(uri, null, null, null, null)?.use { c ->
                val i = c.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                if (c.moveToFirst() && i >= 0) log("Q6 display name=${c.getString(i)}")
            }
        } catch (e: Throwable) {
            log("Q6 name query threw ${e.javaClass.simpleName}: ${e.message}")
        }

        openOnce("first r (main thread)", uri, "r")

        // THE PROPERTY THE DESIGN TURNS ON: a second redemption.
        openOnce("second r (main thread)", uri, "r")

        // ...and off the thread that picked.
        Thread {
            openOnce("third r (worker thread)", uri, "r")
            openOnce("rw (worker thread)", uri, "rw")
            // LAST, because "w" truncates.
            openOnce("w (worker thread)", uri, "w")
            log("==== end")
        }.start()
    }

    private fun openOnce(label: String, uri: Uri, mode: String) {
        try {
            val pfd = contentResolver.openFileDescriptor(uri, mode)
            if (pfd == null) {
                log("Q7 $label mode=$mode -> null")
                return
            }
            val fd = pfd.detachFd()
            val adopted = ParcelFileDescriptor.adoptFd(fd)
            val st = Os.fstat(adopted.fileDescriptor)
            val reg = OsConstants.S_ISREG(st.st_mode)
            val seek = try {
                Os.lseek(adopted.fileDescriptor, 0, OsConstants.SEEK_CUR); true
            } catch (e: Throwable) {
                false
            }
            val body = if (mode == "r") {
                FileInputStream(adopted.fileDescriptor).readBytes().decodeToString()
            } else {
                "(not read)"
            }
            log("Q7 $label mode=$mode fd=$fd isreg=$reg lseek=$seek size=${st.st_size} body=$body")
            adopted.close()
        } catch (e: Throwable) {
            log("Q7 $label mode=$mode THREW ${e.javaClass.simpleName}: ${e.message}")
        }
    }
}
