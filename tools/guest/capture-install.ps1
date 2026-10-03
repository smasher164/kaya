# The Windows lane's ONE-TIME capture install (docs/capture-plan.md section 9, ruled
# 2026-10-02; the recipe and what it leaves on the machine: docs/HACKING.md,
# "The Windows capture install"). Run over ssh, which is elevated on the VM:
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File C:\kaya\capture-install.ps1 -Mode check
#   powershell -NoProfile -ExecutionPolicy Bypass -File C:\kaya\capture-install.ps1 -Mode install
#
# check prints one line per part, `capture-install: <part> ok|MISSING|STALE ...`,
# and exits 0 only when every part is in place. install puts in place what
# check finds missing and says whether a reboot is still owed.
param(
    [ValidateSet("check", "install")] [string]$Mode = "check",
    [string]$Staged = "C:\kaya"
)
$ErrorActionPreference = "Stop"

$InstallDir = "C:\Program Files\kaya-capture"
$Dll = Join-Path $InstallDir "kaya_winvcam.dll"
$Cameras = @(
    @{ Clsid = "{73D25515-3E88-5187-8020-696B652FA737}"; Name = "kaya Synthetic Camera 1" },
    @{ Clsid = "{9D4DF51D-C03E-5430-9201-371FF0648E12}"; Name = "kaya Synthetic Camera 2" }
)
$CableZip = "https://download.vb-audio.com/Download_CABLE/VBCABLE_Driver_Pack45.zip"
$CableSha = "B950E39F01AF1D04EA623C8F6D8EB9B6EA5C477C637295FABF20631C85116BFB"

function Sha([string]$Path) { (Get-FileHash -Algorithm SHA256 $Path).Hash }

function Check-Dll {
    $stagedDll = Join-Path $Staged "kaya_winvcam.dll"
    if (-not (Test-Path $Dll)) { return "MISSING $Dll" }
    if ((Test-Path $stagedDll) -and ((Sha $stagedDll) -ne (Sha $Dll))) {
        return "STALE $Dll differs from the deployed $stagedDll"
    }
    return "ok $Dll sha256 $(Sha $Dll)"
}

function Check-Clsids {
    foreach ($c in $Cameras) {
        $key = "HKLM:\SOFTWARE\Classes\CLSID\$($c.Clsid)\InprocServer32"
        if (-not (Test-Path $key)) { return "MISSING $key" }
        $p = Get-ItemProperty $key
        if ($p.'(default)' -ne $Dll -or $p.ThreadingModel -ne "Both") {
            return "STALE $key names '$($p.'(default)')' threading '$($p.ThreadingModel)'"
        }
    }
    return "ok both class ids name $Dll"
}

function Check-Cable {
    $render = Get-PnpDevice -PresentOnly -Class AudioEndpoint -ErrorAction SilentlyContinue |
        Where-Object { $_.FriendlyName -like "CABLE Input*" -and $_.Status -eq "OK" }
    $capture = Get-PnpDevice -PresentOnly -Class AudioEndpoint -ErrorAction SilentlyContinue |
        Where-Object { $_.FriendlyName -like "CABLE Output*" -and $_.Status -eq "OK" }
    if ($render -and $capture) { return "ok '$($render.FriendlyName)' and '$($capture.FriendlyName)'" }
    $driver = Get-WindowsDriver -Online -ErrorAction SilentlyContinue | Where-Object { $_.OriginalFileName -like "*vbMmeCable64_win10.inf" }
    if ($driver) { return "MISSING the endpoints, though $($driver.Driver) is staged: a reboot is owed" }
    return "MISSING VB-CABLE (no CABLE Input / CABLE Output endpoint)"
}

function Check-Privacy {
    $bad = @()
    foreach ($kind in "webcam", "microphone") {
        foreach ($hive in "HKLM", "HKCU") {
            $v = (Get-ItemProperty "${hive}:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\$kind" -ErrorAction SilentlyContinue).Value
            if ($v -eq "Deny") { $bad += "$hive $kind Deny" }
        }
    }
    if ($bad) { return "STALE the desktop-apps privacy switch reads $($bad -join ', ')" }
    return "ok no camera or microphone privacy switch reads Deny"
}

function Report {
    $all = $true
    foreach ($part in @(
            @("dll", (Check-Dll)), @("clsid", (Check-Clsids)), @("cable", (Check-Cable)), @("privacy", (Check-Privacy)))) {
        # Write-Host: Write-Output inside a function becomes its return value.
        Write-Host "capture-install: $($part[0]) $($part[1])"
        if (-not $part[1].StartsWith("ok")) { $all = $false }
    }
    return $all
}

if ($Mode -eq "check") {
    if (Report) { exit 0 } else { exit 1 }
}

# ---- install ----------------------------------------------------------------

if (-not (Check-Dll).StartsWith("ok")) {
    $stagedDll = Join-Path $Staged "kaya_winvcam.dll"
    if (-not (Test-Path $stagedDll)) { throw "capture-install: no staged $stagedDll (tools/deploy-win.py ships it)" }
    New-Item -ItemType Directory -Force $InstallDir | Out-Null
    # The Frame Server holds the DLL while it serves a camera.
    Stop-Service FrameServer -Force -ErrorAction SilentlyContinue
    Stop-Service FrameServerMonitor -Force -ErrorAction SilentlyContinue
    Copy-Item -Force $stagedDll $Dll
    Write-Output "capture-install: copied $stagedDll -> $Dll"
}
foreach ($c in $Cameras) {
    $root = "HKLM:\SOFTWARE\Classes\CLSID\$($c.Clsid)"
    New-Item -Force $root | Out-Null
    Set-ItemProperty $root -Name "(default)" -Value $c.Name
    New-Item -Force "$root\InprocServer32" | Out-Null
    Set-ItemProperty "$root\InprocServer32" -Name "(default)" -Value $Dll
    Set-ItemProperty "$root\InprocServer32" -Name "ThreadingModel" -Value "Both"
    Write-Output "capture-install: registered $($c.Clsid) ($($c.Name))"
}
if (-not (Check-Cable).StartsWith("ok")) {
    $driver = Get-WindowsDriver -Online -ErrorAction SilentlyContinue | Where-Object { $_.OriginalFileName -like "*vbMmeCable64_win10.inf" }
    if (-not $driver) {
        $zip = Join-Path $Staged "VBCABLE_Driver_Pack45.zip"
        if (-not (Test-Path $zip)) {
            Invoke-WebRequest -UseBasicParsing -Uri $CableZip -OutFile $zip
        }
        if ((Sha $zip) -ne $CableSha) { throw "capture-install: $zip is sha256 $(Sha $zip), not the recorded $CableSha" }
        $dir = Join-Path $Staged "vbcable"
        Expand-Archive -Force $zip $dir
        # The vendor's own setup, silent (-i install, -h hidden); the x64
        # setup installs the ARM64 driver on Windows on Arm.
        $p = Start-Process -Wait -PassThru (Join-Path $dir "VBCABLE_Setup_x64.exe") -ArgumentList "-i", "-h"
        Write-Output "capture-install: VBCABLE_Setup_x64.exe -i -h exited $($p.ExitCode)"
    }
}
$null = Report
if (-not (Check-Cable).StartsWith("ok")) { Write-Output "capture-install: REBOOT OWED" }
