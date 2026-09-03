# Dirty-state probe — MOBILE arm (research)

Probe for the dirty-state window-titles milestone. RESEARCH arm: no device
work, no repo changes, nothing here ships. Question served: kaya may add a
`dirty` attribute to the window construct; each backend lowers it to its
platform's chrome, and a scene must be able to ASSERT the result. On mobile
the prior question is whether there is any chrome to lower to at all.

Fact grades used throughout:
- **[DOC]** — stated in first-party vendor documentation (Apple/Google), URL given.
- **[API]** — a named API exists with the documented behavior; the claim is about
  the API surface, not about what apps do with it.
- **[OBS]** — observed/reported behavior of a shipping app, from a secondary
  source (release notes, support docs, forum). Not first-party spec.
- **[CONV]** — convention claim: "this is what apps generally do." Weakest grade.
  Never used as the basis of a lowering recommendation on its own.

Status: IN PROGRESS.

---

## 1. iOS — the auto-save idiom

### 1.1 There IS a dirty bit. It is private to the framework.

`UIDocument.hasUnsavedChanges` exists and is exactly the flag kaya's `dirty`
would name. **[DOC]** Its documented consumer is the autosave machinery, not
any chrome:

> A Boolean value that indicates whether the document has any unsaved changes.
> […] The default implementation of `autosave(completionHandler:)` initiates a
> save if this property returns `true`. Typical subclasses don't need to
> override `hasUnsavedChanges`. To implement change tracking, they should
> instead use an `UndoManager` object (assigned to `undoManager`) to register
> changes or call `updateChangeCount(_:)` every time the user makes a change;
> UIKit then automatically determines whether there are unsaved changes.

<https://developer.apple.com/documentation/uikit/uidocument/hasunsavedchanges>

Apple names the design "the saveless model" and states its purpose is to remove
save from the user's vocabulary **[DOC]**:

> The saveless-model feature of the `UIDocument` class ensures that document
> data is automatically saved at frequent intervals, relieving users of the need
> to explicitly save their documents.

> Periodically, UIKit calls the `hasUnsavedChanges` method of a `UIDocument`
> object and evaluates the returned value. If the value is `YES`, it saves the
> document data to the document file. The period between checks of the
> `hasUnsavedChanges` value varies according to several factors, including the
> rate of input by the user.

<https://developer.apple.com/library/archive/documentation/DataManagement/Conceptual/DocumentBasedAppPGiOS/ChangeTrackingUndo/ChangeTrackingUndo.html>

Note what the guide does NOT say: it never mentions showing the user a dirty
indicator, and it gives no fixed autosave interval (the widely repeated
"~15 seconds" figure is **[CONV]**, not in the doc — the doc says only that the
period "varies").

**Reading for kaya:** iOS's own document stack computes the dirty bit and
deliberately spends it on *scheduling I/O*, never on *chrome*. A `dirty`
attribute is therefore expressible on iOS; what has no iOS counterpart is the
assumption that declaring it should make something visible.

### 1.2 SwiftUI's DocumentGroup hides the bit entirely

**[DOC]** `DocumentGroup` — "A scene that enables support for opening, creating,
and saving documents":

> For a value-type document, like a `struct`, SwiftUI tracks edits through the
> document binding. For a reference-type document, like a `class`, it tracks
> changes you register with `EnvironmentValues.undoManager`. SwiftUI writes the
> document back to disk when needed — for example, in response to a Save command.

<https://developer.apple.com/documentation/swiftui/documentgroup>

There is no public `hasUnsavedChanges` on the SwiftUI side and no author-facing
save call in the documented examples. On the modern iOS document API the dirty
bit is not merely unsurfaced, it is **not readable by the app author at all**.
That matters directly for kaya's SwiftUI backend, which is the iOS backend.

---

## 2. iOS — where dirty state IS visible: dismissal, not chrome

The maintainer's hypothesis is confirmed by the HIG. iOS's dirty-state
affordance is a *confirmation on discard*, and it is scoped to sheets.

**[DOC]** HIG, Sheets, iOS/iPadOS platform considerations:

> **Support swiping to dismiss a sheet.** People expect to swipe vertically to
> dismiss a sheet instead of tapping a dismiss button. If people have unsaved
> changes in the sheet when they begin swiping to dismiss it, use an action
> sheet to let them confirm their action.

