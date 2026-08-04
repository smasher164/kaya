# The undo probe's AX dump: name every element UI Automation can see in
# the probe process's top-level windows — the context menu popups
# included, since a WinUI flyout is its own top-level
# Microsoft.UI.Content.PopupWindowSiteBridge window.
#
# OUT OF PROCESS on purpose (crates/kaya/Cargo.toml records why kaya's
# own backend may not host a UIA client), and Windows PowerShell 5.1,
# where the UIAutomationClient assemblies ship in the box.
param([int]$TargetPid)
$ErrorActionPreference = 'Continue'
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes

$cond = New-Object Windows.Automation.PropertyCondition(
    [Windows.Automation.AutomationElement]::ProcessIdProperty, $TargetPid)
$roots = [Windows.Automation.AutomationElement]::RootElement.FindAll(
    [Windows.Automation.TreeScope]::Children, $cond)
"roots=$($roots.Count) pid=$TargetPid"
foreach ($r in $roots) {
    "WINDOW name='$($r.Current.Name)' class='$($r.Current.ClassName)' type=$($r.Current.ControlType.ProgrammaticName)"
    $all = $r.FindAll([Windows.Automation.TreeScope]::Descendants,
        [Windows.Automation.Condition]::TrueCondition)
    foreach ($e in $all) {
        $name = $e.Current.Name
        $type = $e.Current.ControlType.ProgrammaticName
        $auto = $e.Current.AutomationId
        $on = $e.Current.IsEnabled
        "  ITEM name='$name' type=$type automationId='$auto' enabled=$on"
    }
}
