// Range stacking probe (docs/range-plan.md §4.2, §4.3, mac arm).
// Everything is driven by events posted into THIS process's own queue.
import AppKit
import ApplicationServices

setvbuf(stdout, nil, _IOLBF, 0)
func log(_ s: String) { print(s); fflush(stdout) }

final class TrackOnlyKnobCell: NSSliderCell {
    override func drawBar(inside rect: NSRect, flipped: Bool) {}
    override func startTracking(at p: NSPoint, in v: NSView) -> Bool { log("   cell startTracking pressed=\(NSEvent.pressedMouseButtons)"); return super.startTracking(at: p, in: v) }
    override func continueTracking(last: NSPoint, current: NSPoint, in v: NSView) -> Bool { let r = super.continueTracking(last: last, current: current, in: v); log("   cell continueTracking \(current) -> \(r)"); return r }
    override func stopTracking(last: NSPoint, current: NSPoint, in v: NSView, mouseIsUp: Bool) { log("   cell stopTracking up=\(mouseIsUp)"); super.stopTracking(last: last, current: current, in: v, mouseIsUp: mouseIsUp) }
}

final class ProbeSlider: NSSlider {
    var name = ""
    override class var cellClass: AnyClass? {
        get { TrackOnlyKnobCell.self }
        set {}
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    var tracked = 0
    override func mouseDown(with event: NSEvent) {
        tracked += 1
        log("mouseDown reached \(name)")
        super.mouseDown(with: event)
        log("mouseDown returned \(name)")
    }
    override func moveUp(_ sender: Any?) { log("   moveUp on \(name)"); super.moveUp(sender) }
    override func mouseDragged(with event: NSEvent) { log("   stray mouseDragged on \(name)"); super.mouseDragged(with: event) }
}

var gap = 1.0
var fakeButtons = 0
final class Swz: NSObject {
    @objc class func kayaPressed() -> Int { fakeButtons }
}
do {
    let orig = class_getClassMethod(NSEvent.self, #selector(getter: NSEvent.pressedMouseButtons))!
    let repl = class_getClassMethod(Swz.self, #selector(Swz.kayaPressed))!
    method_exchangeImplementations(orig, repl)
}
var actions: [String] = []

final class RangeBox: NSView {
    let low = ProbeSlider()
    let high = ProbeSlider()
    var pressPicked = ""
    override init(frame: NSRect) {
        super.init(frame: frame)
        low.name = "low"; high.name = "high"
        for s in [low, high] {
            s.minValue = 0; s.maxValue = 10
            s.isContinuous = true
            s.frame = bounds
            s.autoresizingMask = [.width]
            addSubview(s)
        }
        low.doubleValue = 2; high.doubleValue = 8
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Trim")
        low.setAccessibilityLabel("In")
        high.setAccessibilityLabel("Out")
    }
    required init?(coder: NSCoder) { fatalError() }

    func knobCentre(_ s: NSSlider) -> NSPoint {
        let cell = s.cell as! NSSliderCell
        let r = cell.knobRect(flipped: s.isFlipped)
        return convert(NSPoint(x: r.midX, y: r.midY), from: s)
    }
    func barRect() -> NSRect {
        let cell = low.cell as! NSSliderCell
        return convert(cell.barRect(flipped: low.isFlipped), from: low)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let p = convert(point, from: superview)
        guard bounds.contains(p) else { return nil }
        let lc = knobCentre(low).x, hc = knobCentre(high).x
        let pick: ProbeSlider
        if abs(hc - lc) < 0.5 {
            pick = p.x < lc ? low : high
        } else {
            pick = p.x < (lc + hc) / 2 ? low : high
        }
        pressPicked = pick.name
        return pick
    }

    override func draw(_ dirtyRect: NSRect) {
        let bar = barRect()
        NSColor.tertiaryLabelColor.setFill()
        NSBezierPath(roundedRect: bar, xRadius: bar.height / 2, yRadius: bar.height / 2).fill()
        let lc = knobCentre(low).x, hc = knobCentre(high).x
        NSColor.controlAccentColor.setFill()
        NSBezierPath(rect: NSRect(x: lc, y: bar.minY, width: hc - lc, height: bar.height)).fill()
    }
}

final class Target: NSObject {
    let box: RangeBox
    init(_ box: RangeBox) { self.box = box }
    @objc func changed(_ s: ProbeSlider) {
        let type = NSApp.currentEvent?.type
        let final = type != .leftMouseDown && type != .leftMouseDragged
        let raw = s.doubleValue
        var v = (raw * 2).rounded() / 2
        if s === box.low { v = min(max(v, 0), box.high.doubleValue - gap) }
        else { v = max(min(v, 10), box.low.doubleValue + gap) }
        if v != raw { s.doubleValue = v }
        actions.append("\(s.name) raw=\(raw) -> \(v) final=\(final) ev=\(type.map { "\($0.rawValue)" } ?? "nil")")
        box.needsDisplay = true
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
NSEvent.isMouseCoalescingEnabled = false
let win = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 320, height: 160),
                   styleMask: [.titled], backing: .buffered, defer: false)
win.title = "rangeprobe"
let content = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 160))
win.contentView = content
let box = RangeBox(frame: NSRect(x: 20, y: 100, width: 280, height: 28))
content.addSubview(box)
let target = Target(box)
for s in [box.low, box.high] { s.target = target; s.action = #selector(Target.changed(_:)) }
let vert = ProbeSlider()
vert.name = "vertical"
vert.isVertical = true
vert.minValue = 0; vert.maxValue = 1; vert.doubleValue = 0.25
vert.frame = NSRect(x: 20, y: 5, width: 28, height: 90)
content.addSubview(vert)
win.orderFrontRegardless()

func post(_ type: NSEvent.EventType, at p: NSPoint, pressure: Float = 1) {
    let ev = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                windowNumber: win.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: pressure)!
    app.postEvent(ev, atStart: false)
}
func inWindow(_ p: NSPoint) -> NSPoint { box.convert(p, to: nil) }

final class Mark: NSObject { @objc func up() { fakeButtons = 0 } }
func gesture(from a: NSPoint, to b: NSPoint, steps: Int = 1) {
    fakeButtons = 1
    post(.leftMouseDown, at: inWindow(a))
    for i in 1...steps {
        let t = CGFloat(i) / CGFloat(steps)
        post(.leftMouseDragged, at: inWindow(NSPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)))
    }
    post(.leftMouseUp, at: inWindow(b), pressure: 0)
}

