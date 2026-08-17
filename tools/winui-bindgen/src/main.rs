//! Regenerates crates/kaya/src/winui/bindings.rs from the Windows App SDK
//! metadata in third_party/ (run tools/fetch-winappsdk.sh first).
//!
//! Filters are type-level to keep the generated file small; windows-bindgen
//! pulls in dependencies automatically.

fn main() {
    let sdk = "../../third_party/winappsdk";
    let args = vec![
        "--in".to_string(),
        "default".to_string(),
        "--in".to_string(),
        format!("{sdk}/Microsoft.WindowsAppSDK.WinUI-2.2.1/extracted/metadata/Microsoft.UI.Xaml.winmd"),
        // The RichEdit text object model, which is a SEPARATE winmd in
        // the same WinUI package: RichEditBox has no Text property and
        // no editing commands of its own — every one of them lives on
        // Microsoft.UI.Text.RichEditTextDocument, so the textarea's
        // control cannot be bound without this input
        // (docs/textarea-foundation-plan.md, the windows arm).
        "--in".to_string(),
        format!("{sdk}/Microsoft.WindowsAppSDK.WinUI-2.2.1/extracted/metadata/Microsoft.UI.Text.winmd"),
        "--in".to_string(),
        format!("{sdk}/Microsoft.WindowsAppSDK.InteractiveExperiences-2.0.15/extracted/metadata/10.0.18362.0/Microsoft.UI.winmd"),
        "--in".to_string(),
        format!("{sdk}/Microsoft.WindowsAppSDK.InteractiveExperiences-2.0.15/extracted/metadata/10.0.18362.0/Microsoft.Foundation.winmd"),
        "--in".to_string(),
        format!("{sdk}/Microsoft.WindowsAppSDK.InteractiveExperiences-2.0.15/extracted/metadata/10.0.18362.0/Microsoft.Graphics.winmd"),
        "--in".to_string(),
        format!("{sdk}/Microsoft.WindowsAppSDK.Foundation-2.1.0/extracted/metadata"),
        "--out".to_string(),
        "../../crates/kaya/src/winui/bindings.rs".to_string(),
        "--filter".to_string(),
        "Microsoft.UI.Xaml.Application".to_string(),
        "Microsoft.UI.Xaml.ApplicationInitializationCallback".to_string(),
        "Microsoft.UI.Xaml.ApplicationInitializationCallbackParams".to_string(),
        "Microsoft.UI.Xaml.LaunchActivatedEventArgs".to_string(),
        "Microsoft.UI.Xaml.WindowEventArgs".to_string(),
        "Microsoft.UI.Xaml.UnhandledExceptionEventHandler".to_string(),
        "Microsoft.UI.Xaml.UnhandledExceptionEventArgs".to_string(),
        "Windows.Foundation.TypedEventHandler".to_string(),
        "Microsoft.UI.Xaml.Window".to_string(),
        "Microsoft.UI.Xaml.IApplicationOverrides".to_string(),
        "Microsoft.UI.Xaml.RoutedEventHandler".to_string(),
        "Microsoft.UI.Xaml.DependencyObject".to_string(),
        "Microsoft.UI.Xaml.UIElement".to_string(),
        "Microsoft.UI.Xaml.FrameworkElement".to_string(),
        "Microsoft.UI.Xaml.Controls.Control".to_string(),
        // Unlocks UIElement.Focus/FocusState for the focus command and
        // the harness's is_focused (the slots were `usize` pads while
        // the enum was unfiltered).
        "Microsoft.UI.Xaml.FocusState".to_string(),
        "Microsoft.UI.Xaml.Controls.ContentControl".to_string(),
        "Microsoft.UI.Xaml.Controls.Panel".to_string(),
        "Microsoft.UI.Xaml.Controls.UIElementCollection".to_string(),
        "Microsoft.UI.Xaml.Controls.Primitives.ButtonBase".to_string(),
        "Microsoft.UI.Xaml.Controls.Button".to_string(),
        "Microsoft.UI.Xaml.Controls.TextBlock".to_string(),
        "Microsoft.UI.Xaml.Controls.TextBox".to_string(),
        // THE TEXTAREA'S CONTROL (docs/textarea-foundation-plan.md).
        // RichEditBox is the rich-CAPABLE control kaya pins to
        // plain-text behavior; TextBox stays the entry's. It is not a
        // drop-in — it has no Text property and none of the editing
        // commands — so the text object model comes with it, and each
        // type is named explicitly because the filter never pulls
        // referenced types transitively (docs/traps.md).
        //
        // RichEditTextDocument is what RichEditBox.TextDocument
        // answers with; ITextDocument/ITextDocument2 are the
        // interfaces it implements (a class whose default interface is
        // filtered out keeps its methods as bare vtable pads).
        // ITextSelection is Document.Selection — cut, copy, paste and
        // the caret — and ITextRange is the base it extends.
        "Microsoft.UI.Xaml.Controls.RichEditBox".to_string(),
        "Microsoft.UI.Text.RichEditTextDocument".to_string(),
        "Microsoft.UI.Text.ITextDocument".to_string(),
        "Microsoft.UI.Text.ITextDocument2".to_string(),
        "Microsoft.UI.Text.ITextSelection".to_string(),
        "Microsoft.UI.Text.ITextRange".to_string(),
        // The plain-text PINS, each an enum the setter takes — and an
        // unfiltered enum takes its setter down with it, silently, so
        // an unnamed pin here reads as "no such method" rather than as
        // a missing filter:
        //   TextGetOptions::AdjustCrlf  — the read that does NOT append
        //     the story's trailing paragraph mark (GetText(None) does,
        //     and after lf() that is a newline the guest never wrote).
        //   TextSetOptions::None        — the write that treats kaya's
        //     string as TEXT rather than as RTF markup.
        //   RichEditClipboardFormat::PlainText — nothing RTF leaves a
        //     kaya textarea on copy or cut.
        //   DisabledFormattingAccelerators::All — Ctrl+B/I/U never
        //     format; the default (None) makes them bold/italic/
        //     underline the user's text.
        // The Paste pair is the fourth pin's mechanism: the control's
        // own paste is cancelled and kaya inserts the clipboard's plain
        // text itself, so every paste route lands what the entry's
        // TextBox would land.
        "Microsoft.UI.Text.TextGetOptions".to_string(),
        "Microsoft.UI.Text.TextSetOptions".to_string(),
        // THE TEXT-RANGE PRIMITIVES (docs/ranges-plan.md D1). Each of
        // these three names an ITextRange member that does not exist
        // without it — the transitivity trap again, and here it hides
        // the whole milestone: `get_CharacterFormat`, `ScrollIntoView`
        // and `GetRect` are all in the metadata (52 members on
        // ITextRange) and all three were absent from the generated file
        // because their parameter and return types were unfiltered.
        //   ITextCharacterFormat — the highlight itself. A declared
        //     range is `range.CharacterFormat.BackgroundColor = colour`,
        //     which is the ONLY per-range decoration a WinUI text
        //     control can express (TextBox cannot express it at all,
        //     which is why the textarea is a RichEditBox).
        //   PointOptions — `ScrollIntoView`'s placement argument (reveal)
        //     and `GetRect`'s coordinate space (the viewport read: a
        //     range's rectangle in CLIENT coordinates is where it sits
        //     relative to what is on screen right now).
        //   TextConstants — `AutoColor`, the background value an
        //     UNPAINTED run carries. Clearing a highlight means writing
        //     that value back, and naming the platform's own constant is
        //     the difference between a clear and a guess at a magic
        //     colour (measured: an unpainted run reads #00000001).
        // Windows.Foundation.Rect is GetRect's out parameter; without it
        // the method vanishes with the rest.
        "Microsoft.UI.Text.ITextCharacterFormat".to_string(),
        "Microsoft.UI.Text.PointOptions".to_string(),
        "Microsoft.UI.Text.TextConstants".to_string(),
        "Windows.Foundation.Rect".to_string(),
        // D4's refusal needs to KNOW a composition is live, and this
        // control is the only party that does: an input method's
        // composition is on no kaya channel and never will be. The two
        // event args types are named for the transitivity reason
        // everything else here is — without them `add_TextCompositionStarted`
        // and `add_TextCompositionEnded` are absent from the generated
        // RichEditBox, which reads as "WinUI has no composition events"
        // when it has six.
        "Microsoft.UI.Xaml.Controls.TextCompositionStartedEventArgs".to_string(),
        "Microsoft.UI.Xaml.Controls.TextCompositionEndedEventArgs".to_string(),
        "Microsoft.UI.Xaml.Controls.RichEditClipboardFormat".to_string(),
        "Microsoft.UI.Xaml.Controls.DisabledFormattingAccelerators".to_string(),
        "Microsoft.UI.Xaml.Controls.TextControlPasteEventHandler".to_string(),
        "Microsoft.UI.Xaml.Controls.TextControlPasteEventArgs".to_string(),
        "Microsoft.UI.Xaml.Controls.XamlControlsResources".to_string(),
        "Microsoft.UI.Xaml.ResourceDictionary".to_string(),
        "Microsoft.UI.Xaml.Controls.TextChangedEventHandler".to_string(),
        "Microsoft.UI.Xaml.Controls.TextChangedEventArgs".to_string(),
        "Microsoft.UI.Xaml.Markup.XamlReader".to_string(),
        "Microsoft.UI.Xaml.Markup.IXamlMetadataProvider".to_string(),
        "Microsoft.UI.Xaml.Markup.IXamlType".to_string(),
        "Microsoft.UI.Xaml.Markup.IXamlMember".to_string(),
        "Microsoft.UI.Xaml.Markup.XmlnsDefinition".to_string(),
        "Windows.UI.Xaml.Interop.TypeName".to_string(),
        "Microsoft.UI.Xaml.XamlTypeInfo.XamlControlsXamlMetaDataProvider".to_string(),
        "Microsoft.UI.Xaml.Controls.MenuFlyout".to_string(),
        "Microsoft.UI.Xaml.Controls.Primitives.FlyoutBase".to_string(),
        "Microsoft.UI.Xaml.Style".to_string(),
        "Microsoft.UI.Xaml.Controls.Orientation".to_string(),
        // Grid, not StackPanel, is what carries the row/column
        // containers: proportional `grow` needs star sizing, and a
        // StackPanel sizes children to their natural extent along its
        // stacking axis with no weight concept anywhere. GridLength
        // with GridUnitType::Star is the whole reason these are here;
        // Grid's Row/Column attached properties place each child.
        "Microsoft.UI.Xaml.Controls.Grid".to_string(),
        "Microsoft.UI.Xaml.Controls.RowDefinition".to_string(),
        "Microsoft.UI.Xaml.Controls.ColumnDefinition".to_string(),
        "Microsoft.UI.Xaml.Controls.RowDefinitionCollection".to_string(),
        "Microsoft.UI.Xaml.Controls.ColumnDefinitionCollection".to_string(),
        "Microsoft.UI.Xaml.GridLength".to_string(),
        "Microsoft.UI.Xaml.GridUnitType".to_string(),
        // The root-fills observation compares the mounted root against
        // the content island's size — UIElement.XamlRoot is the only
        // window-content geometry the framework exposes. Size must be
        // named explicitly too: the filter never pulls referenced types
        // transitively (see docs/traps.md).
        "Microsoft.UI.Xaml.XamlRoot".to_string(),
        "Windows.Foundation.Size".to_string(),
        // The normalized root inset rides Grid.Padding, whose methods
        // vanish silently while Thickness is unfiltered (the
        // transitivity trap again).
        "Microsoft.UI.Xaml.Thickness".to_string(),
        // The list-detail arm hides the covered entry's back bar, since
        // a detail pane sitting BESIDE its list covers nothing and has
        // nowhere to go back to. UIElement.Visibility carries that, and
        // the enum must be named for the same transitivity reason as
        // everything else in this list.
        "Microsoft.UI.Xaml.Visibility".to_string(),
        // TwoPaneView is the platform's own list-detail container, and
        // unlike GNOME's and Material's it is pure layout: no
        // navigation, no history, nothing that wants to own the stack
        // kaya's core owns. Adopting it hands Windows the decision of
        // WHERE one pane becomes two (MinWideModeWidth), which is the
        // whole point — kaya no longer draws that line itself.
        //
        // Every enum it answers with has to be named here too, for the
        // transitivity reason above: Mode is what the split observation
        // reads, and PanePriority is which pane survives the collapse.
        "Microsoft.UI.Xaml.Controls.TwoPaneView".to_string(),
        "Microsoft.UI.Xaml.Controls.TwoPaneViewMode".to_string(),
        "Microsoft.UI.Xaml.Controls.TwoPaneViewPriority".to_string(),
        "Microsoft.UI.Xaml.Controls.TwoPaneViewWideModeConfiguration".to_string(),
        "Microsoft.UI.Xaml.Controls.TwoPaneViewTallModeConfiguration".to_string(),
        // The align observation reads child positions through
        // UIElement.TransformToVisual (and text baselines through
        // TextBlock.BaselineOffset beneath them); the transform's own
        // types must be named or the method vanishes silently — the
        // same transitivity trap as Thickness.
        "Microsoft.UI.Xaml.Media.GeneralTransform".to_string(),
        "Windows.Foundation.Point".to_string(),
        // Per-child cross placement stamps.
        "Microsoft.UI.Xaml.HorizontalAlignment".to_string(),
        "Microsoft.UI.Xaml.VerticalAlignment".to_string(),
        "Microsoft.UI.Xaml.Controls.Primitives.ToggleButton".to_string(),
        "Microsoft.UI.Xaml.Controls.CheckBox".to_string(),
        "Microsoft.UI.Xaml.Controls.Primitives.RangeBase".to_string(),
        "Microsoft.UI.Xaml.Controls.Slider".to_string(),
        "Microsoft.UI.Xaml.Controls.Primitives.RangeBaseValueChangedEventHandler".to_string(),
        "Microsoft.UI.Xaml.Controls.Primitives.RangeBaseValueChangedEventArgs".to_string(),
        // The image widget: Image displays a BitmapImage source fed
        // from an in-memory stream (encoded bytes arrive as blobs;
        // there is no file to point a Uri at).
        "Microsoft.UI.Xaml.Controls.Image".to_string(),
        // The class filter is explicit: without it windows-bindgen
        // emits only the IImageSource interface, leaving BitmapImage's
        // required_hierarchy! (and Image.Source/SetSource) referencing
        // a type that does not exist.
        "Microsoft.UI.Xaml.Media.ImageSource".to_string(),
        "Microsoft.UI.Xaml.Media.Imaging.BitmapSource".to_string(),
        "Microsoft.UI.Xaml.Media.Imaging.BitmapImage".to_string(),
        // THE BRAND TYPEFACE (docs/styling-plan.md Slice 2b). The
        // transitivity trap in its usual disguise: `FontFamily` appeared
        // nine times in the generated file before this line and every one
        // was a vtable PAD — `IControl_Vtbl { FontFamily: usize,
        // SetFontFamily: usize }`, the same on ITextBlock and IFontIcon,
        // plus three FontFamilyProperty statics — so the backend read as
        // "WinUI controls have no font family". One filter entry turns all
        // of them into methods and unlocks the constructor
        // (`CreateInstanceWithName`) and the `Source` accessor the
        // typeface read starts from.
        "Microsoft.UI.Xaml.Media.FontFamily".to_string(),
        "Windows.Storage.Streams.InMemoryRandomAccessStream".to_string(),
        "Windows.Storage.Streams.DataWriter".to_string(),
        // StoreAsync's return type; without it the method is skipped.
        "Windows.Storage.Streams.DataWriterStoreOperation".to_string(),
        "Windows.Storage.Streams.IRandomAccessStream".to_string(),
        "Windows.Foundation.IReference".to_string(),
        "Windows.Foundation.PropertyValue".to_string(),
        "Windows.Foundation.EventHandler".to_string(),
        "Windows.ApplicationModel.Core.ICoreApplicationUnhandledError".to_string(),
        "Windows.ApplicationModel.Core.UnhandledErrorDetectedEventArgs".to_string(),
        "Windows.ApplicationModel.Core.UnhandledError".to_string(),
        "Microsoft.UI.Dispatching.DispatcherQueue".to_string(),
        "Microsoft.UI.Dispatching.DispatcherQueueHandler".to_string(),
        // App-scope stub brushes for theme keys that dictionary
        // realization demands when the full XamlControlsResources
        // merge cannot load (dll-hosted guests have no exe-adjacent
        // resources.pri, so ms-appx never resolves there).
        "Microsoft.UI.Xaml.Media.SolidColorBrush".to_string(),
        "Microsoft.UI.Xaml.Media.Brush".to_string(),
        "Windows.UI.Color".to_string(),
        // The progress bar: RangeBase descendant like Slider;
        // IsIndeterminate is the activity mode.
        "Microsoft.UI.Xaml.Controls.ProgressBar".to_string(),
        // The scroll viewport: ScrollViewer is the platform's own
        // machinery — ScrollableHeight/VerticalOffset are the
        // observation sources and ChangeView the API scroll_end
        // drives. The mode/visibility enums must be named or the
        // properties vanish (the transitivity trap).
        "Microsoft.UI.Xaml.Controls.ScrollViewer".to_string(),
        "Microsoft.UI.Xaml.Controls.ScrollMode".to_string(),
        "Microsoft.UI.Xaml.Controls.ScrollBarVisibility".to_string(),
        // The alert vocabulary: ContentDialog's three slots ARE the
        // shape (two actions + close). The result/button enums must
        // be named or the properties vanish (the transitivity trap);
        // ShowAsync's IAsyncOperation rides windows-future paths like
        // TextBox's.
        "Microsoft.UI.Xaml.Controls.ContentDialog".to_string(),
        "Microsoft.UI.Xaml.Controls.ContentDialogResult".to_string(),
        "Microsoft.UI.Xaml.Controls.ContentDialogButton".to_string(),
        // The select: ComboBox rows are ComboBoxItems (their content
        // is each option's TextBlock); SelectionChanged reports
        // picks. The selector base and its event types must be named
        // or the members vanish (the transitivity trap).
        "Microsoft.UI.Xaml.Controls.ComboBox".to_string(),
        "Microsoft.UI.Xaml.Controls.ComboBoxItem".to_string(),
        "Microsoft.UI.Xaml.Controls.ItemsControl".to_string(),
        "Microsoft.UI.Xaml.Controls.ItemCollection".to_string(),
        "Microsoft.UI.Xaml.Controls.Primitives.Selector".to_string(),
        "Microsoft.UI.Xaml.Controls.Primitives.SelectorItem".to_string(),
        "Microsoft.UI.Xaml.Controls.SelectionChangedEventHandler".to_string(),
        "Microsoft.UI.Xaml.Controls.SelectionChangedEventArgs".to_string(),
        // The radio group: RadioButtons is the choice contract's
        // inline control — Items (a plain IVector, no ItemCollection
        // hierarchy), SelectedIndex, SelectionChanged.
        "Microsoft.UI.Xaml.Controls.RadioButtons".to_string(),
        // The sections switcher: NavigationView is the platform's own
        // idiom (left pane for auto/sidebar, Top for the bar hint) —
        // items are NavigationViewItems with string content, selection
        // rides SelectionChanged. The enums and event args must be
        // named or the members vanish (the transitivity trap).
        "Microsoft.UI.Xaml.Controls.NavigationView".to_string(),
        "Microsoft.UI.Xaml.Controls.NavigationViewItem".to_string(),
        "Microsoft.UI.Xaml.Controls.NavigationViewItemBase".to_string(),
        "Microsoft.UI.Xaml.Controls.NavigationViewPaneDisplayMode".to_string(),
        "Microsoft.UI.Xaml.Controls.NavigationViewSelectionChangedEventArgs".to_string(),
        "Microsoft.UI.Xaml.Controls.NavigationViewBackButtonVisible".to_string(),
        // The runner's REAL press: the open dialog lives in the popup
        // layer (GetOpenPopupsForXamlRoot), its template buttons are
        // found by part name, and ButtonAutomationPeer.Invoke runs
        // the same click pipeline a user's press does.
        "Microsoft.UI.Xaml.Media.VisualTreeHelper".to_string(),
        "Microsoft.UI.Xaml.Controls.Primitives.Popup".to_string(),
        "Microsoft.UI.Xaml.Automation.Peers.AutomationPeer".to_string(),
        "Microsoft.UI.Xaml.Automation.Peers.FrameworkElementAutomationPeer".to_string(),
        "Microsoft.UI.Xaml.Automation.Peers.ButtonBaseAutomationPeer".to_string(),
        "Microsoft.UI.Xaml.Automation.Peers.ButtonAutomationPeer".to_string(),
        // Accessibility (DESIGN.md, the a11y_id/a11y_label props):
        // AutomationProperties is the SETTER side — AutomationId is the
        // automation identifier and Name is what a screen reader speaks
        // — while the peers above are the READ side. Unlike GTK, WinUI
        // publishes a settable identifier, so the harness matches by
        // identity here rather than by ordinal.
        "Microsoft.UI.Xaml.Automation.AutomationProperties".to_string(),
        // The control-type enum the peer's GetAutomationControlType
        // returns. Without it windows-bindgen filters the type out AND
        // drops the method that returns it — the vtable slot survives as
        // a bare usize, so the omission reads as "no such method".
        "Microsoft.UI.Xaml.Automation.Peers.AutomationControlType".to_string(),
        // The heading role's enum (docs/styling-plan.md D4), and it
        // gates BOTH halves of that role at once: without it
        // IAutomationPropertiesStatics keeps HeadingLevelProperty,
        // GetHeadingLevel and SetHeadingLevel as bare usize pads (the
        // SETTER), and every peer's GetHeadingLevel/GetHeadingLevelCore
        // is padded the same way (the READ `ax` reports `heading/<label>`
        // from). Measured before it was added: 5 pads, no type. UIA's
        // HeadingLevel is the property that gives real heading
        // NAVIGATION; AutomationProperties::SetLevel is a different
        // property (hierarchical item level) and SetLocalizedControlType
        // would only make Narrator say the word.
        "Microsoft.UI.Xaml.Automation.Peers.AutomationHeadingLevel".to_string(),
        // Menus (DESIGN.md, Menus and the command vocabulary): the
        // ratified WinUI lowering — MenuBar in its own Auto row of the
        // window shell Grid, MenuBarItem per top-level grouping node,
        // the flyout item kinds 1:1, KeyboardAccelerator per shortcut
        // (primary → Control), MenuFlyout as ContextFlyout for the
        // widget/node anchor. Each class is named explicitly: the
        // filter never pulls referenced types transitively
        // (docs/traps.md), and the item base class must be present or
        // MenuBarItem.Items/MenuFlyout.Items reference a type that
        // does not exist.
        "Microsoft.UI.Xaml.Controls.MenuBar".to_string(),
        "Microsoft.UI.Xaml.Controls.MenuBarItem".to_string(),
        "Microsoft.UI.Xaml.Controls.MenuFlyoutItemBase".to_string(),
        "Microsoft.UI.Xaml.Controls.MenuFlyoutItem".to_string(),
        "Microsoft.UI.Xaml.Controls.ToggleMenuFlyoutItem".to_string(),
        "Microsoft.UI.Xaml.Controls.RadioMenuFlyoutItem".to_string(),
        "Microsoft.UI.Xaml.Controls.MenuFlyoutSubItem".to_string(),
        "Microsoft.UI.Xaml.Controls.MenuFlyoutSeparator".to_string(),
        // Shortcuts ride the REAL accelerator machinery: the chord
        // enums live in Windows.System and must be named or
        // KeyboardAccelerator's Key/Modifiers setters vanish silently
        // (the transitivity trap; UIElement.KeyboardAccelerators was a
        // usize pad while the class was unfiltered).
        "Microsoft.UI.Xaml.Input.KeyboardAccelerator".to_string(),
        "Windows.System.VirtualKey".to_string(),
        "Windows.System.VirtualKeyModifiers".to_string(),
        // The harness verbs invoke flyout items through their
        // automation peers (the ContentDialog precedent): the peers
        // for the item kinds plus the provider interfaces the invoke
        // patterns live on — casting the peer to the provider is the
        // route that works whatever concrete peer a subclass mints
        // (this SDK has no RadioMenuFlyoutItem peer of its own).
        "Microsoft.UI.Xaml.Automation.Peers.MenuFlyoutItemAutomationPeer".to_string(),
        "Microsoft.UI.Xaml.Automation.Peers.ToggleMenuFlyoutItemAutomationPeer".to_string(),
        "Microsoft.UI.Xaml.Automation.Peers.MenuBarItemAutomationPeer".to_string(),
        "Microsoft.UI.Xaml.Automation.Provider.IInvokeProvider".to_string(),
        "Microsoft.UI.Xaml.Automation.Provider.IToggleProvider".to_string(),
        "Microsoft.UI.Xaml.Automation.Provider.IExpandCollapseProvider".to_string(),
        // THE SEMANTIC ICONS (docs/styling-plan.md D6). Before these four
        // entries this backend could not construct an icon at all, and the
        // reason was the transitivity trap wearing its usual disguise:
        // `Icon`/`SetIcon` DO exist in the metadata on IMenuFlyoutItem,
        // IMenuFlyoutSubItem and INavigationViewItem, but IconElement was
        // unfiltered, so windows-bindgen dropped all three accessors and
        // left `usize` pads in their vtable slots. Reading the generated
        // file then says "WinUI menu items have no icon", which is false.
        //
        // Both routes are needed, and the second is not optional: the
        // `Symbol` enum covers 17 of kaya's 20 concepts and the other
        // three — info, warning, lock — have no enum member at all, so
        // they can only be spelled as Segoe Fluent Icons codepoints
        // through FontIcon (styling/symbols-fluent.md).
        //   IconElement — the base BOTH routes return and the type every
        //     Icon setter takes; without it nothing else here helps.
        //   Symbol      — the enum. An unfiltered enum takes its setter
        //     down with it (the FocusState precedent above).
        //   SymbolIcon  — route 1, the stable API-name spelling: kaya
        //     writes `Symbol::Copy`, never a codepoint.
        //   FontIcon    — route 2. Neither route sets a FontFamily: both
        //     resolve through the SymbolThemeFontFamily theme resource,
        //     which is also what makes the Windows 10 fallback to Segoe
        //     MDL2 Assets free (all codepoints kaya uses are in both
        //     catalogs — checked mechanically, 33/33).
        "Microsoft.UI.Xaml.Controls.IconElement".to_string(),
        "Microsoft.UI.Xaml.Controls.Symbol".to_string(),
        "Microsoft.UI.Xaml.Controls.SymbolIcon".to_string(),
        "Microsoft.UI.Xaml.Controls.FontIcon".to_string(),
    ];
    let args: Vec<&str> = args.iter().map(String::as_str).collect();
    windows_bindgen::bindgen(args);
    fix_array_proxy_paths();
    fix_observable_vector_paths();
    println!("generated crates/kaya/src/winui/bindings.rs");
}

