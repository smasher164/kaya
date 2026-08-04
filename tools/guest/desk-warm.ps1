# CAN A WINDOW ON THIS DESKTOP TAKE THE FOREGROUND? Asked once, before
# the suites, because 145 legs bet on the answer and only the desktop
# knows it.
#
# Every chord-injecting leg (menus_*, commands_*) raises the guest
# window and CONFIRMS it before pressing anything
# (crates/kaya/src/winui/mod.rs, shortcut()). When the desktop refuses,
# each of those legs dies 3s later with "could not foreground the guest
# window", ten of them per lane, and the transcript blames WinUI. The
# state that causes it is INVISIBLE FROM SSH: an ssh session has its own
# window station (`query session` marks it `>services`, session 0) and
# can see neither the input desktop nor a window with no title. So this
# runs where the legs run — an interactive scheduled task — and does the
# legs' own handover as the test.
#
# The answer is a PROOF, not a survey: a real window, a real
# SetForegroundWindow, the guard's own poll. If it succeeds here it
# succeeds for the legs; if it fails, the lane stops now instead of at
# leg 8 with ten panics.
#
# Measured 2026-08-04 on the VM, one leg run per row:
#
#   desktop state                          bare SetForegroundWindow   menus_rust
#   idle (Progman / taskbar in front)      won on attempt 0           PASS
#   Start menu open (SearchHost)           LOST after 150 tries       PASS
#   another process holds the fg lock      LOST after 150 tries       PASS
#   input desktop is not the legs'         LOST after 150 tries       FAIL
#
# The two middle rows are why this script taps ESC and ALT the way the
# guard does rather than testing bare: the guard beats both of those on
# its own (ESC dismisses the menu, ALT releases the lock), so a bare
# test would fail the lane on states the legs handle. The last row is
# the one that kills legs, and no key can reach it — injected input
# goes to the INPUT desktop, so ESC and ALT are delivered somewhere
# else entirely. It is checked first and reported by name.
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

# WHO HAS IT — printed on the way in and on the way out, because the
# holder's name is the whole diagnosis when this fails. A toast has no
# title, so the class and the owning process are what identify it.
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

# 1. THE DESKTOP THE INPUT GOES TO must be the desktop this task's
# windows live on. It is not, when the console session is LOCKED (input
# on WinSta0\Winlogon) or a UAC consent prompt is up (the secure
# desktop) — and then nothing a guest can do reaches the screen. This
# is the only state measured to fail a real leg, and the only one
# nothing on this machine can clear.
$mine = [KayaDesk]::ObjName([KayaDesk]::GetThreadDesktop([KayaDesk]::GetCurrentThreadId()))
Say 'desktop' $mine
# DESKTOP_READOBJECTS|DESKTOP_SWITCHDESKTOP — enough to name it. Access
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

# 2. THE FOREGROUND LOCK, applied WHERE IT COUNTS. Windows refuses
# SetForegroundWindow to a process that did not receive the last input
# until ForegroundLockTimeout has passed. deploy-win writes 0 to
# HKCU\Control Panel\Desktop, which seeds the NEXT logon. Applying it to
# the LIVE session used to be a SystemParametersInfo call made over ssh,
# and could not work: measured 2026-08-04, that call runs in session 0
# against its own window station, and the console session still read
# 2147483647 after every deploy that day. It is this call, from inside
# the session, that lands — the same reading is 0 afterwards.
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
# shortcut()): keep asking for 3s, ESC at 200ms to dismiss a menu, a
# bare ALT at 1s to release a held foreground lock. Same shape on
# purpose: this must answer the question the legs will ask, not an
# easier one. BOUNDED BY THE CLOCK rather than by a try count, because
# the guard's 150 tries are 3s and PowerShell's are not: a form here
# costs ~120ms a turn, so counting to 150 would wait 18s and pass a
# desktop that hands over too slowly for any leg.
#
# The clearing is the warm-up — a Start menu left open on the VM is
# dismissed here, once, instead of by each of ten legs at their own
# 200ms cost.
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
