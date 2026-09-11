// Rich-text platform probe, iOS half (docs/rich-text-plan.md §3, R4/R6/R9).
// A minimal simulator .app on the notifyprobe shape; every line is prefixed
// PROBE and reaches the host through `simctl launch --console-pty`.
// KAYA_RTPROBE_MODE picks the section: edits | undo | typing | ax | all.
import Foundation
import UIKit

func say(_ s: String) { print("PROBE \(s)"); fflush(stdout) }

// ---------------------------------------------------------------- the spy

final class StorageSpy: NSObject, NSTextStorageDelegate {
    struct Event {
        let phase: String
        let mask: NSTextStorage.EditActions
        let range: NSRange
        let delta: Int
        let post: NSString
    }
    var events: [Event] = []

    static func maskName(_ m: NSTextStorage.EditActions) -> String {
        var parts: [String] = []
        if m.contains(.editedAttributes) { parts.append("editedAttributes") }
        if m.contains(.editedCharacters) { parts.append("editedCharacters") }
        if parts.isEmpty { parts.append("(none)") }
        return parts.joined(separator: "|")
    }

    func textStorage(
        _ ts: NSTextStorage, didProcessEditing m: NSTextStorage.EditActions, range: NSRange,
        changeInLength delta: Int
    ) {
        events.append(
            Event(phase: "did", mask: m, range: range, delta: delta, post: ts.string as NSString))
    }
}

final class ViewSpy: NSObject, UITextViewDelegate {
    var shouldCalls: [(NSRange, String)] = []
    var didChangeCount = 0
    func textView(
        _ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String
    ) -> Bool {
        shouldCalls.append((range, text))
        return true
    }
    func textViewDidChange(_ textView: UITextView) { didChangeCount += 1 }
}

/// The suppression candidate: iOS has no `allowsUndo`, so the only per-view
/// lever is the responder-chain property itself.
final class NoUndoTextView: UITextView {
    var suppress = false
    override var undoManager: UndoManager? { suppress ? nil : super.undoManager }
}

// ------------------------------------------------------------- description

func fontDescription(_ f: UIFont) -> String {
    let t = f.fontDescriptor.symbolicTraits
    var traits: [String] = []
    if t.contains(.traitBold) { traits.append("bold") }
    if t.contains(.traitItalic) { traits.append("italic") }
    if t.contains(.traitMonoSpace) { traits.append("monoSpace") }
    return "\(f.fontName)/\(f.pointSize)\(traits.isEmpty ? "" : "[" + traits.joined(separator: ",") + "]")"
}

func describe(_ attrs: [NSAttributedString.Key: Any]) -> String {
    var parts: [String] = []
    for key in attrs.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
        let v = attrs[key]!
        let text: String
        switch v {
        case let f as UIFont: text = fontDescription(f)
        case let c as UIColor:
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            c.getRed(&r, green: &g, blue: &b, alpha: &a)
            text = String(format: "rgba(%.2f,%.2f,%.2f,%.2f)", r, g, b, a)
        case let u as URL: text = "URL(\(u.absoluteString))"
        case let s as String: text = "\"\(s)\""
        case let p as NSParagraphStyle:
            var bits = ["align=\(p.alignment.rawValue)", "headIndent=\(p.headIndent)"]
            if !p.textLists.isEmpty { bits.append("textLists=\(p.textLists.map { $0.markerFormat.rawValue })") }
            text = "NSParagraphStyle(" + bits.joined(separator: " ") + ")"
        case let n as NSNumber: text = "\(n)"
        default: text = "\(type(of: v))"
        }
        parts.append("\(key.rawValue)=\(text)")
    }
    return parts.isEmpty ? "(none)" : parts.joined(separator: " ")
}

func quoted(_ s: String) -> String {
    var out = ""
    for ch in s.unicodeScalars {
        switch ch {
        case "\n": out += "\\n"
        case "\"": out += "\\\""
        default:
            if ch.value < 0x20 || ch.value == 0xFFFC || ch.value > 0x7E {
                out += String(format: "\\u{%04X}", ch.value)
            } else { out.unicodeScalars.append(ch) }
        }
    }
    return "\"" + out + "\""
}

func dumpRuns(_ s: NSAttributedString, label: String) {
    say("runs of \(label): length=\(s.length) string=\(quoted(s.string))")
    s.enumerateAttributes(in: NSRange(location: 0, length: s.length)) { attrs, r, _ in
        let sub = (s.string as NSString).substring(with: r)
        say("  [\(r.location),\(r.location + r.length)) \(quoted(sub)) -> \(describe(attrs))")
    }
}

