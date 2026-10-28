BeforeAll {
    $repo = Split-Path -Parent $PSScriptRoot
    foreach ($module in 'BaselinePacks', 'AssessmentCollection', 'AssessmentSettings', 'AssessmentRules', 'AssessmentReports', 'Assessment') {
        $file = Join-Path $repo "lib\$module.ps1"
        if (Test-Path $file) { . $file }
    }
    . (Join-Path $PSScriptRoot 'TestHelpers\Assessment.ps1')
    function New-JobFixture {
        param([switch]$RealGraph)
        $folder = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        [void](New-Item -ItemType Directory "$folder\app\baselines" -Force)
        Copy-Item "$repo\lib" "$folder\app" -Recurse
        [IO.File]::WriteAllBytes("$folder\app\baselines\synthetic.json", (New-IdsTestPackBytes))
        if (-not $RealGraph) { Add-Content "$folder\app\lib\Graph.ps1" @'
function Invoke-IdsGraphRaw {
    param($Uri)
    if ($Uri -match '/organization') {
        return @{ value = @(@{ id = 'synthetic-tenant'; displayName = 'Synthetic tenant' }) }
    }
    return @{ value = @() }
}
'@
        }
        $state = [hashtable]::Synchronized(@{
            Auth = @{ transport = 'token'; access_token = 'SYNTHETIC-SECRET'; tenant_id = 'synthetic-tenant' }
            Export = @{ running = $false }
            Browser = @{ running = $false }
            Config = @{ OutputPath = "$folder\export"; ImportedPackRoot = "$folder\imports" }
        })
        $pack = Read-IdsBaselinePack (New-IdsTestPackBytes)
        return @{
            root = "$folder\app"; state = $state
            options = @{ packIds = @("$($pack.id)@$($pack.version)#$($pack.sha256)")
                context = @{ platforms = @('windows11'); osVersions = @{}; enrollmentModes = @{} }
                outputPath = "$folder\reports" }
        }
    }
    function Wait-Assessment {
        param($State)
        $deadline = (Get-Date).AddSeconds(20)
        while ($State.Assessment.running -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 50 }
        $State.Assessment.running | Should -BeFalse
        while ($State.Assessment.job -and (Get-Date) -lt $deadline) {
            Clear-IdsAssessmentJob $State
            Start-Sleep -Milliseconds 20
        }
        $State.Assessment.job | Should -BeNullOrEmpty
    }
}

