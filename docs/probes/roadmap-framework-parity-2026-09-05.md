# GUI framework parity survey

Surveyed 2026-09-05 for kaya's roadmap. Question: what do other GUI frameworks
support that kaya does not, and which of those gaps are table stakes rather than
niche?

**15 framework columns, 70 features.** Columns: SwiftUI (with AppKit/UIKit
backing), Jetpack Compose + Compose Multiplatform, Flutter, Qt 6 (Widgets +
QML), GTK4 + libadwaita, WinUI 3 / Windows App SDK, Avalonia 11, .NET MAUI,
React Native, Electron, Tauri 2, egui, iced, Slint, Uno Platform.

**Verdicts.** `Y` first-party (the framework or a platform SDK it directly
exposes). `P` partial — a named third-party package, only some of the
framework's own targets, a native escape hatch, or a markedly weaker version.
`N` absent; the app builds it. `–` the platform has no such concept. `?` not
established (used rather than guessed).

**kaya's baseline**, from `kaya-surface.md`, for reading the matrix against:
kaya ships tooltip (A14), date/time pickers (A15), slider (A16), tabs (A17,
`sections`), split view (A18, adaptive panes), toolbar (A19, chrome promotion),
context menu (A20), sortable table (A21), virtualized lists (A22), drag and
drop (B14), clipboard (B15), file dialogs (B16), menubar (B17), undo/redo
(B18), adaptive layout (D8). Everything else in the matrix is a gap or partial.

The feature IDs are defined in `CHARGE.md` in this directory and are used
verbatim in every section below.

---

# Part one: framework by framework

## SwiftUI

Apple's declarative UI framework for macOS, iOS/iPadOS, watchOS, tvOS and visionOS; a SwiftUI app freely calls the rest of Apple's SDKs (AppKit/UIKit, UserNotifications, PhotosUI, StoreKit, MapKit, AVKit, WebKit, ...). Doc root: https://developer.apple.com/documentation/swiftui

