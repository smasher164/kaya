# App identity on phones (iOS + Android) — the packaging boundary

Research arm for the chrome design brief. Every claim is marked
[REPO] (read in this tree), [DOC] (cited, version pinned),
[MEASURED] (command + output shown), [INFER] (reasoning, not a source).

STATUS: complete. No emulator or simulator was booted by this arm; the
repo was not modified (see the two notes at the end).

---

## 0. What the tree declares today [REPO]

### Android

Four gradle modules under `/Users/akhilindurti/Projects/kaya/android/`:
`kaya` (the library / AAR), and three validation apps `milestone2`
(Rust guest), `milestone2kt` (JVM ring guest), `milestone2go` (Go guest).

Pins, read from the module build files:

| module | applicationId | compileSdk | minSdk | targetSdk |
|---|---|---|---|---|
| `kaya` (library) | — | 35 | 26 | — |
| `milestone2` | `dev.kaya.milestone2` | 35 | 26 | 35 |
| `milestone2kt` | `dev.kaya.milestone2kt` | 35 | 26 | 35 |
| `milestone2go` | `dev.kaya.milestone2go` | 35 | 26 | 35 |

- `/Users/akhilindurti/Projects/kaya/android/build.gradle.kts`: AGP
  `8.7.3`, Kotlin `2.0.21`. `buildToolsVersion = "37.0.0"` (pinned to
  what the nix SDK provides).
- **NAME**: each app manifest carries a hard-coded `android:label` on
  `<application>` and nothing else:
  - `android/milestone2/src/main/AndroidManifest.xml:25` —
    `android:label="kaya milestone 0"`
  - `android/milestone2kt/src/main/AndroidManifest.xml:11` —
    `android:label="kaya milestone 0 (jvm ring)"`
  - `android/milestone2go/src/main/AndroidManifest.xml:4` —
    `android:label="kaya milestone 0 (go)"`
  These are literal strings, not `@string/…` resources. There is no
  `app_name` string resource anywhere in the tree.
- **ICON**: there is **no `android:icon` and no `android:roundIcon`
  anywhere in the tree**, and no launcher icon resource at all. The
  complete `res/` inventory of the whole android tree is four files:
  `android/kaya/src/main/res/values/themes.xml`,
  `.../values-night/themes.xml`,
  `.../values/kaya_harness_strings.xml` (one string:
  `kaya_harness_a11y_description`), and
  `.../xml/kaya_harness_accessibility.xml`. No `mipmap-*`, no
  `drawable-*`, no adaptive-icon XML.
  So kaya's Android apps ship the platform's generic default icon
  today. [REPO]
- The library manifest (`android/kaya/src/main/AndroidManifest.xml`)
  declares only `KayaClipProvider`; it declares no identity at all,
  deliberately (its comment explains the app-vs-library split for the
  a11y service).
- The Activity is a bare `ComponentActivity`
  (`android/milestone2/src/main/kotlin/dev/kaya/milestone2/MainActivity.kt`)
  that maps `KAYA_*` intent extras to env, loads the guest .so, and
  calls `Kaya.attach(this)` + `KayaCompose.mount(this)`. It touches no
  identity API.
- **No `setTaskDescription`, no `TaskDescription`, no `android:icon`
  anywhere in the tree** (grep over `*.kt *.swift *.sh *.xml *.plist
  *.in *.rs *.md`, excluding `third_party/`, `build/`, `target/`). The
  only hit for the whole identity family was
  `tools/ios/scopeprobe/Info.plist.in:5` — `CFBundleDisplayName` =
  `ScopeProbe`, a probe harness, not a kaya app. [REPO]

### iOS

There IS a real `.app` bundle with a real `Info.plist`, assembled by
the lane script rather than by Xcode:

- `/Users/akhilindurti/Projects/kaya/tools/ios/run-sim.sh:93-106`,
  `make_bundle(name, bundle_id, executable_path)`: `mkdir` the
  `<name>.app`, substitute `@EXECUTABLE@`/`@BUNDLE_ID@`/`@NAME@` into
  `tools/ios/Info.plist.in` with a python3 one-liner, copy the
  executable in. That is the entire bundle — **no `Assets.car`, no
  asset catalog, no `actool` invocation, no icon file of any kind.**
- `/Users/akhilindurti/Projects/kaya/tools/ios/Info.plist.in` declares:
  `CFBundleExecutable`, `CFBundleIdentifier`, `CFBundleName` (all three
  fed the same `@NAME@`/`@BUNDLE_ID@` pair), `CFBundlePackageType`,
  `CFBundleShortVersionString` 0.0.0, `CFBundleVersion` 1,
  `LSRequiresIPhoneOS`, `UIDeviceFamily` [1,2],
  `UIFileSharingEnabled`, `LSSupportsOpeningDocumentsInPlace`,
  `UILaunchScreen {}`.
  **No `CFBundleDisplayName`. No `CFBundleIconName`. No
  `CFBundleIcons`. No `CFBundleAlternateIcons`.** [REPO]
