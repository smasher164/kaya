# The search field, the platforms' own documentation (survey 2026-09-06)

Read for docs/search-plan.md §0. Written by a research agent from the vendors' documentation; every fact carries a URL and the unverified ones say so.


Researched 2026-09-06 for kaya docs/tasks-plan.md §6 S1. Every fact below carries a URL;
where a claim could not be verified from official docs it is marked UNVERIFIED.

## 1. THE WIDGET — per platform

### macOS / iOS (SwiftUI, `swift/KayaSwiftUI.swift`)

**`.searchable(text:placement:prompt:)`** — "Marks this view as searchable, which
configures the display of a search field." iOS 15.0+ / macOS 12.0+ / visionOS 1.0+ /
watchOS 8.0+ / tvOS 15.0+.
<https://developer.apple.com/documentation/swiftui/view/searchable(text:placement:prompt:)>

**THE STRUCTURAL REQUIREMENT (this is the surprise for kaya).** Apple's own article
"Adding a search interface to your app" opens with it:

> "Add a search interface to your app by applying one of the searchable view modifiers
> — like `searchable(text:placement:prompt:)` — to a `NavigationSplitView` or
> `NavigationStack`, or to a view inside one of these. A search field then appears in
> the toolbar. The precise placement and appearance of the search field depends on the
> platform, where you put the modifier in code, and its configuration."

So `.searchable` is NOT a widget you can place. It is a modifier that asks the enclosing
navigation container to grow a search field somewhere of its own choosing. On a plain
`VStack` with no navigation container above it there is no toolbar to host the field and
nothing renders. (Not verified by running it — Apple's doc states the requirement; I did
not find a sentence that says explicitly "renders nothing otherwise".)
<https://developer.apple.com/documentation/swiftui/adding-a-search-interface-to-your-app>

**Automatic placement, per Apple:**
- **macOS**: "the search field appears on the trailing edge of the toolbar" (when applied
  to a `NavigationSplitView`).
- **iOS/iPadOS**: "In a double-column view, the search field appears in the first column.
  In a triple-column view, it appears at the top of the middle column."
Same URL.

**`SearchFieldPlacement` cases** — `automatic`, `toolbar`, `sidebar`,
`navigationBarDrawer`, `navigationBarDrawer(displayMode:)`, `toolbarPrincipal`. All six are
declared available on iOS 15+/macOS 12+ (the availability table does not restrict any case
to one platform), and "If SwiftUI can't satisfy the placement request, it relies on
automatic placement rules."
<https://developer.apple.com/documentation/swiftui/searchfieldplacement>

**There is no SwiftUI `TextFieldStyle` for search.** (Checked the TextFieldStyle
documentation set — see below. The AppKit widget is the only real search field on macOS.)

**AppKit `NSSearchField`** — a subclass of `NSTextField`, wrapping `NSSearchFieldCell`;
"a customized text input area, a search button, a cancel button, and a pop-up icon menu
for recent searches and custom categories."
<https://developer.apple.com/documentation/appkit/nssearchfield>

Behaviour knobs on NSSearchField (all from the same page and its property pages):
- `sendsWholeSearchString` — "True: send on button click/Return key. False: send after each
  keystroke." So AppKit's search field is **incremental by default** and opt-out.
- `sendsSearchStringImmediately` — send the action immediately when appropriate.
- `recentSearches: [String]`, `maximumRecents: Int`,
  `recentsAutosaveName: NSSearchField.RecentsAutosaveName?` — the **recents menu**, built
  from `searchMenuTemplate: NSMenu?` with the tags `recentsMenuItemTag`,
  `recentsTitleMenuItemTag`, `clearRecentsMenuItemTag`, `noRecentsMenuItemTag`.
- `cancelButtonBounds`, `searchButtonBounds`, `searchTextBounds` — so the field is a
  three-part thing: magnifier button, text, cancel button.
- `NSSearchFieldDelegate` reports search started / search ended.
<https://developer.apple.com/documentation/appkit/nssearchfield>

### GTK4 + libadwaita (`crates/kaya/src/gtk.rs`)

**`GtkSearchEntry`** — "A single-line text entry widget for use as a search entry",
implements `GtkEditable`.
- **`search-changed`** is the filtering signal, and it is **debounced**: emitted "with a
  delay after the user stops typing".
