// Rich-text platform probe, macOS half (docs/rich-text-plan.md §3, R4/R6/R9).
// Nothing in the kaya tree is touched; this file lives under the job's tmp.
//
// Modes (argv[1]):
//   edits   — R4 edit reporting, the one-subtraction formula, IME marked text
//   undo    — R6 undo scope and suppression
//   typing  — typing-attribute inheritance at the end of a bold run and a link
//   rtf     — RTF paste with the rich opinions unpinned
//   axhold  — build the styled runs, print the pid, hold for the AX reader
// Every line is prefixed PROBE so the report can quote it verbatim.
import AppKit
import Foundation

func say(_ s: String) { print("PROBE \(s)"); fflush(stdout) }

// ---------------------------------------------------------------- the spy

final class StorageSpy: NSObject, NSTextStorageDelegate {
    struct Event {
        let phase: String
        let mask: NSTextStorageEditActions
        let range: NSRange
        let delta: Int
        let post: NSString
    }
    var events: [Event] = []
    weak var forwardTo: NSTextStorageDelegate?

    static func maskName(_ m: NSTextStorageEditActions) -> String {
        var parts: [String] = []
        if m.contains(.editedAttributes) { parts.append("editedAttributes") }
        if m.contains(.editedCharacters) { parts.append("editedCharacters") }
        if parts.isEmpty { parts.append("(none)") }
        return parts.joined(separator: "|")
    }

    func textStorage(
        _ ts: NSTextStorage, willProcessEditing m: NSTextStorageEditActions,
        range: NSRange, changeInLength delta: Int
    ) {
        events.append(
            Event(phase: "will", mask: m, range: range, delta: delta, post: ts.string as NSString))
        forwardTo?.textStorage?(
            ts, willProcessEditing: m, range: range, changeInLength: delta)
    }

    func textStorage(
        _ ts: NSTextStorage, didProcessEditing m: NSTextStorageEditActions,
        range: NSRange, changeInLength delta: Int
    ) {
        events.append(
            Event(phase: "did", mask: m, range: range, delta: delta, post: ts.string as NSString))
        forwardTo?.textStorage?(
            ts, didProcessEditing: m, range: range, changeInLength: delta)
    }
}

final class ViewSpy: NSObject, NSTextViewDelegate {
    var shouldCalls: [(NSRange, String?)] = []
    var didChangeCount = 0
    var didChangeSelectionCount = 0
    func textView(
        _ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange,
        replacementString: String?
    ) -> Bool {
        shouldCalls.append((affectedCharRange, replacementString))
        return true
    }
    /// The notification kaya's Coordinator actually listens to
    /// (swift/KayaSwiftUI.swift, `textDidChange`): the fold's own channel.
    func textDidChange(_ notification: Notification) { didChangeCount += 1 }
    func textViewDidChangeSelection(_ notification: Notification) { didChangeSelectionCount += 1 }
}

// ------------------------------------------------------------ the fixture

let content = NSTextContentStorage()
let layout = NSTextLayoutManager()
content.addTextLayoutManager(layout)
let container = NSTextContainer(size: CGSize(width: 420, height: CGFloat.greatestFiniteMagnitude))
container.widthTracksTextView = true
layout.textContainer = container
let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 420, height: 260), textContainer: container)
let spy = StorageSpy()
let vspy = ViewSpy()

/// kaya's own pin set, verbatim in shape from swift/KayaSwiftUI.swift's
/// kayaPinPlainText — the probe starts where the shipped widget stands.
func pinPlainText(_ v: NSTextView) {
    v.isRichText = false
    v.importsGraphics = false
    v.allowsImageEditing = false
    v.usesFontPanel = false
    v.usesRuler = false
    v.isRulerVisible = false
    v.allowsDocumentBackgroundColorChange = false
    v.isAutomaticQuoteSubstitutionEnabled = false
    v.isAutomaticDashSubstitutionEnabled = false
    v.isAutomaticTextReplacementEnabled = false
    v.isAutomaticSpellingCorrectionEnabled = false
    v.isAutomaticTextCompletionEnabled = false
    v.smartInsertDeleteEnabled = false
    v.isContinuousSpellCheckingEnabled = false
    v.isGrammarCheckingEnabled = false
    v.isAutomaticLinkDetectionEnabled = false
    v.isAutomaticDataDetectionEnabled = false
    v.writingToolsBehavior = .none
    v.usesFindBar = false
    v.usesFindPanel = false
    v.isIncrementalSearchingEnabled = false
}

let window = NSWindow(
    contentRect: NSRect(x: 200, y: 200, width: 440, height: 300),
    styleMask: [.titled, .closable], backing: .buffered, defer: false)

