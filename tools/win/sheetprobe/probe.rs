//! THROWAWAY sheet probe for the WinUI backend — docs/sheet-plan.md U1.
//! A MODULE OF THE BACKEND, like tools/win/undoprobe: it asks WinUI, on
//! kaya's own UI thread over kaya's own root, (1) whether a second
//! ContentDialog can be shown while one is up, (2) whether a Popup with a
//! full-root backdrop and a ContentDialog can be up at once, both ways
//! round. Wiring is temporary (build.sh applies and restores it).

#![allow(dead_code)]

use super::bindings::Microsoft::UI::Xaml::Controls::Primitives::Popup;
use super::bindings::Microsoft::UI::Xaml::Controls::{ContentDialog, Grid, TextBlock};
use super::bindings::Microsoft::UI::Xaml::FrameworkElement;
use super::bindings::Microsoft::UI::Xaml::Media::SolidColorBrush;
use super::bindings::Windows::Foundation::PropertyValue;
use super::bindings::Windows::UI::Color;
use super::{CORE, CoreState, DISPATCHER, DispatcherQueueHandler};
use std::cell::RefCell;
use std::io::Write as _;
use std::time::{Duration, Instant};
use windows_core::{IInspectable, Interface, HSTRING};

static START: std::sync::OnceLock<Instant> = std::sync::OnceLock::new();

thread_local! {
    // Everything presented stays alive on the UI thread for the run.
    static KEEP: RefCell<Vec<IInspectable>> = const { RefCell::new(Vec::new()) };
    static DIALOGS: RefCell<Vec<ContentDialog>> = const { RefCell::new(Vec::new()) };
    static POPUPS: RefCell<Vec<Popup>> = const { RefCell::new(Vec::new()) };
}

fn say(s: impl AsRef<str>) {
    let t = START.get_or_init(Instant::now).elapsed().as_millis();
    println!("PROBE {t:>6}ms {}", s.as_ref());
    let _ = std::io::stdout().flush();
}

fn nap(ms: u64) {
    std::thread::sleep(Duration::from_millis(ms));
}

fn on_ui<T: Send + 'static>(
    f: impl FnOnce(&mut CoreState) -> windows_core::Result<T> + Send + 'static,
) -> Result<T, String> {
    let (tx, rx) = std::sync::mpsc::channel();
    let Some(dispatcher) = DISPATCHER.get() else {
        return Err("no dispatcher yet".to_owned());
    };
    let cell = std::sync::Mutex::new(Some((f, tx)));
    let handler = DispatcherQueueHandler::new(move || {
        if let Some((f, tx)) = cell.lock().unwrap().take() {
            CORE.with_borrow_mut(|core| match core.as_mut() {
                Some(core) => {
                    let _ = tx.send(f(core).map_err(|e| format!("{} ({:?})", e.message(), e.code())));
                }
                None => {
                    let _ = tx.send(Err("core not built yet".to_owned()));
                }
            });
        }
        Ok(())
    });
    dispatcher.0.TryEnqueue(&handler).map_err(|e| e.message().to_string())?;
    match rx.recv_timeout(Duration::from_secs(20)) {
        Ok(v) => v,
        Err(_) => Err("UI thread did not answer in 20s".to_owned()),
    }
}

fn on_ui_raw(f: impl FnOnce() + Send + 'static) {
    let Some(dispatcher) = DISPATCHER.get() else { return };
    let cell = std::sync::Mutex::new(Some(f));
    let handler = DispatcherQueueHandler::new(move || {
        if let Some(f) = cell.lock().unwrap().take() {
            f();
        }
        Ok(())
    });
    let _ = dispatcher.0.TryEnqueue(&handler);
}

fn root_of(core: &CoreState) -> windows_core::Result<FrameworkElement> {
    let host = super::winui_window(core, 0)?;
    let content = host.Content()?;
    Interface::cast(&content)
}

fn text(s: &str) -> windows_core::Result<IInspectable> {
    PropertyValue::CreateString(&HSTRING::from(s))
}

fn dialog(title: &str, body: &str, root: &FrameworkElement) -> windows_core::Result<ContentDialog> {
    let d = ContentDialog::new()?;
    d.SetTitle(&text(title)?)?;
    let tb = TextBlock::new()?;
    tb.SetText(&HSTRING::from(body))?;
    d.SetContent(&tb)?;
    d.SetCloseButtonText(&HSTRING::from("Cancel"))?;
    d.SetXamlRoot(&root.XamlRoot()?)?;
    Ok(d)
}

