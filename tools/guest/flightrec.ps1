# The flight recorder's guest half: what was on the Windows desktop when a
# leg failed.
#
# MUST RUN IN THE INTERACTIVE SESSION (schtasks /it). An ssh session is
# session 0 with its own window station and can neither see nor touch the
# desktop, so GetForegroundWindow, UI Automation and PrintWindow all answer
# nothing there. deploy-win.sh launches both modes as scheduled tasks with
# per-leg task names, because the lane runs up to KAYA_WIN_JOBS legs at once
# and one shared task name would have them overwrite each other.
#
# TWO MODES, because the evidence has two lifetimes:
#
#   -Mode sample  -Leg <name> -Seconds <n>
#       Polls GetForegroundWindow while the leg runs and appends a line per
#       change. THIS IS THE ONLY HONEST WAY TO HAVE FOREGROUND HISTORY AT
#       FAIL TIME: a verdict is known only after the guest has exited, and
#       by then the desktop says nothing about what stole focus during the
#       scene. The runner keeps this file only when the leg fails.
#
#   -Mode collect -Leg <name>
#       The at-fail collection: any live dialog's UIA tree, a bounded
#       Event Log slice, the filtered process list, and a PrintWindow shot
#       of the app window.
#
# THIS FILE IS ASCII ON ITS CODE LINES, and that is a rule with a
# measurement behind it (tools/flightrec-selftest.sh N5): Windows
# PowerShell 5.1 reads a .ps1 in the machine's ANSI CODEPAGE, so an em-dash
# in a string literal arrives as three bytes CONTAINING A DOUBLE QUOTE,
# which closes the string and kills the parse before the first statement.
# The task then exits having created nothing, and the runner cannot tell
# that from a capture that had nothing to collect.
#
# CharSet.Unicode IS NOT OPTIONAL on the two text calls below, and this is
# also measured: DllImport defaults to Ansi, so a *W function handed an
# ANSI buffer writes UTF-16 into it and the unmarshal stops at the first
# NUL byte. Every class and title came back as ONE CHARACTER -- class='W'
# for WinUIDesktopWin32WindowClass -- which meant the '#32770' test could
# never match, the UIA walk could never fire, and the shot could never find
# its window. All three would have reported "nothing was there" forever.
#
# ON PrintWindow, and why not a screen copy: WinUI draws through
# DirectComposition, which GDI-family screen copies read as BLANK, and the
# lane tiles six legs where slots 4 and 5 sit below the bottom of an
# 800-tall desktop, where a copy of the screen has nothing to copy at all
# (measured 2026-08-26, docs/traps.md). PrintWindow with
# PW_RENDERFULLCONTENT asks DWM for the window's composited content
# addressed by HWND, so an occluded or part-off-screen window still
# answers. Windows are found by CLASS, never by title: the title is a
# placeholder the app replaces with its own caption moments later.
#
# ON UI AUTOMATION, and why it is safe HERE and nowhere else: kaya's own
# backend may not host a UIA client (crates/kaya/Cargo.toml records it --
# an in-process client makes the Shell's file dialog fatal to the java
# leg), so this attaches OUT OF PROCESS. Even out of process the attach can
# disturb a live Shell dialog, which is why it happens only after the leg
# has ALREADY LOST and the runner is about to kill the guests anyway.

param(
    [Parameter(Mandatory = $true)][ValidateSet('sample', 'collect')][string]$Mode,
    [Parameter(Mandatory = $true)][string]$Leg,
    # Lane-long: ONE sampler now covers the whole run and the windows lane
    # is ~10 minutes, longer under the matrix. ALL.stop is the normal exit;
    # this deadline only stops a sampler whose lane died without one.
    [int]$Seconds = 5400
)

$ErrorActionPreference = 'Continue'
$dir = 'C:\kaya\flightrec'
if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

# NO BOM. `Out-File -Encoding utf8` on PowerShell 5.1 writes a byte-order
# mark, which makes the artifact `file`-detect as binary and makes grep
# refuse to print matches -- a bundle nobody can grep is a bundle nobody
# reads.
$enc = New-Object System.Text.UTF8Encoding $false
function Reset($path) { [System.IO.File]::WriteAllText($path, '', $enc) }
function Emit($path, $text) { [System.IO.File]::AppendAllText($path, "$text`r`n", $enc) }