func boot() {
    view.isEditable = true
    view.isSelectable = true
    view.allowsUndo = true
    view.font = NSFont.systemFont(ofSize: 13)
    view.isVerticallyResizable = true
    view.delegate = vspy
    pinPlainText(view)
    let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 440, height: 300))
    scroll.documentView = view
    scroll.hasVerticalScroller = true
    window.contentView = scroll
    window.title = "kaya richtext probe"
    window.makeKeyAndOrderFront(nil)
    window.makeFirstResponder(view)
    guard let storage = view.textStorage else { say("FATAL no textStorage"); exit(2) }
    say("fixture textStorage.delegate before = \(String(describing: storage.delegate))")
    say("fixture textStorage class = \(type(of: storage))")
    spy.forwardTo = storage.delegate
    storage.delegate = spy
    say("fixture textLayoutManager = \(view.textLayoutManager != nil ? "TextKit2" : "TextKit1")")
    say("fixture window.isKeyWindow=\(window.isKeyWindow) NSApp.isActive=\(NSApp.isActive)")
    say("fixture firstResponder=\(String(describing: window.firstResponder))")
}

// ------------------------------------------------------------- describing

func fontDescription(_ f: NSFont) -> String {
    let t = f.fontDescriptor.symbolicTraits
    var traits: [String] = []
    if t.contains(.bold) { traits.append("bold") }
    if t.contains(.italic) { traits.append("italic") }
    if t.contains(.monoSpace) { traits.append("monoSpace") }
    return "\(f.fontName)/\(f.pointSize)\(traits.isEmpty ? "" : "[" + traits.joined(separator: ",") + "]")"
}

func describe(_ attrs: [NSAttributedString.Key: Any]) -> String {
    var parts: [String] = []
    for key in attrs.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
        let v = attrs[key]!
        let text: String
        switch v {
        case let f as NSFont: text = fontDescription(f)
        case let c as NSColor:
            let rgb = c.usingColorSpace(.sRGB)
            text = rgb.map {
                String(
                    format: "sRGB(%.2f,%.2f,%.2f,%.2f)", $0.redComponent, $0.greenComponent,
                    $0.blueComponent, $0.alphaComponent)
            } ?? "\(c)"
        case let u as URL: text = "URL(\(u.absoluteString))"
        case let s as String: text = "\"\(s)\""
        case let p as NSParagraphStyle:
            var bits = ["align=\(p.alignment.rawValue)", "headIndent=\(p.headIndent)",
                        "firstLineHeadIndent=\(p.firstLineHeadIndent)"]
            if !p.textLists.isEmpty {
                bits.append("textLists=\(p.textLists.map { $0.markerFormat.rawValue })")
            }
            text = "NSParagraphStyle(" + bits.joined(separator: " ") + ")"
        case let n as NSNumber: text = "\(n)"
        default: text = "\(type(of: v))"
        }
        parts.append("\(key.rawValue)=\(text)")
    }
    return parts.isEmpty ? "(none)" : parts.joined(separator: " ")
}

func dumpRuns(_ s: NSAttributedString, label: String) {
    say("runs of \(label): length=\(s.length) string=\(quoted(s.string))")
    s.enumerateAttributes(in: NSRange(location: 0, length: s.length)) { attrs, r, _ in
        let sub = (s.string as NSString).substring(with: r)
        say("  [\(r.location),\(r.location + r.length)) \(quoted(sub)) -> \(describe(attrs))")
    }
}

func quoted(_ s: String) -> String {
    var out = ""
    for ch in s.unicodeScalars {
        switch ch {
        case "\n": out += "\\n"
        case "\"": out += "\\\""
        case "\\": out += "\\\\"
        default:
            if ch.value < 0x20 || ch.value == 0xFFFC || ch.value > 0x7E {
                out += String(format: "\\u{%04X}", ch.value)
            } else { out.unicodeScalars.append(ch) }
        }
    }
    return "\"" + out + "\""
}


/// One overload-free attribute read: `attribute(_:at:effectiveRange:)` has two
/// signatures and an optional chain makes `nil` ambiguous.
func attrAt(_ key: NSAttributedString.Key, _ at: Int, _ v: NSTextView = view) -> Any? {
    guard let st = v.textStorage, at >= 0, at < st.length else { return nil }
    var r = NSRange(location: 0, length: 0)
    return st.attributes(at: at, effectiveRange: &r)[key]
}

func fontAt(_ at: Int, _ v: NSTextView = view) -> NSFont? { attrAt(.font, at, v) as? NSFont }

// -------------------------------------------------------------- the fold

