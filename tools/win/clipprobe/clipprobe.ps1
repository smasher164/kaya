# ClipProbe's foreign half, orchestrating the whole run inside the ONE
# interactive-session task (each ssh connection has its own window
# station and its own clipboard — see src/main.rs).
#
# Windows PowerShell 5.1 ONLY: pwsh silently lacks -Format /
# -TextFormatType on Get-Clipboard and -AsHtml/-LiteralPath on
# Set-Clipboard, so the edition is asserted rather than assumed.
$ErrorActionPreference = 'Continue'
if ($PSVersionTable.PSEdition -ne 'Desktop') {
    "PROBE FATAL: not Windows PowerShell (Desktop) - the clipboard cmdlet surface is different"
    exit 1
}
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
"PROBE edition: $($PSVersionTable.PSEdition) $($PSVersionTable.PSVersion)"
"PROBE session: id=$([System.Diagnostics.Process]::GetCurrentProcess().SessionId) sta=$([Threading.Thread]::CurrentThread.GetApartmentState())"

$exe = 'C:\kaya\clipprobe\clipprobe.exe'

# ---- Phase A: the arm's write, read by FOREIGN stock tooling --------
& $exe set
"PROBE A text: >>>$(Get-Clipboard -Raw)<<<"

# Raw CF_HTML including the header. NOT Get-Clipboard -TextFormatType
# Html for the record that matters: that cmdlet decodes the UTF-8
# payload with the ANSI code page and corrupts non-ASCII irreversibly.
# PresentationCore's GetText(Html) is the safe reader. (ASCII fragment
# here, so this run also prints the cmdlet's view for comparison.)
$rawHtml = [Windows.Clipboard]::GetText([Windows.TextDataFormat]::Html)
$head = $rawHtml.Substring(0, [Math]::Min(130, $rawHtml.Length)) -replace "`r","\r" -replace "`n","\n"
"PROBE A html raw head: >>>$head<<<"
if ($rawHtml -match 'StartFragment:(\d+)') { $sf = [int]$Matches[1] }
if ($rawHtml -match 'EndFragment:(\d+)') { $ef = [int]$Matches[1] }
$htmlBytes = [Text.Encoding]::UTF8.GetBytes($rawHtml)
$frag = [Text.Encoding]::UTF8.GetString($htmlBytes[$sf..($ef - 1)])
"PROBE A html fragment via THEIR parse of OUR header: >>>$frag<<<"

$ms = [Windows.Clipboard]::GetData('dev.kaya/note')
if ($ms) {
    $buf = New-Object byte[] $ms.Length
    [void]$ms.Read($buf, 0, $ms.Length)
    "PROBE A custom: >>>$([Text.Encoding]::UTF8.GetString($buf))<<< ($($ms.Length) bytes)"
} else {
    "PROBE A custom: NULL"
}

$fd = Get-Clipboard -Format FileDropList
"PROBE A files: $(@($fd | ForEach-Object { $_.FullName }) -join ';')"

# The image, DECODED by a foreign decoder (GDI+), from the PNG bytes.
$pngStream = [Windows.Clipboard]::GetData('PNG')
if ($pngStream) {
    try {
        $img = [System.Drawing.Image]::FromStream($pngStream)
        "PROBE A image decoded: $($img.Width)x$($img.Height)"
    } catch {
        "PROBE A image decode FAILED: $($_.Exception.Message)"
    }
} else {
    "PROBE A image: PNG format NULL"
}
# And what a DIB-path consumer sees of a PNG-only clip (expected: null
# — recorded so the plan can state the interop cut deliberately).
$gi = Get-Clipboard -Format Image
if ($gi) { "PROBE A Get-Clipboard -Format Image: $($gi.Width)x$($gi.Height)" } else { "PROBE A Get-Clipboard -Format Image: null" }

# ---- Phase B: FOREIGN seeds, read by the arm's own path -------------
Set-Clipboard -Value 'from another app'
& $exe read text

Set-Clipboard -Value '<b>seeded</b> html' -AsHtml
& $exe read html

$pngBytes = [IO.File]::ReadAllBytes('C:\kaya\clipprobe\pixel.png')
$seedMs = New-Object IO.MemoryStream (,$pngBytes)
[Windows.Clipboard]::SetData('PNG', $seedMs)
& $exe read image

Set-Clipboard -LiteralPath 'C:\kaya\clipprobe\f1.txt','C:\kaya\clipprobe\f2.txt'
& $exe read files

# MemoryStream, NEVER a string: a string goes through the WPF
# serialized-object path (16-byte GUID + BinaryFormatter blob) that
# round-trips inside PowerShell while every other reader sees garbage.
$noteMs = New-Object IO.MemoryStream (,[Text.Encoding]::UTF8.GetBytes('note=1'))
[Windows.Clipboard]::SetData('dev.kaya/note', $noteMs)
& $exe read custom

# ---- Phase C: decoder strictness (the broken-CRC PNG lesson) --------
# The OLD 88-byte guest constant with its wrong IDAT CRC, base64. A
# decoder that accepts it would have hidden §5b finding 5 on this lane.
$broken = [Convert]::FromBase64String('iVBORw0KGgoAAAANSUhEUgAAAAQAAAAECAIAAAAmkwkpAAAAHElEQVQYV2P8z8Dwn4HhPwPDfwaG/wwM/xkY/jMwAAA9lAf5iizqhAAAAABJRU5ErkJggg==')
try {
    $bi = [System.Drawing.Image]::FromStream((New-Object IO.MemoryStream (,$broken)))
    "PROBE C gdiplus on broken png: DECODED $($bi.Width)x$($bi.Height)"
} catch { "PROBE C gdiplus on broken png: REJECTED" }
try {
    $dec = New-Object Windows.Media.Imaging.PngBitmapDecoder(
        (New-Object IO.MemoryStream (,$broken)),
        [Windows.Media.Imaging.BitmapCreateOptions]::None,
        [Windows.Media.Imaging.BitmapCacheOption]::OnLoad)
    "PROBE C wpf on broken png: DECODED $($dec.Frames[0].PixelWidth)x$($dec.Frames[0].PixelHeight)"
} catch { "PROBE C wpf on broken png: REJECTED" }
try {
    $good = [System.Drawing.Image]::FromStream((New-Object IO.MemoryStream (,$pngBytes)))
    "PROBE C gdiplus on valid png (control): $($good.Width)x$($good.Height)"
} catch { "PROBE C gdiplus on valid png: REJECTED (control FAILED)" }

'PROBEDONE'
