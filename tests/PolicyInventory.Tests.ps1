BeforeAll {
    $repo = Split-Path -Parent $PSScriptRoot
    foreach ($module in 'Graph', 'BaselinePacks', 'AssessmentCollection', 'AssessmentSettings', 'AssessmentRules', 'AssessmentReports', 'Assessment', 'PolicyInventory') {
        $file = Join-Path $repo "lib\$module.ps1"
        if (Test-Path $file) { . $file }
    }

    Describe 'Policy loading worker' {
        BeforeAll {
            . (Join-Path $PSScriptRoot 'TestHelpers\Assessment.ps1')
            function New-PolicyWorkerFixture {
                param([string]$Mode = 'ready')
                $folder = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
                [void][IO.Directory]::CreateDirectory("$folder\app\baselines")
                Copy-Item "$repo\lib" "$folder\app" -Recurse
                $pack = [Text.Encoding]::UTF8.GetString((New-IdsTestPackBytes)) | ConvertFrom-Json
                $pack.controls[0].mappings[0].family = 'deviceConfiguration'
                $pack.controls[0].mappings[0].policyTypes = @('windows10EndpointProtectionConfiguration')
                $pack.controls[0].mappings[0].settingId = $null
                $pack.controls[0].mappings[0].property = 'smartScreenEnableInShell'
                $bytes = [Text.Encoding]::UTF8.GetBytes(($pack | ConvertTo-Json -Depth 20))
                [IO.File]::WriteAllBytes("$folder\app\baselines\synthetic.json", $bytes)
                $validated = Read-IdsBaselinePack $bytes
                Add-Content "$folder\app\lib\Graph.ps1" (@'
    function Invoke-IdsGraphRaw {
        param($Uri, $Body)
        if ($Uri -match '/organization') {
            if ('__MODE__' -eq 'slow') { Start-Sleep -Seconds 2 }
            if ('__MODE__' -eq 'metadataDenied') {
                $error = [Exception]::new('SYNTHETIC-PRIVATE metadata denied')
                $error | Add-Member NoteProperty StatusCode 403
                throw $error
            }
            $id = if ('__MODE__' -eq 'mismatch') { 'another-synthetic-tenant' } else { 'synthetic-tenant' }
            return [pscustomobject]@{ value = @([pscustomobject]@{ id = $id; displayName = 'Synthetic tenant' }) }
        }
        if ('__MODE__' -eq 'failed' -or
            ('__MODE__' -in @('partial', 'unauthorized') -and $Uri -match '/deviceCompliancePolicies$')) {
            $error = [Exception]::new('SYNTHETIC-PRIVATE provider response')
            $status = if ('__MODE__' -eq 'unauthorized') { 401 } elseif ('__MODE__' -eq 'failed') { 503 } else { 403 }
            $error | Add-Member NoteProperty StatusCode $status
            throw $error
        }
        if ($Uri -match '\$batch$') {
            return [pscustomobject]@{ responses = @(foreach ($request in $Body.requests) {
                [pscustomobject]@{ id = $request.id; status = 200; body = [pscustomobject]@{ value = @() } }
            }) }
        }
        if ($Uri -match '/deviceConfigurations$') {
            return [pscustomobject]@{ value = @([pscustomobject]@{
                id = 'synthetic-policy'; displayName = 'Synthetic policy'
                '@odata.type' = '#microsoft.graph.windows10EndpointProtectionConfiguration'
                smartScreenEnableInShell = $true; wifiPreSharedKey = 'SYNTHETIC-PRIVATE'
            }) }
        }
        return [pscustomobject]@{ value = @() }
    }
    '@).Replace('__MODE__', $Mode)
                $state = [hashtable]::Synchronized(@{
                    Auth = @{ transport = 'token'; tenant_id = 'synthetic-tenant'; access_token = 'SYNTHETIC-TOKEN' }
                    Export = @{ running = $false }; Browser = @{ running = $false }
                    Config = @{ OutputPath = "$folder\export"; ImportedPackRoot = "$folder\imports" }
                })
                Initialize-IdsAssessment $state
                Initialize-IdsPolicyInventory $state
                return @{
                    root = "$folder\app"; state = $state
                    options = @{ packIds = @("$($validated.id)@$($validated.version)#$($validated.sha256)")
                        context = @{ platforms = @('windows11'); osVersions = @{ windows11 = '10.0.26100' } }
                        outputPath = "$folder\reports" }
                }
            }
            function Wait-PolicyWorker {
                param($State)
                $deadline = (Get-Date).AddSeconds(20)
                do { Clear-IdsPolicyLoadJob $State; Start-Sleep -Milliseconds 20 }
                while ($State.Policies.job -and (Get-Date) -lt $deadline)
                $State.Policies.job | Should -BeNullOrEmpty
                $State.Policies.running | Should -BeFalse
            }
        }

        It 'automatically loads once per sign-in and retains a private reusable snapshot' {
            $fixture = New-PolicyWorkerFixture
            try {
                Sync-IdsPolicyLoad $fixture.state $fixture.root
                Wait-PolicyWorker $fixture.state
                $snapshot = Get-IdsLoadedPolicies $fixture.state
                $fixture.state.Policies.status | Should -Be 'ready'
                $snapshot.collection.policies.Count | Should -Be 1
                $snapshot.collection.documentation.deviceConfiguration[0].policy.wifiPreSharedKey | Should -Be 'SYNTHETIC-PRIVATE'
                $snapshot.collection.policies[0].rawSettings[0].wifiPreSharedKey | Should -BeNullOrEmpty
                (Get-IdsPolicySummary $fixture.state | ConvertTo-Json -Depth 20) | Should -Not -Match 'SYNTHETIC-PRIVATE|SYNTHETIC-TOKEN'
                Sync-IdsPolicyLoad $fixture.state $fixture.root
                $fixture.state.Policies.job | Should -BeNullOrEmpty
                [object]::ReferenceEquals($snapshot, (Get-IdsLoadedPolicies $fixture.state)) | Should -BeTrue
            } finally { Stop-IdsPolicyLoad $fixture.state }
        }

        It 'preserves source failures without falsely reporting successful loading: <Mode>' -ForEach @(
            @{ Mode = 'partial'; Status = 'partial' }, @{ Mode = 'failed'; Status = 'failed' }
            @{ Mode = 'unauthorized'; Status = 'failed' }, @{ Mode = 'mismatch'; Status = 'failed' }
            @{ Mode = 'metadataDenied'; Status = 'ready' }
        ) {
            $fixture = New-PolicyWorkerFixture $Mode
            try {
                Start-IdsPolicyLoad $fixture.state $fixture.root | Should -BeTrue
                Wait-PolicyWorker $fixture.state
                $fixture.state.Policies.status | Should -Be $Status
                (Get-IdsPolicySummary $fixture.state | ConvertTo-Json -Depth 20) | Should -Not -Match 'SYNTHETIC-PRIVATE|SYNTHETIC-TOKEN'
                if ($Status -eq 'failed') {
                    { Get-IdsLoadedPolicies $fixture.state } | Should -Throw '*Load policies*'
                    $fixture.state.Policies.error | Should -Not -BeNullOrEmpty
                }
                if ($Status -eq 'partial') {
                    (Get-IdsLoadedPolicies $fixture.state).collection.sources |
                        Where-Object family -EQ compliance | ForEach-Object { $_.complete | Should -BeFalse }
                }
            } finally { Stop-IdsPolicyLoad $fixture.state }
        }

        It 'discards a stale worker when the tenant or session epoch changes: <Change>' -ForEach @('tenant', 'epoch') {
            $fixture = New-PolicyWorkerFixture 'slow'
            try {
                Start-IdsPolicyLoad $fixture.state $fixture.root | Should -BeTrue
                if ($_ -eq 'tenant') { $fixture.state.Auth.tenant_id = 'another-synthetic-tenant' }
                else { $fixture.state.Assessment.epoch++ }
                Wait-PolicyWorker $fixture.state
                $fixture.state.Policies.snapshot | Should -BeNullOrEmpty
                (Get-IdsPolicySummary $fixture.state).count | Should -Be 0
            } finally { Stop-IdsPolicyLoad $fixture.state }
        }

        It 'cancels loading on sign-out without publishing a late snapshot' {
            $fixture = New-PolicyWorkerFixture 'slow'
            Start-IdsPolicyLoad $fixture.state $fixture.root | Should -BeTrue
            Stop-IdsPolicyLoad $fixture.state
            $fixture.state.Auth = $null
            $fixture.state.Policies.job | Should -BeNullOrEmpty
            $fixture.state.Policies.snapshot | Should -BeNullOrEmpty
            $fixture.state.Policies.status | Should -Be 'idle'
        }

        It 'evaluates and reports the loaded policy without another Graph read' {
            $fixture = New-PolicyWorkerFixture
            try {
                Start-IdsPolicyLoad $fixture.state $fixture.root | Should -BeTrue
                Wait-PolicyWorker $fixture.state
                Add-Content "$($fixture.root)\lib\Graph.ps1" "function Invoke-IdsGraphRaw { throw 'Unexpected repeat policy read' }"
                Start-IdsAssessmentJob $fixture.state $fixture.options $fixture.root | Should -BeTrue
                $deadline = (Get-Date).AddSeconds(20)
                do { Clear-IdsAssessmentJob $fixture.state; Start-Sleep -Milliseconds 20 }
                while ($fixture.state.Assessment.job -and (Get-Date) -lt $deadline)
                $fixture.state.Assessment.job | Should -BeNullOrEmpty
                $fixture.state.Assessment.error | Should -BeNullOrEmpty
                $fixture.state.Assessment.result.controls[0].status | Should -Be 'aligned'
                $fixture.state.Assessment.result.policySnapshotAt | Should -Be $fixture.state.Policies.snapshot.capturedAt
                [IO.File]::ReadAllText($fixture.state.Assessment.reportPaths.jsonPath) |
                    Should -Not -Match 'SYNTHETIC-PRIVATE|SYNTHETIC-TOKEN|rawSettings|documentation'
            } finally { Stop-IdsAssessmentJob $fixture.state; Stop-IdsPolicyLoad $fixture.state }
        }
    }
}

Describe 'Shared policy collection' {
    BeforeEach {
        Mock Invoke-IdsGraph {
            param($Path)
            if ($Path -eq '/deviceManagement/deviceCompliancePolicies') {
                return [pscustomobject]@{ value = @([pscustomobject]@{
                    id = 'synthetic-compliance'; displayName = 'Synthetic compliance'
                    '@odata.type' = '#microsoft.graph.windows10CompliancePolicy'
                    passwordRequired = $false
                }) }
            }
            return [pscustomobject]@{ value = @() }
        }
        Mock Invoke-IdsGraphBatch {
            param($Requests)
            $result = @{}
            foreach ($request in $Requests) {
                $values = @(if ($request.id -eq 'actions') {
                    [pscustomobject]@{ id = 'action'; ruleName = 'PasswordRequired'; scheduledActionConfigurations = @() }
                })
                $result[$request.id] = @{ status = 200; body = [pscustomobject]@{ value = $values } }
            }
            return $result
        }
    }

    It 'loads all five policy families without packs and preserves documentation-only details' {
        $collection = Get-IdsAssessmentCollection -AllPolicies -IncludeDocumentation
        $collection.sources.Count | Should -Be 20
        @($collection.sources | Where-Object { -not $_.complete }).Count | Should -Be 0
        $collection.policies.Count | Should -Be 1
        $collection.policies[0].rawSettings[0].passwordRequired | Should -BeFalse
        $document = $collection.documentation.compliance[0]
        $document.policy.passwordRequired | Should -BeFalse
        ($document.policy.assignments -is [array]) | Should -BeTrue
        $document.policy.scheduledActionsForRule[0].ruleName | Should -Be 'PasswordRequired'
        Should -Invoke Invoke-IdsGraph -Times 5 -Exactly
    }

    It 'keeps compliance action failures separate from assessment evidence' {
        Mock Invoke-IdsGraphBatch {
            @{ assignments = @{ status = 200; body = @{ value = @() } }; actions = @{ status = 403 } }
        }
        $collection = Get-IdsAssessmentCollection -AllPolicies -IncludeDocumentation
        $collection.documentationIssues.Count | Should -Be 1
        $collection.documentationIssues[0].family | Should -Be 'compliance'
        $collection.issues.Count | Should -Be 0
        @($collection.sources | Where-Object { -not $_.complete }).Count | Should -Be 0
    }
}

Describe 'Tenant-owned policy snapshot' {
    BeforeEach {
        $state = [hashtable]::Synchronized(@{
            Auth = @{ tenant_id = 'synthetic-tenant'; account = 'synthetic-account'; method = 'synthetic' }
            Export = @{ running = $false }; Browser = @{ running = $false }
        })
        Initialize-IdsAssessment $state
        Initialize-IdsPolicyInventory $state
    }

    It 'denies workflow admission until the policy snapshot is ready' {
        { Get-IdsLoadedPolicies $state } | Should -Throw '*Load policies*'
        $state.Policies.status = 'loading'
        { Get-IdsLoadedPolicies $state } | Should -Throw '*Load policies*'
        $state.Policies.status = 'failed'
        { Get-IdsLoadedPolicies $state } | Should -Throw '*Load policies*'
    }

    It 'does not expose raw evidence or credentials through the status projection' {
        $state.Policies.status = 'ready'
        $state.Policies.epoch = $state.Assessment.epoch
        $state.Policies.identity = Get-IdsPolicyIdentity $state
        $state.Policies.snapshot = @{
            capturedAt = '2026-10-29T10:00:00Z'; tenant = @{ id = 'synthetic-tenant' }
            collection = @{ policies = @(@{ family = 'compliance'; rawSettings = 'SYNTHETIC-PRIVATE' })
                sources = @(); issues = @(); documentation = @{ secret = 'SYNTHETIC-PRIVATE' }
                documentationIssues = @() }
        }
        (Get-IdsLoadedPolicies $state).tenant.id | Should -Be 'synthetic-tenant'
        $summary = Get-IdsPolicySummary $state
        $summary.status | Should -Be 'ready'
        $summary.count | Should -Be 1
        ($summary | ConvertTo-Json -Depth 20) | Should -Not -Match 'SYNTHETIC-PRIVATE|rawSettings|documentation|access_token'
        $state.Auth.tenant_id = 'another-synthetic-tenant'
        { Get-IdsLoadedPolicies $state } | Should -Throw '*Load policies*'
        (Get-IdsPolicySummary $state).count | Should -Be 0
    }

    It 'invalidates snapshots across session epochs even for the same account' {
        $state.Policies.status = 'ready'
        $state.Policies.epoch = $state.Assessment.epoch
        $state.Policies.identity = Get-IdsPolicyIdentity $state
        $state.Policies.snapshot = @{ collection = @{ policies = @() } }
        $state.Assessment.epoch++
        { Get-IdsLoadedPolicies $state } | Should -Throw '*Load policies*'
    }

    It 'includes a policy worker in shared job and identity-mutation exclusion' {
        $state.Policies.running = $true
        Test-IdsWorkActive $state | Should -BeTrue
        $state.Policies.running = $false
        $state.Policies.job = @{ handle = @{ IsCompleted = $false } }
        Test-IdsWorkActive $state | Should -BeTrue
    }
}