/// R4's "one subtraction": from (editedRange, changeInLength) taken AFTER the
/// edit, the range replaced in PRE-edit coordinates is
/// {editedRange.location, editedRange.length - changeInLength} and the inserted
/// text is the post-edit substring at editedRange. Folding every character
/// event over the pre-edit mirror must reproduce the post-edit string.
/// The MINIMAL delta, the one kaya's own mirror diff produces: common prefix,
/// common suffix, the rest. Compared against what the platform reported.
func minimalDelta(_ pre: NSString, _ post: NSString) -> (NSRange, String) {
    var p = 0
    while p < pre.length, p < post.length, pre.character(at: p) == post.character(at: p) { p += 1 }
    var s = 0
    while s < pre.length - p, s < post.length - p,
        pre.character(at: pre.length - 1 - s) == post.character(at: post.length - 1 - s)
    { s += 1 }
    let replaced = NSRange(location: p, length: pre.length - p - s)
    let inserted = post.substring(with: NSRange(location: p, length: post.length - p - s))
    return (replaced, inserted)
}

func act(_ name: String, _ body: () -> Void) {
    spy.events.removeAll()
    vspy.shouldCalls.removeAll()
    vspy.didChangeCount = 0
    vspy.didChangeSelectionCount = 0
    let pre = NSString(string: view.string)
    body()
    let post = NSString(string: view.string)
    say("--- action \(name)")
    say("  pre=\(quoted(pre as String)) post=\(quoted(post as String))")
    for (r, s) in vspy.shouldCalls {
        say("  shouldChangeTextIn {\(r.location),\(r.length)} replacement=\(s.map(quoted) ?? "nil")")
    }
    var mirror = pre
    for e in spy.events where e.phase == "did" {
        say(
            "  did mask=\(StorageSpy.maskName(e.mask)) editedRange={\(e.range.location),\(e.range.length)} changeInLength=\(e.delta)"
        )
        guard e.mask.contains(.editedCharacters) else { continue }
        let replacedLen = e.range.length - e.delta
        let replaced = NSRange(location: e.range.location, length: replacedLen)
        let inserted = e.post.substring(with: e.range)
        say(
            "    -> replaced pre-range {\(replaced.location),\(replaced.length)} with \(quoted(inserted))"
        )
        guard NSMaxRange(replaced) <= mirror.length else {
            say("    -> FOLD OUT OF BOUNDS against mirror length \(mirror.length)")
            return
        }
        mirror = NSString(string: mirror.replacingCharacters(in: replaced, with: inserted))
    }
    say("  fold \(mirror.isEqual(to: post as String) ? "MATCHES" : "DIFFERS FROM") the post-edit string")
    if !mirror.isEqual(to: post as String) { say("  fold produced \(quoted(mirror as String))") }
    let (mr, mi) = minimalDelta(pre, post)
    say("  minimal diff: replace {\(mr.location),\(mr.length)} with \(quoted(mi))")
    let charEvents = spy.events.filter { $0.phase == "did" && $0.mask.contains(.editedCharacters) }
    if charEvents.count == 1 {
        let e = charEvents[0]
        let reported = NSRange(location: e.range.location, length: e.range.length - e.delta)
        let same = NSEqualRanges(reported, mr)
        say(
            "  reported vs minimal: reported {\(reported.location),\(reported.length)} \(same ? "EQUALS" : "IS WIDER THAN") minimal {\(mr.location),\(mr.length)}"
        )
    }
    say("  textDidChange fired \(vspy.didChangeCount)x, textViewDidChangeSelection \(vspy.didChangeSelectionCount)x")
}

// ------------------------------------------------------------- the fixture text

func reset(_ s: String) {
    view.string = s
    view.setSelectedRange(NSRange(location: (s as NSString).length, length: 0))
    view.undoManager?.removeAllActions()
    spy.events.removeAll()
}

let bold = NSFontManager.shared.convert(NSFont.systemFont(ofSize: 13), toHaveTrait: .boldFontMask)
let mono = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
let italic = NSFontManager.shared.convert(NSFont.systemFont(ofSize: 13), toHaveTrait: .italicFontMask)
let headingFont = NSFont.boldSystemFont(ofSize: 24)

// ----------------------------------------------------------------- modes

/// A PRIVATE pasteboard, never the general one: `paste:` reads
/// NSPasteboard.general and this probe must not touch the host's clipboard.
/// `readSelection(from:)` is the method `paste:` itself calls.
func privatePasteboard(_ suffix: String) -> NSPasteboard {
    let pb = NSPasteboard(name: NSPasteboard.Name("kaya.richtext.probe.\(suffix)"))
    pb.clearContents()
    return pb
}

