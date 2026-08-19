package main
import ("fmt"; "strings"; "unicode/utf8"; "unicode/utf16")
func main() {
    s1 := "ab😀cd"; s2 := "ab👨‍👩‍👧‍👦cd"; s3 := "abécd"
    fmt.Println("LANG go")
    fmt.Println("natural_len_S1", len(s1))
    fmt.Println("natural_len_S2", len(s2))
    fmt.Println("natural_index_cd_S2", strings.Index(s2, "cd"))
    fmt.Println("scalars_len_S2", utf8.RuneCountInString(s2))
    fmt.Println("utf16_len_S2", len(utf16.Encode([]rune(s2))))
    cut := s1[:3]
    fmt.Printf("split_codepoint_S1 %q valid_utf8=%v bytes=%v\n", cut, utf8.ValidString(cut), []byte(cut))
    fmt.Printf("split_grapheme_S3 %q\n", s3[:3])
    fmt.Println("stdlib_graphemes NONE (x/text or uniseg required)")
}
