BeforeAll {
    . "$PSScriptRoot\TestHelpers\Assessment.ps1"
    . "$PSScriptRoot\..\lib\Graph.ps1"
    . "$PSScriptRoot\..\lib\BaselinePacks.ps1"
    . "$PSScriptRoot\..\lib\AssessmentCollection.ps1"
    . "$PSScriptRoot\..\lib\AssessmentSettings.ps1"
    if (Test-Path "$PSScriptRoot\..\lib\AssessmentRules.ps1") { . "$PSScriptRoot\..\lib\AssessmentRules.ps1" }

    function New-TestMapping($Type = 'boolean', $Operator = 'eq', $Expected = $true) {
        [pscustomobject]@{
            family = 'settingsCatalog'; policyTypes = @('deviceManagementConfigurationPolicy')
            settingId = 'synthetic.required'; property = $null; instancePath = $null
            valueType = $Type; operator = $Operator; expected = $Expected; caseSensitive = $true
        }
    }
    function New-TestObservation($Value = $true, $Type = 'boolean', $Key = 'settingsCatalog:one') {
        [pscustomobject]@{
            policyKey = $Key; family = 'settingsCatalog'; settingId = 'synthetic.required'
            property = $null; instancePath = '/synthetic.required[0]'
            valueType = $Type; value = $Value; configured = $true; supported = $true; secret = $false
        }
    }
    function New-TestPack($Mapping = (New-TestMapping)) {
        $pack = Read-IdsBaselinePack -Bytes (New-IdsTestPackBytes)
        $pack.controls[0].mappings = @($Mapping)
        return $pack
    }
    function New-TestSnapshot($Observations = @((New-TestObservation))) {
        $policies = @($Observations | Group-Object policyKey | ForEach-Object {
            $policy = New-IdsTestAssessmentPolicy
            $policy.key = $_.Name
            $policy.id = $_.Name.Split(':')[1]
            $policy.platform = 'windows11'
            $policy.PSObject.Properties.Remove('rawSettings')
            $policy
        })
        [pscustomobject]@{
            observations = @($Observations); policies = $policies
            sources = @([pscustomobject]@{ family = 'settingsCatalog'; platform = 'windows11'; complete = $true; errors = @() })
            issues = @()
        }
    }
    function Invoke-TestAssessment($Pack, $Snapshot, $Context = @{ platforms = @('windows11'); osVersions = @{}; enrollmentModes = @{} }) {
        Compare-IdsAssessment -Packs @($Pack) -Snapshot $Snapshot -Context $Context
    }
}

