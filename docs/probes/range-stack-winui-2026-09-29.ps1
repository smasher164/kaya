# The WinUI stacked-pair probe (docs/range-plan.md §4, the WinUI MEASURED
# paragraph): run in the VM's INTERACTIVE session against a live range guest
# (guests/rust/range.rs held open by a scratch `settle`), driven by
# docs/probes/range-stack-winui-2026-09-29.py. Every press is a real
# mouse_event on the system input queue, every value is read back through
# UI Automation from outside the process, as Narrator reads it.
param([string]$Log, [string]$Shots, [switch]$Rtl)

Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes, System.Drawing
Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class P {
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern void mouse_event(uint f, uint dx, uint dy, uint d, IntPtr e);
    [DllImport("user32.dll")] public static extern void keybd_event(byte k, byte s, uint f, IntPtr e);
    [DllImport("user32.dll")] public static extern uint GetDpiForWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern int GetSystemMetrics(int i);
}
"@

function Say($s) { Add-Content -Path $Log -Value $s -Encoding utf8 }
$A = [System.Windows.Automation.AutomationElement]
$T = [System.Windows.Automation.TreeScope]

$proc = $null
for ($i = 0; $i -lt 60 -and -not $proc; $i++) {
    $proc = Get-Process range -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
    if (-not $proc) { Start-Sleep -Milliseconds 500 }
}
if (-not $proc) { Say "PROVE: no range window"; Say "PROVE: done"; exit 1 }
Start-Sleep -Seconds 3
$hwnd = $proc.MainWindowHandle
[P]::SetForegroundWindow($hwnd) | Out-Null
$scale = [P]::GetDpiForWindow($hwnd) / 96.0
Say "M: dpi scale $scale rtl=$Rtl"
$win = $A::FromHandle($hwnd)

function Named($name) {
    $c = New-Object System.Windows.Automation.PropertyCondition($A::NameProperty, $name)
    $win.FindFirst($T::Descendants, $c)
}
function Val($e) { $e.GetCurrentPattern([System.Windows.Automation.RangeValuePattern]::Pattern).Current.Value }
function SetVal($e, $v) { $e.GetCurrentPattern([System.Windows.Automation.RangeValuePattern]::Pattern).SetValue($v) }
function Labels {
    $c = New-Object System.Windows.Automation.PropertyCondition($A::ControlTypeProperty, [System.Windows.Automation.ControlType]::Text)
    ($win.FindAll($T::Descendants, $c) | ForEach-Object { $_.Current.Name }) -join " | "
}
function Pair { "In=$(Val $low) Out=$(Val $high) labels=[$(Labels)]" }

$low = Named "In"; $high = Named "Out"; $vol = Named "Volume"
if (-not $low -or -not $high) { Say "PROVE: sliders In/Out not in the UIA tree"; Say "PROVE: done"; exit 1 }

# THE SHAPE A READER SEES: each thumb's control type and name, and its
# parent in the control view (the group rule 7 asks for).
$walker = [System.Windows.Automation.TreeWalker]::ControlViewWalker
foreach ($e in @($low, $high, $vol)) {
    $p = $walker.GetParent($e)
    Say ("M: uia {0} '{1}' rect={2} parent={3} '{4}'" -f $e.Current.ControlType.ProgrammaticName, $e.Current.Name, $e.Current.BoundingRectangle, $p.Current.ControlType.ProgrammaticName, $p.Current.Name)
}
$vo = $vol.GetCurrentPropertyValue($A::OrientationProperty)
Say "M: uia Volume orientation=$vo value=$(Val $vol)"

# The GROUP's box is the track's: each thumb's own box is its CLIPPED half
# (UIA reports the bounds after the clip), measured on the first run.
$r = $walker.GetParent($low).Current.BoundingRectangle
Say "M: group rect $r"
# The template's own boxes (generic.xaml): an 18 DIP thumb whose centre runs
# from 9 DIP in at one end of the track to 9 DIP in at the other.
function Xof($v) {
    $f = $v / 10.0
    if ($Rtl) { $f = 1.0 - $f }
    [int]($r.Left + $scale * 9 + $f * ($r.Width - $scale * 18))
}
$y = [int]($r.Top + $r.Height / 2)
function Down($x, $yy) { [P]::SetCursorPos($x, $yy) | Out-Null; Start-Sleep -Milliseconds 120; [P]::mouse_event(2, 0, 0, 0, [IntPtr]::Zero); Start-Sleep -Milliseconds 120 }
function Up { [P]::mouse_event(4, 0, 0, 0, [IntPtr]::Zero); Start-Sleep -Milliseconds 400 }
function Click($x, $yy) { Down $x $yy; Up }
# A drag's movements as ABSOLUTE mouse input (MOVE|ABSOLUTE, 0..65535): a
# SetCursorPos alone moves the cursor and raises no pointer update, which the
# first run measured as a thumb that never left its place.
$sw = [P]::GetSystemMetrics(0); $sh = [P]::GetSystemMetrics(1)
function MoveTo($x, $yy) {
    [P]::mouse_event(0x8001, [uint32]([int]($x * 65535 / ($sw - 1))), [uint32]([int]($yy * 65535 / ($sh - 1))), 0, [IntPtr]::Zero)
}
function Drag($x, $to) {
    Down $x $y
    $step = [Math]::Sign($to - $x) * 4
    for ($p = $x; [Math]::Abs($to - $p) -gt 4; $p += $step) { MoveTo $p $y; Start-Sleep -Milliseconds 15 }
    MoveTo $to $y; Start-Sleep -Milliseconds 60
    Up
}
function Shot($name) {
    $wr = $win.Current.BoundingRectangle
    $b = New-Object System.Drawing.Bitmap -ArgumentList @([int]$wr.Width, [int]$wr.Height)
    $g = [System.Drawing.Graphics]::FromImage($b)
    $g.CopyFromScreen([int]$wr.Left, [int]$wr.Top, 0, 0, $b.Size)
    $b.Save("$Shots\$name.png"); $g.Dispose(); $b.Dispose()
}
function Reset($lo, $hi) { SetVal $high 10; SetVal $low $lo; SetVal $high $hi; Start-Sleep -Milliseconds 400 }

