# THE CAPTION TITLE CENTRES ON THE WINDOW: the acceptance measurement.
#
# Prints one AIM line per geometry: the title's centre-x minus the window's
# centre-x, with the menu's right edge and the commands' left edge beside it,
# because a title that is CLAMPED (correct, on a narrow window) and one that
# is DRIFTING (the defect this exists for) differ only in whether a header
# explains the offset.
#
# WHAT IT MEASURES, AND WHAT IT REFUSES TO INFER
#   - the window: DwmGetWindowAttribute(DWMWA_EXTENDED_FRAME_BOUNDS), the
#     VISIBLE frame. GetWindowRect on Win11 includes a ~7px invisible resize
#     border per side, so its centre is the centre of something nobody sees.
#     Both are printed once, with the client width, so the reader can see
#     they are concentric rather than take it on trust.
#   - the title, the menu items and the commands: UIA bounding rectangles.
#     An element UIA does not publish is SAID, never skipped: at widths
#     where the band has no room left the title genuinely stops existing,
#     and "no element named X" is the honest report of that.
#
# HOW IT RUNS. It must run in the VM's INTERACTIVE session — an ssh session
# has its own window station and can neither see the window nor synthesize
# input into it — so `title-centre-probe.sh` beside this file schedules it
# with `schtasks /it` against a guest running the toolbar scene with a
# trailing settle. From the repo root, inside the dev shell:
#
#     crates/kaya/src/winui/title-centre-probe.sh akhil@192.168.64.2
#
# THE LANE CARRIES IT: `tools/deploy-win.sh`'s caption-centre phase runs
# this on every full windows lane, and `tools/deploy-win.sh <host>
# caption-centre` runs it alone. The wall that runs on every lane LEG is the
# post-condition inside `center_caption_title`; this script is the
# measurement that says by how much, in physical pixels, off UIA — at widths
# no scene drives.
#
# THE LANE READS TWO KINDS OF LINE FROM THIS FILE and asserts on them, so
# they are a contract, not decoration:
#   AIMPLAN <n>          how many geometries this run will attempt, printed
#                        BEFORE any of them: a sweep that stopped early
#                        reports no drift, which is the same output as a
#                        sweep that found none.
#   AIMFLOOR w=<n>       the narrowest width driven — the one tag at which a
#                        vanished title is correct rather than a defect.
#   AIMV <tag> drift=<d> clamped=<bool> absent=<bool>
#                        one per geometry. CLAMPED carries the one
#                        distinction a reader has to make and `grep DRIFT=0`
#                        cannot: on a narrow window the offset is the rule
#                        working.
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
    # THE ROW IS STILL EMITTED, and it says ABSENT rather than going
    # missing. A row that simply vanished would make the plan's count
    # rule fail for a state that is CORRECT at the sweep's floor — below
    # 480 the span between the headers closes entirely and the title
    # collapses to nothing rather than crossing a header — and, worse,
    # would let a title that vanished at a WIDE width hide inside the
    # same silence. The lane's rule is that an absent row is allowed at
    # the sweep's narrowest width and nowhere else.
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
  # THE MACHINE-READABLE TWIN of the row above, for the lane phase that
  # reads this output (tools/deploy-win.sh's caption-centre phase). It
  # carries the one distinction a reader has to make and a `grep DRIFT=0`
  # cannot: a row is CLAMPED when the window's own centre would put the
  # title across a header, and a clamped row's drift is the rule WORKING.
  # Computed from the same measured edges as the row above, with 4 DIP of
  # slack because these edges are read to the first BUTTON while the
  # backend clamps to the CommandBar, which insets it by ~3.
  $wanted = $winC - $t.Width / 2.0
  $clamped = $false
  if ($menuR -ne $null -and $wanted -lt ($menuR + 4)) { $clamped = $true }
  if ($cmdL -ne $null -and ($wanted + $t.Width) -gt ($cmdL - 4)) { $clamped = $true }
  Say ("AIMV {0} drift={1} clamped={2} absent=false" -f $tag, [Math]::Round($tC - $winC, 1), $clamped.ToString().ToLower())
}

# THE PLAN, PRINTED BEFORE ANY OF IT RUNS. The lane phase requires exactly
# this many AIMV rows back: a probe that measured nothing — a window that
# never appeared, a sweep that threw halfway — otherwise reports no drift
# at all, which reads identically to reporting no drift because there is
# none. Kept beside the two lists it counts so it cannot drift from them.
$sweep = @(1100, 900, 800, 700, 640, 600, 560, 520, 480)
Say ("AIMPLAN {0}" -f ($sweep.Count + 2))
# The narrowest width this run drives. It is the ONE tag at which a row
# may report the title absent: at that width the toolbar scene's menu,
# commands, drag strip and caption cluster fill the band, and collapsing
# the title is the clamp taken to its limit rather than a defect.
Say ("AIMFLOOR w={0}" -f ($sweep | Measure-Object -Minimum).Minimum)

Aim "launch"

# A LIVE RESIZE, driven by a real drag of the window's right border: a
# continuous WM_SIZING stream, not one SetWindowPos. The grab point is in
# the INVISIBLE resize border, which is OUTSIDE the visible frame - measured,
# after a grab at the visible edge moved nothing at all.
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

# THE CLAMP, driven deliberately: a width sweep, each step a real resize.
# The whole run is printed so the width at which the true centre stops being
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
