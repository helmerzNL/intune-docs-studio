BeforeAll {
    $repo = Split-Path -Parent $PSScriptRoot
    . (Join-Path $repo 'lib\Graph.ps1')
    . (Join-Path $repo 'lib\BaselinePacks.ps1')
    $module = Join-Path $repo 'lib\AssessmentCollection.ps1'
    if (Test-Path -LiteralPath $module) { . $module }
    function New-CollectionPack([string]$Family = 'settingsCatalog', [string]$Platform = 'windows11') {
        return [pscustomobject]@{
            platform = $Platform
            sources = @(@{ url = 'https://untrusted.invalid/reference' })
            controls = @(@{ reference = 'https://graph.microsoft.com/beta/danger'; mappings = @(@{ family = $Family }) })
        }
    }
}

Describe 'Strict assessment paging' {
    It 'propagates only sanitized structured authentication classification through inventory issues' {
        Mock Invoke-IdsGraph {
            $exception = [Exception]::new('Graph pagination SYNTHETIC-SECRET invalid_grant provider payload')
            $exception | Add-Member NoteProperty OAuthError 'invalid_grant'
            throw $exception
        }
        $collection = Get-IdsAssessmentCollection -Packs @(New-CollectionPack) -Context @{ platforms = @('windows11') }
        $collection.issues.Count | Should -Be 1
        $collection.issues[0].authenticationFailure | Should -BeTrue
        $collection.issues[0].statusCode | Should -BeNullOrEmpty
        ($collection | ConvertTo-Json -Depth 20) | Should -Not -Match 'SYNTHETIC-SECRET|invalid_grant|OAuthError'
    }

    It 'does not infer authentication failure from provider message text' {
        Mock Invoke-IdsGraph { throw 'invalid_grant SYNTHETIC-SECRET' }
        $page = Get-IdsAssessmentPages -Path '/synthetic'
        $page.complete | Should -BeFalse
        $page.errors[0].authenticationFailure | Should -BeFalse
        ($page | ConvertTo-Json -Depth 10) | Should -Not -Match 'invalid_grant|SYNTHETIC-SECRET'
    }

    It 'preserves structured authentication failure when the batch transport throws' {
        Mock Invoke-IdsGraphBatch {
            $exception = [Exception]::new('SYNTHETIC-SECRET provider payload')
            $exception | Add-Member NoteProperty OAuthError 'invalid_grant'
            throw $exception
        }
        $reads = Get-IdsAssessmentBatchPages @(@{ id = 'assignments'; url = '/synthetic/assignments' })
        $reads.assignments.complete | Should -BeFalse
        $reads.assignments.errors[0].authenticationFailure | Should -BeTrue
        ($reads | ConvertTo-Json -Depth 10) | Should -Not -Match 'SYNTHETIC-SECRET|invalid_grant|OAuthError'
    }

    It 'does not treat a failed second page as a complete first page' {
        Mock Invoke-IdsGraph {
            param($Path)
            if ($Path -eq '/synthetic') {
                return [pscustomobject]@{
                    value = @([pscustomobject]@{ id = 'policy-a' })
                    '@odata.nextLink' = 'https://graph.microsoft.com/beta/synthetic?page=2'
                }
            }
            throw 'synthetic access failure'
        }
        $page = Get-IdsAssessmentPages -Path '/synthetic'
        $page.complete | Should -BeFalse
        $page.items.Count | Should -Be 1
        $page.errors.Count | Should -Be 1
    }

    It 'preserves empty/singleton arrays with <_> objects' -ForEach @(0, 1, 2) {
        $script:pageSize = $_
        Mock Invoke-IdsGraph { [pscustomobject]@{ value = @(for ($i = 0; $i -lt $script:pageSize; $i++) { @{ id = "$i" } }) } }
        $page = Get-IdsAssessmentPages -Path '/synthetic'
        $page.complete | Should -BeTrue
        ($page.items -is [array]) | Should -BeTrue
        $page.items.Count | Should -Be $script:pageSize
        ($page.errors -is [array]) | Should -BeTrue
        Should -Invoke Invoke-IdsGraph -Times 1 -Exactly -ParameterFilter { -not $All -and -not $Tolerant }
    }

    It 'follows a same-resource next link in the selected version' {
        Mock Invoke-IdsGraph {
            param($Path)
            if ($Path -eq '/synthetic') {
                @{ value = @(@{ id = 'a' }); '@odata.nextLink' = 'https://graph.microsoft.com/v1.0/synthetic?page=2' }
            } else { @{ value = @(@{ id = 'b' }) } }
        }
        $page = Get-IdsAssessmentPages -Path '/synthetic' -Version 'v1.0'
        $page.complete | Should -BeTrue
        $page.items.id | Should -Be @('a', 'b')
        Should -Invoke Invoke-IdsGraph -Times 2 -Exactly -ParameterFilter { $Version -eq 'v1.0' }
    }

    It 'rejects malformed collection bodies: <name>' -ForEach @(
        @{ name = 'null'; body = $null }, @{ name = 'missing value'; body = @{} },
        @{ name = 'null value'; body = @{ value = $null } },
        @{ name = 'scalar value'; body = @{ value = 'a' } },
        @{ name = 'object value'; body = @{ value = @{ id = 'a' } } },
        @{ name = 'null item'; body = @{ value = @($null) } },
        @{ name = 'scalar item'; body = @{ value = @(7) } }
    ) {
        $script:badBody = $body
        Mock Invoke-IdsGraph { $script:badBody }
        $page = Get-IdsAssessmentPages -Path '/synthetic'
        $page.complete | Should -BeFalse
        $page.errors.Count | Should -Be 1
    }

    It 'refuses a next link before sending it: <_>' -ForEach @(
        'http://graph.microsoft.com/beta/synthetic?page=2',
        'https://other.invalid/beta/synthetic?page=2',
        'https://graph.microsoft.com:444/beta/synthetic?page=2',
        'https://user:pass@graph.microsoft.com/beta/synthetic?page=2',
        'https://graph.microsoft.com/beta/synthetic?page=2#fragment',
        'https://graph.microsoft.com/v1.0/synthetic?page=2',
        'https://graph.microsoft.com/beta/other?page=2',
        '//other.invalid/beta/synthetic', '/synthetic?page=2', '', 3
    ) {
        $script:badLink = $_
        Mock Invoke-IdsGraph { @{ value = @(@{ id = 'a' }); '@odata.nextLink' = $script:badLink } }
        $page = Get-IdsAssessmentPages -Path '/synthetic'
        $page.complete | Should -BeFalse
        $page.items.Count | Should -Be 1
        Should -Invoke Invoke-IdsGraph -Times 1 -Exactly
    }

    It 'detects cycles without requesting a page twice' {
        Mock Invoke-IdsGraph { @{ value = @(@{ id = 'a' }); '@odata.nextLink' = 'https://graph.microsoft.com/beta/synthetic' } }
        $page = Get-IdsAssessmentPages -Path '/synthetic'
        $page.complete | Should -BeFalse
        $page.errors[0].reason | Should -Match 'cycle'
        Should -Invoke Invoke-IdsGraph -Times 1 -Exactly
    }

    It 'marks a remaining next link at the 500-page cap incomplete' {
        $script:pageNumber = 0
        Mock Invoke-IdsGraph {
            $script:pageNumber++
            @{ value = @(@{ id = "$script:pageNumber" }); '@odata.nextLink' = "https://graph.microsoft.com/beta/synthetic?page=$script:pageNumber" }
        }
        $page = Get-IdsAssessmentPages -Path '/synthetic'
        $page.complete | Should -BeFalse
        $page.items.Count | Should -Be 500
        $page.errors[0].reason | Should -Match '500'
        Should -Invoke Invoke-IdsGraph -Times 500 -Exactly
    }

    It 'retains status <_> without retaining response content' -ForEach @(403, 429, 500, 503) {
        $script:failureCode = $_
        Mock Invoke-IdsGraph {
            $error = [Exception]::new('synthetic-sensitive-response')
            $error | Add-Member NoteProperty StatusCode $script:failureCode
            throw $error
        }
        $page = Get-IdsAssessmentPages -Path '/synthetic'
        $page.complete | Should -BeFalse
        $page.errors[0].statusCode | Should -Be $script:failureCode
        ($page | ConvertTo-Json -Depth 10) | Should -Not -Match 'synthetic-sensitive-response'
    }
}