func richSample() -> NSAttributedString {
    let s = NSMutableAttributedString(string: "plain red Times bold italic under strike link list")
    let ns = s.string as NSString
    func r(_ sub: String) -> NSRange { ns.range(of: sub) }
    s.addAttribute(.font, value: NSFont.systemFont(ofSize: 13), range: NSRange(location: 0, length: s.length))
    s.addAttribute(.foregroundColor, value: NSColor.systemRed, range: r("red"))
    s.addAttribute(.font, value: NSFont(name: "Times New Roman", size: 22) ?? NSFont.systemFont(ofSize: 22), range: r("Times"))
    s.addAttribute(.font, value: bold, range: r("bold"))
    s.addAttribute(.font, value: italic, range: r("italic"))
    s.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: r("under"))
    s.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: r("strike"))
    s.addAttribute(.link, value: URL(string: "https://kaya.dev/probe")!, range: r("link"))
    s.addAttribute(.backgroundColor, value: NSColor.systemYellow, range: r("plain"))
    // A SECOND PARAGRAPH, so the paragraph-level answer is measured rather than
    // inferred: paragraph attributes apply to whole paragraphs, and a one-
    // paragraph sample cannot tell a dropped list from an overwritten one.
    let tail = NSMutableAttributedString(string: "\nbullet paragraph\nquote paragraph")
    let listPara = NSMutableParagraphStyle()
    listPara.alignment = .center
    listPara.headIndent = 36
    listPara.firstLineHeadIndent = 18
    listPara.textLists = [NSTextList(markerFormat: .disc, options: 0)]
    let quotePara = NSMutableParagraphStyle()
    quotePara.headIndent = 48
    quotePara.firstLineHeadIndent = 48
    quotePara.alignment = .right
    let tns = tail.string as NSString
    tail.addAttribute(.font, value: NSFont.systemFont(ofSize: 13), range: NSRange(location: 0, length: tail.length))
    tail.addAttribute(.paragraphStyle, value: listPara, range: tns.range(of: "bullet paragraph"))
    tail.addAttribute(.paragraphStyle, value: quotePara, range: tns.range(of: "quote paragraph"))
    s.append(tail)
    return s
}

func modeEdits() {
    say("== R4 edit reporting, the pinned (plain-text) control ==")
    reset("hello world")
    act("typed character (insertText, the path a key event ends in)") {
        view.setSelectedRange(NSRange(location: 5, length: 0))
        view.insertText("X", replacementRange: NSRange(location: NSNotFound, length: 0))
    }
    act("typed character at the end") {
        view.insertText("!", replacementRange: NSRange(location: NSNotFound, length: 0))
    }
    act("backspace (deleteBackward:)") { view.deleteBackward(nil) }
    act("selection replaced by typing") {
        view.setSelectedRange(NSRange(location: 0, length: 5))
        view.insertText("HI", replacementRange: NSRange(location: NSNotFound, length: 0))
    }
    reset("hello world")
    act("paste of plain text (readSelection from a private pasteboard)") {
        let pb = privatePasteboard("plain")
        pb.setString("PASTED", forType: .string)
        view.setSelectedRange(NSRange(location: 5, length: 0))
        let ok = view.readSelection(from: pb)
        say("  readSelection returned \(ok)")
    }
    reset("hello world")
    act("paste of RTF while PINNED (isRichText=false)") {
        let pb = privatePasteboard("rtfpinned")
        let data = richSample().rtf(
            from: NSRange(location: 0, length: richSample().length), documentAttributes: [:])!
        pb.setData(data, forType: .rtf)
        view.setSelectedRange(NSRange(location: 5, length: 0))
        let ok = view.readSelection(from: pb)
        say("  readSelection returned \(ok)")
    }
    say("  storage after the pinned RTF paste:")
    dumpRuns(view.attributedString(), label: "pinned paste")

    reset("hello world")
    view.isRichText = true
    act("paste of RTF while UNPINNED (isRichText=true, importsGraphics=false)") {
        let pb = privatePasteboard("rtfrich")
        let sample = richSample()
        let data = sample.rtf(from: NSRange(location: 0, length: sample.length), documentAttributes: [:])!
        pb.setData(data, forType: .rtf)
        view.setSelectedRange(NSRange(location: 5, length: 0))
        let ok = view.readSelection(from: pb)
        say("  readSelection returned \(ok)")
    }
    view.isRichText = false
    pinPlainText(view)

    reset("hello world")
    act("programmatic replaceCharacters on the storage") {
        view.textStorage?.replaceCharacters(in: NSRange(location: 0, length: 5), with: "HOWDY")
    }
    reset("hello world")
    act("programmatic view.string = (kaya's own push)") { view.string = "goodbye world" }
    reset("hello world")
    act("attribute-only addAttribute (no beginEditing)") {
        view.textStorage?.addAttribute(.font, value: bold, range: NSRange(location: 0, length: 5))
    }
    reset("hello world")
    act("attribute-only inside beginEditing/endEditing") {
        guard let st = view.textStorage else { return }
        st.beginEditing()
        st.addAttribute(.font, value: bold, range: NSRange(location: 0, length: 5))
        st.addAttribute(.underlineStyle, value: 1, range: NSRange(location: 6, length: 5))
        st.endEditing()
    }
    reset("hello world")
    act("attribute-only through shouldChangeText(nil)/didChangeText (the toolbar path)") {
        let r = NSRange(location: 0, length: 5)
        let ok = view.shouldChangeText(in: r, replacementString: nil)
        say("  shouldChangeText returned \(ok)")
        view.textStorage?.addAttribute(.font, value: bold, range: r)
        view.didChangeText()
    }

    say("== IME: marked text through NSTextInputClient ==")
    say("  view.inputContext keyboard input sources = \(view.inputContext?.keyboardInputSources ?? [])")
    say("  NSTextInputContext.current = \(String(describing: NSTextInputContext.current))")
    say("  NOT switching the input source: NSTextInputContext.selectedKeyboardInputSource drives TSM,")
    say("  which is host-wide while an app is active. setMarkedText IS the method a Japanese IME calls.")
    reset("abc")
    act("setMarkedText (composition begins)") {
        view.setSelectedRange(NSRange(location: 3, length: 0))
        view.setMarkedText(
            "にほん", selectedRange: NSRange(location: 3, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0))
    }
    say("  hasMarkedText=\(view.hasMarkedText()) markedRange={\(view.markedRange().location),\(view.markedRange().length)}")
    act("setMarkedText again (composition grows)") {
        view.setMarkedText(
            "にほんご", selectedRange: NSRange(location: 4, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0))
    }
    act("insertText (composition commits)") {
        view.insertText("日本語", replacementRange: view.markedRange())
    }
    say("  hasMarkedText after commit=\(view.hasMarkedText())")
    say("  multi-byte check: NSString length=\((view.string as NSString).length) utf8=\(view.string.utf8.count)")
}


