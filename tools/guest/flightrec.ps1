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

# A TOAST SAYS WHAT IT IS: a shell "New notification" window in the
# foreground blocks every SetForegroundWindow (docs/traps.md, "A shell toast
# holds the foreground"), and the sixth notes-leg red came with every kaya
# history EMPTY at the dismissal before it -- so the sampler reads the
# toast's own text through UI Automation the moment it sees one, which is
# the only thing that tells a kaya toast from the shell's own.
function ToastText($h) {
    try {
        Add-Type -AssemblyName UIAutomationClient -ErrorAction Stop
        Add-Type -AssemblyName UIAutomationTypes -ErrorAction Stop
        $root = [System.Windows.Automation.AutomationElement]::FromHandle($h)
        if ($null -eq $root) { return 'uia: FromHandle answered nothing for this window' }
        $all = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants,
            [System.Windows.Automation.Condition]::TrueCondition)
        $names = New-Object System.Collections.ArrayList
        foreach ($el in $all) {
            $n = $el.Current.Name
            if ($n -and $n.Length -gt 0 -and -not $names.Contains($n)) { [void]$names.Add($n) }
        }
        # AN EMPTY READ SAYS WHAT IT WALKED (the seventh notes red read
        # toast='' and could not tell a nameless tree from a walk that
        # never happened): the element count and the root's own name.
        if ($names.Count -eq 0) {
            $rootName = $root.Current.Name
            return "uia: $($all.Count) element(s) walked, none named; root name '$rootName' class '$($root.Current.ClassName)'"
        }
        $joined = ($names -join ' | ')
        if ($joined.Length -gt 300) { $joined = $joined.Substring(0, 300) + '...' }
        return $joined
    } catch {
        return "uia failed: $($_.Exception.Message)"
    }
}

