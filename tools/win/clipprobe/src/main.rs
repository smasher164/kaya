// ClipProbe (Windows) — what the classic Win32 clipboard charges for
// kaya's five representations, measured ON THE PATH THE ARM WILL USE,
// in the interactive session, with a FOREIGN PowerShell process on the
// other side of every assertion. Why classic Win32 and not WinRT
// DataTransfer, and what each question found, is docs/clipboard-plan.md
// §6.
//
// Throwaway; nothing builds or runs this but a human, via build.sh,
// which runs everything in ONE interactive-session scheduled task —
// every ssh connection gets its OWN window station and therefore its
// OWN CLIPBOARD (measured 2026-08-03: a value written in one ssh
// connection reads back null in the next), so nothing here may touch
// the clipboard from the ssh session itself.

use windows::Win32::Foundation::{HANDLE, HGLOBAL};
use windows::Win32::System::DataExchange::{
    CloseClipboard, EmptyClipboard, EnumClipboardFormats, GetClipboardData,
    GetClipboardFormatNameW, IsClipboardFormatAvailable, OpenClipboard,
    RegisterClipboardFormatW, SetClipboardData,
};
use windows::Win32::System::Memory::{
    GlobalAlloc, GlobalLock, GlobalSize, GlobalUnlock, GMEM_MOVEABLE,
};
use windows_core::w;

const CF_UNICODETEXT: u32 = 13;
const CF_HDROP: u32 = 15;

/// The same valid 4x4 PNG the guests embed (77 bytes; the previous
/// 88-byte constant had a broken IDAT CRC — §5b finding 5).
const PIXEL_PNG: &[u8] = &[
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44,
    0x52, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x04, 0x08, 0x02, 0x00, 0x00, 0x00, 0x26,
    0x93, 0x09, 0x29, 0x00, 0x00, 0x00, 0x14, 0x49, 0x44, 0x41, 0x54, 0x78, 0xDA, 0x63, 0xF8,
    0xCF, 0xC0, 0x00, 0x47, 0x48, 0x4C, 0x74, 0xDE, 0x7F, 0x24, 0x00, 0x00, 0xD2, 0x6F, 0x17,
    0xE9, 0x51, 0xBB, 0x23, 0x2D, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42,
    0x60, 0x82,
];

fn say(line: &str) {
    println!("PROBE {line}");
}

/// Open with the retry discipline the arm will need: the clipboard is
/// a global lock and another process holding it answers with an error,
/// not a wait.
fn open_clipboard_retry() {
    for attempt in 0..10 {
        if unsafe { OpenClipboard(None) }.is_ok() {
            return;
        }
        std::thread::sleep(std::time::Duration::from_millis(20 * (attempt + 1)));
    }
    panic!("clipprobe: could not open the clipboard after 10 tries — another process holds it");
}

fn set_bytes(format: u32, bytes: &[u8]) {
    unsafe {
        let hglobal: HGLOBAL =
            GlobalAlloc(GMEM_MOVEABLE, bytes.len().max(1)).expect("GlobalAlloc");
        let p = GlobalLock(hglobal);
        std::ptr::copy_nonoverlapping(bytes.as_ptr(), p as *mut u8, bytes.len());
        let _ = GlobalUnlock(hglobal);
        SetClipboardData(format, Some(HANDLE(hglobal.0))).expect("SetClipboardData");
    }
}

/// Read one format's bytes: GlobalSize is allowed to exceed the
/// requested allocation, so self-delimiting formats must trust their
/// own delimiters, and this probe reports BOTH the size and the bytes
/// so that fact is visible.
fn get_bytes(format: u32) -> Option<Vec<u8>> {
    unsafe {
        if IsClipboardFormatAvailable(format).is_err() {
            return None;
        }
        let handle = GetClipboardData(format).ok()?;
        let hglobal = HGLOBAL(handle.0);
        let size = GlobalSize(hglobal);
        let p = GlobalLock(hglobal);
        if p.is_null() {
            return None;
        }
        let bytes = std::slice::from_raw_parts(p as *const u8, size).to_vec();
        let _ = GlobalUnlock(hglobal);
        Some(bytes)
    }
}

fn utf16z(s: &str) -> Vec<u8> {
    let mut units: Vec<u16> = s.encode_utf16().collect();
    units.push(0);
    units.iter().flat_map(|u| u.to_le_bytes()).collect()
}

