# The ghost result: why `onActivityResult` is never called after a DocumentsUI SAVE

Research log, 2026-08-20. Primary sources are AOSP at `refs/heads/main` unless a
release tag is named. Every file quoted was fetched from
`android.googlesource.com/platform/{frameworks/base, packages/apps/DocumentsUI,
system/logging}`; local copies are under this scratchpad in `aosp/`, `fb/`.
Line numbers are from those fetched files.

**The signature being explained**

- `ACTION_CREATE_DOCUMENT` launched via androidx `ActivityResultRegistry.register(key, StartActivityForResult)` + `launch()`.
- DocumentsUI save dialog appears, is renamed via accessibility, SAVE pressed by an accessibility service.
- Dialog closes normally. `Activity.onActivityResult` is NEVER invoked — not `RESULT_OK`, not `RESULT_CANCELED`.
- Caller activity stays RESUMED and responsive.
- Earlier `OPEN_DOCUMENT` and a cancelled `CREATE_DOCUMENT`, same process, same minute, delivered normally.
- `am_freeze` for DocumentsUI ~10.4 s after the press. No `am_kill` / `am_proc_died`.
- Emulator, API 35/36 Google APIs image, heavy host CPU contention, ~1-in-2 loaded runs, never solo.

---

## HEADLINE

**There is no filed AOSP bug that matches this signature** (Q1a lists the searches
and the four well-known causes that do *not* fit). But there is a concrete,
completely unlogged drop path in current AOSP `frameworks/base` that produces the
signature exactly, and whose race window is opened by a `Handler.post` onto a
contended system_server handler — so it widens under CPU starvation and closes
when the machine is idle. It is a framework race. DocumentsUI's only contribution
is *timing*. The freezer is not involved, and the `am_freeze` line is positive
evidence *against* freezer involvement (Q3).

The chain, all in `services/core/java/com/android/server/wm/`:

1. `ActivityRecord.finishActivityResults()` sends the result **asynchronously**
   (`mAtmService.mH.post(...)`) whenever the caller is already `RESUMED` at the
   moment the picker finishes. **New in Android 14**; unchanged in 15 and 16.
2. When that post finally runs, `ActivityRecord.sendResult()` schedules an
   `ActivityResultItem` only `if (isState(RESUMED) && attachedToProcess())`.
   Otherwise it falls through to `addResultLocked()`, which merely appends to the
   `ActivityRecord.results` field.
3. `ActivityRecord.results` is drained in exactly three places, all of them
   *resume* or *(re)launch* paths. There is no timer and no idle drain.
4. `TaskFragment.resumeTopActivity()` returns early **without** draining
   `next.results` when the activity is already the resumed one — two separate
   early returns.
5. `ActivityRecord.completeResumeLocked()` does `results = null;` unconditionally.

A result parked in `results` while its owner is (or becomes) RESUMED with no
further resume pass is destroyed with **no log line at any level** on a
production build: `DEBUG_RESULTS` is a compile-time `false` in both
`ActivityTaskManagerDebugConfig` and `ActivityThread`.

**The one measurement that settles it** is the event-log tag
`wm_on_activity_result_called` (30062), written unconditionally by
`Activity.internalDispatchActivityResult()` in the *app* process on every
delivery. Its absence, paired with a *present* `wm_finish_activity ...
app-request` for `PickActivity`, pins the drop to the framework rather than to
the app or to androidx. Full recipe in Q6.

---

## Q1. Known AOSP issues: intermittently lost result for CREATE_DOCUMENT / DocumentsUI

### Q1a. No matching filed bug

Searches run against issuetracker.google.com, StackOverflow, AOSP gitiles/gerrit
and the open web:

- `"onActivityResult not called" CREATE_DOCUMENT intermittent`
- `DocumentsUI PickActivity setResult race`
- `"activity result" lost emulator`
- `wm_finish_activity result lost`
- `ActivityRecord addResultLocked race`
- `onActivityResult never called activity result lost RESULT_CANCELED not delivered Android 15`
- `"finishActivityResults" "isState(RESUMED)" mH.post activity result race`
- `"mForceSendResultForMediaProjection"`
- `"addResultLocked" OR "sendResult" OR "results = null" completeResumeLocked lost`
- `Storage Access Framework save dialog closes intermittently emulator Android 14 15`

Nothing matches "dialog closes, no result at all, caller stays resumed". What the
corpus is full of is four deterministic causes, none of which fit — listed so
they can be dismissed on the record:

| Known cause | Symptom it produces | Fits? |
|---|---|---|
| `launchMode="singleInstance"` (or `singleTask`) on the caller | `RESULT_CANCELED` **immediately at `launch()` time** | No — no result at all, and other round-trips in the same process work |
| `FLAG_ACTIVITY_NEW_TASK` on the outgoing intent | `RESULT_CANCELED` immediately | No |
| `startActivityForResult` from a nested fragment | result goes to the parent, never the child | No — the app's own `Activity.onActivityResult` override, logging *before* `super`, does not fire |
| Process death mid-picker | result arrives after process restart, or the `ActivityResultRegistry` key is not restored | No — no `am_kill` / `am_proc_died`, caller kept running |

`issuetracker.google.com/issues/37136466` (SAF `ACTION_CREATE_DOCUMENT` overwrite
semantics) and `issuetracker.google.com/issues/192567522` are unrelated.

**Conclusion: this is an unfiled framework race. There is no bug id and no
"fixed in" version to point at.**

