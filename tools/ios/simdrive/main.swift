// simdrive — the harness's eyes and hands OUTSIDE the app, on iOS.
//
// Android needed an accessibility service to reach DocumentsUI because
// the picker is a separate APK. iOS needs the same thing for the same
// reason and cannot have it: `UIDocumentPickerViewController` is a
// REMOTE view controller, its content lives in another process, and an
// app has no way to become an assistive client. Measured
// (docs/traps.md): in-process the picker publishes zero accessibility
// elements, and its one in-process affordance — the Cancel tracking
// view — refuses `accessibilityActivate()`.
//
// So the eyes go on the HOST, where the simulator's own frameworks
// expose both halves. Everything below is private framework shipped
// inside Xcode, and it is the same surface `simctl` itself talks to.
//
//   READING   SimServiceContext -> SimDevice for the UDID
//             device.accessibilityPlatformTranslationToken
//             AXPTranslator, whose bridgeTokenDelegate fulfils each
//             AXPTranslatorRequest through
//             -[SimDevice sendAccessibilityRequestAsync:...]
//             objectAtPoint: to learn the picker's pid, then
//             translationApplicationObjectForPid: for its root, then
//             AXPMacPlatformElement to read the tree.
//
//   DRIVING   IndigoHIDMessageForMouseNSEvent sources a digitizer
//             payload; it is re-enveloped as a single-touch message and
//             sent to SimulatorKit.SimDeviceLegacyHIDClient.
//
// FOUR THINGS THAT LOOK LIKE FAILURE AND ARE NOT, all measured, all
// costly to rediscover:
//
//  1. `frontmostApplication` returns THE APP, and its AXChildren are
//     empty — because the picker is a different process sitting on top
//     of it. The app is not the thing to read.
//  2. Translated elements expose NO AXParent, so you cannot climb out
//     of a hit test. The only way in is by pid.
//  3. AXPMacPlatformElement is a LEGACY accessibility element. It
//     answers -accessibilityAttributeValue:; the modern
//     accessibilityLabel/accessibilityChildren properties return
//     nothing and look exactly like an empty tree.
//  4. The bridge delegate must go on EVERY AXPTranslator singleton.
//     With it on only one, the first fetch works and every attribute
//     read afterwards silently returns nothing.
//
// And one that is not a failure at all: the row's accessibility
// description omits the file extension ("picked, Text file, 12 bytes")
// while the PICKED URL carries it in full ("picked.txt"). Rows are
// therefore matched on the stem — see `rowName`.
import CoreGraphics
import Foundation
import ObjectiveC

// MARK: - plumbing

func fail(_ s: String) -> Never {
    FileHandle.standardError.write(Data(("simdrive: " + s + "\n").utf8))
    exit(1)
}

