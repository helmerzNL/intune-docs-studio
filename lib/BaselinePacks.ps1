. (Join-Path $PSScriptRoot 'Localization.ps1')

function Get-IdsAssessmentPropertyCatalog {
    # Graph v1.0 macOSCompliancePolicy defines encoding, not recommended values.
    # https://learn.microsoft.com/en-us/graph/api/resources/intune-deviceconfig-macoscompliancepolicy?view=graph-rest-1.0
    return @{
        'compliance:macOSCompliancePolicy' = @{
            storageRequireEncryption = 'boolean'
            systemIntegrityProtectionEnabled = 'boolean'
            passwordMinimumLength = 'number'
        }
        # Graph resource definitions, reviewed 2026-10-28 (encoding only).
        # https://learn.microsoft.com/en-us/graph/api/resources/intune-deviceconfig-windows10compliancepolicy?view=graph-rest-1.0
        'compliance:windows10CompliancePolicy' = @{
            storageRequireEncryption = 'boolean'
            passwordMinimumLength = 'number'
            passwordRequired = 'boolean'
        }
        # https://learn.microsoft.com/en-us/graph/api/resources/intune-deviceconfig-ioscompliancepolicy?view=graph-rest-1.0
        'compliance:iosCompliancePolicy' = @{
            passcodeRequired = 'boolean'
            passcodeMinimumLength = 'number'
            securityBlockJailbrokenDevices = 'boolean'
        }
        # https://learn.microsoft.com/en-us/graph/api/resources/intune-deviceconfig-androidworkprofilecompliancepolicy?view=graph-rest-1.0
        'compliance:androidWorkProfileCompliancePolicy' = @{
            passwordRequired = 'boolean'
            passwordMinimumLength = 'number'
            storageRequireEncryption = 'boolean'
        }
        # https://learn.microsoft.com/en-us/graph/api/resources/intune-deviceconfig-androiddeviceownercompliancepolicy?view=graph-rest-beta
        'compliance:androidDeviceOwnerCompliancePolicy' = @{
            passwordRequired = 'boolean'
            passwordMinimumLength = 'number'
        }
        # https://learn.microsoft.com/en-us/graph/api/resources/intune-deviceconfig-macosgeneraldeviceconfiguration?view=graph-rest-1.0
        'deviceConfiguration:macOSGeneralDeviceConfiguration' = @{
            passwordRequired = 'boolean'
            passwordMinimumLength = 'number'
            passwordRequiredType = 'string'
            emailInDomainSuffixes = 'stringSet'
        }
        # Graph beta legacy Endpoint Protection profiles; encoding only.
        # https://learn.microsoft.com/en-us/graph/api/resources/intune-deviceconfig-windows10endpointprotectionconfiguration?view=graph-rest-beta
        'deviceConfiguration:windows10EndpointProtectionConfiguration' = @{
            smartScreenEnableInShell = 'boolean'
            smartScreenBlockOverrideForFiles = 'boolean'
        }
        # https://learn.microsoft.com/en-us/graph/api/resources/intune-deviceconfig-macosendpointprotectionconfiguration?view=graph-rest-beta
        'deviceConfiguration:macOSEndpointProtectionConfiguration' = @{
            fileVaultEnabled = 'boolean'
        }
        # Graph v1.0 device restrictions, not a compliance requirement.
        # https://learn.microsoft.com/en-us/graph/api/resources/intune-deviceconfig-iosgeneraldeviceconfiguration?view=graph-rest-1.0
        'deviceConfiguration:iosGeneralDeviceConfiguration' = @{
            passcodeRequired = 'boolean'
        }
    }
}