Describe 'Conservative policy aggregation' {
    It 'consumes real normalized evidence for <Family> on <Platform>' -ForEach @(
        @{ Family = 'settingsCatalog'; Platform = 'windows11'; PolicyType = 'deviceManagementConfigurationPolicy'; Property = $null }
        @{ Family = 'deviceConfiguration'; Platform = 'macos'; PolicyType = 'macOSGeneralDeviceConfiguration'; Property = 'passwordRequired' }
        @{ Family = 'compliance'; Platform = 'iosIpados'; PolicyType = 'iosCompliancePolicy'; Property = 'passcodeRequired' }
        @{ Family = 'admx'; Platform = 'windows11'; PolicyType = 'groupPolicyConfiguration'; Property = $null }
        @{ Family = 'intent'; Platform = 'androidEnterprise'; PolicyType = 'deviceManagementIntent'; Property = $null }
    ) {
        $mapping = New-TestMapping boolean eq $false
        $mapping.family = $Family
        $mapping.policyTypes = @($PolicyType)
        $mapping.property = $Property
        if ($Property) { $mapping.settingId = $null }
        $policy = New-IdsTestAssessmentPolicy $Family $PolicyType
        $policy.platform = $Platform
        $policy.template = @{ platformType = $Platform }
        $policy.enrollmentMode = 'fullyManaged'
        $policy.rawSettings = switch ($Family) {
            settingsCatalog { ,@{ settingInstance = New-IdsTestSettingInstance -Id 'synthetic.required' -Value @{ value = $false } } }
            deviceConfiguration { ,@{ $Property = $false } }
            compliance { ,@{ $Property = $false } }
            admx { ,@{ definition = @{ id = 'synthetic.required' }; enabled = $false; presentationValues = @() } }
            intent { ,@{ definitionId = 'synthetic.required'; value = $false } }
        }
        $collection = New-IdsTestAssessmentCollection @($policy)
        $collection.sources = @([pscustomobject]@{ family = $Family; platform = $Platform; complete = $true; errors = @() })
        $snapshot = ConvertTo-IdsAssessmentSnapshot $collection
        $pack = New-TestPack $mapping
        $pack.platform = $Platform
        $context = @{ platforms = @($Platform); osVersions = @{}; enrollmentModes = @{ androidEnterprise = 'fullyManaged' } }
        $result = Invoke-TestAssessment $pack $snapshot $context
        $result.controls[0].status | Should -BeExactly 'aligned'
        $result.controls[0].policyResults[0].policyKey | Should -BeExactly "${Family}:synthetic"
        $result.controls[0].observed[0].value | Should -BeFalse
        $result.controls[0].references[0].url | Should -BeExactly 'https://example.invalid/rules'
    }

    It 'consumes normalized unsupported evidence as incomplete rather than false absence' {
        $policy = New-IdsTestAssessmentPolicy -Settings @(@{
            settingInstance = @{ '@odata.type' = '#microsoft.graph.unknownSetting'; settingDefinitionId = 'unrelated.unknown' }
        }) -Template @{ platformType = 'windows11' }
        $collection = New-IdsTestAssessmentCollection @($policy)
        $collection.sources = @([pscustomobject]@{ family = 'settingsCatalog'; platform = 'windows11'; complete = $true; errors = @() })
        $snapshot = ConvertTo-IdsAssessmentSnapshot $collection
        (Invoke-TestAssessment (New-TestPack) $snapshot).controls[0].status | Should -BeExactly 'notAssessed'
    }

    It 'ignores unrelated failed sources but requires completeness of alternative relevant families' {
        $pack = New-TestPack
        $snapshot = New-TestSnapshot
        $snapshot.sources += [pscustomobject]@{ family = 'intent'; platform = 'windows11'; complete = $false; errors = @() }
        $snapshot.sources += [pscustomobject]@{ family = 'settingsCatalog'; platform = 'macos'; complete = $false; errors = @() }
        (Invoke-TestAssessment $pack $snapshot).controls[0].status | Should -BeExactly 'aligned'
        $alternative = New-TestMapping
        $alternative.family = 'intent'
        $alternative.policyTypes = @('deviceManagementIntent')
        $pack.controls[0].mappings += $alternative
        (Invoke-TestAssessment $pack $snapshot).controls[0].status | Should -BeExactly 'notAssessed'
    }

    It 'compares typed sets across policies using unordered duplicate-insensitive semantics' {
        $pack = New-TestPack (New-TestMapping stringSet setEquals @('a', 'b'))
        $first = New-TestObservation @('a', 'b') stringSet
        $second = New-TestObservation @('b', 'a', 'a') stringSet 'settingsCatalog:two'
        (Invoke-TestAssessment $pack (New-TestSnapshot @($first, $second))).controls[0].status | Should -BeExactly 'aligned'
        $second.value = @('a', 'c')
        (Invoke-TestAssessment $pack (New-TestSnapshot @($first, $second))).controls[0].status | Should -BeExactly 'potentialConflict'
    }

    It 'performs no file or network access' {
        $pack = New-TestPack
        $snapshot = New-TestSnapshot
        Mock Get-Content { throw 'Unexpected file read' }
        Mock Set-Content { throw 'Unexpected file write' }
        Mock Invoke-RestMethod { throw 'Unexpected network request' }
        Mock Invoke-WebRequest { throw 'Unexpected network request' }
        (Invoke-TestAssessment $pack $snapshot).controls[0].status | Should -BeExactly 'aligned'
        Should -Invoke Get-Content -Times 0
        Should -Invoke Set-Content -Times 0
        Should -Invoke Invoke-RestMethod -Times 0
        Should -Invoke Invoke-WebRequest -Times 0
    }

    It 'preserves equal duplicates per policy but not duplicate collection entries' {
        $one = New-TestObservation
        $two = New-TestObservation $true boolean 'settingsCatalog:two'
        $snapshot = New-TestSnapshot @($one, $one, $two)
        $control = (Invoke-TestAssessment (New-TestPack) $snapshot).controls[0]
        $control.status | Should -BeExactly 'aligned'
        $control.observed.Count | Should -Be 2
        $control.policyResults.Count | Should -Be 2
        $control.policyResults[0].observed.Count | Should -Be 1
        $control.policyResults[1].observed.Count | Should -Be 1
    }

    It 'uses mapping case semantics for same-policy <Type> duplicates (caseSensitive=<CaseSensitive>)' -ForEach @(
        @{ Type = 'string'; CaseSensitive = $false; Expected = 'ABC'; Other = 'abc'; Status = 'aligned'; Count = 1 }
        @{ Type = 'stringSet'; CaseSensitive = $false; Expected = @('ABC', 'DEF'); Other = @('def', 'abc', 'ABC'); Status = 'aligned'; Count = 1 }
        @{ Type = 'string'; CaseSensitive = $true; Expected = 'ABC'; Other = 'abc'; Status = 'notAssessed'; Count = 2 }
        @{ Type = 'stringSet'; CaseSensitive = $true; Expected = @('ABC', 'DEF'); Other = @('def', 'abc', 'ABC'); Status = 'notAssessed'; Count = 2 }
    ) {
        $mapping = New-TestMapping $Type eq $Expected
        $mapping.caseSensitive = $CaseSensitive
        $snapshot = New-TestSnapshot @((New-TestObservation $Expected $Type), (New-TestObservation $Other $Type))
        $control = (Invoke-TestAssessment (New-TestPack $mapping) $snapshot).controls[0]
        $control.status | Should -BeExactly $Status
        $control.policyResults[0].status | Should -BeExactly $Status
        $control.observed.Count | Should -Be $Count
        $control.policyResults[0].observed.Count | Should -Be $Count
    }

    It 'retains separate policy evidence under <Type> case semantics (caseSensitive=<CaseSensitive>)' -ForEach @(
        @{ Type = 'string'; CaseSensitive = $false; Expected = 'ABC'; Other = 'abc'; Status = 'aligned'; OtherStatus = 'aligned' }
        @{ Type = 'stringSet'; CaseSensitive = $false; Expected = @('ABC', 'DEF'); Other = @('def', 'abc'); Status = 'aligned'; OtherStatus = 'aligned' }
        @{ Type = 'string'; CaseSensitive = $true; Expected = 'ABC'; Other = 'abc'; Status = 'potentialConflict'; OtherStatus = 'misaligned' }
        @{ Type = 'stringSet'; CaseSensitive = $true; Expected = @('ABC', 'DEF'); Other = @('def', 'abc'); Status = 'potentialConflict'; OtherStatus = 'misaligned' }
    ) {
        $mapping = New-TestMapping $Type eq $Expected
        $mapping.caseSensitive = $CaseSensitive
        $snapshot = New-TestSnapshot @(
            (New-TestObservation $Expected $Type),
            (New-TestObservation $Other $Type 'settingsCatalog:two')
        )
        $control = (Invoke-TestAssessment (New-TestPack $mapping) $snapshot).controls[0]
        $control.status | Should -BeExactly $Status
        $control.observed.Count | Should -Be 2
        $control.policyResults.Count | Should -Be 2
        $control.policyResults[0].policyKey | Should -BeExactly 'settingsCatalog:one'
        $control.policyResults[0].status | Should -BeExactly 'aligned'
        $control.policyResults[1].policyKey | Should -BeExactly 'settingsCatalog:two'
        $control.policyResults[1].status | Should -BeExactly $OtherStatus
    }

    It 'keeps both matching and violating policies when boolean values differ' {
        $snapshot = New-TestSnapshot @((New-TestObservation), (New-TestObservation $false boolean 'settingsCatalog:two'))
        $control = (Invoke-TestAssessment (New-TestPack) $snapshot).controls[0]
        $control.status | Should -BeExactly 'potentialConflict'
        ($control.policyResults | Where-Object policyKey -EQ 'settingsCatalog:one').status | Should -BeExactly 'aligned'
        ($control.policyResults | Where-Object policyKey -EQ 'settingsCatalog:two').status | Should -BeExactly 'misaligned'
    }

    It 'reports false and zero as configured rather than missing' -ForEach @(
        @{ Value = $false; Type = 'boolean' }; @{ Value = 0; Type = 'number' }
    ) {
        $pack = New-TestPack (New-TestMapping $Type eq $Value)
        $control = (Invoke-TestAssessment $pack (New-TestSnapshot @((New-TestObservation $Value $Type)))).controls[0]
        $control.status | Should -BeExactly 'aligned'
        $control.observed[0].configured | Should -BeTrue
        $control.observed[0].value | Should -Be $Value
    }

    It 'requires all complete relevant sources before absence can mean missing' {
        $pack = New-TestPack
        $snapshot = New-TestSnapshot @()
        $control = (Invoke-TestAssessment $pack $snapshot).controls[0]
        $control.status | Should -BeExactly 'missing'
        $control.observed -is [array] | Should -BeTrue
        $control.observed.Count | Should -Be 0
        $control.policyResults -is [array] | Should -BeTrue
        $nullValue = New-TestObservation $null
        $nullValue.configured = $false
        (Invoke-TestAssessment $pack (New-TestSnapshot @($nullValue))).controls[0].status | Should -BeExactly 'missing'
    }

    It 'flags unassigned alignment without claiming device compliance and keeps assignment failure separate' {
        $snapshot = New-TestSnapshot
        $pack = New-TestPack
        $control = (Invoke-TestAssessment $pack $snapshot).controls[0]
        $control.status | Should -BeExactly 'aligned'
        $control.policyResults[0].assigned | Should -BeFalse
        $control.policyResults[0].reason | Should -Match 'unassigned'
        $control.reason | Should -Match 'not device compliance'
        $snapshot.policies[0].assignmentsComplete = $false
        $snapshot.issues = @([pscustomobject]@{
            family = 'settingsCatalog'; policyKey = 'settingsCatalog:one'; stage = 'assignments'; statusCode = 403; reason = 'Synthetic denied assignments.'
        })
        $control = (Invoke-TestAssessment $pack $snapshot).controls[0]
        $control.status | Should -BeExactly 'aligned'
        $control.policyResults[0].assigned | Should -BeNullOrEmpty
        $control.policyResults[0].assignmentsComplete | Should -BeFalse
        $control.policyResults[0].reason | Should -Match 'unknown'
        $snapshot.policies[0].assignmentsComplete = $true
        $snapshot.policies[0].assignments = @(@{ target = @{ '@odata.type' = '#microsoft.graph.allDevicesAssignmentTarget' } })
        (Invoke-TestAssessment $pack $snapshot).controls[0].policyResults[0].assigned | Should -BeTrue
    }

    It 'matches stable family, type, identifier and exact literal instance path, never display labels' -ForEach @(
        @{ Dimension = 'family' }; @{ Dimension = 'type' }; @{ Dimension = 'identifier' }; @{ Dimension = 'path' }
    ) {
        $mapping = New-TestMapping
        $mapping.instancePath = '/group[0]/synthetic.required[0]'
        $snapshot = New-TestSnapshot
        $snapshot.observations[0].instancePath = $mapping.instancePath
        switch ($Dimension) {
            family { $snapshot.observations[0].family = 'intent' }
            type { $snapshot.policies[0].policyType = 'unrelatedPolicyType' }
            identifier { $snapshot.observations[0].settingId = 'Synthetic.Required' }
            path { $snapshot.observations[0].instancePath = '/group[1]/synthetic.required[0]' }
        }
        (Invoke-TestAssessment (New-TestPack $mapping) $snapshot).controls[0].status | Should -BeExactly 'missing'
    }

    It 'treats alternative mappings as sources for one atomic check, not required compound clauses' {
        $pack = New-TestPack
        $alternative = New-TestMapping
        $alternative.settingId = 'synthetic.alternative'
        $pack.controls[0].mappings += $alternative
        $snapshot = New-TestSnapshot
        $snapshot.observations[0].settingId = 'synthetic.alternative'
        $control = (Invoke-TestAssessment $pack $snapshot).controls[0]
        $control.status | Should -BeExactly 'aligned'
        $control.policyResults.Count | Should -Be 1
        $control.observed.Count | Should -Be 1
    }

    It 'recognizes differing values for equivalent alternative selectors across policies' {
        $pack = New-TestPack
        $alternative = New-TestMapping
        $alternative.family = 'intent'; $alternative.policyTypes = @('deviceManagementIntent')
        $alternative.settingId = 'synthetic.equivalent'
        $pack.controls[0].mappings += $alternative
        $snapshot = New-TestSnapshot @((New-TestObservation), (New-TestObservation $false boolean 'intent:two'))
        $intent = $snapshot.policies | Where-Object key -EQ 'intent:two'
        $intent.family = 'intent'; $intent.policyType = 'deviceManagementIntent'
        $snapshot.observations[1].family = 'intent'; $snapshot.observations[1].settingId = 'synthetic.equivalent'
        $snapshot.observations[1].instancePath = '/synthetic.equivalent[0]'
        $snapshot.sources += [pscustomobject]@{ family = 'intent'; platform = 'windows11'; complete = $true; errors = @() }
        (Invoke-TestAssessment $pack $snapshot).controls[0].status | Should -BeExactly 'potentialConflict'
    }

    It 'does not combine sets from separate repeated instances into a passing set' {
        $pack = New-TestPack (New-TestMapping stringSet containsAll @('a', 'b'))
        $first = New-TestObservation @('a') stringSet
        $second = New-TestObservation @('b') stringSet
        $first.instancePath = '/group[0]/child[0]'
        $second.instancePath = '/group[1]/child[0]'
        $control = (Invoke-TestAssessment $pack (New-TestSnapshot @($first, $second))).controls[0]
        $control.status | Should -BeExactly 'misaligned'
        $control.observed.Count | Should -Be 2
        $control.policyResults[0].observed.Count | Should -Be 2
    }

    It 'does not flag different repeated-instance paths in separate policies as the same setting conflict' {
        $pack = New-TestPack (New-TestMapping number gte 8)
        $first = New-TestObservation 8 number
        $second = New-TestObservation 12 number 'settingsCatalog:two'
        $first.instancePath = '/group[0]/child[0]'
        $second.instancePath = '/group[1]/child[0]'
        (Invoke-TestAssessment $pack (New-TestSnapshot @($first, $second))).controls[0].status | Should -BeExactly 'aligned'
    }

    It 'preserves potential conflict details when one value has an unsupported mapping type' {
        $snapshot = New-TestSnapshot @((New-TestObservation), (New-TestObservation 'true' string 'settingsCatalog:two'))
        $control = (Invoke-TestAssessment (New-TestPack) $snapshot).controls[0]
        $control.status | Should -BeExactly 'notAssessed'
        $control.reason | Should -Match 'potential conflict'
        $control.observed[1].value | Should -BeExactly 'true'
    }

    It 'does not silently choose between contradictory duplicate evidence for one policy identity' {
        $snapshot = New-TestSnapshot @((New-TestObservation), (New-TestObservation $false))
        $control = (Invoke-TestAssessment (New-TestPack) $snapshot).controls[0]
        $control.status | Should -BeExactly 'notAssessed'
        $control.reason | Should -Match 'contradictory'
        $control.observed.Count | Should -Be 2
    }

    It 'sorts evidence reproducibly without mutating inputs or copying raw policy data' {
        $one = New-TestObservation $true
        $one.settingId = 'synthetic.alternative'
        $two = New-TestObservation $true
        $pack = New-TestPack
        $mapping = New-TestMapping
        $mapping.settingId = 'synthetic.alternative'
        $pack.controls[0].mappings += $mapping
        $snapshot = New-TestSnapshot @($one, $two)
        $snapshot.policies[0] | Add-Member rawSettings @(@{ token = 'SYNTHETIC-NEVER-COPY' })
        $snapshot.policies[0] | Add-Member accessToken 'SYNTHETIC-NEVER-COPY'
        $before = $snapshot | ConvertTo-Json -Depth 30 -Compress
        $first = Invoke-TestAssessment $pack $snapshot | ConvertTo-Json -Depth 30 -Compress
        ($snapshot | ConvertTo-Json -Depth 30 -Compress) | Should -BeExactly $before
        $first | Should -Not -Match 'rawSettings|accessToken|SYNTHETIC-NEVER-COPY'
        [array]::Reverse($snapshot.observations)
        $second = Invoke-TestAssessment $pack $snapshot | ConvertTo-Json -Depth 30 -Compress
        $second | Should -BeExactly $first
    }

    It 'applies explicit exclusion before incomplete evidence and unknown dimensions' {
        $pack = New-TestPack
        $pack.platform = 'androidEnterprise'
        $pack.controls[0].applicability.osMin = '14.0'
        $pack.controls[0].applicability.enrollmentModes = @('fullyManaged')
        $snapshot = New-TestSnapshot
        $snapshot.sources[0].complete = $false
        $context = @{ platforms = @('androidEnterprise'); osVersions = @{}; enrollmentModes = @{ androidEnterprise = 'workProfile' } }
        $control = (Invoke-TestAssessment $pack $snapshot $context).controls[0]
        $control.status | Should -BeExactly 'notApplicable'
        $control.reason | Should -Match 'enrollment'
    }

    It 'recognizes numeric OS versions with one to four components at inclusive bounds' -ForEach @(
        @{ Minimum = '14'; Maximum = '14.0'; Selected = '14.0.0' }
        @{ Minimum = '14.0'; Maximum = '14.0.0.0'; Selected = '14' }
        @{ Minimum = '14.0.1'; Maximum = '14.0.1.0'; Selected = '14.0.1' }
    ) {
        $pack = New-TestPack
        $pack.controls[0].applicability.osMin = $Minimum
        $pack.controls[0].applicability.osMax = $Maximum
        $context = @{ platforms = @('windows11'); osVersions = @{ windows11 = $Selected }; enrollmentModes = @{} }
        (Invoke-TestAssessment $pack (New-TestSnapshot) $context).controls[0].status | Should -BeExactly 'aligned'
    }

    It 'requires known applicability for <Dimension>' -ForEach @(
        @{ Dimension = 'selected platform' }
        @{ Dimension = 'omitted platform context' }
        @{ Dimension = 'control OS minimum' }
        @{ Dimension = 'control OS maximum' }
        @{ Dimension = 'invalid OS version' }
        @{ Dimension = 'enrollment mode' }
        @{ Dimension = 'policy platform' }
        @{ Dimension = 'policy OS bounds' }
        @{ Dimension = 'policy enrollment mode' }
    ) {
        $pack = New-TestPack
        $snapshot = New-TestSnapshot
        $context = @{ platforms = @('windows11'); osVersions = @{}; enrollmentModes = @{} }
        switch ($Dimension) {
            'selected platform' { $context.platforms = @() }
            'omitted platform context' { $context.Remove('platforms') }
            'control OS minimum' { $pack.controls[0].applicability.osMin = '10.0.22000' }
            'control OS maximum' { $pack.controls[0].applicability.osMax = '10.0.99999' }
            'invalid OS version' { $pack.controls[0].applicability.osMin = '10.0'; $context.osVersions.windows11 = 'invalid' }
            'enrollment mode' {
                $pack.platform = 'androidEnterprise'; $context.platforms = @('androidEnterprise')
                $pack.controls[0].applicability.enrollmentModes = @('fullyManaged')
                $snapshot.sources[0].platform = 'androidEnterprise'
                $snapshot.policies[0].platform = 'androidEnterprise'
                $snapshot.policies[0].enrollmentMode = 'fullyManaged'
            }
            'policy platform' { $snapshot.policies[0].platform = $null }
            'policy OS bounds' { $snapshot.policies[0].osMin = '10.0.22000' }
            'policy enrollment mode' {
                $pack.platform = 'androidEnterprise'; $context.platforms = @('androidEnterprise')
                $context.enrollmentModes.androidEnterprise = 'fullyManaged'
                $snapshot.policies[0].platform = 'androidEnterprise'
                $snapshot.sources[0].platform = 'androidEnterprise'
            }
        }
        $control = (Invoke-TestAssessment $pack $snapshot $context).controls[0]
        $control.status | Should -BeExactly 'notAssessed'
        @($control.policyResults | Where-Object { $_.status -in @('aligned', 'missing') }).Count | Should -Be 0
    }

    It 'does not infer Android enrollment applicability from an unrestricted control with <Evidence>' -ForEach @(
        @{ Evidence = 'no context or policy mode'; Selected = $null; PolicyMode = $null; Configured = $true }
        @{ Evidence = 'no context and absent value'; Selected = $null; PolicyMode = $null; Configured = $false }
        @{ Evidence = 'known policy mode only'; Selected = $null; PolicyMode = 'fullyManaged'; Configured = $true }
        @{ Evidence = 'known context only'; Selected = 'fullyManaged'; PolicyMode = $null; Configured = $true }
    ) {
        $pack = New-TestPack
        $pack.platform = 'androidEnterprise'
        $pack.controls[0].applicability.enrollmentModes.Count | Should -Be 0
        $observation = New-TestObservation
        $observation.configured = $Configured
        $snapshot = New-TestSnapshot @($observation)
        $snapshot.sources[0].platform = 'androidEnterprise'
        $snapshot.policies[0].platform = 'androidEnterprise'
        $snapshot.policies[0].enrollmentMode = $PolicyMode
        $context = @{ platforms = @('androidEnterprise'); osVersions = @{} }
        if ($Selected) { $context.enrollmentModes = @{ androidEnterprise = $Selected } }

        $control = (Invoke-TestAssessment $pack $snapshot $context).controls[0]
        $control.status | Should -BeExactly 'notAssessed'
        $control.policyResults[0].status | Should -BeExactly 'notAssessed'
        $control.reason | Should -Match 'enrollment'
    }

    It 'does not infer missing Android settings without enrollment context even with no policies' {
        $pack = New-TestPack
        $pack.platform = 'androidEnterprise'
        $snapshot = New-TestSnapshot @()
        $snapshot.sources[0].platform = 'androidEnterprise'
        $context = @{ platforms = @('androidEnterprise'); osVersions = @{}; enrollmentModes = @{} }
        (Invoke-TestAssessment $pack $snapshot $context).controls[0].status | Should -BeExactly 'notAssessed'
    }

    It 'allows an unrestricted Android control when enrollment context and policy metadata are known' {
        $pack = New-TestPack
        $pack.platform = 'androidEnterprise'
        $snapshot = New-TestSnapshot
        $snapshot.sources[0].platform = 'androidEnterprise'
        $snapshot.policies[0].platform = 'androidEnterprise'
        $snapshot.policies[0].enrollmentMode = 'fullyManaged'
        $context = @{ platforms = @('androidEnterprise'); osVersions = @{}; enrollmentModes = @{ androidEnterprise = 'fullyManaged' } }
        $control = (Invoke-TestAssessment $pack $snapshot $context).controls[0]
        $control.status | Should -BeExactly 'aligned'
        $control.policyResults[0].status | Should -BeExactly 'aligned'
    }

    It 'excludes policies explicitly outside the selected platform, OS or enrollment scope' -ForEach @(
        @{ Scope = 'platform' }; @{ Scope = 'OS' }; @{ Scope = 'enrollment' }
    ) {
        $pack = New-TestPack
        $snapshot = New-TestSnapshot @((New-TestObservation), (New-TestObservation $false boolean 'settingsCatalog:two'))
        $context = @{ platforms = @('windows11'); osVersions = @{ windows11 = '10.0.22631' }; enrollmentModes = @{} }
        switch ($Scope) {
            platform { $snapshot.policies[1].platform = 'macos' }
            OS { $snapshot.policies[1].osMax = '10.0.22000' }
            enrollment {
                $pack.platform = 'androidEnterprise'; $context.platforms = @('androidEnterprise')
                $context.enrollmentModes.androidEnterprise = 'fullyManaged'
                $snapshot.sources[0].platform = 'androidEnterprise'
                $snapshot.policies[0].platform = 'androidEnterprise'; $snapshot.policies[0].enrollmentMode = 'fullyManaged'
                $snapshot.policies[1].platform = 'androidEnterprise'; $snapshot.policies[1].enrollmentMode = 'dedicated'
            }
        }
        $snapshot.policies[1].settingsComplete = $false
        $control = (Invoke-TestAssessment $pack $snapshot $context).controls[0]
        $control.status | Should -BeExactly 'aligned'
        $control.observed.Count | Should -Be 1
        $control.policyResults.Count | Should -Be 1
    }

    It 'leaves manual and unsupported mappings not assessed with their reason' {
        $pack = New-TestPack
        $pack.controls[0].mappings = @()
        $pack.controls[0].manualReason = 'Manual review of a compound requirement.'
        $control = (Invoke-TestAssessment $pack (New-TestSnapshot)).controls[0]
        $control.status | Should -BeExactly 'notAssessed'
        $control.reason | Should -Match 'Manual review'
        $pack.controls[0].manualReason = $null
        $control = (Invoke-TestAssessment $pack (New-TestSnapshot)).controls[0]
        $control.status | Should -BeExactly 'notAssessed'
        $control.reason | Should -Match 'mapping'
    }

    It 'does not dismiss an incomplete source with <Failure> diagnostics' -ForEach @(
        @{ Failure = 'null'; Errors = $null }
        @{ Failure = 'empty'; Errors = @() }
        @{ Failure = 'unknown stage'; Errors = @(@{ family = 'settingsCatalog'; policyKey = 'settingsCatalog:two'; stage = 'unknown' }) }
        @{ Failure = 'policy-scoped inventory'; Errors = @(@{ family = 'settingsCatalog'; policyKey = 'settingsCatalog:two'; stage = 'inventory' }) }
        @{ Failure = 'global settings'; Errors = @(@{ family = 'settingsCatalog'; policyKey = $null; stage = 'settings' }) }
        @{ Failure = 'unresolved policy'; Errors = @(@{ family = 'settingsCatalog'; policyKey = 'settingsCatalog:unknown'; stage = 'settings' }) }
        @{ Failure = 'wrong family'; Errors = @(@{ family = 'intent'; policyKey = 'settingsCatalog:two'; stage = 'settings' }) }
    ) {
        $pack = New-TestPack
        $snapshot = New-TestSnapshot @((New-TestObservation), (New-TestObservation $false boolean 'settingsCatalog:two'))
        $snapshot.policies[1].platform = 'macos'
        $snapshot.policies[1].settingsComplete = $false
        $snapshot.sources[0].complete = $false
        $snapshot.sources[0].errors = $Errors
        $control = (Invoke-TestAssessment $pack $snapshot).controls[0]
        $control.status | Should -BeExactly 'notAssessed'
        $control.reason | Should -Match 'incomplete'
    }

    It 'cannot pass or infer absence with <Failure>' -ForEach @(
        @{ Failure = 'failed source' }
        @{ Failure = 'unreported source' }
        @{ Failure = 'failed settings' }
        @{ Failure = 'unsupported observation' }
        @{ Failure = 'secret observation' }
        @{ Failure = 'wrong typed observation' }
        @{ Failure = 'failed empty source' }
    ) {
        $pack = New-TestPack
        $snapshot = New-TestSnapshot
        switch ($Failure) {
            'failed source' { $snapshot.sources[0].complete = $false }
            'unreported source' { $snapshot.sources = @() }
            'failed settings' { $snapshot.policies[0].settingsComplete = $false }
            'unsupported observation' { $snapshot.observations[0].supported = $false }
            'secret observation' { $snapshot.observations[0].secret = $true }
            'wrong typed observation' { $snapshot.observations[0].valueType = 'string'; $snapshot.observations[0].value = 'true' }
            'failed empty source' { $snapshot.observations = @(); $snapshot.sources[0].complete = $false }
        }
        $control = (Invoke-TestAssessment $pack $snapshot).controls[0]
        $control.status | Should -BeExactly 'notAssessed'
        $control.reason | Should -Not -BeNullOrEmpty
        if ($Failure -eq 'secret observation') { $control.observed[0].value | Should -BeNullOrEmpty }
    }

    It 'keeps mismatch and potential conflict evidence visible under incomplete collection' {
        $snapshot = New-TestSnapshot @((New-TestObservation), (New-TestObservation $false boolean 'settingsCatalog:two'))
        $snapshot.sources[0].complete = $false
        $control = (Invoke-TestAssessment (New-TestPack) $snapshot).controls[0]
        $control.status | Should -BeExactly 'notAssessed'
        $control.reason | Should -Match 'potential conflict'
        $control.reason | Should -Match 'violat'
        ($control.policyResults | Where-Object policyKey -EQ 'settingsCatalog:two').status | Should -BeExactly 'misaligned'
        $control.observed.Count | Should -Be 2
    }

    It 'uses configured evidence in another policy despite explicit null or absence' {
        $absent = New-TestObservation $null boolean 'settingsCatalog:two'
        $absent.configured = $false
        $snapshot = New-TestSnapshot @((New-TestObservation), $absent)
        $control = (Invoke-TestAssessment (New-TestPack) $snapshot).controls[0]
        $control.status | Should -BeExactly 'aligned'
        ($control.policyResults | Where-Object policyKey -EQ 'settingsCatalog:two').status | Should -BeExactly 'missing'
    }

    It 'reports differing cross-policy values as potential conflict even when both meet the bound' {
        $pack = New-TestPack (New-TestMapping number gte 8)
        $snapshot = New-TestSnapshot @((New-TestObservation 8 number), (New-TestObservation 12 number 'settingsCatalog:two'))
        $result = Invoke-TestAssessment $pack $snapshot
        $result.controls[0].status | Should -BeExactly 'potentialConflict'
        $result.controls[0].observed.Count | Should -Be 2
        $result.controls[0].policyResults.Count | Should -Be 2
        @($result.controls[0].policyResults | Where-Object status -NE aligned).Count | Should -Be 0
        $result.controls[0].reason | Should -Match 'targeting'
    }
}

