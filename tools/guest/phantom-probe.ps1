# WATCH THE FOREGROUND FROM THE CONSOLE SESSION and, whenever the shell's
# notification host window holds it, take every reading there is
# (docs/deferred.md, the phantom notification window). It is the only way
# anyone has WATCHED that window: it comes up in a notification leg's wake,
# holds the foreground with nothing in it, and no leg but the one it lands
# on can see it.
#
# Readings, on every change of the foreground: the window's own six
# (IsWindowVisible, IsIconic, GetWindowRect, DWMWA_CLOAKED,
# GetLayeredWindowAttributes, both GetWindowLongPtr words), the notification
# database's newest row by a byte scan -- ArrivalTime is a FILETIME and
# sqlite stores an 8-byte integer big-endian, so a row inside the horizon is
# an 8-byte big-endian value inside it, CLEARED ROWS INCLUDED (measured;
# that is why the wait does not decide on this reading) -- and the window's
# UIA text, which is what tells an empty host window from a real banner.
#
# The levers, each of which was tried against the window and is recorded in
# the notes: -KillHost, -RestartShell, -Toast (any -Aumid, -Count,
# -Scenario), -ClearAfter, -OwnWindow, -Shot.
#
# Run through schtasks /it like notify-ready.ps1 -- an ssh session is
# session 0 and GetForegroundWindow there answers about a desktop no leg
# lives on.
#
# ASCII ONLY (a guest .ps1 is read in the machine's ANSI code page;
# tools/check-steps.py refuses a non-ASCII byte outside a comment).
param([switch]$KillHost, [switch]$RestartShell, [int]$Seconds = 20, [switch]$Toast,
      [string]$Aumid = '', [int]$Count = 1, [string]$Scenario = '',
      [switch]$ClearAfter, [switch]$OwnWindow,
      [int]$RestartSettleMs = 3000, [switch]$Shot)
$ErrorActionPreference = 'Continue'

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class KayaFg {
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern int GetClassName(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern int IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern int IsIconic(IntPtr h);
    [DllImport("user32.dll")] public static extern int GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern int GetLayeredWindowAttributes(IntPtr h, out uint key, out byte alpha, out uint flags);
    [DllImport("user32.dll")] public static extern IntPtr GetWindowLongPtr(IntPtr h, int i);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr h, uint a, out uint v, int n);
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int left, top, right, bottom; }
    public static string Reading(IntPtr h) {
        RECT r; uint key; byte alpha; uint flags; uint cloaked = 0;
        int gotRect = GetWindowRect(h, out r);
        int hr = DwmGetWindowAttribute(h, 14, out cloaked, 4);
        int lay = GetLayeredWindowAttributes(h, out key, out alpha, out flags);
        return "visible=" + IsWindowVisible(h) + " iconic=" + IsIconic(h)
            + " rect=" + (gotRect == 0 ? "unreadable"
                : (r.left + "," + r.top + " " + (r.right - r.left) + "x" + (r.bottom - r.top)))
            + " cloaked=" + (hr == 0 ? cloaked.ToString() : ("unreadable(0x" + hr.ToString("x8") + ")"))
            + " layered=" + (lay == 0 ? "no" : ("alpha=" + alpha + " flags=0x" + flags.ToString("x")))
            + " style=0x" + GetWindowLongPtr(h, -16).ToInt64().ToString("x")
            + " exstyle=0x" + GetWindowLongPtr(h, -20).ToInt64().ToString("x");
    }
    // The newest notification's age, read BY BYTES exactly as the guest's
    // wait reads it: ArrivalTime is a FILETIME and sqlite stores an 8-byte
    // integer big-endian, so a row inside the horizon is an 8-byte
    // big-endian value inside it.
    public static long NewestAgeMs(string dir, long horizonMs) {
        long now = DateTime.UtcNow.ToFileTimeUtc();
        long hi = now + 10000L * 10000L;
        long lo = now - horizonMs * 10000L;
        long newest = -1;
        foreach (string name in new string[] { "wpndatabase.db", "wpndatabase.db-wal" }) {
            string path = System.IO.Path.Combine(dir, name);
            byte[] b;
            try {
                using (var fs = new System.IO.FileStream(path, System.IO.FileMode.Open,
                        System.IO.FileAccess.Read, System.IO.FileShare.ReadWrite)) {
                    b = new byte[fs.Length];
                    int off = 0;
                    while (off < b.Length) { int n = fs.Read(b, off, b.Length - off); if (n <= 0) break; off += n; }
                }
            } catch (Exception) { continue; }
            for (int i = 0; i + 8 <= b.Length; i++) {
                long v = ((long)b[i] << 56) | ((long)b[i+1] << 48) | ((long)b[i+2] << 40)
                       | ((long)b[i+3] << 32) | ((long)b[i+4] << 24) | ((long)b[i+5] << 16)
                       | ((long)b[i+6] << 8) | (long)b[i+7];
                if (v >= lo && v <= hi && v > newest) newest = v;
            }
        }
        return newest < 0 ? -1 : (now - newest) / 10000L;
    }
}
'@

