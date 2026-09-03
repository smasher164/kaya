# Drag and drop on GTK4 and WinUI 3 — research for a kaya design pass

Research only. No processes started, nothing edited in the repo.
Date: 2026-09-02. Sources: repo code/docs, docs.gtk.org, learn.microsoft.com.

## §0 — what kaya has already decided (the doctrine this must fit)

From DESIGN.md's "Drag and drop" case analysis (DESIGN.md:3044-3054), verbatim
in substance:

- **Hover acceptance is answered from a PRE-PUSHED vocabulary** of accepted
  types and operations. The app is not asked mid-hover. DESIGN notes this
  "matches platform convention anyway, since fetching drag content mid-hover
  is discouraged everywhere". Dynamic hover policy is app-updated state;
  staleness there "mislabels a cursor badge, which is cosmetic".
- **The drop verdict is a BOUNDED WAIT whose expiry rejects the drop and
  snaps the drag back** — "a fail-safe and retryable default".
- **Source-side data provision** (`IDataObject::GetData`, pasteboard
  promises) is "demand with a generous deadline; the blocked party is the
  receiving process, and platforms have long normalized slow providers".
- Side benefit claimed: "app logic keeps running inside the drag and resize
  modal loops that stall single-threaded apps."

Degradation table (DESIGN.md:3300-3312) — two rows are drag's:

| Situation | Degradation |
|---|---|
| Drop verdict misses its deadline | Drop rejected; drag snaps back (retryable) |
| Stale hover policy | Wrong cursor badge until the next refresh (cosmetic) |

The table's own preamble says only the "App thread stalled entirely" row is
CURRENT BEHAVIOUR; the drop-verdict and hover rows "describe … drag-and-drop
… which [does] not exist in the core (each is admission-gated in
docs/deferred.md)".

Ledger status (docs/deferred.md:1742-1746): drag and drop is one of the two
still-open halves of the "system-integration floor" entry (the other is
notifications), "the most divergent, and it interacts with window management
on both mac and Windows". The spec does not mention it today.

Clipboard doctrine that drag inherits (docs/clipboard-plan.md §0, DESIGN.md
"Clipboard"):

- **Closed representation set**: `text`, `html`, `image`, `files`, plus
  `custom(id, bytes)`. Rejected: an open MIME→bytes map.
- **Copy takes a RECORD, paste returns a SUM** — offer many, receive one.
- **Canonical wire order is descending clip value**: custom (16), files (8),
  image (4), html (2), text (1).
- **kaya derives nothing between representations**, with one exception:
  `files` also gets the platform's text rendition of the paths.
- **Acceptance is per-widget and is a LIST** (`accepts`, space-separated
  kind names plus custom ids), not a mask — so a custom id can be accepted.
- **Files are the file dialog's capability**: a dropped/pasted file
  registers into the same picked table `kaya_open_picked` redeems.
- **"Paste and drop are the same event"** (docs/clipboard-plan.md:207-216):
  "Android built `onReceiveContent` as a SINGLE API for content arriving
  from paste, from drag and drop, and from autofill. Wayland agrees
  structurally: both are `wl_data_offer`. macOS and Windows use one clip
  model for both. So `on_paste` is the same payload arriving through a third
  trigger when drag and drop lands later, not a second data model."