// ------------------------------------------------------------------- fixture

let view = NoUndoTextView(frame: CGRect(x: 0, y: 60, width: 380, height: 320))
let spy = StorageSpy()
let vspy = ViewSpy()
let bold = UIFont.boldSystemFont(ofSize: 15)
let italic = UIFont(
    descriptor: UIFont.systemFont(ofSize: 15).fontDescriptor.withSymbolicTraits(.traitItalic)!,
    size: 15)
let mono = UIFont.monospacedSystemFont(ofSize: 15, weight: .regular)
let headingFont = UIFont.boldSystemFont(ofSize: 26)

func attrAt(_ key: NSAttributedString.Key, _ at: Int) -> Any? {
    let st = view.textStorage
    guard at >= 0, at < st.length else { return nil }
    var r = NSRange(location: 0, length: 0)
    return st.attributes(at: at, effectiveRange: &r)[key]
}
func fontAt(_ at: Int) -> UIFont? { attrAt(.font, at) as? UIFont }

func reset(_ s: String) {
    view.text = s
    view.font = UIFont.systemFont(ofSize: 15)
    view.selectedRange = NSRange(location: (s as NSString).length, length: 0)
    view.undoManager?.removeAllActions()
    spy.events.removeAll()
}

func minimalDelta(_ pre: NSString, _ post: NSString) -> (NSRange, String) {
    var p = 0
    while p < pre.length, p < post.length, pre.character(at: p) == post.character(at: p) { p += 1 }
    var s = 0
    while s < pre.length - p, s < post.length - p,
        pre.character(at: pre.length - 1 - s) == post.character(at: post.length - 1 - s)
    { s += 1 }
    return (
        NSRange(location: p, length: pre.length - p - s),
        post.substring(with: NSRange(location: p, length: post.length - p - s))
    )
}

func act(_ name: String, _ body: () -> Void) {
    spy.events.removeAll()
    vspy.shouldCalls.removeAll()
    vspy.didChangeCount = 0
    let pre = NSString(string: view.text ?? "")
    body()
    let post = NSString(string: view.text ?? "")
    say("--- action \(name)")
    say("  pre=\(quoted(pre as String)) post=\(quoted(post as String))")
    for (r, s) in vspy.shouldCalls {
        say("  shouldChangeTextIn {\(r.location),\(r.length)} replacementText=\(quoted(s))")
    }
    var mirror = pre
    for e in spy.events where e.phase == "did" {
        say(
            "  did mask=\(StorageSpy.maskName(e.mask)) editedRange={\(e.range.location),\(e.range.length)} changeInLength=\(e.delta)"
        )
        guard e.mask.contains(.editedCharacters) else { continue }
        let replaced = NSRange(location: e.range.location, length: e.range.length - e.delta)
        let inserted = e.post.substring(with: e.range)
        say("    -> replaced pre-range {\(replaced.location),\(replaced.length)} with \(quoted(inserted))")
        guard NSMaxRange(replaced) <= mirror.length else {
            say("    -> FOLD OUT OF BOUNDS against mirror length \(mirror.length)")
            return
        }
        mirror = NSString(string: mirror.replacingCharacters(in: replaced, with: inserted))
    }
    say("  fold \(mirror.isEqual(to: post as String) ? "MATCHES" : "DIFFERS FROM") the post-edit string")
    let (mr, mi) = minimalDelta(pre, post)
    say("  minimal diff: replace {\(mr.location),\(mr.length)} with \(quoted(mi))")
    let charEvents = spy.events.filter { $0.phase == "did" && $0.mask.contains(.editedCharacters) }
    if charEvents.count == 1 {
        let e = charEvents[0]
        let reported = NSRange(location: e.range.location, length: e.range.length - e.delta)
        say(
            "  reported vs minimal: reported {\(reported.location),\(reported.length)} \(NSEqualRanges(reported, mr) ? "EQUALS" : "IS WIDER THAN") minimal {\(mr.location),\(mr.length)}"
        )
    }
    say("  textViewDidChange fired \(vspy.didChangeCount)x")
}