**[DOC]** Same page, anatomy/best practices:

> If you provide a Done button, always pair it with a Cancel button to give
> people a clear way to dismiss the sheet without confirming or saving their
> changes […]

> **Cancel (or Close) button** — dismisses a sheet without saving any changes.
> **Done button** — dismisses a sheet after completing a task or explicitly
> saving changes.

<https://developer.apple.com/design/human-interface-guidelines/sheets>

This is the single place in Apple's mobile guidance where "unsaved changes"
drives an observable UI behavior. It is a *transition* affordance, not a
*persistent* one — nothing renders while the document merely sits dirty.

### 2.1 The UIKit API behind it

**[DOC]** `UIViewController.isModalInPresentation`:

> The default value of this property is `false`. When you set it to `true`,
> UIKit ignores events outside the view controller's bounds and prevents the
> interactive dismissal of the view controller while it is onscreen.

<https://developer.apple.com/documentation/uikit/uiviewcontroller/ismodalinpresentation>

**[DOC]** `UIAdaptivePresentationControllerDelegate` supplies the hooks
(<https://developer.apple.com/documentation/uikit/uiadaptivepresentationcontrollerdelegate>):

| method | abstract |
| --- | --- |
| `presentationControllerShouldDismiss(_:)` | Asks the delegate for permission to dismiss the presentation. |
| `presentationControllerDidAttemptToDismiss(_:)` | Notifies the delegate that a user-initiated attempt to dismiss a view was prevented. |
| `presentationControllerWillDismiss(_:)` | Notifies the delegate before a presentation is dismissed. |
| `presentationControllerDidDismiss(_:)` | Notifies the delegate after a presentation is dismissed. |

**[DOC]** `presentationControllerDidAttemptToDismiss(_:)` discussion:

> UIKit supports refusing to dismiss a presentation when the
> `presentationController.isModalInPresentation` returns `true` or
> `presentationControllerShouldDismiss(_:)` returns `false`.
> Use this method to inform the user why the presentation can't be dismissed,
> for example, by presenting an instance of `UIAlertController`.

So the documented UIKit shape of "declare dirty, get a confirmation" is:
set `isModalInPresentation = true` (or return `false` from
`presentationControllerShouldDismiss`) when dirty, then present the
confirmation from `presentationControllerDidAttemptToDismiss`. Note Apple's own
API doc says *alert*; the HIG says *action sheet*. Minor divergence, worth
knowing before writing an expected string.

### 2.2 SwiftUI cannot express the confirmation without dropping to UIKit

This is the sharpest finding in the iOS half, and it directly constrains
kaya's SwiftUI backend.

**[DOC]** `interactiveDismissDisabled(_:)`, iOS 15.0+:

> Conditionally prevents interactive dismissal of presentations like popovers,
> sheets, and inspectors.
> […] Use the `interactiveDismissDisabled(_:)` modifier to conditionally prevent
> this kind of dismissal. You typically do this to prevent the user from
> dismissing a presentation before providing needed data or completing a
> required action.
> […] The modifier has no effect on programmatic dismissal […]

<https://developer.apple.com/documentation/swiftui/view/interactivedismissdisabled(_:)>

The modifier takes a `Bool` and returns a view. **It has no attempt callback.**
It is the exact analogue of `isModalInPresentation` — the blocking half — with
no analogue of `presentationControllerDidAttemptToDismiss` — the *tell the user
why* half. A pure-SwiftUI app that sets it on a dirty sheet produces a sheet
that silently refuses to move, with no confirmation and no explanation, which is
the opposite of the HIG's instruction. **[CONV]** The community's standing
workarounds are (a) wrap in `UIViewControllerRepresentable` to get the delegate
back, or (b) abuse `presentationDetents` as a drag threshold:
<https://livsycode.com/swiftui/intercepting-swiftui-sheet-dismissal/>,
<https://fatbobman.com/en/posts/newinteractivedismissdiabled/>

Per the ratified backend roster, kaya's iOS backend is the SwiftUI interpreter,
so an "arm the discard confirmation" lowering on iOS lands on the side of this
gap, not the side with the API.

---

## 3. iOS — is there scene/window-level dirty chrome? Almost.

### 3.1 There is a scene title, and it is not a document title

**[DOC]** `UIScene.title`, iOS 13.0+ — "A user-visible string you supply to help
users differentiate among your app's scenes."

> The system displays this string in the app switcher to make it easier for the
> user to differentiate among your app's scenes. Set this property to an empty
> string if you don't want the app switcher to display anything for the scene.
> iPad and iPhone apps running on a Mac with Apple silicon and apps built with
> Mac Catalyst display the title in the title bar of the scene's window.

<https://developer.apple.com/documentation/uikit/uiscene/title>

So on iPhone/iPad proper the scene title renders **only in the app switcher** —
a place the user is not looking while editing, and a place a harness cannot
screenshot from inside the app. The title-bar rendering is explicitly scoped to
Catalyst and iOS-apps-on-Apple-silicon-Macs, i.e. the desktop arm's territory.

### 3.2 There is no `isDocumentEdited` on iOS

macOS has `NSWindow.isDocumentEdited`, which puts the dot in the close button.
**No UIKit counterpart exists** — no property on `UIScene`, `UIWindowScene`, or
`UIViewController` marks a scene as edited, and nothing in iPadOS 26's new
window controls surfaces one. **[OBS/CONV]** iPadOS 26 gained traffic-light
window controls (close/minimize/resize) with a draggable title bar, and the
coverage of that feature describes close/minimize/zoom with no edited-state
indicator:
<https://appleinsider.com/inside/ipados-26/tips/whats-new-with-ipad-app-windows-in-ipados-26-and-how-they-work>,
<https://support.apple.com/en-us/125309>
I could not find a first-party statement either way; grade this a
**documented absence of the API**, not a proven absence of the pixel.

### 3.3 iOS 27 (beta, current) adds a scene-close confirmation — no indicator

This is the newest and most relevant API, and it arrived after the last
milestone. **[DOC]** `UISceneClosureConfirmation` —

> A configuration specifying a confirmation dialog that will be shown before a
> user action will result in destruction of the scene session and the
> disconnection of the scene.

`@MainActor class UISceneClosureConfirmation`, availability **iOS 27.0+ beta,
iPadOS 27.0+ beta, Mac Catalyst 27.0+ beta**.
Initializer `init(title:message:actions:)`; a `.destructive` `UIAlertAction`
replaces the default "Close" button, `.cancel` replaces "Cancel".
<https://developer.apple.com/documentation/uikit/uisceneclosureconfirmation>

**[DOC]** `UIWindowScene.closureConfirmation` —
`@NSCopying var closureConfirmation: UISceneClosureConfirmation? { get set }`,
same iOS 27.0+ beta availability. Abstract: "A configuration describing a
confirmation dialog to be shown when a user action will result in destruction of
the scene session and disconnection of the scene."
<https://developer.apple.com/documentation/uikit/uiwindowscene/closureconfirmation>

> **Correction worth recording.** A web search summary asserted this API is
> "iOS 17+". The primary documentation says **iOS 27.0+ beta**. The search
> summary was wrong by ten major versions. Every version claim in this report
> was re-checked against `developer.apple.com` JSON for this reason.

Two limits on this API, both material to kaya:
1. Apple's doc carries **no discussion section** — the abstract is the whole
   specification. It does not enumerate which user actions trigger it (window
   close button? app-switcher swipe? keyboard shortcut?), and it never mentions
   documents or unsaved changes. The one worked example in the docs is a
   *video-meeting* app ("Leave or End meeting?"), not an editor. It is a generic
   scene-destruction hook that unsaved-changes is merely one use of.
2. It is **UIKit-only and beta**. I found no SwiftUI scene modifier equivalent
   in iOS 27; the SwiftUI iOS 27 changes in this area are new
   optional-value-bound `alert`/`confirmationDialog` overloads, which are
   unrelated. **[OBS]**
   <https://www.swiftjectivec.com/ios-27-notable-uikit-additions/>

Even here, note the shape: iOS's answer to dirty state is **a dialog at the
moment of destruction**, never a persistent mark on chrome.

---

## 4. iOS — what shipping editors actually do

### 4.1 First-party: save-less, no indicator

**[DOC]** Apple Support, Pages on iPad: "Pages automatically saves your document
as you work and gives it a default name." The page documents no Save button.
<https://support.apple.com/guide/pages-ipad/save-and-name-a-document-tan95caaa4ff/ipados>

Notes has never had a save button; its editing model is continuous. **[CONV]**

### 4.2 Third-party serious editors: also save-less, and the indicator is a
### standing unmet feature request

**Textastic** (long-running iOS code editor) is the cleanest data point because
its author documents the policy and the users argue with it.

**[DOC]** Textastic manual, "When does Textastic save file changes?":
Textastic automatically saves file changes every 10 seconds and when the file is
closed to open another file; the manual describes following Apple's
recommendation to minimize explicit save prompts, and documents no save button
and no unsaved-changes indicator.
<https://www.textasticapp.com/manual/lessons/When_does_Textastic_save_file_changes.html>

**[OBS]** Textastic feedback forum, "Show which files have been
changed/modified since download": users request asterisk/colour badges for
modified files; the developer marked it **Planned**, with **161 votes**, and it
is not shipped.
<https://feedback.textasticapp.com/communities/1/topics/681-show-which-files-have-been-changedmodified-since-download>
Be precise about what this shows: the request is for *local-vs-remote sync*
divergence, not *unsaved buffer* state. It is still the closest thing to a
user-side demand for a dirty mark on iOS I could find, and it has gone unmet
for years.

**iA Writer**: autosaves continuously; no save button. **[OBS]**
<https://ia.net/writer/support/help/icloud>

**Working Copy** (git client) *does* show dirty state — a badge on the Changes
tab with lines added/deleted, a Status tab saying whether the file is modified.
**[DOC]** <https://workingcopyapp.com/manual/file-changes/>
But read what that is: dirtiness is Working Copy's **subject matter** (VCS
working-tree status), rendered in **content**, in a tab, by the app. It is not
window chrome and it is not the framework's document-dirty bit. It is evidence
for the opposite conclusion — on iOS, if you want dirty visible, you draw it
yourself in your own content.

