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

    It 'skips ordinal-distinct Unicode <shape> rather than merging linguistically equal values' -ForEach @(
        @{ shape = 'scalar strings'; isSet = $false }
        @{ shape = 'string-set members'; isSet = $true }
    ) {
        $values = @([string][char]0x00C5, [string][char]0x212B)
        $items = @(for ($index = 0; $index -lt $values.Count; $index++) {
            $instance = if ($isSet) {
                New-IdsTestSettingCollectionInstance -Id 'syn.unicode' -Values @(
                    @{ value = $values[$index] }, @{ value = 'shared' })
            } else {
                New-IdsTestSettingInstance -Id 'syn.unicode' -Value @{ value = $values[$index] }
            }
            $policy = New-IdsTestBuildKitPolicy -Name "Synthetic L1 Unicode $index" -Instances @(
                $instance,
                (New-IdsTestSettingInstance -Id 'syn.kept' -Value @{ value = 1 })
            )
            New-IdsTestBuildKitItem $policy "kit/unicode$index.json"
        })
        $result = ConvertTo-IdsBuildKitPacks -Policies $items -ArchiveSha256 $archiveSha
        $result.skipped.Count | Should -Be 1
        $result.skipped[0].entry | Should -BeExactly 'kit/unicode1.json'
        $result.skipped[0].reason | Should -BeExactly ("Setting 'syn.unicode' has different values in policies " +
            "'Synthetic L1 Unicode 0' (archive entry 'kit/unicode0.json') and " +
            "'Synthetic L1 Unicode 1' (archive entry 'kit/unicode1.json'), so it was skipped for pack 'cis.windows11.l1'.")
        $result.packs.Count | Should -Be 1
        (Read-IdsBaselinePack -Bytes $result.packs[0]).controls.id | Should -BeExactly 'syn.kept'
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

Describe 'CIS build-kit archive reader' {
    BeforeAll {
        function New-TestPolicyJson([string]$Name = 'Synthetic L1 policy', [string]$Id = 'syn.archive', $Value = 1) {
            $policy = New-IdsTestBuildKitPolicy -Name $Name -Instances @(New-IdsTestSettingInstance -Id $Id -Value @{ value = $Value })
            return ConvertTo-Json -InputObject $policy -Depth 64 -Compress
        }
        function Get-TestSkipLines($Result) { @($Result.skipped | ForEach-Object { "$($_.entry) => $($_.reason)" }) }
        $unreadable = 'Could not be read (encrypted, corrupt or unsupported compression).'
    }

    It 'rejects <label> bytes as an invalid ZIP archive' -ForEach @(
        @{ label = 'text'; bytes = [Text.Encoding]::UTF8.GetBytes('not a zip archive') }
        @{ label = 'empty'; bytes = [byte[]]::new(0) }
    ) {
        { ConvertFrom-IdsBaselineArchive -Bytes $bytes } |
            Should -Throw -ExceptionType ([ArgumentException]) -ExpectedMessage 'The file is not a valid ZIP archive.'
    }

    It 'rejects archives over the <limit> limit' -ForEach @(
        @{ limit = 'entry'; count = 1001; extension = 'txt'; message = 'Archive entry limit exceeded (1,000 entries).' }
        @{ limit = 'JSON entry'; count = 501; extension = 'json'; message = 'Archive JSON entry limit exceeded (500 entries).' }
    ) {
        $entries = [ordered]@{}
        for ($index = 0; $index -lt $count; $index++) { $entries["kit/entry$index.$extension"] = '{}' }
        $zip = New-IdsTestZipBytes $entries
        { ConvertFrom-IdsBaselineArchive -Bytes $zip } |
            Should -Throw -ExceptionType ([ArgumentException]) -ExpectedMessage $message
    }

    It 'accepts archives at the entry limits' {
        $entries = [ordered]@{}
        for ($index = 0; $index -lt 500; $index++) {
            $entries["kit/entry$index.json"] = '{}'
            $entries["kit/entry$index.txt"] = 'synthetic'
        }
        $result = ConvertFrom-IdsBaselineArchive -Bytes (New-IdsTestZipBytes $entries)
        $result.packs.Count | Should -Be 0
        $result.skipped.Count | Should -Be 500
        $result.skipped[0].reason | Should -BeExactly 'Not a Settings Catalog policy or rule pack.'
        $result.ignored | Should -Be 500
    }

    It 'accepts an empty archive with typed empty result arrays' {
        $result = ConvertFrom-IdsBaselineArchive -Bytes (New-IdsTestZipBytes ([ordered]@{}))
        ($result.packs -is [byte[][]]) | Should -BeTrue
        $result.packs.Count | Should -Be 0
        ($result.skipped -is [object[]]) | Should -BeTrue
        $result.skipped.Count | Should -Be 0
        $result.ignored | Should -Be 0
        $result.sha256 | Should -Match '\A[0-9a-f]{64}\z'
    }

    It 'rejects a damaged central directory as an invalid ZIP' {
        $zip = New-IdsTestZipBytes ([ordered]@{ 'kit/policy.json' = (New-TestPolicyJson) })
        $central = [BitConverter]::ToInt32($zip, $zip.Length - 6)
        $zip[$central] = 0
        { ConvertFrom-IdsBaselineArchive -Bytes $zip } |
            Should -Throw -ExceptionType ([ArgumentException]) -ExpectedMessage 'The file is not a valid ZIP archive.'
    }

    It 'rejects the whole archive for the unsafe entry name <name>' -ForEach @(
        @{ name = '../escape.json' }
        @{ name = 'kit/../escape.json' }
        @{ name = 'kit\..\escape.json' }
        @{ name = 'kit/..' }
        @{ name = '/rooted.json' }
        @{ name = '\rooted.json' }
        @{ name = 'C:drive.json' }
        @{ name = 'kit/policy.json:stream' }
    ) {
        $zip = New-IdsTestZipBytes ([ordered]@{ 'kit/safe.json' = (New-TestPolicyJson); $name = '{}' })
        { ConvertFrom-IdsBaselineArchive -Bytes $zip } |
            Should -Throw -ExceptionType ([ArgumentException]) -ExpectedMessage "Archive entry names must be relative without ':' or '..' segments."
    }

    It 'ignores directories, counts other files and skips nested archives' {
        $zip = New-IdsTestZipBytes ([ordered]@{
            'kit/' = $null
            'kit/L1/' = $null
            'kit\empty\' = $null
            'kit/readme.pdf' = 'synthetic'
            'kit/settings.xlsx' = 'synthetic'
            'kit/policy.xml' = '<policy />'
            'kit/inner.ZIP' = (New-IdsTestZipBytes ([ordered]@{ 'inner.json' = (New-TestPolicyJson) }))
            'kit/L1/policy.JSON' = (New-TestPolicyJson)
        })
        $result = ConvertFrom-IdsBaselineArchive -Bytes $zip
        $result.ignored | Should -Be 3
        (Get-TestSkipLines $result) | Should -BeExactly 'kit/inner.ZIP => Nested ZIP archives are not opened; extract and upload the inner ZIP.'
        $result.packs.Count | Should -Be 1
        (Read-IdsBaselinePack -Bytes $result.packs[0]).controls[0].reference |
            Should -BeExactly "CIS build kit policy 'Synthetic L1 policy' (archive entry 'kit/L1/policy.JSON')"
    }

    It 'skips an entry that is <label>' -ForEach @(
        @{ label = 'encrypted'; change = 'Encrypted'; declared = 0; level = 'Optimal' }
        @{ label = 'stored with an unsupported compression method'; change = 'UnsupportedCompression'; declared = 0; level = 'Optimal' }
        @{ label = 'corrupt'; change = 'CorruptData'; declared = 0; level = 'Optimal' }
        @{ label = 'shorter than its declared size'; change = 'DeclaredLength'; declared = 5000; level = 'Optimal' }
        @{ label = 'longer than its declared deflated size'; change = 'DeclaredLength'; declared = 1; level = 'Optimal' }
        @{ label = 'longer than its declared size'; change = 'DeclaredLength'; declared = 1; level = 'NoCompression' }
    ) {
        $zip = New-IdsTestZipBytes ([ordered]@{
            'kit/broken.json' = (New-TestPolicyJson -Id 'syn.broken')
            'kit/good.json' = (New-TestPolicyJson -Id 'syn.good')
        }) -CompressionLevel $level
        $result = ConvertFrom-IdsBaselineArchive -Bytes (Edit-IdsTestZipFirstEntry $zip $change -Length $declared)
        (Get-TestSkipLines $result) | Should -BeExactly "kit/broken.json => $unreadable"
        $result.packs.Count | Should -Be 1
        (@((Read-IdsBaselinePack -Bytes $result.packs[0]).controls.id) -join ',') | Should -BeExactly 'syn.good'
    }

    It 'skips JSON entries over 10 MiB by <label> size' -ForEach @(
        @{ label = 'declared'; level = 'Optimal'; declared = 0 }
        @{ label = 'actual'; level = 'NoCompression'; declared = 100 }
        @{ label = 'actual deflated'; level = 'Optimal'; declared = 100 }
    ) {
        $zip = New-IdsTestZipBytes ([ordered]@{ 'kit/large.json' = [byte[]]::new(10MB + 1) }) -CompressionLevel $level
        if ($declared) { $zip = Edit-IdsTestZipFirstEntry $zip DeclaredLength -Length $declared }
        $result = ConvertFrom-IdsBaselineArchive -Bytes $zip
        $result.packs.Count | Should -Be 0
        (Get-TestSkipLines $result) | Should -BeExactly 'kit/large.json => JSON entry exceeds the 10 MiB limit.'
    }

    It 'skips a stored policy changed to other valid JSON without updating its CRC' {
        $json = New-TestPolicyJson -Value 1
        $zip = New-IdsTestZipBytes ([ordered]@{
            'kit/changed.json' = $json
            'kit/good.json' = (New-TestPolicyJson -Id 'syn.good')
        }) -CompressionLevel NoCompression
        $start = 30 + [BitConverter]::ToUInt16($zip, 26) + [BitConverter]::ToUInt16($zip, 28)
        $value = $json.IndexOf('"value":1', [StringComparison]::Ordinal)
        $value | Should -BeGreaterOrEqual 0
        $zip[$start + $value + 8] = [byte][char]'2'
        $result = ConvertFrom-IdsBaselineArchive -Bytes $zip
        (Get-TestSkipLines $result) | Should -BeExactly "kit/changed.json => $unreadable"
        $result.packs.Count | Should -Be 1
        (Read-IdsBaselinePack -Bytes $result.packs[0]).controls.id | Should -BeExactly 'syn.good'
    }

    It 'skips deflated data beyond the declared length with <label> CRC' -ForEach @(
        @{ label = 'full-data'; prefixCrc = $false }
        @{ label = 'valid-prefix'; prefixCrc = $true }
    ) {
        $pack = New-IdsTestPackBytes
        [byte[]]$data = $pack + [Text.Encoding]::UTF8.GetBytes('invalid suffix')
        $zip = New-IdsTestZipBytes ([ordered]@{ 'kit/hidden.json' = $data })
        $zip = Edit-IdsTestZipFirstEntry $zip DeclaredLength -Length $pack.Length
        if ($prefixCrc) {
            $prefix = New-IdsTestZipBytes ([ordered]@{ 'kit/hidden.json' = $pack })
            $crc = [BitConverter]::ToUInt32($prefix, 14)
            $central = [BitConverter]::ToInt32($zip, $zip.Length - 6)
            [BitConverter]::GetBytes($crc).CopyTo($zip, 14)
            [BitConverter]::GetBytes($crc).CopyTo($zip, $central + 16)
        }
        $result = ConvertFrom-IdsBaselineArchive -Bytes $zip
        (Get-TestSkipLines $result) | Should -BeExactly "kit/hidden.json => $unreadable"
        $result.packs.Count | Should -Be 0
    }

    It 'counts unclamped bytes from a corrupt deflated entry toward the archive budget' {
        $entries = [ordered]@{}
        $filler = [byte[]]::new(10000000)
        [Array]::Fill($filler, [byte]255)
        for ($index = 0; $index -lt 7; $index++) { $entries["kit/filler$index.json"] = $filler }
        $zip = Edit-IdsTestZipFirstEntry (New-IdsTestZipBytes $entries) DeclaredLength -Length 100
        { ConvertFrom-IdsBaselineArchive -Bytes $zip } |
            Should -Throw -ExceptionType ([IO.InvalidDataException]) -ExpectedMessage 'Archive JSON read limit exceeded (64 MiB).'
    }

    It 'preserves <label> ZIP compatibility while verifying integrity' -ForEach @(
        @{ label = 'signed data descriptor'; descriptor = 'Signed'; zip64 = $false; local64 = $false; level = 'Optimal' }
        @{ label = 'unsigned data descriptor'; descriptor = 'Unsigned'; zip64 = $false; local64 = $false; level = 'Optimal' }
        @{ label = 'stored data descriptor'; descriptor = 'Signed'; zip64 = $false; local64 = $false; level = 'NoCompression' }
        @{ label = 'ZIP64 directory and entry'; descriptor = 'None'; zip64 = $true; local64 = $false; level = 'Optimal' }
        @{ label = 'ZIP64 signed descriptor'; descriptor = 'Signed'; zip64 = $true; local64 = $false; level = 'Optimal' }
        @{ label = 'ZIP64 unsigned descriptor'; descriptor = 'Unsigned'; zip64 = $true; local64 = $false; level = 'Optimal' }
        @{ label = 'local-only ZIP64'; descriptor = 'None'; zip64 = $false; local64 = $true; level = 'Optimal' }
        @{ label = 'local-only ZIP64 descriptor'; descriptor = 'Signed'; zip64 = $false; local64 = $true; level = 'Optimal' }
    ) {
        $pack = New-IdsTestPackBytes
        $zip = New-IdsTestZipVariant -Content $pack -Descriptor $descriptor -Zip64:$zip64 -LocalZip64:$local64 `
            -CompressionLevel $level -Name "kit/$([char]0xE9).json" -Comment 'synthetic comment' `
            -Prefix ([Text.Encoding]::ASCII.GetBytes('synthetic prefix'))
        $result = ConvertFrom-IdsBaselineArchive -Bytes $zip
        $result.skipped.Count | Should -Be 0
        $result.packs.Count | Should -Be 1
        [Convert]::ToBase64String($result.packs[0]) | Should -BeExactly ([Convert]::ToBase64String($pack))
    }

    It 'skips inconsistent local metadata: <field>' -ForEach @(
        @{ field = 'CRC'; offset = 14 }
        @{ field = 'method'; offset = 8 }
        @{ field = 'name'; offset = 30 }
    ) {
        $zip = New-IdsTestZipBytes ([ordered]@{
            'kit/changed.json' = (New-TestPolicyJson)
            'kit/good.json' = (New-TestPolicyJson -Id 'syn.good')
        })
        $zip[$offset] = ($zip[$offset] + 1) % 256
        $result = ConvertFrom-IdsBaselineArchive -Bytes $zip
        (Get-TestSkipLines $result) | Should -BeExactly "kit/changed.json => $unreadable"
        $result.packs.Count | Should -Be 1
        (Read-IdsBaselinePack -Bytes $result.packs[0]).controls.id | Should -BeExactly 'syn.good'
    }

    It 'skips a mismatched data descriptor' {
        $zip = New-IdsTestZipVariant -Content (New-IdsTestPackBytes) -Descriptor Signed
        $central = [BitConverter]::ToInt32($zip, $zip.Length - 6)
        $zip[$central - 12] = ($zip[$central - 12] + 1) % 256
        $result = ConvertFrom-IdsBaselineArchive -Bytes $zip
        $result.packs.Count | Should -Be 0
        (Get-TestSkipLines $result) | Should -BeExactly "kit/policy.json => $unreadable"
    }

    It 'skips <label> deflate framing even when CRC and actual length match' -ForEach @(
        @{ label = 'missing final block'; final = 0; suffix = [byte[]]@() }
        @{ label = 'trailing compressed garbage'; final = 1; suffix = [byte[]](0, 1) }
    ) {
        $pack = New-IdsTestPackBytes
        # A DEFLATE stored block: BFINAL/BTYPE, LEN, NLEN, literal bytes.
        [byte[]]$raw = [byte[]]@($final) + [BitConverter]::GetBytes([uint16]$pack.Length) +
            [BitConverter]::GetBytes([uint16](65535 - $pack.Length)) + $pack + $suffix
        $zip = New-IdsTestZipVariant -Content $pack -DeflateData $raw
        $result = ConvertFrom-IdsBaselineArchive -Bytes $zip
        $result.packs.Count | Should -Be 0
        (Get-TestSkipLines $result) | Should -BeExactly "kit/policy.json => $unreadable"
    }

    It 'accepts a complete deflate stored block' {
        $pack = New-IdsTestPackBytes
        [byte[]]$raw = [byte[]]@(1) + [BitConverter]::GetBytes([uint16]$pack.Length) +
            [BitConverter]::GetBytes([uint16](65535 - $pack.Length)) + $pack
        $result = ConvertFrom-IdsBaselineArchive -Bytes (New-IdsTestZipVariant -Content $pack -DeflateData $raw)
        $result.skipped.Count | Should -Be 0
        $result.packs.Count | Should -Be 1
        [Convert]::ToBase64String($result.packs[0]) | Should -BeExactly ([Convert]::ToBase64String($pack))
    }

    It 'accepts fixed-Huffman deflate framing before classifying its JSON' {
        $bytes = [Text.Encoding]::ASCII.GetBytes('123456789')
        $raw = [byte[]](0x33, 0x34, 0x32, 0x36, 0x31, 0x35, 0x33, 0xB7, 0xB0, 0x04, 0x00)
        $result = ConvertFrom-IdsBaselineArchive -Bytes (New-IdsTestZipVariant -Content $bytes -DeflateData $raw)
        (Get-TestSkipLines $result) | Should -BeExactly 'kit/policy.json => Not a Settings Catalog policy or rule pack.'
    }

    It 'rejects impossible ZIP64 directory offsets without unchecked indexing' {
        $zip = New-IdsTestZipVariant -Content (New-IdsTestPackBytes) -Zip64
        $locator = $zip.Length - 42
        $record = [BitConverter]::ToInt32($zip, $locator + 8)
        [BitConverter]::GetBytes([uint64]::MaxValue).CopyTo($zip, $record + 48)
        { ConvertFrom-IdsBaselineArchive -Bytes $zip } |
            Should -Throw -ExceptionType ([ArgumentException]) -ExpectedMessage 'The file is not a valid ZIP archive.'
    }

    It 'converts a policy exactly at the 10 MiB entry limit' {
        $json = New-TestPolicyJson
        $padded = $json + (' ' * (10MB - [Text.Encoding]::UTF8.GetByteCount($json)))
        $result = ConvertFrom-IdsBaselineArchive -Bytes (New-IdsTestZipBytes ([ordered]@{ 'kit/policy.json' = $padded }))
        $result.skipped.Count | Should -Be 0
        $result.packs.Count | Should -Be 1
        (Read-IdsBaselinePack -Bytes $result.packs[0]).controls.id | Should -BeExactly 'syn.archive'
    }

    It 'bounds actual decompression to 10 MiB plus one byte and counts every returned byte' {
        $zip = New-IdsTestZipBytes ([ordered]@{ 'kit/large.json' = [byte[]]::new(11MB) })
        Initialize-IdsBaselineArchiveReader
        $entries = [Ids.BaselineZipReader]::ReadDirectory($zip, 1)
        $budget = @{ read = 123L }
        $content = Read-IdsBaselineArchiveEntry $zip $entries[0] $budget
        $content.Length | Should -Be 10485761
        $budget.read | Should -Be 10485884
    }

    It 'stops with an InvalidDataException after more than 64 MiB of JSON' {
        $entries = [ordered]@{}
        # Invalid UTF-8 keeps these budget fixtures away from the JSON parser.
        $filler = [byte[]]::new(10000000)
        [Array]::Fill($filler, [byte]255)
        for ($index = 0; $index -lt 7; $index++) { $entries["kit/filler$index.json"] = $filler }
        $zip = New-IdsTestZipBytes $entries
        { ConvertFrom-IdsBaselineArchive -Bytes $zip } |
            Should -Throw -ExceptionType ([IO.InvalidDataException]) -ExpectedMessage 'Archive JSON read limit exceeded (64 MiB).'
    }

    It 'enforces the total budget at <label>' -ForEach @(
        @{ label = 'exactly 64 MiB'; extra = 0 }
        @{ label = '64 MiB plus one byte'; extra = 1 }
    ) {
        $entries = [ordered]@{}
        $filler = [byte[]]::new(10MB)
        [Array]::Fill($filler, [byte]255)
        for ($index = 0; $index -lt 6; $index++) { $entries["kit/filler$index.json"] = $filler }
        $last = [byte[]]::new(4MB + $extra)
        [Array]::Fill($last, [byte]255)
        $entries['kit/last.json'] = $last
        $zip = New-IdsTestZipBytes $entries
        if ($extra) {
            { ConvertFrom-IdsBaselineArchive -Bytes $zip } |
                Should -Throw -ExceptionType ([IO.InvalidDataException]) -ExpectedMessage 'Archive JSON read limit exceeded (64 MiB).'
        } else {
            $result = ConvertFrom-IdsBaselineArchive -Bytes $zip
            $result.packs.Count | Should -Be 0
            $result.skipped.Count | Should -Be 7
            foreach ($item in $result.skipped) { $item.reason | Should -BeExactly 'Not valid UTF-8 or UTF-16 text.' }
        }
    }

    It 'decodes <label> JSON entries' -ForEach @(
        @{ label = 'UTF-8 without BOM'; encoding = [Text.UTF8Encoding]::new($false); bom = $false }
        @{ label = 'UTF-8 with BOM'; encoding = [Text.UTF8Encoding]::new($true); bom = $true }
        @{ label = 'UTF-16 LE with BOM'; encoding = [Text.UnicodeEncoding]::new($false, $true); bom = $true }
        @{ label = 'UTF-16 BE with BOM'; encoding = [Text.UnicodeEncoding]::new($true, $true); bom = $true }
    ) {
        $value = "Caf$([char]0xE9) $([char]0x2713) $([char]::ConvertFromUtf32(0x1F600))"
        [byte[]]$bytes = $encoding.GetBytes((New-TestPolicyJson -Id 'syn.text' -Value $value))
        if ($bom) { [byte[]]$bytes = $encoding.GetPreamble() + $bytes }
        $result = ConvertFrom-IdsBaselineArchive -Bytes (New-IdsTestZipBytes ([ordered]@{ 'kit/text.json' = $bytes }))
        $result.skipped.Count | Should -Be 0
        $result.packs.Count | Should -Be 1
        (Read-IdsBaselinePack -Bytes $result.packs[0]).controls[0].mappings[0].expected | Should -BeExactly $value
    }

    It 'skips entries that are not valid text, JSON, rule packs or Settings Catalog policies' {
        $zip = New-IdsTestZipBytes ([ordered]@{
            'kit/latin1.json' = [byte[]](0x7B, 0x22, 0xE9, 0x22, 0x7D)
            'kit/odd.json' = [byte[]](0xFF, 0xFE, 0x7B)
            'kit/invalid.json' = '{"name":'
            'kit/deep.json' = ('[' * 65) + (']' * 65)
            'kit/duplicate.json' = '{"name":"Synthetic L1 a","Name":"Synthetic L1 b","settings":[]}'
            'kit/long.json' = '{"name":"' + ('x' * 40000) + '","settings":[]}'
            'kit/readme.json' = '{"title":"Synthetic readme"}'
            'kit/empty.json' = '[]'
            'kit/mixed.json' = '[{"settings":[]},{"title":"Synthetic"}]'
            'kit/list.json' = '{"value":[]}'
            'kit/pack.json' = '{"schemaVersion":1}'
        })
        $result = ConvertFrom-IdsBaselineArchive -Bytes $zip
        $result.packs.Count | Should -Be 0
        $result.ignored | Should -Be 0
        $lines = Get-TestSkipLines $result
        $expected = @(
            'kit/latin1.json => Not valid UTF-8 or UTF-16 text.'
            'kit/odd.json => Not valid UTF-8 or UTF-16 text.'
            'kit/invalid.json => Invalid JSON or nesting deeper than 64 levels.'
            'kit/deep.json => Invalid JSON or nesting deeper than 64 levels.'
            'kit/duplicate.json => Invalid JSON: Pack JSON duplicate member at $.'
            'kit/long.json => Invalid JSON: Pack string limit (32768 characters) at $.name.'
            'kit/readme.json => Not a Settings Catalog policy or rule pack.'
            'kit/empty.json => Not a Settings Catalog policy or rule pack.'
            'kit/mixed.json => Not a Settings Catalog policy or rule pack.'
            'kit/list.json => Not a Settings Catalog policy or rule pack.'
            'kit/pack.json => Invalid rule pack: *'
        )
        $lines.Count | Should -Be $expected.Count
        for ($index = 0; $index -lt $expected.Count; $index++) { $lines[$index] | Should -BeLike $expected[$index] }
    }

    It 'skips empty JSON and invalid policy-list shapes without failing the archive' {
        $entries = [ordered]@{
            'kit/zero.json' = $null
            'kit/null.json' = 'null'
            'kit/false.json' = 'false'
            'kit/number.json' = '42'
            'kit/string.json' = '"synthetic"'
            'kit/wrapped-object.json' = '{"value":{"settings":[]}}'
            'kit/wrapped-mixed.json' = '{"value":[{"settings":[]},null]}'
            'kit/nested.json' = '[[{"settings":[]}]]'
            'kit/schema-first.json' = '{"schemaVersion":2,"settings":[]}'
            'kit/good.json' = (New-TestPolicyJson)
        }
        $result = ConvertFrom-IdsBaselineArchive -Bytes (New-IdsTestZipBytes $entries)
        $result.packs.Count | Should -Be 1
        $result.skipped.Count | Should -Be 9
        $result.skipped[0].reason | Should -BeExactly 'Invalid JSON or nesting deeper than 64 levels.'
        foreach ($index in 1..7) {
            $result.skipped[$index].reason | Should -BeExactly 'Not a Settings Catalog policy or rule pack.'
        }
        $result.skipped[8].reason | Should -BeLike 'Invalid rule pack: *'
    }

    It 'rejects malformed BOM-prefixed Unicode without replacement characters' -ForEach @(
        @{ bytes = [byte[]](0xEF, 0xBB, 0xBF, 0xC0, 0xAF) }
        @{ bytes = [byte[]](0xFF, 0xFE, 0x00, 0xD8) }
        @{ bytes = [byte[]](0xFE, 0xFF, 0xDC, 0x00) }
    ) {
        $result = ConvertFrom-IdsBaselineArchive -Bytes (New-IdsTestZipBytes ([ordered]@{ 'kit/text.json' = $bytes }))
        $result.packs.Count | Should -Be 0
        (Get-TestSkipLines $result) | Should -BeExactly 'kit/text.json => Not valid UTF-8 or UTF-16 text.'
    }

    It 'rejects a UTF-32 BOM rather than treating it as UTF-16' {
        $encoding = [Text.UTF32Encoding]::new($false, $true)
        [byte[]]$bytes = $encoding.GetPreamble() + $encoding.GetBytes((New-TestPolicyJson))
        $result = ConvertFrom-IdsBaselineArchive -Bytes (New-IdsTestZipBytes ([ordered]@{ 'kit/utf32.json' = $bytes }))
        $result.packs.Count | Should -Be 0
        (Get-TestSkipLines $result) | Should -BeExactly 'kit/utf32.json => Not valid UTF-8 or UTF-16 text.'
    }

    It 'accepts nesting at depth 64 and policy arrays containing exactly one item' {
        $policy = New-TestPolicyJson
        $policy = $policy.Substring(0, $policy.Length - 1) + ',"metadata":' + ('[' * 63) + (']' * 63) + '}'
        $result = ConvertFrom-IdsBaselineArchive -Bytes (New-IdsTestZipBytes ([ordered]@{
            'kit/depth.json' = $policy
            'kit/singleton.json' = '[' + (New-TestPolicyJson -Id 'syn.singleton') + ']'
        }))
        $result.skipped.Count | Should -Be 0
        $result.packs.Count | Should -Be 1
        (@((Read-IdsBaselinePack -Bytes $result.packs[0]).controls.id) -join ',') | Should -BeExactly 'syn.archive,syn.singleton'
    }

    It 'converts single policies, policy arrays and value lists' {
        $first = New-TestPolicyJson -Name 'Synthetic L1 first' -Id 'syn.first'
        $second = New-TestPolicyJson -Name 'Synthetic L1 second' -Id 'syn.second'
        $listed = New-TestPolicyJson -Name 'Synthetic L1 listed' -Id 'syn.listed'
        $zip = New-IdsTestZipBytes ([ordered]@{
            'kit/single.json' = (New-TestPolicyJson -Name 'Synthetic L1 single' -Id 'syn.single')
            'kit/array.json' = "[$first,$second]"
            'kit/list.json' = "{""@odata.context"":""synthetic"",""value"":[$listed]}"
        })
        $result = ConvertFrom-IdsBaselineArchive -Bytes $zip
        $result.skipped.Count | Should -Be 0
        $result.packs.Count | Should -Be 1
        $pack = Read-IdsBaselinePack -Bytes $result.packs[0]
        (@($pack.controls | ForEach-Object { "$($_.id) <= $($_.reference)" }) -join "`n") | Should -BeExactly (@(
            "syn.first <= CIS build kit policy 'Synthetic L1 first' (archive entry 'kit/array.json')"
            "syn.listed <= CIS build kit policy 'Synthetic L1 listed' (archive entry 'kit/list.json')"
            "syn.second <= CIS build kit policy 'Synthetic L1 second' (archive entry 'kit/array.json')"
            "syn.single <= CIS build kit policy 'Synthetic L1 single' (archive entry 'kit/single.json')"
        ) -join "`n")
    }

    It 'passes schema-1 rule packs through and skips invalid ones' {
        $packBytes = New-IdsTestPackBytes
        [byte[]]$withBom = [byte[]](0xEF, 0xBB, 0xBF) + $packBytes
        $utf16 = [Text.UnicodeEncoding]::new($true, $true)
        [byte[]]$utf16Bytes = $utf16.GetPreamble() + $utf16.GetBytes([Text.Encoding]::UTF8.GetString($packBytes))
        $zip = New-IdsTestZipBytes ([ordered]@{
            'packs/synthetic.json' = $packBytes
            'packs/synthetic-bom.json' = $withBom
            'packs/synthetic-utf16.json' = $utf16Bytes
            'packs/invalid.json' = '{"schemaVersion":1,"id":"synthetic-invalid"}'
        })
        $result = ConvertFrom-IdsBaselineArchive -Bytes $zip
        $result.packs.Count | Should -Be 3
        foreach ($bytes in $result.packs) {
            [Convert]::ToBase64String($bytes) | Should -BeExactly ([Convert]::ToBase64String($packBytes))
        }
        (Get-TestSkipLines $result) | Should -BeLike 'packs/invalid.json => Invalid rule pack: *'
    }

    It 'keeps rule packs in entry order rather than path order' {
        $result = ConvertFrom-IdsBaselineArchive -Bytes (New-IdsTestZipBytes ([ordered]@{
            'z/windows.json' = (New-IdsTestPackBytes -Platform windows11)
            'a/macos.json' = (New-IdsTestPackBytes -Platform macos)
        }))
        $result.packs.Count | Should -Be 2
        (@($result.packs | ForEach-Object { (Read-IdsBaselinePack -Bytes $_).platform }) -join ',') |
            Should -BeExactly 'windows11,macos'
    }

    It 'converts mixed archives deterministically and imports them idempotently' {
        $secret = New-IdsTestBuildKitPolicy -Name 'Synthetic L1 secret' -Instances @(
            New-IdsTestSettingInstance -Id 'syn.secret' -Value @{
                '@odata.type' = '#microsoft.graph.deviceManagementConfigurationSecretSettingValue'; value = 'synthetic-hidden-value' })
        $zip = New-IdsTestZipBytes ([ordered]@{
            'kit/readme.txt' = 'synthetic'
            'kit/notes.json' = '{"title":"Synthetic notes"}'
            'kit/L2/policy.json' = (New-TestPolicyJson -Name 'Synthetic L2 policy' -Id 'syn.level2')
            'packs/synthetic.json' = (New-IdsTestPackBytes)
            'kit/L1/policy.json' = (New-TestPolicyJson -Name 'Synthetic L1 policy' -Id 'syn.level1')
            'kit/L1/secret.json' = (ConvertTo-Json -InputObject $secret -Depth 64 -Compress)
        }) -LastWriteTime ([DateTimeOffset]::new(2026, 10, 3, 23, 30, 0, [TimeSpan]::FromHours(-8)))
        $first = ConvertFrom-IdsBaselineArchive -Bytes $zip
        $second = ConvertFrom-IdsBaselineArchive -Bytes $zip
        $hashStream = [IO.MemoryStream]::new($zip)
        try { $hash = (Get-FileHash -InputStream $hashStream -Algorithm SHA256).Hash.ToLowerInvariant() }
        finally { $hashStream.Dispose() }
        $first.sha256 | Should -BeExactly $hash
        $first.ignored | Should -Be 1
        (@($first.packs | ForEach-Object { (Read-IdsBaselinePack -Bytes $_).id }) -join ',') |
            Should -BeExactly 'synthetic-pack,cis.windows11.l1,cis.windows11.l2'
        ((Get-TestSkipLines $first) -join "`n") | Should -BeExactly (@(
            'kit/notes.json => Not a Settings Catalog policy or rule pack.'
            "kit/L1/secret.json => Setting 'syn.secret' in policy 'Synthetic L1 secret' is secret and was not converted."
        ) -join "`n")
        $level1 = Read-IdsBaselinePack -Bytes $first.packs[1]
        $level1.sources[0].retrievedOn | Should -BeExactly '2026-10-03'
        $level1.sources[0].revision | Should -BeExactly "Archive SHA-256 $($first.sha256)"
        $second.packs.Count | Should -Be $first.packs.Count
        for ($index = 0; $index -lt $first.packs.Count; $index++) {
            [Convert]::ToBase64String($second.packs[$index]) | Should -BeExactly ([Convert]::ToBase64String($first.packs[$index]))
        }
        $root = Join-Path $TestDrive 'imported'
        (@(Import-IdsBaselinePackSet -Packs $first.packs -ImportedRoot $root).added -join ',') | Should -BeExactly 'True,True,True'
        (@(Import-IdsBaselinePackSet -Packs $second.packs -ImportedRoot $root).added -join ',') | Should -BeExactly 'False,False,False'
        @(Get-ChildItem -LiteralPath $root -Filter '*.json').Count | Should -Be 3
    }
}
