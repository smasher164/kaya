#!/usr/bin/env python3
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent / "lib"))
from kaya_gate import Gate, dev_shell_or_die

dev_shell_or_die()

# THE SAFE SAVE'S ORDER, ARM BY ARM (docs/rich-document-plan.md §4.1): what
# makes each arm safe is the order of a few calls, and every scene reads the
# same bytes back whatever that order was, since only a crash between two of
# them shows it. Held here:
#   the desktops: the temporary file's fsync before the rename, and Windows'
#     rename with MOVEFILE_WRITE_THROUGH;
#   Android: the persistable grant before the copy, the backup and its record
#     fsynced before the overwrite, the overwrite's fsync and the read-back
#     before the backup is deleted;
#   iOS: everything inside coordinate(writingItemAt:options: .forReplacing),
#     the bytes in the item replacement directory, fsync before replaceItemAt.

import re

CORE = "crates/kaya/src/safesave.rs"
SWIFT = "swift/KayaSwiftUI.swift"

gate = Gate("check-safe-save")


def body(text, anchor):
    """The brace-balanced body of the function whose signature starts at
    `anchor`, or "" when absent."""
    at = text.find(anchor)
    if at < 0:
        return ""
    start = text.find("{", at)
    depth = 0
    for i in range(start, len(text)):
        if text[i] == "{":
            depth += 1
        elif text[i] == "}":
            depth -= 1
            if depth == 0:
                return text[start:i + 1]
    return ""


def ordered(text, steps):
    """The first step out of order or absent, or None. `steps` is a list of
    (name, pattern); each must match after the previous one."""
    at = 0
    for name, pattern in steps:
        m = re.compile(pattern).search(text, at)
        if m is None:
            return name
        at = m.end()
    return None


DESKTOP = [
    ("the temporary file opened create_new", r"\.create_new\(true\)\.open\(&temp\)"),
    ("its bytes written", r"file\.write_all\(bytes\)\?"),
    ("its fsync", r"file\.sync_all\(\)\?"),
    ("the rename over the name", r"rename_over\(&temp, path\)\?"),
    ("the directory's fsync", r"sync_dir\(&dir\)"),
]
WINDOWS = [
    ("MoveFileExW", r"MoveFileExW\("),
    ("REPLACE_EXISTING with WRITE_THROUGH", r"MOVEFILE_REPLACE_EXISTING \| MOVEFILE_WRITE_THROUGH"),
]
ANDROID = [
    ("the persistable grant", r"let grant = doc\.take_grant\(\);"),
    ("the copy of the current contents", r"\.read_all\(\)"),
    ("the backup's fsync", r'write_synced\(&dir\.join\("old"\), &old\)\?'),
    ("the record, after the backup", r"write_record\(&dir, &record\)\?"),
    ("the store's fsync", r"sync_dir\(store\)"),
    ("the overwrite", r"let wrote = overwrite\(doc, bytes, fault\);"),
    ("the read-back check", r"verify\(doc, bytes\)"),
    ("the backup removed only once checked",
     r"Ok\(\(\)\) => \{\s*// 5\.[^\n]*\n\s*if let Err\(e\) = remove_backup\(&dir\)"),
    ("the grant released after the backup", r"release\(grant\);"),
]
OVERWRITE = [
    ("the write", r"file\.write_all\(bytes\)\?;\s*if seekable"),
    ("its fsync", r"file\.sync_all\(\)\?;\s*\}\s*drop\(file\);\s*Ok"),
]
IOS = [
    ("the security scope", r"url\.startAccessingSecurityScopedResource\(\)"),
    ("the coordinated write .forReplacing",
     r"NSFileCoordinator\(filePresenter: nil\)\.coordinate\(\s*"
     r"writingItemAt: url, options: \.forReplacing"),
    ("the item replacement directory", r"for: \.itemReplacementDirectory, in: \.userDomainMask"),
    ("the replacement's bytes", r"write\(fd, raw\.baseAddress!"),
    ("its fsync", r"fsync\(fd\) == 0"),
    ("replaceItemAt", r"manager\.replaceItemAt\(target, withItemAt: temp\)"),
]


