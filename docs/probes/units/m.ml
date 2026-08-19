let () =
  let s1 = "ab😀cd" and s2 = "ab👨‍👩‍👧‍👦cd" and s3 = "abécd" in
  print_endline "LANG ocaml";
  Printf.printf "natural_len_S1 %d\n" (String.length s1);
  Printf.printf "natural_len_S2 %d\n" (String.length s2);
  (* index of "cd" *)
  let idx hay needle =
    let n = String.length needle and h = String.length hay in
    let rec go i = if i + n > h then -1
      else if String.sub hay i n = needle then i else go (i+1) in go 0 in
  Printf.printf "natural_index_cd_S2 %d\n" (idx s2 "cd");
  (* scalars via Stdlib's UTF-8 decoder (4.14+) *)
  let scalars s =
    let i = ref 0 and n = ref 0 in
    while !i < String.length s do
      let d = String.get_utf_8_uchar s !i in
      i := !i + Uchar.utf_decode_length d; incr n
    done; !n in
  Printf.printf "scalars_len_S2 %d\n" (scalars s2);
  let cut = String.sub s1 0 3 in
  Printf.printf "split_codepoint_S1 len=%d bytes=" (String.length cut);
  String.iter (fun c -> Printf.printf "%02x " (Char.code c)) cut;
  print_newline ();
  let d = String.get_utf_8_uchar s1 3 in
  Printf.printf "decode_at_byte3_valid=%b\n" (Uchar.utf_decode_is_valid d);
  Printf.printf "split_grapheme_S3 %d\n" (String.length (String.sub s3 0 3));
  print_endline "stdlib_graphemes NONE (Uuseg required)"
