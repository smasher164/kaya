package dev.kaya

import android.accessibilityservice.AccessibilityService
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo

/**
 * The harness's eyes and hands OUTSIDE this app.
 *
 * Every other platform's file picker is reachable from inside the
 * process: GTK's chooser is our own widget, the Shell's dialog is COM in
 * our address space, and NSOpenPanel is XPC but still our application to
 * the accessibility API. Android's is not. `ACTION_OPEN_DOCUMENT` hands
 * off to DocumentsUI, a separate APK, and the platform deliberately
 * stops one app from reading or touching another's UI.
 *
 * UI Automator can cross that line, but it is instrumentation — it runs
 * under AndroidJUnitRunner, and this lane launches the app with
 * `am start` and reads verdicts from logcat. An accessibility service
 * crosses the same line without restructuring the lane: it sees every
 * window on the device and can act on them, which is exactly what a
 * screen reader does.
 *
 * NOT IN THE LIBRARY'S MANIFEST, deliberately. The class lives here
 * because KayaCompose is what calls it, but only the validation apps
 * declare the service, so a user's app never carries an accessibility
 * service it did not ask for. The runner enables it over adb; nothing
 * about it starts on its own.
 */
class KayaHarnessAccessibility : AccessibilityService() {
    override fun onServiceConnected() {
        super.onServiceConnected()
        live = this
        android.util.Log.i("kaya", "KAYA_A11Y: harness accessibility service connected")
    }

    override fun onDestroy() {
        if (live === this) {
            live = null
        }
        super.onDestroy()
    }

    // The service is driven, never reactive: the scene says when to look.
    override fun onAccessibilityEvent(event: AccessibilityEvent?) = Unit

    override fun onInterrupt() = Unit

    companion object {
        /**
         * The connected service, or null when the runner has not enabled
         * it. Null is an answer the caller must handle rather than a
         * state to assert away — a leg running without the service
         * should say so, not crash.
         */
        @Volatile
        var live: KayaHarnessAccessibility? = null
            private set

        /** DocumentsUI's package, the window the picker actually lives in. */
        const val PICKER_PACKAGE = "com.android.documentsui"
    }

    /**
     * Every node under every window belonging to [pkg], depth-first.
     *
     * getWindows() and not getRootInActiveWindow(): the picker is a
     * different app's window, and "active" is a moving target while it
     * is coming up.
     */
    fun nodesIn(pkg: String): List<AccessibilityNodeInfo> {
        val out = mutableListOf<AccessibilityNodeInfo>()
        for (window in windows.orEmpty()) {
            val root = window.root ?: continue
            if (root.packageName?.toString() != pkg) continue
            collect(root, out)
        }
        return out
    }

    private fun collect(node: AccessibilityNodeInfo, out: MutableList<AccessibilityNodeInfo>) {
        if (out.size > 4000) return
        out.add(node)
        for (i in 0 until node.childCount) {
            collect(node.getChild(i) ?: continue, out)
        }
    }
}