Add-Type -Namespace KayaFR -Name Win -MemberDefinition @'
[DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h, System.Text.StringBuilder s, int n);
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassNameW(IntPtr h, System.Text.StringBuilder s, int n);
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
[DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr p);
[DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
[DllImport("user32.dll")] public static extern int PrintWindow(IntPtr h, IntPtr dc, uint flags);
public delegate bool EnumProc(IntPtr h, IntPtr p);
public struct RECT { public int Left, Top, Right, Bottom; }
'@

function ClassOf($h) {
    $c = New-Object System.Text.StringBuilder 256
    [void][KayaFR.Win]::GetClassNameW($h, $c, 256)
    return $c.ToString()
}

function Describe($h) {
    $t = New-Object System.Text.StringBuilder 512
    [void][KayaFR.Win]::GetWindowTextW($h, $t, 512)
    $procId = 0
    [void][KayaFR.Win]::GetWindowThreadProcessId($h, [ref]$procId)
    $name = '?'
    try { $name = (Get-Process -Id $procId -ErrorAction Stop).ProcessName } catch { $name = '?' }
    return "hwnd=0x{0:x} pid={1} proc={2} class='{3}' title='{4}'" -f `
        [int64]$h, $procId, $name, (ClassOf $h), $t.ToString()
}

function VisibleWindows() {
    $found = New-Object System.Collections.ArrayList
    $cb = [KayaFR.Win+EnumProc] {
        param($h, $p)
        if ([KayaFR.Win]::IsWindowVisible($h)) { [void]$found.Add($h) }
        return $true
    }
    [void][KayaFR.Win]::EnumWindows($cb, [IntPtr]::Zero)
    return $found
}

# ------------------------------------------------------------- sample --
if ($Mode -eq 'sample') {
    $out = Join-Path $dir "$Leg-foreground.txt"
    Reset $out
    Emit $out "flightrec sample: ring=$Leg started=$(Get-Date -Format o)"
    $last = ''
    $lines = 1
    $t0 = Get-Date
    # STOPPED BY A FILE, not by killing powershell: the lane runs several
    # legs at once and a name-wide taskkill would take the others' samplers
    # with it. The runner drops <leg>.stop; ALL.stop is the lane's backstop,
    # dropped by the runner's EXIT trap so a leg that died without stopping
    # its own sampler cannot leave one polling after the lane has gone. The
    # deadline is only the last resort.
    $stop = Join-Path $dir "$Leg.stop"
    $stopAll = Join-Path $dir 'ALL.stop'
    while (((Get-Date) - $t0).TotalSeconds -lt $Seconds) {
        if ((Test-Path $stop) -or (Test-Path $stopAll)) { break }
        # THE STOP CHANNEL VANISHING IS ALSO A STOP. Both stop files live
        # in $dir, so a cleanup that removes the directory leaves this
        # polling for a file that can never appear -- measured 2026-08-27,
        # a sampler orphaned for its whole 5400s deadline that way.
        if (-not (Test-Path $dir)) { break }
        $h = [KayaFR.Win]::GetForegroundWindow()
        $line = if ($h -eq [IntPtr]::Zero) { 'foreground=none' } else { Describe $h }
        # Only CHANGES, so a lane does not write two lines a second of the
        # same window.
        if ($line -ne $last) {
            # GUEST EPOCH SECONDS, not milliseconds-since-start: ONE sampler
            # now serves the whole lane (it was per leg, and that cost three
            # ssh round trips a leg -- see the runner), so a reader has to
            # be able to place a line against a leg that started whenever.
            # flightrec_win_clock_sync reads the offset once and the bundle
            # names the leg's window in these same units.
            $at = [int64](Get-Date -UFormat %s)
            Emit $out "at=$at $line"
            $last = $line
            $lines++
            # A ring, so a long lane cannot grow this without bound. Halved
            # rather than trimmed by one, because a rewrite per line on a
            # file this size would be the cost the per-leg design just shed.
            if ($lines -gt 5000) {
                $keep = (Get-Content $out -Tail 2500)
                [System.IO.File]::WriteAllLines($out, $keep, $enc)
                $lines = $keep.Count
            }
        }
        Start-Sleep -Milliseconds 500
    }
    Emit $out "flightrec sample: ring=$Leg stopped=$(Get-Date -Format o)"
    exit 0
}

# ------------------------------------------------------------ collect --
$out = Join-Path $dir "$Leg-collect.txt"
Reset $out
Emit $out "flightrec collect: leg=$Leg at=$(Get-Date -Format o)"

# 1. The windows that exist right now, and the foreground.
Emit $out '== visible windows =='
$wins = VisibleWindows
foreach ($h in $wins) { Emit $out (Describe $h) }
Emit $out "visible=$($wins.Count)"
Emit $out '== foreground =='
$fg = [KayaFR.Win]::GetForegroundWindow()
if ($fg -eq [IntPtr]::Zero) { Emit $out 'foreground=none' } else { Emit $out (Describe $fg) }

# 2. Any live dialog's UIA tree. A Shell dialog is class #32770; a WinUI
#    flyout is its own top-level PopupWindowSiteBridge window.
Emit $out '== dialog UIA tree =='
$dialogs = @()
foreach ($h in $wins) {
    $cn = ClassOf $h
    if ($cn -eq '#32770' -or $cn -like '*PopupWindowSiteBridge*') { $dialogs += $h }
}
if ($dialogs.Count -eq 0) {
    # A DIAGNOSTIC MAY ONLY PRINT WHAT IT MEASURED: no dialog was up is a
    # finding, and it is not the same as the walk having failed. The count
    # of windows actually examined rides the sentence so a reader can tell
    # this from an enumeration that saw nothing at all.
    Emit $out "no #32770 and no popup site bridge among the $($wins.Count) visible windows -- nothing to walk"
} else {
    try {
        Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
        foreach ($h in $dialogs) {
            Emit $out "DIALOG $(Describe $h)"
            $root = [Windows.Automation.AutomationElement]::FromHandle($h)
            $all = $root.FindAll([Windows.Automation.TreeScope]::Descendants,
                [Windows.Automation.Condition]::TrueCondition)
            Emit $out "  elements=$($all.Count)"
            foreach ($e in $all) {
                Emit $out ("  ITEM name='{0}' type={1} automationId='{2}' enabled={3}" -f `
                    $e.Current.Name, $e.Current.ControlType.ProgrammaticName,
                    $e.Current.AutomationId, $e.Current.IsEnabled)
            }
        }
    } catch {
        Emit $out "UIA walk failed: $($_.Exception.Message)"
    }
}

