# Block until C:\kaya\<File> carries EXIT= or <Seconds> pass, then print
# the file. One resident process per leg in place of a host-driven ssh
# poll — the why and the measurements live at run_one_suite in
# tools/deploy-win.sh.
param([string]$File, [int]$Seconds = 290)
$path = "C:\kaya\$File"
$deadline = (Get-Date).AddSeconds($Seconds)
while ((Get-Date) -lt $deadline) {
    if ((Test-Path $path) -and (Select-String -Quiet -SimpleMatch -Pattern 'EXIT=' -Path $path)) {
        break
    }
    Start-Sleep -Milliseconds 150
}
if (Test-Path $path) { Get-Content -Raw $path }
