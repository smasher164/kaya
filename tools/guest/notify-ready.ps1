# WILL THIS DESKTOP DELIVER A NOTIFICATION? Asked once, before any leg, the
# way desk-warm.ps1 asks whether the desktop will hand over the foreground.
#
# THE REGISTRY VALUE IS NOT THE ANSWER (measured 2026-09-09): the platform
# reads ToastEnabled / NOC_GLOBAL_SETTING_TOASTS_ENABLED LAZILY, so a lane
# can write one value and run against another for the life of a logon --
# which is exactly how tools/deploy-win.py wrote 0 for months while the
# notify legs passed, until something made the platform re-read it and every
# `expect_notification` began failing with `history holds 0 notification(s)`
# on a machine whose registry, AUMID key, activator and services all looked
# right. So this asks the PLATFORM: it posts a toast under the app's own
# AUMID, reads the history back, removes it, and prints both answers.
#
# ASCII ONLY: a guest .ps1 is read in the machine's ANSI code page
# (docs/traps.md; tools/check-steps.py refuses a non-ASCII byte outside a
# comment).
param([Parameter(Mandatory = $true)][string]$Aumid)
$ErrorActionPreference = 'Continue'
[Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
[Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom, ContentType = WindowsRuntime] | Out-Null

$xml = New-Object Windows.Data.Xml.Dom.XmlDocument
$xml.LoadXml('<toast><visual><binding template="ToastGeneric"><text>kaya</text><text>notification readiness probe</text></binding></visual></toast>')
$toast = New-Object Windows.UI.Notifications.ToastNotification $xml
$toast.Tag = 'kaya-ready'
$toast.Group = 'kaya-ready'
$notifier = [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($Aumid)
Write-Output "notify-ready.setting=$($notifier.Setting)"
$notifier.Show($toast)
Start-Sleep -Milliseconds 1500
$history = @([Windows.UI.Notifications.ToastNotificationManager]::History.GetHistory($Aumid))
Write-Output "notify-ready.delivered=$($history.Count)"
[Windows.UI.Notifications.ToastNotificationManager]::History.RemoveGroup('kaya-ready', $Aumid)
$left = @([Windows.UI.Notifications.ToastNotificationManager]::History.GetHistory($Aumid))
Write-Output "notify-ready.after-remove=$($left.Count)"
Write-Output 'NOTIFYREADYDONE'
