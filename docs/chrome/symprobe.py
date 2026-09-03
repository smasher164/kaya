import re, pathlib
p = pathlib.Path('/Users/akhilindurti/Projects/kaya/swift/KayaSwiftUI.swift')
lines = p.read_text().splitlines()
# track #if os(...) nesting the way check-verbs.py does, but record the condition
stack = []
ctx = []
for line in lines:
    t = line.strip()
    if t.startswith('#endif'):
        if stack: stack.pop()
    ctx.append(list(stack))
    if t.startswith('#if'):
        stack.append(t)
    elif t.startswith('#else') and stack:
        stack[-1] = '#else of ' + stack[-1]
    elif t.startswith('#elseif') and stack:
        stack[-1] = t

print("=== reads of `.symbol` (not writes) in KayaSwiftUI.swift ===")
for n,(line,c) in enumerate(zip(lines,ctx),1):
    if re.search(r'\.symbol\b', line) and not re.search(r'\.symbol\s*=[^=]', line):
        print(f"{n}: cond={c!r}\n    {line.strip()}")
print()
print("=== writes to `.symbol` ===")
for n,(line,c) in enumerate(zip(lines,ctx),1):
    if re.search(r'\.symbol\s*=[^=]', line):
        print(f"{n}: cond={c!r}\n    {line.strip()}")