- `tools/check-steps.sh:2274-2277` already gates two of those keys
  (`UIFileSharingEnabled` / `LSSupportsOpeningDocumentsInPlace`) —
  i.e. there is a precedent in this tree for a gate that reads
  `Info.plist.in` and refuses on a missing key.

### macOS, for contrast [REPO]

macOS guests run as **bare executables with no bundle at all** —
`tools/validate-mac.sh:74-108` stages the Rust guests out of
`target/debug/examples` and runs them directly, and its comment
describes LaunchServices treating the *containing directory* as the
bundle. So mac has no `Info.plist` and therefore no
`CFBundleIconFile`/`CFBundleName` either. (mac is another arm's
subject; noted only because the iOS half of the same SwiftUI backend
DOES have a bundle and mac does not — the two halves of one backend
sit on opposite sides of the packaging boundary.)

**Bottom line for §0: kaya declares a NAME on both phones today
(`android:label` literal / `CFBundleName` from the lane script) and
declares NO ICON on either.**

---

## ANDROID

### 1. The launcher icon is packaging, full stop

`android:icon` is a manifest attribute on `<application>` / `<activity>`
/ `<activity-alias>`, taking a **drawable resource reference**. There is
no setter for it. `PackageManager.getApplicationIcon()` /
`getActivityIcon()` are read-only, and they resolve the resource out of
the installed APK. [DOC]
https://developer.android.com/guide/topics/manifest/application-element#icon
— "This attribute must be set as a reference to a drawable resource
containing the image." The value is compiled into `resources.arsc` at
build time; changing it means shipping a new APK. There is no
`byte[]`-shaped launcher-icon API at ANY API level.

**Runtime alternative, and what it actually is.** The "change your app
icon" trick is `<activity-alias>` + `PackageManager
.setComponentEnabledSetting(ComponentName, int newState, int flags)`
(API level 1; `COMPONENT_ENABLED_STATE_ENABLED` = 1,
`COMPONENT_ENABLED_STATE_DISABLED` = 2, `DONT_KILL_APP` = 1). [DOC]
https://developer.android.com/reference/android/content/pm/PackageManager#setComponentEnabledSetting(android.content.ComponentName,%20int,%20int)
The app declares N `<activity-alias>` entries, each with its own
`android:icon` and `android:label` and its own LAUNCHER intent filter,
exactly one enabled; switching means enabling one and disabling the
others.

This is **still packaging** — every icon is a compiled drawable resource
shipped in the APK, pre-declared in the manifest. What is chosen at
runtime is WHICH pre-declared alias is live, exactly like iOS alternate
icons. It is not a bytes channel. [INFER, from the resource-reference
requirement above]

What it costs:
- **The app is killed** when the currently-enabled component is
  disabled. `DONT_KILL_APP` is documented as advisory:
  "the current [enabled] state is not changed for the app" — in practice
  disabling the live alias restarts the process. [DOC]
  https://developer.android.com/reference/android/content/pm/PackageManager#DONT_KILL_APP
- **Home-screen shortcuts break on API ≤ 28**; API 29+ keeps them.
  [DOC, weak — this is community-documented rather than in the reference:
  https://blog.jakelee.co.uk/programmatically-changing-app-icon/ ,
  https://dev.to/anandankur16/let-users-change-your-app-icon-a-guide-to-dynamic-icons-on-android-with-activity-alias-3okp ]
  Treat the exact API boundary as unverified; the FACT that pinned
  shortcuts are disturbed is well attested.
- Launcher caches mean the new icon can lag arbitrarily.

Verdict for §1: **NOT a runtime blob story.** Nothing in this family
accepts image bytes.

### 2. Recents / task switcher — `ActivityManager.TaskDescription`

This is the one place an Android app pushes a label and an image into
system chrome at runtime. `Activity.setTaskDescription(TaskDescription)`,
added in API 21. [MEASURED — pinned SDK]
`android-35/android-stubs-src.jar → android/app/Activity.java:559`:
`public void setTaskDescription(android.app.ActivityManager.TaskDescription taskDescription)`.

**Exact API levels, measured out of the pinned SDK** (not from a doc
page). Command and output:

```
$ SDK=$ANDROID_HOME   # /nix/store/fswv7kcnk8kfm3wdaawwbg23ip6c7421-androidsdk/libexec/android-sdk
$ python3 <parse $SDK/platforms/android-35/data/api-versions.xml>
CLASS android/app/ActivityManager$TaskDescription {'since': '21'}
    <init>()V                                        {'deprecated': '33'}
    <init>(Landroid/app/ActivityManager$TaskDescription;)V {}          # copy ctor, NOT deprecated
    <init>(Ljava/lang/String;)V                      {'deprecated': '33'}
    <init>(Ljava/lang/String;I)V                     {'since': '28', 'deprecated': '33'}
    <init>(Ljava/lang/String;II)V                    {'since': '28', 'deprecated': '33'}
    <init>(Ljava/lang/String;Landroid/graphics/Bitmap;)V   {'deprecated': '28'}
    <init>(Ljava/lang/String;Landroid/graphics/Bitmap;I)V  {'deprecated': '28'}
    getIcon()Landroid/graphics/Bitmap;               {'deprecated': '30'}
    getLabel()Ljava/lang/String;                     {}
    getPrimaryColor()I                               {}
    getBackgroundColor()I  getStatusBarColor()I  getNavigationBarColor()I {'since': '33'}
