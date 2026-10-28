BeforeAll {
    . "$PSScriptRoot\TestHelpers\Assessment.ps1"
    . "$PSScriptRoot\..\lib\BaselinePacks.ps1"
    . "$PSScriptRoot\..\lib\AssessmentCollection.ps1"
    if (Test-Path "$PSScriptRoot\..\lib\AssessmentSettings.ps1") { . "$PSScriptRoot\..\lib\AssessmentSettings.ps1" }
    function Get-TestSnapshot($Policy) {
        ConvertTo-IdsAssessmentSnapshot (New-IdsTestAssessmentCollection @($Policy))
    }
    function Get-TestCatalogSnapshot($Instance, $Definitions = @()) {
        Get-TestSnapshot (New-IdsTestAssessmentPolicy -Settings @(@{
            settingInstance = $Instance; settingDefinitions = $Definitions
        }))
    }
}

Describe 'Typed assessment normalization' {
    It 'retains a configured false property without display conversion' {
        $policy = New-IdsTestAssessmentPolicy compliance macOSCompliancePolicy @(
            [pscustomobject]@{ '@odata.type' = '#microsoft.graph.macOSCompliancePolicy'; storageRequireEncryption = $false }
        )
        $snapshot = Get-TestSnapshot $policy
        $snapshot.observations.Count | Should -Be 1
        $snapshot.observations[0].configured | Should -BeTrue
        $snapshot.observations[0].value | Should -BeFalse
        $snapshot.observations[0].valueType | Should -Be 'boolean'
    }

    It 'normalizes verified properties for <Type>' -ForEach @(
        @{ Type = 'windows10CompliancePolicy'; Property = 'passwordMinimumLength'; Value = 0; Platform = $null }
        @{ Type = 'macOSCompliancePolicy'; Property = 'storageRequireEncryption'; Value = $false; Platform = 'macos' }
        @{ Type = 'iosCompliancePolicy'; Property = 'passcodeRequired'; Value = $false; Platform = 'iosIpados' }
        @{ Type = 'androidWorkProfileCompliancePolicy'; Property = 'passwordRequired'; Value = $false; Platform = 'androidEnterprise' }
        @{ Type = 'androidDeviceOwnerCompliancePolicy'; Property = 'passwordRequired'; Value = $false; Platform = 'androidEnterprise' }
    ) {
        $snapshot = Get-TestSnapshot (New-IdsTestAssessmentPolicy compliance $Type @(@{ $Property = $Value; displayName = 'Not evidence'; id = 'metadata' }))
        $snapshot.observations.Count | Should -Be 1
        $snapshot.observations[0].property | Should -BeExactly $Property
        $snapshot.observations[0].value | Should -Be $Value
        $snapshot.policies[0].platform | Should -Be $Platform
    }

    It 'distinguishes Android enrollment modes without inferring device owner mode from its name' {
        $work = Get-TestSnapshot (New-IdsTestAssessmentPolicy compliance androidWorkProfileCompliancePolicy)
        $ownerPolicy = New-IdsTestAssessmentPolicy compliance androidDeviceOwnerCompliancePolicy
        $owner = Get-TestSnapshot $ownerPolicy
        $work.policies[0].enrollmentMode | Should -BeExactly 'workProfile'
        $owner.policies[0].enrollmentMode | Should -BeNullOrEmpty
        foreach ($mode in @('fullyManaged', 'dedicated')) {
            $ownerPolicy.enrollmentMode = $mode
            (Get-TestSnapshot $ownerPolicy).policies[0].enrollmentMode | Should -BeExactly $mode
        }
    }

    It 'does not promote generic Windows metadata to discovered Windows 11 applicability' {
        $policy = New-IdsTestAssessmentPolicy compliance windows10CompliancePolicy
        $policy.platform = 'windows11'
        (Get-TestSnapshot $policy).policies[0].platform | Should -BeNullOrEmpty
        $policy.osMin = '10.0.22000'
        (Get-TestSnapshot $policy).policies[0].platform | Should -Be 'windows11'
    }

    It 'preserves modern endpoint-security template metadata without changing family or guessing platform' {
        $template = @{ templateId = 'synthetic-template'; templateFamily = 'endpointSecurityAntivirus'; templateDisplayName = 'Windows 11' }
        $policy = New-IdsTestAssessmentPolicy -Template $template
        $snapshot = Get-TestSnapshot $policy
        $snapshot.policies.Count | Should -Be 1
        $snapshot.policies[0].family | Should -Be 'settingsCatalog'
        $snapshot.policies[0].template.templateId | Should -Be 'synthetic-template'
        $snapshot.policies[0].platform | Should -BeNullOrEmpty
        $policy.platform = 'macos'
        (Get-TestSnapshot $policy).policies[0].platform | Should -Be 'macos'
    }

    It 'uses intent template platformType instead of display names' {
        $policy = New-IdsTestAssessmentPolicy intent deviceManagementIntent @() @{ id = 'template'; platformType = 'ios' }
        (Get-TestSnapshot $policy).policies[0].platform | Should -Be 'iosIpados'
    }

    It 'normalizes legacy allowlisted arrays and excludes arbitrary policy properties' {
        $policy = New-IdsTestAssessmentPolicy deviceConfiguration macOSGeneralDeviceConfiguration @(@{
            emailInDomainSuffixes = @(); passwordMinimumLength = 0; passwordRequiredType = 'deviceDefault'
            password = 'SYNTHETIC-SECRET'; payload = '<xml />'; description = 'not a rule'
        })
        $snapshot = Get-TestSnapshot $policy
        $snapshot.observations.Count | Should -Be 3
        ($snapshot.observations | Where-Object property -EQ emailInDomainSuffixes).valueType | Should -Be 'stringSet'
        ($snapshot.observations | Where-Object property -EQ emailInDomainSuffixes).value.Count | Should -Be 0
        ($snapshot | ConvertTo-Json -Depth 40) | Should -Not -Match 'SYNTHETIC-SECRET|<xml|rawSettings|not a rule'
    }

    It 'preserves explicit null separately from false and absent properties' {
        $snapshot = Get-TestSnapshot (New-IdsTestAssessmentPolicy compliance macOSCompliancePolicy @(@{ storageRequireEncryption = $null }))
        $snapshot.observations.Count | Should -Be 1
        $snapshot.observations[0].configured | Should -BeFalse
        $snapshot.observations[0].supported | Should -BeTrue
        $snapshot.observations[0].value | Should -BeNullOrEmpty
    }

    It 'keeps simple <Label> values typed' -ForEach @(
        @{ Label = 'false'; Value = $false; Type = 'boolean' }
        @{ Label = 'zero'; Value = 0; Type = 'number' }
        @{ Label = 'numeric string'; Value = '0'; Type = 'string' }
        @{ Label = 'empty string'; Value = ''; Type = 'string' }
    ) {
        $snapshot = Get-TestCatalogSnapshot (New-IdsTestSettingInstance -Value @{ value = $Value })
        $snapshot.observations[0].value | Should -BeExactly $Value
        $snapshot.observations[0].valueType | Should -Be $Type
        $snapshot.observations[0].configured | Should -BeTrue
    }

    It 'keeps encoded choice IDs and recursively visits children' {
        $child = New-IdsTestSettingInstance -Id 'child' -Value @{ value = $false }
        $snapshot = Get-TestCatalogSnapshot (New-IdsTestSettingInstance choice 'parent' @{ value = 'parent_0'; children = @($child) })
        $snapshot.observations.Count | Should -Be 2
        $snapshot.observations[0].value | Should -BeExactly 'parent_0'
        $snapshot.observations[0].valueType | Should -Be 'string'
        $snapshot.observations[1].value | Should -BeFalse
        $snapshot.observations[1].instancePath | Should -BeExactly '/parent[0]/child[0]'
    }

    It 'keeps <Label> collections as typed arrays' -ForEach @(
        @{ Label = 'strings'; Kind = 'simple'; Values = @(@{ value = 'a' }, @{ value = 'b' }); Type = 'stringSet'; Want = @('a', 'b') }
        @{ Label = 'numbers'; Kind = 'simple'; Values = @(@{ value = 0 }, @{ value = 1 }); Type = 'numberSet'; Want = @(0, 1) }
        @{ Label = 'choices'; Kind = 'choice'; Values = @(@{ value = 'id_0' }, @{ value = 'id_1' }); Type = 'stringSet'; Want = @('id_0', 'id_1') }
        @{ Label = 'empty'; Kind = 'simple'; Values = @(); Type = 'numberSet'; Want = @() }
    ) {
        $typeKind = $Kind.Substring(0, 1).ToUpperInvariant() + $Kind.Substring(1)
        $instance = @{ '@odata.type' = "#microsoft.graph.deviceManagementConfiguration${typeKind}SettingCollectionInstance"; settingDefinitionId = 'set' }
        $instance["${Kind}SettingCollectionValue"] = $Values
        $snapshot = Get-TestCatalogSnapshot $instance @(@{
            id = 'set'; '@odata.type' = '#microsoft.graph.deviceManagementConfigurationSimpleSettingCollectionDefinition'
            valueDefinition = @{ '@odata.type' = '#microsoft.graph.deviceManagementConfigurationIntegerSettingValueDefinition' }
        })
        $observation = $snapshot.observations[0]
        $observation.valueType | Should -Be $Type
        $observation.value -is [array] | Should -BeTrue
        $observation.value.Count | Should -Be $Want.Count
        for ($i = 0; $i -lt $Want.Count; $i++) { $observation.value[$i] | Should -BeExactly $Want[$i] }
    }

    It 'preserves distinct repeated group paths' {
        $instance = @{ '@odata.type' = '#microsoft.graph.deviceManagementConfigurationGroupSettingCollectionInstance'
            settingDefinitionId = 'group'; groupSettingCollectionValue = @(
                @{ children = @((New-IdsTestSettingInstance -Id 'child' -Value @{ value = 0 })) }
                @{ children = @((New-IdsTestSettingInstance -Id 'child' -Value @{ value = 1 })) }
            ) }
        $snapshot = Get-TestCatalogSnapshot $instance
        $snapshot.observations.Count | Should -Be 2
        $snapshot.observations[0].instancePath | Should -Be '/group[0]/child[0]'
        $snapshot.observations[1].instancePath | Should -Be '/group[1]/child[0]'
    }

    It 'normalizes single groups and choice collection children' {
        foreach ($kind in @('group', 'choiceCollection')) {
            $child = New-IdsTestSettingInstance -Id 'leaf' -Value @{ value = 0 }
            $instance = if ($kind -eq 'group') { New-IdsTestSettingInstance group 'group' @{ children = @($child) } }
                else { @{ '@odata.type' = '#microsoft.graph.deviceManagementConfigurationChoiceSettingCollectionInstance'
                    settingDefinitionId = 'choice'; choiceSettingCollectionValue = @(@{ value = 'choice_1'; children = @($child) }) } }
            $snapshot = Get-TestCatalogSnapshot $instance
            @($snapshot.observations | Where-Object settingId -EQ leaf).Count | Should -Be 1
        }
    }

    It 'normalizes ADMX enablement and typed presentations without display conversion' {
        $policy = New-IdsTestAssessmentPolicy admx groupPolicyConfiguration @(@{
            definition = @{ id = 'definition' }; enabled = $true
            presentationValues = @(
                @{ presentation = @{ id = 'integer' }; '@odata.type' = '#microsoft.graph.groupPolicyPresentationValueDecimal'; value = 0 }
                @{ presentation = @{ id = 'text' }; '@odata.type' = '#microsoft.graph.groupPolicyPresentationValueText'; value = 'option_0' }
            )
        })
        $snapshot = Get-TestSnapshot $policy
        $snapshot.observations.Count | Should -Be 3
        $snapshot.observations[0].settingId | Should -Be 'definition'
        $snapshot.observations[0].value | Should -BeTrue
        $snapshot.observations[1].instancePath | Should -Be '/definition[0]/integer[0]'
        $snapshot.observations[1].value | Should -Be 0
        $snapshot.observations[2].value | Should -BeExactly 'option_0'
    }

    It 'parses intent JSON <Json> without coercing types' -ForEach @(
        @{ Json = 'false'; Type = 'boolean'; Value = $false }
        @{ Json = '0'; Type = 'number'; Value = 0 }
        @{ Json = '"id_0"'; Type = 'string'; Value = 'id_0' }
        @{ Json = '[0,1]'; Type = 'numberSet'; Value = @(0, 1) }
        @{ Json = '["a","b"]'; Type = 'stringSet'; Value = @('a', 'b') }
        @{ Json = 'null'; Type = $null; Value = $null }
    ) {
        $snapshot = Get-TestSnapshot (New-IdsTestAssessmentPolicy intent deviceManagementIntent @(@{ definitionId = 'intent-setting'; valueJson = $Json }))
        $snapshot.observations[0].valueType | Should -Be $Type
        if ($null -eq $Value) { $snapshot.observations[0].configured | Should -BeFalse }
        else { ($snapshot.observations[0].value | ConvertTo-Json -Compress) | Should -Be ($Value | ConvertTo-Json -Compress) }
    }

    It 'normalizes direct intent false values' {
        $snapshot = Get-TestSnapshot (New-IdsTestAssessmentPolicy intent deviceManagementIntent @(@{ definitionId = 'intent-setting'; value = $false }))
        $snapshot.observations[0].value | Should -BeFalse
        $snapshot.observations[0].configured | Should -BeTrue
    }

    It 'marks malformed or unsupported intent JSON incomplete instead of claiming absence' -ForEach @(
        @{ Json = '{bad' }; @{ Json = '{"value":0}' }; @{ Json = '[false,0]' }; @{ Json = '[]' }
    ) {
        $snapshot = Get-TestSnapshot (New-IdsTestAssessmentPolicy intent deviceManagementIntent @(@{ definitionId = 'unsupported'; valueJson = $Json }))
        $snapshot.observations[0].supported | Should -BeFalse
        $snapshot.policies[0].settingsComplete | Should -BeFalse
        $snapshot.issues.Count | Should -BeGreaterThan 0
    }

    It 'never retains catalog secrets identified by <Marker>' -ForEach @(
        @{ Marker = 'definition' }; @{ Marker = 'type' }; @{ Marker = 'redacted' }; @{ Marker = 'encrypted' }
    ) {
        $value = @{ value = 'SYNTHETIC-SECRET' }
        $definitions = @()
        switch ($Marker) {
            definition { $definitions = @(@{ id = 'secret'; isSecret = $true }) }
            type { $value['@odata.type'] = '#microsoft.graph.deviceManagementConfigurationSecretSettingValue' }
            redacted { $value.assessmentRedacted = $true }
            encrypted { $value.isEncrypted = $true }
        }
        $snapshot = Get-TestCatalogSnapshot (New-IdsTestSettingInstance simple secret $value) $definitions
        $snapshot.observations[0].secret | Should -BeTrue
        $snapshot.observations[0].supported | Should -BeFalse
        ($snapshot | ConvertTo-Json -Depth 40) | Should -Not -Match 'SYNTHETIC-SECRET'
    }

    It 'does not parse encrypted intent values or custom payloads' {
        foreach ($policy in @(
            (New-IdsTestAssessmentPolicy intent deviceManagementIntent @(@{ definitionId = 'secret'; isEncrypted = $true; valueJson = '"SYNTHETIC-SECRET"' }))
            (New-IdsTestAssessmentPolicy deviceConfiguration macOSCustomConfiguration @(@{ payload = 'SYNTHETIC-SECRET' }))
        )) {
            $snapshot = Get-TestSnapshot $policy
            $snapshot.policies[0].settingsComplete | Should -BeFalse
            ($snapshot | ConvertTo-Json -Depth 40) | Should -Not -Match 'SYNTHETIC-SECRET'
        }
    }

    It 'propagates unknown shapes and depth failures to relevant completeness only' {
        $instance = New-IdsTestSettingInstance -Value @{ value = 0 }
        for ($i = 0; $i -lt 34; $i++) { $instance = New-IdsTestSettingInstance group "group$i" @{ children = @($instance) } }
        foreach ($item in @($instance, @{ settingDefinitionId = 'unknown'; '@odata.type' = '#microsoft.graph.futureSettingInstance' })) {
            $policy = New-IdsTestAssessmentPolicy -Settings @(@{ settingInstance = $item })
            $policy.platform = 'macos'
            $collection = New-IdsTestAssessmentCollection @($policy)
            $collection.sources = @(
                [pscustomobject]@{ family = 'settingsCatalog'; platform = 'macos'; complete = $true; errors = @() }
                [pscustomobject]@{ family = 'compliance'; platform = 'macos'; complete = $true; errors = @() }
            )
            $snapshot = ConvertTo-IdsAssessmentSnapshot $collection
            $snapshot.policies[0].settingsComplete | Should -BeFalse
            $snapshot.sources[0].complete | Should -BeFalse
            $snapshot.sources[1].complete | Should -BeTrue
            @($snapshot.observations | Where-Object { -not $_.supported }).Count | Should -BeGreaterThan 0
            $collection.sources[0].complete | Should -BeTrue
        }
    }

    It 'preserves collection issues, assignment completeness and array-valued roots' {
        $policy = New-IdsTestAssessmentPolicy compliance macOSCompliancePolicy @(@{ passwordMinimumLength = 0 })
        $policy.assignmentsComplete = $false
        $collection = New-IdsTestAssessmentCollection @($policy)
        $collection.issues = @([pscustomobject]@{ family = 'compliance'; policyKey = $policy.key; stage = 'assignments'; statusCode = 403; reason = 'Denied' })
        $snapshot = ConvertTo-IdsAssessmentSnapshot $collection
        $snapshot.policies[0].settingsComplete | Should -BeTrue
        $snapshot.policies[0].assignmentsComplete | Should -BeFalse
        $snapshot.issues[0].statusCode | Should -Be 403
        foreach ($name in @('observations', 'policies', 'sources', 'issues')) { $snapshot.$name -is [array] | Should -BeTrue }
        $empty = ConvertTo-IdsAssessmentSnapshot (New-IdsTestAssessmentCollection)
        $empty.observations.Count | Should -Be 0
    }

    It 'types empty string sets from the actual Graph valueDefinition shape' {
        $instance = @{ '@odata.type' = '#microsoft.graph.deviceManagementConfigurationSimpleSettingCollectionInstance'
            settingDefinitionId = 'empty'; simpleSettingCollectionValue = @() }
        $snapshot = Get-TestCatalogSnapshot $instance @(@{
            id = 'empty'; '@odata.type' = '#microsoft.graph.deviceManagementConfigurationSimpleSettingCollectionDefinition'
            valueDefinition = @{ '@odata.type' = '#microsoft.graph.deviceManagementConfigurationStringSettingValueDefinition' }
        })
        $snapshot.observations[0].valueType | Should -Be 'stringSet'
        $snapshot.observations[0].configured | Should -BeTrue
        $snapshot.observations[0].supported | Should -BeTrue
        $snapshot.observations[0].value -is [array] | Should -BeTrue
    }

    It 'rejects unknown nested direct intent arrays without recursive traversal' {
        $value = ,@(0)
        for ($i = 0; $i -lt 40; $i++) { $value = ,$value }
        $snapshot = Get-TestSnapshot (New-IdsTestAssessmentPolicy intent deviceManagementIntent @(@{ definitionId = 'nested'; value = $value }))
        $snapshot.observations[0].supported | Should -BeFalse
    }

    It 'retains ADMX list name-value provenance rather than flattening names away' {
        $snapshot = Get-TestSnapshot (New-IdsTestAssessmentPolicy admx groupPolicyConfiguration @(@{
            definition = @{ id = 'definition' }; enabled = $true; presentationValues = @(@{
                presentation = @{ id = 'list' }; '@odata.type' = '#microsoft.graph.groupPolicyPresentationValueList'
                values = @(@{ name = 'first'; value = 'a' }, @{ name = 'second'; value = 'b' })
            })
        }))
        $snapshot.observations.Count | Should -Be 5
        $snapshot.observations[1].instancePath | Should -Be '/definition[0]/list[0]/item[0]/name'
        $snapshot.observations[1].value | Should -BeExactly 'first'
        $snapshot.observations[2].value | Should -BeExactly 'a'
        $snapshot.observations[3].value | Should -BeExactly 'second'
        $snapshot.policies[0].settingsComplete | Should -BeTrue
    }

    It 'does not claim malformed null scalar containers or template defaults are configured evidence' -ForEach @(
        @{ Container = 'invalid' }
        @{ Container = @{ unexpected = 0 } }
        @{ Container = @{ settingValueTemplateReference = @{ useTemplateDefault = $true }; value = 0 } }
    ) {
        $snapshot = Get-TestCatalogSnapshot (New-IdsTestSettingInstance -Value $Container)
        $snapshot.observations[0].supported | Should -BeFalse
        $snapshot.policies[0].settingsComplete | Should -BeFalse
    }

    It 'keeps known-null setting values unconfigured and supported' {
        $snapshot = Get-TestCatalogSnapshot (New-IdsTestSettingInstance -Value @{ value = $null })
        $snapshot.observations[0].configured | Should -BeFalse
        $snapshot.observations[0].supported | Should -BeTrue
    }

    It 'rejects allowlisted property type coercion' {
        $snapshot = Get-TestSnapshot (New-IdsTestAssessmentPolicy compliance macOSCompliancePolicy @(@{ storageRequireEncryption = 'false'; passwordMinimumLength = '0' }))
        $snapshot.observations.Count | Should -Be 2
        @($snapshot.observations | Where-Object supported).Count | Should -Be 0
        $snapshot.policies[0].settingsComplete | Should -BeFalse
    }

    It 'retains unique escaped paths for repeated top-level and nested settings' {
        $first = New-IdsTestSettingInstance -Id 'a/b' -Value @{ value = 0 }
        $second = New-IdsTestSettingInstance -Id 'a/b' -Value @{ value = 1 }
        $snapshot = Get-TestSnapshot (New-IdsTestAssessmentPolicy -Settings @(@{ settingInstance = $first }, @{ settingInstance = $second }))
        $snapshot.observations[0].instancePath | Should -Be '/a%2Fb[0]'
        $snapshot.observations[1].instancePath | Should -Be '/a%2Fb[1]'
    }

    It 'keeps definition-marked child secrets out of observations' {
        $child = New-IdsTestSettingInstance -Id 'child' -Value @{ value = 'SYNTHETIC-SECRET' }
        $snapshot = Get-TestCatalogSnapshot (New-IdsTestSettingInstance group parent @{ children = @($child) }) @(@{ id = 'child'; isSecret = $true })
        $snapshot.observations[0].secret | Should -BeTrue
        ($snapshot | ConvertTo-Json -Depth 40) | Should -Not -Match 'SYNTHETIC-SECRET'
    }

    It 'marks collected redacted property evidence unsupported without dropping its identity' {
        $snapshot = Get-TestSnapshot (New-IdsTestAssessmentPolicy compliance macOSCompliancePolicy @(@{
            storageRequireEncryption = $null; assessmentRedacted = $true
        }))
        $snapshot.observations[0].property | Should -Be 'storageRequireEncryption'
        $snapshot.observations[0].secret | Should -BeTrue
        $snapshot.observations[0].supported | Should -BeFalse
    }

    It 'preserves prior settings failures and assignment target evidence without mutating input' {
        $policy = New-IdsTestAssessmentPolicy compliance macOSCompliancePolicy @(@{ storageRequireEncryption = $false })
        $policy.settingsComplete = $false
        $policy.assignments = @(@{ target = @{ '@odata.type' = '#microsoft.graph.groupAssignmentTarget'
            groupId = 'synthetic-group'; deviceAndAppManagementAssignmentFilterId = 'synthetic-filter' } })
        $collection = New-IdsTestAssessmentCollection @($policy)
        $collection.sources = @([pscustomobject]@{ family = 'compliance'; platform = 'macos'; complete = $false; errors = @() })
        $snapshot = ConvertTo-IdsAssessmentSnapshot $collection
        $snapshot.policies[0].settingsComplete | Should -BeFalse
        $snapshot.policies[0].assignments[0].target.groupId | Should -Be 'synthetic-group'
        $snapshot.policies[0].assignments[0].target.deviceAndAppManagementAssignmentFilterId | Should -Be 'synthetic-filter'
        $snapshot.sources[0].complete | Should -BeFalse
        $policy.platform | Should -BeNullOrEmpty
        $policy.rawSettings[0].storageRequireEncryption | Should -BeFalse
    }

    It 'does not evaluate inactive ADMX presentation values as configured' {
        $snapshot = Get-TestSnapshot (New-IdsTestAssessmentPolicy admx groupPolicyConfiguration @(@{
            definition = @{ id = 'disabled' }; enabled = $false
            presentationValues = @(@{ presentation = @{ id = 'stale' }
                '@odata.type' = '#microsoft.graph.groupPolicyPresentationValueDecimal'; value = 99 })
        }))
        $snapshot.observations[0].value | Should -BeFalse
        $snapshot.observations[1].configured | Should -BeFalse
        $snapshot.observations[1].value | Should -BeNullOrEmpty
        $snapshot.policies[0].settingsComplete | Should -BeTrue
    }

    It 'redacts definition value-type secrets before reading the value' {
        $snapshot = Get-TestCatalogSnapshot (New-IdsTestSettingInstance -Id 'secret' -Value @{ value = 'SYNTHETIC-SECRET' }) @(@{
            id = 'secret'; valueDefinition = @{ '@odata.type' = '#microsoft.graph.deviceManagementConfigurationSecretSettingValueDefinition' }
        })
        $snapshot.observations[0].secret | Should -BeTrue
        ($snapshot | ConvertTo-Json -Depth 40) | Should -Not -Match 'SYNTHETIC-SECRET'
    }

    It 'does not normalize unknown or contradictory catalog value types by their scalar value alone' -ForEach @(
        @{ DeclaredType = '#microsoft.graph.futurePayloadValue'; RawValue = '<script>SYNTHETIC</script>' }
        @{ DeclaredType = '#microsoft.graph.deviceManagementConfigurationIntegerSettingValue'; RawValue = '0' }
    ) {
        $snapshot = Get-TestCatalogSnapshot (New-IdsTestSettingInstance -Value @{
            '@odata.type' = $DeclaredType; value = $RawValue
        })
        $snapshot.observations[0].supported | Should -BeFalse
        ($snapshot | ConvertTo-Json -Depth 40) | Should -Not -Match 'SYNTHETIC</script>'
    }

    It 'accepts 32 setting levels and rejects the 33rd' -ForEach @(
        @{ Groups = 31; Supported = $true }; @{ Groups = 32; Supported = $false }
    ) {
        $instance = New-IdsTestSettingInstance -Value @{ value = 0 }
        for ($i = 0; $i -lt $Groups; $i++) { $instance = New-IdsTestSettingInstance group "group$i" @{ children = @($instance) } }
        $snapshot = Get-TestCatalogSnapshot $instance
        $snapshot.observations[0].supported | Should -Be $Supported
        $snapshot.policies[0].settingsComplete | Should -Be $Supported
    }

    It 'keeps singleton choice and simple sets as arrays' -ForEach @(
        @{ Kind = 'Choice'; Value = 'id_0'; Type = 'stringSet' }
        @{ Kind = 'Simple'; Value = 0; Type = 'numberSet' }
    ) {
        $snapshot = Get-TestCatalogSnapshot @{
            '@odata.type' = "#microsoft.graph.deviceManagementConfiguration${Kind}SettingCollectionInstance"
            settingDefinitionId = 'single'; "${Kind}SettingCollectionValue" = @(@{ value = $Value })
        }
        $snapshot.observations[0].value -is [array] | Should -BeTrue
        $snapshot.observations[0].value.Count | Should -Be 1
        $snapshot.observations[0].value[0] | Should -BeExactly $Value
        $snapshot.observations[0].valueType | Should -Be $Type
    }
}