/// CF_HTML with 10-digit fixed-width offsets. Fixed width is what
/// makes the header length a CONSTANT rather than a fixpoint — pad
/// while computing but print unpadded and every offset is silently
/// short. Verified against a byte-exact worked example (the fragment
/// "<b>kaya</b> clip" => StartHTML 105, StartFragment 141,
/// EndFragment 157, EndHTML 193).
fn build_cf_html(fragment: &str) -> Vec<u8> {
    const HEADER_LEN: usize = 105;
    const PREFIX: &str = "<html>\r\n<body>\r\n<!--StartFragment-->";
    const SUFFIX: &str = "<!--EndFragment-->\r\n</body>\r\n</html>";
    let start_fragment = HEADER_LEN + PREFIX.len();
    let end_fragment = start_fragment + fragment.len();
    let end_html = end_fragment + SUFFIX.len();
    let header = format!(
        "Version:0.9\r\nStartHTML:{HEADER_LEN:010}\r\nEndHTML:{end_html:010}\r\nStartFragment:{start_fragment:010}\r\nEndFragment:{end_fragment:010}\r\n"
    );
    assert!(header.len() == HEADER_LEN, "the header stopped being a constant");
    let mut out = header.into_bytes();
    out.extend_from_slice(PREFIX.as_bytes());
    out.extend_from_slice(fragment.as_bytes());
    out.extend_from_slice(SUFFIX.as_bytes());
    out
}

/// The read side's fragment parse — offsets are BYTE offsets into the
/// whole payload, and a reader must trust them, never GlobalSize.
fn parse_cf_html(payload: &[u8]) -> Option<String> {
    let head = String::from_utf8_lossy(&payload[..payload.len().min(400)]).into_owned();
    let grab = |key: &str| -> Option<usize> {
        let at = head.find(key)? + key.len();
        head[at..]
            .chars()
            .take_while(|c| c.is_ascii_digit())
            .collect::<String>()
            .parse()
            .ok()
    };
    let start = grab("StartFragment:")?;
    let end = grab("EndFragment:")?;
    if start >= end || end > payload.len() {
        return None;
    }
    Some(String::from_utf8_lossy(&payload[start..end]).into_owned())
}

/// DROPFILES: 20-byte struct (pFiles=20, pt={0,0}, fNC=0, fWide=1),
/// then UTF-16 paths each NUL-terminated, then one extra NUL.
fn build_dropfiles(paths: &[&str]) -> Vec<u8> {
    let mut out = Vec::new();
    out.extend_from_slice(&20u32.to_le_bytes()); // pFiles
    out.extend_from_slice(&0i32.to_le_bytes()); // pt.x
    out.extend_from_slice(&0i32.to_le_bytes()); // pt.y
    out.extend_from_slice(&0u32.to_le_bytes()); // fNC
    out.extend_from_slice(&1u32.to_le_bytes()); // fWide
    for path in paths {
        out.extend_from_slice(&utf16z(path));
    }
    out.extend_from_slice(&[0, 0]); // the terminating extra NUL
    out
}

fn parse_dropfiles(bytes: &[u8]) -> Vec<String> {
    if bytes.len() < 20 {
        return Vec::new();
    }
    let p_files = u32::from_le_bytes(bytes[0..4].try_into().unwrap()) as usize;
    let f_wide = u32::from_le_bytes(bytes[16..20].try_into().unwrap());
    if f_wide == 0 {
        return vec!["<ANSI list, unhandled by this probe>".into()];
    }
    let mut out = Vec::new();
    let mut at = p_files;
    loop {
        let mut units = Vec::new();
        while at + 1 < bytes.len() {
            let u = u16::from_le_bytes([bytes[at], bytes[at + 1]]);
            at += 2;
            if u == 0 {
                break;
            }
            units.push(u);
        }
        if units.is_empty() {
            break;
        }
        out.push(String::from_utf16_lossy(&units));
    }
    out
}

fn format_name(format: u32) -> String {
    match format {
        1 => "CF_TEXT".into(),
        13 => "CF_UNICODETEXT".into(),
        15 => "CF_HDROP".into(),
        2 => "CF_BITMAP".into(),
        8 => "CF_DIB".into(),
        17 => "CF_DIBV5".into(),
        16 => "CF_LOCALE".into(),
        7 => "CF_OEMTEXT".into(),
        _ => {
            let mut buf = [0u16; 256];
            let n = unsafe { GetClipboardFormatNameW(format, &mut buf) };
            if n > 0 {
                String::from_utf16_lossy(&buf[..n as usize])
            } else {
                format!("#{format}")
            }
        }
    }
}

fn escape(s: &str) -> String {
    s.replace('\r', "\\r").replace('\n', "\\n")
}