**Verdict for iOS conventions:** the save-less model is not just the default,
it is near-universal, and no editor surveyed puts a dirty mark in anything a
platform would call chrome.

---

## 5. Android — the equivalent story

### 5.1 No dirty chrome exists, at any layer

There is no Android analogue of `NSWindow.isDocumentEdited`. Searching the
window/activity/task surfaces turns up only *identity* APIs, never *state*:

- `Activity.setTitle` / the manifest `android:label` — labels the app bar.
- `ActivityManager.TaskDescription` — sets the **label, colour and icon shown in
  the Recents screen**. **[DOC]**
  <https://developer.android.com/reference/android/app/ActivityManager.TaskDescription>
  Like `UIScene.title`, this is a switcher-only string, not chrome the user sees
  while editing, and it carries no edited flag.
- Android's desktop windowing (freeform windows, Android 15/16) draws a caption
  bar with the app icon/name and maximize/minimize/close controls. **[OBS]**
  <https://www.androidauthority.com/android-16-minimize-desktop-windows-3535415/>
  No public API marks that caption as edited, and none of the coverage describes
  such an indicator.

So on Android the answer to "what chrome does dirty lower to" is, as far as
public API goes, **nothing**. This is a stronger negative than iOS's: iOS at
least has the iOS 27 scene-closure hook.

