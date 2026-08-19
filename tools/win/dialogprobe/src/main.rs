// DialogProbe — what the Shell's file dialog is MADE OF, measured on
// the VM the windows lane actually runs on: whether the file list and
// the address bar are classic controls or DirectUI, whether the classic
// control ids answer, and which of those reads survive a PROCESS
// BOUNDARY (the guest must stop loading uiautomationcore — see
// docs/deferred.md and docs/traps.md).
//
// It opens the dialog the way crates/kaya/src/winui/mod.rs does, on its
// own STA thread with CLSCTX_INPROC_SERVER, rather than attaching to a
// running app: it must measure the arrangement the harness would
// actually have, not a similar one. The window calls are hand-declared
// with plain types for the same reason.
//
// Not a lane; nothing builds it but build.sh beside it. Output goes to
// stdout under "PROBE", and the last line is PROBEDONE so the runner
// knows it finished rather than hung.

use windows::core::PCWSTR;
use windows::Win32::System::Com::{
    CoCreateInstance, CoInitializeEx, CoUninitialize, CLSCTX_INPROC_SERVER,
    COINIT_APARTMENTTHREADED,
};
use windows::Win32::UI::Shell::{
    FileOpenDialog, IFileOpenDialog, IShellItem, SHCreateItemFromParsingName, FOS_FORCEFILESYSTEM,
};

type EnumProc = unsafe extern "system" fn(isize, isize) -> i32;

#[link(name = "user32")]
extern "system" {
    fn EnumWindows(proc: Option<EnumProc>, param: isize) -> i32;
    fn EnumChildWindows(parent: isize, proc: Option<EnumProc>, param: isize) -> i32;
    fn GetClassNameW(hwnd: isize, buf: *mut u16, len: i32) -> i32;
    fn GetWindowTextW(hwnd: isize, buf: *mut u16, len: i32) -> i32;
    fn GetDlgCtrlID(hwnd: isize) -> i32;
    fn GetWindowRect(hwnd: isize, rect: *mut [i32; 4]) -> i32;
    fn IsWindowVisible(hwnd: isize) -> i32;
    fn SendMessageW(hwnd: isize, msg: u32, wparam: usize, lparam: isize) -> isize;
    fn GetWindowThreadProcessId(hwnd: isize, pid: *mut u32) -> u32;
}

const WM_SETTEXT: u32 = 0x000C;
const WM_GETTEXT: u32 = 0x000D;

const LVM_GETITEMCOUNT: u32 = 0x1004;
const LVM_GETITEMTEXTW: u32 = 0x1073;
const LVIF_TEXT: u32 = 0x0001;
const BM_CLICK: u32 = 0x00F5;

/// The layout LVM_GETITEMTEXTW expects. Only the first seven fields are
/// read for a text query, but the struct has to be the full size or the
/// control writes past what it was handed.
#[repr(C)]
#[derive(Default)]
struct LvItemW {
    mask: u32,
    i_item: i32,
    i_sub_item: i32,
    state: u32,
    state_mask: u32,
    psz_text: *mut u16,
    cch_text_max: i32,
    i_image: i32,
    l_param: isize,
    i_indent: i32,
    i_group_id: i32,
    cch_columns: u32,
    pu_columns: *mut u32,
    pi_col_fmt: *mut i32,
    i_group: i32,
}

fn say(line: &str) {
    use std::io::Write;
    println!("PROBE {line}");
    let _ = std::io::stdout().flush();
}

fn wide(s: &str) -> Vec<u16> {
    s.encode_utf16().chain(std::iter::once(0)).collect()
}

fn class_of(hwnd: isize) -> String {
    let mut buf = [0u16; 256];
    let n = unsafe { GetClassNameW(hwnd, buf.as_mut_ptr(), buf.len() as i32) };
    String::from_utf16_lossy(&buf[..n.max(0) as usize])
}

fn text_of(hwnd: isize) -> String {
    let mut buf = [0u16; 512];
    let n = unsafe { GetWindowTextW(hwnd, buf.as_mut_ptr(), buf.len() as i32) };
    String::from_utf16_lossy(&buf[..n.max(0) as usize])
}

