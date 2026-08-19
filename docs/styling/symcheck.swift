import AppKit
let names = ["plus","minus","trash","pencil","checkmark","xmark","magnifyingglass",
             "square.and.arrow.up","square.and.arrow.down","gearshape","folder",
             "arrow.clockwise","info.circle","exclamationmark.triangle","exclamationmark.octagon",
             "chevron.backward","chevron.forward","line.3.horizontal","ellipsis.circle",
             "doc.on.doc","doc.on.clipboard","star","lock","person","house",
             // canaries: these MUST fail, or the check proves nothing
             "kaya.definitely.not.a.symbol","house.of.leaves.bogus"]
var bad: [String] = []
for n in names {
    let img = NSImage(systemSymbolName: n, accessibilityDescription: nil)
    let ok = img != nil
    print("\(ok ? "resolves" : "NIL     ")  \(n)")
    if !ok { bad.append(n) }
}
print("---")
print("nil names: \(bad)")