CLASS android/app/ActivityManager$TaskDescription$Builder {'since': '33'}
    setLabel(Ljava/lang/String;)…      setIcon(I)…      setPrimaryColor(I)…
    setBackgroundColor(I)…  setStatusBarColor(I)…  setNavigationBarColor(I)…  build()…
```

Read that table twice, because it is the whole finding:

- **A Bitmap IS accepted** — `TaskDescription(String label, Bitmap icon)`
  and `(String, Bitmap, int colorPrimary)`, since API 21. Cross-checked
  against the stubs source
  (`android/app/ActivityManager.java:396,399`) and the reference page.
  [MEASURED + DOC]
- **Both Bitmap constructors have been deprecated since API 28**
  (Android 9, 2018) — deprecated at the same level that added the
  `iconRes` constructors. [MEASURED]
- **The current spelling is `TaskDescription.Builder`, added API 33**
  (Android 13), and at compileSdk 35 **its only icon setter is
  `setIcon(int iconRes)` — a drawable resource id. There is NO Bitmap
  overload.** [MEASURED, stubs `ActivityManager.java:439`; the whole
  Builder is lines 431-455 and there is no other setIcon]
  So on the tree's pinned SDK, the modern, non-deprecated path to the
  recents icon is *packaging again* — a compiled drawable resource.
- **API 37 (Android 17, shipped 2026-06-16) adds
  `Builder.setIcon(Icon)` and `Builder.setBadge(Icon)`.** [DOC]
  https://developer.android.com/reference/android/app/ActivityManager.TaskDescription.Builder
  — "setIcon / Added in API level 37 / public …Builder setIcon (Icon icon)"
  and "setBadge / Added in API level 37 … The badge is an optional,
  small icon that is displayed on bottom corner of the icon in places
  like the taskbar and launcher."
  `android.graphics.drawable.Icon` is the real bytes type:
  `Icon.createWithBitmap(Bitmap)`, `Icon.createWithAdaptiveBitmap(Bitmap)`
  and — literally a blob — **`Icon.createWithData(byte[] data, int
  offset, int length)`, "Create an Icon pointing to a compressed bitmap
  stored in a byte array."** [DOC]
  https://developer.android.com/reference/android/graphics/drawable/Icon
  Android 17 is TWO MONTHS OLD as of today and the tree pins
  compileSdk 35 / minSdk 26, so this is not a surface kaya can compile
  against without moving the SDK pin, and it would be unavailable on
  every device below API 37.

**Size constraints.** No public documented ceiling on the bitmap.
The framework does not reject a large one; it persists it. In AOSP's
`TaskDescription` the icon is stored as an `Icon` (`mIcon`) and the
system separately writes it to disk and keeps a `mIconFilename`
(`ActivityManager.java` — `setIconFilename()` sets `mIcon = null` when
a filename arrives). [MEASURED, AOSP `main`:
https://android.googlesource.com/platform/frameworks/base/+/refs/heads/main/core/java/android/app/ActivityManager.java
lines 2217-2232, 2540-2575]. Practical guidance in the wild is
"launcher-icon sized" (48-192 px); I found no normative number, so
treat "any size works" as unverified.

**Does the recents label default to the activity label?** Yes.
[DOC, older but still the guide's wording]
https://webarchive.library.unt.edu/web/20160706082538mp_/https://developer.android.com/guide/components/recents.html
— "If you don't provide a label value or provide a null value, the
most-specific value available from the manifest is used."
Confirmed structurally in the current shipping consumer, below.

**Does anything the user sees actually change on a modern Android?
This is the honest part, and the answer is: mostly no.**

I read the actual consumer — AOSP Launcher3 / Quickstep's
`TaskIconCache`, which is what draws the Recents cards on stock Android
(Pixel and every Launcher3-derived OEM shell). [MEASURED — fetched and
decoded from
https://android.googlesource.com/platform/packages/apps/Launcher3/+/refs/heads/main/quickstep/src/com/android/quickstep/TaskIconCache.java ]

```java
// Load icon
// TODO: Load icon resource (b/143363444)
Bitmap icon = getIcon(desc, key.userId);
if (icon != null) { entry.icon = …from your bitmap… }
else { …fall back to the activity's manifest icon… }
…
private Bitmap getIcon(ActivityManager.TaskDescription desc, int userId) {
    if (desc.getInMemoryIcon() != null) return desc.getInMemoryIcon();
    return ActivityManager.TaskDescription.loadTaskDescriptionIcon(
            desc.getIconFilename(), userId);
}
…
if (activityInfo != null) {
    entry.contentDescription = getBadgedContentDescription(
            activityInfo, task.key.userId, task.taskDescription);
    if (enableOverviewIconMenu()) {
        entry.title = Utilities.trim(activityInfo.loadLabel(mContext.getPackageManager()));
    }
}
…
private String getBadgedContentDescription(ActivityInfo info, int userId, TaskDescription td) {
    String taskLabel = td == null ? null : Utilities.trim(td.getLabel());
    if (TextUtils.isEmpty(taskLabel)) taskLabel = Utilities.trim(info.loadLabel(pm));
    …
    return applicationLabel.equals(taskLabel) ? badgedApplicationLabel
                                              : badgedApplicationLabel + " " + taskLabel;
}
```

Three things fall out of that, and each one matters to the brief:

1. **The ICON that Recents draws is `desc.getInMemoryIcon()` — the
   BITMAP.** The deprecated-since-API-28 constructor is the one the
   shipping Recents honors.
2. **`setIcon(int iconRes)` — the modern non-deprecated spelling — is
   NOT IMPLEMENTED by Recents.** The comment is right there in the
   source: `// TODO: Load icon resource (b/143363444)`. So the current
   API takes a resource that the current consumer ignores, and the
   deprecated API takes a bitmap that the current consumer uses.
   [MEASURED]
3. **The VISIBLE title is the manifest label, not your
   TaskDescription label.** `entry.title` is
   `activityInfo.loadLabel(pm)` — the manifest — and only under the
   `enableOverviewIconMenu()` flag at that. `td.getLabel()` is used
   ONLY to build `entry.contentDescription`, i.e. **the TalkBack
   announcement**. [MEASURED]

So on stock modern Android with gesture navigation: the recents card is
a snapshot with a small app icon; your TaskDescription **icon** can
change that icon, your TaskDescription **label** changes what a screen
reader says and nothing a sighted user sees. Older Android (Lollipop
through roughly Pie, the button-nav card stack) DID show the label as
visible card text — that is where all the "polish your overview screen"
blog material comes from, and it is stale. [INFER, from the code above +
the age of the guide material]. OEM shells (Samsung One UI, MIUI, etc.)
re-implement Recents entirely and I did not read any of them — assume
nothing carries over.

### 3. Anything else on Android that carries identity at runtime?

- **`android:label` at runtime: no.** `ApplicationInfo.labelRes` /
  `nonLocalizedLabel` are read-only fields on an object the
  PackageManager hands you; there is no setter and no IPC to change the
  installed package's label. `Activity.setTitle()` exists but sets the
  WINDOW title (what an ActionBar draws), not the package label, and is
  not what Recents reads (§2 shows Recents reads `activityInfo
  .loadLabel`). [INFER, from the PackageManager surface + the Launcher3
  read above; I found no setter in the pinned SDK]
- **The notification "app name": no.** The name in a notification header
  is resolved by SystemUI from the posting package's label. The app
  controls the small icon (`Notification.Builder.setSmallIcon(Icon)`,
  API 23 — and `Icon` again means real bytes are accepted), the large
  icon, and `setSubText`, but not the app-name line.
  [DOC] https://developer.android.com/reference/android/app/Notification.Builder#setSmallIcon(android.graphics.drawable.Icon)
- **Shortcuts DO take runtime bytes** — `ShortcutInfo.Builder
  .setIcon(Icon)` and `.setShortLabel(CharSequence)`, API 25, with
  `Icon.createWithBitmap` / `createWithAdaptiveBitmap` accepted.
  [DOC] https://developer.android.com/reference/android/content/pm/ShortcutInfo.Builder#setIcon(android.graphics.drawable.Icon)
  But that is a SHORTCUT's identity (a long-press menu entry, a pinned
  home-screen item), not the app's. Worth naming in the brief only so
  the brief is not accused of missing it.