Say "M: start $(Pair)"
Shot "start"
# A click on the track in the LOW half (value 3.5; the midpoint is 5).
Click (Xof 3.5) $y
Say "M: click at value 3.5 -> $(Pair)"
Reset 2 8
# A click on the track in the HIGH half (value 6.5).
Click (Xof 6.5) $y
Say "M: click at value 6.5 -> $(Pair)"
Reset 2 8
# A press on the low thumb, dragged to the far end: the thumb stops.
Drag (Xof 2) (Xof 10)
Say "M: low dragged to 10 -> $(Pair)"
Reset 2 8
# The assistive path: RangeValue.SetValue past the other thumb.
SetVal $low 9.5
Start-Sleep -Milliseconds 400
Say "M: uia set In 9.5 -> $(Pair)"
SetVal $high 1
Start-Sleep -Milliseconds 400
Say "M: uia set Out 1 -> $(Pair)"
Reset 2 8

# A TIE (the arm's probe switch forces the gap to 0): both at 5, a press 3px
# either side of the shared centre and a drag away from it.
SetVal $low 5; SetVal $high 5; Start-Sleep -Milliseconds 400
Say "M: tie set -> $(Pair)"
Shot "tie"
$c = Xof 5
$away = [int](24 * $scale)
Drag ($c - 3) ($c - $away)
Say "M: tie, press 3px left of centre, drag left -> $(Pair)"
SetVal $low 5; SetVal $high 5; Start-Sleep -Milliseconds 400
Drag ($c + 3) ($c + $away)
Say "M: tie, press 3px right of centre, drag right -> $(Pair)"
SetVal $high 5; SetVal $low 5; Start-Sleep -Milliseconds 400
Drag ($c - 3) ($c + $away)
Say "M: tie, press 3px left of centre, drag RIGHT -> $(Pair)"
SetVal $high 5; SetVal $low 5; Start-Sleep -Milliseconds 400
Drag ($c + 3) ($c - $away)
Say "M: tie, press 3px right of centre, drag LEFT -> $(Pair)"
Reset 2 8

# THE VERTICAL FADER: presses near each end, then Up with its focus.
if ($vol) {
    $vr = $vol.Current.BoundingRectangle
    $vx = [int]($vr.Left + $vr.Width / 2)
    Click $vx ([int]($vr.Bottom - 12 * $scale))
    Say "M: fader press near its bottom -> $(Val $vol) rect=$vr"
    Click $vx ([int]($vr.Top + 12 * $scale))
    Say "M: fader press near its top -> $(Val $vol)"
    SetVal $vol 0.25; Start-Sleep -Milliseconds 300
    $vol.SetFocus(); Start-Sleep -Milliseconds 300
    [P]::keybd_event(0x26, 0, 0, [IntPtr]::Zero); [P]::keybd_event(0x26, 0, 2, [IntPtr]::Zero)
    Start-Sleep -Milliseconds 500
    Say "M: fader 0.25 + Up -> $(Val $vol)"
    [P]::keybd_event(0x27, 0, 0, [IntPtr]::Zero); [P]::keybd_event(0x27, 0, 2, [IntPtr]::Zero)
    Start-Sleep -Milliseconds 500
    Say "M: fader + Right -> $(Val $vol)"
}
# The range's keys: Right on the focused low thumb (mirrored in RTL).
$low.SetFocus(); Start-Sleep -Milliseconds 300
[P]::keybd_event(0x27, 0, 0, [IntPtr]::Zero); [P]::keybd_event(0x27, 0, 2, [IntPtr]::Zero)
Start-Sleep -Milliseconds 500
Say "M: In focused + Right -> $(Pair)"
Shot "focused"
Say "PROVE: done"