func richSample() -> NSAttributedString {
    let s = NSMutableAttributedString(string: "plain red Times bold italic under strike link\nbullet paragraph")
    let ns = s.string as NSString
    func r(_ sub: String) -> NSRange { ns.range(of: sub) }
    s.addAttribute(.font, value: UIFont.systemFont(ofSize: 15), range: NSRange(location: 0, length: s.length))
    s.addAttribute(.foregroundColor, value: UIColor.systemRed, range: r("red"))
    s.addAttribute(.font, value: UIFont(name: "TimesNewRomanPSMT", size: 24) ?? UIFont.systemFont(ofSize: 24), range: r("Times"))
    s.addAttribute(.font, value: bold, range: r("bold"))
    s.addAttribute(.font, value: italic, range: r("italic"))
    s.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: r("under"))
    s.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: r("strike"))
    s.addAttribute(.link, value: URL(string: "https://kaya.dev/probe")!, range: r("link"))
    s.addAttribute(.backgroundColor, value: UIColor.systemYellow, range: r("plain"))
    let para = NSMutableParagraphStyle()
    para.alignment = .center
    para.headIndent = 36
    para.textLists = [NSTextList(markerFormat: .disc, options: 0)]
    s.addAttribute(.paragraphStyle, value: para, range: r("bullet paragraph"))
    return s
}

// ----------------------------------------------------------------- sections

func sectionEdits() {
    say("== R4 edit reporting on UITextView ==")
    say("allowsEditingTextAttributes (default) = \(view.allowsEditingTextAttributes)")
    reset("hello world")
    act("typed character (insertText, UIKeyInput's own path)") {
        view.selectedRange = NSRange(location: 5, length: 0)
        view.insertText("X")
    }
    act("typed character at the end") {
        view.selectedRange = NSRange(location: (view.text as NSString).length, length: 0)
        view.insertText("!")
    }
    act("backspace (deleteBackward)") { view.deleteBackward() }
    act("selection replaced by typing") {
        view.selectedRange = NSRange(location: 0, length: 5)
        view.insertText("HI")
    }

    reset("hello world")
    act("programmatic replaceCharacters on the storage") {
        view.textStorage.replaceCharacters(in: NSRange(location: 0, length: 5), with: "HOWDY")
    }
    reset("hello world")
    act("programmatic view.text = (kaya's own push)") { view.text = "goodbye world" }
    reset("hello world")
    act("attribute-only addAttribute (no beginEditing)") {
        view.textStorage.addAttribute(.font, value: bold, range: NSRange(location: 0, length: 5))
    }
    reset("hello world")
    act("attribute-only inside beginEditing/endEditing") {
        view.textStorage.beginEditing()
        view.textStorage.addAttribute(.font, value: bold, range: NSRange(location: 0, length: 5))
        view.textStorage.addAttribute(.underlineStyle, value: 1, range: NSRange(location: 6, length: 5))
        view.textStorage.endEditing()
    }
    reset("hello world")
    view.allowsEditingTextAttributes = true
    view.selectedRange = NSRange(location: 0, length: 5)
    act("toggleBoldface: (UIKit's OWN toolbar Bold)") { view.toggleBoldface(nil) }
    say("  font at 0 after toggleBoldface = \(fontAt(0).map(fontDescription) ?? "nil")")
    view.allowsEditingTextAttributes = false

    say("== IME: marked text on UITextView ==")
    reset("abc")
    act("setMarkedText (composition begins)") {
        view.selectedRange = NSRange(location: 3, length: 0)
        view.setMarkedText("にほん", selectedRange: NSRange(location: 3, length: 0))
    }
    say("  markedTextRange present = \(view.markedTextRange != nil)")
    act("setMarkedText again (composition grows)") {
        view.setMarkedText("にほんご", selectedRange: NSRange(location: 4, length: 0))
    }
    act("insertText (composition commits)") { view.insertText("日本語") }
    say("  markedTextRange after commit = \(view.markedTextRange != nil)")
    say("  multi-byte: NSString length=\((view.text as NSString).length) utf8=\((view.text ?? "").utf8.count)")
}


