<#
    Typed, local-only normalization. Requires BaselinePacks.ps1 and
    AssessmentCollection.ps1; never uses the exporter's display renderer.

    Snapshot policies contain metadata, not rawSettings. Observations contain
    only scalar/typed-set values. instancePath is a slash-separated, URI-escaped
    setting ID with a zero-based sibling/group occurrence, e.g.
    /group[0]/child[0]. ADMX presentations use /definition[0]/presentation[0].
    A list presentation retains each name/value pair at a separate indexed path,
    rather than discarding names or approximating pairs as a set.

    Unsupported evidence marks its policy and relevant family/platform sources
    incomplete. Unknown applicability is null; generic Windows metadata cannot
    establish Windows 11, and Android device-owner types cannot distinguish
    fully managed from dedicated enrollment. No name/display label is a hint.
#>

function Test-IdsAssessmentSecret {
    param($Node)
    return (
        (Get-IdsAssessmentMember $Node 'assessmentRedacted') -eq $true -or
        (Get-IdsAssessmentMember $Node 'isSecret') -eq $true -or
        (Get-IdsAssessmentMember $Node 'isEncrypted') -eq $true -or
        ([string](Get-IdsAssessmentMember $Node '@odata.type')) -match 'SecretSettingValue|omaSetting(Base64|Xml)'
    )
}

function Get-IdsAssessmentValueType {
    param($Value)
    if ($Value -is [bool]) { return 'boolean' }
    if ($Value -is [string]) { return 'string' }
    if ($Value -is [byte] -or $Value -is [sbyte] -or $Value -is [int16] -or
        $Value -is [uint16] -or $Value -is [int32] -or $Value -is [uint32] -or
        $Value -is [int64] -or $Value -is [uint64] -or $Value -is [decimal] -or
        $Value -is [single] -or $Value -is [double]) {
        if ([double]::IsNaN([double]$Value) -or [double]::IsInfinity([double]$Value)) { return $null }
        return 'number'
    }
    if ($Value -is [Collections.IList] -and $Value.Count -gt 0) {
        if ($Value[0] -is [Collections.IList]) { return $null }
        $type = Get-IdsAssessmentValueType $Value[0]
        if ($type -notin @('string', 'number')) { return $null }
        foreach ($item in $Value) {
            # Do not recurse into unknown nested collections.
            if ($item -is [Collections.IList] -or (Get-IdsAssessmentValueType $item) -cne $type) { return $null }
        }
        return "${type}Set"
    }
    return $null
}

function Add-IdsNormalizedObservation {
    param($State, $SettingId, $Property, $Path, $Value,
        $ValueType = $null, [bool]$Secret = $false, [bool]$Supported = $true)
    $configured = $null -ne $Value
    if ($Secret) {
        $Value = $null
        $configured = $false
        $Supported = $false
    } elseif ($Supported -and $configured) {
        $actualType = Get-IdsAssessmentValueType $Value
        $emptySet = $Value -is [Collections.IList] -and $Value.Count -eq 0 -and $ValueType -in @('stringSet', 'numberSet')
        if (-not $emptySet -and (-not $actualType -or ($ValueType -and $ValueType -cne $actualType))) {
            $Supported = $false
        } elseif (-not $ValueType) { $ValueType = $actualType }
    }
    if (-not $Supported) {
        $Value = $null
        $State.policy.settingsComplete = $false
        $State.issues.Add([pscustomobject]@{
            family = $State.policy.family; policyKey = $State.policy.key
            stage = 'settings'; statusCode = $null
            reason = $(if ($Secret) { 'Secret setting evidence redacted; automated mapping unsupported.' }
                else { 'Unsupported setting shape, type, or nesting (maximum 32 levels).' })
        })
    }
    if ($Value -is [Collections.IList]) { $Value = @($Value) }
    $State.observations.Add([pscustomobject]@{
        policyKey = $State.policy.key; family = $State.policy.family
        settingId = $SettingId; property = $Property; instancePath = $Path
        valueType = $ValueType; value = $Value; configured = $configured
        secret = $Secret; supported = $Supported
    })
}

function Get-IdsNormalizedPath {
    param([string]$Parent, [string]$Id, $Counters)
    if (-not $Counters.ContainsKey($Id)) { $Counters[$Id] = 0 }
    $index = $Counters[$Id]
    $Counters[$Id]++
    return "$Parent/$([uri]::EscapeDataString($Id))[$index]"
}

