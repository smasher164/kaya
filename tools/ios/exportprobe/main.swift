import UIKit
import UniformTypeIdentifiers

private let payload = Data("kaya export preflight\n".utf8)
private let exportName =
    ProcessInfo.processInfo.environment["KAYA_EXPORT_NAME"]
    ?? "kaya-export-preflight"

private func documentsDirectory() -> URL {
    FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
}

private func probeFile(_ name: String) -> URL {
    FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent(name)
}

private func publish(_ result: String) {
    let line = result.replacingOccurrences(of: "\n", with: " ") + "\n"
    try? Data(line.utf8).write(
        to: probeFile("kaya-export-preflight-result"), options: .atomic)
}

final class ExportViewController: UIViewController, UIDocumentPickerDelegate {
    private var started = false

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !started else { return }
        started = true

        let manager = FileManager.default
        try? manager.removeItem(at: probeFile("kaya-export-preflight-result"))
        try? manager.removeItem(at: probeFile("kaya-export-preflight-ready"))
        let source = manager.temporaryDirectory.appendingPathComponent(exportName)
        do {
            try payload.write(to: source, options: .atomic)
        } catch {
            publish("error could not stage source: \(error)")
            return
        }

        let picker = UIDocumentPickerViewController(forExporting: [source], asCopy: true)
        picker.directoryURL = documentsDirectory()
        picker.shouldShowFileExtensions = true
        picker.delegate = self
        present(picker, animated: false) {
            try? Data("ready\n".utf8).write(
                to: probeFile("kaya-export-preflight-ready"), options: .atomic)
        }
    }

    func documentPicker(
        _ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]
    ) {
        guard let destination = urls.first else {
            publish("empty didPickDocumentsAt")
            return
        }
        let scoped = destination.startAccessingSecurityScopedResource()
        defer {
            if scoped { destination.stopAccessingSecurityScopedResource() }
        }
        do {
            let copied = try Data(contentsOf: destination)
            guard copied == payload else {
                publish("error destination bytes differ")
                return
            }
            guard destination.lastPathComponent == exportName else {
                publish("error destination name is \(destination.lastPathComponent)")
                return
            }
            try? FileManager.default.removeItem(at: destination)
            publish("ok")
        } catch {
            publish("error destination would not reopen: \(error)")
        }
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        publish("empty documentPickerWasCancelled")
    }
}

final class ExportAppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = ExportViewController()
        window.makeKeyAndVisible()
        self.window = window
        return true
    }
}

UIApplicationMain(
    CommandLine.argc,
    CommandLine.unsafeArgv,
    nil,
    NSStringFromClass(ExportAppDelegate.self))