- **`search-delay`** (guint, GTK **4.8+**) — "The delay in milliseconds from last keypress
  to the search changed signal." **Default 150.**
  <https://docs.gtk.org/gtk4/property.SearchEntry.search-delay.html>
- Other signals: `search-started`, `next-match`, `previous-match`, **`stop-search`**
  ("emitted when the user terminates a search via keyboard", i.e. Escape), `activate`.
- Clear icon, built in: "will show an inactive symbolic 'find' icon when empty, and a
  symbolic 'clear' icon when there is text. Clicking the 'clear' icon will empty the
  search entry."
- `placeholder-text`: "The text that will be displayed in the GtkSearchEntry when it is
  empty and unfocused."
- `key-capture-widget` — capture keystrokes from another widget (type-to-search) without
  a GtkSearchBar.
- **Accessible role: `GTK_ACCESSIBLE_ROLE_SEARCH_BOX`.** CSS node `entry.search ╰── text`.
<https://docs.gtk.org/gtk4/class.SearchEntry.html>

**`GtkSearchBar`** — "Reveals a search entry when search is started." Holds an editable via
`connect_entry()`; `search-mode-enabled` shows/hides it; `show-close-button`;
`set_key_capture_widget()` for type-to-search from the window; "**Escape hides the search
bar**". Accessible role **`GTK_ACCESSIBLE_ROLE_SEARCH`** (a landmark, distinct from the
entry's SEARCH_BOX role).
<https://docs.gtk.org/gtk4/class.SearchBar.html>

### Windows / WinUI 3 (`crates/kaya/src/winui/`)

Microsoft's own routing sentence, from the text-controls chooser: "Use an **AutoSuggestBox**
control to show the user a list of suggestions to choose from as they type. … **You should
also use an AutoSuggestBox control to implement a search box.**" There is no `SearchBox`
control and no documented "search" style for `TextBox`.
<https://learn.microsoft.com/en-us/windows/apps/design/controls/text-controls>

**AutoSuggestBox**, the three events:
- **`TextChanged`** — "occurs whenever the content of the text box is updated. Use the event
  args `Reason` property to determine whether the change was due to user input. If the
  change reason is **UserInput**, filter your data based on the input."
  (`AutoSuggestionBoxTextChangeReason`: `UserInput`, `ProgrammaticChange`,
  `SuggestionChosen` — the enum is why kaya must not echo its own model write back as a
  user edit.)
- **`SuggestionChosen`** — keyboard navigation of the popup, updates the text box.
- **`QuerySubmitted`** — "occurs when a user commits a query string": Enter or a click on
  the query icon (`ChosenSuggestion` is null), or Enter/click/tap on a suggestion list item
  (`ChosenSuggestion` is the item). `QueryText` always carries the text box text.
- **Search look**: "By default, the text entry box doesn't have a query button shown. You
  can set the `QueryIcon` property to add a button with the specified icon on the right side
  of the text box. For example, to make the AutoSuggestBox look like a typical search box,
  add a 'find' icon: `<AutoSuggestBox QueryIcon="Find"/>`."
- Anatomy: "an optional header and a text box with optional hint text" (`PlaceholderText`);
  "The auto-suggest results list populates automatically once the user starts to enter text.
  The results list can appear above or below the text entry box. **A 'clear all' button
  appears**."
<https://learn.microsoft.com/en-us/windows/apps/design/controls/auto-suggest-box>

### Android / Compose Material 3 (`android/kaya/src/main/kotlin/dev/kaya/KayaCompose.kt`)

**Version matters here.** `android/kaya/build.gradle.kts` pins
`platform("androidx.compose:compose-bom:2024.10.01")`, which maps to
**material3 1.3.1**.
<https://developer.android.com/develop/ui/compose/bom/bom-mapping>

At 1.3.1 the search API is the slot-based pair, both `@ExperimentalMaterial3Api`:

```kotlin
SearchBar(inputField = { … }, expanded: Boolean, onExpandedChange: (Boolean) -> Unit,
          modifier, shape, colors, tonalElevation, shadowElevation, windowInsets,
          content: @Composable ColumnScope.() -> Unit)

SearchBarDefaults.InputField(query: String, onQueryChange: (String) -> Unit,
          onSearch: (String) -> Unit, expanded: Boolean, onExpandedChange: (Boolean) -> Unit,
          modifier, enabled, placeholder, leadingIcon, trailingIcon, colors, interactionSource)
```
`DockedSearchBar` takes the same `inputField`/`expanded` pair.
<https://developer.android.com/develop/ui/compose/components/search-bar>