| ID | Feature | Verdict | Framework's own name for it | Source |
|----|---------|---------|------------------------------|--------|
| A1 | toggle switch | Y | `Toggle` with `.toggleStyle(.switch)` (`.checkbox` is the separate macOS checkbox style) | https://developer.apple.com/documentation/swiftui/controls-and-indicators |
| A2 | segmented control | Y | `Picker` + `.pickerStyle(.segmented)`; also `.palette` | https://developer.apple.com/documentation/swiftui/segmentedpickerstyle |
| A3 | stepper | Y | `Stepper` (macOS + iOS; `buttonRepeatBehavior` for press-and-hold) | https://developer.apple.com/documentation/swiftui/stepper |
| A4 | secure / password entry | Y | `SecureField` | https://developer.apple.com/documentation/swiftui/securefield |
| A5 | formatted / numeric field with validation | Y | `TextField(_:value:format:)` with `FormatStyle` + `ParseStrategy` (iOS 15+/macOS 12+), `.keyboardType(.decimalPad)`, `.textContentType`, `.textInputSuggestions` | https://developer.apple.com/documentation/swiftui/text-input-and-output |
| A6 | search field | Y | `.searchable(text:placement:prompt:)`, `.searchScopes`, `.searchSuggestions`, `.searchCompletion`, `@Environment(\.isSearching)` | https://developer.apple.com/documentation/swiftui/search |
| A7 | colour picker | Y | `ColorPicker` (iOS 14+/macOS 11+) | https://developer.apple.com/documentation/swiftui/colorpicker |
| A8 | tree view / outline | Y | `OutlineGroup`, `DisclosureGroup`, `List(_:children:)`, `DisclosureTableRow` for hierarchical `Table` | https://developer.apple.com/documentation/swiftui/lists |
| A9 | popover | Y | `.popover(isPresented:attachmentAnchor:arrowEdge:content:)`; `.presentationCompactAdaptation(.popover)` to stop iPhone turning it into a sheet | https://developer.apple.com/documentation/swiftui/modal-presentations |
| A10 | sheet / custom-content modal | Y | `.sheet`, `.fullScreenCover` (iOS/tvOS/watchOS only), `.presentationDetents`, `.confirmationDialog`, `.inspector` | https://developer.apple.com/documentation/swiftui/modal-presentations |
| A11 | badge | Y | `.badge(_:)` on `List` rows, `Section`s and `TabView` tabs; `.badgeProminence` | https://developer.apple.com/documentation/swiftui/lists |
| A12 | hyperlink / rich text / markdown | Y | `Link`, `Text` renders Markdown from `LocalizedStringKey`/`AttributedString`, `TextEditor(text: $attributedString)` (iOS 26/macOS 26), `TextRenderer` | https://developer.apple.com/documentation/swiftui/text-input-and-output |
| A13 | indeterminate activity indicator | Y | `ProgressView()` with no value (spinner); `.progressViewStyle(.circular)`. Determinate is `ProgressView(value:total:)`; `Gauge` is separate | https://developer.apple.com/documentation/swiftui/progressview |
| A14 | tooltip | Y | `.help(_:)` — renders a help tag on macOS and visionOS, and sets an accessibility hint on all platforms. iOS/iPadOS get the hint only, no visual tooltip | https://developer.apple.com/documentation/swiftui/view/help(_:) |
| A15 | date / time pickers | Y | `DatePicker` (`.date`, `.hourAndMinute`), `MultiDatePicker`, `.datePickerStyle(.graphical/.wheel/.compact/.field/.stepperField)` | https://developer.apple.com/documentation/swiftui/datepicker |
| A16 | slider | Y | `Slider` (value, range, step, `onEditingChanged`); `Gauge` for read-only | https://developer.apple.com/documentation/swiftui/slider |
| A17 | tabs | Y | `TabView`, `Tab`/`TabSection` (iOS 18+/macOS 15+), `.tabViewStyle(.page/.sidebarAdaptable/.grouped)`, `.tabItem` | https://developer.apple.com/documentation/swiftui/tabview |
| A18 | split view / sidebar-detail | Y | `NavigationSplitView` (2 or 3 columns, `.navigationSplitViewColumnWidth`); macOS also has `HSplitView`/`VSplitView`, plus `.inspector` | https://developer.apple.com/documentation/swiftui/navigationsplitview |
| A19 | toolbar | Y | `.toolbar { ToolbarItem/ToolbarItemGroup/ToolbarSpacer }`, `ToolbarItemPlacement`, `.toolbarRole`, `.windowToolbarStyle`, user customization via `.toolbar(id:)` | https://developer.apple.com/documentation/swiftui/toolbars |
| A20 | context menu | Y | `.contextMenu(menuItems:)`, `.contextMenu(menuItems:preview:)`, `.contextMenu(forSelectionType:menu:primaryAction:)` | https://developer.apple.com/documentation/swiftui/menus-and-commands |
| A21 | table / data grid with column sorting | Y | `Table` + `TableColumn(_:value:)` + `sortOrder:` binding of `[KeyPathComparator]`; `TableColumnCustomization` for reorder/hide. macOS 12+, iPadOS 16+ (iPhone renders the first column only) | https://developer.apple.com/documentation/swiftui/tables |
| A22 | virtualized (recycling) lists | Y | `List` (recycles; UICollectionView/NSTableView backed) and `LazyVStack`/`LazyHStack`/`LazyVGrid`/`LazyHGrid` (lazy creation, no recycling) | https://developer.apple.com/documentation/swiftui/lists |
| A23 | webview | Y | `WebView`/`WebPage` (WebKit, iOS 26/macOS 26+) plus `.webViewScrollPosition` etc.; before 26, `WKWebView` in a `UIViewRepresentable`/`NSViewRepresentable` | https://developer.apple.com/documentation/webkit/webview |
| A24 | video player | Y | `VideoPlayer` (AVKit) | https://developer.apple.com/documentation/avkit/videoplayer |
| A25 | audio playback | Y | AVFoundation `AVAudioPlayer`/`AVPlayer`/`AVAudioEngine` called from a SwiftUI app; no SwiftUI view (AVKit's `VideoPlayer` also plays audio-only assets) | https://developer.apple.com/documentation/avfaudio/avaudioplayer |
| A26 | map | Y | `Map` (MapKit for SwiftUI; new content-builder API iOS 17+/macOS 14+), `Annotation`, `MapPolyline`, `.mapStyle`, `.mapControls`, `Marker` | https://developer.apple.com/documentation/mapkit/map(position:bounds:interactionmodes:scope:content:) |
| B1 | local notifications | Y | UserNotifications: `UNUserNotificationCenter`, `UNMutableNotificationContent`, `UNTimeIntervalNotificationTrigger`. Same framework on macOS and iOS | https://developer.apple.com/documentation/usernotifications |
| B2 | system tray / menu bar extra | Y | `MenuBarExtra` scene + `.menuBarExtraStyle(.menu/.window)` — macOS 13+ only; iOS has no such concept | https://developer.apple.com/documentation/swiftui/scenes |
| B3 | dock / taskbar badge | Y | macOS: `NSApplication.shared.dockTile.badgeLabel` (AppKit). iOS: `UNUserNotificationCenter.setBadgeCount(_:)` (iOS 16+) for the home-screen icon badge | https://developer.apple.com/documentation/appkit/nsdocktile |
| B4 | global hotkeys | P | No SwiftUI or modern AppKit API. macOS route is Carbon `RegisterEventHotKey` (HIToolbox) or `NSEvent.addGlobalMonitorForEvents` (observe-only, needs Accessibility permission). iOS has none — `.keyboardShortcut`/`UIKeyCommand` are in-app only | https://developer.apple.com/documentation/appkit/nsevent/1535472-addglobalmonitorforevents |
| B5 | window styles (utility/panel, always-on-top, transparent) | Y | `UtilityWindow` scene, `.windowLevel(.floating)`/`WindowLevel`, `.windowStyle(.hiddenTitleBar/.plain)`, `.windowBackgroundDragBehavior`, `.containerBackground(.thinMaterial, for: .window)` — macOS (and visionOS); iOS has one window per scene | https://developer.apple.com/documentation/swiftui/windows |
| B6 | fullscreen | Y | macOS: `.windowFullScreenBehavior(_:)`, `WindowToolbarFullScreenVisibility`, `NSWindow.toggleFullScreen`. iOS: `.fullScreenCover`, `.statusBarHidden`, `.persistentSystemOverlays(.hidden)` | https://developer.apple.com/documentation/swiftui/windows |
| B7 | window position/size persistence | Y | macOS scenes persist their frame automatically; `.defaultSize`, `.defaultPosition`, `.windowIdealSize`, `.defaultWindowPlacement`, `.windowResizability`, `NSWindow.setFrameAutosaveName` | https://developer.apple.com/documentation/swiftui/windows |
| B8 | session / state restoration | Y | `@SceneStorage`, `Scene.restorationBehavior(_:)`/`SceneRestorationBehavior`, `NSUserActivity` via `.userActivity`/`.onContinueUserActivity`, `@AppStorage` | https://developer.apple.com/documentation/swiftui/persistent-storage |
| B9 | recent files / security-scoped bookmarks | Y | `DocumentGroup` populates File ▸ Open Recent automatically (`NSDocumentController.noteNewRecentDocumentURL`); `URL.bookmarkData(options: .withSecurityScope)` + `startAccessingSecurityScopedResource()` for sandboxed re-access | https://developer.apple.com/documentation/swiftui/documents |
| B10 | share sheet | Y | `ShareLink`, `SharePreview`; also `.exportableToServices`, `NSSharingServicePicker`/`UIActivityViewController` underneath | https://developer.apple.com/documentation/swiftui/sharelink |
| B11 | URL schemes / deep links / universal links | Y | `.onOpenURL(perform:)`, `@Environment(\.openURL)`, `.handlesExternalEvents`, `.onContinueUserActivity(NSUserActivityTypeBrowsingWeb:)`; declared in Info.plist `CFBundleURLTypes` / Associated Domains | https://developer.apple.com/documentation/swiftui/system-events |
| B12 | file type associations | Y | Info.plist `CFBundleDocumentTypes` + `UTExportedTypeDeclarations`, `UTType`, and `DocumentGroup` with `FileDocument`/`ReferenceFileDocument` | https://developer.apple.com/documentation/swiftui/documents |
| B13 | printing | P | No SwiftUI printing API. Host escape hatch: `NSPrintOperation` (macOS) / `UIPrintInteractionController` (iOS); `ImageRenderer` (iOS 16+/macOS 13+) renders a SwiftUI view into a `CGContext` or PDF to feed them | https://developer.apple.com/documentation/appkit/nsprintoperation |
| B14 | drag and drop | Y | `.draggable(_:)`, `.dropDestination`/`.dropConfiguration`, `.onDrag`/`.onDrop`, `DropDelegate`, `Transferable`, `.dragContainer`, `.reorderContainer`, `.springLoadingBehavior` | https://developer.apple.com/documentation/swiftui/drag-and-drop |
| B15 | clipboard | Y | `.copyable(_:)`, `.cuttable(for:action:)`, `.pasteDestination(for:action:)`, `PasteButton`, `.onCopyCommand`/`.onPasteCommand`; `NSPasteboard`/`UIPasteboard` underneath | https://developer.apple.com/documentation/swiftui/clipboard |
| B16 | file dialogs | Y | `.fileImporter`, `.fileExporter`, `.fileMover`, `FileDialogBrowserOptions`, `.fileDialogDefaultDirectory`; `NSOpenPanel`/`NSSavePanel` underneath | https://developer.apple.com/documentation/swiftui/modal-presentations |
| B17 | menubar (application menu) | Y | `Commands`, `CommandMenu`, `CommandGroup(replacing:)`, `.keyboardShortcut`, built-ins (`SidebarCommands`, `ToolbarCommands`, `TextEditingCommands`, `InspectorCommands`). macOS main menu; iPadOS turns the same declarations into key commands and the iPadOS menu bar | https://developer.apple.com/documentation/swiftui/menus-and-commands |
| B18 | undo/redo integration | Y | `@Environment(\.undoManager)` giving Foundation's `UndoManager`; `CommandGroup(after: .undoRedo)`, `ReferenceFileDocument` registers document undo automatically | https://developer.apple.com/documentation/swiftui/environmentvalues/undomanager |
| B19 | launch at login | Y | macOS 13+: `SMAppService.mainApp.register()` / `.loginItem(identifier:)` (ServiceManagement). No concept on iOS | https://developer.apple.com/documentation/servicemanagement/smappservice |
| B20 | background tasks | Y | `Scene.backgroundTask(_:action:)` with `BackgroundTask.appRefresh/urlSession/...` (iOS 16+/macOS 13+); BackgroundTasks framework (`BGTaskScheduler`) on iOS, `NSBackgroundActivityScheduler`/launchd agents on macOS | https://developer.apple.com/documentation/swiftui/system-events |
| B21 | camera / photo picker | Y | Photo picker is first-party: `PhotosPicker` / `.photosPicker(isPresented:selection:)` (PhotosUI). Live camera capture is P — no SwiftUI view; wrap `UIImagePickerController` or `AVCaptureVideoPreviewLayer` in a `UIViewControllerRepresentable` | https://developer.apple.com/documentation/photokit/photospicker |
| B22 | biometrics / keychain / secure storage | Y | `LocalAuthenticationView` (SwiftUI, iOS 18+), `LAContext.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics)`, Keychain Services (`SecItemAdd`, `kSecAttrAccessibleWhenUnlocked`), `.privacySensitive`/`.redacted` for screen redaction | https://developer.apple.com/documentation/localauthentication |
| B23 | haptics | Y | `.sensoryFeedback(_:trigger:)` + `SensoryFeedback` (iOS 17+/macOS 14+/watchOS 10+); Core Haptics `CHHapticEngine` and `NSHapticFeedbackManager` (macOS trackpad) underneath | https://developer.apple.com/documentation/swiftui/controls-and-indicators |
| C1 | localization / string tables | Y | `LocalizedStringKey`, `LocalizedStringResource`, `Text` auto-localizes literals; Xcode String Catalogs (`.xcstrings`), `Bundle.module`, `.environment(\.locale, _:)` | https://developer.apple.com/documentation/xcode/localization |
| C2 | RTL layout mirroring | Y | `@Environment(\.layoutDirection)` + `LayoutDirection`; leading/trailing alignment and `HStack` mirror automatically; `.layoutDirectionBehavior(_:)`, `.flipsForRightToLeftLayoutDirection(_:)` for images/text | https://developer.apple.com/documentation/swiftui/layout-adjustments |
| C3 | plural rules | Y | String Catalog plural variations (CLDR categories) / legacy `.stringsdict`; automatic grammatical agreement markup `Text("^[\(n) file](inflect: true)")` | https://developer.apple.com/documentation/xcode/localizing-and-varying-text-with-a-string-catalog |
| C4 | date / number formatting | Y | `Text(_:format:)` with Foundation `FormatStyle` (`.number`, `.currency`, `.dateTime`, `.relative`), `Text(_:style:)`, `SystemFormatStyle`, `TimeDataSource`, `@Environment(\.locale/.calendar/.timeZone)` | https://developer.apple.com/documentation/swiftui/text-input-and-output |
| C5 | dynamic type / user font scaling | Y | `@Environment(\.dynamicTypeSize)`, `.dynamicTypeSize(_:)`, `DynamicTypeSize`, `@ScaledMetric`, `.textScale(_:)`, `Font.TextStyle`, `.minimumScaleFactor` | https://developer.apple.com/documentation/swiftui/text-input-and-output |
| C6 | IME and composition (CJK) | Y | Inherited from the platform text system — `TextField`/`TextEditor`/`SecureField` are backed by AppKit/UIKit text input, so marked text and candidate windows work with no app code. SwiftUI exposes no marked-text API of its own; `.typesettingLanguage`, `.textInputDictationBehavior` are the nearest knobs | https://developer.apple.com/documentation/swiftui/text-input-and-output |
| C7 | spellcheck | P | System text views spell-check by default, but SwiftUI ships no API to enable, disable or configure it — only `.autocorrectionDisabled(_:)`. To control it you drop to `NSTextView.isContinuousSpellCheckingEnabled` / `UITextView.spellCheckingType` in a Representable. macOS also gets the standard Edit ▸ Spelling menu via `TextEditingCommands` | https://developer.apple.com/documentation/swiftui/texteditor |
| C8 | reduced-motion / high-contrast honouring | Y | `@Environment(\.accessibilityReduceMotion)`, `.accessibilityReduceTransparency`, `.accessibilityDifferentiateWithoutColor`, `.accessibilityInvertColors`, `.colorSchemeContrast`, `.legibilityWeight`, `.accessibilityDimFlashingLights` | https://developer.apple.com/documentation/swiftui/accessible-appearance |
| D1 | animations / transitions API (explicit) | Y | `withAnimation(_:_:)`, `Animation` (spring/timing curves), `.transition(_:)`, `AnyTransition`, `PhaseAnimator`, `KeyframeAnimator`, `.matchedGeometryEffect`, `.navigationTransition(.zoom)`, `Animatable` | https://developer.apple.com/documentation/swiftui/animations |
| D2 | implicit animation | Y | `.animation(_:value:)` — any change to the observed value animates with no animator; `.contentTransition(_:)` for in-place content changes; `.transaction(_:)` | https://developer.apple.com/documentation/swiftui/animations |
| D3 | scroll-to programmatic | Y | `ScrollViewReader` + `ScrollViewProxy.scrollTo(_:anchor:)`; `.scrollPosition(_:anchor:)` / `.scrollPosition(id:)` with `ScrollPosition` (iOS 18+/macOS 15+); `.defaultScrollAnchor` | https://developer.apple.com/documentation/swiftui/scroll-views |
| D4 | horizontal scroll | Y | `ScrollView(.horizontal)`, `ScrollView([.horizontal, .vertical])`, `LazyHStack`/`LazyHGrid`, `.scrollTargetBehavior(.paging/.viewAligned)`, `.scrollIndicators(_:axes:)` | https://developer.apple.com/documentation/swiftui/scroll-views |
| D5 | pull-to-refresh | Y | `.refreshable(action:)` + `@Environment(\.refresh)`/`RefreshAction`. The pull gesture is the iOS/iPadOS idiom; on macOS the action is installed in the environment but there is no pull gesture | https://developer.apple.com/documentation/swiftui/lists |
| D6 | swipe actions on list rows | Y | `.swipeActions(edge:allowsFullSwipe:content:)` (iOS 15+/macOS 12+); `.onDelete`, `.deleteDisabled`, `EditActions`. Primarily the iOS idiom | https://developer.apple.com/documentation/swiftui/lists |
| D7 | keyboard focus order / tab traversal | Y | `@FocusState` + `.focused(_:)`/`.focused(_:equals:)`, `.focusable(_:interactions:)`, `.focusSection()`, `.focusScope(_:)`, `.defaultFocus(_:_:priority:)`, `.prefersDefaultFocus`, `@Environment(\.resetFocus)`, `.onKeyPress`. No explicit index-based tab order — traversal follows layout order, shaped structurally by `focusSection`/`focusScope` | https://developer.apple.com/documentation/swiftui/focus |
| D8 | adaptive layout | Y | `@Environment(\.horizontalSizeClass/.verticalSizeClass)` + `UserInterfaceSizeClass`, `ViewThatFits`, `.containerRelativeFrame`, `NavigationSplitView` collapse, `AnyLayout`/custom `Layout`, `.presentationCompactAdaptation`, `.tabViewStyle(.sidebarAdaptable)` | https://developer.apple.com/documentation/swiftui/layout-adjustments |
| E1 | hot reload | P | Xcode Previews (`#Preview`, `@Previewable`, `PreviewModifier`) live-update the canvas as you type, but there is no first-party hot reload of a *running* app; for that, third-party `InjectionIII`/`Inject` (John Holdsworth) | https://developer.apple.com/documentation/swiftui/previews-in-xcode |
| E2 | inspector / devtools | Y | Xcode Debug ▸ View Debugging ▸ Capture View Hierarchy (renders SwiftUI view trees and attributes), Instruments' SwiftUI template (View Body / View Properties / Core Animation Commits), `Self._printChanges()`, `.performanceAnalysis` docs | https://developer.apple.com/documentation/swiftui/performance-analysis |
| E3 | testing / UI-driving harness | Y | XCTest UI Testing: `XCUIApplication`, `XCUIElement`, `XCUIElementQuery`, Xcode UI recording; targets are addressed with `.accessibilityIdentifier(_:)`/`.accessibilityLabel(_:)`. Swift Testing + previews for unit-level checks | https://developer.apple.com/documentation/xctest/user-interface-tests |
| E4 | packaging / signing / distribution | Y | Xcode archive + Organizer, automatic code signing, `notarytool` notarization/stapling for direct Mac distribution, App Store Connect + TestFlight, `xcodebuild -exportArchive` | https://developer.apple.com/documentation/xcode/distributing-your-app-for-beta-testing-and-releases |
| E5 | auto-update | P | Automatic only through the App Store / Mac App Store. A directly distributed (notarized, non-store) Mac app has no Apple updater — the ecosystem answer is the third-party `Sparkle` framework | https://sparkle-project.org |

Notes:
- macOS/iOS divergences worth naming: `MenuBarExtra`, `UtilityWindow`, `.windowLevel`, `HSplitView`/`VSplitView`, `SMAppService` login items and the visual half of `.help()` are macOS-only; `.fullScreenCover`, pull-to-refresh's gesture, `PhotosPicker`'s camera-adjacent flows and haptics are the iOS side. `Table` exists on both but renders only its first column at compact width (iPhone).
- The three `P` rows that are real gaps rather than platform-shape differences: global hotkeys (B4 — the only supported registration API is Carbon `RegisterEventHotKey`), printing (B13 — nothing in SwiftUI; `ImageRenderer` + `NSPrintOperation`/`UIPrintInteractionController`), and spellcheck configuration (C7 — behaviour is free, control is not).
- Several rows are only recently first-party: `WebView`/`WebPage` (iOS 26/macOS 26; a `WKWebView` Representable before that), `.sensoryFeedback` (iOS 17+/macOS 14+), `ScrollPosition` (iOS 18+/macOS 15+), `Tab`/`TabSection` (iOS 18+/macOS 15+), `LocalAuthenticationView` (iOS 18+), rich-text `TextEditor(text:selection:)` (iOS 26/macOS 26).
- The Representable escape hatch (`NSViewRepresentable`, `UIViewRepresentable`, `NSViewControllerRepresentable`, `UIViewControllerRepresentable`, `NSHostingView`/`UIHostingController` in the other direction) is first-party and documented, so "not in SwiftUI" is rarely "not reachable" — the P verdicts above mark where you must use it.
- Drag and drop was substantially rebuilt in the 2026 SDKs: `.dropConfiguration`, `DragConfiguration`/`DropSession`, `.dragContainer`/`.dragContainerSelection` for multi-item drags, and `.reorderContainer`/`.reorderDestination` for list reordering, on top of the older `.draggable`/`.dropDestination`/`Transferable`.
- E1 is the weakest row: Xcode Previews is genuinely live but is a canvas, not the running app, and it recompiles rather than patching state.

OFF-LIST (prominent SwiftUI surface the 70 IDs do not name):
- `Gauge` + `.gaugeStyle(.accessoryCircular/.linearCapacity/...)` — a bounded-value readout that is neither a slider nor a progress bar.
- Swift Charts: `Chart` with `BarMark`/`LineMark`/`AreaMark`/`RuleMark`, `.chartXAxis`, `.chartScrollableAxes` — first-party declarative charting.
- `Canvas`/`GraphicsContext` immediate-mode drawing plus Metal shader modifiers `.colorEffect`, `.distortionEffect`, `.layerEffect`, `ShaderLibrary`.
- Liquid Glass as a material vocabulary: `Glass`, `.glassEffect`, `.backgroundExtensionEffect`, `.scrollEdgeEffectStyle`.
- `Transferable` — one conformance simultaneously powers drag and drop, `.copyable`/`.pasteDestination`, and `ShareLink`.
- Composable gesture values: `DragGesture`, `MagnifyGesture`, `RotateGesture`, `.sequenced(before:)`, `.simultaneously(with:)`, `SpatialEventGesture`, `.onKeyPress`.
- SF Symbols as a first-class control vocabulary: `Image(systemName:)`, variable-value symbols, `.symbolEffect(.bounce/.variableColor)`, `.symbolRenderingMode`.
- The same views run outside the app window: WidgetKit widgets and Live Activities, Control Center controls (`ControlWidget`), watch complications — one `View` body, several hosts.

---

## Jetpack Compose + Compose Multiplatform

Kotlin declarative UI. Jetpack Compose (Google) is Android's toolkit and directly exposes the Android SDK; Compose Multiplatform (JetBrains, current 1.12.0, Aug 2026) republishes the same `foundation`/`material3`/`ui` artifacts for iOS, desktop JVM and web/wasm. Docs: https://developer.android.com/develop/ui/compose and https://kotlinlang.org/docs/multiplatform/compose-multiplatform-and-jetpack-compose.html. `Y on Android only` counts as **P**, per the charge.

| ID | Feature | Verdict | Framework's own name for it | Source |
|----|---------|---------|------------------------------|--------|
| A1 | toggle switch | Y | `Switch` (material3, multiplatform) | https://developer.android.com/develop/ui/compose/components |
| A2 | segmented control | Y | `SegmentedButton` + `SingleChoiceSegmentedButtonRow` / `MultiChoiceSegmentedButtonRow` (material3, multiplatform) | https://developer.android.com/develop/ui/compose/components |
| A3 | stepper (+/- incrementer) | P | nothing in material3 for phone/desktop; `Stepper` exists only in Wear Compose (`androidx.wear.compose.material`) | https://developer.android.com/develop/ui/compose/components |
| A4 | secure / password entry | Y | `TextField(visualTransformation = PasswordVisualTransformation(), keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password))` | https://developer.android.com/develop/ui/compose/text |
| A5 | number / formatted field with validation | Y | `KeyboardOptions(keyboardType = KeyboardType.Number)`, `VisualTransformation`, `BasicTextField`'s `InputTransformation`/`OutputTransformation`, `TextField(isError=, supportingText=)` | https://developer.android.com/develop/ui/compose/text |
| A6 | search field | Y | `SearchBar` / `DockedSearchBar` + `SearchBarDefaults` (material3, multiplatform) | https://developer.android.com/develop/ui/compose/components |
| A7 | colour picker | P | nothing first-party; community `colorpicker-compose` (skydoves) — multiplatform | https://github.com/skydoves/colorpicker-compose |
| A8 | tree view / outline | P | nothing in Compose or material3; JetBrains **Jewel** ships `LazyTree`/`BasicLazyTree` but only for Compose for Desktop and it requires the JetBrains Runtime | https://github.com/JetBrains/jewel |
| A9 | popover (anchored transient surface) | Y | `Popup` / `PopupProperties` (foundation, multiplatform), `DropdownMenu`, material3 `RichTooltip` | https://developer.android.com/develop/ui/compose/components |
| A10 | sheet / custom-content modal | Y | `Dialog`, `AlertDialog` / `BasicAlertDialog`, `ModalBottomSheet`, `BottomSheetScaffold` | https://developer.android.com/develop/ui/compose/components |
| A11 | badge | Y | `Badge` / `BadgedBox` (material3) | https://developer.android.com/develop/ui/compose/components |
| A12 | hyperlink / rich text / markdown | Y | `AnnotatedString` + `buildAnnotatedString`, `LinkAnnotation.Url`, `withLink`, `TextLinkStyles`; markdown has no first-party renderer | https://developer.android.com/develop/ui/compose/text/user-interactions |
| A13 | indeterminate activity indicator | Y | `CircularProgressIndicator()` / `LinearProgressIndicator()` with no `progress` argument | https://developer.android.com/develop/ui/compose/components |
| A14 | tooltip | Y | material3 `TooltipBox` + `PlainTooltip` / `RichTooltip` + `rememberTooltipState`; desktop also has `TooltipArea` | https://kotlinlang.org/docs/multiplatform/compose-desktop-components.html |
| A15 | date / time pickers | Y | `DatePicker` / `DatePickerDialog` / `DateRangePicker`, `TimePicker` / `TimeInput` (material3, multiplatform) | https://developer.android.com/develop/ui/compose/components |
| A16 | slider | Y | `Slider`, `RangeSlider` (material3) | https://developer.android.com/develop/ui/compose/components |
| A17 | tabs | Y | `PrimaryTabRow` / `SecondaryTabRow` / `ScrollableTabRow` + `Tab`/`LeadingIconTab` | https://developer.android.com/develop/ui/compose/components |
| A18 | split view / sidebar-detail | Y | `ListDetailPaneScaffold`, `SupportingPaneScaffold`, `NavigationSuiteScaffold` (`androidx.compose.material3.adaptive`; CMP 1.12 ships adaptive 1.3.0-beta02 for all targets) | https://developer.android.com/develop/ui/compose/layouts/adaptive |
| A19 | toolbar | Y | `TopAppBar` / `CenterAlignedTopAppBar` / `MediumTopAppBar` / `LargeTopAppBar` / `BottomAppBar` | https://developer.android.com/develop/ui/compose/components |
| A20 | context menu | Y | desktop: `ContextMenuArea`, `ContextMenuItem`, `ContextMenuDataProvider`, `TextContextMenu`; Android: `DropdownMenu` on long-press plus the built-in text selection toolbar | https://kotlinlang.org/docs/multiplatform/compose-desktop-context-menus.html |
| A21 | table / data grid with column sorting | N | no data grid and no sortable header anywhere in Compose or material3; built by hand from `LazyColumn` + a header `Row` + your own sort state | https://developer.android.com/develop/ui/compose/components |
| A22 | virtualized lists | Y | `LazyColumn` / `LazyRow` / `LazyVerticalGrid` / `LazyVerticalStaggeredGrid` with `key` and `contentType` | https://developer.android.com/develop/ui/compose/lists |
| A23 | webview | P | Android only, and via the host escape hatch: `AndroidView { WebView(it) }`. Nothing in CMP; community `compose-webview-multiplatform` (KevinnZou) | https://github.com/KevinnZou/compose-webview-multiplatform |
| A24 | video player | P | Android only: `androidx.media3:media3-ui-compose` (`PlayerSurface`, `ContentFrame`) and `media3-ui-compose-material3` (`Player`, `MiniController`). Nothing for CMP desktop/iOS/web | https://developer.android.com/media/media3/ui/compose |
| A25 | audio playback | P | Android only: Media3 `ExoPlayer`, `MediaPlayer`. No multiplatform audio API in CMP | https://developer.android.com/media/media3 |
| A26 | map | P | Android only: Google's `maps-compose` (`GoogleMap` composable). The CMP docs list Maps Compose explicitly as Jetpack-only | https://kotlinlang.org/docs/multiplatform/compose-multiplatform-and-jetpack-compose.html |
| B1 | local notifications | P | desktop is first-party (`Notification` + `TrayState.sendNotification`); Android via `NotificationManagerCompat`/`NotificationChannel`; nothing on iOS or web | https://kotlinlang.org/docs/multiplatform/compose-desktop-components.html |
| B2 | system tray / status item | Y | `Tray(icon, state = rememberTrayState(), menu = { Item(...) })` in `ApplicationScope` (desktop; the other targets have no such concept) | https://kotlinlang.org/docs/multiplatform/compose-desktop-components.html |
| B3 | dock / taskbar badge | P | no Compose API; desktop through JVM `java.awt.Taskbar.setIconBadge`; Android's launcher dots come free with a notification channel | https://kotlinlang.org/docs/multiplatform/compose-desktop-components.html |
| B4 | global hotkeys | N | key handling is window-scoped only (`Modifier.onPreviewKeyEvent`, `Window(onKeyEvent =)`); nothing system-wide on any target | https://kotlinlang.org/docs/multiplatform/compose-desktop-keyboard.html |
| B5 | window styles (panel, always-on-top, transparent) | Y | `Window(alwaysOnTop =, undecorated =, transparent =, focusable =, resizable =)`, `DialogWindow(modalityType =)` (desktop) | https://kotlinlang.org/docs/multiplatform/compose-desktop-top-level-windows-management.html |
| B6 | fullscreen | Y | `rememberWindowState(placement = WindowPlacement.Fullscreen)` on desktop; Android immersive via `WindowInsetsControllerCompat` | https://kotlinlang.org/docs/multiplatform/compose-desktop-top-level-windows-management.html |
| B7 | window position / size persistence | N | `WindowState` exposes `position` and `size` live, but nothing persists them across launches — you serialise them yourself | https://kotlinlang.org/docs/multiplatform/compose-desktop-top-level-windows-management.html |
| B8 | session / state restoration | P | Android: `rememberSaveable` + `SavedStateHandle` survive process death. `rememberSaveable` compiles on all CMP targets but nothing writes it to disk on desktop, so a relaunch starts fresh | https://developer.android.com/develop/ui/compose/state-saving |
| B9 | recent files / security-scoped bookmarks | P | Android only: the Storage Access Framework's `takePersistableUriPermission` over a document URI. No desktop or iOS equivalent | https://developer.android.com/training/data-storage/shared/documents-files |
| B10 | share sheet | P | Android only, via the SDK: `Intent.ACTION_SEND` / `ShareCompat.IntentBuilder` / `Intent.createChooser`. Nothing in CMP | https://developer.android.com/training/sharing/send |
| B11 | URL schemes / deep links / universal links | Y | Android manifest intent filters + `navigation-compose` `deepLinks` (navigation is multiplatform); the desktop Gradle plugin writes `CFBundleURLTypes` for macOS | https://kotlinlang.org/docs/multiplatform/compose-native-distribution.html |
| B12 | file type associations | P | Android intent filters do it; the Compose Desktop `nativeDistributions` DSL documents no file-association option, so desktop means hand-passing jpackage arguments or an external packager | https://kotlinlang.org/docs/multiplatform/compose-native-distribution.html |
| B13 | printing | P | no Compose API. Android exposes `PrintManager` / `androidx.print.PrintHelper`; desktop falls back to JVM `java.awt.print` | https://developer.android.com/training/printing |
| B14 | drag and drop | Y | `Modifier.dragAndDropSource` / `Modifier.dragAndDropTarget`, `DragAndDropTransferData`, `DragAndDropEvent` — multiplatform in foundation; on Android `View.DRAG_FLAG_GLOBAL` + `requestDragAndDropPermissions` crosses app boundaries | https://developer.android.com/develop/ui/compose/touch-input/user-interactions/drag-and-drop |
| B15 | clipboard | Y | `LocalClipboard` (suspend `getClipEntry`/`setClipEntry`, multiplatform) and the older `LocalClipboardManager` | https://developer.android.com/develop/ui/compose/text/user-input |
| B16 | file dialogs | P | Android only: `ActivityResultContracts.OpenDocument`/`CreateDocument`/`PickVisualMedia`. CMP desktop has no file dialog — you reach for AWT `FileDialog`/Swing `JFileChooser` or community `FileKit` | https://github.com/vinceglb/FileKit |
| B17 | menubar (application menu) | Y | `MenuBar { Menu("File") { Item("Open", onClick =, shortcut = KeyShortcut(...)) } }` in `FrameWindowScope`, plus `Tray` menus (desktop; native macOS menu bar) | https://kotlinlang.org/docs/multiplatform/compose-desktop-components.html |
| B18 | undo/redo integration | P | text fields only: `TextFieldState.undoState` (`undo()`, `redo()`, `clearHistory()`) in `BasicTextField`. There is no app-level undo manager | https://developer.android.com/develop/ui/compose/text/user-input |
| B19 | launch at login | N | no API on any target; a desktop app writes the launch agent / registry key itself | https://kotlinlang.org/docs/multiplatform/compose-native-distribution.html |
| B20 | background tasks | P | Android only: `androidx.work` `WorkManager` (and `Service`/`AlarmManager`). Nothing multiplatform | https://developer.android.com/topic/libraries/architecture/workmanager |
| B21 | camera / photo picker | P | Android only: CameraX with `androidx.camera:camera-compose` (`CameraXViewfinder`) and the system photo picker via `ActivityResultContracts.PickVisualMedia`. Nothing in CMP | https://developer.android.com/media/camera/camerax/compose |
| B22 | biometrics / keychain / secure storage | P | Android only: `androidx.biometric` `BiometricPrompt`, Android Keystore. Nothing in CMP; on iOS you write Kotlin/Native interop to LocalAuthentication yourself | https://developer.android.com/identity/sign-in/biometric-auth |
| B23 | haptics | Y | `LocalHapticFeedback` + `HapticFeedbackType` (multiplatform API; Android and iOS actually vibrate, desktop is a no-op) | https://developer.android.com/develop/ui/compose/touch-input/haptics |
| C1 | localization / string tables | Y | Android string resources + `stringResource`; CMP `compose.resources` with `stringResource` and locale qualifiers (`values-fr`) | https://kotlinlang.org/docs/multiplatform/compose-multiplatform-resources.html |
| C2 | RTL layout mirroring | Y | `LocalLayoutDirection` / `LayoutDirection.Rtl`, automatic mirroring of `Row`/padding/`start`-`end`, `Modifier.mirror`-free by default; RTL string qualifiers in CMP resources | https://kotlinlang.org/docs/multiplatform/compose-multiplatform-resources.html |
| C3 | plural rules | Y | Android `plurals` XML + `pluralStringResource`; CMP `compose.resources` `pluralStringResource` | https://kotlinlang.org/docs/multiplatform/compose-multiplatform-resources.html |
| C4 | date / number formatting | P | nothing in Compose. Android/desktop JVM get `java.time.format.DateTimeFormatter` and `java.text.NumberFormat`; Kotlin/Native (iOS) and wasm have no localized formatter, so you write `expect`/`actual` over `NSNumberFormatter` | https://kotlinlang.org/docs/multiplatform/compose-multiplatform-and-jetpack-compose.html |
| C5 | dynamic type / user font scaling | Y | `sp` text units scale with the system font size through `LocalDensity.fontScale`; non-linear font scaling honoured on Android 14+ | https://developer.android.com/develop/ui/compose/accessibility/scalable-content |
| C6 | IME and composition | Y | `PlatformTextInputModifierNode` / `TextInputSession`, composition region rendered by `BasicTextField`; CMP implements IME on iOS and desktop too | https://developer.android.com/develop/ui/compose/text/user-input |
| C7 | spellcheck | N | no spell-check API: no misspelling underlines, no suggestion menu. The nearest thing is `KeyboardOptions(autoCorrectEnabled = true)`, which only asks the soft keyboard to autocorrect | https://developer.android.com/develop/ui/compose/text/user-input |
| C8 | reduced-motion / high-contrast honouring | P | no Compose API for either. On Android you read `Settings.Global.ANIMATOR_DURATION_SCALE` and `AccessibilityManager.isHighTextContrastEnabled` yourself; `LocalAccessibilityManager` exposes only recommended timeouts | https://developer.android.com/develop/ui/compose/accessibility |
| D1 | explicit animations / transitions | Y | `Animatable`, `updateTransition` + `Transition`, `AnimatedVisibility`, `AnimatedContent`, `rememberInfiniteTransition`, shared-element transitions | https://developer.android.com/develop/ui/compose/animation/introduction |
| D2 | implicit animation | Y | `animateFloatAsState` / `animateColorAsState` / `animateDpAsState`, `Modifier.animateContentSize`, `Modifier.animateItem` in lazy lists | https://developer.android.com/develop/ui/compose/animation/quick-guide |
| D3 | programmatic scroll-to | Y | `LazyListState.animateScrollToItem` / `scrollToItem`, `ScrollState.animateScrollTo`, `BringIntoViewRequester` | https://developer.android.com/develop/ui/compose/lists |
| D4 | horizontal scroll | Y | `LazyRow`, `Modifier.horizontalScroll(rememberScrollState())`, `HorizontalPager` | https://developer.android.com/develop/ui/compose/lists |
| D5 | pull-to-refresh | Y | material3 `PullToRefreshBox` / `Modifier.pullToRefresh` + `rememberPullToRefreshState` | https://developer.android.com/develop/ui/compose/components |
| D6 | swipe actions on list rows | Y | material3 `SwipeToDismissBox` + `rememberSwipeToDismissBoxState` with start/end backgrounds | https://developer.android.com/develop/ui/compose/components |
| D7 | focus order / tab traversal | Y | `FocusRequester`, `Modifier.focusProperties { next = …; previous = … }`, `Modifier.focusGroup`, `LocalFocusManager.moveFocus`; desktop tab traversal documented separately | https://developer.android.com/develop/ui/compose/touch-input/focus |
| D8 | adaptive layout | Y | `WindowSizeClass` via `currentWindowAdaptiveInfo()` (compact/medium/expanded + `WindowPosture`), `BoxWithConstraints`, the adaptive scaffolds | https://developer.android.com/develop/ui/compose/layouts/adaptive |
| E1 | hot reload | Y | Compose Hot Reload (JetBrains) for desktop JVM — 1.12 adds an MCP server so an agent can drive the running app; Android Studio Live Edit on Android | https://raw.githubusercontent.com/JetBrains/compose-multiplatform/master/CHANGELOG.md |
| E2 | inspector / devtools | P | Android only: Android Studio's Compose-aware Layout Inspector (live hierarchy, recomposition counts). No view-hierarchy inspector for CMP desktop, iOS or web | https://developer.android.com/studio/debug/layout-inspector |
| E3 | testing / UI-driving harness | Y | `createComposeRule()` / `createAndroidComposeRule<A>()`, semantics finders (`onNodeWithText`), actions (`performClick`), assertions (`assertIsDisplayed`); CMP has the same API through `runComposeUiTest` | https://developer.android.com/develop/ui/compose/testing |
| E4 | packaging / signing / distribution | Y | Android Gradle signing + Play; Compose Desktop `nativeDistributions` (dmg/pkg/exe/msi/deb/rpm via jpackage, jlink, ProGuard, macOS signing and notarization, App Store); iOS through the Xcode project | https://kotlinlang.org/docs/multiplatform/compose-native-distribution.html |
| E5 | auto-update | P | nothing first-party — the desktop docs point at Conveyor (Hydraulic, third-party) for online updates; on Android it is Google Play's in-app update library | https://kotlinlang.org/docs/multiplatform/compose-native-distribution.html |

Notes:
- The split is sharp and it falls exactly on the window boundary: everything drawn inside the window is multiplatform, everything touching the OS is Android-only. 15 of the 23 B rows are P for that one reason — the CMP artifact set is `ui`/`foundation`/`material3`/`animation` plus navigation, lifecycle and viewmodel, and nothing else.
- Compose Desktop is the exception and is genuinely first-party for window chrome: `Tray` + notifications, `MenuBar`, context menus, scrollbars, tooltips, always-on-top/transparent/undecorated windows, `WindowPlacement.Fullscreen`. There is no file dialog in that set, which is the conspicuous hole.
- No data grid anywhere in Compose or material3 — no sortable header, no column resize, no column reorder. `LazyColumn` plus a hand-written header `Row` is the state of the art.
- material3 tracks the Material spec, so a control Material does not specify is not in Compose: no colour picker, no tree, no stepper outside Wear Compose.
- Version caveat: CMP 1.12.0 (Aug 2026) ships material3-adaptive 1.3.0-beta02, so the adaptive scaffolds are beta on the non-Android targets. Compose Hot Reload is desktop-JVM only. I could not confirm from the reference pages whether a user-draggable pane splitter (`PaneExpansionState`) is exposed — the scaffolds themselves definitely are.
- Cross-app drag really works on Android (`View.DRAG_FLAG_GLOBAL` + `requestDragAndDropPermissions`) through the same multiplatform modifiers, making B14 one of the few OS-integration rows that is not Android-shaped.

OFF-LIST (prominent in Compose, not among the 70 IDs):
- `Modifier` chains as the entire layout/decoration vocabulary — `padding`, `background`, `clip`, `border`, `graphicsLayer`, `pointerInput` — composed onto any composable.
- The snapshot state system itself: `remember`, `mutableStateOf`, `derivedStateOf`, `snapshotFlow`, automatic recomposition.
- Shared-element transitions between screens: `SharedTransitionLayout`, `Modifier.sharedElement`.
- Foldable and posture awareness: `WindowPosture`, hinge location, `currentWindowAdaptiveInfo()`.
- Predictive back: `PredictiveBackHandler` renders the system back gesture's preview.
- Alternate form-factor component sets: `androidx.wear.compose`, `androidx.tv.material3`.
- `@Preview` — composables rendered in the IDE (and the Compose Preview screenshot tests) without running the app.
- Two-way host interop: `AndroidView`/`ComposeView`, `UIKitView`/`ComposeUIViewController`, `SwingPanel`/`ComposePanel`.


---

## Flutter

Google's Dart UI toolkit that renders its own widgets (Impeller/Skia) on Android, iOS, macOS, Windows, Linux and web; current stable 3.47 (2026-08-12). Docs: https://docs.flutter.dev/ui/widgets and https://api.flutter.dev. Counted as `Y`: the SDK plus packages whose pub.dev publisher is flutter.dev or dart.dev; a community package is `P` with the package named.

| ID | Feature | Verdict | Framework's own name for it | Source |
|----|---------|---------|------------------------------|--------|
| A1 | toggle switch | Y | `Switch`, `SwitchListTile`, `CupertinoSwitch` | https://api.flutter.dev/flutter/material/Switch-class.html |
| A2 | segmented control | Y | `SegmentedButton` (M3), `CupertinoSlidingSegmentedControl` | https://api.flutter.dev/flutter/material/SegmentedButton-class.html |
| A3 | stepper (+/- incrementer) | N | none — `Stepper` is a step-by-step wizard, not a numeric incrementer; no Cupertino stepper either | https://api.flutter.dev/flutter/material/Stepper-class.html |
| A4 | secure / password entry | Y | `TextField(obscureText: true, obscuringCharacter:)` | https://api.flutter.dev/flutter/material/TextField/obscureText.html |
| A5 | number / formatted field with validation | Y | `TextInputFormatter` (`FilteringTextInputFormatter`, `LengthLimitingTextInputFormatter`), `TextInputType.number`, `Form` + `TextFormField.validator` | https://api.flutter.dev/flutter/services/TextInputFormatter-class.html |
| A6 | search field | Y | `SearchBar` / `SearchAnchor` (M3), `CupertinoSearchTextField` | https://api.flutter.dev/flutter/material/SearchAnchor-class.html |
| A7 | colour picker | P | no first-party widget; community `flutter_colorpicker` (publisher mchome) | https://pub.dev/packages/flutter_colorpicker |
| A8 | tree view / outline | Y | `TreeSliver` / `TreeSliverNode` / `TreeSliverController` in `widgets`; 2-D `TreeView` in `two_dimensional_scrollables` (flutter.dev) | https://api.flutter.dev/flutter/widgets/TreeSliver-class.html |
| A9 | popover (anchored transient surface) | Y | `MenuAnchor` / `RawMenuAnchor`, `OverlayPortal`, `PopupMenuButton` | https://api.flutter.dev/flutter/material/MenuAnchor-class.html |
| A10 | sheet / custom-content modal | Y | `showDialog` + `Dialog`, `showModalBottomSheet`, `DraggableScrollableSheet`, `CupertinoActionSheet` | https://api.flutter.dev/flutter/material/showDialog.html |
| A11 | badge | Y | `Badge` / `Badge.count` (M3) | https://api.flutter.dev/flutter/material/Badge-class.html |
| A12 | hyperlink / rich text / markdown | Y | `Text.rich` + `TextSpan` + `TapGestureRecognizer`, `WidgetSpan`, `SelectableText.rich`; links opened with `url_launcher` (flutter.dev). Markdown is the weak half — flutter.dev's `flutter_markdown` is discontinued | https://api.flutter.dev/flutter/widgets/Text/Text.rich.html |
| A13 | indeterminate activity indicator | Y | `CircularProgressIndicator(value: null)`, `CupertinoActivityIndicator` | https://api.flutter.dev/flutter/cupertino/CupertinoActivityIndicator-class.html |
| A14 | tooltip | Y | `Tooltip`, `TooltipTheme`, `tooltip:` on most controls | https://api.flutter.dev/flutter/material/Tooltip-class.html |
| A15 | date / time pickers | Y | `showDatePicker`, `showDateRangePicker`, `showTimePicker`, `CupertinoDatePicker`, `CupertinoTimerPicker` | https://api.flutter.dev/flutter/material/showDatePicker.html |
| A16 | slider | Y | `Slider`, `RangeSlider`, `CupertinoSlider` | https://api.flutter.dev/flutter/material/Slider-class.html |
| A17 | tabs | Y | `TabBar` / `TabBarView` / `DefaultTabController`, `CupertinoTabScaffold` | https://api.flutter.dev/flutter/material/TabBar-class.html |
| A18 | split view / resizable panes | P | no first-party splitter or list-detail scaffold; flutter.dev's `flutter_adaptive_scaffold` is DISCONTINUED; community `multi_split_view`, `resizable_widget` | https://pub.dev/packages/flutter_adaptive_scaffold |
| A19 | toolbar | Y | `AppBar` / `SliverAppBar` / `BottomAppBar`, `CupertinoNavigationBar` | https://api.flutter.dev/flutter/material/AppBar-class.html |
| A20 | context menu | Y | `ContextMenuController`, `contextMenuBuilder`, `AdaptiveTextSelectionToolbar`, `MenuAnchor` right-click | https://api.flutter.dev/flutter/widgets/ContextMenuController-class.html |
| A21 | table / data grid with column sorting | Y | `DataTable` + `DataColumn.onSort` + `sortColumnIndex`/`sortAscending`, `PaginatedDataTable`, `DataTableSource` | https://api.flutter.dev/flutter/material/DataTable-class.html |
| A22 | virtualized lists | Y | `ListView.builder` / `SliverList` / `SliverChildBuilderDelegate` (lazy build + cacheExtent) | https://api.flutter.dev/flutter/widgets/ListView-class.html |
| A23 | webview | Y | `webview_flutter` + `WebViewWidget`/`WebViewController` (flutter.dev) | https://pub.dev/packages/webview_flutter |
| A24 | video player | Y | `video_player` + `VideoPlayerController` (flutter.dev; Android/iOS/macOS/web) | https://pub.dev/packages/video_player |
| A25 | audio playback | P | no flutter.dev audio package; `video_player` will play an audio-only stream; community `just_audio`, `audioplayers` | https://pub.dev/packages/just_audio |
| A26 | map | Y | `google_maps_flutter` + `GoogleMap` (flutter.dev; Android/iOS/web) | https://pub.dev/packages/google_maps_flutter |
| B1 | local notifications | P | none first-party; community `flutter_local_notifications` (dexterous.com.au) | https://pub.dev/packages/flutter_local_notifications |
| B2 | system tray / status item | P | none first-party; community `tray_manager`, `system_tray` | https://pub.dev/packages/tray_manager |
| B3 | dock / taskbar badge | P | none first-party; community `app_badge_plus`, `flutter_app_badger` | https://pub.dev/packages/app_badge_plus |
| B4 | global hotkeys | P | none first-party (`Shortcuts`/`HardwareKeyboard` are in-app only); community `hotkey_manager` | https://pub.dev/packages/hotkey_manager |
| B5 | window styles (panel, always-on-top, transparent) | P | none first-party; community `window_manager` (`setAlwaysOnTop`, `setAsFrameless`, transparent), `bitsdojo_window` | https://pub.dev/packages/window_manager |
| B6 | fullscreen | P | mobile immersive is first-party (`SystemChrome.setEnabledSystemUIMode`); desktop window fullscreen needs `window_manager` | https://api.flutter.dev/flutter/services/SystemChrome/setEnabledSystemUIMode.html |
| B7 | window position / size persistence | P | community `window_manager` + `shared_preferences` (flutter.dev) written by hand; nothing automatic | https://pub.dev/packages/window_manager |
| B8 | session / state restoration | Y | `RestorationMixin`, `RestorableProperty`, `restorationScopeId`, `RestorationBucket` (Android + iOS) | https://api.flutter.dev/flutter/widgets/RestorationMixin-mixin.html |
| B9 | recent files / security-scoped bookmarks | P | `file_selector` hands back an `XFile` path with no bookmark; macOS sandbox bookmarks via community `macos_secure_bookmarks` | https://pub.dev/packages/macos_secure_bookmarks |
| B10 | share sheet | P | none first-party; community `share_plus` (fluttercommunity.dev) | https://pub.dev/packages/share_plus |
| B11 | URL schemes / deep links / universal links | Y | first-party deep linking into the `Router` API, `go_router` (flutter.dev); outgoing via `url_launcher` (flutter.dev) | https://docs.flutter.dev/ui/navigation/deep-linking |
| B12 | file type associations | N | no Flutter API; hand-edited `AndroidManifest.xml` / `Info.plist` / Windows registry per platform | https://docs.flutter.dev/deployment |
| B13 | printing | P | none first-party; community `printing` + `pdf` (David PHAM-VAN) | https://pub.dev/packages/printing |
| B14 | drag and drop | P | in-app is first-party and complete (`Draggable`, `DragTarget`, `LongPressDraggable`, `ReorderableListView`); cross-app OS drag needs community `super_drag_and_drop` / `desktop_drop` | https://api.flutter.dev/flutter/widgets/Draggable-class.html |
| B15 | clipboard | Y | `Clipboard.setData` / `getData` — plain text only; images and file lists need community `super_clipboard` | https://api.flutter.dev/flutter/services/Clipboard-class.html |
| B16 | file dialogs | Y | `file_selector` (flutter.dev): `openFile`, `openFiles`, `getSaveLocation`, `getDirectoryPath` | https://pub.dev/packages/file_selector |
| B17 | menubar (application menu) | Y | `PlatformMenuBar` + `PlatformMenu`/`PlatformMenuItem` (native macOS menu bar); `MenuBar` for an in-app bar | https://api.flutter.dev/flutter/widgets/PlatformMenuBar-class.html |
| B18 | undo/redo integration | Y | `UndoHistory` / `UndoHistoryController`, `UndoManager` (services) wired to the iOS/macOS system undo | https://api.flutter.dev/flutter/widgets/UndoHistory-class.html |
| B19 | launch at login | P | none first-party; community `launch_at_startup` | https://pub.dev/packages/launch_at_startup |
| B20 | background tasks | P | none first-party; community `workmanager` (Android WorkManager + iOS BGTaskScheduler), `flutter_background_service` | https://pub.dev/packages/workmanager |
| B21 | camera / photo picker | Y | `camera` (`CameraController`, `CameraPreview`) and `image_picker`, both flutter.dev | https://pub.dev/packages/camera |
| B22 | biometrics / keychain / secure storage | P | biometrics first-party: `local_auth` (flutter.dev); keychain/keystore storage is community `flutter_secure_storage` — `shared_preferences` is not secure | https://pub.dev/packages/local_auth |
| B23 | haptics | Y | `HapticFeedback.lightImpact/mediumImpact/heavyImpact/selectionClick/vibrate` | https://api.flutter.dev/flutter/services/HapticFeedback-class.html |
| C1 | localization / string tables | Y | `flutter_localizations` + `gen-l10n` over ARB files, `AppLocalizations`, `MaterialApp.localizationsDelegates` | https://docs.flutter.dev/ui/accessibility-and-internationalization/internationalization |
| C2 | RTL layout mirroring | Y | `Directionality`, `TextDirection`, `EdgeInsetsDirectional`, `AlignmentDirectional`, automatic mirroring of Material widgets | https://docs.flutter.dev/ui/accessibility-and-internationalization/internationalization |
| C3 | plural rules | Y | ICU plural syntax in ARB (`{count, plural, ...}`) via gen-l10n; `Intl.plural` in `intl` (dart.dev) | https://pub.dev/packages/intl |
| C4 | date / number formatting | Y | `DateFormat`, `NumberFormat`, `Intl.defaultLocale` in `intl` (dart.dev) | https://pub.dev/packages/intl |
| C5 | dynamic type / font scaling | Y | `TextScaler`, `MediaQuery.textScalerOf`, `MediaQuery.withNoTextScaling` | https://api.flutter.dev/flutter/painting/TextScaler-class.html |
| C6 | IME and composition | Y | `TextEditingValue.composing`, `TextInputConnection`, `TextInputClient`, composing underline | https://api.flutter.dev/flutter/services/TextEditingValue/composing.html |
| C7 | spellcheck | P | `SpellCheckConfiguration` + `DefaultSpellCheckService` — Android and iOS only; no desktop or web spell check | https://api.flutter.dev/flutter/widgets/SpellCheckConfiguration-class.html |
| C8 | reduced motion / high contrast | Y | `MediaQuery.disableAnimationsOf`, `highContrastOf`, `boldTextOf`, `accessibleNavigationOf` | https://api.flutter.dev/flutter/widgets/MediaQueryData/disableAnimations.html |
| D1 | explicit animations / transitions | Y | `AnimationController`, `Tween`, `AnimatedBuilder`, `*Transition` widgets; `animations` package (flutter.dev) for shared-axis/container transforms | https://docs.flutter.dev/ui/animations |
| D2 | implicit animation | Y | `AnimatedContainer`, `AnimatedOpacity`, all `ImplicitlyAnimatedWidget`s, `TweenAnimationBuilder` | https://api.flutter.dev/flutter/widgets/AnimatedContainer-class.html |
| D3 | programmatic scroll-to | Y | `ScrollController.animateTo/jumpTo`, `Scrollable.ensureVisible`, `showOnScreen` | https://api.flutter.dev/flutter/widgets/ScrollController-class.html |
| D4 | horizontal scroll | Y | `scrollDirection: Axis.horizontal` on every scrollable; `PageView`, `SingleChildScrollView` | https://api.flutter.dev/flutter/widgets/ListView-class.html |
| D5 | pull-to-refresh | Y | `RefreshIndicator`, `CupertinoSliverRefreshControl` | https://api.flutter.dev/flutter/material/RefreshIndicator-class.html |
| D6 | swipe actions on rows | P | `Dismissible` is first-party but is swipe-to-dismiss with a background, not revealed action buttons; community `flutter_slidable` for those | https://pub.dev/packages/flutter_slidable |
| D7 | focus order / tab traversal | Y | `FocusTraversalGroup`, `OrderedTraversalPolicy`, `FocusTraversalOrder`, `FocusNode.nextFocus` | https://api.flutter.dev/flutter/widgets/FocusTraversalGroup-class.html |
| D8 | adaptive layout | Y | `LayoutBuilder`, `MediaQuery.sizeOf`, `OrientationBuilder`, `SafeArea`; guidance in the adaptive-design docs (note: the `Breakpoint` API shipped in the now-discontinued `flutter_adaptive_scaffold`) | https://docs.flutter.dev/ui/adaptive-responsive |
| E1 | hot reload | Y | `r` hot reload / `R` hot restart in `flutter run`; stateful hot reload in IDEs; Widget Previewer (stable in 3.47) | https://docs.flutter.dev/tools/hot-reload |
| E2 | inspector / devtools | Y | Flutter DevTools Widget Inspector, layout explorer, timeline, memory | https://docs.flutter.dev/tools/devtools/inspector |
| E3 | testing / UI-driving harness | Y | `flutter_test` + `WidgetTester`/finders/golden files; `integration_test` on device; `flutter drive` | https://docs.flutter.dev/testing/overview |
| E4 | packaging / signing / distribution | Y | per-target build+sign docs for Android, iOS, macOS, Windows, Linux and web (`flutter build appbundle/ipa/macos/...`) | https://docs.flutter.dev/deployment |
| E5 | auto-update | P | nothing first-party; desktop via community `auto_updater` (Sparkle/WinSparkle); Android in-app updates via the Play library; Shorebird for Dart code push | https://pub.dev/packages/auto_updater |

Notes:
- Flutter draws its own widgets, so the A section is nearly all Y and none of it depends on the host toolkit — but it also means Material and Cupertino are two parallel widget sets you pick between (`Switch` vs `CupertinoSwitch`, and so on across roughly forty controls), plus `.adaptive` constructors that choose for you.
- Google's package portfolio is the dividing line, and it has been shrinking: `flutter_markdown` and `flutter_adaptive_scaffold` are both flutter.dev-published and both now marked discontinued, which is what moves A12's markdown half and A18 off `Y`.
- Desktop system integration is essentially all community: window management, tray, printing, local notifications, global hotkeys, launch-at-login, auto-update. Those packages are widely used and well maintained, but none is Google's, so every one of them is P here.
- `Clipboard` is plain text only — images and file lists need community `super_clipboard`. Drag and drop is complete in-app (`Draggable`/`DragTarget`/`ReorderableListView`) but does not cross the app boundary without `super_drag_and_drop`.
- Check the pub.dev publisher, not the naming style: the `_plus` family (`share_plus`, `package_info_plus`) is fluttercommunity.dev, not flutter.dev.
- Current stable is Flutter 3.47 (2026-08-12); the Widget Previewer graduated to stable in it. `Stepper` is a name collision — it is a step-by-step wizard, not a numeric incrementer, and no numeric incrementer exists.

OFF-LIST (prominent in Flutter, not among the 70 IDs):
- Two complete design systems in the box, Material (`material_ui`) and Cupertino (`cupertino_ui`), with `Theme`/`CupertinoTheme` and `.adaptive` constructors that switch per platform.
- Golden-file (screenshot) testing built into `flutter_test`: `matchesGoldenFile`.
- `CustomPaint`/`Canvas`, GLSL fragment shaders (`FragmentProgram`), and the Impeller renderer.
- `Hero` — shared-element animation across route transitions, first-party and one widget wide.
- `InteractiveViewer` — pinch-zoom, pan and scale container for any child.
- `rfw` (Remote Flutter Widgets, flutter.dev): render declarative widget descriptions fetched at runtime.
- `pigeon` (flutter.dev): typed code generation for host-platform channels; `dart:ffi` for direct C interop.
- Web and WebAssembly as first-class targets running the same widget code.

---

## Qt 6 (Qt Widgets + Qt Quick / QML)

C++ framework with two UI tiers — Qt Widgets (retained C++ widgets, desktop-only) and Qt Quick / QML (declarative, GPU scene graph, desktop + Android + iOS + embedded). Targets Windows, macOS, Linux (X11 + Wayland), Android, iOS, WebAssembly, embedded/RTOS. Doc root: https://doc.qt.io/qt-6/ (checked against the 6.11 docs).

Every row says which tier has it. "Widgets" = Qt Widgets C++ class; "Quick" = a QML type from Qt Quick / Qt Quick Controls.

| ID | Feature | Verdict | Framework's own name for it | Source |
|----|---------|---------|------------------------------|--------|
| A1 | toggle switch | Y | `Switch`, `SwitchDelegate` (Quick Controls). Widgets have **no** switch — `QCheckBox` only | https://doc.qt.io/qt-6/qtquickcontrols-index.html |
| A2 | segmented control | P | No dedicated control in either tier. Built from `TabBar`+`TabButton` or a `ButtonGroup` of `Button`s (Quick) / `QButtonGroup` of `QToolButton`s (Widgets) | https://doc.qt.io/qt-6/qtquickcontrols-index.html , https://doc.qt.io/qt-6/qtwidgets-module.html |
| A3 | stepper (+/- incrementer) | Y | `QSpinBox`, `QDoubleSpinBox` (Widgets); `SpinBox`, `DoubleSpinBox` (Quick) | https://doc.qt.io/qt-6/qtwidgets-module.html |
| A4 | secure / password entry | Y | `QLineEdit::EchoMode::Password` (Widgets); `TextField.echoMode: TextInput.Password` (Quick) | https://doc.qt.io/qt-6/qlineedit.html |
| A5 | number / formatted field with validation | Y | `QValidator` family (`QIntValidator`, `QDoubleValidator`, `QRegularExpressionValidator`), `QLineEdit::inputMask`; QML `IntValidator`/`DoubleValidator`/`RegularExpressionValidator`, `TextInput.inputMask` | https://doc.qt.io/qt-6/qvalidator.html |
| A6 | search field | Y | `SearchField` (Quick Controls, **new in Qt 6.10**). Widgets: `QLineEdit::setClearButtonEnabled` + `QCompleter`, no dedicated class | https://doc.qt.io/qt-6/qml-qtquick-controls-searchfield.html |
| A7 | colour picker | Y | `QColorDialog` (Widgets); `ColorDialog` (Qt Quick Dialogs) | https://doc.qt.io/qt-6/qcolordialog.html |
| A8 | tree view / outline | Y | `QTreeView`, `QTreeWidget` (Widgets); `TreeView` + `TreeViewDelegate` (Quick, 6.3+) | https://doc.qt.io/qt-6/qtreeview.html |
| A9 | popover | Y | `Popup` (Quick Controls, anchored via `popup.open()`/`ToolTip`); Widgets: `Qt::Popup` window flag, `QMenu` | https://doc.qt.io/qt-6/qtquickcontrols-index.html |
| A10 | sheet / modal dialog | Y | `QDialog`, `QMessageBox`, `QWizard` (Widgets); `Dialog`, `Drawer` (Quick Controls) | https://doc.qt.io/qt-6/qdialog.html |
| A11 | badge (count/dot) | N | No `Badge` type in Qt Quick Controls and no Widgets class; app draws it | https://doc.qt.io/qt-6/qtquickcontrols-index.html |
| A12 | hyperlink / rich text / markdown | Y | `QLabel` rich text + `linkActivated`, `QTextDocument::setMarkdown()`, `QTextBrowser`; QML `Text.textFormat: Text.MarkdownText`/`Text.RichText`, `linkActivated` | https://doc.qt.io/qt-6/qtextdocument.html#setMarkdown |
| A13 | activity indicator | Y | `BusyIndicator` (Quick); `QProgressBar` with min==max==0 (Widgets) | https://doc.qt.io/qt-6/qtquickcontrols-index.html |
| A14 | tooltip | Y | `QToolTip`, `QWidget::setToolTip`; `ToolTip` (Quick, also attached `ToolTip.text`) | https://doc.qt.io/qt-6/qtooltip.html |
| A15 | date / time pickers | Y | `QDateTimeEdit`, `QDateEdit`, `QTimeEdit`, `QCalendarWidget` (Widgets); `MonthGrid`, `DayOfWeekRow`, `WeekNumberColumn`, `Tumbler` (Quick) | https://doc.qt.io/qt-6/qml-qtquick-controls-monthgrid.html |
| A16 | slider | Y | `QSlider`, `QDial` (Widgets); `Slider`, `RangeSlider`, `Dial` (Quick) | https://doc.qt.io/qt-6/qtquickcontrols-index.html |
| A17 | tabs | Y | `QTabWidget`, `QTabBar` (Widgets); `TabBar`+`TabButton`+`StackLayout`, `SwipeView` (Quick) | https://doc.qt.io/qt-6/qtabwidget.html |
| A18 | split view | Y | `QSplitter` (Widgets); `SplitView` (Quick, 6.0+) | https://doc.qt.io/qt-6/qsplitter.html |
| A19 | toolbar | Y | `QToolBar` (dockable, `QMainWindow`); `ToolBar`+`ToolButton` (Quick) | https://doc.qt.io/qt-6/qtoolbar.html |
| A20 | context menu | Y | `QWidget::setContextMenuPolicy` + `QMenu`; `ContextMenu` attached type + `Menu` (Quick) | https://doc.qt.io/qt-6/qtquickcontrols-index.html |
| A21 | table / data grid with column sorting | Y | `QTableView` + `QHeaderView` sort indicator + `QSortFilterProxyModel` (Widgets); `TableView` + `HorizontalHeaderView` (Quick — sorting is manual there) | https://doc.qt.io/qt-6/qsortfilterproxymodel.html |
| A22 | virtualized (recycling) lists | Y | Model/view `QListView`/`QTableView`/`QTreeView` create delegates on demand; QML `ListView`/`TableView` with `reuseItems: true` | https://doc.qt.io/qt-6/qml-qtquick-tableview.html |
| A23 | webview | Y | **Qt WebEngine** (Chromium; desktop only, LGPLv3/GPLv3/commercial, not on iOS/Android) and **Qt WebView** (wraps the OS web view on Android/iOS/macOS/Windows) | https://doc.qt.io/qt-6/qtmodules.html |
| A24 | video player | Y | Qt Multimedia `QMediaPlayer` + `QVideoWidget`; QML `MediaPlayer` + `VideoOutput` | https://doc.qt.io/qt-6/qtmultimedia-index.html |
| A25 | audio playback | Y | `QMediaPlayer`+`QAudioOutput`, `QSoundEffect`, `QAudioSink`; Qt Spatial Audio add-on | https://doc.qt.io/qt-6/qtmultimedia-index.html |
| A26 | map | Y | Qt Location `MapView`/`Map` + Qt Positioning. **Technology Preview** in 6.11 and only the OpenStreetMap plugin ships | https://doc.qt.io/qt-6/qtlocation-index.html |
| B1 | local notifications | P | No notification module in Qt 6. Only first-party path is `QSystemTrayIcon::showMessage()` balloons (desktop, needs a tray). Third-party: KNotifications, snorenotify | https://doc.qt.io/qt-6/qsystemtrayicon.html , https://doc.qt.io/qt-6/qtmodules.html |
| B2 | system tray / status item | Y | `QSystemTrayIcon` (Windows, macOS, and Linux DEs with D-Bus StatusNotifierItem or XEmbed); `SystemTrayIcon` in Qt.labs.platform | https://doc.qt.io/qt-6/qsystemtrayicon.html |
| B3 | dock / taskbar badge | N | `QWinTaskbarButton` (Qt Windows Extras) and Qt Mac Extras were **removed in Qt 6** with no replacement | https://doc.qt.io/qt-6/qtmodules.html |
| B4 | global hotkeys | P | No Qt module. Third-party `QHotkey` (Skycoder42) wraps X11/Win32/Carbon; nothing works under Wayland without the portal | https://doc.qt.io/qt-6/qtmodules.html |
| B5 | window styles (utility/always-on-top/transparent) | P | `Qt::Tool`, `Qt::WindowStaysOnTopHint`, `Qt::FramelessWindowHint`, `Qt::WA_TranslucentBackground`. Stays-on-top and window type hints are ignored under Wayland; no blur API anywhere | https://doc.qt.io/qt-6/qt.html#WindowType-enum |
| B6 | fullscreen | Y | `QWidget::showFullScreen()`; `Window.visibility: Window.FullScreen` | https://doc.qt.io/qt-6/qwidget.html#showFullScreen |
| B7 | window position/size persistence | P | `QWidget::saveGeometry()`/`restoreGeometry()` + `QSettings` — Widgets only, and the app owns the storage. No QML equivalent | https://doc.qt.io/qt-6/qwidget.html#saveGeometry |
| B8 | session / state restoration | P | `QSessionManager` (X11 XSMP + Windows session mgmt only), `QMainWindow::saveState()`/`restoreState()` for dock/toolbar layout. No macOS NSWindow restoration, nothing on Wayland | https://doc.qt.io/qt-6/qsessionmanager.html |
| B9 | recent files / security-scoped bookmarks | N | No API. Qt ships a "Recent Files" *example* you copy into your app; no macOS security-scoped bookmark support | https://doc.qt.io/qt-6/qtwidgets-mainwindows-recentfiles-example.html |
| B10 | share sheet | N | No share API in any Qt 6 module | https://doc.qt.io/qt-6/qtmodules.html |
| B11 | URL schemes / deep links | Y | `QDesktopServices::setUrlHandler()`, with documented `CFBundleURLSchemes`/Universal Links (Apple) and intent-filter/`assetlinks.json` (Android) registration | https://doc.qt.io/qt-6/qdesktopservices.html |
| B12 | file type associations | P | No runtime API. Qt Installer Framework's `RegisterFileType` operation does it at install time (Windows-centric) | https://doc.qt.io/qtinstallerframework/scripting.html |
| B13 | printing | Y | Qt Print Support: `QPrinter`, `QPrintDialog`, `QPrintPreviewDialog`, `QPageSetupDialog`. **C++/Widgets only** — no QML printing API | https://doc.qt.io/qt-6/qtprintsupport-index.html |
| B14 | drag and drop | Y | `QDrag`+`QMimeData`, `dragEnterEvent`/`dropEvent` (Widgets); `Drag` attached property, `DropArea`, `DragHandler` (Quick) | https://doc.qt.io/qt-6/dnd.html |
| B15 | clipboard | Y | `QClipboard` (`QGuiApplication::clipboard()`) with `QMimeData`. No QML clipboard type — TextEdit's cut/copy/paste, or expose `QClipboard` yourself | https://doc.qt.io/qt-6/qclipboard.html |
| B16 | file dialogs | Y | `QFileDialog` (Widgets); `FileDialog`/`FolderDialog` in Qt Quick Dialogs; native variants in Qt.labs.platform | https://doc.qt.io/qt-6/qfiledialog.html |
| B17 | menubar (application menu) | Y | `QMenuBar` (native macOS menu bar automatically); `MenuBar` (Quick Controls) and native `MenuBar` in Qt.labs.platform | https://doc.qt.io/qt-6/qmenubar.html |
| B18 | undo/redo integration | Y | `QUndoStack`, `QUndoCommand`, `QUndoGroup`, `QUndoView`. No QML API | https://doc.qt.io/qt-6/qundostack.html |
| B19 | launch at login | N | No Qt API on any platform | https://doc.qt.io/qt-6/qtmodules.html |
| B20 | background tasks | N | Qt Concurrent / `QThreadPool` are in-process threading, not OS-scheduled background work. No API for iOS BGTaskScheduler, Android WorkManager, launchd, etc. | https://doc.qt.io/qt-6/qtconcurrent-index.html |
| B21 | camera / photo picker | P | Camera is Y: Qt Multimedia `QCamera`, `QImageCapture`, QML `CaptureSession`. **No photo-library picker** — no `PHPickerViewController`/Android photo-picker binding | https://doc.qt.io/qt-6/qtmultimedia-index.html |
| B22 | biometrics / keychain / secure storage | P | Nothing in Qt. Third-party `QtKeychain` (frankosterfeld) wraps Keychain / Credential Store / libsecret. No biometric prompt API at all | https://doc.qt.io/qt-6/qtmodules.html |
| B23 | haptics | N | No haptics or vibration module in Qt 6 (Qt Feedback was a Qt Mobility / Qt 5 thing and did not come across) | https://doc.qt.io/qt-6/qtmodules.html |
| C1 | localization / string tables | Y | `tr()` / `qsTr()`, `QTranslator`, `.ts`/`.qm`, Qt Linguist + `lupdate`/`lrelease` | https://doc.qt.io/qt-6/internationalization.html |
| C2 | RTL layout mirroring | Y | `QGuiApplication::layoutDirection`, `QWidget::layoutDirection`; QML `LayoutMirroring.enabled` + `mirror` on Quick Controls | https://doc.qt.io/qt-6/qml-qtquick-layoutmirroring.html |
| C3 | plural rules | Y | `tr("%n file(s)", "", n)` / `qsTr(...).arg(n)` with `%n`; Linguist edits per-language plural forms | https://doc.qt.io/qt-6/i18n-source-translation.html |
| C4 | date / number formatting | Y | `QLocale::toString()` for dates/times/numbers/currency, `QLocale::formattedDataSize()`, CLDR-derived data | https://doc.qt.io/qt-6/qlocale.html |
| C5 | dynamic type / user font scaling | P | Honours system DPI and the desktop font on Windows/macOS/Linux; no iOS Dynamic Type or Android `sp` integration, and no text-size-category API | https://doc.qt.io/qt-6/highdpi.html |
| C6 | IME and composition | Y | `QInputMethod`, `QInputMethodEvent`, `inputMethodQuery`; Qt Virtual Keyboard add-on for embedded | https://doc.qt.io/qt-6/qinputmethod.html |
| C7 | spellcheck | N | No spellcheck in `QTextEdit`/`TextArea` or anywhere else in Qt 6 | https://doc.qt.io/qt-6/qtwidgets-module.html |
| C8 | reduced-motion / high-contrast | P | `QStyleHints::colorScheme` (6.5+) and `QStyleHints::accessibility` → `QAccessibilityHints::contrastPreference` (6.10+). **No reduced-motion signal at all** | https://doc.qt.io/qt-6/qstylehints.html , https://doc.qt.io/qt-6/qaccessibilityhints.html |
| D1 | animations / transitions API | Y | `QPropertyAnimation`, `QVariantAnimation`, `QSequentialAnimationGroup`; QML `NumberAnimation`, `Transition`, `states`, Qt Quick Timeline | https://doc.qt.io/qt-6/animation-overview.html |
| D2 | implicit animation | Y | QML `Behavior on <property>` animates any change to that property. Widgets have no equivalent | https://doc.qt.io/qt-6/qml-qtquick-behavior.html |
| D3 | scroll-to programmatic | Y | `QAbstractItemView::scrollTo()`, `QScrollArea::ensureWidgetVisible()`; `ListView.positionViewAtIndex()`, `TableView.positionViewAtCell()` | https://doc.qt.io/qt-6/qabstractitemview.html#scrollTo |
| D4 | horizontal scroll | Y | `QScrollArea`/`QAbstractScrollArea` horizontal bar; `ListView.orientation: ListView.Horizontal`, `Flickable.flickableDirection` | https://doc.qt.io/qt-6/qml-qtquick-flickable.html |
| D5 | pull-to-refresh | N | No such type in Qt Quick Controls; build it from a `Flickable` overshoot handler | https://doc.qt.io/qt-6/qtquickcontrols-index.html |
| D6 | swipe actions on list rows | Y | `SwipeDelegate` (Quick Controls) with `swipe.left`/`swipe.right` panels | https://doc.qt.io/qt-6/qml-qtquick-controls-swipedelegate.html |
| D7 | keyboard focus order / tab traversal | Y | `QWidget::setTabOrder()`, `focusPolicy`; QML `KeyNavigation`, `FocusScope`, `activeFocusOnTab`, `Keys` | https://doc.qt.io/qt-6/qwidget.html#setTabOrder |
| D8 | adaptive layout | P | Qt Quick Layouts + `Screen`/`Window` bindings, `QLayout` size policies. No breakpoint or size-class concept — you write the width thresholds yourself | https://doc.qt.io/qt-6/qtquicklayouts-index.html |
| E1 | hot reload | P | QML only: Qt Design Studio live preview / QML hot reload and Qt Creator's QML preview. No C++ or Widgets hot reload | https://doc.qt.io/qt-6/topics-app-development.html |
| E2 | inspector / devtools | Y | Qt Creator's QML debugger + inspector (live object tree, property editing, QML Profiler). For Widgets the practical tool is GammaRay (KDAB, third-party) | https://doc.qt.io/qtcreator/creator-debugging-qml.html |
| E3 | testing / UI-driving harness | Y | Qt Test (`QTest::mouseClick`, `keyClicks`, `QSignalSpy`), Qt Quick Test (`TestCase`); Squish is the commercial GUI-driving product | https://doc.qt.io/qt-6/qttest-index.html |
| E4 | packaging / signing / distribution | Y | `windeployqt`, `macdeployqt`, `androiddeployqt`, `qt_generate_deploy_app_script()`; CMake codesign properties for macOS/iOS/Android; Qt Installer Framework | https://doc.qt.io/qt-6/deployment.html |
| E5 | auto-update | P | Qt Installer Framework's maintenance tool does online updates from a repository. No in-app updater API and nothing on mobile | https://doc.qt.io/qtinstallerframework/ifw-updates.html |

Notes:
- **Two tiers, two holes.** Widgets have no `Switch` and no implicit animation; Quick has no printing, no `QUndoStack`, no clipboard type and no sorting on `TableView`. Several rows are Y only because the *other* tier has it, and the tiers do not mix freely (`QQuickWidget` embeds Quick in Widgets, one direction).
- **Qt 6 dropped the platform-extras modules.** Qt Windows Extras / Qt Mac Extras / Qt X11 Extras all went; that is why B3 (taskbar badge) is N in Qt 6 where it was available in Qt 5.
- **The system-integration column is Qt's weak side**: no notifications, no global hotkeys, no keychain, no haptics, no launch-at-login, no share sheet, no background tasks. Qt is a widget toolkit plus networking; OS-service bindings are left to the app.
- **Licensing**: Qt WebEngine is LGPLv3/GPLv3/commercial (its Chromium bulk makes LGPL static linking impractical); Qt Charts and Qt Data Visualization were GPL/commercial-only and are now superseded by Qt Graphs. Everything else in the table is LGPLv3-or-commercial.
- **Technology Preview**: Qt Location (A26) is still TP in 6.11 after being absent for the whole 6.0-6.4 series, and only the OSM plugin ships — the Qt 5 Mapbox/Esri/HERE plugins did not return.
- **Wayland caveats** apply to B5 (stays-on-top and window type hints ignored), B2 (tray needs a StatusNotifierItem host — GNOME shows none without an extension), B4 (nothing works), B7/B8 (no client-side window positioning).

OFF-LIST (Qt ships these; the 70 IDs do not name them):
- 3D scene graph and 3D UI: **Qt Quick 3D** (+ Qt Quick 3D Physics, Qt Shader Tools) — a whole 3D tier inside the same declarative language.
- Charting and data visualization: **Qt Graphs** (2D + 3D bars/scatter/surface), superseding Qt Charts / Qt Data Visualization.
- **Model/view architecture** as a first-class concept: `QAbstractItemModel`, `QSortFilterProxyModel`, `QIdentityProxyModel`, `QDataWidgetMapper` — sorting/filtering/mapping as reusable objects rather than per-view code.
- **Qt State Machine + Qt SCXML**: declarative statecharts driving UI, with QML `State`/`Transition` bound to them.
- **Qt Virtual Keyboard**: a full on-screen keyboard with layouts, handwriting and word prediction, for kiosk/embedded.
- **Qt PDF**: render and view PDFs in-app (`QPdfDocument`, QML `PdfMultiPageView`).
- Device buses as framework modules: **Qt Bluetooth, Qt NFC, Qt SerialPort, Qt SerialBus (CAN/Modbus), Qt OPC UA, Qt MQTT, Qt CoAP** — industrial/IoT I/O shipped alongside the GUI.
- **Qt Wayland Compositor**: build the compositor itself, not just a client — a shipped path to writing the shell your app runs in.

## GTK4 + libadwaita (GNOME platform)

GTK4 is the C widget toolkit (with GObject-Introspection bindings for Python/JS/Rust/Vala); libadwaita adds the GNOME design language, adaptive containers and the boxed-list/preferences idiom. Targets Linux (Wayland first, X11 legacy) plus best-effort Windows/macOS backends; libadwaita is Linux/GNOME only in practice. Doc roots: https://docs.gtk.org/gtk4/ , https://gnome.pages.gitlab.gnome.org/libadwaita/doc/ , https://docs.gtk.org/gio/ (checked against GTK 4.22/4.23 and libadwaita main).

Scope counted as Y: GTK4 itself, libadwaita, and GLib/GIO. GNOME platform libraries that are separate dependencies (libshumate, libsecret, libspelling, libportal, WebKitGTK) are P with the library named. Portals are Y where GTK/GIO speak them for you, P where the app must drive the D-Bus interface (usually via libportal).

| ID | Feature | Verdict | Framework's own name for it | Source |
|----|---------|---------|------------------------------|--------|
| A1 | toggle switch | Y | `GtkSwitch`; `AdwSwitchRow` in a boxed list | https://docs.gtk.org/gtk4/class.Switch.html |
| A2 | segmented control | Y | `AdwToggleGroup` + `AdwToggle` (libadwaita 1.7+); before that, linked `GtkToggleButton`s with the `.linked` style class | https://gnome.pages.gitlab.gnome.org/libadwaita/doc/main/class.ToggleGroup.html |
| A3 | stepper (+/- incrementer) | Y | `GtkSpinButton` (+`GtkAdjustment`); `AdwSpinRow` | https://docs.gtk.org/gtk4/class.SpinButton.html |
| A4 | secure / password entry | Y | `GtkPasswordEntry` (with caps-lock warning and peek icon); `AdwPasswordEntryRow` | https://docs.gtk.org/gtk4/class.PasswordEntry.html |
| A5 | number / formatted field with validation | P | Numeric is covered by `GtkSpinButton`/`AdwSpinRow`. There is **no validator or input-mask API** — `GtkEntry:input-purpose`/`input-hints` only hint the IME; you validate in a `::changed` handler | https://docs.gtk.org/gtk4/class.Entry.html |
| A6 | search field | Y | `GtkSearchEntry` + `GtkSearchBar` (with `gtk_search_bar_set_key_capture_widget` for type-to-search) | https://docs.gtk.org/gtk4/class.SearchEntry.html |
| A7 | colour picker | Y | `GtkColorDialog` + `GtkColorDialogButton` (4.10+; `GtkColorChooser*` deprecated) | https://docs.gtk.org/gtk4/class.ColorDialog.html |
| A8 | tree view / outline | Y | `GtkColumnView` or `GtkListView` + `GtkTreeListModel` + `GtkTreeExpander`. `GtkTreeView`/`GtkTreeStore` still exist but are **deprecated since 4.10** | https://docs.gtk.org/gtk4/class.TreeExpander.html |
| A9 | popover | Y | `GtkPopover` (anchored to a widget, arrow, autohide), `GtkPopoverMenu` | https://docs.gtk.org/gtk4/class.Popover.html |
| A10 | sheet / modal dialog | Y | `AdwDialog` (adaptive: floating on desktop, bottom sheet on narrow), `AdwAlertDialog`, `AdwPreferencesDialog`, `AdwBottomSheet`. `GtkDialog` deprecated 4.10 | https://gnome.pages.gitlab.gnome.org/libadwaita/doc/main/class.Dialog.html |
| A11 | badge (count/dot) | Y | `AdwViewStackPage:badge-number` and `:needs-attention` (drawn by `AdwViewSwitcher`); `AdwTabPage:needs-attention`/`:indicator-icon`. No general-purpose badge on arbitrary widgets | https://gnome.pages.gitlab.gnome.org/libadwaita/doc/main/class.ViewStackPage.html |
| A12 | hyperlink / rich text / markdown | Y | Pango markup in `GtkLabel` (`use-markup`, `<a href>` + `::activate-link`), `GtkLinkButton`, `GtkTextView` with `GtkTextTag` attributes. **No markdown renderer** | https://docs.gtk.org/gtk4/class.Label.html |
| A13 | activity indicator | Y | `GtkSpinner`; `AdwSpinner` (libadwaita 1.7+, the GNOME-styled one) | https://gnome.pages.gitlab.gnome.org/libadwaita/doc/main/class.Spinner.html |
| A14 | tooltip | Y | `gtk_widget_set_tooltip_text()`/`_markup()`, or `has-tooltip` + `::query-tooltip` + `GtkTooltip` for custom content | https://docs.gtk.org/gtk4/class.Tooltip.html |
| A15 | date / time pickers | P | `GtkCalendar` gives a month grid for dates. **No time picker and no date/time entry widget** anywhere in GTK4 or libadwaita — apps hand-roll them from `GtkSpinButton`s | https://docs.gtk.org/gtk4/class.Calendar.html |
| A16 | slider | Y | `GtkScale` (+ `GtkScaleButton` for the popup form). No slider row in libadwaita | https://docs.gtk.org/gtk4/class.Scale.html |
| A17 | tabs | Y | `AdwTabView` + `AdwTabBar` + `AdwTabOverview` (browser-style, draggable, detachable); `AdwViewSwitcher`/`AdwInlineViewSwitcher` for view switching; `GtkNotebook` legacy | https://gnome.pages.gitlab.gnome.org/libadwaita/doc/main/class.TabView.html |
| A18 | split view | Y | `AdwNavigationSplitView` (sidebar+content, collapses to a navigation stack), `AdwOverlaySplitView`; `GtkPaned` for a plain draggable divider | https://gnome.pages.gitlab.gnome.org/libadwaita/doc/main/class.NavigationSplitView.html |
| A19 | toolbar | Y | `AdwToolbarView` (top/bottom bars with adaptive styling), `AdwHeaderBar`/`GtkHeaderBar`. `GtkToolbar` was **removed** in GTK4 | https://gnome.pages.gitlab.gnome.org/libadwaita/doc/main/class.ToolbarView.html |
| A20 | context menu | Y | `GtkPopoverMenu` from a `GMenuModel` + `GtkGestureClick`; text widgets take one directly via `GtkText:extra-menu`/`GtkTextView:extra-menu` | https://docs.gtk.org/gtk4/class.PopoverMenu.html |
| A21 | table / data grid with column sorting | Y | `GtkColumnView` + `GtkColumnViewColumn:sorter` + `GtkColumnViewSorter` feeding a `GtkSortListModel`; clickable headers wired for you | https://docs.gtk.org/gtk4/class.ColumnView.html |
| A22 | virtualized (recycling) lists | Y | `GtkListView`, `GtkColumnView`, `GtkGridView` with `GtkListItemFactory` — only visible rows are realized, and list items are recycled | https://docs.gtk.org/gtk4/class.ListView.html |
| A23 | webview | P | Not GTK. **WebKitGTK** (`webkitgtk-6.0`, `WebKitWebView`) is a separate WebKit-project library that distros package; it is the only realistic option and is Linux-only | https://webkitgtk.org/reference/webkitgtk/stable/ |
| A24 | video player | Y | `GtkVideo` + `GtkMediaFile`/`GtkMediaStream` (GStreamer or ffmpeg backend, chosen at build time) | https://docs.gtk.org/gtk4/class.Video.html |
| A25 | audio playback | Y | `GtkMediaFile`/`GtkMediaStream` play audio files; `gtk_widget_error_bell()` for the system bell. Event sounds normally go through GSound/libcanberra | https://docs.gtk.org/gtk4/class.MediaFile.html |
| A26 | map | P | **libshumate** (`ShumateSimpleMap`/`ShumateMap`, LGPL, GNOME-hosted, GTK4 widget, raster + vector tiles, OSM sources) — a separate dependency, not GTK | https://gnome.pages.gitlab.gnome.org/libshumate/ |
| B1 | local notifications | Y | GIO `GNotification` + `g_application_send_notification()`; buttons/actions, icon, priority, category. Routed through `org.freedesktop.portal.Notification` when sandboxed. Actions are unsupported on the Windows backend | https://docs.gtk.org/gio/class.Notification.html |
| B2 | system tray / status item | P | GTK4 **removed** `GtkStatusIcon`. The route is the StatusNotifierItem D-Bus spec via third-party `libayatana-appindicator3`/`libayatana-appindicator` — and GNOME Shell shows no tray at all without an extension | https://docs.gtk.org/gtk4/migrating-3to4.html |
| B3 | dock / taskbar badge | - | No GNOME concept and nothing in GTK/GIO. Some shells honour the unofficial `com.canonical.Unity.LauncherEntry` D-Bus signal (Dash-to-Dock, KDE, Ubuntu) if you emit it yourself | https://docs.gtk.org/gio/ |
| B4 | global hotkeys | P | Not in GTK/GIO. Under Wayland the only route is `org.freedesktop.portal.GlobalShortcuts`, wrapped by **libportal** (`XdpGlobalShortcutsSession`); needs xdg-desktop-portal 1.17+ and a backend that implements it. Under X11 it is raw `XGrabKey` | https://libportal.org/ |
| B5 | window styles (utility/always-on-top/transparent) | P | Transparency works (CSS `background-color: transparent` with a compositor). GTK4 **removed** `gtk_window_set_keep_above/below` and `gtk_window_set_type_hint` — always-on-top and panel/utility windows are not expressible; on Wayland you need third-party `gtk4-layer-shell` | https://docs.gtk.org/gtk4/migrating-3to4.html |
| B6 | fullscreen | Y | `gtk_window_fullscreen()`, `gtk_window_fullscreen_on_monitor()`, `GtkWindow:fullscreened` | https://docs.gtk.org/gtk4/method.Window.fullscreen.html |
| B7 | window position/size persistence | P | Size only: save `gtk_window_get_default_size()` + `maximized` to GSettings and restore. **Position is impossible** — GTK4 removed `gtk_window_move()`/`get_position()` because Wayland has no client-side window positioning | https://docs.gtk.org/gtk4/migrating-3to4.html |
| B8 | session / state restoration | N | GTK4 has no session-management API (XSMP support is gone) and GNOME does not relaunch apps into prior state. Apps persist what they want in GSettings themselves | https://docs.gtk.org/gtk4/migrating-3to4.html |
| B9 | recent files | Y | `GtkRecentManager` (the shared `recently-used.xbel` list). Sandboxed apps additionally keep persistent access to portal-opened files through the Documents portal, which is the security-scoped-bookmark analogue | https://docs.gtk.org/gtk4/class.RecentManager.html |
| B10 | share sheet | N | No share portal, no GNOME share sheet, nothing in GTK. `g_app_info_launch_default_for_uri()` on a `mailto:` is the closest thing | https://docs.gtk.org/gio/ |
| B11 | URL schemes / deep links | Y | `G_APPLICATION_HANDLES_OPEN` on `GApplication` + `::open` signal, with `MimeType=x-scheme-handler/foo;` in the `.desktop` file. No universal-links equivalent (there is no such Linux concept) | https://docs.gtk.org/gio/class.Application.html |
| B12 | file type associations | Y | `.desktop` `MimeType=` + shared-mime-info XML; at runtime `g_app_info_set_as_default_for_type()` / `g_app_info_add_supports_type()` | https://docs.gtk.org/gio/iface.AppInfo.html |
| B13 | printing | Y | `GtkPrintDialog` (4.14+) and `GtkPrintOperation` with `GtkPrintSettings`/`GtkPageSetup`, CUPS backend; routed through the print portal when sandboxed | https://docs.gtk.org/gtk4/class.PrintDialog.html |
| B14 | drag and drop | Y | `GtkDragSource` + `GtkDropTarget`/`GtkDropTargetAsync` + `GdkContentProvider`/`GdkContentFormats` (event-controller based since GTK4) | https://docs.gtk.org/gtk4/class.DragSource.html |
| B15 | clipboard | Y | `GdkClipboard` (`gdk_display_get_clipboard()` / `get_primary_clipboard()` — X11/Wayland PRIMARY selection is first-class) with `GdkContentProvider` | https://docs.gtk.org/gdk4/class.Clipboard.html |
| B16 | file dialogs | Y | `GtkFileDialog` (4.10+, async; `GtkFileChooser*` deprecated); transparently becomes the portal file chooser inside a Flatpak sandbox | https://docs.gtk.org/gtk4/class.FileDialog.html |
| B17 | menubar (application menu) | Y | `GtkPopoverMenuBar` from a `GMenuModel`, or `gtk_application_set_menubar()`. The GNOME HIG steers apps to a primary menu in the header bar instead, and there is no native macOS/Windows menu-bar mapping | https://docs.gtk.org/gtk4/class.PopoverMenuBar.html |
| B18 | undo/redo integration | P | `GtkTextBuffer` has real built-in undo (`enable-undo`, `can-undo`, `undo()`, `redo()`, `begin_irreversible_action()`), and `GtkText`/`GtkEntry` inherit it. **No app-wide undo manager** — nothing like `QUndoStack` for non-text state | https://docs.gtk.org/gtk4/class.TextBuffer.html |
| B19 | launch at login | P | XDG autostart `.desktop` in `~/.config/autostart` written by hand, or the Background portal's autostart request via **libportal** (`xdp_portal_request_background` with `XDP_BACKGROUND_FLAG_AUTOSTART`). Nothing in GTK/GIO | https://libportal.org/ |
| B20 | background tasks | P | Permission to keep running in the background is the Background portal (libportal). Actual *scheduling* is systemd user timers or your own main-loop timers — there is no WorkManager/BGTaskScheduler analogue | https://libportal.org/ |
| B21 | camera / photo picker | P | Camera access is the Camera portal via **libportal** (`xdp_portal_access_camera`), which hands back a PipeWire fd you render with GStreamer — GTK has no camera widget. No photo-library picker concept; use `GtkFileDialog` | https://libportal.org/ |
| B22 | biometrics / keychain / secure storage | P | **libsecret** (GNOME library) talks to the Secret Service / gnome-keyring. No biometric prompt API of any kind (fprintd is a system service, not app-facing) | https://gnome.pages.gitlab.gnome.org/libsecret/ |
| B23 | haptics | N | Nothing in GTK4, libadwaita or GLib. Even on GNOME mobile (Phosh) apps have no haptics API | https://docs.gtk.org/gtk4/ |
| C1 | localization / string tables | Y | gettext (`_()`/`g_dgettext`), `.po`/`.mo`, `GLib.dgettext`; translatable strings in `.ui` files and `GResource` | https://docs.gtk.org/glib/i18n.html |
| C2 | RTL layout mirroring | Y | `gtk_widget_set_direction()`/`GTK_TEXT_DIR_RTL`, automatic mirroring of box/grid layouts and of icons marked with the `-rtl` suffix | https://docs.gtk.org/gtk4/method.Widget.set_direction.html |
| C3 | plural rules | Y | `ngettext()`/`g_dngettext()` with per-language `Plural-Forms` in the `.po` header | https://docs.gtk.org/glib/i18n.html |
| C4 | date / number formatting | P | `g_date_time_format()` is locale-aware strftime and `g_format_size()` handles byte sizes, but GLib has **no locale number or currency formatter** — you fall back to locale `printf` or link ICU yourself | https://docs.gtk.org/glib/struct.DateTime.html |
| C5 | dynamic type / user font scaling | Y | GTK honours `gtk-font-name` and `gtk-xft-dpi` (which GNOME's `text-scaling-factor` drives) and restyles live; `GtkSettings` notifies on change | https://docs.gtk.org/gtk4/class.Settings.html |
| C6 | IME and composition | Y | `GtkIMContext`/`GtkIMMulticontext` with ibus/fcitx modules; `GtkText`/`GtkTextView` handle preedit and `::preedit-changed` for you | https://docs.gtk.org/gtk4/class.IMContext.html |
| C7 | spellcheck | P | Not in GTK. **libspelling** (GNOME library, enchant-backed, the one GNOME Text Editor uses) attaches to a `GtkTextView`; `gspell` is the older equivalent | https://gnome.pages.gitlab.gnome.org/libspelling/ |
| C8 | reduced-motion / high-contrast | Y | `GtkSettings:gtk-interface-reduced-motion` (4.22) and `:gtk-interface-contrast` (4.20); `GtkSettings:gtk-enable-animations` long before that; `AdwStyleManager:high-contrast` and `:dark` | https://docs.gtk.org/gtk4/class.Settings.html , https://gnome.pages.gitlab.gnome.org/libadwaita/doc/main/class.StyleManager.html |
| D1 | animations / transitions API | Y | `AdwAnimation` with `AdwTimedAnimation` (easings) and `AdwSpringAnimation` (physical springs); underneath, `gtk_widget_add_tick_callback()` on the `GdkFrameClock` | https://gnome.pages.gitlab.gnome.org/libadwaita/doc/main/class.SpringAnimation.html |
| D2 | implicit animation | P | GTK CSS supports `transition:` on styled properties (colour, background, opacity, border), so a style-class change animates itself. Arbitrary widget properties do **not** — those need an explicit `AdwAnimation` | https://docs.gtk.org/gtk4/css-properties.html |
| D3 | scroll-to programmatic | Y | `gtk_list_view_scroll_to()` / `gtk_column_view_scroll_to()` (4.12+, with select/focus flags), `gtk_widget_activate_action("list.scroll-to-item")`, or `GtkScrolledWindow` adjustments | https://docs.gtk.org/gtk4/method.ListView.scroll_to.html |
| D4 | horizontal scroll | Y | `GtkScrolledWindow` with `hscrollbar-policy`; `GtkListView:orientation` for horizontal lists; kinetic/touchpad scrolling handled | https://docs.gtk.org/gtk4/class.ScrolledWindow.html |
| D5 | pull-to-refresh | N | No such widget in GTK4 or libadwaita; nothing in the widget gallery | https://gnome.pages.gitlab.gnome.org/libadwaita/doc/main/widget-gallery.html |
| D6 | swipe actions on list rows | N | No row-swipe-action API. `AdwSwipeTracker`/`AdwSwipeable` exist but are the gesture primitive behind carousels and navigation views, not per-row reveal actions | https://gnome.pages.gitlab.gnome.org/libadwaita/doc/main/class.SwipeTracker.html |
| D7 | keyboard focus order / tab traversal | Y | `GtkWidget:focusable`/`:can-focus`, `gtk_widget_set_focus_child()`, `gtk_widget_child_focus()`, the `GtkWidgetClass.focus` vfunc, `GtkRoot` focus, plus `GtkShortcutController` for accelerators | https://docs.gtk.org/gtk4/class.Widget.html |
| D8 | adaptive layout | Y | `AdwBreakpoint` + `AdwBreakpointBin` (declarative `max-width: 400sp` conditions that set properties), `AdwClamp`, `AdwMultiLayoutView`, collapsing `AdwNavigationSplitView`/`AdwOverlaySplitView` | https://gnome.pages.gitlab.gnome.org/libadwaita/doc/main/class.Breakpoint.html |
| E1 | hot reload | N | No hot reload. `.ui` files are compiled into `GResource` at build time; GNOME Builder and the Workbench app give live preview of a `.ui`/Blueprint file, not of a running app's state | https://docs.gtk.org/gtk4/class.Builder.html |
| E2 | inspector / devtools | Y | **GTK Inspector** — `GTK_DEBUG=interactive` or Ctrl+Shift+D: live widget tree, property editing, CSS editor with live reload, layout/baseline overlays, a11y tree, frame recorder | https://docs.gtk.org/gtk4/running.html |
| E3 | testing / UI-driving harness | P | `gtk_test_init()` (GLib test harness + deterministic locale) and the `gtk_test_accessible_assert_*` macros for a11y assertions. GTK4 **removed** GTK3's `gtk_test_widget_click`/`gtk_test_slider_set_perc` — there is no supported way to synthesize input. Driving the UI means third-party dogtail/libatspi or GNOME's openQA | https://docs.gtk.org/gtk4/func.test_init.html |
| E4 | packaging / signing / distribution | Y | Flatpak + `flatpak-builder` + Flathub is the first-party GNOME story (manifest, sandbox permissions, portal-mediated access); Meson + GNOME Builder build it. Repo GPG signing rather than per-binary code signing | https://docs.flatpak.org/ |
| E5 | auto-update | P | Updates come from Flatpak/GNOME Software or the distro package manager, not from the app. No in-app updater API, and no way for an app to trigger its own update | https://docs.flatpak.org/ |

Notes:
- **The GTK4 migration deleted several system-integration APIs and did not replace them**: `GtkStatusIcon` (B2), `gtk_window_move`/`get_position` (B7), `set_keep_above`/`set_type_hint` (B5), the GTK3 input-synthesis test helpers (E3). Every one of those is a Wayland consequence — the compositor owns stacking, placement and input injection now — so the answer is "ask the portal" or "not possible", never "call GDK".
- **Portals are the system-integration layer, and they are not GTK.** File dialogs, printing and notifications get portal routing for free from GTK/GIO; camera, background/autostart, global shortcuts, screenshot, screencast and inhibit do not — you link libportal (or write D-Bus by hand) and each needs a portal backend that implements it. That split is exactly the Y/P line in the B rows.
- **libadwaita is where the modern controls live**, not GTK: the switch row, segmented control (`AdwToggleGroup`), spinner, adaptive dialog, bottom sheet, tab overview, breakpoints and the whole boxed-list idiom are libadwaita classes. An app that uses GTK4 alone is missing most of the A-column strength here.
- **GTK is ahead of every other toolkit surveyed on C8**: `gtk-interface-reduced-motion` (4.22) and `gtk-interface-contrast` (4.20) are real settings with change notification, and `AdwStyleManager` exposes dark/high-contrast/accent as properties you can bind.
- **The real content gaps** are A15 (no time picker at all — apps build them out of spin buttons), A23/A26 (webview and map are separate non-GTK libraries), D5/D6 (no pull-to-refresh, no row swipe actions despite libadwaita's mobile ambitions) and B18 (undo exists only inside text buffers).
- **X11-only / Wayland-restricted** matters for four rows: B4 global hotkeys (X11 `XGrabKey` vs the portal, nothing otherwise), B5 always-on-top and panel windows (X11 only; `gtk4-layer-shell` for Wayland), B7 window positioning (X11 only, and the API is gone from GTK4 either way), B2 tray (D-Bus StatusNotifierItem, invisible on stock GNOME Shell).

OFF-LIST (GTK/libadwaita ship these; the 70 IDs do not name them):
- **List-model pipelines as widgets' data source**: `GListModel` + `GtkFilterListModel`, `GtkSortListModel`, `GtkSliceListModel`, `GtkFlattenListModel`, `GtkMapListModel`, `GtkSelectionModel` — filtering/sorting/selection composed as objects, reused by every view.
- **`GtkExpression`** — declarative property bindings (`GtkPropertyExpression`, `GtkClosureExpression`, `GtkCConstantExpression`) usable from `.ui` XML, i.e. bindings without code.
- **`GAction`/`GMenuModel` as the app's command layer**: actions carry state and parameter types, menus and shortcuts are declared against action names, and the same model drives menubar, popover menu and D-Bus activation.
- **Toasts and status pages**: `AdwToast`/`AdwToastOverlay` (undoable transient messages), `AdwBanner`, `AdwStatusPage` — GNOME's answer to empty states and transient feedback, with no equivalent ID on the list.
- **`AdwAvatar`** — generated initials/colour avatars from a name, a control most toolkits leave to the app.
- **`AdwAboutDialog` and `AdwShortcutsDialog`** — the About box and the keyboard-shortcuts window as first-party widgets fed from metadata.
- **`GtkEmojiChooser`** — a built-in emoji picker, wired into `GtkText`/`GtkTextView` by default.
- **GTK CSS as the styling system**: real cascading stylesheets over the widget tree with selectors, custom properties, `@define-color`, live reload in the Inspector — plus `GtkSnapshot`/`GskRenderNode` for custom drawing below it.

---

**WinUI 3 / Avalonia / Uno — 70-feature parity survey**


---

## WinUI 3 (Windows App SDK 2.0)

Microsoft's current native UI framework for Windows desktop (Win32/HWND-based, C# and C++/WinRT); Windows 10 1809+ and Windows 11 only — it is not cross-platform. A WinUI app also calls WinRT/Windows SDK APIs directly for system integration.
Doc roots: https://learn.microsoft.com/en-us/windows/apps/design/controls/ and https://learn.microsoft.com/en-us/windows/apps/windows-app-sdk/

| ID | Feature | Verdict | Framework's own name for it | Source |
|----|---------|---------|------------------------------|--------|
| A1 | toggle switch | Y | `ToggleSwitch` ("Toggle switches" — distinct from `CheckBox`) | https://learn.microsoft.com/en-us/windows/apps/design/controls/toggles |
| A2 | segmented control | Y | `SelectorBar` (WASDK 1.5+); also `Segmented` in Windows Community Toolkit | https://learn.microsoft.com/en-us/windows/apps/design/controls/selector-bar |
| A3 | stepper (+/-) | Y | `NumberBox` with `SpinButtonPlacementMode` (inline/compact spin buttons) | https://learn.microsoft.com/en-us/windows/apps/design/controls/number-box |
| A4 | secure / password entry | Y | `PasswordBox` (`PasswordRevealMode`) | https://learn.microsoft.com/en-us/windows/apps/design/controls/password-box |
| A5 | number / formatted field w/ validation | Y | `NumberBox` (`NumberFormatter`, `ValidationMode`, `AcceptsExpression`); `INotifyDataErrorInfo` binding validation | https://learn.microsoft.com/en-us/windows/apps/design/controls/number-box |
| A6 | search field | Y | `AutoSuggestBox` (`QueryIcon`, `QuerySubmitted`) — the Fluent search control | https://learn.microsoft.com/en-us/windows/apps/design/controls/auto-suggest-box |
| A7 | colour picker | Y | `ColorPicker` / `ColorPickerButton` | https://learn.microsoft.com/en-us/windows/apps/design/controls/color-picker |
| A8 | tree view / outline | Y | `TreeView` (data-bound or `TreeViewNode`) | https://learn.microsoft.com/en-us/windows/apps/design/controls/tree-view |
| A9 | popover | Y | `Flyout`, `MenuFlyout`, `TeachingTip`, `Popup` | https://learn.microsoft.com/en-us/windows/apps/design/controls/dialogs-and-flyouts/flyouts |
| A10 | modal dialog w/ custom content | Y | `ContentDialog` (arbitrary XAML content; set `XamlRoot`) | https://learn.microsoft.com/en-us/windows/apps/design/controls/dialogs-and-flyouts/dialogs |
| A11 | badge | Y | `InfoBadge` (numeric / icon / dot), designed to sit on `NavigationView` items | https://learn.microsoft.com/en-us/windows/apps/design/controls/info-badge |
| A12 | hyperlink / rich text / markdown | Y | `HyperlinkButton`, `Hyperlink` inline, `RichTextBlock`, `RichEditBox`. Markdown rendering is NOT first-party — `MarkdownTextBlock` is in the Windows Community Toolkit | https://learn.microsoft.com/en-us/windows/apps/design/controls/rich-text-block |
| A13 | activity indicator | Y | `ProgressRing` (`IsIndeterminate`), distinct from `ProgressBar` | https://learn.microsoft.com/en-us/windows/apps/design/controls/progress-controls |
| A14 | tooltip | Y | `ToolTip` / `ToolTipService.ToolTip` attached property | https://learn.microsoft.com/en-us/windows/apps/design/controls/tooltips |
| A15 | date / time pickers | Y | `DatePicker`, `TimePicker`, `CalendarDatePicker`, `CalendarView` | https://learn.microsoft.com/en-us/windows/apps/design/controls/date-picker |
| A16 | slider | Y | `Slider` (`StepFrequency`, `TickPlacement`, orientation) | https://learn.microsoft.com/en-us/windows/apps/design/controls/slider |
| A17 | tabs | Y | `TabView` (tear-off, close, reorder), `Pivot` | https://learn.microsoft.com/en-us/windows/apps/design/controls/tab-view |
| A18 | split view / sidebar-detail | Y | `SplitView`, `TwoPaneView`, `NavigationView` (adaptive sidebar); user drag-to-resize splitter is Community Toolkit `GridSplitter`/`PropertySizer`, not first-party | https://learn.microsoft.com/en-us/windows/apps/design/controls/split-view |
| A19 | toolbar | Y | `CommandBar`, `CommandBarFlyout`, `AppBarButton` | https://learn.microsoft.com/en-us/windows/apps/design/controls/command-bar |
| A20 | context menu | Y | `MenuFlyout` via `UIElement.ContextFlyout`; `CommandBarFlyout` | https://learn.microsoft.com/en-us/windows/apps/design/controls/menus-and-context-menus |
| A21 | table / data grid w/ column sorting | P | No first-party control. Docs: "DataGrid — No first-party WinUI 3 control. The CommunityToolkit DataGrid is UWP-only (7.1.0) and has not been ported to WinUI 3. Community alternative: WinUI.TableView." Sorting must be hand-written over `ListView`+`GridView` layout | https://learn.microsoft.com/en-us/windows/apps/windows-app-sdk/migrate-to-windows-app-sdk/what-is-supported |
| A22 | virtualized lists | Y | `ListView`/`GridView` (virtualizing panels), `ItemsRepeater`, `ItemsView`, `ItemsStackPanel`; `AnnotatedScrollBar` for huge collections | https://learn.microsoft.com/en-us/windows/apps/design/controls/items-repeater |
| A23 | webview | Y | `WebView2` (Chromium/Edge). Needs the WebView2 Runtime, pre-installed on most Win10/11 | https://learn.microsoft.com/en-us/microsoft-edge/webview2/ |
| A24 | video player | Y | `MediaPlayerElement` (+ `MediaTransportControls`), introduced WASDK 1.2 | https://learn.microsoft.com/en-us/windows/apps/design/controls/media-playback |
| A25 | audio playback | Y | `Windows.Media.Playback.MediaPlayer`; `SystemMediaTransportControls` via interop | https://learn.microsoft.com/en-us/windows/apps/design/controls/media-playback |
| A26 | map | Y | `Microsoft.UI.Xaml.Controls.MapControl`, introduced WASDK 1.5 (needs a maps service token) | https://learn.microsoft.com/en-us/windows/apps/windows-app-sdk/migrate-to-windows-app-sdk/what-is-supported |
| B1 | local notifications | Y | `AppNotificationBuilder` / `AppNotificationManager` (Windows App SDK). Works packaged AND unpackaged (WPF/WinForms/console guides exist). Limitation: elevated apps cannot send or receive them | https://learn.microsoft.com/en-us/windows/apps/develop/notifications/app-notifications/ |
| B2 | system tray / status item | P | No WinUI/WinRT API. Win32 `Shell_NotifyIcon` via P/Invoke, or the `H.NotifyIcon.WinUI` NuGet package | https://github.com/HavenDV/H.NotifyIcon |
| B3 | taskbar badge | Y | `BadgeUpdateManager.CreateBadgeUpdaterForApplication()` + `BadgeNotification` — numeric 1-99 or a fixed glyph set; needs MSIX package identity, and you cannot supply your own badge image | https://learn.microsoft.com/en-us/windows/apps/develop/notifications/badges |
| B4 | global hotkeys | P | No WinUI/WinRT API. Win32 `RegisterHotKey` + `WM_HOTKEY` through the window's HWND (`WinRT.Interop.WindowNative.GetWindowHandle`) | https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-registerhotkey |
| B5 | window styles (utility, on-top, blurred) | Y | `AppWindow` + `OverlappedPresenter` (`IsAlwaysOnTop`, `SetBorderAndTitleBar`, `IsMaximizable`), `CompactOverlayPresenter`; `MicaBackdrop` / `DesktopAcrylicBackdrop` (`SystemBackdrop`) | https://learn.microsoft.com/en-us/windows/apps/develop/ui/windowing-overview |
| B6 | fullscreen | Y | `AppWindow.SetPresenter(AppWindowPresenterKind.FullScreen)` / `FullScreenPresenter` | https://learn.microsoft.com/en-us/windows/apps/develop/ui/windowing-overview |
| B7 | window position/size persistence | N | `AppWindow.MoveAndResize` / `Move` exist, but nothing persists or restores geometry — the app stores and re-applies it | https://learn.microsoft.com/en-us/windows/windows-app-sdk/api/winrt/microsoft.ui.windowing.appwindow |
| B8 | session / state restoration | N | No XAML state-restoration service in WinUI 3. `AppInstance.Restart(args)` restarts with a command line only; the app serializes its own UI state | https://learn.microsoft.com/en-us/windows/apps/windows-app-sdk/applifecycle/applifecycle |
| B9 | recent files / bookmarks | Y | `Windows.Storage.AccessCache.StorageApplicationPermissions` `FutureAccessList` / `MostRecentlyUsedList` (persisted permission tokens = the security-scoped-bookmark analogue) and `Windows.UI.StartScreen.JumpList`; both need MSIX package identity. Unpackaged: Win32 `SHAddToRecentDocs` | https://learn.microsoft.com/en-us/uwp/api/windows.storage.accesscache.storageapplicationpermissions |
| B10 | share sheet | Y | `DataTransferManager` + `IDataTransferManagerInterop::ShowShareUIForWindow` (HWND interop required in desktop apps) | https://learn.microsoft.com/en-us/windows/apps/develop/ui-input/display-ui-objects |
| B11 | URL schemes / deep links | Y | `ActivationRegistrationManager.RegisterForProtocolActivation` (unpackaged) or the MSIX `windows.protocol` extension; handled via `AppInstance.GetActivatedEventArgs` | https://learn.microsoft.com/en-us/windows/apps/windows-app-sdk/applifecycle/applifecycle-rich-activation |
| B12 | file type associations | Y | `ActivationRegistrationManager.RegisterForFileTypeActivation` (unpackaged) or the MSIX `windows.fileTypeAssociation` extension | https://learn.microsoft.com/en-us/windows/apps/windows-app-sdk/applifecycle/applifecycle-rich-activation |
| B13 | printing | P | `Windows.Graphics.Printing.PrintManager` via `IPrintManagerInterop`. Docs: "Supported on Windows 11 (not yet available on Windows 10)" | https://learn.microsoft.com/en-us/windows/apps/windows-app-sdk/migrate-to-windows-app-sdk/what-is-supported |
| B14 | drag and drop | Y | `UIElement.CanDrag` / `AllowDrop` / `DragStarting` / `DragOver` / `Drop`, `DataPackage`, `DragUI`; cross-app via the shell data package | https://learn.microsoft.com/en-us/windows/apps/design/input/drag-and-drop |
| B15 | clipboard | Y | `Windows.ApplicationModel.DataTransfer.Clipboard` + `DataPackage` (text, bitmap, storage items, custom formats) | https://learn.microsoft.com/en-us/windows/apps/design/input/copy-and-paste |
| B16 | file dialogs | Y | `Windows.Storage.Pickers.FileOpenPicker` / `FileSavePicker` / `FolderPicker` with `IInitializeWithWindow`; WASDK 1.8 adds `Microsoft.Windows.Storage.Pickers` which take the window directly | https://learn.microsoft.com/en-us/windows/apps/develop/ui-input/display-ui-objects |
| B17 | menubar | Y | `MenuBar` + `MenuBarItem` + `MenuFlyoutItem` (in-window, Windows has no system-owned app menu) | https://learn.microsoft.com/en-us/windows/apps/design/controls/menus |
| B18 | undo/redo integration | N | No framework-level undo manager. Only per-control undo (`TextBox` Ctrl+Z, `RichEditBox.Document.Undo`/`Redo`); an app implements its own stack | https://learn.microsoft.com/en-us/windows/windows-app-sdk/api/winrt/microsoft.ui.xaml.controls.richeditbox |
| B19 | launch at login | Y | `Windows.ApplicationModel.StartupTask.RequestEnableAsync` (needs MSIX identity + a `windows.startupTask` extension; the user can veto in Task Manager). Unpackaged: the `Run` registry key | https://learn.microsoft.com/en-us/uwp/api/windows.applicationmodel.startuptask |
| B20 | background tasks | Y | `Microsoft.Windows.ApplicationModel.Background.BackgroundTaskBuilder`, introduced WASDK 1.7; plus push-notification background activation (`COM` activation) | https://learn.microsoft.com/en-us/windows/apps/windows-app-sdk/migrate-to-windows-app-sdk/what-is-supported |
| B21 | camera / photo picker | Y | `Microsoft.Windows.Media.Capture.CameraCaptureUI`, introduced WASDK 1.7; photo picking is `FileOpenPicker`. (`CaptureElement` has no WinUI 3 equivalent — use `MediaPlayerElement` + `MediaSource.CreateFromMediaFrameSource` for preview) | https://learn.microsoft.com/en-us/windows/apps/windows-app-sdk/migrate-to-windows-app-sdk/what-is-supported |
| B22 | biometrics / secure storage | Y | `Windows.Security.Credentials.UI.UserConsentVerifier` (Windows Hello, via `IUserConsentVerifierInterop`), `Windows.Security.Credentials.PasswordVault`, `KeyCredentialManager`, `DataProtectionProvider` | https://learn.microsoft.com/en-us/windows/apps/develop/ui-input/display-ui-objects |
| B23 | haptics | P | `Windows.Devices.Haptics` (`SimpleHapticsController`) covers pens, touchpads and gamepads only; no general desktop/window haptics API | https://learn.microsoft.com/en-us/uwp/api/windows.devices.haptics |
| C1 | localization / string tables | Y | MRT Core: `.resw` resource files + `x:Uid` in XAML + `ResourceLoader`/`ResourceManager`; works unpackaged since Win10 1903 (manual `MakePri.exe`) | https://learn.microsoft.com/en-us/windows/uwp/app-resources/localize-strings-ui-manifest |
| C2 | RTL layout mirroring | Y | `FrameworkElement.FlowDirection = RightToLeft`; the `LayoutDirection` resource qualifier | https://learn.microsoft.com/en-us/windows/apps/design/globalizing/adjust-layout-and-fonts |
| C3 | plural rules | P | No plural-aware lookup in `.resw`/`ResourceLoader` and none in .NET. Apps use the `Humanizer` or `SmartFormat.NET` NuGet packages, or ICU MessageFormat bindings | https://learn.microsoft.com/en-us/windows/uwp/app-resources/localize-strings-ui-manifest |
| C4 | date / number formatting | Y | `Windows.Globalization.DateTimeFormatting.DateTimeFormatter`, `Windows.Globalization.NumberFormatting.*` (also used by `NumberBox`), plus .NET `CultureInfo` formatting | https://learn.microsoft.com/en-us/uwp/api/windows.globalization.numberformatting |
| C5 | dynamic type / font scaling | Y | Honours the system text-size setting automatically; `UISettings.TextScaleFactor` + `TextScaleFactorChanged`, opt out per element with `IsTextScaleFactorEnabled` | https://learn.microsoft.com/en-us/uwp/api/windows.ui.viewmanagement.uisettings.textscalefactor |
| C6 | IME / composition | Y | TSF composition works in `TextBox`/`RichEditBox` out of the box. The custom-editor API `CoreTextServicesManager` is noted "Supported only on Windows 11" in WinUI 3 | https://learn.microsoft.com/en-us/windows/apps/windows-app-sdk/migrate-to-windows-app-sdk/what-is-supported |
| C7 | spellcheck | Y | `TextBox.IsSpellCheckEnabled` / `RichEditBox.IsSpellCheckEnabled` (on by default) | https://learn.microsoft.com/en-us/windows/apps/design/controls/text-box |
| C8 | reduced-motion / high-contrast | Y | `UISettings.AnimationsEnabled`, `AccessibilitySettings.HighContrast` + `HighContrastScheme`, and `HighContrast` XAML theme dictionaries applied automatically | https://learn.microsoft.com/en-us/windows/apps/design/accessibility/high-contrast-themes |
| D1 | animations / transitions API | Y | XAML `Storyboard` + `DoubleAnimation`, `Microsoft.UI.Composition` animations (`ExpressionAnimation`, `SpringVector3NaturalMotionAnimation`), `AnimatedVisualPlayer` (Lottie) | https://learn.microsoft.com/en-us/windows/apps/design/motion/ |
| D2 | implicit animation | Y | `UIElement.Transitions` theme transitions (`EntranceThemeTransition`, `RepositionThemeTransition`…), Composition `ImplicitAnimationCollection`, and implicit show/hide animations | https://learn.microsoft.com/en-us/windows/apps/design/motion/xaml-transitions |
| D3 | scroll-to programmatic | Y | `ScrollView.ScrollTo` / `ScrollBy`, `ScrollViewer.ChangeView`, `ListViewBase.ScrollIntoView`, `FrameworkElement.StartBringIntoView` | https://learn.microsoft.com/en-us/windows/apps/design/controls/scroll-controls |
| D4 | horizontal scroll | Y | `ScrollViewer.HorizontalScrollBarVisibility` / `HorizontalScrollMode`; `GridView`/`ItemsRepeater` horizontal layouts | https://learn.microsoft.com/en-us/windows/apps/design/controls/scroll-controls |
| D5 | pull-to-refresh | Y | `RefreshContainer` + `RefreshVisualizer` (`RefreshRequested`) | https://learn.microsoft.com/en-us/windows/apps/design/controls/pull-to-refresh |
| D6 | swipe actions on rows | Y | `SwipeControl` + `SwipeItems` (`LeftItems`/`RightItems`, Reveal and Execute modes) | https://learn.microsoft.com/en-us/windows/apps/design/controls/swipe |
| D7 | focus order / tab traversal | Y | `TabIndex`, `IsTabStop`, `TabFocusNavigation`, `XYFocusUp/Down/Left/Right`, `FocusManager.FindNextElement`/`TryMoveFocus` | https://learn.microsoft.com/en-us/windows/apps/design/input/keyboard-interactions |
| D8 | adaptive layout | Y | `VisualStateManager` + `AdaptiveTrigger` (`MinWindowWidth`), `NavigationView` adaptive display modes, `TwoPaneView` | https://learn.microsoft.com/en-us/windows/apps/design/layout/responsive-design |
| E1 | hot reload | Y | XAML Hot Reload + .NET Hot Reload in Visual Studio (the static XAML **Designer** does not support WinUI 3 — runtime tools are the recommended workflow) | https://learn.microsoft.com/en-us/windows/apps/develop/ui/xaml-runtime-design-tools |
| E2 | inspector / devtools | Y | Live Visual Tree, Live Property Explorer and the in-app XAML toolbar in Visual Studio | https://learn.microsoft.com/en-us/windows/apps/develop/ui/xaml-runtime-design-tools |
| E3 | testing / UI-driving harness | P | No supported first-party harness: WinAppDriver is archived by Microsoft; the live route is the Appium `windows` driver (built on it), or `Microsoft.Windows.Apps.Test` (MITA/TAEF), which is what the WinUI repo itself uses | https://github.com/microsoft/WinAppDriver |
| E4 | packaging / signing / distribution | Y | MSIX (packaged, or unpackaged/self-contained deployment), Visual Studio publish, Microsoft Store, `.appinstaller` | https://learn.microsoft.com/en-us/windows/apps/windows-app-sdk/deployment-architecture |
| E5 | auto-update | Y | Microsoft Store automatic updates; MSIX App Installer `.appinstaller` automatic update checks; `Windows.Services.Store.StoreContext` for in-app update prompts | https://learn.microsoft.com/en-us/windows/msix/app-installer/update-settings |

Notes:
- Windows-only. Nothing here is cross-platform; parity with a cross-platform toolkit means parity on one platform.
- The biggest first-party hole is the **data grid** (A21): Microsoft's own migration page says there is no WinUI 3 DataGrid and points at the community `WinUI.TableView`.
- Several WinRT APIs still need HWND interop in a WinUI window (share UI, pickers pre-1.8, print manager, Windows Hello) — see the `IInitializeWithWindow` / `IDataTransferManagerInterop` / `IPrintManagerInterop` list. It is supported and documented, not a hack, but it is boilerplate per call site.
- Package identity (MSIX) gates B3 (taskbar badge), B9 (FutureAccessList/JumpList) and B19 (StartupTask). Notifications (B1) and background tasks (B20) do NOT require it.
- Other documented gaps not on the 70-item list: `InkCanvas` experimental only, `InkToolbar` absent, `CaptureElement` absent, `RadialController` fail-fasts in packaged apps, `DisplayRequest` absent, no gamepad virtual keys, no Xbox/HoloLens.
- Windows App SDK 2.0 notes its own launch speed, RAM and install size are "larger/slower than seen in UWP".

OFF-LIST (prominent WinUI things the 70 IDs do not name):
- `RatingControl` — 1-to-5-star rating input.
- `PersonPicture` — contact avatar with initials/photo fallback.
- `SemanticZoom` — two-level zoomed-in/zoomed-out view of one collection.
- `BreadcrumbBar` and `PipsPager` — trail-of-navigation and dot pagination.
- `TeachingTip` — targeted coach-mark flyout for onboarding, distinct from tooltip and popover.
- `InfoBar` — inline, dismissible app-wide status message strip.
- `Expander` and `AnnotatedScrollBar` — disclosure container; scrollbar with labelled jump targets in huge lists.
- `TitleBar` control + `SystemBackdrop` (Mica/Acrylic) — first-party custom caption and window material.
- `AnimatedIcon` / `AnimatedVisualPlayer` — Lottie playback as an icon or a view.
- Widgets (`widget-providers`) — the Windows widget board is a first-party surface with no analogue in the list.

---

## Avalonia UI (12.1.2, current stable; 11.3.x still maintained)

MIT-licensed .NET UI framework that renders its own controls with Skia on Windows, macOS, Linux (X11 + Wayland), iOS, Android, WebAssembly and Linux framebuffer. Since v12 a set of premium controls and the developer tools sit behind a paid subscription.
Doc roots: https://docs.avaloniaui.net/controls/ , https://github.com/AvaloniaUI/Avalonia , https://avaloniaui.net/pricing

| ID | Feature | Verdict | Framework's own name for it | Source |
|----|---------|---------|------------------------------|--------|
| A1 | toggle switch | Y | `ToggleSwitch` (separate from `CheckBox`/`ToggleButton`) | https://docs.avaloniaui.net/controls/input/selectors/toggleswitch |
| A2 | segmented control | N | No segmented control. `TabStrip` or a `RadioButton` group restyled is the workaround | https://docs.avaloniaui.net/controls/navigation/tabstrip |
| A3 | stepper (+/-) | Y | `NumericUpDown` (built on `ButtonSpinner`/`Spinner`) | https://docs.avaloniaui.net/controls/input/selectors/numericupdown |
| A4 | secure / password entry | Y | `TextBox` with `PasswordChar` + `RevealPassword` (no separate PasswordBox type) | https://docs.avaloniaui.net/controls/input/text-input/textbox |
| A5 | number / formatted field w/ validation | Y | `NumericUpDown` (min/max, `FormatString`, `NumberFormat`), `MaskedTextBox`, and `DataValidationErrors` over `INotifyDataErrorInfo`/`IDataErrorInfo` | https://docs.avaloniaui.net/controls/input/text-input/maskedtextbox |
| A6 | search field | P | No dedicated search control. `AutoCompleteBox` is the nearest (suggestions, filtering) but carries no search chrome | https://docs.avaloniaui.net/controls/input/text-input/autocompletebox |
| A7 | colour picker | Y | `ColorPicker`, `ColorView`, `ColorSpectrum`, `ColorSlider` (assembly `Avalonia.Controls.ColorPicker`, shipped in the `Avalonia` metapackage) | https://docs.avaloniaui.net/controls/input/selectors/colorpicker |
| A8 | tree view / outline | Y | `TreeView` / `TreeViewItem`; hierarchical-with-columns is `TreeDataGrid` (paid, see A21) | https://docs.avaloniaui.net/controls/data-display/structured-data/treeview |
| A9 | popover | Y | `Popup`, `Flyout` / `MenuFlyout`, `ToolTip`, `ContextMenu`, `OverlayPopupHost` | https://docs.avaloniaui.net/controls/layout/containers/flyout |
| A10 | modal dialog w/ custom content | Y | `Window.ShowDialog<T>(owner)` — a real modal window with arbitrary content; `Avalonia.Labs.Controls.ContentDialog` for an in-window overlay dialog | https://docs.avaloniaui.net/controls/primitives/window |
| A11 | badge | P | Nothing in core. `InfoBadge` lives in the first-party preview package `Avalonia.Labs.Controls` | https://github.com/AvaloniaUI/Avalonia.Labs/tree/main/src/Avalonia.Labs.Controls |
| A12 | hyperlink / rich text / markdown | Y | `HyperlinkButton`, `TextBlock.Inlines` (`Run`, `Bold`, `Italic`, `InlineUIContainer`), `SelectableTextBlock`. Markdown rendering is the paid `Avalonia.Controls.Markdown`; the OSS alternative is `Markdown.Avalonia` | https://docs.avaloniaui.net/controls/data-display/text-display/textblock |
| A13 | activity indicator | Y | `ProgressBar` with `IsIndeterminate="True"` (the Fluent theme draws a distinct indeterminate animation); no separate ring control | https://docs.avaloniaui.net/controls/feedback/progressbar |
| A14 | tooltip | Y | `ToolTip.Tip` attached property (+ `ToolTip.Placement`, `ShowDelay`) | https://docs.avaloniaui.net/controls/feedback/tooltip |
| A15 | date / time pickers | Y | `DatePicker`, `TimePicker`, `CalendarDatePicker`, `Calendar` | https://docs.avaloniaui.net/controls/input/date-and-time/datepicker |
| A16 | slider | Y | `Slider` (`TickBar`, `TickPlacement`, orientation) | https://docs.avaloniaui.net/controls/input/selectors/slider |
| A17 | tabs | Y | `TabControl`, `TabStrip`, `TabbedPage` (navigation-style) | https://docs.avaloniaui.net/controls/navigation/tabcontrol |
| A18 | split view / sidebar-detail | Y | `SplitView` (overlay/inline pane), `GridSplitter` for user-resizable panes, `DrawerPage` | https://docs.avaloniaui.net/controls/layout/containers/splitview |
| A19 | toolbar | Y | `CommandBar` (new in Avalonia 12); `Menu` + `Separator` before that | https://docs.avaloniaui.net/controls/navigation/commandbar |
| A20 | context menu | Y | `ContextMenu` / `Control.ContextFlyout` | https://docs.avaloniaui.net/controls/menus/contextmenu |
| A21 | table / data grid w/ column sorting | Y | `DataGrid` in the separate first-party NuGet **`Avalonia.Controls.DataGrid`** (12.1.2), MIT: "`CanUserSortColumns` … (Default is true.)". Core also has `TableView` (columns, no sorting). `TreeDataGrid` (sorting, filtering, hierarchy) is a PAID Avalonia Pro control | https://docs.avaloniaui.net/controls/data-display/structured-data/datagrid |
| A22 | virtualized lists | Y | `VirtualizingStackPanel` (the default `ListBox` panel), `VirtualizingCarouselPanel`, `ItemsRepeater`, `ILogicalScrollable` | https://docs.avaloniaui.net/controls/data-display/collections/itemsrepeater |
| A23 | webview | P | `NativeWebView` in the first-party `Avalonia.Controls.WebView` package — WebView2 on Windows, WKWebView on macOS/iOS, WPE/WebKitGTK on Linux; **Android is documented as not yet implemented**. OSS alternatives: `WebViewControl-Avalonia`, `Avalonia.CefGlue` | https://docs.avaloniaui.net/controls/web/nativewebview |
| A24 | video player | P | `MediaPlayerControl` / `MediaPlayer` in `Avalonia.Controls.MediaPlayer` — the page states "This control is available as part of Avalonia Pro or higher" (paid). OSS alternative: `LibVLCSharp.Avalonia` | https://docs.avaloniaui.net/controls/media/mediaplayer/ |
| A25 | audio playback | P | Same `Avalonia.Controls.MediaPlayer` (paid Pro). No separate audio API in the OSS core | https://docs.avaloniaui.net/controls/media/mediaplayer/media-playback |
| A26 | map | P | No map control. `Mapsui.Avalonia` (third-party OSS) is the standard answer; the Pro chart pack has choropleth/shape "map charts", which are not an interactive map | https://github.com/Mapsui/Mapsui |
| B1 | local notifications | P | Core has only in-window toasts (`WindowNotificationManager`, `INotificationManager`). Real OS notifications come from the first-party PREVIEW package `Avalonia.Labs.Notifications` (Windows WinRT, macOS/iOS `UNUserNotificationCenter`, Linux freedesktop, Android channels) | https://github.com/AvaloniaUI/Avalonia.Labs/tree/main/src/Avalonia.Labs.Notifications |
| B2 | system tray / status item | Y | `TrayIcon` (+ `TrayIcon.Icons` attached to `Application`, `NativeMenu` for its menu); Windows, macOS status item, Linux StatusNotifierItem | https://docs.avaloniaui.net/controls/navigation/trayicon |
| B3 | dock or taskbar badge | N | No badge/overlay API in the tree (`Window` has `Icon` only) | https://github.com/AvaloniaUI/Avalonia/tree/master/src/Avalonia.Controls |
| B4 | global hotkeys | N | `HotkeyManager` binds a `KeyGesture` inside the app's own top level only; there is no system-wide registration | https://github.com/AvaloniaUI/Avalonia/blob/master/src/Avalonia.Controls/HotkeyManager.cs |
| B5 | window styles (utility, on-top, blurred) | Y | `Window.Topmost`, `SystemDecorations` (None/BorderOnly/Full), `WindowTransparencyLevel` (`Transparent`, `Blur`, `AcrylicBlur`, `Mica`), `ExtendClientAreaToDecorationsHint`, `ExperimentalAcrylicBorder`, `MacOSProperties`/`Win32Properties`/`X11Properties` | https://docs.avaloniaui.net/controls/primitives/window |
| B6 | fullscreen | Y | `Window.WindowState = WindowState.FullScreen` | https://docs.avaloniaui.net/controls/primitives/window |
| B7 | window position/size persistence | N | `Position`, `Width`/`Height` and `WindowStartupLocation` are settable; nothing persists or restores them | https://docs.avaloniaui.net/controls/primitives/window |
| B8 | session / state restoration | N | No state-restoration service; the app serialises and re-applies its own state | https://docs.avaloniaui.net/docs/concepts/application-lifetimes |
| B9 | recent files / security-scoped bookmarks | Y | `IStorageBookmarkItem.SaveBookmarkAsync()` + `IStorageProvider.OpenFileBookmarkAsync()` / `OpenFolderBookmarkAsync()` — the sandbox-bookmark abstraction, implemented on macOS/iOS/Android/browser. No recent-files/jump-list UI | https://github.com/AvaloniaUI/Avalonia/blob/master/src/Avalonia.Base/Platform/Storage/IStorageBookmarkItem.cs |
| B10 | share sheet | N | No share API anywhere in the tree | https://github.com/AvaloniaUI/Avalonia/tree/master/src/Avalonia.Base/Platform/Storage |
| B11 | URL schemes / deep links | Y | `IActivatableApplicationLifetime.Activated` with `ProtocolActivatedEventArgs` (`ActivationKind.OpenUri`); `TopLevel.Launcher` (`ILauncher`) for the outbound direction. The scheme itself is declared in each platform's manifest/installer — there is no registration API | https://github.com/AvaloniaUI/Avalonia/blob/master/src/Avalonia.Controls/ApplicationLifetimes/ProtocolActivatedEventArgs.cs |
| B12 | file type associations | Y | `FileActivatedEventArgs` on the same activatable lifetime (`ActivationKind.File`); registration again lives in the platform manifest/installer | https://github.com/AvaloniaUI/Avalonia/blob/master/src/Avalonia.Controls/ApplicationLifetimes/FileActivatedEventArgs.cs |
| B13 | printing | N | No printing API. The only "print" symbols in the tree are the WebView's own `WebViewPrintSettings` and a macOS interop shim | https://github.com/AvaloniaUI/Avalonia |
| B14 | drag and drop | Y | `DragDrop.DoDragDrop`, `DragDrop.AllowDropProperty`, `DragEventArgs`, `DataObject`/`IDataObject`, `DragDropEffects`; platform impls for Win32, macOS, X11, Wayland | https://github.com/AvaloniaUI/Avalonia/blob/master/src/Avalonia.Base/Input/DragDrop.cs |
| B15 | clipboard | Y | `TopLevel.Clipboard` (`IClipboard`) — text, `DataObject`, formats; per-platform impls incl. Wayland and Android | https://github.com/AvaloniaUI/Avalonia/blob/master/src/Avalonia.Base/Input/Platform/IClipboard.cs |
| B16 | file dialogs | Y | `TopLevel.StorageProvider` (`IStorageProvider`): `OpenFilePickerAsync`, `SaveFilePickerAsync`, `OpenFolderPickerAsync`, `FilePickerFileType`, `WellKnownFolder`; native on every backend, `Avalonia.Dialogs` is the managed fallback | https://github.com/AvaloniaUI/Avalonia/blob/master/src/Avalonia.Base/Platform/Storage/IStorageProvider.cs |
| B17 | menubar (application menu) | Y | `NativeMenu` / `NativeMenuBar` — a genuine macOS system menu bar (and Linux global menu where the shell exports one); `Menu` for the in-window one | https://docs.avaloniaui.net/controls/menus/nativemenu |
| B18 | undo/redo integration | N | No framework undo manager. `TextBox` has its own undo stack; `Avalonia.Labs.CommandManager` gives routed commands, not undo | https://github.com/AvaloniaUI/Avalonia/blob/master/src/Avalonia.Controls/TextBox.cs |
| B19 | launch at login | N | Nothing first-party | https://github.com/AvaloniaUI/Avalonia |
| B20 | background tasks | N | Nothing first-party; a desktop app uses .NET threads, mobile requires platform code | https://github.com/AvaloniaUI/Avalonia |
| B21 | camera / photo picker | N | No camera or photo-library API. `IStorageProvider` opens the document picker, not the photo picker | https://github.com/AvaloniaUI/Avalonia/tree/master/src/Avalonia.Base/Platform/Storage |
| B22 | biometrics / keychain / secure storage | N | Nothing first-party; `WebAuthenticationBroker` exists in the WebView package but is OAuth, not local secrets | https://docs.avaloniaui.net/controls/web/webauthenticationbroker |
| B23 | haptics | Y | `PlatformFeedback` attached property + `InputElement.PerformFeedback(FeedbackAction)`, `FeedbackType.Haptic`/`Sound`/`Auto`; returns false when the platform cannot | https://github.com/AvaloniaUI/Avalonia/blob/master/src/Avalonia.Controls/Platform/PlatformFeedback.cs |
| C1 | localization / string tables | P | No Avalonia-level localization API, XAML directive or string table. Apps use plain .NET `.resx` + `ResourceManager` / `Microsoft.Extensions.Localization` bound from XAML; `IPlatformSettings` does report the OS preferred language as a BCP-47 tag | https://docs.avaloniaui.net/docs/app-development/localizing |
| C2 | RTL layout mirroring | Y | `Visual.FlowDirection` (`LeftToRight`/`RightToLeft`), inherited down the tree, honoured by layout and text | https://github.com/AvaloniaUI/Avalonia/blob/master/src/Avalonia.Base/Media/FlowDirection.cs |
| C3 | plural rules | P | Nothing first-party and nothing in .NET; apps take the `Humanizer` or `SmartFormat.NET` NuGet packages | https://docs.avaloniaui.net/docs/app-development/localizing |
| C4 | date / number formatting | Y | .NET `CultureInfo`/`IFormatProvider` throughout; `NumericUpDown.FormatString`/`NumberFormat`, binding `StringFormat` | https://docs.avaloniaui.net/controls/input/selectors/numericupdown |
| C5 | dynamic type / user font scaling | N | Avalonia scales by display DPI (`RenderScaling`) only. There is no text-scale symbol anywhere in the tree; the OS "make text bigger" preference is not read | https://github.com/AvaloniaUI/Avalonia/blob/master/src/Avalonia.Base/Platform/IPlatformSettings.cs |
| C6 | IME and composition | Y | `TextInputMethodClient` / `ITextInputMethodImpl` with native implementations (macOS `AvnTextInputMethod`, Win32 TSF, X11, Wayland, Android) and `TextBoxTextInputMethodClient` wired into `TextBox` | https://github.com/AvaloniaUI/Avalonia/blob/master/src/Avalonia.Base/Input/TextInput/TextInputMethodClient.cs |
| C7 | spellcheck | N | No spellcheck symbol in the tree; `TextBox` has none | https://github.com/AvaloniaUI/Avalonia/blob/master/src/Avalonia.Controls/TextBox.cs |
| C8 | reduced-motion / high-contrast | P | High contrast is exposed: `PlatformColorValues.ContrastPreference` (`NoPreference`/`High`) from `IPlatformSettings.GetColorValues()`, plus accent colours and theme variant. There is NO reduced-motion signal anywhere in the tree | https://github.com/AvaloniaUI/Avalonia/blob/master/src/Avalonia.Base/Platform/PlatformColorValues.cs |
| D1 | animations / transitions API | Y | `Animation` with `KeyFrame`s (CSS-like, in styles), `Transitions` collection, easings, and the `Avalonia.Rendering.Composition` animation layer (`ExpressionBuilder` in Labs) | https://docs.avaloniaui.net/docs/graphics-animation/animations/keyframe-animations |
| D2 | implicit animation | Y | `Control.Transitions` — set `<DoubleTransition Property="Opacity" .../>` and any change to that property animates with no animator | https://docs.avaloniaui.net/docs/graphics-animation/animations/transitions |
| D3 | scroll-to programmatic | Y | `Control.BringIntoView()`, `ScrollViewer.Offset` / `ScrollToHome`/`ScrollToEnd`, `ItemsControl.ScrollIntoView`, `IScrollAnchorProvider` | https://docs.avaloniaui.net/controls/layout/containers/scrollviewer |
| D4 | horizontal scroll | Y | `ScrollViewer.HorizontalScrollBarVisibility` / `HorizontalSnapPointsType`; horizontal `VirtualizingStackPanel` | https://docs.avaloniaui.net/controls/layout/containers/scrollviewer |
| D5 | pull-to-refresh | Y | `RefreshContainer` + `RefreshVisualizer` (`RefreshRequested`, `RefreshCompletionDeferral`, `ScrollablePullGestureRecognizer`) | https://docs.avaloniaui.net/controls/layout/containers/refreshcontainer |
| D6 | swipe actions on list rows | P | The gesture is core (`SwipeGestureRecognizer`, `SwipeGestureEventArgs`, `SwipeDirection`), but the row-action control (`Swipe`, `SwipeItem`, `SwipeMode`, `OpenSwipeItem`) lives in the first-party preview package `Avalonia.Labs.Controls` | https://github.com/AvaloniaUI/Avalonia.Labs/tree/main/src/Avalonia.Labs.Controls |
| D7 | keyboard focus order / tab traversal | Y | `TabIndex`, `IsTabStop`, `KeyboardNavigation.TabNavigation` (`Continue`/`Cycle`/`Contained`/`Once`/`None`), `FocusManager` | https://docs.avaloniaui.net/docs/concepts/input/focus |
| D8 | adaptive layout | N | No `VisualStateManager`, no `AdaptiveTrigger`, no size classes — apps bind to `Bounds`/`Width` and toggle style classes or swap `DataTemplate`s by hand | https://github.com/AvaloniaUI/Avalonia |
| E1 | hot reload | P | Hot Reload is a PAID subscription component: the docs require "a valid Avalonia license key that includes access to `AvaloniaUI.DiagnosticsSupport.HotReload`". There is no free XAML hot reload; the free previewer only re-renders on build | https://docs.avaloniaui.net/tools/hot-reload/ |
| E2 | inspector / devtools | P | The free `Avalonia.Diagnostics` DevTools (F12) stops at 11.3.20 — it is gone from the v12 source tree and has no 12.x release. In v12 the inspector is the paid `AvaloniaUI.DiagnosticsSupport` "Developer Tools" (Plus tier) | https://docs.avaloniaui.net/tools/developer-tools/attaching-applications |
| E3 | testing / UI-driving harness | Y | `Avalonia.Headless` platform + `Avalonia.Headless.XUnit` / `Avalonia.Headless.NUnit` attributes (drive clicks, keys, capture frames), `Avalonia.Headless.Vnc`, plus a documented Appium route for real UI tests | https://docs.avaloniaui.net/docs/testing/ |
| E4 | packaging / signing / distribution | Y | Per-platform deployment docs (macOS `.app`+notarisation, Linux, Android, iOS, WebAssembly, Docker, NativeAOT) over `dotnet publish`; the one-command installer builder `Parcel` is a paid Plus-tier tool | https://docs.avaloniaui.net/docs/deployment/macos |
| E5 | auto-update | P | Nothing first-party. Apps use `Velopack` (the usual choice), `NetSparkle` or `Squirrel` | https://github.com/velopack/velopack |

Notes:
- **Version drift matters here.** The prompt said v11; the current stable is **12.1.2 (2026-09-02)**, and v12 both ADDED controls (`CommandBar`, `TableView`, `NativeWebView`, `MediaPlayer`, `Markdown`, navigation `*Page` controls) and MOVED things behind a licence.
- **The paid line is the biggest surprise.** Per https://avaloniaui.net/pricing: base framework MIT and free; **Plus** (€299/seat/yr) = DevTools, Hot Reload, Parcel packaging, IDE extensions; **Pro** (€899) = the premium controls; **Enterprise** (€6,999) = source. `TreeDataGrid` and `MediaPlayer` doc pages carry "This control is available as part of Avalonia Pro or higher". `DataGrid` does not — it stays free.
- The free-forever inspector story regressed: `Avalonia.Diagnostics` has no 12.x package and is absent from the v12 repo.
- System integration is where Avalonia is thinnest against a native toolkit: no printing, no share sheet, no camera, no biometrics/secure storage, no launch-at-login, no background tasks, no OS notifications outside a preview package.
- `Avalonia.Labs` (AvaloniaUI's own incubator repo) carries several things the core lacks — OS notifications, `Swipe`, `InfoBadge`, `ContentDialog`, Lottie, GIF, `FlexPanel`, QR — and is explicitly preview-quality.
- Avalonia has real a11y backends (UIA on Windows, NSAccessibility on macOS, AT-SPI on X11/Wayland) with per-control `AutomationPeer`s, which is unusual for a self-drawing toolkit.

OFF-LIST (prominent Avalonia things the 70 IDs do not name):
- `Avalonia.Headless.Vnc` — run the whole UI over VNC with no display server.
- Navigation stack as controls: `NavigationPage`, `ContentPage`, `TabbedPage`, `DrawerPage`, `CarouselPage` with page transitions.
- `NativeControlHost` / `Win32Properties` / `MacOSProperties` / `X11Properties` — embed native handles and reach the platform window.
- Styles-as-CSS: selector-based `Style`/`ControlTheme` with pseudo-classes (`:pointerover`, `:pressed`), not WPF triggers.
- `Avalonia.Rendering.Composition` — a retained composition layer with `ExpressionBuilder` (Labs) for GPU-side animation.
- 130+ chart types as a first-party (paid) control pack, including flame graphs, Sankey, Smith and Gantt.
- WebAssembly and Linux-framebuffer/embedded as shipped targets alongside desktop and mobile.
- `Avalonia XPF` — a separate commercial product that runs unmodified WPF apps on macOS/Linux.

---

## Uno Platform (6.x)

A cross-platform re-implementation of the WinUI 3 / Windows App SDK API surface (`Microsoft.UI.Xaml` + a large slice of WinRT) for iOS, Android, macOS, Linux (Skia desktop: X11/Wayland/framebuffer), WebAssembly and tvOS — on Windows it hands through to real WinUI. So its control answers largely track WinUI's, and the interesting column is per-platform coverage.
Doc roots: https://platform.uno/docs/articles/implemented-views.html , https://platform.uno/docs/articles/intro.html

| ID | Feature | Verdict | Framework's own name for it | Source |
|----|---------|---------|------------------------------|--------|
| A1 | toggle switch | Y | `ToggleSwitch` (WASM, Skia, mobile) | https://platform.uno/docs/articles/implemented-views.html |
| A2 | segmented control | P | Not the WinUI `SelectorBar`; the segmented idiom comes from `TabBar` in the separate `Uno.Toolkit.UI` package (Material/Cupertino themes) | https://platform.uno/docs/articles/Uno.UI.Toolkit.html |
| A3 | stepper (+/-) | Y | `NumberBox` with spin buttons | https://platform.uno/docs/articles/implemented-views.html |
| A4 | secure / password entry | Y | `PasswordBox` | https://platform.uno/docs/articles/implemented-views.html |
| A5 | number / formatted field w/ validation | Y | `NumberBox` (`NumberFormatter`, `ValidationMode`); `Uno.Extensions.Validation` for model validation | https://platform.uno/docs/articles/implemented-views.html |
| A6 | search field | Y | `AutoSuggestBox` | https://platform.uno/docs/articles/implemented-views.html |
| A7 | colour picker | Y | `ColorPicker` | https://platform.uno/docs/articles/implemented-views.html |
| A8 | tree view / outline | Y | `TreeView` | https://platform.uno/docs/articles/implemented-views.html |
| A9 | popover | Y | `Flyout`, `Popup`, `TeachingTip` | https://platform.uno/docs/articles/implemented-views.html |
| A10 | modal dialog w/ custom content | Y | `ContentDialog` (also `MessageDialog`) | https://platform.uno/docs/articles/features/dialogs.html |
| A11 | badge | Y | `InfoBadge` | https://platform.uno/docs/articles/implemented-views.html |
| A12 | hyperlink / rich text / markdown | Y | `HyperlinkButton`, `RichTextBlock`, `RichEditBox`, `TextBlock` inlines. No markdown renderer — third-party | https://platform.uno/docs/articles/implemented-views.html |
| A13 | activity indicator | Y | `ProgressRing` (has its own feature page; indeterminate Lottie/native variants per platform) | https://platform.uno/docs/articles/features/progressring.html |
| A14 | tooltip | Y | `ToolTip` / `ToolTipService` | https://platform.uno/docs/articles/implemented-views.html |
| A15 | date / time pickers | Y | `DatePicker`, `TimePicker`, `CalendarDatePicker`, `CalendarView` (native pickers on mobile) | https://platform.uno/docs/articles/controls/DatePicker.html |
| A16 | slider | Y | `Slider` | https://platform.uno/docs/articles/implemented-views.html |
| A17 | tabs | Y | `TabView`, `Pivot`; `TabBar`/`TabBarItem` in `Uno.Toolkit.UI` | https://platform.uno/docs/articles/implemented-views.html |
| A18 | split view / sidebar-detail | Y | `SplitView`, `NavigationView`, `TwoPaneView` | https://platform.uno/docs/articles/implemented-views.html |
| A19 | toolbar | Y | `CommandBar` (renders as the native navigation/action bar on iOS and Android), `AppBarButton` | https://platform.uno/docs/articles/implemented-views.html |
| A20 | context menu | Y | `MenuFlyout` (`MenuFlyoutItem`, `MenuFlyoutSubItem`, `MenuFlyoutSeparator`), `ContextFlyout` | https://platform.uno/docs/articles/implemented-views.html |
| A21 | table / data grid w/ column sorting | P | No first-party grid (same hole as WinUI). The community port `Uno.Microsoft.Toolkit.Uwp.UI.Controls.DataGrid` (7.1.11) is the usual answer | https://www.nuget.org/packages/Uno.Microsoft.Toolkit.Uwp.UI.Controls.DataGrid |
| A22 | virtualized lists | Y | `ListView`/`GridView` with virtualizing panels, `ItemsRepeater` | https://platform.uno/docs/articles/implemented-views.html |
| A23 | webview | P | `WebView2` — the implemented-views matrix lists Android, iOS, tvOS and WASM (plus Windows via WinUI); it is not listed for Skia desktop/macOS | https://platform.uno/docs/articles/implemented-views.html |
| A24 | video player | Y | `MediaPlayerElement` (WASM, Skia, mobile) | https://platform.uno/docs/articles/implemented-views.html |
| A25 | audio playback | Y | `MediaPlayer` / `MediaPlayerElement`; `Windows.Media.Playback` shims | https://platform.uno/docs/articles/implemented-views.html |
| A26 | map | N | `MapControl` is listed under "Not yet implemented" | https://platform.uno/docs/articles/implemented-views.html |
| B1 | local notifications | P | The `Windows.UI.Notifications` page documents BADGE notifications only (iOS, tvOS, macOS). The full toast/local-notification stack is Windows-only via WinUI passthrough; elsewhere apps take a plugin | https://platform.uno/docs/articles/features/windows-ui-notifications.html |
| B2 | system tray / status item | N | No tray/status-item API documented for Skia desktop or macOS | https://platform.uno/docs/articles/features/ |
| B3 | dock or taskbar badge | Y | `BadgeUpdateManager` — "Badge notifications are supported on iOS, tvOS, and macOS" (macOS numeric + textual, iOS/tvOS numeric, permission required), plus Windows | https://platform.uno/docs/articles/features/windows-ui-notifications.html |
| B4 | global hotkeys | N | Nothing documented | https://platform.uno/docs/articles/features/ |
| B5 | window styles (utility, on-top, blurred) | P | `SystemBackdrop` (Mica/Acrylic) has a feature page and `Window`/`AppWindow` are implemented, but presenter coverage (always-on-top, borderless) is per-target and not uniformly documented | https://platform.uno/docs/articles/features/system-backdrop.html |
| B6 | fullscreen | Y | `AppWindow` full-screen presenter / `ApplicationView.TryEnterFullScreenMode` | https://platform.uno/docs/articles/features/windows-ui-xaml-window.html |
| B7 | window position/size persistence | N | Nothing persists window geometry | https://platform.uno/docs/articles/features/windows-ui-xaml-window.html |
| B8 | session / state restoration | N | No state-restoration service; `ApplicationData` gives you a place to write it yourself | https://platform.uno/docs/articles/features/applicationdata.html |
| B9 | recent files / bookmarks | P | `Windows.UI.StartScreen` (JumpList/SecondaryTile) and `ApplicationData` are implemented; there is no cross-platform security-scoped-bookmark story | https://platform.uno/docs/articles/features/windows-ui-startscreen.html |
| B10 | share sheet | P | `DataTransferManager.ShowShareUI()` with `DataPackage` — Android, iOS, macOS, WASM, Tizen; text and Uri only, **File sharing is ✖ on every platform** | https://platform.uno/docs/articles/features/windows-applicationmodel-datatransfer.html |
| B11 | URL schemes / deep links | Y | Protocol activation (`OnActivated` with `ProtocolActivatedEventArgs`); a dedicated page covers registration per target | https://platform.uno/docs/articles/features/protocol-activation.html |
| B12 | file type associations | ? | No file-association documentation found; `FileActivatedEventArgs` support across targets could not be established | https://platform.uno/docs/articles/features/ |
| B13 | printing | N | No printing API documented on any target | https://platform.uno/docs/articles/features/ |
| B14 | drag and drop | Y | Full XAML drag/drop implementation in `Uno.UI` (`DragDropManager`, `DragStartingEventArgs`, `DragUI`/`DragUIOverride`, `DropUITarget`, `DropCompletedEventArgs`) | https://github.com/unoplatform/uno/tree/master/src/Uno.UI/UI/Xaml/DragDrop |
| B15 | clipboard | Y | `Windows.ApplicationModel.DataTransfer.Clipboard` with a per-platform support page | https://platform.uno/docs/articles/features/clipboard.html |
| B16 | file dialogs | Y | `Windows.Storage.Pickers` (`FileOpenPicker`, `FileSavePicker`, `FolderPicker`) mapped to each platform's native picker | https://platform.uno/docs/articles/features/windows-storage-pickers.html |
| B17 | menubar (application menu) | P | `MenuBar` is implemented as an in-window control; no native macOS application-menu export is documented for the Skia macOS head | https://platform.uno/docs/articles/implemented-views.html |
| B18 | undo/redo integration | N | No framework undo manager (inherits WinUI's gap); text controls only | https://platform.uno/docs/articles/implemented-views.html |
| B19 | launch at login | N | Nothing documented | https://platform.uno/docs/articles/features/ |
| B20 | background tasks | N | No background-task scheduling API; the "background worker" sample is just a .NET thread | https://platform.uno/docs/articles/features/ |
| B21 | camera / photo picker | Y | `Windows.Media.Capture` (`CameraCaptureUI`) plus `FileOpenPicker` for the photo library | https://platform.uno/docs/articles/features/windows-media-capture.html |
| B22 | biometrics / keychain / secure storage | P | `Windows.Security.Credentials.PasswordVault` is implemented (keychain/keystore backed); no biometric-prompt API (`UserConsentVerifier`/`KeyCredentialManager`) is documented | https://platform.uno/docs/articles/features/PasswordVault.html |
| B23 | haptics | Y | `Windows.Devices.Haptics` (`VibrationDevice`, `SimpleHapticsController`) with its own feature page | https://platform.uno/docs/articles/features/windows-devices-haptics.html |
| C1 | localization / string tables | Y | `.resw` + `x:Uid` (`working-with-strings`) and `Uno.Extensions.Localization` for runtime culture switching | https://platform.uno/docs/articles/features/working-with-strings.html |
| C2 | RTL layout mirroring | Y | `FrameworkElement.FlowDirection` (inherited from the WinUI surface Uno implements) | https://platform.uno/docs/articles/implemented-views.html |
| C3 | plural rules | P | Nothing first-party; `Humanizer`/`SmartFormat.NET` as on any .NET stack | https://platform.uno/docs/articles/features/working-with-strings.html |
| C4 | date / number formatting | Y | .NET `CultureInfo` plus the `Windows.Globalization` shims | https://platform.uno/docs/articles/guides/localization.html |
| C5 | dynamic type / user font scaling | ? | No text-scale-factor documentation found; could not establish whether `UISettings.TextScaleFactor` is honoured on non-Windows heads | https://platform.uno/docs/articles/features/windows-ui-viewmanagement.html |
| C6 | IME and composition | P | Mobile and WASM heads use the platform's own text input (so IME works there); the Skia desktop text stack's composition support is not documented as complete | https://platform.uno/docs/articles/features/pointers-keyboard-and-other-user-inputs.html |
| C7 | spellcheck | Y | `TextBox.IsSpellCheckEnabled`, with a dedicated per-platform feature page | https://platform.uno/docs/articles/features/spellchecking.html |
| C8 | reduced-motion / high-contrast | ? | Themes and dark/light are documented; no high-contrast or reduced-motion signal could be established | https://platform.uno/docs/articles/features/working-with-themes.html |
| D1 | animations / transitions API | Y | XAML `Storyboard` animations (with a page on native vs non-native animation), plus Lottie via `Uno.Lottie` | https://platform.uno/docs/articles/features/working-with-animations.html |
| D2 | implicit animation | P | Theme transitions and `Transitions` exist in the surface but are only partially implemented outside Windows; verify per target | https://platform.uno/docs/articles/implemented-views.html |
| D3 | scroll-to programmatic | Y | `ScrollViewer.ChangeView`, `ListViewBase.ScrollIntoView`, `StartBringIntoView` | https://platform.uno/docs/articles/implemented-views.html |
| D4 | horizontal scroll | Y | `ScrollViewer` horizontal modes; horizontal `ItemsRepeater`/`GridView` layouts | https://platform.uno/docs/articles/implemented-views.html |
| D5 | pull-to-refresh | Y | `RefreshContainer` / `RefreshVisualizer` (native on Android/iOS) | https://platform.uno/docs/articles/implemented-views.html |
| D6 | swipe actions on list rows | Y | `SwipeControl` / `SwipeItems` | https://platform.uno/docs/articles/implemented-views.html |
| D7 | keyboard focus order / tab traversal | Y | `TabIndex`, `IsTabStop`, `FocusManager`, with a focus-management feature page | https://platform.uno/docs/articles/features/focus-management.html |
| D8 | adaptive layout | Y | `AdaptiveTrigger` + `VisualStateManager` (own feature page); `Uno.Toolkit.UI` `ResponsiveView`/`ResponsiveExtension` | https://platform.uno/docs/articles/features/AdaptiveTrigger.html |
| E1 | hot reload | Y | XAML **and** C# Hot Reload across all targets (Uno Platform Studio), documented as a first-class feature | https://platform.uno/docs/articles/features/working-with-xaml-hot-reload.html |
| E2 | inspector / devtools | Y | **Hot Design** — a runtime visual designer/inspector that turns the running app into a designer, in VS, VS Code and Rider on any OS. Requires signing in with an Uno Platform account (Studio licensing); not available for the WinAppSDK head | https://platform.uno/docs/articles/studio/Hot%20Design/hot-design-overview.html |
| E3 | testing / UI-driving harness | Y | `Uno.UITest` (a Xamarin.UITest-compatible driver over Android/iOS/WASM), plus a Skia headless host for automated runs | https://platform.uno/docs/articles/external/uno.uitest/doc/using-uno-uitest.html |
| E4 | packaging / signing / distribution | Y | Per-target publishing docs: Android, iOS, WebAssembly, desktop (macOS `.app`/notarisation, Linux, Windows packaged-signed / packaged-unsigned / unpackaged) | https://platform.uno/docs/articles/uno-publishing-overview.html |
| E5 | auto-update | N | No auto-update mechanism documented; store channels or a third-party updater | https://platform.uno/docs/articles/uno-publishing-overview.html |

Notes:
- Uno's verdicts are best read as "WinUI's answer, minus the platforms where the shim is missing". The control layer is remarkably complete; the system-integration layer is where holes appear, and they are per-head rather than global.
- The two flat gaps against WinUI are `MapControl` (explicitly "not yet implemented") and the DataGrid, which WinUI itself does not have.
- Share is the sharpest partial: `DataTransferManager` works, but the docs' own table marks File sharing unsupported on every platform.
- Notifications are the other one: only BADGE notifications are documented outside Windows.
- Three rows are `?` (B12 file associations, C5 text scaling, C8 high contrast / reduced motion) — the docs did not settle them and guessing would be worse.
- Windows is a passthrough head: on Windows an Uno app IS a WinUI 3 app, so anything in the WinUI table above is reachable there through the same WinRT APIs.

OFF-LIST (prominent Uno things the 70 IDs do not name):
- Hot Design — a runtime visual designer that edits the live running app, IDE-agnostic; nothing else here has one.
- Uno.Extensions — a whole app framework beside the UI: Navigation, MVUX, DI, Configuration, Authentication (OIDC/MSAL/Web), HTTP, Serialization.
- Uno Toolkit (`Uno.Toolkit.UI`): `NavigationBar`, `TabBar`, `Chip`, `Card`, `Divider`, `DrawerControl`, `AutoLayout`, `ResponsiveView`, `ExtendedSplashScreen`.
- Uno Themes: Material 3 and Cupertino design systems as drop-in resource dictionaries, plus a Figma plugin that generates them.
- C# Markup — declare the whole UI in C# instead of XAML, with a source-generated fluent API.
- A deep sensor surface as WinRT shims: accelerometer, gyrometer, compass, barometer, magnetometer, proximity, light, step counter, flashlight, MIDI, gamepad.
- Non-desktop heads shipped as first-class targets: WebAssembly, Linux framebuffer, Android TV / Auto / Wear, tvOS.
- `using-skia-hosting-native-controls` and native-rendering mode — mix real platform views into the Skia-drawn tree.

---

## .NET MAUI

Microsoft's XAML/C# cross-platform UI framework; one project targets Android, iOS,
macOS (Mac Catalyst) and Windows (WinUI 3) — plus Tizen (community).
Docs: https://learn.microsoft.com/dotnet/maui/ — controls index
`user-interface/controls/`, device APIs (the old Xamarin.Essentials) `platform-integration/`.

| ID | Feature | Verdict | Framework's own name for it | Source |
|----|---------|---------|------------------------------|--------|
| A1 | toggle switch | Y | `Switch` (separate from `CheckBox`) | https://learn.microsoft.com/en-us/dotnet/maui/user-interface/controls/switch |
| A2 | segmented control | P | nothing in MAUI or CommunityToolkit.Maui; Syncfusion **Segmented Control** (`SfSegmentedControl`), Telerik `RadSegmentedControl` | https://www.syncfusion.com/maui-controls |
| A3 | stepper | Y | `Stepper` | https://learn.microsoft.com/en-us/dotnet/maui/user-interface/controls/stepper |
| A4 | secure / password entry | Y | `Entry.IsPassword` | https://learn.microsoft.com/en-us/dotnet/maui/user-interface/controls/entry |
| A5 | number / formatted field + validation | P | core has only `Entry.Keyboard="Numeric"`; masking and validation are **CommunityToolkit.Maui** `MaskedBehavior`, `NumericValidationBehavior`, `TextValidationBehavior`, `MultiValidationBehavior`; Syncfusion `SfNumericEntry`/`SfMaskedEntry` | https://learn.microsoft.com/en-us/dotnet/communitytoolkit/maui/behaviors/masked-behavior |
| A6 | search field | Y | `SearchBar`; Shell's `SearchHandler` | https://learn.microsoft.com/en-us/dotnet/maui/user-interface/controls/searchbar |
| A7 | colour picker | P | none in MAUI or CommunityToolkit.Maui; Syncfusion **Color Picker** | https://www.syncfusion.com/maui-controls |
| A8 | tree view / outline | P | none in core; Syncfusion `SfTreeView`, Telerik `RadTreeView`, DevExpress | https://www.syncfusion.com/maui-controls |
| A9 | popover | P | **CommunityToolkit.Maui** `Popup` + `IPopupService`; core has only `DisplayAlert`/`DisplayActionSheet`/`DisplayPromptAsync`. iOS-only platform-specific renders a modal page as a popover | https://learn.microsoft.com/en-us/dotnet/communitytoolkit/maui/views/popup |
| A10 | sheet / custom-content modal | Y | `Navigation.PushModalAsync`, `Page.ModalPresentationStyle` (iOS/Mac Catalyst platform-specific) | https://learn.microsoft.com/en-us/dotnet/maui/ios/platform-specifics/page-presentation-style |
| A11 | badge (count/dot on a control or tab) | P | no control badge and no Shell tab badge in core; Syncfusion `SfBadgeView`. (CommunityToolkit's `Badge` is the *app icon* badge — see B3) | https://www.syncfusion.com/maui-controls |
| A12 | hyperlink / attributed text / markdown | Y | `Label.FormattedText` with `Span` (`TextDecorations`, per-span `GestureRecognizers`). Markdown itself is P — Syncfusion **Markdown Viewer** | https://learn.microsoft.com/en-us/dotnet/maui/user-interface/controls/label |
| A13 | activity indicator | Y | `ActivityIndicator` (distinct type from `ProgressBar`) | https://learn.microsoft.com/en-us/dotnet/maui/user-interface/controls/activityindicator |
| A14 | tooltip | Y | `ToolTipProperties.Text` attached property. All 4 targets, but: Android shows it on long-press; iOS only when the app runs on an Apple-silicon Mac; placement is not configurable | https://learn.microsoft.com/en-us/dotnet/maui/user-interface/tooltips |
| A15 | date / time pickers | Y | `DatePicker`, `TimePicker` (native pickers) | https://learn.microsoft.com/en-us/dotnet/maui/user-interface/controls/datepicker |
| A16 | slider | Y | `Slider` | https://learn.microsoft.com/en-us/dotnet/maui/user-interface/controls/slider |
| A17 | tabs | Y | `TabbedPage`; Shell `Tab`/`TabBar` | https://learn.microsoft.com/en-us/dotnet/maui/user-interface/pages/tabbedpage |
| A18 | split view / resizable panes | P | `FlyoutPage` (sidebar+detail, **not** user-resizable) and `TwoPaneView` (foldable-device container, no draggable splitter). No resizable-splitter control | https://learn.microsoft.com/en-us/dotnet/maui/user-interface/controls/twopaneview |
| A19 | toolbar | Y | `Page.ToolbarItems` / `ToolbarItem`; Syncfusion has a standalone `SfToolbar` | https://learn.microsoft.com/en-us/dotnet/maui/user-interface/toolbaritem |
| A20 | context menu | P | `MenuFlyout` on `FlyoutBase.ContextFlyout` — **Mac Catalyst and Windows only**, nothing on Android/iOS; items also cannot be added/removed at runtime, and it is unsupported on `Entry` on Mac Catalyst | https://learn.microsoft.com/en-us/dotnet/maui/user-interface/context-menu |
| A21 | table / data grid with column sorting | P | `TableView` is a static settings-style list and `CollectionView` has no columns; grids are Syncfusion `SfDataGrid`, Telerik `RadDataGrid`, DevExpress `DXDataGrid` | https://www.syncfusion.com/maui-controls |
| A22 | virtualized (recycling) lists | Y | `CollectionView` (`ItemsUpdatingScrollMode`, `RemainingItemsThreshold`), `ListView`, `CarouselView` | https://learn.microsoft.com/en-us/dotnet/maui/user-interface/controls/collectionview/ |
| A23 | webview | Y | `WebView`; also `HybridWebView` (C#/JS bridge) and `BlazorWebView` | https://learn.microsoft.com/en-us/dotnet/maui/user-interface/controls/webview |
| A24 | video player | P | **CommunityToolkit.Maui.MediaElement** `MediaElement` | https://learn.microsoft.com/en-us/dotnet/communitytoolkit/maui/views/mediaelement |
| A25 | audio playback | P | same `MediaElement`; `Plugin.Maui.Audio` for effects/recording. `TextToSpeech` is first-party but is not playback | https://learn.microsoft.com/en-us/dotnet/communitytoolkit/maui/views/mediaelement |
| A26 | map | Y | `Map` in the first-party **Microsoft.Maui.Controls.Maps** NuGet. Windows only from .NET MAUI 10 (WinUI `MapControl` + an Azure Maps key); on MAUI 9 and earlier Windows is unsupported and needs `CommunityToolkit.Maui.Maps` | https://learn.microsoft.com/en-us/dotnet/maui/user-interface/controls/map |
| B1 | local notifications | P | **no cross-platform API**. Microsoft's own doc is a per-platform native recipe behind a hand-written `INotificationManagerService`; `Plugin.LocalNotification` is the usual package | https://learn.microsoft.com/en-us/dotnet/maui/platform-integration/local-notifications |
| B2 | system tray / status item / menu bar extra | N | nothing in MAUI on Windows or Mac Catalyst; not in the docs at all | https://learn.microsoft.com/en-us/dotnet/maui/platform-integration/ |
| B3 | dock / taskbar badge | P | **CommunityToolkit.Maui** `Badge` API sets the app icon badge count (Android, iOS, Mac Catalyst, Windows, Tizen) | https://learn.microsoft.com/en-us/dotnet/communitytoolkit/maui/essentials/badge |
| B4 | global hotkeys | N | `KeyboardAccelerator` exists but is scoped to menu items inside the app, not system-wide | https://learn.microsoft.com/en-us/dotnet/maui/user-interface/keyboard-accelerators |
| B5 | window styles (utility, always-on-top, transparent) | P | `Window` exposes only `X`/`Y`/`Width`/`Height` (Windows), `Minimum*`/`Maximum*` (desktop), `Title`, `Overlays`, and `TitleBar` for a custom caption. No always-on-top, transparency, blur or panel style — native code per platform | https://learn.microsoft.com/en-us/dotnet/maui/user-interface/controls/window |
| B6 | fullscreen | N | no fullscreen API on `Window` or `Page`; Windows/Mac Catalyst need native code | https://learn.microsoft.com/en-us/dotnet/maui/user-interface/controls/window |
| B7 | window position/size persistence | P | `Window.X/Y/Width/Height` are settable (Windows only) so you can restore geometry by hand; nothing saves or restores it for you | https://learn.microsoft.com/en-us/dotnet/maui/user-interface/controls/window |
| B8 | session / state restoration | P | `Window.Backgrounding` + `BackgroundingEventArgs.State`, returned via `IActivationState` in `CreateWindow` — **iOS and Mac Catalyst only**, and string state only | https://learn.microsoft.com/en-us/dotnet/maui/user-interface/controls/window |
| B9 | recent files / security-scoped bookmarks | N | `FilePicker` returns a `FileResult` for one session; no bookmark or recent-documents API | https://learn.microsoft.com/en-us/dotnet/maui/platform-integration/storage/file-picker |
| B10 | share sheet | Y | `Share.RequestAsync` (`ShareTextRequest`, `ShareFileRequest`, `ShareMultipleFilesRequest`) | https://learn.microsoft.com/en-us/dotnet/maui/platform-integration/data/share |
| B11 | URL schemes / deep links / universal links | Y | Android App Links, Apple Universal Links, plus `Launcher.OpenAsync` and `AppLinks` | https://learn.microsoft.com/en-us/dotnet/maui/android/app-links |
| B12 | file type associations | N | no MAUI API or doc; you hand-edit `Package.appxmanifest` / `Info.plist` / the Android manifest per platform | https://learn.microsoft.com/en-us/dotnet/maui/platform-integration/ |
| B13 | printing | N | no printing API anywhere in MAUI or CommunityToolkit.Maui | https://learn.microsoft.com/en-us/dotnet/maui/platform-integration/ |
| B14 | drag and drop | Y | `DragGestureRecognizer` / `DropGestureRecognizer` (`DragStarting`, `DragOver`, `Drop`, `DropCompleted`) | https://learn.microsoft.com/en-us/dotnet/maui/fundamentals/gestures/drag-and-drop |
| B15 | clipboard | Y | `Clipboard.SetTextAsync` / `GetTextAsync` / `HasText` / `ClipboardContentChanged` (text only) | https://learn.microsoft.com/en-us/dotnet/maui/platform-integration/data/clipboard |
| B16 | file dialogs | P | open is first-party (`FilePicker.PickAsync`/`PickMultipleAsync`); **save and folder dialogs are not** — CommunityToolkit.Maui `FileSaver` and `FolderPicker` | https://learn.microsoft.com/en-us/dotnet/communitytoolkit/maui/essentials/file-saver |
| B17 | menubar (application menu) | Y | `Window.MenuBarItems` / `MenuBarItem` with `MenuFlyoutItem`s and `KeyboardAccelerator`s — Mac Catalyst and Windows (the only targets with the concept) | https://learn.microsoft.com/en-us/dotnet/maui/user-interface/menu-bar |
| B18 | undo/redo integration | N | no undo manager; `Entry`/`Editor` inherit only whatever the native text control does | https://learn.microsoft.com/en-us/dotnet/maui/user-interface/controls/ |
| B19 | launch at login | N | no API | https://learn.microsoft.com/en-us/dotnet/maui/platform-integration/ |
| B20 | background tasks | P | no first-party API; `Shiny.Jobs` (Shiny.NET) is the usual package, otherwise WorkManager / `BGTaskScheduler` through platform code | https://learn.microsoft.com/en-us/dotnet/maui/platform-integration/invoke-platform-code |
| B21 | camera / photo picker | Y | `MediaPicker.PickPhotoAsync`, `CapturePhotoAsync`, `PickVideoAsync`, `CaptureVideoAsync`. An in-app camera *preview* is CommunityToolkit.Maui `CameraView` | https://learn.microsoft.com/en-us/dotnet/maui/platform-integration/device-media/picker |
| B22 | biometrics / keychain / secure storage | P | `SecureStorage` is first-party on all four targets (Keychain / Keystore / DPAPI). **Biometric auth has no API** — `Plugin.Fingerprint` or native Face ID / Windows Hello. MAUI 11 adds `Passkeys` (WebAuthn/FIDO2), which is adjacent but not local biometric gating | https://learn.microsoft.com/en-us/dotnet/maui/platform-integration/storage/secure-storage |
| B23 | haptics | Y | `HapticFeedback.Perform(HapticFeedbackType.Click/LongPress)` and `Vibration.Vibrate` | https://learn.microsoft.com/en-us/dotnet/maui/platform-integration/device/haptic-feedback |
| C1 | localization / string tables | Y | .NET `.resx` resource files with a generated `AppResources` class; per-platform app-name and image localization documented | https://learn.microsoft.com/en-us/dotnet/maui/fundamentals/localization |
| C2 | RTL layout mirroring | Y | `Window.FlowDirection` / `VisualElement.FlowDirection` (`MatchParent`, `LeftToRight`, `RightToLeft`); apps follow the device locale automatically | https://learn.microsoft.com/en-us/dotnet/maui/fundamentals/localization#right-to-left-localization |
| C3 | plural rules | P | `.resx` has no plural forms and .NET ships no CLDR plural API; SmartFormat.NET's `PluralLocalizationFormatter` or Humanizer | https://learn.microsoft.com/en-us/dotnet/maui/fundamentals/localization |
| C4 | date / number formatting | Y | `System.Globalization` / `CultureInfo`, and `StringFormat` inside bindings | https://learn.microsoft.com/en-us/dotnet/maui/fundamentals/data-binding/string-formatting |
| C5 | dynamic type / user font scaling | Y | `FontAutoScalingEnabled` on every text control, **default true** | https://learn.microsoft.com/en-us/dotnet/maui/user-interface/fonts#disable-font-auto-scaling |
| C6 | IME and composition | Y | native `Entry`/`Editor` handle composition; Android `Entry` IME options are exposed as a platform-specific | https://learn.microsoft.com/en-us/dotnet/maui/android/platform-specifics/entry-ime-options |
| C7 | spellcheck | Y | `InputView.IsSpellCheckEnabled` on `Entry`/`Editor`; Windows adds a `SearchBar` spell-check platform-specific | https://learn.microsoft.com/en-us/dotnet/maui/windows/platform-specifics/searchbar-spell-check |
| C8 | reduced-motion / high-contrast honouring | P | no API to query either. The accessibility checklist only says to *test* under large fonts and high contrast; reading `UIAccessibility.IsReduceMotionEnabled` or `AccessibilitySettings.HighContrast` means platform code | https://learn.microsoft.com/en-us/dotnet/maui/fundamentals/accessibility |
| D1 | animations / transitions API | Y | `ViewExtensions` (`FadeTo`, `TranslateTo`, `RotateTo`, `ScaleTo`, `RelScaleTo`…), the `Animation` class for custom/compound animations, `Easing` | https://learn.microsoft.com/en-us/dotnet/maui/user-interface/animation/basic |
| D2 | implicit animation | N | all animation is explicit and awaited; `VisualStateManager` swaps property values without tweening. `EnterActions`/`ExitActions` on triggers still call an explicit animation | https://learn.microsoft.com/en-us/dotnet/maui/user-interface/visual-states |
| D3 | scroll-to programmatic | Y | `ScrollView.ScrollToAsync`, `CollectionView.ScrollTo(index/item, position, animate)`, `CarouselView.ScrollTo` | https://learn.microsoft.com/en-us/dotnet/maui/user-interface/controls/collectionview/scrolling |
| D4 | horizontal scroll | Y | `ScrollView.Orientation`, `LinearItemsLayout(ItemsLayoutOrientation.Horizontal)` on `CollectionView` | https://learn.microsoft.com/en-us/dotnet/maui/user-interface/controls/collectionview/layout |
| D5 | pull-to-refresh | Y | `RefreshView` (`IsRefreshing`, `Command`); Windows adds a pull-direction platform-specific | https://learn.microsoft.com/en-us/dotnet/maui/user-interface/controls/refreshview |
| D6 | swipe actions on list rows | Y | `SwipeView` with `SwipeItems` on any of four `SwipeDirection`s | https://learn.microsoft.com/en-us/dotnet/maui/user-interface/controls/swipeview |
| D7 | keyboard focus order / tab traversal | Y | `VisualElement.TabIndex`, `IsTabStop`, `Focus()`/`Unfocus()`; Windows access keys as a platform-specific | https://learn.microsoft.com/en-us/dotnet/maui/windows/platform-specifics/visualelement-access-keys |
| D8 | adaptive layout | Y | `AdaptiveTrigger` (`MinWindowWidth`/`MinWindowHeight`) inside `VisualState.StateTriggers`, plus `OnIdiom`/`OnPlatform` markup and `DeviceStateTrigger`/`OrientationStateTrigger` | https://learn.microsoft.com/en-us/dotnet/maui/fundamentals/triggers#adaptive-trigger |
| E1 | hot reload | Y | XAML Hot Reload plus .NET Hot Reload (VS and VS Code) | https://learn.microsoft.com/en-us/dotnet/maui/xaml/hot-reload |
| E2 | inspector / devtools | Y | Live Visual Tree + Live Property Explorer ("Inspect the visual tree"); the newer first-party **DevFlow** agent adds visual-tree inspection, screenshots and an MCP server, but is marked experimental | https://learn.microsoft.com/en-us/dotnet/maui/user-interface/live-visual-tree |
| E3 | testing / UI-driving harness | P | no shipped harness — Microsoft's documented route is **Appium** (UIAutomator2 / XCUITest / Mac2 / Windows drivers) with NUnit; `Microsoft.Maui.DevFlow.Agent` does element interaction and automation first-party but is experimental | https://learn.microsoft.com/en-us/dotnet/maui/deployment/ui-testing |
| E4 | packaging / signing / distribution | Y | per-target publish docs (Google Play, App Store, in-house/ad-hoc, Mac Catalyst signed/unsigned, Windows MSIX packaged and unpackaged) via `dotnet publish` | https://learn.microsoft.com/en-us/dotnet/maui/deployment/ |
| E5 | auto-update | N | no updater in the framework; you get store updates, or hand-roll on top of MSIX/App Installer on Windows | https://learn.microsoft.com/en-us/dotnet/maui/windows/deployment/overview |

Notes:
- The "sidebar + tabs + URI routing" story is `Shell`, not the individual controls — most real MAUI apps get tabs, flyout and search through Shell rather than `TabbedPage`/`FlyoutPage`/`SearchBar`.
- CommunityToolkit.Maui is close to a second first-party tier (Microsoft-hosted docs, MS-owned repo) and is where `Popup`, `MediaElement`, `CameraView`, `FileSaver`, `FolderPicker`, `Badge`, `SpeechToText`, `DrawingView` and `Expander` live. Treat every `P` naming it as "one NuGet away", not "unavailable".
- The genuinely absent tier is desktop-shell integration: no tray item, no global hotkey, no printing, no launch-at-login, no file associations, no fullscreen, no window transparency. MAUI's desktop targets are Mac Catalyst and WinUI, and the shared API stops at the window edge.
- Two features are desktop-only by design and silently do nothing on phones: `MenuFlyout` context menus and `MenuBarItem` menu bars (Mac Catalyst + Windows).
- .NET MAUI 11 previews GTK4 (Linux), AppKit (macOS) and WPF (Windows) "platform backends" beside the four shipping targets — a fifth platform is being staged.
- Verdicts are read against .NET MAUI 10 (the default moniker on learn.microsoft.com), with MAUI 11 additions called out where they change an answer (`Passkeys`, `Window.StatusBarTheme`, Windows `Map`).

OFF-LIST (MAUI ships these; the 70 IDs do not name them):
- `Shell` — one declarative app skeleton giving flyout, tabs, URI-based routing (`//route/page?id=1`) and a native search handler.
- `BlazorWebView` and `HybridWebView` — render Blazor components, or arbitrary HTML/JS, with a typed C#↔JavaScript bridge.
- `GraphicsView` + `Microsoft.Maui.Graphics` — retained 2D canvas with brushes, gradients, paths, blend modes and winding rules.
- Handlers (`Handler.Mapper`/`CommandMapper`) — per-platform customization of any control without subclassing a renderer.
- `AppActions` — home-screen long-press shortcuts / Windows jump list entries.
- `WebAuthenticator` and (MAUI 11) `Passkeys` — browser OAuth round trip and WebAuthn/FIDO2 registration and sign-in.
- Device APIs with no ID here: `TextToSpeech`, `Geolocation`/`Geocoding`, `Contacts`, `Email`, `Sms`, `PhoneDialer`, `Battery`, `Flashlight`, `Screenshot`, and the accelerometer/barometer/compass/gyroscope/magnetometer/orientation sensors.
- `TitleBar` — a fully custom window caption bar (Windows, Mac Catalyst), and CSS-based styling (`user-interface/styles/css`) beside XAML styles.

---

## React Native

Meta's JavaScript/React framework. The core ships **iOS and Android only**; macOS and
Windows (Microsoft), visionOS (Callstack), tvOS, Web and OpenHarmony are out-of-tree
platforms. Docs: https://reactnative.dev/docs/components-and-apis — core surface is
small by policy ("Lean Core"), and most of the 70 features here live in the
`@react-native-community`, Expo or Software Mansion ecosystems.

| ID | Feature | Verdict | Framework's own name for it | Source |
|----|---------|---------|------------------------------|--------|
| A1 | toggle switch | Y | `Switch` (a core component; renders `UISwitch`/`SwitchCompat`) | https://reactnative.dev/docs/switch |
| A2 | segmented control | P | `SegmentedControlIOS` was **removed from core**; `@react-native-segmented-control/segmented-control` (native on iOS, JS-drawn on Android) | https://reactnative.dev/docs/segmentedcontrolios |
| A3 | stepper | N | nothing in core and no standard community package; `UIStepper` is not bridged | https://reactnative.dev/docs/components-and-apis |
| A4 | secure / password entry | Y | `TextInput secureTextEntry` (+ iOS `textContentType="password"`) | https://reactnative.dev/docs/textinput#securetextentry |
| A5 | number / formatted field + validation | P | core has `keyboardType`, `inputMode`, `maxLength` and nothing else — no mask, no validation. `react-native-mask-input`, or `react-hook-form` for validation | https://reactnative.dev/docs/textinput#keyboardtype |
| A6 | search field | P | no core search control. React Navigation's `headerSearchBarOptions` (via `react-native-screens`) renders the native `UISearchController`/`SearchView`; `react-native-paper` `Searchbar` otherwise | https://reactnavigation.org/docs/native-stack-navigator/#headersearchbaroptions |
| A7 | colour picker | P | `reanimated-color-picker` or `react-native-color-picker`; nothing in core | https://www.npmjs.com/package/reanimated-color-picker |
| A8 | tree view / outline | N | nothing in core and no maintained standard package; hierarchies are hand-built on `SectionList` | https://reactnative.dev/docs/components-and-apis |
| A9 | popover | P | `react-native-popover-view`, or `@gorhom/bottom-sheet` for the sheet idiom. Core has `Modal` (full-screen/overlay) and iOS-only `ActionSheetIOS` | https://www.npmjs.com/package/react-native-popover-view |
| A10 | sheet / custom-content modal | Y | `Modal` (`presentationStyle`, `animationType`, `transparent`) — arbitrary children, both platforms | https://reactnative.dev/docs/modal |
| A11 | badge (count/dot on a control or tab) | P | React Navigation `tabBarBadge` / `tabBarBadgeStyle`; `react-native-paper` `Badge`. Nothing in core | https://reactnavigation.org/docs/bottom-tab-navigator/#tabbarbadge |
| A12 | hyperlink / attributed text / markdown | Y | nested `<Text>` with per-span styles, `onPress`, `selectable`, `textDecorationLine`. Markdown is P — `react-native-markdown-display` | https://reactnative.dev/docs/text |
| A13 | activity indicator | Y | `ActivityIndicator`. Note the inverse gap: core has **no determinate progress bar** — `ProgressBarAndroid` is deprecated and `ProgressViewIOS` was removed | https://reactnative.dev/docs/activityindicator |
| A14 | tooltip | P | `react-native-walkthrough-tooltip` or `react-native-paper` `Tooltip`; no core API and no OS hover tooltip on either shipping platform | https://www.npmjs.com/package/react-native-walkthrough-tooltip |
| A15 | date / time pickers | P | `DatePickerIOS`/`DatePickerAndroid`/`TimePickerAndroid` were **removed from core**; `@react-native-community/datetimepicker` is the successor | https://reactnative.dev/docs/datepickerios |
| A16 | slider | P | removed from core; `@react-native-community/slider` | https://www.npmjs.com/package/@react-native-community/slider |
| A17 | tabs | P | no tab component in core; `@react-navigation/bottom-tabs` and `@react-navigation/material-top-tabs` | https://reactnavigation.org/docs/bottom-tab-navigator/ |
| A18 | split view / resizable panes | P | `@react-navigation/drawer` with `drawerType="permanent"` gives a persistent sidebar+detail; `DrawerLayoutAndroid` is core but Android-only and not permanent. No draggable splitter anywhere | https://reactnavigation.org/docs/drawer-navigator/#drawertype |
| A19 | toolbar | P | `ToolbarAndroid` was removed; React Navigation's `header` with `headerLeft`/`headerRight`/`headerTitle` is the route | https://reactnavigation.org/docs/native-stack-navigator/#headerright |
| A20 | context menu | P | `@react-native-menu/menu` (native `UIMenu` / Android `PopupMenu`); core has only iOS `ActionSheetIOS` and no right-click concept | https://www.npmjs.com/package/@react-native-menu/menu |
| A21 | table / data grid with column sorting | N | nothing in core and no standard package; you compose a `FlatList` with a header row and sort the data yourself | https://reactnative.dev/docs/components-and-apis |
| A22 | virtualized (recycling) lists | Y | `FlatList`, `SectionList`, `VirtualizedList` (windowing, `getItemLayout`, `removeClippedSubviews`); `@shopify/flash-list` for the faster recycler | https://reactnative.dev/docs/flatlist |
| A23 | webview | P | `WebView` was **removed from core**; `react-native-webview` is the community successor (also used by RN macOS/Windows) | https://www.npmjs.com/package/react-native-webview |
| A24 | video player | P | `expo-video` or `react-native-video`; nothing in core | https://docs.expo.dev/versions/latest/sdk/video/ |
| A25 | audio playback | P | `expo-audio` (or `expo-speech` for TTS), `react-native-audio-api`; nothing in core | https://docs.expo.dev/versions/latest/sdk/audio/ |
| A26 | map | P | `react-native-maps` (Google Maps / MapKit) or `expo-maps`; nothing in core | https://www.npmjs.com/package/react-native-maps |
| B1 | local notifications | P | core `PushNotificationIOS` is deprecated and iOS-only; `expo-notifications` (scheduling, channels, permissions) or `@notifee/react-native` | https://reactnative.dev/docs/pushnotificationios |
| B2 | system tray / status item / menu bar extra | N | no API in core; react-native-macos and react-native-windows expose none in JS either | https://reactnative.dev/docs/out-of-tree-platforms |
| B3 | dock / taskbar badge | P | `expo-notifications` `setBadgeCountAsync`/`getBadgeCountAsync` (iOS badge, Android launcher badge); core `PushNotificationIOS.setApplicationIconBadgeNumber` is deprecated | https://docs.expo.dev/versions/latest/sdk/notifications/ |
| B4 | global hotkeys | N | no API. react-native-macos' `keyDownEvents`/`validKeysDown` on `View` are in-app key handling only | https://reactnative.dev/docs/out-of-tree-platforms |
| B5 | window styles (utility, always-on-top, transparent) | N | RN has no window object at all; on macOS/Windows you configure `NSWindow`/XAML in the native app shell. `@react-native-community/blur` blurs a *view*, not a window | https://reactnative.dev/docs/out-of-tree-platforms |
| B6 | fullscreen | P | the mobile equivalent only: `StatusBar hidden` / `StatusBar.setHidden`, plus `expo-navigation-bar` for Android immersive mode. No window-fullscreen API | https://reactnative.dev/docs/statusbar |
| B7 | window position/size persistence | N | no window API in core or in the desktop forks' JS surface | https://reactnative.dev/docs/out-of-tree-platforms |
| B8 | session / state restoration | P | core `AppState` reports only active/background/inactive. React Navigation ships a documented state-persistence recipe (`initialState` + `onStateChange` + `@react-native-async-storage/async-storage`) | https://reactnavigation.org/docs/state-persistence/ |
| B9 | recent files / security-scoped bookmarks | N | no API; document pickers return a one-shot URI | https://reactnative.dev/docs/components-and-apis |
| B10 | share sheet | Y | `Share.share({message, url, title})`, returning `sharedAction`/`dismissedAction` | https://reactnative.dev/docs/share |
| B11 | URL schemes / deep links / universal links | Y | `Linking` — `openURL`, `canOpenURL`, `getInitialURL`, the `url` event, `openSettings`, `sendIntent` (Android); the doc covers Android App Links and iOS Universal Links setup | https://reactnative.dev/docs/linking |
| B12 | file type associations | N | no API; you hand-edit `CFBundleDocumentTypes` / Android intent filters in the native projects | https://reactnative.dev/docs/linking |
| B13 | printing | P | `expo-print` (`printAsync`, `printToFileAsync`); nothing in core | https://docs.expo.dev/versions/latest/sdk/print/ |
| B14 | drag and drop | P | in-app dragging only: `PanResponder` and the gesture responder system in core, `react-native-gesture-handler` + `react-native-draggable-flatlist`/`react-native-drax` in practice. **No OS-level drag source or drop target** in core; react-native-macos adds `draggedTypes`/`onDrop`/`onDragEnter` on `View` | https://reactnative.dev/docs/panresponder |
| B15 | clipboard | P | `Clipboard` was **removed from core**; `@react-native-clipboard/clipboard` or `expo-clipboard` (the latter also does images and HTML) | https://reactnative.dev/docs/clipboard |
| B16 | file dialogs | P | `@react-native-documents/picker` (was `react-native-document-picker`) or `expo-document-picker` for open; "save" is `expo-file-system` + `expo-sharing`, or the Android SAF create-document intent | https://docs.expo.dev/versions/latest/sdk/document-picker/ |
| B17 | menubar (application menu) | N | no API; on macOS the menu lives in the native `AppDelegate`/XIB | https://reactnative.dev/docs/out-of-tree-platforms |
| B18 | undo/redo integration | N | no undo manager. `TextInput` inherits whatever the native text field does (iOS shake-to-undo), nothing app-wide | https://reactnative.dev/docs/textinput |
| B19 | launch at login | N | no API in core or the community packages | https://reactnative.dev/docs/components-and-apis |
| B20 | background tasks | P | **Headless JS** is core but **Android-only** (`AppRegistry.registerHeadlessTask`); cross-platform is `expo-background-task` + `expo-task-manager`, or `react-native-background-fetch` | https://reactnative.dev/docs/headless-js-android |
| B21 | camera / photo picker | P | core `ImagePickerIOS` was removed; `expo-image-picker` or `react-native-image-picker` for the picker, `expo-camera` or `react-native-vision-camera` for a live camera view | https://reactnative.dev/docs/imagepickerios |
| B22 | biometrics / keychain / secure storage | P | core `AsyncStorage` was removed and was never secure. `expo-secure-store` or `react-native-keychain` (Keychain/Keystore), plus `expo-local-authentication` for Face ID / Touch ID / BiometricPrompt | https://docs.expo.dev/versions/latest/sdk/securestore/ |
| B23 | haptics | P | core `Vibration.vibrate(pattern)` is a motor on/off only; taptic/haptic feedback types are `expo-haptics` or `react-native-haptic-feedback` | https://reactnative.dev/docs/vibration |
| C1 | localization / string tables | P | no string-table mechanism in core. `expo-localization` for locale/region/calendar, then `i18n-js`, `react-i18next` or `react-intl` for the catalogue | https://docs.expo.dev/versions/latest/sdk/localization/ |
| C2 | RTL layout mirroring | Y | `I18nManager` (`isRTL`, `allowRTL`, `forceRTL`, `swapLeftAndRightInRTL`), plus direction-relative style props (`start`/`end`, `marginStart`, `writingDirection`) | https://reactnative.dev/docs/i18nmanager |
| C3 | plural rules | P | Hermes, the default engine, implements `Intl.Collator`/`NumberFormat`/`DateTimeFormat` but **not `Intl.PluralRules`**; you need `@formatjs/intl-pluralrules` or i18n libraries carrying their own rules | https://github.com/facebook/hermes/blob/main/doc/IntlAPIs.md |
| C4 | date / number formatting | Y | `Intl.NumberFormat`, `Intl.DateTimeFormat`, `Date.prototype.toLocale*`, `String.prototype.localeCompare` — implemented in Hermes on both platforms by delegating to the OS formatters (documented per-property and per-Android-SDK variance) | https://github.com/facebook/hermes/blob/main/doc/IntlAPIs.md |
| C5 | dynamic type / user font scaling | Y | `allowFontScaling` on `Text`/`TextInput` (**default true**), `maxFontSizeMultiplier`, `PixelRatio.getFontScale()` | https://reactnative.dev/docs/text#allowfontscaling |
| C6 | IME and composition | Y | `TextInput` is the native `UITextField`/`EditText`, so composition is the platform's; `onKeyPress` fires per composed key | https://reactnative.dev/docs/textinput |
| C7 | spellcheck | P | `TextInput spellCheck` is **iOS-only**; on Android you get only `autoCorrect` and whatever the keyboard does | https://reactnative.dev/docs/textinput#spellcheck-ios |
| C8 | reduced-motion / high-contrast honouring | Y | `AccessibilityInfo.isReduceMotionEnabled()` + `reduceMotionChanged` (both platforms); `isHighTextContrastEnabled()` (Android); `isDarkerSystemColorsEnabled()`, `isReduceTransparencyEnabled()`, `isInvertColorsEnabled()`, `isGrayscaleEnabled()`, `prefersCrossFadeTransitions()` (iOS) | https://reactnative.dev/docs/accessibilityinfo |
| D1 | animations / transitions API | Y | `Animated` (`timing`/`spring`/`decay`, `Animated.Value`, `useNativeDriver`), `Easing`, `Transforms`; `react-native-reanimated` is the ecosystem's high-performance layer | https://reactnative.dev/docs/animated |
| D2 | implicit animation | Y | `LayoutAnimation.configureNext(...)` — the *next* layout pass animates automatically, no per-property animator. Android needs `UIManager.setLayoutAnimationEnabledExperimental(true)` | https://reactnative.dev/docs/layoutanimation |
| D3 | scroll-to programmatic | Y | `ScrollView.scrollTo`/`scrollToEnd`; `FlatList.scrollToIndex`/`scrollToItem`/`scrollToOffset`/`scrollToEnd`; `SectionList.scrollToLocation` | https://reactnative.dev/docs/flatlist#scrolltoindex |
| D4 | horizontal scroll | Y | `horizontal` prop on `ScrollView`/`FlatList`, with `pagingEnabled`, `snapToInterval`, `snapToAlignment` | https://reactnative.dev/docs/scrollview#horizontal |
| D5 | pull-to-refresh | Y | `RefreshControl` passed as `refreshControl` to any `ScrollView`/`FlatList` | https://reactnative.dev/docs/refreshcontrol |
| D6 | swipe actions on list rows | P | nothing in core; `react-native-gesture-handler`'s `Swipeable`/`ReanimatedSwipeable` is the standard | https://docs.swmansion.com/react-native-gesture-handler/docs/components/reanimated_swipeable/ |
| D7 | keyboard focus order / tab traversal | P | `focusable`, `nextFocusUp/Down/Left/Right/Forward` and `tabIndex` on `View` are **Android-only**; `TextInput.focus()`/`blur()` are cross-platform. No iOS focus-order API; RN macOS/Windows add their own `acceptsKeyboardFocus` | https://reactnative.dev/docs/view#nextfocusdown-android |
| D8 | adaptive layout | Y | `useWindowDimensions()` hook, `Dimensions`, `Platform.OS`/`Platform.select`, `.ios.js`/`.android.js` file extensions, flexbox and percentage sizing. No breakpoint container primitive — you branch on the hook's value | https://reactnative.dev/docs/usewindowdimensions |
| E1 | hot reload | Y | Fast Refresh, on by default; preserves component state across edits | https://reactnative.dev/docs/fast-refresh |
| E2 | inspector / devtools | Y | React Native DevTools (bundled, Chrome DevTools frontend): components tree, props/state, profiler, plus the in-app Element Inspector from the Dev Menu | https://reactnative.dev/docs/react-native-devtools |
| E3 | testing / UI-driving harness | P | the template ships Jest with an RN preset (unit + component + snapshot); the UI-driving half is third-party — Detox, Appium or Maestro | https://reactnative.dev/docs/testing-overview |
| E4 | packaging / signing / distribution | Y | `signed-apk-android`, `publishing-to-app-store`, `running-on-device` in core docs; Expo EAS Build is the managed alternative | https://reactnative.dev/docs/signed-apk-android |
| E5 | auto-update | P | no first-party updater and Microsoft's CodePush is retired; `expo-updates` / EAS Update ship JS-bundle OTA updates (native changes still need a store release) | https://docs.expo.dev/versions/latest/sdk/updates/ |

Notes:
- "Lean Core" is the single biggest shape of this table: `Clipboard`, `WebView`, `Slider`, `AsyncStorage`, `DatePickerIOS`, `SegmentedControlIOS`, `ImagePickerIOS`, `ToolbarAndroid` and `ProgressViewIOS` were all **removed from React Native and re-homed in community packages**. Nine `P`s here are ex-core APIs, not things RN never had.
- There is no navigation in core at all — tabs, stacks, headers, drawers, deep-link routing and the search bar all come from React Navigation (or Expo Router on top of it). That is a much larger delegation than any of the other frameworks in this survey.
- The New Architecture (Fabric renderer + Turbo Native Modules) is the default from RN 0.76; legacy native modules and components still run through an interop layer, so "does this package support the New Architecture" is now a real per-package question for every `P` above.
- Desktop is out-of-tree: `react-native-macos` and `react-native-windows` are Microsoft repos on their own release cadence, and every window/menu/tray feature (B2, B5, B7, B17) is missing from *their* JS surface too, not just from core.
- The clearest asymmetry versus other frameworks: RN's accessibility-state surface (C8) is unusually complete — six iOS toggles and two Android ones queryable *and* subscribable — while its control inventory (A2, A3, A7, A8, A21) is unusually thin.
- Expo is effectively a second standard library: 13 of the `P` rows above name an `expo-*` package. Bare RN apps can install these individually, so `P` here means "one dependency", not "unavailable".

OFF-LIST (React Native ships these; the 70 IDs do not name them):
- The gesture responder system + `PanResponder` — a negotiated protocol by which views claim and release a touch, with `onMoveShouldSetResponderCapture` bubbling/capturing.
- `KeyboardAvoidingView` and the `Keyboard` module — soft-keyboard avoidance as a first-class layout primitive.
- `InputAccessoryView` (iOS) — custom content docked above the on-screen keyboard.
- `PlatformColor()` and `DynamicColorIOS()` — reference the OS's own semantic/dynamic colours from JS instead of hard-coding hexes.
- `Pressable` with `hitSlop`/`pressRetentionOffset` and style-as-a-function-of-press-state.
- Turbo Native Modules, Fabric Native Components and pure C++ Turbo Modules — a codegen'd, typed bridge as a documented extension point.
- `AppState`, `useColorScheme`, `Appearance`, `SafeAreaView`/notch insets, `AccessibilityInfo.announceForAccessibility`.
- Out-of-tree platforms as a supported concept: one codebase to macOS, Windows, visionOS, tvOS, Web and OpenHarmony via Metro's `--platform` registration.

---

**Electron and Tauri 2**

Both are "web UI + native OS bridge": the **controls** come from HTML/CSS/JS inside
a webview, the **system integration** from a native main process. So a control row
is `Y` only when the web platform ships a native element or API for it in the
engine the framework actually runs. "You could write it in React / take it from
Radix or MUI" is not `Y`.

The rule used consistently below for controls the platform does not ship:
**`P` = the platform ships a real but weaker piece** (`<table>` without sorting,
`content-visibility` without recycling); **`N` = the platform ships nothing at all
for it** and every app writes it or imports a library (tabs, tree view, toolbar,
split view, segmented control, badge, map).

**Engine difference, which decides many control rows.** Electron **bundles
Chromium** — one engine on every platform, version pinned by the Electron release,
proprietary codecs (H.264/AAC) enabled in official builds. Tauri 2 **uses the
system webview** — WebView2 (Chromium) on Windows, **WKWebView** (Safari's WebKit)
on macOS/iOS, **WebKitGTK** on Linux, Android System WebView on Android. A
Chromium-only web feature is `Y` for Electron and at best `P` for Tauri, and a
Tauri app's available web features are a function of the *user's OS version*.

---

## Electron

Chromium + Node.js in one process tree; macOS, Windows, Linux (no mobile).
Docs: https://www.electronjs.org/docs/latest/api/

| ID | Feature | Verdict | Framework's own name for it | Source |
|----|---------|---------|------------------------------|--------|
| A1 | toggle switch | N | none — `<input type=checkbox switch>` is experimental and Chromium ignores it; apps style a checkbox in CSS | https://developer.mozilla.org/en-US/docs/Web/HTML/Reference/Elements/input/checkbox |
| A2 | segmented control | N | none — a styled radio group | https://developer.mozilla.org/en-US/docs/Web/HTML/Reference/Elements/input/radio |
| A3 | stepper | P | `<input type="number">` spin buttons; no standalone +/- control | https://developer.mozilla.org/en-US/docs/Web/HTML/Reference/Elements/input/number |
| A4 | secure / password entry | Y | `<input type="password">` | https://developer.mozilla.org/en-US/docs/Web/HTML/Reference/Elements/input/password |
| A5 | number / formatted field with validation | Y | `<input type="number">`, `pattern`, `min`/`max`/`step`, Constraint Validation API (`setCustomValidity`, `:invalid`), `inputmode` | https://developer.mozilla.org/en-US/docs/Web/HTML/Guides/Constraint_validation |
| A6 | search field | Y | `<input type="search">` (Chromium draws the clear button) | https://developer.mozilla.org/en-US/docs/Web/HTML/Reference/Elements/input/search |
| A7 | colour picker | Y | `<input type="color">`, with `alpha` and `colorspace` | https://developer.mozilla.org/en-US/docs/Web/HTML/Reference/Elements/input/color |
| A8 | tree view / outline | N | none — `<details>`/`<summary>` is one level of disclosure; `role="tree"` is semantics only | https://developer.mozilla.org/en-US/docs/Web/HTML/Reference/Elements/details |
| A9 | popover | Y | `popover` attribute + Popover API (`showPopover()`, `:popover-open`), anchored with CSS anchor positioning (`anchor-name`, `position-area`), which is Chromium-first | https://developer.mozilla.org/en-US/docs/Web/API/Popover_API |
| A10 | sheet / modal dialog | Y | `<dialog>` + `showModal()`, `::backdrop` | https://developer.mozilla.org/en-US/docs/Web/HTML/Reference/Elements/dialog |
| A11 | badge (in-app count/dot) | N | none — CSS only (B3 covers the dock/taskbar badge) | https://www.electronjs.org/docs/latest/api/app |
| A12 | hyperlink / rich text / markdown | Y | `<a>`, HTML rich text, `contenteditable`; markdown needs a library (marked, markdown-it) | https://developer.mozilla.org/en-US/docs/Web/HTML/Reference/Elements/a |
| A13 | activity indicator | Y | `<progress>` with no `value` renders indeterminate | https://developer.mozilla.org/en-US/docs/Web/HTML/Reference/Elements/progress |
| A14 | tooltip | Y | `title` attribute — the OS tooltip; no styling or delay control | https://developer.mozilla.org/en-US/docs/Web/HTML/Reference/Global_attributes/title |
| A15 | date / time pickers | Y | `<input type="date"/"time"/"datetime-local"/"month"/"week">` — Chromium draws a full calendar picker for all of them | https://developer.mozilla.org/en-US/docs/Web/HTML/Reference/Elements/input/date |
| A16 | slider | Y | `<input type="range">` | https://developer.mozilla.org/en-US/docs/Web/HTML/Reference/Elements/input/range |
| A17 | tabs | N | none — `role="tablist"` is semantics only | https://developer.mozilla.org/en-US/docs/Web/Accessibility/ARIA/Reference/Roles/tab_role |
| A18 | split view | N | none — CSS `resize` resizes one box from its corner; no splitter | https://developer.mozilla.org/en-US/docs/Web/CSS/resize |
| A19 | toolbar | N | none — `role="toolbar"` is semantics only (the native `Menu` is B17) | https://www.electronjs.org/docs/latest/api/menu |
| A20 | context menu | Y | `Menu.buildFromTemplate(...).popup()` — a real native menu, from the `contextmenu` DOM event | https://www.electronjs.org/docs/latest/api/menu |
| A21 | table / data grid with sorting | P | `<table>`/`<th scope>` gives structure only; sorting, resizing and selection come from TanStack Table or AG Grid | https://developer.mozilla.org/en-US/docs/Web/HTML/Reference/Elements/table |
| A22 | virtualized (recycling) lists | P | `content-visibility: auto` + `contain-intrinsic-size` skip offscreen layout/paint but do not recycle DOM; recycling comes from TanStack Virtual / react-window | https://developer.mozilla.org/en-US/docs/Web/CSS/content-visibility |
| A23 | webview | Y | `<webview>` tag, and the preferred `WebContentsView` / `BrowserWindow.contentView` | https://www.electronjs.org/docs/latest/api/webview-tag |
| A24 | video player | Y | `<video controls>`; official builds ship H.264/AAC | https://developer.mozilla.org/en-US/docs/Web/HTML/Reference/Elements/video |
| A25 | audio playback | Y | `<audio>`, Web Audio API | https://developer.mozilla.org/en-US/docs/Web/HTML/Reference/Elements/audio |
| A26 | map | N | none — no OS map SDK bridge; MapLibre GL JS / Leaflet are ordinary JS libraries | https://www.electronjs.org/docs/latest/api/ |
| B1 | local notifications | Y | `new Notification({...}).show()` (main process); web `Notification` in the renderer | https://www.electronjs.org/docs/latest/api/notification |
| B2 | system tray / status item | Y | `Tray` (+ `tray.setContextMenu`, `setTitle`, `setToolTip`) | https://www.electronjs.org/docs/latest/api/tray |
| B3 | dock / taskbar badge | Y | `app.setBadgeCount(n)` / `app.badgeCount` (macOS, Linux); `win.setOverlayIcon()` on Windows; `app.dock.bounce()` | https://www.electronjs.org/docs/latest/api/app |
| B4 | global hotkeys | Y | `globalShortcut.register(accelerator, cb)` | https://www.electronjs.org/docs/latest/api/global-shortcut |
| B5 | window styles | Y | `alwaysOnTop`, `transparent`, `frame:false`, `vibrancy` (macOS), `backgroundMaterial: mica\|acrylic\|tabbed` (Windows), `type:'panel'` (macOS, floats over fullscreen apps), `titleBarStyle`, `roundedCorners`, `hasShadow` | https://www.electronjs.org/docs/latest/api/structures/base-window-options |
| B6 | fullscreen | Y | `win.setFullScreen()`, `fullscreen` option, `setSimpleFullScreen()` (macOS) | https://www.electronjs.org/docs/latest/api/browser-window |
| B7 | window position/size persistence | P | no Electron API; the de-facto answer is the `electron-window-state` npm package (third-party) | https://www.npmjs.com/package/electron-window-state |
| B8 | session / state restoration | N | nothing — you serialise your own UI state | https://www.electronjs.org/docs/latest/api/ |
| B9 | recent files / security-scoped bookmarks | Y | `app.addRecentDocument()`, `getRecentDocuments()`, `clearRecentDocuments()`; `dialog.showOpenDialog({securityScopedBookmarks:true})` + `app.startAccessingSecurityScopedResource()` for MAS builds | https://www.electronjs.org/docs/latest/api/app |
| B10 | share sheet | P | `ShareMenu` — **macOS only**; nothing on Windows or Linux | https://www.electronjs.org/docs/latest/api/share-menu |
| B11 | URL schemes / deep links | Y | `app.setAsDefaultProtocolClient()`, `open-url` (macOS), `second-instance` (Win/Linux), `protocol.handle()` for custom schemes | https://www.electronjs.org/docs/latest/api/app |
| B12 | file type associations | P | no runtime Electron API — declared in the packager (`electron-builder` `fileAssociations`, Forge maker config); the runtime side is the `open-file` event | https://www.electron.build/configuration/configuration |
| B13 | printing | Y | `webContents.print()`, `webContents.printToPDF()`, `getPrintersAsync()` | https://www.electronjs.org/docs/latest/api/web-contents |
| B14 | drag and drop | Y | HTML5 DnD in-page; dropped-file paths via `webUtils.getPathForFile(file)`; dragging files OUT via `webContents.startDrag({file, icon})` | https://www.electronjs.org/docs/latest/tutorial/native-file-drag-drop |
| B15 | clipboard | Y | `clipboard` module — `readText/writeText`, `readHTML`, `readImage`, `readRTF`, `readBookmark`, `readBuffer` with custom formats | https://www.electronjs.org/docs/latest/api/clipboard |
| B16 | file dialogs | Y | `dialog.showOpenDialog()`, `showSaveDialog()`, `showMessageBox()`, `showCertificateTrustDialog()` | https://www.electronjs.org/docs/latest/api/dialog |
| B17 | menubar (application menu) | Y | `Menu.setApplicationMenu(Menu.buildFromTemplate(...))`, `MenuItem` roles | https://www.electronjs.org/docs/latest/api/menu |
| B18 | undo/redo integration | P | `webContents.undo()/redo()` and the `'undo'`/`'redo'` menu roles drive **Chromium's text-editing undo stack only**; there is no app-model undo manager | https://www.electronjs.org/docs/latest/api/web-contents |
| B19 | launch at login | Y | `app.setLoginItemSettings({openAtLogin:true})` / `getLoginItemSettings()` (macOS, Windows) | https://www.electronjs.org/docs/latest/api/app |
| B20 | background tasks | N | no scheduler; the app is a foreground process. `powerMonitor` reports suspend/resume and `utilityProcess` forks a child, but neither schedules work when the app is not running | https://www.electronjs.org/docs/latest/api/power-monitor |
| B21 | camera / photo picker | P | `navigator.mediaDevices.getUserMedia()` (Chromium) for the camera and `desktopCapturer` for screens/windows; **no OS photo-library picker** — `<input type=file>` is a plain file dialog | https://www.electronjs.org/docs/latest/api/desktop-capturer |
| B22 | biometrics / keychain / secure storage | P | `safeStorage.encryptString()/decryptString()` uses the OS keychain/DPAPI/libsecret; **no biometric prompt API** | https://www.electronjs.org/docs/latest/api/safe-storage |
| B23 | haptics | N | no API | https://www.electronjs.org/docs/latest/api/ |
| C1 | localization / string tables | P | `app.getLocale()`, `app.getPreferredSystemLanguages()`, `app.getSystemLocale()` detect the locale; **string tables are third-party** (i18next, @fluent/bundle) | https://www.electronjs.org/docs/latest/api/app |
| C2 | RTL layout mirroring | Y | `dir="rtl"` + CSS logical properties (`margin-inline-start`, `inset-inline`) | https://developer.mozilla.org/en-US/docs/Web/CSS/CSS_logical_properties_and_values |
| C3 | plural rules | Y | `Intl.PluralRules` | https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Global_Objects/Intl/PluralRules |
| C4 | date / number formatting | Y | `Intl.DateTimeFormat`, `Intl.NumberFormat`, `Intl.RelativeTimeFormat`, `Intl.ListFormat` | https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Global_Objects/Intl |
| C5 | dynamic type / user font scaling | P | `webFrame.setZoomFactor()` / `webContents.setZoomFactor()` and `rem` units are the manual route; Chromium honours OS **display** scaling, not a separate OS text-size preference | https://www.electronjs.org/docs/latest/api/web-frame |
| C6 | IME and composition | Y | Chromium's IME; `compositionstart`/`compositionupdate`/`compositionend` | https://developer.mozilla.org/en-US/docs/Web/API/CompositionEvent |
| C7 | spellcheck | Y | Chromium's spellchecker — `session.setSpellCheckerLanguages()`, `setSpellCheckerDictionaryDownloadURL()`, and `misspelledWord`/`dictionarySuggestions` on the `context-menu` event | https://www.electronjs.org/docs/latest/api/session |
| C8 | reduced-motion / high-contrast | Y | `prefers-reduced-motion`, `prefers-contrast`, `forced-colors` media queries; `nativeTheme.shouldUseHighContrastColors`, `prefersReducedTransparency`, `shouldUseDarkColors` | https://www.electronjs.org/docs/latest/api/native-theme |
| D1 | animations / transitions API | Y | Web Animations API — `element.animate()`, `Animation`, `ViewTransition` | https://developer.mozilla.org/en-US/docs/Web/API/Web_Animations_API |
| D2 | implicit animation | Y | CSS `transition` | https://developer.mozilla.org/en-US/docs/Web/CSS/transition |
| D3 | scroll-to programmatic | Y | `scrollIntoView()`, `scrollTo()`, `scroll-behavior: smooth` | https://developer.mozilla.org/en-US/docs/Web/API/Element/scrollIntoView |
| D4 | horizontal scroll | Y | `overflow-x: auto`, CSS scroll snap | https://developer.mozilla.org/en-US/docs/Web/CSS/overflow-x |
| D5 | pull-to-refresh | N | nothing — `overscroll-behavior` only *suppresses* the browser's own; an app builds the gesture | https://developer.mozilla.org/en-US/docs/Web/CSS/overscroll-behavior |
| D6 | swipe actions on list rows | N | nothing — pointer events + CSS scroll snap, hand-built | https://developer.mozilla.org/en-US/docs/Web/API/Pointer_events |
| D7 | keyboard focus order / tab traversal | Y | `tabindex`, `inert`, `focus({preventScroll})`, `:focus-visible`, `autofocus` | https://developer.mozilla.org/en-US/docs/Web/HTML/Reference/Global_attributes/inert |
| D8 | adaptive layout | Y | media queries, container queries (`@container`), flexbox, grid | https://developer.mozilla.org/en-US/docs/Web/CSS/CSS_containment/Container_queries |
| E1 | hot reload | Y | Electron Forge's Vite/Webpack plugins give renderer HMR from your bundler; main-process edits restart the app | https://www.electronforge.io/config/plugins/vite |
| E2 | inspector / devtools | Y | Chrome DevTools — `webContents.openDevTools()`, plus React/Vue DevTools via `session.extensions` | https://www.electronjs.org/docs/latest/tutorial/devtools-extension |
| E3 | testing / UI-driving harness | Y | documented: Playwright's `_electron` API, WebdriverIO `@wdio/electron-service`, Selenium + `electron-chromedriver`, or a custom IPC-over-STDIO driver | https://www.electronjs.org/docs/latest/tutorial/automated-testing |
| E4 | packaging / signing / distribution | Y | Electron Forge (makers for dmg/zip/squirrel/msi/deb/rpm/flatpak), `@electron/packager`, `@electron/osx-sign`, `@electron/notarize`; `electron-builder` is the popular alternative | https://www.electronforge.io/ |
| E5 | auto-update | Y | `autoUpdater` (Squirrel.Mac / Squirrel.Windows), the free `update.electronjs.org` service for public GitHub repos | https://www.electronjs.org/docs/latest/api/auto-updater |

Notes:
- Chromium is bundled, so **every control row above is the same on macOS, Windows and Linux** and does not depend on the user's OS version — the single biggest practical difference from Tauri. The price is ~150 MB per app and a Chromium security-update treadmill tied to Electron releases.
- The system-integration column (B rows) is where Electron is genuinely strong: 20 of 23 B rows are `Y` or `P` with a first-party main-process module. The three real gaps are session/state restoration (B8), background scheduling (B20) and haptics (B23).
- The controls column is where it is genuinely weak: **8 of 26 A rows are `N`** — toggle switch, segmented control, tree, tabs, split view, toolbar, in-app badge, map. Every Electron app carries a component library for these, and that library, not the framework, decides how the app looks.
- Window persistence (B7) and file associations (B12) are the two places Tauri has a first-party answer and Electron does not.
- `BrowserView` is deprecated in favour of `WebContentsView`; new work should use `BaseWindow` + `contentView`.
- Undo (B18) is the sharpest mismatch with a native toolkit: Electron gives you Chromium's *text field* undo stack and a menu role that drives it, and nothing at all for document-model undo.

OFF-LIST (prominent Electron surfaces not among the 70 IDs):
- `desktopCapturer` + `session.setDisplayMediaRequestHandler` — screen/window capture and screen sharing.
- `TouchBar` — the macOS Touch Bar (`TouchBarSlider`, `TouchBarScrubber`, `TouchBarSegmentedControl`).
- `crashReporter` + `@electron/crashpad` upload — first-party crash collection to a Sentry/Breakpad endpoint.
- `protocol.handle()` / `protocol.registerSchemesAsPrivileged` — serving the app off a custom scheme with real web origins.
- `session` — cookie jar, proxy config, permission request handlers, per-partition storage, extension loading.
- `powerSaveBlocker` — prevent display/system sleep during a long task.
- `inAppPurchase` (Mac App Store StoreKit) and `pushNotifications` (macOS APNs registration).
- `utilityProcess` / `MessageChannelMain` — spawn a Node child with a structured-clone message port, the sanctioned way to move work off the UI process.

---

## Tauri 2

Rust backend + the **system** webview; macOS, Windows, Linux **and Android/iOS**.
Docs: https://v2.tauri.app/ , plugins https://v2.tauri.app/plugin/ , JS API
https://v2.tauri.app/reference/javascript/

Verdicts below count the **official** `tauri-apps/plugins-workspace` plugins as
`Y` (named in the row); community plugins are `P`. Where a plugin is desktop-only
or mobile-only the row says so.

| ID | Feature | Verdict | Framework's own name for it | Source |
|----|---------|---------|------------------------------|--------|
| A1 | toggle switch | P | `<input type=checkbox switch>` — experimental; WebKit (WKWebView, macOS/iOS) renders it, Chromium (WebView2/Android) and WebKitGTK ignore the attribute, so it is not uniform across Tauri's engines. Apps style a checkbox instead | https://developer.mozilla.org/en-US/docs/Web/HTML/Reference/Elements/input/checkbox |
| A2 | segmented control | N | none — a styled radio group | https://developer.mozilla.org/en-US/docs/Web/HTML/Reference/Elements/input/radio |
| A3 | stepper | P | `<input type="number">` spin buttons; no standalone +/- control | https://developer.mozilla.org/en-US/docs/Web/HTML/Reference/Elements/input/number |
| A4 | secure / password entry | Y | `<input type="password">` | https://developer.mozilla.org/en-US/docs/Web/HTML/Reference/Elements/input/password |
| A5 | number / formatted field with validation | Y | `<input type="number">`, `pattern`, Constraint Validation API (`setCustomValidity`, `:invalid`) | https://developer.mozilla.org/en-US/docs/Web/HTML/Guides/Constraint_validation |
| A6 | search field | Y | `<input type="search">` | https://developer.mozilla.org/en-US/docs/Web/HTML/Reference/Elements/input/search |
| A7 | colour picker | Y | `<input type="color">`; the newer `alpha` / `colorspace` attributes are not yet in every engine | https://developer.mozilla.org/en-US/docs/Web/HTML/Reference/Elements/input/color |
| A8 | tree view / outline | N | none — `<details>` is one level of disclosure; `role="tree"` is semantics only | https://developer.mozilla.org/en-US/docs/Web/HTML/Reference/Elements/details |
| A9 | popover | P | `popover` attribute + Popover API — Baseline "newly available" only since Jan 2025, so it needs Safari 17+/WebKitGTK 2.42+, i.e. a recent user OS; and the CSS anchor positioning that makes it *anchored* is Chromium-first, so on WebKitGTK you position it yourself | https://developer.mozilla.org/en-US/docs/Web/API/Popover_API |
| A10 | sheet / modal dialog | Y | `<dialog>` + `showModal()` | https://developer.mozilla.org/en-US/docs/Web/HTML/Reference/Elements/dialog |
| A11 | badge (in-app count/dot) | N | none — CSS only (B3 is the dock/taskbar badge) | https://v2.tauri.app/reference/javascript/api/namespacewindow/ |
| A12 | hyperlink / rich text / markdown | Y | `<a>`, HTML rich text, `contenteditable`; markdown needs a library | https://developer.mozilla.org/en-US/docs/Web/HTML/Reference/Elements/a |
| A13 | activity indicator | Y | `<progress>` with no `value`; plus `Window.setProgressBar()` for the taskbar/dock indicator | https://v2.tauri.app/reference/javascript/api/namespacewindow/ |
| A14 | tooltip | Y | `title` attribute — the OS tooltip | https://developer.mozilla.org/en-US/docs/Web/HTML/Reference/Global_attributes/title |
| A15 | date / time pickers | P | `<input type="date"/"time"/"datetime-local">` — the picker UI is the system engine's and differs per platform; `week`/`month` are not implemented in WebKit-family engines, so the Linux/macOS/iOS side is weaker than the Windows (Chromium) side | https://developer.mozilla.org/en-US/docs/Web/HTML/Reference/Elements/input/date |
| A16 | slider | Y | `<input type="range">` | https://developer.mozilla.org/en-US/docs/Web/HTML/Reference/Elements/input/range |
| A17 | tabs | N | none — `role="tablist"` is semantics only | https://developer.mozilla.org/en-US/docs/Web/Accessibility/ARIA/Reference/Roles/tab_role |
| A18 | split view | N | none — CSS `resize` is not a splitter | https://developer.mozilla.org/en-US/docs/Web/CSS/resize |
| A19 | toolbar | N | none in the webview (the native `Menu` is B17) | https://v2.tauri.app/learn/window-menu/ |
| A20 | context menu | Y | `Menu.popup(position, window)` — a real native context menu, desktop only; `CheckMenuItem`, `IconMenuItem`, `Submenu`, `PredefinedMenuItem` | https://v2.tauri.app/reference/javascript/api/namespacemenu/ |
| A21 | table / data grid with sorting | P | `<table>` gives structure only; sorting/resizing from TanStack Table or AG Grid | https://developer.mozilla.org/en-US/docs/Web/HTML/Reference/Elements/table |
| A22 | virtualized (recycling) lists | P | `content-visibility: auto` skips offscreen work but does not recycle DOM, and it reached WebKit only in Safari 18 / WebKitGTK 2.46; recycling from TanStack Virtual | https://developer.mozilla.org/en-US/docs/Web/CSS/content-visibility |
| A23 | webview | P | `<iframe>` is the in-page route. Tauri's own `Webview` (child webviews in one window, `reparent()`, `setPosition/setSize/setZoom`, `clearAllBrowsingData`) is a Tauri-managed surface rather than an embeddable control, and the multi-webview split is not part of the stable API surface (the crate carries an `unstable` feature for in-flux APIs) | https://v2.tauri.app/reference/javascript/api/namespacewebview/ |
| A24 | video player | Y | `<video controls>` — but on Linux, WebKitGTK plays only the codecs the user's GStreamer plugins provide, so H.264 is a packaging dependency, not a given | https://developer.mozilla.org/en-US/docs/Web/HTML/Reference/Elements/video |
| A25 | audio playback | Y | `<audio>`, Web Audio API | https://developer.mozilla.org/en-US/docs/Web/HTML/Reference/Elements/audio |
| A26 | map | N | nothing — no OS map SDK bridge; MapLibre GL JS / Leaflet are ordinary JS libraries | https://v2.tauri.app/plugin/ |
| B1 | local notifications | Y | `@tauri-apps/plugin-notification` — all five platforms, with actions, attachments, channels and scheduled notifications | https://v2.tauri.app/plugin/notification/ |
| B2 | system tray / status item | Y | core `TrayIconBuilder` / `@tauri-apps/api/tray` `TrayIcon.new()` behind the `tray-icon` cargo feature; desktop. Linux gets no click/enter/leave tray events, only the context menu | https://v2.tauri.app/learn/system-tray/ |
| B3 | dock / taskbar badge | Y | `Window.setBadgeCount()` (macOS, Linux), `setBadgeLabel()` (macOS), `setOverlayIcon()` (Windows), `setProgressBar()` | https://v2.tauri.app/reference/javascript/api/namespacewindow/ |
| B4 | global hotkeys | Y | `@tauri-apps/plugin-global-shortcut` — desktop only | https://v2.tauri.app/plugin/global-shortcut/ |
| B5 | window styles | P | `transparent`, `decorations:false`, `alwaysOnTop`, `setEffects()` (Mica/Acrylic/Blur on Windows, vibrancy on macOS), `setTitleBarStyle(Transparent)`, `setShadow`, `setVisibleOnAllWorkspaces`. **No utility/panel window type** — floating-panel behaviour needs the community `tauri-nspanel` plugin | https://v2.tauri.app/learn/window-customization/ |
| B6 | fullscreen | Y | `Window.setFullscreen()`, `fullscreen` in the window config | https://v2.tauri.app/reference/javascript/api/namespacewindow/ |
| B7 | window position/size persistence | Y | `@tauri-apps/plugin-window-state` — official; desktop only | https://v2.tauri.app/plugin/window-state/ |
| B8 | session / state restoration | N | nothing for UI state. `@tauri-apps/plugin-store` is a key-value store you write into yourself | https://v2.tauri.app/plugin/store/ |
| B9 | recent files / security-scoped bookmarks | P | `@tauri-apps/plugin-persisted-scope` persists the filesystem access the user granted across restarts (the security-scoped-bookmark analogue). **No recent-documents API** on any platform | https://v2.tauri.app/plugin/persisted-scope/ |
| B10 | share sheet | P | no official plugin; the community `tauri-plugin-sharesheet` covers Android/iOS | https://v2.tauri.app/plugin/ |
| B11 | URL schemes / deep links | Y | `@tauri-apps/plugin-deep-link` — custom schemes on all five platforms, plus iOS Universal Links and Android App Links. Runtime registration is Windows/Linux only; desktop pairs it with `plugin-single-instance` | https://v2.tauri.app/plugin/deep-linking/ |
| B12 | file type associations | Y | `bundle.fileAssociations` in `tauri.conf.json` — extensions, MIME types, macOS role, Android intent filters | https://v2.tauri.app/reference/config/ |
| B13 | printing | P | **no Tauri print API** — the `Webview` class exposes no `print()`. You are left with the page's own `window.print()`, whose availability is the system webview's (Chromium-based WebView2 and WebKitGTK implement it; WKWebView on macOS/iOS is the known gap) | https://v2.tauri.app/reference/javascript/api/namespacewebview/ |
| B14 | drag and drop | P | dropping IN is first-party: `Webview.onDragDropEvent()` gives `over`/`drop` with cursor position and real file `paths` (gate it with `dragDropEnabled`); HTML5 DnD works in-page. Dragging files **out** has no Tauri API — the community `tauri-plugin-drag` does it | https://v2.tauri.app/reference/javascript/api/namespacewebview/ |
| B15 | clipboard | Y | `@tauri-apps/plugin-clipboard-manager` — `writeText`, `readText`, `writeHtml`, `writeImage`, `readImage`; all platforms | https://v2.tauri.app/plugin/clipboard/ |
| B16 | file dialogs | Y | `@tauri-apps/plugin-dialog` — `open`, `save`, `message`, `ask`, `confirm`; all five platforms (Android and iOS have no folder picker, and return content/`file://` URIs) | https://v2.tauri.app/plugin/dialog/ |
| B17 | menubar (application menu) | Y | core `Menu` / `MenuBuilder`, `setAsAppMenu()`, `setAsWindowMenu()`, accelerators, checkable and icon items; desktop only | https://v2.tauri.app/learn/window-menu/ |
| B18 | undo/redo integration | P | `PredefinedMenuItem.undo()/redo()` wires a menu item to the **webview's text-editing undo stack**; no app-model undo manager | https://v2.tauri.app/learn/window-menu/ |
| B19 | launch at login | Y | `@tauri-apps/plugin-autostart` | https://v2.tauri.app/plugin/autostart/ |
| B20 | background tasks | N | no scheduler on any platform. `plugin-process`, `plugin-shell` (sidecars) and a Rust thread all run only while the app runs | https://v2.tauri.app/plugin/ |
| B21 | camera / photo picker | P | `@tauri-apps/plugin-barcode-scanner` drives the mobile camera for codes; `getUserMedia` depends on the system webview (and needs per-platform permission plumbing); **no photo-library picker plugin** | https://v2.tauri.app/plugin/barcode-scanner/ |
| B22 | biometrics / keychain / secure storage | P | `@tauri-apps/plugin-biometric` prompts Face ID / Touch ID / Android BiometricPrompt but is **mobile only**; `@tauri-apps/plugin-stronghold` is an encrypted database, not the OS keychain; desktop keychain access is community (`tauri-plugin-keyring`) | https://v2.tauri.app/plugin/biometric/ |
| B23 | haptics | P | `@tauri-apps/plugin-haptics` — official, but **Android and iOS only**; nothing on desktop | https://v2.tauri.app/plugin/haptics/ |
| C1 | localization / string tables | P | `@tauri-apps/plugin-os` `locale()` detects the locale; **string tables are third-party** (i18next, @fluent/bundle) | https://v2.tauri.app/plugin/os-info/ |
| C2 | RTL layout mirroring | Y | `dir="rtl"` + CSS logical properties | https://developer.mozilla.org/en-US/docs/Web/CSS/CSS_logical_properties_and_values |
| C3 | plural rules | Y | `Intl.PluralRules` | https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Global_Objects/Intl/PluralRules |
| C4 | date / number formatting | Y | `Intl.DateTimeFormat`, `Intl.NumberFormat` | https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Global_Objects/Intl |
| C5 | dynamic type / user font scaling | P | `Webview.setZoom()` and `rem` units are the manual route; no OS text-scale honouring. On iOS/macOS WKWebView, `font: -apple-system-body` does track Dynamic Type, but that is a WebKit-only trick | https://v2.tauri.app/reference/javascript/api/namespacewebview/ |
| C6 | IME and composition | Y | the system webview's IME; `compositionstart`/`update`/`end` | https://developer.mozilla.org/en-US/docs/Web/API/CompositionEvent |
| C7 | spellcheck | P | the `spellcheck` attribute, handled by whichever engine is hosting; **no Tauri API** to set dictionaries, languages, or read misspelling suggestions the way Electron's `session` does | https://developer.mozilla.org/en-US/docs/Web/HTML/Reference/Global_attributes/spellcheck |
| C8 | reduced-motion / high-contrast | Y | `prefers-reduced-motion`, `prefers-contrast`, `forced-colors`; `plugin-os` and `Window.theme()` for the dark/light setting | https://v2.tauri.app/reference/javascript/api/namespacewindow/ |
| D1 | animations / transitions API | Y | Web Animations API `element.animate()` | https://developer.mozilla.org/en-US/docs/Web/API/Web_Animations_API |
| D2 | implicit animation | Y | CSS `transition` | https://developer.mozilla.org/en-US/docs/Web/CSS/transition |
| D3 | scroll-to programmatic | Y | `scrollIntoView()`, `scrollTo()`, `scroll-behavior: smooth` | https://developer.mozilla.org/en-US/docs/Web/API/Element/scrollIntoView |
| D4 | horizontal scroll | Y | `overflow-x: auto`, CSS scroll snap | https://developer.mozilla.org/en-US/docs/Web/CSS/overflow-x |
| D5 | pull-to-refresh | N | nothing — hand-built from touch events | https://developer.mozilla.org/en-US/docs/Web/CSS/overscroll-behavior |
| D6 | swipe actions on list rows | N | nothing — hand-built | https://developer.mozilla.org/en-US/docs/Web/API/Pointer_events |
| D7 | keyboard focus order / tab traversal | Y | `tabindex`, `inert`, `focus()`, `:focus-visible` | https://developer.mozilla.org/en-US/docs/Web/HTML/Reference/Global_attributes/inert |
| D8 | adaptive layout | Y | media queries, container queries, flexbox, grid — the same CSS serves the desktop and mobile targets | https://developer.mozilla.org/en-US/docs/Web/CSS/CSS_containment/Container_queries |
| E1 | hot reload | Y | `tauri dev` runs your frontend dev server (`build.devUrl`) so the webview gets your bundler's HMR; Rust edits recompile and relaunch. `tauri android dev` / `tauri ios dev` do the same on device | https://v2.tauri.app/develop/ |
| E2 | inspector / devtools | Y | `Webview::open_devtools()` behind the `devtools` cargo feature; inspect-element in dev builds; on macOS/iOS it is the Safari Web Inspector attaching to WKWebView | https://v2.tauri.app/develop/debug/ |
| E3 | testing / UI-driving harness | Y | WebdriverIO `@wdio/tauri-service` with an embedded WebDriver server (this is how macOS is covered, since WKWebView has no native driver); `tauri-driver` + msedgedriver/WebKitWebDriver on Windows/Linux; a browser mode that mocks `invoke()` | https://v2.tauri.app/develop/tests/webdriver/ |
| E4 | packaging / signing / distribution | Y | `tauri build` bundler — `app`/`dmg`, `msi`/`nsis`, `deb`/`rpm`/`appimage`, plus Android `.aab`/`.apk` and iOS `.ipa`; macOS `signingIdentity` + entitlements + notarization, Windows `certificateThumbprint`/`signCommand`/`timestampUrl` | https://v2.tauri.app/reference/config/ |
| E5 | auto-update | Y | `@tauri-apps/plugin-updater` — static JSON endpoint or dynamic server, **mandatory** signature verification (`tauri signer generate`), Windows install modes. **Desktop only**; mobile updates go through the stores | https://v2.tauri.app/plugin/updater/ |

Notes:
- **Tauri is the only framework in this pair that reaches phones.** Android and iOS are first-class `tauri android dev` / `tauri ios dev` targets, and the plugin set is split accordingly: `haptics`, `biometric`, `nfc`, `barcode-scanner` are mobile-only; `global-shortcut`, `window-state`, `dialog`-folder-picking, `menu`, `tray`, `updater`, `shell`, `cli`, `single-instance`, `positioner` are desktop-only.
- **The system webview is the whole trade.** ~5-10 MB bundles and no Chromium treadmill, but a Tauri app's available web features are set by the *user's OS version*: Popover (A9), `content-visibility` (A22), the `switch` attribute (A1) and date-picker quality (A15) all differ across WKWebView / WebKitGTK / WebView2. Linux is the sharpest edge — WebKitGTK lags Safari, and `<video>` codecs are a GStreamer packaging problem.
- Tauri's B-column is *narrower but tidier* than Electron's: it has first-party answers where Electron has none (window-state B7, file associations B12, autostart B19 as a plugin rather than a raw API), and no answer at all where Electron has one (printing B13, drag-files-out B14, recent documents B9, spellchecker control C7).
- Everything is behind a **capability/permission ACL**: a plugin call fails unless the window's capability file grants that permission (`fs:allow-read-file`, `dialog:allow-open`). This is real security surface a native toolkit does not have, and real configuration work.
- Controls are exactly as thin as Electron's — the same 8 `N` rows, plus A1/A9/A15/A22/A23 degraded to `P` by engine variance. A Tauri app's look comes entirely from its CSS/component library.
- The updater (E5) refuses to run unsigned, which is stricter than Electron's `autoUpdater` and worth copying.

OFF-LIST (prominent Tauri surfaces not among the 70 IDs):
- The **capability / permission ACL** (`capabilities/*.json`, `plugin:allow-*` scopes) — per-window, per-command authorisation of every native call.
- `invoke()` / `#[tauri::command]` — the typed Rust↔JS IPC that *is* the programming model, plus `Channel` for streaming and `emit`/`listen` for events.
- `@tauri-apps/plugin-sql` — sqlx-backed SQLite/Postgres/MySQL from the frontend, with migrations.
- `@tauri-apps/plugin-http` — a Rust HTTP client that bypasses the webview's CORS, with a per-URL allowlist.
- `@tauri-apps/plugin-shell` sidecars — ship an external binary in the bundle and spawn it (`externalBin`).
- `@tauri-apps/plugin-nfc` and `plugin-barcode-scanner` — NFC tag read/write and camera code scanning on Android/iOS.
- `@tauri-apps/plugin-geolocation` — position and heading tracking on all platforms.
- `@tauri-apps/plugin-single-instance` and `plugin-positioner` — one-process enforcement and "move this window to the tray corner".

---

**Rust-native GUI frameworks: egui, iced, Slint**

Three Rust-native toolkits that paint their own widgets. None wraps a platform
control set, so most of the OS-integration group (B) and the i18n group (C) is
genuinely absent rather than merely undocumented. Verdicts follow the shared
charge; `P` is used only where the framework's own documentation or ecosystem names the
package or the feature is a markedly weaker version.

---

## egui

Immediate-mode Rust GUI (`egui` 0.36.x) that repaints and re-lays-out every frame and
paints every pixel itself; `eframe` runs it on Windows, macOS, Linux, Android and
web/wasm. Doc root: https://docs.rs/egui/latest/egui/ and https://github.com/emilk/egui

| ID | Feature | Verdict | Framework's own name for it | Source |
|----|---------|---------|------------------------------|--------|
| A1 | toggle switch | N | none; the repo's `toggle_switch` is a *custom-widget code sample* in egui_demo_lib, not a shipped widget. Only `Checkbox` ships | https://docs.rs/egui/latest/egui/widgets/index.html |
| A2 | segmented control | P | markedly weaker: a horizontal row of `Button::selectable` / `Ui::selectable_label`; no grouped control, no shared frame | https://docs.rs/egui/latest/egui/widgets/struct.Button.html |
| A3 | stepper (+/-) | N | `DragValue` is drag-to-scrub + type-in; it has no +/- increment buttons | https://docs.rs/egui/latest/egui/widgets/struct.DragValue.html |
| A4 | secure / password entry | Y | `TextEdit::password(true)` | https://docs.rs/egui/latest/egui/widgets/struct.TextEdit.html |
| A5 | number field with validation | Y | `DragValue` + `range()`, `clamp_existing_to_range()`, `custom_formatter()`, `custom_parser()`, `fixed_decimals()`, `hexadecimal()` | https://docs.rs/egui/latest/egui/widgets/struct.DragValue.html |
| A6 | search field | N | no search control; a plain `TextEdit` is all there is | https://docs.rs/egui/latest/egui/widgets/index.html |
| A7 | colour picker | Y | `egui::color_picker`, `Ui::color_edit_button_srgba` / `_rgb` / `_hsva` | https://docs.rs/egui/latest/egui/color_picker/index.html |
| A8 | tree view / outline | P | markedly weaker: nested `CollapsingHeader`. No tree widget, no selection model, no expand-all, no indent guides | https://docs.rs/egui/latest/egui/containers/index.html |
| A9 | popover | Y | `egui::Popup` (+ `Area`, `Tooltip`, `containers::menu`) | https://docs.rs/egui/latest/egui/containers/index.html |
| A10 | sheet / modal dialog | Y | `egui::Modal` (dim backdrop, custom content) | https://docs.rs/egui/latest/egui/containers/index.html |
| A11 | badge | N | no badge widget | https://docs.rs/egui/latest/egui/widgets/index.html |
| A12 | hyperlink / rich text / markdown | Y | `Hyperlink`, `Link`, `RichText`, `text::LayoutJob` + `TextFormat` for attributed runs. Markdown itself is third-party (`egui_commonmark`) | https://docs.rs/egui/latest/egui/widgets/struct.Hyperlink.html |
| A13 | activity indicator | Y | `Spinner` (distinct from `ProgressBar`) | https://docs.rs/egui/latest/egui/widgets/index.html |
| A14 | tooltip | Y | `Response::on_hover_text` / `on_hover_ui`, `containers::Tooltip` | https://docs.rs/egui/latest/egui/containers/index.html |
| A15 | date / time pickers | P | date only: `egui_extras::DatePickerButton` behind the `datepicker` feature. No time picker anywhere | https://docs.rs/egui_extras/latest/egui_extras/struct.DatePickerButton.html |
| A16 | slider | Y | `Slider` (also `Slider::vertical`, logarithmic, stepped) | https://docs.rs/egui/latest/egui/widgets/struct.Slider.html |
| A17 | tabs | N | no tab or dock container in `egui::containers`; `egui_dock` is third-party and is not named in egui's own docs | https://docs.rs/egui/latest/egui/containers/index.html |
| A18 | split view / resizable panes | P | markedly weaker: `SidePanel::resizable(true)` + `CentralPanel` gives sidebar-detail with a drag handle; `Resize` for a free region. No n-way splitter | https://docs.rs/egui/latest/egui/containers/panel/index.html |
| A19 | toolbar | P | markedly weaker: `TopBottomPanel` + `ui.horizontal` is the idiom; no toolbar control, no overflow, no customisation | https://docs.rs/egui/latest/egui/containers/panel/index.html |
| A20 | context menu | Y | `Response::context_menu`, `containers::menu` | https://docs.rs/egui/latest/egui/containers/menu/index.html |
| A21 | table / data grid with sorting | P | `egui_extras::TableBuilder` / `Table` / `Column` gives resizable columns and a sticky header, but **no column sorting** — the app sorts its own data | https://docs.rs/egui_extras/latest/egui_extras/struct.TableBuilder.html |
| A22 | virtualized lists | Y | `ScrollArea::show_rows` / `show_viewport`; `TableBody::rows` renders only visible rows | https://docs.rs/egui/latest/egui/containers/struct.ScrollArea.html |
| A23 | webview | N | — | https://github.com/emilk/egui |
| A24 | video player | N | third-party `egui_video`, not named in egui's docs | https://github.com/emilk/egui |
| A25 | audio playback | N | — | https://github.com/emilk/egui |
| A26 | map | N | third-party `walkers`, not named in egui's docs | https://github.com/emilk/egui |
| B1 | local notifications | N | — | https://docs.rs/eframe/latest/eframe/ |
| B2 | system tray / status item | N | — | https://docs.rs/eframe/latest/eframe/ |
| B3 | dock / taskbar badge | N | `ViewportCommand::RequestUserAttention` bounces/flashes but sets no count | https://docs.rs/egui/latest/egui/viewport/enum.ViewportCommand.html |
| B4 | global hotkeys | N | `KeyboardShortcut` is in-app only | https://docs.rs/egui/latest/egui/struct.KeyboardShortcut.html |
| B5 | window styles (panel, on-top, transparent) | Y | `ViewportBuilder::with_window_level`, `with_transparent`, `with_decorations`, `with_mouse_passthrough`, `with_taskbar`, macOS `with_fullsize_content_view`/`with_titlebar_shown`/`with_has_shadow`, X11 `with_window_type`. No blur/vibrancy | https://docs.rs/egui/latest/egui/viewport/struct.ViewportBuilder.html |
| B6 | fullscreen | Y | `ViewportBuilder::with_fullscreen`, `ViewportCommand::Fullscreen` (borderless) | https://docs.rs/egui/latest/egui/viewport/enum.ViewportCommand.html |
| B7 | window position/size persistence | Y | `eframe::NativeOptions::persist_window` — "the native window position and size will be persisted" (needs the `persistence` feature) | https://docs.rs/eframe/latest/eframe/struct.NativeOptions.html |
| B8 | session / state restoration | Y | `eframe::App::save` + `eframe::Storage`, `get_value`/`set_value` (RON), `storage_dir`; egui `Memory` is persisted too | https://docs.rs/eframe/latest/eframe/trait.App.html |
| B9 | recent files / scoped bookmarks | N | — | https://github.com/emilk/egui |
| B10 | share sheet | N | — | https://github.com/emilk/egui |
| B11 | URL schemes / deep links | N | `PlatformOutput::open_url` opens links outward; nothing receives them | https://docs.rs/egui/latest/egui/struct.PlatformOutput.html |
| B12 | file type associations | N | — | https://github.com/emilk/egui |
| B13 | printing | N | — | https://github.com/emilk/egui |
| B14 | drag and drop | Y | in-app `egui::DragAndDrop` payloads + `Ui::dnd_drag_source`/`dnd_drop_zone`; OS files **in** via `RawInput::hovered_files`/`dropped_files`. Dragging OUT to another app is not supported | https://docs.rs/egui/latest/egui/struct.DragAndDrop.html |
| B15 | clipboard | Y | `Context::copy_text`, `Context::copy_image`, `Event::Paste`, `ViewportCommand::RequestCut/Copy/Paste` | https://docs.rs/egui/latest/egui/struct.Context.html |
| B16 | file dialogs | P | third-party `rfd`, but named as the answer in egui's own FAQ ("The async version of `rfd` works on both native and web") | https://github.com/emilk/egui#how-do-i-open-a-file-dialog |
| B17 | menubar (application menu) | P | `egui::containers::menu` / `MenuBar` draws a menu bar **inside the egui canvas**; there is no native macOS/Windows application menu | https://docs.rs/egui/latest/egui/containers/menu/index.html |
| B18 | undo/redo integration | Y | `egui::util::undoer::Undoer` + `Settings` — "Automatic undo system", generic over app state; `TextEdit` uses it internally | https://docs.rs/egui/latest/egui/util/undoer/index.html |
| B19 | launch at login | N | — | https://github.com/emilk/egui |
| B20 | background tasks | N | the FAQ's answer is "spawn a thread / use channels" — plain Rust, no framework facility | https://github.com/emilk/egui |
| B21 | camera / photo picker | N | — | https://github.com/emilk/egui |
| B22 | biometrics / keychain | N | — | https://github.com/emilk/egui |
| B23 | haptics | N | — | https://github.com/emilk/egui |
| C1 | localization / string tables | N | no string-table mechanism; strings are Rust literals | https://github.com/emilk/egui |
| C2 | RTL layout mirroring | N | no bidi and no RTL mirroring; egui lays out left-to-right and its own docs only address non-latin *glyphs* ("you need to install your own font") | https://github.com/emilk/egui |
| C3 | plural rules | N | — | https://github.com/emilk/egui |
| C4 | date / number formatting | N | `DragValue::custom_formatter` is a hook you fill in yourself; no locale-aware formatting | https://docs.rs/egui/latest/egui/widgets/struct.DragValue.html |
| C5 | dynamic type / user font scaling | P | markedly weaker: `Context::zoom_factor`/`set_zoom_factor` (Ctrl +/-) and `Style` font sizes scale the whole UI, but nothing reads the OS text-size accessibility setting | https://docs.rs/egui/latest/egui/struct.Context.html |
| C6 | IME and composition | Y | `egui::Event::Ime` / `ImeEvent`, `PlatformOutput::ime`, `ViewportCommand::IMEAllowed`/`IMERect`/`IMEPurpose` | https://docs.rs/egui/latest/egui/viewport/enum.ViewportCommand.html |
| C7 | spellcheck | N | egui paints its own text editor; no spellcheck | https://docs.rs/egui/latest/egui/widgets/struct.TextEdit.html |
| C8 | reduced-motion / high-contrast | N | `Context::system_theme` reads OS dark/light only; no reduced-motion or contrast signal | https://docs.rs/egui/latest/egui/struct.Context.html |
| D1 | animations / transitions API | Y | `Context::animate_bool`, `animate_bool_with_time_and_easing`, `animate_value_with_time`, `clear_animations` | https://docs.rs/egui/latest/egui/struct.Context.html |
| D2 | implicit animation | P | markedly weaker: built-in widgets animate themselves off `Style::animation_time`, but an app value needs an explicit `animate_*` call every frame | https://docs.rs/egui/latest/egui/struct.Style.html |
| D3 | scroll-to programmatic | Y | `Response::scroll_to_me`, `Ui::scroll_to_cursor`, `Ui::scroll_to_rect`, `ScrollArea::vertical_scroll_offset` | https://docs.rs/egui/latest/egui/containers/struct.ScrollArea.html |
| D4 | horizontal scroll | Y | `ScrollArea::horizontal` / `both` | https://docs.rs/egui/latest/egui/containers/struct.ScrollArea.html |
| D5 | pull-to-refresh | N | — | https://docs.rs/egui/latest/egui/containers/struct.ScrollArea.html |
| D6 | swipe actions on list rows | N | — | https://docs.rs/egui/latest/egui/ |
| D7 | keyboard focus order / tab traversal | Y | tab moves focus in widget-declaration order; `Memory::request_focus`, `Response::request_focus`/`surrender_focus`, `Ui::skip_ahead_auto_ids` | https://docs.rs/egui/latest/egui/struct.Memory.html |
| D8 | adaptive layout (breakpoints) | N | no breakpoint or size-class concept; you branch on `ui.available_width()` yourself | https://docs.rs/egui/latest/egui/struct.Ui.html |
| E1 | hot reload | N | no first-party hot reload; a code change means a recompile and relaunch | https://github.com/emilk/egui |
| E2 | inspector / devtools | Y | `Context::inspection_ui`, `memory_ui`, `settings_ui`, `style_ui`, `texture_ui`; `Options::debug` draws widget rects / "debug on hover" | https://docs.rs/egui/latest/egui/struct.Context.html |
| E3 | testing / UI-driving harness | Y | `egui_kittest` (in the egui repo): `Harness`, AccessKit-based queries by label, simulated clicks, wgpu snapshot tests | https://docs.rs/egui_kittest/latest/egui_kittest/ |
| E4 | packaging / signing / distribution | N | nothing first-party; `eframe_template` ships CI, but bundling/signing is `cargo-bundle`/`cargo-packager`/Trunk, none named as egui's answer | https://github.com/emilk/eframe_template |
| E5 | auto-update | N | — | https://github.com/emilk/egui |

Notes:
- Accessibility is the one system integration egui does properly: optional AccessKit, but its own FAQ scopes it — "currently implements the native accessibility APIs on Windows and macOS" (so Linux is the hole), plus an experimental built-in screen reader on web.
- egui's stated non-goals cut off a third of this list by design: "Become the most powerful GUI library" and "Native looking interface" are both explicit non-goals, and the README warns "If you want a GUI that looks native, egui is not for you."
- The immediate-mode model means anything stateful the OS owns (menus, tray, notifications, dialogs) has to be someone else's crate; the FAQ answers exactly one of those (`rfd` for file dialogs) and is silent on the rest.
- `egui_extras` is first-party (same repo) but every one of its interesting pieces is behind a cargo feature: `datepicker`, `image`, `svg`, `syntect`.
- Version churn is a stated risk: "If you want something that doesn't break when you upgrade it, egui isn't for you (yet)."
- Web/wasm is a first-class target, which is why the OS-integration rows are N rather than "not yet" — the same code has to run on a canvas.

OFF-LIST (egui ships these prominently; the 70 IDs do not name them):
- `egui::Window` — movable/resizable/collapsible floating windows drawn *inside* one OS window, a whole window manager on the canvas.
- `egui::containers::Scene` — an infinite zoom-and-pan surface for node graphs and canvases.
- `DragValue` — drag-the-number scrubbing as the primary numeric input idiom (no spinner metaphor at all).
- `Painter` / `Shape` on any `Ui`, plus `Shape::Callback` to splice raw wgpu/glow 3D into a widget rect.
- The `Response` return-value model — `if ui.button("x").clicked()`, no callbacks or handler registration anywhere.
- `egui_extras::StripBuilder` / `Strip` — a fixed-cell layout primitive distinct from rows/columns/grid.
- `Context::request_discard()` — multi-pass layout within one frame, for sizing that needs a second look.
- `egui_extras::syntax_highlighting` — code display with optional syntect.

---

## iced

Retained-mode, Elm-architecture Rust GUI (`iced` 0.14.0, released 2026-09-04) that paints its own
widgets via wgpu or tiny-skia; targets Windows, macOS, Linux and web/wasm. Doc root:
https://docs.rs/iced/latest/iced/ — third-party additions from `iced_aw` 0.14.1
(https://docs.rs/iced_aw/latest/iced_aw/), the community "additional widgets" crate.

| ID | Feature | Verdict | Framework's own name for it | Source |
|----|---------|---------|------------------------------|--------|
| A1 | toggle switch | Y | `widget::Toggler` — "Binary choice via switch toggle", distinct from `Checkbox` | https://docs.rs/iced/latest/iced/widget/index.html |
| A2 | segmented control | N | nothing in iced or `iced_aw`; the nearest is `iced_aw::tab_bar`, which is tabs | https://docs.rs/iced_aw/latest/iced_aw/ |
| A3 | stepper (+/-) | P | third-party `iced_aw::number_input` (+/- buttons around a numeric field). Nothing in iced itself | https://docs.rs/iced_aw/latest/iced_aw/ |
| A4 | secure / password entry | Y | `TextInput::secure()` — "Converts the TextInput into a secure password input" | https://docs.rs/iced/latest/iced/widget/text_input/struct.TextInput.html |
| A5 | number field with validation | P | third-party `iced_aw::number_input` / `iced_aw::typed_input`. iced core has only `TextInput` + your own parse | https://docs.rs/iced_aw/latest/iced_aw/ |
| A6 | search field | N | no search control in either crate | https://docs.rs/iced/latest/iced/widget/index.html |
| A7 | colour picker | P | third-party `iced_aw::color_picker` | https://docs.rs/iced_aw/latest/iced_aw/ |
| A8 | tree view / outline | N | no tree in iced or `iced_aw` | https://docs.rs/iced_aw/latest/iced_aw/ |
| A9 | popover | P | third-party `iced_aw::drop_down`. iced core has `overlay` + `hover` + `Float` primitives but no anchored popover widget | https://docs.rs/iced_aw/latest/iced_aw/ |
| A10 | sheet / modal dialog | P | markedly weaker: iced's own `modal` example is hand-built from `stack` + `opaque` + `mouse_area` (first-party primitives, no widget); third-party `iced_aw::modal` / `iced_aw::card` are the packaged version | https://docs.rs/iced/latest/iced/widget/fn.opaque.html |
| A11 | badge | P | third-party `iced_aw::badge` | https://docs.rs/iced_aw/latest/iced_aw/ |
| A12 | hyperlink / rich text / markdown | Y | `widget::markdown` (feature `markdown`; incremental parsing, images, quotes, tasklists in 0.14) and `widget::text::Rich` / `rich_text!` with link spans | https://docs.rs/iced/latest/iced/widget/markdown/index.html |
| A13 | activity indicator | P | third-party `iced_aw::spinner`; iced core ships only `ProgressBar` | https://docs.rs/iced_aw/latest/iced_aw/ |
| A14 | tooltip | Y | `widget::Tooltip` (0.14 added `delay`) | https://docs.rs/iced/latest/iced/widget/tooltip/index.html |
| A15 | date / time pickers | P | third-party `iced_aw::date_picker` and `iced_aw::time_picker` — both, unusually | https://docs.rs/iced_aw/latest/iced_aw/ |
| A16 | slider | Y | `widget::Slider` and `widget::VerticalSlider` | https://docs.rs/iced/latest/iced/widget/index.html |
| A17 | tabs | P | third-party `iced_aw::tabs` / `iced_aw::tab_bar` | https://docs.rs/iced_aw/latest/iced_aw/ |
| A18 | split view / resizable panes | Y | `widget::PaneGrid` — split, drag, resize and maximize n panes, first-party (also `iced_aw::split`, `iced_aw::sidebar`) | https://docs.rs/iced/latest/iced/widget/pane_grid/index.html |
| A19 | toolbar | N | no toolbar widget; a `row!` of buttons in a `container` is the idiom | https://docs.rs/iced/latest/iced/widget/index.html |
| A20 | context menu | P | third-party `iced_aw::context_menu` | https://docs.rs/iced_aw/latest/iced_aw/ |
| A21 | table / data grid with sorting | P | `widget::table` is new in 0.14 — `Table`, `Column`, `column()` with a header and a view fn — but **no sorting, no column resize** documented | https://docs.rs/iced/latest/iced/widget/table/index.html |
| A22 | virtualized lists | N | `widget::Lazy` memoises a subtree by hash; it does not recycle or window rows. No virtualization anywhere | https://docs.rs/iced/latest/iced/widget/lazy/index.html |
| A23 | webview | N | — | https://docs.rs/iced/latest/iced/widget/index.html |
| A24 | video player | N | third-party `iced_video_player`, not named in iced's docs | https://github.com/iced-rs/iced |
| A25 | audio playback | N | — | https://github.com/iced-rs/iced |
| A26 | map | N | — | https://github.com/iced-rs/iced |
| B1 | local notifications | N | — | https://docs.rs/iced/latest/iced/ |
| B2 | system tray / status item | N | — | https://docs.rs/iced/latest/iced/ |
| B3 | dock / taskbar badge | N | `window::request_user_attention` only flashes; no count | https://docs.rs/iced/latest/iced/window/index.html |
| B4 | global hotkeys | N | `iced::keyboard` is in-app only | https://docs.rs/iced/latest/iced/keyboard/index.html |
| B5 | window styles (panel, on-top, transparent) | Y | `window::Settings` has `level` (`window::Level`), `transparent`, `decorations`, **`blur`**, `platform_specific`; plus `window::set_level`, `toggle_decorations`, `enable_mouse_passthrough`, `show_system_menu` | https://docs.rs/iced/latest/iced/window/settings/struct.Settings.html |
| B6 | fullscreen | Y | `window::Settings.fullscreen`, `window::Mode::Fullscreen` via `window::set_mode` | https://docs.rs/iced/latest/iced/window/index.html |
| B7 | window position/size persistence | N | `window::position`/`size` let you read geometry, but nothing persists or restores it | https://docs.rs/iced/latest/iced/window/index.html |
| B8 | session / state restoration | N | no storage or state-restoration facility in the crate | https://docs.rs/iced/latest/iced/ |
| B9 | recent files / scoped bookmarks | N | — | https://docs.rs/iced/latest/iced/ |
| B10 | share sheet | N | — | https://docs.rs/iced/latest/iced/ |
| B11 | URL schemes / deep links | N | — | https://docs.rs/iced/latest/iced/ |
| B12 | file type associations | N | — | https://docs.rs/iced/latest/iced/ |
| B13 | printing | N | — | https://docs.rs/iced/latest/iced/ |
| B14 | drag and drop | P | OS files **in** only: `window::Event::FileHovered` / `FileDropped` / `FilesHoveredLeft`. No drag payload or drop-target system; `PaneGrid` has its own internal pane drag, `window::drag()` drags the window. Dragging out is not supported (third-party `iced_drop` for in-app reorder) | https://docs.rs/iced/latest/iced/window/enum.Event.html |
| B15 | clipboard | Y | `iced::clipboard::read` / `write`, plus `read_primary` / `write_primary` (X11 primary selection) | https://docs.rs/iced/latest/iced/clipboard/index.html |
| B16 | file dialogs | P | third-party `rfd`; iced ships no dialog, but its own official `editor` example is built on `rfd` | https://github.com/iced-rs/iced/tree/master/examples/editor |
| B17 | menubar (application menu) | P | third-party `iced_aw::menu`, drawn **inside the canvas**; iced has no native application menu. (0.14 gave overlay menus `shadow` styling) | https://docs.rs/iced_aw/latest/iced_aw/ |
| B18 | undo/redo integration | N | no undo manager; `text_editor::Action` has Move/Select/Edit/Click/Drag/Scroll and **no Undo or Redo** | https://docs.rs/iced/latest/iced/widget/text_editor/enum.Action.html |
| B19 | launch at login | N | — | https://docs.rs/iced/latest/iced/ |
| B20 | background tasks | N | `Task` / `Subscription` are in-process async only; no OS-scheduled background work | https://docs.rs/iced/latest/iced/task/index.html |
| B21 | camera / photo picker | N | — | https://docs.rs/iced/latest/iced/ |
| B22 | biometrics / keychain | N | — | https://docs.rs/iced/latest/iced/ |
| B23 | haptics | N | — | https://docs.rs/iced/latest/iced/ |
| C1 | localization / string tables | N | — | https://docs.rs/iced/latest/iced/ |
| C2 | RTL layout mirroring | P | text only: `text::Shaping::Advanced` (cosmic-text, cargo feature `advanced-shaping`) does complex-script shaping and font fallback. The **layout** never mirrors — `Alignment`/`Padding` are absolute left/right, with no leading/trailing or direction concept | https://docs.rs/iced_core/latest/iced_core/text/enum.Shaping.html |
| C3 | plural rules | N | — | https://docs.rs/iced/latest/iced/ |
| C4 | date / number formatting | N | — | https://docs.rs/iced/latest/iced/ |
| C5 | dynamic type / user font scaling | P | markedly weaker: `Settings::default_text_size` and `Application::scale_factor` scale the UI, but nothing reads an OS text-size preference | https://docs.rs/iced/latest/iced/struct.Settings.html |
| C6 | IME and composition | Y | `iced_core::input_method` — `InputMethod`, `Preedit`, `Purpose`, `input_method::Event`; 0.14 headline "Input method support" with preedit window sizing | https://docs.rs/iced_core/latest/iced_core/input_method/index.html |
| C7 | spellcheck | N | iced paints its own `text_editor` | https://docs.rs/iced/latest/iced/widget/text_editor/index.html |
| C8 | reduced-motion / high-contrast | N | dark/light only, via the `linux-theme-detection` feature and `Theme` | https://docs.rs/iced/latest/iced/theme/index.html |
| D1 | animations / transitions API | Y | `iced::animation` — `Animation`, `Easing`, `Interpolable`; new in 0.14 ("Animation API for application code") | https://docs.rs/iced/latest/iced/animation/index.html |
| D2 | implicit animation | N | `Animation` is an explicit value you hold in state and interpolate each frame | https://docs.rs/iced/latest/iced/animation/index.html |
| D3 | scroll-to programmatic | Y | `scrollable::scroll_to`, `snap_to`, `scroll_by` with `AbsoluteOffset` / `RelativeOffset` | https://docs.rs/iced/latest/iced/widget/scrollable/index.html |
| D4 | horizontal scroll | Y | `scrollable::Direction::{Horizontal, Both}` | https://docs.rs/iced/latest/iced/widget/scrollable/enum.Direction.html |
| D5 | pull-to-refresh | N | — | https://docs.rs/iced/latest/iced/widget/scrollable/index.html |
| D6 | swipe actions on list rows | N | — | https://docs.rs/iced/latest/iced/widget/index.html |
| D7 | keyboard focus order / tab traversal | Y | `advanced::widget::operation::focusable::{focus, focus_next, focus_previous, find_focused}`, `TextInput::id()`; 0.14 added `unfocus` / `is_focused` | https://docs.rs/iced/latest/iced/advanced/widget/operation/focusable/index.html |
| D8 | adaptive layout (breakpoints) | Y | `widget::Responsive` — "Adapts content based on available space" (rebuilds the subtree with the measured size); plus `Sensor` for enter/exit | https://docs.rs/iced/latest/iced/widget/responsive/index.html |
| E1 | hot reload | Y | cargo feature `hot` (`iced_debug/hot`), new in 0.14 — "Hot reloading" is a headline release feature | https://github.com/iced-rs/iced/releases/tag/0.14.0 |
| E2 | inspector / devtools | Y | **comet**: cargo features `debug` (`iced_devtools`) and `time-travel`; README lists "Debug tooling with performance metrics and time traveling" | https://github.com/iced-rs/iced/releases/tag/0.14.0 |
| E3 | testing / UI-driving harness | Y | `iced_test` 0.14 (official, iced-rs repo) — headless `Simulator`, selectors, click/type/tap, message assertions, snapshot tests; cargo feature `tester` | https://docs.rs/iced_test/latest/iced_test/ |
| E4 | packaging / signing / distribution | N | nothing first-party | https://github.com/iced-rs/iced |
| E5 | auto-update | N | — | https://github.com/iced-rs/iced |

Notes:
- 0.14.0 landed the day before this survey (2026-09-04) and moved four E-group rows from N to Y at once: hot reload, the comet devtools with time travel, `iced_test`, plus the first `table`, `grid` and `animation` APIs. Anything written about iced before that date understates it badly.
- The widget roster is still deliberately thin. Eleven of the 26 control rows here are carried by `iced_aw`, a community crate that version-locks to iced (0.14.1 tracks iced 0.14.0) — a real coupling risk, not a free extension.
- iced has no accessibility layer at all: no AccessKit, nothing in the crate root, and the a11y work lives in a downstream fork (System76's `libcosmic`). That is invisible in this table because the 70 IDs do not include accessibility.
- `PaneGrid` is the standout first-party widget — split/drag/resize/maximize panes is something most of the mainstream toolkits make you assemble.
- iced's `table` has columns and headers but no sorting; combined with no virtualization, a large sortable grid is app work.
- Everything is one message enum: there are no callbacks, so "handler" rows (context menu, drag) become Task/Message plumbing rather than API surface.

OFF-LIST (iced ships these prominently; the 70 IDs do not name them):
- `widget::PaneGrid` — dockable/splittable/draggable/maximizable pane layout as one widget.
- `Task` and `Subscription` — futures and streams as first-class, cancellable sources of messages.
- `time-travel` in comet — rewind and replay the application's message history against live UI.
- `widget::shader` — an embedded custom wgpu render pass sized and clipped like any widget.
- `widget::canvas` with a retained `Cache` and the `canvas::Program` trait.
- `widget::qr_code` — a QR code as a shipped widget.
- `daemon` mode — an application that runs with no window at all, opening them on demand.
- `widget::Lazy` / `Sensor` / `Float` / `Pin` — memoised subtrees, viewport enter/exit messages, and out-of-flow positioning.

---

## Slint

Declarative GUI toolkit (`slint` 1.17.1; 1.18 in development) with its own `.slint` markup language,
compiled ahead of time and driven from Rust, C++, JavaScript or Python; targets desktop
(Windows/macOS/Linux, winit or Qt backend), Android, iOS, web/wasm and bare-metal MCUs.
Doc root: https://docs.slint.dev/latest/docs/slint/ — triple-licensed royalty-free / GPLv3 / commercial.

| ID | Feature | Verdict | Framework's own name for it | Source |
|----|---------|---------|------------------------------|--------|
| A1 | toggle switch | Y | `Switch` widget, separate from `CheckBox` | https://docs.slint.dev/latest/docs/slint/reference/overview/ |
| A2 | segmented control | N | nothing; `RadioGroup` or a row of `Button`s is the fallback | https://docs.slint.dev/latest/docs/slint/reference/overview/ |
| A3 | stepper (+/-) | Y | `SpinBox` (minimum / maximum / step-size) | https://docs.slint.dev/latest/docs/slint/reference/std-widgets/basic-widgets/spinbox/ |
| A4 | secure / password entry | Y | `LineEdit` / `TextInput` with `input-type: password` | https://docs.slint.dev/latest/docs/slint/reference/std-widgets/views/lineedit/ |
| A5 | number field with validation | Y | `LineEdit` `input-type: number`/`decimal` plus `SpinBox`'s clamped range; `input-method-hints` steers the mobile keyboard | https://docs.slint.dev/latest/docs/slint/reference/std-widgets/views/lineedit/ |
| A6 | search field | N | no search control | https://docs.slint.dev/latest/docs/slint/reference/overview/ |
| A7 | colour picker | N | no colour picker | https://docs.slint.dev/latest/docs/slint/reference/overview/ |
| A8 | tree view / outline | N | no tree; `StandardListView` is flat | https://docs.slint.dev/latest/docs/slint/reference/overview/ |
| A9 | popover | Y | `PopupWindow` (`close-policy`, `is-open`, `close()`, escape-to-close, multiple at once) and the `Tooltip` element | https://docs.slint.dev/latest/docs/slint/reference/window/popupwindow/ |
| A10 | sheet / modal dialog | Y | `Dialog` — "can be used in place of Window, but it has buttons that are automatically laid out", ordered per platform, with `StandardButton` / `dialog-button-role` | https://docs.slint.dev/latest/docs/slint/reference/window/dialog/ |
| A11 | badge | N | no badge widget | https://docs.slint.dev/latest/docs/slint/reference/overview/ |
| A12 | hyperlink / rich text / markdown | Y | `StyledText` element + `styled-text` type + `@markdown(...)` macro — a CommonMark subset with bold, italic, strikethrough, inline code, lists, `<u>`, `<font color>` and **HTTP links** (`link-color`) | https://docs.slint.dev/latest/docs/slint/reference/elements/styledtext/ |
| A13 | activity indicator | Y | `Spinner`, distinct from `ProgressIndicator` | https://docs.slint.dev/latest/docs/slint/reference/std-widgets/basic-widgets/spinner/ |
| A14 | tooltip | Y | `Tooltip` element (added 1.17.0) | https://docs.slint.dev/latest/docs/slint/reference/window/tooltip/ |
| A15 | date / time pickers | Y | `DatePickerPopup` **and** `TimePickerPopup` — both, first-party | https://docs.slint.dev/latest/docs/slint/reference/std-widgets/misc/datepickerpopup/ |
| A16 | slider | Y | `Slider` (with `orientation`) | https://docs.slint.dev/latest/docs/slint/reference/std-widgets/basic-widgets/slider/ |
| A17 | tabs | Y | `TabWidget` with `Tab` children | https://docs.slint.dev/latest/docs/slint/reference/std-widgets/views/tabwidget/ |
| A18 | split view / resizable panes | N | no splitter or resizable-pane widget in Std-Widgets | https://docs.slint.dev/latest/docs/slint/reference/overview/ |
| A19 | toolbar | N | no toolbar widget; a `HorizontalBox` of `Button`s | https://docs.slint.dev/latest/docs/slint/reference/overview/ |
| A20 | context menu | Y | `ContextMenuArea` + `Menu`/`MenuItem`/`MenuSeparator`; **native menu on macOS** (1.16) and native look and feel on Windows (1.14) | https://docs.slint.dev/latest/docs/slint/reference/window/contextmenuarea/ |
| A21 | table / data grid with sorting | Y | `StandardTableView` — `columns`, `rows`, `current-sort-column`, and `sort-ascending(int)` / `sort-descending(int)` callbacks fired from header clicks; the app sorts the model (`ModelExt::sort_by`) | https://docs.slint.dev/latest/docs/slint/reference/std-widgets/views/standardtableview/ |
| A22 | virtualized lists | Y | `ListView` — "elements are only instantiated if they are visible, which guarantees stable performance with a practically unlimited number of items" | https://docs.slint.dev/latest/docs/slint/reference/std-widgets/views/listview/ |
| A23 | webview | N | — | https://docs.slint.dev/latest/docs/slint/reference/overview/ |
| A24 | video player | N | no video element; the ffmpeg example pushes frames into an `Image` | https://github.com/slint-ui/slint/tree/master/examples |
| A25 | audio playback | N | — | https://docs.slint.dev/latest/docs/slint/reference/overview/ |
| A26 | map | N | — | https://docs.slint.dev/latest/docs/slint/reference/overview/ |
| B1 | local notifications | N | no notification API; nothing in the changelog | https://github.com/slint-ui/slint/blob/master/CHANGELOG.md |
| B2 | system tray / status item | Y | `SystemTrayIcon` top-level element (default cargo feature `system-tray`): icon, tooltip, title, `clicked()`, one `Menu` child. NSStatusItem on macOS, Shell notification-area icon on Windows, StatusNotifierItem/`ksni` on Linux (needs a DE that implements it; plain X11 trays unsupported) | https://docs.slint.dev/latest/docs/slint/reference/window/systemtrayicon/ |
| B3 | dock / taskbar badge | N | — | https://docs.slint.dev/latest/docs/slint/reference/window/window/ |
| B4 | global hotkeys | N | `MenuItem::shortcut` is in-app only | https://github.com/slint-ui/slint/blob/master/CHANGELOG.md |
| B5 | window styles (panel, on-top, transparent) | Y | `Window` properties `always-on-top`, `no-frame`, `resize-border-width`, `background` (a brush); "Added support for Window transparency on supported platforms" (1.1.0). No blur/vibrancy and no utility/panel window class | https://docs.slint.dev/latest/docs/slint/reference/window/window/ |
| B6 | fullscreen | Y | `Window.full-screen` — "the Window will occupy the entire screen, it will not be resizable, and it will not display the title bar"; also `maximized` / `minimized` | https://docs.slint.dev/latest/docs/slint/reference/window/window/ |
| B7 | window position/size persistence | N | nothing persists geometry | https://docs.slint.dev/latest/docs/slint/reference/window/window/ |
| B8 | session / state restoration | N | — | https://docs.slint.dev/latest/docs/slint/ |
| B9 | recent files / scoped bookmarks | N | — | https://docs.slint.dev/latest/docs/slint/ |
| B10 | share sheet | N | — | https://docs.slint.dev/latest/docs/slint/ |
| B11 | URL schemes / deep links | N | — | https://docs.slint.dev/latest/docs/slint/ |
| B12 | file type associations | N | — | https://docs.slint.dev/latest/docs/slint/ |
| B13 | printing | N | — | https://github.com/slint-ui/slint/blob/master/CHANGELOG.md |
| B14 | drag and drop | Y | `DragArea` / `DropArea` elements and the `data-transfer` type (text, image, **and a list of file paths**), `copy`/`move`/`link` actions, `drag-finished(action)`. "On platforms that support it, a `DropArea` also accepts drops from other applications"; dragging **out** to other applications is documented on the Qt backend (1.18) | https://docs.slint.dev/latest/docs/slint/guide/development/drag-and-drop/ |
| B15 | clipboard | P | markedly weaker: `TextInput`/`LineEdit`/`TextEdit` have `cut()`, `copy()`, `paste()`, `select-all()` and a built-in copy/paste context menu, but the host language (Rust/C++/JS/Python) gets no clipboard API — nothing in the `slint` crate root | https://github.com/slint-ui/slint/blob/master/CHANGELOG.md |
| B16 | file dialogs | N | no dialog, and Slint's own "Third Party Libraries" page recommends only component sets — it names nothing for file dialogs | https://docs.slint.dev/latest/docs/slint/guide/development/third-party-libraries/ |
| B17 | menubar (application menu) | Y | `MenuBar` element inside `Window` (added 1.9.0) with `Menu`, `MenuItem` (`shortcut`, `icon`, `checkable`, `checked`), `MenuSeparator`; one per window, hideable via `if`. Nativeness is documented for context menus (macOS/Windows), not stated for the MenuBar itself | https://docs.slint.dev/latest/docs/slint/reference/window/window/ |
| B18 | undo/redo integration | P | markedly weaker: text-input scope only — `TextInput::undo()` / `redo()` plus Ctrl+Z/Ctrl+Shift+Z (1.5.0, functions in 1.17.0). No application-level undo manager | https://github.com/slint-ui/slint/blob/master/CHANGELOG.md |
| B19 | launch at login | N | — | https://docs.slint.dev/latest/docs/slint/ |
| B20 | background tasks | N | `Timer`, `spawn_local`, `invoke_from_event_loop` are in-process only | https://docs.rs/slint/latest/slint/ |
| B21 | camera / photo picker | N | — | https://docs.slint.dev/latest/docs/slint/ |
| B22 | biometrics / keychain | N | — | https://docs.slint.dev/latest/docs/slint/ |
| B23 | haptics | N | — | https://docs.slint.dev/latest/docs/slint/ |
| C1 | localization / string tables | Y | `@tr("...")` in `.slint`, gettext `.po`/`.mo` via `slint-tr-extractor` + `msgfmt`, `slint::init_translations!`, `select_bundled_translation()` (bundled mode for wasm/embedded), context via `@tr("ctx" => "text")` | https://docs.slint.dev/latest/docs/slint/guide/development/translations/ |
| C2 | RTL layout mirroring | P | text only: `TextHorizontalAlignment` gained `start` / `end` in 1.16 — "aligned with the start edge... could be left or right depending on the direction of the text". There is no `layout-direction` property and layouts do not mirror | https://docs.slint.dev/latest/docs/slint/reference/elements/text/ |
| C3 | plural rules | Y | `@tr("I have {n} item" \| "I have {n} items" % count)` — gettext plural forms, so the translator's language rules apply | https://docs.slint.dev/latest/docs/slint/guide/development/translations/ |
| C4 | date / number formatting | N | no locale-aware date or number formatting | https://docs.slint.dev/latest/docs/slint/guide/development/translations/ |
| C5 | dynamic type / user font scaling | P | markedly weaker: "The default font size for application is read from system settings on Windows and Linux" (1.17.0) — macOS is not covered and there is no dynamic-type ramp or per-element scaling | https://github.com/slint-ui/slint/blob/master/CHANGELOG.md |
| C6 | IME and composition | Y | `input-method-hints` on `TextInput` / `LineEdit`, preedit handling (Android commit-on-focus-change), `Window.virtual-keyboard-position` / `virtual-keyboard-size` | https://github.com/slint-ui/slint/blob/master/CHANGELOG.md |
| C7 | spellcheck | N | — | https://docs.slint.dev/latest/docs/slint/reference/keyboard-input/textinput/ |
| C8 | reduced-motion / high-contrast | N | `Palette.color-scheme` is dark/light only (iOS system theme detection added 1.17) | https://docs.slint.dev/latest/docs/slint/reference/std-widgets/globals/palette/ |
| D1 | animations / transitions API | Y | `animate` blocks (duration, easing, delay, iteration-count) plus declarative `states` and `transitions` with in/out animations | https://docs.slint.dev/latest/docs/slint/guide/language/animations/ |
| D2 | implicit animation | Y | this is Slint's model: `animate x { duration: 250ms; }` on a property makes **every** change to it animate, with no animator object anywhere | https://docs.slint.dev/latest/docs/slint/guide/language/animations/ |
| D3 | scroll-to programmatic | Y | `ScrollView`/`ListView` `viewport-x` / `viewport-y` are in-out and settable; focusing an element also scrolls the parent `Flickable` to reveal it (1.15) | https://docs.slint.dev/latest/docs/slint/reference/std-widgets/views/scrollview/ |
| D4 | horizontal scroll | Y | `horizontal-scrollbar-policy` (`as-needed` / `always-on` / `always-off`), `Flickable` on both axes | https://docs.slint.dev/latest/docs/slint/reference/std-widgets/views/scrollview/ |
| D5 | pull-to-refresh | N | — | https://docs.slint.dev/latest/docs/slint/reference/overview/ |
| D6 | swipe actions on list rows | N | `SwipeGestureHandler` (1.13) is a gesture primitive you would build row actions on; no row-action affordance ships | https://docs.slint.dev/latest/docs/slint/reference/gestures/swipegesturehandler/ |
| D7 | keyboard focus order / tab traversal | Y | `FocusScope` with `focus-gained`/`focus-lost` and a `FocusReason`, `focus()` (works on invisible items), `focus-on-click`, `focus-on-tab-navigation`, Tab traversal including inside `Flickable` | https://docs.slint.dev/latest/docs/slint/guide/development/focus/ |
| D8 | adaptive layout (breakpoints) | P | markedly weaker: `states [ narrow when root.width < 600px : { ... } ]` is the declarative mechanism, and layouts are constraint-driven. There is no size class, breakpoint container, or responsive-layout page in the docs | https://docs.slint.dev/latest/docs/slint/guide/language/states-and-transitions/ |
| E1 | hot reload | Y | cargo feature `live-preview` — "reload the .slint files at runtime and reload it whenever the files are modified on disk", **inside your running app with its state and callbacks intact**; plus standalone `slint-viewer --auto-reload` and the VS Code / LSP Live Preview | https://docs.slint.dev/latest/docs/slint/guide/tooling/live-preview/ |
| E2 | inspector / devtools | P | markedly weaker: the Live Preview renders the UI tree and the `system-testing` feature "permits remote introspection and control of the user interface", but there is no runtime view-hierarchy/property inspector attached to a running app; the VS Code extension lists only syntax highlighting, diagnostics, live preview, completion and jump-to-definition | https://marketplace.visualstudio.com/items?itemName=Slint.slint |
| E3 | testing / UI-driving harness | P | cargo feature `system-testing`: with `SLINT_TEST_SERVER` set, the app "connects to the system test server at the given address and permits remote introspection and control of the user interface" — but the server is Slint's own tooling and the element-query API (`ElementHandle`) lives in the internal `i-slint-backend-testing` crate; there is no `slint::testing` module in the public Rust API | https://github.com/slint-ui/slint/blob/master/api/rs/slint/Cargo.toml |
| E4 | packaging / signing / distribution | P | Android only: the docs prescribe `xbuild` (`x build --platform android --arch arm64 --format apk --release`) and `./gradlew assembleRelease` for C++. Nothing for desktop installers, code signing or notarization | https://docs.slint.dev/latest/docs/slint/guide/platforms/mobile/android/ |
| E5 | auto-update | N | — | https://docs.slint.dev/latest/docs/slint/ |

Notes:
- Slint is by a distance the most complete of the three on system integration: it is the only one with a first-party system tray, a menu bar, cross-application drag and drop, real gettext localization with plural forms, and both a date and a time picker.
- It is also the only one whose accessibility is on by default — `accessibility` is a default cargo feature and 1.18 exposes text-input content and selection to assistive technology. (Not a row here; the 70 IDs omit accessibility.)
- Implicit animation (D2) is the architectural difference from the other two: `animate` is a property modifier, so any assignment animates. egui and iced both make you hold and tick an animator.
- The licence is the practical catch: royalty-free for proprietary **desktop/mobile/web**, GPLv3 or a paid commercial licence for **embedded**. The `system-testing` harness points at Slint's own (commercial) test server.
- The desktop widget roster still has real holes: no colour picker, no tree, no split view, no search field, no toolbar, no segmented control, and no file dialog — and unlike iced there is no `iced_aw`-style community widget crate filling them (the recommended third-party libraries are all whole design systems).
- Two backends behave differently: `backend-qt` gives native styling and drag-**out** to other applications; the default winit backend does not. That is a real per-platform split inside one framework.

OFF-LIST (Slint ships these prominently; the 70 IDs do not name them):
- The `.slint` language itself — a compiled declarative UI language with its own LSP, formatter, viewer and Figma variable import, separate from the host language.
- `states` / `transitions` — declarative state machines with per-state property values and directional in/out animations.
- Embedded and bare-metal MCU targets: `no_std`, the LinuxKMS backend and a software renderer, on the same source as the desktop build.
- `SwipeGestureHandler` and `ScaleRotateGestureHandler` — multi-touch gestures as first-class elements.
- `Palette` / `StyleMetrics` globals plus compile-time style selection (fluent, cupertino, material, native/Qt).
- `@markdown(...)` and the `styled-text` value type — rich text as a language-level type, not a widget property.
- `Window.safe-area-insets`, `virtual-keyboard-position`, `virtual-keyboard-size` — mobile chrome exposed as ordinary window properties.
- Four host languages from one UI definition (Rust, C++, JavaScript, Python), each with a generated typed API.

---

# Part two: the matrix

Column keys: **SwU** SwiftUI (+AppKit/UIKit) · **Cmp** Jetpack Compose +
Compose Multiplatform · **Flu** Flutter · **Qt** Qt 6 (Widgets + QML) ·
**GTK** GTK4 + libadwaita · **WU3** WinUI 3 / Windows App SDK ·
**Avl** Avalonia · **MAU** .NET MAUI · **RN** React Native ·
**Elc** Electron · **Tau** Tauri 2 · **egu** egui · **icd** iced ·
**Slt** Slint · **Uno** Uno Platform.

`Y` first-party · `P` partial (named package, some targets only, or a native
escape hatch) · `N` absent · `–` no such concept on the platform · `?` not
established. Per-row reasoning and the source URL for each cell are in the
framework sections above.
| ID | Feature | SwU | Cmp | Flu | Qt | GTK | WU3 | Avl | MAU | RN | Elc | Tau | egu | icd | Slt | Uno |
|----|---------|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|
| | **Controls** |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |
| A1 | toggle switch (vs checkbox) | Y | Y | Y | Y | Y | Y | Y | Y | Y | N | P | N | Y | Y | Y |
| A2 | segmented control | Y | Y | Y | P | Y | Y | N | P | P | N | N | P | N | N | P |
| A3 | stepper (+/-) | Y | P | N | Y | Y | Y | Y | Y | N | P | P | N | P | Y | Y |
| A4 | secure / password entry | Y | Y | Y | Y | Y | Y | Y | Y | Y | Y | Y | Y | Y | Y | Y |
| A5 | number / formatted field + validation | Y | Y | Y | Y | P | Y | Y | P | P | Y | Y | Y | P | Y | Y |
| A6 | search field | Y | Y | Y | Y | Y | Y | P | Y | P | Y | Y | N | N | N | Y |
| A7 | colour picker | Y | P | P | Y | Y | Y | Y | P | P | Y | Y | Y | P | N | Y |
| A8 | tree view / outline | Y | P | Y | Y | Y | Y | Y | P | N | N | N | P | N | N | Y |
| A9 | popover | Y | Y | Y | Y | Y | Y | Y | P | P | Y | P | Y | P | Y | Y |
| A10 | sheet / modal beyond alert | Y | Y | Y | Y | Y | Y | Y | Y | Y | Y | Y | Y | P | Y | Y |
| A11 | badge | Y | Y | Y | N | Y | Y | P | P | P | N | N | N | P | N | Y |
| A12 | hyperlink / rich text / markdown | Y | Y | Y | Y | Y | Y | Y | Y | Y | Y | Y | Y | Y | Y | Y |
| A13 | activity indicator vs progress bar | Y | Y | Y | Y | Y | Y | Y | Y | Y | Y | Y | Y | P | Y | Y |
| A14 | tooltip *(kaya has)* | Y | Y | Y | Y | Y | Y | Y | Y | P | Y | Y | Y | Y | Y | Y |
| A15 | date / time pickers *(kaya has)* | Y | Y | Y | Y | P | Y | Y | Y | P | Y | P | P | P | Y | Y |
| A16 | slider *(kaya has)* | Y | Y | Y | Y | Y | Y | Y | Y | P | Y | Y | Y | Y | Y | Y |
| A17 | tabs *(kaya has)* | Y | Y | Y | Y | Y | Y | Y | Y | P | N | N | N | P | Y | Y |
| A18 | split view *(kaya has)* | Y | Y | P | Y | Y | Y | Y | P | P | N | N | P | Y | N | Y |
| A19 | toolbar *(kaya has)* | Y | Y | Y | Y | Y | Y | Y | Y | P | N | N | P | N | N | Y |
| A20 | context menu *(kaya has)* | Y | Y | Y | Y | Y | Y | Y | P | P | Y | Y | Y | P | Y | Y |
| A21 | table / data grid + sorting *(kaya has)* | Y | N | Y | Y | Y | P | Y | P | N | P | P | P | P | Y | P |
| A22 | virtualized lists *(kaya has)* | Y | Y | Y | Y | Y | Y | Y | Y | Y | P | P | Y | N | Y | Y |
| A23 | webview | Y | P | Y | Y | P | Y | P | Y | P | Y | P | N | N | N | P |
| A24 | video player | Y | P | Y | Y | Y | Y | P | P | P | Y | Y | N | N | N | Y |
| A25 | audio playback | Y | P | P | Y | Y | Y | P | P | P | Y | Y | N | N | N | Y |
| A26 | map | Y | P | Y | Y | P | Y | P | Y | P | N | N | N | N | N | N |
| | **Window and system integration** |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |
| B1 | local notifications | Y | P | P | P | Y | Y | P | P | P | Y | Y | N | N | N | P |
| B2 | system tray / status item | Y | Y | P | Y | P | P | Y | N | N | Y | Y | N | N | Y | N |
| B3 | dock / taskbar badge | Y | P | P | N | – | Y | N | P | P | Y | Y | N | N | N | Y |
| B4 | global hotkeys | P | N | P | P | P | P | N | N | N | Y | Y | N | N | N | N |
| B5 | window styles (panel/on-top/transparent) | Y | Y | P | P | P | Y | Y | P | N | Y | P | Y | Y | Y | P |
| B6 | fullscreen | Y | Y | P | Y | Y | Y | Y | N | P | Y | Y | Y | Y | Y | Y |
| B7 | window position/size persistence | Y | N | P | P | P | N | N | P | N | P | Y | Y | N | N | N |
| B8 | session / state restoration | Y | P | Y | P | N | N | N | P | P | N | N | Y | N | N | N |
| B9 | recent files / bookmarks | Y | P | P | N | Y | Y | Y | N | N | Y | P | N | N | N | P |
| B10 | share sheet | Y | P | P | N | N | Y | N | Y | Y | P | P | N | N | N | P |
| B11 | URL schemes / deep links | Y | Y | Y | Y | Y | Y | Y | Y | Y | Y | Y | N | N | N | Y |
| B12 | file type associations | Y | P | N | P | Y | Y | Y | N | N | P | Y | N | N | N | ? |
| B13 | printing | P | P | P | Y | Y | P | N | N | P | Y | P | N | N | N | N |
| B14 | drag and drop *(kaya has)* | Y | Y | P | Y | Y | Y | Y | Y | P | Y | P | Y | P | Y | Y |
| B15 | clipboard *(kaya has)* | Y | Y | Y | Y | Y | Y | Y | Y | P | Y | Y | Y | Y | P | Y |
| B16 | file dialogs *(kaya has)* | Y | P | Y | Y | Y | Y | Y | P | P | Y | Y | P | P | N | Y |
| B17 | menubar *(kaya has)* | Y | Y | Y | Y | Y | Y | Y | Y | N | Y | Y | P | P | Y | P |
| B18 | undo/redo integration *(kaya has)* | Y | P | Y | Y | P | N | N | N | N | P | P | Y | N | P | N |
| B19 | launch at login | Y | N | P | N | P | Y | N | N | N | Y | Y | N | N | N | N |
| B20 | background tasks | Y | P | P | N | P | Y | N | P | P | N | N | N | N | N | N |
| B21 | camera / photo picker | Y | P | Y | P | P | Y | N | Y | P | P | P | N | N | N | Y |
| B22 | biometrics / keychain | Y | P | P | P | P | Y | N | P | P | P | P | N | N | N | P |
| B23 | haptics | Y | Y | Y | N | N | P | Y | Y | P | N | P | N | N | N | Y |
| | **Text and internationalisation** |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |
| C1 | localization / string tables | Y | Y | Y | Y | Y | Y | P | Y | P | P | P | N | N | Y | Y |
| C2 | RTL layout mirroring | Y | Y | Y | Y | Y | Y | Y | Y | Y | Y | Y | N | P | P | Y |
| C3 | plural rules | Y | Y | Y | Y | Y | P | P | P | P | Y | Y | N | N | Y | P |
| C4 | date / number formatting | Y | P | Y | Y | P | Y | Y | Y | Y | Y | Y | N | N | N | Y |
| C5 | dynamic type / font scaling | Y | Y | Y | P | Y | Y | N | Y | Y | P | P | P | P | P | ? |
| C6 | IME and composition | Y | Y | Y | Y | Y | Y | Y | Y | Y | Y | Y | Y | Y | Y | P |
| C7 | spellcheck | P | N | P | N | P | Y | N | Y | P | Y | P | N | N | N | Y |
| C8 | reduced-motion / high-contrast | Y | P | Y | P | Y | Y | P | P | Y | Y | Y | N | N | N | ? |
| | **Motion and layout** |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |
| D1 | animations / transitions API | Y | Y | Y | Y | Y | Y | Y | Y | Y | Y | Y | Y | Y | Y | Y |
| D2 | implicit animation | Y | Y | Y | Y | P | Y | Y | N | Y | Y | Y | P | N | Y | P |
| D3 | scroll-to programmatic | Y | Y | Y | Y | Y | Y | Y | Y | Y | Y | Y | Y | Y | Y | Y |
| D4 | horizontal scroll | Y | Y | Y | Y | Y | Y | Y | Y | Y | Y | Y | Y | Y | Y | Y |
| D5 | pull-to-refresh | Y | Y | Y | N | N | Y | Y | Y | Y | N | N | N | N | N | Y |
| D6 | swipe actions on rows | Y | Y | P | Y | N | Y | P | Y | P | N | N | N | N | N | Y |
| D7 | focus order / tab traversal | Y | Y | Y | Y | Y | Y | Y | Y | P | Y | Y | Y | Y | Y | Y |
| D8 | adaptive layout *(kaya has)* | Y | Y | Y | P | Y | Y | N | Y | Y | Y | Y | N | Y | P | Y |
| | **Developer tooling** |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |
| E1 | hot reload | P | Y | Y | P | N | Y | P | Y | Y | Y | Y | N | Y | Y | Y |
| E2 | inspector / devtools | Y | P | Y | Y | Y | Y | P | Y | Y | Y | Y | Y | Y | P | Y |
| E3 | testing / driving harness | Y | Y | Y | Y | P | P | Y | P | P | Y | Y | Y | Y | P | Y |
| E4 | packaging / signing / distribution | Y | Y | Y | Y | Y | Y | Y | Y | Y | Y | Y | N | N | P | Y |
| E5 | auto-update | P | P | P | P | P | Y | P | N | P | Y | Y | N | N | N | N |

---

# Part three: what the matrix says for kaya

The counts below are taken over the **ten full toolkits** — SwiftUI, Compose,
Flutter, Qt, GTK4, WinUI 3, Avalonia, MAUI, React Native, Uno — and not over
all fifteen columns. Electron and Tauri are shells around a webview and egui,
iced and Slint are an order of magnitude smaller in scope; including them
would understate what a toolkit in kaya's position is expected to have. The
Electron/Tauri and Rust-native columns stay in the matrix because they are
informative on the *system* rows, where they are frequently ahead.

Two counts per feature: `Y` is first-party, `Y+P` is "an app on this framework
can get it at all", including through a named package. The second number is the
one that matters for kaya, because kaya owns all five of its backends and has no
package ecosystem to delegate to — whatever a kaya app needs, kaya ships.

## 1. Table stakes — kaya lacks these and nearly everyone ships them first-party

Threshold: first-party (`Y`) in at least 8 of the 10 full toolkits.

| ID | Feature | Y / 10 | Note |
|----|---------|:-----:|------|
| A1 | **toggle switch** distinct from checkbox | 10 | The single most universal control kaya does not have. `Toggle`+`.switch`, `Switch`, `Adw`/`GtkSwitch`, `ToggleSwitch`, `SwitchCell`. The only dissent anywhere: Electron `N` (HTML has no switch element), Tauri `P`, egui `N`. |
| A4 | secure / password entry | 10 | Unanimous across all 15 columns. |
| A10 | sheet / modal beyond a plain alert | 10 | kaya has alerts with two actions; every toolkit also has an arbitrary-content modal (`.sheet`, `ModalBottomSheet`, `showDialog`, `AdwDialog`, `ContentDialog`, `Popup`). |
| A12 | hyperlink / rich or attributed text / markdown | 10 | Unanimous across all 15. Ranges from `Link`+`AttributedString` to `AnnotatedString` to Slint's `@markdown()`. |
| A13 | activity indicator distinct from a progress bar | 10 | kaya's `progress` has an indeterminate mode, so this is closer than it looks; the distinction elsewhere is a separate spinner control. |
| B11 | URL schemes / deep links | 10 | Unanimous among full toolkits; the three Rust natives are the only `N`s anywhere. |
| C2 | RTL layout mirroring | 10 | Automatic in all ten. The Rust natives are the exception: egui does not mirror layout at all, iced and Slint only partly — they shape RTL *text* and largely stop there. |
| D1 | animations / transitions API | 10 | Unanimous across all 15 columns — the only feature besides secure entry and rich text with no dissent. |
| D3 | scroll-to programmatic | 10 | Unanimous across all 15. |
| D4 | horizontal scroll | 10 | Unanimous across all 15. |
| E4 | packaging / signing / distribution | 10 | Only egui and iced have no story. |
| C6 | IME and composition | 9 | 14 of 15 overall. This is the one where "we never thought about it" ships a toolkit that CJK users cannot type into. |
| D7 | keyboard focus order / tab traversal | 9 | 14 of 15 overall. |
| A6 | search field as a distinct control | 8 | `.searchable`, `SearchBar`, `SearchBox`, `GtkSearchEntry`, Qt 6.10's new `SearchField`. |
| A9 | popover | 8 | Every full toolkit; kaya has menus and alerts but no anchored transient surface. |
| C1 | localization / string tables | 8 | |
| C4 | date / number formatting | 8 | |
| E2 | inspector / devtools | 8 | Live view-hierarchy inspection. kaya has a scene harness (E3) but nothing to look at a running tree with. |
| D5 | pull-to-refresh | 8 | Mobile idiom: `Y` on all the toolkits that target phones, `N` on Qt and GTK, which do not. kaya targets iOS and Android, so this counts. |

Reading this list: the gaps are not exotic. **Eleven of the nineteen are
unanimous.** Four of them (D1, D3, D4, C6) are not controls at all but basic
mechanics of a scrolling, animated, text-entering UI — the kind of thing whose
absence is felt on every screen rather than on one.

## 2. Differentiators — a minority ship these; optional for kaya

Threshold: available at all (`Y+P`) in 7 or fewer of the 10.

| ID | Feature | Y / Y+P | Note |
|----|---------|:------:|------|
| B4 | global hotkeys | 0 / 5 | **No full toolkit ships this first-party.** The only two `Y`s in the entire matrix are Electron's `globalShortcut` and Tauri's `plugin-global-shortcut`. Wayland forbids it outright without a portal. |
| B19 | launch at login | 2 / 4 | The rarest system feature after global hotkeys. |
| B7 | window position/size persistence | 1 / 5 | Almost every framework leaves this to the app. Tauri's `plugin-window-state` is the notable exception. |
| B8 | session / state restoration | 2 / 6 | Apple's `SceneStorage`/`NSUserActivity` and Android's `rememberSaveable` are the real implementations; elsewhere it is app work. |
| B12 | file type associations | 4 / 6 | Usually a packaging-manifest concern rather than an API. |
| B2 | system tray / status item | 4 / 7 | MAUI, Uno and React Native have none; GTK4 deleted its tray API in the Wayland migration. |
| B9 | recent files / bookmarks | 4 / 7 | |
| B10 | share sheet | 4 / 7 | |
| B13 | printing | 2 / 7 | Even SwiftUI has no printing API — you fall to `NSPrintOperation`. Qt and GTK are the strong ones here. |
| B20 | background tasks | 2 / 7 | |
| B3 | dock / taskbar badge | 3 / 7 | |
| C7 | spellcheck | 3 / 7 | Usually inherited from the native text widget rather than configurable. |
| B23 | haptics | 6 / 8 | Mobile-only concept; Avalonia's `PlatformFeedback` was a surprise. |
| E5 | auto-update | 1 / 8 | The desktop *shells* own this (Electron `autoUpdater`, Tauri `plugin-updater` with mandatory signature checks); toolkits do not. |
| C5 | dynamic type / user font scaling | 7 / 8 | Borderline — automatic on the mobile-first frameworks, absent on the desktop-first ones. |

Between the two lists sits a **third tier worth naming separately: features every
framework's users can get, but almost nobody ships first-party.** `Y+P` is 9 or
10 out of 10 while `Y` is 6 or fewer: local notifications (Y=3), webview (5),
audio playback (5), biometrics/keychain (2), plural rules (5), colour picker (6),
map (5), badge (6), camera/photo picker (5), reduced-motion honouring (5),
segmented control (5), window styles (4). For every other toolkit these are a
package away. **kaya has no package ecosystem, so for kaya each of these is
either first-party work or a hole**, which makes this tier the one where kaya's
architecture costs it the most — and, equally, where shipping them natively on
five backends would be the clearest differentiator, because nobody else does.

## 3. Widely shipped and not on kaya's candidate list at all

These came out of the per-framework `OFF-LIST` sweeps: things named prominently
in several frameworks' own documentation that appear nowhere in kaya's 70-item
candidate list or its "not shipped" inventory.

1. **Transient message surface — toast / snackbar / inline banner.** `AdwToast`
   + `AdwToastOverlay` (with an undo action built in), WinUI `InfoBar` and
   `TeachingTip`, Material `Snackbar` in Compose, Flutter `SnackBar`, MAUI
   Community Toolkit `Toast`. This is how every one of them reports "deleted, undo?"
   — and kaya has core-owned undo with no surface to offer it on.
2. **Gestures beyond drag: pinch, rotate, long-press, and gesture composition.**
   SwiftUI `MagnifyGesture`/`RotateGesture`/`.sequenced(before:)`, React Native's
   gesture responder system and `PanResponder`, Flutter `GestureDetector` and
   `InteractiveViewer`, Slint `ScaleRotateGestureHandler`/`SwipeGestureHandler`,
   Compose `pointerInput`. kaya has drag and drop and nothing else; on a canvas
   or a map, pinch-zoom is the interaction.
3. **Mobile chrome as layout input: safe-area insets and soft-keyboard
   avoidance.** Compose `WindowInsets`, Flutter `SafeArea`/`MediaQuery.viewInsets`,
   React Native `KeyboardAvoidingView` + `SafeAreaView`, Slint's
   `Window.safe-area-insets`/`virtual-keyboard-position`. kaya has an `inset` prop
   but nothing that reacts to the keyboard, and it ships on iOS and Android.
4. **An escape hatch to a native view.** `UIViewRepresentable`/`NSViewRepresentable`,
   `AndroidView`/`UIKitView`/`SwingPanel`, MAUI `Handler.Mapper`, Avalonia
   `NativeControlHost`, RN Fabric Native Components, Uno's native-hosting mode.
   Every mature toolkit has a documented way to drop to the platform when the
   abstraction runs out. kaya's five-backend uniformity invariant makes this the
   hardest thing on this list — and the most conspicuous absence.
5. **A styling system beyond a brand tier.** GTK CSS with selectors and live
   reload, Avalonia's selector styles with pseudo-classes, MAUI's CSS + XAML
   styles, Uno Themes, Slint's `Palette`/`StyleMetrics`. kaya has accent colour
   and typeface family; everyone else has a cascade or a token set.
6. **Charts.** Swift Charts, Qt Graphs, Avalonia's (paid) 130-type pack,
   Syncfusion/Telerik on MAUI. kaya has a canvas, which is the raw material.
7. **Disclosure / expander.** SwiftUI `DisclosureGroup`, WinUI `Expander`,
   `AdwExpanderRow`, Flutter `ExpansionTile`, HTML `<details>`. Small, and in
   nearly every catalogue.
8. **Collection pipelines as reusable objects.** Qt's `QSortFilterProxyModel`
   and GTK's `GtkFilterListModel`/`GtkSortListModel`/`GtkSelectionModel` make
   sorting, filtering and selection composable model objects rather than per-view
   code. kaya's tables emit `sort_requested` and leave the rest to the app.
9. **Custom title bar and window material.** WinUI `TitleBar` + `SystemBackdrop`
   (Mica/Acrylic), MAUI `TitleBar`, Electron's frameless-window options,
   SwiftUI's Liquid Glass vocabulary.
10. **Device and sensor APIs as part of the framework.** MAUI Essentials
    (`TextToSpeech`, `Geolocation`, `Contacts`, `Battery`, `Flashlight`,
    `Screenshot`, the whole sensor set), Tauri's geolocation/NFC/barcode plugins,
    Uno's WinRT sensor shims. Whether a GUI library should own these is a real
    question — but three of the surveyed frameworks answered yes.

Two smaller ones worth a line each: **screenshot / view-tree capture** (MAUI
`Screenshot`, Electron `desktopCapturer`, and the mechanism behind Flutter's
`matchesGoldenFile` golden tests — kaya has recording mode, which is adjacent),
and **crash reporting** (Electron's `crashReporter` is first-party; kaya's own
inventory lists it as not shipped but it was not on the candidate list).

## Caveats on this survey

- Verdicts are documentation-derived, not compiled. A `Y` means the framework's
  own docs name the API; nobody built an app against it.
- Three Uno rows are `?` (file associations, text scaling, high-contrast) and one
  Tauri and one Electron row are hedged in their section text rather than
  asserted; those are noted where they sit.
- Avalonia was surveyed against 12.1.2, the current stable, not the v11 the charge
  named. Several of its controls have moved behind a paid licence since v11.
- iced 0.14.0 was released 2026-09-04, one day before this survey; four of its
  developer-tooling rows changed with that release.