/// UITextView's paste runs through UITextPasteDelegate and can land a turn or
/// more later, so `act` (which reads the text on the next line) sees nothing.
/// This section waits, and reports what the view was even willing to accept.
func sectionPaste(_ done: @escaping () -> Void) {
    say("== paste, measured asynchronously ==")
    func pasteConfig(_ label: String) {
        say("  [\(label)] allowsEditingTextAttributes=\(view.allowsEditingTextAttributes)")
        say("  [\(label)] pasteConfiguration = \(view.pasteConfiguration?.acceptableTypeIdentifiers ?? [])")
        say("  [\(label)] canPerformAction(paste:) = \(view.canPerformAction(#selector(UIResponder.paste(_:)), withSender: nil))")
    }
    let sample = richSample()
    let rtf = try? sample.data(
        from: NSRange(location: 0, length: sample.length),
        documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])

    var steps: [(String, () -> Void)] = []
    steps.append(
        ("plain text, allowsEditingTextAttributes=false",
         {
            view.allowsEditingTextAttributes = false
            UIPasteboard.general.items = []
            UIPasteboard.general.string = "PASTED"
         }))
    steps.append(
        ("RTF, allowsEditingTextAttributes=false",
         {
            view.allowsEditingTextAttributes = false
            UIPasteboard.general.items = []
            if let rtf { UIPasteboard.general.setData(rtf, forPasteboardType: "public.rtf") }
         }))
    steps.append(
        ("RTF, allowsEditingTextAttributes=true",
         {
            view.allowsEditingTextAttributes = true
            UIPasteboard.general.items = []
            if let rtf { UIPasteboard.general.setData(rtf, forPasteboardType: "public.rtf") }
         }))

    func run(_ i: Int) {
        guard i < steps.count else {
            view.allowsEditingTextAttributes = false
            UIPasteboard.general.items = []
            done()
            return
        }
        let (label, prepare) = steps[i]
        reset("hello world")
        prepare()
        say("-- \(label)")
        say("  pasteboard: numberOfItems=\(UIPasteboard.general.numberOfItems) hasStrings=\(UIPasteboard.general.hasStrings) types=\(UIPasteboard.general.types)")
        pasteConfig(label)
        spy.events.removeAll()
        vspy.didChangeCount = 0
        let pre = NSString(string: view.text ?? "")
        view.selectedRange = NSRange(location: 5, length: 0)
        view.paste(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            let post = NSString(string: view.text ?? "")
            say("  pre=\(quoted(pre as String)) post=\(quoted(post as String))")
            for e in spy.events where e.phase == "did" {
                say(
                    "  did mask=\(StorageSpy.maskName(e.mask)) editedRange={\(e.range.location),\(e.range.length)} changeInLength=\(e.delta)"
                )
                if e.mask.contains(.editedCharacters) {
                    let replaced = NSRange(location: e.range.location, length: e.range.length - e.delta)
                    say("    -> replaced pre-range {\(replaced.location),\(replaced.length)} with \(quoted(e.post.substring(with: e.range)))")
                }
            }
            say("  textViewDidChange fired \(vspy.didChangeCount)x")
            dumpRuns(view.attributedText, label: label)
            run(i + 1)
        }
    }
    run(0)
}

