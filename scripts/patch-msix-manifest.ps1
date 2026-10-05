<#
.SYNOPSIS
  Declare the bridge binary as a second <Application> in the generated AppxManifest,
  and give every packaged executable an inbound UDP firewall rule.

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

  Both the app and the bridge open an Iroh endpoint, which binds UDP on every
  interface. With no rule for the binary, Windows Defender Firewall prompts on
  that first bind and records the answer against the exe's full path — and a
  package's install folder carries its version, so every update would prompt
  again for each binary. A package-declared rule is installed with the package
  and survives updates, so the prompt never appears.

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
$desktop2Ns = 'http://schemas.microsoft.com/appx/manifest/desktop/windows10/2'
$desktop4Ns = 'http://schemas.microsoft.com/appx/manifest/desktop/windows10/4'
$xmlnsNs = 'http://www.w3.org/2000/xmlns/'

[xml]$manifest = Get-Content -LiteralPath $resolvedPath -Raw

$applications = $manifest.SelectSingleNode("//*[local-name()='Applications']")
if ($null -eq $applications) {
  throw "AppxManifest.xml has no <Applications> element: $resolvedPath"
}

$root = $manifest.DocumentElement

function Use-ManifestNamespace([string]$Prefix, [string]$Uri) {
  if ([string]::IsNullOrEmpty($root.GetAttribute("xmlns:$Prefix"))) {
    # SetAttribute refuses the xmlns namespace URI, so build the declaration node.
    $declaration = $manifest.CreateAttribute('xmlns', $Prefix, $xmlnsNs)
    $declaration.Value = $Uri
    $root.Attributes.Append($declaration) | Out-Null
  }
  $ignorable = @($root.GetAttribute('IgnorableNamespaces') -split '\s+' | Where-Object { $_ })
  if ($ignorable -notcontains $Prefix) {
    $root.SetAttribute('IgnorableNamespaces', (($ignorable + $Prefix) -join ' '))
  }
}

# Every declared executable gets a rule rather than a named list, so a binary
# added to the package later cannot reintroduce the prompt; a rule for an exe
# that never listens is inert. Returns whether the manifest changed.
function Add-FirewallRules {
  $executables = @(
    $applications.SelectNodes("*[local-name()='Application']") |
      ForEach-Object { $_.GetAttribute('Executable') }
  )
  # Only an inbound UDP rule counts as coverage, matching what
  # verify-msix-executables.ps1 asserts; any other rule for the exe leaves the
  # Iroh bind prompting.
  $covered = @(
    $manifest.SelectNodes("//*[local-name()='FirewallRules']") |
      Where-Object {
        $_.SelectNodes("*[local-name()='Rule' and @Direction='in' and @IPProtocol='UDP']").Count -gt 0
      } |
      ForEach-Object { $_.GetAttribute('Executable') }
  )
  $missing = @($executables | Where-Object { $covered -notcontains $_ })
  if ($missing.Count -eq 0) { return $false }

  Use-ManifestNamespace 'desktop2' $desktop2Ns

  # Package-level, not inside an <Application>: windows.firewallRules is only
  # valid as a package extension.
  $packageExtensions = $root.SelectSingleNode("*[local-name()='Extensions']")
  if ($null -eq $packageExtensions) {
    $packageExtensions = $manifest.CreateElement('Extensions', $foundationNs)
    $root.InsertAfter($packageExtensions, $applications) | Out-Null
  }

  foreach ($name in $missing) {
    $extension = $manifest.CreateElement('desktop2', 'Extension', $desktop2Ns)
    $extension.SetAttribute('Category', 'windows.firewallRules')
    $rules = $manifest.CreateElement('desktop2', 'FirewallRules', $desktop2Ns)
    $rules.SetAttribute('Executable', $name)
    $rule = $manifest.CreateElement('desktop2', 'Rule', $desktop2Ns)
    $rule.SetAttribute('Direction', 'in')
    # Iroh's QUIC transport is UDP only, on an OS-assigned port, so the rule
    # names a protocol and no port range.
    $rule.SetAttribute('IPProtocol', 'UDP')
    # Not just private: a laptop running the app or bridge joins public
    # networks too, and the endpoint completes a session only with endpoint IDs
    # its authorization snapshot names.
    $rule.SetAttribute('Profile', 'all')
    $rules.AppendChild($rule) | Out-Null
    $extension.AppendChild($rules) | Out-Null
    $packageExtensions.AppendChild($extension) | Out-Null
    Write-Host "Declared inbound UDP firewall rule for '$name'"
  }
  return $true
}

$declared = @($applications.SelectNodes("*[local-name()='Application']"))

if (@($declared | Where-Object { $_.GetAttribute('Executable') -eq $Executable }).Count -gt 0) {
  # A manifest patched before the firewall rules existed still needs them.
  if (Add-FirewallRules) { $manifest.Save($resolvedPath) }
  Write-Host "Already declared: $Executable"
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
Use-ManifestNamespace 'uap5' $uap5Ns
Use-ManifestNamespace 'desktop4' $desktop4Ns

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
Add-FirewallRules | Out-Null
$manifest.Save($resolvedPath)

Write-Host "Declared '$Executable' as <Application Id=`"$Id`"> with execution alias '$Executable'"
