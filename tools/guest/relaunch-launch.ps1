# THE SECOND ACT'S PLAIN DOOR (docs/tasks-s4-plan.md P5): S9's door is a
# notification tap; an S4 scene relaunches with NOTHING PENDING, so this
# starts the same exe the way a user starts it and the act-two marker on
# disk is the only thing that says a second act exists (crates/kaya/src/
# act2.rs). The runner's other door is relaunch-com.ps1, and the two speak
# one protocol to the runner: an ACT2: line and RELAUNCHDONE.
#
# NO KAYA_* THAT SIGNALS THE HARNESS may reach the child: with
# KAYA_SELFTEST set the core runs ACT ONE again from the top and never
# adopts the marker, so the leg would pass having measured nothing that
# survived. The variables the DEPLOY sets machine-wide (KAYA_SCENES_DIR,
# KAYA_ASSET_DIR, KAYA_LIB) are this guest's installation and stay: a user
# launching the app here inherits exactly those.
#
# WHY A FILE AND NOT AN INLINE -Command: through ssh and cmd a
# `powershell -Command "..."` arrives as one quoted string PowerShell
# PRINTS (docs/traps.md, measured 2026-09-01).
#
# ASCII ONLY: a guest .ps1 is read in the machine's ANSI code page
# (docs/traps.md; tools/check-steps.py refuses a non-ASCII byte outside a
# comment).
param(
    [Parameter(Mandatory = $true)][string]$Leg,
    [Parameter(Mandatory = $true)][string]$Exe,
    [Parameter(Mandatory = $true)][string]$Id,
    [int]$Deadline = 150
)
$ErrorActionPreference = 'Continue'

# THE LEG'S OWN STATE HOME, which is where act one left its marker: the
# harness's scratch is ONE tree per app and this lane pools many legs of one
# app, so every launcher sets `XDG_STATE_HOME=C:\kaya\legs\<leg>\state`
# and clears it at its own start. The door must hand the SAME one to the
# process it starts, or act two adopts nothing and runs act one again from
# the top. NOT CLEARED HERE: keeping it is the whole point of act two.
$state = "C:\kaya\legs\$Leg\state"
$env:XDG_STATE_HOME = $state
# THE ACT-TWO LAYOUT, whose one definition is crates/kaya/src/act2.rs
# (`<state>/act2/<id>`, `<state>` = $XDG_STATE_HOME\kaya here).
$verdict = Join-Path $state "kaya\act2\$Id\act2.verdict"
$marker = Join-Path $state "kaya\act2\$Id\marker"
Remove-Item -LiteralPath $verdict -Force -ErrorAction SilentlyContinue
Write-Output "relaunch-launch: watching $verdict"

# THE MARKER IS WHAT MAKES THIS A SECOND ACT. Said before the door opens,
# because a plain launch with no marker is act one all over again and its
# verdict would read like a pass.
if (-not (Test-Path -LiteralPath $marker)) {
    Write-Output "relaunch-launch: act one left no $marker, so a plain launch would start the app fresh rather than continue the scene"
    Write-Output 'RELAUNCHDONE'
    exit 1
}

foreach ($name in @('KAYA_SELFTEST', 'KAYA_SELFTEST_SCRIPT', 'KAYA_ACT2_DIR',
                    'KAYA_ACT2_VERDICT', 'KAYA_VERB_TRACE', 'KAYA_LINGER',
                    'KAYA_WIN_SLOT', 'KAYA_APPEARANCE')) {
    Remove-Item -LiteralPath "Env:$name" -Force -ErrorAction SilentlyContinue
}
# WHAT THE CHILD ACTUALLY INHERITS, printed rather than promised: "the door
# was plain" is a claim a reader can check only against the list.
$kept = @(Get-ChildItem Env: | Where-Object { $_.Name -like 'KAYA_*' } |
          ForEach-Object { $_.Name } | Sort-Object)
Write-Output "relaunch-launch: the child inherits KAYA_* = $($kept -join ', ')"
Write-Output "relaunch-launch: XDG_STATE_HOME=$env:XDG_STATE_HOME"

$path = Join-Path 'C:\kaya' $Exe
if (-not (Test-Path -LiteralPath $path)) {
    Write-Output "relaunch-launch: $path is not on this guest, so there is nothing to launch"
    Write-Output 'RELAUNCHDONE'
    exit 1
}
$log = "C:\kaya\out_$Leg-act2app.txt"
Remove-Item -LiteralPath $log -Force -ErrorAction SilentlyContinue
$t0 = Get-Date
$proc = Start-Process -FilePath $path -WorkingDirectory 'C:\kaya' `
    -RedirectStandardOutput $log -RedirectStandardError "$log.err" -PassThru
Write-Output "relaunch-launch: started $path plainly as pid $($proc.Id)"

# NOT $deadline: PowerShell is case-insensitive, so assigning it would write
# the [int] parameter and fail with an unrelated cast error.
$until = (Get-Date).AddSeconds($Deadline)
while ((Get-Date) -lt $until) {
    if (Test-Path -LiteralPath $verdict) {
        $line = (Get-Content -LiteralPath $verdict -Encoding UTF8 -ErrorAction SilentlyContinue) -join ' '
        if ($line) {
            $waited = [int]((Get-Date) - $t0).TotalMilliseconds
            Write-Output "relaunch-launch: act two answered in ${waited}ms from $verdict"
            Write-Output "ACT2: $line"
            break
        }
    }
    Start-Sleep -Milliseconds 250
}
$answered = (Test-Path -LiteralPath $verdict)
if (-not $answered) {
    # THE DEADLINE SAYS WHAT IT SAW, never just that it waited.
    Write-Output "relaunch-launch: no act-two verdict after ${Deadline}s"
    Write-Output "relaunch-launch:   $verdict exists=$answered"
    if ($proc.HasExited) {
        # A NUMBER OR A '?', never a blank: Start-Process's own Process
        # object answers an EMPTY ExitCode here (watched printing on the VM
        # 2026-09-09), and `the process exited  and wrote no verdict` reads
        # like a zero to the next person.
        $code = '?'
        try { $proc.Refresh(); $code = "$($proc.ExitCode)" } catch { $code = '?' }
        if ($code -eq '') { $code = '?' }
        Write-Output "relaunch-launch:   the process exited with code $code and wrote no verdict"
    } else {
        Write-Output "relaunch-launch:   pid $($proc.Id) is still running"
    }
}
# THE APP'S OWN OUTPUT, whichever way this ended: a second act that failed
# printed its reason there and nowhere else.
foreach ($f in @($log, "$log.err")) {
    if ((Test-Path -LiteralPath $f) -and (Get-Item -LiteralPath $f).Length -gt 0) {
        Write-Output "relaunch-launch: --- $f ---"
        Get-Content -LiteralPath $f | ForEach-Object { Write-Output $_ }
    }
}
if (-not $proc.HasExited) {
    # The lane's next leg must not meet this window: the process is act
    # two's, started by this script, so this script ends it.
    Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
    Write-Output "relaunch-launch: stopped pid $($proc.Id), which this door started"
}
Write-Output 'RELAUNCHDONE'
if ($answered) { exit 0 } else { exit 1 }