### 5.2 Where dirty state IS expressible: back, declared ahead

Android's mechanism is `OnBackPressedCallback`, and its critical property is
that arming is **declared in advance via a Boolean**, not decided when the
gesture arrives.

**[DOC]** "Provide custom back navigation":

> The constructor for `OnBackPressedCallback` takes a boolean for the initial
> enabled state. Only when a callback is enabled, for example when `isEnabled()`
> returns `true`, will the dispatcher call the callback's `handleOnBackPressed()`
> to handle the Back button event. You can change the enabled state by calling
> `setEnabled()`.

<https://developer.android.com/guide/navigation/custom-back>

**[DOC]** Compose spelling — `androidx.activity.compose.BackHandler`:

```kotlin
@Composable
public fun BackHandler(enabled: Boolean = true, onBack: () -> Unit)
```
> An effect for handling presses of the system back button.
> @param enabled If `true`, this handler will be enabled and eligible to handle
> the back press.
> @param onBack The action to be invoked when the system back button is pressed.

<https://github.com/androidx/androidx/blob/androidx-main/activity/activity-compose/src/main/java/androidx/activity/compose/BackHandler.kt>

**[DOC]** The layer underneath, as of the 2025/26 rework — `androidx.navigationevent`,
"a KMP-first API for handling system back as well as Predictive Back"; stable
1.0.0 Nov 2025, latest stable **1.1.2 (2026-06-17)**, alpha 1.2.0-alpha03
(2026-07-29). `NavigationEventHandler` takes `isBackEnabled: Boolean` in its
constructor and exposes `onBackStarted` / `onBackProgressed` / `onBackCompleted`
/ `onBackCancelled`. The release notes state "The `androidx.activity` APIs have
been rewritten on top of the Navigation Event APIs".
<https://developer.android.com/jetpack/androidx/releases/navigationevent>