function ConvertTo-IdsCatalogObservations {
    param($State, $Node, $Definitions, [string]$Parent = '', $Counters = @{},
        [int]$Depth = 0, [bool]$InheritedSecret = $false)
    $id = Get-IdsAssessmentMember $Node 'settingDefinitionId'
    $validId = $id -is [string] -and -not [string]::IsNullOrWhiteSpace($id)
    $path = Get-IdsNormalizedPath $Parent ([string]$id) $Counters
    $secret = $InheritedSecret -or (Test-IdsAssessmentSecret $Node)
    foreach ($definition in $Definitions) {
        if ((Get-IdsAssessmentMember $definition 'id') -ceq $id -and
            ((Test-IdsAssessmentSecret $definition) -or
                (Test-IdsAssessmentSecret (Get-IdsAssessmentMember $definition 'valueDefinition')))) { $secret = $true }
    }
    if ($Depth -ge 32 -or -not $validId -or $secret) {
        Add-IdsNormalizedObservation $State $id $null $path $null -Secret $secret -Supported $false
        return
    }
    $type = ([string](Get-IdsAssessmentMember $Node '@odata.type')) -replace '^#?microsoft\.graph\.', ''
    $valueName = switch -CaseSensitive ($type) {
        deviceManagementConfigurationSimpleSettingInstance { 'simpleSettingValue' }
        deviceManagementConfigurationChoiceSettingInstance { 'choiceSettingValue' }
        deviceManagementConfigurationSimpleSettingCollectionInstance { 'simpleSettingCollectionValue' }
        deviceManagementConfigurationChoiceSettingCollectionInstance { 'choiceSettingCollectionValue' }
        deviceManagementConfigurationGroupSettingInstance { 'groupSettingValue' }
        deviceManagementConfigurationGroupSettingCollectionInstance { 'groupSettingCollectionValue' }
        default { $null }
    }
    if (-not $valueName) {
        Add-IdsNormalizedObservation $State $id $null $path $null -Supported $false
        return
    }
    $container = Get-IdsAssessmentMember $Node $valueName
    if ($null -eq $container) {
        Add-IdsNormalizedObservation $State $id $null $path $null
        return
    }
    $collection = $valueName -match 'Collection'
    if (($collection -and $container -isnot [Collections.IList]) -or
        (-not $collection -and $container -isnot [Collections.IDictionary] -and $container -isnot [pscustomobject])) {
        Add-IdsNormalizedObservation $State $id $null $path $null -Supported $false
        return
    }
    $entries = @($container)
    foreach ($entry in $entries) {
        if (Test-IdsAssessmentSecret $entry) {
            Add-IdsNormalizedObservation $State $id $null $path $null -Secret $true
            return
        }
        # Groups inherit template references too; unresolved parents cannot
        # provide trusted evidence through their descendants.
        if (($entry -isnot [Collections.IDictionary] -and $entry -isnot [pscustomobject]) -or
            (Get-IdsAssessmentMember (Get-IdsAssessmentMember $entry 'settingValueTemplateReference') 'useTemplateDefault') -eq $true) {
            Add-IdsNormalizedObservation $State $id $null $path $null -Supported $false
            return
        }
    }
    $isGroup = $valueName -like 'group*'
    $isChoice = $valueName -like 'choice*'
    if (-not $isGroup) {
        $values = [Collections.Generic.List[object]]::new()
        $valid = $true
        foreach ($entry in $entries) {
            $hasValue = if ($entry -is [Collections.IDictionary]) { $entry.Contains('value') } else { $null -ne $entry.PSObject.Properties['value'] }
            if (-not $hasValue) { $valid = $false; continue }
            $declaredType = ([string](Get-IdsAssessmentMember $entry '@odata.type')) -replace '^#?microsoft\.graph\.', ''
            $expectedType = switch -CaseSensitive ($declaredType) {
                deviceManagementConfigurationStringSettingValue { 'string' }
                deviceManagementConfigurationIntegerSettingValue { 'number' }
                deviceManagementConfigurationBooleanSettingValue { 'boolean' }
                deviceManagementConfigurationChoiceSettingValue { 'string' }
                default { $null }
            }
            if ($declaredType -and -not $expectedType) { $valid = $false; continue }
            $value = Get-IdsAssessmentMember $entry 'value'
            if ($null -ne $value -and (Get-IdsAssessmentValueType $value) -cnotin @('boolean', 'number', 'string')) {
                $valid = $false
                continue
            }
            if ($null -ne $value -and $expectedType -and (Get-IdsAssessmentValueType $value) -cne $expectedType) { $valid = $false }
            if ($collection -and $null -eq $value) { $valid = $false }
            if ($isChoice -and $null -ne $value -and $value -isnot [string]) { $valid = $false }
            $values.Add($value)
        }
        $value = if ($collection) { ,($values.ToArray()) } elseif ($values.Count -eq 1) { $values[0] } else { $null }
        $valueType = if ($isChoice) { if ($collection) { 'stringSet' } else { 'string' } } else { $null }
        if ($collection -and $values.Count -eq 0 -and -not $valueType) {
            foreach ($definition in $Definitions) {
                if ((Get-IdsAssessmentMember $definition 'id') -cne $id) { continue }
                switch -CaseSensitive ([string](Get-IdsAssessmentMember (Get-IdsAssessmentMember $definition 'valueDefinition') '@odata.type')) {
                    '#microsoft.graph.deviceManagementConfigurationIntegerSettingValueDefinition' { $valueType = 'numberSet' }
                    '#microsoft.graph.deviceManagementConfigurationStringSettingValueDefinition' { $valueType = 'stringSet' }
                }
            }
        }
        Add-IdsNormalizedObservation $State $id $null $path $value $valueType -Supported $valid
        if (-not $valid) { return }
    }
    if ($isGroup -or $isChoice) {
        $groupIndex = 0
        foreach ($entry in $entries) {
            $childPath = $path
            if ($groupIndex -gt 0) { $childPath = Get-IdsNormalizedPath $Parent $id $Counters }
            $groupIndex++
            $children = Get-IdsAssessmentMember $entry 'children'
            if (($null -ne $children -and $children -isnot [Collections.IList]) -or
                ($isGroup -and $null -eq $children)) {
                Add-IdsNormalizedObservation $State $id $null $childPath $null -Supported $false
                continue
            }
            $childCounters = @{}
            foreach ($child in $children) {
                ConvertTo-IdsCatalogObservations $State $child $Definitions $childPath $childCounters ($Depth + 1)
            }
        }
    }
}

