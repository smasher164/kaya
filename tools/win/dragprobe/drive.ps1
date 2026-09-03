# The interactive-session driver for the drag probe (docs/dnd-plan.md §2
# probes 1 and 2). An ssh session has its own window station and can
# neither see these windows nor synthesize input into them
# (docs/traps.md), so this runs as a `schtasks /it` task; run.py on the mac
# schedules it and reads the logs back.
#
# Real input, the caption probe's proven shape (crates/kaya/src/winui/
# title-centre-probe.ps1): absolute mouse_event moves with a press, a
# stepped path and a release. OLE's modal loop reads the real message
# queue, so nothing programmatic can stand in for it.
param([string]$Scenario = "a-winrt-to-win32")

$ErrorActionPreference = "Continue"
$Root = "C:\kaya\dragprobe"
$WinUiExe = "$Root\src\winui\bin\Release\net10.0-windows10.0.26100.0\win-arm64\KayaDragProbe.exe"
$StockExe = "$Root\src\stock\bin\Release\net10.0-windows\win-arm64\StockOle.exe"
$DriveLog = "$Root\log-drive.txt"

function Say($m) {
    $line = (Get-Date).ToString("HH:mm:ss.fff") + " DRIVE " + $m
    Add-Content -Path $DriveLog -Value $line
    Write-Host $line
}

Add-Type @"
using System;
using System.Runtime.InteropServices;
public struct RECT { public int Left, Top, Right, Bottom; }
public class U {
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr lp);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr h, System.Text.StringBuilder sb, int max);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h, System.Text.StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint f, uint dx, uint dy, uint d, IntPtr e);
  [DllImport("user32.dll")] public static extern int GetSystemMetrics(int i);
  public const uint MOVE = 0x0001, ABSOLUTE = 0x8000, LEFTDOWN = 0x0002, LEFTUP = 0x0004;
  public const uint SWP_NOZORDER = 0x0004, SWP_NOACTIVATE = 0x0010;

  // THE INTEGRITY LEVEL, MEASURED RATHER THAN ASSUMED: with UAC off there
  // is no split token and every process shares one level, which is the
  // only honest answer to "elevated versus not" on this VM.
  [DllImport("kernel32.dll")] public static extern IntPtr OpenProcess(uint access, bool inherit, int pid);
  [DllImport("kernel32.dll")] public static extern bool CloseHandle(IntPtr h);
  [DllImport("advapi32.dll", SetLastError=true)] public static extern bool OpenProcessToken(IntPtr p, uint access, out IntPtr tok);
  [DllImport("advapi32.dll", SetLastError=true)] public static extern bool GetTokenInformation(IntPtr tok, int cls, IntPtr buf, int len, out int ret);
  [DllImport("advapi32.dll", CharSet=CharSet.Unicode, SetLastError=true)] public static extern bool ConvertSidToStringSidW(IntPtr sid, out IntPtr str);
  [DllImport("kernel32.dll")] public static extern IntPtr LocalFree(IntPtr p);

  public static string Integrity(int pid) {
    IntPtr proc = OpenProcess(0x1000, false, pid);
    if (proc == IntPtr.Zero) return "<no access to pid " + pid + ">";
    try {
      IntPtr tok;
      if (!OpenProcessToken(proc, 0x0008, out tok)) return "<no token>";
      try {
        int need;
        GetTokenInformation(tok, 25, IntPtr.Zero, 0, out need);
        IntPtr buf = Marshal.AllocHGlobal(need);
        try {
          if (!GetTokenInformation(tok, 25, buf, need, out need)) return "<no integrity>";
          IntPtr sid = Marshal.ReadIntPtr(buf);
          IntPtr str;
          if (!ConvertSidToStringSidW(sid, out str)) return "<no sid>";
          string s = Marshal.PtrToStringUni(str);
          LocalFree(str);
          string name = s.EndsWith("-4096") ? "low" : s.EndsWith("-8192") ? "medium"
                      : s.EndsWith("-12288") ? "high" : s.EndsWith("-16384") ? "system" : "?";
          return s + " (" + name + ")";
        } finally { Marshal.FreeHGlobal(buf); }
      } finally { CloseHandle(tok); }
    } finally { CloseHandle(proc); }
  }
}
"@

