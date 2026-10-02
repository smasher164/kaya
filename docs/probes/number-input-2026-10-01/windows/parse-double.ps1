$ErrorActionPreference="Stop"
[void][Windows.Globalization.NumberFormatting.DecimalFormatter, Windows.Globalization, ContentType=WindowsRuntime]
[void][Windows.System.UserProfile.GlobalizationPreferences, Windows.System.UserProfile, ContentType=WindowsRuntime]
$cases=@('34','3.5','3,5','٣٤','٣٫٥','٣.٥','٣,٥','3٫5','1,234.5','1.234,5','1.234','1,234','12,34','12.34','1,23,4.5','1.2.3','12.34,5','١٬٢٣٤','١٬٢٣٤٫٥','١٢٬٣٤','-3.5','-3,5','-٣٫٥','−3.5','؜-٣٫٥','‏-٣٫٥',' 3.5 ','3.5e2','+3.5')

function hexs($s){ ($s.ToCharArray() | % { '{0:X4}' -f [int]$_ }) -join ' ' }
$region=[Windows.System.UserProfile.GlobalizationPreferences]::HomeGeographicRegion
"home region: $region ; user default locale: " + (Get-Culture).Name
foreach($loc in @('en-US','de-DE','ar-EG')){
  foreach($grouped in @($false,$true)){
    $f = New-Object Windows.Globalization.NumberFormatting.DecimalFormatter -ArgumentList @([string[]]@($loc)), $region
    $f.NumberRounder=$null; $f.IntegerDigits=1; $f.FractionDigits=0; $f.IsGrouped=$grouped
    "== $loc grouped=$grouped numeral=$($f.NumeralSystem) resolved=$($f.ResolvedLanguage) writes -1234.5 as [" + $f.FormatDouble(-1234.5) + "] hex " + (hexs $f.FormatDouble(-1234.5))
    foreach($c in $cases){
      $r=$null; try { $r=$f.ParseDouble($c) } catch { $r="EXC" }
      if($r -eq $null){$r='null'}
      "  [" + $c + "] (" + (hexs $c) + ") -> " + $r
    }
  }
}
"== default-constructed DecimalFormatter (user settings) numeral=" 
$d = New-Object Windows.Globalization.NumberFormatting.DecimalFormatter
"lang=" + ($d.Languages -join ',') + " writes -1234.5 as [" + $d.FormatDouble(-1234.5) + "]"
foreach($c in $cases){ $r=$d.ParseDouble($c); if($r -eq $null){$r='null'}; "  [" + $c + "] -> " + $r }
"PARSEDONE"