/// Every in-process route a Cmd-Z can take to this view. `tryToPerform` is the
/// one that does NOT need a key window, so it answers even in an accessory app;
/// the other three need NSApp to be active, which `undokey` arranges.
func cmdZChannels(_ label: String) {
    let before = view.string
    let fontBefore = fontAt(0)
    let event = NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
        windowNumber: window.windowNumber, context: nil, characters: "z",
        charactersIgnoringModifiers: "z", isARepeat: false, keyCode: 6)!
    say("  [\(label)] isKeyWindow=\(window.isKeyWindow) NSApp.isActive=\(NSApp.isActive) firstResponderIsView=\(window.firstResponder === view)")
    say("  [\(label)] view.tryToPerform(undo:) -> \(view.tryToPerform(Selector(("undo:")), with: nil)); string=\(quoted(view.string))")
    say("  [\(label)] view.performKeyEquivalent -> \(view.performKeyEquivalent(with: event)); string=\(quoted(view.string))")
    say("  [\(label)] mainMenu.performKeyEquivalent -> \(NSApp.mainMenu?.performKeyEquivalent(with: event) ?? false); string=\(quoted(view.string))")
    NSApp.sendEvent(event)
    say("  [\(label)] NSApp.sendEvent(Cmd-Z); string=\(quoted(view.string))")
    say("  [\(label)] NSApp.sendAction(undo:) -> \(NSApp.sendAction(Selector(("undo:")), to: nil, from: nil)); string=\(quoted(view.string))")
    let fontAfter = fontAt(0)
    say(
        "  [\(label)] text moved=\(before != view.string) font moved=\(fontBefore != fontAfter) (\(fontBefore.map(fontDescription) ?? "nil") -> \(fontAfter.map(fontDescription) ?? "nil"))"
    )
}

