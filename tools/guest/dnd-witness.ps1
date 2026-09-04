# THE WINDOWS CROSS-APP DRAG WITNESSES (docs/dnd-plan.md §5 step 7, D9).
# A real SendInput drag between kaya's window and a FOREIGN Win32 process
# — tools/win/dragprobe/stock, the same stock OLE app probes 1 and 2 were
# measured against — in the interactive session, because a drag is real
# mouse input and OLE's modal loop reads the real message queue.
#
# Both directions assert through kaya's OWN MODEL, read back out of the
# running app over UI Automation: the guest's drop_status label is what
# the app wrote when the occurrence arrived, so a green witness is kaya
# having taken a foreign payload, not a log line about one.
#
# -Direction out: kaya is the SOURCE (XAML DragStarting fills a
#   DataPackage) and the stock OLE window is the reader — probe 1's
#   forward direction with kaya's real app in the probe's place.
# -Direction in: the stock window is the SOURCE (DoDragDrop over a
#   hand-rolled IDataObject carrying text and CF_HDROP) and kaya's
#   classic-OLE target takes it. This is the route's REASON: XAML's
#   AllowDrop registers no OLE drop target on any of a WinUI window's
#   HWNDs, so a Win32 source reaches kaya here or nowhere. Explorer
#   follows as the third phase, the shape probe 2 measured.
param([string]$Direction = "out")

$ErrorActionPreference = "Continue"
$Root = "C:\kaya"
# $FilesDir, NOT $Files: PowerShell variable names are CASE-INSENSITIVE,
# so a local `$files` holding a drop point IS this one, and the folder
# Explorer is then opened on is a pair of screen coordinates (measured
# 2026-09-03 — Explorer opened on Documents and the item census read
# empty; docs/traps.md).
$Stock = "$Root\dragprobe\src\stock\bin\Release\net10.0-windows\win-arm64\StockOle.exe"
$FilesDir = "$Root\dndwitness"
$StockLog = "$FilesDir\stock.txt"
$Failures = New-Object System.Collections.ArrayList

function Say($m) { Write-Host ((Get-Date).ToString("HH:mm:ss.fff") + " WITNESS " + $m) }
function Fail($m) { [void]$Failures.Add($m); Say "FAIL $m" }

Add-Type @"
using System;
using System.Runtime.InteropServices;
public class W {
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr lp);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr h, System.Text.StringBuilder sb, int max);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint f, uint dx, uint dy, uint d, IntPtr e);
  [DllImport("user32.dll")] public static extern int GetSystemMetrics(int i);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
  public const uint MOVE = 0x0001, ABSOLUTE = 0x8000, LEFTDOWN = 0x0002, LEFTUP = 0x0004;
  public const uint SWP_NOZORDER = 0x0004;
}
"@

Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes

$ScreenW = [W]::GetSystemMetrics(0)
$ScreenH = [W]::GetSystemMetrics(1)

function MoveTo($x, $y) {
    [W]::mouse_event([W]::MOVE -bor [W]::ABSOLUTE,
                     [int](($x * 65535) / ($ScreenW - 1)),
                     [int](($y * 65535) / ($ScreenH - 1)), 0, [IntPtr]::Zero)
    [W]::SetCursorPos($x, $y) | Out-Null
}

# The measured gesture (docs/probes/dnd-probe-windows-2026-09-03.md's
# drive.ps1, which is also the shape inject_drag takes): a settle, the
# press, six small moves inside the source past the system's drag
# threshold, a stepped path, a pause, one nudge, the release.
function Drag($x1, $y1, $x2, $y2) {
    Say "drag $x1,$y1 -> $x2,$y2"
    MoveTo $x1 $y1
    Start-Sleep -Milliseconds 500
    [W]::mouse_event([W]::LEFTDOWN, 0, 0, 0, [IntPtr]::Zero)
    Start-Sleep -Milliseconds 300
    for ($i = 1; $i -le 6; $i++) { MoveTo ($x1 + $i * 3) ($y1 + $i * 2); Start-Sleep -Milliseconds 60 }
    for ($i = 1; $i -le 30; $i++) {
        $t = $i / 30.0
        MoveTo ([int]($x1 + ($x2 - $x1) * $t)) ([int]($y1 + ($y2 - $y1) * $t))
        Start-Sleep -Milliseconds 60
    }
    MoveTo $x2 $y2
    Start-Sleep -Milliseconds 400
    MoveTo ($x2 + 2) ($y2 + 1)
    Start-Sleep -Milliseconds 300
    [W]::mouse_event([W]::LEFTUP, 0, 0, 0, [IntPtr]::Zero)
    Start-Sleep -Milliseconds 1500
}

