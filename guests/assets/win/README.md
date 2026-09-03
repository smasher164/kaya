# The minimal Windows resource index

`minimal-resources.pri` — 1040 bytes of MRT (Modern Resource
Technology) package resource index. Every kaya host process on Windows
needs one of these **beside its executable**, and this is the smallest
one that satisfies the requirement.

## What it is for

WinUI resolves `ms-appx:` URIs against the directory of the **process
executable** — not the DLL, not the working directory. Several control
templates merge `XamlControlsResources` through `ms-appx`, and in an
unpackaged process with no index beside the exe the XAML parser
fail-fasts with `0xC000027B` (a bare
`RoFailFastWithErrorContextInternal2`) at realization. The rule and the
measurement are in docs/traps.md, "WinUI resource resolution is anchored
to the PROCESS exe's directory".

That is why the file has to travel with the guests rather than live
beside the backend. kaya's Rust scene binaries sit beside it and work;
`python.exe`, `java.exe`, `dotnet.exe` and a `go run` temp executable do
not, so tools/deploy-win.py puts a copy beside each host it launches.
The copy is inert for a program that never touches WinUI.

## Where it came from, honestly

**Nobody knows, and this paragraph is the point of this file.** The
index was committed once, in `cc5999d` ("get windows working the
official way", 2026-07-15), with no provenance note and no recipe. Its
contents are readable enough to say what it declares — the MRT sections
`[mrm_pridescex]`, `[mrm_hschemaex]`, `[mrm_res_map2_]` and two
`[mrm_dataitem]` entries, naming one resource map called
`KayaPlaceholder` and one `priconfig.xml` — but nothing in this tree
produced them and nothing in this tree can reproduce them.

## How to regenerate it, when someone needs to

Not attempted, and written down so the next reader does not have to
rediscover the shape:

    makepri createconfig /cf priconfig.xml /dq en-US
    makepri new /pr <project dir> /cf priconfig.xml /of resources.pri

`makepri.exe` ships with the Windows SDK and is not in this repo's dev
shell, so regeneration is a Windows-VM operation. Until someone does it,
this file is a vendored binary with a known job and an unknown author,
which is exactly the state a family README exists to make visible rather
than to hide.

## Why it lives here

It is bulk data that a build stages onto a machine, which is what an
asset is (docs/assets-plan.md A2). It sat under `tools/guest/` beside a
shell script for two milestones, filed as a tool because a tool shipped
it — and the survey that found it found it precisely by asking which
files under the asset convention had no README (docs/assets-plan.md A1.1
and A6, gate 3).

The deploy still ships it every run and still hashes it into the deploy
stamp (tools/deploy-win.py); only its path moved.

## Licence

None, and none is needed: the index carries no third-party code and no
third-party content. It declares one empty resource map named
`KayaPlaceholder` and a `priconfig.xml` entry — data about this
repository's own (absent) resources — produced by a Microsoft SDK tool
whose OUTPUT belongs to whoever ran it. There is no upstream project to
credit and no terms to reproduce, which is the one hygiene question a
vendored binary asks, answered here rather than left to be looked up.
