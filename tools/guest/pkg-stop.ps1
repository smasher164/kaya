# Stops a packaged leg's invoker that outlived the runner's deadline, so its
# late guest cannot start during another leg (docs/traps.md, the packaged leg
# launched eight minutes late).
param([Parameter(Mandatory = $true)][string]$Leg)
$mine = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.CommandLine -like "*pkg-run.ps1*-Inner pkg_$Leg.cmd*" })
foreach ($p in $mine) {
    Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
    Write-Output ("pkg-stop: stopped the invoker {0}, started {1:HH:mm:ss}" -f $p.ProcessId, $p.CreationDate)
}
if ($mine.Count -eq 0) {
    Write-Output "pkg-stop: no invoker of $Leg was alive"
}
