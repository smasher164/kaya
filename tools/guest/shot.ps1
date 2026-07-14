# Screenshot the guest desktop, foregrounding the kaya window first.
# Must run in the interactive session (schtasks /it).
$w = New-Object -ComObject WScript.Shell
$null = $w.AppActivate("kaya milestone 0")
Start-Sleep -Seconds 1
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms
$b = [System.Windows.Forms.SystemInformation]::VirtualScreen
$bmp = New-Object System.Drawing.Bitmap $b.Width, $b.Height
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.CopyFromScreen($b.Left, $b.Top, 0, 0, $bmp.Size)
$bmp.Save("C:\kaya\shot.png")