/// ShowAsync's own answer: accepted (an operation), or the HRESULT WinUI
/// refuses with — the sentence the plan's R4 rests on.
fn show(label: &str, d: &ContentDialog) -> String {
    match d.ShowAsync() {
        Ok(op) => {
            KEEP.with_borrow_mut(|k| k.push(op.cast().expect("op is IInspectable")));
            format!("{label}: ShowAsync ACCEPTED")
        }
        Err(e) => format!("{label}: ShowAsync REFUSED — {} ({:?})", e.message(), e.code()),
    }
}

fn popup_over_root(core: &CoreState, label: &str) -> windows_core::Result<String> {
    let root = root_of(core)?;
    let xr = root.XamlRoot()?;
    let size = xr.Size()?;
    let grid = Grid::new()?;
    grid.SetWidth(size.Width as f64)?;
    grid.SetHeight(size.Height as f64)?;
    let smoke = SolidColorBrush::CreateInstanceWithColor(Color { A: 140, R: 0, G: 0, B: 0 })?;
    grid.SetBackground(&smoke)?;
    let tb = TextBlock::new()?;
    tb.SetText(&HSTRING::from(label))?;
    grid.Children()?.Append(&tb)?;
    let popup = Popup::new()?;
    popup.SetChild(&grid)?;
    popup.SetXamlRoot(&xr)?;
    popup.SetIsLightDismissEnabled(false)?;
    popup.SetShouldConstrainToRootBounds(true)?;
    popup.SetIsOpen(true)?;
    let open = popup.IsOpen()?;
    POPUPS.with_borrow_mut(|p| p.push(popup));
    Ok(format!("{label}: popup open={open} over a {}x{} root", size.Width, size.Height))
}

pub(super) fn maybe_spawn() {
    if std::env::var("KAYA_SHEET_PROBE").is_err() {
        return;
    }
    START.get_or_init(Instant::now);
    std::thread::spawn(run);
}

fn run() {
    say("sheet probe armed (U1: a modal over a modal on WinUI)");
    let mut ready = false;
    for _ in 0..100 {
        if on_ui(|core| root_of(core)?.XamlRoot().map(|_| ())).is_ok() {
            ready = true;
            break;
        }
        nap(100);
    }
    if !ready {
        say("the root never got a XamlRoot in 10s — nothing to measure");
        println!("PROBEDONE");
        on_ui_raw(|| super::request_exit(0));
        return;
    }
    nap(1500);

    // (1) ContentDialog over ContentDialog.
    let r = on_ui(|core| {
        let root = root_of(core)?;
        let a = dialog("sheet A", "a form, as a ContentDialog", &root)?;
        let s = show("A", &a);
        DIALOGS.with_borrow_mut(|d| d.push(a));
        Ok(s)
    });
    say(format!("{r:?}"));
    nap(800);
    let r = on_ui(|core| {
        let root = root_of(core)?;
        let b = dialog("alert over A", "discard?", &root)?;
        let s = show("B over A", &b);
        DIALOGS.with_borrow_mut(|d| d.push(b));
        Ok(s)
    });
    say(format!("{r:?}"));
    nap(800);
    let r = on_ui(|_core| {
        DIALOGS.with_borrow(|d| {
            for (i, x) in d.iter().enumerate() {
                let _ = x.Hide();
                say(format!("hid dialog #{i}"));
            }
        });
        Ok(())
    });
    say(format!("hide: {r:?}"));
    nap(800);

    // (2) A Popup with a backdrop, then a ContentDialog over it.
    let r = on_ui(|core| popup_over_root(core, "sheet as popup"));
    say(format!("{r:?}"));
    nap(800);
    let r = on_ui(|core| {
        let root = root_of(core)?;
        let c = dialog("alert over popup", "discard?", &root)?;
        let s = show("C over popup", &c);
        DIALOGS.with_borrow_mut(|d| d.push(c));
        Ok(s)
    });
    say(format!("{r:?}"));
    nap(800);
    // (3) And a second popup over the first (the chain), with the dialog up.
    let r = on_ui(|core| popup_over_root(core, "child sheet as popup"));
    say(format!("{r:?}"));
    nap(800);
    let r = on_ui(|_core| {
        let opens: Vec<bool> = POPUPS.with_borrow(|p| p.iter().map(|x| x.IsOpen().unwrap_or(false)).collect());
        DIALOGS.with_borrow(|d| {
            if let Some(c) = d.last() {
                let _ = c.Hide();
            }
        });
        Ok(format!("popups open={opens:?}; hid the dialog over them"))
    });
    say(format!("{r:?}"));
    nap(600);
    let r = on_ui(|_core| {
        POPUPS.with_borrow(|p| {
            for x in p.iter() {
                let _ = x.SetIsOpen(false);
            }
        });
        Ok("popups closed")
    });
    say(format!("{r:?}"));
    println!("PROBEDONE");
    let _ = std::io::stdout().flush();
    nap(300);
    on_ui_raw(|| super::request_exit(0));
}