Describe 'Collector to rules failure isolation' -Tag 'CollectionIntegration' {
    It 'assesses only relevant settings failures with <Scope> and configured=<Configured>' -ForEach @(
        @{ Scope = 'excluded OS'; Configured = $true; Status = 'aligned' }
        @{ Scope = 'excluded OS'; Configured = $false; Status = 'missing' }
        @{ Scope = 'excluded enrollment'; Configured = $true; Status = 'aligned' }
        @{ Scope = 'excluded enrollment'; Configured = $false; Status = 'missing' }
        @{ Scope = 'relevant policy'; Configured = $true; Status = 'notAssessed' }
        @{ Scope = 'relevant policy'; Configured = $false; Status = 'notAssessed' }
        @{ Scope = 'unknown OS'; Configured = $true; Status = 'notAssessed' }
        @{ Scope = 'unknown platform'; Configured = $true; Status = 'notAssessed' }
        @{ Scope = 'unknown enrollment'; Configured = $true; Status = 'notAssessed' }
        @{ Scope = 'failed inventory'; Configured = $true; Status = 'notAssessed' }
        @{ Scope = 'failed inventory'; Configured = $false; Status = 'notAssessed' }
    ) {
        $pack = New-TestPack
        $context = @{ platforms = @('windows11'); osVersions = @{ windows11 = '10.0.22631' }; enrollmentModes = @{} }
        $goodPolicy = @{
            id = 'good'; platforms = 'windows10'
            templateReference = @{ platformType = 'windows11' }
        }
        $failedPolicy = @{
            id = 'failed'; platforms = 'windows10'
            templateReference = @{ platformType = 'windows11' }
        }
        switch ($Scope) {
            'excluded OS' { $failedPolicy.osMaximumVersion = '10.0.22000' }
            'unknown OS' { $failedPolicy.osMaximumVersion = '10.0.22000'; $context.osVersions = @{} }
            'unknown platform' { $failedPolicy.Remove('platforms'); $failedPolicy.Remove('templateReference') }
            'failed inventory' { $failedPolicy.osMaximumVersion = '10.0.22000' }
        }
        if ($Scope -in @('excluded enrollment', 'unknown enrollment')) {
            $pack.platform = 'androidEnterprise'
            $context.platforms = @('androidEnterprise')
            $context.enrollmentModes.androidEnterprise = 'fullyManaged'
            foreach ($policy in @($goodPolicy, $failedPolicy)) {
                $policy.platforms = 'androidEnterprise'
                $policy.templateReference.platformType = 'androidEnterprise'
                $policy.enrollmentMode = 'fullyManaged'
            }
            $failedPolicy.enrollmentMode = if ($Scope -eq 'excluded enrollment') { 'dedicated' } else { $null }
        }
        $script:integrationInventory = @{ value = @($goodPolicy, $failedPolicy) }
        if ($Scope -eq 'failed inventory') {
            $script:integrationInventory['@odata.nextLink'] = 'https://graph.microsoft.com/beta/deviceManagement/configurationPolicies?page=2'
        }
        $script:integrationSettings = @(if ($Configured) {
            @{ settingInstance = New-IdsTestSettingInstance -Id 'synthetic.required' -Value @{ value = $true } }
        })
        Mock Invoke-IdsGraph {
            param($Path)
            if ($Path -ceq '/deviceManagement/configurationPolicies') { return $script:integrationInventory }
            throw 'Synthetic inventory continuation failure.'
        }
        Mock Invoke-IdsGraphBatch {
            param($Requests)
            $responses = @{}
            foreach ($request in $Requests) {
                $entry = @{ status = 200; body = @{ value = @() } }
                if ($request.url -match "/configurationPolicies\('failed'\)/settings") {
                    $entry = @{ status = 403; body = @{ value = @() } }
                } elseif ($request.url -match '/settings\?') {
                    $entry.body.value = $script:integrationSettings
                }
                $responses[$request.id] = $entry
            }
            return $responses
        }

        $collection = Get-IdsAssessmentCollection -Packs @($pack) -Context $context
        $collection.sources[0].complete | Should -BeFalse
        ($collection.policies | Where-Object key -EQ 'settingsCatalog:good').settingsComplete | Should -BeTrue
        ($collection.policies | Where-Object key -EQ 'settingsCatalog:failed').settingsComplete | Should -BeFalse
        $collection.sources[0].errors.policyKey | Should -Contain 'settingsCatalog:failed'
        ($collection.issues | Where-Object { $_.policyKey -eq 'settingsCatalog:failed' -and $_.stage -eq 'settings' }).statusCode | Should -Be 403
        $snapshot = ConvertTo-IdsAssessmentSnapshot $collection
        $snapshot.sources[0].complete | Should -BeFalse
        $control = (Invoke-TestAssessment $pack $snapshot $context).controls[0]
        $control.status | Should -BeExactly $Status -Because $control.reason
        if ($Status -ne 'notAssessed') {
            $control.policyResults.Count | Should -Be 1
            $control.policyResults[0].policyKey | Should -BeExactly 'settingsCatalog:good'
            $control.policyResults[0].status | Should -BeExactly $Status
            $control.observed.Count | Should -Be ([int]$Configured)
        } else {
            $control.reason | Should -Match 'incomplete|unknown'
        }
    }
}