func modeUndo() {
    say("== R6 undo scope and suppression ==")
    say("view.undoManager is \(String(describing: view.undoManager.map { ObjectIdentifier($0) }))")
    say("window.undoManager is \(String(describing: window.undoManager.map { ObjectIdentifier($0) }))")
    say("same object = \(view.undoManager === window.undoManager)")

    // --- allowsUndo = true
    view.allowsUndo = true
    reset("hello world")
    say("-- allowsUndo=true, typed text")
    view.insertText("!", replacementRange: NSRange(location: NSNotFound, length: 0))
    say("  after typing: canUndo=\(view.undoManager?.canUndo ?? false) string=\(quoted(view.string))")
    view.undoManager?.undo()
    say("  after undo():  string=\(quoted(view.string))")

    say("-- allowsUndo=true, ATTRIBUTE-ONLY through shouldChangeText(nil)/didChangeText")
    reset("hello world")
    let r = NSRange(location: 0, length: 5)
    let ok = view.shouldChangeText(in: r, replacementString: nil)
    view.textStorage?.addAttribute(.font, value: bold, range: r)
    view.didChangeText()
    let f0 = fontAt(0)
    say("  shouldChangeText(nil) returned \(ok); font at 0 = \(f0.map(fontDescription) ?? "nil")")
    say("  canUndo=\(view.undoManager?.canUndo ?? false) undoActionName=\(view.undoManager?.undoActionName ?? "")")
    view.undoManager?.undo()
    let f1 = fontAt(0)
    say("  after undo(): font at 0 = \(f1.map(fontDescription) ?? "nil") string=\(quoted(view.string))")
    say("  canRedo=\(view.undoManager?.canRedo ?? false)")
    view.undoManager?.redo()
    let f2 = fontAt(0)
    say("  after redo(): font at 0 = \(f2.map(fontDescription) ?? "nil")")

    say("-- allowsUndo=true, attribute change WITHOUT shouldChangeText/didChangeText")
    reset("hello world")
    view.textStorage?.addAttribute(.font, value: bold, range: r)
    say("  canUndo=\(view.undoManager?.canUndo ?? false)")

    say("-- allowsUndo=true, setTextColor: (an AppKit rich-text action)")
    reset("hello world")
    view.isRichText = true
    view.setTextColor(NSColor.systemRed, range: r)
    say("  canUndo=\(view.undoManager?.canUndo ?? false) undoActionName=\(view.undoManager?.undoActionName ?? "")")
    view.undoManager?.undo()
    let c = attrAt(.foregroundColor, 0)
    say("  after undo(): foregroundColor at 0 = \(c.map { "\($0)" } ?? "nil")")
    view.isRichText = false

    // THE POSITIVE CONTROL for the Cmd-Z channel. A negative that was never
    // watched succeeding proves the channel is dead, not the switch (CLAUDE.md
    // invariant 3: watch the negative test fail).
    say("-- POSITIVE CONTROL: Cmd-Z with allowsUndo=TRUE, the same three channels")
    view.allowsUndo = true
    reset("hello world")
    view.insertText("K", replacementRange: NSRange(location: NSNotFound, length: 0))
    say("  typed: string=\(quoted(view.string)) canUndo=\(view.undoManager?.canUndo ?? false)")
    cmdZChannels("control, allowsUndo=true")
    say("  CONTROL VERDICT: Cmd-Z \(view.string == "hello world" ? "DOES" : "does NOT") reach the view in this fixture")

    // --- the flip
    say("-- flipping allowsUndo to FALSE at runtime")
    reset("hello world")
    let before = view.string
    view.allowsUndo = false
    say("  text after the flip = \(quoted(view.string)) unchanged=\(before == view.string)")
    say("  view.undoManager still = \(String(describing: view.undoManager.map { ObjectIdentifier($0) }))")
    window.undoManager?.removeAllActions()
    view.insertText("Z", replacementRange: NSRange(location: NSNotFound, length: 0))
    say("  typed with allowsUndo=false: string=\(quoted(view.string)) view.undoManager?.canUndo=\(view.undoManager?.canUndo ?? false)")
    say("  and the WINDOW's manager: \(window.undoManager == nil ? "nil" : "present") canUndo=\(window.undoManager?.canUndo ?? false) (the chain above the view)")
    let ok2 = view.shouldChangeText(in: r, replacementString: nil)
    view.textStorage?.addAttribute(.font, value: bold, range: r)
    view.didChangeText()
    say("  attribute act with allowsUndo=false: shouldChangeText=\(ok2) view.undoManager?.canUndo=\(view.undoManager?.canUndo ?? false) window canUndo=\(window.undoManager?.canUndo ?? false)")

    say("-- Cmd-Z with allowsUndo=false, three channels, none of them the host UI")
    cmdZChannels("allowsUndo=false")

    say("-- flipping allowsUndo back to TRUE")
    let textBefore2 = view.string
    view.allowsUndo = true
    say("  text after the flip back = \(quoted(view.string)) unchanged=\(textBefore2 == view.string)")
    say("  view.undoManager back to \(String(describing: view.undoManager.map { ObjectIdentifier($0) }))")
    view.undoManager?.removeAllActions()
    view.insertText("Q", replacementRange: NSRange(location: NSNotFound, length: 0))
    say("  typed: string=\(quoted(view.string)) canUndo=\(view.undoManager?.canUndo ?? false)")
    view.undoManager?.undo()
    say("  after undo(): string=\(quoted(view.string))")

    say("-- per-view: a SECOND text view in the same window with allowsUndo=false")
    let content2 = NSTextContentStorage()
    let layout2 = NSTextLayoutManager()
    content2.addTextLayoutManager(layout2)
    let container2 = NSTextContainer(size: CGSize(width: 200, height: CGFloat.greatestFiniteMagnitude))
    layout2.textContainer = container2
    let view2 = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 60), textContainer: container2)
    view2.isEditable = true
    view2.allowsUndo = false
    view2.string = "second"
    window.contentView?.addSubview(view2)
    say("  view2.undoManager identity = \(String(describing: view2.undoManager.map { ObjectIdentifier($0) }))")
    view2.undoManager?.removeAllActions()
    view2.insertText("2", replacementRange: NSRange(location: NSNotFound, length: 0))
    say("  view2 typed with allowsUndo=false: canUndo=\(view2.undoManager?.canUndo ?? false) string=\(quoted(view2.string))")
    view.insertText("1", replacementRange: NSRange(location: NSNotFound, length: 0))
    say("  view1 typed with allowsUndo=true:  canUndo=\(view.undoManager?.canUndo ?? false) string=\(quoted(view.string))")
}