/// Q1's real question, asked of one window: does it answer listview
/// messages, and does it hand back row text?
fn interrogate_listview(hwnd: isize, indent: &str) {
    let count = unsafe { SendMessageW(hwnd, LVM_GETITEMCOUNT, 0, 0) };
    say(&format!("{indent}  LVM_GETITEMCOUNT -> {count}"));
    if count <= 0 {
        return;
    }
    for row in 0..count.min(10) {
        let mut buf = [0u16; 260];
        let mut item = LvItemW {
            mask: LVIF_TEXT,
            i_item: row as i32,
            psz_text: buf.as_mut_ptr(),
            cch_text_max: buf.len() as i32,
            ..Default::default()
        };
        let got = unsafe {
            SendMessageW(
                hwnd,
                LVM_GETITEMTEXTW,
                row as usize,
                &mut item as *mut LvItemW as isize,
            )
        };
        let text = String::from_utf16_lossy(&buf[..got.max(0) as usize]);
        say(&format!("{indent}  row[{row}] chars={got} text={text:?}"));
    }
}

unsafe extern "system" fn dump_child(hwnd: isize, param: isize) -> i32 {
    let depth = param as usize;
    let indent = "  ".repeat(depth);
    let class = class_of(hwnd);
    let mut rect = [0i32; 4];
    unsafe { GetWindowRect(hwnd, &mut rect) };
    say(&format!(
        "{indent}{class} id={} visible={} text={:?} rect={},{} {}x{}",
        unsafe { GetDlgCtrlID(hwnd) },
        unsafe { IsWindowVisible(hwnd) } != 0,
        text_of(hwnd),
        rect[0],
        rect[1],
        rect[2] - rect[0],
        rect[3] - rect[1],
    ));
    // Asked of ANY window, not only ones named SysListView32: a control
    // that answers LVM_GETITEMCOUNT is a listview whatever it calls
    // itself, and a DirectUI host that does not answer is the answer to
    // Q1 either way.
    if class.contains("SysListView32") || class.contains("DirectUI") || class.contains("DUIView") {
        interrogate_listview(hwnd, &indent);
    }
    unsafe { EnumChildWindows(hwnd, Some(dump_child), depth as isize + 1) };
    1
}

unsafe extern "system" fn find_dialog(hwnd: isize, param: isize) -> i32 {
    if class_of(hwnd) == "#32770" && unsafe { IsWindowVisible(hwnd) } != 0 {
        unsafe { *(param as *mut isize) = hwnd };
        return 0;
    }
    1
}

unsafe extern "system" fn find_cancel(hwnd: isize, param: isize) -> i32 {
    if unsafe { GetDlgCtrlID(hwnd) } == 2 {
        unsafe { *(param as *mut isize) = hwnd };
        return 0;
    }
    1
}

/// Every window under `parent`, depth first. Used by the cross-process
/// half, which hunts for windows by control id rather than dumping.
fn descendants(parent: isize) -> Vec<isize> {
    unsafe extern "system" fn collect(hwnd: isize, param: isize) -> i32 {
        unsafe { (*(param as *mut Vec<isize>)).push(hwnd) };
        unsafe { EnumChildWindows(hwnd, Some(collect), param) };
        1
    }
    let mut out: Vec<isize> = Vec::new();
    unsafe { EnumChildWindows(parent, Some(collect), &mut out as *mut Vec<isize> as isize) };
    out
}

fn find_by(parent: isize, id: i32, class: &str) -> Option<isize> {
    descendants(parent)
        .into_iter()
        .find(|&h| unsafe { GetDlgCtrlID(h) } == id && class_of(h) == class)
}

/// The dialog belonging to some OTHER process — what a helper sees.
fn foreign_dialog(want: Option<u32>) -> Option<isize> {
    struct Hunt {
        want: Option<u32>,
        mine: u32,
        found: isize,
    }
    unsafe extern "system" fn visit(hwnd: isize, param: isize) -> i32 {
        let hunt = unsafe { &mut *(param as *mut Hunt) };
        if class_of(hwnd) != "#32770" || unsafe { IsWindowVisible(hwnd) } == 0 {
            return 1;
        }
        let mut pid = 0u32;
        unsafe { GetWindowThreadProcessId(hwnd, &mut pid) };
        let wanted = match hunt.want {
            Some(p) => pid == p,
            None => pid != hunt.mine,
        };
        if wanted {
            hunt.found = hwnd;
            return 0;
        }
        1
    }
    let mut hunt = Hunt {
        want,
        mine: std::process::id(),
        found: 0,
    };
    unsafe { EnumWindows(Some(visit), &mut hunt as *mut Hunt as isize) };
    (hunt.found != 0).then_some(hunt.found)
}

