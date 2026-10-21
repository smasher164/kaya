//! The skin's WinUI arm (docs/styling-pass-plan.md §3's WinUI row, Y2-Y9).
//! tools/lib/skin_winui.py holds its doors.

use std::cell::RefCell;
use std::collections::HashMap;
use std::sync::Arc;

use super::*;
use bindings::Microsoft::UI::Xaml::Automation::AutomationProperties;
use bindings::Microsoft::UI::Xaml::Automation::Peers::AutomationControlType;
use bindings::Microsoft::UI::Xaml::Controls::ItemContainer;
use bindings::Microsoft::UI::Xaml::Media::ImageBrush;
use bindings::Microsoft::UI::Xaml::{CornerRadius, VerticalAlignment};

#[derive(Default, Clone)]
struct Ground {
    kind: i64,
    packed: Option<i64>,
    bytes: Option<Arc<[u8]>>,
    picture: Option<BitmapImage>,
    generation: u64,
    watched: bool,
}

struct Dock {
    host: Grid,
    root: Option<WidgetId>,
    player: Option<u64>,
}

#[derive(Default)]
struct Skin {
    grounds: HashMap<u64, Ground>,
    /// An activatable container's ItemContainer, by the container's id and by
    /// the wrapped grid's COM identity (`element()` answers it).
    hosts: HashMap<u64, ItemContainer>,
    host_keys: HashMap<usize, ItemContainer>,
    /// The item's child: the selected fill, the container, the accent pill.
    frames: HashMap<u64, Grid>,
    table_rows: std::collections::HashSet<u64>,
    /// The filled activatable containers whose item took the fill's corner.
    host_fills: HashMap<u64, i64>,
    selected: HashMap<u64, bool>,
    shapes: HashMap<u64, i64>,
    shapers: HashMap<u64, Grid>,
    tints: HashMap<u64, i64>,
    /// The dock surface's id to its dock, and the window to its dock surface.
    docks: HashMap<u64, Dock>,
    dock_of: HashMap<u64, u64>,
    /// The decoded art an image ground draws, for the readers' picture probe.
    #[cfg(feature = "harness")]
    decoded: HashMap<u64, Option<(u32, u32, Arc<Vec<u8>>)>>,
}

thread_local! {
    static SKIN: RefCell<Skin> = RefCell::new(Skin::default());
}

#[link(name = "user32")]
unsafe extern "system" {
    fn GetCursorPos(point: *mut Point32) -> i32;
}

fn container(core: &CoreState, id: WidgetId) -> Option<Grid> {
    match core.widgets.get(&id) {
        Some(NativeWidget::Column(grid) | NativeWidget::Row(grid)) => Some(grid.clone()),
        _ => None,
    }
}

fn key_of(element: &UIElement) -> Option<usize> {
    windows_core::Interface::cast::<windows_core::IUnknown>(element)
        .ok()
        .map(|unknown| windows_core::Interface::as_raw(&unknown) as usize)
}

/// What a parent lays out for a wrapped container: its ItemContainer.
pub(super) fn host_of(inner: &UIElement) -> Option<UIElement> {
    SKIN.with_borrow(|s| {
        if s.host_keys.is_empty() {
            return None;
        }
        s.host_keys.get(&key_of(inner)?)?.cast().ok()
    })
}

#[cfg(feature = "harness")]
/// What a wrapped container's ItemContainer holds: the container's own
/// control, for the walks that meet the item in its place (a table's rows).
pub(super) fn inner_of(outer: &UIElement) -> Option<UIElement> {
    use windows_core::Interface;
    let child = outer.cast::<ItemContainer>().ok()?.Child().ok()?;
    match child.cast::<Grid>() {
        Ok(frame) if frame.Name().is_ok_and(|n| n.to_string() == ITEM_FRAME_NAME) => frame.Children().ok()?.GetAt(1).ok(),
        _ => Some(child),
    }
}

#[cfg(feature = "harness")]
/// The element an assistive client meets for a target: the host of a wrapped
/// container, the element itself otherwise.
pub(super) fn ax_element(element: &UIElement) -> UIElement {
    host_of(element).unwrap_or_else(|| element.clone())
}

fn dark_of(core: &CoreState, element: Option<&FrameworkElement>) -> bool {
    let window_dark = || {
        core.window
            .Content()
            .ok()
            .and_then(|root| windows_core::Interface::cast::<FrameworkElement>(&root).ok())
            .and_then(|e| e.ActualTheme().ok())
            .is_some_and(|theme| theme == ElementTheme::Dark)
    };
    match element {
        Some(e) if e.IsLoaded().unwrap_or(false) => e.ActualTheme().is_ok_and(|t| t == ElementTheme::Dark),
        _ => window_dark(),
    }
}

fn high_contrast() -> bool {
    windows::UI::ViewManagement::AccessibilitySettings::new()
        .and_then(|s| s.HighContrast())
        .unwrap_or(false)
}

/// A brush key resolved in a theme through a detached element that requests
/// it, `fill_tint`'s route: RGBA, 0-255.
pub(super) fn resolve(key: &str, dark: bool) -> windows_core::Result<[f64; 4]> {
    let markup = format!(
        "<Grid xmlns=\"http://schemas.microsoft.com/winfx/2006/xaml/presentation\" \
         RequestedTheme=\"{}\" Background=\"{{ThemeResource {key}}}\"/>",
        if dark { "Dark" } else { "Light" }
    );
    let probe: Grid = XamlReader::Load(&HSTRING::from(markup))?.cast()?;
    let c = probe.Background()?.cast::<SolidColorBrush>()?.Color()?;
    Ok([c.R, c.G, c.B, c.A].map(f64::from))
}

fn rgb_of(c: [f64; 4]) -> u32 {
    (c[0] as u32) << 16 | (c[1] as u32) << 8 | c[2] as u32
}

/// The skin's props. Answers whether this arm took the prop.
pub(super) fn set_prop(core: &mut CoreState, id: WidgetId, prop: Prop, value: &Value) -> windows_core::Result<bool> {
    let is_container = container(core, id).is_some();
    let is_image = matches!(core.widgets.get(&id), Some(NativeWidget::Image { .. }));
    let is_label = matches!(core.widgets.get(&id), Some(NativeWidget::Label { .. }));
    match (prop, value) {
        (Prop::Ground, Value::I64(kind)) if is_container => {
            SKIN.with_borrow_mut(|s| s.grounds.entry(id.0).or_default().kind = *kind);
            paint_ground(core, id)?;
        }
        (Prop::Color, Value::I64(packed)) if is_container => {
            SKIN.with_borrow_mut(|s| s.grounds.entry(id.0).or_default().packed = Some(*packed));
            paint_ground(core, id)?;
        }
        (Prop::Source, Value::Blob(blob)) if is_container => {
            let bytes = blob.0.clone();
            let generation = SKIN.with_borrow_mut(|s| {
                let g = s.grounds.entry(id.0).or_default();
                g.bytes = Some(bytes.clone());
                g.picture = None;
                g.generation += 1;
                #[cfg(feature = "harness")]
                s.decoded.remove(&id.0);
                g.generation
            });
            paint_ground(core, id)?;
            if !bytes.is_empty() {
                images::picture(core, bytes, move |core, picture| {
                    let current = SKIN.with_borrow_mut(|s| {
                        let Some(g) = s.grounds.get_mut(&id.0) else { return false };
                        if g.generation != generation {
                            return false;
                        }
                        g.picture = picture;
                        true
                    });
                    if current { paint_ground(core, id) } else { Ok(()) }
                })?;
            }
        }
        (Prop::Filled, Value::I64(tint)) if is_container && *tint == i64::from(crate::wire::TINT_OVERLAY) => {
            let grid = container(core, id).expect("checked above");
            grid.SetStyle(&overlay_style()?)?;
            grid.SetRequestedTheme(ElementTheme::Dark)?;
            core.filled.insert(id, *tint);
            stamp_container_padding(core, id)?;
        }
        (Prop::Activatable, Value::Bool(on)) if is_container => {
            if *on {
                wrap(core, id)?;
            } else {
                unwrap(core, id)?;
            }
        }
        (Prop::Selected, Value::Bool(on)) if is_container => {
            SKIN.with_borrow_mut(|s| s.selected.insert(id.0, *on));
            if let Some(host) = SKIN.with_borrow(|s| s.hosts.get(&id.0).cloned()) {
                host.SetIsSelected(*on)?;
            }
            paint_selected(id)?;
        }
        (Prop::Shape, Value::I64(shape)) if is_image => {
            SKIN.with_borrow_mut(|s| s.shapes.insert(id.0, *shape));
            reshape(core, id)?;
        }
        (Prop::Tint, Value::I64(tint)) if is_label => {
            SKIN.with_borrow_mut(|s| s.tints.insert(id.0, *tint));
            paint_tint(core, id)?;
        }
        _ => return Ok(false),
    }
    Ok(true)
}