function KayaWindow($seconds) {
    $deadline = (Get-Date).AddSeconds($seconds)
    $cond = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::ClassNameProperty,
        "WinUIDesktopWin32WindowClass")
    while ((Get-Date) -lt $deadline) {
        $w = [System.Windows.Automation.AutomationElement]::RootElement.FindFirst(
            [System.Windows.Automation.TreeScope]::Children, $cond)
        if ($w) { return $w }
        Start-Sleep -Milliseconds 400
    }
    return $null
}

# Every Name kaya's window publishes, in tree order — the diagnostic every
# failure below prints, so a miss says what the app actually showed rather
# than only what it wanted.
function KayaNames($win) {
    $out = New-Object System.Collections.ArrayList
    $cond = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
        [System.Windows.Automation.ControlType]::Text)
    $all = $win.FindAll([System.Windows.Automation.TreeScope]::Descendants, $cond)
    foreach ($e in $all) { [void]$out.Add($e.Current.Name) }
    return $out
}

function KayaPoint($win, $name) {
    $cond = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::NameProperty, $name)
    $e = $win.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $cond)
    if (-not $e) { return $null }
    $r = $e.Current.BoundingRectangle
    if ($r.Width -le 0 -or $r.Height -le 0) { return $null }
    return @([int]($r.X + $r.Width / 2), [int]($r.Y + $r.Height / 2))
}

