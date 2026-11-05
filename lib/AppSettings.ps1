. (Join-Path $PSScriptRoot 'Localization.ps1')

# Application preferences only. Never store tenant data, tokens or customer output here.

function Get-IdsDefaultAppSettings {
    return [ordered]@{ verdictThresholds = [ordered]@{ good = 90; attention = 70; coverage = 80 } }
}

function Get-IdsAppSettingsFields {
    param($InputObject)
    $fields = [ordered]@{}
    if ($InputObject -is [Collections.IDictionary]) {
        foreach ($key in $InputObject.Keys) { $fields[[string]$key] = $InputObject[$key] }
    } elseif ($InputObject -is [Management.Automation.PSCustomObject]) {
        foreach ($property in $InputObject.PSObject.Properties) { $fields[$property.Name] = $property.Value }
    } else {
        throw [ArgumentException]::new((Get-IdsText -Key 'settings.must_be_object'))
    }
    return $fields
}

function Assert-IdsAppSettingsNames {
    param([Collections.IDictionary]$Fields, [string[]]$Allowed)
    foreach ($name in $Fields.Keys) {
        if ($name -cnotin $Allowed) { throw [ArgumentException]::new((Get-IdsText -Key 'settings.unknown_field' -Arguments @{ name = $name })) }
    }
    foreach ($name in $Allowed) {
        if (-not $Fields.Contains($name)) { throw [ArgumentException]::new((Get-IdsText -Key 'settings.missing_field' -Arguments @{ name = $name })) }
    }
}

function ConvertTo-IdsVerdictThresholds {
    param($InputObject)
    $fields = Get-IdsAppSettingsFields $InputObject
    Assert-IdsAppSettingsNames $fields @('good', 'attention', 'coverage')
    $thresholds = [ordered]@{}
    foreach ($name in 'good', 'attention', 'coverage') {
        $value = $fields[$name]
        $integer = $null -ne $value -and $value -isnot [bool] -and [Type]::GetTypeCode($value.GetType()) -in @(
            [TypeCode]::Byte, [TypeCode]::SByte, [TypeCode]::Int16, [TypeCode]::UInt16,
            [TypeCode]::Int32, [TypeCode]::UInt32, [TypeCode]::Int64, [TypeCode]::UInt64)
        if (-not $integer -or $value -lt 0 -or $value -gt 100) {
            throw [ArgumentException]::new((Get-IdsText -Key 'settings.threshold_whole_number' -Arguments @{ name = $name }))
        }
        $thresholds[$name] = [int]$value
    }
    if ($thresholds.attention -ge $thresholds.good) {
        throw [ArgumentException]::new((Get-IdsText -Key 'settings.threshold_order'))
    }
    return $thresholds
}

function ConvertTo-IdsAppSettings {
    param($InputObject)
    $fields = Get-IdsAppSettingsFields $InputObject
    Assert-IdsAppSettingsNames $fields @('verdictThresholds')
    return [ordered]@{ verdictThresholds = (ConvertTo-IdsVerdictThresholds $fields.verdictThresholds) }
}

function Get-IdsAppSettings {
    param([hashtable]$State)
    $path = $State.Config.SettingsPath
    if (-not $path -or -not [IO.File]::Exists($path)) { return Get-IdsDefaultAppSettings }
    try {
        if ([IO.FileInfo]::new($path).Length -gt 64KB) { throw [IO.InvalidDataException]::new() }
        $text = [IO.File]::ReadAllText($path, [Text.UTF8Encoding]::new($false, $true))
        return ConvertTo-IdsAppSettings (ConvertFrom-Json -InputObject $text -AsHashtable -Depth 8)
    } catch {
        Write-Warning (Get-IdsText -Key 'settings.file_ignored')
        return Get-IdsDefaultAppSettings
    }
}

function Set-IdsAppSettings {
    param([hashtable]$State, $Settings)
    $validated = ConvertTo-IdsAppSettings $Settings
    $path = $State.Config.SettingsPath
    if (-not $path) { throw [InvalidOperationException]::new((Get-IdsText -Key 'settings.location_unavailable')) }
    $directory = [IO.Path]::GetDirectoryName($path)
    if ($directory) { $null = [IO.Directory]::CreateDirectory($directory) }
    # Write a sibling temporary file first so an interrupted save never leaves partial JSON.
    $temporary = "$path.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        [IO.File]::WriteAllText($temporary, (ConvertTo-Json -InputObject $validated -Depth 8), [Text.UTF8Encoding]::new($false))
        [IO.File]::Move($temporary, $path, $true)
    } finally {
        if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
    }
    return $validated
}

function Invoke-IdsSettingsRoute {
    param([string]$Method, [string]$Path, [object]$Request, [hashtable]$State)
    $response = [pscustomobject]@{ handled = $true; status = 200; body = $null }
    if ("$Method $Path" -cnotin @('GET /api/settings', 'POST /api/settings')) {
        $response.handled = $false
        return $response
    }
    try {
        if ($Method -ceq 'POST') {
            # Same listener-identity checks as the assessment routes: never trust the request URL.
            $expected = "http://localhost:$($State.Config.Port)"
            if ($Request.Headers['Host'] -cne ([uri]$expected).Authority -or $Request.Headers['Origin'] -cne $expected) {
                $response.status = 403; $response.body = @{ error = (Get-IdsText -Key 'text.same_origin_request_required') }
                return $response
            }
            if ($Request.ContentType -notmatch '^(?i:application/json)(?:\s*;\s*charset\s*=\s*(?i:utf-8))?\s*$') {
                $response.status = 415; $response.body = @{ error = (Get-IdsText -Key 'text.content_type_must_be_application_json_with_utf_8_encoding') }
                return $response
            }
            $body = Read-IdsAssessmentRequestJson $Request 4KB
            $settings = Set-IdsAppSettings -State $State -Settings $body
        } else {
            $settings = Get-IdsAppSettings $State
        }
        $response.body = @{ settings = $settings; defaults = (Get-IdsDefaultAppSettings) }
    } catch [IO.InvalidDataException] {
        $response.status = 413; $response.body = @{ error = $_.Exception.Message }
    } catch [ArgumentException] {
        $response.status = 400; $response.body = @{ error = $_.Exception.Message }
    } catch {
        $response.status = 500; $response.body = @{ error = (Get-IdsText -Key 'settings.save_failed') }
    }
    return $response
}
