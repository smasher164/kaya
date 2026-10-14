//! What the display said when GTK could not open it (docs/traps.md, the x11
//! leg whose display would not open): GTK prints `Failed to open display`
//! and exits 1 from inside its own startup, naming nothing it measured.

use std::io::{Read, Write};
use std::os::unix::net::UnixStream;
use std::path::Path;
use std::time::Duration;

/// One sentence of what the display's socket answered, for the backend GDK
/// was asked for.
pub(crate) fn display_why_not(
    backend: Option<&str>,
    display: Option<&str>,
    wayland: Option<&str>,
    runtime: Option<&str>,
    x11_dir: &Path,
) -> String {
    let asked = format!(
        "GDK_BACKEND={}, DISPLAY={}, WAYLAND_DISPLAY={}",
        backend.unwrap_or("<unset>"),
        display.unwrap_or("<unset>"),
        wayland.unwrap_or("<unset>")
    );
    if backend == Some("wayland") {
        let Some(name) = wayland else {
            return format!("{asked}: no WAYLAND_DISPLAY to open");
        };
        let path = if name.starts_with('/') {
            name.to_owned()
        } else {
            match runtime {
                Some(dir) => format!("{dir}/{name}"),
                None => return format!("{asked}: WAYLAND_DISPLAY is relative and XDG_RUNTIME_DIR is unset"),
            }
        };
        return match UnixStream::connect(&path) {
            Ok(_) => format!("{asked}: {path} accepts a connection now, so the compositor refused or failed GTK's own"),
            Err(e) => format!("{asked}: connecting to {path}: {e}"),
        };
    }
    let Some(display) = display else {
        return format!("{asked}: no DISPLAY to open");
    };
    let Some(number) = display
        .strip_prefix(':')
        .map(|d| d.split('.').next().unwrap_or(d))
        .filter(|d| !d.is_empty() && d.chars().all(|c| c.is_ascii_digit()))
    else {
        return format!("{asked}: DISPLAY is not a local `:N` display, so no socket was asked");
    };
    let socket = x11_dir.join(format!("X{number}"));
    if !socket.exists() {
        return format!("{asked}: {} does not exist (no X server listens there)", socket.display());
    }
    let mut stream = match UnixStream::connect(&socket) {
        Ok(s) => s,
        Err(e) => return format!("{asked}: connecting to {}: {e}", socket.display()),
    };
    let _ = stream.set_read_timeout(Some(Duration::from_secs(2)));
    let _ = stream.set_write_timeout(Some(Duration::from_secs(2)));
    let mut setup = vec![0x6c, 0];
    setup.extend_from_slice(&11u16.to_le_bytes());
    setup.extend_from_slice(&0u16.to_le_bytes());
    setup.extend_from_slice(&[0, 0, 0, 0, 0, 0]);
    if let Err(e) = stream.write_all(&setup) {
        return format!("{asked}: {} accepted a connection and refused the setup request: {e}", socket.display());
    }
    let mut reply = Vec::new();
    let mut chunk = [0u8; 256];
    while reply.len() < 8 || reply.len() < 8 + 4 * u16::from_le_bytes([reply[6], reply[7]]) as usize {
        match stream.read(&mut chunk) {
            Ok(0) => break,
            Ok(n) => reply.extend_from_slice(&chunk[..n]),
            Err(e) => {
                return format!(
                    "{asked}: {} accepted a connection and gave no setup answer ({} bytes, then {e})",
                    socket.display(),
                    reply.len()
                )
            }
        }
        if reply.first() == Some(&1) {
            break;
        }
    }
    format!("{asked}: {}: {}", socket.display(), setup_answer(&reply))
}

