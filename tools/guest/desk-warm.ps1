# CAN A WINDOW ON THIS DESKTOP TAKE THE FOREGROUND? Asked once, before
# the suites, with the chord legs' OWN handover as the test — a real
# window and the guard's own poll, not a survey. It runs inside an
# interactive scheduled task because the states that refuse are
# INVISIBLE FROM SSH (an ssh session gets its own window station,
# session 0). docs/traps.md holds the measured truth table and why the
# proof is bounded by the clock rather than by a try count.
$ErrorActionPreference = 'Continue'

Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public class KayaDesk {
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassNameW(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern int GetWindowThreadProcessId(IntPtr h, out int pid);
  [DllImport("user32.dll")] public static extern IntPtr OpenInputDesktop(int flags, bool inherit, uint access);
  [DllImport("user32.dll")] public static extern bool CloseDesktop(IntPtr h);
  [DllImport("user32.dll")] public static extern IntPtr GetThreadDesktop(int tid);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern bool GetUserObjectInformationW(IntPtr h, int index, StringBuilder info, int len, out int need);
  [DllImport("kernel32.dll")] public static extern int GetCurrentThreadId();
  [DllImport("user32.dll")] public static extern bool SystemParametersInfoA(uint action, uint p, ref uint v, uint flags);
  [DllImport("user32.dll")] public static extern bool SystemParametersInfoW(uint action, uint p, IntPtr v, uint flags);
  [DllImport("user32.dll")] public static extern void keybd_event(byte key, byte scan, uint flags, IntPtr extra);
  public static string ClassOf(IntPtr h) { var sb = new StringBuilder(256); GetClassNameW(h, sb, 256); return sb.ToString(); }
  public static string TextOf(IntPtr h) { var sb = new StringBuilder(256); GetWindowTextW(h, sb, 256); return sb.ToString(); }
  public static string ObjName(IntPtr h) { int need; var sb = new StringBuilder(256); GetUserObjectInformationW(h, 2, sb, 256, out need); return sb.ToString(); }
}
'@

function Say($k, $v) { Write-Output ("deskwarm.{0}={1}" -f $k, $v) }

# The holder's name is the whole diagnosis when this fails, and a toast
# has no title — so class and owning process are what identify it.
function Describe-Foreground($tag) {
    $fg = [KayaDesk]::GetForegroundWindow()
    if ($fg -eq [IntPtr]::Zero) { Say $tag "<none>"; return }
    $owner = 0
    [void][KayaDesk]::GetWindowThreadProcessId($fg, [ref]$owner)
    $name = '<gone>'
    try { $name = (Get-Process -Id $owner -ErrorAction Stop).ProcessName } catch { }
    Say $tag ("{0} `"{1}`" ({2}/{3})" -f [KayaDesk]::ClassOf($fg), [KayaDesk]::TextOf($fg), $name, $owner)
}

Say 'session' ([System.Diagnostics.Process]::GetCurrentProcess().SessionId)

# 1. THE DESKTOP THE INPUT GOES TO must be the one this task's windows
# live on — it is not when the console session is LOCKED or a UAC prompt
# is up, and that is the only state measured to fail a real leg and the
# only one no key can clear.
$mine = [KayaDesk]::ObjName([KayaDesk]::GetThreadDesktop([KayaDesk]::GetCurrentThreadId()))
Say 'desktop' $mine
# DESKTOP_READOBJECTS|DESKTOP_SWITCHDESKTOP — enough to name it, and a
# DENIED is itself an answer: the secure desktop refuses this.
$input_desk = [KayaDesk]::OpenInputDesktop(0, $false, [uint32]0x101)
if ($input_desk -eq [IntPtr]::Zero) {
    Say 'inputdesktop' "<denied>"
    Say 'verdict' 'BLOCKED'
    Say 'reason' 'inputdesktop'
    Say 'holder' 'the input desktop refuses to be opened, which is what the secure desktop does'
    "DESKWARMDONE"
    exit 0
}
$input_name = [KayaDesk]::ObjName($input_desk)
[void][KayaDesk]::CloseDesktop($input_desk)
Say 'inputdesktop' $input_name
if ($input_name -ne $mine) {
    Say 'verdict' 'BLOCKED'
    Say 'reason' 'inputdesktop'
    Say 'holder' "input is on '$input_name', the legs' windows are on '$mine'"
    "DESKWARMDONE"
    exit 0
}

# 2. THE FOREGROUND LOCK, applied WHERE IT COUNTS: the registry write
# deploy-win makes seeds the NEXT logon, and the same call made over ssh
# lands in session 0 (docs/traps.md). Only this one, from inside the
# session, moves the live reading.
# SPI_SETFOREGROUNDLOCKTIMEOUT = 0x2001, SPIF_SENDCHANGE = 2,
# SPI_GETFOREGROUNDLOCKTIMEOUT = 0x2000.
$before = [uint32]0
[void][KayaDesk]::SystemParametersInfoA(0x2000, 0, [ref]$before, 0)
[void][KayaDesk]::SystemParametersInfoW(0x2001, 0, [IntPtr]::Zero, 2)
$after = [uint32]0
[void][KayaDesk]::SystemParametersInfoA(0x2000, 0, [ref]$after, 0)
Say 'fglocktimeout' "$before -> $after"

Describe-Foreground 'before'

# 3. THE PROOF — the guard's own attempt (crates/kaya/src/winui/mod.rs,
# shortcut()): 3s of asking, ESC at 200ms to dismiss a menu, a bare ALT
# at 1s to release a held foreground lock. BOUNDED BY THE CLOCK, not by
# a try count: a form here costs ~120ms a turn, so the guard's 150 tries
# would wait 18s and pass a desktop far too slow for any leg. Winning
# clears the desktop, which is the warm-up half.
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$form = New-Object System.Windows.Forms.Form
$form.Text = 'kaya desk warm-up'
$form.Width = 320
$form.Height = 120
$form.StartPosition = 'Manual'
$form.Location = New-Object System.Drawing.Point(20, 20)
$form.Show()
[System.Windows.Forms.Application]::DoEvents()
$hwnd = $form.Handle
$won = $false
$tries = 0
$escaped = $false
$alted = $false
$clock = [Diagnostics.Stopwatch]::StartNew()
while ($clock.ElapsedMilliseconds -lt 3000) {
    $tries++
    if ([KayaDesk]::GetForegroundWindow() -eq $hwnd) { $won = $true; break }
    [void][KayaDesk]::SetForegroundWindow($hwnd)
    if (-not $escaped -and $clock.ElapsedMilliseconds -ge 200) {
        $escaped = $true
        [KayaDesk]::keybd_event(0x1B, 0, 0, [IntPtr]::Zero)
        [KayaDesk]::keybd_event(0x1B, 0, 2, [IntPtr]::Zero)
    }
    if (-not $alted -and $clock.ElapsedMilliseconds -ge 1000) {
        $alted = $true
        [KayaDesk]::keybd_event(0x12, 0, 0, [IntPtr]::Zero)
        [KayaDesk]::keybd_event(0x12, 0, 2, [IntPtr]::Zero)
    }
    [System.Windows.Forms.Application]::DoEvents()
    Start-Sleep -Milliseconds 20
}
$clock.Stop()
Say 'tries' $tries
Say 'ms' $clock.ElapsedMilliseconds
if (-not $won) {
    Describe-Foreground 'holder'
    Say 'verdict' 'BLOCKED'
    Say 'reason' 'foreground'
}
else {
    Say 'verdict' 'OK'
}
$form.Close()
[System.Windows.Forms.Application]::DoEvents()
"DESKWARMDONE"
