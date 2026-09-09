# Run one leg's guest INSIDE the installed package (docs/packaging-plan.md
# P3). The lane's own door is the outer run_<leg>.cmd; this is the step that
# gives the process package identity, and the inner .cmd is what actually sets
# the harness environment and runs the exe.
#
# TWO MEASURED FACTS SHAPE THIS (2026-09-08, on the VM):
#
#   -PreventBreakaway IS REQUIRED. Without it the launched process has NO
#   package identity at all - `Package.Current` throws 0x80073D54 and
#   GetCurrentApplicationUserModelId answers APPMODEL_ERROR_NO_APPLICATION  - 
#   so the leg would run as an ordinary exe out of C:\Program Files\WindowsApps
#   and prove nothing. With it the identity reaches grandchildren too, which is
#   what the inner cmd's own child needs.
#
#   THE CALLER'S ENVIRONMENT DOES NOT TRAVEL. Variables set in this session are
#   absent from the launched process; only the USER's persistent environment
#   (the deploy's `setx` values) arrives. So KAYA_SELFTEST and the rest are set
#   by the inner .cmd, and the tile slot is passed as an argument.
param(
    [Parameter(Mandatory = $true)][string]$AppId,
    [Parameter(Mandatory = $true)][string]$Inner,
    [string]$Slot = '0'
)
$ErrorActionPreference = 'Stop'

$manifest = 'C:\kaya\pkgstage\AppxManifest.xml'
if (-not (Test-Path $manifest)) {
    Write-Output "pkg-run: $manifest is missing - the package was never staged"
    exit 1
}
[xml]$staged = Get-Content -Path $manifest -Encoding UTF8
$pkg = Get-AppxPackage -Name $staged.Package.Identity.Name
if (-not $pkg) {
    Write-Output "pkg-run: $($staged.Package.Identity.Name) is not installed on this guest"
    exit 1
}
# Composed with -f rather than with escaped quotes inside a double-quoted
# string: the escaped form failed to PARSE, which took the whole script down
# and cost one leg its 298s deadline in silence (2026-09-08).
$line = '/c C:\kaya\{0} "{1}" {2}' -f $Inner, $pkg.InstallLocation, $Slot
Invoke-CommandInDesktopPackage -PackageFamilyName $pkg.PackageFamilyName -AppId $AppId `
    -Command 'C:\Windows\System32\cmd.exe' -Args $line -PreventBreakaway
Write-Output "pkg-run: $($pkg.PackageFamilyName)!$AppId <- $line"
