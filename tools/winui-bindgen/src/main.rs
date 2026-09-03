//! Regenerates crates/kaya/src/winui/bindings.rs from the Windows App SDK
//! metadata in third_party/ (run tools/fetch-winappsdk.sh first). EVERY
//! TYPE IS NAMED EXPLICITLY, enums and event args included: an unfiltered
//! one leaves the method naming it a bare `usize` vtable pad.
//! docs/traps.md: windows-bindgen type filters do not pull referenced
//! types transitively. Each comment says what its entry unlocks.

fn main() {
    let sdk = "../../third_party/winappsdk";
    let args = vec![
        "--in".to_string(),
        "default".to_string(),
        "--in".to_string(),
        format!("{sdk}/Microsoft.WindowsAppSDK.WinUI-2.2.1/extracted/metadata/Microsoft.UI.Xaml.winmd"),
        // The RichEdit text object model is a SEPARATE winmd in the same
        // WinUI package: every RichEditBox editing command lives on
        // Microsoft.UI.Text.RichEditTextDocument
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
        // the harness's is_focused.
        "Microsoft.UI.Xaml.FocusState".to_string(),
        "Microsoft.UI.Xaml.Controls.ContentControl".to_string(),
        "Microsoft.UI.Xaml.Controls.Panel".to_string(),
        "Microsoft.UI.Xaml.Controls.UIElementCollection".to_string(),
        "Microsoft.UI.Xaml.Controls.Primitives.ButtonBase".to_string(),
        "Microsoft.UI.Xaml.Controls.Button".to_string(),
        "Microsoft.UI.Xaml.Controls.TextBlock".to_string(),
        // TEXT WRAPS (the 2026-08-29 ruling): the two enums
        // `SetTextWrapping`/`SetTextTrimming` take.
        "Microsoft.UI.Xaml.TextWrapping".to_string(),
        "Microsoft.UI.Xaml.TextTrimming".to_string(),
        "Microsoft.UI.Xaml.Controls.TextBox".to_string(),
        // THE TEXTAREA'S CONTROL (docs/textarea-foundation-plan.md):
        // RichEditBox is the rich-CAPABLE control kaya pins to plain
        // text; TextBox stays the entry's. It has no Text property and
        // none of the editing commands, so its text object model —
        // RichEditTextDocument, ITextDocument/2, ITextSelection,
        // ITextRange — comes with it.
        "Microsoft.UI.Xaml.Controls.RichEditBox".to_string(),
        "Microsoft.UI.Text.RichEditTextDocument".to_string(),
        "Microsoft.UI.Text.ITextDocument".to_string(),
        "Microsoft.UI.Text.ITextDocument2".to_string(),
        "Microsoft.UI.Text.ITextSelection".to_string(),
        "Microsoft.UI.Text.ITextRange".to_string(),
        // The plain-text PINS, each an enum the setter takes:
        //   TextGetOptions::AdjustCrlf — the read that does NOT append
        //     the story's trailing paragraph mark.
        //   TextSetOptions::None — kaya's string as TEXT, not RTF markup.
        //   RichEditClipboardFormat::PlainText — nothing RTF leaves a
        //     kaya textarea on copy or cut.
        //   DisabledFormattingAccelerators::All — Ctrl+B/I/U never
        //     format. The Paste pair cancels the control's own paste so
        //     kaya inserts the clipboard's plain text itself.
        "Microsoft.UI.Text.TextGetOptions".to_string(),
        "Microsoft.UI.Text.TextSetOptions".to_string(),
        // THE TEXT-RANGE PRIMITIVES (docs/ranges-plan.md D1), each
        // unlocking an ITextRange member:
        //   ITextCharacterFormat — the highlight, the ONLY per-range
        //     decoration a WinUI text control can express.
        //   PointOptions — ScrollIntoView's placement and GetRect's
        //     coordinate space (CLIENT coordinates).
        //   TextConstants — `AutoColor`, the background an UNPAINTED run
        //     carries; clearing a highlight writes it back (measured: an
        //     unpainted run reads #00000001).
        //   Windows.Foundation.Rect — GetRect's out parameter.
        "Microsoft.UI.Text.ITextCharacterFormat".to_string(),
        "Microsoft.UI.Text.PointOptions".to_string(),
        "Microsoft.UI.Text.TextConstants".to_string(),
        "Windows.Foundation.Rect".to_string(),
        // D4's refusal needs to KNOW a composition is live, and this
        // control is the only party that does: an input method's
        // composition is on no kaya channel and never will be. These
        // two unlock add_TextCompositionStarted/Ended.
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
        // Grid, not StackPanel, carries the row/column containers:
        // proportional `grow` needs star sizing and a StackPanel has no
        // weight concept anywhere. GridLength with GridUnitType::Star is
        // the whole reason these are here.
        "Microsoft.UI.Xaml.Controls.Grid".to_string(),
        "Microsoft.UI.Xaml.Controls.RowDefinition".to_string(),
        "Microsoft.UI.Xaml.Controls.ColumnDefinition".to_string(),
        "Microsoft.UI.Xaml.Controls.RowDefinitionCollection".to_string(),
        "Microsoft.UI.Xaml.Controls.ColumnDefinitionCollection".to_string(),
        "Microsoft.UI.Xaml.GridLength".to_string(),
        "Microsoft.UI.Xaml.GridUnitType".to_string(),
        // The root-fills observation compares the mounted root against
        // the content island's size — UIElement.XamlRoot is the only
        // window-content geometry the framework exposes.
        "Microsoft.UI.Xaml.XamlRoot".to_string(),
        "Windows.Foundation.Size".to_string(),
        // The normalized root inset rides Grid.Padding, whose methods
        // take a Thickness.
        "Microsoft.UI.Xaml.Thickness".to_string(),
        // The list-detail arm hides the covered entry's back bar, since
        // a detail pane BESIDE its list covers nothing and has nowhere
        // to go back to. UIElement.Visibility carries that.
        "Microsoft.UI.Xaml.Visibility".to_string(),
        // TwoPaneView is the platform's own list-detail container and,
        // unlike GNOME's and Material's, pure layout: no navigation, no
        // history, nothing that wants to own the stack kaya's core owns.
        // Adopting it hands Windows the decision of WHERE one pane
        // becomes two (MinWideModeWidth), which is the point. Mode is
        // what the split observation reads; PanePriority is which pane
        // survives the collapse.
        "Microsoft.UI.Xaml.Controls.TwoPaneView".to_string(),
        "Microsoft.UI.Xaml.Controls.TwoPaneViewMode".to_string(),
        "Microsoft.UI.Xaml.Controls.TwoPaneViewPriority".to_string(),
        "Microsoft.UI.Xaml.Controls.TwoPaneViewWideModeConfiguration".to_string(),
        "Microsoft.UI.Xaml.Controls.TwoPaneViewTallModeConfiguration".to_string(),
        // The align observation reads child positions through
        // UIElement.TransformToVisual (and text baselines through
        // TextBlock.BaselineOffset beneath them).
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
        // Without the class filter windows-bindgen emits only the
        // IImageSource interface, leaving BitmapImage's
        // required_hierarchy! (and Image.Source/SetSource) referencing a
        // type that does not exist.
        "Microsoft.UI.Xaml.Media.ImageSource".to_string(),
        "Microsoft.UI.Xaml.Media.Imaging.BitmapSource".to_string(),
        "Microsoft.UI.Xaml.Media.Imaging.BitmapImage".to_string(),
        // THE CANVAS BLIT (docs/canvas-plan.md §8). The raw-pixel
        // sibling of the encoded path above: the core hands over device
        // pixels, so nothing here decodes. `IBuffer` is what
        // `WriteableBitmap.PixelBuffer` returns.
        "Microsoft.UI.Xaml.Media.Imaging.WriteableBitmap".to_string(),
        "Windows.Storage.Streams.IBuffer".to_string(),
        // `Image.Stretch`. The blit fills a box the backend sized from
        // the BUFFER, so Fill is exact rather than a stretch
        // (docs/canvas-plan.md §3.2.1).
        "Microsoft.UI.Xaml.Media.Stretch".to_string(),
        // THE SIZE POLICY'S TWO CHANNELS (§3.2.1). The REPORT is what
        // layout assigned a canvas, and `LayoutSlot` is the only read
        // that answers it: a canvas's Image carries an explicit
        // Width/Height from the buffer (the 1:1 blit), which is a hard
        // constraint, so its own arranged box is the RASTER's size and
        // never the track's. The DRIVE is `CompositionTarget.Rendering`,
        // the non-harness frame clock (§15.4).
        "Microsoft.UI.Xaml.Controls.Primitives.LayoutInformation".to_string(),
        "Microsoft.UI.Xaml.Media.CompositionTarget".to_string(),
        "Microsoft.UI.Xaml.Media.RenderingEventArgs".to_string(),
        // `RenderingTime`'s return struct. A clock read inside the
        // callback is exactly the jitter the platform's own frame
        // timestamp exists to remove.
        "Windows.Foundation.TimeSpan".to_string(),
        // THE SCALE CHANNEL (§5): the argument of
        // `XamlRoot.Changed`'s add-handler. Windows delivers a DPI change
        // per top-level window and the core has to re-raster on it.
        "Microsoft.UI.Xaml.XamlRootChangedEventArgs".to_string(),
        // THE APPEARANCE BIT (§6): the enum the getter beside
        // `ActualThemeChanged` returns, without which the backend can be
        // told the theme moved and cannot ask what it moved to.
        "Microsoft.UI.Xaml.ElementTheme".to_string(),
        // THE BRAND TYPEFACE (docs/styling-plan.md Slice 2b). One entry
        // turns nine FontFamily pads into methods and unlocks the
        // constructor (`CreateInstanceWithName`) and the `Source`
        // accessor the typeface read starts from.
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
        // The scroll viewport: ScrollableHeight/VerticalOffset are the
        // observation sources and ChangeView the API scroll_end drives.
        "Microsoft.UI.Xaml.Controls.ScrollViewer".to_string(),
        "Microsoft.UI.Xaml.Controls.ScrollMode".to_string(),
        "Microsoft.UI.Xaml.Controls.ScrollBarVisibility".to_string(),
        // The alert vocabulary: ContentDialog's three slots ARE the
        // shape (two actions + close). ShowAsync's IAsyncOperation rides
        // windows-future paths like TextBox's.
        "Microsoft.UI.Xaml.Controls.ContentDialog".to_string(),
        "Microsoft.UI.Xaml.Controls.ContentDialogResult".to_string(),
        "Microsoft.UI.Xaml.Controls.ContentDialogButton".to_string(),
        // The select: ComboBox rows are ComboBoxItems (their content is
        // each option's TextBlock); SelectionChanged reports picks.
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
        // rides SelectionChanged.
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
        // returns.
        "Microsoft.UI.Xaml.Automation.Peers.AutomationControlType".to_string(),
        // The heading role's enum (docs/styling-plan.md D4), gating BOTH
        // halves of that role at once: AutomationProperties' setter and
        // every peer's GetHeadingLevel read. UIA's HeadingLevel is the
        // property that gives real heading NAVIGATION;
        // AutomationProperties::SetLevel is a different property
        // (hierarchical item level) and SetLocalizedControlType would
        // only make Narrator say the word.
        "Microsoft.UI.Xaml.Automation.Peers.AutomationHeadingLevel".to_string(),
        // Menus (DESIGN.md, Menus and the command vocabulary): the
        // ratified WinUI lowering — MenuBar, MenuBarItem per grouping
        // node, the flyout item kinds 1:1, KeyboardAccelerator per
        // shortcut, MenuFlyout as ContextFlyout. The item base class must
        // be present or MenuBarItem.Items/MenuFlyout.Items name a type
        // that does not exist.
        "Microsoft.UI.Xaml.Controls.MenuBar".to_string(),
        "Microsoft.UI.Xaml.Controls.MenuBarItem".to_string(),
        "Microsoft.UI.Xaml.Controls.MenuFlyoutItemBase".to_string(),
        "Microsoft.UI.Xaml.Controls.MenuFlyoutItem".to_string(),
        "Microsoft.UI.Xaml.Controls.ToggleMenuFlyoutItem".to_string(),
        "Microsoft.UI.Xaml.Controls.RadioMenuFlyoutItem".to_string(),
        "Microsoft.UI.Xaml.Controls.MenuFlyoutSubItem".to_string(),
        "Microsoft.UI.Xaml.Controls.MenuFlyoutSeparator".to_string(),
        // Shortcuts ride the REAL accelerator machinery; the chord
        // enums KeyboardAccelerator's Key/Modifiers setters take live in
        // Windows.System.
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
        // THE SEMANTIC ICONS (docs/styling-plan.md D6): every `Icon`
        // setter takes an IconElement, and BOTH routes are needed —
        // `Symbol` covers 17 of kaya's 20 concepts, and info, warning and
        // lock have no member at all, so those are Segoe Fluent
        // codepoints through FontIcon (docs/styling/symbols-fluent.md).
        // Neither route sets a FontFamily: both resolve through the
        // SymbolThemeFontFamily theme resource, which is what makes the
        // Windows 10 fallback to Segoe MDL2 Assets free (33/33).
        "Microsoft.UI.Xaml.Controls.IconElement".to_string(),
        "Microsoft.UI.Xaml.Controls.Symbol".to_string(),
        "Microsoft.UI.Xaml.Controls.SymbolIcon".to_string(),
        "Microsoft.UI.Xaml.Controls.FontIcon".to_string(),
        // THE TOOLBAR (docs/chrome-plan.md C2's WinUI row): the promoted
        // catalog actions as a CommandBar of AppBarButtons. Filtering
        // `CommandBar` ALONE emits it with NO PrimaryCommands and no
        // SecondaryCommands (measured: 176 methods, neither present) —
        // both are IObservableVector<ICommandBarElement>, so that element
        // type, which kaya never names in a signature, unlocks them.
        // AppBar is CommandBar's BASE, without which the bar cannot be
        // cast into the shell Grid. NOT filtered, each absence a
        // decision: AppBarToggleButton and AppBarSeparator (only `action`
        // items are promotable) and the CommandBar*/AppBar* styling enums.
        "Microsoft.UI.Xaml.Controls.CommandBar".to_string(),
        "Microsoft.UI.Xaml.Controls.AppBar".to_string(),
        "Microsoft.UI.Xaml.Controls.ICommandBarElement".to_string(),
        "Microsoft.UI.Xaml.Controls.AppBarButton".to_string(),
        // THE TITLEBAR THE TOOLBAR MERGES INTO (docs/chrome-plan.md C2's
        // WinUI row): the commands ride IN the caption row. ONE ENTRY IS
        // ENOUGH, measured: every slot this arm uses is typed in
        // already-filtered types. TitleBarTemplateSettings is deliberately
        // absent — kaya reads no template state.
        "Microsoft.UI.Xaml.Controls.TitleBar".to_string(),
        // THE APP IDENTITY'S CAPTION SINK (docs/app-identity-plan.md I3):
        // `ITitleBar`'s IconSource slot. ONE SUBCLASS REACHES BYTES,
        // measured (the plan's I1/§2): of the seven IconSource subclasses
        // only ImageIconSource carries an `ImageSource` slot, and
        // BitmapIconSource's only picture slot is a `Uri`, which would
        // force a temp file. IconSource is the base SetIconSource takes.
        "Microsoft.UI.Xaml.Controls.IconSource".to_string(),
        "Microsoft.UI.Xaml.Controls.ImageIconSource".to_string(),
        // THE TASKBAR AND ALT-TAB SINK, the WINDOW's icon and not the
        // control's (I3: one declaration, two sinks). `Microsoft.UI.IconId`
        // is the parameter type of every `…WithIconId` overload on
        // IAppWindow/IAppWindow4; without it only the overloads demanding
        // an .ico path on disk survive, and kaya's icon arrives as bytes.
        "Microsoft.UI.IconId".to_string(),
        // THE WINDOW'S OWN CAPTION HEIGHT: the XAML control does not
        // tell the WINDOW what its caption is, so the app must
        // (docs/chrome-plan.md C2's WinUI row and
        // docs/chrome/toolbar-winui.md carry the measurements).
        // `Window.AppWindow` is the ONLY route. NOT filtered: every other
        // Windowing type, since kaya sizes its windows through XAML.
        "Microsoft.UI.Windowing.AppWindow".to_string(),
        "Microsoft.UI.Windowing.AppWindowTitleBar".to_string(),
        "Microsoft.UI.Windowing.TitleBarHeightOption".to_string(),
        // DRAG AND DROP (docs/dnd-plan.md §5 step 5). Until these landed
        // every ADD half of the six drag events was a `usize` vtable PAD
        // while the Remove halves survived on their i64 token, and
        // AllowDrop/CanDrag were reachable with no event to answer
        // (docs/probes/dnd-2026-09-02-gtk-winui.md §2.5). The payload IS
        // WinRT DataTransfer here: XAML drag is `DataPackage` and there is
        // no classic-Win32 door into DragStarting, which is the one place
        // the clipboard's "classic Win32, deliberately" ruling cannot hold.
        // DragStarting and DropCompleted ride the already-filtered
        // TypedEventHandler; only the four DragEnter/Over/Leave/Drop
        // events have a handler type of their own.
        "Microsoft.UI.Xaml.DragStartingEventArgs".to_string(),
        "Microsoft.UI.Xaml.DropCompletedEventArgs".to_string(),
        "Microsoft.UI.Xaml.DragEventHandler".to_string(),
        "Microsoft.UI.Xaml.DragEventArgs".to_string(),
        "Microsoft.UI.Xaml.DragOperationDeferral".to_string(),
        "Windows.ApplicationModel.DataTransfer.DataPackage".to_string(),
        "Windows.ApplicationModel.DataTransfer.DataPackageView".to_string(),
        "Windows.ApplicationModel.DataTransfer.DataPackageOperation".to_string(),
        "Windows.ApplicationModel.DataTransfer.StandardDataFormats".to_string(),
        // The image and files representations: SetBitmap takes a stream
        // REFERENCE and SetStorageItems an IIterable<IStorageItem>, so the
        // two carrier types come with them. `custom(id, bytes)` needs none
        // of this — it rides SetData's IInspectable over a memory IStream
        // (probe 1: the string flavour crosses as UTF-16 with a NUL).
        "Windows.Storage.Streams.IRandomAccessStream".to_string(),
        "Windows.Storage.Streams.IRandomAccessStreamWithContentType".to_string(),
        "Windows.Storage.Streams.RandomAccessStreamReference".to_string(),
        "Windows.Storage.IStorageItem".to_string(),
        "Windows.Storage.StorageFile".to_string(),
    ];
    let args: Vec<&str> = args.iter().map(String::as_str).collect();
    windows_bindgen::bindgen(args);
    fix_array_proxy_paths();
    fix_observable_vector_paths();
    println!("generated crates/kaya/src/winui/bindings.rs");
}

/// ItemCollection (ComboBox.Items) has IObservableVector as its DEFAULT
/// interface, but windows-bindgen's built-in reference maps all of
/// Windows.Foundation.Collections to the windows-collections crate, whose
/// pinned 0.3 ships only the plain vector/iterable types. The references
/// list is first-match-wins with the built-ins inserted at the front, so
/// no --reference override can carve the two observable types out.
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

/// windows-bindgen 0.62 emits `windows_core::ArrayProxy::from_raw_parts
/// (..).as_array()` in the IPropertyValue vtable shims (pulled in by the
/// IReference filter), but windows-core 0.62.2 keeps that type at
/// `imp::array_proxy` with a Deref-to-Array API.
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