func sectionUndo() {
    say("== R6 undo on UITextView ==")
    view.suppress = false
    say("view.undoManager = \(String(describing: view.undoManager.map { ObjectIdentifier($0) })) class=\(view.undoManager.map { String(describing: type(of: $0)) } ?? "nil")")
    say("window.undoManager = \(String(describing: view.window?.undoManager.map { ObjectIdentifier($0) }))")
    say("same object = \(view.undoManager === view.window?.undoManager)")
    say("isFirstResponder = \(view.isFirstResponder)")

    reset("hello world")
    view.insertText("!")
    say("-- typed: string=\(quoted(view.text)) canUndo=\(view.undoManager?.canUndo ?? false)")
    view.undoManager?.undo()
    say("   after undo(): string=\(quoted(view.text))")

    say("-- attribute-only through textStorage, NO begin/endEditing")
    reset("hello world")
    view.textStorage.addAttribute(.font, value: bold, range: NSRange(location: 0, length: 5))
    say("   font at 0 = \(fontAt(0).map(fontDescription) ?? "nil") canUndo=\(view.undoManager?.canUndo ?? false)")
    view.undoManager?.undo()
    say("   after undo(): font at 0 = \(fontAt(0).map(fontDescription) ?? "nil")")

    say("-- attribute-only INSIDE beginEditing/endEditing")
    reset("hello world")
    view.textStorage.beginEditing()
    view.textStorage.addAttribute(.font, value: bold, range: NSRange(location: 0, length: 5))
    view.textStorage.endEditing()
    say("   font at 0 = \(fontAt(0).map(fontDescription) ?? "nil") canUndo=\(view.undoManager?.canUndo ?? false)")
    view.undoManager?.undo()
    say("   after undo(): font at 0 = \(fontAt(0).map(fontDescription) ?? "nil")")

    say("-- toggleBoldface: (UIKit's own formatting command)")
    reset("hello world")
    view.allowsEditingTextAttributes = true
    view.selectedRange = NSRange(location: 0, length: 5)
    view.toggleBoldface(nil)
    say("   font at 0 = \(fontAt(0).map(fontDescription) ?? "nil") canUndo=\(view.undoManager?.canUndo ?? false) name=\(view.undoManager?.undoActionName ?? "")")
    view.undoManager?.undo()
    say("   after undo(): font at 0 = \(fontAt(0).map(fontDescription) ?? "nil") string=\(quoted(view.text))")
    view.allowsEditingTextAttributes = false

    say("-- POSITIVE CONTROL for the suppression test: typing DOES register")
    reset("hello world")
    view.insertText("K")
    let controlRegistered = view.undoManager?.canUndo ?? false
    say("   typed: canUndo=\(controlRegistered) (must be true or the negative below proves nothing)")

    say("-- SUPPRESSION CANDIDATE 1: override undoManager to nil on the view")
    reset("hello world")
    view.suppress = true
    say("   view.undoManager = \(String(describing: view.undoManager.map { ObjectIdentifier($0) }))")
    let before = view.text ?? ""
    view.insertText("Z")
    say("   typed with the override: string=\(quoted(view.text)) text still editable=\(before != (view.text ?? ""))")
    say("   view.undoManager?.canUndo=\(view.undoManager?.canUndo ?? false)")
    say("   window.undoManager?.canUndo=\(view.window?.undoManager?.canUndo ?? false) (the chain above)")
    view.suppress = false
    say("   with the override lifted, view.undoManager = \(String(describing: view.undoManager.map { ObjectIdentifier($0) })) canUndo=\(view.undoManager?.canUndo ?? false)")
    say("   text after lifting = \(quoted(view.text))")

    say("-- SUPPRESSION CANDIDATE 2: UndoManager.disableUndoRegistration() around the edits")
    reset("hello world")
    view.undoManager?.disableUndoRegistration()
    view.insertText("D")
    view.textStorage.addAttribute(.font, value: bold, range: NSRange(location: 0, length: 5))
    view.undoManager?.enableUndoRegistration()
    say("   string=\(quoted(view.text)) canUndo=\(view.undoManager?.canUndo ?? false)")

    say("-- SUPPRESSION CANDIDATE 3: levelsOfUndo = 1 then removeAllActions (the WinUI UndoLimit shape)")
    reset("hello world")
    view.undoManager?.levelsOfUndo = 1
    view.insertText("L")
    say("   levelsOfUndo=1: canUndo=\(view.undoManager?.canUndo ?? false)")
    view.undoManager?.levelsOfUndo = 0
}


