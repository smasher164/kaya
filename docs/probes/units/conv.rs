use std::time::Instant;

/// byte offset -> UTF-16 code-unit offset (what AppKit/UIKit/WinUI/Compose want)
fn utf16_of(s: &str, byte: usize) -> Option<usize> {
    if !s.is_char_boundary(byte) { return None; }        // O(1) validation
    Some(s[..byte].encode_utf16().count())               // O(byte)
}
/// byte offset -> code-point offset (what GTK's text iters want)
fn scalar_of(s: &str, byte: usize) -> Option<usize> {
    if !s.is_char_boundary(byte) { return None; }
    Some(s[..byte].chars().count())
}
/// one pass, all offsets at once
fn utf16_many(s: &str, bytes: &[usize]) -> Vec<Option<usize>> {
    let mut want: Vec<(usize, usize)> = bytes.iter().copied().enumerate().map(|(i,b)|(b,i)).collect();
    want.sort_unstable();
    let mut out = vec![None; bytes.len()];
    let mut u16at = 0usize; let mut b = 0usize; let mut w = 0usize;
    for ch in s.chars() {
        while w < want.len() && want[w].0 == b { out[want[w].1] = Some(u16at); w += 1; }
        while w < want.len() && want[w].0 < b + ch.len_utf8() && want[w].0 > b { out[want[w].1] = None; w += 1; }
        b += ch.len_utf8(); u16at += ch.len_utf16();
    }
    while w < want.len() && want[w].0 == b { out[want[w].1] = Some(u16at); w += 1; }
    out
}

fn main() {
    // A realistic editor buffer: 400 lines of mixed Latin/CJK/emoji.
    let mut s = String::new();
    for i in 0..400 {
        s.push_str(&format!("line {i:03} the quick brown fox jumps — 日本語のテキスト 😀 and back to ascii\n"));
    }
    println!("buffer: {} bytes, {} scalars, {} utf16 units, {} lines",
        s.len(), s.chars().count(), s.encode_utf16().count(), s.lines().count());

    // 50 ranges (100 offsets), spread through the buffer, all valid.
    let mut offs: Vec<usize> = Vec::new();
    let mut i = 0;
    while offs.len() < 100 && i < s.len() { if s.is_char_boundary(i) { offs.push(i); } i += 61; }
    assert_eq!(offs.len(), 100, "needed 100 valid offsets");

    let t = Instant::now();
    let mut acc = 0usize;
    for _ in 0..100 { for &o in &offs { acc += utf16_of(&s, o).unwrap_or(0); } }
    let naive = t.elapsed() / 100;
    let t = Instant::now();
    for _ in 0..100 { let v = utf16_many(&s, &offs); acc += v[0].unwrap_or(0); }
    let onepass = t.elapsed() / 100;
    let t = Instant::now();
    for _ in 0..100 { for &o in &offs { acc += scalar_of(&s, o).unwrap_or(0); } }
    let scalars = t.elapsed() / 100;
    let t = Instant::now();
    let mut ok = 0usize;
    for _ in 0..1000 { for &o in &offs { if s.is_char_boundary(o) { ok += 1; } } }
    let validate = t.elapsed() / 1000;
    println!("100 offsets, per call-set:");
    println!("  utf16_of naive (O(n) each): {naive:?}");
    println!("  utf16_many one pass:        {onepass:?}");
    println!("  scalar_of naive:            {scalars:?}");
    println!("  is_char_boundary only:      {validate:?}   (ok={ok})");
    println!("  (acc {acc})");

    // agreement between the two implementations
    let a: Vec<Option<usize>> = offs.iter().map(|&o| utf16_of(&s, o)).collect();
    let b = utf16_many(&s, &offs);
    println!("naive == one-pass: {}", a == b);

    // and the refusal case: every non-boundary byte in the emoji
    let e = "ab\u{1F600}cd";
    for i in 0..=e.len() {
        print!(" {i}:{}", if e.is_char_boundary(i) { format!("u16={}", utf16_of(e, i).unwrap()) } else { "REFUSE".into() });
    }
    println!();
}
