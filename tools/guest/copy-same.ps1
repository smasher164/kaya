# C:\kaya\copies.txt's "source destination" lines, copied within C:\kaya and
# hash-checked (tools/deploy-win.py, ship_flat_artifacts).
$ErrorActionPreference = 'Stop'
$lines = @(Get-Content C:\kaya\copies.txt | Where-Object { $_.Trim() })
$hashes = @{}
$equal = 0
foreach ($line in $lines) {
    $src, $dst = $line.Trim().Split(' ')
    if (-not $hashes.ContainsKey($src)) {
        $hashes[$src] = (Get-FileHash -LiteralPath "C:\kaya\$src" -Algorithm SHA256).Hash
    }
    Copy-Item -LiteralPath "C:\kaya\$src" -Destination "C:\kaya\$dst" -Force
    $got = (Get-FileHash -LiteralPath "C:\kaya\$dst" -Algorithm SHA256).Hash
    if ($got -eq $hashes[$src]) {
        $equal++
    } else {
        Write-Output "copy-same: C:\kaya\$dst reads $got after the copy, C:\kaya\$src $($hashes[$src])"
    }
}
Write-Output "copy-same: $equal of $($lines.Count) hash-equal"
