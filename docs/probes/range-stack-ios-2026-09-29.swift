// Range stacking probe, iOS (docs/range-plan.md §4.2, §4.3, the iOS arm).
// A UIKit app with the arm's own mechanics: two UISliders with empty track
// images (and, in the `tint` pair, clear track tints, the arm's final
// spelling) in one container whose hitTest splits at the midpoint of the two
// thumbs' centres (the tie by press side), a pair at a tie, a pair under
// forced right to left, and the fader (a UISlider rotated -90 degrees in a
// wrapper that is the accessibility element). Real touches come from the
// lane's XCUITest driver (tools/ios/xcuidrive) started by hand; every event
// is written to Documents/probe.log. Built by hand, never by a lane:
//   swiftc -target arm64-apple-ios17.0-simulator -sdk <iPhoneSimulator SDK>
//     -parse-as-library -o RangeProbe.app/RangeProbe <this file>
import UIKit

var logLines: [String] = []
func say(_ s: String) {
    logLines.append(s)
    let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    try? logLines.joined(separator: "\n").appending("\n").write(
        to: dir.appendingPathComponent("probe.log"), atomically: true, encoding: .utf8)
}

func midX(_ s: UISlider) -> CGFloat {
    s.thumbRect(forBounds: s.bounds, trackRect: s.trackRect(forBounds: s.bounds), value: s.value).midX
}

final class Thumb: UISlider {
    var name = ""
    override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        let ok = super.beginTracking(touch, with: event)
        say("\(name) beginTracking at \(Int(touch.location(in: self).x)) -> \(ok) value \(value)")
        return ok
    }
    override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
        super.endTracking(touch, with: event)
        say("\(name) endTracking value \(value)")
    }
    override func accessibilityIncrement() { say("\(name) accessibilityIncrement"); super.accessibilityIncrement() }
    override func accessibilityDecrement() { say("\(name) accessibilityDecrement"); super.accessibilityDecrement() }
}

