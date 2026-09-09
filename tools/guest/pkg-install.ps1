# Pack the staged MSIX and install it, ON THE GUEST (docs/packaging-plan.md
# section 3.1). Everything here reads the staged AppxManifest.xml, which
# tools/lib/packaging/windows.py generated from guests/assets/identity.toml:
# no name, id or publisher is spelled twice.
#
# WHY A FILE AND NOT AN INLINE -Command: through ssh and cmd a
# `powershell -Command "..."` arrives as one quoted string PowerShell PRINTS
# (docs/traps.md, measured 2026-09-01).
#
# WHY THE CONSOLE SESSION: deployment initializes the Process Lifetime
# Manager, which an ssh session (session 0, its own window station) cannot
# reach - measured 2026-09-08, `Failed to initialize PLM with error
# 0x80070005` in the PackagesInUseClosed state handler. The runner starts
# this through schtasks /it, the same door a WinUI guest goes through.
#
# WHY SIGNED AND NOT -AllowUnsigned: measured on this VM, the unsigned
# namespace is refused at manifest validation for every publisher spelling
# INCLUDING Microsoft's own documented sample; the self-signed certificate
# is the route that installs. Part 2 replaces the certificate; nothing else
# about the artifact changes.
param(
    [string]$Stage = 'C:\kaya\pkgstage',
    [string]$Msix = 'C:\kaya\kaya.msix',
    [string]$Pfx = 'C:\kaya\kaya-package.pfx',
    [string]$Password = 'kaya'
)
$ErrorActionPreference = 'Continue'

function Fail($why) {
    Write-Output "pkg-install: FAILED - $why"
    Write-Output 'PKGINSTALLDONE'
    exit 1
}

$sdk = 'C:\Program Files (x86)\Windows Kits\10\bin\10.0.26100.0\arm64'
$makeappx = Join-Path $sdk 'makeappx.exe'
$signtool = Join-Path $sdk 'signtool.exe'
foreach ($tool in @($makeappx, $signtool)) {
    if (-not (Test-Path $tool)) { Fail "$tool is not on this guest" }
}

$manifestPath = Join-Path $Stage 'AppxManifest.xml'
if (-not (Test-Path $manifestPath)) { Fail "$manifestPath was never staged" }
[xml]$manifest = Get-Content -Path $manifestPath -Encoding UTF8
$name = $manifest.Package.Identity.Name
$publisher = $manifest.Package.Identity.Publisher
$apps = @($manifest.Package.Applications.Application | ForEach-Object { $_.Id })
if (-not $name -or -not $publisher) { Fail 'the staged manifest declares no Identity' }
Write-Output "pkg-install: manifest declares $name, publisher $publisher, entry points $($apps -join ',')"

# THE CERTIFICATE, ONCE, AND IDEMPOTENTLY. Its subject IS the manifest's
# publisher - deployment refuses any other pair - so it follows the
# declaration like everything else here.
$cert = Get-ChildItem Cert:\CurrentUser\My |
        Where-Object { $_.Subject -eq $publisher } | Select-Object -First 1
if (-not $cert) {
    $cert = New-SelfSignedCertificate -Type Custom -Subject $publisher `
        -KeyUsage DigitalSignature -FriendlyName 'kaya package signing' `
        -CertStoreLocation 'Cert:\CurrentUser\My' `
        -TextExtension @('2.5.29.37={text}1.3.6.1.5.5.7.3.3',
                         '2.5.29.19={text}Subject Type:End Entity')
    Write-Output "pkg-install: minted a signing certificate for $publisher"
}
if (-not $cert) { Fail "no signing certificate for $publisher" }
$trusted = Get-ChildItem Cert:\LocalMachine\TrustedPeople -ErrorAction SilentlyContinue |
           Where-Object { $_.Thumbprint -eq $cert.Thumbprint }
if (-not $trusted) {
    $cer = Join-Path $env:TEMP 'kaya-package.cer'
    Export-Certificate -Cert $cert -FilePath $cer | Out-Null
    Import-Certificate -FilePath $cer -CertStoreLocation Cert:\LocalMachine\TrustedPeople | Out-Null
    Remove-Item -Force $cer -ErrorAction SilentlyContinue
    Write-Output "pkg-install: trusted $($cert.Thumbprint) for this machine"
}
Write-Output "pkg-install: signing certificate $($cert.Thumbprint) ($($cert.Subject))"

$pw = ConvertTo-SecureString -String $Password -Force -AsPlainText
Export-PfxCertificate -Cert $cert -FilePath $Pfx -Password $pw | Out-Null

$packed = & $makeappx pack /o /d $Stage /p $Msix 2>&1
if ($LASTEXITCODE -ne 0) { Fail "makeappx pack: $($packed | Select-Object -Last 4)" }
Write-Output "pkg-install: packed $Msix ($((Get-Item $Msix).Length) bytes)"

$signed = & $signtool sign /fd SHA256 /f $Pfx /p $Password $Msix 2>&1
if ($LASTEXITCODE -ne 0) { Fail "signtool sign: $($signed | Select-Object -Last 4)" }

Get-AppxPackage -Name $name -ErrorAction SilentlyContinue | ForEach-Object {
    Remove-AppxPackage -Package $_.PackageFullName -ErrorAction SilentlyContinue
}
try { Add-AppxPackage -Path $Msix -ErrorAction Stop }
catch { Fail "Add-AppxPackage: $(($_.Exception.Message -split "`r?`n" | Where-Object { $_ -match 'error 0x|HRESULT' }) -join ' | ')" }

$pkg = Get-AppxPackage -Name $name
if (-not $pkg) { Fail "Add-AppxPackage reported success and $name is not installed" }

# AND TAKE THE INSTALL'S OWN TOAST DOWN. Deployment raises a system
# notification that the user toast toggle the deploy sets does NOT suppress,
# and while a toast is up SetForegroundWindow fails for everything else - the
# desk warm-up that runs a second after this install was measured losing to
# `ShellExperienceHost "New notification"` through both of its remedies
# (2026-09-08; docs/traps.md, "A shell toast holds the foreground, and ten
# legs die of it"). The shell restarts the host on demand.
Get-Process ShellExperienceHost -ErrorAction SilentlyContinue |
    Stop-Process -Force -ErrorAction SilentlyContinue
Write-Output 'pkg-install: took the install toast down (ShellExperienceHost)'
Write-Output "pkg-install: installed $($pkg.PackageFullName)"
Write-Output "pkg-install: family $($pkg.PackageFamilyName)"
foreach ($app in $apps) {
    Write-Output "pkg-install: aumid $($pkg.PackageFamilyName)!$app"
}
Write-Output 'pkg-install: OK'
Write-Output 'PKGINSTALLDONE'
