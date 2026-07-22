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
    ];
    let args: Vec<&str> = args.iter().map(String::as_str).collect();
    windows_bindgen::bindgen(args);
    fix_array_proxy_paths();
    println!("generated crates/kaya/src/winui/bindings.rs");
}

/// windows-bindgen 0.62 emits `windows_core::ArrayProxy::from_raw_parts
/// (..).as_array()` in the IPropertyValue vtable shims (pulled in by the
/// IReference filter), but windows-core 0.62.2 keeps that type at
/// `imp::array_proxy` with a Deref-to-Array API. Rewrite to the
/// spelling the pinned windows-core actually exports; `&mut proxy`
/// coerces to `&mut Array<T>` and the proxy's Drop performs the
/// write-back after the call, same semantics either way.
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