function AwaitName($win, $prefix, $seconds, $what) {
    $deadline = (Get-Date).AddSeconds($seconds)
    while ((Get-Date) -lt $deadline) {
        foreach ($n in (KayaNames $win)) { if ($n -like "$prefix*") { Say "$what -> `"$n`""; return $n } }
        Start-Sleep -Milliseconds 300
    }
    Fail "$what : kaya never showed a label starting `"$prefix`"; it showed [$((KayaNames $win) -join ' | ')]"
    return $null
}

function WaitForLine($file, $needle, $seconds) {
    $deadline = (Get-Date).AddSeconds($seconds)
    while ((Get-Date) -lt $deadline) {
        if (Test-Path $file) {
            foreach ($l in (Get-Content -Path $file -ErrorAction SilentlyContinue)) {
                if ($l -like "*$needle*") { return $l }
            }
        }
        Start-Sleep -Milliseconds 300
    }
    return $null
}

function StopAll() {
    foreach ($n in @("dnd", "StockOle")) {
        Get-Process -Name $n -ErrorAction SilentlyContinue | ForEach-Object {
            Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
        }
    }
    Start-Sleep -Milliseconds 600
}

# The VISIBLE top-level windows of a class, EnumWindows-style. NOT
# UIA's RootElement children: a shell window that has been asked to Quit
# lingers in that tree, and FindFirst answered it (measured 2026-09-03 —
# the item enumeration read ZERO list items for 25s against a window that
# was on its way out).
function WindowsOfClass($cls) {
    $found = New-Object System.Collections.ArrayList
    $cb = [W+EnumProc] {
        param($hh, $ll)
        if ([W]::IsWindowVisible($hh)) {
            $c = New-Object System.Text.StringBuilder 256
            [W]::GetClassName($hh, $c, 256) | Out-Null
            if ($c.ToString() -eq $cls) { [void]$found.Add($hh) }
        }
        return $true
    }
    [W]::EnumWindows($cb, [IntPtr]::Zero) | Out-Null
    return $found
}

function CloseExplorerWindows() {
    try {
        $shell = New-Object -ComObject Shell.Application
        foreach ($w in @($shell.Windows())) {
            try { if ($w.FullName -like "*explorer.exe*") { $w.Quit() } } catch { }
        }
    } catch { }
    Start-Sleep -Milliseconds 800
}

# ---------------------------------------------------------------------

Say "direction $Direction on a ${ScreenW}x${ScreenH} screen"
StopAll
Remove-Item -Path $FilesDir -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $FilesDir -Force | Out-Null
# NO BOM and no trailing newline: the guest reads the file back verbatim
# and the scene's own strings are what the assertions compare.
[IO.File]::WriteAllText("$FilesDir\note.txt", "foreign bytes",
                        (New-Object Text.UTF8Encoding $false))
[IO.File]::WriteAllText("$FilesDir\explorer.txt", "explorer bytes",
                        (New-Object Text.UTF8Encoding $false))

if (-not (Test-Path $Stock)) {
    Fail "the stock OLE witness is not built at $Stock (tools/deploy-win.py builds it beside the C# guests)"
}

# kaya at tile slot 0 (6,6 556x378) and the stock window clear of it, so
# neither window is ever under the other's drop point.
$env:KAYA_WIN_SLOT = "0"
Remove-Item Env:\KAYA_SELFTEST -ErrorAction SilentlyContinue
if ($Failures.Count -eq 0) {
    Say "starting kaya dnd.exe with no scene"
    Start-Process -FilePath "$Root\dnd.exe" -WorkingDirectory $Root | Out-Null
}
$win = KayaWindow 60
if (-not $win) { Fail "kaya's window never appeared (class WinUIDesktopWin32WindowClass)" }

$sx = [Math]::Min(580, $ScreenW - 440)
$sy = [Math]::Min(400, $ScreenH - 380)
$sw = [Math]::Min(420, $ScreenW - $sx - 10)
$sh = [Math]::Min(360, $ScreenH - $sy - 10)
$stockCentre = @([int]($sx + $sw / 2), [int]($sy + $sh / 2))

if ($Failures.Count -eq 0 -and $Direction -eq "out") {
    $env:KAYA_DP_LOG = $StockLog
    $env:KAYA_DP_TTL = "120"
    Start-Process -FilePath $Stock -ArgumentList "target $sx $sy $sw $sh" | Out-Null
    if (-not (WaitForLine $StockLog "stock READY" 40)) {
        Fail "the stock OLE reader never printed READY"
    } else {
        $src = KayaPoint $win "hello"
        if (-not $src) {
            Fail "kaya's drag source (the label reading `"hello`") has no box; the window showed [$((KayaNames $win) -join ' | ')]"
        } else {
            Drag $src[0] $src[1] $stockCentre[0] $stockCentre[1]
            # WHAT THE FOREIGN READER GOT, both representations named
            # separately: probe 1 measured the custom id crossing as a
            # stream and the text as UTF-16, and a witness that checked
            # only one would pass with the other silently gone.
            $custom = WaitForLine $StockLog 'OLE custom "dev.kaya/note"' 30
            if (-not $custom) { Fail "the stock reader never reported the custom format" }
            elseif ($custom -notlike '*utf8="note!"*') { Fail "the stock reader read the custom id as: $custom" }
            else { Say "foreign reader got the custom id: $custom" }
            $text = WaitForLine $StockLog "OLE CF_UNICODETEXT" 10
            if (-not $text) { Fail "the stock reader never reported CF_UNICODETEXT" }
            elseif ($text -notlike '*"hello"*') { Fail "the stock reader read the text as: $text" }
            else { Say "foreign reader got the text: $text" }
            # AND KAYA'S OWN SIDE: DropCompleted is where a source learns
            # what a FOREIGN destination did with it (D1).
            AwaitName $win "drag ended copy" 20 "kaya's source learned the outcome" | Out-Null
        }
    }
}

if ($Failures.Count -eq 0 -and $Direction -eq "in") {
    $env:KAYA_DP_LOG = $StockLog
    $env:KAYA_DP_TTL = "180"
    $env:KAYA_DP_FILE = "$FilesDir\note.txt"
    Start-Process -FilePath $Stock -ArgumentList "source $sx $sy $sw $sh" | Out-Null
    if (-not (WaitForLine $StockLog "stock READY" 40)) {
        Fail "the stock OLE source never printed READY"
    } else {
        $textPoint = KayaPoint $win "text target"
        if (-not $textPoint) {
            Fail "kaya's text destination has no box; the window showed [$((KayaNames $win) -join ' | ')]"
        } else {
            Drag $stockCentre[0] $stockCentre[1] $textPoint[0] $textPoint[1]
            AwaitName $win "text target got text kaya stock text (copy)" 20 `
                "kaya took the foreign text" | Out-Null
        }
        $filesPoint = KayaPoint $win "files target"
        if (-not $filesPoint) {
            Fail "kaya's files destination has no box; the window showed [$((KayaNames $win) -join ' | ')]"
        } else {
            Drag $stockCentre[0] $stockCentre[1] $filesPoint[0] $filesPoint[1]
            # A DROPPED FILE IS A PICKED FILE (D6): the guest opens what it
            # was handed through the picked table and prints the bytes, so
            # this line is the redemption and not just the name.
            AwaitName $win "files target got note.txt foreign bytes (copy)" 20 `
                "kaya took the foreign file" | Out-Null
        }
    }
}

# EXPLORER, the single most-wanted foreign source (probe 2). Its own
# phase of the `in` leg, and its own file, so the label it produces
# cannot be the previous drop's.
if ($Failures.Count -eq 0 -and $Direction -eq "in") {
    Get-Process -Name StockOle -ErrorAction SilentlyContinue |
        ForEach-Object { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue }
    CloseExplorerWindows
    Start-Process explorer.exe $FilesDir
    # ONE POLL over the WHOLE question — which windows exist, whether UIA
    # answers for each, and what each lists — because "no window", "a
    # window UIA will not bind" and "a window with no items" are three
    # different findings and one `[]` cannot tell them apart.
    $item = $null
    $census = "nothing was enumerated at all"
    $placed = @{}
    $deadline = (Get-Date).AddSeconds(45)
    while ((Get-Date) -lt $deadline -and -not $item) {
        $rows = New-Object System.Collections.ArrayList
        foreach ($h in (WindowsOfClass "CabinetWClass")) {
            if (-not $placed.ContainsKey([string]$h)) {
                # PLACED CLEAR OF KAYA, and big enough to list: Explorer
                # opens where it last was, which on this VM is over the
                # tile slot 0 window the drag has to reach.
                $ex = [int][Math]::Min(690, $ScreenW - $sx - 10)
                $ey = [int][Math]::Min(390, $ScreenH - $sy - 10)
                [W]::SetWindowPos($h, [IntPtr]::Zero, $sx, $sy, $ex, $ey, [W]::SWP_NOZORDER) | Out-Null
                $placed[[string]$h] = $true
                Start-Sleep -Milliseconds 1500
            }
            $e = [System.Windows.Automation.AutomationElement]::FromHandle($h)
            if (-not $e) { [void]$rows.Add("0x$($h.ToString('x')) UIA would not bind"); continue }
            $names = New-Object System.Collections.ArrayList
            $items = $e.FindAll([System.Windows.Automation.TreeScope]::Descendants,
                (New-Object System.Windows.Automation.PropertyCondition(
                    [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
                    [System.Windows.Automation.ControlType]::ListItem)))
            foreach ($it in $items) {
                [void]$names.Add($it.Current.Name)
                if ($it.Current.Name -like "explorer*") { $item = $it }
            }
            [void]$rows.Add("0x$($h.ToString('x')) '$($e.Current.Name)' items=$($items.Count) [$($names -join ' | ')]")
        }
        $census = $rows -join " ;; "
        if (-not $item) { Start-Sleep -Milliseconds 900 }
    }
    if (-not $item) {
        Fail "no Explorer list item named explorer.txt; the last census of visible CabinetWClass windows was: $census"
    } else {
        $r = $item.Current.BoundingRectangle
        $filesPoint = KayaPoint $win "files target"
        if (-not $filesPoint) {
            Fail "kaya's files destination has no box before the Explorer drag"
        } else {
            Drag ([int]($r.X + $r.Width / 2)) ([int]($r.Y + $r.Height / 2)) $filesPoint[0] $filesPoint[1]
            AwaitName $win "files target got explorer.txt explorer bytes (copy)" 25 `
                "kaya took a file dragged out of Explorer" | Out-Null
        }
    }
    CloseExplorerWindows
}

StopAll
if ($Failures.Count -eq 0) {
    Write-Host "KAYA_SELFTEST: OK (dnd witness $Direction)"
} else {
    Write-Host "KAYA_SELFTEST: FAILED (dnd witness $Direction): $($Failures -join '; ')"
}
if (Test-Path $StockLog) {
    Write-Host "===== the foreign process's own log ====="
    Get-Content -Path $StockLog | ForEach-Object { Write-Host "  $_" }
}
# THE LEG'S EXIT CODE, not just its sentence: deploy-win reads the
# verdict TEXT first and EXIT= second, and a driver that always left 0
# would make the second half agree with everything.
if ($Failures.Count -ne 0) { exit 1 }