Note the shape is unchanged across the rewrite: a **declared-ahead Boolean**
gates interception. That is precisely the shape of a `dirty` attribute.

### 5.3 Google's own worked example for this Boolean is unsaved changes

This is the single most on-point citation in the Android half. **[DOC]**
"Add support for the predictive back gesture", describing the callback-stack
figure:

> In this example, the "Are you sure..." callback is enabled when the user
> enters data into a form, and disabled otherwise. The callback opens a
> confirmation dialog when the user swipes back to exit the form.

<https://developer.android.com/guide/navigation/custom-back/predictive-back-gesture>

And the accompanying discipline, which reads like it was written for kaya's
`dirty`:

> 1. Determine the UI state that enables and disables each callback.
> 2. Define that state using an observable data holder type, such as `StateFlow`
> or Compose State, and enable or disable the callback as the state changes.

> If your app was previously associating back logic with conditional statements,
> this might signify you are reacting to the back event after it has already
> occurred. Avoid this pattern with newer callbacks.

> It is easier to manage the enabled state of a callback if that callback has a
> single responsibility.

### 5.4 The price, measured from the vendor's own doc

Arming interception is not free on Android, and Google states the charge
explicitly:

> If your app enables an `OnBackPressedCallback` or an `OnBackInvokedCallback`
> with `PRIORITY_DEFAULT` or `PRIORITY_OVERLAY`, **the predictive back animations
> don't run** and you must handle the back event. Don't create these callbacks to
> run business logic or to log.

<https://developer.android.com/guide/navigation/custom-back/predictive-back-gesture>

**This is the concrete platform charge this probe was sent to find.** On
Android, declaring a surface dirty — if dirty arms back interception — costs the
user the predictive-back preview animation for as long as the flag is true. A
document the user edits once and leaves open is then a document whose back
gesture is permanently de-animated. Any `dirty` design that arms back
unconditionally is buying a persistent animation regression with a transient
state.

kaya already knows this. `crates/kaya/src/spec.rs` on `intercept_back`:

> off = the platform pops natively with its full predictive animation; on = the
> back affordance emits `back_requested` and nothing pops until the app answers
> with `pop_entry`

and DESIGN.md's Navigation section already identifies the model correctly:

> This is Android's own model — OnBackPressedCallback is declared-ahead
> enablement, not veto-at-gesture-time — so an armed interception taking over
> the gesture is the platform's semantics, not a kaya carve-out

The research confirms that reading, including after the `navigationevent`
rewrite.

### 5.5 Material guidance: a dialog, and its wording

Material's guidance covers the *dialog*, not any persistent indicator.
**[DOC]** Material (m1, static spec):

> Tapping "Cancel" in a confirmation dialog, or pressing "Back," cancels the
> action, discards any changes, and closes the dialog.

<https://m1.material.io/components/dialogs.html>
Material 2/3 guidance recommends explicit verbs over OK/Cancel, with "Discard"
as the example affirmative label for exactly this case. **[OBS]** — the m2/m3
pages are client-rendered and I could not extract them verbatim; graded down
accordingly. <https://m2.material.io/design/components/dialogs.html>

