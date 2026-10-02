import Foundation
let ins = ["3.5","3,5","1.234","1,234","1.234,5","1,234.5","12,34","٣٫٥","-3,5"]
func kayaParse(_ s: String) -> String {
    // crates/kaya/src/fmt.rs parse_in: CFLocaleCopyCurrent, decimal style, grouping off, whole text
    let f = CFNumberFormatterCreate(nil, CFLocaleCopyCurrent(), .decimalStyle)!
    CFNumberFormatterSetProperty(f, CFNumberFormatterKey.useGroupingSeparator, kCFBooleanFalse)
    var range = CFRange(location: 0, length: (s as NSString).length)
    var v = 0.0
    let ok = CFNumberFormatterGetValueFromString(f, s as CFString, &range, .doubleType, &v)
    return (ok && range.location == 0 && range.length == (s as NSString).length) ? "\(v)" : "nil"
}
func kayaWrite(_ v: Double) -> String {
    let f = CFNumberFormatterCreate(nil, CFLocaleCopyCurrent(), .decimalStyle)!
    CFNumberFormatterSetProperty(f, CFNumberFormatterKey.useGroupingSeparator, kCFBooleanFalse)
    CFNumberFormatterSetProperty(f, CFNumberFormatterKey.minFractionDigits, 1 as CFNumber)
    return CFNumberFormatterCreateStringWithNumber(nil, f, v as CFNumber) as String
}
let cur = Locale.current
print("Locale.current=\(cur.identifier) decimal='\(cur.decimalSeparator ?? "?")' group='\(cur.groupingSeparator ?? "?")' arg-domain AppleICUNumberSymbols=\(UserDefaults.standard.object(forKey: "AppleICUNumberSymbols").map{"\($0)"} ?? "unset")")
let nf = NumberFormatter(); nf.numberStyle = .decimal
print("NumberFormatter() writes 1234.5 as \(nf.string(from: 1234.5)!); kaya door writes 12.5 as \(kayaWrite(12.5))")
for s in ins {
    let a = nf.number(from: s).map{"\($0)"} ?? "nil"
    let b = (try? Double(s, format: .number)).map{"\($0)"} ?? "nil"
    print("  \(s)\tNumberFormatter=\(a)\tFormatStyle(.number)=\(b)\tkaya=\(kayaParse(s))")
}