function Set-IdsNormalizedApplicability {
    param($Policy)
    $type = [string]$Policy.policyType
    switch -Regex -CaseSensitive ($type) {
        '^macOS' { $Policy.platform = 'macos' }
        '^ios' { $Policy.platform = 'iosIpados' }
        '^androidWorkProfile' { $Policy.platform = 'androidEnterprise'; $Policy.enrollmentMode = 'workProfile' }
        '^androidDeviceOwner' {
            $Policy.platform = 'androidEnterprise'
            if ($Policy.enrollmentMode -cnotin @('fullyManaged', 'dedicated', 'corporateOwnedWorkProfile')) { $Policy.enrollmentMode = $null }
        }
    }
    if (-not $Policy.platform) {
        switch -CaseSensitive ([string](Get-IdsAssessmentMember $Policy.template 'platformType')) {
            macOS { $Policy.platform = 'macos' }
            ios { $Policy.platform = 'iosIpados' }
            androidEnterprise { $Policy.platform = 'androidEnterprise' }
            windows11 { $Policy.platform = 'windows11' }
        }
    }
    # A Windows-family candidate is not discovered Windows 11 device scope.
    $Policy.windowsFamily = $Policy.platform -ceq 'windows11' -or $type -cmatch '^windows(10|11)'
    if ($Policy.windowsFamily) {
        $minimum = $null
        $explicit11 = (Get-IdsAssessmentMember $Policy.template 'platformType') -ceq 'windows11'
        $bounded11 = [version]::TryParse([string]$Policy.osMin, [ref]$minimum) -and $minimum -ge [version]'10.0.22000'
        $Policy.platform = if ($explicit11 -or $bounded11) { 'windows11' } else { $null }
    }
    if ($Policy.platform -cnotin @('windows11', 'macos', 'iosIpados', 'androidEnterprise')) { $Policy.platform = $null }
    if ($null -ne $Policy.osApplicabilityRule) {
        $rawRule = $Policy.osApplicabilityRule
        $names = if ($rawRule -is [Collections.IDictionary]) { @($rawRule.Keys) } else { @($rawRule.PSObject.Properties.Name) }
        $supported = ($rawRule -is [Collections.IDictionary] -or $rawRule -is [pscustomobject]) -and
            @($names | Where-Object { $_ -cnotin @('@odata.type', 'minOSVersion', 'maxOSVersion', 'ruleType') }).Count -eq 0
        $ruleType = Get-IdsAssessmentMember $rawRule '@odata.type'
        if ($null -ne $ruleType -and $ruleType -cne '#microsoft.graph.deviceManagementApplicabilityRuleOsVersion') { $supported = $false }
        $safe = [ordered]@{}
        foreach ($name in 'minOSVersion', 'maxOSVersion', 'ruleType') {
            $value = Get-IdsAssessmentMember $rawRule $name
            if ($null -ne $value -and $value -isnot [string]) { $supported = $false; $value = $null }
            $safe[$name] = $value
        }
        $safe.supported = $supported
        $Policy.osApplicabilityRule = [pscustomobject]$safe
    }
}