function ConvertTo-IdsPackNumberKey {
    param([string]$Text)
    $parts = $Text -split '[eE]', 2
    $mantissa = $parts[0]
    $point = $mantissa.IndexOf('.')
    $scale = if ($point -ge 0) { $mantissa.Length - $point - 1 } else { 0 }
    $digits = $mantissa.TrimStart('-').Replace('.', '').TrimStart('0')
    if ($digits.Length -eq 0) { return '0' }
    $significand = $digits.TrimEnd('0')
    $exponent = if ($parts.Length -eq 2) {
        [long]::Parse($parts[1], [Globalization.CultureInfo]::InvariantCulture)
    } else { 0L }
    $exponent += $digits.Length - $significand.Length - $scale
    $sign = if ($mantissa.StartsWith('-')) { '-' } else { '' }
    return "$sign$($significand)e$($exponent.ToString([Globalization.CultureInfo]::InvariantCulture))"
}

function ConvertFrom-IdsPackJsonElement {
    param([System.Text.Json.JsonElement]$Element, [string]$Path = '$')
    switch ($Element.ValueKind.ToString()) {
        Object {
            $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
            $object = [ordered]@{}
            foreach ($member in $Element.EnumerateObject()) {
                if (-not $names.Add($member.Name)) { throw (Get-IdsText -Key 'text.pack_json_duplicate_member_at_arg0' -Arguments @{ arg0 = ($Path) }) }
                if ($member.Name.Length -gt 32768) { throw (Get-IdsText -Key 'text.pack_string_limit_32768_characters_at_arg0' -Arguments @{ arg0 = ($Path) }) }
                $object[$member.Name] = ConvertFrom-IdsPackJsonElement $member.Value "$Path.$($member.Name)"
            }
            return $object
        }
        Array {
            if ($Path -ceq '$.controls' -and $Element.GetArrayLength() -gt 20000) {
                throw (Get-IdsText -Key 'text.pack_control_limit_exceeded_20000_controls')
            }
            $items = [Collections.Generic.List[object]]::new()
            foreach ($item in $Element.EnumerateArray()) {
                $items.Add((ConvertFrom-IdsPackJsonElement $item "$Path[]"))
            }
            return ,($items.ToArray())
        }
        String {
            $text = $Element.GetString()
            if ($text.Length -gt 32768) { throw (Get-IdsText -Key 'text.pack_string_limit_32768_characters_at_arg0' -Arguments @{ arg0 = ($Path) }) }
            return $text
        }
        Number {
            $integer = 0L
            if ($Element.TryGetInt64([ref]$integer)) { return $integer }
            $decimal = [decimal]0
            if ($Element.TryGetDecimal([ref]$decimal) -and $decimal -ne 0) {
                # TryGetDecimal can succeed after rounding, including to a different nonzero value.
                $decimalText = $decimal.ToString('G29', [Globalization.CultureInfo]::InvariantCulture)
                if ((ConvertTo-IdsPackNumberKey $Element.GetRawText()) -ceq (ConvertTo-IdsPackNumberKey $decimalText)) {
                    return $decimal
                }
            }
            $number = $Element.GetDouble()
            if ([double]::IsInfinity($number) -or [double]::IsNaN($number)) {
                throw (Get-IdsText -Key 'text.pack_json_number_must_be_finite_at_arg0' -Arguments @{ arg0 = ($Path) })
            }
            if ($number -eq 0 -and ($Element.GetRawText() -split '[eE]')[0] -match '[1-9]') {
                throw (Get-IdsText -Key 'text.pack_json_number_underflows_the_supported_numeric_range_at_arg0' -Arguments @{ arg0 = ($Path) })
            }
            return $number
        }
        True { return $true }
        False { return $false }
        Null { return $null }
        default { throw (Get-IdsText -Key 'text.unsupported_pack_json_value_at_arg0' -Arguments @{ arg0 = ($Path) }) }
    }
}

