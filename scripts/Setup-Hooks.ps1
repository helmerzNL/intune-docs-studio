[CmdletBinding()]
param(
    [string]$Root = (Split-Path -Parent $PSScriptRoot)
)

$ErrorActionPreference = 'Stop'
$rootPath = [System.IO.Path]::GetFullPath($Root)
$managedHooksPath = [System.IO.Path]::GetFullPath((Join-Path $rootPath 'tests\hooks'))
$managedHook = Join-Path $managedHooksPath 'pre-commit'

if (-not (Test-Path -LiteralPath $managedHook -PathType Leaf) -or
    -not ((Get-Content -LiteralPath $managedHook -Raw) -match 'Intune Docs Studio managed pre-commit hook')) {
    throw 'The tracked managed hook tests/hooks/pre-commit is missing or unrecognized. Restore it before enabling hook setup.'
}

$gitRoot = & git -C $rootPath rev-parse --show-toplevel 2>$null
if ($LASTEXITCODE -ne 0 -or [System.IO.Path]::GetFullPath(($gitRoot | Select-Object -First 1)) -ne $rootPath) {
    throw "Root '$rootPath' is not the top level of a Git repository. Run this command from the repository root."
}

$configuredPath = & git -C $rootPath config --get core.hooksPath 2>$null
if ($LASTEXITCODE -eq 0) {
    $configuredPath = ($configuredPath | Select-Object -First 1).ToString()
    if ([System.IO.Path]::IsPathRooted($configuredPath)) {
        $effectivePath = [System.IO.Path]::GetFullPath($configuredPath)
    } else {
        $effectivePath = [System.IO.Path]::GetFullPath((Join-Path $rootPath $configuredPath))
    }
    if (-not [string]::Equals($effectivePath, $managedHooksPath, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "A custom hooks path is already configured ('$configuredPath'). No changes were made; integrate the lightweight check manually if desired."
    }
    Write-Host 'The managed lightweight pre-commit hook is already enabled.'
    exit 0
}

$defaultHooksPath = & git -C $rootPath rev-parse --git-path hooks 2>$null
if ($LASTEXITCODE -ne 0) {
    throw "Unable to locate the repository hooks directory. No changes were made."
}
$defaultHooksPath = ($defaultHooksPath | Select-Object -First 1).ToString()
if (-not [System.IO.Path]::IsPathRooted($defaultHooksPath)) {
    $defaultHooksPath = Join-Path $rootPath $defaultHooksPath
}
$defaultHooksPath = [System.IO.Path]::GetFullPath($defaultHooksPath)
if (Test-Path -LiteralPath $defaultHooksPath -PathType Container) {
    $existingHooks = @(Get-ChildItem -LiteralPath $defaultHooksPath -File -Force |
        Where-Object { $_.Name -notlike '*.sample' })
    if ($existingHooks.Count -gt 0) {
        $existingHookPaths = ($existingHooks.FullName -join "', '")
        throw "A hook already exists at '$existingHookPaths'. No changes were made; setting core.hooksPath would bypass existing hooks. Integrate the lightweight check manually to preserve your custom hooks."
    }
}

& git -C $rootPath config --local core.hooksPath 'tests/hooks'
if ($LASTEXITCODE -ne 0) {
    throw 'Git could not enable the managed hook. No changes were made; check repository config permissions.'
}

Write-Host 'Enabled the opt-in lightweight pre-commit policy hook (tests/hooks).'