- **The a11y announcement**: covered above — TaskDescription's label
  reaches the Recents card's content description, which is a real (if
  narrow) observable.

---

## iOS

Environment: `Xcode-26.6.0.app`, iPhoneOS SDK **26.5** [MEASURED —
`xcrun --sdk iphoneos --show-sdk-version` → `26.5`]. Everything below
is read out of that SDK's headers or Apple's documentation JSON.

### 4. The app icon is asset-catalog / Info.plist packaging

The primary icon comes from an asset catalog (`AppIcon`) compiled by
`actool` into `Assets.car`, with `CFBundleIcons → CFBundlePrimaryIcon`
generated into `Info.plist` by Xcode. [DOC]
https://developer.apple.com/documentation/xcode/configuring-your-app-icon
— "Xcode uses these setting[s] to generate the entries for
`CFBundlePrimaryIcon` and `CFBundleAlternateIcons` under the top-level
key `CFBundleIcons`."

**`UIApplication.setAlternateIconName(_:completionHandler:)` is the one
runtime API, and it takes a NAME, never bytes.** [MEASURED — the entire
iOS 26.5 SDK header census]

```
$ grep -rn "AlternateIcon" $IPHONEOS_SDK/System/Library/Frameworks/ --include="*.h"
UIKit.framework/Headers/UIApplication.h:258:@property (readonly, nonatomic) BOOL supportsAlternateIcons … API_AVAILABLE(ios(10.3), tvos(10.2)) API_UNAVAILABLE(watchos);
UIKit.framework/Headers/UIApplication.h:261:- (void)setAlternateIconName:(nullable NSString *)alternateIconName completionHandler:(nullable void (^)(NSError *_Nullable error))completionHandler … API_AVAILABLE(ios(10.3), tvos(10.2)) API_UNAVAILABLE(watchos);
UIKit.framework/Headers/UIApplication.h:264:@property (nullable, readonly, nonatomic) NSString *alternateIconName … API_AVAILABLE(ios(10.3), tvos(10.2)) API_UNAVAILABLE(watchos);
```

