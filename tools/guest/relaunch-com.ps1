# THE SECOND ACT'S DOOR ON WINDOWS (docs/tasks-s9-plan.md R6/R6a): act one
# has exited, its marker is on disk, and this pushes the OS's own door one
# step past a tap nothing can drive - CoCreateInstance of the app's toast
# activator class id, which starts the exe (through the library's HKCU
# LocalServer32 when unpackaged, through the package's com:ExeServer when
# packaged) and then Activate with the toast's own launch string.
#
# WHY Add-Type: INotificationActivationCallback is a raw IUnknown-derived
# interface with no IDispatch and no type library, so PowerShell cannot call
# it through a System.__ComObject. The in-box C# compiler is measured present
# on this guest (PS 5.1.26100.9168).
#
# WHY A FILE AND NOT AN INLINE -Command: through ssh and cmd a
# `powershell -Command "..."` arrives as one quoted string PowerShell PRINTS
# (docs/traps.md, measured 2026-09-01).
#
# ASCII ONLY: a guest .ps1 is read in the machine's ANSI code page, so one
# non-ASCII byte inside a string closes it (docs/traps.md; tools/check-steps.py
# refuses one).
param(
    [Parameter(Mandatory = $true)][string]$Clsid,
    [Parameter(Mandatory = $true)][string]$Aumid,
    [Parameter(Mandatory = $true)][string]$Key,
    [Parameter(Mandatory = $true)][int]$Notification,
    [Parameter(Mandatory = $true)][string]$Id,
    [string]$Family = '',
    [int]$Deadline = 150
)
$ErrorActionPreference = 'Continue'

# THE LAUNCH STRING, JOINED HERE because `=` is an argument delimiter in a
# .cmd's %1..%9 and `kaya=1` arrives as two tokens (measured 2026-09-08).
$Launch = "$Key=$Notification"

# THE ACT-TWO LAYOUT, whose one definition is crates/kaya/src/act2.rs
# (`<state>/act2/<id>`, `<state>` = %LOCALAPPDATA%\kaya here). The runner
# cannot read the started process's KAYA_ACT2_VERDICT, so the path is spelled
# here and nowhere else on this side.
$candidates = @((Join-Path $env:LOCALAPPDATA "kaya\act2\$Id\act2.verdict"))
if ($Family -ne '') {
    # A packaged process may see a redirected LOCALAPPDATA; both are polled and
    # the one that answered is named, so a reading is never a guess.
    $candidates += (Join-Path $env:LOCALAPPDATA "Packages\$Family\LocalCache\Local\kaya\act2\$Id\act2.verdict")
}
foreach ($c in $candidates) {
    Remove-Item -LiteralPath $c -Force -ErrorAction SilentlyContinue
    Write-Output "relaunch-com: watching $c"
}

Add-Type -Language CSharp -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

[ComImport, Guid("53E31837-6600-4A81-9395-75CFFE746F94"),
 InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface INotificationActivationCallback {
    void Activate([MarshalAs(UnmanagedType.LPWStr)] string appUserModelId,
                  [MarshalAs(UnmanagedType.LPWStr)] string invokedArgs,
                  IntPtr data, uint count);
}

public static class KayaRelaunchDoor {
    [DllImport("ole32.dll")]
    static extern int CoCreateInstance(ref Guid clsid, IntPtr outer, uint ctx,
                                       ref Guid iid, out IntPtr obj);
    // CLSCTX_LOCAL_SERVER: the class must come from a process COM starts, not
    // from a DLL loaded into this one.
    public static string Push(string clsid, string aumid, string args) {
        Guid c = new Guid(clsid);
        Guid iid = new Guid("53E31837-6600-4A81-9395-75CFFE746F94");
        IntPtr p;
        int hr = CoCreateInstance(ref c, IntPtr.Zero, 4, ref iid, out p);
        if (hr != 0) {
            return string.Format("CoCreateInstance({0}) failed 0x{1:X8}", clsid, hr);
        }
        object o = Marshal.GetObjectForIUnknown(p);
        Marshal.Release(p);
        try {
            ((INotificationActivationCallback)o).Activate(aumid, args, IntPtr.Zero, 0);
        } catch (Exception e) {
            return "Activate threw " + e.Message;
        }
        return "OK";
    }
}
'@

$t0 = Get-Date
$answer = [KayaRelaunchDoor]::Push($Clsid, $Aumid, $Launch)
$ms = [int]((Get-Date) - $t0).TotalMilliseconds
Write-Output "relaunch-com: $Clsid Activate('$Aumid', '$Launch') -> $answer in ${ms}ms"
if ($answer -ne 'OK') {
    Write-Output 'relaunch-com: the door did not open, so act two never started'
    Write-Output 'RELAUNCHDONE'
    exit 1
}

# NOT $deadline: PowerShell is case-insensitive, so assigning it would write
# the [int] parameter and fail with an unrelated cast error.
$until = (Get-Date).AddSeconds($Deadline)
while ((Get-Date) -lt $until) {
    foreach ($c in $candidates) {
        if (Test-Path -LiteralPath $c) {
            $line = (Get-Content -LiteralPath $c -Encoding UTF8 -ErrorAction SilentlyContinue) -join ' '
            if ($line) {
                $waited = [int]((Get-Date) - $t0).TotalMilliseconds
                Write-Output "relaunch-com: act two answered in ${waited}ms from $c"
                Write-Output "ACT2: $line"
                Write-Output 'RELAUNCHDONE'
                exit 0
            }
        }
    }
    Start-Sleep -Milliseconds 250
}
# THE DEADLINE SAYS WHAT IT SAW, never just that it waited: which paths were
# watched, and whether the process COM started is still alive.
$live = @(Get-Process -ErrorAction SilentlyContinue |
          Where-Object { $_.Path -and $_.Path -like '*tasks.exe' })
Write-Output "relaunch-com: no act-two verdict after ${Deadline}s"
foreach ($c in $candidates) {
    Write-Output "relaunch-com:   $c exists=$(Test-Path -LiteralPath $c)"
}
foreach ($p in $live) {
    Write-Output "relaunch-com:   still running pid $($p.Id) $($p.Path)"
}
if ($live.Count -eq 0) {
    Write-Output 'relaunch-com:   the process COM started is gone; it wrote no verdict'
}
Write-Output 'RELAUNCHDONE'
exit 1
