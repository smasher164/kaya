# Drag and drop: Android/Compose mechanics + cross-toolkit API shapes

Research notes for a maintainer design pass. RESEARCH ONLY — nothing in the repo
was edited, no process started.

Status legend: [repo] read out of this tree; [web] cited from the vendor docs.

---

## 0. What kaya already committed to (read out of the tree)

### 0.1 DESIGN.md's drag-and-drop paragraph (line 3044)

> **Drag and drop.** Hover acceptance is answered from a pre-pushed vocabulary of
> accepted types and operations, which matches platform convention anyway, since
> fetching drag content mid-hover is discouraged everywhere. Dynamic hover policy
> is app-updated state; staleness there mislabels a cursor badge, which is
> cosmetic. The drop verdict is a bounded wait whose expiry rejects the drop and
> snaps the drag back, a fail-safe and retryable default. Source-side data
> provision (`IDataObject::GetData`, pasteboard promises) is demand with a
> generous deadline; the blocked party is the receiving process, and platforms
> have long normalized slow providers. A side benefit: app logic keeps running
> inside the drag and resize modal loops that stall single-threaded apps.

Four separable claims, and Android answers each of them precisely (see §1.3):

1. hover acceptance = pre-pushed vocabulary, answered core-side, no app hop;
2. the drop VERDICT = a bounded wait on the app thread;
3. expiry ⇒ reject + snap back;
4. source-side data provision = demand with a generous deadline.

### 0.2 The blocking policy the paragraph rests on (DESIGN.md ~2990)

- "Bounded waits on **decisions** are allowed only when the expiry default is
  fail-safe and retryable. The drop verdict qualifies: on expiry the drop is
  rejected and the drag snaps back, an idiom users already know. A wait is never
  allowed where expiry silently commits an irreversible branch; accepting a
  'move' drop causes the source to delete the original."
- "Unbounded waits are prohibited." Three structural guarantees named for any
  finite deadline: deadlock immunity, OS-watchdog safety ("Not Responding", the
  beachball, an a11y "busy" state), and a cap on priority inversion (a parked
  main thread inherits the app thread's QoS; futex/condvar parks do not donate
  priority).
- Bounded waits on CONTENT are always allowed — lateness is cosmetic.

So the design's own dividing line is decision-vs-content, and the drop verdict is
the one DECISION it lets block. That is exactly the half Android constrains
hardest.

### 0.3 The degradation table (DESIGN.md ~3300)

Preamble is explicit that drag-and-drop is NOT BUILT: "Audio underrun, the drop
verdict, list teleport and the custom-editor rows all describe audio,
drag-and-drop and row-window virtualization, none of which exist in the core
(each is admission-gated in docs/deferred.md)."

| Situation | Degradation |
|---|---|
| Drop verdict misses its deadline | Drop rejected; drag snaps back (retryable) |
| Stale hover policy | Wrong cursor badge until the next refresh (cosmetic) |

### 0.4 The clipboard section is the payload model already ratified (DESIGN.md 2303+)

- A clip is ONE item available in several types; kaya's set is CLOSED:
  `text`, `html`, `image`, `files`, plus `custom(id, bytes)` as the escape hatch.
- Closed because the lowering per representation is real work: `CF_HTML`'s
  mandatory offset header, **Android's `ClipData` cannot carry image bytes at all
  and needs a `content://` provider**, files are three unrelated encodings
  (`CF_HDROP`, `text/uri-list`, file URLs).
- **Copy takes a RECORD, paste returns a SUM.** Offer many, receive one.
- Wire order is DESCENDING CLIP VALUE: custom (16), files (8), image (4),
  html (2), text (1).
- `custom`'s id grammar is MIME-SHAPED: contains a slash, lowercase, no spaces —
  a measured GDK charge (a slashless id is advertised and never served).
- Acceptance is per-widget and it is a LIST (`accepts`), not a mask — the closed
  kind names plus any custom ids. Explicitly cites Android:
  "`setOnReceiveContentListener` takes the accepted MIME types as an argument ON
  THE VIEW."