/// windows-bindgen 0.62 emits `windows_core::ArrayProxy::from_raw_parts
/// (..).as_array()` in the IPropertyValue vtable shims (pulled in by the
/// IReference filter), but windows-core 0.62.2 keeps that type at
/// `imp::array_proxy` with a Deref-to-Array API. Rewrite to the
/// spelling the pinned windows-core actually exports; `&mut proxy`
/// coerces to `&mut Array<T>` and the proxy's Drop performs the
/// write-back after the call, same semantics either way.
/// ItemCollection (ComboBox.Items) has IObservableVector as its
/// DEFAULT interface, but windows-bindgen's built-in reference maps
/// all of Windows.Foundation.Collections to the windows-collections
/// crate — whose pinned 0.3 ships only the plain vector/iterable
/// types, not the observable ones. The references list is
/// first-match-wins with the built-ins inserted at the front, so no
/// --reference override can carve the two observable types out.
/// Re-point them at the full `windows` crate (Foundation_Collections
/// feature), which does ship them; the hierarchy macros declare
/// per-type conversions independently, so mixing the two crates'
/// collection interfaces in one hierarchy is sound.
fn fix_observable_vector_paths() {
    let path = "../../crates/kaya/src/winui/bindings.rs";
    let src = std::fs::read_to_string(path).expect("bindings.rs was just generated");
    if !src.contains("windows_collections::IObservableVector")
        && !src.contains("windows_collections::VectorChangedEventHandler")
    {
        return;
    }
    let fixed = src
        .replace(
            "windows_collections::IObservableVector",
            "windows::Foundation::Collections::IObservableVector",
        )
        .replace(
            "windows_collections::VectorChangedEventHandler",
            "windows::Foundation::Collections::VectorChangedEventHandler",
        );
    assert!(
        !fixed.contains("windows_collections::IObservableVector")
            && !fixed.contains("windows_collections::VectorChangedEventHandler"),
        "observable-vector fixup left references behind; check windows-bindgen output"
    );
    std::fs::write(path, fixed).expect("write bindings.rs");
}

fn fix_array_proxy_paths() {
    let path = "../../crates/kaya/src/winui/bindings.rs";
    let src = std::fs::read_to_string(path).expect("bindings.rs was just generated");
    if !src.contains("windows_core::ArrayProxy") {
        return;
    }
    let fixed = regex_lite::Regex::new(r"windows_core::ArrayProxy::from_raw_parts")
        .unwrap()
        .replace_all(&src, "&mut windows_core::imp::array_proxy");
    let fixed = regex_lite::Regex::new(r"\s*\.as_array\(\)")
        .unwrap()
        .replace_all(&fixed, "");
    assert!(
        !fixed.contains("windows_core::ArrayProxy"),
        "ArrayProxy fixup left references behind; check windows-bindgen output"
    );
    std::fs::write(path, fixed.as_ref()).expect("write bindings.rs");
}