pub(super) fn forget(core: &mut CoreState, id: WidgetId) {
    let _ = core;
    SKIN.with_borrow_mut(|s| {
        s.grounds.remove(&id.0);
        if let Some(host) = s.hosts.remove(&id.0) {
            s.host_keys.retain(|_, h| *h != host);
        }
        s.host_fills.remove(&id.0);
        s.frames.remove(&id.0);
        s.table_rows.remove(&id.0);
        s.selected.remove(&id.0);
        s.shapes.remove(&id.0);
        s.shapers.remove(&id.0);
        s.tints.remove(&id.0);
        TINT_DRAWN.with_borrow_mut(|m| m.remove(&id.0));
        ROLE_STYLE.with_borrow_mut(|m| m.remove(&id.0));
        #[cfg(feature = "harness")]
        s.decoded.remove(&id.0);
    });
}

// --- Y2, Y3: grounds ---------------------------------------------------

/// The gradient's top stop is the core's clamped colour for the appearance
/// (light in bits 24-47, dark in 0-23), its bottom stop the window ground
/// resolved from its token at this moment; in High Contrast both stops are
/// the window colour, flat, as a {ThemeResource}.
fn gradient_brush(dark: bool, packed: i64) -> windows_core::Result<Brush> {
    let stops = if high_contrast() {
        "<GradientStop Offset=\"0\" Color=\"{ThemeResource SystemColorWindowColor}\"/>\
         <GradientStop Offset=\"1\" Color=\"{ThemeResource SystemColorWindowColor}\"/>"
            .to_owned()
    } else {
        let top = if dark { packed & 0xFF_FFFF } else { (packed >> 24) & 0xFF_FFFF };
        let ground = rgb_of(resolve("ApplicationPageBackgroundThemeBrush", dark)?);
        format!(
            "<GradientStop Offset=\"0\" Color=\"#FF{top:06X}\"/>\
             <GradientStop Offset=\"1\" Color=\"#FF{ground:06X}\"/>"
        )
    };
    XamlReader::Load(&HSTRING::from(format!(
        "<LinearGradientBrush xmlns=\"http://schemas.microsoft.com/winfx/2006/xaml/presentation\" \
         StartPoint=\"0,0\" EndPoint=\"0,1\">{stops}</LinearGradientBrush>"
    )))?
    .cast()
}

fn paint_ground(core: &CoreState, id: WidgetId) -> windows_core::Result<()> {
    let Some(grid) = container(core, id) else { return Ok(()) };
    let Some(ground) = SKIN.with_borrow(|s| s.grounds.get(&id.0).cloned()) else { return Ok(()) };
    if !ground.watched {
        SKIN.with_borrow_mut(|s| {
            if let Some(g) = s.grounds.get_mut(&id.0) {
                g.watched = true;
            }
        });
        grid.ActualThemeChanged(&TypedEventHandler::<FrameworkElement, windows_core::IInspectable>::new(
            move |_, _| {
                images::on_ui(move |core| paint_ground(core, id));
                Ok(())
            },
        ))?;
    }
    let fe: FrameworkElement = grid.cast()?;
    match ground.kind {
        k if k == crate::wire::GROUND_GRADIENT => match ground.packed {
            Some(packed) => grid.SetBackground(&gradient_brush(dark_of(core, Some(&fe)), packed)?),
            None => grid.SetBackground(None::<&Brush>),
        },
        k if k == crate::wire::GROUND_IMAGE => match ground.picture {
            Some(picture) => {
                let brush = ImageBrush::new()?;
                brush.SetStretch(Stretch::UniformToFill)?;
                brush.SetImageSource(&picture)?;
                grid.SetBackground(&brush)
            }
            None => grid.SetBackground(None::<&Brush>),
        },
        _ => grid.SetBackground(None::<&Brush>),
    }
}

/// The platform's panel over media (Y3): Fluent's in-app acrylic, the dark
/// theme's, which falls back to its own opaque colour when the user turns
/// Transparency effects off; text inside takes the dark theme's foreground.
fn overlay_style() -> windows_core::Result<Style> {
    XamlReader::Load(&HSTRING::from(
        "<Style xmlns=\"http://schemas.microsoft.com/winfx/2006/xaml/presentation\" TargetType=\"Grid\">\
         <Setter Property=\"Background\" Value=\"{ThemeResource AcrylicInAppFillColorDefaultBrush}\"/>\
         <Setter Property=\"CornerRadius\" Value=\"{ThemeResource OverlayCornerRadius}\"/></Style>",
    ))?
    .cast()
}

// --- Y4: activatable and selected --------------------------------------

const ITEM_FRAME_NAME: &str = "kayaItemFrame";

/// Y4's WinUI selected surface, ListView's own: `ListViewItemBackgroundSelected`
/// under the container and the accent pill at its leading edge, 3x16 as
/// ListViewItemPresenter draws it. ItemContainer's own selection is a ring,
/// which the item's resources clear (the 2026-10-17 preview).
const ITEM_FRAME_XAML: &str = "<Grid xmlns=\"http://schemas.microsoft.com/winfx/2006/xaml/presentation\" \
     Name=\"kayaItemFrame\">\
     <Border Visibility=\"Collapsed\" Background=\"{ThemeResource ListViewItemBackgroundSelected}\" \
       CornerRadius=\"{ThemeResource ListViewItemCornerRadius}\"/>\
     <Border Visibility=\"Collapsed\" Width=\"3\" Height=\"16\" HorizontalAlignment=\"Left\" VerticalAlignment=\"Center\" \
       Background=\"{ThemeResource ListViewItemSelectionIndicatorBrush}\" \
       CornerRadius=\"{ThemeResource ListViewItemSelectionIndicatorCornerRadius}\"/>\
   </Grid>";

const ITEM_RING_KEYS: [&str; 4] = [
    "ItemContainerSelectionVisualBackground",
    "ItemContainerSelectionVisualPointerOverBackground",
    "ItemContainerSelectionVisualPressedBackground",
    "ItemContainerSelectedInnerBorderBrush",
];

/// The selected fill and the pill shown while the app's selection is on.
fn paint_selected(id: WidgetId) -> windows_core::Result<()> {
    let (frame, on, table, fill) = SKIN.with_borrow(|s| {
        (s.frames.get(&id.0).cloned(), s.selected.get(&id.0).copied().unwrap_or(false), s.table_rows.contains(&id.0),
         s.host_fills.get(&id.0).copied().unwrap_or(0))
    });
    let Some(frame) = frame else { return Ok(()) };
    let vis = |shown: bool| if shown { Visibility::Visible } else { Visibility::Collapsed };
    let children = frame.Children()?;
    children.GetAt(0)?.SetVisibility(vis(on))?;
    children.GetAt(2)?.SetVisibility(vis(on && !table))?;
    // A filled card's own fill sat over the selected fill and hid it: the
    // selected surface takes the fill's place, its shape and stroke kept.
    if fill != 0 {
        if let Ok(card) = windows_core::Interface::cast::<Grid>(&children.GetAt(1)?) {
            card.SetStyle(&if on { tinted_style(fill, "SubtleFillColorTransparentBrush")? } else { filled_style(fill)? })?;
        }
    }
    Ok(())
}

