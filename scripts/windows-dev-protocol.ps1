[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [ValidateSet('Add', 'Remove')]
  [string]$Action,

  [ValidatePattern('^[A-Za-z][A-Za-z0-9+.-]*$')]
  [string]$Protocol = 'antgrid',

  [string]$ExecutablePath
)

$ErrorActionPreference = 'Stop'

if ($env:OS -ne 'Windows_NT' -or $null -eq (Get-PSDrive -Name HKCU -ErrorAction SilentlyContinue)) {
  throw 'Windows protocol registration requires Windows and the HKCU registry provider.'
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$defaultExecutable = Join-Path $repoRoot 'app\build\windows\x64\runner\Debug\antgrid.exe'
$executable = if ([string]::IsNullOrWhiteSpace($ExecutablePath)) {
  [IO.Path]::GetFullPath($defaultExecutable)
}
else {
  [IO.Path]::GetFullPath($ExecutablePath)
}

$protocolKey = "Registry::HKEY_CURRENT_USER\Software\Classes\$Protocol"
$shellKey = "$protocolKey\shell"
$openKey = "$shellKey\open"
$commandKey = "$openKey\command"
$expectedCommand = '"{0}" "%1"' -f $executable

if ($Action -eq 'Add') {
  foreach ($key in @($protocolKey, $shellKey, $openKey, $commandKey)) {
    New-Item -Path $key -Force | Out-Null
  }

  Set-Item -LiteralPath $protocolKey -Value 'URL:Antgrid Protocol'
  New-ItemProperty `
    -LiteralPath $protocolKey `
    -Name 'URL Protocol' `
    -PropertyType String `
    -Value '' `
    -Force | Out-Null
  Set-Item -LiteralPath $commandKey -Value $expectedCommand

  if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) {
    Write-Warning "Debug executable does not exist yet: $executable. Run Flutter before activating an antgrid:// URL."
  }

  Write-Host "Registered ${Protocol}:// for this checkout."
  Write-Host "Handler: $expectedCommand"
  return
}

if (-not (Test-Path -LiteralPath $protocolKey)) {
  Write-Host "Protocol '${Protocol}' is not registered; nothing to remove."
  return
}

if (-not (Test-Path -LiteralPath $commandKey)) {
  throw "Refusing to remove ${Protocol}:// because its handler command is missing."
}

$currentCommand = [string](Get-Item -LiteralPath $commandKey).GetValue('')
if (-not [StringComparer]::OrdinalIgnoreCase.Equals($currentCommand, $expectedCommand)) {
  throw @"
Refusing to remove ${Protocol}:// because another executable owns it.
Current:  $currentCommand
Expected: $expectedCommand
"@
}

Remove-Item -LiteralPath $protocolKey -Recurse -Force
Write-Host "Removed ${Protocol}:// handler for this checkout."
Write-Host "Handler: $expectedCommand"
