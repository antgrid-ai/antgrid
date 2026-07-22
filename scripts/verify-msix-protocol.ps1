[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string]$Path,

  [Parameter(Mandatory = $true)]
  [ValidatePattern('^[A-Za-z][A-Za-z0-9+.-]*$')]
  [string]$Protocol
)

$ErrorActionPreference = 'Stop'
$resolvedPath = (Resolve-Path -LiteralPath $Path).Path

Add-Type -AssemblyName System.IO.Compression.FileSystem
$archive = [System.IO.Compression.ZipFile]::OpenRead($resolvedPath)

try {
  $manifestEntry = $archive.GetEntry('AppxManifest.xml')
  if ($null -eq $manifestEntry) {
    throw "MSIX does not contain AppxManifest.xml: $resolvedPath"
  }

  $stream = $manifestEntry.Open()
  $reader = [System.IO.StreamReader]::new($stream)
  try {
    [xml]$manifest = $reader.ReadToEnd()
  }
  finally {
    $reader.Dispose()
    $stream.Dispose()
  }

  $protocolNames = @(
    $manifest.SelectNodes("//*[local-name()='Protocol']") |
      ForEach-Object { $_.GetAttribute('Name') }
  )

  if ($protocolNames -notcontains $Protocol) {
    $declared = if ($protocolNames.Count -eq 0) {
      '(none)'
    }
    else {
      $protocolNames -join ', '
    }
    throw "MSIX protocol '$Protocol' is missing from AppxManifest.xml; declared protocols: $declared"
  }

  Write-Host "Verified MSIX protocol activation: $Protocol"
}
finally {
  $archive.Dispose()
}