function ToastText($h) {
    try {
        Add-Type -AssemblyName UIAutomationClient -ErrorAction Stop
        Add-Type -AssemblyName UIAutomationTypes -ErrorAction Stop
        $root = [System.Windows.Automation.AutomationElement]::FromHandle($h)
        if ($null -eq $root) { return 'uia: FromHandle answered nothing for this window' }
        $all = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants,
            [System.Windows.Automation.Condition]::TrueCondition)
        $names = New-Object System.Collections.ArrayList
        foreach ($el in $all) {
            $n = $el.Current.Name
            if ($n -and $n.Length -gt 0 -and -not $names.Contains($n)) { [void]$names.Add($n) }
        }
        if ($names.Count -eq 0) {
            return "uia: $($all.Count) element(s) walked, none named; root name '$($root.Current.Name)' class '$($root.Current.ClassName)'"
        }
        $joined = ($names -join ' | ')
        if ($joined.Length -gt 300) { $joined = $joined.Substring(0, 300) + '...' }
        return $joined
    } catch {
        return "uia failed: $($_.Exception.Message)"
    }
}

function Say($m) { Write-Output "phantom-probe.$m" }

$dir = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Notifications'
Say "dir=$dir"

if ($KillHost) {
    $before = @(Get-Process ShellExperienceHost -ErrorAction SilentlyContinue).Count
    taskkill /f /im ShellExperienceHost.exe 2>&1 | Out-Null
    Start-Sleep -Milliseconds 400
    $after = @(Get-Process ShellExperienceHost -ErrorAction SilentlyContinue).Count
    Say "killhost.before=$before killhost.after=$after"
}

if ($RestartShell) {
    $was = @(Get-Process explorer -ErrorAction SilentlyContinue).Count
    taskkill /f /im explorer.exe 2>&1 | Out-Null
    $back = 0
    for ($i = 0; $i -lt 60; $i++) {
        Start-Sleep -Milliseconds 100
        $back = @(Get-Process explorer -ErrorAction SilentlyContinue).Count
        if ($back -gt 0) { break }
    }
    if ($back -eq 0) { Start-Process explorer.exe; Start-Sleep -Seconds 3
                       $back = @(Get-Process explorer -ErrorAction SilentlyContinue).Count }
    Start-Sleep -Milliseconds $RestartSettleMs
    if ($form) { [Windows.Forms.Application]::DoEvents() }
    $seh = @(Get-Process ShellExperienceHost -ErrorAction SilentlyContinue).Count
    Say "restartshell.was=$was back=$back shellexperiencehost=$seh"
}

$form = $null
if ($OwnWindow) {
    Add-Type -AssemblyName System.Windows.Forms
    $form = New-Object Windows.Forms.Form
    $form.Text = 'kaya phantom probe window'
    $form.Width = 700
    $form.Height = 400
    $form.TopMost = $false
    $form.Show()
    $form.Activate()
    [Windows.Forms.Application]::DoEvents()
    Start-Sleep -Milliseconds 600
    [Windows.Forms.Application]::DoEvents()
    Say "ownwindow.handle=0x$($form.Handle.ToInt64().ToString('x'))"
}