final class Pair: UIView {
    let low = Thumb()
    let high = Thumb()
    let tag0: String
    init(_ tag0: String, low l: Float, high h: Float, rtl: Bool, clearTint: Bool = false) {
        self.tag0 = tag0
        super.init(frame: .zero)
        accessibilityContainerType = .semanticGroup
        accessibilityLabel = "Trim \(tag0)"
        if rtl { semanticContentAttribute = .forceRightToLeft }
        for (s, n, v) in [(low, "low", l), (high, "high", h)] {
            s.name = "\(tag0).\(n)"
            s.minimumValue = 0
            s.maximumValue = 10
            s.value = v
            s.isContinuous = true
            if clearTint {
                s.minimumTrackTintColor = .clear
                s.maximumTrackTintColor = .clear
            } else {
                s.setMinimumTrackImage(UIImage(), for: .normal)
                s.setMaximumTrackImage(UIImage(), for: .normal)
            }
            s.accessibilityLabel = n == "low" ? "In \(tag0)" : "Out \(tag0)"
            if rtl { s.semanticContentAttribute = .forceRightToLeft }
            s.addTarget(self, action: #selector(changed(_:)), for: .valueChanged)
            addSubview(s)
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc func changed(_ s: Thumb) { say("\(s.name) valueChanged \(s.value)"); setNeedsDisplay() }
    override func layoutSubviews() {
        super.layoutSubviews()
        for s in [low, high] { s.frame = bounds }
        setNeedsDisplay()
    }
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard self.point(inside: point, with: event) else { return nil }
        let lc = midX(low), hc = midX(high)
        let minAtLeft = low.effectiveUserInterfaceLayoutDirection == .leftToRight
        let lowTakes: Bool
        if abs(hc - lc) < 0.5 {
            lowTakes = minAtLeft ? point.x < lc : point.x > lc
        } else {
            let mid = (lc + hc) / 2
            lowTakes = lc < hc ? point.x < mid : point.x > mid
        }
        say("\(tag0) hitTest x=\(Int(point.x)) lowC=\(Int(lc)) highC=\(Int(hc)) -> \(lowTakes ? "low" : "high")")
        return lowTakes ? low : high
    }
    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let track = low.trackRect(forBounds: low.bounds)
        ctx.setFillColor(UIColor.tertiarySystemFill.cgColor)
        ctx.addPath(UIBezierPath(roundedRect: track, cornerRadius: track.height / 2).cgPath)
        ctx.fillPath()
        ctx.setFillColor(tintColor.cgColor)
        let a = midX(low), b = midX(high)
        ctx.fill(CGRect(x: min(a, b), y: track.minY, width: abs(b - a), height: track.height))
    }
}

final class Fader: UIView {
    let slider = Thumb()
    override init(frame: CGRect) {
        super.init(frame: frame)
        slider.name = "fader"
        slider.minimumValue = 0
        slider.maximumValue = 1
        slider.value = 0.25
        slider.semanticContentAttribute = .forceLeftToRight
        slider.isAccessibilityElement = false
        slider.addTarget(self, action: #selector(changed), for: .valueChanged)
        isAccessibilityElement = true
        accessibilityTraits = .adjustable
        accessibilityLabel = "Volume"
        addSubview(slider)
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc func changed() { say("fader valueChanged \(slider.value)") }
    override var accessibilityValue: String? {
        get { slider.accessibilityValue }
        set { super.accessibilityValue = newValue }
    }
    override func accessibilityIncrement() { say("fader wrapper increment"); slider.value += 0.25; changed() }
    override func accessibilityDecrement() { say("fader wrapper decrement"); slider.value -= 0.25; changed() }
    override func layoutSubviews() {
        super.layoutSubviews()
        let h = slider.intrinsicContentSize.height
        slider.transform = .identity
        slider.bounds = CGRect(x: 0, y: 0, width: bounds.height, height: h)
        slider.center = CGPoint(x: bounds.midX, y: bounds.midY)
        slider.transform = CGAffineTransform(rotationAngle: -.pi / 2)
    }
}

final class Root: UIViewController {
    let tie = Pair("tie", low: 5, high: 5, rtl: false)
    let open = Pair("open", low: 2, high: 8, rtl: false)
    let rtl = Pair("rtl", low: 2, high: 8, rtl: true)
    let fader = Fader()
    let tinted = Pair("tint", low: 2, high: 8, rtl: false, clearTint: true)
    let plainOne = UISlider()
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        for (v, y) in [(tie as UIView, 120.0), (open, 200), (rtl, 280)] {
            v.frame = CGRect(x: 20, y: y, width: 300, height: 34)
            view.addSubview(v)
        }
        fader.frame = CGRect(x: 150, y: 360, width: 34, height: 200)
        view.addSubview(fader)
        tinted.frame = CGRect(x: 20, y: 600, width: 300, height: 34)
        view.addSubview(tinted)
        plainOne.frame = CGRect(x: 20, y: 680, width: 300, height: 34)
        plainOne.value = 0.5
        view.addSubview(plainOne)
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        report()
    }
    func report() {
        for p in [tie, open, rtl, tinted] {
            let win = { (r: CGRect, v: UIView) in v.convert(r, to: nil) }
            say("\(p.tag0) frame \(win(p.bounds, p)) lowDir=\(p.low.effectiveUserInterfaceLayoutDirection.rawValue)")
            for s in [p.low, p.high] {
                let track = s.trackRect(forBounds: s.bounds)
                let knob = s.thumbRect(forBounds: s.bounds, trackRect: track, value: s.value)
                let k0 = s.thumbRect(forBounds: s.bounds, trackRect: track, value: s.minimumValue)
                say("  \(s.name) value \(s.value) track \(win(track, s)) knob \(win(knob, s)) knobAtMin \(win(k0, s)) axFrame \(s.accessibilityFrame) ax=\(s.isAccessibilityElement) label \(s.accessibilityLabel ?? "-") value \(s.accessibilityValue ?? "-")")
                say("  \(s.name) minTrackImage \(String(describing: s.minimumTrackImage(for: .normal)?.size)) thumbImage \(String(describing: s.thumbImage(for: .normal)?.size)) currentThumb \(String(describing: s.currentThumbImage?.size))")
            }
            say("  \(p.tag0) knob centre y vs track centre y: \(p.low.convert(p.low.thumbRect(forBounds: p.low.bounds, trackRect: p.low.trackRect(forBounds: p.low.bounds), value: p.low.value), to: nil).midY) / \(p.low.convert(p.low.trackRect(forBounds: p.low.bounds), to: nil).midY)")
            say("  \(p.tag0) accessibilityElements count \(p.accessibilityElementCount()) container \(p.accessibilityContainerType.rawValue)")
        }
        let plain = UISlider(frame: CGRect(x: 0, y: 0, width: 300, height: 34))
        say("plain UISlider trackRect \(plain.trackRect(forBounds: plain.bounds)) intrinsic \(plain.intrinsicContentSize)")
        let s = fader.slider
        let track = s.trackRect(forBounds: s.bounds)
        let knob = s.thumbRect(forBounds: s.bounds, trackRect: track, value: s.value)
        say("fader frame \(fader.convert(fader.bounds, to: nil)) axFrame \(fader.accessibilityFrame) slider frame \(s.convert(s.bounds, to: nil)) knob(window) \(s.convert(knob, to: nil)) knobAtMin(window) \(s.convert(s.thumbRect(forBounds: s.bounds, trackRect: track, value: 0), to: nil)) knobAtMax(window) \(s.convert(s.thumbRect(forBounds: s.bounds, trackRect: track, value: 1), to: nil))")
        // THE ASSISTIVE PATH IN-PROCESS: UISlider's own increment, before and after.
        let v0 = open.low.value
        open.low.accessibilityIncrement()
        say("open.low own accessibilityIncrement: \(v0) -> \(open.low.value)")
        open.low.value = v0
        fader.accessibilityIncrement()
        say("fader after wrapper increment \(fader.slider.value), knob(window) \(s.convert(s.thumbRect(forBounds: s.bounds, trackRect: s.trackRect(forBounds: s.bounds), value: s.value), to: nil))")
        fader.slider.value = 0.25
    }
}

final class Delegate: UIResponder, UIApplicationDelegate, UIWindowSceneDelegate {
    var window: UIWindow?
    func application(_ a: UIApplication, configurationForConnecting s: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let c = UISceneConfiguration(name: nil, sessionRole: s.role)
        c.delegateClass = Delegate.self
        return c
    }
    func scene(_ scene: UIScene, willConnectTo s: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let ws = scene as? UIWindowScene else { return }
        let w = UIWindow(windowScene: ws)
        w.rootViewController = Root()
        w.makeKeyAndVisible()
        window = w
    }
}

@main
struct Main {
    static func main() {
        UIApplicationMain(CommandLine.argc, CommandLine.unsafeArgv, nil, NSStringFromClass(Delegate.self))
    }
}