function Assert-IdsPackObject {
    param($Value, [string[]]$Fields, [string]$Path)
    if ($Value -isnot [Collections.IDictionary]) { throw (Get-IdsText -Key 'text.pack_arg0_must_be_an_object' -Arguments @{ arg0 = ($Path) }) }
    foreach ($key in $Value.Keys) {
        if ($Fields -cnotcontains $key) { throw (Get-IdsText -Key 'text.pack_arg0_has_an_unknown_field' -Arguments @{ arg0 = ($Path) }) }
    }
    foreach ($field in $Fields) {
        if (@($Value.Keys) -cnotcontains $field) { throw (Get-IdsText -Key 'text.pack_arg0_arg1_is_required' -Arguments @{ arg0 = ($Path); arg1 = ($field) }) }
    }
}

function Assert-IdsPackString {
    param($Value, [string]$Path, [switch]$Nullable, [switch]$AllowEmpty)
    if ($Nullable -and $null -eq $Value) { return }
    if ($Value -isnot [string] -or (-not $AllowEmpty -and [string]::IsNullOrWhiteSpace($Value))) {
        throw (Get-IdsText -Key 'text.pack_arg0_must_be_a_nonempty_string_arg1' -Arguments @{ arg0 = $Path; arg1 = $(if ($Nullable) { Get-IdsText 'fragment.or_null' }) })
    }
}

function Assert-IdsPackEnum {
    param($Value, [string[]]$Values, [string]$Path)
    if ($Value -isnot [string] -or $Values -cnotcontains $Value) { throw (Get-IdsText -Key 'text.pack_arg0_is_unsupported' -Arguments @{ arg0 = ($Path) }) }
}

function Assert-IdsPackArray {
    param($Value, [string]$Path, [switch]$Nonempty)
    if ($Value -isnot [array] -or ($Nonempty -and $Value.Count -eq 0)) { throw (Get-IdsText -Key 'text.pack_arg0_must_be_an_arg1_array' -Arguments @{ arg0 = $Path; arg1 = $(if ($Nonempty) { Get-IdsText 'fragment.nonempty' }) }) }
}

function Assert-IdsPackStringArray {
    param($Value, [string]$Path, [switch]$Nonempty)
    Assert-IdsPackArray $Value $Path -Nonempty:$Nonempty
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($item in $Value) {
        Assert-IdsPackString $item "$Path[]"
        if (-not $seen.Add($item)) { throw (Get-IdsText -Key 'text.pack_arg0_has_duplicate_entries' -Arguments @{ arg0 = ($Path) }) }
    }
}

function Assert-IdsPackExpectedScalar {
    param($Value, [string]$Type, [string]$Path)
    $valid = switch ($Type) {
        boolean { $Value -is [bool] }
        number { $Value -is [long] -or $Value -is [decimal] -or $Value -is [double] }
        string { $Value -is [string] }
        default { $false }
    }
    if (-not $valid) { throw (Get-IdsText -Key 'text.pack_arg0_has_an_invalid_expected_arg1_value' -Arguments @{ arg0 = ($Path); arg1 = ($Type) }) }
}

