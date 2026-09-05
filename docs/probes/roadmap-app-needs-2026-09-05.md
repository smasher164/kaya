# What real applications need from a GUI framework

Research for kaya's roadmap, 2026-09-05. Vocabulary is kaya-surface.md's: SHIPPED
items are named as kaya names them; NOT-SHIPPED items are named from that file's
list. Every claim below carries a URL. Numbers are quoted, never estimated; a
number I could not find is written `?`.

Sections are written in the order they were researched. The ranking is last.

### Top-line answers

- **15 archetypes** defined and grounded in named shipping apps (§3);
  **6 independent evidence sources** counted (§1 vendor catalogues, §2 store and
  legal requirements, §4 a 105-app real corpus, §5 Stack Overflow volume,
  §6-§7d issue-tracker upvotes across 11 frameworks, plus pub.dev dependency
  counts).
- **The single clearest gap is a search field** — must-have in 11 of 15
  archetypes, needed by 30% of a 105-app real catalogue, in all four vendor
  catalogues and all nine Electron apps checked, and cheap to build.
- **The top four gaps are all cheap**: search field, notifications, tree view,
  background tasks. The expensive ones (video, audio, webview) rank 6th-8th.
- **Four gaps are compliance, not preference**: dynamic type, reduced motion,
  localization/RTL, and notifications-that-degrade-gracefully. Apple's
  Accessibility Nutrition Labels are becoming mandatory and the European
  Accessibility Act has applied since 28 June 2025.
- **kaya already ships the top ask of two rival frameworks** — Compose
  Multiplatform's highest-reaction issue ever is a data table (134 +1) and
  iced's is mobile support (138 +1) — and the highest-reaction *shipped*
  Flutter ask, cross-app drag and drop (270 +1).
- **The three archetypes kaya could almost build today**: task manager
  (3 gaps), dashboard/data tool (3), settings-heavy utility (4 — and the
  single biggest archetype by volume at 22% of the GNOME catalogue).
- **The loudest complaint in the whole corpus is not a widget**: Flutter's
  Cupertino fidelity scores 61% satisfaction, "our lowest-rated area", while
  `fluent_ui` + `macos_ui` have 4,294 pub.dev likes between them. kaya's
  one-backend-per-platform architecture is the answer to the thing the largest
  competitor is measurably worst at.

---

## 1. The four platform component catalogues (what each OS vendor thinks an app needs)

This is the cheapest breadth evidence there is: each platform owner publishes the
list of controls it expects apps to use. A control that appears in ALL FOUR is
something the platform designers consider non-optional. kaya ships 17 kinds; the
catalogues run 45-90.

### Apple — Human Interface Guidelines, Components (64 entries, 8 categories)
Fetched 2026-09-05 from the HIG's own data endpoint
(https://developer.apple.com/tutorials/data/design/human-interface-guidelines/components.json —
the human page https://developer.apple.com/design/human-interface-guidelines/components
is a JS shell).

| Category | Components |
|---|---|
| Content (4) | Charts, Image views, **Text views**, **Web views** |
| Layout and organization (10) | Boxes, Collections, Column views, **Disclosure controls**, Labels, Lists and tables, Lockups, **Outline views**, Split views, Tab views |
| Menus and actions (12) | Activity views (**share sheet**), Buttons, Context menus, **Dock menus**, Edit menus, **Home Screen quick actions**, Menus, Ornaments, **Pop-up buttons**, **Pull-down buttons**, The menu bar, **Toolbars** |
| Navigation and search (5) | Path controls, **Search fields**, Sidebars, Tab bars, **Token fields** |
| Presentation (8) | **Action sheets**, Alerts, Page controls, **Panels**, **Popovers**, Scroll views, **Sheets**, Windows |
| Selection and input (11) | **Color wells**, **Combo boxes**, **Digit entry views**, **Image wells**, Pickers, **Segmented controls**, Sliders, **Steppers**, Text fields, **Toggles**, Virtual keyboards |
| Status (4) | Activity rings, **Gauges**, Progress indicators, **Rating indicators** |
| System experiences (10) | App Shortcuts, Complications, Controls, **Live Activities**, **Notifications**, Snippets, **Status bars**, Top Shelf, Watch faces, **Widgets** |

Bold = not in kaya's shipped list. kaya covers roughly 20 of the 64; the misses
that are ordinary-app (not watch/TV) are: text views with rich text, web views,
outline/disclosure (tree), share sheet, pop-up/pull-down buttons as distinct
affordances, toolbars as an author-visible surface, search fields, token fields,
action sheets, panels, popovers, sheets, colour wells, combo boxes, image wells,
segmented controls, steppers, toggles, notifications, status items.

