BeforeAll {
    . "$PSScriptRoot\TestHelpers\Assessment.ps1"
    . "$PSScriptRoot\..\lib\BaselinePacks.ps1"
    . "$PSScriptRoot\..\lib\AssessmentRules.ps1"
    . "$PSScriptRoot\..\lib\Render.ps1"
    . "$PSScriptRoot\..\lib\AssessmentCollection.ps1"
    . "$PSScriptRoot\..\lib\AssessmentSettings.ps1"
    if (Test-Path "$PSScriptRoot\..\lib\AssessmentReports.ps1") { . "$PSScriptRoot\..\lib\AssessmentReports.ps1" }

    function New-ReportResult {
        $pack = Read-IdsBaselinePack -Bytes (New-IdsTestPackBytes)
        $snapshot = [pscustomobject]@{
            observations = @(); policies = @()
            sources = @([pscustomobject]@{ family = 'settingsCatalog'; platform = 'windows11'; complete = $true; errors = @() })
            issues = @()
        }
        $context = @{ platforms = @('windows11'); osVersions = @{ windows11 = '10.0.26100' }; enrollmentModes = @{} }
        $evaluation = Compare-IdsAssessment -Packs @($pack) -Snapshot $snapshot -Context $context
        [pscustomobject]@{
            schemaVersion = 1; runId = 'synthetic-run'; generatedAt = '2026-10-28T12:00:00Z'
            tenant = @{ id = 'synthetic-tenant'; displayName = 'Synthetic tenant' }
            context = $context; packs = @($pack); summaries = $evaluation.summaries
            controls = $evaluation.controls; policies = @(); collectionIssues = @()
            sources = $snapshot.sources
        }
    }

    function New-EvidenceResult {
        $result = New-ReportResult
        $pack = $result.packs[0]
        $prototype = $pack.controls[0]
        $observations = @()
        $pack.controls = @(foreach ($status in @('aligned', 'misaligned', 'missing', 'potentialConflict', 'notApplicable', 'notAssessed')) {
            $control = $prototype | ConvertTo-Json -Depth 20 | ConvertFrom-Json
            $control.id = $status
            $control.mappings[0].policyTypes = @('deviceManagementConfigurationPolicy')
            $control.mappings[0].settingId = "synthetic.$status"
            if ($status -eq 'notApplicable') { $control.applicability.osMin = '99' }
            if ($status -eq 'notAssessed') { $control.mappings = @(); $control.manualReason = 'Synthetic manual review limitation.' }
            if ($status -in @('aligned', 'misaligned', 'potentialConflict')) {
                $observations += [pscustomobject]@{
                    policyKey = 'settingsCatalog:one'; family = 'settingsCatalog'
                    settingId = "synthetic.$status"; property = $null; instancePath = '/nested[0]'
                    valueType = 'boolean'; value = ($status -ne 'misaligned')
                    configured = $true; secret = $false; supported = $true
                }
            }
            if ($status -eq 'potentialConflict') {
                $observations += [pscustomobject]@{
                    policyKey = 'settingsCatalog:two'; family = 'settingsCatalog'
                    settingId = "synthetic.$status"; property = $null; instancePath = '/nested[0]'
                    valueType = 'boolean'; value = $false; configured = $true; secret = $false; supported = $true
                }
            }
            $control
        })
        $one = New-IdsTestAssessmentPolicy
        $one.key = 'settingsCatalog:one'; $one.id = 'one'; $one.platform = 'windows11'
        $one.assignmentsComplete = $false
        $one.template = @{ templateId = 'synthetic-template'; templateDisplayVersion = '1'; platformType = 'windows11' }
        $two = New-IdsTestAssessmentPolicy
        $two.key = 'settingsCatalog:two'; $two.id = 'two'; $two.platform = 'windows11'
        $two.assignments = @(
            @{ id = 'include'; target = @{
                '@odata.type' = '#microsoft.graph.groupAssignmentTarget'
                groupId = 'synthetic-group'; groupDisplayName = 'Unresolved group (synthetic-group)'
                deviceAndAppManagementAssignmentFilterId = 'synthetic-filter'
                deviceAndAppManagementAssignmentFilterType = 'include'
            } },
            @{ id = 'exclude'; target = @{ '@odata.type' = '#microsoft.graph.exclusionGroupAssignmentTarget'; groupId = 'synthetic-excluded-group' } }
        )
        $issue = [pscustomobject]@{ family = 'settingsCatalog'; policyKey = $one.key; stage = 'assignments'; statusCode = 403; reason = 'Synthetic denied assignments.' }
        $snapshot = [pscustomobject]@{
            observations = $observations; policies = @($one, $two)
            sources = $result.sources; issues = @($issue)
        }
        $evaluation = Compare-IdsAssessment -Packs @($pack) -Snapshot $snapshot -Context $result.context
        $result.controls = $evaluation.controls; $result.summaries = $evaluation.summaries
        $result.policies = $snapshot.policies; $result.collectionIssues = $snapshot.issues
        return $result
    }
}

