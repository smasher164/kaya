# The flight recorder's guest half. `sample` polls the foreground WHILE
# the leg runs (a verdict is known only after the guest exits, when the
# desktop says nothing about what stole focus); `collect` is the at-fail
# dump. MUST RUN IN THE INTERACTIVE SESSION (schtasks /it, per-leg task
# names): an ssh session is session 0 with its own window station, where
# GetForegroundWindow, UIA and PrintWindow all answer nothing.

param(
    [Parameter(Mandatory = $true)][ValidateSet('sample', 'collect', 'list')][string]$Mode,
    [Parameter(Mandatory = $true)][string]$Leg,
    # The lane run this sampler belongs to (docs/deferred.md's LEAK entry):
    # a sampler names its run so the lane's exit can wait for ITS OWN and
    # tell a leaked one from a neighbour's.
    [string]$Run = 'none',
    # Lane-long: ALL.stop is the normal exit, and this deadline only stops
    # a sampler whose lane died without one.
    [int]$Seconds = 5400
)

# ASCII ON THE CODE LINES (tools/flightrec-selftest.py N5): PowerShell
# 5.1 reads a .ps1 in the machine's ANSI codepage, so a non-ASCII
# character inside a string literal kills the parse.
$ErrorActionPreference = 'Continue'
$dir = 'C:\kaya\flightrec'
if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

# NO BOM: `Out-File -Encoding utf8` on PowerShell 5.1 writes one, which
# makes the artifact `file`-detect as binary and grep refuse to print
# matches.
$enc = New-Object System.Text.UTF8Encoding $false
function Reset($path) { [System.IO.File]::WriteAllText($path, '', $enc) }
function Emit($path, $text) { [System.IO.File]::AppendAllText($path, "$text`r`n", $enc) }

# --------------------------------------------------------------- list --
# WHAT IS STILL POLLING, ANSWERED BEFORE THE Add-Type BELOW: the lane's
# exit waits on this and a wait must be cheap (the C# compile the user32
# declarations need costs seconds). TWO SOURCES, because either alone has
# a hole: a sampler drops sample-<run>.pid at startup and removes it in a
# finally, which is the only thing that says WHICH RUN it belongs to; and
# the live process list catches a sampler with no pid file at all -- one
# started from a build of this script that predates the file, which is
# every lane's FIRST run after a flightrec.ps1 edit, since the runner
# starts the sampler before it deploys. A pid is reused, so the name is
# read back before a row counts as alive. Runs over ssh, session 0 -- it
# enumerates processes and touches no desktop.
function SamplerPid($path) {
    $text = ''
    try { $text = [System.IO.File]::ReadAllText($path).Trim() } catch { $text = '' }
    $n = 0
    if ([int]::TryParse($text, [ref]$n)) { return $n }
    return 0
}

function StartedAt($proc) {
    try { return $proc.StartTime.ToString('o') } catch { return '?' }
}

if ($Mode -eq 'list') {
    $runs = @{}
    foreach ($f in @(Get-ChildItem -Path $dir -Filter 'sample-*.pid' -ErrorAction SilentlyContinue)) {
        $token = $f.BaseName.Substring(7)
        $sp = SamplerPid $f.FullName
        $proc = $null
        if ($sp -gt 0) { $proc = Get-Process -Id $sp -ErrorAction SilentlyContinue }
        if ($proc -and $proc.ProcessName -eq 'powershell') {
            $runs[$sp] = $token
        } else {
            Write-Output "stale run=$token pid=$sp (no live powershell with that pid)"
            Remove-Item $f.FullName -Force -ErrorAction SilentlyContinue
        }
    }
    # THE PROCESS LIST IS THE NET UNDER THE PID FILES. A sampler it can see
    # and no pid file names is reported run=? and the lane refuses on it:
    # at the end of a lane, a sampler nobody can attribute is the leak this
    # whole mechanism exists for.
    $seen = @{}
    foreach ($p in @(Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue)) {
        $line = $p.CommandLine
        if ($line -and $line -like '*flightrec.ps1*' -and $line -like '*-Mode sample*') {
            $seen[[int]$p.ProcessId] = $line
        }
    }
    $live = 0
    $pids = @(@($runs.Keys) + @($seen.Keys) | Sort-Object -Unique)
    foreach ($sp in $pids) {
        $token = '?'
        if ($runs.ContainsKey($sp)) { $token = $runs[$sp] }
        $proc = Get-Process -Id $sp -ErrorAction SilentlyContinue
        if (-not $proc) { continue }
        $where = 'process'
        if ($runs.ContainsKey($sp)) {
            $where = 'pidfile'
            if ($seen.ContainsKey($sp)) { $where = 'pidfile+process' }
        }
        Write-Output "sampler run=$token pid=$sp name=$($proc.ProcessName) started=$(StartedAt $proc) seen=$where"
        $live = $live + 1
    }
    Write-Output "samplers=$live"
    exit 0
}