### Q1b. The one relevant behavioural change that *does* carry a bug id

`core/java/android/app/servertransaction/ActivityResultItem.java:54-60`:

```java
/**
 * Correct the lifecycle of activity result after {@link android.os.Build.VERSION_CODES#S} to
 * guarantee that an activity gets activity result just before resume.
 */
@ChangeId
@EnabledAfter(targetSdkVersion = Build.VERSION_CODES.S)
public static final long CALL_ACTIVITY_RESULT_BEFORE_RESUME = 78294732L;
```

`78294732` is the AOSP bug id. It is a targetSdk-gated compat change:
`getPostExecutionState()` returns `ON_RESUME` for `targetSdk > S`, `UNDEFINED`
otherwise. Relevant because the *shape* of the delivery transaction depends on
the app's `targetSdk`, so a repro that changes `targetSdk` changes the code path.
It is not the bug.

### Q1c. The race, stated precisely, with the code

**Step 1 — the async hop.** `ActivityRecord.finishActivityResults()`,
[`services/core/java/com/android/server/wm/ActivityRecord.java:3578-3593`](https://cs.android.com/android/platform/superproject/main/+/main:frameworks/base/services/core/java/com/android/server/wm/ActivityRecord.java;l=3578):

```java
if (mForceSendResultForMediaProjection || resultTo.isState(RESUMED)) {
    // Sending the result to the resultTo activity asynchronously to prevent the
    // resultTo activity getting results before this Activity paused.
    final ActivityRecord resultToActivity = resultTo;
    mAtmService.mH.post(() -> {
        synchronized (mAtmService.mGlobalLock) {
            resultToActivity.sendResult(this.getUid(), resultWho, requestCode,
                    resultCode, resultData, callerToken, resultGrants,
                    mForceSendResultForMediaProjection);
        }
    });
} else {
    resultTo.addResultLocked(this, resultWho, requestCode, resultCode, resultData,
            callerToken);
}
resultTo = null;
```

Version history, verified by fetching each release tag and reading the function:

| Release | `mH.post` branch | Line |
|---|---|---|
| `android-13.0.0_r1` | **absent** — always `addResultLocked` | 3269 |
| `android-14.0.0_r1` | present, same condition | 3423 |
| `android-15.0.0_r1` (API 35) | present, identical | 3635 |
| `android-16.0.0_r1` (API 36) | present, identical | 3480 |

The async hop exists on exactly the emulator images in question, and did not
exist before Android 14. `mAtmService.mH` is the `ActivityTaskManagerService`
handler — a shared, heavily loaded system_server handler thread. Under host CPU
starvation that post can be delayed arbitrarily. **This is the "only under load,
never solo" property, in one line of code.**

**Step 2 — the state re-check that can miss.** Same file, `sendResult()`,
lines 4975-5017:

```java
if (isState(RESUMED) && attachedToProcess()) {
    try {
        final ArrayList<ResultInfo> list = new ArrayList<>();
        list.add(new ResultInfo(resultWho, requestCode, resultCode, data, callerToken));
        final ActivityResultItem item = new ActivityResultItem(token, list);
        mAtmService.getLifecycleManager().scheduleTransactionItem(app.getThread(), item);
        return;
    } catch (Exception e) {
        Slog.w(TAG, "Exception thrown sending result to " + this, e);
    }
}
// ... media-projection force-send branch ...
addResultLocked(null /* from */, resultWho, requestCode, resultCode, data, callerToken);
```

Two ways to reach the fall-through:

- the caller is no longer `RESUMED` when the post finally runs (it went
  `PAUSING`/`PAUSED`, or is mid-relaunch for a configuration change), or
- `scheduleTransactionItem` throws — the **only logged** case,
  `W ActivityTaskManager: Exception thrown sending result to ActivityRecord{...}`.

Note also that `scheduleTransactionItem` is itself deferred:
`ClientLifecycleManager.scheduleTransactionItem()` (lines 104-112) adds the item
to a *pending* `ClientTransaction` keyed by client binder, dispatched later from
`RootWindowContainer#performSurfacePlacementNoTrace` /
`WindowSurfacePlacer#continueLayout`, unless
`shouldDispatchPendingTransactionsImmediately()` (no layout deferred, requested
or in progress). That is a second asynchronous hop, also load-sensitive.

**Step 3 — `results` is a dead-letter box.** `addResultLocked` (line 4912) only
appends to the `ArrayList<ResultInfo> results` field. Exhaustive grep of that
field's consumers across `frameworks/base`:

- `TaskFragment.resumeTopActivity()` lines 1606-1619 — "Deliver all pending results"
- `ActivityTaskSupervisor.realStartActivityLocked()` lines 904-911 — only `if (andResume)`, bundled into `LaunchActivityItem`
- `ActivityRecord.relaunchActivityLocked()` lines 9698-9703 — only `if (andResume)`, bundled into `ActivityRelaunchItem`

All three are resume-or-launch paths. There is no timer, no idle drain, no
"deliver pending results to an already-running activity" path.

**Step 4 — the early returns that skip the drain.**
[`services/core/java/com/android/server/wm/TaskFragment.java:1355-1378`](https://cs.android.com/android/platform/superproject/main/+/main:frameworks/base/services/core/java/com/android/server/wm/TaskFragment.java;l=1355):

```java
final TaskDisplayArea taskDisplayArea = getDisplayArea();
// If the top activity is the resumed one, nothing to do.
if (mResumedActivity == next && next.isState(RESUMED)
        && taskDisplayArea.allResumedActivitiesComplete()) {
    ...
    ProtoLog.d(WM_DEBUG_STATES, "resumeTopActivity: Top activity resumed %s", next);
    return false;
}
```

and again at lines 1447-1458 (the `dontWaitForPause` case). Both return **before**
the `next.results` drain at line 1609. Once the caller is settled as the resumed
activity, no amount of subsequent `resumeTopActivity` traffic will deliver a
result parked in `results`.

There is a third skip at lines 1595-1603:

```java
if (next.mPendingRelaunchCount > originalRelaunchingCount) {
    // The activity is scheduled to relaunch, then ResumeActivityItem will be also
    // included (see ActivityRecord#relaunchActivityLocked) if it should resume.
    next.completeResumeLocked();
    return true;
}
```

**Step 5 — and then it is erased.** `ActivityRecord.completeResumeLocked()`,
line 6517:

```java
void completeResumeLocked() {
    idle = false;
    results = null;
    ...
}
```

Unconditional. Any result parked in `results` that was not picked up by the
transaction this resume corresponds to is destroyed here, silently.

### Q1d. Why it fires on SAVE and not on CANCEL or OPEN

The branch taken at Step 1 depends on `resultTo.isState(RESUMED)` *at the instant
DocumentsUI calls `finish()`*.

- A **cancel** is a `finish()` on the input event, synchronously, while the
  caller is still `PAUSED` behind the picker. That takes the safe
  `addResultLocked` branch and rides the caller's ordinary resume.
- A **SAVE** calls `finish()` from `AsyncTask.onPostExecute` (Q2) — an arbitrary
  number of main-loop turns after the click, and after the create's binder round
  trip into the provider. Under load that is long enough for the caller to have
  been resumed already (the picker's window can be released, or
  `ensureActivitiesVisible` can resume the caller, before the finishing activity
  is torn down), which flips the branch onto the racy `mH.post` path.

That single timing difference is why an identical-looking cancel in the same
minute is reliable and a save is 50/50.

### Q1e. Prediction worth testing

The bug should reproduce **without DocumentsUI at all**: a two-activity test app
where the callee does `handler.postDelayed({ setResult(RESULT_OK, i); finish() },
300)` while the caller is being resumed, under `stress-ng`-level host load. If
that reproduces, the report writes itself and the repro is small enough to file.

---

## Q2. AOSP DocumentsUI: the exact CREATE_DOCUMENT save path

Source: `platform/packages/apps/DocumentsUI` at `refs/heads/main`.

Caveat on package name: the Google APIs image ships
`com.google.android.documentsui`, Google's build of this same tree plus vendor
bits. AOSP is the only readable source; the picker save path below is the shared
part.

### The call chain

**1. `picker/SaveFragment.java`** — the bottom bar with the filename field and the
SAVE button. `TAG = "SaveFragment"` (line 49); attached with
`ft.replace(R.id.container_save, fragment, TAG); ft.commitAllowingStateLoss();`
(lines 71-73). The button is `android.R.id.button1` (line 121); its listener
(lines 168-174) calls `performSave()`, as does `KEYCODE_ENTER` on the name field
(lines 113-116):

```java
private void performSave() {
    if (mReplaceTarget != null) {
        mInjector.actions.saveDocument(getChildFragmentManager(), mReplaceTarget);
    } else {
        final String mimeType = getArguments().getString(EXTRA_MIME_TYPE);
        final String displayName = mDisplayName.getText().toString();
        mInjector.actions.saveDocument(mimeType, displayName, mInProgressStateListener);
    }
}
```

Two arms. A name that still matches an existing document in the directory
(`mReplaceTarget != null`, set by `setReplaceTarget`, line 191) goes to the
overwrite arm. **A rename through accessibility writes the `EditText`, which
fires `mDisplayNameWatcher.onTextChanged` and clears `mReplaceTarget`** (lines
147-155), so the accessibility-driven flow always takes the create arm.

**2. `picker/ActionHandler.java:445-459`** — the create arm. This is where the
asynchrony is:

```java
void saveDocument(
        String mimeType, String displayName, BooleanConsumer inProgressStateListener) {
    assert (mState.action == ACTION_CREATE);
    mInjector.pickResult.increaseActionCount();
    new CreatePickedDocumentTask(
            mActivity, mDocs, mLastAccessed, mState.stack, mimeType, displayName,
            inProgressStateListener,
            this::onPickFinished)
            .executeOnExecutor(getExecutorForCurrentDirectory());
}
```

**3. `picker/CreatePickedDocumentTask.java`** — a `PairedTask<Activity, Void, Uri>`:

```java
@Override protected void prepare() { mInProgressStateListener.accept(true); }

@Override protected Uri run(Void... params) {
    DocumentInfo cwd = mStack.peek();
    Uri childUri = mDocs.createDocument(cwd, mMimeType, mDisplayName);   // binder into the provider
    if (childUri != null) { mLastAccessed.setLastAccessed(mOwner, mStack); }
    return childUri;
}

@Override protected void finish(Uri result) {
    if (result != null) {
        mCallback.accept(result);                                        // -> onPickFinished
    } else {
        Snackbars.makeSnackbar(mOwner, R.string.save_error, Snackbar.LENGTH_LONG).show();
    }
    mInProgressStateListener.accept(false);
}
```

**4. `picker/ActionHandler.java:488-533`** — `onPickFinished(Uri... uris)` builds
the result intent, adds `FLAG_GRANT_READ_URI_PERMISSION |
FLAG_GRANT_WRITE_URI_PERMISSION | FLAG_GRANT_PERSISTABLE_URI_PERMISSION` for
`ACTION_CREATE`, then:

```java
mActivity.setResult(FragmentActivity.RESULT_OK, intent, 0);
mActivity.finish();
```

`PickActivity.setResult(int, Intent, int)` (lines 470-471) is only a
test-interception overload; it calls the real `setResult(resultCode, intent)`.

**Which fragment handles SAVE, answered plainly:** `SaveFragment`, not
`PickFragment`. `PickFragment` is the OPEN_TREE / copy-destination bar.
`ActionHandler.pickDocument()` is for `ACTION_OPEN_TREE` and
`ACTION_PICK_COPY_DESTINATION` only and `throw`s `IllegalStateException` on
anything else (lines 439-441); `ActionHandler.saveDocument()` is the
CREATE_DOCUMENT entry point.

### Is creation async relative to setResult+finish? Yes, twice over

- `CreatePickedDocumentTask` is an `AsyncTask` run on
  `getExecutorForCurrentDirectory()` (`ActionHandler.java:535-542`) — a
  per-authority `ExecutorService`, falling back to
  `AsyncTask.THREAD_POOL_EXECUTOR`. `setResult`/`finish` happen in
  `onPostExecute` on the main looper, an unbounded number of main-loop turns
  after the click and after a binder round trip into the provider.
- The overwrite arm, `ACTION_OPEN_TREE` and copy-destination go through
  `finishPicking(Uri...)` (lines 477-486), which prepends a *second* async task
  (`SetLastAccessedStackTask`) before `onPickFinished`. The plain create arm does
  not.

### Can the activity finish with the async create in flight, skipping setResult?

Yes — two mechanisms exist. **Neither one closes the dialog while leaving the
caller with no result**, so neither explains the observation:

**(i) The `isDestroyed` guard.** `base/PairedTask.java:34-37` passes
`super(owner::isDestroyed)`; `base/CheckedTask.java:52-74` short-circuits every
stage on it:

```java
@Override protected final void onPreExecute()  { if (mCheck.stop()) return; prepare(); }
@Override protected final Output doInBackground(Input... input) { if (mCheck.stop()) return null; return run(input); }
@Override protected final void onPostExecute(Output result)     { if (mCheck.stop()) return; finish(result); }
```

If `PickActivity` is destroyed while the create is in flight, `onPostExecute`
returns silently, `onPickFinished` is never reached, `setResult` is never called.
**But** the destruction is itself a finish/destroy, and the framework then
synthesizes `RESULT_CANCELED` via `ActivityRecord.removeFromHistory()`:

```java
void removeFromHistory(String reason) {
    finishActivityResults(Activity.RESULT_CANCELED,
            null /* resultData */, null /* resultGrants */);
```
(`ActivityRecord.java:4098-4100`)

So this path yields `RESULT_CANCELED` — *unless that `RESULT_CANCELED` is itself
dropped by the Q1c race*, which it can be, since it goes through identical
delivery code. Note also that `doInBackground` returning `null` on the guard
makes `finish(null)` indistinguishable from a genuine create failure.

**(ii) `createDocument` returns null or throws.**
`DocumentsAccess.RuntimeDocumentAccess.createDocument` (`TAG = "DocumentAccess"`,
line 71) swallows everything:

```java
} catch (Exception e) {
    Log.w(TAG, "Failed to create document", e);
    return null;
}
```

That `Log.w` is always compiled in, so **`W DocumentAccess: Failed to create
document` is an unconditional, no-configuration marker for a failed create** —
add it to the filterspec. `CreatePickedDocumentTask.finish(null)` then shows a
`Snackbar` (`R.string.save_error`) and calls `mInProgressStateListener.accept(false)`,
which un-hides the SAVE button and hides the progress bar
(`SaveFragment.setPending`, lines 209-212). **The dialog stays open.** A null
create therefore cannot produce "dialog closed, no result" — it produces "dialog
still there, red snackbar". This rules out the async-create-failure hypothesis on
source.

### Verdict on Q2

DocumentsUI's save path is async and does have a silent no-result branch, but
every DocumentsUI-internal branch either leaves the dialog open or destroys the
activity — which the framework turns into `RESULT_CANCELED`. **DocumentsUI's only
contribution to the observed bug is timing:** it calls `setResult`+`finish` from
`onPostExecute` rather than from the click, and that delay is what flips
`ActivityRecord.finishActivityResults` onto its racy branch.

---

## Q3. Cached-app freezer and in-flight binder transactions

**Verdict: ruled out on source, and the `am_freeze` line is positive evidence
*against* freezer involvement.**

### `setResult` + `finish` is one synchronous binder call

`setResult` is purely local — it stores `mResultCode` / `mResultData` on the
Activity. Nothing crosses a process boundary. The result travels on `finish()`,
which is a *synchronous, two-way* AIDL call into system_server.
`core/java/android/app/Activity.java`, `private void finish(int finishTask)`:

```java
synchronized (this) {
    resultCode = mResultCode;
    resultData = mResultData;
}
if (false) Log.v(TAG, "Finishing self: token=" + mToken);
if (resultData != null) {
    resultData.prepareToLeaveProcess(this);
}
if (ActivityClient.getInstance().finishActivity(mToken, resultCode, resultData,
        finishTask)) {
    mFinished = true;
}
```

`IActivityClientController.finishActivity` returns `boolean`, so it is blocking
and two-way. The payload is inside system_server before `finish()` returns, or
the call threw. It cannot be "in flight and lost" by a later freeze of
DocumentsUI.

### The kernel refuses to freeze a process with outstanding transactions

`services/core/java/com/android/server/am/CachedAppOptimizer.java`,
`freezeProcess()` lines 2334-2342:

```java
Slog.d(TAG_AM, "freezing " + pid + " " + name);

// Freeze binder interface before the process, to flush any
// transactions that might be pending.
try {
    if (mFreezer.freezeBinder(pid, true, FREEZE_BINDER_TIMEOUT_MS) != 0) {
        handleBinderFreezerFailure(proc, "outstanding txns");
        return;
    }
}
```

and the `am_freeze` event is written only *after* the freeze actually succeeded,
line 2378-2382:

```java
if (!frozen) {
    return;
}

EventLog.writeEvent(EventLogTags.AM_FREEZE, pid, name);
```

**So the `am_freeze` in the observed log is proof from the kernel that
DocumentsUI had zero outstanding binder transactions at that moment.** A process
with a pending transaction takes the `handleBinderFreezerFailure(proc,
"outstanding txns")` path, is rescheduled with exponential backoff, and emits no
`am_freeze` at all.

### And a transaction that *did* arrive during a freeze is loud, not silent

Same file, unfreeze path, lines 1458-1481:

```java
int freezeInfo = mFreezer.getBinderFreezeInfo(pid);

if ((freezeInfo & SYNC_RECEIVED_WHILE_FROZEN) != 0) {
    Slog.d(TAG_AM, "pid " + pid + " " + app.processName
            + " received sync transactions while frozen, killing");
    app.killLocked("Sync transaction while in frozen state",
            ApplicationExitInfo.REASON_FREEZER,
            ApplicationExitInfo.SUBREASON_FREEZER_BINDER_TRANSACTION, true);
    processKilled = true;
}
```

There is no such kill in the observed log, and no `am_kill` / `am_proc_died`.

### The AOSP contract, for completeness

[source.android.com/docs/core/architecture/ipc/binder-freezer](https://source.android.com/docs/core/architecture/ipc/binder-freezer)
and [source.android.com/docs/core/perf/cached-apps-freezer](https://source.android.com/docs/core/perf/cached-apps-freezer):
a **sync** transaction to a frozen process causes the *frozen callee* to be
killed, so the caller does not hang; an **async (oneway)** transaction is
*buffered* until thaw, and if the async buffer overflows the recipient crashes.
Neither mode silently discards a transaction.

The one place freezing could touch the framework result path is `sendResult` →
`scheduleTransactionItem` → `ClientTransaction.schedule()` →
`IApplicationThread.scheduleTransaction`, a **oneway** call to the *caller's*
process. But the caller here is RESUMED and foreground, therefore never frozen —
and any failure there is logged (`W ActivityTaskManager: Exception thrown sending
result to ...`, plus `W ClientLifecycleManager: Failed to deliver transaction for
...`). `RemoteCallbackList`'s frozen-callee policies
(`FROZEN_CALLEE_POLICY_DROP` / `ENQUEUE_MOST_RECENT` / `ENQUEUE_ALL`) are a
different mechanism entirely, for app-registered callbacks; activity results do
not travel on one.

### If you want the freezer formally out of the picture for a repro run

```
adb shell device_config put activity_manager_native_boot use_freezer false
# or, on a userdebug image:
adb shell settings put global cached_apps_freezer disabled && adb reboot
```

The bug should survive both.

---

## Q4. Emulator-specific and accessibility-click-specific flakiness

### Q4a. No known emulator/Google-APIs DocumentsUI result-delivery bug

Searches for goldfish/ranchu-specific or Google-APIs-specific result-delivery
flakiness turned up nothing. The emulator's contribution here is not a bug of its
own — it is that **the emulator is the machine most likely to starve
system_server's handler threads**, which is precisely what widens the Q1c window.
That is a scheduling property, not a goldfish defect.

### Q4b. A stale accessibility node cannot click a different node

`core/java/android/view/AccessibilityInteractionController.java`,
`performAccessibilityActionUiThread`:

```java
boolean succeeded = false;
try {
    if (mViewRootImpl.mView == null || mViewRootImpl.mAttachInfo == null ||
            mViewRootImpl.mStopped || mViewRootImpl.mPausedForTransition) {
        return;
    }
    setAccessibilityFetchFlags(flags);
    final View target = findViewByAccessibilityId(accessibilityViewId);
    if (target != null && isShown(target) && isVisibleToAccessibilityService(target)) {
        ...
        succeeded = target.performAccessibilityAction(action, arguments);
    }
} finally {
    ...
    callback.setPerformAccessibilityActionResult(succeeded, interactionId);
```

The action is routed by **accessibility view id within a specific window**. If the
view is gone, hidden, or not visible to the service, `succeeded` stays `false` and
that `false` is reported back to the service. **A stale node click fails; it does
not land somewhere else.** It cannot hit the nav-bar BACK, which lives in a
different window (SystemUI) with a different window id.

Two consequences worth having in the diagnostic kit:

- The early `return` on `mStopped || mPausedForTransition` means a click delivered
  while the picker window is stopped or mid-transition is **silently swallowed**
  and reported `false`. Under load that is a real failure mode — but it produces
  "SAVE never fired, dialog still open", not the observed symptom.
- While the create is in flight, `SaveFragment.setPending(true)` sets the SAVE
  button `INVISIBLE` and shows the `ProgressBar`. So a retrying harness that
  re-clicks SAVE will find no SAVE node the second time (`isShown(target)` is
  false); it cannot double-fire the create through the button.

### Q4c. Every DocumentsUI dismissal path still produces a result

- `PickActivity.onBackPressed()` (lines 182-183) calls `super.onBackPressed()` →
  `finish()` → `RESULT_CANCELED` through the same `finishActivityResults`.
- `AccessibilityService.GLOBAL_ACTION_BACK` reaches the same place.
- Destruction with a task in flight → `removeFromHistory()` →
  `finishActivityResults(RESULT_CANCELED, ...)`.

So there is no DocumentsUI-side dismissal that produces *zero* results. Every one
of them funnels into the code path from Q1c, which is where results are lost.

### Q4d. The one competing hypothesis, and how to kill it in one grep

**Alternative:** the picker was never finished at all — its window merely went
*away* (backgrounded / stopped), e.g. because something brought the caller's task
to the front. The observer sees "the dialog closed", the caller is resumed and
responsive, no result is ever produced (correctly, because nothing finished), and
DocumentsUI's process becomes cached and is frozen ~10 s later — **which is
exactly as consistent with the observed `am_freeze` as the finish hypothesis is.**

The discriminator is one line in the events buffer:

```
adb logcat -b events -d | grep -i "wm_finish_activity" | grep -i documentsui
```

- **Present** (reason `app-request`) → the picker really did finish with a result,
  and the drop is the framework race of Q1c.
- **Absent** → the picker was backgrounded, not finished; the bug is upstream, in
  whatever moved the task, and the SAVE press never completed.

Run this grep first. It splits the problem in half before anything else.

---

## Q5. Making DocumentsUI log verbosely on a stock Google-APIs emulator, no root

### Q5a. The tag is `Documents`, and on a Google APIs image DEBUG is already on

`src/com/android/documentsui/base/SharedMinimal.java:29-34` — the whole gate:

```java
public final class SharedMinimal {

    public static final String TAG = "Documents";

    public static final boolean DEBUG = !"user".equals(Build.TYPE);
    public static final boolean VERBOSE = DEBUG && Log.isLoggable(TAG, Log.VERBOSE);
```

Two separate things:

- **`DEBUG` is not a log tag at all.** It is `!"user".equals(Build.TYPE)`.
  `google_apis` emulator images are **userdebug** (which is why `adb root` works
  on them; `google_apis_playstore` images are `user` and it does not). **So on the
  image in question `DEBUG` is already `true` with no configuration whatsoever.**
  Verify in one command: `adb shell getprop ro.build.type`.
- **`VERBOSE` additionally requires** `Log.isLoggable("Documents", VERBOSE)`, i.e.
  `adb shell setprop log.tag.Documents VERBOSE`.

**The trap:** `VERBOSE` is a `static final` field evaluated once at class load.
Setting the property after DocumentsUI is already running does nothing. Always:

```
adb shell setprop log.tag.Documents VERBOSE
adb shell am force-stop com.google.android.documentsui
```

### Q5b. The single most useful DocumentsUI line, and it needs no configuration

`picker/ActionHandler.java` uses `TAG = "PickerActionHandler"` (line 82) — *not*
`"Documents"` — and gates on `DEBUG`, which is already true:

```java
private void onPickFinished(Uri... uris) {
    if (DEBUG) {
        Log.d(TAG, "onFinished() " + Arrays.toString(uris));
    }
```

So on a `userdebug` image you get, for free:

```
D PickerActionHandler: onFinished() [content://com.android.externalstorage.documents/document/...]
```

**This line firing proves DocumentsUI reached `onPickFinished` and therefore
called `setResult(RESULT_OK, ...)` + `finish()`.** It is the DocumentsUI-side half
of the bisection; `wm_on_activity_result_called` (Q6) is the app-side half. If the
first is present and the second is absent, the framework ate the result.

Other tags to add to a filter, all `Log.e`/`Log.w` (always on):
`PickActivity`, `PickerActionHandler`, `DocumentAccess`, `Documents`,
`SaveFragment`, `PickFragment`.

A practical filterspec:

```
adb logcat -v threadtime \
  PickerActionHandler:V PickActivity:V DocumentAccess:V Documents:V SaveFragment:V \
  ActivityTaskManager:V ActivityManager:V ClientLifecycleManager:V \
  WindowManager:V ActivityThread:V '*:S'
```

### Q5c. The framework's own result logging is NOT enableable at runtime

Do not go hunting for `setprop` on these — they are compile-time constants:

- `services/core/java/com/android/server/wm/ActivityTaskManagerDebugConfig.java:41,57`
  — `static final boolean DEBUG_ALL = false;` and
  `static final boolean DEBUG_RESULTS = DEBUG_ALL || false;`
- `core/java/android/app/ActivityThread.java:313` —
  `private static final boolean DEBUG_RESULTS = false;`

Also from that config file: `TAG_ATM = "ActivityTaskManager"` and
`APPEND_CATEGORY_NAME = false`, so `TAG_RESULTS` is just `"ActivityTaskManager"`
— there is no separate `_Results` tag to filter on even on a custom build.

### Q5d. What *is* enableable at runtime: ProtoLog

The `WM_DEBUG_STATES` group covers exactly the state transitions and the
early-return in Step 4 of Q1c. It routes to logcat under tag `WindowManager`
(`core/java/com/android/internal/protolog/WmProtoLogGroups.java:53-54,166`:
`WM_DEBUG_STATES(..., Consts.TAG_WM)` with `TAG_WM = "WindowManager"`), and it can
be turned on with a shell command on a stock build:

```
adb shell cmd window logging enable-text WM_DEBUG_STATES
# ... reproduce ...
adb shell cmd window logging disable-text WM_DEBUG_STATES
```

Backed by `WindowManagerShellCommand.java:116-133` dispatching to
`PerfettoProtoLogImpl.onShellCommand` (`case "enable-text"`, line 340) /
`LegacyProtoLogImpl`. `adb shell cmd window logging status` lists the groups.

The lines this turns on that matter:

- `resumeTopActivity: Top activity resumed <ActivityRecord>` — **the early return
  that skips the results drain (TaskFragment:1375)**
- `resumeTopActivity: Top activity resumed (dontWaitForPause) <r>` (line 1455)
- `resumeTopActivity: Skip resume: some activity pausing.` / `need to start pausing`
- `Moving to RESUMED Relaunching <r> callers=...` / `Resumed after relaunch <r>`

### Q5e. Buffer sizes: `-G` is per-buffer and does **not** persist

- `system/logging/logcat/logcat.cpp:1042-1062` loops over the buffer id mask and
  calls `android_logger_set_log_size` per buffer. Help text, line 415-417:
  *"Set size of a ring buffer in logd. May suffix with K or M. This can
  individually control each buffer's size with `-b`."* With no `-b`, it applies to
  the default selection, so **name the buffers explicitly**.
- `system/logging/logd/LogSize.h:23-25`:
  `kDefaultLogBufferSize = 256 KB`, `kLogBufferMinSize = 64 KB`,
  `kLogBufferMaxSize = 256 MB` (older logd capped at 16 MB; current AOSP allows
  256 MB).
- **`persist.logd.size` will not help you on an emulator.**
  `system/logging/logd/LogSize.cpp:65-93` — since b/196856709 the property
  override is honoured only when `ro.debuggable` **and** `ro.hardware.type` is
  `automotive` or `desktop`:

```java
/* This method should only be used for debuggable devices. */
static bool isAllowedToOverrideBufferSize() {
    const auto hwType = android::base::GetProperty("ro.hardware.type", "");
    /* Allow automotive and desktop devices to optionally override the default. */
    return (hwType == "automotive" || hwType == "desktop");
}
```

  So `-G` at runtime is the only lever, and it must be re-applied after every
  boot. Verify with `adb logcat -g`.

Recommended, run after every emulator boot and before the repro:

```
adb logcat -b main   -G 64M
adb logcat -b system -G 64M
adb logcat -b events -G 64M
adb logcat -b crash  -G 16M
adb logcat -g            # confirm it took
adb logcat -b all -c     # clear immediately before the run
```

---

## Q6. What a successful delivery logs that a lost one does not

### Q6a. The decisive line: `wm_on_activity_result_called`, event tag 30062

`core/java/android/app/Activity.java`, `internalDispatchActivityResult`, last
statement, **unconditional, no debug flag**:

```java
} else {
    Fragment frag = mFragments.findFragmentByWho(who);
    if (frag != null) {
        frag.onActivityResult(requestCode, resultCode, data);
    }
}

EventLogTags.writeWmOnActivityResultCalled(mIdent, getComponentName().getClassName(),
        reason);
```

Definition, `core/java/android/app/EventLogTags.logtags:24-25`:

```
# The activity's onActivityResult has been called.
30062 wm_on_activity_result_called (Token|1|5),(Component Name|3),(Reason|3)
```

It is written in the **app** process, after the dispatch, on every path
(`onActivityResult`, permission results, fragment results, autofill). `Reason` is
the transaction that carried it — `"ACTIVITY_RESULT"` from
`ActivityResultItem.execute()`:

```java
client.handleSendResult(r, mResultInfoList, "ACTIVITY_RESULT");
```

(`core/java/android/app/servertransaction/ActivityResultItem.java:78`), or the
resume/relaunch/launch reason when the results ride one of those.

**A run in which the app's `onActivityResult` never fired has no
`wm_on_activity_result_called` for that component. A run in which it fired has
exactly one.** That is the yes/no.

### Q6b. The bisection, in order

Capture `adb logcat -b events,main,system -v threadtime` across the whole run.

| # | Line to grep | Buffer | Means |
|---|---|---|---|
| 1 | `wm_create_activity ... PickActivity` | events | picker launched, `resultTo` link established |
| 2 | `D PickerActionHandler: onFinished()` | main | DocumentsUI reached `onPickFinished`; `setResult(RESULT_OK)` + `finish()` executed (needs `ro.build.type=userdebug`, which google_apis is — Q5b) |
| 3 | `wm_finish_activity ... PickActivity ... app-request` | events | `finish()` reached ATMS **with the result payload**. Reason string from `ActivityClientController.java:527`, `r.finishIfPossible(resultCode, resultData, resultGrants, "app-request", ...)` |
| 4 | `wm_on_activity_result_called ... <YourActivity> ... ACTIVITY_RESULT` | events | **the result was delivered.** Its absence with 2 and 3 present is the bug |
| 5 | `wm_resume_activity` / `wm_on_resume_called` for the caller | events | where the caller resumed relative to 3 — this is the branch selector in `finishActivityResults` |
| 6 | `wm_destroy_activity ... PickActivity` | events | picker torn down |
| 7 | `am_freeze <pid> ...documentsui` | events | routine, and per Q3 proof that no transaction was outstanding |

**Signature of the Q1c race: 2 and 3 present, 4 absent, and 5 landing *before* 3.**

If 5 lands before 3, `resultTo.isState(RESUMED)` was true at finish time and the
racy `mH.post` branch was taken. On a working run, expect 5 *after* 3.

### Q6c. The only error lines the drop path can produce

All at `W`/`E`, always compiled in:

| Log line | Source |
|---|---|
| `W ActivityTaskManager: Exception thrown sending result to ActivityRecord{...}` | `ActivityRecord.sendResult()` line 4983 — the transaction could not be scheduled; the result fell into `results` |
| `W ActivityTaskManager: Unable to get the lifecycle item for state <state> so couldn't immediately send result` | `ActivityRecord.sendResult()` line 5003 (media-projection force-send only) |
| `W ClientLifecycleManager: Failed to deliver transaction for <client>` | `ClientLifecycleManager.scheduleTransaction()` line 79 |
| `E ClientLifecycleManager: Failed to deliver pending transaction` | `ClientLifecycleManager.dispatchPendingTransactions()` lines 165, 180 |
| `I ActivityTaskManager: Failed to finish by app-request` | `ActivityClientController.java:531` — `finishIfPossible` returned `FINISH_RESULT_CANCELLED` |
| `W ActivityTaskManager: Force removing <r>: app died, no saved state` | `ActivityRecord.java:4359`, with a `wm_finish_activity ... "proc died without state saved"` beside it |

**Most likely outcome: none of these appear.** The Q1c drop is completely silent.
Their absence is itself informative — it excludes the transport failures and
leaves the state race.

### Q6d. Grep targets that do NOT exist (do not waste a run on them)

- There is no `SCHEDULE_SEND_RESULT` message in modern `ActivityThread` — result
  delivery moved to `ClientTransaction` / `ActivityResultItem` in Android 9. The
  old `H.SEND_RESULT` handler message is gone.
- There is no "Skipping delivery" line anywhere in the result path.
- `Slog.v(TAG_RESULTS, "Adding result to ...")`,
  `"Send activity result to ..."`, `"Delivering results to ..."`,
  `"No result destination from ..."` and `ActivityThread`'s
  `"Handling send result to ..."` / `"Delivering result to activity ..."` all
  exist in source but are behind compile-time `false` (Q5c). **They require a
  custom `system_server` / framework build.**

### Q6e. Two runtime observations that need no custom build

**1. The orphaned result is visible in `dumpsys`, briefly.**
`ActivityRecord.dump()` lines 1105-1107:

```java
if (results != null) {
    pw.print(prefix); pw.print("results="); pw.println(results);
}
```

So, immediately after the SAVE press, poll:

```
while :; do adb shell dumpsys activity activities | grep -n "results=" ; sleep 0.2; done
```

Catching `results=[ResultInfo{who=null, request=..., result=-1, data=Intent{...}}]`
on the *caller's* `ActivityRecord` while `onActivityResult` never fires is direct
proof of the parked-result state. It vanishes the moment `completeResumeLocked()`
runs, so poll fast and start before the press.

**2. atrace slices, no debug build required.**
`ActivityResultItem.execute()` wraps the dispatch in
`Trace.traceBegin(TRACE_TAG_ACTIVITY_MANAGER, "activityDeliverResult")`, and
`ClientLifecycleManager.dispatchPendingTransactions()` emits
`clientTransactionsDispatched` under `TRACE_TAG_WINDOW_MANAGER`. A perfetto
capture with the `am` and `wm` categories shows whether an `activityDeliverResult`
slice ever ran in the caller's process — and, on the loaded runs, exactly how long
the `mH` handler was starved.

---

## Practical next steps, in priority order

1. **`adb logcat -b events -d | grep -i wm_finish_activity | grep -i documentsui`**
   on a captured failure. Present vs absent splits the problem in half (Q4d).
2. Capture with big buffers (Q5e) and bisect on the seven-line table in Q6b. The
   pair to look at is `D PickerActionHandler: onFinished()` present +
   `wm_on_activity_result_called` absent.
3. Check the ordering of the caller's `wm_resume_activity` against DocumentsUI's
   `wm_finish_activity`. Caller-resumes-first is the branch selector.
4. Poll `dumpsys activity activities | grep results=` across the press (Q6e).
5. Turn off the freezer (Q3) to close it out formally; expect no change.
6. Build the DocumentsUI-free repro from Q1e. If it reproduces, that is a filable
   AOSP bug with a two-activity test case, and the fix is small: drain
   `results` in `sendResult`'s fall-through when the target is already RESUMED and
   attached, instead of parking it in a list only a future resume can read.

## Workaround shape, if a fix is needed before AOSP moves

Nothing app-side can un-drop the result. The two mitigations that actually change
the odds:

- **Make the caller not be RESUMED when the picker finishes.** The safe
  `addResultLocked` branch is taken when `resultTo.isState(RESUMED)` is false.
  Anything that keeps the caller paused until the picker is fully gone avoids the
  racy branch entirely.
- **Do not rely on the result for correctness.** For `ACTION_CREATE_DOCUMENT`
  specifically, the document *was* created before `setResult` ran — the URI exists
  on disk. A timeout-and-recover path (re-query the tree, or `ACTION_OPEN_DOCUMENT`
  the known name) turns a lost result into a slow one rather than a hang.
