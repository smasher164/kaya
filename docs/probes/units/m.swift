import Foundation
let s1 = "ab😀cd", s2 = "ab👨‍👩‍👧‍👦cd", s3 = "abécd"
print("LANG swift")
print("natural_len_S1", s1.count)              // Characters = extended grapheme clusters
print("natural_len_S2", s2.count)
print("natural_index_cd_S2", s2.distance(from: s2.startIndex, to: s2.range(of: "cd")!.lowerBound))
print("scalars_len_S2", s2.unicodeScalars.count)
print("utf16_len_S2", s2.utf16.count)
print("bytes_len_S2", s2.utf8.count)
print("nsstring_length_S2", (s2 as NSString).length)
// A mid-surrogate UTF-16 offset turned into a String.Index:
let mid = String.Index(utf16Offset: 3, in: s1)
print("utf16Offset3_roundtrip", mid.utf16Offset(in: s1), "prefix=", String(s1[s1.startIndex..<mid]).debugDescription)
print("split_grapheme_S3", String(s3.prefix(3)).debugDescription, "count=", s3.prefix(3).count)