/// The selected surface again, after the container's fill was restyled.
pub(super) fn repaint_selected(id: WidgetId) -> windows_core::Result<()> {
    paint_selected(id)
}

/// A declared table's row keeps its cells on the header's edges and has no
/// room for the pill, so it wears the selected fill alone (DataGrid's row;
/// docs/traps.md, the ItemContainer that clips its child).
pub(super) fn seat_in_table(id: WidgetId, in_table: bool) -> windows_core::Result<()> {
    SKIN.with_borrow_mut(|s| {
        if in_table {
            s.table_rows.insert(id.0);
        } else {
            s.table_rows.remove(&id.0);
        }
    });
    paint_selected(id)
}

/// Whether a container is a declared table's row, which wears no pill.
pub(super) fn is_table_row(id: u64) -> bool {
    SKIN.with_borrow(|s| s.table_rows.contains(&id))
}

/// The item frame an activatable container's selection surface is drawn in.
#[cfg(feature = "harness")]
pub(super) fn frame_of(id: WidgetId) -> Option<Grid> {
    SKIN.with_borrow(|s| s.frames.get(&id.0).cloned())
}

/// Whether a container takes a click as a whole (its inset follows, Y4).
pub(super) fn is_activatable(id: WidgetId) -> bool {
    SKIN.with_borrow(|s| s.hosts.contains_key(&id.0))
}

/// A container that takes a click as a whole is the child of an
/// ItemContainer, Fluent's own item: its template draws the platform's hover
/// and press layers OVER the child and its selection ring around it, from its
/// tokens; its peer carries SelectionItem (Y4 reads selected off the tree),
/// and UIA calls it a button.
fn wrap(core: &mut CoreState, id: WidgetId) -> windows_core::Result<()> {
    if SKIN.with_borrow(|s| s.hosts.contains_key(&id.0)) {
        return Ok(());
    }
    require_control_resources("this container takes a click as a whole");
    let inner = core.widgets.get(&id).expect("scene validated the id").inner_element()?;
    let host = ItemContainer::new()?;
    host.SetHorizontalContentAlignment(HorizontalAlignment::Stretch)?;
    host.SetVerticalContentAlignment(VerticalAlignment::Stretch)?;
    host.SetMinHeight(0.0)?;
    host.SetMinWidth(0.0)?;
    AutomationProperties::SetAutomationControlType(&host, AutomationControlType::Button)?;
    let tag = core.widget_tags.get(&id.0).cloned().unwrap_or_default();
    let sink = core.occurrences.clone();
    let tapped_tag = tag.clone();
    let tapped_sink = sink.clone();
    // A PRESS ON THE CHILD, A RELEASE ON IT OR THE ITEM'S CAPTURE ENDING:
    // ItemContainer handles its own press, release and tap (its ItemInvoked
    // is internal), so a handler on the item hears none of them, while the
    // child sees the press first as it bubbles, and the release either on
    // itself or, when the item took the pointer, as the item's capture loss
    // (measured on the VM, 2026-10-16). A release outside the item is no
    // click. The child is hit-testable over its whole box (`round_host`).
    let armed = Arc::new(std::sync::atomic::AtomicBool::new(false));
    let pressed = armed.clone();
    inner.PointerPressed(&PointerEventHandler::new(move |_, _: windows_core::Ref<'_, PointerRoutedEventArgs>| {
        pressed.store(true, std::sync::atomic::Ordering::Relaxed);
        Ok(())
    }))?;
    let fire = {
        let armed = armed.clone();
        Arc::new(move || {
            if !armed.swap(false, std::sync::atomic::Ordering::Relaxed) || !pointer_inside(id) {
                return;
            }
            press(&tapped_sink, id, &tapped_tag);
        })
    };
    let released = fire.clone();
    inner.PointerReleased(&PointerEventHandler::new(move |_, _: windows_core::Ref<'_, PointerRoutedEventArgs>| {
        released();
        Ok(())
    }))?;
    host.PointerCaptureLost(&PointerEventHandler::new(move |_, _: windows_core::Ref<'_, PointerRoutedEventArgs>| {
        fire();
        Ok(())
    }))?;
    host.PreviewKeyDown(&KeyEventHandler::new(move |_, args| {
        if let Some(args) = args.as_ref() {
            let key = args.Key()?;
            if key == VirtualKey::Enter || key == VirtualKey::Space {
                args.SetHandled(true)?;
                press(&sink, id, &tag);
            }
        }
        Ok(())
    }))?;
    host.SetIsSelected(SKIN.with_borrow(|s| s.selected.get(&id.0).copied().unwrap_or(false)))?;
    let clear = theme_resource::<Brush>("SubtleFillColorTransparentBrush")?;
    let resources = host.Resources()?;
    for key in ITEM_RING_KEYS {
        resources.Insert(&PropertyValue::CreateString(&HSTRING::from(key))?, &clear)?;
    }
    let frame: Grid = XamlReader::Load(&HSTRING::from(ITEM_FRAME_XAML))?.cast()?;
    reseat_element(core, id, &inner, &host.cast()?)?;
    let pill = frame.Children()?.GetAt(1)?;
    frame.Children()?.RemoveAt(1)?;
    frame.Children()?.Append(&inner)?;
    frame.Children()?.Append(&pill)?;
    host.SetChild(&frame)?;
    let key = key_of(&inner).expect("a live control has a COM identity");
    SKIN.with_borrow_mut(|s| {
        s.hosts.insert(id.0, host.clone());
        s.host_keys.insert(key, host);
        s.frames.insert(id.0, frame);
    });
    paint_selected(id)?;
    stamp_container_padding(core, id)
}

/// Whether the pointer is over a container's laid-out box now.
fn pointer_inside(id: WidgetId) -> bool {
    CORE.with(|core| {
        let Ok(core) = core.try_borrow() else { return false };
        let Some(core) = core.as_ref() else { return false };
        let mut at = Point32 { x: 0, y: 0 };
        // SAFETY: a stack POINT for the call to fill.
        if unsafe { GetCursorPos(&mut at) } == 0 {
            return false;
        }
        widget_screen_rect(core, id.0).is_some_and(|(x, y, w, h)| {
            let (px, py) = (f64::from(at.x), f64::from(at.y));
            px >= x && px < x + w && py >= y && py < y + h
        })
    })
}

/// A filled activatable container's item takes the fill's corner, so the
/// item's state layer (drawn over its child, ItemContainer's template) and its
/// selection ring follow the card's shape.
fn round_host(core: &CoreState, id: WidgetId, host: &ItemContainer) -> windows_core::Result<()> {
    if SKIN.with_borrow(|s| s.host_fills.contains_key(&id.0)) {
        return Ok(());
    }
    match core.filled.get(&id) {
        Some(&tint) => {
            host.SetCornerRadius(theme_resource::<IReference<CornerRadius>>("OverlayCornerRadius")?.Value()?)?;
            SKIN.with_borrow_mut(|s| s.host_fills.insert(id.0, tint));
        }
        // An unfilled child draws nothing where it has no content, so the
        // pointer would pass through it to the item: the transparent token
        // makes the whole box the child's.
        None => {
            if let Some(grid) = container(core, id) {
                grid.SetBackground(&theme_resource::<Brush>("SubtleFillColorTransparentBrush")?)?;
            }
            SKIN.with_borrow_mut(|s| s.host_fills.insert(id.0, 0));
        }
    }
    Ok(())
}

#[cfg(feature = "harness")]
/// The tag an activatable container reports `activated` under, or `None`
/// when it is not one.
pub(super) fn activation_tag(core: &CoreState, id: WidgetId) -> Option<Vec<u8>> {
    SKIN.with_borrow(|s| s.hosts.contains_key(&id.0)).then(|| core.widget_tags.get(&id.0).cloned()).flatten()
}

