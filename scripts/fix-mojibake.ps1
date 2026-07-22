# Repair UTF-8-mis-decoded-as-Windows-1252 mojibake in app/lib/**/*.dart.
#
# Symptom: text like `âœ"` instead of `✓`, `â†'` instead of `→`. Cause:
# a UTF-8 file was at some point opened as Windows-1252 and re-saved as
# UTF-8, double-encoding every multi-byte glyph.
#
# Strategy: every mojibake char is a Unicode codepoint that has a 1-byte
# CP1252 representation. For each char, recover its CP1252 byte, collect
# runs (bounded lookahead, max 6 chars), and strict-decode the run as
# UTF-8. If the decode succeeds AND shortens the string, swap it in.
#
# Run from repo root:  pwsh scripts/fix-mojibake.ps1

$root = Join-Path $PSScriptRoot '..\app\lib'
$cp1252 = [System.Text.Encoding]::GetEncoding(1252)
$utf8Strict = New-Object System.Text.UTF8Encoding($false, $true)
$utf8NoBom  = New-Object System.Text.UTF8Encoding($false)

$charToByte = New-Object 'System.Collections.Generic.Dictionary[char,int]'
for ($b = 0; $b -lt 256; $b++) {
    try {
        $s = $cp1252.GetString([byte[]]@($b))
        if ($s.Length -eq 1) { $charToByte[[char]$s[0]] = $b }
    } catch { }
}

function RepairString([string]$s) {
    $sb = New-Object System.Text.StringBuilder
    $i = 0
    $n = $s.Length
    while ($i -lt $n) {
        $c = $s[$i]
        if ([int]$c -lt 0x80) {
            [void]$sb.Append($c); $i++; continue
        }
        $maxK = [Math]::Min(6, $n - $i)
        $bytes = New-Object byte[] $maxK
        $valid = 0
        for ($k = 0; $k -lt $maxK; $k++) {
            $ch = $s[$i + $k]
            if (-not $charToByte.ContainsKey($ch)) { break }
            $bytes[$k] = [byte]$charToByte[$ch]
            $valid = $k + 1
        }
        $bestLen = 0; $bestDecoded = $null
        for ($k = 2; $k -le $valid; $k++) {
            $slice = New-Object byte[] $k
            [Array]::Copy($bytes, 0, $slice, 0, $k)
            try {
                $decoded = $utf8Strict.GetString($slice)
                if ($decoded.Length -lt $k) {
                    $bestLen = $k
                    $bestDecoded = $decoded
                }
            } catch { }
        }
        if ($bestLen -gt 0) {
            [void]$sb.Append($bestDecoded)
            $i += $bestLen
        } else {
            [void]$sb.Append($c); $i++
        }
    }
    return $sb.ToString()
}

$files = Get-ChildItem -Path $root -Recurse -Filter *.dart
$fixed = 0
foreach ($f in $files) {
    $content = [System.IO.File]::ReadAllText($f.FullName, [System.Text.Encoding]::UTF8)
    if ($content.Length -eq 0) { continue }
    $original = $content
    if ([int]$content[0] -eq 0xFEFF) { $content = $content.Substring(1) }
    $repaired = RepairString $content
    if ($repaired -ne $original) {
        [System.IO.File]::WriteAllText($f.FullName, $repaired, $utf8NoBom)
        $fixed++
        Write-Output $f.FullName
    }
}
Write-Output "Fixed: $fixed files"