# 3. The shell process state, filtered to what this lane runs.
Emit $out '== tasklist (lane processes) =='
$names = @('python', 'go', 'dotnet', 'java', 'kaya-guests', 'cdb', 'WerFault', 'powershell', 'wscript')
$procs = Get-Process -ErrorAction SilentlyContinue |
    Where-Object { $names -contains $_.ProcessName -or $_.MainWindowHandle -ne 0 } |
    Sort-Object -Property CPU -Descending |
    Select-Object -First 40 Id, ProcessName, CPU, WorkingSet64, MainWindowTitle |
    Format-Table -AutoSize | Out-String -Width 200
Emit $out $procs.TrimEnd()

# 4. A BOUNDED Event Log slice. Application errors only, newest 20 -- an
#    unbounded wevtutil dump is megabytes and nobody reads it.
Emit $out '== Application event log, newest 20 errors =='
$evt = (& wevtutil qe Application "/q:*[System[(Level=1 or Level=2)]]" /c:20 /rd:true /f:text 2>&1) -join "`r`n"
Emit $out $evt

# 5. The shot: the app window by CLASS, through PrintWindow.
Emit $out '== window shot =='
$shot = Join-Path $dir "$Leg-shot.png"
if (Test-Path $shot) { Remove-Item $shot -Force }
$target = [IntPtr]::Zero
foreach ($h in $wins) {
    if ((ClassOf $h) -eq 'WinUIDesktopWin32WindowClass') { $target = $h; break }
}
if ($target -eq [IntPtr]::Zero) {
    Emit $out "no WinUIDesktopWin32WindowClass window among the $($wins.Count) visible ones -- the guest had already exited, so there was nothing to photograph. The window list above is what WAS there."
} else {
    try {
        Add-Type -AssemblyName System.Drawing
        $r = New-Object KayaFR.Win+RECT
        [void][KayaFR.Win]::GetWindowRect($target, [ref]$r)
        $w = $r.Right - $r.Left
        $hgt = $r.Bottom - $r.Top
        $bmp = New-Object System.Drawing.Bitmap $w, $hgt
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $dc = $g.GetHdc()
        # PW_RENDERFULLCONTENT = 2 -- see the header.
        $rc = [KayaFR.Win]::PrintWindow($target, $dc, 2)
        $g.ReleaseHdc($dc)
        $g.Dispose()
        if ($rc -eq 0) {
            Emit $out "PrintWindow(PW_RENDERFULLCONTENT) of the ${w}x${hgt} window answered 0"
        } else {
            $bmp.Save($shot, [System.Drawing.Imaging.ImageFormat]::Png)
            Emit $out "shot saved ${w}x${hgt} -> $shot"
        }
        $bmp.Dispose()
    } catch {
        Emit $out "shot failed: $($_.Exception.Message)"
    }
}

Emit $out 'COLLECTDONE'
exit 0