Three symbols, in one `@interface UIApplication
(UIAlternateApplicationIcons)` category, and their types are `BOOL` and
`NSString *`. **There is no `NSData`, no `UIImage`, and no `CGImage`
anywhere in the iOS app-icon surface.** Introduced iOS 10.3 (tvOS 10.2),
not deprecated as of SDK 26.5.

What the name must be, verbatim from Apple: [DOC]
https://developer.apple.com/documentation/uikit/uiapplication/setalternateiconname(_:completionhandler:)
> "The name of the alternate icon, as declared in the
> `CFBundleAlternateIcons` key of your app's `Info.plist` file. Specify
> `nil` if you want to display the app's primary icon, which you declare
> using the `CFBundlePrimaryIcon` key. Both keys are subentries of the
> `CFBundleIcons` key in your app's `Info.plist` file."
> "You can change the icon only if the value of the
> `supportsAlternateIcons` property is `true`."

And what `CFBundleAlternateIcons` holds: [DOC]
https://developer.apple.com/documentation/bundleresources/information-property-list/cfbundleicons/cfbundlealternateicons
> "In iOS, the value of the key is a dictionary. The key for each
> dictionary entry is the name of the alternate icon, which is also the
> string you pass to `setAlternateIconName(_:completionHandler:)` when
> changing icons. The value for each dictionary key is an
> `AppIconReferenceName` dictionary."

So the mechanism is: **every icon is compiled into the app bundle at
build time; the runtime call selects one by key.** Structurally the same
shape as Android's `<activity-alias>` (§1) — a pre-declared set, chosen
at runtime — and structurally NOT a blob channel. This is the finding
the brief asked me to confirm, and it is confirmed twice over: by the
parameter's documentation and by the SDK header census.

**The system alert.** `setAlternateIconName` presents a system alert
("You have changed the icon for …") that the app cannot suppress
through any documented API. Apple's reference does not mention the
alert at all — the behavior is universally reported and worked around
only via private selectors (`_setAlternateIconName:completionHandler:`)
or timing hacks, and the current reports say the suppression tricks
stopped working on iOS 26.1. [DOC-weak / community]
https://developer.apple.com/forums/thread/811534 ,
https://gist.github.com/Bonney/79e28be05fcb19e2f9e1b418244c66e4
Mark this as *not* pinned to an Apple statement: the honest phrasing for
the brief is "the system, not the app, decides whether the user is
prompted, and there is no documented way to change the icon silently."

**iOS 18 icon variants — relevant, and it cuts the same way.** iOS/iPadOS
app icons have three stylistic variants (Light, Dark, Tinted), authored
as separate image wells in the asset catalog under an Appearance
setting, or left to the system's automatic treatment. [DOC]
https://developer.apple.com/documentation/xcode/configuring-your-app-icon
— "iOS and iPadOS support three stylistic variations for app icons:
Light, Dark, and Tinted… Provide your tinted app icon as a grayscale
image. Provide your dark app icon with a transparent background."
This *triples* the packaging surface (one declared identity becomes
three authored assets per icon) and adds nothing runtime-settable. If
kaya ever declares an icon, the variants are a reason the lowering must
target an asset pipeline and not a byte blob.

### 5. Is there ANY iOS surface where a runtime icon blob shows?