- kaya DERIVES NOTHING between representations (one exception: a file list also
  gets the platform's text rendition of the paths).
- Deliberately out: lazy rendering ("a callback the platform can block on,
  arriving on the app thread at a moment kaya does not control"), multiple items
  per clip, the X11/Wayland PRIMARY selection.

### 0.5 docs/clipboard-plan.md — "Paste and drop are the same event" (§, line 207)

> Android built `onReceiveContent` as a SINGLE API for content arriving from
> paste, from drag and drop, and from autofill. Wayland agrees structurally: both
> are `wl_data_offer`. macOS and Windows use one clip model for both.
> So `on_paste` is the same payload arriving through a third trigger when drag
> and drop lands later, not a second data model.

**This is the single most load-bearing prior decision for the design pass:**
drop is already committed to being `on_paste`'s payload under a third trigger.
Everything below should be read against it.

### 0.6 The measured Android clipboard facts already on the record (§0e.3, §3)

- No host-side path: there is no `cmd clipboard`; `service call clipboard <n>`
  shifts per API level, and a shell reader is never focused anyway.
- A FOCUSED read works and is fast (1 ms through the real system service).
- A read at `onCreate` returns null (no focus yet) — silent, indistinguishable
  from an empty clipboard.
- Content outlives the writing process.
- API 33+ pops a system clipboard preview overlay over the app for several
  seconds after a copy; it does not steal focus but is on screen and in the a11y
  tree. **Any clipboard leg has to expect it.**
- WRITES are not focus-gated, only READS are.
- Verification needs a FOREIGN app (a helper APK), because "a test where kaya
  reads what kaya wrote CANNOT CATCH" a malformed lowering.

### 0.7 What the Compose backend already does with ClipData (repo)

`android/kaya/src/main/kotlin/dev/kaya/KayaCompose.kt` (~line 3593,
`kayaCopyToClipboard`): builds ONE `ClipData` whose `ClipDescription("kaya",
mimes)` lists every offered mime, then appends `ClipData.Item`s — text+html as
one item, custom payloads and the image as `content://` URIs served by
`KayaClipProvider`, files as `Uri` items. That provider and the union
description are exactly what a drag payload would reuse, unchanged.

### 0.8 The "reorder ops" the tree actually has (repo)

There is **no `reorderable` prop and no `MoveRequested` occurrence in the tree
today** (grepped: `reorderable` appears only in DESIGN.md's tabs prose and in a
GTK `GtkColumnView:reorderable` quote inside docs/probes/table-overflow-2026.md;
`MoveRequested` appears nowhere). What exists is the model-side move:

- `crates/kaya/src/spec.rs` tx record **kind 15 `collection_move`**
  `{collection_id, path, key, before}` — "Move an entry so it sits before the
  entry whose key is the one value in `before`, or to the end when `before` is
  empty. **Keys, never indices**: order is data, and indices would race the very
  deltas that change them."
- The 21 occurrences today are: button_clicked, text_changed, toggled,
  value_changed, close_requested, window_closed, alert_result, entry_popped,
  back_requested, section_selected, menu_activated, menu_toggled,
  menu_value_changed, file_dialog_result, clipboard_result, pasted, undone,
  redone, sort_requested, draw_requested, tick. **A drop/move occurrence would be
  #22.** `sort_requested` is the closest precedent in shape: the toolkit asks,
  the app decides, the app writes the model.
- docs/deferred.md 2440 records a deliberate residual: the reorder scene asserts
  child order at the app's mirror, not at the toolkit, and "an undo's re-insert
  and re-order travel the same `apply_delta` path the reorder scene already
  exercises at the toolkit."

So the shape a future `reorderable` prop would take is already implied: a
`MoveRequested`-style occurrence carrying (moved key, before-key) — the exact
argument tuple of `collection_move` — and the app answering by issuing
`collection_move`. That is `sort_requested`'s request/answer grammar, and it is
the same "core defaults to doing nothing, app decides" shape DESIGN.md's window
close veto uses.

---

## 1. Android: the View-level floor (what everything else lowers to)

### 1.1 Starting a drag

`View.startDragAndDrop(ClipData data, View.DragShadowBuilder shadowBuilder, Object myLocalState, int flags)`
(API 24+; `startDrag` before that). [web]

- **`ClipData`** is the payload — the *same* class the clipboard uses. Its
  `ClipDescription` carries the label and the MIME type array. This is why
  docs/clipboard-plan.md could say "paste and drop are the same event": on Android
  they are literally the same type.
- **`myLocalState`** is an in-process Object handed back through
  `DragEvent.getLocalState()`. It never crosses a process boundary — the
  same-app fast path for "which row is this".
- **`DragShadowBuilder`** draws the floating image. Two constructors:
  `DragShadowBuilder(View)` reproduces the view's appearance centred under the
  touch point, and the no-arg one requires you to override
  `onProvideShadowMetrics(Point outShadowSize, Point outShadowTouchPoint)` and
  `onDrawShadow(Canvas)` — "or you get an invisible drag shadow". [web]
- **Flags** (0 for none, OR-combined): `DRAG_FLAG_GLOBAL` — "a drag can cross
  window boundaries… all visible applications with targetSdkVersion >= N (24)
  will be able to participate in the drag operation and receive the dragged
  content. **If this is the only flag set, then the drag recipient will only have
  access to text data and intents contained in the ClipData object**";
  `DRAG_FLAG_GLOBAL_URI_READ` / `DRAG_FLAG_GLOBAL_URI_WRITE` — required in
  addition when the ClipData carries `content://` URIs needing a permission
  grant; `DRAG_FLAG_GLOBAL_PERSISTABLE_URI_PERMISSION`,
  `DRAG_FLAG_GLOBAL_PREFIX_URI_PERMISSION`; `DRAG_FLAG_OPAQUE` — "the drag shadow
  will be opaque, otherwise it will be semitransparent". [web]

### 1.2 The event stream and its boolean returns

`View.OnDragListener.onDrag(View, DragEvent)` / `View.onDragEvent(DragEvent)`,
dispatched on the UI thread. [web]

| Action | Contract |
|---|---|
| `ACTION_DRAG_STARTED` | **Return `true` to register** and keep receiving events; `false` opts this view out of the whole session until `ACTION_DRAG_ENDED`. Only `getClipDescription()` (the MIME list) is available — not the data. |
| `ACTION_DRAG_ENTERED` | shadow entered the view's bounds |
| `ACTION_DRAG_LOCATION` | shadow still inside, with x/y |
| `ACTION_DRAG_EXITED` | shadow left the bounds |
| `ACTION_DROP` | released over this view. **`getClipData()` is valid only here.** Return `true` if the drop was processed, `false` otherwise. Only sent to views that returned `true` for `ACTION_DRAG_STARTED`. |
| `ACTION_DRAG_ENDED` | session over, wherever it ended. `getResult()` returns exactly the boolean the drop target returned for `ACTION_DROP`, and `false` if no `ACTION_DROP` was ever sent. |

**This is the hover-acceptance shape DESIGN.md predicted.** `ACTION_DRAG_STARTED`
carries the `ClipDescription` (the MIME vocabulary) and *not* the data, and the
accept decision is that one boolean. Android's own docs say to decide it from
`clipDescription.hasMimeType(...)` — i.e. from a pre-pushed vocabulary of
accepted types. kaya's "hover acceptance is answered from a pre-pushed vocabulary
of accepted types" is Android's literal API.

**But Android has NO operation vocabulary.** There is no copy/move/link mask
anywhere in the View drag API: no `effectAllowed`, no `dropEffect`, no
`DragDropEffects`. The whole verdict channel is one `boolean`. Anything
operation-shaped has to be carried by the app inside the `ClipData` or the
`localState`, or negotiated out of band. This is the sharpest divergence from
every other platform in part B.

### 1.3 THE DROP VERDICT: what Android actually charges (the key finding)

**The verdict is synchronous, and the platform itself already implements kaya's
bounded wait — with a 5-second ceiling and a real return-to-source animation.**

From AOSP `services/core/java/com/android/server/wm/DragDropController.java`: [web]

```java
static final long DRAG_TIMEOUT_MS = 5000;
...
case MSG_DRAG_END_TIMEOUT: {
    final IBinder win = (IBinder) msg.obj;
    if (DEBUG_DRAG) Slog.w(TAG_WM, "Timeout ending drag to win " + win);
    synchronized (mService.mGlobalLock) {
        // !!! TODO: ANR the drag-receiving app
        if (mDragState != null) {
            mDragState.endDragLocked(false /* consumed */,
                    false /* relinquishDragSurfaceToDropTarget */);
        }
    }
    break;
}
```

The window manager posts the drop to the target window and starts a 5 s timer; the
app's `ViewRootImpl` reports the listener's boolean back through
`reportDropResult`, which cancels the timer. If nothing is reported in 5 s the
drag ends **not consumed**, exactly kaya's "expiry rejects the drop".

And AOSP `DragState.java` supplies the snap-back: [web]

```java
private static final long MIN_ANIMATION_DURATION_MS = 195;
private static final long MAX_ANIMATION_DURATION_MS = 375;
...
if (!mDragResult) {
    if (!isAccessibilityDragDrop() && !relinquishDragSurfaceToDragSource()) {
        mAnimator = createReturnAnimationLocked();
        return;  // Will call closeLocked() when the animation is done.
    }
}
closeLocked();
```

`createReturnAnimationLocked()` animates the drag surface **back to its origin**
when the drop was not consumed, over a distance-scaled 195–375 ms;
`createCancelAnimationLocked()` scales-and-fades to nothing when the drag is
cancelled outright. So:

- **kaya half 1 (hover acceptance from a pre-pushed vocabulary): Android honours
  it exactly.** No app hop is needed at `ACTION_DRAG_STARTED`; the core can answer
  from the widget's declared accept list, which is the same list `accepts` already
  holds for paste.
- **kaya half 2 (a bounded wait on the drop verdict): Android honours it, and
  bounds it FOR you at 5000 ms.** kaya's own deadline must therefore be
  *strictly less* than 5 s, or the platform's timeout fires first and kaya's
  never does — the same shape as the harness ceiling rule. A margin under
  ~4 s is the safe budget.
- **kaya half 3 (expiry rejects and the drag snaps back): Android does this
  itself, for free, in the window manager, with a real animation.** kaya's stated
  degradation is not something the Android backend has to synthesise — it is what
  the platform does when the backend simply reports `false`.
- **Can the verdict be deferred?** No. `onDrag` returns a `boolean` on the UI
  thread and `ViewRootImpl` reports it immediately; there is no promise, no
  "I'll tell you later", no async completion object anywhere in the API.
  Blocking inside `onDrag` is the only way to take time, and that is precisely
  the bounded wait kaya's architecture already performs — with the platform's own
  5 s cap and a `// !!! TODO: ANR the drag-receiving app` comment sitting over it.
  **NOTE the second-order cost:** blocking the Android UI thread inside `onDrag`
  also stalls the drag animation for other windows, so the wait wants to be short
  (tens of ms in the healthy case) rather than merely under 5 s.

### 1.4 Cross-app and content URIs

- Cross-app drags need `DRAG_FLAG_GLOBAL`, and only work where two apps are
  visible at once — multi-window/split-screen, freeform, tablets, ChromeOS,
  desktop windowing. On a phone in full-screen there is nothing to drop onto, so
  a "global" drag is a same-app drag in practice.
- With `DRAG_FLAG_GLOBAL` alone the recipient gets **text and intents only**. Any
  `content://` URI additionally needs `DRAG_FLAG_GLOBAL_URI_READ`, and the
  receiver must call
  `activity.requestDragAndDropPermissions(dragEvent)` → `DragAndDropPermissions`,
  use the URI, then `permission.release()`. Compose's own docs show exactly this
  inside `onDrop`. [web]
- **This lands squarely on kaya's existing image/custom lowering.** The Compose
  backend already serves images and custom payloads as `content://` URIs from
  `KayaClipProvider` (repo, `kayaCopyToClipboard`), so a kaya drag payload is the
  same ClipData construction plus these two flags plus a `release()` in the
  receiving arm.

## 2. Android: Compose Foundation

### 2.1 The two modifiers

```kotlin
// receiving
fun Modifier.dragAndDropTarget(
    shouldStartDragAndDrop: (startEvent: DragAndDropEvent) -> Boolean,
    target: DragAndDropTarget,
): Modifier
```
`shouldStartDragAndDrop` is `ACTION_DRAG_STARTED`'s boolean, one level up, and the
canonical body is a MIME test:
`event.mimeTypes().contains(ClipDescription.MIMETYPE_TEXT_PLAIN)`. [web]

```kotlin
interface DragAndDropTarget {
    fun onStarted(event: DragAndDropEvent) {}
    fun onEntered(event: DragAndDropEvent) {}
    fun onMoved(event: DragAndDropEvent) {}
    fun onExited(event: DragAndDropEvent) {}
    fun onChanged(event: DragAndDropEvent) {}
    fun onDrop(event: DragAndDropEvent): Boolean   // the only non-default member
    fun onEnded(event: DragAndDropEvent) {}
}
```
One-to-one with the `DragEvent` actions; `onDrop`'s `Boolean` IS `ACTION_DROP`'s.
The target must be `remember`ed. `event.toAndroidDragEvent()` drops to the
platform event (needed for `clipData` and for `requestDragAndDropPermissions`). [web]

```kotlin
// sending — the API in Compose 1.7.x (what this repo pins)
fun Modifier.dragAndDropSource(
    block: suspend DragAndDropSourceScope.() -> Unit
): Modifier
fun Modifier.dragAndDropSource(
    drawDragDecoration: DrawScope.() -> Unit,
    block: suspend DragAndDropSourceScope.() -> Unit
): Modifier
```
`DragAndDropSourceScope` is a `PointerInputScope` with `startTransfer(...)`, so
**the app chooses the start gesture**. Google's own codelab uses a long press: [web]
```kotlin
Modifier.dragAndDropSource {
    detectTapGestures(onLongPress = {
        startTransfer(DragAndDropTransferData(ClipData.newPlainText("image uri", url)))
    })
}
```
`detectDragGesturesAfterLongPress` is the other common body when the source also
wants the drag offsets.

Both of these are **deprecated in current Compose** in favour of a
Compose-owns-the-gesture form: [web]
```kotlin
fun Modifier.dragAndDropSource(
    transferData: (Offset) -> DragAndDropTransferData?
): Modifier
fun Modifier.dragAndDropSource(
    drawDragDecoration: DrawScope.() -> Unit,
    transferData: (Offset) -> DragAndDropTransferData?
): Modifier
```
with the deprecation message "Replaced by overload with a callback for obtain a
transfer data, **start detection is performed by Compose itself**". So the newer
API takes the start-gesture decision away from the app and gives Compose the
mobile idiom (long press) by default.

`DragAndDropTransferData(clipData, localState, flags)` is the wire: it is
literally `startDragAndDrop`'s three non-shadow arguments, and `flags` takes
`View.DRAG_FLAG_GLOBAL` etc. `drawDragDecoration: DrawScope.() -> Unit` is
`DragShadowBuilder.onDrawShadow` in Compose's idiom.

### 2.2 Version reality for THIS repo

`android/kaya/build.gradle.kts` pins `platform("androidx.compose:compose-bom:2024.10.01")`
and the file's own comment states that BOM "would supply 1.7.5" for the icon
modules — so **Compose Foundation 1.7.5**, `compileSdk 35`, `minSdk 26`. [repo]

- The DnD modifiers were **introduced in Compose 1.6** (Jan 2024) and are
  `@ExperimentalFoundationApi`. [web]
- 1.7.x is the generation with `dragAndDropTarget(shouldStartDragAndDrop, target)`
  and the `suspend DragAndDropSourceScope.() -> Unit` source — i.e. **everything
  kaya needs is already on the pinned classpath**, no dependency move.
- The `transferData` overloads (Compose owns the start gesture) are the *later*
  spelling; taking them means moving the BOM, which the build file's comments
  show is a considered decision here (material3-adaptive and the icons are
  already pinned outside the BOM).
- Compose 1.10.0-alpha01 removed a `DragGesturePickUpEnabled` flag — the start
  gesture is still being tuned upstream. [web]

### 2.3 Android's own "paste and drop are the same event", in the framework source

`View.onDragEvent`'s default implementation (AOSP `core/java/android/view/View.java`): [web]

```java
public boolean onDragEvent(DragEvent event) {
    if (mListenerInfo == null || mListenerInfo.mOnReceiveContentListener == null) return false;
    // Accept drag events by default if there's an OnReceiveContentListener set.
    if (event.getAction() == DragEvent.ACTION_DRAG_STARTED) return true;
    if (event.getAction() == DragEvent.ACTION_DROP) {
        final DragAndDropPermissions permissions = DragAndDropPermissions.obtain(event);
        if (permissions != null) permissions.takeTransient();
        final ContentInfo payload = new ContentInfo.Builder(event.getClipData(),
                SOURCE_DRAG_AND_DROP).setDragAndDropPermissions(permissions).build();
        ContentInfo remainingPayload = performReceiveContent(payload);
        return remainingPayload != payload;   // true unless nothing was consumed
    }
    return false;
}
```

So a View that declared an `OnReceiveContentListener` — the very API
docs/clipboard-plan.md cites for `accepts` — **automatically** accepts the drag
session, takes the URI permissions, and routes the drop into the same
`performReceiveContent` that paste uses, tagged `SOURCE_DRAG_AND_DROP`. The
"third trigger, same payload" claim is not an analogy on Android; it is the
default implementation.

### 2.4 The other Android drag flags worth knowing (AOSP View.java) [web]

- `DRAG_FLAG_GLOBAL_URI_READ` / `_WRITE` are literally
  `Intent.FLAG_GRANT_READ_URI_PERMISSION` / `_WRITE_`, plus
  `_PERSISTABLE_URI_PERMISSION` and `_PREFIX_URI_PERMISSION`.
- `DRAG_FLAG_ACCESSIBILITY_ACTION` (1<<10) — "the drag was initiated with
  `AccessibilityNodeInfo.AccessibilityAction.ACTION_DRAG_START`… this is used by
  the system to perform a drag **without animations**." **There is an
  accessibility route into drag and drop**, `ACTION_DRAG_START` /
  `ACTION_DRAG_DROP` / `ACTION_DRAG_CANCEL`, which matters to a project whose
  a11y invariant is that native widgets ARE the tree.
- `DRAG_FLAG_GLOBAL_SAME_APPLICATION` (1<<12) — cross-window but same UID.
- `DRAG_FLAG_START_INTENT_SENDER_ON_UNHANDLED_DRAG` (1<<13) — hand an unhandled
  drag to the system to launch an activity.
- `DRAG_FLAG_REQUEST_SURFACE_FOR_RETURN_ANIMATION` (1<<11, @hide) — its javadoc
  is the plainest statement of the snap-back: the caller may take the drag
  surface "if the view starting a global drag changes visibility during the
  gesture and **the default animation of animating the surface back to the
  origin** is not sufficient", delivered on `ACTION_DRAG_ENDED` "only if the drag
  event's `getDragResult()` is `false`".

### 2.5 Payload representations, mapped to kaya's grammar

| kaya rep | Android drag carriage | Notes |
|---|---|---|
| `text` | `ClipData.Item(CharSequence)`, `MIMETYPE_TEXT_PLAIN` | free, no flags |
| `html` | the SAME `ClipData.Item(text, htmlText)`, `MIMETYPE_TEXT_HTML` | Android's item holds text and html together — one item, two mimes; kaya's backend already does this |
| `image` | `ClipData.Item(Uri)` + a `ContentProvider` | **cannot be bytes**; needs `DRAG_FLAG_GLOBAL_URI_READ` cross-app, plus `requestDragAndDropPermissions` + `release()` on the receiving side |
| `files` | `ClipData.Item(Uri)` per file, `MIMETYPE_TEXT_URILIST` | same shape as the picker's capability |
| `custom(id, bytes)` | `ClipData.Item(Uri)` into `KayaClipProvider` under the custom mime id | id is already MIME-shaped by kaya's rule, so it goes straight into `ClipDescription` |

Two structural notes:

1. **`ClipDescription` is a LIST of MIME types on ONE description, and `ClipData`
   is a LIST of items.** kaya's "one clip, several representations" maps onto the
   description; kaya's "no multiple items per clip" ruling means the item list is
   used only as the several representations' carriage, exactly as
   `kayaCopyToClipboard` already does. **No new decision is needed here.**
2. **Hover only sees the `ClipDescription`.** `getClipData()` "only returns valid
   data if the event action is `ACTION_DROP`". So kaya's "fetching drag content
   mid-hover is discouraged everywhere" is, on Android, *forbidden*: the data does
   not exist before the drop. Pre-pushed accept vocabulary is the only shape
   Android allows.

## 3. Reorder inside a LazyColumn, and the mobile idiom

**`dragAndDropSource/Target` is NOT what anyone uses to reorder a list.** [web]
The two modifiers are a *data transfer* API (ClipData in, ClipData out); a reorder
is a *positional* gesture that needs live index math and item animation, and the
DnD modifiers give neither. The field has settled on gesture libraries:

- `sh.calvin.reorderable` (Calvin-LL/Reorderable) — `rememberReorderableLazyListState { from, to -> ... }` with an `onMove(from, to)` callback, a
  `ReorderableItem` wrapper, drag handles, haptics, and `Modifier.animateItem()`
  for the shuffle. Works on Compose Multiplatform.
- `org.burnoutcrew.composereorderable` (aclassen/ComposeReorderable) — the older
  one; `reorderable()` + `detectReorderAfterLongPress()`.
- Hand-rolled: `Modifier.pointerInput { detectDragGesturesAfterLongPress(...) }`
  plus `LazyListState.layoutInfo.visibleItemsInfo` to find the hovered index, and
  `scrollBy` for edge auto-scroll.

Three consequences for kaya:

- **Reorder and cross-widget drop are two different features on Android**, and
  only the second is `dragAndDropSource/Target`. A `reorderable` prop on a
  collection would be lowered to a gesture, not to `startDragAndDrop`, on Compose.
  (On GTK4 and WinUI it can genuinely be the DnD framework; on SwiftUI it is
  `.onMove` on a `List`, again a different API from `.draggable`/`.dropDestination`.)
  That split is worth a ruling, because it decides whether kaya has ONE feature
  with two lowerings or TWO features.
- The occurrence a reorder wants is `(moved key, before key)` — which is exactly
  `collection_move`'s argument tuple, and `onMove(from, to)` in every library is
  index-shaped, so the backend does the index→key resolution. kaya's "keys, never
  indices" rule already says which side that conversion lives on.
- **Long press is the mobile start gesture and press-and-move is the desktop one.**
  Android's own `input draganddrop` bakes a long press in (§4), Google's codelab
  uses `detectTapGestures(onLongPress)`, and the newer Compose API makes long-press
  start detection Compose's own job. On the desktop backends a drag starts after a
  small movement threshold with the button down. A uniform kaya spelling therefore
  cannot name the gesture; it can only name the *affordance* (this widget is a drag
  source), and each backend picks its platform's start gesture — which is exactly
  invariant 1's "idiom decides the spelling, never the semantics".

## 4. Harness observability on the emulator

### 4.1 `adb shell input draganddrop` — confirmed, and it is a long-press swipe

AOSP `services/core/java/com/android/server/input/InputShellCommand.java`: [web]

```java
private void runDragAndDrop(int inputSource, int displayId) {
    inputSource = getSource(inputSource, InputDevice.SOURCE_TOUCHSCREEN);
    sendSwipe(inputSource, displayId, true);   // isDragDrop = true
}
```
Usage line: `draganddrop <x1> <y1> <x2> <y2> [duration(ms)] (Default: touchscreen)`.
Default duration 300 ms. With `isDragDrop` true the injected sequence is:
**ACTION_DOWN at (x1,y1) → sleep `ViewConfiguration.getLongPressTimeout()` (~500 ms)
→ interpolated ACTION_MOVEs at ~120 Hz → ACTION_UP at (x2,y2)**.

**So it injects TOUCH events, not drag events.** It does not call
`startDragAndDrop`; it produces the gesture that makes an app call it. That is
good news for a kaya leg — it exercises the whole real path, source gesture
included — and it means:
- the duration must exceed the long-press timeout comfortably; the AOSP sleep is
  already the long-press timeout, so `duration` is the *move* time. 1500 ms is a
  safe, slow, watchable move.
- `input swipe x y x y 1500` (the degenerate same-point swipe the repo already
  uses in `tools/android/undoprobe/run.sh` for long presses) is the fallback and
  is exactly what `draganddrop` does for its first phase.
- Android is the EASY lane for this. The hard one is iOS: docs/deferred.md's
  "CHORE — SYNTHESIZING A PAN INTO THE iOS SIMULATOR (2026-08-30)" records that
  **no host-driven pan reaches the simulator's device content today** — synthetic
  CGEvents are ignored by the content view, nixpkgs' idb-companion crashes on
  attach, and simdrive's own `swipe` (down + interpolated down-state + up) "does
  NOT read as a pan: a SwiftUI vertical scroll does not move", with
  `IndigoHIDMessageForScrollEvent` probed and no permutation working. The entry's
  stated guaranteed path is "a resident XCUITest driver (XCUICoordinate
  press/drag) … a small runner app in tools/ios beside simdrive". **A drag
  feature is exactly the "need bigger than screenshot framing" that entry says
  would justify building it** — so an iOS drag leg carries that cost, and it
  should be priced into any build order before the feature is admitted. [repo]

Availability: the command lives in the platform `input` shell command. It is
present on modern API levels (the repo's emulator is API 35, `compileSdk 35`), so
this is not a constraint in practice; the "Android 7+ / Android 12+" claims found
in third-party write-ups disagree with each other and neither is worth relying on
— the honest statement for a plan is "present on API 35, verify with
`adb shell input` (no args prints the usage)".

### 4.2 What the repo's Compose harness does today, and what a drag verb would cost

`KayaCompose.kt`'s `"click"` verb does **not** synthesise input at all: it resolves
the target in the scene model and calls `KayaPresent.emitClicked(it.tag)` on the
UI thread, i.e. it emits the occurrence directly. [repo] The same file's a11y
verbs read the real semantics tree, and `header_click`, `toggle`, `set_value` are
all model-side emits.

Three candidate drivers for a drag verb, worst to best:

1. **Model-side emit** (today's `click` shape): call the `DragAndDropTarget`'s
   `onDrop` (or just emit the drop occurrence). Cheapest, uniform with every other
   verb — and **it proves nothing about the platform**: it cannot catch a wrong
   `ClipData` lowering, a missing `DRAG_FLAG_GLOBAL_URI_READ`, or a
   `shouldStartDragAndDrop` that rejects. This is the same objection
   docs/clipboard-plan.md already sustained against an in-process clipboard read
   ("shipping the verification that cannot fail for the reason we care about is
   worse than shipping nothing").
2. **Synthetic `DragEvent` into `View.dispatchDragEvent`.**
   `public boolean dispatchDragEvent(DragEvent event)` IS public API, and
   `DragEvent implements Parcelable` with public `writeToParcel`/`CREATOR`. But
   the full-parameter `DragEvent.obtain(...)` is `/** @hide */`, so there is no
   supported way to *construct* one — only reflection into a hidden method (blocked
   since API 28) or hand-writing a Parcel in the undocumented field order. Not a
   wall a lane should stand on.
3. **Host-side `adb shell input draganddrop x1 y1 x2 y2 <ms>`.** Drives the real
   gesture, the real `startDragAndDrop`, the real window-manager session, the real
   `ACTION_DROP`. Costs the harness a coordinate, which is the thing the whole
   harness is designed to avoid — every other verb addresses widgets by a11y id.
   **The bridge already exists in the tree**: `kayaSemanticsByTag` /
   `kayaAxFind` resolve a testTag to a `SemanticsNode`, and a SemanticsNode has
   `boundsInWindow`, so the harness can answer "where is `button@x`" and a
   *runner-side* verb can turn two a11y ids into two centre points. That keeps the
   .steps file id-addressed (invariant 6, scripts shared verbatim) while the
   gesture stays real.

**What a verb can assert byte-identically.** The drop's occurrence payload is the
right observable, and it is already a frozen-string shape kaya knows how to
compare: the same closed representation sum `on_paste` delivers. A `expect_drop`
naming `(target, representation, value)` reads identically on five platforms
because the representation set is closed and the values are the guest's own
strings. The *positions* are what differ per platform and must stay out of the
verdict — which is the table-tier lesson (decision 5) one feature over.

---

# PART B — how other cross-platform toolkits shape the API

## B1. Flutter (in-framework: `Draggable` / `DragTarget`)

```dart
Draggable<T>({ required Widget child, required Widget feedback, T? data,
  Widget? childWhenDragging, Axis? axis, Axis? affinity,
  DragAnchorStrategy dragAnchorStrategy = childDragAnchorStrategy,
  int? maxSimultaneousDrags, VoidCallback? onDragStarted,
  DragUpdateCallback? onDragUpdate, DraggableCanceledCallback? onDraggableCanceled,
  DragEndCallback? onDragEnd, VoidCallback? onDragCompleted, ... })

DragTarget<T>({ required DragTargetBuilder<T> builder,
  DragTargetWillAcceptWithDetails<T>? onWillAcceptWithDetails,
  DragTargetAcceptWithDetails<T>? onAcceptWithDetails,
  DragTargetMove<T>? onMove, DragTargetLeave<T>? onLeave, ... })
```
[web] The payload is a **Dart generic `T`, not a serialised representation** — this
is in-app only, and the type parameter *is* the accept filter (a `DragTarget<Foo>`
never sees a `Draggable<Bar>`). `onWillAcceptWithDetails` is hover acceptance
(synchronous bool), `onAcceptWithDetails` is the drop, `builder(context,
candidateData, rejectedData)` re-renders the target with the accepted and rejected
payloads in hand — Flutter's answer to "hover feedback" is to give the target the
data, which is possible only because nothing crosses a process boundary.
`LongPressDraggable` is the mobile-idiom subclass. **No operation vocabulary at
all** (no copy/move/link), and **no OS integration**: none of this can leave the
Flutter view. `onDragCompleted` vs `onDraggableCanceled` is how the source learns
the outcome. Flutter's snap-back is `feedback` simply disappearing plus whatever
the app animates.

## B2. Flutter, OS-level (`super_drag_and_drop`, `desktop_drop`)

`super_drag_and_drop` is the package that adds what the framework lacks, on macOS,
iOS, Android, Windows, Linux and Web. [web] `DragItemWidget(dragItemProvider:
(request) async => DragItem(...))` — the provider returns `null` to refuse the
drag; `item.add(Formats.plainText('...'))`, `Formats.htmlText`, `Formats.png`,
`Formats.fileUri`, `SimpleFileFormat` / `CustomValueFormat` for custom types, and
`addVirtualFile()` for files that do not exist yet. **Lazy data is first-class:**
`Formats.htmlText.lazy(() => '<b>…</b>')` defers the value until a consumer asks.
Receiving is `DropRegion(formats: [...], onDropOver: (event) => DropOperation.copy,
onDropEnter:, onDropLeave:, onPerformDrop: (event) async { … item.dataReader … })`.
**`onDropOver` returns a `DropOperation`** — this is the "hover answers an
operation" shape, and note it returns synchronously while `onPerformDrop` is
`async`: the package splits the verdict (sync) from the data fetch (async), which
is precisely kaya's decision/content split.

## B3. Qt (`QDrag` / `QMimeData`)

```cpp
QDrag *drag = new QDrag(this);
QMimeData *mime = new QMimeData;
mime->setText(...); mime->setData("application/x-myapp", bytes);
drag->setMimeData(mime); drag->setPixmap(pix); drag->setHotSpot(pt);
Qt::DropAction result = drag->exec(Qt::CopyAction | Qt::MoveAction, Qt::MoveAction);
```
[web] `exec()` **blocks** and returns the action that actually happened — the source
learns the outcome as a return value, and for `Qt::MoveAction` it is the source's
job to delete the original afterwards. Receiving: `setAcceptDrops(true)` then
`dragEnterEvent(QDragEnterEvent*)`, `dragMoveEvent`, `dragLeaveEvent`,
`dropEvent(QDropEvent*)`. The target inspects `event->mimeData()->hasFormat(...)`
and calls `event->acceptProposedAction()` or `event->setDropAction(Qt::MoveAction);
event->accept()`. `Qt::CopyAction | MoveAction | LinkAction | IgnoreAction`;
`possibleActions()` is the source's mask, `proposedAction()` the current proposal.
**Lazy data is `QMimeData` subclassing**: override `formats()` and
`retrieveData(mimeType, type)` and the bytes are produced only when asked — the
same trick as `IDataObject::GetData`.

## B4. Avalonia

```csharp
[Obsolete("Use DoDragDropAsync instead.")]
public static Task<DragDropEffects> DoDragDrop(PointerEventArgs triggerEvent,
                                               IDataObject data,
                                               DragDropEffects allowedEffects);
```
[web] The source passes an **allowed-effects mask** and awaits the effect that
happened. Targets set the attached property `DragDrop.AllowDrop="True"` and handle
the attached routed events `DragDrop.DragEnterEvent`, `DragOverEvent`,
`DragLeaveEvent`, `DropEvent`; in `DragOver` the handler writes
`e.DragEffects` to pick the operation (and thereby the cursor), and in `Drop` it
writes `e.DragEffects` again to say what actually happened. Data is `IDataObject` /
`DataObject` keyed by `DataFormats.Text`, `DataFormats.Files`, or an app string.
Current Avalonia is migrating to `DoDragDropAsync` + a `DataTransfer` object.
Shape-wise this is WPF/WinForms' model, which is COM `IDataObject`'s model, which
is where "source mask ∩ target choice" comes from.

## B5. GTK4

Uniform across GTK's backends by construction — X11, Wayland, Windows and macOS all
sit under one GDK abstraction, which is the thing kaya is trying to be. Source:
`GtkDragSource` (an event controller added with `gtk_widget_add_controller`), whose
**`prepare(x, y)` signal returns a `GdkContentProvider`** — or `NULL` to cancel —
plus `drag-begin` (set the icon), `drag-cancel`, and `drag-end` (**where a
`GDK_ACTION_MOVE` source deletes the original**). `gtk_drag_source_set_actions()`
is the mask. Target: `gtk_drop_target_new(GType type, GdkDragAction actions)`, with
`accept`, `enter`, `motion` (**returns the `GdkDragAction` this target will
perform** — hover answers an operation), `leave`, and `drop` (**returns `gboolean`**).
`gtk_drop_target_set_gtypes()` is the accept list. `GdkDragAction` is
`COPY | MOVE | LINK | ASK`. [web]

Two GTK details a kaya design should notice:
- The **`preload` property** on `GtkDropTarget` is the explicit knob for "load the
  data on hover rather than at drop". GTK made that a *choice*, defaulting off —
  which is the same conclusion DESIGN.md reached ("fetching drag content mid-hover
  is discouraged everywhere").
- **`GtkDropTargetAsync` exists** for targets that need full asynchronous control
  of the drop. So GTK is the one desktop toolkit that offers a genuinely deferred
  verdict — the opposite end from Android's synchronous boolean.
- `GdkContentProvider` is the lazy-data object (a provider can write a mime type
  asynchronously on demand), the direct analogue of `IDataObject::GetData` and
  `NSPasteboardItemDataProvider`.

## B6. Web / Electron

HTML5: `draggable="true"`, then `dragstart` (source; **the only event where
`dataTransfer.setData(type, value)` may be called**), `dragenter` / `dragover`
(target; **must call `preventDefault()` or the element is not a drop target at
all**), `dragleave`, `drop` (**the only event where `getData()` returns anything —
"protected mode"**), `dragend` (source, always, carrying the final `dropEffect`).
[web] Operations: the source sets `effectAllowed` in `dragstart` (`none`, `copy`,
`move`, `link`, `copyMove`, `copyLink`, `linkMove`, `all`, `uninitialized`); the
target sets `dropEffect` in `dragover`/`dragenter` (`copy`, `move`, `link`,
`none`); the user's modifier keys bias it; the browser honours the intersection.
`setDragImage(el, x, y)` is the preview. **The verdict cannot be asynchronous** —
"no promises, async operations, or delayed decisions are supported in the
specification"; a drop that is not `preventDefault`ed simply fails and `dragend`
reports `dropEffect: "none"`.

Electron adds the **OS-level** half the web platform lacks:
`webContents.startDrag({ file: '/path', icon: '/path/icon.png' })` (or `files: []`),
called **in the main process, in response to the renderer's `ondragstart` after
`preventDefault()` and an `ipcRenderer.send`**. [web] It is file-only — Electron
does not expose a general OS drag payload — so an Electron app's rich drag is
in-page HTML5 and its outward drag is files.

## B7. React Native

**No built-in drag and drop API of any kind.** [web] Everything is
`PanResponder` or `react-native-gesture-handler` + `react-native-reanimated`,
with third-party layers (`react-native-reanimated-dnd`, various sortable-list
packages) on top. That means: no OS payload model, no operation vocabulary, no
cross-app drag, and the "drop target" is whatever hit-testing the app writes
itself. Worth naming in a design pass only as the counter-example — the framework
kaya's DESIGN.md already cites for getting the async boundary wrong is also the
one that never built this feature.

## B8. .NET MAUI

Two gesture recognizers added to a view's `GestureRecognizers`: [web]
- `DragGestureRecognizer` — `CanDrag` (bool, default true), `DragStarting` /
  `DragStartingCommand` with `DragStartingEventArgs { Cancel, Data: DataPackage,
  PlatformArgs }`, and `DropCompleted` / `DropCompletedCommand` so the source
  learns the outcome.
- `DropGestureRecognizer` — `AllowDrop` (bool, default true), `DragOver` /
  `DragLeave` (`DragEventArgs { Data: DataPackage, AcceptedOperation, PlatformArgs }`)
  and `Drop` (`DropEventArgs { Data: DataPackageView, Handled: bool, PlatformArgs }`).
- `DataPackage` has typed `Text` and `Image` properties plus a
  `DataPackagePropertySet` (a `Dictionary<string,object>` property bag);
  `DataPackageView` is the read-only view handed to the receiver. MAUI
  auto-populates the package for image and text controls.
- **`DataPackageOperation` has exactly two members: `None` and `Copy`** (default
  `Copy`). MAUI deliberately did not attempt a cross-platform move/link
  vocabulary — the most direct evidence available that a five-platform toolkit
  found the operation mask not worth unifying.
- `PlatformArgs` is the escape hatch on every event args type
  (`PlatformDragEventArgs.DragEvent` is literally `android.views.DragEvent`), i.e.
  MAUI's answer to divergence is a documented hole rather than a lowest common
  denominator.

---

# PART C — the common model, and where the toolkits disagree

## C1. The five-step model every one of them has

1. **The source DECLARES**: a payload (typed object, or a set of typed
   representations), an allowed-operation mask, and a drag preview.
2. **The target DECLARES**: which types it accepts (and sometimes which
   operations).
3. **HOVER ANSWERS**: continuously, whether this target will take it and
   (usually) with which operation. Nobody reads the payload's *bytes* here —
   several platforms forbid it.
4. **DROP DELIVERS**: the data plus the chosen operation, once, at one target.
5. **THE SOURCE LEARNS THE OUTCOME**: so a `move` can delete the original.

kaya's DESIGN.md paragraph covers 3 and 4 and is silent on 1, 2 and 5. **Step 5 is
the one with teeth**, because DESIGN.md's own blocking policy names it: "accepting
a 'move' drop causes the source to delete the original." Every toolkit here gives
the source that signal — Qt as `exec()`'s return, Avalonia as the awaited
`DragDropEffects`, GTK as `drag-end`, HTML5 as `dragend`'s `dropEffect`, MAUI as
`DropCompleted`, Flutter as `onDragCompleted`/`onDraggableCanceled`, Android as
`ACTION_DRAG_ENDED` + `getResult()`. A kaya design that omits it makes `move`
unimplementable.

## C2. Where "which operation" is decided

| Toolkit | Who proposes | Who decides | Vocabulary |
|---|---|---|---|
| HTML5 / Electron | source `effectAllowed` | target `dropEffect`, biased by modifier keys, browser takes the intersection | copy / move / link / none |
| Qt | source mask in `exec(supported, default)` | target via `setDropAction` / `acceptProposedAction` | Copy / Move / Link / Ignore |
| Avalonia (WPF lineage) | source `allowedEffects` | target writes `e.DragEffects` in DragOver **and again in Drop** | Copy / Move / Link / None (+ combos) |
| GTK4 | source `gtk_drag_source_set_actions` | target returns a `GdkDragAction` from `motion` | COPY / MOVE / LINK / **ASK** |
| macOS/iOS (for reference) | source's `NSDraggingSession` / `UIDragItem` | target returns an `NSDragOperation` / `UIDropProposal` | copy / move / link / generic / delete |
| .NET MAUI | — | target sets `AcceptedOperation` | **None / Copy only** |
| Flutter (framework) | — | — | **none** |
| **Android** | — | — | **none — one `boolean`** |

Two readings for the design pass:

- The **intersection model** (source mask ∩ target choice, user modifiers as a
  tiebreak) is the desktop consensus, and GTK's `ASK` is the honest admission that
  sometimes the *user* decides.
- **Android has no place to put it**, and MAUI — the only other project here that
  had to ship the same five platforms kaya does — responded by shrinking the
  vocabulary to `None | Copy`. If kaya wants copy/move/link uniformly, the Android
  lowering has to carry the operation **inside the payload** (a kaya-private
  entry in the `ClipDescription`, or `myLocalState` for same-app drags) and
  synthesise the badge itself, and the *cross-app* case then cannot be uniform at
  all, because a foreign Android app will never read that entry. That is a
  carve-out, and by the standing rule carve-outs go to the maintainer.

## C3. How each represents lazy data

- **Qt**: subclass `QMimeData`, override `retrieveData()`.
- **GTK4**: `GdkContentProvider`, including callback/async providers; plus
  `GtkDropTarget:preload` as the explicit hover-fetch switch.
- **Windows/Avalonia**: `IDataObject::GetData` — the receiving process blocks.
- **Apple**: `NSPasteboardItemDataProvider` / `NSFilePromiseProvider`,
  `UIDragItem`'s `itemProvider` (`NSItemProvider` load callbacks).
- **super_drag_and_drop**: `Format.lazy(() => value)` and `addVirtualFile()`.
- **HTML5**: none — `setData` is eager, in `dragstart`, and that is the whole API.
- **Android**: **none for bytes.** The lazy mechanism is a `content://` URI: the
  provider is asked for the stream when the receiver opens it, which is lazy in
  effect but only for things expressible as a stream.

DESIGN.md already calls source-side provision "demand with a generous deadline",
and docs/clipboard-plan.md already ruled **lazy rendering OUT** for the clipboard.
Android's shape says the ruling can hold for drag too at zero cost, because the
image and custom reps already go out as `content://` URIs that are read on demand
by construction.

## C4. Where the start gesture lives

| | start gesture |
|---|---|
| Android / Compose (new API) | Compose owns it; long press |
| Android / Compose (1.7, this repo's pin) | **the app owns it** — `dragAndDropSource { detectTapGestures(onLongPress = { startTransfer(...) }) }` |
| Flutter | `Draggable` (pan) vs `LongPressDraggable` — two widgets |
| Qt | app-written: `mousePressEvent` records, `mouseMoveEvent` past `startDragDistance()` calls `exec()` |
| Avalonia | app-written: from a pointer event, call `DoDragDrop(triggerEvent, …)` |
| GTK4 | `GtkDragSource` is a `GtkGestureSingle` — the controller owns it, tunable |
| HTML5 | the browser owns it (`draggable="true"`) |
| MAUI | the recognizer owns it |

The two ends are "the toolkit owns the gesture, the app declares an affordance"
(HTML5, MAUI, GTK, new Compose) and "the app writes the gesture" (Qt, Avalonia,
old Compose). **kaya has no gesture vocabulary and no wish for one**, so the
declare-an-affordance end is the only one available — which conveniently is where
every toolkit is drifting.

## C5. Straight answers to the three doctrine questions

**Can the Android drop verdict be deferred?** No. `onDrop`/`onDragEvent` returns a
`boolean` synchronously on the UI thread; `ViewRootImpl` reports it to the window
manager immediately; there is no completion object anywhere in the API. The only
way to take time is to block in the handler.

**How far can Android honour kaya's bounded wait?** Fully, and it enforces one
itself: `DragDropController.DRAG_TIMEOUT_MS = 5000`, after which the window
manager ends the drag `consumed = false` (with a live
`// !!! TODO: ANR the drag-receiving app` in the source). kaya's own deadline must
sit strictly inside that, and in practice should be far inside it, because the
blocked thread is the UI thread that is also animating the drag.

**Does the drag snap back?** Yes — and by the system, not the app.
`DragState.endDragLocked` selects `createReturnAnimationLocked()` whenever
`!mDragResult`, animating the drag surface back to its origin over 195–375 ms
scaled by distance (`createCancelAnimationLocked()` scales-and-fades for an
outright cancel). The hidden
`DRAG_FLAG_REQUEST_SURFACE_FOR_RETURN_ANIMATION` javadoc names it outright: "the
default animation of animating the surface back to the origin". So kaya's stated
degradation — "drop rejected; drag snaps back (retryable)" — is on Android
literally free: report `false` and the platform does the rest.

---

# PART D — what the maintainer actually has to rule

Written as questions, each with the fact that forces it. Nothing here is decided.

1. **Is drop a third trigger on `on_paste`, or its own occurrence?**
   docs/clipboard-plan.md already committed to the first, and Android's
   `View.onDragEvent` default implementation *literally* routes drop into
   `performReceiveContent` with `SOURCE_DRAG_AND_DROP`. Against it: a drop has a
   POSITION and a paste does not, and a drop can be refused while a paste cannot.
   The cheapest shape consistent with both is `on_paste`'s payload plus a
   drop-only trigger field, but that is a spec-hash move either way.

2. **Does kaya have an operation vocabulary (copy/move/link) at all?**
   The desktop four all have one; Android has none and MAUI shrank it to
   `None | Copy` for exactly this reason. Under invariant 1 this is either a
   uniform semantics with an Android carve-out stated uniformly, or no vocabulary
   at all. Note DESIGN.md's blocking policy already assumes `move` exists
   ("accepting a 'move' drop causes the source to delete the original").

3. **What does the source learn?** No current kaya occurrence tells a source
   anything after the fact. Without a drop-outcome occurrence, `move` cannot be
   implemented by a guest at all. Every toolkit surveyed has this signal.

4. **What is the bounded wait's number, and where is it enforced?**
   Android's system ceiling is 5000 ms. A kaya deadline of, say, 250 ms is inside
   every platform's own limit and keeps the UI thread free; the harness-ceiling
   gate's shape (one rule, all three harnesses, one flattened sentence) is the
   precedent for holding one number in several files.

5. **Is `reorderable` the same feature as drop, or a different one?**
   On Compose they are different APIs (`dragAndDropSource/Target` vs a
   long-press pan over `LazyListState`), on SwiftUI they are different
   (`.onMove` vs `.draggable`/`.dropDestination`), on GTK4 and WinUI they can be
   the same. If they are one kaya feature, four of five backends need two
   lowerings behind one prop.

6. **What does a reorder occurrence carry?** `collection_move`'s tuple —
   `(collection_id, path, key, before)` — is already the right shape and already
   says "keys, never indices". The libraries all hand you `(fromIndex, toIndex)`,
   so the index→key resolution is backend work, which is where kaya already puts
   it.

7. **Cross-app or same-app only for v1?** Same-app is uniform and testable on all
   five lanes. Cross-app on Android needs `DRAG_FLAG_GLOBAL` plus URI-permission
   flags plus a visible second window (so: tablet/desktop-windowing only), and on
   phones there is nothing to drop onto. A foreign-app drag witness would be the
   drag analogue of the clipboard helper APK that docs/clipboard-plan.md insisted
   on — and by that same argument ("a test where kaya reads what kaya wrote cannot
   catch a malformed lowering"), a same-app-only drag leg cannot validate the
   `ClipData` lowering at all.

8. **How is a drag DRIVEN in the harness, on each lane?** Android has
   `adb shell input draganddrop` (real gesture, real framework). iOS has nothing
   today and would need the XCUITest driver docs/deferred.md already scoped. The
   three desktop lanes each need their own answer. This is the admission gate:
   a feature whose legs cannot be driven on two of five lanes is a feature whose
   guard does not exist.

---

# Sources

Android / Compose
- https://developer.android.com/develop/ui/compose/touch-input/user-interactions/drag-and-drop
- https://developer.android.com/codelabs/codelab-dnd-compose
- https://developer.android.com/develop/ui/views/touch-and-input/drag-drop/concepts
- https://developer.android.com/develop/ui/views/touch-and-input/drag-drop/view
- https://developer.android.com/reference/android/view/DragEvent
- https://composables.com/docs/androidx.compose.foundation/foundation/modifiers/dragAndDropTarget
- https://composables.com/jetpack-compose/androidx.compose.foundation/foundation/modifiers/dragAndDropSource/api
- AOSP `core/java/android/view/View.java`, `core/java/android/view/DragEvent.java`,
  `services/core/java/com/android/server/wm/DragDropController.java`,
  `services/core/java/com/android/server/wm/DragState.java`,
  `services/core/java/com/android/server/input/InputShellCommand.java`
  (via https://raw.githubusercontent.com/aosp-mirror/platform_frameworks_base/main/…)
- https://github.com/Calvin-LL/Reorderable , https://github.com/aclassen/ComposeReorderable

Other toolkits
- https://api.flutter.dev/flutter/widgets/Draggable-class.html
- https://api.flutter.dev/flutter/widgets/DragTarget-class.html
- https://pub.dev/packages/super_drag_and_drop
- https://doc.qt.io/qt-6/dnd.html
- https://api-docs.avaloniaui.net/docs/M_Avalonia_Input_DragDrop_DoDragDrop
- https://docs.avaloniaui.net/docs/input-interaction/drag-and-drop
- https://docs.gtk.org/gtk4/class.DragSource.html , https://docs.gtk.org/gtk4/class.DropTarget.html
- https://developer.mozilla.org/en-US/docs/Web/API/HTML_Drag_and_Drop_API/Drag_operations
- https://www.electronjs.org/docs/latest/tutorial/native-file-drag-drop
- https://learn.microsoft.com/en-us/dotnet/maui/fundamentals/gestures/drag-and-drop
- https://github.com/entropyconquers/react-native-reanimated-dnd (RN has no built-in API)