/// The follow-up the first undo run demanded: after the nil override was lifted
/// the manager reported canUndo=true, which means the override may only HIDE
/// the manager from the responder chain while UITextView keeps registering
/// through its own private reference. This settles it by actually undoing.
func sectionUndo2() {
    say("== R6 follow-up: is the nil override a suppression or only a hiding? ==")
    view.suppress = false
    reset("hello world")
    say("-- A: override to nil, type, lift, then UNDO")
    view.undoManager?.removeAllActions()
    say("   stack empty before: canUndo=\(view.undoManager?.canUndo ?? false)")
    view.suppress = true
    view.insertText("Z")
    say("   typed under the override: string=\(quoted(view.text)) view.undoManager=\(view.undoManager == nil ? "nil" : "present")")
    view.suppress = false
    say("   lifted: canUndo=\(view.undoManager?.canUndo ?? false) name=\(view.undoManager?.undoActionName ?? "")")
    view.undoManager?.undo()
    say("   after undo(): string=\(quoted(view.text))")
    say("   VERDICT: the override is \(view.text == "hello world" ? "a HIDING ONLY — registration continued" : "a real SUPPRESSION — nothing was registered")")

    say("-- B: disableUndoRegistration, then a first-responder cycle")
    reset("hello world")
    let before = view.undoManager.map { ObjectIdentifier($0) }
    view.undoManager?.disableUndoRegistration()
    view.insertText("D")
    say("   typed while disabled: canUndo=\(view.undoManager?.canUndo ?? false)")
    view.resignFirstResponder()
    view.becomeFirstResponder()
    let after = view.undoManager.map { ObjectIdentifier($0) }
    say("   manager identity before=\(String(describing: before)) after the cycle=\(String(describing: after)) same=\(before == after)")
    say("   isUndoRegistrationEnabled after the cycle = \(view.undoManager?.isUndoRegistrationEnabled ?? true)")
    view.insertText("E")
    say("   typed after the cycle: string=\(quoted(view.text)) canUndo=\(view.undoManager?.canUndo ?? false)")
    if view.undoManager?.isUndoRegistrationEnabled == false { view.undoManager?.enableUndoRegistration() }

    say("-- C: removeAllActions after every edit (the brute force)")
    reset("hello world")
    for ch in ["a", "b", "c"] {
        view.insertText(ch)
        view.undoManager?.removeAllActions()
    }
    say("   string=\(quoted(view.text)) canUndo=\(view.undoManager?.canUndo ?? false)")

    say("-- D: does a fresh UITextView start with registration enabled?")
    let fresh = NoUndoTextView(frame: CGRect(x: 0, y: 400, width: 300, height: 60))
    view.superview?.addSubview(fresh)
    fresh.becomeFirstResponder()
    say("   fresh.undoManager=\(fresh.undoManager == nil ? "nil" : "present") class=\(fresh.undoManager.map { String(describing: type(of: $0)) } ?? "nil") enabled=\(fresh.undoManager?.isUndoRegistrationEnabled ?? true)")
    fresh.insertText("f")
    say("   typed: canUndo=\(fresh.undoManager?.canUndo ?? false)")
    fresh.resignFirstResponder()
    fresh.removeFromSuperview()
    view.becomeFirstResponder()

    say("-- E: does disableUndoRegistration also cover UIKit's OWN formatting command?")
    reset("hello world")
    view.allowsEditingTextAttributes = true
    view.undoManager?.disableUndoRegistration()
    view.selectedRange = NSRange(location: 0, length: 5)
    view.toggleBoldface(nil)
    say("   font at 0 = \(fontAt(0).map(fontDescription) ?? "nil") canUndo=\(view.undoManager?.canUndo ?? false)")
    view.undoManager?.enableUndoRegistration()
    view.allowsEditingTextAttributes = false
    say("   POSITIVE CONTROL: the same act with registration ENABLED")
    reset("hello world")
    view.allowsEditingTextAttributes = true
    view.selectedRange = NSRange(location: 0, length: 5)
    view.toggleBoldface(nil)
    say("   font at 0 = \(fontAt(0).map(fontDescription) ?? "nil") canUndo=\(view.undoManager?.canUndo ?? false)")
    view.allowsEditingTextAttributes = false
}

func sectionTyping() {
    say("== typing attributes on UITextView ==")
    view.allowsEditingTextAttributes = true
    reset("hello world")
    view.textStorage.addAttribute(.font, value: bold, range: NSRange(location: 0, length: 5))
    view.textStorage.addAttribute(.link, value: URL(string: "https://kaya.dev/probe")!, range: NSRange(location: 6, length: 5))
    view.textStorage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: NSRange(location: 6, length: 5))
    dumpRuns(view.attributedText, label: "before")

    func caret(_ at: Int, _ label: String) {
        view.selectedRange = NSRange(location: at, length: 0)
        say("caret at \(at) (\(label)): typingAttributes -> \(describe(view.typingAttributes))")
    }
    caret(3, "inside the bold run")
    caret(5, "at the END of the bold run")
    caret(0, "at the START of the bold run")
    caret(8, "inside the link run")
    caret(11, "at the END of the link run")
    caret(6, "at the START of the link run")

    say("-- typing at the end of the bold run")
    view.selectedRange = NSRange(location: 5, length: 0)
    view.insertText("B")
    say("   font at 5 = \(fontAt(5).map(fontDescription) ?? "nil")")

    let end = (view.text as NSString).range(of: "world")
    let after = end.location + end.length
    say("-- typing at the end of the link run (index \(after))")
    view.selectedRange = NSRange(location: after, length: 0)
    view.insertText("L")
    say("   link at \(after) = \(attrAt(.link, after).map { "\($0)" } ?? "nil") underline = \(attrAt(.underlineStyle, after).map { "\($0)" } ?? "nil")")
    dumpRuns(view.attributedText, label: "after")

    say("-- typing INSIDE the link run")
    reset("hello world")
    view.textStorage.addAttribute(.link, value: URL(string: "https://kaya.dev/probe")!, range: NSRange(location: 6, length: 5))
    view.selectedRange = NSRange(location: 8, length: 0)
    view.insertText("Z")
    say("   link at 8 = \(attrAt(.link, 8).map { "\($0)" } ?? "nil")")
    view.allowsEditingTextAttributes = false
}