func modeTyping() {
    say("== typing attributes: does a run extend? ==")
    view.isRichText = true
    reset("hello world")
    guard let st = view.textStorage else { return }
    st.addAttribute(.font, value: bold, range: NSRange(location: 0, length: 5))
    st.addAttribute(.link, value: URL(string: "https://kaya.dev/probe")!, range: NSRange(location: 6, length: 5))
    st.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: NSRange(location: 6, length: 5))
    dumpRuns(view.attributedString(), label: "before")

    func caret(_ at: Int, _ label: String) {
        view.setSelectedRange(NSRange(location: at, length: 0))
        say("caret at \(at) (\(label)): typingAttributes -> \(describe(view.typingAttributes))")
    }
    caret(3, "inside the bold run")
    caret(5, "at the END of the bold run")
    caret(0, "at the START of the bold run")
    caret(8, "inside the link run")
    caret(11, "at the END of the link run")
    caret(6, "at the START of the link run")

    say("-- typing at the end of the bold run")
    view.setSelectedRange(NSRange(location: 5, length: 0))
    view.insertText("B", replacementRange: NSRange(location: NSNotFound, length: 0))
    let fb = fontAt(5)
    say("  inserted at 5; font there = \(fb.map(fontDescription) ?? "nil")")

    say("-- typing at the end of the link run")
    let linkEnd = (view.string as NSString).length - "world".count + "world".count
    let end = (view.string as NSString).range(of: "world")
    let after = end.location + end.length
    view.setSelectedRange(NSRange(location: after, length: 0))
    say("  (link ends at \(after); computed \(linkEnd))")
    view.insertText("L", replacementRange: NSRange(location: NSNotFound, length: 0))
    let lk = attrAt(.link, after)
    let ul = attrAt(.underlineStyle, after)
    say("  inserted at \(after); link there = \(lk.map { "\($0)" } ?? "nil") underlineStyle = \(ul.map { "\($0)" } ?? "nil")")
    dumpRuns(view.attributedString(), label: "after")

    say("-- typing INSIDE the link run")
    reset("hello world")
    view.textStorage?.addAttribute(.link, value: URL(string: "https://kaya.dev/probe")!, range: NSRange(location: 6, length: 5))
    view.setSelectedRange(NSRange(location: 8, length: 0))
    view.insertText("Z", replacementRange: NSRange(location: NSNotFound, length: 0))
    let lk2 = attrAt(.link, 8)
    say("  inserted at 8; link there = \(lk2.map { "\($0)" } ?? "nil")")

    say("-- a pinned (isRichText=false) view: does an attribute survive typing at all?")
    view.isRichText = false
    pinPlainText(view)
    reset("hello world")
    view.textStorage?.addAttribute(.font, value: bold, range: NSRange(location: 0, length: 5))
    view.setSelectedRange(NSRange(location: 5, length: 0))
    say("  typingAttributes with isRichText=false -> \(describe(view.typingAttributes))")
    view.insertText("P", replacementRange: NSRange(location: NSNotFound, length: 0))
    let fp = fontAt(5)
    say("  font at 5 = \(fp.map(fontDescription) ?? "nil")")
    dumpRuns(view.attributedString(), label: "pinned after typing")
}

