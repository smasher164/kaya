package dev.kaya

import android.accessibilityservice.AccessibilityService
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo

/**
 * The harness's eyes and hands OUTSIDE this app. Android's picker is
 * DocumentsUI, a separate APK, so nothing in-process can read it. UI
 * Automator could, but it is instrumentation and this lane launches
 * with `am start` and reads logcat; an accessibility service crosses
 * the same line without restructuring the lane.
 *
 * NOT IN THE LIBRARY'S MANIFEST: only the validation apps declare the
 * service, so a user's app never carries one it did not ask for. The
 * runner enables it over adb; nothing here starts on its own.
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

    // The service stays DRIVEN for reads — the scene says when to look —
    // but events are consumed as FRESHNESS SIGNALS since 2026-08-22:
    // the window list getWindows() answers is a snapshot that lags
    // reality in both directions, and the straggler-back family's ninth
    // sighting measured a press slipping through a 65ms gap no polled
    // read could see (the WATCH entry in docs/deferred.md). A
    // WINDOWS_CHANGE_REMOVED event names the window that ACTUALLY left,
    // straight from the system, and the epoch says the system processed
    // something since the last press. Neither makes the service
    // reactive: nothing here initiates.
    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        event ?: return
        if (event.eventType == AccessibilityEvent.TYPE_WINDOWS_CHANGED &&
            android.os.Build.VERSION.SDK_INT >= 28 &&
            (event.windowChanges and AccessibilityEvent.WINDOWS_CHANGE_REMOVED) != 0
        ) {
            noteRemoved(event.windowId)
        }
        windowEpoch += 1
    }

    override fun onInterrupt() = Unit

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
         * Is the app's OWN activity resumed? Written on the main thread
         * from the mounted activity's lifecycle (KayaCompose.mount),
         * read by [dismiss] from the harness thread.
         *
         * IN-PROCESS AND SO LAG-FREE, which is the whole reason it
         * exists: every other signal [dismiss] has comes out of the
         * accessibility window list, and that list is a snapshot that
         * lags reality in both directions (docs/deferred.md's WATCH
         * entry on the dialog family).
         */
        @Volatile
        internal var appResumed: Boolean = false

        /**
         * Bumped on EVERY accessibility event, on the service's main
         * looper (single writer). [dismiss] presses again only after
         * this has moved since its last press: a system that has
         * processed nothing since the previous back cannot have needed
         * another one yet.
         */
        @Volatile
        internal var windowEpoch: Long = 0

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
        }

        /**
         * DocumentsUI's package, BOTH SPELLINGS: AOSP images carry
         * `com.android.documentsui`, google_apis images (what
         * run-emulator.sh creates) carry the google one
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
         * panels, phone and tablet (docs/probes/open-panel-phone.md —
         * the two uiautomator dumps' identical id sets), it is in the SHARED
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
         * How many backs a dismissal may take, and how long each is
         * given to land. The ceiling is the directory trail's length
         * plus room, not a guess at a race (docs/traps.md).
         */
        private const val MAX_BACKS = 8
        private const val BACK_SETTLE_MS = 400L

        /** How long the picker is given to leave once it has been answered. */
        private const val GONE_TRIES = 15
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
     *
     * PRIVATE, because as a failure string it lies: a window whose root
     * read returns null contributes nothing here and is invisible to
     * every reader built on this one. [windowCensus] is what a failure
     * prints.
     */
    private fun windowPackages(): List<String> =
        windows.orEmpty().mapNotNull { it.root?.packageName?.toString() }

    /**
     * WHAT THE SERVICE CAN SEE AND WHAT IT COULD READ: every window,
     * with its package when the root answered and `root-unreadable`
     * plus the window's title when it did not.
     *
     * An unreadable root is not the same failure as a missing window
     * and wants the opposite fix, and no reader above can tell them
     * apart — [pickerPackage], [pickerWindow] and [nodesIn] all drop a
     * null-rooted window silently, which is how a save leg printed
     * "DocumentsUI is showing []" about a list it never read
     * (docs/deferred.md's WATCH entry, 2026-08-21 matrix6).
     *
     * THE A11Y ID IS PRINTED because system_server names windows by it
     * in its own complaint — `AccessibilityManagerService: wait for
     * adding window timeout: <id>` — so the two logs can be joined.
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

    /**
     * What the live SAVE panel is REALLY showing: the directory it is
     * in, and the name in its name field. Null when no save panel is up.
     *
     * THE NAME HALF IS THE WHOLE POINT: a backend that ignored the name
     * it was told saves under the SUGGESTED name, and every assertion
     * downstream passes on the wrong file.
     *
     * THE ROWS ARE NOT READ HERE, for the mac arm's reason rather than
     * this platform's: a save dialog need not publish a file browser at
     * all. DocumentsUI happens to list files in CREATE mode (measured),
     * and this reader still does not look.
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
     * (docs/probes/save-probe-android.md, log-B2). False when no save
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
     * Press the live save panel's own SAVE button, so DocumentsUI's own
     * create-and-answer runs and nothing is synthesized. False when no
     * save panel is up or the button refused.
     */
    fun confirmSave(): Boolean {
        val nodes = dialogNodes(save = true) ?: return false
        val button = nodes.firstOrNull {
            it.viewIdResourceName?.endsWith(SAVE_BUTTON_ID) == true
        } ?: return false
        return button.performAction(AccessibilityNodeInfo.ACTION_CLICK)
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
        return row.performAction(AccessibilityNodeInfo.ACTION_CLICK)
    }

    /**
     * Dismiss the picker with the system back gesture — there is no
     * Cancel button. ONE BACK IS NOT ENOUGH: the first backs walk UP
     * the directory tree, and only the one taken at the root dismisses
     * (docs/traps.md). Bounded, with the picker being GONE as the
     * proof, never the action's return value.
     *
     * KIND-AGNOSTIC ON PURPOSE, unlike [choose] and [saveState]: back is
     * the cancel affordance of BOTH dialogs (measured at three backs and
     * a null result Intent for the save panel too), and "gone" is the
     * same proof either way.
     *
     * MUST NOT RUN ON THE MAIN THREAD — getWindows() is refreshed on
     * this service's main looper, which is the app's (docs/traps.md).
     * Asserted below rather than commented.
     *
     * Null when the picker went; a measured sentence when it did not,
     * because "would not dismiss" has two causes the caller cannot
     * otherwise tell apart — a picker that ate its backs, and a gate
     * that never let one through.
     */
    fun dismiss(): String? {
        check(android.os.Looper.myLooper() != android.os.Looper.getMainLooper()) {
            "kaya: the picker drive must not run on the main thread — getWindows() " +
                "is refreshed there and would never see the picker leave"
        }
        // BACK IS PRESSED ONLY WHILE THE PICKER HOLDS INPUT FOCUS AND
        // THE APP'S OWN ACTIVITY IS NOT RESUMED. Both halves guard one
        // failure: the window list LAGS a dismissal, a stale entry buys
        // one extra press, and that STRAGGLER BACK lands on the app and
        // finish()es the scene's activity — after which a dialog's
        // result has no live destination and vanishes with no line
        // anywhere. Focus is read from the lagging snapshot and cannot
        // see the app take over; [appResumed] is in-process and lags
        // nothing, and in both 2026-08-21 traces the straggler was
        // injected ~130ms AFTER the app's own onResume. The WATCH entry
        // in docs/deferred.md holds the timestamps.
        //
        // THE RESUMED READ COMES LAST, after the window read that can
        // itself cost hundreds of milliseconds under load: hoisting it
        // hands the press a value measured before the wait.
        var backs = 0
        var waits = 0
        var absent = 0
        var refused = 0
        var withheld = 0
        // The epoch at the LAST press: pressing again before it moves
        // would be racing a system that has processed nothing since —
        // and the ninth sighting's straggler slipped through exactly
        // such a race (the WATCH entry; ruled 2026-08-22, remedy A).
        var epochAtPress = -1L
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
                if (appResumed) {
                    refused += 1
                } else if (windowEpoch == epochAtPress) {
                    // The handshake: nothing has happened since the last
                    // press — the previous back is still in flight.
                    withheld += 1
                } else {
                    epochAtPress = windowEpoch
                    performGlobalAction(GLOBAL_ACTION_BACK)
                    backs += 1
                }
            }
            Thread.sleep(BACK_SETTLE_MS)
        }
        if (pickerPackage() == null) return null
        return "the picker would not dismiss after $backs backs in $waits looks " +
            "($refused refused while the app's own activity was resumed, " +
            "$withheld withheld waiting for the previous press to be processed); " +
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
        // out mid-relayout under load. One absent read declared a picker
        // gone whose activity was top-resumed in the at-fail dumpsys, the
        // choose reported success, the result never came, and the next
        // open died on the one-per-process wall (2026-08-21, the tables
        // ledger's ghost family).
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
