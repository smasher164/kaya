import unicodedata
cases = {
 "EMOJI  a<U+1F600>b": "a\U0001F600b",
 "COMBIN ae<U+0301>b": "aéb",
 "ZWJ    a<family>b" : "a\U0001F468‍\U0001F469‍\U0001F467‍\U0001F466b",
 "CJK    a<3 han>b"  : "a日本語b",
 "CRLF   a<CR><LF>b" : "a\r\nb",
 "FLAG   a<US flag>b": "a\U0001F1FA\U0001F1F8b",
}
def utf16len(s): return len(s.encode('utf-16-le'))//2
print(f"{'case':22} {'bytes':>5} {'utf16':>5} {'scalars':>7} {'graphemes(approx)':>17}")
for k,v in cases.items():
    print(f"{k:22} {len(v.encode()):5} {utf16len(v):5} {len(v):7}")
print()
for k,v in cases.items():
    print("### ", k, repr(v))
    b=0; u=0
    print(f"  {'scalar':>6} {'char':10} {'name':38} {'byteoff':>7} {'u16off':>6}")
    for i,ch in enumerate(v):
        try: nm = unicodedata.name(ch)
        except ValueError: nm = "<%04X>"%ord(ch)
        print(f"  {i:6} U+{ord(ch):05X}  {nm[:38]:38} {b:7} {u:6}")
        b += len(ch.encode()); u += utf16len(ch)
    print(f"  {'END':6} {'':8} {'':38} {b:7} {u:6}")
    print()