Describe 'Assessment job admission and session ownership' {
    It 'rejects assessment starts while an export is active' {
        $state = [hashtable]::Synchronized(@{
            Auth = @{ transport = 'token' }
            Export = @{ running = $true }
            Assessment = @{ running = $false; epoch = 1 }
        })
        Start-IdsAssessmentJob -State $state -Options @{} -Root $repo | Should -BeFalse
    }

    It 'does not overwrite a job handle while its worker is still unwinding' {
        $state = [hashtable]::Synchronized(@{
            Auth = @{ transport = 'token' }; Export = @{ running = $false }
            Assessment = @{ running = $false; epoch = 1 }
            Job = @{ handle = @{ IsCompleted = $false } }
        })
        Start-IdsAssessmentJob -State $state -Options @{} -Root $repo | Should -BeFalse
    }

    It 'rejects assessment admission while a portal worker is unwinding' {
        $fixture = New-JobFixture
        $fixture.state.Browser.job = @{ handle = @{ IsCompleted = $false } }
        Start-IdsAssessmentJob $fixture.state @{} $fixture.root | Should -BeFalse
    }

    It 'snapshots packs and context, publishes a partial safe result and disposes completed jobs' {
        $fixture = New-JobFixture
        $state = $fixture.state
        try {
            Start-IdsAssessmentJob $state $fixture.options $fixture.root | Should -BeTrue
            $fixture.options.context.platforms[0] = 'macos'
            [IO.File]::WriteAllText("$($fixture.root)\baselines\synthetic.json", '{}')
            Start-IdsAssessmentJob $state @{} $fixture.root | Should -BeFalse
            { Reset-IdsAssessment $state } | Should -Throw '*running*'
            Wait-Assessment $state
            $state.Assessment.error | Should -BeNullOrEmpty
            $state.Assessment.done | Should -BeTrue
            $state.Assessment.partial | Should -BeTrue
            $state.Assessment.result.context.platforms | Should -Be @('windows11')
            $state.Assessment.result.controls.status | Should -Be 'missing'
            $state.Assessment.result.packs[0].coverage.inventory | Should -Be 'partial'
            $state.Assessment.result.packs[0].sha256 | Should -Match '^[a-f0-9]{64}$'
            $json = ConvertTo-Json $state.Assessment.result -Depth 64
            $json | Should -Not -Match 'SYNTHETIC-SECRET|access_token|rawSettings|"controls":.*"mappings"'
            Test-Path $state.Assessment.reportPaths.jsonPath | Should -BeTrue
            $epoch = $state.Assessment.epoch
            Reset-IdsAssessment $state
            $state.Assessment.epoch | Should -Be ($epoch + 1)
            $state.Assessment.result | Should -BeNullOrEmpty
        } finally { Stop-IdsAssessmentJob $state }
    }

    It 'runs real legacy policy evidence through normalization, evaluation and both reports without raw payloads' {
        $fixture = New-JobFixture
        $pack = [Text.Encoding]::UTF8.GetString((New-IdsTestPackBytes)) | ConvertFrom-Json
        $pack.controls[0].mappings[0].family = 'deviceConfiguration'
        $pack.controls[0].mappings[0].policyTypes = @('windows10EndpointProtectionConfiguration')
        $pack.controls[0].mappings[0].settingId = $null
        $pack.controls[0].mappings[0].property = 'smartScreenEnableInShell'
        $bytes = [Text.Encoding]::UTF8.GetBytes(($pack | ConvertTo-Json -Depth 20))
        [IO.File]::WriteAllBytes("$($fixture.root)\baselines\synthetic.json", $bytes)
        $validated = Read-IdsBaselinePack $bytes
        $fixture.options.packIds = @("$($validated.id)@$($validated.version)#$($validated.sha256)")
        $fixture.options.context.osVersions = @{ windows11 = '10.0.22631' }
        Add-Content "$($fixture.root)\lib\Graph.ps1" @'
function Invoke-IdsGraphRaw {
    param($Uri)
    if ($Uri -match '/organization') { return @{ value = @(@{ id = 'synthetic-tenant' }) } }
    if ($Uri -match '\$batch$') {
        return @{ responses = @([pscustomobject]@{ id = 'assignments'; status = 200
            body = @{ value = @(@{ id = 'synthetic-assignment'
                target = @{ '@odata.type' = '#microsoft.graph.allDevicesAssignmentTarget' }
                accessToken = 'SYNTHETIC-SECRET' }) } }) }
    }
    return @{ value = @(@{ id = 'synthetic-policy'; displayName = 'Synthetic policy'
        '@odata.type' = '#microsoft.graph.windows10EndpointProtectionConfiguration'
        osMinimumVersion = '10.0.22000'; smartScreenEnableInShell = $true; syntheticUnknown = 'SYNTHETIC-SECRET' }) }
}
'@
        try {
            Start-IdsAssessmentJob $fixture.state $fixture.options $fixture.root | Should -BeTrue
            Wait-Assessment $fixture.state
            $a = $fixture.state.Assessment
            $a.error | Should -BeNullOrEmpty
            $a.result.controls[0].status | Should -Be 'aligned' -Because ($a.result | ConvertTo-Json -Depth 64 -Compress)
            $a.result.controls[0].observed[0].value | Should -BeTrue
            $a.result.controls[0].policyResults[0].assigned | Should -BeTrue
            $a.result.policies[0].assignments[0].target.'@odata.type' | Should -Be '#microsoft.graph.allDevicesAssignmentTarget'
            $json = [IO.File]::ReadAllText($a.reportPaths.jsonPath)
            $json | Should -Not -Match 'SYNTHETIC-SECRET|accessToken|rawSettings'
            ($json | ConvertFrom-Json).controls[0].observed[0].value | Should -BeTrue
            [IO.File]::ReadAllText($a.reportPaths.markdownPath) | Should -Not -Match 'SYNTHETIC-SECRET'
        } finally { Stop-IdsAssessmentJob $fixture.state }
    }

    It 'surfaces report write failures without publishing an in-memory successful result' {
        $fixture = New-JobFixture
        Add-Content "$($fixture.root)\lib\Graph.ps1" @'
function Invoke-IdsGraphRaw {
    param($Uri)
    if ($Uri -match '/organization') {
        [IO.File]::WriteAllText((Join-Path (Split-Path (Split-Path $PSScriptRoot)) 'reports'), 'synthetic obstruction')
        return @{ value = @(@{ id = 'synthetic-tenant' }) }
    }
    return @{ value = @() }
}
'@
        try {
            Start-IdsAssessmentJob $fixture.state $fixture.options $fixture.root | Should -BeTrue
            Wait-Assessment $fixture.state
            $fixture.state.Assessment.error | Should -Match 'failed during Writing reports'
            $fixture.state.Assessment.result | Should -BeNullOrEmpty
            $fixture.state.Assessment.reportPaths | Should -BeNullOrEmpty
        } finally { Stop-IdsAssessmentJob $fixture.state }
    }

    It 'does not turn a top-level authentication failure into a successful empty assessment' {
        $fixture = New-JobFixture
        Add-Content "$($fixture.root)\lib\Graph.ps1" @'
function Invoke-IdsGraphRaw { throw 'SYNTHETIC-SECRET provider failure' }
'@
        try {
            Start-IdsAssessmentJob $fixture.state $fixture.options $fixture.root | Should -BeTrue
            Wait-Assessment $fixture.state
            $fixture.state.Assessment.done | Should -BeTrue
            $fixture.state.Assessment.error | Should -Not -BeNullOrEmpty
            $fixture.state.Assessment.error | Should -Not -Match 'SYNTHETIC-SECRET'
            $fixture.state.Assessment.result | Should -BeNullOrEmpty
        } finally { Stop-IdsAssessmentJob $fixture.state }
    }

    It 'does not require extra organization-read consent when the existing session identifies the tenant' {
        $fixture = New-JobFixture
        Add-Content "$($fixture.root)\lib\Graph.ps1" @'
function Invoke-IdsGraphRaw {
    param($Uri)
    if ($Uri -match '/organization') {
        $exception = [Exception]::new('Synthetic organization permission denied')
        $exception | Add-Member NoteProperty StatusCode 403
        throw $exception
    }
    return @{ value = @() }
}
'@
        try {
            Start-IdsAssessmentJob $fixture.state $fixture.options $fixture.root | Should -BeTrue
            Wait-Assessment $fixture.state
            $fixture.state.Assessment.error | Should -BeNullOrEmpty
            $fixture.state.Assessment.result.tenant.id | Should -Be 'synthetic-tenant'
        } finally { Stop-IdsAssessmentJob $fixture.state }
    }

    It 'retains source failures as partial not-assessed evidence for status <Code>' -ForEach @(0, 403) {
        $code = $_
        $fixture = New-JobFixture
        Add-Content "$($fixture.root)\lib\Graph.ps1" (@'
function Invoke-IdsGraphRaw {
    param($Uri)
    if ($Uri -match '/organization') { return @{ value = @(@{ id = 'synthetic-tenant' }) } }
    $exception = [Exception]::new('SYNTHETIC-SECRET source unavailable')
    if (__CODE__) { $exception | Add-Member NoteProperty StatusCode __CODE__ }
    throw $exception
}
'@).Replace('__CODE__', [string]$code)
        try {
            Start-IdsAssessmentJob $fixture.state $fixture.options $fixture.root | Should -BeTrue
            Wait-Assessment $fixture.state
            $fixture.state.Assessment.error | Should -BeNullOrEmpty
            $fixture.state.Assessment.partial | Should -BeTrue
            $fixture.state.Assessment.result.controls.status | Should -Be 'notAssessed'
            $fixture.state.Assessment.result.collectionIssues.Count | Should -BeGreaterThan 0
            ($fixture.state.Assessment.result | ConvertTo-Json -Depth 64) | Should -Not -Match 'SYNTHETIC-SECRET'
        } finally { Stop-IdsAssessmentJob $fixture.state }
    }

    It 'fails expired collection authentication rather than presenting a partial success' {
        $fixture = New-JobFixture
        Add-Content "$($fixture.root)\lib\Graph.ps1" @'
function Invoke-IdsGraphRaw {
    param($Uri)
    if ($Uri -match '/organization') { return @{ value = @(@{ id = 'synthetic-tenant' }) } }
    $exception = [Exception]::new('SYNTHETIC-SECRET unauthorized')
    $exception | Add-Member NoteProperty StatusCode 401
    throw $exception
}
'@
        try {
            Start-IdsAssessmentJob $fixture.state $fixture.options $fixture.root | Should -BeTrue
            Wait-Assessment $fixture.state
            $fixture.state.Assessment.error | Should -Match 'failed during Collecting'
            $fixture.state.Assessment.result | Should -BeNullOrEmpty
        } finally { Stop-IdsAssessmentJob $fixture.state }
    }

    It 'fails without reports when refresh fails after organization success during <Stage>' -ForEach @(
        @{ Stage = 'inventory' }, @{ Stage = 'batch' }
    ) {
        $fixture = New-JobFixture -RealGraph
        $fixture.state.Auth.expires_at = [datetime]::UtcNow.AddHours(1)
        $fixture.state.Auth.refresh_token = 'SYNTHETIC-REFRESH-SECRET'
        Add-Content "$($fixture.root)\lib\Auth.ps1" @'
function Invoke-IdsTokenEndpoint {
    $exception = [Exception]::new('SYNTHETIC-SECRET provider payload')
    $exception | Add-Member NoteProperty OAuthError 'invalid_grant'
    throw $exception
}
'@
        Add-Content "$($fixture.root)\lib\Graph.ps1" (@'
function Invoke-WebRequest {
    param($Uri)
    if ($Uri -match '/organization') {
        if ('__STAGE__' -eq 'inventory') { $script:IdsGraphState.Auth.expires_at = [datetime]::UtcNow.AddMinutes(-1) }
        return @{ Content = '{"value":[{"id":"synthetic-tenant"}]}' }
    }
    if ($Uri -match '/deviceManagement/configurationPolicies$') {
        $script:IdsGraphState.Auth.expires_at = [datetime]::UtcNow.AddMinutes(-1)
        return @{ Content = '{"value":[{"id":"synthetic-policy","platforms":"windows10"}]}' }
    }
    throw 'Unexpected synthetic request'
}
'@).Replace('__STAGE__', $Stage)
        try {
            Start-IdsAssessmentJob $fixture.state $fixture.options $fixture.root | Should -BeTrue
            Wait-Assessment $fixture.state
            $a = $fixture.state.Assessment
            $a.done | Should -BeTrue
            $a.error | Should -Match 'failed during Collecting'
            $a.error | Should -Not -Match 'SYNTHETIC|invalid_grant|OAuthError'
            $a.result | Should -BeNullOrEmpty
            $a.reportPaths | Should -BeNullOrEmpty
            $a.partial | Should -BeFalse
            Test-Path $fixture.options.outputPath | Should -BeFalse
        } finally { Stop-IdsAssessmentJob $fixture.state }
    }

    It 'does not publish a result when the captured epoch becomes stale' {
        $fixture = New-JobFixture
        Add-Content "$($fixture.root)\lib\Graph.ps1" @'
function Invoke-IdsGraphRaw {
    param($Uri)
    if ($Uri -match '/organization') {
        Start-Sleep -Milliseconds 500
        return @{ value = @(@{ id = 'synthetic-tenant' }) }
    }
    return @{ value = @() }
}
'@
        try {
            Start-IdsAssessmentJob $fixture.state $fixture.options $fixture.root | Should -BeTrue
            $fixture.state.Assessment.epoch++
            $deadline = (Get-Date).AddSeconds(10)
            while ($fixture.state.Assessment.job -and (Get-Date) -lt $deadline) {
                Clear-IdsAssessmentJob $fixture.state
                Start-Sleep -Milliseconds 50
            }
            $fixture.state.Assessment.result | Should -BeNullOrEmpty
            Test-Path $fixture.options.outputPath | Should -BeFalse
        } finally { Stop-IdsAssessmentJob $fixture.state }
    }

    It 'rejects changed hashes, unknown IDs, empty platform coverage and invalid context before starting' {
        $fixture = New-JobFixture
        foreach ($identity in @('unknown@1.0.0#' + ('0' * 64), 'synthetic-pack@1.0.0#' + ('0' * 64))) {
            $fixture.options.packIds = @($identity)
            { Start-IdsAssessmentJob $fixture.state $fixture.options $fixture.root } | Should -Throw '*identity*'
        }
        $fixture = New-JobFixture
        $fixture.options.context.platforms = @('windows11', 'macos')
        { Start-IdsAssessmentJob $fixture.state $fixture.options $fixture.root } | Should -Throw '*requires an applicable pack*'
        $fixture.options.context.platforms = @('windows11')
        $fixture.options.context.osVersions = @{ windows11 = 'invalid' }
        { Start-IdsAssessmentJob $fixture.state $fixture.options $fixture.root } | Should -Throw '*OS version*'
        $fixture.state.Assessment.running | Should -BeFalse
    }

    It 'stops and disposes an active worker and clears pending identity material on reset' {
        $fixture = New-JobFixture
        Add-Content "$($fixture.root)\lib\Graph.ps1" @'
function Invoke-IdsGraphRaw { Start-Sleep -Seconds 30; throw 'stopped' }
'@
        Start-IdsAssessmentJob $fixture.state $fixture.options $fixture.root | Should -BeTrue
        $runspace = $fixture.state.Assessment.job.runspace
        Stop-IdsAssessmentJob $fixture.state
        $runspace.RunspaceStateInfo.State | Should -Be 'Closed'
        $fixture.state.Assessment.running | Should -BeFalse
        $fixture.state.Assessment.job | Should -BeNullOrEmpty
        $fixture.state.Assessment.done | Should -BeTrue
        $fixture.state.Assessment.error | Should -Match 'cancel'
        $fixture.state.Pending = @{ deviceCode = 'synthetic' }
        Reset-IdsAssessment $fixture.state
        $fixture.state.Pending | Should -BeNullOrEmpty
    }
}
