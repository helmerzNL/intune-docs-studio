BeforeAll {
    . "$PSScriptRoot\TestHelpers\Assessment.ps1"
    foreach ($module in 'BaselinePacks', 'AssessmentCollection', 'AssessmentSettings', 'AssessmentRules') {
        . "$PSScriptRoot\..\lib\$module.ps1"
    }
    if (Test-Path "$PSScriptRoot\..\lib\BaselineArchive.ps1") { . "$PSScriptRoot\..\lib\BaselineArchive.ps1" }
    $archiveSha = '0123456789abcdef' * 4
    function Get-TestControlSignature($Control) {
        $mapping = $Control.mappings[0]
        "$($Control.id)|$($mapping.valueType)|$($mapping.operator)|$(ConvertTo-Json -InputObject $mapping.expected -Compress)"
    }
}

Describe 'Build-kit Settings Catalog conversion' {
    It 'converts choice, child, collection, integer and string settings into validated controls' {
        $child = New-IdsTestSettingInstance -Id 'syn.choice.child' -Value @{ value = 7 }
        $instances = @(
            (New-IdsTestSettingInstance -Kind choice -Id 'syn.choice' -Value @{ value = 'syn.choice_1'; children = @($child) }),
            (New-IdsTestSettingInstance -Id 'syn.integer' -Value @{
                '@odata.type' = '#microsoft.graph.deviceManagementConfigurationIntegerSettingValue'; value = 5 }),
            (New-IdsTestSettingInstance -Id 'syn.string' -Value @{
                '@odata.type' = '#microsoft.graph.deviceManagementConfigurationStringSettingValue'; value = 'Exact Text' }),
            (New-IdsTestSettingCollectionInstance -Id 'syn.strings' -Values @(@{ value = 'b' }, @{ value = 'a' })),
            (New-IdsTestSettingCollectionInstance -Id 'syn.numbers' -Values @(@{ value = 3 }, @{ value = 1 })),
            (New-IdsTestSettingCollectionInstance -Id 'syn.empty'),
            (New-IdsTestSettingCollectionInstance -Kind choice -Id 'syn.choices' -Values @(
                @{ value = 'syn.choices_2' }, @{ value = 'syn.choices_1' }))
        )
        $definitions = @(
            @{ id = 'syn.choice'; displayName = 'Synthetic choice' },
            @{ id = 'syn.empty'; valueDefinition = @{
                '@odata.type' = '#microsoft.graph.deviceManagementConfigurationIntegerSettingValueDefinition' } }
        )
        $policy = New-IdsTestBuildKitPolicy -Instances $instances -Definitions $definitions
        $result = ConvertTo-IdsBuildKitPacks -Policies @(New-IdsTestBuildKitItem $policy) -ArchiveSha256 $archiveSha
        $result.skipped.Count | Should -Be 0
        $result.packs.Count | Should -Be 1
        $pack = Read-IdsBaselinePack -Bytes $result.packs[0]
        $pack.id | Should -BeExactly 'cis.windows11.l1'
        $pack.profile | Should -BeExactly 'Level 1 (L1)'
        $pack.framework | Should -BeExactly 'CIS'
        $pack.classification | Should -BeExactly 'baseline'
        $pack.platform | Should -BeExactly 'windows11'
        $pack.frameworkVersion | Should -BeExactly 'Unknown (customer-supplied build kit)'
        (@($pack.controls | ForEach-Object { Get-TestControlSignature $_ }) -join "`n") | Should -BeExactly (@(
            'syn.choice|string|eq|"syn.choice_1"'
            'syn.choice.child|number|eq|7'
            'syn.choices|stringSet|setEquals|["syn.choices_2","syn.choices_1"]'
            'syn.empty|numberSet|setEquals|[]'
            'syn.integer|number|eq|5'
            'syn.numbers|numberSet|setEquals|[3,1]'
            'syn.string|string|eq|"Exact Text"'
            'syn.strings|stringSet|setEquals|["b","a"]'
        ) -join "`n")
        $pack.controls[0].title | Should -BeExactly 'Synthetic choice'
        $pack.controls[3].title | Should -BeExactly 'syn.empty'
        foreach ($control in $pack.controls) {
            $control.reference | Should -BeExactly "CIS build kit policy 'Synthetic L1 policy' (archive entry 'kit/policy.json')"
            (@($control.sourceIds) -join ',') | Should -BeExactly 'cis-build-kit'
            $control.manualReason | Should -BeNullOrEmpty
            $control.applicability.osMin | Should -BeNullOrEmpty
            $control.applicability.osMax | Should -BeNullOrEmpty
            @($control.applicability.enrollmentModes).Count | Should -Be 0
            @($control.mappings).Count | Should -Be 1
            $control.mappings[0].family | Should -BeExactly 'settingsCatalog'
            (@($control.mappings[0].policyTypes) -join ',') | Should -BeExactly 'deviceManagementConfigurationPolicy'
            $control.mappings[0].settingId | Should -BeExactly $control.id
            $control.mappings[0].property | Should -BeNullOrEmpty
            $control.mappings[0].instancePath | Should -BeNullOrEmpty
            $control.mappings[0].caseSensitive | Should -BeTrue
        }
    }

    It 'skips secret, unsupported, unconfigured and template-default settings with reasons' {
        $secret = New-IdsTestSettingInstance -Id 'syn.secret' -Value @{
            '@odata.type' = '#microsoft.graph.deviceManagementConfigurationSecretSettingValue'; value = 'synthetic-hidden-value' }
        $unknown = @{ '@odata.type' = '#microsoft.graph.deviceManagementConfigurationUnknownSettingInstance'; settingDefinitionId = 'syn.unknown' }
        $missing = New-IdsTestSettingInstance -Id 'syn.missing' -Value $null
        $template = New-IdsTestSettingInstance -Id 'syn.template' -Value @{
            value = 1; settingValueTemplateReference = @{ useTemplateDefault = $true } }
        $nestedChild = New-IdsTestSettingInstance -Id 'syn.parent.child' -Value @{
            value = 2; settingValueTemplateReference = @{ useTemplateDefault = $true } }
        $nested = New-IdsTestSettingInstance -Kind choice -Id 'syn.parent' -Value @{ value = 'syn.parent_1'; children = @($nestedChild) }
        $kept = New-IdsTestSettingInstance -Id 'syn.kept' -Value @{ value = 1 }
        $policy = New-IdsTestBuildKitPolicy -Name 'Synthetic L1 skips' -Instances @($secret, $unknown, $missing, $template, $nested, $kept)
        $result = ConvertTo-IdsBuildKitPacks -Policies @(New-IdsTestBuildKitItem $policy 'kit/skips.json') -ArchiveSha256 $archiveSha
        $result.packs.Count | Should -Be 1
        $pack = Read-IdsBaselinePack -Bytes $result.packs[0]
        (@($pack.controls.id) -join ',') | Should -BeExactly 'syn.kept'
        (@($result.skipped | ForEach-Object { "$($_.entry) => $($_.reason)" }) -join "`n") | Should -BeExactly (@(
            "kit/skips.json => Setting 'syn.secret' in policy 'Synthetic L1 skips' is secret and was not converted."
            "kit/skips.json => Setting 'syn.unknown' in policy 'Synthetic L1 skips' has an unsupported shape or value type and was not converted."
            "kit/skips.json => Setting 'syn.missing' in policy 'Synthetic L1 skips' has no configured value and was not converted."
            "kit/skips.json => Setting 'syn.template' in policy 'Synthetic L1 skips' uses a template default value and was not converted."
            "kit/skips.json => Setting 'syn.parent' in policy 'Synthetic L1 skips' uses a template default value and was not converted."
        ) -join "`n")
        [Text.Encoding]::UTF8.GetString($result.packs[0]) | Should -Not -Match 'synthetic-hidden-value'
    }

    It 'skips repeated and conflicting settings and merges equal values from several policies' {
        $group = @{
            '@odata.type' = '#microsoft.graph.deviceManagementConfigurationGroupSettingCollectionInstance'
            settingDefinitionId = 'syn.group'
            groupSettingCollectionValue = @(
                @{ children = @(New-IdsTestSettingInstance -Id 'syn.group.item' -Value @{ value = 1 }) },
                @{ children = @(New-IdsTestSettingInstance -Id 'syn.group.item' -Value @{ value = 2 }) }
            )
        }
        $first = New-IdsTestBuildKitPolicy -Name 'Synthetic L1 first' -Instances @(
            $group,
            (New-IdsTestSettingInstance -Id 'syn.number' -Value @{ value = 5 }),
            (New-IdsTestSettingInstance -Id 'syn.text' -Value @{ value = 'Abc' }),
            (New-IdsTestSettingInstance -Id 'syn.type' -Value @{ value = 5 }),
            (New-IdsTestSettingInstance -Id 'syn.same' -Value @{ value = 10 }),
            (New-IdsTestSettingCollectionInstance -Id 'syn.set' -Values @(@{ value = 'a' }, @{ value = 'b' }))
        )
        $second = New-IdsTestBuildKitPolicy -Name 'Synthetic L1 second' -Instances @(
            (New-IdsTestSettingInstance -Id 'syn.number' -Value @{ value = 6 }),
            (New-IdsTestSettingInstance -Id 'syn.text' -Value @{ value = 'abc' }),
            (New-IdsTestSettingInstance -Id 'syn.type' -Value @{ value = '5' }),
            (New-IdsTestSettingInstance -Id 'syn.same' -Value @{ value = [decimal]'10.0' }),
            (New-IdsTestSettingCollectionInstance -Id 'syn.set' -Values @(@{ value = 'b' }, @{ value = 'a' }))
        )
        $result = ConvertTo-IdsBuildKitPacks -Policies @(
            (New-IdsTestBuildKitItem $first 'kit/a.json'),
            (New-IdsTestBuildKitItem $second 'kit/b.json')
        ) -ArchiveSha256 $archiveSha
        $pack = Read-IdsBaselinePack -Bytes $result.packs[0]
        (@($pack.controls.id) -join ',') | Should -BeExactly 'syn.same,syn.set'
        $pack.controls[0].reference | Should -BeExactly ("CIS build kit policy 'Synthetic L1 first' (archive entry 'kit/a.json'); " +
            "CIS build kit policy 'Synthetic L1 second' (archive entry 'kit/b.json')")
        $pack.controls[0].mappings[0].expected | Should -Be 10
        $conflict = "in policies 'Synthetic L1 first' (archive entry 'kit/a.json') and 'Synthetic L1 second' " +
            "(archive entry 'kit/b.json'), so it was skipped for pack 'cis.windows11.l1'."
        (@($result.skipped | ForEach-Object { "$($_.entry) => $($_.reason)" }) -join "`n") | Should -BeExactly (@(
            "kit/a.json => Setting 'syn.group.item' occurs more than once in policy 'Synthetic L1 first', so it was skipped for pack 'cis.windows11.l1'."
            "kit/b.json => Setting 'syn.number' has different values $conflict"
            "kit/b.json => Setting 'syn.text' has different values $conflict"
            "kit/b.json => Setting 'syn.type' has different values $conflict"
        ) -join "`n")
    }

    It 'lists at most five policy references per control' {
        $items = @(foreach ($number in 1..7) {
            $policy = New-IdsTestBuildKitPolicy -Name "Synthetic L1 policy $number" -Instances @(
                New-IdsTestSettingInstance -Id 'syn.shared' -Value @{ value = 1 })
            New-IdsTestBuildKitItem $policy "kit/p$number.json"
        })
        $result = ConvertTo-IdsBuildKitPacks -Policies $items -ArchiveSha256 $archiveSha
        $pack = Read-IdsBaselinePack -Bytes $result.packs[0]
        $expected = (@(foreach ($number in 1..5) {
            "CIS build kit policy 'Synthetic L1 policy $number' (archive entry 'kit/p$number.json')"
        }) -join '; ') + '; and 2 more'
        $pack.controls[0].reference | Should -BeExactly $expected
    }

    It 'groups policies by platform and CIS profile level and skips unsupported platforms' {
        $cases = @(
            @('Synthetic L1 Windows', 'windows10'),
            @('Synthetic (L2) Windows', 'windows10AndLater'),
            @('Synthetic BL Windows', 'windows11'),
            @('Synthetic NG Windows', 'windows10'),
            @('Synthetic l1 BLOCKING Windows', 'windows10'),
            @('Synthetic L1 and L2 Windows', 'windows10'),
            @('Synthetic Level 1 (L1) macOS', 'macOS'),
            @('Synthetic LEVEL 2 iOS', 'iOS'),
            @('Synthetic Android', 'androidEnterprise'),
            @('Synthetic L1 combined', 'windows10,macOS'),
            @('Synthetic L1 Linux', 'linux')
        )
        $items = @(for ($index = 0; $index -lt $cases.Count; $index++) {
            $policy = New-IdsTestBuildKitPolicy -Name $cases[$index][0] -Platforms $cases[$index][1] -Instances @(
                New-IdsTestSettingInstance -Id "syn.setting$index" -Value @{ value = $index })
            New-IdsTestBuildKitItem $policy "kit/$index.json"
        })
        $result = ConvertTo-IdsBuildKitPacks -Policies $items -ArchiveSha256 $archiveSha
        $packs = @($result.packs | ForEach-Object { Read-IdsBaselinePack -Bytes $_ })
        (@($packs | ForEach-Object { "$($_.id)|$($_.profile)|$($_.platform)|$(@($_.controls.id) -join ',')" }) -join "`n") |
            Should -BeExactly (@(
                'cis.androidenterprise.build-kit|Unclassified build kit policies|androidEnterprise|syn.setting8'
                'cis.iosipados.l2|Level 2 (L2)|iosIpados|syn.setting7'
                'cis.macos.l1|Level 1 (L1)|macos|syn.setting6'
                'cis.windows11.bl|BitLocker (BL)|windows11|syn.setting2'
                'cis.windows11.build-kit|Unclassified build kit policies|windows11|syn.setting4,syn.setting5'
                'cis.windows11.l1|Level 1 (L1)|windows11|syn.setting0'
                'cis.windows11.l2|Level 2 (L2)|windows11|syn.setting1'
                'cis.windows11.ng|Next Generation Windows Security (NG)|windows11|syn.setting3'
            ) -join "`n")
        (@($result.skipped | ForEach-Object { "$($_.entry) => $($_.reason)" }) -join "`n") | Should -BeExactly (@(
            "kit/9.json => Policy 'Synthetic L1 combined' targets an unsupported or combined platform."
            "kit/10.json => Policy 'Synthetic L1 Linux' targets an unsupported or combined platform."
        ) -join "`n")
    }

    It 'detects one framework version from <label>' -ForEach @(
        @{ label = 'policy names'; names = @('Synthetic L1 v4.0.0 first', 'Synthetic L1 v4.0.0 second')
            entries = @('kit/a.json', 'kit/b.json'); expected = 'v4.0.0' }
        @{ label = 'entry paths'; names = @('Synthetic L1 first', 'Synthetic L1 second')
            entries = @('kit_v3.0.1/a.json', 'kit_v3.0.1/b.json'); expected = 'v3.0.1' }
        @{ label = 'conflicting names'; names = @('Synthetic L1 v4.0.0', 'Synthetic L1 v4.1.0')
            entries = @('kit_v3.0.1/a.json', 'kit_v3.0.1/b.json'); expected = 'Unknown (customer-supplied build kit)' }
        @{ label = 'four-part versions'; names = @('Synthetic L1 v4.0.0.1', 'Synthetic L1 second')
            entries = @('kit/a.json', 'kit/b.json'); expected = 'Unknown (customer-supplied build kit)' }
        @{ label = 'four-part names with valid paths'; names = @('Synthetic L1 v4.0.0.1', 'Synthetic L1 second')
            entries = @('kit_v3.0.1/a.json', 'kit_v3.0.1/b.json'); expected = 'Unknown (customer-supplied build kit)' }
        @{ label = 'mixed three-part and four-part names'; names = @('Synthetic L1 v4.0.0', 'Synthetic L1 v4.0.0.1')
            entries = @('kit/a.json', 'kit/b.json'); expected = 'Unknown (customer-supplied build kit)' }
        @{ label = 'mixed three-part and four-part paths'; names = @('Synthetic L1 first', 'Synthetic L1 second')
            entries = @('kit_v3.0.1/a.json', 'kit_v3.0.1.2/b.json'); expected = 'Unknown (customer-supplied build kit)' }
    ) {
        $items = @(for ($index = 0; $index -lt 2; $index++) {
            $policy = New-IdsTestBuildKitPolicy -Name $names[$index] -Instances @(
                New-IdsTestSettingInstance -Id "syn.version$index" -Value @{ value = $index })
            New-IdsTestBuildKitItem $policy $entries[$index]
        })
        $result = ConvertTo-IdsBuildKitPacks -Policies $items -ArchiveSha256 $archiveSha
        (Read-IdsBaselinePack -Bytes $result.packs[0]).frameworkVersion | Should -BeExactly $expected
    }

    It 'produces deterministic bytes, content-derived versions and wall-clock retrieval dates' {
        $first = New-IdsTestBuildKitPolicy -Name 'Synthetic L1 first' -Instances @(
            New-IdsTestSettingInstance -Id 'syn.first' -Value @{ value = 1 })
        $second = New-IdsTestBuildKitPolicy -Name 'Synthetic L1 second' -Instances @(
            New-IdsTestSettingInstance -Id 'syn.second' -Value @{ value = 'two' })
        $hidden = New-IdsTestBuildKitPolicy -Name 'Synthetic L1 hidden' -Instances @(
            New-IdsTestSettingInstance -Id 'syn.hidden' -Value @{
                '@odata.type' = '#microsoft.graph.deviceManagementConfigurationSecretSettingValue'; value = 'hidden' })
        $items = @(
            (New-IdsTestBuildKitItem $first 'kit/a.json' ([DateTimeOffset]::new(2026, 10, 3, 1, 0, 0, [TimeSpan]::FromHours(5)))),
            (New-IdsTestBuildKitItem $second 'kit/b.json' ([DateTimeOffset]::new(2026, 10, 1, 12, 0, 0, [TimeSpan]::Zero))),
            (New-IdsTestBuildKitItem $hidden 'kit/c.json' ([DateTimeOffset]::new(2026, 12, 31, 12, 0, 0, [TimeSpan]::Zero)))
        )
        $one = ConvertTo-IdsBuildKitPacks -Policies $items -ArchiveSha256 $archiveSha
        $two = ConvertTo-IdsBuildKitPacks -Policies $items -ArchiveSha256 $archiveSha
        $one.packs.Count | Should -Be 1
        [Convert]::ToBase64String($two.packs[0]) | Should -BeExactly ([Convert]::ToBase64String($one.packs[0]))
        $one.packs[0][0] | Should -Be 0x7B
        $pack = Read-IdsBaselinePack -Bytes $one.packs[0]
        $text = [Text.Encoding]::UTF8.GetString($one.packs[0])
        $escaped = [Text.Json.JsonEncodedText]::Encode($pack.version).ToString()
        $baseText = $text.Replace("""version"": ""$escaped""", '"version": "1.0.0"')
        $baseBytes = [Text.Encoding]::UTF8.GetBytes($baseText)
        $stream = [IO.MemoryStream]::new($baseBytes)
        try { $baseHash = (Get-FileHash -InputStream $stream -Algorithm SHA256).Hash.ToLowerInvariant() }
        finally { $stream.Dispose() }
        $pack.version | Should -BeExactly ('1.0.0+' + $baseHash.Substring(0, 12))
        $pack.sourceRevision | Should -BeExactly "CIS build kit archive SHA-256 $archiveSha"
        @($pack.sources).Count | Should -Be 1
        $pack.sources[0].id | Should -BeExactly 'cis-build-kit'
        $pack.sources[0].url | Should -BeExactly 'https://workbench.cisecurity.org/'
        $pack.sources[0].revision | Should -BeExactly "Archive SHA-256 $archiveSha"
        $pack.sources[0].retrievedOn | Should -BeExactly '2026-10-03'
        $pack.coverage.inventory | Should -BeExactly 'partial'
        $pack.coverage.totalSourceControls | Should -BeNullOrEmpty
        $other = ConvertTo-IdsBuildKitPacks -Policies $items -ArchiveSha256 ('fedcba9876543210' * 4)
        (Read-IdsBaselinePack -Bytes $other.packs[0]).version | Should -Not -Be $pack.version
    }

    It 'reports policies without settings and accepts an empty policy list' {
        $empty = ConvertTo-IdsTestJsonValue @{ name = 'Synthetic L1 empty'; platforms = 'windows10'; settings = @() }
        $missing = ConvertTo-IdsTestJsonValue @{ name = 'Synthetic L1 missing'; platforms = 'windows10' }
        $result = ConvertTo-IdsBuildKitPacks -Policies @(
            (New-IdsTestBuildKitItem $empty 'kit/empty.json'),
            (New-IdsTestBuildKitItem $missing 'kit/missing.json')
        ) -ArchiveSha256 $archiveSha
        $result.packs.Count | Should -Be 0
        (@($result.skipped | ForEach-Object { "$($_.entry) => $($_.reason)" }) -join "`n") | Should -BeExactly (@(
            "kit/empty.json => Policy 'Synthetic L1 empty' contains no settings."
            "kit/missing.json => Policy 'Synthetic L1 missing' contains no settings."
        ) -join "`n")
        $none = ConvertTo-IdsBuildKitPacks -Policies @() -ArchiveSha256 $archiveSha
        $none.packs.Count | Should -Be 0
        $none.skipped.Count | Should -Be 0
    }

    It 'creates controls that the rule engine evaluates against Settings Catalog evidence' {
        $policy = New-IdsTestBuildKitPolicy -Name 'Synthetic L1 rule' -Instances @(
            New-IdsTestSettingInstance -Id 'syn.rule' -Value @{ value = 15 })
        $result = ConvertTo-IdsBuildKitPacks -Policies @(New-IdsTestBuildKitItem $policy) -ArchiveSha256 $archiveSha
        $pack = Read-IdsBaselinePack -Bytes $result.packs[0]
        $context = @{ platforms = @('windows11'); osVersions = @{ windows11 = '10.0.22631' }; enrollmentModes = @{} }
        foreach ($case in @(@{ value = 15; status = 'aligned' }, @{ value = 14; status = 'misaligned' })) {
            $instance = New-IdsTestSettingInstance -Id 'syn.rule' -Value @{ value = $case.value }
            $tenant = New-IdsTestAssessmentPolicy -Settings @(@{ settingInstance = $instance })
            $tenant.platform = 'windows11'
            $collection = New-IdsTestAssessmentCollection @($tenant)
            $collection.sources = @([pscustomobject]@{ family = 'settingsCatalog'; platform = 'windows11'; complete = $true; errors = @() })
            $comparison = Compare-IdsAssessment @($pack) (ConvertTo-IdsAssessmentSnapshot $collection) $context
            $comparison.controls.Count | Should -Be 1
            $comparison.controls[0].status | Should -BeExactly $case.status
        }
    }

    It 'requires a lowercase archive SHA-256: <label>' -ForEach @(
        @{ label = 'uppercase'; hash = 'A' * 64 }
        @{ label = 'empty'; hash = '' }
        @{ label = 'short'; hash = 'a' * 63 }
        @{ label = 'non-hex'; hash = 'g' * 64 }
        @{ label = 'trailing newline'; hash = ('a' * 64) + "`n" }
    ) {
        { ConvertTo-IdsBuildKitPacks -Policies @() -ArchiveSha256 $hash } |
            Should -Throw 'ArchiveSha256 must be 64 lowercase hexadecimal characters.'
    }

    It 'excludes repeated IDs even when one occurrence is <shape>' -ForEach @(
        @{ shape = 'unconfigured'; repeated = $null }
        @{ shape = 'unsupported'; repeated = @{ '@odata.type' = '#microsoft.graph.futureValue'; value = 2 } }
        @{ shape = 'secret'; repeated = @{ '@odata.type' = '#microsoft.graph.deviceManagementConfigurationSecretSettingValue'; value = 'hidden' } }
        @{ shape = 'template-default'; repeated = @{ value = 2; settingValueTemplateReference = @{ useTemplateDefault = $true } } }
    ) {
        $policy = New-IdsTestBuildKitPolicy -Name 'Synthetic L1 repeated' -Instances @(
            (New-IdsTestSettingInstance -Id 'syn.repeated' -Value @{ value = 1 }),
            (New-IdsTestSettingInstance -Id 'syn.repeated' -Value $repeated),
            (New-IdsTestSettingInstance -Id 'syn.kept' -Value @{ value = 2 })
        )
        $result = ConvertTo-IdsBuildKitPacks -Policies @(New-IdsTestBuildKitItem $policy) -ArchiveSha256 $archiveSha
        $result.packs.Count | Should -Be 1
        (Read-IdsBaselinePack -Bytes $result.packs[0]).controls.id | Should -BeExactly 'syn.kept'
        $result.skipped.reason | Should -Contain "Setting 'syn.repeated' occurs more than once in policy 'Synthetic L1 repeated', so it was skipped for pack 'cis.windows11.l1'."
    }

    It 'excludes repeated IDs from another policy even if that policy contributes no controls' {
        $first = New-IdsTestBuildKitPolicy -Name 'Synthetic L1 first v4.0.0' -Instances @(
            (New-IdsTestSettingInstance -Id 'syn.repeated' -Value @{ value = 1 }),
            (New-IdsTestSettingInstance -Id 'syn.kept' -Value @{ value = 2 })
        )
        $second = New-IdsTestBuildKitPolicy -Name 'Synthetic L1 second v9.0.0' -Instances @(
            (New-IdsTestSettingInstance -Id 'syn.repeated' -Value $null),
            (New-IdsTestSettingInstance -Id 'syn.repeated' -Value $null)
        )
        foreach ($reverse in @($false, $true)) {
            $items = @(
                (New-IdsTestBuildKitItem $first 'kit/first.json'),
                (New-IdsTestBuildKitItem $second 'kit/second.json' ([DateTimeOffset]::new(2026, 12, 31, 0, 0, 0, [TimeSpan]::Zero)))
            )
            if ($reverse) { [Array]::Reverse($items) }
            $result = ConvertTo-IdsBuildKitPacks -Policies $items -ArchiveSha256 $archiveSha
            $result.packs.Count | Should -Be 1
            $pack = Read-IdsBaselinePack -Bytes $result.packs[0]
            $pack.controls.id | Should -BeExactly 'syn.kept'
            $pack.frameworkVersion | Should -BeExactly 'v4.0.0'
            $pack.sources[0].retrievedOn | Should -BeExactly '2026-10-01'
            $result.skipped.reason | Should -Contain "Setting 'syn.repeated' occurs more than once in policy 'Synthetic L1 second v9.0.0', so it was skipped for pack 'cis.windows11.l1'."
        }
    }

    It 'does not classify profile tokens adjacent to letters or digits: <name>' -ForEach @(
        @{ name = 'Synthetic XL1 L20 BLEND SING' }
        @{ name = 'Synthetic éL1' }
        @{ name = 'Synthetic L2é' }
        @{ name = 'Synthetic Level 1٢' }
    ) {
        $policy = New-IdsTestBuildKitPolicy -Name $name -Instances @(
            New-IdsTestSettingInstance -Id 'syn.token' -Value @{ value = 1 })
        $result = ConvertTo-IdsBuildKitPacks -Policies @(New-IdsTestBuildKitItem $policy) -ArchiveSha256 $archiveSha
        (Read-IdsBaselinePack -Bytes $result.packs[0]).id | Should -BeExactly 'cis.windows11.build-kit'
    }

    It 'preserves scalar and set types across JSON input, serialization and the rule engine' {
        $instances = @(
            (New-IdsTestSettingInstance -Id 'syn.false' -Value @{ value = $false }),
            (New-IdsTestSettingInstance -Id 'syn.zero' -Value @{ value = 0 }),
            (New-IdsTestSettingInstance -Id 'syn.emptyString' -Value @{ value = '' }),
            (New-IdsTestSettingInstance -Id 'syn.decimal' -Value @{ value = [decimal]'1.25' }),
            (New-IdsTestSettingInstance -Id 'syn.double' -Value @{ value = 1e-100 }),
            (New-IdsTestSettingInstance -Id 'syn.largeInteger' -Value @{ value = 9007199254740993L }),
            (New-IdsTestSettingCollectionInstance -Id 'syn.singleton' -Values @(@{ value = 'only' })),
            (New-IdsTestSettingCollectionInstance -Id 'syn.emptySet')
        )
        $definitions = @(@{ id = 'syn.emptySet'; valueDefinition = @{
            '@odata.type' = '#microsoft.graph.deviceManagementConfigurationStringSettingValueDefinition'
        } })
        $policy = New-IdsTestBuildKitPolicy -Instances $instances -Definitions $definitions
        $result = ConvertTo-IdsBuildKitPacks -Policies @(New-IdsTestBuildKitItem $policy) -ArchiveSha256 $archiveSha
        $result.skipped.Count | Should -Be 0
        $pack = Read-IdsBaselinePack -Bytes $result.packs[0]
        (@($pack.controls | ForEach-Object { Get-TestControlSignature $_ }) -join "`n") | Should -BeExactly (@(
            'syn.decimal|number|eq|1.25'
            'syn.double|number|eq|1E-100'
            'syn.emptySet|stringSet|setEquals|[]'
            'syn.emptyString|string|eq|""'
            'syn.false|boolean|eq|false'
            'syn.largeInteger|number|eq|9007199254740993'
            'syn.singleton|stringSet|setEquals|["only"]'
            'syn.zero|number|eq|0'
        ) -join "`n")
        $tenant = New-IdsTestAssessmentPolicy -Settings $policy.settings
        $tenant.platform = 'windows11'
        $collection = New-IdsTestAssessmentCollection @($tenant)
        $collection.sources = @([pscustomobject]@{ family = 'settingsCatalog'; platform = 'windows11'; complete = $true; errors = @() })
        $comparison = Compare-IdsAssessment @($pack) (ConvertTo-IdsAssessmentSnapshot $collection) @{
            platforms = @('windows11'); osVersions = @{ windows11 = '10.0.22631' }; enrollmentModes = @{}
        }
        @($comparison.controls).Count | Should -Be 8
        @($comparison.controls | Where-Object status -CNE 'aligned').Count | Should -Be 0
    }

    It 'handles setting IDs that match dictionary members and orders them ordinally' {
        $policy = New-IdsTestBuildKitPolicy -Instances @(
            (New-IdsTestSettingInstance -Id 'Values' -Value @{ value = 3 }),
            (New-IdsTestSettingInstance -Id 'keys' -Value @{ value = 4 }),
            (New-IdsTestSettingInstance -Id 'Keys' -Value @{ value = 2 }),
            (New-IdsTestSettingInstance -Id 'Count' -Value @{ value = 1 })
        )
        $result = ConvertTo-IdsBuildKitPacks -Policies @(New-IdsTestBuildKitItem $policy) -ArchiveSha256 $archiveSha
        $result.skipped.Count | Should -Be 0
        $result.packs.Count | Should -Be 1
        (@((Read-IdsBaselinePack -Bytes $result.packs[0]).controls.id) -join ',') | Should -BeExactly 'Count,Keys,Values,keys'
    }

    It 'skips generated packs over the 10 MiB limit and packs that fail validation' {
        $large = @{ name = 'Synthetic L1 large'; platforms = 'windows10'; settings = @(foreach ($number in 1..11) {
            @{ settingInstance = New-IdsTestSettingInstance -Id "syn.large$number" -Value @{ value = ('x' * 1MB) } }
        }) }
        $long = @{ name = 'Synthetic L2 long'; platforms = 'windows10'; settings = @(
            @{ settingInstance = New-IdsTestSettingInstance -Id 'syn.long' -Value @{ value = ('y' * 40000) } }
        ) }
        $result = ConvertTo-IdsBuildKitPacks -Policies @(
            (New-IdsTestBuildKitItem $large 'kit/large.json'),
            (New-IdsTestBuildKitItem $long 'kit/long.json')
        ) -ArchiveSha256 $archiveSha
        $result.packs.Count | Should -Be 0
        $result.skipped.Count | Should -Be 2
        $result.skipped[0].entry | Should -BeExactly 'cis.windows11.l1'
        $result.skipped[0].reason | Should -BeExactly "Generated pack 'cis.windows11.l1' exceeds the 10 MiB pack limit."
        $result.skipped[1].entry | Should -BeExactly 'cis.windows11.l2'
        $result.skipped[1].reason | Should -BeLike "Generated pack 'cis.windows11.l2' is invalid: *string limit*"
    }

    It 'names policies by name, then displayName, then archive file name' {
        $display = ConvertTo-IdsTestJsonValue @{ displayName = 'Synthetic L1 display'; platforms = 'windows10'; settings = @(
            @{ settingInstance = New-IdsTestSettingInstance -Id 'syn.display' -Value @{ value = 1 } }) }
        $file = ConvertTo-IdsTestJsonValue @{ platforms = 'windows10'; settings = @(
            @{ settingInstance = New-IdsTestSettingInstance -Id 'syn.file' -Value @{ value = 2 } }) }
        $result = ConvertTo-IdsBuildKitPacks -Policies @(
            (New-IdsTestBuildKitItem $display 'kit/display.json'),
            (New-IdsTestBuildKitItem $file 'kit/L1/Synthetic L1 file.JSON')
        ) -ArchiveSha256 $archiveSha
        $pack = Read-IdsBaselinePack -Bytes $result.packs[0]
        $pack.id | Should -BeExactly 'cis.windows11.l1'
        (@($pack.controls.reference) -join "`n") | Should -BeExactly (@(
            "CIS build kit policy 'Synthetic L1 display' (archive entry 'kit/display.json')"
            "CIS build kit policy 'Synthetic L1 file' (archive entry 'kit/L1/Synthetic L1 file.JSON')"
        ) -join "`n")
    }
}
