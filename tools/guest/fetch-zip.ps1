# Fetch a zip BY VERSION AND BY BYTES and expand it under Dest: the
# sha256 recorded beside the version in tools/deploy-win.py is compared
# BEFORE anything is expanded, and a mismatch is this script's own
# refusal (tools/check-pins.py holds the shape).
#
# A FILE, NOT AN INLINE -Command: a script passed through ssh and cmd
# as `powershell -Command \"...\"` arrives as ONE quoted string, and
# PowerShell evaluates a bare string expression by PRINTING it — the
# Go 1.27 pin was echoed and never installed for weeks while the go
# legs ran the VM's system Go (measured 2026-09-01, docs/traps.md).
param(
    [Parameter(Mandatory = $true)][string]$Url,
    [Parameter(Mandatory = $true)][string]$Sha256,
    [Parameter(Mandatory = $true)][string]$Dest
)
$ErrorActionPreference = 'Stop'
$zip = "$Dest.zip"
Remove-Item -Recurse -Force $Dest -ErrorAction SilentlyContinue
Remove-Item -Force $zip -ErrorAction SilentlyContinue
Invoke-WebRequest -Uri $Url -OutFile $zip
$got = (Get-FileHash -Algorithm SHA256 $zip).Hash.ToLower()
if ($got -ne $Sha256.ToLower()) {
    Write-Output "fetch-zip: $Url arrived as sha256 $got, not the pinned $Sha256 - refusing to expand it"
    Remove-Item -Force $zip
    exit 1
}
Expand-Archive -Path $zip -DestinationPath $Dest -Force
Remove-Item -Force $zip
Write-Output "fetch-zip: $Url verified ($got) and expanded under $Dest"
exit 0
