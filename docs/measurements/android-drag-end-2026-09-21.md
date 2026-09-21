# Android drag end survives removal of its source

The Rust async-dialog matrix passed every new dialog leg but failed dnd-compose.
The bundle and step clock were read before forming a hypothesis. The sixth drag
accepted a custom move, changed its source to "moved out", then reported
started=1 entered=2 dropped=1 ended=false. The next two row reorders passed.
The matrix was not an ALL PASS and was not committed.

## Evidence missing from the original bundle

The logcat tail began after the relevant event. The system-events selection
omitted drag history, although the complete device buffers said WindowManager
received the successful drop result and sent DRAG_ENDED to Kaya at
23:38:38.831 PDT on September 20. A missing Kaya callback does not establish
that Android sent no end. The older ledger's inference is corrected without
assigning a new cause to every historical missed-start/no-enter sighting.

The recorder now includes WindowManager drag/drop, ViewRoot drop results and
Kaya drag/request/ack events. Three one-substitution renderer mutations were
watched failing. check-flightrec passes 57 negatives in total. The forced red
below produced seven nonempty bundle sections, including the complete timeline.

## Mechanism and native measurement

The pinned Compose 1.11.4 implementation clears thisDragAndDropTarget on detach
and dispatches onEnded through attached targets. The exact source used was the
[official UI source jar](https://dl.google.com/dl/android/maven2/androidx/compose/ui/ui/1.11.4/ui-1.11.4-sources.jar)
and its [Android companion](https://dl.google.com/dl/android/maven2/androidx/compose/ui/ui-android/1.11.4/ui-android-1.11.4-sources.jar).
Kaya's source was its sole permitted end reporter. A drop handler can clear its
draggable declaration, and a reorder can restamp its row, before native END
arrives. Both remove that target.

A temporary probe at KayaRoot wrapped Compose's installed drag listener. All
events except END were forwarded unchanged. Each actual END was copied through
Parcel, held for 500ms, then delivered to the same manager. Parcel omits
localState, so the probe's onEnded alone used kayaDragSession. The probe never
invented an end event or inferred completion from a drop. The installed block,
lookup replacement and disposal instrument were each read back with count 1.

The probe's core, removed after the comparison:

```kotlin
val view = LocalView.current
DisposableEffect(view) {
    val listener = view.javaClass.getMethod("getDragAndDropManager")
        .invoke(view) as android.view.View.OnDragListener
    view.setOnDragListener { _, event ->
        if (event.action == android.view.DragEvent.ACTION_DRAG_ENDED) {
            val parcel = android.os.Parcel.obtain()
            event.writeToParcel(parcel, 0)
            parcel.setDataPosition(0)
            val copy = android.view.DragEvent.CREATOR.createFromParcel(parcel)
            parcel.recycle()
            view.postDelayed({ listener.onDrag(view, copy) }, 500)
            true
        } else listener.onDrag(view, event)
    }
    onDispose { view.setOnDragListener(listener) }
}
```

The old owner failed in 125 seconds. Its first five drags passed; the move and
both reorders lost END. The recorder's system-events showed native END sent and
held at 00:06:28.634, source disposal at 28.654 with ended=false, and Compose
delivery at 29.141. The step clock reported timeout at 38107ms, then the stale
"drag ended none" at 53124ms. The bundle was read back from run
20260921T070555Z-065527, android-dnd-compose.

With stable-root ownership, the identical probe passed all eight drags in
29 seconds. For the same move, source disposal at 00:09:12.970 preceded END
delivery at 13.456; the root emitted operation 2 and the expected label passed.
The two reordered sources also completed. The temporary listener and global
end-session lookup were removed and read back as zero occurrences.

Two earlier probes are not negatives: hidden DragEvent.obtain reflection was
refused at startup, and a listener replacement that failed to forward through
Compose lost START. A 750ms sleep inside onDrop did not reproduce the race.

## Production guard

KayaRoot accepts every local KayaDragSession and is the only native onEnded
reporter. A session captures the source identity at start, and its ended flag
deduplicates reporting. Clearing a source or restamping a row cannot remove the
root. Production reads the session from the native event, not from a global.
Source disposal logs the measured source id, payload presence and counters.

check-universal-props has eight new one-substitution negatives: disconnected
root, lost local admission, removed native callback, guessed session, lost
deduplication, current-node identity substituted for captured identity, missing
identity capture, and a second reporter. All eight failed by name; the complete
gate passes 23 negatives. The shared dnd scene already asserts the cleared
source and both reorder completions on every binding. No protocol or binding
surface changes. Rust, Go and Java use this Android backend; the other six
bindings retain their existing backends and semantics.

The ordinary production dnd-compose leg passed all eight drags in 27 seconds,
with no delayed listener or global-session lookup installed. The full
validation ladder passed: 644 core tests, 25 doctests (one existing ignored),
61 gates and 477 standalone Mac legs. The final matrix passed Mac 477,
Linux 777, Windows 283, iOS 139 and Android 148 legs plus all 61 gates in
1072 seconds, every timing ceiling held. All three Android drag hosts passed.