fn cmd_set() {
    // The files the FileDropList half names, and the pixel the ps1
    // seeds from, written before anything touches the clipboard.
    std::fs::create_dir_all("C:\\kaya\\clipprobe").expect("mkdir");
    std::fs::write("C:\\kaya\\clipprobe\\f1.txt", b"one").expect("f1");
    std::fs::write("C:\\kaya\\clipprobe\\f2.txt", b"two").expect("f2");
    std::fs::write("C:\\kaya\\clipprobe\\pixel.png", PIXEL_PNG).expect("pixel");

    let custom = unsafe { RegisterClipboardFormatW(w!("dev.kaya/note")) };
    say(&format!("W2 RegisterClipboardFormatW(\"dev.kaya/note\") = atom {custom}"));
    say(&format!("W2 name read back: {:?}", format_name(custom)));
    let png = unsafe { RegisterClipboardFormatW(w!("PNG")) };
    let html = unsafe { RegisterClipboardFormatW(w!("HTML Format")) };

    open_clipboard_retry();
    unsafe { EmptyClipboard() }.expect("EmptyClipboard");
    // Descending clip value — custom, files, image, html, text — the
    // canonical order (§1): first-set is preferred-order on Windows.
    set_bytes(custom, b"note=1");
    set_bytes(
        CF_HDROP,
        &build_dropfiles(&["C:\\kaya\\clipprobe\\f1.txt", "C:\\kaya\\clipprobe\\f2.txt"]),
    );
    set_bytes(png, PIXEL_PNG);
    set_bytes(html, &build_cf_html("<b>kaya</b> clip"));
    set_bytes(CF_UNICODETEXT, &utf16z("kaya clip"));
    unsafe { CloseClipboard() }.expect("CloseClipboard");
    say("W1 set five formats in one open; exiting so the foreign reads outlive the owner");
}

fn cmd_read(kind: &str) {
    open_clipboard_retry();
    // The offer, as the arm's read chooser would see it.
    let mut format = 0u32;
    let mut offers = Vec::new();
    loop {
        format = unsafe { EnumClipboardFormats(format) };
        if format == 0 {
            break;
        }
        offers.push(format_name(format));
    }
    say(&format!("W4 [{kind}] offer: {}", offers.join(" | ")));

    match kind {
        "text" => match get_bytes(CF_UNICODETEXT) {
            Some(bytes) => {
                let units: Vec<u16> = bytes
                    .chunks_exact(2)
                    .map(|c| u16::from_le_bytes([c[0], c[1]]))
                    .take_while(|&u| u != 0)
                    .collect();
                say(&format!(
                    "W4 text: >>>{}<<<",
                    escape(&String::from_utf16_lossy(&units))
                ));
            }
            None => say("W4 text: ABSENT"),
        },
        "html" => {
            let html = unsafe { RegisterClipboardFormatW(w!("HTML Format")) };
            match get_bytes(html) {
                Some(bytes) => {
                    say(&format!(
                        "W4 html raw head: >>>{}<<<",
                        escape(&String::from_utf8_lossy(&bytes[..bytes.len().min(160)]))
                    ));
                    match parse_cf_html(&bytes) {
                        Some(fragment) => say(&format!("W4 html fragment: >>>{}<<<", escape(&fragment))),
                        None => say("W4 html fragment: PARSE FAILED"),
                    }
                }
                None => say("W4 html: ABSENT"),
            }
        }
        "image" => {
            let png = unsafe { RegisterClipboardFormatW(w!("PNG")) };
            match get_bytes(png) {
                Some(bytes) => say(&format!(
                    "W4 image: {} bytes (GlobalSize), starts_with_signature={}, equals_pixel_when_truncated={}",
                    bytes.len(),
                    bytes.starts_with(&[0x89, 0x50, 0x4E, 0x47]),
                    bytes.len() >= PIXEL_PNG.len() && &bytes[..PIXEL_PNG.len()] == PIXEL_PNG
                )),
                None => say("W4 image: PNG format ABSENT"),
            }
        }
        "files" => match get_bytes(CF_HDROP) {
            Some(bytes) => say(&format!("W4 files: {:?}", parse_dropfiles(&bytes))),
            None => say("W4 files: ABSENT"),
        },
        "custom" => {
            let custom = unsafe { RegisterClipboardFormatW(w!("dev.kaya/note")) };
            match get_bytes(custom) {
                Some(bytes) => say(&format!(
                    "W4 custom: GlobalSize={} bytes={:?}",
                    bytes.len(),
                    escape(&String::from_utf8_lossy(&bytes))
                )),
                None => say("W4 custom: ABSENT"),
            }
        }
        other => say(&format!("unknown read kind {other:?}")),
    }
    unsafe { CloseClipboard() }.expect("CloseClipboard");
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    match args.get(1).map(String::as_str) {
        Some("set") => cmd_set(),
        Some("read") => cmd_read(args.get(2).map(String::as_str).unwrap_or("text")),
        _ => {
            eprintln!("usage: clipprobe set | clipprobe read <text|html|image|files|custom>");
            std::process::exit(2);
        }
    }
}
