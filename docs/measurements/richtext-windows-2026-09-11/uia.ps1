# The out-of-process UI Automation half of the rich-text probe
# (docs/rich-text-plan.md R9): what a screen reader can actually read off a
# WinUI 3 RichEditBox carrying bold / italic / underline / strike / monospace
# / link / heading-sized runs.
#
# OUT OF PROCESS ON PURPOSE: a same-process UIA read runs the provider's
# main-thread code on the calling thread, which is the trap that ate a day on
# the mac a11y milestone. This runs from the same interactive session as the
# probe but from its own PowerShell process.
#
# POWERSHELL VARIABLES ARE CASE-INSENSITIVE: run 1 held the TextPattern TYPE
# in $TP and the pattern INSTANCE in $tp, which is one variable, so
# GetCurrentPattern was handed a null and the whole UIA half measured nothing.

$ErrorActionPreference = 'Continue'
$DIR = 'C:\kaya\richtext-probe'

function Say($s) { Write-Output $s }

Say ("uia.ps1 start " + (Get-Date -Format 'HH:mm:ss.fff') + " psversion=" + $PSVersionTable.PSVersion)

$ready = $false
for ($i = 0; $i -lt 180; $i++) {
    if (Test-Path "$DIR\ready.txt") { $ready = $true; break }
    Start-Sleep -Milliseconds 1000
}
if (-not $ready) { Say "uia.ps1: no ready.txt after 180s, giving up"; exit 1 }
Say "uia.ps1: ready.txt seen"
Start-Sleep -Milliseconds 600

Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes

$AEL  = [System.Windows.Automation.AutomationElement]
$TPAT = [System.Windows.Automation.TextPattern]
$TSC  = [System.Windows.Automation.TreeScope]
$TUN  = [System.Windows.Automation.Text.TextUnit]
$TEP  = [System.Windows.Automation.Text.TextPatternRangeEndpoint]

$probePid = [int](Get-Content "$DIR\pid.txt" -Raw).Trim()
Say "uia.ps1: probe pid=$probePid"