func modeRTF() {
    say("== RTF paste with the rich opinions unpinned ==")
    let sample = richSample()
    dumpRuns(sample, label: "the RTF source")
    let data = sample.rtf(from: NSRange(location: 0, length: sample.length), documentAttributes: [:])!
    say("rtf bytes = \(data.count)")

    for (label, rich, graphics) in [
        ("isRichText=false importsGraphics=false (kaya today)", false, false),
        ("isRichText=true  importsGraphics=false (v1 candidate)", true, false),
        ("isRichText=true  importsGraphics=true  (everything)", true, true),
    ] {
        reset("")
        view.isRichText = rich
        view.importsGraphics = graphics
        let pb = privatePasteboard("rtf\(rich)\(graphics)")
        pb.setData(data, forType: .rtf)
        say("-- \(label)")
        let types = view.readablePasteboardTypes.map { $0.rawValue }
        say("  readablePasteboardTypes: \(types.count) types, first 8 = \(types.prefix(8))")
        let ok = view.readSelection(from: pb)
        say("  readSelection returned \(ok)")
        dumpRuns(view.attributedString(), label: label)
    }

    say("== RTFD with an image attachment ==")
    let att = NSTextAttachment()
    let img = NSImage(size: NSSize(width: 8, height: 8))
    img.lockFocus()
    NSColor.systemBlue.setFill()
    NSRect(x: 0, y: 0, width: 8, height: 8).fill()
    img.unlockFocus()
    att.image = img
    let withImage = NSMutableAttributedString(string: "before ")
    withImage.append(NSAttributedString(attachment: att))
    withImage.append(NSAttributedString(string: " after"))
    let rtfd = withImage.rtfd(
        from: NSRange(location: 0, length: withImage.length), documentAttributes: [:])!
    for (label, rich, graphics) in [
        ("isRichText=true importsGraphics=false", true, false),
        ("isRichText=true importsGraphics=true", true, true),
    ] {
        reset("")
        view.isRichText = rich
        view.importsGraphics = graphics
        let pb = privatePasteboard("rtfd\(graphics)")
        pb.setData(rtfd, forType: .rtfd)
        say("-- \(label)")
        let ok = view.readSelection(from: pb)
        say("  readSelection returned \(ok)")
        say("  string = \(quoted(view.string)) (U+FFFC present = \(view.string.unicodeScalars.contains { $0.value == 0xFFFC }))")
        say("  NSString length = \((view.string as NSString).length), utf8 = \(view.string.utf8.count)")
        dumpRuns(view.attributedString(), label: "rtfd " + label)
    }
    view.isRichText = false
    pinPlainText(view)
}

func modeAXHold() {
    view.isRichText = true
    let s = NSMutableAttributedString(string: "Heading one\nplain bold italic under strike mono link end\n")
    let ns = s.string as NSString
    func r(_ sub: String) -> NSRange { ns.range(of: sub) }
    s.addAttribute(.font, value: NSFont.systemFont(ofSize: 13), range: NSRange(location: 0, length: s.length))
    s.addAttribute(.font, value: headingFont, range: r("Heading one"))
    s.addAttribute(.font, value: bold, range: r("bold"))
    s.addAttribute(.font, value: italic, range: r("italic"))
    s.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: r("under"))
    s.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: r("strike"))
    s.addAttribute(.font, value: mono, range: r("mono"))
    s.addAttribute(.link, value: URL(string: "https://kaya.dev/probe")!, range: r("link"))
    s.addAttribute(.foregroundColor, value: NSColor.systemRed, range: r("end"))
    view.textStorage?.setAttributedString(s)
    view.setAccessibilityIdentifier("richtext-probe")
    view.setAccessibilityLabel("probe notes")
    dumpRuns(view.attributedString(), label: "the held document")
    say("axhold pid=\(ProcessInfo.processInfo.processIdentifier) READY")
    DispatchQueue.main.asyncAfter(deadline: .now() + 45) {
        say("axhold timeout, leaving")
        exit(0)
    }
}

// ------------------------------------------------------------------ main

let mode = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "edits"
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

// An Edit menu of this app's OWN, so the Cmd-Z channel has somewhere to go.
let mainMenu = NSMenu()
let editItem = NSMenuItem()
let editMenu = NSMenu(title: "Edit")
editMenu.addItem(
    NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
let redo = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
redo.keyEquivalentModifierMask = [.command, .shift]
editMenu.addItem(redo)
editItem.submenu = editMenu
mainMenu.addItem(editItem)
app.mainMenu = mainMenu

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ n: Notification) {
        boot()
        say("mode=\(mode) macOS=\(ProcessInfo.processInfo.operatingSystemVersionString)")
        switch mode {
        case "edits": modeEdits()
        case "undo": modeUndo()
        case "undokey":
            // The Cmd-Z channels need a key window, which needs an ACTIVE app.
            // Own window, own menu; the host UI is not touched. Checked idle first.
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(view)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                say("activated: isKeyWindow=\(window.isKeyWindow) NSApp.isActive=\(NSApp.isActive)")
                modeUndo()
                say("DONE undokey")
                exit(0)
            }
            return
        case "typing": modeTyping()
        case "rtf": modeRTF()
        case "axhold":
            modeAXHold()
            return
        default: say("unknown mode \(mode)")
        }
        say("DONE \(mode)")
        exit(0)
    }
}
let delegate = AppDelegate()
app.delegate = delegate
app.run()