### 5.6 Google's own editors: save-less, with a transient *saved* indicator

**[OBS]** Google Docs autosaves continuously with no save button, and shows a
transient status ("Saving…" / "All changes saved in Drive" / "Saved to Drive")
in its toolbar. Google Keep likewise saves and syncs automatically with no save
button.
<https://support.google.com/docs/> (product behavior; the specific status
strings come from secondary write-ups, e.g.
<https://nerdtechy.com/does-google-docs-autosave>)

Observe the polarity: Google's indicator reports **saved**, transiently, after
the fact. It is a reassurance that the dirty window has closed — not a badge
that stays lit while work is unsaved. Nobody on mobile ships the persistent
"this is unsaved" mark that a desktop title-bar dot is.

---

## 6. Observability — how would a harness leg READ this?

The design question demands each claim answer its own assertability. On mobile
the answer is sharply bimodal, and kaya's existing harness code already draws
the line.

### 6.1 What kaya can read today

kaya already has the three verbs a confirmation needs — `expect_alert "<title>"`,
`alert_choose <0|1|cancel>`, `expect_alerts <n>` — exercised by
`tools/scenes/confirm.steps`. Their implementations reveal the constraint:

**SwiftUI** (`swift/KayaSwiftUI.swift:4396`) reads the real presented object:

```swift
return kayaLiveAlertController?.title ?? ""
```

with the stated rule in its own comment — "The REAL presented dialog's title
(NSAlert's messageText / the UIAlertController's title), never the request's
copy — a backend that materialized nothing must fail here." It can do this
because **the interpreter itself constructed and retained that
`UIAlertController`.** The same file already records the iOS limit on driving
it: "the real dismissal plus the SAME closure the pressed action runs (UIKit
exposes no public press)".

**Compose** (`KayaCompose.kt:3108`) is weaker still — it reads
`KayaSceneModel.alertTitle`, "the presented dialog's title off the model that
renders it". That is a model read, not a platform read.

Both are **in-process reads of objects kaya owns**.

### 6.2 What kaya could not read

- **`UISceneClosureConfirmation` is system-presented.** The app hands the system
  a *configuration* (`init(title:message:actions:)`) and the system builds and
  presents the dialog. kaya would retain the config, not the presented
  controller. Asserting against it is asserting the request's own copy —
  precisely what `expect_alert`'s comment forbids, and for the right reason: it
  cannot distinguish "the system presented it" from "the system ignored it".
  Worse, scene destruction on iPhone/iPad is initiated from the **app switcher**,
  outside the app: an in-process harness cannot drive the gesture that triggers
  the dialog at all.
- **Android's freeform caption bar is SystemUI**, a different process. Neither
  Compose semantics nor kaya's model can see it. Only a cross-window driver
  (UiAutomator) could, which is not what kaya's interpreter is.
- **`UIScene.title` / `TaskDescription` label** render in the app switcher /
  Recents — again outside the app's own window. kaya can *set* them and read
  back the value it set, which asserts nothing about materialization.

### 6.3 The honest rule this yields