$ScreenW = [U]::GetSystemMetrics(0)
$ScreenH = [U]::GetSystemMetrics(1)

function MoveTo($x, $y) {
    $dx = [int](($x * 65535) / ($ScreenW - 1))
    $dy = [int](($y * 65535) / ($ScreenH - 1))
    [U]::mouse_event([U]::MOVE -bor [U]::ABSOLUTE, $dx, $dy, 0, [IntPtr]::Zero)
    [U]::SetCursorPos($x, $y) | Out-Null
}

function Drag($x1, $y1, $x2, $y2, $steps) {
    if (-not $steps) { $steps = 30 }
    Say "drag $x1,$y1 -> $x2,$y2 in $steps steps"
    MoveTo $x1 $y1
    Start-Sleep -Milliseconds 500
    [U]::mouse_event([U]::LEFTDOWN, 0, 0, 0, [IntPtr]::Zero)
    Start-Sleep -Milliseconds 300
    # The first moves are small and inside the source: a drag begins only
    # after the system threshold, and a jump straight to the target can
    # look like a click that landed somewhere else.
    for ($i = 1; $i -le 6; $i++) { MoveTo ($x1 + $i * 3) ($y1 + $i * 2); Start-Sleep -Milliseconds 60 }
    for ($i = 1; $i -le $steps; $i++) {
        $t = $i / [double]$steps
        MoveTo ([int]($x1 + ($x2 - $x1) * $t)) ([int]($y1 + ($y2 - $y1) * $t))
        Start-Sleep -Milliseconds 60
    }
    MoveTo $x2 $y2
    Start-Sleep -Milliseconds 400
    MoveTo ($x2 + 2) ($y2 + 1)
    Start-Sleep -Milliseconds 300
    [U]::mouse_event([U]::LEFTUP, 0, 0, 0, [IntPtr]::Zero)
    Say "released at $x2,$y2"
    Start-Sleep -Milliseconds 2000
}

function WindowsOfClass($cls) {
    $found = New-Object System.Collections.ArrayList
    $cb = [U+EnumProc] {
        param($hh, $ll)
        if ([U]::IsWindowVisible($hh)) {
            $c = New-Object System.Text.StringBuilder 256
            [U]::GetClassName($hh, $c, 256) | Out-Null
            if ($c.ToString() -eq $cls) { [void]$found.Add($hh) }
        }
        return $true
    }
    [U]::EnumWindows($cb, [IntPtr]::Zero) | Out-Null
    return $found
}

function WaitForLine($file, $needle, $seconds) {
    $deadline = (Get-Date).AddSeconds($seconds)
    while ((Get-Date) -lt $deadline) {
        if (Test-Path $file) {
            $t = Get-Content -Path $file -ErrorAction SilentlyContinue
            foreach ($l in $t) { if ($l -like "*$needle*") { return $l } }
        }
        Start-Sleep -Milliseconds 300
    }
    Say "TIMEOUT waiting for '$needle' in $file"
    return $null
}

function ZoneCentre($file, $zone) {
    $l = WaitForLine $file "ZONE $zone " 40
    if (-not $l) { return $null }
    if ($l -match "centre=(\d+),(\d+)") { return @([int]$Matches[1], [int]$Matches[2]) }
    Say "could not parse a centre out of: $l"
    return $null
}

function StartProbe($exe, $arguments, $logfile, $envs) {
    foreach ($k in $envs.Keys) { Set-Item -Path ("env:" + $k) -Value ([string]$envs[$k]) }
    $env:KAYA_DP_LOG = $logfile
    if ($arguments) { $p = Start-Process -FilePath $exe -ArgumentList $arguments -PassThru }
    else { $p = Start-Process -FilePath $exe -PassThru }
    Say "started $exe $arguments (pid $($p.Id)) -> $logfile; integrity $([U]::Integrity($p.Id))"
    return $p
}