/// kaya's own route into the accessibility runtime (swift/KayaSwiftUI.swift,
/// `kayaAxEnableAutomation`): NOT VoiceOver — the automation switch, which is
/// what makes UIKit materialize its accessibility tree in a process with no
/// assistive technology attached. Without it every AX property answers its
/// unloaded default and the measurement says nothing.
func enableAxAutomation() {
    guard let handle = dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW),
        let symbol = dlsym(handle, "_AXSSetAutomationEnabled")
    else {
        say("AX automation: _AXSSetAutomationEnabled NOT FOUND — the tree stays empty")
        return
    }
    typealias SetAutomation = @convention(c) (Bool) -> Void
    unsafeBitCast(symbol, to: SetAutomation.self)(true)
    say("AX automation enabled via _AXSSetAutomationEnabled(true)")
}

func axElements(_ v: UIView, _ depth: Int = 0, _ out: inout [(Int, NSObject)]) {
    if depth > 6 { return }
    out.append((depth, v))
    for sub in v.subviews { axElements(sub, depth + 1, &out) }
    let n = v.accessibilityElementCount()
    if n != NSNotFound && n > 0 {
        for i in 0..<n {
            if let e = v.accessibilityElement(at: i) as? NSObject { out.append((depth + 1, e)) }
        }
    }
}

func sectionAX() {
    say("== R9 accessibility of the attributed text, in process ==")
    say("automation already enabled at launch; UIAccessibility.isVoiceOverRunning = \(UIAccessibility.isVoiceOverRunning)")
    let s = NSMutableAttributedString(string: "Heading one\nplain bold italic under strike mono link end\n")
    let ns = s.string as NSString
    func r(_ sub: String) -> NSRange { ns.range(of: sub) }
    s.addAttribute(.font, value: UIFont.systemFont(ofSize: 15), range: NSRange(location: 0, length: s.length))
    s.addAttribute(.font, value: headingFont, range: r("Heading one"))
    s.addAttribute(.font, value: bold, range: r("bold"))
    s.addAttribute(.font, value: italic, range: r("italic"))
    s.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: r("under"))
    s.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: r("strike"))
    s.addAttribute(.font, value: mono, range: r("mono"))
    s.addAttribute(.link, value: URL(string: "https://kaya.dev/probe")!, range: r("link"))
    s.addAttribute(.foregroundColor, value: UIColor.systemRed, range: r("end"))
    view.attributedText = s
    dumpRuns(view.attributedText, label: "the document")

    say("accessibilityTraits = \(view.accessibilityTraits.rawValue)")
    say("accessibilityLabel = \(String(describing: view.accessibilityLabel))")
    say("accessibilityValue = \(quoted(view.accessibilityValue ?? ""))")
    if let av = view.accessibilityAttributedValue {
        say("accessibilityAttributedValue length = \(av.length)")
        av.enumerateAttributes(in: NSRange(location: 0, length: av.length)) { attrs, r, _ in
            let sub = (av.string as NSString).substring(with: r)
            say("  run [\(r.location),\(r.location + r.length)) \(quoted(sub)) -> \(describe(attrs))")
        }
    } else {
        say("accessibilityAttributedValue is NIL — UIKit publishes no attributed value here")
    }

    say("-- the UIAccessibility keys, declared by hand on a copy")
    let marked = NSMutableAttributedString(attributedString: s)
    marked.addAttribute(.accessibilityTextHeadingLevel, value: NSNumber(value: 1), range: r("Heading one"))
    marked.addAttribute(.UIAccessibilityTextAttributeContext, value: UIAccessibilityTextualContext.sourceCode, range: r("mono"))
    view.attributedText = marked
    if let av = view.accessibilityAttributedValue {
        av.enumerateAttributes(in: NSRange(location: 0, length: av.length)) { attrs, r, _ in
            let keys = attrs.keys.map { $0.rawValue }.sorted()
            let sub = (av.string as NSString).substring(with: r)
            say("  run [\(r.location),\(r.location + r.length)) \(quoted(sub)) keys=\(keys)")
        }
    }
    say("UIAccessibilityTextAttributeHeadingLevel = \(NSAttributedString.Key.accessibilityTextHeadingLevel.rawValue)")
    say("UIAccessibilityTextAttributeContext = \(NSAttributedString.Key.UIAccessibilityTextAttributeContext.rawValue)")
    say("UIAccessibilityTextAttributeCustom = \(NSAttributedString.Key.accessibilityTextCustom.rawValue)")
    say("UIAccessibility.isVoiceOverRunning = \(UIAccessibility.isVoiceOverRunning)")

    // What an assistive client reaches through the text-input protocol: the
    // element's own children, which is where a UIKit link would live.
    say("accessibilityElementCount = \(view.accessibilityElementCount())")
    say("isAccessibilityElement = \(view.isAccessibilityElement)")

    say("-- the element tree under the text view, as the automation runtime sees it")
    var found: [(Int, NSObject)] = []
    axElements(view, 0, &found)
    for (d, e) in found {
        let traits = (e.value(forKey: "accessibilityTraits") as? UInt64) ?? 0
        say("  \(String(repeating: "  ", count: d))\(type(of: e)) isElement=\((e as? UIView)?.isAccessibilityElement ?? e.isAccessibilityElement) traits=\(traits) label=\(String(describing: e.accessibilityLabel)) value=\(quoted(e.accessibilityValue ?? ""))")
        if let av = e.accessibilityAttributedValue {
            say("  \(String(repeating: "  ", count: d))attributedValue length=\(av.length):")
            av.enumerateAttributes(in: NSRange(location: 0, length: av.length)) { attrs, r, _ in
                let sub = (av.string as NSString).substring(with: r)
                let keys = attrs.keys.map { $0.rawValue }.sorted()
                say("  \(String(repeating: "  ", count: d))  run [\(r.location),\(r.location + r.length)) \(quoted(sub)) keys=\(keys) -> \(describe(attrs))")
            }
        }
    }
    say("UIAccessibilityTraitLink raw = \(UIAccessibilityTraits.link.rawValue), Header = \(UIAccessibilityTraits.header.rawValue)")
}

