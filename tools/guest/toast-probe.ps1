# RAISE A TOAST THAT HOLDS THE FOREGROUND, so the flight recorder's
# toast-moment section can be SEEN filled instead of believed (the
# maintainer's 2026-09-16 ruling: a section nobody has watched fill is a
# guess). Five windows bundles named the toast's class and never its
# sender; a toast cannot be raised from the mac side, so this raises one
# here and the notes_rust leg is run against it.
#
# scenario="reminder": the platform keeps such a toast up UNTIL IT IS
# DISMISSED, so it outlasts even the guest's 30s wait. The scenario also
# REQUIRES at least one action, which is what the button below is for.
#
# The AUMID is PowerShell's own registered one -- already in the guest's
# NotificationHandler table, so nothing has to be registered and nothing
# is left behind but the toast, which -Clear takes down.
#
# Run through schtasks /it like notify-ready.ps1 and dismiss-toasts.ps1:
# the notification platform answers per LOGON SESSION, and an ssh session
# is session 0 with no desktop.
#
# ASCII ONLY: a guest .ps1 is read in the machine's ANSI code page
# (docs/traps.md; tools/check-steps.py refuses a non-ASCII byte outside a
# comment).
param([switch]$Clear, [string]$Scenario = 'reminder',
      [string]$Aumid = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe',
      [int]$Count = 1)
$ErrorActionPreference = 'Continue'
[Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
[Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom, ContentType = WindowsRuntime] | Out-Null

$aumid = $Aumid
$history = [Windows.UI.Notifications.ToastNotificationManager]::History
Write-Output "toast-probe.aumid=$aumid"

if ($Clear) {
    $before = -1
    try { $before = @($history.GetHistory($aumid)).Count } catch { $before = -1 }
    try { $history.RemoveGroup('kaya-toast-probe', $aumid) } catch { Write-Output "toast-probe.removegroup-failed=$($_.Exception.Message)" }
    try { $history.Clear($aumid) } catch { Write-Output "toast-probe.clear-failed=$($_.Exception.Message)" }
    $after = -1
    try { $after = @($history.GetHistory($aumid)).Count } catch { $after = -1 }
    Write-Output "toast-probe.before=$before"
    Write-Output "toast-probe.after=$after"
    Write-Output 'TOASTPROBEDONE'
    exit 0
}

$stamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
$text = "kaya flightrec toast probe $stamp"
$notifier = [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($aumid)
Write-Output "toast-probe.scenario=$Scenario"
Write-Output "toast-probe.setting=$($notifier.Setting)"
for ($i = 1; $i -le $Count; $i++) {
    $xml = New-Object Windows.Data.Xml.Dom.XmlDocument
    $xml.LoadXml('<toast scenario="' + $Scenario + '"><visual><binding template="ToastGeneric"><text>kaya flightrec toast probe</text><text>' + $text + ' #' + $i + '</text></binding></visual><actions><action activationType="system" arguments="dismiss" content="Dismiss" /></actions></toast>')
    $toast = New-Object Windows.UI.Notifications.ToastNotification $xml
    # A UNIQUE TAG PER COPY: one Tag replaces its predecessor rather than
    # queueing beside it, so a burst under one tag is one banner.
    $toast.Tag = "kaya-toast-probe-$i"
    $toast.Group = 'kaya-toast-probe'
    $notifier.Show($toast)
    Start-Sleep -Milliseconds 300
}
Start-Sleep -Milliseconds 1200
$held = -1
try { $held = @($history.GetHistory($aumid)).Count } catch { $held = -1 }
Write-Output "toast-probe.text=$text"
Write-Output "toast-probe.history=$held"
Write-Output 'TOASTPROBEDONE'