function StopAll() {
    foreach ($n in @("KayaDragProbe", "StockOle")) {
        Get-Process -Name $n -ErrorAction SilentlyContinue | ForEach-Object {
            Say "stopping $n pid $($_.Id)"
            Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
        }
    }
    Start-Sleep -Milliseconds 500
}

function CloseExplorerWindows() {
    try {
        $shell = New-Object -ComObject Shell.Application
        $ws = @($shell.Windows())
        foreach ($w in $ws) {
            try { if ($w.FullName -like "*explorer.exe*") { $w.Quit() } } catch { }
        }
        Say "closed $($ws.Count) shell window(s)"
    } catch { Say "closing shell windows threw: $($_.Exception.Message)" }
    Start-Sleep -Milliseconds 800
}

function OpenExplorerAt($folder, $x, $y, $w, $h) {
    CloseExplorerWindows
    Start-Process explorer.exe $folder
    $deadline = (Get-Date).AddSeconds(25)
    $hwnd = [IntPtr]::Zero
    while ((Get-Date) -lt $deadline) {
        $ws = WindowsOfClass "CabinetWClass"
        if ($ws.Count -gt 0) { $hwnd = $ws[0]; break }
        Start-Sleep -Milliseconds 400
    }
    if ($hwnd -eq [IntPtr]::Zero) { Say "no CabinetWClass window appeared for $folder"; return $null }
    Start-Sleep -Milliseconds 1500
    [U]::SetWindowPos($hwnd, [IntPtr]::Zero, $x, $y, $w, $h, [U]::SWP_NOZORDER) | Out-Null
    Start-Sleep -Milliseconds 1500
    $r = New-Object RECT
    [U]::GetWindowRect($hwnd, [ref]$r) | Out-Null
    Say "explorer hwnd=0x$($hwnd.ToString('x')) rect=$($r.Left),$($r.Top),$($r.Right),$($r.Bottom)"
    return $hwnd
}

function ExplorerItemPoint($hwnd, $prefix) {
    Add-Type -AssemblyName UIAutomationClient
    Add-Type -AssemblyName UIAutomationTypes
    $root = [System.Windows.Automation.AutomationElement]::FromHandle($hwnd)
    if (-not $root) { Say "UIA could not attach to the explorer window"; return $null }
    $cond = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
        [System.Windows.Automation.ControlType]::ListItem)
    $items = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, $cond)
    Say "explorer list items: $($items.Count)"
    foreach ($it in $items) {
        $n = $it.Current.Name
        Say "  item '$n' rect=$($it.Current.BoundingRectangle)"
        if ($n -like "$prefix*") {
            $r = $it.Current.BoundingRectangle
            return @([int]($r.X + $r.Width / 2), [int]($r.Y + $r.Height / 2), $n)
        }
    }
    Say "no list item starting with '$prefix'"
    return $null
}

# ---------------------------------------------------------------------------

Say "scenario $Scenario begins (screen ${ScreenW}x${ScreenH}, admin=$(([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)))"
Say "driver integrity: $([U]::Integrity($PID))"
$expl = Get-Process -Name explorer -ErrorAction SilentlyContinue | Select-Object -First 1
if ($expl) { Say "explorer.exe (pid $($expl.Id)) integrity: $([U]::Integrity($expl.Id))" } else { Say "explorer.exe is not running" }
StopAll

$WinUiLog = "$Root\log-winui.txt"
$StockLog = "$Root\log-stock.txt"
$winui = $WinUiExe
$stock = $StockExe

