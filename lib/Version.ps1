. (Join-Path $PSScriptRoot 'Localization.ps1')

<#
    Version.ps1 - single source of build identity (version, channel, commit).

    A source checkout is a beta build. A packaged build-info.json, when present, is
    authoritative and must agree with VERSION; anything else is an error, never a fallback.
#>

function Get-IdsBuildInfo {
    param([Parameter(Mandatory)][string]$Root)

    $semver = '^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$'
    $versionPath = Join-Path $Root 'VERSION'
    if (-not (Test-Path -LiteralPath $versionPath -PathType Leaf)) {
        throw 'VERSION file is missing; it must contain MAJOR.MINOR.PATCH, for example 0.1.0.'
    }
    $version = [IO.File]::ReadAllText($versionPath).Trim()
    if ($version -notmatch $semver) {
        throw 'VERSION must contain MAJOR.MINOR.PATCH, for example 0.1.0.'
    }

    $metadataPath = Join-Path $Root 'build-info.json'
    if (-not (Test-Path -LiteralPath $metadataPath -PathType Leaf)) {
        return @{ version = $version; channel = 'beta'; commit = 'development' }
    }

    try {
        $metadata = [IO.File]::ReadAllText($metadataPath) | ConvertFrom-Json -AsHashtable -ErrorAction Stop
    } catch {
        throw "build-info.json is not valid JSON: $($_.Exception.Message)"
    }
    if ($metadata -isnot [System.Collections.IDictionary]) { throw 'build-info.json must contain a JSON object.' }
    foreach ($field in 'version', 'channel', 'commit') {
        if ($metadata[$field] -isnot [string] -or -not $metadata[$field]) {
            throw "build-info.json requires a string '$field'."
        }
    }
    if ($metadata.version -notmatch $semver) { throw 'build-info.json version must be MAJOR.MINOR.PATCH.' }
    if ($metadata.version -ne $version) {
        throw "build-info.json version $($metadata.version) does not match VERSION $version."
    }
    if ($metadata.channel -cnotin 'beta', 'stable') { throw "build-info.json channel must be 'beta' or 'stable'." }
    if ($metadata.commit -ceq 'development') {
        if ($metadata.channel -cne 'beta') { throw "A development commit is only valid for beta builds." }
    } elseif ($metadata.commit -cnotmatch '^[0-9a-f]{7,40}$') {
        throw 'build-info.json commit must be a 7-40 character lowercase hex SHA.'
    }

    return @{ version = $version; channel = $metadata.channel; commit = $metadata.commit }
}
