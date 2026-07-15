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
        "Microsoft.UI.Xaml.Controls.StackPanel".to_string(),
        "Windows.Foundation.EventHandler".to_string(),
        "Windows.ApplicationModel.Core.ICoreApplicationUnhandledError".to_string(),
        "Windows.ApplicationModel.Core.UnhandledErrorDetectedEventArgs".to_string(),
        "Windows.ApplicationModel.Core.UnhandledError".to_string(),
        "Microsoft.UI.Dispatching.DispatcherQueue".to_string(),
        "Microsoft.UI.Dispatching.DispatcherQueueHandler".to_string(),
    ];
    let args: Vec<&str> = args.iter().map(String::as_str).collect();
    windows_bindgen::bindgen(args);
    println!("generated crates/kaya/src/winui/bindings.rs");
}