Describe 'Collection completeness and nested reads' {
    BeforeEach {
        $script:graphBodies = @{
            '/deviceManagement/configurationPolicies' = @{ value = @(@{ id = 'policy-a'; platforms = 'windows10' }) }
            '/deviceManagement/groupPolicyConfigurations' = @{ value = @(@{ id = 'admx' }) }
            '/deviceManagement/intents' = @{ value = @(@{ id = 'intent'; templateId = 'template-a' }) }
            '/deviceManagement/templates?$select=id,displayName,templateType,platformType' = @{ value = @(@{ id = 'template-a'; platformType = 'windows10' }) }
        }
        $script:batchEntries = @{}
        Mock Invoke-IdsGraph {
            param($Path)
            if ($script:graphBodies.ContainsKey($Path)) { return $script:graphBodies[$Path] }
            throw 'Synthetic request failure'
        }
        Mock Invoke-IdsGraphBatch {
            param($Requests)
            $result = @{}
            foreach ($request in $Requests) {
                if ($script:batchEntries.ContainsKey($request.url)) {
                    if ($null -ne $script:batchEntries[$request.url]) { $result[$request.id] = $script:batchEntries[$request.url] }
                } else { $result[$request.id] = @{ status = 200; body = @{ value = @() } } }
            }
            return $result
        }
    }

    It 'follows settings and assignment batch next links independently' {
        $settingsUrl = "/deviceManagement/configurationPolicies('policy-a')/settings?`$expand=settingDefinitions&`$top=1000"
        $assignmentsUrl = "/deviceManagement/configurationPolicies('policy-a')/assignments"
        $script:batchEntries[$settingsUrl] = @{ status = 200; body = @{ value = @(@{ id = 's1'; settingInstance = @{ settingDefinitionId = 'stable' } }); '@odata.nextLink' = "https://graph.microsoft.com/beta/deviceManagement/configurationPolicies('policy-a')/settings?page=2" } }
        $script:batchEntries[$assignmentsUrl] = @{ status = 200; body = @{ value = @(@{ id = 'a1'; target = @{ '@odata.type' = '#microsoft.graph.allDevicesAssignmentTarget' } }); '@odata.nextLink' = "https://graph.microsoft.com/beta/deviceManagement/configurationPolicies('policy-a')/assignments?page=2" } }
        $script:graphBodies["https://graph.microsoft.com/beta/deviceManagement/configurationPolicies('policy-a')/settings?page=2"] = @{ value = @(@{ id = 's2'; settingInstance = @{ settingDefinitionId = 'stable2' } }) }
        $script:graphBodies["https://graph.microsoft.com/beta/deviceManagement/configurationPolicies('policy-a')/assignments?page=2"] = @{ value = @(@{ id = 'a2'; target = @{ '@odata.type' = '#microsoft.graph.allLicensedUsersAssignmentTarget' } }) }
        $r = Get-IdsAssessmentCollection -Packs @(New-CollectionPack) -Context @{ platforms = @('windows11') }
        $r.policies[0].rawSettings.id | Should -Be @('s1', 's2')
        $r.policies[0].assignments.id | Should -Be @('a1', 'a2')
        $r.policies[0].settingsComplete | Should -BeTrue
        $r.policies[0].assignmentsComplete | Should -BeTrue
        $r.issues.Count | Should -Be 0
    }

    It 'does not erase settings completeness for <stage> batch failure <name>' -ForEach @(
        @{ stage = 'assignments'; name = 'omitted entry'; entry = $null; status = $null }
        @{ stage = 'assignments'; name = '403'; entry = @{ status = 403; body = @{ value = @() } }; status = 403 }
        @{ stage = 'settings'; name = 'omitted entry'; entry = $null; status = $null }
        @{ stage = 'settings'; name = '429'; entry = @{ status = 429; body = @{ value = @() } }; status = 429 }
        @{ stage = 'settings'; name = '500'; entry = @{ status = 500; body = @{ value = @() } }; status = 500 }
        @{ stage = 'settings'; name = '503'; entry = @{ status = 503; body = @{ value = @() } }; status = 503 }
        @{ stage = 'settings'; name = 'null body'; entry = @{ status = 200; body = $null }; status = $null }
        @{ stage = 'settings'; name = 'missing status'; entry = @{ body = @{ value = @() } }; status = $null }
        @{ stage = 'settings'; name = 'string status'; entry = @{ status = '200'; body = @{ value = @() } }; status = $null }
    ) {
        $url = if ($stage -eq 'settings') { "/deviceManagement/configurationPolicies('policy-a')/settings?`$expand=settingDefinitions&`$top=1000" } else { "/deviceManagement/configurationPolicies('policy-a')/assignments" }
        $script:batchEntries[$url] = $entry
        $r = Get-IdsAssessmentCollection -Packs @(New-CollectionPack) -Context @{ platforms = @('windows11') }
        $r.policies[0].settingsComplete | Should -Be ($stage -ne 'settings')
        $r.policies[0].assignmentsComplete | Should -Be ($stage -ne 'assignments')
        $r.sources[0].complete | Should -Be ($stage -ne 'settings')
        $r.issues.Count | Should -Be 1
        $r.issues[0].stage | Should -Be $stage
        $r.issues[0].policyKey | Should -Be 'settingsCatalog:policy-a'
        $r.issues[0].statusCode | Should -Be $status
    }

    It 'retains partial nested settings after a continuation failure' {
        $script:batchEntries["/deviceManagement/configurationPolicies('policy-a')/settings?`$expand=settingDefinitions&`$top=1000"] = @{
            status = 200; body = @{ value = @(@{ id = 's1'; settingInstance = @{ settingDefinitionId = 'stable' } }); '@odata.nextLink' = "https://graph.microsoft.com/beta/deviceManagement/configurationPolicies('policy-a')/settings?page=2" }
        }
        $r = Get-IdsAssessmentCollection -Packs @(New-CollectionPack) -Context @{ platforms = @('windows11') }
        $r.policies[0].rawSettings.Count | Should -Be 1
        $r.policies[0].settingsComplete | Should -BeFalse
        $r.policies[0].assignmentsComplete | Should -BeTrue
        $r.sources[0].complete | Should -BeFalse
        $r.issues[0].stage | Should -Be 'settings'
    }

    It 'independently pages ADMX definition values and presentation values' {
        $script:batchEntries["/deviceManagement/groupPolicyConfigurations('admx')/definitionValues?`$expand=definition"] = @{
            status = 200; body = @{ value = @(@{ id = 'd1'; definition = @{ id = 'stable' } }); '@odata.nextLink' = "https://graph.microsoft.com/beta/deviceManagement/groupPolicyConfigurations('admx')/definitionValues?page=2" }
        }
        $script:graphBodies["https://graph.microsoft.com/beta/deviceManagement/groupPolicyConfigurations('admx')/definitionValues?page=2"] = @{ value = @(@{ id = 'd2'; definition = @{ id = 'stable2' } }) }
        $script:batchEntries["/deviceManagement/groupPolicyConfigurations('admx')/definitionValues('d1')/presentationValues?`$expand=presentation"] = @{
            status = 200; body = @{ value = @(@{ id = 'p1'; value = $false }); '@odata.nextLink' = "https://graph.microsoft.com/beta/deviceManagement/groupPolicyConfigurations('admx')/definitionValues('d1')/presentationValues?page=2" }
        }
        $script:graphBodies["https://graph.microsoft.com/beta/deviceManagement/groupPolicyConfigurations('admx')/definitionValues('d1')/presentationValues?page=2"] = @{ value = @(@{ id = 'p2'; value = 0 }) }
        $r = Get-IdsAssessmentCollection -Packs @(New-CollectionPack 'admx') -Context @{ platforms = @('windows11') }
        $r.policies[0].rawSettings.id | Should -Be @('d1', 'd2')
        $r.policies[0].rawSettings[0].presentationValues.id | Should -Be @('p1', 'p2')
        $r.policies[0].settingsComplete | Should -BeTrue
        $r.issues.Count | Should -Be 0
    }

    It 'does not call an absent ADMX presentation entry an empty setting' {
        $script:batchEntries["/deviceManagement/groupPolicyConfigurations('admx')/definitionValues?`$expand=definition"] = @{ status = 200; body = @{ value = @(@{ id = 'd1'; definition = @{ id = 'stable' } }) } }
        $script:batchEntries["/deviceManagement/groupPolicyConfigurations('admx')/definitionValues('d1')/presentationValues?`$expand=presentation"] = $null
        $r = Get-IdsAssessmentCollection -Packs @(New-CollectionPack 'admx') -Context @{ platforms = @('windows11') }
        $r.policies[0].settingsComplete | Should -BeFalse
        $r.policies[0].assignmentsComplete | Should -BeTrue
        $r.policies[0].rawSettings.Count | Should -Be 1
        $r.sources[0].complete | Should -BeFalse
        $r.issues[0].reason | Should -Match 'Missing Graph batch entry'
    }

    It 'preserves intent settings but discloses a failed template read' {
        $script:graphBodies.Remove('/deviceManagement/templates?$select=id,displayName,templateType,platformType')
        $script:batchEntries['/deviceManagement/intents/intent/settings'] = @{ status = 200; body = @{ value = @(@{ definitionId = 'synthetic'; value = 0 }) } }
        $r = Get-IdsAssessmentCollection -Packs @(New-CollectionPack 'intent') -Context @{ platforms = @('windows11') }
        $r.policies[0].template.id | Should -Be 'template-a'
        $r.policies[0].rawSettings[0].value | Should -Be 0
        $r.policies[0].settingsComplete | Should -BeFalse
        $r.sources[0].complete | Should -BeFalse
        @($r.issues | Where-Object stage -EQ 'template').Count | Should -BeGreaterThan 0
    }

    It 'follows expanded nested settings next links on the same navigation resource' {
        $script:batchEntries["/deviceManagement/configurationPolicies('policy-a')/settings?`$expand=settingDefinitions&`$top=1000"] = @{
            status = 200; body = @{ value = @(@{
                id = 's1'; settingInstance = @{ settingDefinitionId = 'stable' }
                settingDefinitions = @(@{ id = 'd1' })
                'settingDefinitions@odata.nextLink' = "https://graph.microsoft.com/beta/deviceManagement/configurationPolicies('policy-a')/settings('s1')/settingDefinitions?page=2"
            }) }
        }
        $script:graphBodies["https://graph.microsoft.com/beta/deviceManagement/configurationPolicies('policy-a')/settings('s1')/settingDefinitions?page=2"] = @{ value = @(@{ id = 'd2' }) }
        $r = Get-IdsAssessmentCollection -Packs @(New-CollectionPack) -Context @{ platforms = @('windows11') }
        $r.policies[0].rawSettings[0].settingDefinitions.id | Should -Be @('d1', 'd2')
        $r.policies[0].settingsComplete | Should -BeTrue
    }

    It 'retains partial assignment evidence after a continuation failure without invalidating settings' {
        $script:batchEntries["/deviceManagement/configurationPolicies('policy-a')/assignments"] = @{
            status = 200; body = @{
                value = @(@{ id = 'a1'; target = @{ '@odata.type' = '#microsoft.graph.groupAssignmentTarget'; groupId = 'synthetic-group' } })
                '@odata.nextLink' = "https://graph.microsoft.com/beta/deviceManagement/configurationPolicies('policy-a')/assignments?page=2"
            }
        }
        $r = Get-IdsAssessmentCollection -Packs @(New-CollectionPack) -Context @{ platforms = @('windows11') }
        $r.policies[0].assignments.Count | Should -Be 1
        $r.policies[0].assignments[0].target.groupId | Should -Be 'synthetic-group'
        $r.policies[0].assignmentsComplete | Should -BeFalse
        $r.policies[0].settingsComplete | Should -BeTrue
        $r.sources[0].complete | Should -BeTrue
        $r.issues[0].stage | Should -Be 'assignments'
    }

    It 'rejects a foreign expanded navigation link while retaining its inline evidence' {
        $script:batchEntries["/deviceManagement/configurationPolicies('policy-a')/settings?`$expand=settingDefinitions&`$top=1000"] = @{
            status = 200; body = @{ value = @(@{
                id = 's1'; settingInstance = @{ settingDefinitionId = 'stable' }
                settingDefinitions = @(@{ id = 'inline' })
                'settingDefinitions@odata.nextLink' = 'https://untrusted.invalid/beta/exfiltrate'
            }) }
        }
        $r = Get-IdsAssessmentCollection -Packs @(New-CollectionPack) -Context @{ platforms = @('windows11') }
        $r.policies[0].rawSettings[0].settingDefinitions[0].id | Should -Be 'inline'
        $r.policies[0].settingsComplete | Should -BeFalse
        $r.sources[0].complete | Should -BeFalse
        $r.issues[0].reason | Should -Match 'Unsafe'
        Should -Invoke Invoke-IdsGraph -Times 1 -Exactly -ParameterFilter { $Path -eq '/deviceManagement/configurationPolicies' }
    }

    It 'pages intent settings and template metadata without changing valueJson or Android enrollment metadata' {
        $script:graphBodies['/deviceManagement/templates?$select=id,displayName,templateType,platformType'] = @{
            value = @()
            '@odata.nextLink' = 'https://graph.microsoft.com/beta/deviceManagement/templates?page=2'
        }
        $script:graphBodies['https://graph.microsoft.com/beta/deviceManagement/templates?page=2'] = @{
            value = @(@{ id = 'template-a'; platformType = 'androidEnterprise' })
        }
        $script:graphBodies['/deviceManagement/intents'] = @{ value = @(@{ id = 'intent'; templateId = 'template-a'; enrollmentMode = 'fullyManaged' }) }
        $script:batchEntries['/deviceManagement/intents/intent/settings'] = @{
            status = 200; body = @{
                value = @(@{ definitionId = 'first'; valueJson = 'false' })
                '@odata.nextLink' = 'https://graph.microsoft.com/beta/deviceManagement/intents/intent/settings?page=2'
            }
        }
        $script:graphBodies['https://graph.microsoft.com/beta/deviceManagement/intents/intent/settings?page=2'] = @{
            value = @(@{ definitionId = 'second'; valueJson = '0' })
        }
        $r = Get-IdsAssessmentCollection -Packs @(New-CollectionPack 'intent' 'androidEnterprise') -Context @{ platforms = @('androidEnterprise') }
        $r.policies[0].rawSettings.valueJson | Should -Be @('false', '0')
        $r.policies[0].platform | Should -Be 'androidEnterprise'
        $r.policies[0].enrollmentMode | Should -Be 'fullyManaged'
        $r.policies[0].settingsComplete | Should -BeTrue
        $r.issues.Count | Should -Be 0
    }
}
Describe 'Assessment policy collection' {
    It 'collects typed catalog evidence and independently paged assignments without fetching references' {
        Mock Invoke-IdsGraph {
            param($Path)
            if ($Path -eq '/deviceManagement/configurationPolicies') {
                return @{ value = @(@{ id = 'policy-a'; name = 'Synthetic'; platforms = 'windows10'; templateReference = @{ templateId = 'template-a'; templateFamily = 'endpointSecurityAntivirus' } }) }
            }
            throw 'Unexpected request'
        }
        Mock Invoke-IdsGraphBatch {
            param($Requests)
            $result = @{}
            foreach ($r in $Requests) {
                $body = if ($r.url -match '/settings\?') {
                    @{ value = @(@{ id = 's'; settingInstance = @{ settingDefinitionId = 'synthetic'; simpleSettingValue = @{ value = $false } } }) }
                } else { @{ value = @(@{ id = 'a'; target = @{ groupId = 'synthetic-group'; '@odata.type' = '#microsoft.graph.exclusionGroupAssignmentTarget'; deviceAndAppManagementAssignmentFilterId = 'filter-a' } }) } }
                $result[$r.id] = @{ status = 200; body = $body }
            }
            return $result
        }
        $result = Get-IdsAssessmentCollection -Packs @(New-CollectionPack) -Context @{ platforms = @('windows11') }
        $result.policies.Count | Should -Be 1
        $p = $result.policies[0]
        $p.key | Should -Be 'settingsCatalog:policy-a'
        $p.policyType | Should -Be 'deviceManagementConfigurationPolicy'
        $p.family | Should -Be 'settingsCatalog'
        $p.platform | Should -Be 'windows11'
        $p.template.templateId | Should -Be 'template-a'
        $p.rawSettings[0].settingInstance.simpleSettingValue.value | Should -Be $false
        $p.rawSettings[0].settingInstance.simpleSettingValue.value | Should -BeOfType ([bool])
        $p.settingsComplete | Should -BeTrue
        $p.assignmentsComplete | Should -BeTrue
        $p.assignments[0].target.groupId | Should -Be 'synthetic-group'
        $p.assignments[0].target.groupDisplayName | Should -Match 'Unresolved'
        $p.assignments[0].target.deviceAndAppManagementAssignmentFilterId | Should -Be 'filter-a'
        $p.assignments[0].target.'@odata.type' | Should -Be '#microsoft.graph.exclusionGroupAssignmentTarget'
        $result.sources.Count | Should -Be 1
        $result.sources[0].complete | Should -BeTrue
        $result.issues.Count | Should -Be 0
        Should -Invoke Invoke-IdsGraph -Times 1 -Exactly -ParameterFilter { $Path -eq '/deviceManagement/configurationPolicies' }
        Should -Invoke Invoke-IdsGraphBatch -Times 1 -Exactly -ParameterFilter {
            @($Requests | Where-Object { $_.url -notmatch "^/deviceManagement/configurationPolicies\('policy-a'\)/(settings|assignments)" }).Count -eq 0
        }
    }

    It 'collects all five families with property, definition/presentation, and intent/template evidence' {
        Mock Invoke-IdsGraph {
            param($Path)
            switch -Regex ($Path) {
                '^/deviceManagement/configurationPolicies$' { return @{ value = @(@{ id = 'modern'; platforms = 'windows10'; templateReference = @{ templateId = 'modern-template' } }) } }
                '^/deviceManagement/deviceConfigurations$' { return @{ value = @(@{ id = 'legacy'; displayName = 'Legacy'; '@odata.type' = '#microsoft.graph.iosGeneralDeviceConfiguration'; passcodeBlockSimple = $false; passcodeMinimumLength = 0; syntheticNull = $null; syntheticSet = @(); payload = 'synthetic-sensitive-payload'; password = 'synthetic-sensitive-password' }) } }
                '^/deviceManagement/deviceCompliancePolicies$' { return @{ value = @(@{ id = 'compliance'; '@odata.type' = '#microsoft.graph.macOSCompliancePolicy'; storageRequireEncryption = $false; passwordMinimumLength = 0; osMinimumVersion = '13.0' }) } }
                '^/deviceManagement/groupPolicyConfigurations$' { return @{ value = @(@{ id = 'admx'; displayName = 'ADMX' }) } }
                '^/deviceManagement/intents$' { return @{ value = @(@{ id = 'intent'; templateId = 'intent-template' }) } }
                '^/deviceManagement/templates\?' { return @{ value = @(@{ id = 'intent-template'; displayName = 'Synthetic template'; templateType = 'securityBaseline'; platformType = 'androidEnterprise' }) } }
                default { throw "Unexpected request $Path" }
            }
        }
        Mock Invoke-IdsGraphBatch {
            param($Requests)
            $results = @{}
            foreach ($r in $Requests) {
                $body = switch -Regex ($r.url) {
                    '/presentationValues\?' { @{ value = @(@{ id = 'presentation'; value = 0; presentation = @{ id = 'definition-presentation' } }) }; break }
                    '/definitionValues\?' { @{ value = @(@{ id = 'definition-value'; enabled = $false; definition = @{ id = 'definition'; classType = 'machine' } }) }; break }
                    '/intents/intent/settings$' { @{ value = @(@{ id = 'intent-setting'; definitionId = 'stable-id'; valueJson = 'false' }) }; break }
                    default { @{ value = @() } }
                }
                $results[$r.id] = @{ status = 200; body = $body }
            }
            return $results
        }
        $packs = @(
            (New-CollectionPack 'settingsCatalog'), (New-CollectionPack 'deviceConfiguration' 'iosIpados'),
            (New-CollectionPack 'compliance' 'macos'), (New-CollectionPack 'admx'),
            (New-CollectionPack 'intent' 'androidEnterprise')
        )
        $r = Get-IdsAssessmentCollection -Packs $packs -Context @{ platforms = @('windows11', 'macos', 'iosIpados', 'androidEnterprise') }
        $r.policies.Count | Should -Be 5
        $r.sources.Count | Should -Be 5
        @($r.sources | Where-Object { -not $_.complete }).Count | Should -Be 0
        $r.issues.Count | Should -Be 0
        $legacy = $r.policies | Where-Object family -EQ 'deviceConfiguration'
        $legacy.rawSettings[0].passcodeBlockSimple | Should -Be $false
        $legacy.rawSettings[0].passcodeMinimumLength | Should -Be 0
        $legacy.rawSettings[0].syntheticSet.Count | Should -Be 0
        $legacy.rawSettings[0].Contains('syntheticNull') | Should -BeTrue
        $legacy.platform | Should -Be 'iosIpados'
        $compliance = $r.policies | Where-Object family -EQ 'compliance'
        $compliance.policyType | Should -Be 'macOSCompliancePolicy'
        $compliance.rawSettings[0].storageRequireEncryption | Should -Be $false
        $compliance.osMin | Should -Be '13.0'
        $admx = $r.policies | Where-Object family -EQ 'admx'
        $admx.platform | Should -Be 'windows11'
        $admx.rawSettings[0].definition.id | Should -Be 'definition'
        $admx.rawSettings[0].presentationValues[0].value | Should -Be 0
        $intent = $r.policies | Where-Object family -EQ 'intent'
        $intent.platform | Should -Be 'androidEnterprise'
        $intent.template.id | Should -Be 'intent-template'
        $intent.rawSettings[0].definitionId | Should -Be 'stable-id'
        $intent.rawSettings[0].valueJson | Should -BeExactly 'false'
        ($r | ConvertTo-Json -Depth 30) | Should -Not -Match 'synthetic-sensitive'
    }

    It 'does not silently accept duplicate policy identities across pages' {
        Mock Invoke-IdsGraph { @{ value = @(@{ id = 'duplicate' }, @{ id = 'duplicate' }) } }
        Mock Invoke-IdsGraphBatch { @{ settings = @{ status = 200; body = @{ value = @() } }; assignments = @{ status = 200; body = @{ value = @() } } } }
        $r = Get-IdsAssessmentCollection -Packs @(New-CollectionPack) -Context @{ platforms = @('windows11') }
        $r.policies.Count | Should -Be 1
        $r.sources[0].complete | Should -BeFalse
        $r.issues[0].reason | Should -Match 'Duplicate'
    }

    It 'marks all family sources incomplete for a cross-platform duplicate retaining <retainedPlatform>' -ForEach @(
        @{ first = 'windows10'; second = 'macOS'; retainedPlatform = 'windows11' }
        @{ first = 'macOS'; second = 'windows10'; retainedPlatform = 'macos' }
    ) {
        $script:duplicatePlatforms = @($first, $second)
        Mock Invoke-IdsGraph {
            @{ value = @(@{ id = 'duplicate'; platforms = $script:duplicatePlatforms[0] })
                '@odata.nextLink' = 'https://graph.microsoft.com/beta/deviceManagement/configurationPolicies?page=2' }
        } -ParameterFilter { $Path -eq '/deviceManagement/configurationPolicies' }
        Mock Invoke-IdsGraph {
            @{ value = @(@{ id = 'duplicate'; platforms = $script:duplicatePlatforms[1] }) }
        } -ParameterFilter { $Path -eq 'https://graph.microsoft.com/beta/deviceManagement/configurationPolicies?page=2' }
        Mock Invoke-IdsGraphBatch {
            @{
                settings = @{ status = 200; body = @{ value = @(@{ id = 's1'; settingInstance = @{ settingDefinitionId = 'stable' } }) } }
                assignments = @{ status = 200; body = @{ value = @(@{ id = 'a1'; target = @{ '@odata.type' = '#microsoft.graph.allDevicesAssignmentTarget' } }) } }
            }
        }
        $r = Get-IdsAssessmentCollection -Packs @(
            (New-CollectionPack), (New-CollectionPack 'settingsCatalog' 'macos')
        ) -Context @{ platforms = @('windows11', 'macos') }
        $r.policies.Count | Should -Be 1
        $r.policies[0].platform | Should -Be $retainedPlatform
        $r.policies[0].settingsComplete | Should -Be $true
        $r.policies[0].assignmentsComplete | Should -Be $true
        $r.policies[0].rawSettings[0].id | Should -Be 's1'
        $r.policies[0].assignments[0].id | Should -Be 'a1'
        $r.issues.Count | Should -Be 1
        $r.issues[0].stage | Should -Be 'inventory'
        $r.issues[0].policyKey | Should -Be 'settingsCatalog:duplicate'
        $r.issues[0].reason | Should -Match 'Duplicate'
        $r.sources.Count | Should -Be 2
        foreach ($platform in @('windows11', 'macos')) {
            $source = $r.sources | Where-Object platform -EQ $platform
            $source.complete | Should -Be $false
            $source.errors.Count | Should -Be 1
            $source.errors[0] | Should -Be $r.issues[0]
        }
        Should -Invoke Invoke-IdsGraphBatch -Times 1 -Exactly
    }

    It 'marks missing Graph policy types as incomplete rather than exposing untyped property evidence' {
        Mock Invoke-IdsGraph { @{ value = @(@{ id = 'synthetic'; storageRequireEncryption = $true }) } }
        Mock Invoke-IdsGraphBatch { @{ assignments = @{ status = 200; body = @{ value = @() } } } }
        $r = Get-IdsAssessmentCollection -Packs @(New-CollectionPack 'compliance' 'macos') -Context @{ platforms = @('macos') }
        $r.policies[0].settingsComplete | Should -BeFalse
        $r.sources[0].complete | Should -BeFalse
        $r.issues[0].reason | Should -Match 'policy type'
    }

    It 'redacts known secret setting values but retains stable setting identity and typed public values' {
        Mock Invoke-IdsGraph { @{ value = @(@{ id = 'synthetic' }) } }
        Mock Invoke-IdsGraphBatch {
            @{
                assignments = @{ status = 200; body = @{ value = @() } }
                settings = @{ status = 200; body = @{ value = @(
                    @{ id = 'secret'; settingInstance = @{ settingDefinitionId = 'synthetic.secret'; simpleSettingValue = @{ '@odata.type' = '#microsoft.graph.deviceManagementConfigurationSecretSettingValue'; value = 'synthetic-sensitive-secret' } } }
                    @{ id = 'definition-secret'; settingDefinitions = @(@{ id = 'synthetic.definition-secret'; isSecret = $true }); settingInstance = @{ settingDefinitionId = 'synthetic.definition-secret'; simpleSettingValue = @{ value = 'synthetic-sensitive-definition-secret' } } }
                    @{ id = 'public'; settingInstance = @{ settingDefinitionId = 'synthetic.public'; simpleSettingCollectionValue = @(@{ value = $false }, @{ value = 0 }, @{ value = $null }, @{ value = @() }) } }
                    @{ id = 'encrypted'; settingInstance = @{ settingDefinitionId = 'synthetic.encrypted'; simpleSettingValue = @{ isEncrypted = $true; value = 'synthetic-sensitive-encrypted' } } }
                    @{ id = 'mixed'; settingDefinitions = @(@{ id = 'child-secret'; isSecret = $true }, @{ id = 'child-public'; isSecret = $false }); settingInstance = @{
                        settingDefinitionId = 'group'; groupSettingCollectionValue = @(@{ children = @(
                            @{ settingDefinitionId = 'child-public'; simpleSettingValue = @{ value = $false } }
                            @{ settingDefinitionId = 'child-secret'; simpleSettingValue = @{ value = 'synthetic-sensitive-child-secret' } }
                        ) })
                    } }
                ) } }
            }
        }
        $r = Get-IdsAssessmentCollection -Packs @(New-CollectionPack) -Context @{ platforms = @('windows11') }
        $r.policies[0].rawSettings[0].settingInstance.settingDefinitionId | Should -Be 'synthetic.secret'
        $r.policies[0].rawSettings[0].settingInstance.simpleSettingValue.assessmentRedacted | Should -BeTrue
        $r.policies[0].rawSettings[0].settingInstance.simpleSettingValue.value | Should -BeNullOrEmpty
        $r.policies[0].rawSettings[1].settingInstance.simpleSettingValue.assessmentRedacted | Should -BeTrue
        $r.policies[0].rawSettings[2].settingInstance.simpleSettingCollectionValue[0].value | Should -Be $false
        $r.policies[0].rawSettings[2].settingInstance.simpleSettingCollectionValue[1].value | Should -Be 0
        $r.policies[0].rawSettings[3].settingInstance.simpleSettingValue.assessmentRedacted | Should -BeTrue
        $r.policies[0].rawSettings[4].settingInstance.groupSettingCollectionValue[0].children[0].simpleSettingValue.value | Should -Be $false
        $r.policies[0].rawSettings[4].settingInstance.groupSettingCollectionValue[0].children[0].simpleSettingValue.value | Should -BeOfType ([bool])
        $r.policies[0].rawSettings[4].settingInstance.groupSettingCollectionValue[0].children[1].simpleSettingValue.assessmentRedacted | Should -BeTrue
        ($r | ConvertTo-Json -Depth 30) | Should -Not -Match 'synthetic-sensitive'
    }

    It 'returns explicit relevant source failures without losing other selected families or platforms' {
        Mock Invoke-IdsGraph {
            param($Path)
            if ($Path -eq '/deviceManagement/configurationPolicies') { throw 'Synthetic failure' }
            if ($Path -eq '/deviceManagement/deviceCompliancePolicies') { return @{ value = @() } }
            throw 'Unexpected request'
        }
        Mock Invoke-IdsGraphBatch { throw 'No policies to batch' }
        $r = Get-IdsAssessmentCollection -Packs @(
            (New-CollectionPack 'settingsCatalog'), (New-CollectionPack 'settingsCatalog' 'macos'),
            (New-CollectionPack 'compliance' 'macos')
        ) -Context @{ platforms = @('windows11', 'macos') }
        $r.sources.Count | Should -Be 3
        @($r.sources | Where-Object { $_.family -eq 'settingsCatalog' -and -not $_.complete }).Count | Should -Be 2
        ($r.sources | Where-Object family -EQ 'compliance').complete | Should -BeTrue
        $r.issues.Count | Should -Be 1
        $r.issues[0].stage | Should -Be 'inventory'
        ($r.policies -is [array]) | Should -BeTrue
        $r.policies.Count | Should -Be 0
        Should -Invoke Invoke-IdsGraphBatch -Times 0
    }

    It 'uses validated mappings only and does not request manual-only or unselected packs' {
        . (Join-Path $PSScriptRoot 'TestHelpers\Assessment.ps1')
        $pack = Read-IdsBaselinePack -Bytes (New-IdsTestPackBytes)
        $manual = Read-IdsBaselinePack -Bytes (New-IdsTestPackBytes -Platform 'macos')
        $manual.controls[0].mappings = @()
        $manual.controls[0].manualReason = 'Synthetic manual review'
        Mock Invoke-IdsGraph { @{ value = @() } }
        Mock Invoke-IdsGraphBatch { throw 'No policies to batch' }
        $r = Get-IdsAssessmentCollection -Packs @($pack, $manual, (New-CollectionPack 'intent' 'androidEnterprise')) -Context @{ platforms = @('windows11', 'macos') }
        $r.sources.Count | Should -Be 1
        $r.sources[0].platform | Should -Be 'windows11'
        $r.sources[0].complete | Should -BeTrue
        Should -Invoke Invoke-IdsGraph -Times 1 -Exactly -ParameterFilter { $Path -eq '/deviceManagement/configurationPolicies' }
    }

    It 'returns array-valued empty collections without performing any requests' {
        Mock Invoke-IdsGraph { throw 'Unexpected request' }
        Mock Invoke-IdsGraphBatch { throw 'Unexpected batch' }
        $r = Get-IdsAssessmentCollection -Packs @() -Context @{ platforms = @('windows11') }
        foreach ($name in @('policies', 'sources', 'issues')) {
            ($r.$name -is [array]) | Should -BeTrue
            $r.$name.Count | Should -Be 0
        }
        Should -Invoke Invoke-IdsGraph -Times 0
        Should -Invoke Invoke-IdsGraphBatch -Times 0
    }
}