### Google — Material Components for Android, component docs (45 documents)
`gh api repos/material-components/material-components-android/contents/docs/components`,
fetched 2026-09-05 (https://github.com/material-components/material-components-android/tree/master/docs/components):
Badge, Banner, BottomAppBar, BottomNavigation, BottomSheet, Button, ButtonGroup,
Card, Carousel, Checkbox, Chip, CommonButton, DataTable, DatePicker, Dialog,
Divider, DockedFloatingToolbars, DockedToolbar, ExtendedFloatingActionButton,
FloatingActionButton, FloatingActionButtonMenu, FloatingToolbar, IconButton,
ImageList, List, LoadingIndicator, MaterialTextView, Menu, NavigationDrawer,
NavigationRail, OverflowLinearLayout, ProgressIndicator, RadioButton, Search,
SideSheet, Slider, Snackbar, SplitButton, Switch, Tabs, TextField, TimePicker,
ToggleButtonGroup, Tooltip, TopAppBar.

Not in kaya: **Badge**, **BottomSheet/SideSheet**, Card, Carousel, Chip,
**DataTable as a component**, Dialog beyond alerts, **FAB**, **Search**,
**Snackbar/toast**, **SplitButton**, **Switch**, **ToggleButtonGroup**
(segmented), NavigationDrawer/Rail (kaya's sections cover part of this).
Notably Material has NO tree view and NO colour picker component — Android's own
catalogue is the one that agrees most closely with kaya's current shape.

### GNOME — GTK4 visual index + libadwaita widget gallery
https://docs.gtk.org/gtk4/visual_index.html and
https://gnome.pages.gitlab.gnome.org/libadwaita/doc/main/widget-gallery.html
(fetched 2026-09-05).

GTK4 ships, beyond kaya's 17: **TextView (rich)**, **Video**, **MediaControls**,
**Calendar**, **EmojiChooser**, **TreeView / IconView / Expander (tree +
disclosure)**, **SearchEntry / SearchBar**, **PasswordEntry**, **SpinButton
(stepper)**, **EditableLabel**, **Switch**, **LinkButton (hyperlink)**,
**ColorDialogButton**, **FontDialogButton**, **Popover / PopoverMenu**,
**Paned (split)**, **Notebook (tabs)**, **InfoBar**, **LevelBar**,
**PrintUnixDialog / PageSetupUnixDialog (printing)**, **ShortcutsWindow**.

libadwaita's gallery is the modern-GNOME shape and is dominated by
**boxed lists** (Action Row, **Switch Row**, Combo Row, **Expander Row**,
Entry Row, **Password Entry Row**, **Spin Row**, Button Row) and
**Preferences** (Preferences Group / Page / Dialog) — i.e. GNOME's answer to
"most apps are a settings screen" is a first-class row vocabulary. Also
**Toast Overlay**, **Banner**, **Status Page**, **Avatar**, **Bottom Sheet**,
**Tab Bar / Tab Overview**, **Carousel**, **Toggle Group** (segmented),
**About Dialog**, **Shortcuts Dialog**.

### Cross-catalogue: controls present in 3-of-4 vendor catalogues but NOT in kaya
toggle switch (Apple Toggles, Material Switch, Adw Switch Row, GTK Switch);
segmented control (Apple Segmented controls, Material ToggleButtonGroup, Adw
Toggle Group, GTK — via ToggleButton box); search field (Apple Search fields,
Material Search, GTK SearchEntry, Adw — via Entry Row); password/secure entry
(Apple Text fields secure, GTK PasswordEntry, Adw Password Entry Row, Android
`textPassword`); stepper / number field (Apple Steppers + Digit entry views,
GTK SpinButton, Adw Spin Row, Material — no); popover (Apple Popovers, GTK
Popover, Material Menu/Tooltip, Adw — via GTK); sheet/modal beyond alerts (Apple
Sheets + Action sheets, Material BottomSheet/SideSheet/Dialog, Adw Dialog +
Bottom Sheet, GTK Dialog); badge (Apple — dock/app badge + Status, Material
BadgeDrawable, Adw — no); tree/outline (Apple Outline views + Disclosure
controls, GTK TreeView + Expander, Adw Expander Row, Material — no);
rich text view (Apple Text views, GTK TextView, Material MaterialTextView with
spans, Adw — via GTK); web view (Apple Web views, GTK WebKitWebView out of tree,
Android WebView, Material — no); colour picker (Apple Color wells, GTK
ColorDialogButton, Material — no, Adw — no); notifications (Apple Notifications,
Android notification channels, GNOME `Gio.Notification`, Windows toast).

---

## 2. Platform store and legal requirements — the needs no app can skip

These are not "features developers want"; they are conditions of shipping. They
are listed first because a framework that cannot satisfy them cannot ship an app
at all, however good its widget set.

### Apple — App Store
- **Minimum SDK / Xcode.** Since **28 April 2026**, submitted apps must be built
  with **Xcode 26 or later** against the iOS/iPadOS/macOS/tvOS/visionOS/watchOS
  **26 SDK**. https://developer.apple.com/news/upcoming-requirements/
  → kaya already tracks this via flake.nix's `apple-sdk_26`; it is a recurring
  yearly tax, not a one-off.
- **Privacy manifests and required-reason APIs.** Since **1 May 2024** an app
  must declare approved reasons for the listed APIs it (or any bundled SDK) uses.
  Since the same date, listed third-party SDKs must ship a privacy manifest and a
  signature. https://developer.apple.com/support/third-party-SDK-requirements/
  → **A cross-platform GUI framework distributed as a binary is exactly a "listed
  SDK" class item.** Flutter, React Native, Cordova and Unity are all on Apple's
  list. If kaya ever ships prebuilt xcframeworks, it inherits the manifest +
  signature obligation.
- **Accessibility Nutrition Labels.** Currently voluntary, and Apple states they
  "will become mandatory before developers can submit new apps and app updates".
  Nine declarable features: **VoiceOver, Voice Control, Larger Text (200%+),
  Dark Interface, Differentiate Without Color Alone, Sufficient Contrast,
  Reduced Motion, Captions, Audio Descriptions.** To declare one you must be able
  to complete *every common task* with it on.
  https://developer.apple.com/help/app-store-connect/manage-app-accessibility/overview-of-accessibility-nutrition-labels/
  → kaya ships VoiceOver labels and Dark Interface. It does **not** ship
  **Larger Text / Dynamic Type**, **Reduced Motion**, or **Captions**, and
  Differentiate-Without-Color and Sufficient Contrast are app-author concerns
  that the framework's brand tier has to make expressible. This is the single
  most concrete "the store will make you do it" list on any platform.
- **HIG accessibility, the hard numbers.** "Ideally, give people the option to
  enlarge text by at least **200 percent** (or 140 percent in watchOS)".
  Contrast: **4.5:1** up to 17pt, **3:1** at 18pt or bold. Control size minimums:
  iOS **44x44pt** default / 28x28pt minimum, macOS **28x28pt** / 20x20pt.
  Reduce Motion: "ensure your app or game responds by reducing automatic and
  repetitive animations". Change log entry **June 9, 2025** added the Assistive
  Access, Switch Control and Nutrition Label guidance.
  https://developer.apple.com/design/human-interface-guidelines/accessibility
- **macOS outside the store: notarization.** "Beginning in **macOS 10.15**, all
  software built after June 1, 2019 and distributed with Developer ID must be
  notarized." Requires Developer ID signing, **Hardened Runtime**, and a secure
  timestamp; `get-task-allow` must not be set.
  https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution
  → this is a packaging/toolchain need, not a widget: kaya's roadmap item is a
  signing + notarization path, not a control.

### Google — Play
- **Target API level.** Android 15 (API 35) was required from **31 August 2025**;
  **Android 16 (API 36) from 31 August 2026** (extension available to 1 Nov 2026),
  for both new apps and updates. Non-compliant apps become unavailable on newer
  Android versions. Wear OS / Automotive: API 35 by 31 Aug 2026; TV: API 34 by
  31 Aug 2025. https://support.google.com/googleplay/android-developer/answer/11926878
  → a yearly tax on the Android backend, and API-level bumps have historically
  broken notifications, background work and storage.

### Microsoft — Store
Store Policies v7.19 (effective 14 October 2025),
https://learn.microsoft.com/en-us/windows/apps/publish/store-policies
- **10.7 Localization**: "You must localize your product for all languages that
  it supports … The experience provided by a product must be reasonably similar
  in all languages that it supports."
- **10.9 Notifications**: "Your product must respect system settings for
  notifications and **remain functional when they are disabled**."
- **10.4.2 Usability**: products "must start up promptly, continue to run and
  remain responsive to user input … must handle exceptions … and remain
  responsive to user input after the exception is handled."
- No explicit accessibility clause in the Store policy list (checked the full
  table of contents; 10.1-10.14, 11.1-11.16).

### EU — European Accessibility Act (Directive (EU) 2019/882)
Applies from **28 June 2025**. Covered services include **e-commerce**
(online sales through websites *and mobile applications*), **consumer banking**,
**e-books and dedicated reading software**, **passenger transport**,
**electronic communications** (voice, real-time text, video conversation) and
**access to audiovisual media services**. Covered products include computers and
operating systems, smartphones, ATMs and ticketing machines.
https://commission.europa.eu/strategy-and-policy/policies/justice-and-fundamental-rights/disability/union-equality-strategy-rights-persons-disabilities-2021-2030/european-accessibility-act_en
and https://eur-lex.europa.eu/legal-content/EN/TXT/HTML/?uri=CELEX:32019L0882
→ **This makes accessibility a legal requirement, not a nicety, for four of the
archetypes below (e-commerce, banking/finance, reader, transport).** The harmonised
standard is EN 301 549, which incorporates WCAG 2.1 AA — and WCAG 2.1 AA
includes **1.4.4 Resize text to 200%**, **1.4.10 Reflow**, **1.4.12 Text spacing**
and **2.3.3 / 2.2.2 motion and animation control**. Those map to kaya's
NOT-shipped **dynamic type / font scaling** and **reduced motion**.

### What this section adds to the ranking
Four NOT-shipped items are **compliance items**, not feature requests:
**dynamic type / font scaling**, **reduced motion**, **localization + RTL**, and
**notifications that degrade gracefully when disabled**. A fifth,
**captions**, is required only of media apps. Nothing else in kaya's NOT-shipped
list is store- or law-mandated.

---

## 3. App archetypes

15 archetypes. (The charge asked for 10-12 and named 15 candidates; I kept them
split rather than merged, because merging e.g. email into "reader" or fitness
into "commerce" would hide real must-have differences — an email client needs
rich text and an RSS reader does not.) Feature names are kaya-surface.md's;
**bold** = NOT shipped by kaya today.

For each: the 2-3 real apps I checked, then must-have / should-have /
rarely-needs. "Must-have" means the app is not recognisably that kind of app
without it — you cannot ship a chat client with no notifications, or a password
manager with a plaintext password field.

### A1. Notes / text & markdown editor
Real apps: **Obsidian** (https://obsidian.md/, help https://help.obsidian.md/),
**Apple Notes** (https://support.apple.com/guide/notes/welcome/mac),
**GNOME Text Editor** (https://apps.gnome.org/TextEditor/),
**Apostrophe** (markdown, GNOME Circle).
Visibly used: sidebar file **tree**, tabbed/split panes, **search field** with
find-and-replace, **rich text / markdown rendering**, **hyperlinks**,
**spellcheck**, **printing/PDF export**, **session restore** of open notes,
**window position memory**, autosave, **dark mode**, **dynamic type**.

- **Must-have**: textarea with find/highlight/select (kaya HAS), **rich text or
  markdown rendering** (Obsidian, Notes, Apostrophe all render; a plain textarea
  is a different, lesser product), **tree view or hierarchical sidebar**,
  **search field**, **spellcheck**, undo/redo (HAS), file dialogs (HAS),
  clipboard (HAS), menus + shortcuts (HAS), **session restoration / reopen last
  document**, **window position memory**.
- **Should-have**: **printing / PDF export**, **hyperlinks**, drag and drop
  (HAS), **recent-files bookmarks**, tabs (kaya's sections partly), **popover**
  for formatting, **colour picker** (highlight colours), auxiliary windows (HAS),
  **file associations** (double-click a .md), **localization**.
- **Rarely needs**: video/audio, maps, biometrics, camera, haptics, **system
  tray**, charts.

### A2. Chat / messaging
Real apps: **Signal Desktop** (https://signal.org/download/,
source https://github.com/signalapp/Signal-Desktop), **Slack**
(https://slack.com/downloads/mac), **Polari** (IRC, GNOME Circle),
**Discord**.
Visibly used: **local notifications** with reply actions, **system tray /
status item**, **dock/taskbar badge** with unread count, **rich text** message
composition (bold/links/code), **image, video and audio playback inline**,
**emoji picker**, **search field**, scroll-to-message, **spellcheck**,
**global hotkey** (Slack's quick-switcher / push-to-talk in Discord),
**deep links** (`slack://`, `signal://`), **swipe actions** on mobile,
**haptics**, **pull-to-refresh**.

- **Must-have**: **local notifications** (a chat app that does not notify is
  not a chat app), **badges** (unread counts), **rich text / hyperlinks** in
  messages, **image display** (HAS) and **video/audio playback**, **search
  field**, scroll (HAS) + **scrollTo** (jump to unread), clipboard incl. images
  (HAS), file dialogs (HAS), **localization + RTL** (chat is where RTL bites
  first — Arabic and Hebrew message bodies inside an LTR shell).
- **Should-have**: **system tray / status item**, **dock badge** on macOS,
  **global hotkeys**, **deep links / URL schemes**, **spellcheck**,
  **emoji picker**, drag and drop of attachments (HAS), **camera / photo
  picker** on mobile, **haptics**, **swipe actions**, **share sheet**,
  **background tasks** (fetch while backgrounded), **webview** (link previews,
  OAuth login).
- **Rarely needs**: printing, tree view, colour picker, maps, charts.

### A3. Task manager / todo
Real apps: **Todoist** (https://todoist.com/), **Things 3**
(https://culturedcode.com/things/), **Errands** (GNOME Circle).
Visibly used: checkbox lists (HAS), **date picker** (HAS) + **time picker**
(HAS), reorderable rows (HAS), **local notifications / reminders**,
**badges**, **swipe actions** (complete/delete on mobile), **tree/outline**
(sub-tasks and projects), **quick-entry global hotkey** (Things' and Todoist's
system-wide capture), **search field**, **share sheet** (add from another app),
**widgets**, **background tasks** (sync).

- **Must-have**: collections with reorder (HAS), checkbox (HAS), date+time
  pickers (HAS), **local notifications** (a reminder that does not fire is not a
  reminder), **search field**, **badges** (today count), navigation stack (HAS),
  sections/sidebar (HAS).
- **Should-have**: **tree view** (sub-tasks), **swipe actions**, **global
  hotkey** for quick capture, **system tray**, **share sheet**, **background
  tasks**, drag and drop between projects (HAS), **localization**,
  **haptics**.
- **Rarely needs**: video, webview, printing, colour picker, maps, charts.
- **NOTE**: this is the archetype kaya is closest to shipping. The gap is
  notifications + badges + search field.

### A4. Media player (audio + video)
Real apps: **VLC** (https://www.videolan.org/vlc/), **GNOME Videos / Decibels /
Amberol** (https://apps.gnome.org/), **Spotify desktop**, **Plex**.
Visibly used: **video surface**, **audio playback**, slider as a scrubber (HAS,
but needs live position updates), **fullscreen**, **always-on-top** (VLC's
"Always on top"), **system tray / media keys**, **global hotkeys** (play/pause),
**local notifications** (now playing), **captions/subtitles**, **file
associations** (open .mkv), **recent files**, **window position memory**,
**dock badge** rarely, **background audio** on mobile, **reduced motion**.

- **Must-have**: **video kind** and **audio playback** (definitionally),
  **fullscreen**, slider (HAS), **file associations**, **captions/subtitles**
  (legal requirement under Apple's Accessibility Nutrition Labels and the EAA's
  audiovisual clause), **background tasks / background audio** on mobile,
  **media keys / global hotkeys**.
- **Should-have**: **always-on-top / window presentation styles**, **system
  tray**, **local notifications**, **recent-files bookmarks**, **window position
  memory**, **share sheet**, **AirPlay/cast**(?), canvas (HAS — visualisers),
  **colour picker** rarely.
- **Rarely needs**: tree view (though library browsers use one), printing, rich
  text, forms.
- **NOTE**: this archetype is entirely blocked on the **video/audio** gap and
  cannot be approximated.

### A5. Photo viewer / gallery / light image editor
Real apps: **GNOME Image Viewer (Loupe)** and **Curtail / Switcheroo /
Obfuscate / Gradia** (GNOME Circle image tools), **Apple Photos**,
**IrfanView / XnView**.
Visibly used: grid of thumbnails (kaya HAS grid + image), zoom/pan gestures,
**horizontal scroll axis** for filmstrips, **fullscreen**, **share sheet**,
**printing**, **colour picker** (annotation tools), **camera / photo picker** on
mobile, **file associations**, drag and drop (HAS), **swipe** between photos,
**pull-to-refresh**? no.

- **Must-have**: image (HAS), grid + scroll (HAS), **fullscreen**, file dialogs
  (HAS), **file associations**, **horizontal scroll axis** (filmstrip),
  **camera / photo picker** on mobile (an iOS gallery app that cannot read the
  photo library is not one).
- **Should-have**: **printing**, **share sheet**, **colour picker**, canvas
  (HAS — for annotation), **swipe actions**, drag and drop (HAS),
  **recent files**, **window position memory**, zoom gestures (**not shipped —
  kaya has no pinch/zoom**).
- **Rarely needs**: notifications, tray, rich text, tree view, charts.

### A6. Settings-heavy utility / preferences app
Real apps: **GNOME Settings** (https://apps.gnome.org/), **Dconf Editor**,
**Rectangle/Raycast-style menu-bar utilities**, and *the majority of GNOME
Circle apps* (Dialect, Valuta, Binary, Collision, Curtail, Eyedropper …).
Visibly used: libadwaita's whole boxed-list vocabulary — **Switch Row**,
**Combo Row**, **Expander Row**, **Entry Row**, **Password Entry Row**,
**Spin Row** — plus Preferences Group / Page / Dialog, **search field** in the
settings window, **toast/snackbar** confirmations.

- **Must-have**: column/row/grid (HAS), label + entry + select + checkbox +
  slider (HAS), **toggle switch as a distinct kind** (every one of the four
  vendor catalogues has it; a checkbox is not a switch on iOS or Android),
  **search field**, settings **persistence** (kaya does not ship a settings
  store), **localization**.
- **Should-have**: **stepper / number field**, **segmented control**,
  **password/secure entry**, **sheet/modal beyond alerts** ("edit this item"),
  **popover**, **toast/snackbar**, **colour picker**, **hyperlinks** (a "learn
  more" link), **dynamic type**.
- **Rarely needs**: video, canvas, tree view, charts, camera.
- **NOTE**: this is the highest-volume archetype in the GNOME corpus below, and
  the one whose gaps are all small controls rather than subsystems.

### A7. Dashboard / data tool (tables + charts)
Real apps: **Graphs** and **Resources** (GNOME Circle),
**TablePlus** (https://tableplus.com/), **Grafana desktop-ish clients**,
**GNOME System Monitor**.
Visibly used: virtualized tables with sortable columns (kaya HAS, to 100k rows),
**charts** (kaya can rasterize them on canvas — HAS in principle, no chart
vocabulary), **tree view** (nested schema/rows), **printing / export**,
**search field**, **segmented control** for range pickers, **colour picker**
(series colours), **copy as CSV** (clipboard, HAS), auxiliary windows (HAS),
**session restoration** of open tabs/queries.

- **Must-have**: tables with sort (HAS), virtualization (HAS), scroll (HAS),
  **search field**, **tree view** (any schema browser or nested aggregation),
  charts — buildable on kaya's canvas today but with **no chart vocabulary**,
  clipboard (HAS).
- **Should-have**: **printing / PDF export**, **segmented control**,
  **colour picker**, **horizontal scroll axis** (wide tables — kaya's scroll is
  vertical only), **number/formatted field**, **session restoration**,
  **window position memory**, **localization + number/date formatting**.
- **Rarely needs**: video, camera, haptics, notifications (except alerting
  dashboards), tray.

### A8. File manager / sync / transfer client
Real apps: **GNOME Files (Nautilus)** (https://apps.gnome.org/Nautilus/),
**Dropbox / Nextcloud desktop clients**, **Warp** and **Fragments** (GNOME
Circle), **Transmit**.
Visibly used: **tree view** sidebar, list/grid switch, **context menus** (HAS),
drag and drop incl. cross-app (HAS), **system tray / status item** (every sync
client lives there), **local notifications** ("sync complete", "conflict"),
**dock/taskbar badge**, progress (HAS), **file associations**, **URL schemes**,
**background tasks**, **auto-update**, **recent files**, **search field**,
**printing** rarely.

- **Must-have**: **tree view**, context menus (HAS), drag and drop (HAS),
  file dialogs (HAS), progress (HAS), **search field**, **background tasks**
  (sync while the window is closed), **system tray / status item** (for the sync
  client sub-kind this is the whole UI), **local notifications**.
- **Should-have**: **badges**, **auto-update**, **file associations**,
  **recent-files bookmarks**, **window position memory**, **session
  restoration**, **URL schemes**, sections/sidebar (HAS), **swipe actions** on
  mobile.
- **Rarely needs**: video, charts, canvas, rich text, colour picker.

### A9. Developer tool (IDE-lite, DB client, API client, git UI)
Real apps: **VS Code** (https://code.visualstudio.com/docs/getstarted/userinterface),
**Zed** (https://zed.dev/), **GNOME Builder**, **Commit** (GNOME Circle),
**Postman/Insomnia**.
Visibly used: VS Code's own UI doc names the parts: **Explorer (tree view)**,
**Editor Groups (split panes)**, **Panel**, **Status Bar**, **Activity Bar**,
**Command Palette** — plus **syntax-highlighted rich text**, **search field**
with regex, **webview** (extensions, previews, docs), **terminal emulation**,
**tabs**, **multi-window**, **global hotkeys**, **auto-update**, **file
associations**, **URL schemes** (`vscode://`), **session restoration**,
**window position memory**, **printing** rarely.

- **Must-have**: **tree view**, **rich text with syntax highlighting**, split
  panes (kaya HAS adaptive panes to three columns), **search field**,
  textarea with find/highlight (HAS), menus + shortcuts (HAS), auxiliary
  windows (HAS), **session restoration**, **file associations**,
  **auto-update**.
- **Should-have**: **webview** (docs, previews, markdown render), **tabs**,
  **global hotkeys**, **URL schemes**, **printing**, **terminal**(?),
  **crash reporting**, **popover** (hover docs), **colour picker** (theme
  editing), **keyboard focus order control**.
- **Rarely needs**: camera, haptics, maps, biometrics, pull-to-refresh.

### A10. Timeline / video editor (creative canvas tool)
Real apps: **DaVinci Resolve**, **Kdenlive/Pitivi**, **Video Trimmer** and
**Constrict** (GNOME Circle), **Figma** (the non-video sibling,
https://www.figma.com/).
Visibly used: **video surface + scrubbing**, canvas with frame drive (kaya HAS
on_draw/on_tick), **horizontal scroll axis** (a timeline IS a horizontal
scroller), drag and drop with snapping (HAS the drag, not the snap), **colour
picker**, **number/formatted fields** (timecode), **stepper**, **tooltips**
(HAS `help`), **multi-window** (HAS), **fullscreen** preview,
**printing** no, **auto-update**, **crash reporting**, **keyboard focus order**,
**always-on-top** floating inspectors / **utility panels**.

- **Must-have**: **video playback surface** (a video editor without video is a
  demo), canvas (HAS), **horizontal scroll axis**, drag and drop (HAS),
  **number/formatted field** (timecode entry), **colour picker**,
  **fullscreen**, undo/redo (HAS), **window presentation styles** (inspector
  panels).
- **Should-have**: **stepper**, **segmented control**, **popover**,
  **auto-update**, **crash reporting**, **session restoration**, **file
  associations**, **printing** no, **share sheet**.
- **Rarely needs**: notifications, tray, tree view (though asset browsers use
  one), maps, biometrics.
- **NOTE**: kaya's canvas gets it most of the way; the two hard blocks are
  **video** and **horizontal scroll axis**.

### A11. Password manager / secrets / 2FA
Real apps: **Bitwarden** (https://bitwarden.com/), **1Password**,
**Secrets** and **Authenticator** (GNOME Circle).
Visibly used: **password / secure entry** (definitionally — a masked field with
reveal), **search field**, **biometrics** (Touch ID / Face ID / Windows Hello),
clipboard with auto-clear (HAS clipboard, no timed clear), **system tray**,
**global hotkey** (autofill), **browser extension / native messaging**,
**camera** (QR enrolment for TOTP), **URL schemes**, **auto-lock on idle**,
**auto-update**, **localization**, **reduced motion**.

- **Must-have**: **password/secure entry**, **search field**, **biometrics**
  (every mainstream manager gates unlock on it), clipboard (HAS),
  **camera** for TOTP QR on mobile, **auto-lock / idle detection** (kaya has no
  app-lifecycle or idle signal), **auto-update** (a security product must
  self-patch).
- **Should-have**: **system tray**, **global hotkeys**, **tree view** (folders),
  **badges**, **URL schemes**, **share sheet**, progress (HAS),
  **background tasks** (sync), **colour picker** no.
- **Rarely needs**: video, canvas, charts, printing (export excepted), maps.

### A12. Reader — RSS, documentation, e-books
Real apps: **NetNewsWire** (https://netnewswire.com/,
source https://github.com/Ranchero-Software/NetNewsWire), **Newsflash** and
**Komikku** and **Biblioteca** and **Wike** (GNOME Circle), **Apple Books**.
Visibly used: **tree view** of feeds/folders, **webview** (an RSS reader renders
HTML article bodies — NetNewsWire and Newsflash both embed a web view),
**rich text**, **hyperlinks**, **search field**, **badges** (unread count),
**local notifications** (new articles), **background tasks** (refresh),
**pull-to-refresh**, **swipe actions** (mark read/star), **share sheet**,
**dynamic type** (an e-book reader that cannot resize text is unusable and, in
the EU, illegal under the EAA's e-books clause), **printing**, **reduced motion**.

- **Must-have**: **webview or rich text with hyperlinks** (an article body is
  HTML — this is the single hardest requirement in the archetype), **tree
  view** / sidebar (HAS sections), **search field**, **dynamic type / font
  scaling**, **background tasks**, **pull-to-refresh** on mobile,
  **swipe actions** on mobile.
- **Should-have**: **badges**, **local notifications**, **share sheet**,
  **printing**, **reduced motion**, **localization + RTL**, **horizontal scroll
  axis** (paged e-book readers), **session restoration** (reading position).
- **Rarely needs**: canvas, video (except embedded), colour picker, maps,
  biometrics, tray.

### A13. Email client
Real apps: **Thunderbird** (https://www.thunderbird.net/), **Apple Mail**,
**Outlook**.
Visibly used: three-pane list-detail (kaya HAS), **tree view** of
folders/accounts, **rich text composition** (the compose window is a rich-text
editor — this is not optional in an email client), **HTML rendering / webview**,
**local notifications**, **badges**, **search field**, **spellcheck**,
**printing**, **file associations** (.eml, mailto:), **URL schemes** (`mailto:`),
**background tasks**, **swipe actions**, **pull-to-refresh**, **share sheet**,
**system tray**, **localization + RTL**.

- **Must-have**: **rich text editing**, **HTML rendering / webview**, **tree
  view**, **search field**, **local notifications**, **badges**, **spellcheck**,
  **URL schemes** (`mailto:` registration), **background tasks**,
  **localization + RTL**, list-detail panes (HAS), file dialogs (HAS).
- **Should-have**: **printing**, **system tray**, **swipe actions**,
  **pull-to-refresh**, **share sheet**, **file associations**, **session
  restoration**, drag and drop of messages (HAS), **auto-update**.
- **Rarely needs**: canvas, video, charts, colour picker, biometrics, maps.
- **NOTE**: the most feature-hungry archetype on this list. Nothing kaya could
  approximate.

### A14. Mobile commerce / catalogue
Real apps: **Amazon**, **Shopify**, **Etsy** mobile apps.
Visibly used: image-heavy scrolling grids (HAS), **pull-to-refresh**,
**horizontal scroll axis** (carousels — every commerce app has one),
**badges** (cart count), **local + push notifications**, **webview** (checkout,
3-D Secure, OAuth), **camera** (barcode/visual search), **share sheet**,
**deep links / URL schemes** (a product link must open the app),
**biometrics** (payment confirm), **localization + RTL + currency formatting**,
**dynamic type**, **haptics**, **maps** (store locator, delivery tracking),
**segmented control**, **search field**, **stepper** (quantity).

- **Must-have**: **search field**, **horizontal scroll axis** (carousels),
  **pull-to-refresh**, **badges**, **deep links / URL schemes**, **webview**
  (payment flows are web-hosted almost universally), **localization +
  number/currency formatting**, **push/local notifications**, **dynamic type**
  and **accessibility** (EAA: e-commerce is explicitly in scope from
  28 June 2025).
- **Should-have**: **camera**, **biometrics**, **share sheet**, **maps**,
  **haptics**, **stepper**, **segmented control**, **swipe actions**,
  **background tasks**, **RTL**.
- **Rarely needs**: printing, tree view, tray, canvas, multi-window,
  colour picker.

### A15. Mobile fitness / health
Real apps: **Strava**, **Apple Fitness / Health**, **Exercise Timer** and
**Solanum** (GNOME Circle, the desktop cousins).
Visibly used: **charts** (every one of them is a chart app), **maps** (route
tracking), **local notifications** (workout reminders, interval cues),
**haptics** (interval feedback — Apple's HIG explicitly recommends haptics as
an accessibility pairing for audio cues), **background tasks** (record a run
with the screen off), **health/sensor permissions**, **share sheet** (post a
run), **dynamic type**, **segmented control** (day/week/month),
**date picker** (HAS), progress rings (Apple HIG's "Activity rings"),
**badges**, **widgets**.

- **Must-have**: **charts** (canvas can draw them; there is no vocabulary),
  **local notifications**, **background tasks**, **haptics**,
  **maps** for the route sub-kind, **segmented control**, date picker (HAS).
- **Should-have**: **share sheet**, **badges**, **dynamic type**, **widgets**,
  **biometrics**, **camera**, **reduced motion**, **swipe actions**,
  **pull-to-refresh**.
- **Rarely needs**: tree view, printing, rich text, webview, multi-window,
  colour picker, tray.

---

## 4. A real corpus, counted: the 105 apps GNOME publishes

https://apps.gnome.org/ (scraped 2026-09-05) publishes **28 Core apps, 71 GNOME
Circle apps and 6 Development Tools = 105 apps**. GNOME Circle is a curated set
whose entry requirement is following the GNOME HIG, so it is the closest thing
that exists to a census of "apps a small team actually ships on a native
cross-platform-shaped toolkit". I classified all 105 into the archetypes above
and tagged each with the kaya NOT-SHIPPED capabilities its published description
and screenshots plainly require. The classification is reproducible and
inspectable at
`parts/gnome-classify.py` — it is my judgement, not GNOME's, and I have marked
it as such.

**Apps per archetype (n=105)**

| Archetype | Apps | Share |
|---|---:|---:|
| A6 Settings-heavy utility | 23 | 22% |
| A4 Media player (audio/video) | 11 | 10% |
| A5 Photo / image tool | 11 | 10% |
| A7 Dashboard / data tool | 11 | 10% |
| A12 Reader (RSS/docs/books) | 9 | 9% |
| A9 Developer tool | 8 | 8% |
| A8 File manager / sync | 7 | 7% |
| A1 Notes / text editor | 4 | 4% |
| A14 Commerce / catalogue | 4 | 4% |
| A2 Chat / messaging | 3 | 3% |
| A3 Task manager | 3 | 3% |
| A10 Timeline / creative | 3 | 3% |
| A15 Fitness / health | 3 | 3% |
| A11 Password manager | 2 | 2% |
| (games / toys) | 3 | 3% |

**Apps needing each NOT-SHIPPED capability (n=105)**

| Capability | Apps | Share |
|---|---:|---:|
| **search field** | 32 | 30% |
| **tree view** | 20 | 19% |
| **notifications** | 18 | 17% |
| **background tasks** | 14 | 13% |
| **rich text** | 13 | 12% |
| **webview** | 13 | 12% |
| **audio playback** | 10 | 10% |
| **video** | 8 | 8% |
| printing | 6 | 6% |
| colour picker | 6 | 6% |
| camera | 5 | 5% |
| horizontal scroll axis | 5 | 5% |
| charts (no vocabulary) | 5 | 5% |
| badges | 4 | 4% |
| fullscreen | 3 | 3% |
| spellcheck | 3 | 3% |
| maps, tabs, secure entry, haptics, localization, tray | 2 each | 2% |
| toggle switch, stepper, session restore, captions, animations, pull-to-refresh | 1 each | 1% |

**15 of 105 (14%) need nothing kaya lacks** — Calculator, Binary, Collision,
Curtail, File Shredder, Junction, Lorem, Obfuscate, Paper Clip, Switcheroo,
Tally, Webfont Bundler and three games. That is the honest measure of kaya's
current reach against a real catalogue: roughly one app in seven.

**Two caveats, stated rather than hidden.**
1. **The toggle-switch count of 1 is an artefact.** I tagged it only where the
   description forced it (Settings). In fact essentially every one of the 23 A6
   apps is built out of libadwaita boxed lists whose rows *are* switches, combo
   rows and spin rows — the widget gallery makes that plain. The true count for
   "toggle switch as a distinct kind" in this corpus is closer to 23 than to 1.
2. The corpus is Linux-desktop-shaped: it under-represents chat, commerce,
   fitness and email, and over-represents small single-purpose utilities. Read
   it as evidence about the *desktop utility* half of kaya's target, and the
   archetype tables in §3 for the rest.

**The finding that matters**: the top four — search field, tree view,
notifications, background tasks — are all things kaya does not have, and none of
them is a large subsystem. Search field is a styled entry with a clear affordance
and a role; tree view is the disclosure-plus-indent generalisation of the For
collection kaya already stamps; notifications is a per-platform API with a small
uniform surface; background tasks is a lifecycle contract. **Video, audio and
webview are the expensive ones and they rank 6th, 7th and 5th.**

---

## 5. Stack Overflow question volume per control

Method: the StackExchange API's `search/advanced` with `filter=total`, which
returns only a count, run per `(tag, full-text term)` pair on 2026-09-05.
Script and raw JSON: `parts/so-counts.py`, `parts/so-counts-*.json`.
Tags: `flutter` (the largest cross-platform corpus),
`swiftui`, `android-jetpack-compose`.
Example call:
`https://api.stackexchange.com/2.3/search/advanced?site=stackoverflow&tagged=flutter&q=webview&filter=total`

**Read this as semi-quantitative.** `q` is full text, so terms marked `*` are
inflated by unrelated matches: "printing" catches `print()` debugging, "maps"
catches Dart's `Map`, "focus"/"animation"/"notification" catch framework
internals, "camera" catches plugin questions. The unstarred rows are clean and
those are the ones I lean on.

**kaya NOT-shipped**

| term | flutter | swiftui | jetpack-compose | sum |
|---|---:|---:|---:|---:|
| maps * | 7,906 | 876 | 298 | 9,080 |
| printing * | 6,858 | 1,670 | 183 | 8,711 |
| localization * | 6,124 | 743 | 211 | 7,078 |
| animation * | 5,211 | 3,589 | 907 | 9,707 |
| notification * | 4,921 | 890 | 102 | 5,913 |
| camera * | 2,468 | 439 | 146 | 3,053 |
| webview | 1,985 | 325 | 121 | 2,431 |
| focus * | 1,292 | 555 | 362 | 2,209 |
| bottom sheet | 838 | 421 | 266 | 1,525 |
| video player | 704 | 169 | 46 | 919 |
| badge | 686 | 188 | 29 | 903 |
| search bar | 679 | 352 | 57 | 1,088 |
| password field | 497 | 79 | 33 | 609 |
| audio player | 390 | 73 | 13 | 476 |
| deep link | 365 | 59 | 53 | 477 |
| scroll to index | 327 | 108 | 57 | 492 |
| fullscreen | 292 | 204 | 40 | 536 |
| color picker | 289 | 324 | 16 | 629 |
| crash report | 254 | 82 | 20 | 356 |
| stepper | 222 | 172 | 4 | 398 |
| menu bar | 219 | 208 | 20 | 447 |
| pull to refresh | 200 | 85 | 24 | 309 |
| auto update | 197 | 56 | 11 | 264 |
| multiple windows | 189 | 74 | 9 | 272 |
| tree view | 174 | 111 | 35 | 320 |
| switch toggle | 172 | 222 | 23 | 417 |
| rtl | 133 | 30 | 25 | 188 |
| markdown | 115 | 54 | 4 | 173 |
| rich text | 105 | 24 | 3 | 132 |
| biometric | 89 | 13 | 6 | 108 |
| hyperlink | 85 | 34 | 4 | 123 |
| swipe to delete | 70 | 166 | 32 | 268 |
| share sheet | 50 | 110 | 13 | 173 |
| font scaling | 49 | 62 | 8 | 119 |
| system tray | 41 | 1 | 2 | 44 |
| spell check | 31 | 9 | 0 | 40 |
| keyboard ime | 30 | 7 | 43 | 80 |
| segmented control | 20 | 91 | 3 | 114 |
| popover | 18 | 316 | 3 | 337 |
| haptic | 16 | 26 | 6 | 48 |

**kaya shipped (baseline)**

| term | flutter | swiftui | jetpack-compose | sum |
|---|---:|---:|---:|---:|
| button * | 20,516 | 14,369 | 2,623 | 37,508 |
| scroll * | 6,022 | 2,442 | 1,142 | 9,606 |
| text field | 3,404 | 974 | 394 | 4,772 |
| table * | 2,723 | 503 | 97 | 3,323 |
| dropdown | 1,986 | 95 | 111 | 2,192 |
| tooltip | 1,449 | 23 | 13 | 1,485 |
| canvas * | 1,333 | 408 | 403 | 2,144 |
| grid * | 1,326 | 611 | 201 | 2,138 |
| image * | 1,243 | 247 | 42 | 1,532 |
| slider | 1,175 | 461 | 97 | 1,733 |
| checkbox | 1,143 | 94 | 108 | 1,345 |
| context menu | 686 | 217 | 22 | 925 |
| alert dialog | 676 | 34 | 38 | 748 |
| file picker | 621 | 120 | 19 | 760 |
| progress indicator | 540 | 32 | 37 | 609 |
| date picker | 402 | 308 | 40 | 750 |
| radio button | 400 | 30 | 24 | 454 |
| time picker | 287 | 236 | 28 | 551 |
| drag and drop | 198 | 223 | 32 | 453 |
| clipboard | 150 | 24 | 18 | 192 |
| undo | 146 | 53 | 15 | 214 |

**What the clean rows say.** Among things kaya does not ship, the highest
question volumes are **webview (2,431)**, **bottom sheet / modal presentation
(1,525)**, **search bar (1,088)**, **video player (919)**, **badge (903)**,
**colour picker (629)**, **password field (609)** and **fullscreen (536)**.
**System tray (44)**, **spellcheck (40)** and **haptics (48)** are the smallest —
real needs for specific archetypes, but not broad ones.

**Platform-shaped differences worth noting**, because they tell you where a
uniform semantics will be argued about:
- **popover**: 316 on SwiftUI, 18 on Flutter. It is an Apple-idiom control;
  Android answers the same need with a bottom sheet (266 on Compose, 838 on
  Flutter). A uniform "popover" in kaya has to decide which it is per platform —
  the same shape as kaya's existing adaptive-panes ruling.
- **swipe to delete**: 166 on SwiftUI vs 70 on Flutter — an iOS-list idiom.
- **menu bar**: 219/208/20 — a desktop concern only, and kaya already ships it.
- **switch toggle**: 222 on SwiftUI vs 172 on Flutter vs 23 on Compose. Low
  absolute numbers because it is *easy*; it is nonetheless in all four vendor
  catalogues. Question volume measures difficulty, not need — this is the one
  place the two metrics disagree and §1 and §4 should win.

---

## 6. What developers complain is missing — Flutter and Compose Multiplatform

Method: GitHub search API sorted by reactions (`gh api search/issues … -f
sort=reactions`), plus targeted feature-word searches, plus pub.dev's public
score endpoint. Full log with every query and every URL:
`parts/flutter-compose-issues.md`. Counts are `+1` reactions on 2026-09-05.

### Top missing-capability issues in flutter/flutter (open unless noted)

| +1 | Issue | Title |
|---:|---|---|
| 1,239 | [#14330](https://github.com/flutter/flutter/issues/14330) | Code Push / Hot Update / out-of-band updates |
| 471 | [#30701](https://github.com/flutter/flutter/issues/30701) | **Support multiple windows for desktop shells** |
| 463 | [#41722](https://github.com/flutter/flutter/issues/41722) | PlatformView (embed a native view) on macOS |
| 365 | [#31713](https://github.com/flutter/flutter/issues/31713) | PlatformView on Windows |
| 305 | [#18443](https://github.com/flutter/flutter/issues/18443) | Support soft hyphenation |
| 291 | [#37597](https://github.com/flutter/flutter/issues/37597) | **webview** on Windows |
| 273 | [#26134](https://github.com/flutter/flutter/issues/26134) | Home and lock screen **widgets** |
| 270 | [#30719](https://github.com/flutter/flutter/issues/30719) | Drag and drop across the Flutter boundary — **CLOSED, shipped** |
| 268 | [#41725](https://github.com/flutter/flutter/issues/41725) | **webview** on macOS — **CLOSED, shipped** |
| 226 | [#65504](https://github.com/flutter/flutter/issues/65504) | Ctrl+F, **finding text on a page** |
| 174 | [#142845](https://github.com/flutter/flutter/issues/142845) | Multi-view for Windows/macOS |
| 170 | [#37673](https://github.com/flutter/flutter/issues/37673) | **video_player** on Windows |
| 161 | [#41980](https://github.com/flutter/flutter/issues/41980) | Desktop splash / background colour |
| 140 | [#41724](https://github.com/flutter/flutter/issues/41724) | PlatformView on Linux |
| 118 | [#41726](https://github.com/flutter/flutter/issues/41726) | **webview** on Linux |
| 114 | [#23603](https://github.com/flutter/flutter/issues/23603) | **Rich clipboard** content |
| 107 | [#32045](https://github.com/flutter/flutter/issues/32045) | Clipboard should support **images** |
| 100 | [#30736](https://github.com/flutter/flutter/issues/30736) | **Window size / placement memory** on desktop |
| 35 | [#81644](https://github.com/flutter/flutter/issues/81644) | **System tray icons** on desktop |

Also: window chrome asks total 7 issues (title, splash, transparency, CSD,
size/position) topping at 161; l10n asks 4 issues topping at 126
([#107157](https://github.com/flutter/flutter/issues/107157), multiple ARB
files); IME 3 issues topping at 35.

### Compose Multiplatform — a structural caveat, checked not assumed
`JetBrains/compose-multiplatform`'s open GitHub "issues" are **all pull
requests** (24 items, every one with `pull_request != null`), and
`compose-multiplatform-core` has **Issues disabled entirely** (`has_issues:
false`). JetBrains closes GitHub issues and redirects to YouTrack
([#5102](https://github.com/JetBrains/compose-multiplatform/issues/5102),
"please use YouTrack"). So every top Compose request below is CLOSED **by
process, not by delivery**:

| +1 | Issue | Title |
|---:|---|---|
| 134 | [#344](https://github.com/JetBrains/compose-multiplatform/issues/344) | **Add Data table component** — the single highest-reaction CMP issue |
| 61 | [#85](https://github.com/JetBrains/compose-multiplatform/issues/85) | Navigation |
| 44 | [#425](https://github.com/JetBrains/compose-multiplatform/issues/425) | String resources for **i18n** |
| 42 | [#169](https://github.com/JetBrains/compose-multiplatform/issues/169) | `isSystemInDarkTheme` on desktop |
| 28 | [#290](https://github.com/JetBrains/compose-multiplatform/issues/290) | onClick handlers for **tray icon** |
| 26 | [#289](https://github.com/JetBrains/compose-multiplatform/issues/289) | API to get **system tray** location |
| 25 | [#668](https://github.com/JetBrains/compose-multiplatform/issues/668) | **WebView** support for desktop |
| 22 | [#277](https://github.com/JetBrains/compose-multiplatform/issues/277) | TextField missing DEL, selection, clipboard, singleLine |
| 17 | [#850](https://github.com/JetBrains/compose-multiplatform/issues/850) | **Menu bar apps** |

→ **kaya already ships the highest-reaction Compose Multiplatform ask**
(a data table with sortable columns, virtualized) and the highest-reaction
*shipped* Flutter ask (cross-app drag and drop).

### pub.dev likes as a proxy for "how many people paid a dependency to fill this gap"
Pulled live from `https://pub.dev/api/packages/<name>/score` on 2026-09-05.
A package that exists only because Flutter core lacks the feature is a decent
measure of the need's breadth:

| Gap the package fills | pub.dev likes |
|---|---:|
| native splash screen | 9,787 |
| **local / desktop notifications** (`flutter_local_notifications`) | **7,343** |
| secure storage | 4,488 |
| native Windows Fluent look (`fluent_ui`) | 3,224 |
| **PDF generation** (`pdf`) | 3,037 |
| **printing** (system print dialog) | 1,808 |
| **window position / size / state** (`window_manager`) | 1,123 |
| **colour picker** (`flutter_colorpicker`) | 1,024 |
| custom window frame (`bitsdojo_window`) | 1,060 |
| native macOS look (`macos_ui`) | 1,070 |
| window transparency / blur (`flutter_acrylic`) | 600 |
| **desktop file drop** (`desktop_drop`) | 466 |
| **multi-window** (`desktop_multi_window`) | 289 |
| **system tray** (`tray_manager` 289 + `system_tray` 288) | 577 combined |
| **rich clipboard** (`super_clipboard`) | 257 |
| **global hotkeys** (`hotkey_manager`) | 147 |
| **URL scheme registration** (`protocol_handler`) | 69 |

For scale, official first-party plugins: `url_launcher` 8,172,
`google_maps_flutter` 4,627, `share_plus` 4,023, `video_player` 3,719,
`local_auth` (biometrics) 3,374, `camera` 2,598.

**Reading**: notifications is the largest genuine gap-filler at 7,343 likes —
roughly twice the official video_player plugin and more than the official maps
plugin. Printing + PDF together (4,845) is much bigger than the GitHub issue
volume suggests. System tray, multi-window, window-state and global hotkeys are
each in the low hundreds: real, desktop-only, and small.

### Flutter's own survey data
- **Q2 2026 survey** (https://flutter.dev/blog/flutter-q2-2026-survey):
  Windows satisfaction 74%, Linux 73%, web 72%. **Cupertino widgets 61% — "the
  steepest decline anywhere in the survey" and "our lowest-rated area."**
  Largest dissatisfaction theme: platform/ecosystem maturity 44%; tooling 33%;
  bugs 24%; **UI/UX aesthetics only 14%**. The roadmap names "expanding
  multi-window desktop support with Canonical", i.e. Google confirms
  multi-window desktop is still not done in 2026.
- **Q3 2022 survey** (https://flutter.dev/blog/what-we-learned-from-the-flutter-q3-2022-survey):
  target platforms Android 91.7%, iOS 61.3%, web 35.5%; **76% build for two or
  more platforms**.
- No official Flutter "most-used widget" telemetry was located. Marked `?`.

**The finding that matters for kaya**: the #1 complaint in the Flutter
ecosystem is not a widget at all — it is **fidelity to the native design
language** (Cupertino 61%, Material 3 Expressive 561 +1, Liquid Glass 549 +1,
`fluent_ui`/`macos_ui` 4,294 likes combined). kaya's one-backend-per-platform
architecture is precisely the answer to that complaint, and it is the thing the
biggest competitor is measurably worst at.

---

## 7. What developers complain is missing — the other eight frameworks

### 7a. Electron, Tauri, React Native desktop

Method as above (`gh api search/issues`, sorted by reactions, open and closed
queried separately; closed issues kept, because a feature that took years and
hundreds of +1s to land is exactly the evidence wanted). Full log:
`parts/tauri-electron-rn-issues.md`. Repo scale on 2026-09-05: tauri 110,827
stars / 1,470 open issues; electron 122,897 / 744; react-native-windows
17,338 / 803; react-native-macos 4,383 / 108.

**First finding, and it is about the evidence itself**: the React Native desktop
trackers carry almost no voting signal. The highest-reaction OPEN issue on
react-native-windows has **15** `+1`
([#13534](https://github.com/microsoft/react-native-windows/issues/13534)) and
on react-native-macos **6**. Electron's top open issue has 402 and Tauri's 214.
React Native desktop is not a meaningful comparison population.

#### Top capability asks (deduplicated across the five repos)

| +1 | Repo / issue | Title | State |
|---:|---|---|---|
| 402 | [electron#673](https://github.com/electron/electron/issues/673) | Runtime mode (share one Electron across apps) | open |
| 257 | [electron#7781](https://github.com/electron/electron/issues/7781) | MacBook Touch Bar API | closed |
| 231 | [electron#10915](https://github.com/electron/electron/issues/10915) | Wayland build | closed |
| 214 | [tauri#14963](https://github.com/tauri-apps/tauri/issues/14963) | Bundle a Chromium renderer (i.e. stop depending on the system webview) | open |
| 155 | [electron#1335](https://github.com/electron/electron/issues/1335) | **Click-through transparency** | open |
| 155 | [electron#5362](https://github.com/electron/electron/issues/5362) | Workspace API | open |
| 122 | [tauri#3619](https://github.com/tauri-apps/tauri/issues/3619) | Flatpak bundling | open |
| 104 | [tauri#323](https://github.com/tauri-apps/tauri/issues/323) | **Custom URI scheme / deep linking** | closed, shipped |
| 92 | [electron#11907](https://github.com/electron/electron/issues/11907) | **Native headerbars** | closed |
| 85 | [tauri#2593](https://github.com/tauri-apps/tauri/issues/2593) | **Native file drag-and-drop out to the filesystem** | open |
| 82 | [electron#17523](https://github.com/electron/electron/issues/17523) | **"Please, make printing work with Electron!"** | closed |
| 81 | [electron#37494](https://github.com/electron/electron/issues/37494) | **Application window restoration** | open |
| 80 | [electron#2911](https://github.com/electron/electron/issues/2911) | Desktop-environment-aware file picker | closed |
| 74 | [tauri#2663](https://github.com/tauri-apps/tauri/issues/2663) | **Titlebar style with native window controls** | closed, shipped |
| 60 | [electron#9029](https://github.com/electron/electron/issues/9029) | **Native PDF rendering for printing** | closed |
| 59 | [electron#12337](https://github.com/electron/electron/issues/12337) | **Enable PDF viewer** | closed, shipped |
| 56 | [electron#30085](https://github.com/electron/electron/issues/30085) | **Notification badges on taskbar icons (Linux)** | closed |
| 48 | [plugins-workspace#2150](https://github.com/tauri-apps/plugins-workspace/issues/2150) | **Notification onclick event** | open |
| 47 | [tauri#4338](https://github.com/tauri-apps/tauri/issues/4338) | **Native context menu** | closed |
| 46 | [tauri#2709](https://github.com/tauri-apps/tauri/issues/2709) | Embed additional web content in a window | closed, shipped |
| 26 | [plugins-workspace#293](https://github.com/tauri-apps/plugins-workspace/issues/293) | **Silent print API** | open |
| 13 | [electron#526](https://github.com/electron/electron/issues/526) | **Save / restore window state** | closed |
| 8 | [tauri#9280](https://github.com/tauri-apps/tauri/issues/9280) | Easier system-tray menu updates | open |
| 0 | [electron#46](https://github.com/electron/electron/issues/46) | **`dock.badge()` and `dock.bounce()`** | closed |

Title-scoped match counts across the five repos (the API's own `total_count`,
a rough measure of how much traffic a topic generates): **notification 356**,
**video 184**, **PDF 168**, **drag and drop 102**, **printing 90**, **global
shortcut 77**, **auto update 73**, **transparency 71**, **multiple windows 52**,
**system tray 49**, **deep link 39**, **spellcheck 31**, **native menu 30**,
**IME 28**, **crash report 28**, **always on top 25**, **RTL 18**, **window
state restore 15**, **colour picker 9**, **dock badge 2**, **rich text 2**,
**tree view 2**.

**Reading.** The web-stack frameworks get their controls for free from HTML, so
their complaint list is *exactly* the list of things a webview cannot do:
printing, PDF, native menus, tray, badges, deep links, window chrome, window
state, drag-out-to-filesystem, IME. That is a clean, independent confirmation of
which needs are genuinely *platform* needs rather than widget needs — and it is
almost disjoint from the widget-shaped list in §1. **Tree view and rich text
barely register here (2 title matches each) because the DOM already has them.**

### 7b. What developers complain is missing — .NET MAUI, egui, iced, Slint

Same method (`gh api search/issues`, sorted by reactions). Raw dumps in
`parts/maui-*.tsv`, `parts/emilk_egui-*.tsv`, `parts/iced-rs_iced-*.tsv`,
`parts/slint-ui_slint-*.tsv`. **I re-verified nine of these counts directly
against `gh api repos/<owner>/<repo>/issues/<n>` before publishing them; all
nine matched.**

**.NET MAUI** (`dotnet/maui`) — top open feature asks:
125 [#11738](https://github.com/dotnet/maui/issues/11738) Blazor Hybrid on Linux ·
92 [#6](https://github.com/dotnet/maui/issues/6) **Transitions** ·
74 [#4528](https://github.com/dotnet/maui/issues/4528) web target ·
72 [#8191](https://github.com/dotnet/maui/issues/8191) Button with arbitrary content ·
63 [#7906](https://github.com/dotnet/maui/issues/7906) Entry/Editor border control ·
48 [#15441](https://github.com/dotnet/maui/issues/15441) Material 3 ·
30 [#7451](https://github.com/dotnet/maui/issues/7451) **tabbed windows** ·
29 [#9578](https://github.com/dotnet/maui/issues/9578) **light/dark splash screen** ·
29 [#4552](https://github.com/dotnet/maui/issues/4552) **custom cursor on desktop** ·
26 [#15440](https://github.com/dotnet/maui/issues/15440) FAB ·
23 [#9931](https://github.com/dotnet/maui/issues/9931) **printing UI for Windows/Android/iOS**.
Closed but telling: 269 [#3439](https://github.com/dotnet/maui/issues/3439) a
visual designer, 104 [#6903](https://github.com/dotnet/maui/issues/6903)
**multi-image picker**, **64 [#1259](https://github.com/dotnet/maui/issues/1259)
DataGrid control**, 40 [#1100](https://github.com/dotnet/maui/issues/1100)
date/time picker gaps, **32 [#2292](https://github.com/dotnet/maui/issues/2292)
cross-platform media player**, 45 [#30](https://github.com/dotnet/maui/issues/30)
**cross-platform lifecycle spec**.

**iced** (`iced-rs/iced`):
**138 [#302](https://github.com/iced-rs/iced/issues/302) mobile support** —
by far its largest ask, and the thing kaya already has ·
54 [#36](https://github.com/iced-rs/iced/issues/36) **text selection** ·
38 [#552](https://github.com/iced-rs/iced/issues/552) **accessibility** ·
**36 [#124](https://github.com/iced-rs/iced/issues/124) tray icon** ·
30 [#489](https://github.com/iced-rs/iced/issues/489) **keyboard focus /
tab traversal** ·
29 [#114](https://github.com/iced-rs/iced/issues/114) **menu bars** ·
17 [#156](https://github.com/iced-rs/iced/issues/156) **rich text styling** ·
17 [#160](https://github.com/iced-rs/iced/issues/160) virtualized list.

**Slint** (`slint-ui/slint`):
**36 [#2723](https://github.com/slint-ui/slint/issues/2723) rich text editor** ·
**31 [#3930](https://github.com/slint-ui/slint/issues/3930) webview element** ·
19 [#612](https://github.com/slint-ui/slint/issues/612) compositing/effects ·
**11 [#505](https://github.com/slint-ui/slint/issues/505) TreeView widget** ·
11 [#8735](https://github.com/slint-ui/slint/issues/8735) embed Servo ·
10 [#9781](https://github.com/slint-ui/slint/issues/9781) file dialogs on all
platforms · 10 [#3258](https://github.com/slint-ui/slint/issues/3258) transitions
for conditional elements.

**egui** (`emilk/egui`):
**26 [#3411](https://github.com/emilk/egui/issues/3411) native system menubar** ·
21 [#2551](https://github.com/emilk/egui/issues/2551) **colour emoji** ·
18 [#429](https://github.com/emilk/egui/issues/429) mnemonics ·
17 [#842](https://github.com/emilk/egui/issues/842) searchable ComboBox ·
14 [#1534](https://github.com/emilk/egui/issues/1534) code-editor line numbers.
Absolute numbers here are an order of magnitude smaller than Flutter's; egui's
community votes little.

**Reading, and this is the most useful cross-check in the whole study.** The
native/immediate-mode frameworks' complaint lists are the *inverse* of the
web-stack ones. Electron and Tauri users ask for platform integration
(printing, tray, badges, deep links, window state) because HTML gives them the
widgets. egui, iced and Slint users ask for **widgets and text**: rich text
(iced 17, Slint 36), tree view (Slint 11), text selection (iced 54), menu bars
(iced 29, egui 26), tray (iced 36), accessibility (iced 38), keyboard focus
traversal (iced 30). **kaya sits on the native side of that line**, so the
iced/Slint list is the closer analogue of its own future backlog — and kaya
already ships menu bars, text selection, accessibility and mobile, which are
four of iced's top seven.

### 7c. What the Rust-native frameworks SHIP — the floor, and where it stops

Second kind of evidence: a maintainer's own widget catalogue is a statement of
what they consider table stakes. Fetched from docs.rs / docs.slint.dev
(full detail in `parts/rust-gui-maui-issues.md`; I spot-verified seven of its
issue numbers against `gh api` and all seven matched).

- **egui** ships Button, Checkbox, RadioButton, Slider, DragValue, Label,
  **Hyperlink/Link**, Image, ProgressBar, Spinner, Separator, TextEdit,
  ComboBox, **colour picker** (a whole `color_picker` module), Grid,
  CollapsingHeader, an in-window menu system. **No tree view** (CollapsingHeader
  is hand-rolled into one), **no table in core** (that is `egui_extras`),
  **no date/time picker in core**, **no video, no webview**, **no OS-native
  menu bar** ([#3411](https://github.com/emilk/egui/issues/3411), 26 +1, open).
- **iced** ships Button, Checkbox, Radio, Slider, VerticalSlider, **Toggler
  (a switch)**, TextInput, TextEditor, PickList, ComboBox, ProgressBar, Image,
  Svg, QRCode, Canvas, Shader, **Tooltip**, PaneGrid, **Markdown**, **Table**,
  Float/Stack/Pin. **No tree view**, **no accessibility at all**
  ([#552](https://github.com/iced-rs/iced/issues/552), 38 +1, open; a second
  older ask [#282](https://github.com/iced-rs/iced/issues/282), 14 +1),
  **no native menu bar**, **no tray**, **no keyboard tab traversal**
  ([#489](https://github.com/iced-rs/iced/issues/489), 30 +1) — a striking gap
  for a framework this mature, and one kaya does not have.
- **Slint** ships Button, CheckBox, ComboBox, ProgressIndicator, RadioGroup,
  Slider, **SpinBox (stepper)**, Spinner, StandardButton, **Switch**, LineEdit,
  ListView, ScrollView, StandardListView, **StandardTableView**, **TabWidget**,
  TextEdit, GridBox, GroupBox, boxes, **DatePickerPopup**, **TimePickerPopup**.
  It is the only one of the three with a built-in table and built-in date/time
  pickers. **No TreeView** ([#505](https://github.com/slint-ui/slint/issues/505),
  11 +1), **no webview element**
  ([#3930](https://github.com/slint-ui/slint/issues/3930), 31 +1), **no rich
  text editor** ([#2723](https://github.com/slint-ui/slint/issues/2723), 36 +1,
  its highest open issue) — though rich text *rendering* shipped
  ([#9560](https://github.com/slint-ui/slint/issues/9560), 17 +1, closed).
  **System tray was its highest-reaction closed issue and it shipped**
  ([#6053](https://github.com/slint-ui/slint/issues/6053), 37 +1) — the clearest
  single data point that tray is a real desktop need rather than folklore.

**Window presentation, from `rust-windowing/winit`** (the layer all three sit
on; small audience, so counts are low but the topics are the signal):
[#2582](https://github.com/rust-windowing/winit/issues/2582) wlr-layer-shell
(41 +1, open — its top issue, and the Wayland protocol that lets an app be an
always-on-top panel), [#159](https://github.com/rust-windowing/winit/issues/159)
child windows (22), [#1499](https://github.com/rust-windowing/winit/issues/1499)
**file drag-OUT** (17 — distinct from drop-in, and the same ask as tauri #2593
at 85), [#862](https://github.com/rust-windowing/winit/issues/862) floating hint
for tiling WMs (13), [#1823](https://github.com/rust-windowing/winit/issues/1823)
software keyboard (14), **[#941](https://github.com/rust-windowing/winit/issues/941)
remember last window position/size (10, open)** — window state restore is not
built in anywhere in this stack.

**Accessibility, from `AccessKit`**: reaction counts across its whole open
tracker max out at **2**. That is not evidence accessibility is unwanted — it is
evidence that end-app developers never file against a backend library. The
demand shows up one layer up as iced #552 (38) and MAUI's accessibility issues.
What AccessKit's tracker does show is that Windows UIA support for **tooltips
(#30), menus (#27), tables with selectable rows (#29), radio groups (#24),
grids (#31) and combo boxes (#25)** is each tracked separately and none is done
— which is a useful map of where a Rust-stack a11y story is thin, and a place
kaya's per-platform backends give it an advantage.

### 7d. What real Electron apps visibly use

**The "awesome" lists, counted rather than eyeballed** (script-parsed from the
raw READMEs, 2026-09-05):
- **awesome-electron** (https://github.com/sindresorhus/awesome-electron):
  **123 real apps** (4 open-source featured, 76 open-source other, 2
  closed-source featured, 41 closed-source other) out of ~240 total entries —
  51% of the list is a showcase of shipped apps. Then 53 tools, then everything
  else in single digits.
- **awesome-tauri** (https://github.com/tauri-apps/awesome-tauri, default branch
  `dev`): **no Apps or Showcase section at all** — 7 guides, 5 articles, 28
  templates, 53 plugins, 16 integrations. Confirmed three ways: the README's own
  table of contents, the docs sitemap (4,163 URLs, no `showcase`/`gallery`
  path), and `v2.tauri.app/showcase/` returning 404. A community discussion
  asking for one (8 upvotes) is still open. So "what Tauri apps use" cannot be
  read off Tauri's own list; the 53 plugins are the signal instead, and a plugin
  list is a list of gaps.

**Capability checklist, nine named Electron apps** (`[cited]` = a live doc quote
pulled 2026-09-05; `[known]` = well-established product behaviour that could not
be re-cited because the vendor help centre returned 403 to automated fetches):

| App | Capabilities it visibly uses that kaya lacks |
|---|---|
| **VS Code** (https://code.visualstudio.com/docs/getstarted/userinterface) | multi-window `[cited]` ("floating windows"), **tabs** `[cited]`, split panes `[cited]`, **sidebar tree view** `[cited]`, **search field** + command palette `[cited]`, **popovers** (hover cards, IntelliSense) `[cited]`, **webview** (extension panels), **colour picker**, **URL scheme** `vscode://`, **auto-update`. Ships NO spellcheck, video/audio or printing natively. |
| **Notion** (https://www.notion.com/help/keyboard-shortcuts) | multi-window `[cited]`, **tabs** `[cited]`, **sidebar tree** `[cited]`, **search field** `[cited]` (⌘P/⌘K plus in-page ⌘F), **popovers** `[cited]` (`/`, `[[`, `+` menus), **rich text** as the whole editing model |
| **Obsidian** (https://obsidian.md/help/tabs) | **tabs** `[cited]`, split panes `[cited]`, multi-window by dragging a tab out `[cited]`, sidebar tree, **rich text / markdown live preview**, plugin **webviews**, **global hotkeys**, `obsidian://` **URL scheme**, **auto-update** |
| **Postman** (https://learning.postman.com/docs/getting-started/basics/navigating-postman/) | **tabs** `[cited]`, **sidebar tree** `[cited]`, split panes `[cited]`, **search field** `[cited]` (⌘K) |
| **Slack** | **notifications**, **system tray**, **unread badge**, **rich text** composer, **search field**, **popovers** (emoji/mention pickers), multi-window `[known]` |
| **Discord** | **system tray**, **notifications**, **global push-to-talk hotkey**, screen share, **rich text** (markdown) composer, **emoji/GIF picker popover** `[known]` |
| **Signal Desktop** (https://github.com/signalapp/Signal-Desktop) | **notifications** with content hiding, **system tray**, **badge count**, `sgnl://` **deep link**, **auto-update**, **search field** `[known]`, source is public so all re-checkable |
| **Insomnia** | sidebar tree, tabs, split panes, search, native menu, auto-update `[known]` |
| **Bitwarden Desktop** (https://github.com/bitwarden/clients/blob/main/package.json) | **auto-update** `[cited]` (`electron-updater` pinned beside `electron 43.2.0`), Linux snap/flatpak targets `[cited]`, `electron-rebuild` for native modules — the **biometric/keychain** integration; **system tray** ("close to tray"), **global hotkey** for autofill, `bitwarden://` **deep link**, clipboard auto-clear `[known]` |

**Reading**: the capability that appears in *every single one* of the nine is
**tabs plus a sidebar tree plus a search field**. That triple is the desktop
app shell, and kaya has one third of it (sections/sidebar). After that:
notifications and tray in the four communication/security apps, auto-update in
five, and rich text in four.

### 7e. Scale, for calibration
Not survey data, but real and dated (npm downloads for 2026-07-31 to
2026-08-29; repo stats via `gh api`, 2026-09-05):
electron **24,683,120** monthly npm downloads / 122,897 stars;
`@tauri-apps/api` **9,431,117** / `@tauri-apps/cli` 8,820,089 / 110,827 stars;
react-native-windows 17,338 stars; react-native-macos 4,383 stars.
Searched and **not found**: any "State of Electron" or "State of Tauri" survey
(Electron's blog carries only release notes; Stack Overflow's 2025 survey names
neither Electron nor Tauri anywhere; JetBrains' State of Developer Ecosystem
2024 says 53% of developers target desktop but names no desktop framework).
Recorded as "checked several likely sources, found nothing", not as proof of
absence — the session's web-search quota was exhausted, so only named-URL
fetches were possible.

---

### 7f. The hand-vetted cross-repo roll-up — who SHIPS it, who is ASKING for it

The strongest single artefact of the tracker research: for 40 features, a
per-framework verdict across MAUI / egui / iced / Slint, built by searching
`in:title` and then **reading every returned title by hand** to discard false
positives. Full table in `parts/rust-gui-maui-issues.md` §"Cross-repo feature
roll-up". **I re-verified nine more of its numbers against `gh api`; all nine
matched exactly.**

**Why the hand-vetting matters, and it is a warning about my §5 too**: the
automated full-text pass returned an egui issue titled "Showcase gallery" as the
**top hit for "notifications", "video" AND "camera" simultaneously**, because
those three words appear in its body. That is the same failure mode as the 13
starred rows in §5's Stack Overflow table, demonstrated concretely.

**Rows that change or sharpen the ranking:**

| Feature | What the hand-vetted sweep found | Effect on §9 |
|---|---|---|
| **search field** | MAUI ships a real SearchBar; **the three Rust crates have no dedicated search-field widget and nobody has filed for one under that name** | Confirms that low issue volume means "easy and unglamorous", not "unwanted". NEED 5 stands on the catalogue and corpus evidence, not on tracker demand. |
| **segmented control** | **Zero clean hits in any of the four trackers, and none of the four ships one** | A documented absence with essentially no visible demand. NEED 3 rests entirely on the vendor catalogues (Apple / Material / libadwaita all have it); flagged as the weakest-evidence row at that score. |
| **reduced motion** | **Zero real hits anywhere — nobody has filed for OS reduced-motion integration in any of the four** | NEED 3 rests **entirely** on compliance (Apple's Nutrition Labels, WCAG 2.3.3 via the EAA). No developer is asking. Both facts are true and the ranking should say so. |
| **spellcheck** | Zero hits in all four trackers | Confirms NEED 2. |
| **notifications** | This method did **not** surface it cleanly in any of the four; agent marked it `?` rather than guessing | NEED 5 rests on pub.dev (7,343 likes), the GNOME corpus (17%), Electron/Tauri title matches (356) and Microsoft policy 10.9 — not on these four trackers. Worth knowing the sources disagree. |
| **password/secure entry** | **Already shipped in all four** (MAUI, egui TextEdit password mode, iced `TextInput::secure`, Slint `input-type: password`) | Table stakes everywhere else. Strengthens "tiny to build, everyone has it". |
| **hyperlink** | **Already shipped in all four** — "already ubiquitous, not a gap" | kaya is the outlier in lacking it. Strengthens NEED 4. |
| **tooltip, multi-window, drag and drop** | Already shipped everywhere; the issues are bugs, not absence | kaya already has all three — parity, not advantage. |
| **date/time picker** | **iced has literally none and no visible ask**; egui's exists only as a third-party `egui_extras` add-on; Slint and MAUI ship them | kaya ships both, natively, on five platforms. |
| **tree view** | **None of the four ships one.** egui has no tree widget at all (CollapsingHeader is the workaround); MAUI [#14341](https://github.com/dotnet/maui/issues/14341) (6 +1) bundles TreeView with TabControl and GridSplitter | Confirms NEED 4 and shows the whole native-toolkit field is missing it. |
| **rich text editor** | Asked for in three of four: Slint [#2723](https://github.com/slint-ui/slint/issues/2723) (36), iced [#156](https://github.com/iced-rs/iced/issues/156) (17), MAUI [#29016](https://github.com/dotnet/maui/issues/29016) (12) | Confirms NEED 4. |
| **video player** | Real gap in egui ([#5566](https://github.com/emilk/egui/issues/5566), 1 +1) and iced ([#316](https://github.com/iced-rs/iced/issues/316), 8 +1), but **barely upvoted anywhere** | Supports NEED 3, not higher: expensive, and the demand is narrow. |
| **background tasks** | MAUI [#2244](https://github.com/dotnet/maui/issues/2244) "hosted services" (30 +1, open); **not applicable to the three Rust crates**, which have no app-lifecycle model to hang one off | kaya, having a real lifecycle across five platforms, is the framework for which this is both meaningful and missing. |
| **window state restore** | iced [#1104](https://github.com/iced-rs/iced/issues/1104) (2), MAUI [#7592](https://github.com/dotnet/maui/issues/7592) (8), winit [#941](https://github.com/rust-windowing/winit/issues/941) (10) — modest but present at every layer | Confirms NEED 3. |
| **always-on-top / transparency / fullscreen** | The API exists in all four; the demand shows up as **"doesn't work on <platform>"** bug reports, not feature requests — and **both egui and iced have an open "transparency broken specifically on Windows" issue** ([egui #4451](https://github.com/emilk/egui/issues/4451), [iced #2525](https://github.com/iced-rs/iced/issues/2525), 7 +1) | A reaction-sorted search structurally under-counts this class. kaya's five-lane matrix is exactly the instrument that catches it. |
| **auto-update** | **No signal in any of the four**; marked unknown rather than guessed | NEED 3 rests on the Electron/Bitwarden evidence alone. |
| **scroll-to-item** | Slint [#11826](https://github.com/slint-ui/slint/issues/11826) (5 +1) is the cleanest statement of the gap: the built-in list can scroll-to-item, a hand-rolled one cannot | Confirms NEED 3. |
| **keyboard focus / tab order** | iced [#489](https://github.com/iced-rs/iced/issues/489) (30) and Slint [#81](https://github.com/slint-ui/slint/issues/81) (6); MAUI's TabIndex/TabStop APIs are still work-in-progress ([#16218](https://github.com/dotnet/maui/issues/16218), 8) | Nobody in this field has solved it. Confirms NEED 3. |

**The corrected top-five by highest single reaction count across egui / iced /
Slint / MAUI**: animation-transitions (MAUI [#6](https://github.com/dotnet/maui/issues/6),
92), accessibility (iced #552, 38), system tray (Slint #6053, 37 closed-shipped;
iced #124, 36 open), rich text editor (Slint #2723, 36), keyboard focus order
(iced #489, 30). MAUI's overall highest open issue,
[#11738](https://github.com/dotnet/maui/issues/11738) Blazor Hybrid on Linux
(125), is a platform-support gap rather than a capability gap and sits outside
that list.

---

## 8. Needs the evidence surfaced that are NOT in kaya-surface.md's NOT-shipped list

Twelve, each with the evidence that found it. These are added to the ranking
table in §9.

1. **Native view embedding (a "PlatformView" escape hatch).** Flutter's three
   open issues total **968 `+1`** — macOS
   [#41722](https://github.com/flutter/flutter/issues/41722) 463, Windows
   [#31713](https://github.com/flutter/flutter/issues/31713) 365, Linux
   [#41724](https://github.com/flutter/flutter/issues/41724) 140. This is the
   single largest *capability* cluster in the Flutter tracker after code push.
   It matters structurally: it is the one feature that makes every OTHER missing
   feature (maps, webview, video, camera preview, a PDF view, a rich-text
   editor) an app-author problem rather than a framework problem. For a
   nine-binding framework it is also the hardest thing to give uniform
   semantics, so it deserves an explicit ruling rather than silence.
2. **Splash screen / first-frame appearance.** `flutter_native_splash` is the
   **most-liked gap-filling package on pub.dev at 9,787 likes**; the desktop
   equivalent is [flutter#41980](https://github.com/flutter/flutter/issues/41980)
   (161). Every shipped app has one.
3. **Chart vocabulary.** Apple's HIG has Charts as a top-level component;
   Material has none but Compose Multiplatform's **highest-reaction issue of all
   time** is [#344 "Add Data table component" (134)](https://github.com/JetBrains/compose-multiplatform/issues/344),
   the same shape of ask. Must-have for 2 archetypes (dashboard, fitness).
   kaya's canvas can already draw one; what is missing is a vocabulary.
4. **Captions / subtitles.** Required by Apple's Accessibility Nutrition Labels
   and by the EAA's audiovisual clause. Only matters if video ships, but it is
   not optional once it does.
5. **Secure storage / keychain.** `flutter_secure_storage` **4,488 pub.dev
   likes**. Must-have for password managers, should-have for anything that logs
   in. Not a widget; a platform service.
6. **App lifecycle and idle signals.** A password manager auto-locks on idle;
   a media player pauses on background; a sync client wakes on resume. kaya has
   no lifecycle surface at all. Found via the password-manager and media
   archetypes, not by any tracker.
7. **Text layout controls** — hyphenation, ellipsis position, line clamp.
   [flutter#18443 "soft hyphenation" 305 `+1`](https://github.com/flutter/flutter/issues/18443)
   and [flutter#45336 "ellipsisStart/Middle/End" 210](https://github.com/flutter/flutter/issues/45336).
   Together 515 — larger than any single widget ask in the Flutter tracker.
8. **Toast / snackbar.** Material ships `Snackbar`, libadwaita ships
   `ToastOverlay`, and it is the standard "your change was saved / undo" surface
   in the settings archetype. kaya has alerts, which are modal, and nothing
   transient.
9. **Pinch / zoom and other multi-touch gestures.** Photo, map and canvas
   archetypes all need it; kaya has no gesture vocabulary beyond click and drag.
10. **Emoji picker.** GTK ships `EmojiChooser`; chat and notes both use it.
    Small, but it is the one input surface a text field cannot fake.
11. **PDF rendering and generation** (distinct from printing).
    `pdf` package **3,037 pub.dev likes**;
    [electron#12337 "Enable PDF Viewer" (59, shipped)](https://github.com/electron/electron/issues/12337)
    and [electron#9029 "native PDF rendering" (60)](https://github.com/electron/electron/issues/9029).
    Document Viewer is a GNOME Core app.
12. **Code push / out-of-band update.** The **single highest-reaction open issue
    in flutter/flutter at 1,239 `+1`**
    ([#14330](https://github.com/flutter/flutter/issues/14330)). It is a
    distribution feature, not a GUI feature, and for kaya it is out of scope —
    but it is recorded here because it is the loudest voice in the entire
    corpus and a roadmap should say out loud that it has considered and declined
    it rather than never having seen it.

---

## 9. THE RANKING

**How to read it.** `must-have` and `should-have` are counts over the 15
archetypes of §3, computed from the transcribed matrix in `parts/rank.py` (run
it; the numbers are reproducible, and they are my classification, not anyone
else's). `NEED` is 1-5 and is a judgement over ALL the evidence — the archetype
counts, the 105-app GNOME census, the four vendor catalogues, Stack Overflow
volume, issue upvotes and pub.dev likes, and store/legal obligation — not a
function of the counts alone. Where the matrix undercounts a feature because it
is cross-cutting rather than archetype-specific (animations, IME, settings
persistence, toggle switch, modal sheets), the note says so and NEED wins.
Where the sources actively disagree — notifications, reduced motion,
segmented control — the row says which sources carry the score and which
found nothing, rather than averaging them into a number that hides it.

| NEED | feature | must-have (of 15) | should-have (of 15) | evidence |
|:---:|---|:---:|:---:|---|
| **5** | search field | 11 | 0 | 30% of the 105 GNOME apps; SO 1,088; in all four vendor catalogues; in all 9 Electron apps checked |
| **5** | notifications | 6 | 2 | largest gap-filling pub.dev package (flutter_local_notifications 7,343 likes); 17% of GNOME apps; 356 Electron/Tauri title matches; Microsoft Store policy 10.9 — *note: the hand-vetted native-tracker sweep did NOT surface it and marked it `?` (§7f); the sources disagree and this score rests on the other four* |
| **4** | tree view | 6 | 2 | 19% of GNOME apps; **absent from egui, iced AND Slint** (Slint #505, 11 +1); Apple Outline views + Disclosure controls; GTK TreeView; a sidebar tree in all 9 Electron apps checked |
| **4** | background tasks | 5 | 4 | 13% of GNOME apps; MAUI #2244 hosted services (30 +1) — and **not applicable to egui/iced/Slint at all**, which have no app-lifecycle model (§7f), so kaya is the framework for which this is both meaningful and missing; sync, refresh and record-with-screen-off |
| **4** | hyperlinks/rich text/markdown | 5 | 2 | 12% of GNOME apps; asked for in 3 of 4 native trackers — **Slint's highest open issue #2723 (36)**, iced #156 (17), MAUI #29016 (12); plain hyperlinks are shipped by ALL FOUR (§7f), so kaya is the outlier; Apple Text views, GTK TextView; the composer in Slack, Discord, Notion and every email client |
| **4** | badges | 4 | 4 | SO 903; electron #30085 taskbar badges (56), #46 dock.badge; unread counts in every chat/mail app |
| **4** | localization/RTL | 4 | 3 | Microsoft Store policy 10.7 REQUIRES it; flutter l10n asks top out at 126; EAA scope — *compliance item* |
| **4** | webview | 3 | 2 | highest clean SO row at 2,431; flutter desktop webview 291/268/118; Slint #3930 (31); CMP #668; 12% of GNOME apps |
| **4** | dynamic type / font scaling | 2 | 2 | Apple Accessibility Nutrition Label 'Larger Text 200%+' — becoming MANDATORY; WCAG 1.4.4 via EAA — *compliance item* |
| **4** | settings persistence | 1 | 0 | shared_preferences is a top-10 pub.dev package; MAUI #4408 appsettings (47) — *matrix undercounts: every archetype stores preferences* |
| **4** | toggle switch | 1 | 0 | in ALL FOUR vendor catalogues (Apple Toggles / Material Switch / Adw Switch Row / GTK Switch) — *matrix undercounts badly: ~23 of the 105 GNOME apps are libadwaita boxed lists* |
| **4** | animations/transitions | 0 | 0 | MAUI's top pure-feature ask #6 Transitions (92); Slint #3258; SO 9,707 (noisy) — *cross-cutting, so no archetype names it — a real miss in the matrix* |
| **4** | sheet/modal beyond alerts | 0 | 1 | SO 1,525 for bottom sheet — 2nd highest clean row; Material BottomSheet+SideSheet, Adw Bottom Sheet, Apple Sheets+Action sheets — *matrix undercounts: it is the standard secondary-screen surface on mobile* |
| **4** | splash screen **[not in kaya's list]** | ? | ? | flutter_native_splash is the MOST-liked gap-filler on pub.dev at 9,787; MAUI #9578 (29); flutter #41980 (161) — *not in kaya's NOT-shipped list* |
| **3** | file associations | 3 | 4 | every document app; MAUI/Electron/Tauri all ship it |
| **3** | fullscreen | 3 | 0 | SO 536; media, photo, reader and editor archetypes |
| **3** | horizontal scroll axis | 3 | 2 | carousels (commerce), filmstrips (photo), timelines (editor), wide tables (dashboard) |
| **3** | video/audio | 3 | 0 | 10%/8% of GNOME apps; SO 919+476; flutter video_player Windows #37673 (170); MAUI #2292 (32); egui #5566 (1) and iced #316 (8) — *expensive, and the native-side demand is thin; blocks 1 archetype entirely* |
| **3** | URL schemes/deep links | 2 | 4 | tauri #323 (104, shipped); protocol_handler 69 likes; mandatory for commerce |
| **3** | auto-update | 2 | 3 | Bitwarden pins electron-updater [cited]; 5 of 9 Electron apps; a security product must self-patch |
| **3** | camera/photo picker | 2 | 3 | MAUI #6903 multi-image picker (104, shipped); camera plugin 2,598 likes |
| **3** | chart vocabulary **[not in kaya's list]** | 2 | 0 | CMP's highest-reaction issue ever is #344 Data table (134) — same shape; Apple HIG has Charts top-level; MAUI #1259 DataGrid (64) — *not in kaya's list; canvas can draw it, the vocabulary is missing* |
| **3** | session restoration | 2 | 5 | electron #37494 (81) and #526; every document and dev tool |
| **3** | app lifecycle / idle **[not in kaya's list]** | 1 | 0 | MAUI #30 [Spec] Cross-Platform LifeCycle (45); password auto-lock, media pause, sync wake — *not in kaya's list* |
| **3** | colour picker | 1 | 5 | SO 629; flutter_colorpicker 1,024 likes; 6% of GNOME apps; Apple Color wells, GTK ColorDialogButton |
| **3** | password/secure entry | 1 | 1 | SO 609; **already shipped by all four of MAUI/egui/iced/Slint** (§7f); GTK PasswordEntry, Adw Password Entry Row, Apple secure text field; every login screen — *tiny to build, and kaya is the outlier without it* |
| **3** | plural/date/number formatting | 1 | 1 | EAA + Microsoft 10.7; every commerce and dashboard app |
| **3** | scrollTo | 1 | 0 | SO 492; flutter #19941 (172) and #65504 Ctrl+F (226); jump-to-unread in every list app |
| **3** | secure storage / keychain **[not in kaya's list]** | 1 | 3 | flutter_secure_storage 4,488 pub.dev likes — *not in kaya's list* |
| **3** | segmented control | 1 | 4 | Apple Segmented controls, Material ToggleButtonGroup, Adw Toggle Group; SwiftUI SO 91 — *weakest-evidence row at this score: the hand-vetted sweep (§7f) found ZERO demand in any of MAUI/egui/iced/Slint, and none of the four ships one; the vendor catalogues are the whole case* |
| **3** | swipe actions | 1 | 7 | SwiftUI SO 166 vs Flutter 70 — an iOS list idiom; should-have in 7 of 15 archetypes |
| **3** | system tray/status item | 1 | 5 | **Slint shipped it as its highest-reaction closed issue, #6053 (37)**; iced #124 (36, open); flutter #81644 (35); CMP #289/#290 (26/28); tray_manager+system_tray 577 likes; 49 Electron/Tauri title matches — *small numbers everywhere, but it IS the whole UI of a sync client* |
| **3** | window position memory | 1 | 4 | window_manager 1,123 likes; flutter #30736 (100); electron #526 and #37494 (81); winit #941 (10) — not built in anywhere in the Rust stack |
| **3** | IME contract | 0 | 0 | electron #33662 Wayland IME (86); flutter 3 issues topping 35; Compose SO 43 — *cross-cutting: every text app in CJK markets — no archetype names it* |
| **3** | keyboard focus order control | 0 | 1 | iced #489 (30) — iced still cannot tab between most widgets; Apple Full Keyboard Access; WCAG 2.4.3 via EAA — *compliance-adjacent* |
| **3** | popover | 0 | 4 | SwiftUI SO 316 vs Flutter 18 — Apple idiom; Apple Popovers, GTK Popover; cited in VS Code, Notion, Slack, Discord |
| **3** | printing | 0 | 6 | electron #17523 'Please, make printing work with Electron!' (82); pdf 3,037 + printing 1,808 likes; MAUI #9931 (23); GTK PrintUnixDialog |
| **3** | reduced motion | 0 | 3 | Apple Accessibility Nutrition Label declarable feature — becoming MANDATORY; WCAG 2.3.3 via EAA — *compliance item, and ONLY that: the hand-vetted sweep found nobody has ever filed for reduced motion in any of the four native trackers (§7f)* |
| **3** | share sheet | 0 | 10 | should-have in 10 of 15 archetypes — the highest should-count of any feature; share_plus 4,023 likes; Apple Activity views |
| **3** | toast/snackbar **[not in kaya's list]** | 0 | 1 | Material Snackbar, Adw ToastOverlay; the 'saved / undo' surface of the settings archetype — *not in kaya's list* |
| **3** | native view embedding **[not in kaya's list]** | ? | ? | flutter PlatformView macOS 463 + Windows 365 + Linux 140 = 968 — the largest capability cluster after code push — *not in kaya's list; the escape hatch that makes every other gap an app problem* |
| **3** | tabs **[not in kaya's list]** | ? | ? | cited in VS Code, Notion, Obsidian, Postman; MAUI #7451 tabbed windows (30); GTK Notebook, Adw Tab Bar — *kaya's sections cover part of this* |
| **3** | text layout controls **[not in kaya's list]** | ? | ? | flutter #18443 soft hyphenation (305) + #45336 ellipsis position (210) = 515, larger than any single widget ask there — *not in kaya's list* |
| **2** | pull-to-refresh | 2 | 2 | SO 309; mobile reader, commerce, chat, mail |
| **2** | spellcheck | 2 | 1 | SO 40; 31 Electron/Tauri title matches; zero hits in all four native trackers (§7f); notes, mail, chat |
| **2** | biometrics | 1 | 2 | local_auth 3,374 likes; must-have for password managers only |
| **2** | captions/subtitles **[not in kaya's list]** | 1 | 0 | Apple Accessibility Nutrition Label declarable feature; EAA audiovisual clause — *not in kaya's list; mandatory once video ships* |
| **2** | global hotkeys | 1 | 4 | hotkey_manager 147 likes; 77 Electron/Tauri title matches; Discord push-to-talk, Bitwarden autofill |
| **2** | haptics | 1 | 3 | SO 48; Apple HIG recommends haptics as the accessibility pairing for audio cues |
| **2** | maps | 1 | 1 | google_maps_flutter 4,627 likes; GNOME Maps is a Core app; SO noisy |
| **2** | number/formatted field | 1 | 1 | Apple Digit entry views, GTK SpinButton, Adw Spin Row; timecode and quantity entry |
| **2** | window presentation styles | 1 | 1 | electron #1335 click-through transparency (155); VLC always-on-top; flutter_acrylic 600 likes; **egui #4451 AND iced #2525 both report transparency broken specifically on Windows** — the demand shows as per-platform breakage, which a reaction-sort under-counts (§7f) |
| **2** | crash reporting | 0 | 2 | 28 Electron/Tauri title matches; 2 archetypes should-have |
| **2** | dock badge | 0 | 1 | electron #46 dock.badge/dock.bounce; electron #30085 Linux taskbar badges (56) — *subsumed by badges* |
| **2** | emoji picker **[not in kaya's list]** | 0 | 1 | GTK EmojiChooser; egui #2551 colour emoji (21); chat and notes — *not in kaya's list* |
| **2** | pinch/zoom gesture **[not in kaya's list]** | 0 | 1 | photo, map and canvas archetypes; kaya has no gesture vocabulary beyond click and drag — *not in kaya's list* |
| **2** | recent-files bookmarks | 0 | 4 | every document archetype's File menu |
| **2** | stepper | 0 | 3 | Apple Steppers, GTK SpinButton, Adw Spin Row; SO 398 |
| **2** | PDF render/generate **[not in kaya's list]** | ? | ? | pdf 3,037 likes; electron #12337 PDF viewer (59, shipped), #9029 (60); GNOME Document Viewer is a Core app — *not in kaya's list; distinct from printing* |
| **1** | code push / OTA update **[not in kaya's list]** | 0 | 0 | flutter #14330 — 1,239 +1, the single loudest issue in the whole corpus — *not in kaya's list; almost certainly out of scope for kaya, recorded so the roadmap declines it explicitly rather than never seeing it* |

**60 rows: all 47 items from kaya-surface.md's NOT-shipped list, plus the 13
found in §8 that are not on it.** Nothing from that list is omitted — checked
item by item. `?` in a count column means the feature is outside the §3 matrix
(it was found by evidence, not by archetype), not that I guessed.

### The five things this table says that the raw counts do not

1. **Search field is the single clearest gap.** It is must-have in 11 of 15
   archetypes, needed by 30% of a real 105-app catalogue, present in every
   vendor catalogue and in every one of the nine Electron apps checked — and it
   is a styled entry with a role and a clear affordance, not a subsystem.
   Nothing else in the list has that ratio of breadth to cost.
2. **The top four gaps are all cheap.** Search field, notifications, tree view
   and background tasks. Video, audio and webview — the expensive ones — rank
   6th, 7th and 8th on the GNOME census.
3. **Four items are compliance, not preference**: dynamic type / font scaling
   and reduced motion (Apple's Accessibility Nutrition Labels are becoming
   mandatory; WCAG 1.4.4 and 2.3.3 reach EU apps through the EAA from
   28 June 2025), localization/RTL (Microsoft Store policy 10.7), and
   notifications that keep working when disabled (Microsoft policy 10.9). These
   cannot be deferred on the grounds that few archetypes name them.
4. **Animations/transitions and the IME contract score 0/0 in the matrix and
   are still NEED 4 and 3.** They are cross-cutting: no archetype lists
   "animation" as a must-have and every one of them has animations. MAUI's
   highest-reaction pure-feature request is literally
   [#6 "[Spec] Transitions" (92)](https://github.com/dotnet/maui/issues/6).
   A matrix built from archetypes structurally cannot see this class, so it is
   flagged rather than trusted.
5. **kaya already ships the top ask of two competing frameworks.** Compose
   Multiplatform's highest-reaction issue of all time is a data table (134);
   iced's is mobile support (138). kaya has both, plus the highest-reaction
   *shipped* Flutter ask (cross-app drag and drop, 270).

### The three archetypes kaya could almost build today

Counted from the matrix: the archetypes with the fewest must-have gaps.

**1. Task manager / todo (A3) — 3 must-have gaps.**
Blocked on **local notifications**, **search field**, **badges**.
Everything else is already there: checkbox collections with keyed row
templates and reorder, date and time pickers, navigation stack, sidebar
sections, drag and drop between projects, undo/redo, menus and shortcuts,
adaptive list-detail on the phone. Real comparables: Todoist, Things 3, GNOME
Errands. Of the three gaps, badges is arguably part of the notifications slice,
so this is effectively **two pieces of work away from a shippable Things-class
app on five platforms** — which no other framework can claim.

**2. Dashboard / data tool (A7) — 3 must-have gaps.**
Blocked on **search field**, **tree view**, and a **chart vocabulary** (the
canvas can already rasterize charts; what is missing is a way to say "bar chart
of this signal" rather than hand-drawn display lists). kaya's virtualized
100k-row sortable table is the differentiator here and is precisely the thing
Compose Multiplatform's community has asked for 134 times and MAUI's 64. Real
comparables: TablePlus, GNOME Resources, Graphs. Second-order wants:
horizontal scroll axis for wide tables, printing/export, number field.

**3. Settings-heavy utility (A6) — 4 must-have gaps, and the biggest archetype
by volume (22% of the GNOME catalogue).**
Blocked on a **toggle switch as a distinct kind**, **search field**,
**settings persistence**, and **localization**. Every one of those is small.
The payoff is the largest single class of app anyone actually ships on a
native toolkit: 23 of 105 in the GNOME census, and the archetype whose whole
vocabulary — Switch Row, Combo Row, Spin Row, Entry Row, Preferences Group —
libadwaita has built a first-class row API for. Second-order wants: stepper,
segmented control, password entry, sheet/modal, toast.

**Runner-up worth naming: photo viewer / gallery (A5), 4 gaps** — fullscreen,
file associations, horizontal scroll axis, and camera/photo picker on mobile.
Three of those four are small; only the photo picker is a real platform slice.

### What is NOT worth building for breadth
By this evidence: **code push / OTA** (loudest in the corpus, wrong layer for
kaya), **maps** (2 archetypes, and a vendor SDK dependency on every platform),
**biometrics** (1 archetype must-have), **haptics** (1), **crash reporting**
(0 must-have), **dock badge** as a separate feature from badges, and **PDF
generation** as distinct from printing. Each is real; none is broad.

### Honest gaps in this study
- No official "most-used widget" telemetry exists for Flutter, SwiftUI or
  Compose that I could find. Marked `?` throughout rather than guessed.
- No "State of Electron" or "State of Tauri" survey was found; Stack Overflow's
  2025 survey names neither framework. Recorded as checked-not-found.
- The 105-app GNOME classification is mine, not GNOME's, and it is
  Linux-desktop-shaped: it under-counts chat, email, commerce and fitness.
- Stack Overflow counts are full-text and noisy on 13 marked terms. The scale of
  that noise is now demonstrated rather than assumed: the same technique applied
  to GitHub returned one egui issue titled "Showcase gallery" as the top hit for
  "notifications", "video" AND "camera" at once (§7f). Treat every starred row
  in §5 as an upper bound.
- **The evidence sources disagree in two places, and I have not smoothed it
  over.** Notifications scores NEED 5 on four sources but did not surface at all
  in the hand-vetted native-tracker sweep. Reduced motion scores NEED 3 purely
  on legal obligation with literally zero developer demand behind it. Segmented
  control scores NEED 3 on the vendor catalogues alone. Each is flagged in its
  own row.
- Compose Multiplatform's real feature backlog lives in YouTrack, which is not
  reachable by the GitHub API; every CMP number here is from GitHub issues that
  JetBrains closed by policy, so CMP is under-represented.
- React Native desktop was checked and found to carry almost no voting signal
  (top open issue: 15 `+1`), so it contributes little.
