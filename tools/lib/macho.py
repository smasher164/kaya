"""A Mach-O's macOS build stamp, read by hand: `vtool`/`otool` are xcrun
shims that cannot find their tool in the dev shell. One reader for
tools/check-design-generation.py and the mac lane's host wall
(tools/lib/lanes/mac.py require_modern)."""

import struct

FAT_MAGIC, FAT_MAGIC_64 = 0xCAFEBABE, 0xCAFEBABF
MH_MAGIC_64, MH_MAGIC_32 = 0xFEEDFACF, 0xFEEDFACE
CPU_TYPE_ARM64 = 0x0100000C
LC_VERSION_MIN_MACOSX, LC_BUILD_VERSION = 0x24, 0x32
PLATFORM_MACOS = 1
MODERN_FLOOR = (26, 0)


def ver(v):
    """LC_BUILD_VERSION packs x.y.z into a u32 as xxxx.yy.zz."""
    return (v >> 16, (v >> 8) & 0xFF, v & 0xFF)


def show(v):
    return f"{v[0]}.{v[1]}.{v[2]}"


def floor_of(v):
    return f"{v[0]}.{v[1]}"


def arm64_offset(fh):
    """Where the arm64 Mach-O starts: 0 for a thin file, the matching
    slice for a fat one (a universal binary's x86_64 slice can carry a
    different stamp, and the lane runs the arm64 one)."""
    fh.seek(0)
    head = fh.read(8)
    if len(head) < 8:
        return None, f"file is {len(head)} bytes — not a Mach-O"
    magic, count = struct.unpack(">2I", head)
    if magic not in (FAT_MAGIC, FAT_MAGIC_64):
        return 0, None
    for _ in range(count):
        if magic == FAT_MAGIC:
            cpu, _sub, off, _size, _align = struct.unpack(">5I", fh.read(20))
        else:
            cpu, _sub, off, _size, _align, _res = struct.unpack(">IIQQII", fh.read(32))
        if cpu == CPU_TYPE_ARM64:
            return off, None
    return None, f"fat binary with {count} slice(s), none of them arm64"


def stamp(path):
    """(platform, minos, sdk, which load command) or (None, why)."""
    try:
        with open(path, "rb") as fh:
            head = fh.read(2)
            if head == b"#!":
                fh.seek(0)
                line = fh.readline(300).decode("utf-8", "replace").strip()
                return None, (f"is a script, not a Mach-O (first line: {line!r}) — "
                              f"a wrapper moved in front of the real host")
            off, why = arm64_offset(fh)
            if off is None:
                return None, why
            fh.seek(off)
            raw = fh.read(32)
            magic = struct.unpack("<I", raw[:4])[0]
            if magic == MH_MAGIC_64:
                hdr = 32
            elif magic == MH_MAGIC_32:
                hdr = 28
            else:
                return None, f"not a little-endian Mach-O (magic 0x{magic:08x})"
            ncmds = struct.unpack("<I", raw[16:20])[0]
            pos = off + hdr
            for _ in range(ncmds):
                fh.seek(pos)
                cmd, cmdsize = struct.unpack("<2I", fh.read(8))
                if cmdsize < 8:
                    return None, f"load command 0x{cmd:x} has cmdsize {cmdsize}"
                if cmd == LC_BUILD_VERSION:
                    plat, minos, sdk, _ntools = struct.unpack("<4I", fh.read(16))
                    return (plat, ver(minos), ver(sdk), "LC_BUILD_VERSION"), None
                if cmd == LC_VERSION_MIN_MACOSX:
                    minos, sdk = struct.unpack("<2I", fh.read(8))
                    return (PLATFORM_MACOS, ver(minos), ver(sdk), "LC_VERSION_MIN_MACOSX"), None
                pos += cmdsize
            return None, (f"carries neither LC_BUILD_VERSION nor LC_VERSION_MIN_MACOSX "
                          f"in {ncmds} load commands")
    except OSError as exc:
        return None, f"could not be read ({exc.strerror})"