function Describe($h) {
    $t = New-Object System.Text.StringBuilder 512
    [void][KayaFR.Win]::GetWindowTextW($h, $t, 512)
    $procId = 0
    [void][KayaFR.Win]::GetWindowThreadProcessId($h, [ref]$procId)
    $name = '?'
    try { $name = (Get-Process -Id $procId -ErrorAction Stop).ProcessName } catch { $name = '?' }
    $line = "hwnd=0x{0:x} pid={1} proc={2} class='{3}' title='{4}'" -f `
        [int64]$h, $procId, $name, (ClassOf $h), $t.ToString()
    if ($t.ToString() -eq 'New notification') { $line = $line + " toast='" + (ToastText $h) + "'" }
    return $line
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

# The whole virtual screen to a PNG; the collect's section 6 and the
# sampler's toast grab both take it, so there is one copy of the rule.
function DesktopGrab($path) {
    Add-Type -AssemblyName System.Drawing
    Add-Type -AssemblyName System.Windows.Forms
    $vs = [System.Windows.Forms.SystemInformation]::VirtualScreen
    $dbmp = New-Object System.Drawing.Bitmap $vs.Width, $vs.Height
    $dg = [System.Drawing.Graphics]::FromImage($dbmp)
    $dg.CopyFromScreen($vs.Left, $vs.Top, 0, 0, $dbmp.Size)
    $dg.Dispose()
    $dbmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
    $dbmp.Dispose()
    return "$($vs.Width)x$($vs.Height)"
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
        $grabbed = New-Object System.Collections.ArrayList
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
            # THE PICTURE AT THE MOMENT (docs/traps.md, the toast entry): a
            # banner is gone by the time the collect runs after the guest
            # exits, and the eighth notes red's desktop grab showed a bare
            # desktop. The first time each toast window holds the foreground
            # the sampler grabs the whole screen right then and names the
            # file on its line; the host pulls the newest inside the leg.
            if ($line -like "*title='New notification'*" -and -not $grabbed.Contains([int64]$h)) {
                [void]$grabbed.Add([int64]$h)
                $stamp = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
                $tpath = Join-Path $dir "lane-toast-$stamp.png"
                try {
                    $size = DesktopGrab $tpath
                    $line = $line + " toastshot=lane-toast-$stamp.png ($size)"
                } catch {
                    $line = $line + " toastshot=failed: $($_.Exception.Message)"
                }
                Get-ChildItem $dir -Filter 'lane-toast-*.png' | Sort-Object LastWriteTime -Descending |
                    Select-Object -Skip 6 | Remove-Item -Force -ErrorAction SilentlyContinue
            }
            # Only CHANGES, so a lane does not write two lines a second of the
            # same window.
            if ($line -ne $last) {
                # GUEST EPOCH SECONDS, not milliseconds-since-start: one
                # sampler serves the whole lane, so a reader must be able to
                # place a line against a leg that started whenever
                # (flightrec_win_clock_sync reads the offset once). NOT
                # `Get-Date -UFormat %s`, which answers LOCAL time as though
                # it were UTC on PowerShell 5.1 (docs/traps.md).
                $at = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
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

# THE HOST READS THE TWO PICTURES' OWN SENTENCES OUT OF THIS FILE
# (flightrec_lane.py's WinRecorder.pull_shot): a bundle section that is
# absent must say what was MEASURED about its absence, and the host
# cannot know why a shot was not taken. One line per picture, always
# written, whether the picture was saved or not.
$why = Join-Path $dir "$Leg-shotwhy.txt"
Reset $why
function Why($section, $text) { Emit $why "${section}: $text" }

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
    $sentence = "no WinUIDesktopWin32WindowClass window among the $($wins.Count) visible ones -- the guest had already exited, so there was nothing to photograph. The window list above is what WAS there."
    Emit $out $sentence
    Why 'shot' $sentence
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
            $sentence = "PrintWindow(PW_RENDERFULLCONTENT) of the ${w}x${hgt} window answered 0"
            Emit $out $sentence
            Why 'shot' $sentence
        } else {
            $bmp.Save($shot, [System.Drawing.Imaging.ImageFormat]::Png)
            Emit $out "shot saved ${w}x${hgt} -> $shot"
            Why 'shot' "PrintWindow of the guest's ${w}x${hgt} window"
        }
        $bmp.Dispose()
    } catch {
        $sentence = "shot failed: $($_.Exception.Message)"
        Emit $out $sentence
        Why 'shot' $sentence
    }
}

# 6. THE WHOLE CONSOLE SESSION, when the foreground is not the guest's own
#    window. PrintWindow photographs ONE window by handle and a toast is
#    another process's, so the picture that ended the 2026-09-16 notes
#    search -- the desktop with the banner on it -- was a HAND tool
#    (tools/guest/shot.cmd) and never on the failure path (docs/traps.md,
#    "A shell toast holds the foreground"). This runs in the interactive
#    session already (schtasks /it), which is the only session that has a
#    desktop to copy. NOTHING IS FOREGROUNDED FIRST: shot.ps1 activates
#    the kaya window because it wants the app, and a recorder that
#    activates anything destroys the evidence it came for.
Emit $out '== desktop shot =='
$desk = Join-Path $dir "$Leg-desktop.png"
if (Test-Path $desk) { Remove-Item $desk -Force }
$fgIsGuest = ($fg -ne [IntPtr]::Zero) -and ((ClassOf $fg) -eq 'WinUIDesktopWin32WindowClass')
if ($fgIsGuest) {
    $sentence = "the foreground at collect WAS the guest's own window (hwnd=0x{0:x}), so the window shot above is the picture and no desktop grab was taken" -f [int64]$fg
    Emit $out $sentence
    Why 'desktop-shot' $sentence
} else {
    try {
        Add-Type -AssemblyName System.Drawing
        Add-Type -AssemblyName System.Windows.Forms
        $vs = [System.Windows.Forms.SystemInformation]::VirtualScreen
        $dbmp = New-Object System.Drawing.Bitmap $vs.Width, $vs.Height
        $dg = [System.Drawing.Graphics]::FromImage($dbmp)
        $dg.CopyFromScreen($vs.Left, $vs.Top, 0, 0, $dbmp.Size)
        $dg.Dispose()
        $dbmp.Save($desk, [System.Drawing.Imaging.ImageFormat]::Png)
        $dbmp.Dispose()
        $fgName = 'none'
        if ($fg -ne [IntPtr]::Zero) { $fgName = ClassOf $fg }
        Emit $out "desktop shot saved $($vs.Width)x$($vs.Height) -> $desk"
        Why 'desktop-shot' "the whole console session at collect, $($vs.Width)x$($vs.Height); the foreground was class '$fgName', not the guest's window"
    } catch {
        $sentence = "desktop shot failed: $($_.Exception.Message)"
        Emit $out $sentence
        Why 'desktop-shot' $sentence
    }
}

# 7. WHAT THE FOREGROUND WINDOW SAYS, in its own words. The sampler reads
#    a toast's text the moment it sees one; this reads WHATEVER holds the
#    foreground at collect, because the class of a blocker ("a
#    ShellExperienceHost window titled 'New notification'") names the
#    family and never WHOSE toast it is -- which is the question the
#    2026-09-16 notes red left open.
Emit $out '== foreground text =='
$fgtext = Join-Path $dir "$Leg-fgtext.txt"
Reset $fgtext
if ($fg -eq [IntPtr]::Zero) {
    Emit $fgtext 'no window held the foreground at collect, so there was nothing to read'
} elseif ($fgIsGuest) {
    Emit $fgtext ("the foreground was the guest's own window: " + (Describe $fg))
    Emit $fgtext 'no shell surface was covering it, so no UI Automation walk was made'
} else {
    Emit $fgtext (Describe $fg)
    Emit $fgtext ('uia: ' + (ToastText $fg))
}
Emit $out (Get-Content $fgtext -Raw)

# 8. THE NOTIFICATION DATABASE: what arrived, from whom, with its text --
#    the platform keeps every notification still in the Action Center in
#    a SQLite file, and it is the only record that names WHOSE toast a
#    banner was once the banner has closed (the seventh and eighth notes
#    reds could not, 2026-09-16). Copied as-is; the host renders it.
Emit $out '== notifications =='
$wpn = Join-Path $dir "$Leg-wpn.db"
if (Test-Path $wpn) { Remove-Item $wpn -Force }
try {
    $src = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Notifications\wpndatabase.db'
    Copy-Item $src $wpn -Force
    Emit $out "notification database copied $((Get-Item $wpn).Length) bytes -> $wpn"
    Why 'notifications' "the platform's own database, copied at collect"
} catch {
    $sentence = "notification database copy failed: $($_.Exception.Message)"
    Emit $out $sentence
    Why 'notifications' $sentence
}

Emit $out 'COLLECTDONE'
exit 0