/// The X server's answer to a connection setup (X11 protocol, Connection
/// Setup): 0 Failed with its reason, 1 Success, 2 Authenticate.
fn setup_answer(reply: &[u8]) -> String {
    match reply.first() {
        None => "the server closed the connection without a setup answer".to_owned(),
        Some(0) => {
            let len = reply.get(1).copied().unwrap_or(0) as usize;
            let reason = reply.get(8..8 + len).map(|r| String::from_utf8_lossy(r).into_owned());
            match reason {
                Some(r) => format!("the server REFUSED the connection: {r:?}"),
                None => format!("the server refused the connection, its reason cut short ({} bytes)", reply.len()),
            }
        }
        Some(1) => "the server accepts a connection now, so GTK's own open failed earlier and the display recovered".to_owned(),
        Some(2) => "the server asked for authentication, which the guest's connection did not carry".to_owned(),
        Some(b) => format!("the server answered setup with an unknown status byte {b}"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::net::UnixListener;

    fn serve(dir: &Path, number: &str, answer: Vec<u8>) -> std::thread::JoinHandle<()> {
        let listener = UnixListener::bind(dir.join(format!("X{number}"))).unwrap();
        std::thread::spawn(move || {
            let (mut s, _) = listener.accept().unwrap();
            let mut req = [0u8; 12];
            s.read_exact(&mut req).unwrap();
            assert_eq!(req[0], 0x6c);
            s.write_all(&answer).unwrap();
        })
    }

    fn scratch(tag: &str) -> std::path::PathBuf {
        let dir = std::env::temp_dir().join(format!("kaya-display-probe-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn every_branch_of_the_display_why_not_prints() {
        let dir = scratch("x11");
        let x = Some("x11");
        let refused = serve(&dir, "1", {
            let mut f = vec![0u8, 33, 11, 0, 0, 0, 9, 0];
            f.extend_from_slice(b"Maximum number of clients reached\0\0\0");
            f
        });
        let said = display_why_not(x, Some(":1"), None, None, &dir);
        refused.join().unwrap();
        assert!(said.contains("REFUSED the connection: \"Maximum number of clients reached\""), "{said}");
        let mut ok = vec![1u8, 0, 11, 0, 0, 0, 1, 0];
        ok.extend_from_slice(&[0; 4]);
        let accepted = serve(&dir, "2", ok);
        let said = display_why_not(x, Some(":2.0"), None, None, &dir);
        accepted.join().unwrap();
        assert!(said.contains("accepts a connection now"), "{said}");
        let auth = serve(&dir, "3", vec![2u8, 0, 0, 0, 0, 0, 0, 0]);
        let said = display_why_not(x, Some(":3"), None, None, &dir);
        auth.join().unwrap();
        assert!(said.contains("asked for authentication"), "{said}");
        let closed = serve(&dir, "4", vec![]);
        let said = display_why_not(x, Some(":4"), None, None, &dir);
        closed.join().unwrap();
        assert!(said.contains("without a setup answer"), "{said}");
        let odd = serve(&dir, "5", vec![7u8, 0, 0, 0, 0, 0, 0, 0]);
        let said = display_why_not(x, Some(":5"), None, None, &dir);
        odd.join().unwrap();
        assert!(said.contains("unknown status byte 7"), "{said}");
        let short = serve(&dir, "6", vec![0u8, 40, 11, 0, 0, 0, 0, 0, b'x']);
        let said = display_why_not(x, Some(":6"), None, None, &dir);
        short.join().unwrap();
        assert!(said.contains("reason cut short"), "{said}");
        let said = display_why_not(x, Some(":9"), None, None, &dir);
        assert!(said.contains("X9 does not exist"), "{said}");
        std::fs::write(dir.join("X8"), b"").unwrap();
        let said = display_why_not(x, Some(":8"), None, None, &dir);
        assert!(said.contains("connecting to") && said.contains("X8"), "{said}");
        let said = display_why_not(x, None, None, None, &dir);
        assert!(said.ends_with("no DISPLAY to open"), "{said}");
        let said = display_why_not(x, Some("host:0"), None, None, &dir);
        assert!(said.contains("not a local `:N` display"), "{said}");
        let w = Some("wayland");
        let said = display_why_not(w, None, None, None, &dir);
        assert!(said.ends_with("no WAYLAND_DISPLAY to open"), "{said}");
        let said = display_why_not(w, None, Some("wayland-1"), None, &dir);
        assert!(said.contains("XDG_RUNTIME_DIR is unset"), "{said}");
        let dir_s = dir.to_str().unwrap();
        let said = display_why_not(w, None, Some("wayland-1"), Some(dir_s), &dir);
        assert!(said.contains("connecting to") && said.contains("wayland-1"), "{said}");
        let _listener = UnixListener::bind(dir.join("wayland-2")).unwrap();
        let said = display_why_not(w, None, Some("wayland-2"), Some(dir_s), &dir);
        assert!(said.contains("accepts a connection now, so the compositor"), "{said}");
        let _ = std::fs::remove_dir_all(&dir);
    }
}