# CharSet.Unicode IS NOT OPTIONAL on the two text calls, measured:
# DllImport defaults to Ansi, so a *W function's UTF-16 unmarshals to ONE
# CHARACTER (class='W' for WinUIDesktopWin32WindowClass) and the '#32770'
# test, the UIA walk and the shot all report "nothing was there".
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
    Emit $out "flightrec sample: ring=$Leg run=$Run pid=$PID started=$(Get-Date -Format o)"
    # THE PID FILE IS THE LANE'S HANDLE ON THIS PROCESS (docs/deferred.md's
    # LEAK entry): written before the loop, removed in the finally below,
    # so `-Mode list` answers for a sampler that is still polling and for
    # one that was killed without cleaning up.
    $pidfile = Join-Path $dir "sample-$Run.pid"
    [System.IO.File]::WriteAllText($pidfile, "$PID", $enc)
    try {
        $last = ''
        $lines = 1
        $t0 = Get-Date
        # STOPPED BY A FILE, not by killing powershell: a name-wide taskkill
        # would take the other legs' samplers with it. ALL.stop is the lane's
        # backstop, dropped by the runner's EXIT trap.
        $stop = Join-Path $dir "$Leg.stop"
        $stopAll = Join-Path $dir 'ALL.stop'
        while (((Get-Date) - $t0).TotalSeconds -lt $Seconds) {
            if ((Test-Path $stop) -or (Test-Path $stopAll)) { break }
            # THE STOP CHANNEL VANISHING IS ALSO A STOP: both stop files live
            # in $dir, so a cleanup that removes it would leave this polling
            # for a file that can never appear (measured 2026-08-27, a sampler
            # orphaned for its whole deadline).
            if (-not (Test-Path $dir)) { break }
            $h = [KayaFR.Win]::GetForegroundWindow()
            $line = if ($h -eq [IntPtr]::Zero) { 'foreground=none' } else { Describe $h }
            # Only CHANGES, so a lane does not write two lines a second of the
            # same window.
            if ($line -ne $last) {
                # GUEST EPOCH SECONDS, not milliseconds-since-start: one
                # sampler serves the whole lane, so a reader must be able to
                # place a line against a leg that started whenever
                # (flightrec_win_clock_sync reads the offset once).
                $at = [int64](Get-Date -UFormat %s)
                Emit $out "at=$at $line"
                $last = $line
                $lines++
                # A ring, HALVED rather than trimmed by one: a rewrite per
                # line on a file this size is the cost this design shed.
                if ($lines -gt 5000) {
                    $keep = (Get-Content $out -Tail 2500)
                    [System.IO.File]::WriteAllLines($out, $keep, $enc)
                    $lines = $keep.Count
                }
            }
            Start-Sleep -Milliseconds 500
        }
    } finally {
        Emit $out "flightrec sample: ring=$Leg run=$Run pid=$PID stopped=$(Get-Date -Format o)"
        Remove-Item $pidfile -Force -ErrorAction SilentlyContinue
    }
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

# 2. Any live dialog's UIA tree (a Shell dialog is class #32770, a WinUI
#    flyout its own PopupWindowSiteBridge). ATTACHED OUT OF PROCESS,
#    since kaya's backend may not host a UIA client (crates/kaya/
#    Cargo.toml records why), and only once the leg has ALREADY LOST:
#    even out of process the attach can disturb a live Shell dialog.
Emit $out '== dialog UIA tree =='
$dialogs = @()
foreach ($h in $wins) {
    $cn = ClassOf $h
    if ($cn -eq '#32770' -or $cn -like '*PopupWindowSiteBridge*') { $dialogs += $h }
}
if ($dialogs.Count -eq 0) {
    # A DIAGNOSTIC MAY ONLY PRINT WHAT IT MEASURED (CLAUDE.md invariant
    # 3): the count of windows examined rides the sentence, so a reader
    # can tell "no dialog" from "the enumeration saw nothing".
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

# 5. The shot: the app window by CLASS (the title is a placeholder the
#    app replaces), through PrintWindow with PW_RENDERFULLCONTENT — a
#    GDI-family screen copy reads DirectComposition content as BLANK and
#    a tiled leg can sit off an 800-tall desktop (docs/traps.md).
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
        # PW_RENDERFULLCONTENT = 2.
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