function ConvertTo-IdsAdmxObservations {
    param($State, $Raw, $Counters)
    $id = Get-IdsAssessmentMember (Get-IdsAssessmentMember $Raw 'definition') 'id'
    $path = Get-IdsNormalizedPath '' ([string]$id) $Counters
    if (-not $id -or (Test-IdsAssessmentSecret $Raw)) {
        Add-IdsNormalizedObservation $State $id $null $path $null -Secret (Test-IdsAssessmentSecret $Raw) -Supported $false
        return
    }
    $enabled = Get-IdsAssessmentMember $Raw 'enabled'
    Add-IdsNormalizedObservation $State $id $null $path $enabled 'boolean'
    $presentations = Get-IdsAssessmentMember $Raw 'presentationValues'
    if ($presentations -isnot [Collections.IList]) {
        Add-IdsNormalizedObservation $State $id $null $path $null -Supported $false
        return
    }
    $presentationCounters = @{}
    foreach ($presentation in $presentations) {
        $presentationId = Get-IdsAssessmentMember (Get-IdsAssessmentMember $presentation 'presentation') 'id'
        $presentationPath = Get-IdsNormalizedPath $path ([string]$presentationId) $presentationCounters
        $secret = Test-IdsAssessmentSecret $presentation
        if (-not $presentationId -or $secret) {
            Add-IdsNormalizedObservation $State $id $null $presentationPath $null -Secret $secret -Supported $false
            continue
        }
        $type = ([string](Get-IdsAssessmentMember $presentation '@odata.type')) -replace '^#?microsoft\.graph\.', ''
        if ($type -ceq 'groupPolicyPresentationValueList') {
            $pairs = Get-IdsAssessmentMember $presentation 'values'
            if ($pairs -isnot [Collections.IList]) {
                Add-IdsNormalizedObservation $State $id $null $presentationPath $null -Supported $false
                continue
            }
            $index = 0
            foreach ($pair in $pairs) {
                $pairPath = "$presentationPath/item[$index]"
                $index++
                if (Test-IdsAssessmentSecret $pair) {
                    Add-IdsNormalizedObservation $State $id $null $pairPath $null -Secret $true
                    continue
                }
                foreach ($member in @('name', 'value')) {
                    $value = if ($enabled -eq $true) { Get-IdsAssessmentMember $pair $member } else { $null }
                    Add-IdsNormalizedObservation $State $id $null "$pairPath/$member" $value 'string' -Supported (
                        ($enabled -is [bool]) -and ($enabled -eq $false -or $value -is [string]))
                }
            }
            continue
        }
        $valueType = switch -CaseSensitive ($type) {
            groupPolicyPresentationValueBoolean { 'boolean' }
            groupPolicyPresentationValueDecimal { 'number' }
            groupPolicyPresentationValueLongDecimal { 'number' }
            groupPolicyPresentationValueText { 'string' }
            default { $null }
        }
        if (-not $valueType) {
            Add-IdsNormalizedObservation $State $id $null $presentationPath $null -Supported $false
            continue
        }
        $value = if ($enabled -eq $true) { Get-IdsAssessmentMember $presentation 'value' } else { $null }
        Add-IdsNormalizedObservation $State $id $null $presentationPath $value $valueType -Supported ($enabled -is [bool])
    }
}