fn unwrap(core: &mut CoreState, id: WidgetId) -> windows_core::Result<()> {
    let Some(host) = SKIN.with_borrow_mut(|s| {
        let host = s.hosts.remove(&id.0)?;
        s.host_keys.retain(|_, h| *h != host);
        Some(host)
    }) else {
        return Ok(());
    };
    let inner = core.widgets.get(&id).expect("scene validated the id").inner_element()?;
    host.SetChild(None::<&UIElement>)?;
    if let Some(frame) = SKIN.with_borrow_mut(|s| s.frames.remove(&id.0)) {
        frame.Children()?.Clear()?;
    }
    SKIN.with_borrow_mut(|s| s.host_fills.remove(&id.0));
    reseat_element(core, id, &host.cast()?, &inner)?;
    stamp_container_padding(core, id)
}

/// THE ONE PRESS DOOR (docs/styling-pass-plan.md Y4, AMENDED 2026-10-17): the
/// user's pick unless the app already selected the container, then the
/// activation, the item showing what the app last wrote.
pub(super) fn press(sink: &OccSink, id: WidgetId, tag: &[u8]) {
    restore_selected(id);
    if !SKIN.with_borrow(|s| s.selected.get(&id.0).copied().unwrap_or(false)) {
        sink.send_selection_changed_tag(tag);
    }
    sink.send_activated_tag(tag);
}

/// The selection is the app's (Y4): whatever the item did with the press, it
/// shows what the app last wrote.
fn restore_selected(id: WidgetId) {
    let (host, on) = SKIN.with_borrow(|s| (s.hosts.get(&id.0).cloned(), s.selected.get(&id.0).copied().unwrap_or(false)));
    if let Some(host) = host {
        let _ = host.SetIsSelected(on);
    }
    let _ = paint_selected(id);
}

/// The accessible name of an activatable container: its labels' text in
/// order, as every other backend's button is named by its content.
fn spoken(core: &CoreState, id: WidgetId, out: &mut Vec<String>) {
    for child in core.child_order.children(id) {
        match core.widgets.get(child) {
            Some(NativeWidget::Label { block, .. }) => {
                if let Ok(text) = block.Text() {
                    if !text.is_empty() {
                        out.push(text.to_string());
                    }
                }
            }
            Some(NativeWidget::Column(_) | NativeWidget::Row(_)) => spoken(core, *child, out),
            _ => {}
        }
    }
}

// --- Y6: shapes --------------------------------------------------------

/// The shape an image is drawn in, `rect` when none was set.
pub(super) fn shape_of(id: WidgetId) -> i64 {
    SKIN.with_borrow(|s| s.shapes.get(&id.0).copied().unwrap_or(crate::wire::SHAPE_RECT))
}

pub(super) fn look_corner(id: WidgetId, width: f64, height: f64) -> windows_core::Result<CornerRadius> {
    corner(shape_of(id), width, height)
}

pub(super) fn shaped(id: WidgetId) -> bool {
    shape_of(id) != crate::wire::SHAPE_RECT
}

/// The corner a shaped picture and its looks take: Fluent's
/// OverlayCornerRadius for `rounded`, half the shorter side for `circle`.
fn corner(shape: i64, width: f64, height: f64) -> windows_core::Result<CornerRadius> {
    Ok(if shape == crate::wire::SHAPE_CIRCLE {
        let r = width.min(height) / 2.0;
        CornerRadius { TopLeft: r, TopRight: r, BottomRight: r, BottomLeft: r }
    } else if shape == crate::wire::SHAPE_ROUNDED {
        theme_resource::<IReference<CornerRadius>>("OverlayCornerRadius")?.Value()?
    } else {
        CornerRadius::default()
    })
}

/// A shaped picture is painted by an ImageBrush on a Grid whose corners are
/// the shape (the Ellipse route's equivalent: a CornerRadius clips the brush
/// it paints), over the Image, which keeps the box, the label and the phase;
/// the loading and failed looks take the same corners.
pub(super) fn reshape(core: &mut CoreState, id: WidgetId) -> windows_core::Result<()> {
    let Some((host, image)) = (match core.widgets.get(&id) {
        Some(NativeWidget::Image { host, image }) => Some((host.clone(), image.clone())),
        _ => None,
    }) else {
        return Ok(());
    };
    let shape = shape_of(id);
    let (width, height, fit) = images::arm_box(core, id);
    let (width, height) = if width > 0.0 && height > 0.0 {
        (width, height)
    } else {
        (image.ActualWidth()?, image.ActualHeight()?)
    };
    let radius = corner(shape, width, height)?;
    for look in images::looks(core, id) {
        look.SetCornerRadius(radius)?;
    }
    let existing = SKIN.with_borrow(|s| s.shapers.get(&id.0).cloned());
    if shape == crate::wire::SHAPE_RECT {
        if let Some(shaper) = existing {
            let children = host.Children()?;
            let mut at = 0u32;
            if children.IndexOf(&shaper, &mut at)? {
                children.RemoveAt(at)?;
            }
            SKIN.with_borrow_mut(|s| s.shapers.remove(&id.0));
        }
        return images::refresh(core, id);
    }
    let shaper = match existing {
        Some(shaper) => shaper,
        None => {
            let shaper = Grid::new()?;
            shaper.SetHorizontalAlignment(HorizontalAlignment::Left)?;
            shaper.SetVerticalAlignment(VerticalAlignment::Center)?;
            shaper.SetIsHitTestVisible(false)?;
            AutomationProperties::SetAccessibilityView(
                &shaper,
                bindings::Microsoft::UI::Xaml::Automation::Peers::AccessibilityView::Raw,
            )?;
            host.Children()?.InsertAt(1, &shaper)?;
            SKIN.with_borrow_mut(|s| s.shapers.insert(id.0, shaper.clone()));
            shaper
        }
    };
    if width > 0.0 && height > 0.0 {
        shaper.SetWidth(width)?;
        shaper.SetHeight(height)?;
    }
    shaper.SetCornerRadius(radius)?;
    let brush = ImageBrush::new()?;
    brush.SetStretch(match fit.and_then(|f| crate::wire::vocab_name(crate::wire::FITS, f)) {
        Some("fill") => Stretch::Fill,
        Some("contain") => Stretch::Uniform,
        _ => Stretch::UniformToFill,
    })?;
    if let Ok(source) = image.Source() {
        brush.SetImageSource(&source)?;
    }
    shaper.SetBackground(&brush)?;
    images::refresh(core, id)
}

/// The Grid painting a shaped image's picture, for phase_drawn.
#[cfg(feature = "harness")]
pub(super) fn shaper_of(id: WidgetId) -> Option<Grid> {
    SKIN.with_borrow(|s| s.shapers.get(&id.0).cloned())
}

// --- Y7: a label's tint ------------------------------------------------

/// The standalone brush a tint paints text in (docs/styling-plan.md D1's
/// `standalone`): never the fill's.
fn standalone_key(tint: i64) -> Option<&'static str> {
    match u32::try_from(tint).ok()? {
        crate::wire::TINT_ACCENT => Some("AccentTextFillColorPrimaryBrush"),
        crate::wire::TINT_SUCCESS => Some("SystemFillColorSuccessBrush"),
        crate::wire::TINT_WARNING => Some("SystemFillColorCautionBrush"),
        crate::wire::TINT_CRITICAL => Some("SystemFillColorCriticalBrush"),
        _ => None,
    }
}

fn in_fill(core: &CoreState, id: WidgetId) -> bool {
    let mut at = id;
    while let Some(parent) = core.child_order.parent_of(at) {
        if core.filled.contains_key(&parent) {
            return true;
        }
        at = parent;
    }
    false
}

// The label's role step its tint must keep (the heading and caption styles).
thread_local! {
    static ROLE_STYLE: RefCell<HashMap<u64, &'static str>> = RefCell::new(HashMap::new());
    static TINT_DRAWN: RefCell<HashMap<u64, (Option<&'static str>, Option<&'static str>)>> = RefCell::new(HashMap::new());
}