Describe 'Typed value comparison' {
    It 'does not round distinct numeric evidence into a false match for <Operator>' -ForEach @(
        @{ Operator = 'eq'; Type = 'number'; Expected = [long]9007199254740993; Value = [double]9007199254740992 }
        @{ Operator = 'gte'; Type = 'number'; Expected = [long]9007199254740993; Value = [double]9007199254740992 }
        @{ Operator = 'lte'; Type = 'number'; Expected = [double]9007199254740992; Value = [long]9007199254740993 }
        @{ Operator = 'in'; Type = 'number'; Expected = @([long]9007199254740993); Value = [double]9007199254740992 }
        @{ Operator = 'setEquals'; Type = 'numberSet'; Expected = @([long]9007199254740993); Value = @([double]9007199254740992) }
        @{ Operator = 'eq'; Type = 'number'; Expected = [decimal]'0.1234567890123456789012345678'; Value = [double]0.12345678901234568 }
    ) {
        $result = Compare-IdsAssessmentValue (New-TestMapping $Type $Operator $Expected) (New-TestObservation $Value $Type)
        $result.assessed | Should -BeTrue
        $result.aligned | Should -BeFalse
    }

    It 'compares equal numeric values across finite CLR types and exponent ranges' -ForEach @(
        @{ Expected = [decimal]'0.1'; Value = [double]0.1 }
        @{ Expected = [long]1; Value = [double]1.0 }
        @{ Expected = [uint64]::MaxValue; Value = [decimal]'18446744073709551615' }
        @{ Expected = [double]::Epsilon; Value = [double]::Epsilon }
        @{ Expected = [double]::MaxValue; Value = [double]::MaxValue }
        @{ Expected = [single]0.1; Value = [double]0.1 }
    ) {
        $result = Compare-IdsAssessmentValue (New-TestMapping number eq $Expected) (New-TestObservation $Value number)
        $result.assessed | Should -BeTrue
        $result.aligned | Should -BeTrue
    }

    It 'evaluates <Label> without coercing values' -ForEach @(
        @{ Label = 'false equality'; Type = 'boolean'; Op = 'eq'; Expected = $false; Value = $false; Aligned = $true }
        @{ Label = 'false inequality'; Type = 'boolean'; Op = 'ne'; Expected = $true; Value = $false; Aligned = $true }
        @{ Label = 'zero equality'; Type = 'number'; Op = 'eq'; Expected = 0; Value = 0; Aligned = $true }
        @{ Label = 'number inequality'; Type = 'number'; Op = 'ne'; Expected = 8; Value = 8; Aligned = $false }
        @{ Label = 'lower bound'; Type = 'number'; Op = 'gte'; Expected = 8; Value = 8; Aligned = $true }
        @{ Label = 'failed lower bound'; Type = 'number'; Op = 'gte'; Expected = 8; Value = 7; Aligned = $false }
        @{ Label = 'upper bound'; Type = 'number'; Op = 'lte'; Expected = 8; Value = 8; Aligned = $true }
        @{ Label = 'failed upper bound'; Type = 'number'; Op = 'lte'; Expected = 8; Value = 9; Aligned = $false }
        @{ Label = 'case-sensitive strings'; Type = 'string'; Op = 'eq'; Expected = 'ABC'; Value = 'abc'; Aligned = $false }
        @{ Label = 'ordinal strings'; Type = 'string'; Op = 'ne'; Expected = 'ABC'; Value = 'ABC'; Aligned = $false }
        @{ Label = 'empty string'; Type = 'string'; Op = 'eq'; Expected = ''; Value = ''; Aligned = $true }
        @{ Label = 'string membership'; Type = 'string'; Op = 'in'; Expected = @('id_0', 'id_1'); Value = 'id_0'; Aligned = $true }
        @{ Label = 'numeric membership'; Type = 'number'; Op = 'in'; Expected = @(0, 8); Value = 0; Aligned = $true }
        @{ Label = 'boolean membership'; Type = 'boolean'; Op = 'in'; Expected = @($true); Value = $false; Aligned = $false }
        @{ Label = 'string set equality'; Type = 'stringSet'; Op = 'setEquals'; Expected = @('a', 'b'); Value = @('b', 'a', 'a'); Aligned = $true }
        @{ Label = 'numeric set equality'; Type = 'numberSet'; Op = 'eq'; Expected = @(0, 1); Value = @(1, 0, 0); Aligned = $true }
        @{ Label = 'set inequality'; Type = 'numberSet'; Op = 'ne'; Expected = @(0, 1); Value = @(1, 0); Aligned = $false }
        @{ Label = 'string containment'; Type = 'stringSet'; Op = 'containsAll'; Expected = @('a'); Value = @('a', 'b'); Aligned = $true }
        @{ Label = 'numeric containment'; Type = 'numberSet'; Op = 'containsAll'; Expected = @(0); Value = @(0, 1); Aligned = $true }
        @{ Label = 'failed containment'; Type = 'numberSet'; Op = 'containsAll'; Expected = @(0, 2); Value = @(0, 1); Aligned = $false }
        @{ Label = 'empty sets'; Type = 'numberSet'; Op = 'setEquals'; Expected = @(); Value = @(); Aligned = $true }
        @{ Label = 'empty subset'; Type = 'stringSet'; Op = 'containsAll'; Expected = @(); Value = @('a'); Aligned = $true }
        @{ Label = 'not display joined'; Type = 'stringSet'; Op = 'setEquals'; Expected = @('a,b'); Value = @('a', 'b'); Aligned = $false }
    ) {
        $result = Compare-IdsAssessmentValue (New-TestMapping $Type $Op $Expected) (New-TestObservation $Value $Type)
        $result.assessed | Should -BeTrue
        $result.aligned | Should -Be $Aligned
        $result.reason | Should -Not -BeNullOrEmpty
    }

    It 'uses explicit case insensitivity for <Operator>' -ForEach @(
        @{ Operator = 'eq'; Type = 'string'; Expected = 'ABC'; Value = 'abc' }
        @{ Operator = 'in'; Type = 'string'; Expected = @('ABC'); Value = 'abc' }
        @{ Operator = 'setEquals'; Type = 'stringSet'; Expected = @('ABC', 'xyz'); Value = @('abc', 'XYZ') }
        @{ Operator = 'containsAll'; Type = 'stringSet'; Expected = @('ABC'); Value = @('abc', 'XYZ') }
    ) {
        $mapping = New-TestMapping $Type $Operator $Expected
        $mapping.caseSensitive = $false
        (Compare-IdsAssessmentValue $mapping (New-TestObservation $Value $Type)).aligned | Should -BeTrue
    }

    It 'rejects incompatible <Type> <Operator>' -ForEach @(
        foreach ($type in @('boolean', 'number', 'string', 'stringSet', 'numberSet')) {
            foreach ($operator in @('gte', 'lte', 'in', 'setEquals', 'containsAll', 'unsupported')) {
                $set = $type -in @('stringSet', 'numberSet')
                if ($operator -eq 'unsupported' -or
                    ($operator -in @('gte', 'lte') -and $type -ne 'number') -or
                    ($operator -in @('setEquals', 'containsAll') -and -not $set) -or
                    ($operator -eq 'in' -and $set)) {
                    @{ Type = $type; Operator = $operator }
                }
            }
        }
    ) {
        $value = switch ($Type) { boolean { $true }; number { 1 }; string { 'a' }; stringSet { ,@('a') }; numberSet { ,@(1) } }
        $result = Compare-IdsAssessmentValue (New-TestMapping $Type $Operator $value) (New-TestObservation $value $Type)
        $result.assessed | Should -BeFalse
        $result.aligned | Should -BeFalse
        $result.reason | Should -Not -BeNullOrEmpty
    }

    It 'rejects <Label> at the value boundary' -ForEach @(
        @{ Label = 'string encoded boolean'; Type = 'boolean'; Op = 'eq'; Expected = $true; Value = 'true' }
        @{ Label = 'numeric boolean'; Type = 'boolean'; Op = 'eq'; Expected = $false; Value = 0 }
        @{ Label = 'numeric string lying about its type'; Type = 'number'; Op = 'gte'; Expected = 8; Value = '12' }
        @{ Label = 'null configured scalar'; Type = 'number'; Op = 'eq'; Expected = 0; Value = $null }
        @{ Label = 'mixed number set'; Type = 'numberSet'; Op = 'eq'; Expected = @(1); Value = @(1, '2') }
        @{ Label = 'mixed string set'; Type = 'stringSet'; Op = 'eq'; Expected = @('a'); Value = @('a', 2) }
        @{ Label = 'nested set'; Type = 'numberSet'; Op = 'eq'; Expected = @(1); Value = @(@(1, 2), 3) }
        @{ Label = 'object'; Type = 'string'; Op = 'eq'; Expected = 'a'; Value = @{ value = 'a' } }
        @{ Label = 'NaN'; Type = 'number'; Op = 'eq'; Expected = 0; Value = [double]::NaN }
        @{ Label = 'infinite number'; Type = 'number'; Op = 'gte'; Expected = 0; Value = [double]::PositiveInfinity }
        @{ Label = 'invalid expected scalar'; Type = 'number'; Op = 'eq'; Expected = '1'; Value = 1 }
        @{ Label = 'invalid expected set'; Type = 'numberSet'; Op = 'eq'; Expected = @(1, '2'); Value = @(1, 2) }
        @{ Label = 'empty membership'; Type = 'number'; Op = 'in'; Expected = @(); Value = 0 }
        @{ Label = 'untyped membership'; Type = 'number'; Op = 'in'; Expected = @(1, '2'); Value = 1 }
        @{ Label = 'scalar membership expectation'; Type = 'string'; Op = 'in'; Expected = 'a'; Value = 'a' }
        @{ Label = 'unknown type'; Type = 'unknown'; Op = 'eq'; Expected = 1; Value = 1 }
    ) {
        $result = Compare-IdsAssessmentValue (New-TestMapping $Type $Op $Expected) (New-TestObservation $Value $Type)
        $result.assessed | Should -BeFalse
        $result.aligned | Should -BeFalse
        $result.reason | Should -Not -BeNullOrEmpty
    }

    It 'does not accept an encoded numeric string as a numeric bound' {
        $result = Compare-IdsAssessmentValue (New-TestMapping number gte 8) (New-TestObservation '12' string)
        $result.assessed | Should -BeFalse
        $result.aligned | Should -BeFalse
        $result.reason | Should -Not -BeNullOrEmpty
    }
}

