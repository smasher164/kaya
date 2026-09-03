# THE CAPTION TITLE CENTRES ON THE WINDOW: the acceptance measurement
# (docs/chrome/winui-clip.md §4). One AIM line per geometry — the title's
# centre-x minus the window's centre-x, with the menu's right edge and the
# commands' left edge beside it, since a CLAMPED title and a DRIFTING one
# differ only in whether a header explains the offset. The window is
# DwmGetWindowAttribute(DWMWA_EXTENDED_FRAME_BOUNDS), the VISIBLE frame:
# GetWindowRect on Win11 adds a ~7px invisible border per side. Runs only in
# the VM's INTERACTIVE session, scheduled by title-centre-probe.sh.
#
# THE LANE READS THREE LINE SHAPES FROM THIS FILE AND ASSERTS ON THEM:
#   AIMPLAN <n>    how many geometries this run will attempt, printed
#                  BEFORE any of them — a sweep that stopped early reports
#                  no drift, which reads like a sweep that found none.
#   AIMFLOOR w=<n> the narrowest width driven: the one tag at which a
#                  vanished title is correct rather than a defect.
#   AIMV <tag> drift=<d> clamped=<bool> absent=<bool>
#                  one per geometry.
$ErrorActionPreference = "Stop"
$log = $env:KAYA_TC_LOG
if (-not $log) { $log = "C:\Users\akhil\kaya-tc\prove-centre.txt" }
function Say($m) { Add-Content -Path $log -Value $m }

Add-Type @"
using System;
using System.Runtime.InteropServices;
public struct RECT { public int Left, Top, Right, Bottom; }
public class U {
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr lp);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr h, System.Text.StringBuilder sb, int max);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint f, uint dx, uint dy, uint d, IntPtr e);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h, System.Text.StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr h, int a, out RECT r, int s);
  public const uint LEFTDOWN = 0x0002, LEFTUP = 0x0004;
  public const int EXTENDED_FRAME_BOUNDS = 9;
  public const uint SWP_NOMOVE = 0x0002, SWP_NOZORDER = 0x0004, SWP_NOACTIVATE = 0x0010;
}
"@

function Frame($h) {
  $r = New-Object RECT
  $rc = [U]::DwmGetWindowAttribute($h, [U]::EXTENDED_FRAME_BOUNDS, [ref]$r, 16)
  if ($rc -ne 0) { [U]::GetWindowRect($h, [ref]$r) | Out-Null }
  return $r
}
function KayaWindows() {
  $found = New-Object System.Collections.ArrayList
  $cb = [U+EnumProc]{
    param($hh, $ll)
    if ([U]::IsWindowVisible($hh)) {
      $c = New-Object System.Text.StringBuilder 256
      [U]::GetClassName($hh, $c, 256) | Out-Null
      if ($c.ToString() -eq "WinUIDesktopWin32WindowClass") { [void]$found.Add($hh) }
    }
    return $true
  }
  [U]::EnumWindows($cb, [IntPtr]::Zero) | Out-Null
  return $found
}
function AllVisibleClasses() {
  $seen = New-Object System.Collections.ArrayList
  $cb = [U+EnumProc]{
    param($hh, $ll)
    if ([U]::IsWindowVisible($hh)) {
      $c = New-Object System.Text.StringBuilder 256
      [U]::GetClassName($hh, $c, 256) | Out-Null
      $t = New-Object System.Text.StringBuilder 256
      [U]::GetWindowTextW($hh, $t, 256) | Out-Null
      if ($t.ToString().Length -gt 0) { [void]$seen.Add(($c.ToString() + " | " + $t.ToString())) }
    }
    return $true
  }
  [U]::EnumWindows($cb, [IntPtr]::Zero) | Out-Null
  return $seen
}

