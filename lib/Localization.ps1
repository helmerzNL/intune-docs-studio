# Locale is runspace-local, never part of shared authentication or tenant configuration.
if (-not (Get-Variable -Name IdsLocale -Scope Script -ErrorAction SilentlyContinue)) {
    $script:IdsLocale = 'en-GB'
    $script:IdsLocaleRoot = Split-Path $PSScriptRoot -Parent
    $script:IdsLocaleCatalogs = @{}
}

function Get-IdsSupportedLocales {
    return @('en-GB', 'nl-NL', 'fr-FR', 'de-DE', 'sv-SE', 'es-ES', 'nb-NO', 'pt-PT', 'it-IT', 'da-DK')
}

function Resolve-IdsLocale {
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyString()][string]$Locale, [switch]$Strict)
    if ([string]::IsNullOrEmpty($Locale)) { return 'en-GB' }
    if ($Locale -cin (Get-IdsSupportedLocales)) { return $Locale }
    if ($Strict) { throw [ArgumentException]::new((Get-IdsText 'error.unsupported_locale' -Arguments @{ locale = $Locale } -Locale 'en-GB')) }
    Write-Warning "IDS localization: unsupported locale '$Locale'; using en-GB."
    return 'en-GB'
}

function Get-IdsLocale { return $script:IdsLocale }

function Set-IdsLocale {
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Locale = 'en-GB', [string]$Root)
    $script:IdsLocale = Resolve-IdsLocale $Locale
    if ($Root) {
        $script:IdsLocaleRoot = [IO.Path]::GetFullPath($Root)
        $script:IdsLocaleCatalogs = @{}
    }
}

function Get-IdsLocaleCatalog {
    param([string]$Locale = (Get-IdsLocale))
    $Locale = Resolve-IdsLocale $Locale
    if (-not $script:IdsLocaleCatalogs.ContainsKey($Locale)) {
        $path = Join-Path $script:IdsLocaleRoot "locales\$Locale.json"
        try {
            $catalog = [IO.File]::ReadAllText($path) | ConvertFrom-Json -AsHashtable -ErrorAction Stop
            if ($catalog.server -isnot [Collections.IDictionary]) { throw 'Expected a server dictionary.' }
            $script:IdsLocaleCatalogs[$Locale] = $catalog.server
        } catch {
            Write-Warning "IDS localization: cannot load server catalog '$Locale': $($_.Exception.Message)"
            $script:IdsLocaleCatalogs[$Locale] = @{}
        }
    }
    return $script:IdsLocaleCatalogs[$Locale]
}

function Get-IdsText {
    param(
        [Parameter(Mandatory)][string]$Key,
        [Collections.IDictionary]$Arguments = @{},
        [string]$Locale = (Get-IdsLocale)
    )
    $Locale = Resolve-IdsLocale $Locale
    $catalog = Get-IdsLocaleCatalog $Locale
    if (-not $catalog.Contains($Key) -or $catalog[$Key] -isnot [string] -or [string]::IsNullOrWhiteSpace($catalog[$Key])) {
        Write-Warning "IDS localization: missing server key '$Key' in '$Locale'; using English."
        $catalog = Get-IdsLocaleCatalog 'en-GB'
    }
    if (-not $catalog.Contains($Key) -or $catalog[$Key] -isnot [string] -or [string]::IsNullOrWhiteSpace($catalog[$Key])) {
        Write-Warning "IDS localization: unknown server key '$Key' in English."
        return "[$Key]"
    }
    $culture = [Globalization.CultureInfo]::GetCultureInfo($Locale)
    return [regex]::Replace($catalog[$Key], '\{([A-Za-z][A-Za-z0-9_]*|\d+)(?::([^{}]+))?\}', {
        param($match)
        $name = $match.Groups[1].Value
        if (-not $Arguments.Contains($name)) {
            Write-Warning "IDS localization: missing argument '$name' for '$Key'."
            return $match.Value
        }
        $value = $Arguments[$name]
        $format = if ($match.Groups[2].Success) { $match.Groups[2].Value } else { $null }
        if ($value -is [IFormattable]) { return $value.ToString($format, $culture) }
        return [string]$value
    }.GetNewClosure())
}

function Get-IdsHtmlText {
    param([Parameter(Mandatory)][string]$Key, [Collections.IDictionary]$Arguments = @{}, [string]$Locale = (Get-IdsLocale))
    return [Net.WebUtility]::HtmlEncode((Get-IdsText -Key $Key -Arguments $Arguments -Locale $Locale))
}

function Format-IdsLocaleNumber {
    param([Parameter(Mandatory)]$Value, [string]$Format = 'N0', [string]$Locale = (Get-IdsLocale))
    return $Value.ToString($Format, [Globalization.CultureInfo]::GetCultureInfo((Resolve-IdsLocale $Locale)))
}

function Format-IdsLocaleDate {
    param([Parameter(Mandatory)]$Value, [string]$Format = 'g', [string]$Locale = (Get-IdsLocale))
    return ([datetimeoffset]$Value).ToUniversalTime().ToString($Format, [Globalization.CultureInfo]::GetCultureInfo((Resolve-IdsLocale $Locale)))
}

function Resolve-IdsLocalizedStaticPath {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$Path)
    if ($Path -ceq '/i18n.js') { return Join-Path $Root 'web\i18n.js' }
    if ($Path -cmatch '\A/locales/([a-z]{2}-[A-Z]{2})\.json\z' -and $Matches[1] -cin (Get-IdsSupportedLocales)) {
        return Join-Path $Root "locales\$($Matches[1]).json"
    }
    if ($Path -cmatch '\A/flags/([a-z]{2}-[A-Z]{2})\.svg\z' -and $Matches[1] -cin (Get-IdsSupportedLocales)) {
        return Join-Path $Root "web\flags\$($Matches[1]).svg"
    }
    return $null
}