function Assert-IdsPackMapping {
    param($Mapping, [string]$Path, [hashtable]$Catalog)
    Assert-IdsPackObject $Mapping @(
        'family', 'policyTypes', 'settingId', 'property', 'instancePath',
        'valueType', 'operator', 'expected', 'caseSensitive'
    ) $Path
    Assert-IdsPackEnum $Mapping.family @('settingsCatalog', 'deviceConfiguration', 'compliance', 'admx', 'intent') "$Path.family"
    Assert-IdsPackStringArray $Mapping.policyTypes "$Path.policyTypes" -Nonempty
    Assert-IdsPackString $Mapping.settingId "$Path.settingId" -Nullable
    Assert-IdsPackString $Mapping.property "$Path.property" -Nullable
    Assert-IdsPackString $Mapping.instancePath "$Path.instancePath" -Nullable
    if (($null -eq $Mapping.settingId) -eq ($null -eq $Mapping.property)) {
        throw (Get-IdsText -Key 'text.pack_arg0_must_have_exactly_one_selector_settingid_or_property' -Arguments @{ arg0 = ($Path) })
    }
    Assert-IdsPackEnum $Mapping.valueType @('boolean', 'number', 'string', 'stringSet', 'numberSet') "$Path.valueType"
    if ($null -ne $Mapping.property) {
        foreach ($policyType in $Mapping.policyTypes) {
            $key = "$($Mapping.family):$policyType"
            if (@($Catalog.Keys) -cnotcontains $key -or
                @($Catalog[$key].Keys) -cnotcontains $Mapping.property -or
                $Catalog[$key][$Mapping.property] -cne $Mapping.valueType) {
                throw (Get-IdsText -Key 'text.pack_arg0_property_is_not_allowlisted_with_this_valuetype_for_every_declared_family_policy_type' -Arguments @{ arg0 = ($Path) })
            }
        }
    } elseif ($Mapping.family -cin @('compliance', 'deviceConfiguration')) {
        throw (Get-IdsText -Key 'text.pack_arg0_selector_must_use_an_allowlisted_property_for_this_family' -Arguments @{ arg0 = ($Path) })
    }
    Assert-IdsPackEnum $Mapping.operator @('eq', 'ne', 'gte', 'lte', 'in', 'setEquals', 'containsAll') "$Path.operator"
    if ($Mapping.caseSensitive -isnot [bool]) { throw (Get-IdsText -Key 'text.pack_arg0_casesensitive_must_be_a_boolean' -Arguments @{ arg0 = ($Path) }) }
    $isSet = $Mapping.valueType -cin @('stringSet', 'numberSet')
    if (($Mapping.operator -cin @('gte', 'lte') -and $Mapping.valueType -cne 'number') -or
        ($Mapping.operator -cin @('setEquals', 'containsAll') -and -not $isSet) -or
        ($Mapping.operator -ceq 'in' -and $isSet)) {
        throw (Get-IdsText -Key 'text.pack_arg0_operator_is_incompatible_with_valuetype' -Arguments @{ arg0 = ($Path) })
    }
    if ($isSet -or $Mapping.operator -ceq 'in') {
        Assert-IdsPackArray $Mapping.expected "$Path.expected" -Nonempty:($Mapping.operator -ceq 'in')
        $scalarType = switch ($Mapping.valueType) {
            stringSet { 'string' }
            numberSet { 'number' }
            default { $Mapping.valueType }
        }
        foreach ($value in $Mapping.expected) { Assert-IdsPackExpectedScalar $value $scalarType "$Path.expected[]" }
    } else {
        Assert-IdsPackExpectedScalar $Mapping.expected $Mapping.valueType "$Path.expected"
    }
}

function ConvertTo-IdsPackObject {
    param($Value)
    if ($Value -is [Collections.IDictionary]) {
        $object = [ordered]@{}
        foreach ($key in $Value.Keys) { $object[$key] = ConvertTo-IdsPackObject $Value[$key] }
        return [pscustomobject]$object
    }
    if ($Value -is [array]) {
        return ,@($Value | ForEach-Object { ConvertTo-IdsPackObject $_ })
    }
    return $Value
}

function Test-IdsPackSameAtomicCheck {
    param($First, $Second)
    foreach ($field in @('valueType', 'operator', 'caseSensitive')) {
        if ($First[$field] -cne $Second[$field]) { return $false }
    }
    # Membership and set expectations are unordered; compare in linear rather than quadratic time.
    $comparer = if ($First.caseSensitive) { [StringComparer]::Ordinal } else { [StringComparer]::OrdinalIgnoreCase }
    $sets = @(
        foreach ($mapping in @($First, $Second)) {
            $set = [Collections.Generic.HashSet[string]]::new($comparer)
            foreach ($value in @($mapping.expected)) {
                $key = if ($value -is [decimal]) {
                    $value.ToString('G29', [Globalization.CultureInfo]::InvariantCulture)
                } elseif ($value -is [double]) {
                    $value.ToString('R', [Globalization.CultureInfo]::InvariantCulture)
                } elseif ($value -is [long]) {
                    $value.ToString([Globalization.CultureInfo]::InvariantCulture)
                } else { [string]$value }
                if ($mapping.valueType -cin @('number', 'numberSet')) {
                    $key = ConvertTo-IdsPackNumberKey $key
                }
                [void]$set.Add($key)
            }
            ,$set
        }
    )
    return $sets[0].SetEquals($sets[1])
}