- **Deliberately out of the clipboard**: lazy rendering ("a callback the
  platform can block on, arriving on the app thread at a moment kaya does
  not control"), multiple items per clip, PRIMARY selection.

**The tension to put in front of the maintainer up front:** the clipboard
ruled lazy rendering OUT; drag and drop's DESIGN paragraph rules source-side
demand IN ("`IDataObject::GetData`, pasteboard promises … demand with a
generous deadline"). Both platforms researched here make lazy provision the
NATIVE shape of a drag source (GTK's `GdkContentProvider` is a
serialize-on-demand object; WinUI's `DataPackage.SetDataProvider` is the
delayed-render API). A ruling is needed on whether drag sources are eager
(materialise at drag start, like copy) or lazy.

## §1 — GTK4 (the lane pins GTK 4.18; Debian trixie, tools/linux/Dockerfile)

All API text below is from docs.gtk.org's GTK 4.0 / GDK 4.0 reference
(the stable series the 4.18 runtime implements) and gtk-rs 0.x's generated
bindings, which is what crates/kaya/src/gtk.rs actually calls.

### 1.1 The source side — GtkDragSource

`GtkDragSource` is an **event controller** (a GtkGestureSingle subclass)
added to a widget with `gtk_widget_add_controller()`. Four signals, in the
gtk-rs spellings kaya would write:

```rust
connect_prepare    : Fn(&DragSource, f64, f64) -> Option<ContentProvider>
connect_drag_begin : Fn(&DragSource, &Drag)
connect_drag_end   : Fn(&DragSource, &Drag, bool)   // bool = delete_data (MOVE)
connect_drag_cancel: Fn(&DragSource, &Drag, DragCancelReason) -> bool
```

- **prepare** — "Emitted when a drag is about to be initiated." Its return
  value IS the payload: a `GdkContentProvider` (or `None` to refuse the
  drag). This is the natural place for kaya to build the same union
  provider `ApplyOp::Copy` already builds.
- **drag-begin** — "Emitted on the drag source when a drag is started."
  Fires *after* the `GdkDrag` exists, which is what makes it the place to
  call `gtk_drag_source_set_icon(paintable, hot_x, hot_y)`. The icon is
  any **`GdkPaintable`** — a `GdkTexture` from kaya's own raster, or
  `gtk_widget_paintable_new(widget)` for the "picture of the row" idiom.
- **drag-end(drag, delete_data)** — "Critical for `GDK_ACTION_MOVE`
  operations to delete transferred data afterward." The `delete_data`
  boolean is how a MOVE tells the source to remove the original.
- **drag-cancel(drag, reason) -> bool** — "Emitted on the drag source when
  a drag has failed"; returning TRUE says the app handled the failure
  itself (which suppresses the default snap-back animation).

Properties: `actions` (`GdkDragAction`) and `content`
(`GdkContentProvider`) can be set once on the controller instead of per
drag. Methods: `set_content`, `set_actions`, `set_icon`, `drag_cancel()`
("Cancels a currently ongoing drag operation"), `drag()` -> `Option<Drag>`.

### 1.2 GdkContentProvider — the SAME object kaya already builds for copy

docs.gtk.org: `GdkContentProvider` "provides content for the clipboard **or
for drag-and-drop operations** in a number of formats." One class, two
consumers — so the copy arm kaya already ships is literally the drag
payload builder.

crates/kaya/src/gtk.rs's `ApplyOp::Copy` (around line 7423-7500) already
builds exactly the right shape, and it is reusable verbatim:

- one `ContentProvider::for_bytes(id, bytes)` per custom representation
- `for_bytes("text/uri-list", …)` for files (RFC CRLF separators)
- `for_bytes("image/png", …)` — "RAW BYTES UNDER THE TYPE, never
  GdkTexture: the texture re-encodes on demand and the bytes stop
  round-tripping"
- `for_bytes("text/html", …)` — bare type, no charset alias
- `for_value(&text.to_value())` for text, so "GTK derives the text/plain
  spellings and charset aliases from it"
- then `ContentProvider::new_union(&providers)` when there is more than one.

docs/clipboard-plan.md §5b finding 1 already MEASURED that a union
advertises all four representations plus GTK's own aliases:

    gchararray GdkTexture GdkPixbuf text/html image/png dev.kaya.note
    text/plain;charset=utf-8 text/plain;charset=ANSI_X3.4-1968 text/plain

So the drag-source lowering on GTK is: hoist that provider-building block
out of the Copy arm into a function, and return it from `prepare`.

**Lazy provision exists but kaya does not need it.** `GdkContentProvider`
serializes on demand — `write_mime_type_async()` / `write_mime_type_finish()`
is the async serialize hook, and a subclass could defer arbitrarily. A
provider built with `for_bytes` already holds the bytes, which is what
kaya's clipboard ruling ("lazy rendering: deliberately out") implies for
drag too. §5b finding 4 also applies unchanged: **a custom id with no
slash is advertised and never served**, because GDK interns the requested
type as a mime type — so the ratified MIME-shaped id grammar carries over
to drag for free.

### 1.3 The destination side — GtkDropTarget vs GtkDropTargetAsync

**GtkDropTarget** (the simple one). Its own class docs say the deciding
sentence: *"GtkDropTarget is ultimately modeled in a **synchronous** way
and only supports data transferred via GType."* Signals, in gtk-rs spelling:

```rust
connect_accept : Fn(&DropTarget, &Drop) -> bool
connect_enter  : Fn(&DropTarget, f64, f64) -> DragAction
connect_motion : Fn(&DropTarget, f64, f64) -> DragAction
connect_leave  : Fn(&DropTarget)
connect_drop   : Fn(&DropTarget, &Value, f64, f64) -> bool
```

- **accept(drop) -> bool** — "Emitted on the drop site when a drop
  operation is about to begin." FALSE ignores the drop entirely; TRUE
  provisionally accepts, and it can still be rejected later with
  `gtk_drop_target_reject()` or by returning FALSE from `::drop`. The
  docs are explicit that **the data is not available here** — only the
  formats: "if the decision whether the drop will be accepted or rejected
  depends on the data, this function should return TRUE" with `preload`
  enabled and the value inspected through `::notify:value`.
- **enter / motion -> GdkDragAction** — this is where the hover verdict
  and hence the cursor badge is answered, and it is a plain synchronous
  return of an action flag. **This is exactly kaya's "pre-pushed
  vocabulary" model**: the accepted-types/actions vocabulary the core
  already holds answers it with no app round trip.
- **drop(value, x, y) -> gboolean** — "Whether the drop was accepted at
  the given pointer position." **Synchronous.** The value is already
  materialised (GTK read it for you).
- Type filtering: `gtk_drop_target_new(GType, GdkDragAction)` or
  `gtk_drop_target_set_gtypes(target, GType*, n)` — the accept list is
  expressed as **GTypes**, not mime strings, on this widget. For files
  the type is `GDK_TYPE_FILE_LIST`, whose value is a boxed `GdkFileList`
  read with `g_value_get_boxed()` then `gdk_file_list_get_files()` (a
  `GSList` of `GFile`). `G_TYPE_STRING` covers text; `GDK_TYPE_TEXTURE`
  covers images. **A raw mime type (kaya's `custom(id, bytes)`) has no
  GType**, which is the first real GTK carve-out — see 1.5.
- `preload` — "Whether the drop data should be preloaded when the pointer
  is only hovering over the widget but has not been released."

**GtkDropTargetAsync** (the complete one). Docs: it is "the more complete
but also more complex method", to be used "only when [GtkDropTarget] lacks
necessary features." Signal order: `accept` -> `drag-enter` -> repeated
`drag-motion` -> `drop` (or `drag-leave`), with the widget carrying
`GTK_STATE_FLAG_DROP_ACTIVE` in between for theming. Its drop signal:

```c
gboolean drop (GtkDropTargetAsync* self, GdkDrop* drop,
               gdouble x, gdouble y, gpointer user_data)
```

Returning TRUE makes the handler **responsible for calling
`gdk_drop_finish()`**, and the docs state: *"The call to gdk_drop_finish()
must only be done when all data has been received."* Data arrives through
`gdk_drop_read_async()` / `read_finish` (bytes for a mime type) or
`gdk_drop_read_value_async()` / `read_value_finish` (a GValue of a GType).

**This is GTK's answer to kaya's deferred drop verdict.** The verdict is
"TRUE, and I will call `gdk_drop_finish()` when I know" — an arbitrary
amount of time later, on the main loop, without blocking it.

`gdk_drop_finish(drop, action)`: "must be called" to conclude the transfer;
"if the action is `GDK_ACTION_MOVE`, the source receives notification to
remove the data." `gdk_drop_finish(drop, GDK_ACTION_NONE)` is the
REJECTION, which is kaya's deadline-expiry answer.

`gdk_drop_status(drop, actions, preferred)`:
```c
void gdk_drop_status (GdkDrop* self, GdkDragAction actions,
                      GdkDragAction preferred)
```
"actions … or `GDK_ACTION_NONE` if no drop will be permitted"; "preferred
… must be a single action that is included within actions". Called on
`GDK_DRAG_ENTER`/`GDK_DRAG_MOTION`, and the docs explicitly allow revising
it: "If the destination [has not] finalized its supported operations, it may
provide preliminary actions and call this function again later with refined
values." **That is the protocol-level home for kaya's "stale hover policy
… cosmetic" row: the badge can be corrected mid-hover.**

### 1.4 GdkDragAction

| Flag | Value | Docs |
|---|---|---|
| `GDK_ACTION_COPY` | 1 | "Copy the data." |
| `GDK_ACTION_MOVE` | 2 | "Move the data, i.e. first copy it, then delete it from the source using the DELETE target of the X selection protocol." |
| `GDK_ACTION_LINK` | 4 | "Add a link to the data. Note that this is only useful if source and destination agree on what it means, and is not supported on all platforms." |
| `GDK_ACTION_ASK` | 8 | "Ask the user what to do with the data." |

`gdk_drag_action_is_unique()` exists to check a single action — the drop
must settle on exactly one. LINK is documented as "not supported on all
platforms", which is a uniformity problem for kaya before Windows is even
considered.

### 1.5 What GTK cannot express the way kaya's grammar wants

1. **GtkDropTarget's accept list is GTypes, not mime types.** `text` is
   `G_TYPE_STRING`, `files` is `GDK_TYPE_FILE_LIST`, `image` is
   `GDK_TYPE_TEXTURE`. `html` and `custom(id, bytes)` have **no GType** —
   they are mime types with bytes behind them. Consequences: either kaya
   uses `GtkDropTargetAsync` for every drop target (reading mime types with
   `gdk_drop_read_async`, which covers every representation uniformly and
   also gives the deferred verdict), **or** it uses `GtkDropTarget` for
   text/files/image and something else for html/custom. The uniform
   answer is DropTargetAsync everywhere — one code path, one verdict
   model, and it happens to be the one that matches the kaya doctrine.
2. **`GDK_ACTION_LINK` is documented as "not supported on all platforms".**
   Windows has `DataPackageOperation.Link`; macOS has `.link`. If kaya's
   operation vocabulary is copy/move/link, GTK is the one that hedges.
3. **`GDK_ACTION_ASK`** has no analogue in the WinUI vocabulary at all
   (`DataPackageOperation` is None/Copy/Move/Link plus two internal
   flags). If kaya offers `ask`, GTK can lower it and Windows cannot.
4. **The image representation.** kaya's clipboard rules image as raw PNG
   bytes; a drop target that filters on `GDK_TYPE_TEXTURE` would get GTK's
   decode instead. With DropTargetAsync + `gdk_drop_read_async("image/png")`
   kaya keeps the ruled shape.

### 1.6 X11 (XDND) vs Wayland (wl_data_device) — the real divergence

The GTK API is one API; the two GDK backends are not the same protocol.

**Wayland — the drag needs a POINTER GRAB, which the lane does not have.**
`wl_data_device.start_drag(source, origin, icon, serial)`: *"The client
must have an active implicit grab that matches the serial."* An implicit
grab is what a real pointer button press creates. This is the **same
failure family as docs/clipboard-plan.md §5b finding 3** ("Rejecting
set_selection request, serial 0 was never given to client"), one input
device over — and it is STRICTLY WORSE for the lane, because:

- the clipboard's fix was a **keyboard** tap (`wtype -k F24`) and the lane
  image installs `wtype`, a *virtual-keyboard* client;
- a drag needs a **pointer button press with an implicit grab held across
  the whole gesture**. `wtype` cannot do that; there is no pointer
  injector in tools/linux/Dockerfile at all.
- the lane's seat is deliberately capability-less
  (`WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1`), which is exactly
  why no serial exists to begin with.

Also from Wayland: the **drag icon is a client surface with the
`dnd_icon` role** — "the top-left corner of the icon surface is placed at
the cursor hotspot", "if the icon surface already has another role, it
raises a protocol error", and "input regions are ignored". GTK
manufactures that surface for you (`gdk_drag_get_drag_surface`,
`gdk_drag_set_hotspot`), so `gtk_drag_source_set_icon(paintable, …)` is
the whole of what kaya writes on both backends.

**X11 — XDND, and the lane already has a pointer injector.** XDND is
client messages between windows plus the X selection machinery; MOVE is
documented at the GDK level in X11's own terms ("delete it from the source
using the DELETE target of the X selection protocol"). The lane runs one
private Xvfb per X11 leg and installs **xdotool**, whose XTEST route
already drives the `type` verb (tools/linux/Dockerfile's last apt layer,
and gtk.rs's `type_text`, which measured that `xdotool type --window`
i.e. XSendEvent "delivers NOTHING to GTK4 — GDK4 reads XI2 events and a
synthetic core event is not one"). XTEST events ARE real input to GDK4,
so `xdotool mousedown 1 / mousemove / mouseup 1` is a genuine drag
gesture on the X11 half.

**Cross-app drags.** Both protocols do them; kaya's lane has no second
app to drag from, and the clipboard milestone's answer (a foreign
reader/writer in the runner's process: `xclip`, `wl-copy`/`wl-paste`)
does not transfer — there is no `wl-drag`. A cross-app drag assertion
would need a second GTK process written for the purpose.

**The session-architecture constraint carries over.** The wayland lane
pools eight legs in one sway session, and §5b measured that a persistent
seat keyboard makes keyboard focus EXCLUSIVE and cost three legs. A
persistent seat POINTER would be the same class of hazard. §5b already
named the exit: **per-leg sway instances** ("a headless sway reaches its
socket in ~55ms, so one compositor per wayland leg costs what xvfb-run
already costs … This is the path to take when the need arrives"). A
drag verb is exactly that need arriving.

## §2 — WinUI 3 (Windows App SDK; kaya pins WinUI **2.2.1**, Foundation 2.1.0, InteractiveExperiences 2.0.15, Runtime 2.2.0 — tools/fetch-winappsdk.sh:89-98)

The learn.microsoft.com pages consulted carry the
`windows-app-sdk-2.0` moniker, which is the family kaya's 2.x packages
belong to.

### 2.1 The XAML surface, end to end

From "Drag and drop — Windows apps" (learn.microsoft.com, ms.date
2026-07-15), the five steps verbatim:

1. "Enable dragging on an element by setting its **CanDrag** property to true."
2. "Build the data package. The system handles images and text
   automatically, but for other content, you'll need to handle the
   **DragStarting** and **DropCompleted** events and use them to construct
   your own data package."
3. "Enable dropping by setting the **AllowDrop** property to **true** on
   all the elements that can receive dropped content."
4. "Handle the **DragOver** event to let the system know what type of drag
   operations the element can receive."
5. "Process the **Drop** event to receive the dropped content."

**Source side.**
- `UIElement.CanDrag` (bool) — "This make the element — and the elements
  it contains, in the case of collections like ListView — draggable."
- `UIElement.DragStarting` -> `DragStartingEventArgs`:
  `AllowedOperations` (DataPackageOperation), `Cancel` (bool),
  `Data` (**DataPackage**), `DragUI` (**DragUI** — the drag visual),
  `GetPosition(UIElement)`, and **`GetDeferral()`** — "Supports
  asynchronous drag-and-drop operations by creating and returning a
  `DragOperationDeferral` object." The docs' own example wraps async
  payload construction in `GetDeferral()` … `deferral.Complete()`.
- `UIElement.DropCompleted` -> `DropCompletedEventArgs.DropResult`
  (a `DataPackageOperation`). "Use [it] to determine the outcome and take
  action, such as removing the source item if a **Move** was performed."
  **This is WinUI's counterpart to GTK's `drag-end(delete_data)`.**
- `UIElement.StartDragAsync(PointerPoint) -> IAsyncOperation<DataPackageOperation>`
  — "If you implement custom gesture detection to initiate a drag
  operation, you can call [it] to programmatically initiate a drag
  operation on **any UIElement**. Calling this method results in the
  **DragStarting** event being raised." Two documented constraints: the
  `PointerPoint` "is the point at which the user interacts with the screen
  using an input device (touch, mouse, or pen)", and — flagged Important —
  "**Not supported if a user runs the app in elevated mode, as an
  administrator.**"

**Destination side.** `UIElement.AllowDrop` (bool) gates all four events,
which are ROUTED events sharing `DragEventArgs`:

| Member | Docs |
|---|---|
| `AcceptedOperation` | "Gets or sets a value that specifies which operations (none, move, copy, and/or link) can be accepted by the target of the drag event." |
| `AllowedOperations` | what the SOURCE allows (read-only) |
| `DataView` | "Gets a read-only copy of the Data object" (a `DataPackageView`) |
| `DragUIOverride` | Caption / IsCaptionVisible / IsContentVisible / IsGlyphVisible / SetContentFromBitmapImage — the target's badge |
| `Handled` | routed-event handling |
| `Modifiers` | SHIFT/CTRL/ALT + mouse-button state |
| `GetDeferral()` | "Supports asynchronous drag-and-drop operations by creating and returning a `DragOperationDeferral` object." |
| `GetPosition(UIElement)` | drop point relative to an element |

The hover verdict is `e.AcceptedOperation = DataPackageOperation.Copy`
set **synchronously in DragOver** — again exactly kaya's pre-pushed
vocabulary, answered with no app round trip. `DragUIOverride` is the
badge, and the "stale hover policy … cosmetic" degradation row is
literally a stale `Caption`.

**AllowDrop's non-obvious requirement**, from the overview: "the
specified area must not have a null background, it must be able to
receive pointer input". A `Grid` with no `Background` is hit-test
transparent and silently never a drop target. **That is a false-green
shape for a first implementation** and it is the sort of thing a gate
should hold on the lowering side.

### 2.2 DataPackage — kaya's clip record, one surface over from the one it uses

`DataPackage` (Windows.ApplicationModel.DataTransfer): "Contains the data
that a user wants to exchange with another app." Its methods map onto
kaya's closed set almost one to one:

| kaya representation | DataPackage |
|---|---|
| `text` | `SetText(String)` — `StandardDataFormats.Text` |
| `html` | `SetHtmlFormat(String)` — `StandardDataFormats.Html` (**CF_HTML with the header; this is the SAME format kaya's Win32 arm builds by hand with 10-digit offsets, clipboard-plan §6 finding 3**) |
| `image` | `SetBitmap(RandomAccessStreamReference)` — `StandardDataFormats.Bitmap` |
| `files` | `SetStorageItems(IIterable<IStorageItem>)` — `StandardDataFormats.StorageItems` |
| `custom(id, bytes)` | `SetData(String formatId, Object)` — "Sets the data contained in the DataPackage in a RandomAccessStream format" |
| the operation | `RequestedOperation` (`DataPackageOperation`) |

`DataPackageOperation` (a `[Flags]` enum): `None = 0` ("Typically used
when the DataPackage object requires **delayed rendering**"),
`Copy = 1`, `Move = 2`, `Link = 4`, plus `BackgroundTarget = 536870912`
and `NewTarget = 1073741824`.

**Lazy provision is `SetDataProvider(String, DataProviderHandler)`** —
"Sets a delegate to handle requests from the target app", and the class
Remarks spell out the intent: "Source apps have the option of using
SetDataProvider to assign a delegate to a DataPackage, instead of
providing the data immediately. This process is useful when the source
app supports a given format but does not want to generate the data unless
the target app requests the data." **That delegate is called on the
source's UI thread, from inside the receiving process's data request —
which is the exact shape kaya's clipboard ruling called "a callback the
platform can block on, arriving on the app thread at a moment kaya does
not control."**

**THE BIG DIVERGENCE FROM KAYA'S EXISTING WINDOWS ARM.** clipboard-plan
§6 finding 2 disqualified the modern WinRT DataTransfer API for the
CLIPBOARD, on three measured charges — `Clipboard.SetContent` works
"only when the application is in the foreground"; the WinRT→Win32 bridge
for a custom format id is documented only in the read direction; and
SetContent's data dies with the process unless flushed — and kaya
therefore ships classic `OpenClipboard`/`SetClipboardData`
(crates/kaya/src/winui/mod.rs:8466-8760, 12211-12251). **None of those
three escapes is available for drag and drop.** XAML drag and drop IS
`DataPackage`; there is no classic-Win32 door into `UIElement.DragStarting`.
So Windows drag and drop is where kaya finally has to meet WinRT
DataTransfer, and the custom-format-id bridge — the one Microsoft records
as asymmetric — is precisely what kaya's `custom(id, bytes)` needs to
cross a process boundary. **This is a ruling-grade finding and it should
be PROBED before any design is fixed**, in the shape §6 was probed: a
a `dragprobe` directory under tools/win in the interactive session, `SetData("dev.kaya/note", …)`
on one side and a stock reader on the other.

`StandardDataFormats`' own Remarks carry the legacy-interop table
("AnsiText" -> CF_TEXT, "DeviceIndependentBitmap" -> CF_DIB, …), which is
where a `DataPackageView` and the Win32 formats meet — useful for
reading an Explorer drop, useless for writing a custom id.

### 2.3 The OLE modal loop underneath, and what it means for a harness

Microsoft's own AllowDrop remarks say: *"The Windows Runtime
implementation of drag-drop concepts permits only certain controls and
input actions to initiate a drag-drop action. **There is no generalized
`DoDragDrop` method** that would permit any UI element to initiate a
drag-drop action."* — i.e. XAML deliberately hides OLE.

Under a WinUI 3 DESKTOP app (a real HWND) the cross-process half is still
OLE. The Win32 contract that matters:

- `DoDragDrop` "enters a modal message loop" on the SOURCE thread,
  pumping mouse and keyboard messages and calling `IDropSource` /
  `IDropTarget` methods until the drop or cancel.
- `RegisterDragDrop`: "The application thread that calls the
  RegisterDragDrop function **must be pumping messages** … because OLE
  creates windows on the thread that need messages processed. If this
  requirement isn't met, then any application that drags an object over
  the window that is registered as a drop target **will hang until the
  target application closes**."

**What that means for kaya specifically, and it is the good news:** the
modal loop is the *platform's* loop on the *UI* thread. kaya's app thread
is a different thread, feeding the UI thread over a ring. The UI thread
keeps pumping inside the modal loop, so the ring keeps draining and the
app keeps running — which is exactly the side benefit DESIGN.md's drag
paragraph already claims ("app logic keeps running inside the drag and
resize modal loops that stall single-threaded apps"). **The claim is
architecturally sound on both platforms.**

**The bad news for the HARNESS.** kaya's harness drives the app *from
another thread* and every existing verb is programmatic, not synthetic:
GTK's `click` is `button.emit_clicked()` (gtk.rs:10417-10437) and WinUI's
is `peer.Invoke()` on the automation peer (winui/mod.rs:16061, 16717).
**Neither can express a drag**: there is no "emit_drag" signal, and OLE's
modal loop is driven by real mouse messages. On Windows the harness's
step would have to either (a) hop to the UI thread and call
`StartDragAsync(pointerPoint)` — which raises DragStarting and runs the
real source path, but needs a `PointerPoint` (only obtainable from
`PointerPoint.GetCurrentPoint(pointerId)` or a pointer event; no public
constructor) and is documented as unsupported when elevated — or (b)
synthesize real mouse input, **for which the tree already has a working
precedent** — see 6.4 Route B.

### 2.4 Cross-process drops: Explorer -> WinUI 3 is a KNOWN-BROKEN PATH

Two contradicting Microsoft statements, both current:

- The overview: "Once implemented, drag and drop works in all directions,
  including app-to-app, app-to-desktop, and desktop-to-app."
- `Microsoft.UI.Xaml.UIElement.AllowDrop`'s own Remarks, still published
  under the `windows-app-sdk-2.0` moniker: "**A UI element can't be a drop
  target for any drag-drop action that begins from outside the current
  app.** This includes actions that come from another app, which is
  possible for a snapped view." (Almost certainly inherited UWP text —
  but it is what the reference page says.)

And the field evidence: microsoft-ui-xaml **issue #10119** ("WinUI 3
Desktop: Drag and drop file from Explorer to app window does not work",
against Windows App SDK 1.6.1 on Windows 11 26100.2161) — `DragOver`
never fires, the "not allowed" cursor is shown, dragging from Explorer's
*Recent items* works while dragging from the Desktop or a folder view
does not. Closed as a duplicate of **#8108**, i.e. long-standing rather
than fixed. Issue **#2715** ("Unable to drop files onto Grid in WinUI3
Desktop") is the older report.

**Ruling implication:** "drop a file from the file manager onto the app"
is the single most-wanted drag scenario and it is the one Windows is
least able to promise. kaya should either (a) probe it on the VM before
promising it, or (b) fall back to the OLE route on the HWND
(`RegisterDragDrop` + a kaya-owned `IDropTarget`), which is the same
"classic Win32 rather than WinRT" move §6 already made for the clipboard
— and which would let kaya read `CF_HDROP` with the `parse_dropfiles`
it already ships (winui/mod.rs:8639, 8714) and register the dropped paths
into the same picked table `kaya_open_picked` redeems.

### 2.5 The bindgen filter has to grow, and the transitivity trap is ALREADY VISIBLE

crates/kaya/src/winui/bindings.rs is generated by tools/winui-bindgen,
whose header says "Filters are type-level"; docs/traps.md's rule (quoted
in that file) is that **the filter never pulls referenced types
transitively**, and an unfiltered parameter type turns its method into a
`usize` vtable PAD.

That has already happened for drag, silently, in the checked-in file:

```
DragStarting: usize,
pub RemoveDragStarting: … fn(*mut c_void, i64) -> HRESULT,
DropCompleted: usize,
pub RemoveDropCompleted: … ,
DragEnter: usize,  DragLeave: usize,  DragOver: usize,  Drop: usize,
```

(bindings.rs around lines 9595-9625.) The **Remove** halves survived
because they take an `i64` token; every ADD half is a pad because its
handler type is unfiltered. `AllowDrop`/`SetAllowDrop` and
`CanDrag`/`SetCanDrag` ARE generated (bindings.rs:6800, 6988) — they take
a bool — so the property half of the surface is already reachable and the
event half is not, which is exactly the shape the TextWrapping and
ITextRange notes in tools/winui-bindgen/src/main.rs describe.

The filter would have to name, at minimum:

- `Microsoft.UI.Xaml.DragStartingEventHandler`, `Microsoft.UI.Xaml.DragStartingEventArgs`
- `Microsoft.UI.Xaml.DropCompletedEventHandler`, `Microsoft.UI.Xaml.DropCompletedEventArgs`
- `Microsoft.UI.Xaml.DragEventHandler`, `Microsoft.UI.Xaml.DragEventArgs`
- `Microsoft.UI.Xaml.DragOperationDeferral`, `Microsoft.UI.Xaml.DragUI`, `Microsoft.UI.Xaml.DragUIOverride`
- `Windows.ApplicationModel.DataTransfer.DataPackage`, `DataPackageView`,
  `DataPackageOperation`, `StandardDataFormats`, `DataProviderHandler`
- `Windows.Storage.IStorageItem` / `StorageFile` for the files half, or
  the OLE route instead
- for the harness: `Microsoft.UI.Input.PointerPoint` (StartDragAsync's
  argument), and `Microsoft.UI.Xaml.Input.PointerRoutedEventArgs` if a
  real pointer event is the source of it.

`Windows.ApplicationModel.DataTransfer` is a **Windows** (not
Microsoft.UI) namespace, so it comes from the `--in default` metadata
the bindgen already passes; `Microsoft.UI.Input.PointerPoint` comes from
the InteractiveExperiences winmd already listed.

## §3 — THE DROP VERDICT: synchronous vs deferred, per platform

kaya's doctrine: "The drop verdict is a bounded wait whose expiry rejects
the drop and snaps the drag back" (DESIGN.md:3048), with hover acceptance
answered from a pre-pushed accepted-types vocabulary.

| | Hover verdict (badge) | Drop verdict |
|---|---|---|
| **GTK, GtkDropTarget** | `enter`/`motion` return `GdkDragAction` — synchronous, no app round trip | `drop(value,x,y) -> gboolean` — **synchronous**; class docs: "GtkDropTarget is ultimately modeled in a synchronous way" |
| **GTK, GtkDropTargetAsync** | `drag-enter`/`drag-motion` return `GdkDragAction`; `gdk_drop_status(actions, preferred)` may be re-called with refined values | `drop(drop,x,y) -> gboolean` TRUE means "I take responsibility"; the real verdict is **`gdk_drop_finish(drop, action)` at an arbitrary later time** ("must only be done when all data has been received"); `gdk_drop_finish(drop, GDK_ACTION_NONE)` is the rejection |
| **WinUI 3 XAML** | `DragOver`'s `e.AcceptedOperation = …` — synchronous | `Drop` handler calls **`e.GetDeferral()`**, does async work, then `deferral.Complete()`. `DragEventArgs.GetDeferral` — "Supports asynchronous drag-and-drop operations by creating and returning a DragOperationDeferral object" |

**So both platforms already have kaya's exact shape, and each has a
single documented "I'll answer later" object**: `GdkDrop` (finished with
`gdk_drop_finish`) and `DragOperationDeferral` (finished with
`Complete()`). kaya's bounded wait is then implemented identically on
both: hold the deferral/GdkDrop, arm a timer for the deadline, and on
expiry finish with the rejection value (`GDK_ACTION_NONE` /
`AcceptedOperation = DataPackageOperation.None` then `Complete()`).

**One asymmetry worth a ruling.** GTK gives the drop verdict a return
value AND a completion; WinUI gives it only a completion (`Drop` is
`void`; the verdict is whatever `AcceptedOperation` holds when the
deferral completes). And on the SOURCE side the outcome is reported
differently: GTK's `drag-end(drag, delete_data: bool)` +
`drag-cancel(drag, reason)`, versus WinUI's
`DropCompleted(args.DropResult: DataPackageOperation)` — where a cancel
is `DropResult == None`. Uniform kaya semantics ("the drop was accepted
as COPY / as MOVE / rejected") is expressible on both, but the SOURCE
must be told, because a MOVE's deletion is the source's job on both
platforms.

**Neither platform's timer is kaya's.** Neither documents a system
deadline on the deferral. If the app never finishes, GTK leaves the drag
hanging (the source waits on `dnd-finished`) and OLE's modal loop keeps
spinning. So the bounded wait is kaya's own timer, and the expiry action
must be a real finish, not a drop-on-the-floor.

## §4 — PAYLOADS

### 4.1 Representation mapping (kaya's closed set -> both platforms)

| kaya | GTK provider (already written in gtk.rs's Copy arm) | GTK drop read | WinUI DataPackage | WinUI drop read |
|---|---|---|---|---|
| `text` | `ContentProvider::for_value(&String)` (GTK derives text/plain + charset aliases) | `G_TYPE_STRING` value, or `read_async("text/plain;charset=utf-8")` | `SetText` (`StandardDataFormats.Text`) | `DataView.GetTextAsync()` |
| `html` | `for_bytes("text/html", …)` — bare type, no charset alias (§5b measured) | `read_async("text/html")` | `SetHtmlFormat` = **CF_HTML with the offset header** | `GetHtmlFormatAsync()` |
| `image` | `for_bytes("image/png", …)` — raw bytes, **never GdkTexture** | `read_async("image/png")` | `SetBitmap(RandomAccessStreamReference)` | `GetBitmapAsync()` |
| `files` | `for_bytes("text/uri-list", …)` CRLF-terminated | `GDK_TYPE_FILE_LIST` -> `GdkFileList` -> `GSList<GFile>`, or `read_async("text/uri-list")` | `SetStorageItems(IIterable<IStorageItem>)` | `GetStorageItemsAsync()` (or `CF_HDROP` via the OLE route, which kaya's `parse_dropfiles` already reads) |
| `custom(id,bytes)` | `for_bytes(id, bytes)` — **id must contain a slash and be lowercase** (§5b finding 4) | `read_async(id)` | `SetData(id, RandomAccessStream)` — **the WinRT↔Win32 bridge Microsoft records as asymmetric for writes; PROBE FIRST** | `GetDataAsync(id)` |

The union/record shape is identical: GTK unions N providers; WinUI calls
N setters on one `DataPackage`. The **descending clip value order**
(custom, files, image, html, text) is honoured by construction on GTK
(the provider list order) and is irrelevant on WinUI (a DataPackage is a
keyed bag; the target's preference decides).

### 4.2 Lazy provision — available on both, and it is the open ruling

- GTK: `GdkContentProvider` "provides content for the clipboard or for
  drag-and-drop operations"; `write_mime_type_async()` is the on-demand
  serialization hook. A `for_bytes` provider is already eager.
- WinUI: `DataPackage.SetDataProvider(String, DataProviderHandler)` —
  "Sets a delegate to handle requests from the target app … useful when
  the source app supports a given format but does not want to generate
  the data unless the target app requests the data."

kaya's clipboard ruled lazy rendering OUT with an argument that transfers
verbatim ("a callback the platform can block on, arriving on the app
thread at a moment kaya does not control"), while DESIGN's drag paragraph
ruled source-side demand IN ("`IDataObject::GetData`, pasteboard
promises … demand with a generous deadline; the blocked party is the
receiving process"). **The maintainer has to pick one.** The cheap and
consistent answer is EAGER: the drag payload is built at `prepare` /
`DragStarting` from data the app already holds, exactly as `copy` does,
and the `files` representation carries the laziness for free by moving
references rather than bytes — which is the same argument the clipboard
ruling already made.

### 4.3 Files, and the picked table

Both platforms hand a drop target a FILE REFERENCE, not bytes: a `GFile`
list / `text/uri-list` on GTK, `IStorageItem`s (or `CF_HDROP` paths) on
Windows. That is precisely the currency
docs/clipboard-plan.md §0 already ruled ("Files are the file dialog's
capability … a pasted file registers into the SAME picked table the file
dialog fills, so `kaya_open_picked` redeems it identically", §6 finding
5). A dropped file should join that table by the same route with no new
concept — and that is the single strongest argument that **drop is
`on_paste` with a third trigger**, exactly as clipboard-plan §0 predicted
("Paste and drop are the same event").

## §5 — REORDER WITHIN A LIST

kaya already has a `reorder` scene (tools/scenes/reorder.steps) and the
wire record: `collection_move { collection_id, path, key, before }`
(crates/kaya/src/spec.rs:511), whose own doc says "Keys, never indices:
order is data, and indices would race the very deltas that change them."
Today the scene drives it with BUTTONS (`click button#0` -> rotate,
`click button#1` -> lift) and asserts with `expect_order column#0 "b|c|a"`.

**GTK.** There is no built-in reorder in GtkListView/GtkColumnView for
ITEMS. `GtkColumnView:reorderable` (quoted in
docs/probes/table-overflow-2026.md:170) reorders **COLUMNS**, not rows,
via header drag. Row reorder is hand-built: a `GtkDragSource` per row
widget (a list item's child), a `GtkDropTarget`/`GtkDropTargetAsync` per
row, and the app moves the model. That maps cleanly onto kaya's design:
the row's drag source offers the row's KEY (a `custom` id would do, e.g.
`application/x-kaya-row` carrying the key bytes), the row's drop target
computes "before which key", and the backend raises a
`MoveRequested { collection_id, path, key, before }` occurrence that the
app confirms by issuing `collection_move`. **Nothing new on the wire
except the occurrence.**

**WinUI.** `ListViewBase.CanReorderItems` + `AllowDrop` is built in:
"To enable users to reorder items using drag-and-drop interaction, you
must set both the CanReorderItems and AllowDrop properties to true."
Caveats from the same page: "Built in reordering is not supported when
items are grouped, or when a VariableSizedWrapGrid is used as the
ItemsPanel"; and "In order to receive the DragItemsStarting and
DragItemsCompleted events while reordering items, the CanDragItems
property must be set to true."

**And this is a REAL divergence, not a spelling one.** WinUI's built-in
reorder mutates the `ItemsSource` collection ITSELF when the drop lands —
the control performs the move. kaya's model forbids that: the model is
the app's, the backend may not write it, and a move is
request-then-confirm (`MoveRequested` -> `collection_move`), exactly like
`CloseRequested` -> `destroy_window()` (DESIGN.md:3039). So on WinUI kaya
would have to either
(a) not use `CanReorderItems` and hand-build the row drag the GTK way, or
(b) use it and immediately undo/re-derive the control's own mutation,
which is the "backend wrote the model" bug class.
**(a) is the uniform answer** and it also matches what kaya already does
for every other collection affordance. Worth stating as a ruling since it
means declining a free native feature on one platform.

The affordance to declare is the ledger's future `reorderable` prop on
the collection (a For), which would set `CanDragItems`/`AllowDrop` on
WinUI and add per-row `GtkDragSource`/`GtkDropTarget` on GTK, plus an
insertion indicator each platform draws its own way (WinUI's is built in
for `CanReorderItems`; GTK's would be kaya's own line, drawn by the
backend, invisible to every observable — a check-table-card-shaped gate).

## §6 — HARNESS OBSERVABILITY

### 6.1 The blocking fact: every existing kaya "click" is PROGRAMMATIC

- GTK: `fn click()` -> `core.buttons[i].emit_clicked()` (gtk.rs:10417-10437).
- WinUI: `fn click()` -> the element's automation peer `Invoke()`
  (winui/mod.rs:16061, 16717, 17428-17443).

Neither has an analogue for a drag: there is no signal to emit, and OLE's
transfer is driven by real mouse messages. Microsoft says so in its own
words, in the UI Automation Drag pattern guidance:
*"IDragProvider is a read-only interface intended for monitoring drag
operations. **You cannot use it to control a drag operation. You can
automate drag operations by sending mouse input to a control.**"*

So a `drag` verb is the second verb in kaya's harness (after `type`) that
must go through the platform's real input path — and `type`'s six-point
contract in gtk.rs:10457-10470 is the precedent to copy, including its
first point: "THE PLATFORM'S OWN INPUT PATH … so the field's native
history fills exactly as a user's typing fills it … a programmatic
insert fills NOTHING here … a stand-in would leave the native tier empty
and let a native-tier leg pass having observed nothing."

### 6.2 Linux, X11 half — **already possible with what the image has**

tools/linux/Dockerfile's last apt layers install `xdotool` for exactly
this class of problem, and gtk.rs's `type_text` already shells out to it.
XTEST events are real XI2 input to GDK4 (the Dockerfile records the
measured negative: `xdotool type --window`, i.e. XSendEvent, "delivers
NOTHING to GTK4 — GDK4 reads XI2 events and a synthetic core event is
not one"). A drag is therefore:

```
xdotool mousemove --window <win> x0 y0 mousedown 1 \
        mousemove --window <win> x1 y1  ...  mousemove --window <win> xN yN \
        mouseup 1
```

Two mechanical requirements, both from GTK's side rather than xdotool's:
`GtkDragSource` is a `GtkGestureSingle` and only begins a drag after the
pointer has moved past the drag threshold with the button held (hence
several intermediate `mousemove` steps, not one jump), and each X11 leg
already has a private Xvfb, so the pointer is the leg's own.

### 6.3 Linux, Wayland half — **not possible with what the image has**

- `wl_data_device.start_drag` requires "an active implicit grab that
  matches the serial", i.e. a real pointer button press.
- The image installs `wtype` (a **virtual KEYBOARD** client) and nothing
  that injects pointer input. The seat is deliberately capability-less
  (`WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1`).
- Two routes exist, neither in the tree today:
  1. **`swaymsg 'seat <name> cursor set <x> <y>'` / `'seat <name> cursor
     press button1'` / `'… release button1'`** — sway ships in the image
     already, so this costs no new package. Per sway-input(5) these accept
     `button[1-9]`, event names, or libinput event codes. **Both
     subcommands are marked DEPRECATED in favour of the virtual-pointer
     protocol**, which is a maintenance risk to name.
  2. **`zwlr_virtual_pointer_v1`** (wlr-virtual-pointer-unstable-v1) — a
     virtual pointer device attached to the seat, the pointer twin of the
     virtual keyboard `wtype` uses. wlroots implements it; there is no
     packaged CLI for it in Debian's archive (`wlrctl` is not in trixie),
     so it means a small vendored client, which §5b already contemplated
     for the seat-flag problem ("a ~20-line patch … or a vendored
     micro-client we own").
- **The session-architecture hazard is live here.** §5b measured that a
  persistent seat KEYBOARD makes keyboard focus exclusive and cost three
  legs in one pooled sway session; a persistent seat POINTER is the same
  family and untested. The ledger's "wayland lane session architecture"
  entry (docs/deferred.md:901-926) already names the exit and says what
  triggers it: "TRIGGERS: the first feature needing a persistent seat
  keyboard (IME, key repeat, compositor-level shortcut injection)".
  **A drag verb is a new trigger for that entry**, and per-leg sway
  instances (measured 55ms to socket) is the answer it prescribes.
- `ydotool`/`dotool` remain disqualified for the reason §5b already
  recorded: "they need a privileged container plus a libinput backend,
  and the kernel-level keyboard they create is PERSISTENT — the exact
  exclusivity this note exists to avoid."

### 6.4 Windows — two routes, and a documented collision with the lane

**Route A — `UIElement.StartDragAsync(PointerPoint)`.** Documented as
the programmatic drag start: "you can call [it] to programmatically
initiate a drag operation on any UIElement. Calling this method results
in the DragStarting event being raised." Two problems:
1. **It needs a `PointerPoint`.** `Microsoft.UI.Input.PointerPoint` has no
   public constructor; it is obtained from
   `PointerRoutedEventArgs.GetCurrentPoint(UIElement)` or the static
   `PointerPoint.GetCurrentPoint(UInt32 pointerId)`. Whether the latter
   answers for the mouse with no pointer message in flight is
   **UNVERIFIED and must be probed**.
2. **"Not supported if a user runs the app in elevated mode, as an
   administrator."** — and **tools/deploy-win.py launches every leg with
   `schtasks … /it /rl highest`** (lines 1586-1589, and the same for the
   probe and the one-shot scripts). `/rl highest` is run-elevated. If the
   VM's account is an administrator, every kaya leg is elevated, so this
   route is documented as unsupported on the lane as it stands today.
   The same elevation also blocks cross-process drags from a
   non-elevated Explorer (Windows' UIPI refuses drops from lower to
   higher integrity).
3. Even if it starts, `StartDragAsync` alone does not MOVE the pointer;
   the drag then follows the real cursor. So a drop still needs pointer
   motion.

**Route B — synthetic mouse input, and THE TREE ALREADY DOES THIS.**
Microsoft's own answer for automating a drag is "sending mouse input to a
control", and `crates/kaya/src/winui/title-centre-probe.ps1` performs a
real mouse drag today (lines 64-65 and 234-243):

```powershell
[DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
[DllImport("user32.dll")] public static extern void mouse_event(uint f, uint dx, uint dy, uint d, IntPtr e);
...
[U]::SetCursorPos($gx, $gy); [U]::mouse_event([U]::LEFTDOWN, 0, 0, 0, [IntPtr]::Zero)
for ($i = 1; $i -le 20; $i++) { [U]::SetCursorPos(($gx - $i * 12), $gy); Start-Sleep -Milliseconds 40 }
[U]::mouse_event([U]::LEFTUP, 0, 0, 0, [IntPtr]::Zero)
```

Its own comment states the shape a drag verb needs: "A LIVE RESIZE,
driven by a real drag of the window's right border: a continuous
WM_SIZING stream, not one SetWindowPos", with 20 intermediate moves at
40ms and a 200ms settle after the button-down. `tools/win/undoprobe/probe.rs`
does the same in Rust (SetCursorPos + `mouse_event` 0x0002/0x0004/0x0008/0x0010).
**So the Windows drag verb is a port of an existing, working probe, not
new ground** — and note both use the older `mouse_event`, not `SendInput`;
either is fine, `SendInput` being the modern spelling.

harness.rs's own `type_text` contract already names `SendInput` as
Windows' member of "THE PLATFORM'S OWN INPUT PATH" (harness.rs:889), so
the doctrine for a drag verb is written down.

**A synthesized drag DOES enter the OLE modal loop correctly** — SendInput places real
messages in the target thread's queue, and `DoDragDrop`'s loop reads the
queue; there is no "synthetic" flag that OLE filters on. The two real
risks are (a) the guest session must be the interactive one (it is:
`schtasks /it`, and clipboard §6 finding 1 already established every
harness verb must be a CHILD OF THE GUEST rather than an ssh session),
and (b) elevation/UIPI, as above.

### 6.5 What a scene could assert BYTE-IDENTICALLY

The existing observable vocabulary already covers the outcome without a
single new verb:

- **A reorder drag**: `expect_order column#0 "b|c|a"` — the existing
  `reorder` scene's own assertion, over a drag instead of a button. That
  is the strongest possible shape, because the SAME expected string is
  already green on five lanes through the programmatic route.
- **A drop's payload**: whatever the guest does with it, observed through
  `expect` / `expect_rows` / `expect_entries`. And since drop is
  `on_paste` with a third trigger, `expect_clipboard`'s frozen-string
  discipline (`ExpectClipboard(String, String)`) is the model.
- **A rejected drop** (the deadline degradation): `expect_order` UNCHANGED
  plus whatever the guest writes on rejection. This is the row of the
  degradation table that most needs a leg, because it is the only one
  that is a DESIGN PROMISE rather than a platform behaviour.

What NO shared scene can observe, and therefore needs the gate treatment
this repo already uses for the table tier and the table card:
- the **cursor badge** (`gdk_drop_status` preferred action /
  `DragUIOverride.Caption`) — no observable anywhere;
- the **drag icon** — a `GdkPaintable` on GTK, `DragUI` on WinUI; pixels
  only, and not in any window capture (the icon is a compositor/shell
  surface, not the app's window);
- **which tier answered** — whether GTK used DropTarget or
  DropTargetAsync, or whether WinUI's built-in ListView reorder ran
  instead of kaya's own path. That is check-table-tier's exact shape.

## §7 — CARVE-OUTS a uniform design would have to state

1. **Wayland cannot start a drag without a pointer grab.** Not an API
   gap, a protocol rule ("The client must have an active implicit grab
   that matches the serial"). Uniform semantics survive; the LANE does
   not, and the fix is the lane's (per-leg sway + a pointer injector),
   not the backend's — same shape as the clipboard's F24 tap.
2. **`GDK_ACTION_ASK` has no Windows analogue.** `DataPackageOperation`
   is None/Copy/Move/Link. If kaya's operation vocabulary includes `ask`
   it is Linux-only; recommend it is NOT in the vocabulary.
3. **`GDK_ACTION_LINK` is documented "not supported on all platforms"**
   even within GTK. Windows and macOS both have link. Either kaya drops
   `link` from the closed vocabulary (copy/move only, which covers every
   archetype app) or it states GTK's hedge.
4. **GtkDropTarget filters by GType; kaya's accept list is mime-shaped.**
   `html` and `custom(id,…)` have no GType, so kaya must use
   GtkDropTargetAsync uniformly. Stating this once beats discovering it
   when `custom` silently never arrives.
5. **WinUI's built-in ListView reorder mutates the ItemsSource itself**,
   which kaya's model forbids. kaya declines the native feature and
   hand-builds row drags on all four backends. (Cost: WinUI's own
   insertion indicator and animations are declined with it.)
6. **Explorer -> WinUI 3 Desktop file drop is a known-broken path**
   (microsoft-ui-xaml #10119, duplicate of #8108; App SDK 1.6.1, Win11
   26100.2161: `DragOver` never fires from the Desktop or a folder view,
   though Recent items works). And `UIElement.AllowDrop`'s own reference
   page still states "A UI element can't be a drop target for any
   drag-drop action that begins from outside the current app", flatly
   contradicting the overview page's "works in all directions". **Probe
   before promising**; the fallback is the OLE route (`RegisterDragDrop`
   + kaya's own `IDropTarget` on the HWND), which is the same
   classic-Win32-instead-of-WinRT move clipboard §6 already made and
   which reuses `parse_dropfiles` unchanged.
7. **Windows drag and drop forces kaya to meet WinRT DataTransfer**,
   which clipboard §6 finding 2 deliberately avoided on three measured
   charges. The one that bites is the custom-format bridge, "documented
   only in the read direction … Microsoft records the write side of that
   bridge as asymmetric". `custom(id, bytes)` crossing a process boundary
   on a Windows drag is UNPROVEN and is the highest-value probe.
8. **StartDragAsync is unsupported when elevated**, and the lane runs
   every leg `schtasks /it /rl highest`. Either the lane stops running
   elevated for drag legs, or the drag verb is SendInput-only on Windows.
9. **Windows synthetic input is already proven on the lane** — this is
    the one carve-out that turns out NOT to be one:
    crates/kaya/src/winui/title-centre-probe.ps1 and
    tools/win/undoprobe/probe.rs both drive real mouse drags in the
    guest session today.
10. **The drag icon is not observable on any platform** and the badge is
   not observable on any platform. Both are cosmetic by DESIGN's own
   degradation table ("Wrong cursor badge … cosmetic"), so a gate rather
   than a leg is the honest wall.
11. **The lazy-provision contradiction** (DESIGN's drag paragraph vs the
    clipboard's "lazy rendering: deliberately out"). Not a platform
    carve-out — an internal one, and it needs a ruling before any arm is
    written.

## §8 — Version notes

- **GTK**: the lane's Debian trixie ships GTK **4.18** (libgtk-4-dev in
  tools/linux/Dockerfile, pinned image digest
  `debian@sha256:fac46bff…`). Every API cited here is GTK 4.0-era except
  `GtkDropTarget:current-drop` (since 4.4, replacing the deprecated
  `:drop`). Nothing cited needs anything newer than 4.4.
- **Windows App SDK**: kaya pins WinUI **2.2.1**, Foundation 2.1.0,
  InteractiveExperiences 2.0.15, Runtime 2.2.0
  (tools/fetch-winappsdk.sh:89-98). The reference pages carry the
  `windows-app-sdk-2.0` moniker; `CanDrag`, `AllowDrop`, `DragStarting`,
  `DropCompleted`, `StartDragAsync`, `DragEventArgs` and
  `ListViewBase.CanReorderItems` all apply from 1.0 through 2.0.
- `Windows.ApplicationModel.DataTransfer` (DataPackage, DataPackageView,
  DataPackageOperation, StandardDataFormats) is a Windows namespace, from
  UniversalApiContract v1.0 — it comes out of the bindgen's `--in default`
  metadata, not the App SDK winmds.
- **Wayland**: `wl_data_device` version 3 semantics
  (`wl_data_offer.finish` / `set_actions` are v3+); wlroots 0.18.x is
  what the lane's sway links.

## §9 — Loose ends worth carrying into the design pass

- **GTK version is measured, not assumed**: `pkg-config --modversion gtk4`
  on the lane image is **4.18.6** (docs/deferred.md:4656,
  docs/traps.md:6403). Every API cited is 4.0-era; the newest is
  `GtkDropTarget:current-drop` (4.4).
- **`GdkDragCancelReason`** has exactly three members:
  `NO_TARGET` (0) "There is no suitable drop target",
  `USER_CANCELLED` (1) "Drag cancelled by the user",
  `ERROR` (2) "Unspecified error". WinUI's cancel is
  `DropResult == DataPackageOperation.None` with no reason at all — so
  a uniform "why did it fail" is NOT expressible; if kaya reports a
  reason it is GTK-only. (Per the diagnostics rule in CLAUDE.md
  invariant 3, that argues for reporting no reason at all rather than
  one that can only discriminate on one platform.)
- **`GtkDropControllerMotion`** exists alongside DropTarget for
  "dynamic interface updates — such as scrolling or page switching —
  triggered by hovering during active drag operations". That is the
  auto-scroll a long-list reorder needs; WinUI's ListView does its own
  auto-scroll during `CanReorderItems`. If kaya declines
  `CanReorderItems` (carve-out 5), it inherits the job of auto-scrolling
  on Windows too, and that is a real cost to put in front of the
  maintainer.
- **`gtk_drag_check_threshold`** is what turns pointer motion into a
  drag; a synthesized drag must exceed it with the button held. It is
  also why the drag gesture and a click are the same press on GTK — a
  row that is both clickable and draggable needs the gesture ordering
  thought through, and `GtkDragSource` is a `GtkGestureSingle` that can
  be given a `propagation-phase` for exactly that.

### The three probes to run before anything is designed

Ranked by how much a wrong assumption would cost:

1. **Windows, `custom(id, bytes)` across a process boundary via
   `DataPackage.SetData`** — this is the one Microsoft records as an
   asymmetric bridge, and kaya's whole `custom` escape hatch rests on
   it. Shape: a a `dragprobe` directory under tools/win in the interactive session, the
   §6 probe's own pattern.
2. **Windows, whether an Explorer file drop reaches a WinUI 3 window at
   all on the VM**, elevated and non-elevated (issue #10119 vs the
   overview's "works in all directions"). This decides between the XAML
   route and the OLE `RegisterDragDrop` route for the single most-wanted
   scenario.
3. **Wayland, whether `swaymsg 'seat - cursor press button1'` gives a
   GDK client a serial that `wl_data_device.start_drag` accepts**, and
   whether attaching a pointer to the pooled seat disturbs the eight
   pooled legs the way a persistent keyboard did. This decides whether
   the wayland drag legs need the per-leg-sway slice first.

## §10 — Sources

GTK / GDK (docs.gtk.org, GTK 4.0 / GDK 4.0 reference; lane runs 4.18.6):
- https://docs.gtk.org/gtk4/drag-and-drop.html
- https://docs.gtk.org/gtk4/class.DragSource.html
- https://docs.gtk.org/gtk4/class.DropTarget.html
- https://docs.gtk.org/gtk4/signal.DropTarget.accept.html
- https://docs.gtk.org/gtk4/signal.DropTarget.drop.html
- https://docs.gtk.org/gtk4/class.DropTargetAsync.html
- https://docs.gtk.org/gtk4/signal.DropTargetAsync.drop.html
- https://docs.gtk.org/gtk4/class.DropControllerMotion.html
- https://docs.gtk.org/gdk4/class.ContentProvider.html
- https://docs.gtk.org/gdk4/class.Drag.html
- https://docs.gtk.org/gdk4/class.Drop.html
- https://docs.gtk.org/gdk4/method.Drop.status.html
- https://docs.gtk.org/gdk4/flags.DragAction.html
- https://docs.gtk.org/gdk4/enum.DragCancelReason.html
- https://gtk-rs.org/gtk4-rs/stable/latest/docs/gtk4/struct.DragSource.html
- https://gtk-rs.org/gtk4-rs/stable/latest/docs/gtk4/struct.DropTarget.html
- https://discourse.gnome.org/t/drag-dropping-files-with-gtk4/6084/2 (GDK_TYPE_FILE_LIST / GdkFileList)

Wayland / sway:
- https://wayland.app/protocols/wayland#wl_data_device:request:start_drag
- https://man.archlinux.org/man/sway-input.5 (`seat <name> cursor move|set|press|release`, both deprecated in favour of virtual-pointer)
- https://wayland.app/protocols/wlr-virtual-pointer-unstable-v1

WinUI 3 / Windows App SDK (learn.microsoft.com, `windows-app-sdk-2.0` moniker):
- https://learn.microsoft.com/en-us/windows/apps/design/input/drag-and-drop (redirects to /windows/apps/develop/data/drag-and-drop, ms.date 2026-07-15)
- https://learn.microsoft.com/en-us/windows/windows-app-sdk/api/winrt/microsoft.ui.xaml.uielement.allowdrop
- https://learn.microsoft.com/en-us/windows/windows-app-sdk/api/winrt/microsoft.ui.xaml.uielement.startdragasync
- https://learn.microsoft.com/en-us/windows/windows-app-sdk/api/winrt/microsoft.ui.xaml.drageventargs
- https://learn.microsoft.com/en-us/uwp/api/windows.ui.xaml.dragstartingeventargs
- https://learn.microsoft.com/en-us/uwp/api/windows.applicationmodel.datatransfer.datapackage
- https://learn.microsoft.com/en-us/uwp/api/windows.applicationmodel.datatransfer.datapackageoperation
- https://learn.microsoft.com/en-us/uwp/api/windows.applicationmodel.datatransfer.standarddataformats
- https://learn.microsoft.com/en-us/windows/windows-app-sdk/api/winrt/microsoft.ui.xaml.controls.listviewbase.canreorderitems
- https://learn.microsoft.com/en-us/windows/windows-app-sdk/api/winrt/microsoft.ui.input.pointerpoint
- https://learn.microsoft.com/en-us/windows/win32/winauto/uiauto-implementingdrag (UIA Drag pattern is read-only)
- https://learn.microsoft.com/en-us/windows/win32/api/ole2/nf-ole2-registerdragdrop (message-pumping requirement)
- https://learn.microsoft.com/en-us/windows/desktop/api/ole2/nf-ole2-dodragdrop (the modal loop)
- https://github.com/microsoft/microsoft-ui-xaml/issues/10119 (closed as duplicate of #8108) and /issues/2715

Repo (all paths absolute under /Users/akhilindurti/Projects/kaya):
- DESIGN.md:3044-3054 (the drag case analysis), :3300-3312 (degradation table), :2312+ (Clipboard)
- docs/clipboard-plan.md §0 (representation grammar, "Paste and drop are the same event"), §5b (GDK probe, the Wayland serial), §6 (Windows, classic Win32 over WinRT DataTransfer)
- docs/deferred.md:1742-1746 (drag still open), :901-926 (wayland lane session architecture)
- crates/kaya/src/gtk.rs:7423-7500 (the Copy arm's providers), :10417-10437 (programmatic click), :10457-10740 (`type_text`, the real-input precedent)
- crates/kaya/src/winui/mod.rs:8466-8760, 12211-12251 (classic Win32 clipboard), :16061/:16717 (programmatic click via automation peer)
- crates/kaya/src/winui/bindings.rs:6800, 6988 (AllowDrop/CanDrag generated), ~9595-9625 (DragStarting/DropCompleted/DragEnter/DragOver/DragLeave/Drop are `usize` PADS)
- tools/winui-bindgen/src/main.rs (the filter, and its own transitivity notes)
- tools/fetch-winappsdk.sh:89-98 (the pinned SDK versions)
- tools/linux/Dockerfile (xdotool, wtype, sway, no pointer injector)
- tools/deploy-win.py:1586-1589 (`schtasks … /it /rl highest`)
- crates/kaya/src/winui/title-centre-probe.ps1:64-65, 234-243 (a REAL mouse drag, already working in the guest session)
- tools/win/undoprobe/probe.rs:34-35, 450-456 (the same, in Rust)
- crates/kaya/src/harness.rs:875-905 (the Stage trait and `type_text`'s six-point real-input contract)
- crates/kaya/src/spec.rs:511 (`collection_move`), tools/scenes/reorder.steps