def census(texts):
    out = []
    core = texts[CORE]
    for label, anchor, steps in (
            ("the desktops' arm", "pub(crate) fn replace_path(", DESKTOP),
            ("the Windows rename", "#[cfg(windows)]\nfn rename_over(", WINDOWS),
            ("Android's five steps", "pub(crate) fn save_document(", ANDROID),
            ("Android's overwrite", "fn overwrite(doc: &dyn Document", OVERWRITE)):
        found = body(core, anchor)
        if not found:
            out.append(f"{CORE}: {label} is not where this gate reads it ({anchor!r})")
            continue
        missing = ordered(found, steps)
        if missing:
            out.append(f"{CORE}: {label} has {missing} missing or out of order "
                       f"(docs/rich-document-plan.md §4.1)")
    ios = body(texts[SWIFT], 'public func kayaSwiftUISavePicked(')
    if not ios:
        out.append(f"{SWIFT}: the iOS arm kaya_swiftui_save_picked is gone")
    else:
        missing = ordered(ios, IOS)
        if missing:
            out.append(f"{SWIFT}: the iOS arm has {missing} missing or out of order "
                       f"(docs/rich-document-plan.md §4.1)")
        coordinated = body(ios, "writingItemAt: url, options: .forReplacing")
        if "replaceItemAt" not in coordinated or "fsync(fd)" not in coordinated:
            out.append(f"{SWIFT}: the iOS arm's fsync and replaceItemAt are not inside "
                       f"the coordinated write's block")
    return out


REAL = {CORE: gate.read(CORE), SWIFT: gate.read(SWIFT)}
gate.counted("arms read", sum(1 for t in REAL.values() if t), floor=2)


def watched(label, texts, wanted):
    gate.negative(label, lambda: census(texts), want=wanted)


core = REAL[CORE]
watched("the desktop rename before the fsync",
        {**REAL, CORE: gate.doctor("the desktop fsync moved after the rename", core,
                                   r"file\.sync_all\(\)\?;\n        drop\(file\);\n"
                                   r"        rename_over\(&temp, path\)\?;",
                                   "drop(file);\n        rename_over(&temp, path)?;\n"
                                   "        file.sync_all()?;")},
        "the desktops' arm has")
watched("Windows without WRITE_THROUGH",
        {**REAL, CORE: gate.doctor("WRITE_THROUGH dropped", core,
                                   r"MOVEFILE_REPLACE_EXISTING \| MOVEFILE_WRITE_THROUGH,",
                                   "MOVEFILE_REPLACE_EXISTING,")},
        "the Windows rename has")
watched("the copy before the grant",
        {**REAL, CORE: gate.doctor("the grant moved after the copy", core,
                                   r"    let grant = doc\.take_grant\(\);\n",
                                   "", flags=0)},
        "Android's five steps has the persistable grant")
watched("the backup deleted before the check",
        {**REAL, CORE: gate.doctor("verify cut from the check", core,
                                   r"verify\(doc, bytes\)\.map_err",
                                   "Ok::<(), std::io::Error>(()).map_err")},
        "Android's five steps has the read-back check")
watched("the overwrite with no fsync",
        {**REAL, CORE: gate.doctor("the overwrite's fsync cut", core,
                                   r"    file\.write_all\(bytes\)\?;\n    if seekable \{\n"
                                   r"        file\.sync_all\(\)\?;\n    \}\n",
                                   "    file.write_all(bytes)?;\n    if seekable {\n    }\n")},
        "Android's overwrite has")
swift = REAL[SWIFT]
watched("the iOS arm without .forReplacing",
        {**REAL, SWIFT: gate.doctor("the coordinator's option changed", swift,
                                    r"writingItemAt: url, options: \.forReplacing, error",
                                    "writingItemAt: url, options: .forMerging, error")},
        "the coordinated write .forReplacing")
watched("the iOS fsync after replaceItemAt",
        {**REAL, SWIFT: gate.doctor("the iOS fsync cut", swift,
                                    r"let synced = wrote && fsync\(fd\) == 0",
                                    "let synced = wrote")},
        "the iOS arm has")

gate.negatives_ran(7)

for line in census(REAL):
    gate.finding(line)

gate.verdict("the desktops, Android and iOS each sync before the rename, the replace "
             "or the backup's delete")