function Assert-IdsPackNoReparsePath {
    param([string]$Path)
    $current = [IO.Path]::GetFullPath($Path)
    while ($current) {
        if (Test-Path -LiteralPath $current -ErrorAction Stop) {
            $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw (Get-IdsText -Key 'text.pack_storage_catalog_paths_must_not_contain_reparse_points')
            }
        }
        $current = [IO.Path]::GetDirectoryName($current)
    }
}

function Read-IdsBaselinePack {
    param([Parameter(Mandatory)][AllowEmptyCollection()][byte[]]$Bytes)
    if ($Bytes.Length -gt 10MB) { throw (Get-IdsText -Key 'text.pack_byte_limit_exceeded_10_mib') }
    $utf8 = [Text.UTF8Encoding]::new($false, $true)
    try { $json = $utf8.GetString($Bytes) } catch { throw (Get-IdsText -Key 'text.pack_must_contain_valid_utf_8_json') }
    $options = [System.Text.Json.JsonDocumentOptions]::new()
    $options.MaxDepth = 32
    try { $document = [System.Text.Json.JsonDocument]::Parse($json, $options) } catch {
        throw (Get-IdsText -Key 'text.pack_json_is_invalid_or_exceeds_the_nesting_limit_32_levels')
    }
    try { $pack = ConvertFrom-IdsPackJsonElement $document.RootElement } finally { $document.Dispose() }
    Assert-IdsPackObject $pack @(
        'schemaVersion', 'id', 'version', 'framework', 'frameworkVersion', 'classification',
        'platform', 'profile', 'sourceRevision', 'sources', 'coverage', 'controls'
    ) '$'
    if ($pack.schemaVersion -isnot [long] -or $pack.schemaVersion -ne 1) { throw (Get-IdsText -Key 'text.pack_schemaversion_must_be_integer_1') }
    Assert-IdsPackString $pack.id '$.id'
    if ($pack.id -cnotmatch '\A[a-z][a-z0-9.-]{0,127}\z') { throw (Get-IdsText -Key 'text.pack_id_must_match_a_z_a_z0_9_0_127') }
    Assert-IdsPackString $pack.version '$.version'
    $numeric = '(0|[1-9][0-9]*)'
    $pre = '(0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*)'
    if ($pack.version -cnotmatch "\A$numeric\.$numeric\.$numeric(-$pre(\.$pre)*)?(\+[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?\z") {
        throw (Get-IdsText -Key 'text.pack_version_must_be_a_semantic_version_without_or')
    }
    foreach ($field in @('framework', 'frameworkVersion', 'profile', 'sourceRevision')) {
        Assert-IdsPackString $pack[$field] "`$.$field"
    }
    Assert-IdsPackEnum $pack.classification @('baseline', 'recommendations') '$.classification'
    Assert-IdsPackEnum $pack.platform @('windows11', 'macos', 'iosIpados', 'androidEnterprise') '$.platform'
    Assert-IdsPackArray $pack.sources '$.sources' -Nonempty
    $sourceIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($source in $pack.sources) {
        Assert-IdsPackObject $source @('id', 'url', 'revision', 'retrievedOn') '$.sources[]'
        foreach ($field in @('id', 'url', 'revision', 'retrievedOn')) { Assert-IdsPackString $source[$field] "`$.sources[].$field" }
        if (-not $sourceIds.Add($source.id)) { throw (Get-IdsText -Key 'text.pack_duplicate_source_id_in_sources') }
        $uri = $null
        if (-not [uri]::TryCreate($source.url, [UriKind]::Absolute, [ref]$uri) -or
            $uri.Scheme -cnotin @('http', 'https') -or -not $uri.Host -or $uri.UserInfo) {
            throw (Get-IdsText -Key 'text.pack_sources_url_must_be_an_absolute_http_s_reference_without_credentials')
        }
        $date = [datetime]::MinValue
        if (-not [datetime]::TryParseExact($source.retrievedOn, 'yyyy-MM-dd',
            [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$date)) {
            throw (Get-IdsText -Key 'text.pack_sources_retrievedon_must_be_a_valid_yyyy_mm_dd_date')
        }
    }
    Assert-IdsPackArray $pack.controls '$.controls' -Nonempty
    if ($pack.controls.Count -gt 20000) { throw (Get-IdsText -Key 'text.pack_control_limit_exceeded_20000_controls') }
    Assert-IdsPackObject $pack.coverage @('inventory', 'totalSourceControls') '$.coverage'
    Assert-IdsPackEnum $pack.coverage.inventory @('complete', 'partial') '$.coverage.inventory'
    $total = $pack.coverage.totalSourceControls
    if (($null -ne $total -and ($total -isnot [long] -or $total -lt $pack.controls.Count)) -or
        ($pack.coverage.inventory -ceq 'complete' -and ($null -eq $total -or $total -ne $pack.controls.Count))) {
        throw (Get-IdsText -Key 'text.pack_coverage_totalsourcecontrols_must_be_an_integer_at_least_the_listed_count_complete_requires_the')
    }
    $controlIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $catalog = Get-IdsAssessmentPropertyCatalog
    foreach ($control in $pack.controls) {
        $path = '$.controls[]'
        Assert-IdsPackObject $control @('id', 'title', 'sourceIds', 'reference', 'applicability', 'manualReason', 'mappings') $path
        foreach ($field in @('id', 'title', 'reference')) { Assert-IdsPackString $control[$field] "$path.$field" }
        if (-not $controlIds.Add($control.id)) { throw (Get-IdsText -Key 'text.pack_duplicate_control_id_in_controls') }
        Assert-IdsPackStringArray $control.sourceIds "$path.sourceIds" -Nonempty
        foreach ($sourceId in $control.sourceIds) {
            if (-not $sourceIds.Contains($sourceId)) { throw (Get-IdsText -Key 'text.pack_arg0_sourceids_references_an_unknown_source' -Arguments @{ arg0 = ($path) }) }
        }
        Assert-IdsPackObject $control.applicability @('osMin', 'osMax', 'enrollmentModes') "$path.applicability"
        $versions = @{}
        foreach ($bound in @('osMin', 'osMax')) {
            $value = $control.applicability[$bound]
            Assert-IdsPackString $value "$path.applicability.$bound" -Nullable
            if ($null -ne $value) {
                if ($value -notmatch '\A[0-9]+(\.[0-9]+){0,3}\z') { throw (Get-IdsText -Key 'text.pack_arg0_applicability_arg1_must_be_a_numeric_os_version' -Arguments @{ arg0 = ($path); arg1 = ($bound) }) }
                $parts = @($value.Split('.'))
                while ($parts.Count -lt 4) { $parts += '0' }
                $version = $null
                if (-not [version]::TryParse(($parts -join '.'), [ref]$version)) { throw (Get-IdsText -Key 'text.pack_arg0_applicability_arg1_is_invalid' -Arguments @{ arg0 = ($path); arg1 = ($bound) }) }
                $versions[$bound] = $version
            }
        }
        if ($versions.ContainsKey('osMin') -and $versions.ContainsKey('osMax') -and $versions.osMin -gt $versions.osMax) {
            throw (Get-IdsText -Key 'text.pack_arg0_applicability_osmax_must_not_precede_osmin' -Arguments @{ arg0 = ($path) })
        }
        Assert-IdsPackStringArray $control.applicability.enrollmentModes "$path.applicability.enrollmentModes"
        Assert-IdsPackArray $control.mappings "$path.mappings"
        Assert-IdsPackString $control.manualReason "$path.manualReason" -Nullable
        if (($control.mappings.Count -eq 0) -eq ($null -eq $control.manualReason)) {
            throw (Get-IdsText -Key 'text.pack_arg0_manualreason_must_be_nonempty_exactly_when_mappings_is_empty' -Arguments @{ arg0 = ($path) })
        }
        foreach ($mapping in $control.mappings) { Assert-IdsPackMapping $mapping "$path.mappings[]" $catalog }
        for ($index = 1; $index -lt $control.mappings.Count; $index++) {
            if (-not (Test-IdsPackSameAtomicCheck $control.mappings[0] $control.mappings[$index])) {
                throw (Get-IdsText -Key 'text.pack_arg0_mappings_must_describe_alternatives_for_the_same_atomic_check' -Arguments @{ arg0 = ($path) })
            }
        }
    }
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $hash = ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant()
    } finally { $sha.Dispose() }
    $result = ConvertTo-IdsPackObject $pack
    $result | Add-Member -NotePropertyName sha256 -NotePropertyValue $hash
    return $result
}