pub(super) fn role_style(id: WidgetId, key: &'static str) {
    ROLE_STYLE.with_borrow_mut(|m| m.insert(id.0, key));
}

pub(super) fn paint_tint(core: &CoreState, id: WidgetId) -> windows_core::Result<()> {
    let Some(NativeWidget::Label { block, .. }) = core.widgets.get(&id) else { return Ok(()) };
    let Some(tint) = SKIN.with_borrow(|s| s.tints.get(&id.0).copied()) else { return Ok(()) };
    let role = ROLE_STYLE.with_borrow(|m| m.get(&id.0).copied());
    let key = standalone_key(tint).filter(|_| !in_fill(core, id));
    if TINT_DRAWN.with_borrow_mut(|m| m.insert(id.0, (key, role)) == Some((key, role))) {
        return Ok(());
    }
    match key {
        Some(key) => block.SetStyle(&themed_foreground_style("TextBlock", role, key)?),
        None => match role {
            Some("CaptionTextBlockStyle") => {
                block.SetStyle(&themed_foreground_style("TextBlock", role, "TextFillColorSecondaryBrush")?)
            }
            Some(key) => block.SetStyle(&theme_resource::<Style>(key)?),
            None => block.SetStyle(None::<&Style>),
        },
    }
}

// --- Y8: the dock ------------------------------------------------------

/// `attach_dock`: a Grid row under the window's content, spanning the window
/// (Windows Media Player's layout), on Fluent's layer fill.
pub(super) fn attach_dock(core: &mut CoreState, window: u64, dock: u64) -> windows_core::Result<()> {
    let host: Grid = XamlReader::Load(&HSTRING::from(
        "<Grid xmlns=\"http://schemas.microsoft.com/winfx/2006/xaml/presentation\" \
         Background=\"{ThemeResource LayerFillColorDefaultBrush}\" \
         BorderBrush=\"{ThemeResource CardStrokeColorDefaultBrush}\" BorderThickness=\"0,1,0,0\"/>",
    ))?
    .cast()?;
    host.SetVisibility(Visibility::Collapsed)?;
    Grid::SetRow(&host, 1)?;
    let ground = window_ground(&winui_window(core, window)?)?;
    let rows = ground.RowDefinitions()?;
    if rows.Size()? == 0 {
        let content = RowDefinition::new()?;
        content.SetHeight(GridLength { Value: 1.0, GridUnitType: GridUnitType::Star })?;
        rows.Append(&content)?;
        let bar = RowDefinition::new()?;
        bar.SetHeight(GridLength { Value: 1.0, GridUnitType: GridUnitType::Auto })?;
        rows.Append(&bar)?;
    }
    ground.Children()?.Append(&host)?;
    SKIN.with_borrow_mut(|s| {
        s.docks.insert(dock, Dock { host, root: None, player: None });
        s.dock_of.insert(window, dock);
    });
    Ok(())
}

/// `set_dock_player` (docs/media-player-plan.md M17): held, and drawn as nothing.
pub(super) fn set_dock_player(dock: u64, player: Option<u64>) {
    SKIN.with_borrow_mut(|s| {
        if let Some(d) = s.docks.get_mut(&dock) {
            d.player = player;
        }
    });
}

pub(super) fn is_dock(surface: u64) -> bool {
    SKIN.with_borrow(|s| s.docks.contains_key(&surface))
}

#[cfg(feature = "harness")]
/// Whether a ground child is a dock's host, which the window's content shares
/// the ground with.
pub(super) fn is_dock_host(element: &UIElement) -> bool {
    SKIN.with_borrow(|s| {
        s.docks.values().any(|d| d.host.cast::<UIElement>().ok().as_ref() == Some(element))
    })
}

/// A window's content was replaced: its dock goes back beside it.
pub(super) fn keep_dock(core: &CoreState, window: u64) -> windows_core::Result<()> {
    let Some(host) = SKIN.with_borrow(|s| s.dock_of.get(&window).and_then(|d| s.docks.get(d)).map(|d| d.host.clone()))
    else {
        return Ok(());
    };
    let ground = window_ground(&winui_window(core, window)?)?;
    let children = ground.Children()?;
    let mut at = 0u32;
    if !children.IndexOf(&host, &mut at)? {
        children.Append(&host)?;
    }
    Ok(())
}

pub(super) fn mount_dock(core: &mut CoreState, dock: u64, root: WidgetId, element: &UIElement) -> windows_core::Result<()> {
    let Some(host) = SKIN.with_borrow_mut(|s| {
        let d = s.docks.get_mut(&dock)?;
        d.root = Some(root);
        Some(d.host.clone())
    }) else {
        return Ok(());
    };
    let children = host.Children()?;
    children.Clear()?;
    children.Append(element)?;
    sync(core)
}

/// The window whose dock holds a widget, if a dock does.
#[cfg(feature = "harness")]
pub(super) fn docked_in(core: &CoreState, id: WidgetId) -> Option<u64> {
    let mut top = id;
    while let Some(parent) = core.child_order.parent_of(top) {
        top = parent;
    }
    SKIN.with_borrow(|s| {
        let (dock, _) = s.docks.iter().find(|(_, d)| d.root == Some(top))?;
        s.dock_of.iter().find(|(_, d)| *d == dock).map(|(w, _)| *w)
    })
}

/// The window's dock host while it shows.
pub(super) fn dock_shown(window: u64) -> windows_core::Result<Option<Grid>> {
    let Some(host) = SKIN.with_borrow(|s| Some(s.docks.get(s.dock_of.get(&window)?)?.host.clone())) else {
        return Ok(None);
    };
    Ok((host.Visibility()? == Visibility::Visible && host.ActualHeight()? > 1.0).then_some(host))
}

/// The height the window's dock takes at its foot, 0 while it is collapsed.
pub(super) fn dock_height(window: u64) -> windows_core::Result<f64> {
    Ok(match dock_shown(window)? {
        Some(host) => host.ActualHeight()?,
        None => 0.0,
    })
}

/// A widget the dock's root holds, through any rows and columns.
fn holds_widget(core: &CoreState, id: WidgetId) -> bool {
    match core.widgets.get(&id) {
        Some(NativeWidget::Column(_) | NativeWidget::Row(_)) => {
            core.child_order.children(id).iter().any(|c| holds_widget(core, *c))
        }
        Some(_) => true,
        None => false,
    }
}

/// The batch's end: a dock collapses while its root holds no widget, an
/// activatable container is named by its labels, a label's tint follows its
/// fill.
pub(super) fn sync(core: &CoreState) -> windows_core::Result<()> {
    let docks: Vec<(Grid, Option<WidgetId>)> =
        SKIN.with_borrow(|s| s.docks.values().map(|d| (d.host.clone(), d.root)).collect());
    for (host, root) in docks {
        let shown = root.is_some_and(|r| holds_widget(core, r));
        host.SetVisibility(if shown { Visibility::Visible } else { Visibility::Collapsed })?;
    }
    let hosts: Vec<(u64, ItemContainer)> = SKIN.with_borrow(|s| s.hosts.iter().map(|(k, v)| (*k, v.clone())).collect());
    for (id, host) in hosts {
        round_host(core, WidgetId(id), &host)?;
        let mut words = Vec::new();
        spoken(core, WidgetId(id), &mut words);
        AutomationProperties::SetName(&host, &HSTRING::from(words.join(", ")))?;
    }
    let tints: Vec<u64> = SKIN.with_borrow(|s| s.tints.keys().copied().collect());
    for id in tints {
        paint_tint(core, WidgetId(id))?;
    }
    Ok(())
}

// --- Y9: the readers -----------------------------------------------------

#[cfg(feature = "harness")]
pub(super) mod read {
    use super::*;