A mobile `dirty` is assertable **exactly when it lowers to something kaya's own
interpreter draws**. An app-drawn confirmation (kaya's existing alert tier,
raised from a back/dismiss request) is fully assertable with verbs that already
exist and already have byte-compared expected strings. Anything that lowers to
system chrome or a system-presented dialog is, on mobile, **declarative-only**:
settable, unobservable, and therefore unable to satisfy invariant 4 ("a gate
that can be satisfied without exercising the real thing is a bug in the gate").

---

## 7. Synthesis for kaya — do / can't options, NOT a decision

Ratification is the maintainer's. What follows is the option space with the
measured charge on each.

### 7.0 The finding that reframes the question

kaya's window vocabulary **already ratified this territory**, and a mobile
`dirty` on the WINDOW tier collides with two standing rules:

- `veto_close` (`crates/kaya/src/spec.rs:209`) already carries the verdict:
  *"Inert on mobile by physics: no chrome close, and back is not close."*
- DESIGN.md, Presentation contexts: *"**Back never touches windows.** At the
  primary surface's root the back gesture belongs to the system (leave the app);
  kaya offers no interception in v1."*

Everything this probe measured agrees with both. A mobile window has no close
affordance to decorate and no dismissal to guard. **A window-level `dirty` is
inert on mobile for exactly the reason `veto_close` already is** — and that is a
precedent, not a new carve-out, which is the cheapest possible outcome for the
uniform-semantics invariant.

Meanwhile the two places mobile genuinely *does* express "confirm before losing
work" are the tiers kaya already has:
- **Modal dismissal** — the iOS sheet swipe-down confirmation (§2), Android's
  back-dismisses-dialog (§5.5). kaya's Modal presentations tier, whose cancel
  path is already "one uniform semantic slot with per-platform spelling: Esc on
  the desktops, the back gesture on Android, Cancel/swipe on iOS."
- **Navigation entry pop** — Google's own unsaved-form example (§5.3). kaya's
  `intercept_back` entry prop, which is already the declared-ahead Boolean that
  Android's API wants.

### Option A — `dirty` is a window prop, inert on mobile

**Do.** Lower to nothing on iOS and Android; document the inertness the way
`veto_close` already documents its own.
- Cost: zero. Precedent exists. Uniform semantics preserved by the existing
  carve-out shape ("the carve-out itself stated uniformly").
- Observability: nothing to assert on mobile; the mobile lanes simply do not
  wire the scene's dirty legs. `tools/check-stubs.py` already governs exactly
  this — a `depth_stub("<scene>")` call, not a sentence — so the "wired iff the
  backend has the feature" rule covers it mechanically.
- Honest? Yes, and it is the only option supported by *documented* platform
  chrome, because on mobile there is none.

### Option B — `dirty` arms a discard confirmation

**Can, partially, and the charge is real.**
- **Android**: expressible via the declared-ahead Boolean
  (`BackHandler(enabled=)` / `NavigationEventHandler(isBackEnabled=)`) — this is
  literally Google's worked example (§5.3). **Charge: predictive back animations
  stop running while armed** (§5.4, vendor-stated). A persistent flag buys a
  persistent animation regression.
- **iOS**: expressible for *sheets* — HIG-endorsed and the intended pattern
  (§2). But kaya's iOS backend is SwiftUI, and **SwiftUI's
  `interactiveDismissDisabled(_:)` has no attempt callback** (§2.2): pure SwiftUI
  can block the swipe but cannot show the confirmation the HIG asks for. Cost is
  a `UIViewControllerRepresentable` drop-down — which the ratified gap policy
  already permits ("interpreter-internal Representable/AndroidView drop-downs"),
  so this is *payable*, but it is real work in the interpreter, not a prop
  passthrough.
- **iOS, window/scene level**: `UISceneClosureConfirmation` exists but is **iOS
  27 beta**, UIKit-only, with no SwiftUI equivalent, no documented trigger list,
  and — decisively — **not assertable in-process** (§6.2).
- **The duplication problem**: at the entry tier this is `intercept_back` with a
  narrower name. At the modal tier it is the existing cancel slot. Adding
  `dirty` here risks two spellings for one mechanism, which the uniform-semantics
  invariant is hostile to.

### Option C — `dirty` renders in the title string

**Can't, honestly, on mobile.** Neither platform has a document title in chrome
the user sees while editing. `UIScene.title` is app-switcher-only on iPhone/iPad
(title-bar rendering is scoped to Catalyst / iOS-apps-on-Mac); Android's
`TaskDescription` label is Recents-only. A mutated title would be invisible in
normal use and unassertable in-process. This is the option to reject on measured
grounds.

### Option D — `dirty` is app-drawn content

**Do, if visibility is wanted.** Every mobile app that shows dirty state draws
it itself: Working Copy's Changes badge (§4.2), Google Docs' toolbar status
(§5.6). This needs no new kaya vocabulary — it is a label the guest sets — and
it is trivially assertable with `expect label#N`. Worth stating explicitly so
the milestone does not invent a prop for something the existing grammar covers.

### The one asymmetry the maintainer should weigh

`dirty` is a **desktop-shaped attribute**. macOS/Windows/GTK have a real
edited-state channel in chrome; mobile has none, and its two platform vendors
have spent fifteen years removing save from the user's model
(Apple: "relieving users of the need to explicitly save their documents";
Google: no save button anywhere). If `dirty` ships as a window prop it will be
a prop whose observable behavior exists on 3 backends and is inert on 2 — which
is allowed by the invariants, but only if the inertness is stated uniformly and
the mobile lanes' missing legs are governed by `check-stubs`, not by silence.

---

## 8. Sources

Primary (vendor documentation), all re-verified against the vendor domain:

- <https://developer.apple.com/documentation/uikit/uidocument/hasunsavedchanges>
- <https://developer.apple.com/library/archive/documentation/DataManagement/Conceptual/DocumentBasedAppPGiOS/ChangeTrackingUndo/ChangeTrackingUndo.html>
- <https://developer.apple.com/documentation/swiftui/documentgroup>
- <https://developer.apple.com/design/human-interface-guidelines/sheets>
- <https://developer.apple.com/documentation/uikit/uiviewcontroller/ismodalinpresentation>
- <https://developer.apple.com/documentation/uikit/uiadaptivepresentationcontrollerdelegate>
- <https://developer.apple.com/documentation/uikit/uiadaptivepresentationcontrollerdelegate/presentationcontrollerdidattempttodismiss(_:)>
- <https://developer.apple.com/documentation/swiftui/view/interactivedismissdisabled(_:)>
- <https://developer.apple.com/documentation/uikit/uiscene/title>
- <https://developer.apple.com/documentation/uikit/uisceneclosureconfirmation>
- <https://developer.apple.com/documentation/uikit/uiwindowscene/closureconfirmation>
- <https://developer.apple.com/videos/play/wwdc2023/10056/>
- <https://support.apple.com/guide/pages-ipad/save-and-name-a-document-tan95caaa4ff/ipados>
- <https://developer.android.com/guide/navigation/custom-back>
- <https://developer.android.com/guide/navigation/custom-back/predictive-back-gesture>
- <https://developer.android.com/jetpack/androidx/releases/navigationevent>
- <https://github.com/androidx/androidx/blob/androidx-main/activity/activity-compose/src/main/java/androidx/activity/compose/BackHandler.kt>
- <https://developer.android.com/reference/android/app/ActivityManager.TaskDescription>
- <https://m1.material.io/components/dialogs.html>

Secondary (graded [OBS]/[CONV] in text):

- <https://www.textasticapp.com/manual/lessons/When_does_Textastic_save_file_changes.html>
- <https://feedback.textasticapp.com/communities/1/topics/681-show-which-files-have-been-changedmodified-since-download>
- <https://workingcopyapp.com/manual/file-changes/>
- <https://ia.net/writer/support/help/icloud>
- <https://www.swiftjectivec.com/ios-27-notable-uikit-additions/>
- <https://livsycode.com/swiftui/intercepting-swiftui-sheet-dismissal/>
- <https://fatbobman.com/en/posts/newinteractivedismissdiabled/>
- <https://appleinsider.com/inside/ipados-26/tips/whats-new-with-ipad-app-windows-in-ipados-26-and-how-they-work>
- <https://support.apple.com/en-us/125309>
- <https://www.androidauthority.com/android-16-minimize-desktop-windows-3535415/>

### Sources I could not extract, and why

- `m3.material.io` and `m2.material.io` are client-rendered; WebFetch returns the
  shell. Material 3 dialog guidance is graded [OBS] as a result, and the m1
  static spec was used where verbatim wording was needed.
- `UIWindowScene.closureConfirmation` has **no discussion section** in Apple's
  docs — the abstract is the entire specification. The trigger list is genuinely
  unspecified, not merely unfound.

### Corrections made during this probe

1. A search summary claimed `UISceneClosureConfirmation` is "iOS 17+". Primary
   docs say **iOS 27.0+ beta**. Off by ten major versions.
2. A search summary claimed Google's custom-back guide recommends a
   `NavigationEventHandler` API for confirm-exit dialogs. The guide itself does
   not mention it; it recommends `OnBackPressedCallback`. (`androidx.navigationevent`
   *is* real and stable — verified separately — but the guide does not cite it
   for that purpose.)
3. The widely repeated "~15 second" UIDocument autosave interval is **not** in
   Apple's documentation, which says only that the period "varies according to
   several factors". Graded [CONV].

Status: COMPLETE.
