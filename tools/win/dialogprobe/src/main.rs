// DialogProbe — what the Shell's file dialog is MADE OF, measured on
// the VM the windows lane actually runs on.
//
// THE QUESTION, and it decides whether the windows harness can drop UI
// Automation entirely:
//
//   Q1 Is the dialog's file list a classic control? docs/deferred.md
//      asserted the rows are a SysListView32 readable with
//      LVM_GETITEMTEXT. THAT WAS NEVER MEASURED — it is true of the old
//      GetOpenFileName dialog, and the Vista-era common item dialog is
//      widely described as DirectUI-hosted, whose items are not windows
//      at all. If they are not, no amount of SendMessage reads them and
//      the only route left is driving the dialog from outside the guest
//      process.
//   Q2 Is the address bar a window with text, or is that DirectUI too?
//      The harness reads the current directory from it.
//   Q3 Do the classic control ids still answer? IDOK=1 and IDCANCEL=2
//      are what file_dialog_press already uses and they work — this
//      records the whole id map, so a future read knows what is there.
//
// WHY IT MAY USE A LOCAL BUFFER AT ALL: the dialog is created with
// CLSCTX_INPROC_SERVER, in the app's own process, on its own STA
// thread. A cross-process listview read needs VirtualAllocEx and
// ReadProcessMemory, because LVITEM carries a pointer the other process
// must be able to dereference; in-process it is just a pointer. So this
// probe opens the dialog the way crates/kaya/src/winui/mod.rs does
// rather than attaching to a running app — it must measure the
// arrangement the harness would actually have, not a similar one.
//
// The window calls are hand-declared with plain types, the way
// file_dialog_is_up declares them, so the probe exercises the same
// calls the backend would make rather than a differently-typed
// wrapper.
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
}

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

fn main() {
    let dir = std::env::args()
        .nth(1)
        .unwrap_or_else(|| r"C:\kaya\probe-dir".to_string());
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