$h = [IntPtr]::Zero
for ($i = 0; $i -lt 80; $i++) {
  $w = KayaWindows
  if ($w.Count -gt 0) { $h = $w[0]; break }
  Start-Sleep -Milliseconds 250
}
if ($h -eq [IntPtr]::Zero) {
  # A DIAGNOSTIC MAY ONLY PRINT WHAT IT MEASURED: say what WAS on the
  # desktop rather than guessing why the guest is missing.
  Say "PROVE: no window of class WinUIDesktopWin32WindowClass. Visible titled windows seen:"
  foreach ($l in AllVisibleClasses) { Say ("PROVE:   " + $l) }
  exit 1
}
function Caption() {
  $sb = New-Object System.Text.StringBuilder 512
  [U]::GetWindowTextW($h, $sb, 512) | Out-Null
  return $sb.ToString()
}
Say ("PROVE: hwnd=0x{0:x} caption=`"{1}`"" -f [int64]$h, (Caption))
$wr0 = New-Object RECT; [U]::GetWindowRect($h, [ref]$wr0) | Out-Null
$cr0 = New-Object RECT; [U]::GetClientRect($h, [ref]$cr0) | Out-Null
$fr0 = Frame $h
Say ("PROVE: window-rect {0}..{1} w={2} | visible-frame {3}..{4} w={5} | client w={6} h={7}" -f `
     $wr0.Left, $wr0.Right, ($wr0.Right - $wr0.Left), $fr0.Left, $fr0.Right, ($fr0.Right - $fr0.Left),
     ($cr0.Right - $cr0.Left), ($cr0.Bottom - $cr0.Top))
[U]::SetForegroundWindow($h) | Out-Null
Start-Sleep -Milliseconds 800

Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
function ByName($name) {
  # Re-rooted on every call: a resize invalidates cached elements.
  $root = [System.Windows.Automation.AutomationElement]::FromHandle($h)
  $c = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::NameProperty, $name)
  return $root.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $c)
}
function RectOf($name) {
  $e = ByName $name
  if ($e -eq $null) { return $null }
  $r = $e.Current.BoundingRectangle
  # UIA answers Rect.Empty - infinities - for an element the layout has
  # pushed off the screen. That is a real state at narrow widths and it is
  # SAID rather than cast to an integer and thrown on.
  if ([double]::IsInfinity($r.X) -or [double]::IsNaN($r.X) -or $r.Width -le 0) { return $null }
  return $r
}

