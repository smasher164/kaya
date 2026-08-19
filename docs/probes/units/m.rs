fn main() {
    let s1 = "ab😀cd"; let s2 = "ab👨‍👩‍👧‍👦cd"; let s3 = "abécd";
    println!("LANG rust");
    println!("natural_len_S1 {}", s1.len());
    println!("natural_len_S2 {}", s2.len());
    println!("natural_index_cd_S2 {}", s2.find("cd").unwrap());
    println!("scalars_len_S2 {}", s2.chars().count());
    println!("utf16_len_S2 {}", s2.encode_utf16().count());
    println!("is_char_boundary_3_S1 {}", s1.is_char_boundary(3));
    let r = std::panic::catch_unwind(|| s1[..3].to_string());
    println!("split_codepoint_S1 {}", match r { Ok(v) => format!("OK {v:?}"), Err(_) => "PANIC".into() });
    println!("split_grapheme_S3 {:?}", &s3[..3]);
    println!("stdlib_graphemes NONE (unicode-segmentation crate required)");
}