    /// One print of the window, and where an element's points land in it.
    pub(in super::super) struct Shot {
        grab: Grab,
        root_x: i32,
        root_y: i32,
        scale: f64,
        root: UIElement,
        pub(in super::super) dark: bool,
        pub(in super::super) ground: [f64; 3],
        pub(in super::super) text: [f64; 3],
    }

    impl Shot {
        pub(in super::super) fn take(core: &CoreState) -> Result<Shot, String> {
            let fail = |e: windows_core::Error| format!("the window could not be placed: {}", e.message());
            let root = core.window.Content().map_err(fail)?;
            let fe: FrameworkElement = root.cast().map_err(fail)?;
            let at = element_placement(core, &fe).map_err(fail)?;
            const PW_RENDERFULLCONTENT: u32 = 2;
            let grab = capture(at.win_w, at.win_h, |mem| {
                if unsafe { PrintWindow(at.hwnd, mem, PW_RENDERFULLCONTENT) } == 0 {
                    return Err(format!("PrintWindow of the {}x{} window answered 0", at.win_w, at.win_h));
                }
                Ok(())
            })?;
            let dark = dark_of(core, None);
            let over = |c: [f64; 4], under: [f64; 3]| {
                let a = c[3] / 255.0;
                [0, 1, 2].map(|k| (c[k] * a + under[k] * (1.0 - a)) / 255.0)
            };
            let g = resolve("ApplicationPageBackgroundThemeBrush", dark).map_err(fail)?;
            let ground = [g[0] / 255.0, g[1] / 255.0, g[2] / 255.0];
            let t = resolve("TextFillColorPrimaryBrush", dark).map_err(fail)?;
            let text = over(t, [g[0], g[1], g[2]]);
            Ok(Shot { grab, root_x: at.ox, root_y: at.oy, scale: at.scale, root, dark, ground, text })
        }

        /// An element's box in device-independent units relative to the
        /// window root.
        pub(in super::super) fn frame(&self, element: &UIElement) -> Option<(f64, f64, f64, f64)> {
            let fe: FrameworkElement = element.cast().ok()?;
            let origin = element
                .TransformToVisual(&self.root)
                .ok()?
                .TransformPoint(bindings::Windows::Foundation::Point { X: 0.0, Y: 0.0 })
                .ok()?;
            Some((f64::from(origin.X), f64::from(origin.Y), fe.ActualWidth().ok()?, fe.ActualHeight().ok()?))
        }

        /// What `element` draws of its box, relative to the window root: its
        /// own layout slot crops an element larger than the slot (a wide
        /// picture's circle; docs/traps.md, an element's own maxima crop an
        /// overflowing fill).
        pub(in super::super) fn drawn(&self, element: &UIElement) -> Option<(f64, f64, f64, f64)> {
            let (x, y, w, h) = self.frame(element)?;
            let fe: FrameworkElement = element.cast().ok()?;
            let root: FrameworkElement = self.root.cast().ok()?;
            let rtl = root.FlowDirection().ok()? == bindings::Microsoft::UI::Xaml::FlowDirection::RightToLeft;
            let [l, t, r, b] = crate::winui::slot_cut(&fe, rtl).ok()?;
            if r <= l || b <= t {
                return Some((x, y, w, h));
            }
            Some((x + l, y + t, r - l, b - t))
        }

        /// Why the probes over `probed` (the root's units) may not be read:
        /// what every ScrollViewer and ancestor slot above `element` and the
        /// root leave of it does not hold all of it (crate::harness::unseen_probe).
        pub(in super::super) fn unseen(&self, element: &UIElement, probed: [f64; 4]) -> windows_core::Result<Option<String>> {
            let fe: FrameworkElement = element.cast()?;
            let root: FrameworkElement = self.root.cast()?;
            let rtl = root.FlowDirection()? == bindings::Microsoft::UI::Xaml::FlowDirection::RightToLeft;
            let [x, y, w, h] = probed;
            let s = crate::winui::ancestors_cut(&fe, &root, rtl, [x, y, x + w, y + h])?;
            let s = [s[0].max(0.0), s[1].max(0.0), s[2].min(root.ActualWidth()?), s[3].min(root.ActualHeight()?)];
            let visible = [s[0], s[1], (s[2] - s[0]).max(0.0), (s[3] - s[1]).max(0.0)];
            Ok(crate::harness::unseen_probe(probed, Some(visible)))
        }

        /// The pixel at a point of the root, 0-1 RGB.
        pub(in super::super) fn at(&self, x: f64, y: f64) -> Option<[f64; 3]> {
            let px = self.root_x + (x * self.scale).floor() as i32;
            let py = self.root_y + (y * self.scale).floor() as i32;
            if px < 0 || py < 0 || px >= self.grab.width || py >= self.grab.height {
                return None;
            }
            let i = (py as usize * self.grab.width as usize + px as usize) * 4;
            let p = &self.grab.pixels[i..i + 4];
            Some([p[2], p[1], p[0]].map(|v| f64::from(v) / 255.0))
        }

        pub(in super::super) fn step(&self) -> f64 {
            1.0 / self.scale
        }
    }

    pub(in super::super) const TOLERANCE: f64 = 0.06;

    pub(in super::super) fn gap(a: [f64; 3], b: [f64; 3]) -> f64 {
        (0..3).map(|k| (a[k] - b[k]).abs()).fold(0.0, f64::max)
    }

    pub(in super::super) fn lum(c: [f64; 3]) -> f64 {
        let l = c.map(|v| if v <= 0.04045 { v / 12.92 } else { ((v + 0.055) / 1.055).powf(2.4) });
        0.2126 * l[0] + 0.7152 * l[1] + 0.0722 * l[2]
    }

    pub(in super::super) fn contrast(a: [f64; 3], b: [f64; 3]) -> f64 {
        let (x, y) = (lum(a), lum(b));
        (x.max(y) + 0.05) / (x.min(y) + 0.05)
    }

    pub(in super::super) fn hex(c: [f64; 3]) -> String {
        format!("{:02X}{:02X}{:02X}", (c[0] * 255.0).round() as u8, (c[1] * 255.0).round() as u8, (c[2] * 255.0).round() as u8)
    }

    /// The image ground's picture at a point of its box, covering the box
    /// centred as UniformToFill draws it, out of the core's own decoder.
    pub(in super::super) fn picture_at(id: WidgetId, x: f64, y: f64, w: f64, h: f64) -> Option<[f64; 3]> {
        let bytes = SKIN.with_borrow(|s| {
            let g = s.grounds.get(&id.0)?;
            (g.kind == crate::wire::GROUND_IMAGE).then(|| g.bytes.clone()).flatten()
        })?;
        let decoded = SKIN.with_borrow(|s| s.decoded.get(&id.0).cloned());
        let decoded = match decoded {
            Some(d) => d,
            None => {
                let d = crate::reader::decode_straight(&bytes).map(|(w, h, px)| (w, h, Arc::new(px)));
                SKIN.with_borrow_mut(|s| s.decoded.insert(id.0, d.clone()));
                d
            }
        }?;
        let (pw, ph, px) = decoded;
        let (fw, fh) = (f64::from(pw), f64::from(ph));
        let scale = (w / fw).max(h / fh);
        let (ox, oy) = ((fw * scale - w) / 2.0, (fh * scale - h) / 2.0);
        let (ix, iy) = (((x + ox) / scale) as i64, ((y + oy) / scale) as i64);
        if ix < 0 || iy < 0 || ix >= i64::from(pw) || iy >= i64::from(ph) {
            return None;
        }
        let i = (iy as usize * pw as usize + ix as usize) * 4;
        Some([px[i], px[i + 1], px[i + 2]].map(|v| f64::from(v) / 255.0))
    }

    /// The nearest container above `id` with an image ground.
    pub(in super::super) fn pictured_ancestor(core: &CoreState, id: WidgetId) -> Option<WidgetId> {
        let mut at = core.child_order.parent_of(id);
        while let Some(p) = at {
            if SKIN.with_borrow(|s| s.grounds.get(&p.0).is_some_and(|g| g.kind == crate::wire::GROUND_IMAGE)) {
                return Some(p);
            }
            at = core.child_order.parent_of(p);
        }
        None
    }

