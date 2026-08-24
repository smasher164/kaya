// simdrive — the harness's eyes and hands OUTSIDE the app, on iOS: it
// reads the simulator's accessibility tree and delivers HID taps from
// the HOST, through private frameworks shipped inside Xcode. Why an
// in-process driver is impossible, and the things on this path that look
// like failure and are not, are in docs/traps.md ("The iOS picker is
// another app too" and the three sections after it).
import CoreGraphics
import Darwin
import Foundation
import ObjectiveC

// MARK: - the side channel
//
// EVERY MEASUREMENT GOES TO A FILE, NEVER TO stdout OR stderr:
// run-sim.sh's simdrive_watch captures this process's whole output and
// hands it to the guest as the response it parses, so one extra byte on
// either stream on a success path breaks the protocol. The file is the
// one KAYA_SIMDRIVE_LOG names (docs/deferred.md's WATCH entry "the iOS
// sheets shrug off single taps under a concurrent matrix"); unset means
// no instrument, which is how this tool stays usable by hand.

let environment = ProcessInfo.processInfo.environment
let processStart = DispatchTime.now().uptimeNanoseconds
let logFD: Int32 = {
    guard let path = environment["KAYA_SIMDRIVE_LOG"], !path.isEmpty else { return -1 }
    return open(path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
}()

var currentVerb = "-"
var bridgeReads = 0
var bridgeSlowLines = 0
var bridgeTimeouts = 0
var bridgeMaxMs: UInt64 = 0
var tapsSent = 0

func mark() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
func sinceMs(_ from: UInt64) -> UInt64 { (mark() - from) / 1_000_000 }
func nowMs() -> UInt64 { sinceMs(processStart) }

/// One event, one line, ONE write: O_APPEND plus a single write keeps a
/// line whole against any other writer of the same file — the shell's
/// watcher writes its own lines to it.
///
/// `at` is epoch MILLISECONDS, an integer, in both writers: run-sim.sh's
/// clock is EPOCHREALTIME, whose radix character belongs to the locale.
/// `t` is monotonic, from this process's start.
func note(_ event: String, _ fields: String = "") {
    guard logFD >= 0 else { return }
    let line = "KAYA_SIMDRIVE: at=\(UInt64(Date().timeIntervalSince1970 * 1000))"
        + " t=\(nowMs()) verb=\(currentVerb) ev=\(event)"
        + (fields.isEmpty ? "" : " " + fields) + "\n"
    _ = line.withCString { write(logFD, $0, strlen($0)) }
}

/// A value with spaces, as one field a key=value reader can take.
func quoted(_ s: String) -> String {
    "\"" + s.replacingOccurrences(of: "\"", with: "'")
        .replacingOccurrences(of: "\n", with: " ") + "\""
}

func xy(_ p: CGPoint) -> String { String(format: "x=%.1f y=%.1f", p.x, p.y) }

func noteSummary() {
    note(
        "end",
        "ms=\(nowMs()) reads=\(bridgeReads) read_max_ms=\(bridgeMaxMs) "
            + "read_timeouts=\(bridgeTimeouts) taps=\(tapsSent)")
}
atexit { noteSummary() }

// MARK: - plumbing

/// EVERY failure sentence carries the bridge's own numbers, because a
/// starved simulator and a healthy one fail in identical words otherwise
/// — a read that timed out at 20s returns nil, which reads here as "not
/// there" (docs/deferred.md's iOS-sheets WATCH entry). Appended here
/// rather than at each call site so a new one cannot be written without
/// them.
func fail(_ s: String) -> Never {
    var sentence = s
    if bridgeReads > 0 {
        sentence += " (measured in this verb: \(bridgeReads) accessibility reads, "
            + "slowest \(bridgeMaxMs)ms, \(bridgeTimeouts) timed out at 20s; "
            + "\(tapsSent) taps sent; \(nowMs())ms since simdrive started)"
    }
    note("fail", "msg=\(quoted(sentence))")
    FileHandle.standardError.write(Data(("simdrive: " + sentence + "\n").utf8))
    exit(1)
}

let developerDir = environment["KAYA_SIMDRIVE_DEVELOPER_DIR"]
    ?? environment["DEVELOPER_DIR"] ?? ""
guard !developerDir.isEmpty else {
    fail("neither KAYA_SIMDRIVE_DEVELOPER_DIR nor DEVELOPER_DIR is set — no Xcode to reach")
}
guard dlopen("/Library/Developer/PrivateFrameworks/CoreSimulator.framework/CoreSimulator", RTLD_NOW) != nil
else { fail("CoreSimulator would not load") }
guard dlopen(
    "/System/Library/PrivateFrameworks/AccessibilityPlatformTranslation.framework/"
        + "AccessibilityPlatformTranslation", RTLD_NOW) != nil
else { fail("AccessibilityPlatformTranslation would not load") }
let simulatorKitHandle: UnsafeMutableRawPointer = {
    guard let handle = dlopen(
        "\(developerDir)/Library/PrivateFrameworks/SimulatorKit.framework/SimulatorKit", RTLD_NOW)
    else { fail("SimulatorKit would not load") }
    return handle
}()

// MARK: - the device

func lookUpDevice(_ udid: String) -> NSObject {
    guard let ctxClass = NSClassFromString("SimServiceContext"),
        let ctx = (ctxClass as AnyObject).perform(
            NSSelectorFromString("sharedServiceContextForDeveloperDir:error:"),
            with: developerDir, with: nil)?.takeUnretainedValue() as? NSObject,
        let set = ctx.perform(NSSelectorFromString("defaultDeviceSetWithError:"), with: nil)?
            .takeUnretainedValue() as? NSObject,
        let devices = set.value(forKey: "devices") as? [NSObject]
    else { fail("no simulator device set for \(developerDir)") }
    guard let found = devices.first(where: {
        ($0.value(forKey: "UDID") as? NSUUID)?.uuidString.lowercased() == udid.lowercased()
    }) else { fail("no device \(udid)") }
    return found
}

// MARK: - the accessibility bridge

@objc protocol SimDeviceAccessibility {
    @objc(sendAccessibilityRequestAsync:completionQueue:completionHandler:)
    func sendAccessibilityRequestAsync(
        _ request: AnyObject, completionQueue: DispatchQueue,
        completionHandler: @escaping (AnyObject?) -> Void)
}

/// Fulfils the translator's requests against the device. The callback is
/// SYNCHRONOUS by contract, so it blocks on the async send.
final class Bridge: NSObject {
    let device: NSObject
    weak var translator: NSObject?
    init(device: NSObject) { self.device = device }

    @objc(accessibilityTranslationDelegateBridgeCallbackWithToken:)
    func callback(withToken token: String) -> (@convention(block) (AnyObject) -> AnyObject?) {
        { [device, weak self] request in
            let sema = DispatchSemaphore(value: 0)
            var out: AnyObject?
            let started = mark()
            unsafeBitCast(device, to: SimDeviceAccessibility.self)
                .sendAccessibilityRequestAsync(
                    request, completionQueue: DispatchQueue.global(),
                    completionHandler: { out = $0; sema.signal() })
            let waited = sema.wait(timeout: .now() + 20)
            // WHAT EVERY READ COST. A request served by a starved
            // process comes back late or not at all, and a timed-out one
            // returns nil — which every caller above reads as "nothing
            // is there". That is the one measurement that separates a
            // simulator that cannot answer from a gesture that was
            // dropped (docs/deferred.md's iOS-sheets WATCH entry).
            let ms = sinceMs(started)
            bridgeReads += 1
            if ms > bridgeMaxMs { bridgeMaxMs = ms }
            if waited == .timedOut {
                bridgeTimeouts += 1
                note("bridge_timeout", "ms=\(ms)")
            } else if ms >= 250 {
                bridgeSlowLines += 1
                if bridgeSlowLines <= 20 { note("bridge_slow", "ms=\(ms)") }
            }
            // Every response must be retired or the next TAP is silently
            // ignored while the reads keep working (docs/traps.md).
            if let out, let translator = self?.translator {
                let reset = NSSelectorFromString("_resetBridgeTokensForResponse:bridgeDelegateToken:")
                if translator.responds(to: reset) {
                    _ = translator.perform(reset, with: out, with: token)
                }
            }
            return out
        }
    }

    @objc(accessibilityTranslationConvertPlatformFrameToSystem:withToken:)
    func convert(_ rect: CGRect, withToken token: String) -> CGRect { rect }

    @objc(accessibilityTranslationRootParentWithToken:)
    func rootParent(withToken token: String) -> AnyObject? { nil }
}

@objc protocol TranslatorMessaging {
    @objc(frontmostApplicationWithDisplayId:bridgeDelegateToken:)
    func frontmostApplication(withDisplayId: UInt32, bridgeDelegateToken: String) -> AnyObject?
    @objc(objectAtPoint:displayId:bridgeDelegateToken:)
    func objectAtPoint(_ point: CGPoint, displayId: UInt32, bridgeDelegateToken: String) -> AnyObject?
    @objc(translationApplicationObjectForPid:)
    func translationApplicationObject(forPid: Int32) -> AnyObject?
}

final class Simulator {
    let device: NSObject
    let token: String
    let translator: NSObject
    private let bridge: Bridge
    private let elementClass: AnyObject

    init(udid: String) {
        device = lookUpDevice(udid)
        guard let token = device.perform(
            NSSelectorFromString("accessibilityPlatformTranslationToken"))?
            .takeUnretainedValue() as? String
        else { fail("the device published no accessibility translation token") }
        self.token = token
        bridge = Bridge(device: device)

        guard let translatorClass = NSClassFromString("AXPTranslator") else {
            fail("no AXPTranslator")
        }
        // EVERY singleton: with the delegate on one, the first fetch
        // works and every read after it returns nothing (docs/traps.md).
        var concrete: NSObject?
        for getter in ["sharedInstance", "sharediOSInstance", "sharedmacOSInstance"] {
            let sel = NSSelectorFromString(getter)
            guard (translatorClass as AnyObject).responds(to: sel),
                let instance = (translatorClass as AnyObject).perform(sel)?
                    .takeUnretainedValue() as? NSObject
            else { continue }
            instance.setValue(bridge, forKey: "bridgeTokenDelegate")
            instance.setValue(true, forKey: "supportsDelegateTokens")
            if getter == "sharediOSInstance" { concrete = instance }
        }
        guard let iOSTranslator = concrete else { fail("no iOS translator instance") }
        translator = iOSTranslator
        bridge.translator = iOSTranslator
        guard let elementClass = NSClassFromString("AXPMacPlatformElement") else {
            fail("no AXPMacPlatformElement")
        }
        self.elementClass = elementClass as AnyObject
    }

    private var messaging: TranslatorMessaging {
        unsafeBitCast(translator, to: TranslatorMessaging.self)
    }

    /// A readable element for a translation object. The token has to ride
    /// the object or its attribute reads route nowhere.
    func element(for translation: AnyObject) -> NSObject? {
        (translation as? NSObject)?.setValue(token, forKey: "bridgeDelegateToken")
        return elementClass.perform(
            NSSelectorFromString("platformElementWithTranslationObject:"), with: translation)?
            .takeUnretainedValue() as? NSObject
    }

    func frontmostApplication() -> NSObject? {
        messaging.frontmostApplication(withDisplayId: 0, bridgeDelegateToken: token) as? NSObject
    }

    func objectAtPoint(_ p: CGPoint) -> NSObject? {
        messaging.objectAtPoint(p, displayId: 0, bridgeDelegateToken: token) as? NSObject
    }

    func applicationObject(forPid pid: Int32) -> NSObject? {
        messaging.translationApplicationObject(forPid: pid) as? NSObject
    }
}

// MARK: - reading elements (the LEGACY api; docs/traps.md)

func attribute(_ element: NSObject, _ name: String) -> Any? {
    let sel = NSSelectorFromString("accessibilityAttributeValue:")
    guard element.responds(to: sel) else { return nil }
    return element.perform(sel, with: name)?.takeUnretainedValue()
}

/// The legacy protocol's action half — a DISCRIMINATOR, not a driver:
/// only savepress's failure path calls it, after six DELIVERED HID taps
/// were ignored (the tenth sighting's shape: taps down=ok, bridge
/// serving reads at 31ms, sheet honestly up — docs/deferred.md's iOS
/// WATCH entry). AX-press landing where HID taps did not convicts the
/// sheet's INPUT path; both failing convicts the button itself. The
/// verbs never drive with it — a user cannot AX-press.
func performAXPress(_ element: NSObject) -> Bool {
    let sel = NSSelectorFromString("accessibilityPerformAction:")
    guard element.responds(to: sel) else { return false }
    _ = element.perform(sel, with: "AXPress")
    return true
}

func text(_ element: NSObject, _ name: String) -> String {
    (attribute(element, name) as? String) ?? ""
}

/// Write an attribute back through the same legacy api the reads use.
/// A set that routes nowhere reports nothing, so every caller reads the
/// value back.
func setAttribute(_ element: NSObject, _ name: String, _ value: Any) -> Bool {
    let sel = NSSelectorFromString("accessibilitySetValue:forAttribute:")
    guard element.responds(to: sel) else { return false }
    element.perform(sel, with: value, with: name)
    return true
}

func children(_ element: NSObject) -> [NSObject] {
    (attribute(element, "AXChildren") as? [NSObject]) ?? []
}

func frame(_ element: NSObject) -> CGRect {
    let origin = (attribute(element, "AXPosition") as? NSValue)?.pointValue ?? .zero
    let size = (attribute(element, "AXSize") as? NSValue)?.sizeValue ?? .zero
    return CGRect(origin: origin, size: size)
}

struct Node {
    /// Carried so a node can be read further or written to without
    /// walking again. Attributes are NOT snapped here: each one is a
    /// synchronous round trip to the device.
    let element: NSObject
    let role: String
    let description: String
    let frame: CGRect
}

func flatten(_ element: NSObject, _ depth: Int = 0, into out: inout [Node]) {
    if out.count > 2000 || depth > 25 { return }
    out.append(Node(
        element: element,
        role: text(element, "AXRole"),
        description: text(element, "AXDescription"),
        frame: frame(element)))
    for child in children(element) { flatten(child, depth + 1, into: &out) }
}

// MARK: - the picker

/// What answered the presence probe: the readable root AND THE PID.
///
/// The pid is carried out because a hit test answers with whatever owns
/// the point, across processes (docs/traps.md), so this is evidence
/// about the picker only while the pid says so — and a sentence that
/// cannot name the process cannot tell a live sheet from SpringBoard
/// answering the same point.
struct PickerHit {
    let root: NSObject
    let pid: Int32
}

/// The host process behind a pid the hit test answered with. Simulator
/// apps are host processes, so this costs no bridge round trip.
func processName(_ pid: Int32) -> String {
    var buffer = [CChar](repeating: 0, count: 128)
    return proc_name(pid, &buffer, UInt32(buffer.count)) > 0
        ? String(cString: buffer) : "unnamed"
}

/// The picker's process, found by hit-testing the middle of the screen:
/// anything there belonging to a pid OTHER than the app under test is
/// the picker on top of it. Nil reads as "no picker is up".
func pickerRoot(_ sim: Simulator, appPid: Int32, screen: CGSize) -> PickerHit? {
    let probes = [
        CGPoint(x: screen.width / 2, y: screen.height / 2),
        CGPoint(x: screen.width / 2, y: screen.height / 3),
        CGPoint(x: screen.width / 2, y: screen.height * 2 / 3),
    ]
    for point in probes {
        guard let hit = sim.objectAtPoint(point),
            let pid = hit.value(forKey: "pid") as? Int32, pid != appPid
        else { continue }
        guard let appObject = sim.applicationObject(forPid: pid),
            let root = sim.element(for: appObject)
        else { continue }
        return PickerHit(root: root, pid: pid)
    }
    return nil
}

/// The app's own screen size in POINTS; the tap wants a ratio of it.
func screenSize(_ sim: Simulator) -> CGSize {
    guard let app = sim.frontmostApplication(), let element = sim.element(for: app) else {
        fail("no frontmost application to size the screen from")
    }
    let size = (attribute(element, "AXSize") as? NSValue)?.sizeValue ?? .zero
    guard size.width > 0, size.height > 0 else { fail("the frontmost application reported no size") }
    return size
}

/// A row's file name, from an accessibility description shaped
/// "<name>, <kind>, <time>, <size>". Returns the STEM: that name omits
/// the extension the picked URL carries (docs/traps.md), so callers
/// compare stems.
func rowName(_ node: Node) -> String? {
    guard node.role == "AXStaticText" else { return nil }
    let parts = node.description.split(separator: ",", omittingEmptySubsequences: false)
        .map { $0.trimmingCharacters(in: .whitespaces) }
    guard parts.count >= 3, !parts[0].isEmpty else { return nil }
    return parts[0]
}

func stem(_ name: String) -> String {
    (name as NSString).deletingPathExtension
}

/// Every element the navigation strip answers a HIT TEST with, as
/// (description, centre). Swept rather than walked because the picker's
/// element tree is shallow and the strip is not reachable from its root
/// (docs/traps.md), and across x as well as y because its controls sit
/// at both edges.
func navigationStrip(_ sim: Simulator, screen: CGSize) -> [(String, CGPoint)] {
    // The sweep is a FIXED number of hit tests, so its wall time is the
    // one direct reading of what the bridge is managing right now.
    let started = mark()
    var probes = 0
    var found: [(String, CGPoint)] = []
    var seen = Set<String>()
    let xs = stride(from: 12.0, through: screen.width - 12, by: 20.0)
    // 40..170 covers the whole chrome band: the controls sit at ~92, but
    // a single-select picker lays its dismissal out differently from a
    // multi-select one.
    for x in xs {
        for y in stride(from: 40.0, through: 170.0, by: 14.0) {
            let point = CGPoint(x: x, y: y)
            probes += 1
            guard let hit = sim.objectAtPoint(point), let element = sim.element(for: hit)
            else { continue }
            let description = text(element, "AXDescription")
            if description.isEmpty || seen.contains(description) { continue }
            seen.insert(description)
            let box = frame(element)
            let centre = box.isEmpty ? point : CGPoint(x: box.midX, y: box.midY)
            found.append((description, centre))
        }
    }
    note("strip", "ms=\(sinceMs(started)) probes=\(probes) controls=\(found.count)")
    return found
}

/// The directory the picker is showing, off the actions button that
/// names it ("kaya-picked-123, Actions Menu").
func currentDirectory(_ sim: Simulator, screen: CGSize) -> String {
    for (description, _) in navigationStrip(sim, screen: screen) {
        let parts = description.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        if parts.count >= 2, parts[1].hasPrefix("Actions Menu") { return parts[0] }
    }
    return ""
}

// MARK: - driving

/// A single tap, delivered through the legacy HID client. RAW BYTES, not
/// mirrored Swift structs: the wire layout is `#pragma pack(4)` and Swift
/// has no packed layout, so a struct mirror would mis-encode silently.
/// Offsets are from idb's Indigo.h.
final class Tapper {
    private let client: AnyObject
    private let messageForMouse: @convention(c) (
        UnsafeMutablePointer<CGPoint>?, UnsafeMutablePointer<CGPoint>?, Int32, Int32, ObjCBool
    ) -> UnsafeMutableRawPointer

    @objc protocol HIDClient {
        @objc(initWithDevice:error:)
        func initWithDevice(
            _ device: Any, error: AutoreleasingUnsafeMutablePointer<AnyObject?>?) -> AnyObject?
        @objc(sendWithMessage:freeWhenDone:completionQueue:completion:)
        func send(
            withMessage message: UnsafeMutableRawPointer, freeWhenDone: Bool,
            completionQueue: DispatchQueue, completion: @escaping (Error?) -> Void)
    }

    init(device: NSObject) {
        // By NAME and never as a type: this class has RELOCATED between
        // Xcode versions (docs/file-dialogs-plan.md §6e).
        guard let clientClass = objc_lookUpClass("SimulatorKit.SimDeviceLegacyHIDClient") else {
            fail("no SimDeviceLegacyHIDClient — it may have moved again in this Xcode")
        }
        let allocated = class_createInstance(clientClass as? AnyClass, 0) as AnyObject
        var error: AnyObject?
        guard let client = unsafeBitCast(allocated, to: HIDClient.self)
            .initWithDevice(device, error: &error)
        else { fail("the HID client would not attach: \(String(describing: error))") }
        self.client = client
        guard let symbol = dlsym(simulatorKitHandle, "IndigoHIDMessageForMouseNSEvent") else {
            fail("no IndigoHIDMessageForMouseNSEvent in SimulatorKit")
        }
        messageForMouse = unsafeBitCast(symbol, to: type(of: messageForMouse))
    }

    private func message(ratio: CGPoint, down: Bool) -> UnsafeMutableRawPointer {
        var point = ratio
        // SimulatorKit has no single-touch builder, so a valid digitizer
        // payload is sourced from the mouse one and re-enveloped.
        let source = messageForMouse(&point, nil, 0x32, down ? 1 : 2, ObjCBool(false))
        var x = ratio.x, y = ratio.y
        memcpy(source.advanced(by: 0x3c), &x, 8)  // xRatio, unaligned by packing
        memcpy(source.advanced(by: 0x44), &y, 8)  // yRatio

        let stride = 0x90
        guard let destination = calloc(1, 0x20 + stride * 2) else { fail("calloc") }
        var inner = UInt32(stride)
        memcpy(destination.advanced(by: 0x18), &inner, 4)
        var eventType = UInt8(2)  // IndigoEventTypeTouch
        memcpy(destination.advanced(by: 0x1c), &eventType, 1)
        var kind = UInt32(0x0000_000B)
        memcpy(destination.advanced(by: 0x20), &kind, 4)
        var timestamp = mach_absolute_time()
        memcpy(destination.advanced(by: 0x24), &timestamp, 8)
        memcpy(destination.advanced(by: 0x30), source.advanced(by: 0x30), 0x70)
        free(source)

        // The second contact: a copy of the first payload, marked.
        memcpy(destination.advanced(by: 0x20 + stride), destination.advanced(by: 0x20), stride)
        var one = UInt32(1), two = UInt32(2)
        memcpy(destination.advanced(by: 0x20 + stride + 0x10), &one, 4)
        memcpy(destination.advanced(by: 0x20 + stride + 0x14), &two, 4)
        return destination
    }

    /// WHAT THE SEND ANSWERED, rather than nothing: the completion
    /// carries an error and the wait can expire, and both used to be
    /// discarded — so "the tap was dropped" was a story no measurement
    /// here could contradict (docs/deferred.md's iOS-sheets WATCH entry).
    private func send(_ message: UnsafeMutableRawPointer) -> String {
        let sema = DispatchSemaphore(value: 0)
        var failure: Error? = nil
        unsafeBitCast(client, to: HIDClient.self).send(
            withMessage: message, freeWhenDone: true,
            completionQueue: DispatchQueue.global(), completion: { failure = $0; sema.signal() })
        if sema.wait(timeout: .now() + 10) == .timedOut { return "timeout" }
        if let failure { return "error:\(failure)" }
        return "ok"
    }

    func tap(at point: CGPoint, screen: CGSize) {
        let ratio = CGPoint(x: point.x / screen.width, y: point.y / screen.height)
        let started = mark()
        let down = send(message(ratio: ratio, down: true))
        let downMs = sinceMs(started)
        usleep(120_000)
        let upAt = mark()
        let up = send(message(ratio: ratio, down: false))
        tapsSent += 1
        note(
            "tap",
            "\(xy(point)) down=\(quoted(down)) down_ms=\(downMs) "
                + "up=\(quoted(up)) up_ms=\(sinceMs(upAt))")
    }
}

// MARK: - verbs

let arguments = CommandLine.arguments
guard arguments.count >= 4 else {
    fail(
        "usage: simdrive <udid> <app-pid> state|choose <name>|cancel|describe|press <label>"
            + "|savestate|savename <name>|savepress|savecancel")
}
let udid = arguments[1]
guard let appPid = Int32(arguments[2]) else { fail("app pid must be a number") }
let verb = arguments[3]
currentVerb = verb

// The fixed cost of getting ready — the translator singletons, the
// device lookup, and one bridge round trip for the screen size. It is
// paid once per harness verb and it grows first when the host is busy.
let attachAt = mark()
let sim = Simulator(udid: udid)
let attachMs = sinceMs(attachAt)
let screenAt = mark()
let screen = screenSize(sim)
note(
    "start",
    "app_pid=\(appPid) app_proc=\(processName(appPid)) attach_ms=\(attachMs) "
        + "screen_ms=\(sinceMs(screenAt)) "
        + "screen=\(String(format: "%.0fx%.0f", screen.width, screen.height))")

func pickerNodes() -> (pid: Int32, nodes: [Node])? {
    guard let hit = pickerRoot(sim, appPid: appPid, screen: screen) else { return nil }
    var nodes: [Node] = []
    flatten(hit.root, 0, into: &nodes)
    return (hit.pid, nodes)
}

/// Bounded: a read that arrives early reports "no dialog" for a dialog
/// that is on its way.
func waitForPicker(_ tries: Int = 20) -> [Node]? {
    let started = mark()
    for n in 0..<tries {
        if let found = pickerNodes(), found.nodes.count > 1 {
            note(
                "wait_picker",
                "ok=yes ms=\(sinceMs(started)) tries=\(n + 1) nodes=\(found.nodes.count) "
                    + "pid=\(found.pid) proc=\(processName(found.pid))")
            return found.nodes
        }
        usleep(300_000)
    }
    note("wait_picker", "ok=no ms=\(sinceMs(started)) tries=\(tries)")
    return nil
}

/// The picker EXISTING is not the picker being READABLE. It is a remote
/// view controller: it publishes its chrome — the nav strip, the
/// directory title, a container for the rows — as soon as it presents,
/// and fills in the row elements a moment later. waitForPicker's
/// `count > 1` is satisfied by the chrome alone, so a read that lands in
/// that window returns the right directory and NO ROWS, and the verb
/// reports an empty list for a picker that is showing two files.
///
/// It survived the first read only because presenting for the first
/// time is slow enough to hide it. The scene's SECOND presentation
/// reuses the already-warm service, and the race is wide open — which
/// is how the iOS lane went red on `expect_file_dialog` with every
/// assertion in the scene passing (2026-07-31).
///
/// So the row read waits for a ROW. A directory with none costs the
/// full budget and then answers honestly; every real one answers as
/// soon as the rows arrive.
func waitForRows(_ tries: Int = 20) -> [Node]? {
    let started = mark()
    var last: [Node]? = nil
    var chrome = "none"
    for n in 0..<tries {
        guard let nodes = waitForPicker() else {
            // The two ways this answers "no rows" are different states,
            // and only one of them is a race: nothing presented at all,
            // against a picker whose chrome is up and whose rows are not.
            note(
                "wait_rows",
                "ok=no why=no-picker ms=\(sinceMs(started)) tries=\(n + 1) "
                    + "chrome_ms=\(chrome) rows=\(last?.compactMap { rowName($0) }.count ?? 0)")
            return last
        }
        if chrome == "none" { chrome = "\(sinceMs(started))" }
        last = nodes
        let rows = nodes.compactMap { rowName($0) }.count
        if rows > 0 {
            note(
                "wait_rows",
                "ok=yes ms=\(sinceMs(started)) tries=\(n + 1) chrome_ms=\(chrome) rows=\(rows)")
            return nodes
        }
        usleep(300_000)
    }
    note(
        "wait_rows",
        "ok=no why=no-rows ms=\(sinceMs(started)) tries=\(tries) chrome_ms=\(chrome) rows=0")
    return last
}

func waitForPickerGone(_ tries: Int = 20) -> Bool {
    let started = mark()
    let timeoutsBefore = bridgeTimeouts
    var held: PickerHit? = nil
    for n in 0..<tries {
        let probe = mark()
        let hit = pickerRoot(sim, appPid: appPid, screen: screen)
        let probeMs = sinceMs(probe)
        if hit == nil {
            note(
                "wait_gone",
                "ok=yes ms=\(sinceMs(started)) tries=\(n + 1) probe_ms=\(probeMs) "
                    + "read_timeouts=\(bridgeTimeouts - timeoutsBefore)")
            return true
        }
        held = hit
        usleep(300_000)
    }
    note(
        "wait_gone",
        "ok=no ms=\(sinceMs(started)) tries=\(tries) "
            + "held_pid=\(held.map { "\($0.pid)" } ?? "none") "
            + "held_proc=\(held.map { processName($0.pid) } ?? "none") "
            + "read_timeouts=\(bridgeTimeouts - timeoutsBefore)")
    return false
}

/// WHO IS HOLDING THE SCREEN, for a failure sentence: the pid, the host
/// process behind it, and what that root says it is. Read only on a
/// failure path — each attribute is a bridge round trip.
func whoHoldsTheScreen() -> String {
    guard let hit = pickerRoot(sim, appPid: appPid, screen: screen) else {
        return "nothing but the app answers the centre hit test now"
    }
    let role = text(hit.root, "AXRole"), described = text(hit.root, "AXDescription")
    return "the centre hit test is answered by pid \(hit.pid) (\(processName(hit.pid)))"
        + ", whose root reads \(role.isEmpty ? "no role" : role)"
        + "/\(described.isEmpty ? "no description" : described)"
}

/// docs/deferred.md's iOS save-sheet WATCH tap-time discriminator.
func tapOwner(_ point: CGPoint) -> String {
    let translation = sim.objectAtPoint(point)
    let pid = translation?.value(forKey: "pid") as? Int32
    let element = translation.flatMap { sim.element(for: $0) }
    let role = element.map { text($0, "AXRole") } ?? ""
    let described = element.map { text($0, "AXDescription") } ?? ""
    return "tap_pid=\(pid.map(String.init) ?? "none") "
        + "tap_proc=\(pid.map(processName) ?? "none") "
        + "tap_role=\(role.isEmpty ? "none" : role) "
        + "tap_desc=\(described.isEmpty ? "none" : described)"
}

// MARK: - the save sheet

/// The export sheet's name fields, BY ROLE. The field publishes no
/// description of its own — the words "Save as" belong to a static text
/// beside it (measured, docs/probes/save-probe-ios.md B.4) — so there is
/// no label to match on, and role is what is left.
func nameFields(_ nodes: [Node]) -> [Node] {
    nodes.filter { $0.role == "AXTextField" && !$0.frame.isEmpty }
}

/// The export sheet, waited for BY ITS FIELD — the same
/// chrome-before-content race waitForRows spells out, and the same cost
/// if it is skipped.
func waitForSaveSheet(_ tries: Int = 20) -> [Node]? {
    let started = mark()
    var last: [Node]? = nil
    var chrome = "none"
    for n in 0..<tries {
        guard let nodes = waitForPicker() else {
            note(
                "wait_save_sheet",
                "ok=no why=no-picker ms=\(sinceMs(started)) tries=\(n + 1) "
                    + "chrome_ms=\(chrome) fields=\(last.map { nameFields($0).count } ?? 0)")
            return last
        }
        if chrome == "none" { chrome = "\(sinceMs(started))" }
        last = nodes
        let fields = nameFields(nodes).count
        if fields > 0 {
            note(
                "wait_save_sheet",
                "ok=yes ms=\(sinceMs(started)) tries=\(n + 1) chrome_ms=\(chrome) fields=\(fields)")
            return nodes
        }
        usleep(300_000)
    }
    note(
        "wait_save_sheet",
        "ok=no why=no-field ms=\(sinceMs(started)) tries=\(tries) chrome_ms=\(chrome) fields=0")
    return last
}

/// The one name field, or a refusal naming what was there instead.
func theNameField(_ nodes: [Node], _ doing: String) -> Node {
    let fields = nameFields(nodes)
    guard fields.count == 1 else {
        let listed = nodes.map { "\($0.role) \($0.description)" }.filter { !$0.isEmpty }
        fail(
            "\(doing): the save dialog publishes \(fields.count) text fields, not one; "
                + "it shows \(listed)")
    }
    return fields[0]
}

/// Press the sheet's own dismissal and require it to be gone. There is
/// NO Cancel when the browser is aimed into a subdirectory, so this walks
/// back until one exists; the back control is identified by POSITION,
/// because its label is the presenting app's name (docs/traps.md).
func cancelSheet(_ what: String) {
    let started = mark()
    let tapper = Tapper(device: sim.device)
    var cancelled = false
    var rounds = 0
    for _ in 0..<5 {
        rounds += 1
        let strip = navigationStrip(sim, screen: screen)
        if let (_, centre) = strip.first(where: { $0.0.hasPrefix("Cancel") }) {
            let owner = tapOwner(centre)
            note("cancel_round", "n=\(rounds) found=cancel \(xy(centre)) \(owner)")
            tapper.tap(at: centre, screen: screen)
            cancelled = true
            break
        }
        guard let back = strip.filter({ $0.1.y < 120 }).min(by: { $0.1.x < $1.1.x })
        else {
            note("cancel_round", "n=\(rounds) found=nothing controls=\(strip.count)")
            break
        }
        let owner = tapOwner(back.1)
        note("cancel_round", "n=\(rounds) found=back \(xy(back.1)) \(owner)")
        tapper.tap(at: back.1, screen: screen)
        usleep(600_000)
    }
    if !cancelled {
        let strip = navigationStrip(sim, screen: screen).map { $0.0 }
        fail(
            "no Cancel reachable from the \(what) after \(rounds) rounds across "
                + "\(sinceMs(started))ms; it offers \(strip)")
    }
    if !waitForPickerGone() {
        fail(
            "the \(what) was still up \(sinceMs(started))ms after cancelling it in round "
                + "\(rounds): \(whoHoldsTheScreen())")
    }
}

switch verb {
case "navstrip":
    // Diagnosis: what the navigation strip offers right now.
    guard waitForPicker() != nil else { print("no picker"); exit(0) }
    for (description, centre) in navigationStrip(sim, screen: screen) {
        print("\(description)\t\(NSStringFromPoint(centre))")
    }

case "describe":
    guard let nodes = waitForPicker() else { print("no picker"); exit(0) }
    for node in nodes {
        print("\(node.role)\t\(node.description)\t\(NSStringFromRect(node.frame))")
    }

case "state":
    // `<directory>` then one row name per line, for expect_file_dialog.
    // Empty output means no picker is up, which must FAIL that verb.
    guard let nodes = waitForRows() else { exit(0) }
    print(currentDirectory(sim, screen: screen))
    for node in nodes { if let name = rowName(node) { print(name) } }

case "choose":
    guard arguments.count >= 5 else { fail("choose needs a name") }
    let wanted = stem(arguments[4])
    guard let nodes = waitForRows() else { fail("no picker is up to choose \(wanted) from") }
    guard let row = nodes.first(where: { rowName($0).map { stem($0) == wanted } ?? false }) else {
        let listed = nodes.compactMap { rowName($0) }
        fail("no row named \(wanted); the picker lists \(listed)")
    }
    // The picker being gone is the proof a tap landed: one arriving
    // before the list is interactive is swallowed with no error, and a
    // swallowed tap and a slow dismissal are the same silence — so the
    // WHOLE select-confirm round retries, savepress's rule (measured
    // under the concurrent matrix, 2026-08-20: filedialog-go's row tap
    // dropped the run after save-go's Save tap was; docs/deferred.md's
    // WATCH entry). Rows are RE-WALKED each round, because what went
    // stale may be the frame rather than the tap; single-selection
    // answers on the row, multi-selection needs the strip's confirm
    // (docs/traps.md), and the rounds converge for both — a re-tap
    // that deselects a landed selection is corrected one round later.
    let chooseStarted = mark()
    let tapper = Tapper(device: sim.device)
    var lastCentre = CGPoint(x: row.frame.midX, y: row.frame.midY)
    var pickerDismissed = false
    var rounds = 0
    var rowOffered = 0
    var rowCentres = Set<String>()
    // Six rounds, savepress's 2026-08-20 raise: the stalled-runloop
    // class holds a sheet through ~18s of taps and polling.
    while rounds < 6 && !pickerDismissed {
        rounds += 1
        let roundAt = mark()
        let walkAt = mark()
        let fresh = pickerNodes()?.nodes
            .first(where: { rowName($0).map { stem($0) == wanted } ?? false })
        let walkMs = sinceMs(walkAt)
        if let fresh {
            rowOffered += 1
            lastCentre = CGPoint(x: fresh.frame.midX, y: fresh.frame.midY)
            rowCentres.insert(String(format: "%.0f,%.0f", lastCentre.x, lastCentre.y))
            tapper.tap(at: lastCentre, screen: screen)
        }
        var confirmed = "not-needed"
        if !waitForPickerGone(6) {
            let strip = navigationStrip(sim, screen: screen)
            if let (_, confirm) = strip.first(where: {
                $0.0.hasPrefix("Open") || $0.0.hasPrefix("Done")
            }) {
                confirmed = "tapped"
                tapper.tap(at: confirm, screen: screen)
            } else {
                confirmed = "absent"
            }
        }
        pickerDismissed = waitForPickerGone()
        // THIS ROUND'S centre, as in savepress: a round whose re-walk
        // found no row tapped nowhere.
        note(
            "choose_round",
            "n=\(rounds) walk_ms=\(walkMs) row=\(fresh == nil ? "absent" : "offered") "
                + "\(fresh.map { xy(CGPoint(x: $0.frame.midX, y: $0.frame.midY)) } ?? "x=none y=none") "
                + "confirm=\(confirmed) "
                + "gone=\(pickerDismissed ? "yes" : "no") round_ms=\(sinceMs(roundAt))")
    }

    // The failure carries the numbers because a miss and a swallowed
    // press look identical from here.
    if !pickerDismissed {
        let held = whoHoldsTheScreen()
        let after = pickerNodes()?.nodes.compactMap { rowName($0) } ?? []
        let strip = navigationStrip(sim, screen: screen).map { $0.0 }
        fail(
            "the picker was still up after \(rounds) rounds of choosing \(wanted) across "
                + "\(sinceMs(chooseStarted))ms: the row was offered in \(rowOffered) of them, "
                + "at \(rowCentres.count == 1 ? "one fixed centre" : "\(rowCentres.count) centres") "
                + "\(rowCentres.sorted()) of a \(screen) screen; \(held); it now lists \(after) "
                + "and offers \(strip)")
    }

case "cancel":
    guard waitForPicker() != nil else { fail("no picker is up to cancel") }
    cancelSheet("picker")

case "savestate":
    // `<directory>` then the name in the "Save as" field, for
    // expect_save_dialog. Empty output means no save sheet is up, which
    // must FAIL that verb. Both halves matter: the directory alone would
    // pass for a sheet that ignored the name it was told.
    guard let nodes = waitForSaveSheet(), !nameFields(nodes).isEmpty else { exit(0) }
    print(currentDirectory(sim, screen: screen))
    print(text(theNameField(nodes, "savestate").element, "AXValue"))

case "savename":
    // Sets the accessibility VALUE and READS IT BACK: a set that routes
    // nowhere looks identical from here (docs/save-plan.md D4).
    //
    // AND THE SET IS RETRIED, NOT ONLY THE READ. Measured 2026-08-09
    // against a live export sheet: twenty-three drives took the name
    // first time, and two consecutive ones — on a machine also running
    // an iOS lane — did not take it at all. Not slowly: the field still
    // read the SUGGESTED name three seconds later, and the sheet went on
    // to export under that name, so the leg would have been green about
    // the wrong file if the read-back were not there. From this side a
    // dropped set and a slow one are the same silence, so the loop sets
    // AGAIN rather than waiting longer, and walks the tree again first
    // in case what went stale was the element rather than the set.
    // Setting the same value twice is idempotent; a leg that fails once
    // a matrix is not.
    guard arguments.count >= 5 else { fail("savename needs a name") }
    let wanted = arguments[4...].joined(separator: " ")
    let nameStarted = mark()
    var settled = ""
    var attempts = 0
    while attempts < 5 && settled != wanted {
        attempts += 1
        guard let nodes = waitForSaveSheet(), !nameFields(nodes).isEmpty else {
            fail("no save dialog is up to name \(wanted)")
        }
        let field = theNameField(nodes, "savename")
        guard setAttribute(field.element, "AXValue", wanted) else {
            fail("the save dialog's name field does not answer the accessibility setter")
        }
        let settleAt = mark()
        var reads = 0
        for _ in 0..<20 {
            reads += 1
            settled = text(field.element, "AXValue")
            if settled == wanted { break }
            usleep(150_000)
        }
        note(
            "savename_try",
            "n=\(attempts) took=\(settled == wanted ? "yes" : "no") reads=\(reads) "
                + "settle_ms=\(sinceMs(settleAt))")
    }
    guard settled == wanted else {
        fail(
            "the save dialog's name field reads \"\(settled)\" after \(attempts) attempts "
                + "to set it to \"\(wanted)\" across \(sinceMs(nameStarted))ms")
    }

case "savepress":
    // The real Save button is in the navigation strip and nowhere else,
    // and the match is EXACT: `press Save` falsely succeeds here on the
    // static text "Save as" (docs/deferred.md), and a prefix match lands
    // on "<App>, Actions Menu" and opens a context menu (measured).
    //
    // AND THE TAP IS RETRIED, NOT ONLY WAITED FOR — savename's measured
    // rule, one gesture over: under a concurrent five-lane matrix the
    // HID tap is dropped the way the AX set was (save-go, twice on
    // 2026-08-20 — Save tapped at its real centre, sheet still up,
    // 102/102 solo on either side; docs/deferred.md's WATCH entry).
    // A dropped tap and a slow dismissal are the same silence, so the
    // loop walks the strip AGAIN each round — a strip that no longer
    // offers Save means the sheet is already going, and tapping there
    // anyway would land on the app behind it, so that round only polls.
    // SIX rounds since 2026-08-20: the WATCH entry's predicted branch
    // fired — save-go under the full matrix, Save present and
    // STATIONARY in the strip after three centred taps across ~18s of
    // dismissal polling, which convicts a starved sim's stalled
    // runloop, not a dropped gesture. More rounds are free when
    // healthy (the first exits as soon as the sheet goes) and give a
    // stalled runloop ~36s to catch up.
    guard waitForSaveSheet() != nil else { fail("no save dialog is up to save") }
    let pressStarted = mark()
    var presses = 0
    var saveOffered = 0
    var saveCentres = Set<String>()
    var sheetGone = false
    while presses < 6 && !sheetGone {
        presses += 1
        let roundAt = mark()
        let stripAt = mark()
        let strip = navigationStrip(sim, screen: screen)
        let stripMs = sinceMs(stripAt)
        var tapped = "no-save-in-strip"
        var roundOwner = "tap_owner=not-tapped"
        // THIS ROUND'S centre, not the last one seen: a round that found
        // no Save tapped nowhere, and printing the previous round's
        // coordinate is a claim nothing measured.
        var roundCentre: CGPoint? = nil
        if let (_, saveCentre) = strip.first(where: { $0.0 == "Save" }) {
            roundCentre = saveCentre
            saveOffered += 1
            saveCentres.insert(String(format: "%.0f,%.0f", saveCentre.x, saveCentre.y))
            tapped = "tapped"
            roundOwner = tapOwner(saveCentre)
            Tapper(device: sim.device).tap(at: saveCentre, screen: screen)
        } else if presses == 1 {
            fail("no Save in the navigation strip; it offers \(strip.map { $0.0 })")
        }
        // The sheet being gone is the proof, as in `choose`.
        sheetGone = waitForPickerGone()
        note(
            "save_round",
            "n=\(presses) strip_ms=\(stripMs) controls=\(strip.count) save=\(tapped) "
                + "\(roundCentre.map { xy($0) } ?? "x=none y=none") "
                + "\(roundOwner) "
                + "gone=\(sheetGone ? "yes" : "no") round_ms=\(sinceMs(roundAt))")
    }
    if !sheetGone {
        let held = whoHoldsTheScreen()
        // The tenth sighting's discriminator: six delivered-and-ignored
        // HID taps say nothing about WHY. One AX-press at the same
        // centre splits the two remaining stories — the leg fails either
        // way, so nothing is laundered; the sentence just learns which.
        var axProbe = "ax-press: no element at the Save centre"
        if let centreString = saveCentres.sorted().first,
            let comma = centreString.firstIndex(of: ","),
            let cx = Double(centreString[..<comma]),
            let cy = Double(centreString[centreString.index(after: comma)...]),
            let hit = sim.objectAtPoint(CGPoint(x: cx, y: cy)),
            let element = sim.element(for: hit)
        {
            if performAXPress(element) {
                let goneAfter = waitForPickerGone(6)
                axProbe =
                    "ax-press on \(text(element, "AXDescription")) "
                    + (goneAfter
                        ? "DISMISSED the sheet the taps could not — the input path is the wedge"
                        : "was also ignored — the button itself is inert")
            } else {
                axProbe = "ax-press: the element takes no actions"
            }
        }
        let after = navigationStrip(sim, screen: screen).map { $0.0 }
        fail(
            "the save dialog was still up after \(presses) presses of Save across "
                + "\(sinceMs(pressStarted))ms: Save was in the strip for \(saveOffered) of them, "
                + "at \(saveCentres.count == 1 ? "one fixed centre" : "\(saveCentres.count) centres") "
                + "\(saveCentres.sorted()) of a \(screen) screen; \(held); \(axProbe); "
                + "it now offers \(after)")
    }

case "savecancel":
    guard waitForSaveSheet() != nil else { fail("no save dialog is up to cancel") }
    cancelSheet("save dialog")

case "press":
    // Tap a control by its accessibility description, wherever it lives:
    // the hit-test overlay first, then the invoked pid's own tree. The
    // paste-permission alert is the customer (docs/clipboard-plan.md).
    guard arguments.count >= 5 else { fail("press needs a label") }
    let label = arguments[4...].joined(separator: " ")
    var pressed = false
    for _ in 0..<20 {
        // BOTH TREES, EVERY TIME: each goes blind in a state the other
        // answers in (docs/clipboard-plan.md §2).
        var nodes: [Node] = []
        var home = "overlay"
        if let overlay = pickerRoot(sim, appPid: appPid, screen: screen) {
            flatten(overlay.root, 0, into: &nodes)
        }
        if !nodes.contains(where: { $0.description.contains(label) }),
            let appObject = sim.applicationObject(forPid: appPid),
            let root = sim.element(for: appObject)
        {
            home = "app"
            nodes = []
            flatten(root, 0, into: &nodes)
        }
        let exact = nodes.first { $0.description == label && !$0.frame.isEmpty }
        // Shortest match, not first: on the paste alert both buttons
        // contain "Allow Paste" and tree order puts the denial first.
        let loose = nodes.filter { $0.description.contains(label) && !$0.frame.isEmpty }
            .min { $0.description.count < $1.description.count }
        if let hit = exact ?? loose {
            // NEVER TAP A MOVING TARGET: an alert reports its buttons'
            // FINAL frames while still animating in. Two identical reads
            // 300ms apart are the proof it has settled
            // (docs/clipboard-plan.md §2).
            usleep(300_000)
            var settledNodes: [Node] = []
            if let overlay = pickerRoot(sim, appPid: appPid, screen: screen) {
                flatten(overlay.root, 0, into: &settledNodes)
            }
            if !settledNodes.contains(where: { $0.description.contains(label) }),
                let appObject = sim.applicationObject(forPid: appPid),
                let root = sim.element(for: appObject)
            {
                settledNodes = []
                flatten(root, 0, into: &settledNodes)
            }
            let settled = settledNodes.first {
                $0.description == hit.description && $0.frame == hit.frame
            }
            guard settled != nil else { continue }
            let centre = CGPoint(x: hit.frame.midX, y: hit.frame.midY)
            Tapper(device: sim.device).tap(at: centre, screen: screen)
            print("pressed \(hit.role)\t\(hit.description)\t\(NSStringFromRect(hit.frame))\tin \(home)")
            pressed = true
            break
        }
        usleep(300_000)
    }
    if !pressed {
        var nodes: [Node] = []
        if let overlay = pickerRoot(sim, appPid: appPid, screen: screen) {
            flatten(overlay.root, 0, into: &nodes)
        }
        let listed = nodes.map { $0.description }.filter { !$0.isEmpty }
        fail("nothing labeled \(label) to press; the overlay offers \(listed)")
    }

default:
    fail("unknown verb \(verb)")
}