switch ($Scenario) {

  "a-winrt-to-win32" {
    # PROBE 1, forward: a WinRT DataPackage with a custom format id, read
    # by a classic OLE IDropTarget in another process.
    StartProbe $winui $null $WinUiLog @{ KAYA_DP_MODE = "xaml"; KAYA_DP_X = 0; KAYA_DP_Y = 0; KAYA_DP_W = 500; KAYA_DP_H = 700; KAYA_DP_TTL = 120 } | Out-Null
    StartProbe $stock "target 540 40 460 600" $StockLog @{ KAYA_DP_TTL = 120 } | Out-Null
    WaitForLine $StockLog "stock READY" 40 | Out-Null
    $src = ZoneCentre $WinUiLog "source"
    if (-not $src) { Say "no source zone; giving up"; break }
    Drag $src[0] $src[1] 770 340
  }

  "b-win32-to-winrt" {
    # PROBE 1, reverse: a classic OLE source with a registered custom
    # clipboard format, read by XAML's DataPackageView.
    StartProbe $stock "source 0 40 480 600" $StockLog @{ KAYA_DP_TTL = 120 } | Out-Null
    StartProbe $winui $null $WinUiLog @{ KAYA_DP_MODE = "xaml"; KAYA_DP_X = 520; KAYA_DP_Y = 0; KAYA_DP_W = 500; KAYA_DP_H = 700; KAYA_DP_TTL = 120 } | Out-Null
    WaitForLine $StockLog "stock READY" 40 | Out-Null
    $dst = ZoneCentre $WinUiLog "drop"
    if (-not $dst) { Say "no drop zone; giving up"; break }
    Drag 240 340 $dst[0] $dst[1]
  }

  "g-win32-to-win32" {
    # The control for the reverse direction: the SAME OLE source into a
    # plain Win32 OLE target. If this passes and the XAML one does not,
    # the source is sound and the receiver is the finding.
    StartProbe $stock "source 0 40 480 600" $StockLog @{ KAYA_DP_TTL = 120 } | Out-Null
    Start-Sleep -Milliseconds 1200
    StartProbe $stock "target 540 40 460 600" "$Root\log-stock2.txt" @{ KAYA_DP_TTL = 120 } | Out-Null
    WaitForLine "$Root\log-stock2.txt" "stock READY" 40 | Out-Null
    Drag 240 340 770 340
  }

  "h-win32-to-ole-winui" {
    # PROBE 1 reverse, through the fallback: the same OLE source into the
    # WinUI window with XAML's drop target revoked and kaya's own
    # IDropTarget registered on the HWND.
    StartProbe $stock "source 0 40 480 600" $StockLog @{ KAYA_DP_TTL = 120 } | Out-Null
    StartProbe $winui $null $WinUiLog @{ KAYA_DP_MODE = "ole"; KAYA_DP_X = 520; KAYA_DP_Y = 0; KAYA_DP_W = 500; KAYA_DP_H = 700; KAYA_DP_TTL = 120 } | Out-Null
    $dst = ZoneCentre $WinUiLog "drop"
    if (-not $dst) { Say "no drop zone; giving up"; break }
    Drag 240 340 $dst[0] $dst[1]
  }

  "c-same-process" {
    # The control for both: XAML source to XAML destination inside ONE
    # process. If this fails, the drive is wrong, not the bridge.
    StartProbe $winui $null $WinUiLog @{ KAYA_DP_MODE = "xaml"; KAYA_DP_X = 0; KAYA_DP_Y = 0; KAYA_DP_W = 500; KAYA_DP_H = 700; KAYA_DP_TTL = 120 } | Out-Null
    $src = ZoneCentre $WinUiLog "source"
    $dst = ZoneCentre $WinUiLog "drop"
    if (-not $src -or -not $dst) { Say "zones missing; giving up"; break }
    Drag $src[0] $src[1] $dst[0] $dst[1]
  }

  "k-winrt-to-winrt" {
    # Does XAML receive a drag that ORIGINATED in WinRT but in ANOTHER
    # PROCESS? Two copies of the same WinUI probe, source on the left,
    # AllowDrop target on the right. This is kaya-window-to-kaya-window.
    StartProbe $winui $null $WinUiLog @{ KAYA_DP_MODE = "xaml"; KAYA_DP_X = 0; KAYA_DP_Y = 0; KAYA_DP_W = 500; KAYA_DP_H = 700; KAYA_DP_TTL = 120 } | Out-Null
    $src = ZoneCentre $WinUiLog "source"
    StartProbe $winui $null "$Root\log-winui2.txt" @{ KAYA_DP_MODE = "xaml"; KAYA_DP_X = 520; KAYA_DP_Y = 0; KAYA_DP_W = 500; KAYA_DP_H = 700; KAYA_DP_TTL = 120 } | Out-Null
    $dst = ZoneCentre "$Root\log-winui2.txt" "drop"
    if (-not $src -or -not $dst) { Say "zones missing; giving up"; break }
    Drag $src[0] $src[1] $dst[0] $dst[1]
  }

  "l-winrt-to-both" {
    # THE ROUTE QUESTION FOR THE ARM: with AllowDrop set AND kaya's own OLE
    # target registered on the island HWND, which one receives a WinRT
    # drag from another process? If the OLE target takes everything, one
    # route serves both worlds.
    StartProbe $winui $null $WinUiLog @{ KAYA_DP_MODE = "xaml"; KAYA_DP_X = 0; KAYA_DP_Y = 0; KAYA_DP_W = 500; KAYA_DP_H = 700; KAYA_DP_TTL = 120 } | Out-Null
    $src = ZoneCentre $WinUiLog "source"
    StartProbe $winui $null "$Root\log-winui2.txt" @{ KAYA_DP_MODE = "both"; KAYA_DP_X = 520; KAYA_DP_Y = 0; KAYA_DP_W = 500; KAYA_DP_H = 700; KAYA_DP_TTL = 120 } | Out-Null
    $dst = ZoneCentre "$Root\log-winui2.txt" "drop"
    if (-not $src -or -not $dst) { Say "zones missing; giving up"; break }
    Drag $src[0] $src[1] $dst[0] $dst[1]
  }

  "m-explorer-to-both" {
    # The same window, this time asked to take an Explorer file drop: does
    # the OLE half still work while AllowDrop is on?
    StartProbe $winui $null $WinUiLog @{ KAYA_DP_MODE = "both"; KAYA_DP_X = 520; KAYA_DP_Y = 0; KAYA_DP_W = 500; KAYA_DP_H = 700; KAYA_DP_TTL = 150 } | Out-Null
    $dst = ZoneCentre $WinUiLog "drop"
    $ex = OpenExplorerAt "$Root\files" 0 0 500 700
    if (-not $ex -or -not $dst) { Say "explorer or zone missing; giving up"; break }
    $pt = ExplorerItemPoint $ex "note"
    if (-not $pt) { Say "no note item; giving up"; break }
    Drag $pt[0] $pt[1] $dst[0] $dst[1] 40
  }

  "j-medium-source-to-ole" {
    # UIPI, as far as a UAC-disabled VM can reach it: the OLE source is
    # launched with a SAFER "basic user" restricted token (runas
    # /trustlevel), so it sits BELOW the drop target the way a
    # non-elevated Explorer would sit below an elevated app.
    # ITS LOG GOES TO THE USER PROFILE: a SAFER-restricted token keeps the
    # user SID but loses Administrators, and C:\kaya is admin-writable
    # only, so a log under it would be silently empty.
    $restrictedLog = Join-Path $env:USERPROFILE "kaya-dp-stock-restricted.txt"
    Remove-Item -Path $restrictedLog -ErrorAction SilentlyContinue
    $env:KAYA_DP_LOG = $restrictedLog
    $env:KAYA_DP_TTL = 120
    $cmd = '"' + $stock + ' source 0 40 480 600"'
    Say "runas /trustlevel:0x20000 $cmd"
    Start-Process -FilePath "runas.exe" -ArgumentList "/trustlevel:0x20000", $cmd | Out-Null
    StartProbe $winui $null $WinUiLog @{ KAYA_DP_MODE = "ole"; KAYA_DP_X = 520; KAYA_DP_Y = 0; KAYA_DP_W = 500; KAYA_DP_H = 700; KAYA_DP_TTL = 120 } | Out-Null
    $ready = WaitForLine $restrictedLog "stock READY" 40
    $sp = Get-Process -Name StockOle -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($sp) { Say "restricted source pid $($sp.Id) integrity: $([U]::Integrity($sp.Id))" } else { Say "RESTRICTED SOURCE NEVER STARTED" }
    if (Test-Path $restrictedLog) { foreach ($l in Get-Content $restrictedLog) { Say "  [restricted source] $l" } }
    $dst = ZoneCentre $WinUiLog "drop"
    if (-not $dst -or -not $ready) { Say "source or zone missing; giving up"; break }
    Drag 240 340 $dst[0] $dst[1]
  }

  "i-xaml-registration-census" {
    # Does AllowDrop=true register an OLE drop target on either HWND? No
    # drag at all: the app asks and prints, then leaves the windows as it
    # found them.
    StartProbe $winui $null $WinUiLog @{ KAYA_DP_MODE = "xaml"; KAYA_DP_X = 0; KAYA_DP_Y = 0; KAYA_DP_W = 500; KAYA_DP_H = 700; KAYA_DP_TTL = 30; KAYA_DP_REGCENSUS = "1" } | Out-Null
    WaitForLine $WinUiLog "CENSUS" 40 | Out-Null
    Start-Sleep -Milliseconds 1500
  }

  "d-explorer-to-xaml" {
    # PROBE 2: an Explorer file drop onto a WinUI 3 window, XAML AllowDrop.
    StartProbe $winui $null $WinUiLog @{ KAYA_DP_MODE = "xaml"; KAYA_DP_X = 520; KAYA_DP_Y = 0; KAYA_DP_W = 500; KAYA_DP_H = 700; KAYA_DP_TTL = 150 } | Out-Null
    $dst = ZoneCentre $WinUiLog "drop"
    $ex = OpenExplorerAt "$Root\files" 0 0 500 700
    if (-not $ex -or -not $dst) { Say "explorer or zone missing; giving up"; break }
    $pt = ExplorerItemPoint $ex "note"
    if (-not $pt) { Say "no note item; giving up"; break }
    Say "dragging explorer item '$($pt[2])'"
    Drag $pt[0] $pt[1] $dst[0] $dst[1] 40
  }

  "e-explorer-to-ole" {
    # PROBE 2's fallback: the same drop with XAML's drop target revoked and
    # kaya's own OLE IDropTarget registered on the WinUI HWND.
    StartProbe $winui $null $WinUiLog @{ KAYA_DP_MODE = "ole"; KAYA_DP_X = 520; KAYA_DP_Y = 0; KAYA_DP_W = 500; KAYA_DP_H = 700; KAYA_DP_TTL = 150 } | Out-Null
    $dst = ZoneCentre $WinUiLog "drop"
    $ex = OpenExplorerAt "$Root\files" 0 0 500 700
    if (-not $ex -or -not $dst) { Say "explorer or zone missing; giving up"; break }
    $pt = ExplorerItemPoint $ex "note"
    if (-not $pt) { Say "no note item; giving up"; break }
    Say "dragging explorer item '$($pt[2])'"
    Drag $pt[0] $pt[1] $dst[0] $dst[1] 40
  }

  "f-explorer-to-stock" {
    # The control for probe 2: the same Explorer drag onto a plain Win32
    # window with a plain OLE drop target. A failure here is the DRIVE, not
    # WinUI.
    StartProbe $stock "target 540 40 460 600" $StockLog @{ KAYA_DP_TTL = 150 } | Out-Null
    WaitForLine $StockLog "stock READY" 40 | Out-Null
    $ex = OpenExplorerAt "$Root\files" 0 0 500 700
    if (-not $ex) { Say "no explorer; giving up"; break }
    $pt = ExplorerItemPoint $ex "note"
    if (-not $pt) { Say "no note item; giving up"; break }
    Say "dragging explorer item '$($pt[2])'"
    Drag $pt[0] $pt[1] 770 340 40
  }

  default { Say "unknown scenario '$Scenario'" }
}

Start-Sleep -Milliseconds 1500
StopAll
CloseExplorerWindows
Say "scenario $Scenario done"