    /// expect_ground (§5.1), the SwiftUI arm's probe geometry: 4 units in
    /// from the right edge, 4 down from the top, 4 up from the bottom and the
    /// middle.
    /// expect_ground_color's read (docs/media-player-plan.md M16 (35)): the ground's
    /// own top probe as 0xRRGGBB and whether the window reads dark.
    pub(in super::super) fn ground_top(core: &CoreState, t: crate::harness::Target) -> windows_core::Result<Result<(u32, bool), String>> {
        let Some(element) = target_element(core, t)? else { return Ok(Err("<no such target>".into())) };
        let shot = match Shot::take(core) {
            Ok(shot) => shot,
            Err(why) => return Ok(Err(format!("<no window pixels: {why}>"))),
        };
        let Some((fx, fy, fw, fh)) = shot.drawn(&element) else { return Ok(Err("<no laid-out frame>".into())) };
        if fw <= 8.0 || fh <= 16.0 {
            return Ok(Err(format!("<no laid-out frame: {fw}x{fh}>")));
        }
        if let Some(why) = shot.unseen(&element, [fx, fy, fw, fh])? {
            return Ok(Err(why));
        }
        let Some(top) = shot.at(fx + fw - 4.0, fy + 4.0) else {
            return Ok(Err(format!("<the probe falls outside the window: {fx},{fy} {fw}x{fh}>")));
        };
        let b = top.map(|v| (v * 255.0).round().clamp(0.0, 255.0) as u32);
        Ok(Ok(((b[0] << 16) | (b[1] << 8) | b[2], shot.dark)))
    }

    pub(in super::super) fn ground(core: &CoreState, t: crate::harness::Target) -> windows_core::Result<String> {
        let Some(id) = target_widget_id(core, t).map(WidgetId) else { return Ok("<no such target>".into()) };
        let Some(element) = target_element(core, t)? else { return Ok("<no such target>".into()) };
        let shot = match Shot::take(core) {
            Ok(shot) => shot,
            Err(why) => return Ok(format!("<no window pixels: {why}>")),
        };
        let Some((fx, fy, fw, fh)) = shot.drawn(&element) else { return Ok("<no laid-out frame>".into()) };
        if fw <= 8.0 || fh <= 16.0 {
            return Ok(format!("<no laid-out frame: {fw}x{fh}>"));
        }
        if let Some(why) = shot.unseen(&element, [fx, fy, fw, fh])? {
            return Ok(why);
        }
        let x = fx + fw - 4.0;
        let (Some(top), Some(bottom), Some(mid)) = (shot.at(x, fy + 4.0), shot.at(x, fy + fh - 4.0), shot.at(x, fy + fh / 2.0))
        else {
            return Ok(format!("<the probes fall outside the window: {fx},{fy} {fw}x{fh}>"));
        };
        let seen = format!(
            "top {}, middle {}, bottom {}, ground {}",
            hex(top), hex(mid), hex(bottom), hex(shot.ground)
        );
        if gap(top, shot.ground) <= TOLERANCE {
            return Ok(format!("none ({seen})"));
        }
        if let Some(art) = picture_at(id, fw - 4.0, 4.0, fw, fh) {
            if gap(art, top) <= TOLERANCE * 2.0 {
                return Ok(format!("image ({seen}, the picture there {})", hex(art)));
            }
        }
        let Some(packed) = SKIN.with_borrow(|s| s.grounds.get(&id.0).and_then(|g| g.packed)) else {
            return Ok(format!("unmatched ({seen}, no gradient colour was sent)"));
        };
        let stop = if shot.dark { packed & 0xFF_FFFF } else { (packed >> 24) & 0xFF_FFFF };
        let want = [(stop >> 16) & 0xFF, (stop >> 8) & 0xFF, stop & 0xFF].map(|v| v as f64 / 255.0);
        let ratio = contrast(mid, shot.text);
        let detail = format!("{seen}, the clamped stop {}, text {ratio:.1}:1 at the middle", hex(want));
        if gap(top, want) <= TOLERANCE && gap(bottom, shot.ground) <= TOLERANCE && ratio >= 4.5 {
            return Ok(format!("gradient ({detail})"));
        }
        Ok(format!("unmatched ({detail})"))
    }

    /// expect_shape (§5.2): the probes at (1,1), (6,6) and the centre of the
    /// image's box against what it sits on, read 4 units left of it.
    pub(in super::super) fn shape(core: &CoreState, t: crate::harness::Target) -> windows_core::Result<String> {
        let Some(element) = target_element(core, t)? else { return Ok("<no such target>".into()) };
        let shot = match Shot::take(core) {
            Ok(shot) => shot,
            Err(why) => return Ok(format!("<no window pixels: {why}>")),
        };
        let Some((fx, fy, fw, fh)) = shot.drawn(&element) else { return Ok("<no laid-out frame>".into()) };
        if fw <= 12.0 || fh <= 12.0 {
            return Ok(format!("<no laid-out frame: {fw}x{fh}>"));
        }
        if let Some(why) = shot.unseen(&element, [fx, fy, fw, fh])? {
            return Ok(why);
        }
        // Each probe against the ground at its own height: a gradient ground
        // changes down the image (docs/traps.md).
        let (Some(under1), Some(under6), Some(under)) =
            (shot.at(fx - 4.0, fy + 1.0), shot.at(fx - 4.0, fy + 6.0), shot.at(fx - 4.0, fy + fh / 2.0))
        else {
            return Ok(format!("<nothing left of {fx},{fy}>"));
        };
        let art = |c: [f64; 3], ground: [f64; 3]| gap(c, ground) > 0.02;
        let (Some(c1), Some(c6), Some(centre)) =
            (shot.at(fx + 1.0, fy + 1.0), shot.at(fx + 6.0, fy + 6.0), shot.at(fx + fw / 2.0, fy + fh / 2.0))
        else {
            return Ok(format!("<the probes fall outside the window: {fx},{fy} {fw}x{fh}>"));
        };
        let seen = format!(
            "(1,1) {} over {}, (6,6) {} over {}, centre {} over {}, drawn at {fx},{fy} {fw}x{fh}",
            hex(c1), hex(under1), hex(c6), hex(under6), hex(centre), hex(under)
        );
        Ok(match (art(c1, under1), art(c6, under6), art(centre, under)) {
            (true, true, true) => format!("rect ({seen})"),
            (false, true, true) => format!("rounded ({seen})"),
            (false, false, true) => format!("circle ({seen})"),
            _ => format!("unmatched ({seen})"),
        })
    }

