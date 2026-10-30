function Get-IdsNextVersion {
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Version,
        [string[]]$Labels = @()
    )

    if ($Version -cnotmatch '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$') {
        throw 'VERSION must contain strict MAJOR.MINOR.PATCH before a stable release.'
    }

    $increments = @($Labels | Where-Object { $_ -in 'version:minor', 'version:major' } | Sort-Object -Unique)
    if ($increments.Count -gt 1) {
        throw 'Select only one version label: version:minor or version:major.'
    }

    try {
        [long]$major = $Matches[1]
        [long]$minor = $Matches[2]
        [long]$patch = $Matches[3]
        $increment = $increments | Select-Object -First 1
        if ($increment -ceq 'version:major') {
            if ($major -eq [long]::MaxValue) { throw 'overflow' }
            $major++; $minor = 0; $patch = 0
        } elseif ($increment -ceq 'version:minor') {
            if ($minor -eq [long]::MaxValue) { throw 'overflow' }
            $minor++; $patch = 0
        } else {
            if ($patch -eq [long]::MaxValue) { throw 'overflow' }
            $patch++
        }
    } catch {
        throw 'The VERSION component cannot be incremented without overflowing.'
    }

    return "$major.$minor.$patch"
}

function Test-IdsReleaseDelta {
    [OutputType([bool])]
    param([Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Paths)

    foreach ($path in $Paths) {
        $normalized = ($path -replace '\\', '/').TrimStart('/')
        if ($normalized.StartsWith('./', [StringComparison]::Ordinal)) {
            $normalized = $normalized.Substring(2)
        }
        if ($normalized -match '^(?:[^/]+\.(?:ps1|cmd)|VERSION)$' -or
            $normalized -match '^(?:lib|web|scripts|tests)/' -or
            $normalized -match '^\.github/(?:workflows|actions)/') {
            return $true
        }
    }
    return $false
}

function Get-IdsReleasePlan {
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Before,
        [Parameter(Mandatory)][string]$After,
        [string[]]$Labels = @()
    )

    $rootPath = [IO.Path]::GetFullPath($Root)
    foreach ($sha in @($Before, $After)) {
        if ($sha -cnotmatch '^[0-9a-f]{40}$') {
            throw 'Release boundaries must be full lowercase 40-character commit SHAs.'
        }
        & git -C $rootPath cat-file -e $sha 2>$null
        if ($LASTEXITCODE -ne 0) { throw "Release boundary commit '$sha' is unavailable locally." }
    }

    $beforeVersion = ((& git -C $rootPath show "${Before}:VERSION" 2>$null) -join "`n").Trim()
    if ($LASTEXITCODE -ne 0 -or $beforeVersion -cnotmatch '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$') {
        throw 'The pre-promotion VERSION must contain strict MAJOR.MINOR.PATCH.'
    }
    $afterVersion = ((& git -C $rootPath show "${After}:VERSION" 2>$null) -join "`n").Trim()
    if ($LASTEXITCODE -ne 0 -or $afterVersion -cne $beforeVersion) {
        throw 'The beta-to-main promotion must not change VERSION; only the stable pipeline may increment it.'
    }

    $paths = @(& git -C $rootPath diff --name-only --no-renames $Before $After 2>$null)
    if ($LASTEXITCODE -ne 0) { throw 'Unable to calculate the stable promotion delta.' }
    $required = (Test-IdsReleaseDelta -Paths $paths) -or ($Labels -contains 'release:required')
    $version = if ($required) { Get-IdsNextVersion -Version $beforeVersion -Labels $Labels } else { $beforeVersion }
    return @{
        required       = [bool]$required
        previousVersion = $beforeVersion
        version        = $version
        tag            = "v$version"
        notesPath      = Join-Path $rootPath "docs\releases\v$version.md"
        promotionSha   = $After
    }
}

function Test-IdsReleaseNotes {
    [OutputType([bool])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Content)

    if ([string]::IsNullOrWhiteSpace($Content)) { return $false }
    $requiredHeadings = @(
        'Changes and user-visible effects',
        'Update instructions',
        'Dependencies and runtime',
        'Data implications',
        'Unverified integrations'
    )
    foreach ($heading in $requiredHeadings) {
        $escaped = [regex]::Escape($heading)
        $match = [regex]::Match($Content, "(?ims)^##\s+$escaped\s*$\s*(.*?)(?=^##\s+|\z)")
        if (-not $match.Success -or [string]::IsNullOrWhiteSpace($match.Groups[1].Value)) {
            return $false
        }
    }
    return $true
}
