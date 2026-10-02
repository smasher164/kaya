import Foundation
let ins = ["3.5","3,5","1234","1.234","1,234","1.234,5","1,234.5","\u{663}\u{66B}\u{665}","\u{663}\u{664}","\u{661}\u{66C}\u{662}\u{663}\u{664}","3\u{66B}5","\u{663}.\u{665}"]
for loc in ["en_US","de_DE","ar_EG"] {
  let l = Locale(identifier: loc)
  for lenient in [false, true] {
    let f = NumberFormatter(); f.locale = l; f.numberStyle = .decimal; f.isLenient = lenient
    print("== \(loc) lenient=\(lenient) decimal='\(f.decimalSeparator!)' group='\(f.groupingSeparator!)'")
    for s in ins { print("  \(s)\tNF=\(f.number(from: s).map{"\($0)"} ?? "nil")\tFS=\((try? Double(s, format: .number.locale(l))).map{"\($0)"} ?? "nil")") }
  }
}
