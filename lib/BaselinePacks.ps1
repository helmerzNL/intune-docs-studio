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
                if (-not $names.Add($member.Name)) { throw "Pack JSON duplicate member at $Path." }
                if ($member.Name.Length -gt 32768) { throw "Pack string limit (32768 characters) at $Path." }
                $object[$member.Name] = ConvertFrom-IdsPackJsonElement $member.Value "$Path.$($member.Name)"
            }
            return $object
        }
        Array {
            if ($Path -ceq '$.controls' -and $Element.GetArrayLength() -gt 20000) {
                throw 'Pack control limit exceeded (20000 controls).'
            }
            $items = [Collections.Generic.List[object]]::new()
            foreach ($item in $Element.EnumerateArray()) {
                $items.Add((ConvertFrom-IdsPackJsonElement $item "$Path[]"))
            }
            return ,($items.ToArray())
        }
        String {
            $text = $Element.GetString()
            if ($text.Length -gt 32768) { throw "Pack string limit (32768 characters) at $Path." }
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
                throw "Pack JSON number must be finite at $Path."
            }
            if ($number -eq 0 -and ($Element.GetRawText() -split '[eE]')[0] -match '[1-9]') {
                throw "Pack JSON number underflows the supported numeric range at $Path."
            }
            return $number
        }
        True { return $true }
        False { return $false }
        Null { return $null }
        default { throw "Unsupported pack JSON value at $Path." }
    }
}

function Assert-IdsPackObject {
    param($Value, [string[]]$Fields, [string]$Path)
    if ($Value -isnot [Collections.IDictionary]) { throw "Pack $Path must be an object." }
    foreach ($key in $Value.Keys) {
        if ($Fields -cnotcontains $key) { throw "Pack $Path has an unknown field." }
    }
    foreach ($field in $Fields) {
        if (@($Value.Keys) -cnotcontains $field) { throw "Pack $Path.$field is required." }
    }
}

function Assert-IdsPackString {
    param($Value, [string]$Path, [switch]$Nullable, [switch]$AllowEmpty)
    if ($Nullable -and $null -eq $Value) { return }
    if ($Value -isnot [string] -or (-not $AllowEmpty -and [string]::IsNullOrWhiteSpace($Value))) {
        throw "Pack $Path must be a nonempty string$(if ($Nullable) { ' or null' })."
    }
}

function Assert-IdsPackEnum {
    param($Value, [string[]]$Values, [string]$Path)
    if ($Value -isnot [string] -or $Values -cnotcontains $Value) { throw "Pack $Path is unsupported." }
}

function Assert-IdsPackArray {
    param($Value, [string]$Path, [switch]$Nonempty)
    if ($Value -isnot [array] -or ($Nonempty -and $Value.Count -eq 0)) { throw "Pack $Path must be an$(if ($Nonempty) { ' nonempty' }) array." }
}

function Assert-IdsPackStringArray {
    param($Value, [string]$Path, [switch]$Nonempty)
    Assert-IdsPackArray $Value $Path -Nonempty:$Nonempty
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($item in $Value) {
        Assert-IdsPackString $item "$Path[]"
        if (-not $seen.Add($item)) { throw "Pack $Path has duplicate entries." }
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
    if (-not $valid) { throw "Pack $Path has an invalid expected $Type value." }
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
        throw "Pack $Path must have exactly one selector: settingId or property."
    }
    Assert-IdsPackEnum $Mapping.valueType @('boolean', 'number', 'string', 'stringSet', 'numberSet') "$Path.valueType"
    if ($null -ne $Mapping.property) {
        foreach ($policyType in $Mapping.policyTypes) {
            $key = "$($Mapping.family):$policyType"
            if (@($Catalog.Keys) -cnotcontains $key -or
                @($Catalog[$key].Keys) -cnotcontains $Mapping.property -or
                $Catalog[$key][$Mapping.property] -cne $Mapping.valueType) {
                throw "Pack $Path.property is not allowlisted with this valueType for every declared family/policy type."
            }
        }
    } elseif ($Mapping.family -cin @('compliance', 'deviceConfiguration')) {
        throw "Pack $Path selector must use an allowlisted property for this family."
    }
    Assert-IdsPackEnum $Mapping.operator @('eq', 'ne', 'gte', 'lte', 'in', 'setEquals', 'containsAll') "$Path.operator"
    if ($Mapping.caseSensitive -isnot [bool]) { throw "Pack $Path.caseSensitive must be a boolean." }
    $isSet = $Mapping.valueType -cin @('stringSet', 'numberSet')
    if (($Mapping.operator -cin @('gte', 'lte') -and $Mapping.valueType -cne 'number') -or
        ($Mapping.operator -cin @('setEquals', 'containsAll') -and -not $isSet) -or
        ($Mapping.operator -ceq 'in' -and $isSet)) {
        throw "Pack $Path.operator is incompatible with valueType."
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
                throw 'Pack storage/catalog paths must not contain reparse points.'
            }
        }
        $current = [IO.Path]::GetDirectoryName($current)
    }
}

