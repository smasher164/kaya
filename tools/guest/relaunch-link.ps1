# THE SECOND ACT'S LINK DOOR (docs/app-links-plan.md L5): the runner asks
# the SHELL to open the URL act one printed, and Windows starts the app
# through the protocol registration the app wrote for itself
# (crates/kaya/src/winui/mod.rs's links_declared). The started process reads
# the URL out of its OWN activation arguments and adopts the act-two marker
# act one left on disk. The runner's other doors are relaunch-com.ps1 and
# relaunch-launch.ps1, and all three speak one protocol to it: an ACT2: line
# and RELAUNCHDONE.
#
# NO KAYA_* THAT SIGNALS THE HARNESS may reach the child, relaunch-launch.ps1's
# rule: with KAYA_SELFTEST set the core runs ACT ONE again from the top and
# never adopts the marker, so the leg would pass having measured nothing that
# survived. THE CHILD INHERITS THIS SCRIPT'S ENVIRONMENT: the process a
# ShellExecute starts is a DIRECT CHILD of the caller and takes its environment
# block (measured 2026-09-09), which is why this door can set the leg's own
# XDG_STATE_HOME itself where relaunch-com.ps1 has to lend it to the USER
# environment (a LocalServer32 is started by the COM service, not by us).
#
# THE URL COMES FROM A FILE, never an argument: `=` is an argument delimiter in
# a .cmd's %1..%9 and `&` is a cmd operator, so a link with a query arrives as
# two tokens or runs the rest of the line (measured 2026-09-09).
#
# THE CHILD HAS NO STDOUT. ShellExecute gives the started process no console
# and no inherited handle, so act two's own printing is unreachable here  -  the
# verdict file is the record, and KAYA_PANIC_LOG below is what turns a panic
# into a line rather than a silence.
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

$state = "C:\kaya\legs\$Leg\state"
$env:XDG_STATE_HOME = $state
# THE ACT-TWO LAYOUT, whose one definition is crates/kaya/src/act2.rs
# (`<state>/act2/<id>`, `<state>` = $XDG_STATE_HOME\kaya here).
$verdict = Join-Path $state "kaya\act2\$Id\act2.verdict"
$marker = Join-Path $state "kaya\act2\$Id\marker"
Remove-Item -LiteralPath $verdict -Force -ErrorAction SilentlyContinue
Write-Output "relaunch-link: watching $verdict"

$urlfile = "C:\kaya\legs\$Leg\relaunch-url.txt"
if (-not (Test-Path -LiteralPath $urlfile)) {
    Write-Output "relaunch-link: the runner wrote no $urlfile, so there is no link to open"
    Write-Output 'RELAUNCHDONE'
    exit 1
}
$url = ((Get-Content -LiteralPath $urlfile -Encoding UTF8) -join '').Trim()
if (-not $url) {
    Write-Output "relaunch-link: $urlfile is empty, so there is no link to open"
    Write-Output 'RELAUNCHDONE'
    exit 1
}
Write-Output "relaunch-link: the link is $url"

# THE MARKER IS WHAT MAKES THIS A SECOND ACT, relaunch-launch.ps1's clause:
# said before the door opens, because a launch with no marker is act one all
# over again and its verdict would read like a pass.
if (-not (Test-Path -LiteralPath $marker)) {
    Write-Output "relaunch-link: act one left no $marker, so opening the link would start the app fresh rather than continue the scene"
    Write-Output 'RELAUNCHDONE'
    exit 1
}

foreach ($name in @('KAYA_SELFTEST', 'KAYA_SELFTEST_SCRIPT', 'KAYA_ACT2_DIR',
                    'KAYA_ACT2_VERDICT', 'KAYA_VERB_TRACE', 'KAYA_LINGER',
                    'KAYA_WIN_SLOT', 'KAYA_APPEARANCE')) {
    Remove-Item -LiteralPath "Env:$name" -Force -ErrorAction SilentlyContinue
}
$log = "C:\kaya\out_$Leg-act2app.txt"
Remove-Item -LiteralPath $log -Force -ErrorAction SilentlyContinue
$env:KAYA_PANIC_LOG = $log
# WHAT THE CHILD ACTUALLY INHERITS, printed rather than promised.
$kept = @(Get-ChildItem Env: | Where-Object { $_.Name -like 'KAYA_*' } |
          ForEach-Object { $_.Name } | Sort-Object)
Write-Output "relaunch-link: the child inherits KAYA_* = $($kept -join ', ')"
Write-Output "relaunch-link: XDG_STATE_HOME=$env:XDG_STATE_HOME"

$expected = Join-Path 'C:\kaya' $Exe
if (-not (Test-Path -LiteralPath $expected)) {
    Write-Output "relaunch-link: $expected is not on this guest, so no registration could point at it"
    Write-Output 'RELAUNCHDONE'
    exit 1
}

# WHO WAS RUNNING BEFORE THE DOOR OPENED, so the process the shell starts can
# be told from the ones already there.
$before = @{}
foreach ($p in Get-Process -ErrorAction SilentlyContinue) { $before[$p.Id] = $true }

