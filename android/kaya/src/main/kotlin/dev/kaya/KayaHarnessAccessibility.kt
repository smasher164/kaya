package dev.kaya

import android.accessibilityservice.AccessibilityService
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo

/**
 * The harness's eyes and hands OUTSIDE this app: Android's picker is
 * DocumentsUI, a separate APK. NOT IN THE LIBRARY'S MANIFEST — only the
 * validation apps declare the service, the runner enables it over adb,
 * and nothing here starts on its own.
 */
class KayaHarnessAccessibility : AccessibilityService() {
    override fun onServiceConnected() {
        super.onServiceConnected()
        live = this
        android.util.Log.i("kaya", "KAYA_A11Y: harness accessibility service connected")
        watchWindowHealth()
    }

    override fun onDestroy() {
        if (live === this) {
            live = null
        }
        super.onDestroy()
    }

    // The service stays DRIVEN for reads — the scene says when to look.
    // A WINDOWS_CHANGE_REMOVED event names a window that ACTUALLY left,
    // straight from the system; nothing here initiates from an event.
    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        event ?: return
        if (event.eventType == AccessibilityEvent.TYPE_WINDOWS_CHANGED &&
            android.os.Build.VERSION.SDK_INT >= 28 &&
            (event.windowChanges and AccessibilityEvent.WINDOWS_CHANGE_REMOVED) != 0
        ) {
            noteRemoved(event.windowId)
        }
    }

    override fun onInterrupt() = Unit

    private fun watchWindowHealth() {
        Thread {
            repeat(50) {
                if (live !== this) return@Thread
                val snapshot = windows.orEmpty()
                val readable = snapshot.count { it.root?.packageName != null }
                if (readable > 0) {
                    android.util.Log.i(
                        "kaya",
                        "KAYA_A11Y_WINDOWS: READY total=${snapshot.size} readable=$readable",
                    )
                    return@Thread
                }
                Thread.sleep(100)
            }
            if (live === this) {
                android.util.Log.w("kaya", "KAYA_A11Y_WINDOWS: BLIND ${windowCensus()}")
            }
        }.apply {
            name = "kaya-a11y-window-health"
            isDaemon = true
            start()
        }
    }

    companion object {
        /**
         * The connected service, or null when the runner has not enabled
         * it. Null is an answer the caller handles — a leg running
         * without the service says so rather than crashing.
         */
        @Volatile
        var live: KayaHarnessAccessibility? = null
            private set

        /**
         * Is the app's OWN activity resumed? Written from the mounted
         * activity's lifecycle, read by [dismiss] on the harness thread.
         * IN-PROCESS AND SO LAG-FREE, unlike every other signal
         * [dismiss] has: the accessibility window list lags reality in
         * both directions (docs/deferred.md's dialog-family WATCH).
         */
        @Volatile
        internal var appResumed: Boolean = false

        /**
         * Window ids the system announced REMOVED (capped; cleared at
         * each dialog present by [clearRemovals]). Fresh where the
         * window list is stale: the list held a dismissed picker long
         * enough to buy a straggler back twice, and this is the signal
         * that cannot.
         */
        private val removedWindows = object : LinkedHashSet<Int>() {}
        private const val REMOVED_CAP = 64

        internal fun noteRemoved(windowId: Int) {
            synchronized(removedWindows) {
                removedWindows.add(windowId)
                while (removedWindows.size > REMOVED_CAP) {
                    removedWindows.remove(removedWindows.first())
                }
            }
        }

        internal fun wasRemoved(windowId: Int): Boolean =
            synchronized(removedWindows) { removedWindows.contains(windowId) }

        /** Called at each dialog present, so a reused id cannot lie. */
        fun clearRemovals() {
            synchronized(removedWindows) { removedWindows.clear() }
            pickerBackGate.clear()
        }

        /**
         * DocumentsUI's package, BOTH SPELLINGS: AOSP images carry
         * `com.android.documentsui`, google_apis images (what
         * run-emulator.py creates) carry the google one
         * (docs/traps.md).
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
         * THE SAVE PANEL'S TWO NODES. Both dialogs are DocumentsUI, so
         * the discriminator is the NAME FIELD (`container_save` is in the
         * SHARED layout and published empty by browse mode, measured on
         * phone and tablet). The name field and EVERY ROW share
         * `android:id/title`, so only EDITABLE tells them apart.
         */
        private const val SAVE_NAME_ID = "/title"
        private const val SAVE_BUTTON_ID = "/button1"

        /**
         * How many backs a dismissal may take, and how long each is
         * given to land. The ceiling is the directory trail's length
         * plus room, not a guess at a race (docs/traps.md).
         */
        private const val MAX_BACKS = 8
        private const val BACK_SETTLE_MS = 400L

        /** How long the picker is given to leave once it has been answered. */
        private const val GONE_TRIES = 15

        private data class PickerBackState(
            val windowId: Int,
            val breadcrumbs: List<String>,
        )

        /**
         * One BACK per exact picker path, after two matching reads.
         * docs/traps.md, "A changed event is not a changed picker path."
         */
        private class PickerBackGate {
            private val spent = mutableSetOf<PickerBackState>()
            private var candidate: PickerBackState? = null
            private var matchingReads = 0
            private var lastPressed: PickerBackState? = null
            private var closingAction = false

            @Synchronized
            fun clear() {
                spent.clear()
                candidate = null
                matchingReads = 0
                lastPressed = null
                closingAction = false
            }

            @Synchronized
            fun observe(state: PickerBackState?): Boolean {
                if (state == null) {
                    candidate = null
                    matchingReads = 0
                    return false
                }
                if (state != candidate) {
                    candidate = state
                    matchingReads = 1
                    return false
                }
                matchingReads += 1
                if (matchingReads < 2 || closingAction || spent.contains(state)) return false
                val previous = lastPressed
                if (previous != null &&
                    (state.windowId != previous.windowId ||
                        state.breadcrumbs.size >= previous.breadcrumbs.size ||
                        previous.breadcrumbs.take(state.breadcrumbs.size) != state.breadcrumbs)
                ) {
                    return false
                }
                spent.add(state)
                lastPressed = state
                return true
            }

            @Synchronized
            fun noteClosingAction(state: PickerBackState?) {
                if (state != null) spent.add(state)
                closingAction = true
            }
        }

        private val pickerBackGate = PickerBackGate()

        private fun pickerBackGateSelftest() {
            val gate = PickerBackGate()
            val folder = PickerBackState(17, listOf("device", "Documents", "folder"))
            val documents = PickerBackState(17, listOf("device", "Documents"))
            val root = PickerBackState(17, listOf("device"))
            val sequence = listOf(folder, folder, folder, documents, documents, root, root, root)
            check(sequence.count(gate::observe) == 3) {
                "kaya: picker BACK gate did not admit exactly one press per shortening path"
            }
            check(!gate.observe(null)) { "kaya: an unreadable picker path admitted a BACK" }
            val oscillating = PickerBackGate()
            check(listOf(folder, documents, folder, documents).none(oscillating::observe)) {
                "kaya: an unstable picker path admitted a BACK"
            }
            val closing = PickerBackGate()
            closing.noteClosingAction(folder)
            check(listOf(documents, documents, root, root).none(closing::observe)) {
                "kaya: cleanup admitted a BACK while a picker action was closing"
            }
        }
    }

    /** Which picker build is on screen, or null when none of them is. */
    fun pickerPackage(): String? =
        PICKER_PACKAGES.firstOrNull { pkg -> windowPackages().contains(pkg) }

    /**
     * The picker's WINDOW, or null — [dismiss] needs the window and not
     * just the package, because whether it still holds INPUT FOCUS is
     * what separates a live dialog from a stale entry the a11y window
     * list has not dropped yet.
     */
    private fun pickerWindow(): android.view.accessibility.AccessibilityWindowInfo? =
        windows.orEmpty().firstOrNull {
            PICKER_PACKAGES.contains(it.root?.packageName?.toString())
        }

    /**
     * Every package that currently owns a window WHOSE ROOT ANSWERED.
     * PRIVATE, because as a failure string it lies — a null-rooted
     * window is invisible here. [windowCensus] is what a failure prints.
     */
    private fun windowPackages(): List<String> =
        windows.orEmpty().mapNotNull { it.root?.packageName?.toString() }

    /**
     * WHAT THE SERVICE CAN SEE AND WHAT IT COULD READ: every window,
     * with `root-unreadable` where the root did not answer — a failure
     * the readers above drop silently (docs/deferred.md's WATCH). The
     * a11y id is printed because system_server names windows by it in
     * "wait for adding window timeout: <id>".
     */
    fun windowCensus(): String {
        val entries = ArrayList<String>()
        var unreadable = 0
        for (window in windows.orEmpty()) {
            val pkg = window.root?.packageName?.toString()
            if (pkg == null) {
                unreadable += 1
                entries.add("id=${window.id} root-unreadable title=\"${window.title ?: ""}\"")
            } else {
                entries.add("id=${window.id} $pkg")
            }
        }
        return "${entries.size} windows, $unreadable with an unreadable root: $entries"
    }

    /**
     * What the picker is REALLY showing: the directory it is in, and the
     * names its list holds. Null when no picker is up.
     */
    fun pickerState(): Pair<String, List<String>>? {
        val nodes = dialogNodes(save = false) ?: return null
        return Pair(breadcrumb(nodes), rows(nodes).map { it.first })
    }

    private fun pickerBackState(
        window: android.view.accessibility.AccessibilityWindowInfo,
    ): PickerBackState? {
        val root = window.root ?: return null
        val nodes = mutableListOf<AccessibilityNodeInfo>()
        collect(root, nodes)
        val trail = nodes
            .filter { it.viewIdResourceName?.endsWith(BREADCRUMB_ID) == true }
            .mapNotNull { it.text?.toString()?.takeIf { text -> text.isNotEmpty() } }
        return if (trail.isEmpty()) null else PickerBackState(window.id, trail)
    }

    /**
     * What the live SAVE panel is REALLY showing: its directory and the
     * name in its name field. THE NAME HALF IS THE WHOLE POINT — a
     * backend that ignored the name saves under the SUGGESTED one, and
     * every later assertion passes on the wrong file. The rows are
     * deliberately not read.
     */
    fun saveState(): Pair<String, String>? {
        val nodes = dialogNodes(save = true) ?: return null
        val name = nameField(nodes)?.text?.toString() ?: return null
        return Pair(breadcrumb(nodes), name)
    }

    /**
     * Type a name into the live save panel's name field, through
     * ACTION_SET_TEXT rather than a synthesized key stream
     * (docs/probes/save-probe-android.md, log-B2). False when no panel
     * is up or the field refused, which the CALLER must report — silence
     * saves under the SUGGESTED name with every assertion still passing.
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
     * Press the live save panel's own SAVE button, so DocumentsUI's own
     * create-and-answer runs and nothing is synthesized. False when no
     * save panel is up or the button refused.
     */
    fun confirmSave(): Boolean {
        val nodes = dialogNodes(save = true) ?: return false
        val button = nodes.firstOrNull {
            it.viewIdResourceName?.endsWith(SAVE_BUTTON_ID) == true
        } ?: return false
        val closingState = pickerWindow()?.let(::pickerBackState)
        val accepted = button.performAction(AccessibilityNodeInfo.ACTION_CLICK)
        if (accepted) pickerBackGate.noteClosingAction(closingState)
        return accepted
    }

    /**
     * WHAT DOCUMENTSUI IS SHOWING, for a failure to say out loud, AND
     * WHETHER ITS TREE WAS READ AT ALL. [dialogShape] answers about a
     * tree it found; with no readable picker window there is no tree,
     * and its empty list read as "DocumentsUI is showing nothing" about
     * something nobody measured (docs/deferred.md's WATCH entry).
     */
    fun dialogReport(): String {
        val pkg = pickerPackage()
            ?: return "no DocumentsUI window with a readable root; ${windowCensus()}"
        return "$pkg publishes ${dialogShape()}"
    }

    /**
     * The distinct view ids in DocumentsUI's tree, shortest form,
     * sorted. Private: a caller that has not asked whether the tree
     * could be read at all prints [dialogReport]'s question as an
     * answer.
     */
    private fun dialogShape(): List<String> {
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
     * The save panel's name box: the one EDITABLE `title` in the tree
     * — see [SAVE_NAME_ID] for why the id alone cannot name it.
     */
    private fun nameField(nodes: List<AccessibilityNodeInfo>): AccessibilityNodeInfo? =
        nodes.firstOrNull {
            it.viewIdResourceName?.endsWith(SAVE_NAME_ID) == true && it.isEditable
        }

    /**
     * The directory this tree is in, off the LAST breadcrumb:
     * DocumentsUI shows the whole trail (volume / Documents / <dir>)
     * and only the tail names where the list is. Both dialogs publish
     * it.
     */
    private fun breadcrumb(nodes: List<AccessibilityNodeInfo>): String =
        nodes.filter { it.viewIdResourceName?.endsWith(BREADCRUMB_ID) == true }
            .mapNotNull { it.text?.toString() }
            .lastOrNull()
            ?: ""

    /**
     * Choose the named row. THE CLICK IS THE ANSWER — this picker has
     * no Open button (docs/traps.md). False when no picker is up or
     * nothing carries that name; the caller reports what the list DID
     * hold rather than pressing on.
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
        val closingState = pickerWindow()?.let(::pickerBackState)
        val accepted = row.performAction(AccessibilityNodeInfo.ACTION_CLICK)
        if (accepted) pickerBackGate.noteClosingAction(closingState)
        return accepted
    }

    /**
     * Dismiss the picker with back — there is no Cancel button, ONE BACK
     * IS NOT ENOUGH, and being GONE is the proof rather than the
     * action's return value (docs/traps.md). MUST NOT RUN ON THE MAIN
     * THREAD, where getWindows() is refreshed. Null when the picker went,
     * else a sentence telling an eaten back from a withheld one.
     */
    fun dismiss(): String? {
        check(android.os.Looper.myLooper() != android.os.Looper.getMainLooper()) {
            "kaya: the picker drive must not run on the main thread — getWindows() " +
                "is refreshed there and would never see the picker leave"
        }
        pickerBackGateSelftest()
        // Three walls admit BACK: picker focus, the app still paused,
        // and one stable strictly-shorter breadcrumb path. See
        // docs/traps.md, "A changed event is not a changed picker path."
        // The resumed read stays after the window/path reads, which can
        // themselves cost hundreds of milliseconds under load.
        var backs = 0
        var waits = 0
        var absent = 0
        var refused = 0
        var withheld = 0
        var unreadable = 0
        while (waits < GONE_TRIES * 2) {
            waits += 1
            val picker = pickerWindow()
            if (picker != null && wasRemoved(picker.id)) {
                // The system itself announced THIS window removed; the
                // list entry is the stale copy the stragglers rode.
                android.util.Log.i(
                    "kaya",
                    "KAYA_DISMISS_REMOVED: window ${picker.id} left by the system's " +
                        "own account; the list still showed it",
                )
                return null
            }
            if (picker == null) {
                // Same debounce as waitForPickerGone: one absent read
                // can be a live window's transient drop-out.
                absent += 1
                if (absent >= 2) return null
                Thread.sleep(BACK_SETTLE_MS)
                continue
            }
            absent = 0
            if (picker.isFocused && backs < MAX_BACKS) {
                val backState = pickerBackState(picker)
                if (appResumed) {
                    refused += 1
                } else if (backState == null) {
                    unreadable += 1
                } else if (!pickerBackGate.observe(backState)) {
                    withheld += 1
                } else {
                    performGlobalAction(GLOBAL_ACTION_BACK)
                    backs += 1
                }
            }
            Thread.sleep(BACK_SETTLE_MS)
        }
        if (pickerPackage() == null) return null
        return "the picker would not dismiss after $backs backs in $waits looks " +
            "($refused refused while the app's own activity was resumed, " +
            "$withheld withheld until a new stable picker path, " +
            "$unreadable with no readable picker path); " +
            windowCensus()
    }

    /**
     * The picker is gone, waited for — the press-landed proof on every
     * backend. A click that arrives before the list is interactive is
     * swallowed with no error anywhere.
     */
    fun waitForPickerGone(): Boolean {
        check(android.os.Looper.myLooper() != android.os.Looper.getMainLooper()) {
            "kaya: waiting for the picker must not run on the main thread"
        }
        // TWO CONSECUTIVE ABSENCES, not one: the window list is a lagging
        // snapshot in BOTH directions — a dismissed picker lingers in it
        // (the straggler-back class) and a LIVE one can transiently drop
        // out mid-relayout under load, which then declares a picker gone
        // whose activity was top-resumed (2026-08-21, the tables ledger's
        // ghost family).
        var absent = 0
        var seenId: Int? = null
        for (i in 0 until GONE_TRIES) {
            val picker = pickerWindow()
            if (picker == null) {
                absent += 1
                if (absent >= 2) return true
            } else {
                seenId = picker.id
                // The system's own removal announcement outranks the
                // stale list entry (the ninth sighting's remedy).
                if (wasRemoved(picker.id)) return true
                absent = 0
            }
            Thread.sleep(BACK_SETTLE_MS)
        }
        return seenId?.let { wasRemoved(it) } ?: false
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
