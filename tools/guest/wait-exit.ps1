# Block until C:\kaya\<File> carries EXIT= or <Seconds> pass, then print
# the file. One resident process per leg in place of a host-driven ssh
# poll — the why and the measurements live at run_one_suite in
# tools/deploy-win.py.
#
# THE VERDICT OUTRANKS THE CORPSE: EXIT= is written by cmd.exe only
# after the guest process fully terminates, and a terminating process
# can be KERNEL-HELD for ~60s past its verdict (an uncompleted
# synchronous IO holds even TerminateProcess; docs/traps.md "exit() is
# not final on Windows" — seven dialog legs at 64s each, verdict at
# ~2s). So once the verdict line is out, EXIT= gets a short grace and
# then the wait leaves under KAYA_LINGER, which run_one_suite treats by
# the doctrine it already states: the verdict TEXT is the authority.
param([string]$File, [int]$Seconds = 290)
$path = "C:\kaya\$File"
$deadline = (Get-Date).AddSeconds($Seconds)
$verdictSeen = $null
$linger = $false
while ((Get-Date) -lt $deadline) {
    if (Test-Path $path) {
        if (Select-String -Quiet -SimpleMatch -Pattern 'EXIT=' -Path $path) {
            break
        }
        if (-not $verdictSeen -and (Select-String -Quiet -SimpleMatch -Pattern 'KAYA_SELFTEST:' -Path $path)) {
            $verdictSeen = (Get-Date)
        }
        if ($verdictSeen -and ((Get-Date) - $verdictSeen).TotalSeconds -gt 6) {
            $linger = $true
            break
        }
    }
    Start-Sleep -Milliseconds 150
}
if (Test-Path $path) { Get-Content -Raw $path }
if ($linger) {
    Write-Output 'KAYA_LINGER: verdict out, the process is still terminating (kernel-held exit)'
}
