// ScopeProbe — a hand-run probe for iOS behaviour NO LANE CAN WITNESS.
//
// The simulator does not enforce the app sandbox (docs/traps.md), so
// every scope-related assertion passes there for free. Anything whose
// answer depends on the sandbox DENYING something has to be measured on
// hardware, by hand, which is what this app is for. It answered the
// file-dialog questions on 2026-07-27 (DESIGN.md, File dialogs) and is
// kept because the next such question will not be the last.
//
// It is NOT part of any lane and never will be: it needs a paired
// device, a developer account, and a human to tap a picker. Run it with
// tools/ios/scopeprobe/build.sh.
//
// THE SHAPE TO COPY when adding a measurement: step 1 is a VACUITY
// GUARD. It opens the picked file with no scope at all and requires the
// denial. A device that also failed to enforce would say so there,
// instead of handing back a row of green ticks that mean nothing.
import UIKit
import UniformTypeIdentifiers

final class VC: UIViewController, UIDocumentPickerDelegate {
    let out = UITextView()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        let b = UIButton(type: .system)
        b.setTitle("Pick a file", for: .normal)
        b.titleLabel?.font = .systemFont(ofSize: 26, weight: .semibold)
        b.addTarget(self, action: #selector(pick), for: .touchUpInside)
        out.isEditable = false
        out.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        out.text = "Tap “Pick a file”.\n\nChoose something OUTSIDE this app — iCloud Drive, or On My iPhone. That is what makes the security scope real."
        let stack = UIStackView(arrangedSubviews: [b, out])
        stack.axis = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -20),
        ])
    }

    @objc func pick() {
        let p = UIDocumentPickerViewController(forOpeningContentTypes: [UTType.item])
        p.delegate = self
        present(p, animated: true)
    }

    func documentPicker(_ c: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        var log = ""
        func say(_ s: String) { log += s + "\n"; NSLog("PROBE %@", s) }

        say("file: \(url.lastPathComponent)")
        say("")

        // (1) VACUITY GUARD. Open with NO security scope. On a device that
        // enforces the sandbox this MUST be denied — if it succeeds, this
        // phone is not enforcing either and every result below is worthless.
        let fd0 = open(url.path, O_RDONLY)
        if fd0 >= 0 {
            var b = [UInt8](repeating: 0, count: 16)
            let n = read(fd0, &b, 16)
            close(fd0)
            say("1. open WITHOUT scope: SUCCEEDED (\(n) bytes)")
            say("   => NOT ENFORCING. Test is vacuous.")
        } else {
            say("1. open WITHOUT scope: denied (errno \(errno))")
            say("   => enforcement confirmed, test is meaningful")
        }
        say("")

        // (2) THE QUESTION. start -> open -> stop -> read.
        let started = url.startAccessingSecurityScopedResource()
        say("2. startAccessingSecurityScopedResource: \(started)")
        let fd = open(url.path, O_RDONLY)
        say("   open with scope held: fd=\(fd)\(fd < 0 ? " errno \(errno)" : "")")
        url.stopAccessingSecurityScopedResource()
        say("   stopAccessingSecurityScopedResource: called")
        if fd >= 0 {
            var b = [UInt8](repeating: 0, count: 64)
            let n = read(fd, &b, 64)
            if n >= 0 {
                say("   READ AFTER STOP: OK, \(n) bytes")
                say("   => THE FD SURVIVES")
            } else {
                say("   READ AFTER STOP: FAILED errno \(errno)")
                say("   => THE FD DOES NOT SURVIVE")
            }
            say("")

            // (3) mmap after the scope is gone — the strong claim, and the
            // one a desktop-class editor actually wants.
            let sz = lseek(fd, 0, SEEK_END)
            _ = lseek(fd, 0, SEEK_SET)
            say("3. lseek size: \(sz)\(sz < 0 ? " (not seekable)" : "")")
            if sz > 0 {
                let len = Int(min(sz, 4096))
                let m = mmap(nil, len, PROT_READ, MAP_PRIVATE, fd, 0)
                if m != MAP_FAILED {
                    let first = m!.assumingMemoryBound(to: UInt8.self).pointee
                    munmap(m, len)
                    say("   MMAP AFTER STOP: OK (first byte 0x\(String(first, radix: 16)))")
                    say("   => RANDOM ACCESS AVAILABLE")
                } else {
                    say("   MMAP AFTER STOP: failed errno \(errno)")
                }
            }
            close(fd)
        }
        say("")

        // (4) IS THE PATH A DURABLE CAPABILITY? Re-open by path now that
        // the scope is released. If this fails, `local_path` must NOT be
        // handed to a guest on iOS: it would look usable and not be.
        let fd2 = open(url.path, O_RDONLY)
        if fd2 >= 0 {
            close(fd2)
            say("4. re-open by PATH after stop: OK")
            say("   => the path IS a durable capability")
        } else {
            say("4. re-open by PATH after stop: denied (errno \(errno))")
            say("   => the path is NOT durable; only the fd is")
        }
        say("")

        // (5) Can the scope be re-acquired from the same URL object? If so
        // the URL is a re-usable capability for as long as it is held.
        let again = url.startAccessingSecurityScopedResource()
        let fd3 = open(url.path, O_RDONLY)
        if fd3 >= 0 { close(fd3) }
        url.stopAccessingSecurityScopedResource()
        say("5. re-start scope: \(again), re-open: \(fd3 >= 0 ? "OK" : "denied errno \(errno)")")
        say(fd3 >= 0 ? "   => the URL can re-acquire" : "   => one-shot")

        out.text = log
    }
}

final class AD: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    func application(_ a: UIApplication,
                     didFinishLaunchingWithOptions o: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        window = UIWindow(frame: UIScreen.main.bounds)
        window?.rootViewController = VC()
        window?.makeKeyAndVisible()
        return true
    }
}

UIApplicationMain(CommandLine.argc, CommandLine.unsafeArgv, nil, NSStringFromClass(AD.self))