/// Q5: the row names, read over UIA from THIS process against a dialog
/// owned by another. The walk mirrors file_dialog_uia's — a true
/// condition and a descendant sweep, filtered in Rust — so what it
/// reports is what the backend's read would report.
fn rows_over_uia(pid: u32) -> Result<Vec<String>, String> {
    use windows::Win32::System::Com::COINIT_MULTITHREADED;
    use windows::Win32::UI::Accessibility::{
        CUIAutomation, IUIAutomation, IUIAutomationElement, TreeScope_Children,
        TreeScope_Descendants,
    };
    const LIST_ITEM: i32 = 50007; // UIA_ListItemControlTypeId

    unsafe {
        let _ = CoInitializeEx(None, COINIT_MULTITHREADED);
        struct Apartment;
        impl Drop for Apartment {
            fn drop(&mut self) {
                unsafe { CoUninitialize() };
            }
        }
        let _apartment = Apartment;

        let automation: IUIAutomation =
            CoCreateInstance(&CUIAutomation, None, CLSCTX_INPROC_SERVER)
                .map_err(|e| format!("CoCreateInstance(CUIAutomation): {e}"))?;
        let condition = automation
            .CreateTrueCondition()
            .map_err(|e| format!("CreateTrueCondition: {e}"))?;
        let root = automation
            .GetRootElement()
            .map_err(|e| format!("GetRootElement: {e}"))?;
        let windows = root
            .FindAll(TreeScope_Children, &condition)
            .map_err(|e| format!("FindAll(children): {e}"))?;

        let mut dialog: Option<IUIAutomationElement> = None;
        for i in 0..windows.Length().unwrap_or(0) {
            let Ok(element) = windows.GetElement(i) else {
                continue;
            };
            let class = element
                .CurrentClassName()
                .map(|c| c.to_string())
                .unwrap_or_default();
            // BY PID AND NOT ONLY BY CLASS: in-process there was exactly
            // one candidate, and a helper serving concurrent legs will
            // see one per guest.
            if class == "#32770" && element.CurrentProcessId().unwrap_or(0) as u32 == pid {
                dialog = Some(element);
                break;
            }
        }
        let dialog = dialog.ok_or_else(|| format!("no #32770 owned by pid {pid} in the UIA tree"))?;

        let mut names = Vec::new();
        let all = dialog
            .FindAll(TreeScope_Descendants, &condition)
            .map_err(|e| format!("FindAll(descendants): {e}"))?;
        for i in 0..all.Length().unwrap_or(0) {
            let Ok(element) = all.GetElement(i) else {
                continue;
            };
            if element.CurrentControlType().map(|t| t.0).unwrap_or(0) == LIST_ITEM {
                names.push(
                    element
                        .CurrentName()
                        .map(|n| n.to_string())
                        .unwrap_or_default(),
                );
            }
        }
        Ok(names)
    }
}