function ConvertTo-IdsAssessmentSnapshot {
    param([Parameter(Mandatory)]$Collection)
    $observations = [Collections.Generic.List[object]]::new()
    $policies = [Collections.Generic.List[object]]::new()
    $issues = [Collections.Generic.List[object]]::new()
    foreach ($issue in $Collection.issues) { $issues.Add($issue) }
    $catalog = Get-IdsAssessmentPropertyCatalog
    foreach ($inputPolicy in $Collection.policies) {
        $metadata = [ordered]@{}
        foreach ($name in @('key', 'id', 'name', 'family', 'policyType', 'template', 'platform', 'windowsFamily', 'osMin', 'osMax',
            'osApplicabilityRule', 'unsupportedApplicability',
            'enrollmentMode', 'assignments', 'settingsComplete', 'assignmentsComplete')) {
            $metadata[$name] = Copy-IdsAssessmentEvidence (Get-IdsAssessmentMember $inputPolicy $name)
        }
        $policy = [pscustomobject]$metadata
        Set-IdsNormalizedApplicability $policy
        $policies.Add($policy)
        $state = @{ policy = $policy; observations = $observations; issues = $issues }
        $counters = @{}
        $definitions = @()
        foreach ($raw in $inputPolicy.rawSettings) {
            foreach ($definition in (Get-IdsAssessmentMember $raw 'settingDefinitions')) { $definitions += $definition }
        }
        foreach ($raw in $inputPolicy.rawSettings) {
            switch -CaseSensitive ($policy.family) {
                settingsCatalog {
                    ConvertTo-IdsCatalogObservations $state (Get-IdsAssessmentMember $raw 'settingInstance') $definitions '' $counters
                }
                { $_ -cin @('deviceConfiguration', 'compliance') } {
                    $selector = "$($policy.family):$($policy.policyType)"
                    if (-not $catalog.ContainsKey($selector)) {
                        Add-IdsNormalizedObservation $state $null $null '/' $null -Supported $false
                        continue
                    }
                    foreach ($propertyName in ($catalog[$selector].Keys | Sort-Object -CaseSensitive)) {
                        $present = if ($raw -is [Collections.IDictionary]) { $raw.Contains($propertyName) } else { $null -ne $raw.PSObject.Properties[$propertyName] }
                        if (-not $present) { continue }
                        $secret = Test-IdsAssessmentSecret $raw
                        $value = if ($secret) { $null } else { Get-IdsAssessmentMember $raw $propertyName }
                        Add-IdsNormalizedObservation $state $null $propertyName $null $value $catalog[$selector][$propertyName] -Secret $secret
                    }
                }
                admx { ConvertTo-IdsAdmxObservations $state $raw $counters }
                intent {
                    $id = Get-IdsAssessmentMember $raw 'definitionId'
                    $path = Get-IdsNormalizedPath '' ([string]$id) $counters
                    $secret = Test-IdsAssessmentSecret $raw
                    if (-not $id -or $secret) {
                        Add-IdsNormalizedObservation $state $id $null $path $null -Secret $secret -Supported $false
                        continue
                    }
                    $value = Get-IdsAssessmentMember $raw 'value'
                    $json = Get-IdsAssessmentMember $raw 'valueJson'
                    $valid = $true
                    if ($null -ne $json) {
                        if ($json -isnot [string]) { $valid = $false } else {
                            try { $value = ConvertFrom-Json -InputObject $json -Depth 32 -NoEnumerate -ErrorAction Stop }
                            catch { $value = $null; $valid = $false }
                        }
                    }
                    Add-IdsNormalizedObservation $state $id $null $path $value -Supported $valid
                }
                default { Add-IdsNormalizedObservation $state $null $null '/' $null -Supported $false }
            }
        }
    }
    $sources = [Collections.Generic.List[object]]::new()
    foreach ($source in $Collection.sources) {
        $errors = @($issues | Where-Object {
            $_.stage -eq 'settings' -and $_.family -ceq $source.family -and
            $_.policyKey -cin @($policies | Where-Object { -not $_.platform -or $_.platform -ceq $source.platform } | ForEach-Object key)
        })
        $sources.Add([pscustomobject]@{
            family = $source.family; platform = $source.platform
            complete = ($source.complete -and $errors.Count -eq 0)
            errors = @(@($source.errors) + $errors | Select-Object -Unique)
        })
    }
    return [pscustomobject]@{
        observations = $observations.ToArray(); policies = $policies.ToArray()
        sources = $sources.ToArray(); issues = $issues.ToArray()
    }
}