if ($Toast) {
    [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
    [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom, ContentType = WindowsRuntime] | Out-Null
    if (-not $Aumid) { $Aumid = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe' }
    $notifier = [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($Aumid)
    Say "toast.aumid=[$Aumid]"
    Say "toast.setting=$($notifier.Setting)"
    for ($i = 1; $i -le $Count; $i++) {
        $xml = New-Object Windows.Data.Xml.Dom.XmlDocument
        $xml.LoadXml('<toast' + $(if ($Scenario) { ' scenario="' + $Scenario + '"' } else { '' }) + '><visual><binding template="ToastGeneric"><text>kaya phantom probe</text><text>probe #' + $i + '</text></binding></visual>' + $(if ($Scenario) { '<actions><action activationType="system" arguments="dismiss" content="Dismiss" /></actions>' } else { '' }) + '</toast>')
        $note = New-Object Windows.UI.Notifications.ToastNotification $xml
        $note.Tag = "kaya-phantom-probe-$i"
        $note.Group = 'kaya-phantom-probe'
        $notifier.Show($note)
        Start-Sleep -Milliseconds 50
    }
}

if ($ClearAfter) {
    $history = [Windows.UI.Notifications.ToastNotificationManager]::History
    try { $history.Clear($Aumid); Say "clearafter.cleared=$Aumid" }
    catch { Say "clearafter.failed=$($_.Exception.Message)" }
}

if ($Shot) {
    Add-Type -AssemblyName System.Drawing
    Add-Type -AssemblyName System.Windows.Forms
    $b = [Windows.Forms.SystemInformation]::VirtualScreen
    $bmp = New-Object Drawing.Bitmap $b.Width, $b.Height
    $g = [Drawing.Graphics]::FromImage($bmp)
    # CAPTUREBLT beside SRCCOPY: a banner is a LAYERED window and a plain
    # SRCCOPY leaves it out (docs/traps.md, the toast moment).
    $g.CopyFromScreen($b.X, $b.Y, 0, 0, $bmp.Size)
    $g.Dispose()
    $bmp.Save('C:\kaya\phantom-shot.png', [Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
    Say "shot=phantom-shot.png $($b.Width)x$($b.Height)"
}

$deadline = (Get-Date).AddSeconds($Seconds)
$last = ''
$lastseh = ''
$t0 = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
while ((Get-Date) -lt $deadline) {
    $h = [KayaFg]::GetForegroundWindow()
    $line = ''
    if ($h -ne [IntPtr]::Zero) {
        $sb = New-Object Text.StringBuilder 256
        [void][KayaFg]::GetClassName($h, $sb, 256)
        $cls = $sb.ToString()
        $sb2 = New-Object Text.StringBuilder 256
        [void][KayaFg]::GetWindowText($h, $sb2, 256)
        $title = $sb2.ToString()
        $pid2 = 0
        [void][KayaFg]::GetWindowThreadProcessId($h, [ref]$pid2)
        $proc = try { (Get-Process -Id $pid2 -ErrorAction Stop).ProcessName } catch { '?' }
        $line = "hwnd=0x$($h.ToInt64().ToString('x')) pid=$pid2 proc=$proc class='$cls' title='$title'"
    } else {
        $line = 'foreground=none'
    }
    if ($line -ne $last) {
        $at = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - $t0
        Say "fg at=${at}ms $line"
        if ($h -ne [IntPtr]::Zero -and $line -match "New notification") {
            $age = [KayaFg]::NewestAgeMs($dir, 3600000)
            Say "reading at=${at}ms newest-notification-age=${age}ms $([KayaFg]::Reading($h))"
            Say "uia at=${at}ms $(ToastText $h)"
        }
        $last = $line
    }
    if ($form) { [Windows.Forms.Application]::DoEvents() }
    $seh = @(Get-Process ShellExperienceHost -ErrorAction SilentlyContinue)
    $sehline = if ($seh.Count) { ($seh | ForEach-Object { $_.Id }) -join ',' } else { 'none' }
    if ($sehline -ne $lastseh) {
        Say "seh at=$([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - $t0)ms pids=$sehline"
        $lastseh = $sehline
    }
    Start-Sleep -Milliseconds 100
}
$age = [KayaFg]::NewestAgeMs($dir, 3600000)
Say "final newest-notification-age=${age}ms"
if ($form) { $form.Close(); [Windows.Forms.Application]::DoEvents() }
Say 'PHANTOMPROBEDONE'