// Either name: the runner already exports DEVELOPER_DIR to reach simctl,
// and a caller outside it can say KAYA_SIMDRIVE_DEVELOPER_DIR instead.
// Both resolve to the same Xcode; requiring the private one would make
// this fail inside the lane for no reason.
let environment = ProcessInfo.processInfo.environment
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
    /// Set once the translator exists; the reset below needs it.
    weak var translator: NSObject?
    init(device: NSObject) { self.device = device }

    @objc(accessibilityTranslationDelegateBridgeCallbackWithToken:)
    func callback(withToken token: String) -> (@convention(block) (AnyObject) -> AnyObject?) {
        { [device, weak self] request in
            let sema = DispatchSemaphore(value: 0)
            var out: AnyObject?
            unsafeBitCast(device, to: SimDeviceAccessibility.self)
                .sendAccessibilityRequestAsync(
                    request, completionQueue: DispatchQueue.global(),
                    completionHandler: { out = $0; sema.signal() })
            _ = sema.wait(timeout: .now() + 20)
            // EVERY RESPONSE MUST BE RETIRED, and forgetting costs
            // something that looks nothing like a leak: the reads keep
            // working, and the next TAP is ignored. Measured — a tap
            // with no reads before it lands, the same tap after a tree
            // walk does not. idb pops each request's token for the same
            // reason; this is that pop.
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
        // EVERY singleton, see note 4 in the header.
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

// MARK: - reading elements (the LEGACY api, see note 3)

func attribute(_ element: NSObject, _ name: String) -> Any? {
    let sel = NSSelectorFromString("accessibilityAttributeValue:")
    guard element.responds(to: sel) else { return nil }
    return element.perform(sel, with: name)?.takeUnretainedValue()
}

func text(_ element: NSObject, _ name: String) -> String {
    (attribute(element, name) as? String) ?? ""
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
    let role: String
    let description: String
    let frame: CGRect
}

func flatten(_ element: NSObject, _ depth: Int = 0, into out: inout [Node]) {
    if out.count > 2000 || depth > 25 { return }
    out.append(Node(
        role: text(element, "AXRole"),
        description: text(element, "AXDescription"),
        frame: frame(element)))
    for child in children(element) { flatten(child, depth + 1, into: &out) }
}

// MARK: - the picker

/// The picker's process, found by hit-testing the middle of the screen:
/// anything there belonging to a pid OTHER than the app under test is
/// the picker sitting on top of it. Nil when the app itself answers,
/// which is how "no picker is up" reads.
func pickerRoot(_ sim: Simulator, appPid: Int32, screen: CGSize) -> NSObject? {
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
        return root
    }
    return nil
}

/// The app's own screen size in POINTS, read off its application element
/// rather than assumed, because the tap wants a ratio of it.
func screenSize(_ sim: Simulator) -> CGSize {
    guard let app = sim.frontmostApplication(), let element = sim.element(for: app) else {
        fail("no frontmost application to size the screen from")
    }
    let size = (attribute(element, "AXSize") as? NSValue)?.sizeValue ?? .zero
    guard size.width > 0, size.height > 0 else { fail("the frontmost application reported no size") }
    return size
}

/// A row's file name, from an accessibility description shaped
/// "<name>, <kind>, <time>, <size>".
///
/// THE EXTENSION IS ABSENT from that name — the picker publishes
/// "picked", never "picked.txt", though the URL it finally answers with
/// carries the extension in full (measured). So this returns the STEM,
/// and callers compare stems. The scene still proves it picked the right
/// file, because it reads the file's BYTES and the decoy's differ.
func rowName(_ node: Node) -> String? {
    guard node.role == "AXStaticText" else { return nil }
    let parts = node.description.split(separator: ",", omittingEmptySubsequences: false)
        .map { $0.trimmingCharacters(in: .whitespaces) }
    // A row carries name/kind/time/size; the list's own "2 items"
    // footer, and every label like it, has no commas at all.
    guard parts.count >= 3, !parts[0].isEmpty else { return nil }
    return parts[0]
}

func stem(_ name: String) -> String {
    (name as NSString).deletingPathExtension
}

/// The directory the picker is showing, off the actions button that
/// names it ("kaya-picked-123, Actions Menu").
///
/// BY HIT TEST, not by walking the tree: the tree hanging off the
/// picker's application object is SHALLOW — it carries the file rows and
/// the tab bar and stops. The navigation bar that names the directory is
/// not a child of anything reachable from there, but it answers a hit
/// test perfectly well (measured). So the title strip is probed
/// directly.
/// Every element the navigation strip answers a hit test with, as
/// (description, centre). The strip is swept rather than walked for the
/// reason above, and across x as well as y because its controls sit at
/// both edges.
func navigationStrip(_ sim: Simulator, screen: CGSize) -> [(String, CGPoint)] {
    var found: [(String, CGPoint)] = []
    var seen = Set<String>()
    let xs = stride(from: 12.0, through: screen.width - 12, by: 20.0)
    // 40..170: the whole chrome band. The strip's controls sit at ~92,
    // but a single-select picker lays its dismissal out differently from
    // a multi-select one, and a sweep pinned to one row finds only the
    // shape it was written against.
    for x in xs {
        for y in stride(from: 40.0, through: 170.0, by: 14.0) {
            let point = CGPoint(x: x, y: y)
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
    return found
}

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

/// A single tap, built the way SimulatorKit builds one and delivered
/// through the legacy HID client.
///
/// RAW BYTES, not mirrored Swift structs: the wire layout is
/// `#pragma pack(4)` and Swift has no packed layout, so a struct mirror
/// would mis-encode silently. Offsets are from idb's Indigo.h.
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
        // Looked up by NAME and never referenced as a type: idb records
        // that this class has RELOCATED between Xcode versions
        // (SimulatorKit -> CoreDeviceIO), and a link-time reference
        // would pin it to whichever framework held it that year.
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
        // SimulatorKit has no single-touch builder — its mouse builder
        // always emits multi-touch — so a valid digitizer payload is
        // sourced from it and re-enveloped as a single-touch message.
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

    private func send(_ message: UnsafeMutableRawPointer) {
        let sema = DispatchSemaphore(value: 0)
        unsafeBitCast(client, to: HIDClient.self).send(
            withMessage: message, freeWhenDone: true,
            completionQueue: DispatchQueue.global(), completion: { _ in sema.signal() })
        _ = sema.wait(timeout: .now() + 10)
    }

    func tap(at point: CGPoint, screen: CGSize) {
        let ratio = CGPoint(x: point.x / screen.width, y: point.y / screen.height)
        send(message(ratio: ratio, down: true))
        usleep(120_000)
        send(message(ratio: ratio, down: false))
    }
}

// MARK: - verbs

let arguments = CommandLine.arguments
guard arguments.count >= 4 else {
    fail("usage: simdrive <udid> <app-pid> state|choose <name>|cancel|describe")
}
let udid = arguments[1]
guard let appPid = Int32(arguments[2]) else { fail("app pid must be a number") }
let verb = arguments[3]

let sim = Simulator(udid: udid)
let screen = screenSize(sim)

func pickerNodes() -> [Node]? {
    guard let root = pickerRoot(sim, appPid: appPid, screen: screen) else { return nil }
    var nodes: [Node] = []
    flatten(root, 0, into: &nodes)
    return nodes
}

/// Bounded: the picker takes a moment to come up, and a read that
/// arrives early reports "no dialog" for a dialog that is on its way.
func waitForPicker(_ tries: Int = 20) -> [Node]? {
    for _ in 0..<tries {
        if let nodes = pickerNodes(), nodes.count > 1 { return nodes }
        usleep(300_000)
    }
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
    var last: [Node]? = nil
    for _ in 0..<tries {
        guard let nodes = waitForPicker() else { return last }
        last = nodes
        if nodes.contains(where: { rowName($0) != nil }) { return nodes }
        usleep(300_000)
    }
    return last
}

func waitForPickerGone(_ tries: Int = 20) -> Bool {
    for _ in 0..<tries {
        if pickerRoot(sim, appPid: appPid, screen: screen) == nil { return true }
        usleep(300_000)
    }
    return false
}

switch verb {
case "navstrip":
    // Diagnosis: what the navigation strip offers right now. The strip
    // is where Cancel and the multi-select confirm live, and neither is
    // reachable by walking the tree.
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
    // `<directory>` then one row name per line — what expect_file_dialog
    // reads. Empty output means no picker is up, which must FAIL that
    // verb rather than pass it quietly.
    guard let nodes = waitForRows() else { exit(0) }
    print(currentDirectory(sim, screen: screen))
    for node in nodes { if let name = rowName(node) { print(name) } }

case "choose":
    guard arguments.count >= 5 else { fail("choose needs a name") }
    let wanted = stem(arguments[4])
    // waitForRows and not waitForPicker, for the reason spelled out
    // there: the chrome arrives before the rows, and looking for a
    // named row in that window fails with "the picker lists []".
    guard let nodes = waitForRows() else { fail("no picker is up to choose \(wanted) from") }
    guard let row = nodes.first(where: { rowName($0).map { stem($0) == wanted } ?? false }) else {
        let listed = nodes.compactMap { rowName($0) }
        fail("no row named \(wanted); the picker lists \(listed)")
    }
    let centre = CGPoint(x: row.frame.midX, y: row.frame.midY)
    let tapper = Tapper(device: sim.device)
    tapper.tap(at: centre, screen: screen)

    // TWO INTERACTIONS, not one, and the scene needs both: with
    // `pick_file()` the tap IS the answer and the picker leaves; with
    // `pick_files()` the tap SELECTS and a confirm appears in the
    // navigation strip (measured: "Open" replaces "Cancel", and a
    // Select All / Deselect All bar appears at the foot). So the picker
    // going away is what tells the two apart, rather than a flag this
    // side would have to be told.
    if !waitForPickerGone(6) {
        let strip = navigationStrip(sim, screen: screen)
        if let (_, confirm) = strip.first(where: {
            $0.0.hasPrefix("Open") || $0.0.hasPrefix("Done")
        }) {
            tapper.tap(at: confirm, screen: screen)
        }
    }

    // THE PICKER BEING GONE IS THE PROOF the tap landed. A tap that
    // arrives before the list is interactive is swallowed with no error
    // anywhere — the same rule every other backend needed.
    //
    // SELF-DIAGNOSING when it does not: a miss and a swallowed press
    // look identical from here, and the numbers are the only way to
    // tell them apart — so they go in the message rather than into a
    // debugging session.
    if !waitForPickerGone() {
        let after = pickerNodes()?.compactMap { rowName($0) } ?? []
        let strip = navigationStrip(sim, screen: screen).map { $0.0 }
        fail(
            "the picker was still up after choosing \(wanted): tapped \(centre) "
                + "(row frame \(row.frame)) of a \(screen) screen; it now lists \(after) "
                + "and offers \(strip)")
    }

case "cancel":
    guard waitForPicker() != nil else { fail("no picker is up to cancel") }
    let tapper = Tapper(device: sim.device)
    // NO CANCEL BUTTON WHEN THE PICKER IS AIMED INTO A SUBDIRECTORY.
    // Measured: a single-selection picker opened at a directory shows a
    // BACK chevron where a Cancel would be, and only the provider's
    // root carries Cancel. (A multi-selection picker carries it
    // throughout, which is why this looked like it worked.) So walk
    // back until the dismissal exists, the way a person would, and
    // press it.
    //
    // The back control's accessibility label is the PRESENTING APP'S
    // NAME, not "Back" — so it is identified by position, as the
    // leftmost thing in the strip, rather than by a word that changes
    // with whatever bundle is under test.
    var cancelled = false
    for _ in 0..<5 {
        let strip = navigationStrip(sim, screen: screen)
        if let (_, centre) = strip.first(where: { $0.0.hasPrefix("Cancel") }) {
            tapper.tap(at: centre, screen: screen)
            cancelled = true
            break
        }
        guard let back = strip.filter({ $0.1.y < 120 }).min(by: { $0.1.x < $1.1.x })
        else { break }
        tapper.tap(at: back.1, screen: screen)
        usleep(600_000)
    }
    if !cancelled {
        let strip = navigationStrip(sim, screen: screen).map { $0.0 }
        fail("no Cancel reachable from the picker; it offers \(strip)")
    }
    if !waitForPickerGone() { fail("the picker was still up after cancelling") }

default:
    fail("unknown verb \(verb)")
}
