<#
.SYNOPSIS
  Assert that a packed MSIX declares the given executables as <Application> entries.

.DESCRIPTION
  Windows only lets a process outside the package launch a packaged binary that
  the manifest declares as an <Application>; an undeclared one fails
  CreateProcess with ERROR_ACCESS_DENIED. Every agent hook config points at
  antgrid-bridge.exe by absolute path, so if the declaration is ever lost the
  build still succeeds, the Store still accepts it, and every hook for every
  agent dies silently in the field.

  Nothing earlier in the pipeline covers this: the hook smoke test runs against
  the loose bridge binary before packaging, which is exactly the case that
  already works.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string]$Path,

  [Parameter(Mandatory = $true)]
  [ValidatePattern('^[A-Za-z0-9._-]+\.exe$')]
  [string[]]$Executable
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

  $declared = @(
    $manifest.SelectNodes("//*[local-name()='Application']") |
      ForEach-Object { $_.GetAttribute('Executable') }
  )

  foreach ($name in $Executable) {
    if ($declared -notcontains $name) {
      $found = if ($declared.Count -eq 0) { '(none)' } else { $declared -join ', ' }
      throw "MSIX does not declare '$name' as an <Application>; declared executables: $found"
    }

    # A declared executable missing from the payload passes the build and fails
    # at Store ingestion instead, so check the entry is actually packed.
    if ($null -eq $archive.GetEntry($name)) {
      throw "MSIX declares '$name' but the file is not in the package: $resolvedPath"
    }
  }

  Write-Host "Verified MSIX declares launchable executables: $($Executable -join ', ')"
}
finally {
  $archive.Dispose()
}