    /// expect_tint (Y7): the label's most distant ink from the ground, nearest
    /// of the appearance's text and the four standalone colours.
    pub(in super::super) fn tint(core: &CoreState, t: crate::harness::Target) -> windows_core::Result<String> {
        let Some(element) = target_element(core, t)? else { return Ok("<no such target>".into()) };
        let shot = match Shot::take(core) {
            Ok(shot) => shot,
            Err(why) => return Ok(format!("<no window pixels: {why}>")),
        };
        let Some((fx, fy, fw, fh)) = shot.drawn(&element) else { return Ok("<no laid-out frame>".into()) };
        if fw <= 2.0 || fh <= 2.0 {
            return Ok(format!("<no laid-out frame: {fw}x{fh}>"));
        }
        if let Some(why) = shot.unseen(&element, [fx, fy, fw, fh])? {
            return Ok(why);
        }
        let mut ink: Option<[f64; 3]> = None;
        let mut best = -1.0;
        let step = shot.step();
        let mut y = fy;
        while y < fy + fh {
            let mut x = fx;
            while x < fx + fw {
                if let Some(c) = shot.at(x, y) {
                    let d: f64 = (0..3).map(|k| (c[k] - shot.ground[k]).abs()).sum();
                    if d > best {
                        best = d;
                        ink = Some(c);
                    }
                }
                x += step;
            }
            y += step;
        }
        let Some(ink) = ink else { return Ok(format!("<no pixels in {fx},{fy} {fw}x{fh}>")) };
        let tone = |key: &str| -> windows_core::Result<[f64; 3]> {
            let c = resolve(key, shot.dark)?;
            let a = c[3] / 255.0;
            Ok([0, 1, 2].map(|k| c[k] / 255.0 * a + shot.ground[k] * (1.0 - a)))
        };
        let mut candidates = vec![("none", shot.text)];
        for (name, tint) in [
            ("accent", crate::wire::TINT_ACCENT),
            ("success", crate::wire::TINT_SUCCESS),
            ("warning", crate::wire::TINT_WARNING),
            ("critical", crate::wire::TINT_CRITICAL),
        ] {
            candidates.push((name, tone(standalone_key(i64::from(tint)).expect("a standalone tint"))?));
        }
        let distance = |c: &[f64; 3]| (0..3).map(|k| (c[k] - ink[k]).powi(2)).sum::<f64>();
        candidates.sort_by(|a, b| distance(&a.1).total_cmp(&distance(&b.1)));
        Ok(format!(
            "{} (ink {}; {})",
            candidates[0].0,
            hex(ink),
            candidates.iter().take(3).map(|(n, c)| format!("{n} {}", hex(*c))).collect::<Vec<_>>().join(", ")
        ))
    }

    /// expect_selected (Y4), off the item's own SelectionItem peer.
    pub(in super::super) fn selected(core: &CoreState, t: crate::harness::Target) -> windows_core::Result<String> {
        use bindings::Microsoft::UI::Xaml::Automation::Peers::FrameworkElementAutomationPeer;
        use bindings::Microsoft::UI::Xaml::Automation::Provider::ISelectionItemProvider;
        let Some(element) = target_element(core, t)? else { return Ok("<no such target>".into()) };
        let Some(host) = host_of(&element) else {
            return Ok("<not activatable: no SelectionItem in the tree>".into());
        };
        let fe: FrameworkElement = host.cast()?;
        let peer = FrameworkElementAutomationPeer::CreatePeerForElement(&fe)?;
        let Ok(item) = peer.cast::<ISelectionItemProvider>() else {
            return Ok(format!("<the {} peer carries no SelectionItem>", peer.GetClassName()?));
        };
        Ok(if item.IsSelected()? { "on" } else { "off" }.to_owned())
    }

    /// expect_dock_player (M17): the player the primary window's dock holds.
    pub(in super::super) fn dock_player(core: &CoreState) -> windows_core::Result<String> {
        let Some((dock, player)) = SKIN.with_borrow(|s| {
            let dock = *s.dock_of.get(&0)?;
            Some((dock, s.docks.get(&dock)?.player))
        }) else {
            return Ok("none (the primary window has no dock)".to_owned());
        };
        Ok(match player {
            None => format!("none (dock {dock} names no player)"),
            Some(p) if super::super::media::is_live(core, p) => format!("bound (dock {dock} shows player {p})"),
            Some(p) => format!("released (dock {dock} names player {p}, which this backend no longer holds)"),
        })
    }

    /// expect_dock (Y8): the dock's host laid out at the window ground's foot
    /// across its width, with the window's content ending above it.
    pub(in super::super) fn dock(core: &CoreState) -> windows_core::Result<String> {
        let Some((host, root)) = SKIN.with_borrow(|s| {
            let d = s.docks.get(s.dock_of.get(&0)?)?;
            Some((d.host.clone(), d.root))
        }) else {
            return Ok("hidden (no dock is attached)".into());
        };
        if root.is_none() {
            return Ok("hidden (no dock is mounted)".into());
        }
        let fe: FrameworkElement = host.cast()?;
        if fe.Visibility()? != Visibility::Visible || fe.ActualHeight()? <= 1.0 {
            return Ok(format!("hidden (the dock's host is {:?} at {}dip)", fe.Visibility()?, fe.ActualHeight()?));
        }
        let ground = window_ground(&winui_window(core, 0)?)?;
        let ground_el: UIElement = ground.cast()?;
        let ground_fe: FrameworkElement = ground.cast()?;
        let (gw, gh) = (ground_fe.ActualWidth()?, ground_fe.ActualHeight()?);
        let place = |e: &UIElement| -> windows_core::Result<(f64, f64, f64, f64)> {
            let f: FrameworkElement = e.cast()?;
            let o = e.TransformToVisual(&ground_el)?.TransformPoint(bindings::Windows::Foundation::Point { X: 0.0, Y: 0.0 })?;
            Ok((f64::from(o.X), f64::from(o.Y), f.ActualWidth()?, f.ActualHeight()?))
        };
        let (x, y, w, h) = place(&host.cast()?)?;
        let children = ground.Children()?;
        let mut panes = Vec::new();
        for i in 0..children.Size()? {
            let child = children.GetAt(i)?;
            if !is_dock_host(&child) {
                panes.push(place(&child)?);
            }
        }
        let spans = x <= 2.0 && x + w >= gw - 2.0;
        let at_foot = (y + h - gh).abs() <= 2.0;
        let above = panes.iter().all(|p| p.1 + p.3 <= y + 1.0);
        let detail = format!("dock {x},{y} {w}x{h}, window {gw}x{gh}, content {panes:?}");
        if let Some(fault) = dock_content_fault(core, &ground_el, y)? {
            return Ok(format!("misplaced ({fault}; {detail})"));
        }
        Ok(if spans && at_foot && above { format!("shown ({detail})") } else { format!("misplaced ({detail})") })
    }

    /// expect_dock's content half (docs/styling-pass-plan.md Y8, §5.4): every
    /// shown widget of the window's own root laid out, on screen and wholly
    /// above the dock's top, so a dock drawn over the content or in its place
    /// reads misplaced.
    fn dock_content_fault(core: &CoreState, ground: &UIElement, dock_top: f64) -> windows_core::Result<Option<String>> {
        let Some(root) = core.mounted_roots.get(&0).copied() else {
            return Ok(None);
        };
        let panel_of = |g: &Grid| {
            core.widgets
                .iter()
                .find(|(_, w)| matches!(w, NativeWidget::Column(p) | NativeWidget::Row(p) if p == g))
                .map(|(id, _)| *id)
        };
        let mut leaves: Vec<WidgetId> = core
            .widgets
            .iter()
            .filter(|(_, w)| !matches!(w, NativeWidget::Column(_) | NativeWidget::Row(_)))
            .map(|(id, _)| *id)
            .collect();
        leaves.sort_by_key(|id| id.0);
        'leaf: for id in leaves {
            let mut chain = vec![id];
            let mut at = id;
            while at != root {
                let Some(up) = core.parents.get(&at).and_then(panel_of) else {
                    continue 'leaf;
                };
                chain.push(up);
                at = up;
            }
            for link in &chain {
                let fe: FrameworkElement = core.widgets[link].element()?.cast()?;
                if fe.Visibility()? != Visibility::Visible {
                    continue 'leaf;
                }
            }
            let e = core.widgets[&id].element()?;
            let fe: FrameworkElement = e.cast()?;
            let Ok(o) = e
                .TransformToVisual(ground)
                .and_then(|t| t.TransformPoint(bindings::Windows::Foundation::Point { X: 0.0, Y: 0.0 }))
            else {
                return Ok(Some(format!("content widget {} was never laid out", id.0)));
            };
            let (top, w, h) = (f64::from(o.Y), fe.ActualWidth()?, fe.ActualHeight()?);
            if w < 1.0 || h < 1.0 {
                return Ok(Some(format!("content widget {} has nothing on screen at {},{} {w}x{h}", id.0, o.X, o.Y)));
            }
            if top + h > dock_top + 1.0 {
                return Ok(Some(format!(
                    "content widget {} at {},{} {w}x{h} does not end above the dock's top {dock_top}",
                    id.0, o.X, o.Y
                )));
            }
        }
        Ok(None)
    }
}