$t0 = Get-Date
Start-Process -FilePath $url
Write-Output "relaunch-link: asked the shell to open $url"

# THE SCHEME IS A PER-USER CLAIM AND THE LAST WRITER WINS (docs/traps.md,
# 2026-09-09): every kaya guest declares the same id, so a registration made
# after act one's would send this door to ANOTHER app's exe. Nothing else can
# see that  -  the wrong app would start, adopt nothing, and this door would sit
# out its deadline naming no cause  -  so the process the shell actually started
# is READ BACK and refused by name when it is not the leg's own.
$started = $null
$others = @()
$strays = @()
$until = (Get-Date).AddSeconds(20)
while ((Get-Date) -lt $until -and -not $started) {
    foreach ($p in Get-Process -ErrorAction SilentlyContinue) {
        if ($before.ContainsKey($p.Id)) { continue }
        $path = $null
        try { $path = $p.Path } catch { $path = $null }
        if (-not $path) { continue }
        if ($path -eq $expected) { $started = $p; break }
        if ($others -notcontains $path) { $others += $path }
        # A GUEST THIS DOOR STARTED BY MISTAKE IS STILL THIS DOOR'S: the
        # wrong app would otherwise sit on the desktop for the rest of the
        # lane, and the next leg's window reads would find it.
        if ($path -like 'C:\kaya\*' -and
                -not ($strays | Where-Object { $_.Id -eq $p.Id })) {
            $strays += [pscustomobject]@{ Id = $p.Id; Path = $path }
        }
    }
    if (-not $started) { Start-Sleep -Milliseconds 200 }
}
if ($started) {
    $waited = [int]((Get-Date) - $t0).TotalMilliseconds
    Write-Output "relaunch-link: the shell started $expected as pid $($started.Id) after ${waited}ms"
} else {
    Write-Output "relaunch-link: no $expected appeared within 20s of opening $url"
    Write-Output "relaunch-link:   the scheme's registration names some other application, or none"
    Write-Output "relaunch-link:   new processes seen instead: $(if ($others) { $others -join ', ' } else { '(none)' })"
    # OBJECTS RATHER THAN A HASHTABLE: an index expression read EMPTY here
    # twice, and `stopped pid 6012 ()` is a sentence that names nothing
    # (watched on the VM 2026-09-09).
    foreach ($stray in $strays) {
        Stop-Process -Id $stray.Id -Force -ErrorAction SilentlyContinue
        Write-Output "relaunch-link:   stopped pid $($stray.Id) ($($stray.Path)), which this door started"
    }
    Write-Output 'RELAUNCHDONE'
    exit 1
}

# NOT $deadline: PowerShell is case-insensitive, so assigning it would write
# the [int] parameter and fail with an unrelated cast error.
$until = (Get-Date).AddSeconds($Deadline)
while ((Get-Date) -lt $until) {
    if (Test-Path -LiteralPath $verdict) {
        $line = (Get-Content -LiteralPath $verdict -Encoding UTF8 -ErrorAction SilentlyContinue) -join ' '
        if ($line) {
            $waited = [int]((Get-Date) - $t0).TotalMilliseconds
            Write-Output "relaunch-link: act two answered in ${waited}ms from $verdict"
            Write-Output "ACT2: $line"
            break
        }
    }
    Start-Sleep -Milliseconds 250
}
$answered = (Test-Path -LiteralPath $verdict)
if (-not $answered) {
    # THE DEADLINE SAYS WHAT IT SAW, never just that it waited.
    Write-Output "relaunch-link: no act-two verdict after ${Deadline}s"
    Write-Output "relaunch-link:   $verdict exists=$answered"
    Write-Output "relaunch-link:   the marker at $marker exists=$(Test-Path -LiteralPath $marker) (act two consumes it on adoption)"
    if ($started.HasExited) {
        # A NUMBER OR A '?', never a blank: a Process object answers an EMPTY
        # ExitCode here (watched on the VM 2026-09-09), and `the process
        # exited  and wrote no verdict` reads like a zero to the next person.
        $code = '?'
        try { $started.Refresh(); $code = "$($started.ExitCode)" } catch { $code = '?' }
        if ($code -eq '') { $code = '?' }
        Write-Output "relaunch-link:   pid $($started.Id) exited with code $code and wrote no verdict"
    } else {
        Write-Output "relaunch-link:   pid $($started.Id) is still running"
    }
}
# A PANIC IS THE ONLY THING THE CHILD CAN SAY: ShellExecute left it no stdout,
# so KAYA_PANIC_LOG is its one channel.
if ((Test-Path -LiteralPath $log) -and (Get-Item -LiteralPath $log).Length -gt 0) {
    Write-Output "relaunch-link: --- $log ---"
    Get-Content -LiteralPath $log | ForEach-Object { Write-Output $_ }
}
if (-not $started.HasExited) {
    # The lane's next leg must not meet this window: the process is act two's,
    # started through this door, so this door ends it.
    Stop-Process -Id $started.Id -Force -ErrorAction SilentlyContinue
    Write-Output "relaunch-link: stopped pid $($started.Id), which this door started"
}
Write-Output 'RELAUNCHDONE'
if ($answered) { exit 0 } else { exit 1 }
