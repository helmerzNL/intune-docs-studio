BeforeAll {
    $repo = Split-Path -Parent $PSScriptRoot
    foreach ($module in 'BaselinePacks', 'AssessmentCollection', 'AssessmentSettings', 'AssessmentRules', 'AssessmentReports', 'Assessment', 'AssessmentApi') {
        . (Join-Path $repo "lib\$module.ps1")
    }
    . (Join-Path $PSScriptRoot 'TestHelpers\Assessment.ps1')
    function New-IntegrationFixture {
        param([string]$Platform, [object[]]$Policies)
        $folder = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        [void][IO.Directory]::CreateDirectory("$folder\app")
        Copy-Item "$repo\lib", "$repo\baselines" "$folder\app" -Recurse
        $payload = ConvertTo-Json -InputObject @{ value = @($Policies) } -Depth 20 -Compress
        Add-Content "$folder\app\lib\Graph.ps1" (@'
function Invoke-IdsGraphRaw {
    param($Uri, $Body)
    if ($Uri -match '/organization') { return @{ value = @(@{ id = 'synthetic-tenant' }) } }
    if ($Uri -match '\$batch$') {
        return @{ responses = @([pscustomobject]@{ id = 'assignments'; status = 200; body = @{ value = @() } }) }
    }
    return ConvertFrom-Json -AsHashtable '__PAYLOAD__'
}
'@).Replace('__PAYLOAD__', $payload.Replace("'", "''"))
        $state = [hashtable]::Synchronized(@{
            Auth = @{ transport = 'token'; access_token = 'SYNTHETIC'; tenant_id = 'synthetic-tenant' }
            Export = @{ running = $false }; Browser = @{ running = $false }
            Config = @{ Port = 7654; OutputPath = "$folder\export"; ImportedPackRoot = "$folder\imports" }
        })
        $catalog = Get-IdsAssessmentCatalog $state "$folder\app"
        $pack = @($catalog.packs | Where-Object platform -CEQ $Platform)[0]
        return @{
            root = "$folder\app"; state = $state
            options = @{ packIds = @("$($pack.id)@$($pack.version)#$($pack.sha256)")
                outputPath = "$folder\reports"
                context = @{ platforms = @($Platform); osVersions = @{}; enrollmentModes = @{} } }
        }
    }
    function Invoke-IntegrationAssessment {
        param($Fixture)
        $text = ConvertTo-Json $Fixture.options -Depth 20 -Compress
        $request = [pscustomobject]@{
            Headers = @{ Origin = 'http://localhost:7654'; Host = 'localhost:7654' }
            ContentType = 'application/json'; ContentLength64 = -1
            InputStream = [IO.MemoryStream]::new([Text.Encoding]::UTF8.GetBytes($text))
        }
        $response = Invoke-IdsAssessmentRoute POST /api/assessment $request $Fixture.state $Fixture.root
        $response.status | Should -Be 202 -Because ($response.body | ConvertTo-Json -Compress)
        # Admission must retain its own immutable applicability context.
        $Fixture.options.context.enrollmentModes.Clear()
        $Fixture.options.context.osVersions.Clear()
        $deadline = (Get-Date).AddSeconds(20)
        while (($Fixture.state.Assessment.running -or $Fixture.state.Assessment.job) -and (Get-Date) -lt $deadline) {
            Clear-IdsAssessmentJob $Fixture.state
            Start-Sleep -Milliseconds 20
        }
        $Fixture.state.Assessment.job | Should -BeNullOrEmpty
        $Fixture.state.Assessment.error | Should -BeNullOrEmpty
        @($Fixture.state.Assessment.result.collectionIssues | Where-Object stage -CEQ assignments).Count | Should -Be 0
        return $Fixture.state.Assessment.result
    }
    function Assert-IntegrationReports {
        param($Fixture, $Result)
        $json = [IO.File]::ReadAllText($Fixture.state.Assessment.reportPaths.jsonPath) | ConvertFrom-Json
        $json.controls.status | Should -Be $Result.controls.status
        $json.context | ConvertTo-Json -Depth 10 -Compress | Should -Be ($Result.context | ConvertTo-Json -Depth 10 -Compress)
        $markdown = [Net.WebUtility]::HtmlDecode([IO.File]::ReadAllText($Fixture.state.Assessment.reportPaths.markdownPath))
        $markdown | Should -Match 'User-selected context is not discovered device inventory'
        foreach ($control in $json.controls) {
            $section = [regex]::Match($markdown, "(?s)### $([regex]::Escape($control.controlId))\r?\n(.*?)(?=\r?\n###? |\z)").Value
            Assert-IdsTestMarkdownObservations $section $control
        }
        return $json
    }
}

Describe 'Bundled production-path applicability and completeness' {
    It 'assesses explicit personal iOS context from API through collection and reports: <Case>' -ForEach @(
        @{ Case = 'true'; Value = $true; Mode = 'personallyOwned'; Status = 'aligned' }
        @{ Case = 'false'; Value = $false; Mode = 'personallyOwned'; Status = 'misaligned' }
        @{ Case = 'absent'; Value = $null; Mode = 'personallyOwned'; Status = 'missing' }
        @{ Case = 'unknown ownership'; Value = $true; Mode = ''; Status = 'notAssessed' }
        @{ Case = 'corporate'; Value = $true; Mode = 'corporateOwned'; Status = 'notApplicable' }
    ) {
        $policy = @{ id = 'ios'; '@odata.type' = '#microsoft.graph.iosGeneralDeviceConfiguration' }
        if ($null -ne $Value) { $policy.passcodeRequired = $Value }
        $fixture = New-IntegrationFixture iosIpados @($policy)
        if ($Mode) { $fixture.options.context.enrollmentModes.iosIpados = $Mode }
        try {
            $result = Invoke-IntegrationAssessment $fixture
            $result.controls.status | Should -Be $Status
            if ($Mode) { $result.context.enrollmentModes.iosIpados | Should -Be $Mode }
            $json = Assert-IntegrationReports $fixture $result
            $json.packs[0].origin | Should -Be 'bundled'
        } finally { Stop-IdsAssessmentJob $fixture.state }
    }

    It 'uses documented Windows applicability and explicit comparison target: <Case>' -ForEach @(
        @{ Case = 'unrestricted'; Rule = $null; Version = '10.0.26100'; Status = 'aligned' }
        @{ Case = 'included'; Rule = @{ '@odata.type' = '#microsoft.graph.deviceManagementApplicabilityRuleOsVersion'; minOSVersion = '10.0.22000'; maxOSVersion = '10.0.27000'; ruleType = 'include' }; Version = '10.0.26100'; Status = 'aligned' }
        @{ Case = 'outside include'; Rule = @{ minOSVersion = '10.0.27000'; ruleType = 'include' }; Version = '10.0.26100'; Status = 'missing' }
        @{ Case = 'excluded'; Rule = @{ minOSVersion = '10.0.22000'; ruleType = 'exclude' }; Version = '10.0.26100'; Status = 'missing' }
        @{ Case = 'outside exclude'; Rule = @{ maxOSVersion = '10.0.21999'; ruleType = 'exclude' }; Version = '10.0.26100'; Status = 'aligned' }
        @{ Case = 'missing target'; Rule = $null; Version = ''; Status = 'notAssessed' }
        @{ Case = 'Windows 10 target'; Rule = $null; Version = '10.0.19045'; Status = 'notApplicable' }
        @{ Case = 'unknown operator'; Rule = @{ minOSVersion = '10.0.22000'; ruleType = 'future' }; Version = '10.0.26100'; Status = 'notAssessed' }
        @{ Case = 'malformed bound'; Rule = @{ minOSVersion = 'bad'; ruleType = 'include' }; Version = '10.0.26100'; Status = 'notAssessed' }
        @{ Case = 'numeric bound'; Rule = @{ minOSVersion = 22000; ruleType = 'include' }; Version = '10.0.26100'; Status = 'notAssessed' }
        @{ Case = 'unknown condition'; Rule = @{ minOSVersion = '10.0.22000'; ruleType = 'include'; future = $true }; Version = '10.0.26100'; Status = 'notAssessed' }
        @{ Case = 'unknown rule shape'; Rule = @{ '@odata.type' = '#microsoft.graph.futureRule'; minOSVersion = '10.0.22000'; ruleType = 'include' }; Version = '10.0.26100'; Status = 'notAssessed' }
        @{ Case = 'inverted bounds'; Rule = @{ minOSVersion = '10.0.27000'; maxOSVersion = '10.0.22000'; ruleType = 'exclude' }; Version = '10.0.26100'; Status = 'notAssessed' }
        @{ Case = 'empty bounds'; Rule = @{ ruleType = 'include' }; Version = '10.0.26100'; Status = 'notAssessed' }
        @{ Case = 'unsupported edition'; Rule = $null; Edition = $true; Version = '10.0.26100'; Status = 'notAssessed' }
    ) {
        $policy = @{ id = 'win'; '@odata.type' = '#microsoft.graph.windows10EndpointProtectionConfiguration'
            smartScreenEnableInShell = $true; smartScreenBlockOverrideForFiles = $true }
        if ($null -ne $Rule) { $policy.deviceManagementApplicabilityRuleOsVersion = $Rule }
        if ($Edition) { $policy.deviceManagementApplicabilityRuleOsEdition = @{ osEditionTypes = @('windows10Enterprise'); ruleType = 'include' } }
        $fixture = New-IntegrationFixture windows11 @($policy)
        if ($Version) { $fixture.options.context.osVersions.windows11 = $Version }
        try {
            $result = Invoke-IntegrationAssessment $fixture
            @($result.controls | Where-Object status -CNE $Status).Count | Should -Be 0 -Because ($result.controls | ConvertTo-Json -Depth 20 -Compress)
            $json = Assert-IntegrationReports $fixture $result
            $json.policies[0].platform | Should -BeNullOrEmpty
            $json.policies[0].windowsFamily | Should -BeTrue
            if ($Rule) { $json.policies[0].osApplicabilityRule.ruleType | Should -Be $Rule.ruleType }
        } finally { Stop-IdsAssessmentJob $fixture.state }
    }

    It 'keeps known unrelated macOS types diagnostic without poisoning mapped evidence: <Case>' -ForEach @(
        @{ Case = 'aligned'; Value = $true; Status = 'aligned' }
        @{ Case = 'misaligned'; Value = $false; Status = 'misaligned' }
        @{ Case = 'missing'; Value = $null; Status = 'missing' }
    ) {
        $policy = @{ id = 'mac'; '@odata.type' = '#microsoft.graph.macOSEndpointProtectionConfiguration' }
        if ($null -ne $Value) { $policy.fileVaultEnabled = $Value }
        $fixture = New-IntegrationFixture macos @($policy, @{
            id = 'wifi'; '@odata.type' = '#microsoft.graph.macOSWiFiConfiguration'; ssid = 'synthetic'
        })
        $fixture.options.context.osVersions.macos = '14.0'
        try {
            $result = Invoke-IntegrationAssessment $fixture
            $result.controls.status | Should -Be $Status
            $result.collectionIssues.policyKey | Should -Contain 'deviceConfiguration:wifi'
            @($result.sources | Where-Object complete -EQ $false).Count | Should -BeGreaterThan 0
            $null = Assert-IntegrationReports $fixture $result
        } finally { Stop-IdsAssessmentJob $fixture.state }
    }

    It 'retains genuinely relevant and unknown policy failures: <Case>' -ForEach @(
        @{ Case = 'relevant unsupported value'; Other = @{ id = 'bad'; '@odata.type' = '#microsoft.graph.macOSEndpointProtectionConfiguration'; fileVaultEnabled = 'true' } }
        @{ Case = 'missing type'; Other = @{ id = 'bad'; fileVaultEnabled = $true } }
        @{ Case = 'abstract type'; Other = @{ id = 'bad'; '@odata.type' = '#microsoft.graph.deviceConfiguration' } }
    ) {
        $fixture = New-IntegrationFixture macos @(
            @{ id = 'mac'; '@odata.type' = '#microsoft.graph.macOSEndpointProtectionConfiguration'; fileVaultEnabled = $true },
            $Other)
        $fixture.options.context.osVersions.macos = '14.0'
        try {
            $result = Invoke-IntegrationAssessment $fixture
            $result.controls.status | Should -Be 'notAssessed'
            $result.controls.observed.value | Should -Contain $true
        } finally { Stop-IdsAssessmentJob $fixture.state }
    }

    It 'rejects cross-platform ownership modes instead of silently assuming personal scope' {
        foreach ($platform in 'iosIpados', 'androidEnterprise') {
            $fixture = New-IntegrationFixture $platform @()
            $fixture.options.context.enrollmentModes[$platform] = if ($platform -ceq 'iosIpados') { 'workProfile' } else { 'personallyOwned' }
            { Resolve-IdsAssessmentOptions $fixture.state $fixture.options $fixture.root } | Should -Throw '*mode*'
        }
    }
}

Describe 'Markdown evidence assertions bind policy, selector, path and actual value' {
    It 'rejects omitted, swapped or expected-only values: <Mutation>' -ForEach @(
        @{ Mutation = 'omitted' }; @{ Mutation = 'swapped' }; @{ Mutation = 'expected-only' }
    ) {
        $control = [pscustomobject]@{ observed = @(
            @{ policyKey = 'policy-a'; property = 'setting'; instancePath = '/one'; value = $true },
            @{ policyKey = 'policy-b'; property = 'setting'; instancePath = '/two'; value = $false }) }
        $records = $control.observed | ConvertTo-Json -Depth 10 | ConvertFrom-Json
        switch ($Mutation) {
            omitted { $records[1].PSObject.Properties.Remove('value') }
            swapped { $records[0].value = $false; $records[1].value = $true }
            expected-only { $records[1].value = $true }
        }
        $section = "| expected | true |`n| observed | $([Net.WebUtility]::HtmlEncode((ConvertTo-Json -InputObject $records -Compress))) |"
        { Assert-IdsTestMarkdownObservations $section $control } | Should -Throw
    }
}

Describe 'Catalog origin survives metadata and report boundaries' {
    It 'preserves imported author-declared Microsoft baseline origin without paths or trusted authority' {
        $fixture = New-IntegrationFixture windows11 @()
        . "$($fixture.root)\lib\BaselinePacks.ps1"
        $raw = [Text.Encoding]::UTF8.GetString((New-IdsTestPackBytes)) | ConvertFrom-Json
        $raw.framework = 'Microsoft'; $raw.classification = 'baseline'
        $imported = Import-IdsBaselinePack ([Text.Encoding]::UTF8.GetBytes(($raw | ConvertTo-Json -Depth 20))) $fixture.state.Config.ImportedPackRoot
        $pack = @( (Get-IdsAssessmentCatalog $fixture.state $fixture.root).packs | Where-Object id -CEQ $imported.id )[0]
        $metadata = Get-IdsAssessmentPackMetadata $pack
        $metadata.origin | Should -Be 'imported'
        ($metadata | ConvertTo-Json -Depth 20) | Should -Not -Match ([regex]::Escape($fixture.state.Config.ImportedPackRoot))
        $fixture.options.packIds = @($metadata.selectionId)
        try {
            $result = Invoke-IntegrationAssessment $fixture
            $result.packs[0].origin | Should -Be 'imported'
            $json = Assert-IntegrationReports $fixture $result
            $json.packs[0].origin | Should -Be 'imported'
            [IO.File]::ReadAllText($fixture.state.Assessment.reportPaths.markdownPath) | Should -Match 'author.declared'
        } finally { Stop-IdsAssessmentJob $fixture.state }
    }
}