The KDoc in AndroidX source states the expansion rule that matters to kaya:

> "A [SearchBar] tries to occupy the entirety of its allowed size in the expanded state. For
> full-screen behavior as specified by Material guidelines, parent layouts of the [SearchBar]
> must not pass any [Constraints] that limit its size, and the host activity should set
> `WindowCompat.setDecorFitsSystemWindows(window, false)`. If this expansion behavior is
> undesirable, for example on large tablet screens, [DockedSearchBar] can be used instead."

<https://android.googlesource.com/platform/frameworks/support/+/refs/heads/androidx-main/compose/material3/material3/src/commonMain/kotlin/androidx/compose/material3/SearchBar.kt>

**Deprecation note (forward-looking, NOT what 1.3.1 has).** On androidx-main (material3
1.4/1.5) both the `inputField` `SearchBar` and the `query`-based
`SearchBarDefaults.InputField` are `@Deprecated`:
`"Use SearchBar with SearchBarState, and ExpandedFullScreenSearchBar or ExpandedDockedSearchBar
to display results."` / `"Use SearchBarDefaults.InputField with TextFieldState and
SearchBarState."` New names there: `TopSearchBar`, `AppBarWithSearch`,
`ExpandedFullScreenSearchBar`, `ExpandedDockedSearchBar`, `rememberSearchBarState`. Same
source URL. If kaya bumps the BOM, the arm has to move.

**The alternative kaya may prefer**: a plain `OutlinedTextField`/`TextField` with
`leadingIcon = { Icon(Icons.Default.Search, …) }` and a trailing clear `IconButton`. That is
NOT a Material "search bar"; see §4 for what M3 says about placement.

### iOS, the field that lives INSIDE content rather than the bar

`UISearchBar` — "A specialized view for receiving search-related information from the user.
… provides a text field for entering text, a search button, a bookmark button, and a cancel
button. **A search bar doesn't actually perform any searches.** You use a delegate … to
implement the actions when the user enters text or clicks buttons."
<https://developer.apple.com/documentation/uikit/uisearchbar>

`UISearchTextField` (iOS 13+), a **subclass of `UITextField`** — "UISearchBar hosts a search
text field, but you may also use a search text field in other roles, such as the title view
of a `UINavigationItem`." It is the class that carries **tokens** (chips), which "always
appear contiguously before any text".
<https://developer.apple.com/documentation/uikit/uisearchtextfield>

So on iOS there are two honest lowerings: `.searchable` (bar-owned, needs a navigation
container) or a `UISearchTextField`/styled `TextField` placed inline in the list. Apple's own
HIG blesses both — see §4.

---

## 2. BEHAVIOUR THAT MUST BE UNIFORM