function Read-IdsBaselinePack {
    param([Parameter(Mandatory)][AllowEmptyCollection()][byte[]]$Bytes)
    if ($Bytes.Length -gt 10MB) { throw 'Pack byte limit exceeded (10 MiB).' }
    $utf8 = [Text.UTF8Encoding]::new($false, $true)
    try { $json = $utf8.GetString($Bytes) } catch { throw 'Pack must contain valid UTF-8 JSON.' }
    $options = [System.Text.Json.JsonDocumentOptions]::new()
    $options.MaxDepth = 32
    try { $document = [System.Text.Json.JsonDocument]::Parse($json, $options) } catch {
        throw 'Pack JSON is invalid or exceeds the nesting limit (32 levels).'
    }
    try { $pack = ConvertFrom-IdsPackJsonElement $document.RootElement } finally { $document.Dispose() }
    Assert-IdsPackObject $pack @(
        'schemaVersion', 'id', 'version', 'framework', 'frameworkVersion', 'classification',
        'platform', 'profile', 'sourceRevision', 'sources', 'coverage', 'controls'
    ) '$'
    if ($pack.schemaVersion -isnot [long] -or $pack.schemaVersion -ne 1) { throw 'Pack $.schemaVersion must be integer 1.' }
    Assert-IdsPackString $pack.id '$.id'
    if ($pack.id -cnotmatch '\A[a-z][a-z0-9.-]{0,127}\z') { throw 'Pack $.id must match [a-z][a-z0-9.-]{0,127}.' }
    Assert-IdsPackString $pack.version '$.version'
    $numeric = '(0|[1-9][0-9]*)'
    $pre = '(0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*)'
    if ($pack.version -cnotmatch "\A$numeric\.$numeric\.$numeric(-$pre(\.$pre)*)?(\+[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?\z") {
        throw 'Pack $.version must be a semantic version without @ or #.'
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
        if (-not $sourceIds.Add($source.id)) { throw 'Pack duplicate source id in $.sources.' }
        $uri = $null
        if (-not [uri]::TryCreate($source.url, [UriKind]::Absolute, [ref]$uri) -or
            $uri.Scheme -cnotin @('http', 'https') -or -not $uri.Host -or $uri.UserInfo) {
            throw 'Pack $.sources[].url must be an absolute HTTP(S) reference without credentials.'
        }
        $date = [datetime]::MinValue
        if (-not [datetime]::TryParseExact($source.retrievedOn, 'yyyy-MM-dd',
            [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$date)) {
            throw 'Pack $.sources[].retrievedOn must be a valid yyyy-MM-dd date.'
        }
    }
    Assert-IdsPackArray $pack.controls '$.controls' -Nonempty
    if ($pack.controls.Count -gt 20000) { throw 'Pack control limit exceeded (20000 controls).' }
    Assert-IdsPackObject $pack.coverage @('inventory', 'totalSourceControls') '$.coverage'
    Assert-IdsPackEnum $pack.coverage.inventory @('complete', 'partial') '$.coverage.inventory'
    $total = $pack.coverage.totalSourceControls
    if (($null -ne $total -and ($total -isnot [long] -or $total -lt $pack.controls.Count)) -or
        ($pack.coverage.inventory -ceq 'complete' -and ($null -eq $total -or $total -ne $pack.controls.Count))) {
        throw 'Pack $.coverage.totalSourceControls must be an integer at least the listed count; complete requires the exact count.'
    }
    $controlIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $catalog = Get-IdsAssessmentPropertyCatalog
    foreach ($control in $pack.controls) {
        $path = '$.controls[]'
        Assert-IdsPackObject $control @('id', 'title', 'sourceIds', 'reference', 'applicability', 'manualReason', 'mappings') $path
        foreach ($field in @('id', 'title', 'reference')) { Assert-IdsPackString $control[$field] "$path.$field" }
        if (-not $controlIds.Add($control.id)) { throw 'Pack duplicate control id in $.controls.' }
        Assert-IdsPackStringArray $control.sourceIds "$path.sourceIds" -Nonempty
        foreach ($sourceId in $control.sourceIds) {
            if (-not $sourceIds.Contains($sourceId)) { throw "Pack $path.sourceIds references an unknown source." }
        }
        Assert-IdsPackObject $control.applicability @('osMin', 'osMax', 'enrollmentModes') "$path.applicability"
        $versions = @{}
        foreach ($bound in @('osMin', 'osMax')) {
            $value = $control.applicability[$bound]
            Assert-IdsPackString $value "$path.applicability.$bound" -Nullable
            if ($null -ne $value) {
                if ($value -notmatch '\A[0-9]+(\.[0-9]+){0,3}\z') { throw "Pack $path.applicability.$bound must be a numeric OS version." }
                $parts = @($value.Split('.'))
                while ($parts.Count -lt 4) { $parts += '0' }
                $version = $null
                if (-not [version]::TryParse(($parts -join '.'), [ref]$version)) { throw "Pack $path.applicability.$bound is invalid." }
                $versions[$bound] = $version
            }
        }
        if ($versions.ContainsKey('osMin') -and $versions.ContainsKey('osMax') -and $versions.osMin -gt $versions.osMax) {
            throw "Pack $path.applicability.osMax must not precede osMin."
        }
        Assert-IdsPackStringArray $control.applicability.enrollmentModes "$path.applicability.enrollmentModes"
        Assert-IdsPackArray $control.mappings "$path.mappings"
        Assert-IdsPackString $control.manualReason "$path.manualReason" -Nullable
        if (($control.mappings.Count -eq 0) -eq ($null -eq $control.manualReason)) {
            throw "Pack $path.manualReason must be nonempty exactly when mappings is empty."
        }
        foreach ($mapping in $control.mappings) { Assert-IdsPackMapping $mapping "$path.mappings[]" $catalog }
        for ($index = 1; $index -lt $control.mappings.Count; $index++) {
            if (-not (Test-IdsPackSameAtomicCheck $control.mappings[0] $control.mappings[$index])) {
                throw "Pack $path.mappings must describe alternatives for the same atomic check."
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
            if (-not (Test-Path -LiteralPath $location.root -PathType Container -ErrorAction Stop)) { throw 'Catalog root must be a directory.' }
            $files = @(Get-ChildItem -LiteralPath $location.root -File -Filter '*.json' -Force -ErrorAction Stop | Sort-Object Name)
            foreach ($file in $files) {
                try {
                    if ($file.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Pack catalog entries must not be reparse points.' }
                    if ($file.Length -gt 10MB) { throw 'Pack byte limit exceeded (10 MiB).' }
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
                $errors.Add([pscustomobject]@{ origin = $pack.origin; path = $pack.path; reason = 'Catalog ID/version has different bytes.' })
            } else { $pack }
        }
    )
    return [pscustomobject]@{ packs = $valid; errors = $errors.ToArray() }
}

function Import-IdsBaselinePack {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][byte[]]$Bytes,
        [Parameter(Mandatory)][string]$ImportedRoot
    )
    $pack = Read-IdsBaselinePack -Bytes $Bytes
    if (-not [IO.Path]::IsPathFullyQualified($ImportedRoot)) { throw 'ImportedRoot must be an absolute filesystem path outside the installation and source tree.' }
    $root = [IO.Path]::GetFullPath($ImportedRoot)
    Assert-IdsPackNoReparsePath $root
    $installation = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
    $separator = [IO.Path]::DirectorySeparatorChar
    $rootPrefix = $root.TrimEnd($separator) + $separator
    $installationPrefix = $installation.TrimEnd($separator) + $separator
    if ($rootPrefix.StartsWith($installationPrefix, [StringComparison]::OrdinalIgnoreCase) -or
        $installationPrefix.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'ImportedRoot must not overlap the application installation/source tree.'
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
        if ($catalog.errors.Count -gt 0) { throw 'Imported catalog has invalid or conflicting entries; repair them before importing.' }
        foreach ($existing in $catalog.packs) {
            if ($existing.id -ceq $pack.id -and $existing.version -ceq $pack.version) {
                if ($existing.sha256 -cne $pack.sha256) { throw 'Imported pack ID/version already exists with different bytes.' }
                return $pack
            }
        }
        $target = Join-Path $root "$($pack.sha256).json"
        $staged = Join-Path $root ('.stage-' + [guid]::NewGuid().ToString('N'))
        [IO.File]::WriteAllBytes($staged, $Bytes)
        [IO.File]::Move($staged, $target)
        return $pack
    } finally {
        try {
            if ($staged -and [IO.File]::Exists($staged)) { [IO.File]::Delete($staged) }
        } finally {
            if ($lock) { $lock.Dispose() }
        }
    }
}