$cond = New-Object System.Windows.Automation.PropertyCondition($AEL::ProcessIdProperty, $probePid)
$topwin = $null
for ($i = 0; $i -lt 30; $i++) {
    $topwin = $AEL::RootElement.FindFirst($TSC::Children, $cond)
    if ($topwin -ne $null) { break }
    Start-Sleep -Milliseconds 500
}
if ($topwin -eq $null) { Say "uia.ps1: no top-level window for pid $probePid"; exit 1 }
Say ("uia.ps1: window name=""" + $topwin.Current.Name + """ class=" + $topwin.Current.ClassName +
     " controlType=" + $topwin.Current.ControlType.ProgrammaticName)

$idc = New-Object System.Windows.Automation.PropertyCondition($AEL::AutomationIdProperty, 'richProbe')
$edit = $topwin.FindFirst($TSC::Descendants, $idc)
if ($edit -eq $null) { Say "uia.ps1: no element with AutomationId richProbe"; exit 1 }

Say ""
Say "== U0 the element a screen reader lands on =="
Say ("  controlType=" + $edit.Current.ControlType.ProgrammaticName +
     " localized=""" + $edit.Current.LocalizedControlType + """" +
     " name=""" + $edit.Current.Name + """" +
     " class=" + $edit.Current.ClassName +
     " id=""" + $edit.Current.AutomationId + """" +
     " keyboardFocusable=" + $edit.Current.IsKeyboardFocusable +
     " isPassword=" + $edit.Current.IsPassword)
$pats = $edit.GetSupportedPatterns()
$names = @()
foreach ($p in $pats) { $names += $p.ProgrammaticName }
Say ("  supported patterns: " + ($names -join ', '))

$patObj = $TPAT::Pattern
if ($patObj -eq $null) {
    Say "  TextPattern::Pattern static was null; taking the pattern off GetSupportedPatterns"
    foreach ($p in $pats) { if ($p.ProgrammaticName -like 'TextPattern*') { $patObj = $p } }
}
$textPat = $null
try { $textPat = $edit.GetCurrentPattern($patObj) } catch { Say ("  GetCurrentPattern THREW " + $_.Exception.Message) }
if ($textPat -eq $null) { Say "  NO TextPattern on the RichEditBox"; exit 1 }
Say ("  SupportedTextSelection=" + $textPat.SupportedTextSelection)

$docRange = $textPat.DocumentRange
Say ("  DocumentRange.GetText(-1)=[" + ($docRange.GetText(-1) -replace "`r", '\r') + "]")

# Attribute ids are UIA's own (UIA_*AttributeId); LookupById is the route that
# does not depend on a static field the managed client may not have filled in.
function Res($id, $staticAttr) {
    if ($staticAttr -ne $null) { return $staticAttr }
    try { return [System.Windows.Automation.AutomationTextAttribute]::LookupById($id) } catch { return $null }
}

$attrList = @(
    @('FontWeight',         (Res 40007 $TPAT::FontWeightAttribute)),
    @('IsItalic',           (Res 40014 $TPAT::IsItalicAttribute)),
    @('UnderlineStyle',     (Res 40030 $TPAT::UnderlineStyleAttribute)),
    @('StrikethroughStyle', (Res 40026 $TPAT::StrikethroughStyleAttribute)),
    @('FontName',           (Res 40005 $TPAT::FontNameAttribute)),
    @('FontSize',           (Res 40006 $TPAT::FontSizeAttribute)),
    @('ForegroundColor',    (Res 40008 $TPAT::ForegroundColorAttribute)),
    @('BackgroundColor',    (Res 40001 $TPAT::BackgroundColorAttribute)),
    @('IsHidden',           (Res 40013 $TPAT::IsHiddenAttribute)),
    @('IsReadOnly',         (Res 40015 $TPAT::IsReadOnlyAttribute)),
    @('BulletStyle',        (Res 40002 $TPAT::BulletStyleAttribute)),
    @('HorizontalTextAlignment', (Res 40009 $TPAT::HorizontalTextAlignmentAttribute)),
    @('IndentationLeading', (Res 40011 $TPAT::IndentationLeadingAttribute)),
    @('OutlineStyles',      (Res 40022 $TPAT::OutlineStylesAttribute)),
    @('OverlineStyle',      (Res 40024 $TPAT::OverlineStyleAttribute)),
    @('StrikethroughColor', (Res 40025 $TPAT::StrikethroughColorAttribute)),
    @('UnderlineColor',     (Res 40029 $TPAT::UnderlineColorAttribute)),
    @('StyleName',          (Res 40033 $null)),
    @('StyleId',            (Res 40034 $null)),
    @('Link',               (Res 40035 $null)),
    @('AnnotationTypes',    (Res 40031 $null)),
    @('CaretPosition',      (Res 40038 $null))
)
foreach ($a in $attrList) {
    if ($a[1] -eq $null) { Say ("  attribute " + $a[0] + " -> <the managed client has no identifier for it>") }
}

function Attr($r, $attr, $label) {
    if ($attr -eq $null) { return "$label=<no identifier>" }
    try {
        $v = $r.GetAttributeValue($attr)
        if ([Object]::ReferenceEquals($v, $AEL::NotSupported)) { return "$label=NotSupported" }
        if ([Object]::ReferenceEquals($v, $TPAT::MixedAttributeValue)) { return "$label=Mixed" }
        if ($v -eq $null) { return "$label=<null>" }
        return ("$label=" + $v.ToString())
    } catch { return ("$label=<threw " + $_.Exception.GetType().Name + ">") }
}

Say ""
Say "== U1 the runs, found by text and read attribute by attribute =="
foreach ($w in @('plain run','bold run','italic run','under run','strike run','mono run','link run','heading run')) {
    $r = $docRange.FindText($w, $false, $true)
    if ($r -eq $null) { Say ("  " + $w + ": FindText found nothing"); continue }
    $line = "  " + $w + " [" + ($r.GetText(-1) -replace "`r", '\r') + "]"
    foreach ($a in $attrList) { $line += " " + (Attr $r $a[1] $a[0]) }
    Say $line
    $kids = $r.GetChildren()
    if ($kids -ne $null -and $kids.Count -gt 0) {
        foreach ($k in $kids) {
            Say ("      range child: type=" + $k.Current.ControlType.ProgrammaticName +
                 " name=""" + $k.Current.Name + """ class=" + $k.Current.ClassName)
        }
    } else { Say "      range children: none" }
}

Say ""
Say "== U2 the whole document as ONE range (what a mixed read answers) =="
$line = "  document"
foreach ($a in $attrList) { $line += " " + (Attr $docRange $a[1] $a[0]) }
Say $line
$dkids = $docRange.GetChildren()
Say ("  DocumentRange.GetChildren() count=" + $(if ($dkids -eq $null) { 0 } else { $dkids.Count }))
if ($dkids -ne $null) {
    foreach ($k in $dkids) {
        Say ("    child: type=" + $k.Current.ControlType.ProgrammaticName +
             " name=""" + $k.Current.Name + """ class=" + $k.Current.ClassName)
    }
}

Say ""
Say "== U3 the FORMAT-unit walk, which is how a screen reader finds run boundaries =="
$r = $docRange.Clone()
$r.MoveEndpointByRange($TEP::End, $docRange, $TEP::Start) | Out-Null
for ($i = 0; $i -lt 40; $i++) {
    $r.ExpandToEnclosingUnit($TUN::Format)
    $t = $r.GetText(-1)
    if ($t -eq $null) { break }
    $show = $t -replace "`r", '\r'
    Say ("  run " + $i + " [" + $show + "] " +
         (Attr $r $attrList[0][1] 'FontWeight') + " " +
         (Attr $r $attrList[1][1] 'IsItalic') + " " +
         (Attr $r $attrList[2][1] 'UnderlineStyle') + " " +
         (Attr $r $attrList[3][1] 'StrikethroughStyle') + " " +
         (Attr $r $attrList[4][1] 'FontName') + " " +
         (Attr $r $attrList[5][1] 'FontSize') + " " +
         (Attr $r $attrList[8][1] 'IsHidden') + " " +
         (Attr $r $attrList[19][1] 'Link'))
    $moved = $r.Move($TUN::Format, 1)
    if ($moved -ne 1) { Say ("  format walk ended after " + ($i + 1) + " runs (Move returned " + $moved + ")"); break }
}

Say ""
Say "== U4 the element subtree (a Hyperlink child would show here) =="
$all = $topwin.FindAll($TSC::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
Say ("  descendants of the window: " + $all.Count)
foreach ($e in $all) {
    Say ("    type=" + $e.Current.ControlType.ProgrammaticName +
         " id=""" + $e.Current.AutomationId + """ name=""" + $e.Current.Name +
         """ class=" + $e.Current.ClassName)
}

Say ""
Say "== U5 the caret's own range =="
try {
    $sel = $textPat.GetSelection()
    Say ("  GetSelection() ranges=" + $sel.Count)
    foreach ($s in $sel) { Say ("    selection [" + ($s.GetText(-1) -replace "`r", '\r') + "]") }
} catch { Say ("  GetSelection THREW " + $_.Exception.Message) }

Say ""
Say "uia.ps1 done"