**The app-switcher card is a snapshot of the app's own UI, not an
icon — confirmed.** [DOC]
https://developer.apple.com/documentation/uikit/uiapplication/ignoresnapshotonnextapplicationlaunch()
> "As part of the state preservation process, UIKit captures your app's
> user interface and stores it in an image file. When your app is
> relaunched, the system displays this snapshot image in place of your
> app's default launch image…"
The card content is pixels UIKit captured from the app's own view
hierarchy. An app influences it only by changing what it draws. Any app
icon / app name adornment around the card (the iPad switcher shows
them; the iPhone switcher as of recent iOS shows bare cards) comes from
the bundle. [INFER — I could not find an Apple statement describing the
switcher's chrome per device class, and I did not boot a simulator to
look; treat the per-device detail as unverified. The structural claim —
card = snapshot, adornment = bundle — is solid.]

Other near-misses, each checked and each a name rather than bytes:
- **Home Screen quick actions**: `UIApplicationShortcutIcon` offers a
  system `IconType`, a contact, or `init(templateImageName: String)` —
  "Creates a Home Screen quick action icon based on an image in your
  app's bundle". A NAME. [DOC]
  https://developer.apple.com/documentation/uikit/uiapplicationshortcuticon/init(templateimagename:)
  (Contrast with Android's `ShortcutInfo.Builder.setIcon(Icon)`, which
  DOES take bytes — the two platforms differ here, which matters for
  invariant 1 if kaya ever goes near shortcuts.)
- **Notifications**: the header's app name and icon come from the
  bundle; `UNNotificationAttachment` carries content media, not
  identity.

**Where the identity NAME lands: packaging.** `CFBundleDisplayName` —
"The user-visible name for the bundle, used by Siri and visible on the
iOS Home screen" — with `CFBundleName` ("up to 15 characters… displayed
if `CFBundleDisplayName` isn't set") as the fallback. [DOC]
https://developer.apple.com/documentation/bundleresources/information-property-list/cfbundledisplayname ,
.../cfbundlename
Both are Info.plist keys. There is no runtime setter for either.
kaya's `tools/ios/Info.plist.in` sets `CFBundleName` (to `@NAME@`, which
run-sim.sh feeds the same string as the executable name) and does not
set `CFBundleDisplayName` at all — so today the iOS home-screen name is
the scene binary's name. [REPO]

### 6. What could a HARNESS honestly READ?

**Android: a real read, and it is genuinely real — not an echo.**
`ActivityManager.getAppTasks()` → `AppTask.getTaskInfo()` →
`RecentTaskInfo extends TaskInfo`, whose `public @Nullable
ActivityManager.TaskDescription taskDescription` field is **not
deprecated** at API 35. [MEASURED — pinned SDK stubs
`android/app/TaskInfo.java:39`; `api-versions.xml` shows
`RecentTaskInfo.taskDescription` `{'since':'21','removed':'29'}`,
meaning it MOVED UP to `TaskInfo` in API 29, not that it went away.]

I traced the whole round trip in AOSP to check whether the read is an
in-process echo. It is not: [MEASURED, AOSP `main` via gitiles]

1. `AppTaskImpl.getTaskInfo()` (services/core/java/com/android/server/wm/
   `AppTaskImpl.java:95`) calls
   `createRecentTaskInfo(task, stripExtras=false, getTasksAllowed=true)`.
2. `Task.fillTaskInfo` (`Task.java:3384`):
   `info.taskDescription = new ActivityManager.TaskDescription(getTaskDescription());`
   — a copy of the SYSTEM's task-level description, which
   `Task.updateTaskDescription()` (`Task.java:1919-1945`) composed by
   walking the task's activities. So what comes back is the system's
   merged state, not the object you handed in.
3. **The icon takes a detour through the filesystem.**
   `ActivityRecord.setTaskDescription` (`ActivityRecord.java:7362-7375`)
   writes your bitmap to a file under the user's images dir and calls
   `setIconFilename(iconFilePath)`, and `TaskDescription
   .setIconFilename` (`ActivityManager.java:2226-2231`) sets
   `mIcon = null`. Reading it back therefore goes
   `getIcon()` → `getInMemoryIcon()` (null) →
   `loadTaskDescriptionIcon(mIconFilename, myUserId)` →
   `ActivityTaskManagerService.getTaskDescriptionIcon(filePath, userId)`
   (`ActivityTaskManagerService.java:3079-3117`), a Binder call whose
   permission check is `matchingActivity.getUid() != callingUid` →
   only then require the privileged permission. **The owning app is
   explicitly allowed to read its own task-description icon back as
   real pixels, out of the file the system wrote.**

That is a read worth having: it proves the system accepted and stored
the bitmap, and the bytes come back across a Binder from a system
service, so a harness comparing them is not comparing the model to
itself. Two honest caveats:
- The only public getter for those pixels is
  `TaskDescription.getIcon()`, **deprecated at API 30** with the text
  "This call is no longer supported. The caller should keep track of any
  icons it sets for the task descriptions internally." [DOC/MEASURED]
  It still works in AOSP `main` (I read the body), but Google has said
  in the deprecation note that it is not to be relied on.
- `getLabel()` on the same object is NOT deprecated and returns the
  system's merged label. That read is clean.

