S1 = 'ab😀cd'
S2 = 'ab👨\u200d👩\u200d👧\u200d👦cd'
S3 = 'abécd'
print("LANG python")
print("natural_len_S1", len(S1))
print("natural_len_S2", len(S2))
print("natural_index_cd_S2", S2.index("cd"))
print("bytes_len_S2", len(S2.encode()))
print("utf16_len_S2", len(S2.encode("utf-16-le"))//2)
# code-point indices cannot split a scalar; they CAN split a grapheme:
print("split_grapheme_S3", repr(S3[:3]), "->utf8", S3[:3].encode())
print("stdlib_graphemes", "NONE (no segmentation in stdlib)")
