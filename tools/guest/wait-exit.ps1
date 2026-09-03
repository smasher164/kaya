# Block until C:\kaya\<File> carries EXIT= or <Seconds> pass, then print
# the file (run_one_suite in tools/deploy-win.py says why).
# THE VERDICT OUTRANKS THE CORPSE: EXIT= is written only once the guest
# fully terminates, and a terminating process can be KERNEL-HELD ~60s
# past its verdict (docs/traps.md "exit() is not final on Windows"), so
# the verdict gets a short grace and the wait leaves under KAYA_LINGER.
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
