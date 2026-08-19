import Foundation
// If a backend ever had to convert a UTF-8 byte offset to an NSRange
// location itself, could it DETECT a bad boundary?
func utf16Offset(ofByte b: Int, in s: String) -> Int? {
    guard b >= 0, b <= s.utf8.count else { return nil }
    let i = s.utf8.index(s.utf8.startIndex, offsetBy: b)
    guard let scalar = i.samePosition(in: s.unicodeScalars) else { return nil }  // mid-codepoint
    return scalar.utf16Offset(in: s)
}
let e = "ab\u{1F600}cd"
var line = ""
for b in 0...e.utf8.count {
    line += " \(b):" + (utf16Offset(ofByte: b, in: e).map { "u16=\($0)" } ?? "REFUSE")
}
print("EMOJI  ab<U+1F600>cd ->" + line)
let z = "ab\u{1F468}\u{200D}\u{1F469}cd"
line = ""
for b in 0...z.utf8.count { line += " \(b):" + (utf16Offset(ofByte: b, in: z).map { "\($0)" } ?? "X") }
print("ZWJ pair ->" + line)
