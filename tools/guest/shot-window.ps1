# Photograph the GUEST'S OWN WINDOW, not the desktop it sits on
# (shot.ps1 beside this grabs the whole virtual screen, for "what is
# covering my app"). It WAITS for the window and asks the platform where
# it is — no fixed sleep, no fixed crop, both of which have shipped
# photographs of the wallpaper (docs/traps.md) — and exits nonzero
# rather than saving one.
param(
    [string]$Process = "python",
    [int]$TimeoutSeconds = 60,
    [string]$Out = "C:\kaya\shot.png"
)

Add-Type @"
using System;
using System.Runtime.InteropServices;
public class KayaWin {
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")]
    public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);
    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);
    // GetWindowRect INCLUDES THE DWM SHADOW, so its rect carries a
    // sliver of wallpaper down both edges.
    [DllImport("dwmapi.dll")]
    public static extern int DwmGetWindowAttribute(
        IntPtr hWnd, int attr, out RECT value, int size);
    public const int ExtendedFrameBounds = 9;
}
"@

$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
$handle = [IntPtr]::Zero
while ((Get-Date) -lt $deadline) {
    $p = Get-Process -Name $Process -ErrorAction SilentlyContinue |
        Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
    if ($p) { $handle = $p.MainWindowHandle; break }
    Start-Sleep -Milliseconds 250
}
if ($handle -eq [IntPtr]::Zero) {
    Write-Error "shot-window: no '$Process' window within $TimeoutSeconds s"
    exit 1
}

$null = [KayaWin]::SetForegroundWindow($handle)
Start-Sleep -Milliseconds 400

$r = New-Object KayaWin+RECT
$dwm = [KayaWin]::DwmGetWindowAttribute(
    $handle, [KayaWin]::ExtendedFrameBounds, [ref]$r, [System.Runtime.InteropServices.Marshal]::SizeOf($r))
if ($dwm -ne 0) {
    # Pre-DWM or a composition-less session: the shadow-inclusive rect
    # is a looser picture of the same window.
    if (-not [KayaWin]::GetWindowRect($handle, [ref]$r)) {
        Write-Error "shot-window: neither DwmGetWindowAttribute nor GetWindowRect answered"
        exit 1
    }
}
$w = $r.Right - $r.Left
$h = $r.Bottom - $r.Top
if ($w -le 0 -or $h -le 0) {
    Write-Error "shot-window: window rect is empty ($w x $h)"
    exit 1
}

Add-Type -AssemblyName System.Drawing
$bmp = New-Object System.Drawing.Bitmap $w, $h
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.CopyFromScreen($r.Left, $r.Top, 0, 0, $bmp.Size)
$bmp.Save($Out)
Write-Output "shot-window: $($w)x$($h) at $($r.Left),$($r.Top) -> $Out"