Describe 'Collection structural evidence' {
    It 'discloses unsupported <family> setting shapes rather than reporting complete evidence' -ForEach @(
        @{ family = 'settingsCatalog'; item = @{ id = 'setting' } }
        @{ family = 'admx'; item = @{ id = 'definition-value' } }
        @{ family = 'intent'; item = @{ id = 'setting'; value = 0 } }
    ) {
        $script:settingItem = $item
        Mock Invoke-IdsGraph {
            param($Path)
            if ($Path -match '/templates\?') { return @{ value = @(@{ id = 'template'; platformType = 'windows10' }) } }
            return @{ value = @(@{ id = 'policy'; templateId = 'template' }) }
        }
        Mock Invoke-IdsGraphBatch {
            param($Requests)
            $result = @{}
            foreach ($r in $Requests) {
                $values = @()
                if ($r.id -eq 'settings') { $values = @($script:settingItem) }
                $result[$r.id] = @{ status = 200; body = @{ value = $values } }
            }
            return $result
        }
        $r = Get-IdsAssessmentCollection -Packs @(New-CollectionPack $family) -Context @{ platforms = @('windows11') }
        $r.policies[0].rawSettings.Count | Should -Be 1
        $r.policies[0].settingsComplete | Should -BeFalse
        $r.sources[0].complete | Should -BeFalse
        @($r.issues | Where-Object { $_.stage -eq 'settings' -and $_.reason -match 'Unsupported' }).Count | Should -BeGreaterThan 0
    }

    It 'does not mark complete settings incomplete because of a malformed assignment target' {
        Mock Invoke-IdsGraph { @{ value = @(@{ id = 'policy' }) } }
        Mock Invoke-IdsGraphBatch {
            @{
                settings = @{ status = 200; body = @{ value = @() } }
                assignments = @{ status = 200; body = @{ value = @(@{ id = 'broken' }) } }
            }
        }
        $r = Get-IdsAssessmentCollection -Packs @(New-CollectionPack) -Context @{ platforms = @('windows11') }
        $r.policies[0].settingsComplete | Should -BeTrue
        $r.policies[0].assignmentsComplete | Should -BeFalse
        $r.sources[0].complete | Should -BeTrue
        $r.issues[0].stage | Should -Be 'assignments'
    }

    It 'isolates a known-platform settings failure from another platform in the same source family' {
        Mock Invoke-IdsGraph { @{ value = @(@{ id = 'windows'; platforms = 'windows10' }, @{ id = 'mac'; platforms = 'macOS' }) } }
        Mock Invoke-IdsGraphBatch {
            param($Requests)
            $result = @{}
            foreach ($r in $Requests) {
                $status = if ($r.url -match "'windows'.*/settings") { 403 } else { 200 }
                $result[$r.id] = @{ status = $status; body = @{ value = @() } }
            }
            return $result
        }
        $r = Get-IdsAssessmentCollection -Packs @((New-CollectionPack), (New-CollectionPack 'settingsCatalog' 'macos')) -Context @{ platforms = @('windows11', 'macos') }
        ($r.sources | Where-Object platform -EQ 'windows11').complete | Should -BeFalse
        ($r.sources | Where-Object platform -EQ 'macos').complete | Should -BeTrue
    }

    It 'batches large ADMX presentation collections through the existing 20-request transport boundary' {
        Mock Invoke-IdsGraph { @{ value = @(@{ id = 'admx' }) } }
        Mock Invoke-IdsGraphRaw {
            param($Uri, $Method, $Body)
            $responses = @(foreach ($r in $Body.requests) {
                $values = if ($r.url -match '/definitionValues\?') {
                    @(1..21 | ForEach-Object { @{ id = "d$_"; definition = @{ id = "stable$_" } } })
                } elseif ($r.url -match '/presentationValues\?') {
                    @(@{ id = 'presentation'; value = 0 })
                } else { @() }
                [pscustomobject]@{ id = $r.id; status = 200; body = @{ value = @($values) } }
            })
            return [pscustomobject]@{ responses = $responses }
        }
        $r = Get-IdsAssessmentCollection -Packs @(New-CollectionPack 'admx') -Context @{ platforms = @('windows11') }
        $r.policies[0].rawSettings.Count | Should -Be 21
        @($r.policies[0].rawSettings | Where-Object { $_.presentationValues.Count -ne 1 }).Count | Should -Be 0
        $r.policies[0].settingsComplete | Should -BeTrue
        Should -Invoke Invoke-IdsGraphRaw -Times 3 -Exactly -ParameterFilter { $Uri -eq 'https://graph.microsoft.com/beta/$batch' -and $Method -eq 'POST' -and $Body.requests.Count -le 20 }
    }

    It 'rejects an unsafe policy identity before constructing any batch URL' {
        Mock Invoke-IdsGraph { @{ value = @(@{ id = "policy')/other?bad='" }) } }
        Mock Invoke-IdsGraphBatch { throw 'Unexpected batch' }
        $r = Get-IdsAssessmentCollection -Packs @(New-CollectionPack) -Context @{ platforms = @('windows11') }
        $r.policies.Count | Should -Be 0
        $r.sources[0].complete | Should -BeFalse
        $r.issues[0].stage | Should -Be 'inventory'
        Should -Invoke Invoke-IdsGraphBatch -Times 0
    }
}