Describe 'Standalone assessment reports' {
    It 'shares documentation labels and value formatting in readable policy tables' {
        $catalogSettings = @([pscustomobject]@{
            settingDefinitions = @([pscustomobject]@{
                id = 'synthetic_enableFirewall'; displayName = 'Enable firewall'
                options = @([pscustomobject]@{ itemId = 'synthetic_enableFirewall_1'; displayName = 'Enabled' })
            })
            settingInstance = [pscustomobject]@{
                '@odata.type' = '#microsoft.graph.deviceManagementConfigurationChoiceSettingInstance'
                settingDefinitionId = 'synthetic_enableFirewall'
                choiceSettingValue = [pscustomobject]@{ value = 'synthetic_enableFirewall_1'; children = @() }
            }
        })
        $legacySettings = @([pscustomobject]@{ smartScreenEnableInShell = $false; smartScreenBlockOverrideForFiles = $true })
        $policies = @(
            (New-IdsTestAssessmentPolicy -Settings $catalogSettings)
            (New-IdsTestAssessmentPolicy -Family deviceConfiguration -PolicyType windows10EndpointProtectionConfiguration -Settings $legacySettings)
        )
        foreach ($policy in $policies) { $policy.platform = 'windows11' }
        $collection = New-IdsTestAssessmentCollection $policies
        $collection.sources = @(
            [pscustomobject]@{ family = 'settingsCatalog'; platform = 'windows11'; complete = $true; errors = @() }
            [pscustomobject]@{ family = 'deviceConfiguration'; platform = 'windows11'; complete = $true; errors = @() }
        )
        $snapshot = ConvertTo-IdsAssessmentSnapshot $collection
        Add-IdsAssessmentPolicyPresentation $collection $snapshot
        $readableCatalog = $snapshot.policies | Where-Object family -EQ settingsCatalog
        $readableLegacy = $snapshot.policies | Where-Object family -EQ deviceConfiguration
        ConvertTo-Json -InputObject $readableCatalog.settingsTables -Depth 20 -Compress |
            Should -Be (ConvertTo-Json -InputObject @(Format-IdsSettingsCatalog $catalogSettings -AsData) -Depth 20 -Compress)
        ConvertTo-Json -InputObject $readableLegacy.settingsTables -Depth 20 -Compress |
            Should -Be (ConvertTo-Json -InputObject @(Format-IdsTemplateSettings $legacySettings[0] -AsData) -Depth 20 -Compress)
        (Format-IdsSettingsCatalog $catalogSettings) | Should -Match '\| Enable firewall \| Enabled \|'
        (Format-IdsTemplateSettings $legacySettings[0]) | Should -Match '\| Smart Screen Enable In Shell \| No \|'
        $result = New-ReportResult
        $mapping = $result.packs[0].controls[0].mappings[0]
        $mapping.settingId = 'synthetic_enableFirewall'
        $mapping.policyTypes = @('deviceManagementConfigurationPolicy')
        $mapping.valueType = 'string'
        $mapping.expected = 'synthetic_enableFirewall_1'
        $evaluation = Compare-IdsAssessment $result.packs $snapshot $result.context
        Add-IdsAssessmentEvidencePresentation $collection $evaluation
        $result.controls = $evaluation.controls
        $result.policies = $snapshot.policies
        $result.controls[0].status | Should -Be 'aligned'
        $result.controls[0].expected[0].displayName | Should -Be 'Enable firewall'
        $result.controls[0].expected[0].displayValue | Should -Be 'Enabled'
        $result.controls[0].observed[0].displayValue | Should -Be 'Enabled'
        $result.controls[0].observed[0].value | Should -Be 'synthetic_enableFirewall_1'
        $projected = ConvertTo-IdsReportProjection $result
        $table = ($projected.policies | Where-Object family -EQ settingsCatalog).settingsTables[0]
        $table.headers | Should -Be @('Setting', 'Value')
        $table.rows[0].cells | Should -Be @('Enable firewall', 'Enabled')
        $text = [Net.WebUtility]::HtmlDecode((ConvertTo-IdsAssessmentMarkdown $result))
        $text | Should -Match '\| Enable firewall \| Enabled \|'
        $text | Should -Match '\| Smart Screen Enable In Shell \| No \|'
        $text | Should -Match '\| Expected \| Enable firewall \| Enabled \| eq \|'
        $text | Should -Match '\| Configured \| Enable firewall \| Enabled \|'
        $pair = Write-IdsAssessmentReports $result "$TestDrive\readable-reports" "$TestDrive\app" "$TestDrive\docs"
        $json = [IO.File]::ReadAllText($pair.jsonPath) | ConvertFrom-Json
        ($json.policies | Where-Object family -EQ settingsCatalog).settingsTables[0].rows[0].cells |
            Should -Be @('Enable firewall', 'Enabled')
    }

    It 'withholds incomplete or secret settings and never formats arbitrary legacy payloads' {
        $policy = New-IdsTestAssessmentPolicy -Family deviceConfiguration -PolicyType windows10EndpointProtectionConfiguration -Settings @(
            [pscustomobject]@{ smartScreenEnableInShell = $false; arbitraryPrivateField = 'SYNTHETIC-PRIVATE' }
        )
        $collection = New-IdsTestAssessmentCollection @($policy)
        $snapshot = ConvertTo-IdsAssessmentSnapshot $collection
        Add-IdsAssessmentPolicyPresentation $collection $snapshot
        ($snapshot.policies | ConvertTo-Json -Depth 20) | Should -Not -Match 'SYNTHETIC-PRIVATE|arbitraryPrivateField'
        $snapshot.policies[0].settingsComplete = $false
        Add-IdsAssessmentPolicyPresentation $collection $snapshot
        $snapshot.policies[0].settingsTables.Count | Should -Be 0
        $snapshot.policies[0].settingsNote | Should -Match 'withheld.*incomplete.*secret.*unsupported'
        $secretPolicy = New-IdsTestAssessmentPolicy -Settings @([pscustomobject]@{
            settingInstance = [pscustomobject]@{
                '@odata.type' = '#microsoft.graph.deviceManagementConfigurationSimpleSettingInstance'
                settingDefinitionId = 'synthetic-secret'
                simpleSettingValue = [pscustomobject]@{
                    '@odata.type' = '#microsoft.graph.deviceManagementConfigurationSecretSettingValue'
                    value = 'SYNTHETIC-PRIVATE'
                }
            }
        })
        $collection = New-IdsTestAssessmentCollection @($secretPolicy)
        $snapshot = ConvertTo-IdsAssessmentSnapshot $collection
        Add-IdsAssessmentPolicyPresentation $collection $snapshot
        $snapshot.policies[0].settingsTables.Count | Should -Be 0
        ($snapshot.policies | ConvertTo-Json -Depth 20) | Should -Not -Match 'SYNTHETIC-PRIVATE|rawSettings'
        $secretObservation = $snapshot.observations[0]
        Set-IdsAssessmentEvidencePresentation $secretObservation @{}
        $secretObservation.displayValue | Should -Be 'Unavailable (secret or unsupported evidence)'
    }

    It 'shares ADMX state and endpoint-security names with documentation' {
        $admx = @([pscustomobject]@{
            id = 'synthetic-definition-value'; enabled = $true
            definition = [pscustomobject]@{ id = 'synthetic-admx'; displayName = 'Turn on protection'; classType = 'machine'; categoryPath = 'Security' }
            presentationValues = @()
        })
        $intent = @([pscustomobject]@{ definitionId = 'synthetic_minimumPasswordLength'; value = 0 })
        $collection = New-IdsTestAssessmentCollection @(
            (New-IdsTestAssessmentPolicy -Family admx -PolicyType groupPolicyConfiguration -Settings $admx)
            (New-IdsTestAssessmentPolicy -Family intent -PolicyType deviceManagementIntent -Settings $intent)
        )
        $snapshot = ConvertTo-IdsAssessmentSnapshot $collection
        Add-IdsAssessmentPolicyPresentation $collection $snapshot
        $admxTables = ($snapshot.policies | Where-Object family -EQ admx).settingsTables
        $intentTables = ($snapshot.policies | Where-Object family -EQ intent).settingsTables
        ConvertTo-Json -InputObject $admxTables -Depth 20 -Compress |
            Should -Be (ConvertTo-Json -InputObject @(Format-IdsAdmxSettings $admx -AsData) -Depth 20 -Compress)
        ConvertTo-Json -InputObject $intentTables -Depth 20 -Compress |
            Should -Be (ConvertTo-Json -InputObject @(Format-IdsIntentSettings $intent -AsData) -Depth 20 -Compress)
        $admxTables[0].rows[0].cells | Should -Contain 'Enabled'
        $intentTables[0].rows[0].cells | Should -Be @('Minimum Password Length', '0')
    }

    It 'escapes readable settings without trusting them as report markup' {
        $result = New-ReportResult
        $policy = New-IdsTestAssessmentPolicy
        $policy | Add-Member NoteProperty settingsTables @(@{
            title = '<script>alert(1)</script>'; headers = @('Setting', 'Value')
            rows = @(@{ cells = @('[click](javascript:bad())', "line`n| injected |") })
        })
        $result.policies = @($policy)
        $markdown = ConvertTo-IdsAssessmentMarkdown $result
        $markdown | Should -Not -Match '<script>|\[click\]\(javascript:|(?m)^\| injected \|'
        $markdown | Should -Match '&#60;script&#62;'
    }

    It 'renders the actual engine mapping array and preserves identity, coverage and scope' {
        $result = New-ReportResult
        $text = [Net.WebUtility]::HtmlDecode((ConvertTo-IdsAssessmentMarkdown -Result $result))
        $text | Should -Match 'synthetic-run'
        $text | Should -Match 'synthetic-tenant'
        $text | Should -Match $result.packs[0].sha256
        $text | Should -Match 'partial'
        $text | Should -Match 'settingsCatalog'
        $text | Should -Match 'synthetic.required'
        $text | Should -Match 'true'
        $text | Should -Match 'mapped famil'
        $text | Should -Match 'not.*tenant-wide'
        $text | Should -Match 'not.*device compliance'
        $text | Should -Match 'user-selected'
        $text | Should -Match 'Assessment coverage'
        $text | Should -Match 'Configuration alignment'
    }

    It 'publishes separate UTF-8 pairs without touching exports or trusting runId as a path' {
        $install = Join-Path $TestDrive 'app'
        $export = Join-Path $TestDrive 'docs'
        $output = Join-Path $TestDrive 'docs-other'
        [void][IO.Directory]::CreateDirectory($export)
        [IO.File]::WriteAllText((Join-Path $export 'keep.txt'), 'untouched')
        $result = New-ReportResult
        $result.runId = '..\docs\overwrite'
        $result.tenant.displayName = 'Synthetic café 漢字'
        $one = Write-IdsAssessmentReports $result $output $install $export
        $two = Write-IdsAssessmentReports $result $output $install $export
        $one.root | Should -Not -Be $two.root
        @($one.PSObject.Properties.Name) -join ',' | Should -BeExactly 'root,markdownPath,jsonPath'
        foreach ($pair in @($one, $two)) {
            Split-Path $pair.root | Should -Be $output
            Split-Path $pair.markdownPath | Should -Be $pair.root
            @(Get-ChildItem -LiteralPath $pair.root).Count | Should -Be 2
            [IO.File]::ReadAllText($pair.markdownPath) | Should -BeExactly (ConvertTo-IdsAssessmentMarkdown $result)
            $json = [IO.File]::ReadAllText($pair.jsonPath) | ConvertFrom-Json
            $json.tenant.displayName | Should -BeExactly 'Synthetic café 漢字'
            $json.controls[0].expected -is [array] | Should -BeTrue
            $json.controls[0].expected[0].expected | Should -BeTrue
            $json.controls[0].observed -is [array] | Should -BeTrue
            $json.packs[0].sha256 | Should -BeExactly $result.packs[0].sha256
            [IO.File]::ReadAllBytes($pair.jsonPath)[0] | Should -Be 123
        }
        [IO.File]::ReadAllText((Join-Path $export 'keep.txt')) | Should -BeExactly 'untouched'
        @(Get-ChildItem $output -Force).Count | Should -Be 2
    }

    It 'rejects equal, ancestor and descendant roots with component boundaries' -ForEach @(
        @{ I = 'app'; E = 'docs'; O = 'docs' }
        @{ I = 'app'; E = 'docs'; O = 'docs\assessments' }
        @{ I = 'app'; E = 'reports\docs'; O = 'reports' }
        @{ I = 'app'; E = 'docs'; O = 'app\reports' }
        @{ I = 'reports\app'; E = 'docs'; O = 'reports' }
        @{ I = 'app'; E = 'app\docs'; O = 'reports' }
        @{ I = 'docs\app'; E = 'docs'; O = 'reports' }
        @{ I = 'APP'; E = 'docs'; O = 'app' }
        @{ I = 'app'; E = 'docs'; O = 'other\..\docs\reports' }
    ) {
        {
            Write-IdsAssessmentReports (New-ReportResult) (Join-Path $TestDrive $O) `
                (Join-Path $TestDrive $I) (Join-Path $TestDrive $E)
        } | Should -Throw '*overlap*'
        Test-Path (Join-Path $TestDrive 'app') | Should -BeFalse
    }

    It 'rejects relative, ambiguous and non-directory roots' {
        $file = Join-Path $TestDrive 'file'
        [IO.File]::WriteAllText($file, 'sentinel')
        foreach ($bad in @('relative', 'C:relative', '\rooted', "$TestDrive\reports.", "$TestDrive\reports ", "$TestDrive\reports:stream", $file)) {
            { Write-IdsAssessmentReports (New-ReportResult) $bad "$TestDrive\app" "$TestDrive\docs" } | Should -Throw
        }
        [IO.File]::ReadAllText($file) | Should -BeExactly 'sentinel'
    }

    It 'rejects junctions in every root including existing ancestors of nonexistent paths' {
        $real = Join-Path $TestDrive 'real'
        $alias = Join-Path $TestDrive 'alias'
        [void][IO.Directory]::CreateDirectory($real)
        [void](New-Item -ItemType Junction -Path $alias -Target $real)
        foreach ($roots in @(
            @("$alias\new", "$TestDrive\app", "$TestDrive\docs"),
            @("$TestDrive\reports", "$alias\new", "$TestDrive\docs"),
            @("$TestDrive\reports", "$TestDrive\app", "$alias\new")
        )) {
            { Write-IdsAssessmentReports (New-ReportResult) $roots[0] $roots[1] $roots[2] } | Should -Throw '*reparse*'
        }
        @(Get-ChildItem $real).Count | Should -Be 0
    }

    It 'fails after the first staged file without publishing or deleting other runs' {
        $output = Join-Path $TestDrive 'reports'
        $existing = Write-IdsAssessmentReports (New-ReportResult) $output "$TestDrive\app" "$TestDrive\docs"
        Mock Set-Content {
            if ($LiteralPath.EndsWith('assessment.md')) {
                Test-Path (Join-Path (Split-Path $LiteralPath) 'assessment.json') | Should -BeTrue
                throw 'Synthetic second-write failure'
            }
            [IO.File]::WriteAllText($LiteralPath, $Value, [Text.UTF8Encoding]::new($false))
        }
        {
            Write-IdsAssessmentReports (New-ReportResult) $output "$TestDrive\app" "$TestDrive\docs"
        } | Should -Throw '*report publication failed*'
        Should -Invoke Set-Content -Times 1 -ParameterFilter { $LiteralPath.EndsWith('assessment.md') }
        @(Get-ChildItem $output -Force).Count | Should -Be 1
        Test-Path $existing.markdownPath | Should -BeTrue
        Test-Path $existing.jsonPath | Should -BeTrue
    }

    It 'keeps all actual engine statuses, policy mismatches, assignment scopes and collection limitations in both reports' {
        $result = New-EvidenceResult
        $pair = Write-IdsAssessmentReports $result "$TestDrive\reports" "$TestDrive\app" "$TestDrive\docs"
        $json = [IO.File]::ReadAllText($pair.jsonPath) | ConvertFrom-Json
        $text = [Net.WebUtility]::HtmlDecode([IO.File]::ReadAllText($pair.markdownPath))
        foreach ($status in @('aligned', 'misaligned', 'missing', 'potentialConflict', 'notApplicable', 'notAssessed')) {
            ($json.controls | Where-Object controlId -EQ $status).status | Should -BeExactly $status
            $json.summaries[0].counts.$status | Should -Be 1
            $text | Should -Match $status
        }
        $json.summaries[0].assessed | Should -Be 4
        $json.summaries[0].coverageDenominator | Should -Be 5
        $json.summaries[0].coveragePercent | Should -Be 80
        $json.summaries[0].alignmentPercent | Should -Be 25
        $conflict = $json.controls | Where-Object controlId -EQ potentialConflict
        $conflict.observed.Count | Should -Be 2
        $conflict.policyResults.Count | Should -Be 2
        $conflict.policyResults[0].observed[0].value | Should -BeTrue
        $conflict.policyResults[1].observed[0].value | Should -BeFalse
        $conflict.policyResults[0].assigned | Should -BeNullOrEmpty
        $conflict.policyResults[1].assigned | Should -BeTrue
        $json.policies[1].assignments.Count | Should -Be 2
        ($json.policies[1].assignments | Where-Object id -EQ include).target.groupDisplayName | Should -BeExactly 'Unresolved group (synthetic-group)'
        $text | Should -Match 'synthetic-excluded-group'
        $text | Should -Match 'synthetic-filter'
        $text | Should -Match 'Synthetic denied assignments'
        $text | Should -Match 'Synthetic manual review limitation'
        $text | Should -Match 'synthetic-template'
        $json.collectionIssues[0].statusCode | Should -Be 403
        $json.packs[0].PSObject.Properties.Name | Should -Not -Contain controls
    }

    It 'preserves empty sets, false, zero, null percentages and unknown assignment evidence' {
        $result = New-EvidenceResult
        $control = $result.controls | Where-Object controlId -EQ aligned
        foreach ($case in @(
            @{ Type = 'boolean'; Value = $false },
            @{ Type = 'number'; Value = 0 },
            @{ Type = 'stringSet'; Value = @() },
            @{ Type = 'numberSet'; Value = @(0) }
        )) {
            $control.expected[0].valueType = $case.Type
            $control.expected[0].expected = $case.Value
            $control.observed[0].valueType = $case.Type
            $control.observed[0].value = $case.Value
            $result.summaries[0].coveragePercent = $null; $result.summaries[0].alignmentPercent = $null
            $pair = Write-IdsAssessmentReports $result "$TestDrive\reports" "$TestDrive\app" "$TestDrive\docs"
            $json = [IO.File]::ReadAllText($pair.jsonPath) | ConvertFrom-Json
            $copy = $json.controls | Where-Object controlId -EQ aligned
            $json.summaries[0].coveragePercent | Should -BeNullOrEmpty
            $json.summaries[0].alignmentPercent | Should -BeNullOrEmpty
            $text = [IO.File]::ReadAllText($pair.markdownPath)
            $text | Should -Match '\| coveragePercent \| not available \|'
            $text | Should -Match '\| alignmentPercent \| not available \|'
            if ($case.Type.EndsWith('Set')) {
                $copy.expected[0].expected -is [array] | Should -BeTrue
                $copy.observed[0].value -is [array] | Should -BeTrue
                $copy.observed[0].value.Count | Should -Be $case.Value.Count
            } else {
                if ($case.Type -eq 'boolean') { $copy.observed[0].value -is [bool] | Should -BeTrue }
                else { $copy.observed[0].value -is [ValueType] | Should -BeTrue }
                $copy.observed[0].value | Should -Be $case.Value
            }
        }
    }

    It 'excludes unknown/auth/raw/script fields at every record boundary and redacts unsupported and secret values' {
        $result = New-EvidenceResult
        $canary = 'sensitive-canary-do-not-serialize'
        $result | Add-Member NoteProperty auth @{ accessToken = $canary }
        $result | Add-Member NoteProperty session @{ browserProfile = $canary }
        $result.tenant.accessToken = $canary
        $result.context.osVersions.rawSettings = $canary
        foreach ($record in @($result.packs[0], $result.packs[0].sources[0], $result.controls[0],
            $result.controls[0].expected[0], $result.controls[0].observed[0], $result.controls[0].policyResults[0],
            $result.controls[0].references[0], $result.policies[0], $result.collectionIssues[0], $result.sources[0])) {
            $record | Add-Member NoteProperty scriptContent $canary
        }
        $result.policies[0].rawSettings = @(@{ payload = $canary })
        $result.policies[0].template.payload = $canary
        $result.policies[1].assignments[0].payload = $canary
        $result.policies[1].assignments[0].target.accessToken = $canary
        $result.controls[0].observed[0].secret = $true
        $result.controls[0].observed[0].value = $canary
        $result.controls[0].policyResults[0].observed[0].supported = $false
        $result.controls[0].policyResults[0].observed[0].value = $canary
        $pair = Write-IdsAssessmentReports $result "$TestDrive\reports" "$TestDrive\app" "$TestDrive\docs"
        foreach ($path in @($pair.markdownPath, $pair.jsonPath)) {
            [IO.File]::ReadAllText($path) | Should -Not -Match "$canary|rawSettings|scriptContent|accessToken|browserProfile"
        }
        $json = [IO.File]::ReadAllText($pair.jsonPath) | ConvertFrom-Json
        $json.controls[0].observed[0].value | Should -BeNullOrEmpty
    }

    It 'escapes imported HTML, Markdown, multiline text and unsafe links without truncating evidence' {
        $result = New-ReportResult
        $attack = '<img src=x onerror=alert(1)> & | [click](javascript:alert(1)) **bold** `code` \ #heading' + "`n## injected"
        $result.controls[0].title = $attack
        $result.controls[0].reason = ('z' * 600) + $attack
        $result.controls[0].references[0].url = 'javascript:alert(1)'
        $text = ConvertTo-IdsAssessmentMarkdown $result
        $text | Should -Not -Match '<img|javascript:alert\(1\)|\*\*bold\*\*|`code`|(?m)^## injected'
        $text | Should -Match '&#60;img'
        $decoded = [Net.WebUtility]::HtmlDecode($text)
        $decoded | Should -Match ([regex]::Escape(('z' * 600) + $attack))
    }

    It 'sorts evidence reproducibly in Markdown and JSON without mutating input' {
        $result = New-EvidenceResult
        $before = $result | ConvertTo-Json -Depth 64
        $one = Write-IdsAssessmentReports $result "$TestDrive\reports" "$TestDrive\app" "$TestDrive\docs"
        ($result | ConvertTo-Json -Depth 64) | Should -BeExactly $before
        [array]::Reverse($result.controls)
        [array]::Reverse($result.policies)
        foreach ($control in $result.controls) {
            [array]::Reverse($control.observed)
            [array]::Reverse($control.policyResults)
            [array]::Reverse($control.references)
        }
        [array]::Reverse($result.policies[0].assignments)
        $two = Write-IdsAssessmentReports $result "$TestDrive\reports" "$TestDrive\app" "$TestDrive\docs"
        [IO.File]::ReadAllText($one.jsonPath) | Should -BeExactly ([IO.File]::ReadAllText($two.jsonPath))
        [IO.File]::ReadAllText($one.markdownPath) | Should -BeExactly ([IO.File]::ReadAllText($two.markdownPath))
    }

    It 'retains all five actual Microsoft checks and their partial legacy/personal/beta source boundaries' {
        $result = New-ReportResult
        $packs = @(Get-ChildItem "$PSScriptRoot\..\baselines\microsoft-*.json" | ForEach-Object {
            Read-IdsBaselinePack -Bytes ([IO.File]::ReadAllBytes($_.FullName))
        })
        $evaluation = Compare-IdsAssessment -Packs $packs -Snapshot ([pscustomobject]@{
            policies = @(); observations = @(); sources = @(); issues = @()
        }) -Context @{ platforms = @('windows11', 'macos', 'iosIpados', 'androidEnterprise'); osVersions = @{}; enrollmentModes = @{} }
        $result.packs = $packs; $result.controls = $evaluation.controls; $result.summaries = $evaluation.summaries
        $pair = Write-IdsAssessmentReports $result "$TestDrive\reports" "$TestDrive\app" "$TestDrive\docs"
        $json = [IO.File]::ReadAllText($pair.jsonPath) | ConvertFrom-Json
        $json.packs.Count | Should -Be 4
        $json.controls.Count | Should -Be 5
        @($json.packs | Where-Object { $_.coverage.inventory -ne 'partial' }).Count | Should -Be 0
        $text = [Net.WebUtility]::HtmlDecode([IO.File]::ReadAllText($pair.markdownPath))
        foreach ($pack in $packs) {
            $text | Should -Match ([regex]::Escape($pack.profile))
            $text | Should -Match ([regex]::Escape($pack.sha256))
        }
        $text | Should -Match 'Personally-owned work profile'
        $text | Should -Match 'Personal basic security'
        $text | Should -Match 'graph-rest-beta'
        $text | Should -Match 'beta/deprecated'
        $text | Should -Match 'not encryption compliance or recovery-key configuration'
    }

    It 'rejects unsupported schema/status and object-valued evidence rather than serializing arbitrary objects' {
        foreach ($change in @(
            { param($r) $r.schemaVersion = 2 },
            { param($r) $r.controls[0].status = 'compliant' },
            { param($r) $r.controls[0].expected[0].expected = @{ payload = 'not-a-boolean' } },
            { param($r) $r.tenant.displayName = @{ token = 'not-text' } }
        )) {
            $result = New-ReportResult
            & $change $result
            { Write-IdsAssessmentReports $result "$TestDrive\invalid-reports" "$TestDrive\app" "$TestDrive\docs" } | Should -Throw
            Test-Path "$TestDrive\invalid-reports" | Should -BeFalse
        }
    }

    It 'preserves source failures, empty result arrays and numeric membership evidence consistently' {
        $result = New-ReportResult
        $issue = [pscustomobject]@{
            family = 'settingsCatalog'; policyKey = $null; stage = 'inventory'
            statusCode = 503; reason = 'Synthetic incomplete inventory.'
        }
        $result.sources[0].complete = $false
        $result.sources[0].errors = @($issue)
        $result.collectionIssues = @($issue)
        $mapping = $result.controls[0].expected[0]
        $mapping.valueType = 'number'; $mapping.operator = 'in'; $mapping.expected = @(7)
        $pair = Write-IdsAssessmentReports $result "$TestDrive\reports" "$TestDrive\app" "$TestDrive\docs"
        $json = [IO.File]::ReadAllText($pair.jsonPath) | ConvertFrom-Json
        $json.sources[0].complete | Should -BeFalse
        $json.sources[0].errors -is [array] | Should -BeTrue
        $json.sources[0].errors[0].statusCode | Should -Be 503
        $json.controls[0].expected[0].expected -is [array] | Should -BeTrue
        $json.controls[0].expected[0].expected[0] | Should -Be 7
        $json.policies -is [array] | Should -BeTrue
        $json.policies.Count | Should -Be 0
        [IO.File]::ReadAllText($pair.markdownPath) | Should -Match 'Synthetic incomplete inventory'
        $result.controls = @(); $result.summaries = @(); $result.packs = @()
        $pair = Write-IdsAssessmentReports $result "$TestDrive\reports" "$TestDrive\app" "$TestDrive\docs"
        $json = [IO.File]::ReadAllText($pair.jsonPath) | ConvertFrom-Json
        foreach ($field in @('packs', 'summaries', 'controls', 'policies')) {
            $json.$field -is [array] | Should -BeTrue
            $json.$field.Count | Should -Be 0
        }
    }

    It 'rejects object-valued configured observations instead of leaking arbitrary payloads' {
        $result = New-EvidenceResult
        $result.controls[0].observed[0].value = @{ script = 'synthetic-forbidden-payload' }
        { ConvertTo-IdsAssessmentMarkdown $result } | Should -Throw '*Invalid boolean field*'
        { Write-IdsAssessmentReports $result "$TestDrive\bad-value" "$TestDrive\app" "$TestDrive\docs" } | Should -Throw '*Invalid boolean field*'
        Test-Path "$TestDrive\bad-value" | Should -BeFalse
    }
}