Reading Compose's own model back would be the echo — the interpreter
would be comparing a Kotlin field to the Kotlin field it set. The
`getAppTasks()` path avoids that; the model read does not.

**iOS: `UIApplication.alternateIconName` is a getter, and it is
weaker.** [DOC]
https://developer.apple.com/documentation/uikit/uiapplication/alternateiconname
> "When the system is displaying one of your app's alternate icons, the
> value of this property is the name of the alternate icon (from your
> app's `Info.plist` file). When the system is displaying your app's
> primary icon, the value of this property is `nil`."

What it returns is a STRING THE APP ITSELF CHOSE, out of a set the app
itself declared. It can tell you the system rejected a change (the
completion handler's `NSError` is the real signal), and the value does
persist across launches, which means it is backed by system state rather
than a process-local variable — but it can never tell you what the Home
Screen actually renders, or that any pixels changed. There is no
`UIImage`/`NSData` getter (the header census in §4 is the proof: three
symbols, none of them image-typed). [DOC for the definition; [INFER] for
"backed by system state, since the selection survives relaunch" — I did
NOT measure this, and measuring it would need a booted simulator, an
asset-catalog build with a real alternate icon, and a relaunch.]

Verdict on reads: **Android has one honest read (label clean, icon via
a deprecated getter but genuinely round-tripped through the system).
iOS has only a name echo of the app's own declaration.** They are not
symmetric, and no amount of spelling makes them so.

---

## VERDICT — where the packaging boundary falls

**On phones, the launcher/Home Screen identity of an app — the icon the
user taps and the name under it — is not a runtime concern and cannot
be made into one.** On Android it is `android:icon` (a compiled drawable
resource reference) and `android:label` in a manifest that is sealed at
APK build time; on iOS it is an asset catalog compiled by `actool` into
`Assets.car` plus `CFBundleDisplayName`/`CFBundleName` in `Info.plist`.
Both platforms offer exactly one runtime lever over the launcher icon,
and on both it is the SAME lever: **choose one of N icons you already
shipped, by name** — `<activity-alias>` + `setComponentEnabledSetting`
on Android, `setAlternateIconName` on iOS. Neither accepts bytes. On
iOS the SDK header census settles it: the whole app-icon surface is
`BOOL supportsAlternateIcons`, `-setAlternateIconName:completionHandler:`
and `NSString *alternateIconName`, and not one of them is image-typed.
So a design that declares "one app identity, name string + icon BYTES
over the wire blob channel, lowered per platform" **has no phone
lowering for the icon half of that sentence.** The brief must say so in
those words rather than describing a per-platform "adapter" that quietly
turns bytes into a build-time asset.

**The single honest runtime candidate is Android's
`ActivityManager.TaskDescription`, and I do not think it is worth
wiring.** It is the only surface on either phone where an app hands the
system a label and an image at runtime and system chrome changes. But
every property it has argues against it:

- It is **Android-only**. iOS has no counterpart at all, so wiring it
  makes the phone arms diverge on a *feature*, not on spelling — which
  is the exact thing invariant 1 forbids without a stated carve-out.
- The **bytes path is deprecated** (`TaskDescription(String, Bitmap)`,
  deprecated since API 28 / 2018) and the **current path is packaging
  again** (`Builder.setIcon(int iconRes)`, API 33 — a compiled drawable
  resource). At the tree's compileSdk 35 those are the only two options.
- The two paths are **each broken in the opposite half**: shipping
  Recents (`Launcher3/TaskIconCache`) reads only the bitmap and carries
  `// TODO: Load icon resource (b/143363444)` for the resource path, so
  the non-deprecated API is ignored by the consumer while the deprecated
  one works.
- **Almost nothing the user sees changes.** On stock modern Android the
  TaskDescription *label* reaches only the recents card's
  accessibility content description — the visible title is
  `activityInfo.loadLabel()`, the manifest label. The icon does change
  the small icon on the card. That is the entire visible payoff: one
  small icon on one screen, on stock Launcher3, with OEM shells
  unchecked.
- The **real bytes API exists but is two months old**:
  `Builder.setIcon(Icon)` and `setBadge(Icon)` arrived in API 37
  (Android 17, 2026-06-16), and `Icon.createWithData(byte[], off, len)`
  is a literal blob constructor. Wiring against it means moving the SDK
  pin off 35, and it would be dead on every device below API 37, which
  is every device kaya's `minSdk = 26` currently promises. I also could
  NOT verify that Android 17's Recents honors a `TYPE_DATA` icon: the
  AOSP snapshot I read predates the API, and the code paths I did read
  (`getInMemoryIcon()`, which returns null for anything but
  `TYPE_BITMAP`) would drop it.

**Recommendation: state it as a REFUSAL, with the reason on the
record.** kaya declares app identity — a name and icon bytes — as
*packaging metadata*, consumed by whatever builds the artifact
(`AndroidManifest.xml` + a generated `mipmap`/adaptive-icon resource;
`Info.plist` + an asset catalog run through `actool`), and kaya's
runtime does not expose it. The refusal is uniform across all 8
bindings and both phones, which satisfies invariant 1 the way a carve-out
never would: nobody gets a `set_app_icon()` that works on one platform.
If a runtime task-switcher identity is ever wanted, it comes back as its
own named feature ("recents card identity"), Android-only and declared
Android-only, after API 37 is a floor kaya can stand on — not smuggled
in as the phone lowering of a cross-platform identity blob.

**What the phone arms SHOULD carry in the brief instead**, since both
tree halves are currently identity-less (§0): the *build* side. Android
has no `android:icon` and no launcher resource at all, and iOS's
generated `Info.plist` has no `CFBundleIconName`, no `CFBundleIcons`, and
not even `CFBundleDisplayName`. If kaya is to have a declared identity at
all, the work is in `tools/ios/Info.plist.in` + an `actool` step in
`tools/ios/run-sim.sh:93` (`make_bundle`), and in the android module
manifests + a generated resource — and the guard belongs where invariant
3 wants it: `tools/check-steps.sh:2274` already refuses on a missing
`Info.plist.in` key, so the same clause extends to the identity keys for
free.

### Loose ends / things I did not verify

- OEM Recents shells (Samsung One UI, MIUI, ColorOS) — not read. Every
  §2 claim about what is drawn is about AOSP Launcher3/Quickstep only.
- Android 17's Recents handling of `Icon` types other than
  `TYPE_BITMAP` — the AOSP snapshot I read predates
  `Builder.setIcon(Icon)`.
- No documented size ceiling for the TaskDescription bitmap was found;
  "any size works" is unverified.
- The `<activity-alias>` shortcut-breakage API boundary (≤28 vs 29+) is
  community-sourced, not from Apple/Google reference docs.
- The iOS alert's exact current behavior on iOS 26.x is
  community-sourced. Apple's reference is silent on it.
- The iPhone-vs-iPad app-switcher chrome (whether icon/name appear
  beside the card) is from memory, not measured or cited.
- `UIApplication.alternateIconName`'s persistence across relaunch is
  reasoned, not measured.

### Device state — I started nothing, and one of my own checks was vacuous

**This arm booted no emulator and no simulator.** Everything above came
from the pinned SDKs, the Xcode SDK headers, AOSP sources and Apple's
documentation JSON.

I have to flag a bad measurement of my own, because it is exactly the
failure shape CLAUDE.md invariant 3 warns about. Mid-run I checked
`xcrun simctl list devices | grep -c Booted` and got `0`, and briefly
wrote that down as "no simulators booted". **That zero was vacuous** —
`DEVELOPER_DIR` was not exported in that shell (agent shells reset
between calls), so `xcrun` errored and grep counted nothing. The
correct check, with `DEVELOPER_DIR=/Applications/Xcode-26.6.0.app/Contents/Developer`:

```
$ xcrun simctl list devices | grep Booted
    kaya-sim-0   (8F0680C5-…) (Booted)
    kaya-sim-1   (45F06B45-…) (Booted)
    kaya-sim-2   (3CD1C302-…) (Booted)
    kaya-sim-pad (13A39E1D-…) (Booted)
$ adb devices
emulator-5554  device
emulator-5556  device
emulator-5558  device
emulator-5560  device
```

Four simulators and four Android emulators ARE running — **and none of
them are mine.** `ps -Ao pid,etime,pcpu,command` dates them well before
this session:

```
 1856 22-12:22:41  2.6  …/emulator/qemu/darwin-aarch64/qemu-system-aarch64-headless -avd kaya … -port 5554
 1859 22-12:22:41  4.3  … -port 5556
 1862 22-12:22:41  2.0  … -port 5558
  482 01-07:47:09  0.0  …/iOS 26.5.simruntime/…/mobiletimerd
```

22 days and 1 day of elapsed time against a session minutes old. These
are the lane's persistent pools — `tools/ios/run-sim.sh:108-121`
documents the iOS pool as deliberately staying booted across runs, and
the `-avd kaya … -read-only` emulators are the android lane's. **I did
not start them and I am deliberately NOT stopping them**, since killing
another arm's warm pool would be the more damaging act. Nothing to clean
up from this arm; nothing was left behind by it.

### Note for the coordinator

The working tree was NOT clean when I started, despite the session's
opening snapshot saying it was. At my first check `git status
--porcelain` reported three modified files; by the end it reported
fourteen modified files plus an untracked `docs/app-identity-plan.md`
(including `AGENTS.md`, `CLAUDE.md`, four bindings and two tools
scripts). **I did not touch the repo** — this arm ran only reads and
`git status`, made no edits, created no files inside the repo and
changed no git state. Those changes are sibling arms' work. Flagging it
so nothing here is attributed to this arm or reverted on its account.

