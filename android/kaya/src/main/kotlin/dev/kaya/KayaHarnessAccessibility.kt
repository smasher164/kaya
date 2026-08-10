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

        /**
         * DocumentsUI's package — BOTH SPELLINGS, because there are two
         * builds of it and the lane meets one of them by accident of
         * which system image the AVD was created from. AOSP images carry
         * `com.android.documentsui`; google_apis images, which is what
         * run-emulator.sh creates, carry
         * `com.google.android.documentsui`. Measured: the constant used
         * to be the AOSP one alone, and it named a package that is not
         * on the device the lane runs.
         */
        val PICKER_PACKAGES = listOf(
            "com.google.android.documentsui",
            "com.android.documentsui",
        )

        /** The row's container in the picker's list; its subtree holds the name. */
        private const val ROW_ID = "/item_root"

        /** The row's basename, and the directory's, in DocumentsUI's tree. */
        private const val ROW_TITLE_ID = "/title"
        private const val BREADCRUMB_ID = "/breadcrumb_text"

        /**
         * THE SAVE PANEL'S TWO NODES, and the one that tells the two
         * dialogs apart.
         *
         * `ACTION_CREATE_DOCUMENT` is DocumentsUI too — the same
         * package, the same breadcrumb, the same file list — so
         * "DocumentsUI is up" does NOT mean "the open picker is up",
         * and the readers below must not see each other's panel.
         * Getting that wrong does not produce a wrong answer, it
         * produces a HANG: a picker read that could see a save panel
         * polls five seconds for a list that is never coming, and
         * `file_save`'s postcondition reads a null state as "the press
         * landed".
         *
         * THE DISCRIMINATOR IS THE NAME FIELD, because it is the only
         * thing the create mode actually adds. `container_save` looks
         * like the obvious answer and is NOT one: MEASURED on both
         * panels, phone and tablet (scratchpad/open-panel-phone.xml vs
         * save-panel-phone.xml, identical id sets), it is in the SHARED
         * layout and is published EMPTY by the browse mode — a
         * discriminator that says "save" about every picker. Keying on
         * it turned every `expect_file_dialog` on this platform red.
         *
         * The name field is also what the two save verbs work on, so
         * this asks one question rather than two that could disagree: a
         * save panel with nothing to type into is not one this harness
         * could drive anyway.
         *
         * THE NAME FIELD AND EVERY ROW SHARE ONE ID — both are
         * `android:id/title` (measured: `text="decoy"` and
         * `text="draft"` carry the id the name box does). So the id
         * alone cannot name the field, and a reader keyed on it reads
         * the FIRST ROW's basename as the name the user typed. Only one
         * of them is EDITABLE, which is the property that makes it the
         * name field rather than a naming coincidence.
         *
         * SUFFIXES, like ROW_ID and BREADCRUMB_ID above, because
         * DocumentsUI ships under two package names and its own ids
         * carry whichever one this device has.
         */
        private const val SAVE_NAME_ID = "/title"
        private const val SAVE_BUTTON_ID = "/button1"

        /**
         * How many backs a dismissal may take, and how long each one is
         * given to land. Three sufficed from the depth the scene aims
         * at; the ceiling is the trail's length plus room, not a guess
         * at a race.
         */
        private const val MAX_BACKS = 8
        private const val BACK_SETTLE_MS = 400L

        /** How long the picker is given to leave once it has been answered. */
        private const val GONE_TRIES = 15
    }

    /** Which picker build is on screen, or null when none of them is. */
    fun pickerPackage(): String? =
        PICKER_PACKAGES.firstOrNull { pkg -> windowPackages().contains(pkg) }

    /** Every package that currently owns a window — what a miss reports. */
    fun windowPackages(): List<String> =
        windows.orEmpty().mapNotNull { it.root?.packageName?.toString() }

    /**
     * What the picker is REALLY showing: the directory it is in, and the
     * names its list holds. Null when no picker is up.
     *
     * The directory comes off the LAST breadcrumb, which is the deepest
     * one — DocumentsUI shows the whole trail (volume / Documents /
     * <dir>) and only the tail names where the list actually is.
     */
    fun pickerState(): Pair<String, List<String>>? {
        val nodes = dialogNodes(save = false) ?: return null
        return Pair(breadcrumb(nodes), rows(nodes).map { it.first })
    }

    /**
     * What the live SAVE panel is REALLY showing: the directory it is
     * in, and the name in its name field. Null when no save panel is up.
     *
     * THE NAME HALF IS THE WHOLE POINT. A backend that ignored the name
     * it was told saves under the SUGGESTED name, and every assertion
     * downstream — the bytes, the reopen, the round trip — passes on the
     * wrong file. Nothing else in the scene can see that.
     *
     * THE ROWS ARE NOT READ HERE, and the reason is the mac arm's rather
     * than this platform's: a save dialog need not publish a file
     * browser at all, so a reader that required rows would be writing a
     * cross-platform verb against one platform's chrome. DocumentsUI
     * happens to list files in CREATE mode (measured), and this reader
     * still does not look.
     */
    fun saveState(): Pair<String, String>? {
        val nodes = dialogNodes(save = true) ?: return null
        val name = nameField(nodes)?.text?.toString() ?: return null
        return Pair(breadcrumb(nodes), name)
    }

    /**
     * Type a name into the live save panel's name field — the harness
     * doing what a user's keyboard would, at set_text's tier.
     *
     * ACTION_SET_TEXT and not a synthesized key stream: measured to
     * return true and to read back as the typed value, and the URI the
     * panel then answered with carried that name
     * (scratchpad/save-probe-android.md, log-B2). False when no save
     * panel is up or the field refused, which the caller reports —
     * silence here would let the leg save under the SUGGESTED name with
     * every byte assertion still passing.
     */
    fun setSaveName(name: String): Boolean {
        val field = dialogNodes(save = true)?.let { nameField(it) } ?: return false
        val args = android.os.Bundle()
        args.putCharSequence(
            AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE,
            name,
        )
        return field.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, args)
    }

    /**
     * Press the live save panel's own SAVE button — the same control a
     * user works, so DocumentsUI's own create-and-answer runs and
     * nothing is synthesized. False when no save panel is up or the
     * button refused.
     */
    fun confirmSave(): Boolean {
        val nodes = dialogNodes(save = true) ?: return false
        val button = nodes.firstOrNull {
            it.viewIdResourceName?.endsWith(SAVE_BUTTON_ID) == true
        } ?: return false
        return button.performAction(AccessibilityNodeInfo.ACTION_CLICK)
    }

    /**
     * WHAT DOCUMENTSUI IS SHOWING, for a failure to say out loud: the
     * distinct view ids in its tree, shortest form, sorted.
     *
     * A read that finds no save panel is otherwise indistinguishable
     * from a save panel that never presented, and the two want opposite
     * fixes. This arm cost a build cycle to exactly that: the reader
     * was keyed on the wrong package's `container_save` and reported
     * "no save dialog live" about a panel that was up, on screen and
     * correct.
     */
    fun dialogShape(): List<String> {
        val pkg = pickerPackage() ?: return emptyList()
        return nodesIn(pkg)
            .mapNotNull { node ->
                node.viewIdResourceName?.substringAfterLast('/')?.let {
                    // EDITABLE IS MARKED because it is the whole
                    // discrimination: a shape with no editable `title`
                    // is a browse picker, whatever else is in it.
                    if (node.isEditable) "$it(editable)" else it
                }
            }
            .distinct()
            .sorted()
    }

    /**
     * DocumentsUI's nodes when it is showing the dialog KIND asked for,
     * null otherwise — the one place the discrimination happens, so the
     * two readers cannot answer differently about the same screen.
     */
    private fun dialogNodes(save: Boolean): List<AccessibilityNodeInfo>? {
        val pkg = pickerPackage() ?: return null
        val nodes = nodesIn(pkg)
        return if ((nameField(nodes) != null) == save) nodes else null
    }

    /**
     * The save panel's name box: the one EDITABLE `title` in the tree.
     * Every row's basename carries the same id (measured), and only
     * this one takes text — so the editable flag is what names it, and
     * it is the same property that makes it the field a user types the
     * file's name into.
     */
    private fun nameField(nodes: List<AccessibilityNodeInfo>): AccessibilityNodeInfo? =
        nodes.firstOrNull {
            it.viewIdResourceName?.endsWith(SAVE_NAME_ID) == true && it.isEditable
        }

    /**
     * The directory this tree is in, off the LAST breadcrumb: DocumentsUI
     * shows the whole trail (volume / Documents / <dir>) and only the
     * tail names where the list actually is. Both dialogs publish it.
     */
    private fun breadcrumb(nodes: List<AccessibilityNodeInfo>): String =
        nodes.filter { it.viewIdResourceName?.endsWith(BREADCRUMB_ID) == true }
            .mapNotNull { it.text?.toString() }
            .lastOrNull()
            ?: ""

    /**
     * Choose the named row, for real: the platform's own click on the
     * platform's own list item. THE CLICK IS THE ANSWER here — this
     * picker has no Open button to press afterwards, so a click that
     * lands is a completed pick (measured).
     *
     * False when no picker is up or nothing carries that name; the
     * caller reports what the list DID hold, because pressing on
     * anyway is how a scene silently picks the wrong file.
     */
    fun choose(name: String): Boolean {
        // THE OPEN PICKER'S ROWS ONLY. The save panel lists files too
        // (measured), and clicking one there NAVIGATES OR RENAMES rather
        // than answering the request — a click that lands, returns true,
        // and leaves the dialog up.
        val row = dialogNodes(save = false)
            ?.let { rows(it) }
            ?.firstOrNull { it.first == name }
            ?.second
            ?: return false
        return row.performAction(AccessibilityNodeInfo.ACTION_CLICK)
    }

    /**
     * Dismiss the picker, which is the system back gesture — there is no
     * Cancel button in it at all.
     *
     * ONE BACK IS NOT ENOUGH and that is not a race: the first backs
     * walk UP the directory tree the picker was aimed into, and only the
     * one taken at the root dismisses. Measured at three from the depth
     * the scene aims at. So this is bounded and its proof is the picker
     * being GONE, never the action's return value.
     *
     * KIND-AGNOSTIC ON PURPOSE, unlike [choose] and [saveState]: back is
     * the cancel affordance of BOTH dialogs (measured at three backs and
     * a null result Intent for the save panel too), and "gone" is the
     * same proof either way. A second copy of this keyed on the kind
     * would be two answers to one question.
     *
     * MUST NOT RUN ON THE MAIN THREAD. getWindows() is refreshed on this
     * service's main looper, which is the app's, so a caller that blocks
     * main watches a frozen window list and concludes the picker is
     * still up forever. Measured, and asserted below rather than
     * commented, because the symptom is a timeout nobody would trace
     * here.
     */
    fun dismiss(): Boolean {
        check(android.os.Looper.myLooper() != android.os.Looper.getMainLooper()) {
            "kaya: the picker drive must not run on the main thread — getWindows() " +
                "is refreshed there and would never see the picker leave"
        }
        var backs = 0
        while (backs < MAX_BACKS) {
            if (pickerPackage() == null) return true
            performGlobalAction(GLOBAL_ACTION_BACK)
            backs += 1
            Thread.sleep(BACK_SETTLE_MS)
        }
        return pickerPackage() == null
    }

    /**
     * The picker is gone, waited for. The press-landed proof on every
     * other backend is the dialog's disappearance and it is here too: a
     * click that arrives before the list is interactive is swallowed
     * with no error anywhere.
     */
    fun waitForPickerGone(): Boolean {
        check(android.os.Looper.myLooper() != android.os.Looper.getMainLooper()) {
            "kaya: waiting for the picker must not run on the main thread"
        }
        for (i in 0 until GONE_TRIES) {
            if (pickerPackage() == null) return true
            Thread.sleep(BACK_SETTLE_MS)
        }
        return false
    }

    /** (name, row) for every row the picker lists, in its own order. */
    private fun rows(
        nodes: List<AccessibilityNodeInfo>,
    ): List<Pair<String, AccessibilityNodeInfo>> =
        nodes.filter { it.viewIdResourceName?.endsWith(ROW_ID) == true }
            .mapNotNull { row -> titleUnder(row)?.let { Pair(it, row) } }

    private fun titleUnder(node: AccessibilityNodeInfo): String? {
        if (node.viewIdResourceName?.endsWith(ROW_TITLE_ID) == true) {
            val t = node.text?.toString()
            if (!t.isNullOrEmpty()) return t
        }
        for (i in 0 until node.childCount) {
            titleUnder(node.getChild(i) ?: continue)?.let { return it }
        }
        return null
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