/// `attach [pid]` — every question asked from outside the owning
/// process.
fn attach(want: Option<u32>) {
    let mut dialog = 0isize;
    for _ in 0..60 {
        if let Some(h) = foreign_dialog(want) {
            dialog = h;
            break;
        }
        std::thread::sleep(std::time::Duration::from_millis(250));
    }
    if dialog == 0 {
        say("no foreign #32770 came up in 15s");
        say("PROBEDONE");
        return;
    }
    let mut pid = 0u32;
    unsafe { GetWindowThreadProcessId(dialog, &mut pid) };
    say(&format!(
        "attached to #32770 of pid {pid} (this probe is {})",
        std::process::id()
    ));

    // Q4: the address bar, cross-process.
    match find_by(dialog, 1001, "ToolbarWindow32") {
        Some(bar) => say(&format!("Q4 address toolbar text={:?}", text_of(bar))),
        None => say("Q4 NO ToolbarWindow32 with id 1001"),
    }

    // Q5: the rows, over UIA.
    match rows_over_uia(pid) {
        Ok(names) => say(&format!("Q5 UIA list items ({}) {names:?}", names.len())),
        Err(why) => say(&format!("Q5 UIA READ FAILED: {why}")),
    }

    // Q6: the file-name box, cross-process. Written and then read back,
    // because a WM_SETTEXT that silently does nothing looks exactly like
    // one that worked.
    match find_by(dialog, 1148, "Edit") {
        Some(edit) => {
            let wanted = wide("picked.txt");
            unsafe { SendMessageW(edit, WM_SETTEXT, 0, wanted.as_ptr() as isize) };
            let mut buf = [0u16; 260];
            let n = unsafe {
                SendMessageW(edit, WM_GETTEXT, buf.len(), buf.as_mut_ptr() as isize)
            };
            say(&format!(
                "Q6 file-name Edit reads back {:?} after WM_SETTEXT",
                String::from_utf16_lossy(&buf[..n.max(0) as usize])
            ));
        }
        None => say("Q6 NO Edit with id 1148"),
    }

    // Q7: dismissal from outside.
    match find_by(dialog, 2, "Button") {
        Some(cancel) => {
            unsafe { SendMessageW(cancel, BM_CLICK, 0, 0) };
            let mut gone = false;
            for _ in 0..20 {
                std::thread::sleep(std::time::Duration::from_millis(250));
                if foreign_dialog(Some(pid)).is_none() {
                    gone = true;
                    break;
                }
            }
            say(&format!("Q7 BM_CLICK on IDCANCEL dismissed it: {gone}"));
        }
        None => say("Q7 NO Button with id 2"),
    }
    say("PROBEDONE");
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.get(1).map(String::as_str) == Some("attach") {
        attach(args.get(2).and_then(|p| p.parse().ok()));
        return;
    }
    let holding = args.get(1).map(String::as_str) == Some("hold");
    let dir = if holding {
        args.get(2)
            .cloned()
            .unwrap_or_else(|| r"C:\kaya\probe-dir".to_string())
    } else {
        args.get(1)
            .cloned()
            .unwrap_or_else(|| r"C:\kaya\probe-dir".to_string())
    };
    let _ = std::fs::create_dir_all(&dir);
    let _ = std::fs::write(format!("{dir}\\picked.txt"), "picked bytes");
    let _ = std::fs::write(format!("{dir}\\decoy.txt"), "decoy");
    say(&format!("==== begin, aimed at {dir}"));

    // The dialog on its own STA thread, exactly as the backend does it.
    let shown = dir.clone();
    std::thread::spawn(move || unsafe {
        let _ = CoInitializeEx(None, COINIT_APARTMENTTHREADED);
        if let Ok(dialog) =
            CoCreateInstance::<_, IFileOpenDialog>(&FileOpenDialog, None, CLSCTX_INPROC_SERVER)
        {
            if let Ok(options) = dialog.GetOptions() {
                let _ = dialog.SetOptions(options | FOS_FORCEFILESYSTEM);
            }
            let path = wide(&shown);
            if let Ok(item) =
                SHCreateItemFromParsingName::<_, _, IShellItem>(PCWSTR(path.as_ptr()), None)
            {
                let _ = dialog.SetFolder(&item);
            }
            let _ = dialog.Show(None);
        }
        CoUninitialize();
    });

    // `hold` exists only so `attach` has something to read: it keeps the
    // dialog up and gets out of the way. Its pid goes to stdout so the
    // runner can aim a reader at it, though attach's default — the first
    // #32770 that is not its own — is enough here.
    if holding {
        say(&format!("holding, pid {}", std::process::id()));
        std::thread::sleep(std::time::Duration::from_secs(90));
        say("PROBEDONE");
        return;
    }

    let mut dialog: isize = 0;
    for _ in 0..60 {
        std::thread::sleep(std::time::Duration::from_millis(250));
        unsafe { EnumWindows(Some(find_dialog), &mut dialog as *mut isize as isize) };
        if dialog != 0 {
            break;
        }
    }
    if dialog == 0 {
        say("no #32770 came up in 15s");
        say("PROBEDONE");
        return;
    }
    say(&format!("Q3 dialog #32770 text={:?}", text_of(dialog)));
    say("Q1/Q2 CHILD WINDOW TREE:");
    unsafe { EnumChildWindows(dialog, Some(dump_child), 1) };

    // Leave nothing running: IDCANCEL, the id the harness already
    // presses.
    let mut cancel: isize = 0;
    unsafe {
        EnumChildWindows(dialog, Some(find_cancel), &mut cancel as *mut isize as isize);
        if cancel != 0 {
            SendMessageW(cancel, BM_CLICK, 0, 0);
        }
    }
    say("PROBEDONE");
}
