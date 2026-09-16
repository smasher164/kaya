# DISMISS EVERY KAYA TOAST before an exclusive leg types (docs/deferred.md,
# the PopupHost WATCH; docs/traps.md "A shell toast holds the foreground"):
# a banner that is up when SetForegroundWindow runs blocks it outright, and
# a pooled notify leg's toast outlives the leg by its display time, into the
# exclusive block that follows. Clearing an AUMID's history takes its banner
# down with it. Run through schtasks /it like notify-ready.ps1 -- the
# platform answers per LOGON SESSION.
#
# ASCII ONLY: a guest .ps1 is read in the machine's ANSI code page.
param([Parameter(Mandatory = $true)][string]$Aumids)
$ErrorActionPreference = 'Continue'
[Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
$history = [Windows.UI.Notifications.ToastNotificationManager]::History
# '~' separates the AUMIDs: ';' and ',' are cmd's own argument delimiters and
# %~1 would carry the first one alone (measured: one identity of three).
foreach ($aumid in $Aumids.Split('~')) {
    if ($aumid.Length -eq 0) { continue }
    $before = -1
    try { $before = @($history.GetHistory($aumid)).Count } catch { $before = -1 }
    try { $history.Clear($aumid) } catch { Write-Output "dismiss-toasts: $aumid clear failed: $($_.Exception.Message)" }
    Write-Output "dismiss-toasts: $aumid held $before, cleared"
}
Write-Output "DISMISSTOASTSDONE"