Describe 'Listed-control coverage and configuration alignment' {
    It 'keeps pack versions, platforms and profiles separate instead of blending counts' {
        $first = New-TestPack
        $second = New-TestPack
        $second.version = '2.0.0'; $second.platform = 'macos'; $second.profile = 'other'
        $third = New-TestPack
        $third.version = '3.0.0'; $third.controls[0].manualReason = 'Manual.'; $third.controls[0].mappings = @()
        $result = Compare-IdsAssessment -Packs @($third, $second, $first) -Snapshot (New-TestSnapshot) -Context @{
            platforms = @('windows11'); osVersions = @{}; enrollmentModes = @{}
        }
        $result.summaries.Count | Should -Be 3
        $result.summaries[0].counts.aligned | Should -Be 1
        $result.summaries[1].counts.notApplicable | Should -Be 1
        $result.summaries[2].counts.notAssessed | Should -Be 1
        $result.summaries[0].coveragePercent | Should -Be 100
        $result.summaries[1].coveragePercent | Should -BeNullOrEmpty
        $result.summaries[2].coveragePercent | Should -Be 0
        ($result.controls.packVersion -join ',') | Should -BeExactly '1.0.0,2.0.0,3.0.0'
    }

    It 'counts all six statuses and keeps unknown applicability in the coverage denominator' {
        $pack = New-TestPack
        $pack.platform = 'androidEnterprise'
        $pack.controls = @(
            foreach ($id in @('aligned', 'misaligned', 'missing', 'conflict', 'excluded', 'manual', 'unknown')) {
                $control = (New-TestPack).controls[0]
                $control.id = $id
                $control.mappings[0].settingId = $id
                switch ($id) {
                    excluded { $control.applicability.enrollmentModes = @('dedicated') }
                    manual { $control.mappings = @(); $control.manualReason = 'Manual review.' }
                    unknown { $control.applicability.osMin = '14.0' }
                }
                $control
            }
        )
        $observations = @(
            foreach ($entry in @(
                @{ Id = 'aligned'; Value = $true; Key = 'settingsCatalog:one' }
                @{ Id = 'misaligned'; Value = $false; Key = 'settingsCatalog:one' }
                @{ Id = 'conflict'; Value = $true; Key = 'settingsCatalog:one' }
                @{ Id = 'conflict'; Value = $false; Key = 'settingsCatalog:two' }
            )) {
                $observation = New-TestObservation $entry.Value boolean $entry.Key
                $observation.settingId = $entry.Id
                $observation
            }
        )
        $context = @{ platforms = @('androidEnterprise'); osVersions = @{}; enrollmentModes = @{ androidEnterprise = 'fullyManaged' } }
        $snapshot = New-TestSnapshot $observations
        $snapshot.sources[0].platform = 'androidEnterprise'
        foreach ($policy in $snapshot.policies) { $policy.platform = 'androidEnterprise'; $policy.enrollmentMode = 'fullyManaged' }
        $result = Invoke-TestAssessment $pack $snapshot $context
        $summary = $result.summaries[0]
        $result.controls.Count | Should -Be 7
        $summary.packId | Should -BeExactly $pack.id
        $summary.platform | Should -BeExactly 'androidEnterprise'
        $summary.profile | Should -BeExactly 'test'
        $summary.inventory | Should -BeExactly 'partial'
        $summary.counts.aligned | Should -Be 1
        $summary.counts.misaligned | Should -Be 1
        $summary.counts.missing | Should -Be 1
        $summary.counts.potentialConflict | Should -Be 1
        $summary.counts.notApplicable | Should -Be 1
        $summary.counts.notAssessed | Should -Be 2
        $summary.assessed | Should -Be 4
        $summary.coverageDenominator | Should -Be 6
        $summary.coveragePercent | Should -Be 66.7
        $summary.alignmentPercent | Should -Be 25.0
    }

    It 'returns null percentages for empty denominators instead of a perfect score' {
        $pack = New-TestPack
        $context = @{ platforms = @('macos'); osVersions = @{}; enrollmentModes = @{} }
        $summary = (Invoke-TestAssessment $pack (New-TestSnapshot) $context).summaries[0]
        $summary.assessed | Should -Be 0
        $summary.coverageDenominator | Should -Be 0
        $summary.coveragePercent | Should -BeNullOrEmpty
        $summary.alignmentPercent | Should -BeNullOrEmpty
        $pack.controls[0].manualReason = 'Manual.'
        $pack.controls[0].mappings = @()
        $summary = (Invoke-TestAssessment $pack (New-TestSnapshot)).summaries[0]
        $summary.coveragePercent | Should -Be 0
        $summary.alignmentPercent | Should -BeNullOrEmpty
        $empty = Compare-IdsAssessment -Packs @() -Snapshot (New-TestSnapshot) -Context @{}
        $empty.controls -is [array] | Should -BeTrue
        $empty.summaries -is [array] | Should -BeTrue
        $empty.controls.Count | Should -Be 0
        $empty.summaries.Count | Should -Be 0
    }
}