$menuNames = @("File", "Edit", "View", "Format")
$cmdNames = @("Save", "Find", "More options")
function Aim($tag) {
  $fr = Frame $h
  $cap = Caption
  $winC = ($fr.Left + $fr.Right) / 2.0
  $t = RectOf $cap
  if ($t -eq $null) {
    Say ("AIM  {0,-10} window {1}..{2} centre {3}   *** UIA PUBLISHED NO ELEMENT NAMED `"{4}`" ***" -f `
         $tag, $fr.Left, $fr.Right, [int]$winC, $cap)
    # THE ROW IS STILL EMITTED, saying ABSENT rather than going missing: a
    # vanished row would break the plan's count rule for a state that is
    # correct at the sweep's floor, and would let a title that vanished at
    # a WIDE width hide in the same silence. An absent row is allowed at
    # the narrowest width and nowhere else.
    Say ("AIMV {0} drift=absent clamped=true absent=true" -f $tag)
    return
  }
  $tC = $t.X + $t.Width / 2.0
  $menuR = $null
  foreach ($n in $menuNames) { $r = RectOf $n; if ($r -ne $null) { $e = $r.X + $r.Width; if ($menuR -eq $null -or $e -gt $menuR) { $menuR = $e } } }
  $cmdL = $null
  foreach ($n in $cmdNames) { $r = RectOf $n; if ($r -ne $null) { if ($cmdL -eq $null -or $r.X -lt $cmdL) { $cmdL = $r.X } } }
  Say ("AIM  {0,-10} window {1}..{2} w={3} centre={4} | title x={5} w={6} h={7} centre={8} | DRIFT={9} | menu-right={10} commands-left={11} | gap-left={12} gap-right={13}" -f `
       $tag, $fr.Left, $fr.Right, ($fr.Right - $fr.Left), [int]$winC,
       [int]$t.X, [int]$t.Width, [int]$t.Height, [int]$tC, [Math]::Round($tC - $winC, 1),
       $(if ($menuR -eq $null) { "none" } else { [string][int]$menuR }),
       $(if ($cmdL -eq $null) { "none" } else { [string][int]$cmdL }),
       $(if ($menuR -eq $null) { "n/a" } else { [string][int]($t.X - $menuR) }),
       $(if ($cmdL -eq $null) { "n/a" } else { [string][int]($cmdL - ($t.X + $t.Width)) }))
  if ($menuR -ne $null -and $t.X -lt $menuR) { Say ("AIM  {0,-10} *** THE TITLE OVERLAPS THE MENU: title starts at {1}, the menu ends at {2} ***" -f $tag, [int]$t.X, [int]$menuR) }
  if ($cmdL -ne $null -and ($t.X + $t.Width) -gt $cmdL) { Say ("AIM  {0,-10} *** THE TITLE OVERLAPS THE COMMANDS: title ends at {1}, the commands start at {2} ***" -f $tag, [int]($t.X + $t.Width), [int]$cmdL) }
  # THE MACHINE-READABLE TWIN of the row above (tools/deploy-win.py's
  # caption-centre phase reads it): CLAMPED is the distinction `grep
  # DRIFT=0` cannot make — the window's own centre would put the title
  # across a header, so the offset is the rule WORKING. 4 DIP of slack,
  # because these edges are read to the first BUTTON while the backend
  # clamps to the CommandBar, which insets it by ~3.
  $wanted = $winC - $t.Width / 2.0
  $clamped = $false
  if ($menuR -ne $null -and $wanted -lt ($menuR + 4)) { $clamped = $true }
  if ($cmdL -ne $null -and ($wanted + $t.Width) -gt ($cmdL - 4)) { $clamped = $true }
  Say ("AIMV {0} drift={1} clamped={2} absent=false" -f $tag, [Math]::Round($tC - $winC, 1), $clamped.ToString().ToLower())
}

# THE PLAN, PRINTED BEFORE ANY OF IT RUNS, and kept beside the list it
# counts. The lane phase requires exactly this many AIMV rows back.
$sweep = @(1100, 900, 800, 700, 640, 600, 560, 520, 480)
Say ("AIMPLAN {0}" -f ($sweep.Count + 2))
# The narrowest width this run drives: the ONE tag at which a row may
# report the title absent, the clamp taken to its limit.
Say ("AIMFLOOR w={0}" -f ($sweep | Measure-Object -Minimum).Minimum)

Aim "launch"

# A LIVE RESIZE, a real border drag: a continuous WM_SIZING stream, not one
# SetWindowPos. The grab point is in the INVISIBLE resize border, OUTSIDE
# the visible frame — measured, after a grab at the visible edge moved
# nothing at all.
$b = Frame $h
$gx = $wr0.Right - 3
$gy = [int](($b.Top + $b.Bottom) / 2)
Say ("PROVE: border-drag grab {0},{1} (window rect right {2}, visible frame right {3})" -f $gx, $gy, $wr0.Right, $b.Right)
[U]::SetCursorPos($gx, $gy) | Out-Null
Start-Sleep -Milliseconds 300
[U]::mouse_event([U]::LEFTDOWN, 0, 0, 0, [IntPtr]::Zero)
Start-Sleep -Milliseconds 200
for ($i = 1; $i -le 20; $i++) {
  [U]::SetCursorPos(($gx - $i * 12), $gy) | Out-Null
  Start-Sleep -Milliseconds 40
}
Start-Sleep -Milliseconds 200
[U]::mouse_event([U]::LEFTUP, 0, 0, 0, [IntPtr]::Zero)
Start-Sleep -Milliseconds 900
$a = Frame $h
Say ("PROVE: border-drag {0} wide -> {1} wide (dragged {2})" -f `
     ($b.Right - $b.Left), ($a.Right - $a.Left), (($a.Right - $a.Left) - ($b.Right - $b.Left)))
Aim "after-drag"

# THE CLAMP, driven deliberately: a width sweep, each step a real resize,
# the whole run printed so the width at which the true centre stops being
# reachable is READ rather than asserted.
foreach ($w in $sweep) {
  $f = Frame $h
  $wr = New-Object RECT
  [U]::GetWindowRect($h, [ref]$wr) | Out-Null
  # SetWindowPos takes the WINDOW rect, which is the visible frame plus the
  # invisible border; the difference is measured, not assumed.
  $slack = ($wr.Right - $wr.Left) - ($f.Right - $f.Left)
  [U]::SetWindowPos($h, [IntPtr]::Zero, 0, 0, ($w + $slack), ($wr.Bottom - $wr.Top),
                    ([U]::SWP_NOMOVE -bor [U]::SWP_NOZORDER -bor [U]::SWP_NOACTIVATE)) | Out-Null
  Start-Sleep -Milliseconds 700
  Aim ("w=" + $w)
}
Say "PROVE: done"
