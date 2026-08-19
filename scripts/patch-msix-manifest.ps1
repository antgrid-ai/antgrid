<#
.SYNOPSIS
  Declare the bridge binary as a second <Application> in the generated AppxManifest.

.DESCRIPTION
  Windows refuses an external CreateProcess on a packaged binary that the manifest
  does not declare as an <Application> — it fails with ERROR_ACCESS_DENIED even
  though the file's DACL grants execute, and libuv surfaces that as
  "EPERM: uv_spawn". Only the app itself, which holds package identity, can spawn
  an undeclared sibling. Every agent hook config the bridge writes points at
  antgrid-bridge.exe by absolute path (`resolveHookCommand` bakes
  `process.execPath`), so on a Store install every hook for every agent fails to
  launch until the binary is declared here.

  The `msix` package hardcodes exactly one <Application> and its `execution_alias`
  option only ever aliases the main executable, so this runs between `msix:build`
  and `msix:pack` — after the manifest is generated, before it is packed.

  Run against the manifest in the build folder, not inside a packed .msix.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string]$ManifestPath,

  [ValidatePattern('^[A-Za-z0-9._-]+\.exe$')]
  [string]$Executable = 'antgrid-bridge.exe',

  # Part of the AUMID (<PackageFamilyName>!<Id>), so it is append-only —
  # renaming an existing Id breaks pinned tiles and shortcuts.
  [ValidatePattern('^[A-Za-z][A-Za-z0-9]*$')]
  [string]$Id = 'bridge',

  [string]$DisplayName = 'Antgrid Bridge',

  [string]$Description = 'Antgrid agent bridge (background helper).'
)

$ErrorActionPreference = 'Stop'

$resolvedPath = (Resolve-Path -LiteralPath $ManifestPath).Path
$packageRoot = Split-Path -Parent $resolvedPath

# msix packs the build folder as-is. Declaring an executable the folder does not
# contain would pass the build and fail at Store ingestion instead, so catch the
# dropped-bridge case (the reason the pack step passes --build-windows false)
# here, where the error still names the cause.
$executablePath = Join-Path $packageRoot $Executable
if (-not (Test-Path -LiteralPath $executablePath)) {
  throw "Cannot declare '$Executable': it is missing from the package folder $packageRoot"
}

$foundationNs = 'http://schemas.microsoft.com/appx/manifest/foundation/windows10'
$uapNs = 'http://schemas.microsoft.com/appx/manifest/uap/windows10'
$uap5Ns = 'http://schemas.microsoft.com/appx/manifest/uap/windows10/5'
$desktop4Ns = 'http://schemas.microsoft.com/appx/manifest/desktop/windows10/4'
$xmlnsNs = 'http://www.w3.org/2000/xmlns/'

[xml]$manifest = Get-Content -LiteralPath $resolvedPath -Raw

$applications = $manifest.SelectSingleNode("//*[local-name()='Applications']")
if ($null -eq $applications) {
  throw "AppxManifest.xml has no <Applications> element: $resolvedPath"
}

$declared = @($applications.SelectNodes("*[local-name()='Application']"))

if (@($declared | Where-Object { $_.GetAttribute('Executable') -eq $Executable }).Count -gt 0) {
  Write-Host "Already declared, nothing to do: $Executable"
  return
}

if (@($declared | Where-Object { $_.GetAttribute('Id') -eq $Id }).Count -gt 0) {
  throw "Application Id '$Id' is already in use in $resolvedPath"
}

$primary = $declared | Select-Object -First 1
if ($null -eq $primary) {
  throw "AppxManifest.xml declares no <Application> to inherit branding from: $resolvedPath"
}
$primaryVisual = $primary.SelectSingleNode("*[local-name()='VisualElements']")
if ($null -eq $primaryVisual) {
  throw "Primary <Application> has no <uap:VisualElements>: $resolvedPath"
}

$application = $manifest.CreateElement('Application', $foundationNs)
$application.SetAttribute('Id', $Id)
$application.SetAttribute('Executable', $Executable)
$application.SetAttribute('EntryPoint', 'Windows.FullTrustApplication')
# An <Application> is single-instance by default, so an activation while one is
# running is handed to the existing process instead of starting another. Hooks
# fire concurrently across terminals and each invocation is its own short-lived
# process, so the bridge must be multi-instance. The alias below also refuses to
# declare Subsystem without it.
$application.SetAttribute('SupportsMultipleInstances', $desktop4Ns, 'true') | Out-Null