function Get-IdsBaselinePacks {
    param([Parameter(Mandatory)][string]$BundledRoot, [Parameter(Mandatory)][string]$ImportedRoot)
    $packs = [Collections.Generic.List[object]]::new()
    $errors = [Collections.Generic.List[object]]::new()
    foreach ($location in @(
        @{ root = $BundledRoot; origin = 'bundled' },
        @{ root = $ImportedRoot; origin = 'imported' }
    )) {
        try {
            Assert-IdsPackNoReparsePath $location.root
            if (-not (Test-Path -LiteralPath $location.root -ErrorAction Stop)) { continue }
            if (-not (Test-Path -LiteralPath $location.root -PathType Container -ErrorAction Stop)) { throw (Get-IdsText -Key 'text.catalog_root_must_be_a_directory') }
            $files = @(Get-ChildItem -LiteralPath $location.root -File -Filter '*.json' -Force -ErrorAction Stop | Sort-Object Name)
            foreach ($file in $files) {
                try {
                    if ($file.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw (Get-IdsText -Key 'text.pack_catalog_entries_must_not_be_reparse_points') }
                    if ($file.Length -gt 10MB) { throw (Get-IdsText -Key 'text.pack_byte_limit_exceeded_10_mib') }
                    $pack = Read-IdsBaselinePack -Bytes ([IO.File]::ReadAllBytes($file.FullName))
                    $pack | Add-Member -NotePropertyName origin -NotePropertyValue $location.origin
                    $pack | Add-Member -NotePropertyName path -NotePropertyValue $file.FullName
                    $packs.Add($pack)
                } catch {
                    $errors.Add([pscustomobject]@{ origin = $location.origin; path = $file.FullName; reason = $_.Exception.Message })
                }
            }
        } catch {
            $errors.Add([pscustomobject]@{ origin = $location.origin; path = $location.root; reason = $_.Exception.Message })
        }
    }
    $conflicts = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $identities = [Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal)
    foreach ($pack in $packs) {
        $identity = "$($pack.id)@$($pack.version)"
        if ($identities.ContainsKey($identity) -and $identities[$identity] -cne $pack.sha256) { [void]$conflicts.Add($identity) }
        $identities[$identity] = $pack.sha256
    }
    $valid = @(
        foreach ($pack in $packs) {
            if ($conflicts.Contains("$($pack.id)@$($pack.version)")) {
                $errors.Add([pscustomobject]@{ origin = $pack.origin; path = $pack.path; reason = (Get-IdsText -Key 'text.catalog_id_version_has_different_bytes') })
            } else { $pack }
        }
    )
    return [pscustomobject]@{ packs = $valid; errors = $errors.ToArray() }
}

