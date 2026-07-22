# Scan the Flutter app for unsafe byte -> string conversions that produce
# mojibake when the underlying bytes are UTF-8 (the default for the Antgrid
# agent's stdout/stderr and every log file we write).
#
# Risky patterns:
#   String.fromCharCodes(bytes)   - treats each byte as a UCS codepoint
#                                   (effectively Latin-1).
#   latin1.decode(bytes)          - same problem, explicit.
#   ascii.decode(bytes)           - throws on >0x7F unless `allowInvalid`,
#                                   but still wrong for multi-byte chars.
#
# Safe replacements:
#   utf8.decode(bytes, allowMalformed: true)
#   const Utf8Decoder(allowMalformed: true).convert(bytes)
#   utf8.decoder.bind(stream).listen(...)
#
# Run:  pwsh scripts/find-byte-decode-bugs.ps1
# Exits 0 if clean, 1 if any hit is found.

$root = Join-Path $PSScriptRoot '..\app\lib'
$pattern = '\b(String\.fromCharCodes|latin1\.decode|ascii\.decode)\b'

$hits = Get-ChildItem -Path $root -Recurse -Filter *.dart |
    Select-String -Pattern $pattern |
    Where-Object { $_.Line -notmatch '^\s*//' }

if ($hits) {
    Write-Output 'Found unsafe byte->string conversions:'
    foreach ($h in $hits) {
        Write-Output ("  {0}:{1}: {2}" -f $h.Path, $h.LineNumber, $h.Line.Trim())
    }
    exit 1
}

Write-Output 'OK: no unsafe byte->string conversions in app/lib.'
exit 0