| question | macOS | iOS | GTK4 | WinUI 3 | Compose M3 |
|---|---|---|---|---|---|
| incremental by default | **yes** (`sendsWholeSearchString` defaults false) | **yes** (`.searchable` binding updates per keystroke) | **yes**, but **debounced 150 ms** | **yes** (`TextChanged`, every edit) | **yes** (`onQueryChange` per edit) |
| built-in debounce | no (`sendsSearchStringImmediately` is a knob, not a timer) | none documented | **`search-delay`, default 150 ms** | none | none |
| a submit event exists | Return, when `sendsWholeSearchString` | `onSubmit(of: .search)` | `activate` signal | `QuerySubmitted` | `onSearch` (`ImeAction.Search`) |
| clear button | built into NSSearchField (`cancelButtonBounds`) | built into UISearchBar/`.searchable` | built in: 'find' icon when empty, 'clear' icon when not, click empties it | AutoSuggestBox shows a "clear all" button | **not built in** — you pass `trailingIcon` yourself |
| Escape | (AppKit's field-editor cancel) | — | `stop-search` on the entry; **`GtkSearchBar` hides on Escape** | — | back/predictive-back collapses the expanded bar |
| return key | submits (see above) | submits; keyboard return key is the **Search** key | `activate` | `QuerySubmitted` with `ChosenSuggestion == null` | `onSearch`; IME action is **forced** to `ImeAction.Search` |

Notes with citations:

- **macOS is incremental unless told otherwise.** `sendsWholeSearchString` — "True: send on
  button click/Return key. False: send after each keystroke."
  <https://developer.apple.com/documentation/appkit/nssearchfield>
- **SwiftUI is incremental by design.** "By updating search results as people type, you ensure
  that your app's search interface is responsive," with the escape hatch stated: "Alternatively,
  you can wait until someone submits the query before conducting the search."
  <https://developer.apple.com/documentation/swiftui/performing-a-search-operation>
  Submission is `onSubmit(of: .search)` — "Invokes an action when someone submits the search
  query by pressing the Return key."
  <https://developer.apple.com/documentation/swiftui/managing-search-interface-activation>
- **GTK is the ONE platform with a documented timer.** `search-changed` is "emitted with a
  delay after the user stops typing"; `search-delay` "The delay in milliseconds from last
  keypress to the search changed signal", **default 150**, GTK 4.8+.
  If kaya wants one observable semantics, either every backend debounces 150 ms or GTK's
  delay is set to 0 and `changed` semantics are used. The scene harness makes this visible:
  a `set_text` followed immediately by an `expect_rows` will read the UNFILTERED list on GTK
  and the filtered one everywhere else unless the runner's answer-wait covers 150 ms.
  <https://docs.gtk.org/gtk4/class.SearchEntry.html>,
  <https://docs.gtk.org/gtk4/property.SearchEntry.search-delay.html>
- **WinUI needs the reason filter.** "Use the event args `Reason` property to determine
  whether the change was due to user input. **If the change reason is UserInput**, filter your
  data based on the input." `AutoSuggestionBoxTextChangeReason` distinguishes `UserInput` from
  `ProgrammaticChange` and `SuggestionChosen`. kaya's backends write the model back into the
  control on every apply, so without this filter the WinUI arm would publish a text-changed
  occurrence for its own write — the same class as the existing "banked text writes" work.
  <https://learn.microsoft.com/en-us/windows/apps/design/controls/auto-suggest-box>
- **Compose forces the IME action.** In `SearchBarDefaults.InputField`:
  `keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search)` and
  `keyboardActions = KeyboardActions(onSearch = { onSearch(query) })`; the newer overload's
  KDoc says outright "Note that the [ImeAction] will always be overwritten with
  [ImeAction.Search]." That is the "search keyboard return key" on Android, for free, and NOT
  overridable.
  <https://android.googlesource.com/platform/frameworks/support/+/refs/heads/androidx-main/compose/material3/material3/src/commonMain/kotlin/androidx/compose/material3/SearchBar.kt>
- **iOS Cancel.** `UISearchController.automaticallyShowsCancelButton`: "By default,
  [UISearchController] shows the search bar's cancel button when search becomes active and
  hides it when the user dismisses search."
  <https://developer.apple.com/documentation/uikit/uisearchcontroller/automaticallyshowscancelbutton>
  In SwiftUI the equivalents are the `isSearching` environment value — "Becomes true when
  someone first taps or clicks in a search field … false when they cancel the search operation
  or when you programmatically dismiss the interface" — and the `dismissSearch` action.
  **NOT DOCUMENTED, and I could not verify:** whether cancelling CLEARS the text binding.
  Apple's page says only that the interface is dismissed; it does not say the binding is
  emptied. This has to be settled by observation before kaya freezes a scene around it.

---

## 3. ACCESSIBILITY — what a search field reports

kaya's harness reads each platform's tree (`expect_ax`), so this table is what the frozen
verdict text would have to be.

| platform | what a search field reports | citation |
|---|---|---|
| **macOS AX** | role `AXTextField` **plus subrole `AXSearchField`**. The modern name is `NSAccessibility.Subrole.searchField` — "A search field subrole." Its ObjC constant (the JSON's `externalID`) is `NSAccessibilitySearchFieldSubrole`. | <https://developer.apple.com/documentation/appkit/nsaccessibility-swift.struct/subrole/searchfield> |
| **SwiftUI (both Apple platforms)** | `AccessibilityTraits.isSearchField` — "The accessibility element is a search field." macOS 10.15+, iOS 13+. | <https://developer.apple.com/documentation/swiftui/accessibilitytraits/issearchfield> |
| **UIKit / iOS** | `UIAccessibilityTraits.searchField` (`UIAccessibilityTraitSearchField`) — "The accessibility element behaves like a search field." | <https://developer.apple.com/documentation/uikit/uiaccessibilitytraits/searchfield> |
| **GTK4** | `GtkSearchEntry` **is** `GTK_ACCESSIBLE_ROLE_SEARCH_BOX` (a plain `GtkEntry` is a text box). `GtkSearchBar` is `GTK_ACCESSIBLE_ROLE_SEARCH` — a landmark, not the field. | <https://docs.gtk.org/gtk4/class.SearchEntry.html>, <https://docs.gtk.org/gtk4/class.SearchBar.html> |
| **WinUI 3 / UIA** | **There is NO Search control type.** The `ControlType` roster is Button…Window with `Edit` ("an edit control, such as a text box") and no search member. What UIA has is a **landmark**: `UIA_SearchLandmarkTypeId = 80004`, "Indicates that the landmark is related to search type elements", settable in XAML through `AutomationProperties.LandmarkType` / `LocalizedLandmarkType`. `AutoSuggestBoxAutomationPeer`'s own control type is not stated on its reference page — **UNVERIFIED**; it must be read off a live tree. | <https://learn.microsoft.com/en-us/dotnet/api/system.windows.automation.controltype>, <https://learn.microsoft.com/en-us/windows/win32/winauto/landmark-type-identifiers>, <https://learn.microsoft.com/en-us/windows/windows-app-sdk/api/winrt/microsoft.ui.xaml.automation.automationproperties> |
| **Compose** | **There is NO search Role.** `androidx.compose.ui.semantics.Role`'s whole roster is Button(0), Checkbox(1), Switch(2), RadioButton(3), Tab(4), Image(5), DropdownList(6), ValuePicker(7), Carousel(8) — read out of SemanticsProperties.kt on androidx-main. Material3's own `SearchBarDefaults.InputField` instead sets `contentDescription = getString(Strings.SearchBarSearch)` and, while expanded, `stateDescription = getString(Strings.SuggestionsAvailable)`. So on Android a search field announces as a text field carrying the content description "Search". | <https://android.googlesource.com/platform/frameworks/support/+/refs/heads/androidx-main/compose/ui/ui/src/commonMain/kotlin/androidx/compose/ui/semantics/SemanticsProperties.kt>, <https://android.googlesource.com/platform/frameworks/support/+/refs/heads/androidx-main/compose/material3/material3/src/commonMain/kotlin/androidx/compose/material3/SearchBar.kt> |

**The consequence for kaya's uniform-semantics rule.** Three platforms have a first-class
search identity in the tree (macOS subrole, iOS trait, GTK role); two do not (UIA has only a
landmark, Compose has nothing). A frozen `expect_ax` string that says "search field" cannot be
byte-identical across five lanes off the platform's own vocabulary — the honest shapes are
either (a) kaya's harness NORMALISES: mac subrole / iOS trait / GTK role → the word "search",
with WinUI and Compose read off the label kaya sets itself; or (b) the observable is kaya's own
role prop rather than the platform's, and the platform identity is checked once per backend by
a gate. Today the mac harness already folds `kAXTextFieldRole` to the string `"field"`
(`swift/KayaSwiftUI.swift:5178`), so the normalising table already exists and would grow a
`"search"` arm.

---

## 4. PLACEMENT CONVENTIONS (the HIGs)

### Apple — HIG "Search fields"
<https://developer.apple.com/design/human-interface-guidelines/search-fields>
(JSON: `https://developer.apple.com/tutorials/data/design/human-interface-guidelines/search-fields.json`
— note the path is `/tutorials/data/design/…`, NOT `/tutorials/data/documentation/design/…`;
the latter 404s. Worth adding to the Apple-docs-JSON memory note.)

> "If possible, start search immediately when a person types. Searching while someone types
> makes the search experience feel more responsive because it provides results that are
> continuously refined as the text becomes more specific."

**iOS** — "There are three main places you can position the entry point for search: As a tab in
a tab bar; In a toolbar at the bottom or top of the screen; Directly inline with content."
And, precisely kaya's S1 case:

> "**Search as an inline field.** In some cases you might want your app to include a search
> field inline with content. Place search as an inline field when its position alongside the
> content it searches strengthens that relationship. When you need to filter or search within a
> single view, it can be helpful to have search appear directly next to content to illustrate
> that the search applies to it, rather than globally. … For example, although the main search
> in the Music app is a tab, people can navigate to their library and use an inline search
> field to filter their songs and albums."
>
> "When at the top, position an inline search field above the list it searches, and consider
> pinning it to the top toolbar when scrolling."

**iPadOS + macOS** (one section, deliberately):

> "Put a search field at the trailing side of the toolbar for many common uses. Many apps
> benefit from the familiar pattern of search in the toolbar, particularly apps with split
> views that need to search across multiple columns of information, like Mail, Notes, and Voice
> Memos."
>
> "Include search at the top of the sidebar when filtering content or navigation there."

So for a task manager whose sidebar is sections and whose column is the open list, Apple's own
answer is: **trailing side of the toolbar** on the Mac, and on iPhone either a bottom-toolbar
search or an **inline field pinned above the list**.

### GNOME — HIG "Search"
<https://developer.gnome.org/hig/patterns/nav/search.html>

- The standard pattern is "a search bar which slides down from beneath the header bar",
  revealed by type-to-search, Ctrl+F, or a header-bar toggle button.
- But the carve-out kaya wants is written into the HIG: "if search is particularly important
  to your app, the search entry can be located elsewhere and made to be permanently visible."
- "Search should be 'live' wherever possible — the content view should update to display search
  results as they are entered."
- It names the two widgets: `GtkSearchBar` (the sliding container) and `GtkSearchEntry` (the
  field).

### Windows
Microsoft has no standalone "Search" design page; the guidance is split:
- Control choice: "**You should also use an AutoSuggestBox control to implement a search box.**"
  <https://learn.microsoft.com/en-us/windows/apps/design/controls/text-controls>
- Placement: the search box is a first-class slot of `NavigationView`'s pane — "An optional
  `AutoSuggestBox` control to allow for **app-level search**. Assign the control to the
  `NavigationView.AutoSuggestBox` property", and the pane anatomy lists it as item 4/5 between
  the nav items and the Settings button, with the sample
  `<AutoSuggestBox x:Name="NavViewSearchBox" QueryIcon="Find"/>`.
  <https://learn.microsoft.com/en-us/windows/apps/design/controls/navigationview>
  That slot is for search across the app. For a field that filters ONE list, Windows has no
  contrary rule — an `AutoSuggestBox` with `QueryIcon="Find"` above the list is the idiom.

### Material 3 / Android
`m3.material.io` is a JavaScript shell to WebFetch and its guidance body could not be
extracted; the page's own description is "Search lets people enter a keyword or phrase to get
relevant information. Search bars can display suggested keywords or phrases as the user types."
(<https://m3.material.io/components/search/guidelines>). **The guidance body is UNVERIFIED
here.** What IS citable comes from AndroidX's own KDoc, which encodes the placement rule:

> "A search bar represents a **floating** search field that allows users to enter a keyword or
> phrase and get relevant information. It can be used as a way to navigate through an app via
> search queries. A search bar expands into a search 'view' and can be used to display dynamic
> suggestions or search results."
>
> "A [SearchBar] tries to occupy the entirety of its allowed size in the expanded state. For
> **full-screen behavior as specified by Material guidelines**, parent layouts of the
> [SearchBar] must not pass any [Constraints] that limit its size … If this expansion behavior
> is undesirable, for example on large tablet screens, [DockedSearchBar] can be used instead."

<https://android.googlesource.com/platform/frameworks/support/+/refs/heads/androidx-main/compose/material3/material3/src/commonMain/kotlin/androidx/compose/material3/SearchBar.kt>

Compose's own guide page describes `SearchBar` as a field with a results dropdown driven by
`expanded`/`onExpandedChange`, and never as a plain inline filter:
<https://developer.android.com/develop/ui/compose/components/search-bar>.
Android's app-bar guide has **nothing** about search in a top app bar
(<https://developer.android.com/develop/ui/compose/components/app-bars>) — the M3 search bar
floats over content instead of living in the bar.

---

## 5. THE THINGS THAT WOULD SURPRISE A DESIGN WRITTEN FROM MEMORY

1. **`.searchable` is not a widget — it is a request to a navigation container.** Apple:
   "Add a search interface to your app by applying one of the searchable view modifiers … to a
   `NavigationSplitView` or `NavigationStack`, or to a view inside one of these. A search field
   then appears **in the toolbar**." There is no `SearchField` view in SwiftUI and no
   `TextFieldStyle` for search. kaya's SwiftUI backend already builds `NavigationStack` /
   `NavigationSplitView` (`swift/KayaSwiftUI.swift:17135`, `:17272`), so the container exists —
   but a search field declared in the middle of a kaya column would NOT render where it was
   declared. It would jump to the toolbar (mac) or the navigation bar (iOS). If kaya wants the
   field WHERE THE GUEST PUT IT, the mac/iOS arm has to be a `TextField` styled as a search box
   (magnifier `Image` + clear `Button` + `.accessibilityAddTraits(.isSearchField)`), or
   `NSViewRepresentable`/`UIViewRepresentable` around `NSSearchField`/`UISearchTextField` — the
   documented drop-down escape the roster already allows.
   <https://developer.apple.com/documentation/swiftui/adding-a-search-interface-to-your-app>

2. **Where `.searchable` lands is not the app's choice.** "If SwiftUI can't satisfy the
   placement request, it relies on automatic placement rules" — a `.searchable(placement:)` is
   a preference, not an instruction. That is exactly the class of thing kaya's byte-frozen
   scenes cannot assert across platforms.
   <https://developer.apple.com/documentation/swiftui/searchfieldplacement>

3. **GTK's `search-changed` fires 150 ms after the last keystroke, by default.** Every other
   platform's filter event is synchronous with the edit. This is the single biggest threat to a
   shared `.steps` script: `set_text "milk"` then `expect_rows 1` is a race on Linux only.
   `search-delay` (GTK 4.8+) can be set to 0, or the GTK arm can filter off `changed` instead of
   `search-changed` — the latter costs the clear-icon-driven emission, which comes through
   `changed` too, so it is probably fine, but it should be a stated ruling rather than a
   default. <https://docs.gtk.org/gtk4/property.SearchEntry.search-delay.html>

4. **`AutoSuggestBox` is a suggestions control that has been talked into being a search box.**
   Its documented anatomy is a text box plus a results list that "populates automatically once
   the user starts to enter text". kaya's tasks app has no suggestions — the list under it IS
   the result. `QueryIcon="Find"` gets the magnifier, and leaving `ItemsSource` empty is the
   way to have no popup, but the control's flyout machinery is still there and
   `IsSuggestionListOpen` is still a thing. **UNVERIFIED:** whether an AutoSuggestBox with an
   empty `ItemsSource` ever flashes an empty flyout in WinUI 3. That is a live-run question, and
   the MS page's own recommendation — "display a single-line 'No results' message" — implies
   the popup is expected to open.
   <https://learn.microsoft.com/en-us/windows/apps/design/controls/auto-suggest-box>

5. **Material's `SearchBar` is designed to eat the screen.** "A [SearchBar] tries to occupy the
   entirety of its allowed size in the expanded state", and full-screen behaviour additionally
   wants `WindowCompat.setDecorFitsSystemWindows(window, false)` on the host activity — which is
   a change to kaya's Android host, not to a composable. A search field that is meant to sit
   above a list and filter it in place is NOT the M3 SearchBar; it is a `TextField` with
   `leadingIcon = Icons.Default.Search` and a trailing clear `IconButton`, and Compose's clear
   button is **not** provided (unlike all four other platforms, where the clear affordance is
   part of the widget).

6. **The Compose search API is being replaced right now.** kaya pins compose-bom 2024.10.01 →
   material3 **1.3.1**, where `SearchBar(inputField=…, expanded=…)` and
   `SearchBarDefaults.InputField(query=…, onQueryChange=…)` are the API and are
   `@ExperimentalMaterial3Api`. On androidx-main both are already `@Deprecated` in favour of
   `SearchBarState` + `TopSearchBar` / `ExpandedFullScreenSearchBar` / `ExpandedDockedSearchBar`.
   Any Compose arm written against 1.3.1 will need rewriting at the next BOM bump.

7. **NSSearchField carries a recents menu.** `recentSearches`, `maximumRecents`,
   `recentsAutosaveName` and a `searchMenuTemplate` with four reserved item tags. If kaya
   lowers to a real `NSSearchField` it inherits a feature no other platform has and that no
   kaya declaration asks for; if it lowers to a styled `TextField` it does not. Either is
   defensible, but it is a divergence that has to be stated (invariant 1).

8. **`GtkSearchBar` and `GtkSearchEntry` are two different accessible things.** The BAR is
   `GTK_ACCESSIBLE_ROLE_SEARCH` (a landmark); the ENTRY is `GTK_ACCESSIBLE_ROLE_SEARCH_BOX`.
   Reading the wrong one out of the tree is a plausible harness bug.

9. **UIA has no search control type at all.** Windows is the one platform where "this is a
   search field" cannot be said in the control type — only as a `Search` LANDMARK (id 80004)
   on a container. Any design that promises "every backend reports a search role" is wrong on
   Windows before it is written.

10. **iOS's cancel affordance is owned by the search controller, not the field.** "By default,
    [UISearchController] shows the search bar's cancel button when search becomes active and
    hides it when the user dismisses search." An inline `UISearchTextField` (no controller) has
    no Cancel button — only the field's own clear button. So "Escape / Cancel" is not one
    behaviour on iOS; it depends on which of the two lowerings kaya picks.

11. **Apple's HIG JSON lives at a different root than the API JSON.**
    `https://developer.apple.com/tutorials/data/documentation/design/human-interface-guidelines/<page>.json`
    → 404. The working path is
    `https://developer.apple.com/tutorials/data/design/human-interface-guidelines/<page>.json`
    (no `documentation/` segment). Verified by curl: 200 / 46,952 bytes for `search-fields`.

---

## 6. WHAT ONE KAYA DECLARATION HAS TO SURVIVE

`docs/tasks-plan.md:445` states S1 as "a search entry filtering the open list — the search
field (**a role on entry**)". Read against the survey, that spelling holds up: the widget is an
entry everywhere, and what changes per platform is (a) the ornament (magnifier + clear), (b) the
accessible identity, (c) the keyboard's return key, and (d) whether the platform wants it in the
chrome rather than in the column. A role on `entry` buys (a), (b) and (c) with no new kind and no
new construction-sugar surface — it joins `ROLE_DESTRUCTIVE(1) … ROLE_PLAIN(5)` in
`crates/kaya/src/wire.rs:510-514` as a sixth value, and `tools/check-sugar-surface.py`'s role
sweep plus `tools/check-verbs.py`'s role-family clause already demand the name in all nine
bindings and both interpreters the moment it exists.

What the role does NOT settle, and the design must:

- **Placement.** Every HIG surveyed puts a *list filter* above the list it filters (Apple's
  inline field, GNOME's "permanently visible" carve-out, an AutoSuggestBox above the content).
  Only macOS/iPadOS pull it into the toolbar, and only for app-level search. Declaring it in the
  column and rendering it in the column is defensible on all five — but it means the mac arm
  must NOT be `.searchable`.
- **The debounce.** GTK's 150 ms is the only asymmetry. Pick one: everyone debounces, or GTK
  sets `search-delay = 0`.
- **The clear button's event.** On four platforms clearing is the widget's own act and arrives
  as an ordinary text change; on Compose kaya draws the button itself. Either way the guest sees
  one thing: the text became empty. That is already uniform if the design says so.
- **The submit.** Return is a real, separate event on all five. If kaya's search entry filters
  incrementally, Return has nothing to do — the design should say whether it publishes anything
  at all, because Compose will forcibly show a **Search** key on the software keyboard whether or
  not kaya listens.
- **The AX verdict text.** See §3: three platforms can say "search", two cannot.

---

## 7. WHAT I COULD NOT VERIFY

- Whether `.searchable` on macOS renders anything at all in a plain `VStack` with no
  NavigationStack/NavigationSplitView above it. Apple states the requirement but never states
  the failure mode. Needs a probe.
- Whether cancelling/dismissing search in SwiftUI clears the `text` binding.
- Whether a WinUI 3 `AutoSuggestBox` with an empty `ItemsSource` opens an empty flyout.
- `AutoSuggestBoxAutomationPeer`'s reported `AutomationControlType` — the reference page lists
  only inherited members and states no override.
- The body of Material 3's own search guidelines (m3.material.io is a JS shell and has no
  reachable JSON; only the page description was retrievable).
- The literal string behind `NSAccessibilitySearchFieldSubrole`. The docs give the constant's
  name, not its value; `"AXSearchField"` is the well-known value but is not stated on the page.
- `Role`'s roster was read from **androidx-main**, not from the 1.3.1 tree kaya pins. It has no
  `Search` member on main; a value cannot have been REMOVED between 1.3.1 and main without a
  deprecation, so the conclusion holds, but the exact 1.3.1 file was not read.