// --------------------------------------------------------------------- main

final class Delegate: NSObject, UIApplicationDelegate {
    var window: UIWindow?
    func application(
        _ app: UIApplication, didFinishLaunchingWithOptions o: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        let w = UIWindow(frame: UIScreen.main.bounds)
        let vc = UIViewController()
        vc.view.backgroundColor = .systemBackground
        view.font = UIFont.systemFont(ofSize: 15)
        view.delegate = vspy
        view.textStorage.delegate = spy
        view.accessibilityIdentifier = "richtext-probe"
        vc.view.addSubview(view)
        w.rootViewController = vc
        w.makeKeyAndVisible()
        window = w
        view.becomeFirstResponder()

        let mode = ProcessInfo.processInfo.environment["KAYA_RTPROBE_MODE"] ?? "all"
        say("mode=\(mode) iOS=\(UIDevice.current.systemVersion) device=\(UIDevice.current.name)")
        say("fixture textLayoutManager = \(view.textLayoutManager != nil ? "TextKit2" : "TextKit1")")
        say("fixture textStorage class = \(type(of: view.textStorage))")
        say("fixture isFirstResponder = \(view.isFirstResponder)")
        // The AX tree materializes ASYNCHRONOUSLY after the automation switch
        // flips (swift/KayaSwiftUI.swift says so and retries for it), so the ax
        // mode flips it at launch and waits before reading.
        var settle = 0.4
        if mode == "ax" || mode == "all" {
            enableAxAutomation()
            settle = 3.0
        }
        // One turn out: UIKit installs the field editor's undo manager when the
        // view becomes first responder, and the measurements need it present.
        DispatchQueue.main.asyncAfter(deadline: .now() + settle) {
            if mode == "edits" || mode == "all" { sectionEdits() }
            if mode == "undo" || mode == "all" { sectionUndo() }
            if mode == "undo2" || mode == "all" { sectionUndo2() }
            if mode == "typing" || mode == "all" { sectionTyping() }
            if mode == "ax" || mode == "all" { sectionAX() }
            if mode == "paste" || mode == "all" {
                sectionPaste {
                    say("DONE \(mode)")
                    exit(0)
                }
                return
            }
            say("DONE \(mode)")
            exit(0)
        }
        return true
    }
}

UIApplicationMain(
    CommandLine.argc, CommandLine.unsafeArgv, nil, NSStringFromClass(Delegate.self))