# VisualElements is mandatory even for a hidden entry, and its logos must resolve.
# Inherit them from the primary app rather than hardcoding Images\* paths, so a
# change in how msix names its generated assets cannot silently break packing.
$visual = $manifest.CreateElement('uap', 'VisualElements', $uapNs)
foreach ($attribute in @('BackgroundColor', 'Square150x150Logo', 'Square44x44Logo')) {
  $value = $primaryVisual.GetAttribute($attribute)
  if ([string]::IsNullOrWhiteSpace($value)) {
    throw "Primary <uap:VisualElements> is missing '$attribute', cannot inherit it"
  }
  $visual.SetAttribute($attribute, $value)
}
# NOT hidden with AppListEntry="none", tempting as it is for a background
# helper: Store ingestion rejects a package containing ANY such Application as
# a headless app ("InvalidParameterValue - Package acceptance validation error
# ... specifies a headless app") unless the product carries Microsoft's
# HeadlessAppBypass waiver, and a visible primary Application does not exempt
# it. That rejection lands at submission commit, minutes after a full upload,
# so nothing local catches it. Restore the hide only once the waiver is granted
# for this product (storeops@microsoft.com).
$visual.SetAttribute('DisplayName', $DisplayName)
$visual.SetAttribute('Description', $Description)
$application.AppendChild($visual) | Out-Null

# Declaring the Application is what makes the absolute path in the hook configs
# launchable. The alias is additive: it puts a version-independent name on PATH
# (%LOCALAPPDATA%\Microsoft\WindowsApps), which survives the package-version
# segment changing under a running session on app update. Aliases can be turned
# off by the user, so nothing may depend on the alias alone.
#
# uap5, not the older uap3 + desktop:ExecutionAlias pair: Subsystem is only
# defined on uap5:AppExecutionAlias, and makeappx rejects it on the uap3 one.
# Executable/EntryPoint are omitted deliberately — uap5 inherits both from the
# enclosing <Application>.
$root = $manifest.DocumentElement
if ([string]::IsNullOrEmpty($root.GetAttribute('xmlns:uap5'))) {
  # SetAttribute refuses the xmlns namespace URI, so build the declaration node.
  $uap5Decl = $manifest.CreateAttribute('xmlns', 'uap5', $xmlnsNs)
  $uap5Decl.Value = $uap5Ns
  $root.Attributes.Append($uap5Decl) | Out-Null
}
$ignorable = @($root.GetAttribute('IgnorableNamespaces') -split '\s+' | Where-Object { $_ })
foreach ($prefix in @('uap5', 'desktop4')) {
  if ($ignorable -notcontains $prefix) { $ignorable += $prefix }
}
$root.SetAttribute('IgnorableNamespaces', ($ignorable -join ' '))

$extensions = $manifest.CreateElement('Extensions', $foundationNs)
$extension = $manifest.CreateElement('uap5', 'Extension', $uap5Ns)
$extension.SetAttribute('Category', 'windows.appExecutionAlias')
$aliasContainer = $manifest.CreateElement('uap5', 'AppExecutionAlias', $uap5Ns)
# The bridge is a console app, so the alias must attach to the caller's console
# instead of allocating a new one — otherwise an alias launch loses stdio, which
# is the whole payload of a hook invocation.
$aliasContainer.SetAttribute('Subsystem', $desktop4Ns, 'console') | Out-Null
$alias = $manifest.CreateElement('uap5', 'ExecutionAlias', $uap5Ns)
$alias.SetAttribute('Alias', $Executable)
$aliasContainer.AppendChild($alias) | Out-Null
$extension.AppendChild($aliasContainer) | Out-Null
$extensions.AppendChild($extension) | Out-Null
$application.AppendChild($extensions) | Out-Null

$applications.AppendChild($application) | Out-Null
$manifest.Save($resolvedPath)

Write-Host "Declared '$Executable' as <Application Id=`"$Id`"> with execution alias '$Executable'"