function Import-IdsBaselinePackSet {
    param(
        [Parameter(Mandatory)][byte[][]]$Packs,
        [Parameter(Mandatory)][string]$ImportedRoot
    )
    $candidates = [Collections.Generic.List[object]]::new()
    $identities = [Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal)
    foreach ($bytes in $Packs) {
        $pack = Read-IdsBaselinePack -Bytes $bytes
        $identity = "$($pack.id)@$($pack.version)"
        if ($identities.ContainsKey($identity)) {
            if ($identities[$identity] -cne $pack.sha256) { throw (Get-IdsText -Key 'text.pack_set_contains_different_packs_with_the_same_id_version_arg0' -Arguments @{ arg0 = ($identity) }) }
            continue
        }
        $identities[$identity] = $pack.sha256
        $candidates.Add([pscustomobject]@{ pack = $pack; bytes = $bytes; added = $true })
    }
    if (-not [IO.Path]::IsPathFullyQualified($ImportedRoot)) { throw (Get-IdsText -Key 'text.importedroot_must_be_an_absolute_filesystem_path_outside_the_installation_and_source_tree') }
    $root = [IO.Path]::GetFullPath($ImportedRoot)
    Assert-IdsPackNoReparsePath $root
    $installation = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
    $separator = [IO.Path]::DirectorySeparatorChar
    $rootPrefix = $root.TrimEnd($separator) + $separator
    $installationPrefix = $installation.TrimEnd($separator) + $separator
    if ($rootPrefix.StartsWith($installationPrefix, [StringComparison]::OrdinalIgnoreCase) -or
        $installationPrefix.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw (Get-IdsText -Key 'text.importedroot_must_not_overlap_the_application_installation_source_tree')
    }
    [void][IO.Directory]::CreateDirectory($root)
    # Serialize writers in this directory; staged files are never catalog entries.
    $lockPath = Join-Path $root '.import.lock'
    $lock = $null
    $staged = $null
    try {
        $lock = [IO.FileStream]::new($lockPath, [IO.FileMode]::OpenOrCreate,
            [IO.FileAccess]::Write, [IO.FileShare]::None, 4096, [IO.FileOptions]::DeleteOnClose)
        $catalog = Get-IdsBaselinePacks -BundledRoot (Join-Path $root '.unused-bundled') -ImportedRoot $root
        if ($catalog.errors.Count -gt 0) { throw (Get-IdsText -Key 'text.imported_catalog_has_invalid_or_conflicting_entries_repair_them_before_importing') }
        # Check every pack before the first write so a conflict leaves the catalog untouched.
        foreach ($candidate in $candidates) {
            foreach ($existing in $catalog.packs) {
                if ($existing.id -ceq $candidate.pack.id -and $existing.version -ceq $candidate.pack.version) {
                    if ($existing.sha256 -cne $candidate.pack.sha256) { throw (Get-IdsText -Key 'text.imported_pack_id_version_already_exists_with_different_bytes') }
                    $candidate.added = $false
                }
            }
        }
        foreach ($candidate in $candidates) {
            if (-not $candidate.added) { continue }
            $target = Join-Path $root "$($candidate.pack.sha256).json"
            $staged = Join-Path $root ('.stage-' + [guid]::NewGuid().ToString('N'))
            [IO.File]::WriteAllBytes($staged, $candidate.bytes)
            [IO.File]::Move($staged, $target)
        }
        return @(foreach ($candidate in $candidates) { [pscustomobject]@{ pack = $candidate.pack; added = $candidate.added } })
    } finally {
        try {
            if ($staged -and [IO.File]::Exists($staged)) { [IO.File]::Delete($staged) }
        } finally {
            if ($lock) { $lock.Dispose() }
        }
    }
}

function Import-IdsBaselinePack {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][byte[]]$Bytes,
        [Parameter(Mandatory)][string]$ImportedRoot
    )
    return @(Import-IdsBaselinePackSet -Packs @(, $Bytes) -ImportedRoot $ImportedRoot)[0].pack
}