func report(_ tag: String) {
    fakeButtons = 0
    let lc = box.knobCentre(box.low), hc = box.knobCentre(box.high), bar = box.barRect()
    log("[\(tag)] low=\(box.low.doubleValue) high=\(box.high.doubleValue) picked=\(box.pressPicked) knobY(low)=\(lc.y) knobY(high)=\(hc.y) barMidY=\(bar.midY) bar=\(bar) lowX=\(lc.x) highX=\(hc.x)")
    for a in actions { log("   action \(a)") }
    actions.removeAll()
}

var steps: [() -> Void] = []
var stepIndex = 0
func next() {
    guard stepIndex < steps.count else { return }
    let s = steps[stepIndex]; stepIndex += 1
    s()
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { next() }
}

steps.append { box.layoutSubtreeIfNeeded(); box.display(); report("initial") }
// 1. A press between the two thumbs on the low half: midpoint split sends it to low.
steps.append {
    let lc = box.knobCentre(box.low)
    gesture(from: lc, to: NSPoint(x: lc.x + 30, y: lc.y))
}
steps.append { report("drag low right 30pt") }
// 2. A press on the high half of the track between the thumbs.
steps.append {
    let lc = box.knobCentre(box.low).x, hc = box.knobCentre(box.high).x
    let y = box.knobCentre(box.high).y
    let p = NSPoint(x: (lc + hc) / 2 + 10, y: y)
    fakeButtons = 1
    post(.leftMouseDown, at: inWindow(p)); post(.leftMouseUp, at: inWindow(p), pressure: 0)
}
steps.append { report("click right of midpoint") }
// 3. Drag low past high: the clamp stops it at high - gap.
steps.append {
    let lc = box.knobCentre(box.low)
    gesture(from: lc, to: NSPoint(x: box.bounds.maxX - 2, y: lc.y), steps: 1)
}
steps.append { report("drag low past high") }
// 4. A tie at gap 0: press left of the shared centre, then right.
steps.append {
    gap = 0
    box.low.doubleValue = 5; box.high.doubleValue = 5; box.needsDisplay = true
}
steps.append {
    let c = box.knobCentre(box.low)
    gesture(from: NSPoint(x: c.x - 3, y: c.y), to: NSPoint(x: c.x - 40, y: c.y))
}
steps.append { report("tie: press left side, drag left") }
steps.append { box.low.doubleValue = 5; box.high.doubleValue = 5; box.needsDisplay = true }
steps.append {
    let c = box.knobCentre(box.low)
    gesture(from: NSPoint(x: c.x + 3, y: c.y), to: NSPoint(x: c.x + 40, y: c.y))
}
steps.append { report("tie: press right side, drag right") }
// 5. The assistive path: in-process accessibility sets.
steps.append {
    gap = 1
    box.low.doubleValue = 2; box.high.doubleValue = 8; box.needsDisplay = true
}
steps.append {
    box.low.setAccessibilityValue(NSNumber(value: 9.5))
}
steps.append { report("setAccessibilityValue(low, 9.5)") }
steps.append {
    box.low.doubleValue = 7
    box.low.accessibilityPerformIncrement()
}
steps.append { report("accessibilityPerformIncrement(low at 7)") }
steps.append {
    // The real reader's route: the AX API against our own pid.
    let appEl = AXUIElementCreateApplication(getpid())
    var found: [AXUIElement] = []
    func walk(_ el: AXUIElement, _ depth: Int) {
        var role: CFTypeRef?; AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &role)
        var title: CFTypeRef?; AXUIElementCopyAttributeValue(el, kAXDescriptionAttribute as CFString, &title)
        var value: CFTypeRef?; AXUIElementCopyAttributeValue(el, kAXValueAttribute as CFString, &value)
        var minv: CFTypeRef?; AXUIElementCopyAttributeValue(el, kAXMinValueAttribute as CFString, &minv)
        var maxv: CFTypeRef?; AXUIElementCopyAttributeValue(el, kAXMaxValueAttribute as CFString, &maxv)
        var actionsRef: CFArray?; AXUIElementCopyActionNames(el, &actionsRef)
        let r = (role as? String) ?? "?"
        if r != "AXApplication" {
            log("   ax \(String(repeating: "  ", count: depth))\(r) desc=\((title as? String) ?? "") value=\(value.map { "\($0)" } ?? "-") min=\(minv.map { "\($0)" } ?? "-") max=\(maxv.map { "\($0)" } ?? "-") actions=\((actionsRef as? [String]) ?? [])")
        }
        if r == "AXSlider" { found.append(el) }
        var kids: CFTypeRef?; AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &kids)
        for k in (kids as? [AXUIElement]) ?? [] { walk(k, depth + 1) }
    }
    log("AXIsProcessTrusted=\(AXIsProcessTrusted())")
    walk(appEl, 0)
    if let lowEl = found.first(where: { el in
        var d: CFTypeRef?; AXUIElementCopyAttributeValue(el, kAXDescriptionAttribute as CFString, &d); return (d as? String) == "In" }) {
        let err = AXUIElementSetAttributeValue(lowEl, kAXValueAttribute as CFString, NSNumber(value: 9.5))
        log("   AX set low 9.5 -> err \(err.rawValue)")
        let err2 = AXUIElementPerformAction(lowEl, kAXIncrementAction as CFString)
        log("   AX increment low -> err \(err2.rawValue)")
    }
}
steps.append { report("AX API set/increment on low") }
// 6. The vertical slider: minimum at the bottom, Up raises it.
steps.append {
    let cell = vert.cell as! NSSliderCell
    let knob = cell.knobRect(flipped: vert.isFlipped)
    let bar = cell.barRect(flipped: vert.isFlipped)
    log("[vertical] isVertical=\(vert.isVertical) flipped=\(vert.isFlipped) value=\(vert.doubleValue) knobMidY=\(knob.midY) bar=\(bar)")
    let up = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.numericPad, .function], timestamp: 0,
                              windowNumber: win.windowNumber, context: nil, characters: String(UnicodeScalar(NSUpArrowFunctionKey)!),
                              charactersIgnoringModifiers: String(UnicodeScalar(NSUpArrowFunctionKey)!), isARepeat: false, keyCode: 126)!
    log("firstResponder ok=\(win.makeFirstResponder(vert))")
    vert.keyDown(with: up)
    vert.interpretKeyEvents([up])
    let knob2 = cell.knobRect(flipped: vert.isFlipped)
    log("[vertical] after Up value=\(vert.doubleValue) knobMidY=\(knob2.midY)")
    vert.doubleValue = 0
    log("[vertical] at min knobMidY=\(cell.knobRect(flipped: vert.isFlipped).midY) (flipped=\(vert.isFlipped): larger y is lower)")
    vert.doubleValue = 0.25
}
steps.append {
    box.low.doubleValue = 2; box.high.doubleValue = 8; box.needsDisplay = true
    log("READY \(getpid())")
}
steps.append {}
steps.append {}
steps.append {}
steps.append {}
steps.append {}
steps.append {}
steps.append {}
steps.append {}
steps.append { log("DONE"); exit(0) }

DispatchQueue.main.async { next() }
app.run()
