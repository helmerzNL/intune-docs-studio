BeforeAll {
    $script:PackageRepo = Split-Path -Parent $PSScriptRoot
    $script:PackageFixture = Join-Path $TestDrive 'package-source'
    $script:BuildScript = Join-Path $script:PackageFixture 'Build-Package.ps1'

    [void](New-Item -ItemType Directory -Path $script:PackageFixture -Force)
    foreach ($file in Get-ChildItem -LiteralPath $script:PackageRepo -Force -Recurse -File |
            Where-Object {
                $_.FullName -notmatch '[\\/]\.git(?:[\\/]|$)' -and
                -not $_.FullName.StartsWith("$TestDrive$([IO.Path]::DirectorySeparatorChar)", [StringComparison]::OrdinalIgnoreCase)
            }) {
        $relative = $file.FullName.Substring($script:PackageRepo.Length + 1)
        $destination = Join-Path $script:PackageFixture $relative
        [void](New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force)
        Copy-Item -LiteralPath $file.FullName -Destination $destination -Force
    }

    $fixtureArtifacts = @{
        '.env' = 'LOCAL_SECRET=synthetic'
        'AGENTS.md' = 'Developer guidance'
        'CLAUDE.md' = 'Developer guidance'
        '.github\copilot-instructions.md' = 'Developer guidance'
        'tests\fixture.Tests.ps1' = 'Describe fixture {}'
        'scripts\deploy.ps1' = 'Write-Output developer-only'
        'docs\superpowers\specs\design.md' = 'Developer specification'
        'baselines\customer-import.json' = '{"customer":"synthetic sentinel"}'
        'baselines\imported\nested.json' = '{"customer":"synthetic nested sentinel"}'
        'AssessmentPacks\customer.json' = '{"customer":"synthetic external pack"}'
        'reports\assessment.json' = '{"tenant":"synthetic report sentinel"}'
        'reports\assessment.md' = 'Synthetic report sentinel'
        'docs\assessment.md' = 'Synthetic generated report'
        'output\.intune-docs-manifest.json' = '{"tenantId":"synthetic"}'
        'browser-state\Default\Cookies' = 'synthetic browser state'
        '.git\config' = '[core]'
    }
    foreach ($relative in $fixtureArtifacts.Keys) {
        $path = Join-Path $script:PackageFixture $relative
        [void](New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force)
        Set-Content -LiteralPath $path -Value $fixtureArtifacts[$relative] -NoNewline
    }

    $script:ProductFiles = @(
        'IntuneDocsStudio.ps1'
        'QUICKSTART.md'
        'README.md'
        'SECURITY.md'
        'Start-IntuneDocs.cmd'
        'VERSION'
        'baselines\microsoft-android-enterprise.json'
        'baselines\microsoft-ios-ipados.json'
        'baselines\microsoft-macos.json'
        'baselines\microsoft-windows-11.json'
        'docs\assessment-rule-packs.md'
        'docs\operations.md'
        'docs\publishing.md'
        'lib\Assessment.ps1'
        'lib\AssessmentApi.ps1'
        'lib\AssessmentCollection.ps1'
        'lib\AssessmentReports.ps1'
        'lib\AssessmentRules.ps1'
        'lib\AssessmentSettings.ps1'
        'lib\Auth.ps1'
        'lib\BaselinePacks.ps1'
        'lib\BrowserSession.ps1'
        'lib\Export.ps1'
        'lib\Graph.ps1'
        'lib\Http.ps1'
        'lib\Render.ps1'
        'lib\Version.ps1'
        'web\app.js'
        'web\index.html'
        'web\style.css'
    )
    $operations = Join-Path $script:PackageFixture 'docs\operations.md'
    Set-Content -LiteralPath $operations -Value '# Operations guide' -NoNewline
    $script:SourceBuildInfo = Join-Path $script:PackageFixture 'build-info.json'
    Set-Content -LiteralPath $script:SourceBuildInfo -Value '{"source":"must remain unchanged"}' -NoNewline

    function Invoke-PackageFixture {
        param(
            [Parameter(Mandatory)][string]$OutputPath,
            [string]$Channel = 'beta',
            [string]$SourceCommit
        )

        if ($PSBoundParameters.ContainsKey('SourceCommit')) {
            & $script:BuildScript -OutputPath $OutputPath -Channel $Channel -SourceCommit $SourceCommit
        } else {
            & $script:BuildScript -OutputPath $OutputPath -Channel $Channel
        }
    }

    function Expand-PackageFixture {
        param([Parameter(Mandatory)][string]$OutputPath)

        $destination = Join-Path $TestDrive ('unpacked-' + [guid]::NewGuid().ToString('N'))
        Expand-Archive -LiteralPath (Join-Path $OutputPath 'IntuneDocsStudio.zip') -DestinationPath $destination
        return (Join-Path $destination 'IntuneDocsStudio')
    }
}

Describe 'Build-Package.ps1 product package contract' {
    It 'includes build identity and exactly the permitted product files' {
        $output = Join-Path $TestDrive 'package'
        Invoke-PackageFixture -OutputPath $output -SourceCommit ('a' * 40)

        $root = Expand-PackageFixture -OutputPath $output
        $metadataPath = Join-Path $root 'build-info.json'
        $metadata = Get-Content -LiteralPath $metadataPath -Raw | ConvertFrom-Json
        $metadata.channel | Should -Be 'beta'
        $metadata.version | Should -Be '0.1.0'
        $metadata.commit | Should -Be ('a' * 40)
        @($metadata.PSObject.Properties.Name | Sort-Object) |
            Should -Be @('channel', 'commit', 'version')

        $actual = @(
            Get-ChildItem -LiteralPath $root -Recurse -File |
                ForEach-Object { $_.FullName.Substring($root.Length + 1) -replace '/', '\' } |
                Sort-Object
        )
        $expected = @('build-info.json') + $script:ProductFiles
        $expected = @($expected | Sort-Object)
        $actual | Should -Be $expected

        Get-Content -LiteralPath $script:SourceBuildInfo -Raw | Should -Be '{"source":"must remain unchanged"}'
        @(Get-ChildItem -LiteralPath $output -Force | Select-Object -ExpandProperty Name) |
            Should -Be @('IntuneDocsStudio.zip')
    }

    It 'produces byte-identical ZIPs from unchanged inputs' {
        $first = Join-Path $TestDrive 'reproducible-one'
        $second = Join-Path $TestDrive 'reproducible-two'
        $sha = 'c' * 40
        Invoke-PackageFixture -OutputPath $first -SourceCommit $sha
        Invoke-PackageFixture -OutputPath $second -SourceCommit $sha

        (Get-FileHash -LiteralPath (Join-Path $first 'IntuneDocsStudio.zip') -Algorithm SHA256).Hash |
            Should -Be (Get-FileHash -LiteralPath (Join-Path $second 'IntuneDocsStudio.zip') -Algorithm SHA256).Hash
    }

    It 'ships exactly four reviewed pack bytes and the customer import reference' {
        $output = Join-Path $TestDrive 'assessment-package'
        Invoke-PackageFixture -OutputPath $output
        $root = Expand-PackageFixture -OutputPath $output
        $expectedPacks = @(
            'baselines\microsoft-windows-11.json'
            'baselines\microsoft-macos.json'
            'baselines\microsoft-ios-ipados.json'
            'baselines\microsoft-android-enterprise.json'
        )
        @(Get-ChildItem (Join-Path $root 'baselines') -Recurse -File).Count | Should -Be 4
        foreach ($entry in $expectedPacks) {
            $packaged = Join-Path $root $entry
            Test-Path -LiteralPath $packaged | Should -BeTrue
            (Get-FileHash -LiteralPath $packaged).Hash |
                Should -Be (Get-FileHash -LiteralPath (Join-Path $script:PackageRepo $entry)).Hash
        }
        Test-Path -LiteralPath (Join-Path $root 'docs\assessment-rule-packs.md') | Should -BeTrue
    }

    It 'fails closed when a required bundled pack or import reference is absent' -ForEach @(
        @{ Relative = 'baselines\microsoft-windows-11.json' }
        @{ Relative = 'baselines\microsoft-macos.json' }
        @{ Relative = 'baselines\microsoft-ios-ipados.json' }
        @{ Relative = 'baselines\microsoft-android-enterprise.json' }
        @{ Relative = 'docs\assessment-rule-packs.md' }
    ) {
        $path = Join-Path $script:PackageFixture $Relative
        $bytes = [IO.File]::ReadAllBytes($path)
        try {
            Remove-Item -LiteralPath $path
            { Invoke-PackageFixture -OutputPath (Join-Path $TestDrive 'missing-resource') } |
                Should -Throw '*Required product file is missing*'
        } finally {
            [IO.File]::WriteAllBytes($path, $bytes)
        }
    }

    It 'runs packaged four-platform evidence through both reports without modifying documentation exports' {
        $output = Join-Path $TestDrive 'integration-package'
        Invoke-PackageFixture -OutputPath $output
        $root = Expand-PackageFixture -OutputPath $output
        foreach ($module in 'BaselinePacks', 'AssessmentCollection', 'AssessmentSettings', 'AssessmentRules', 'AssessmentReports') {
            . (Join-Path $root "lib\$module.ps1")
        }
        . (Join-Path $PSScriptRoot 'TestHelpers\Assessment.ps1')
        $catalog = Get-IdsBaselinePacks (Join-Path $root 'baselines') (Join-Path $TestDrive 'integration-imports')
        $catalog.errors.Count | Should -Be 0
        $catalog.packs.Count | Should -Be 4
        @($catalog.packs.controls).Count | Should -Be 5
        $windows = New-IdsTestAssessmentPolicy deviceConfiguration windows10EndpointProtectionConfiguration @(
            @{ smartScreenEnableInShell = $true; smartScreenBlockOverrideForFiles = $true })
        $windows.osMin = '10.0.22000'; $windows.id = 'windows'; $windows.key = 'deviceConfiguration:windows'
        $mac = New-IdsTestAssessmentPolicy deviceConfiguration macOSEndpointProtectionConfiguration @(@{ fileVaultEnabled = $false })
        $mac.id = 'mac'; $mac.key = 'deviceConfiguration:mac'
        $ios = New-IdsTestAssessmentPolicy deviceConfiguration iosGeneralDeviceConfiguration @(@{})
        $ios.id = 'ios'; $ios.key = 'deviceConfiguration:ios'
        $android = New-IdsTestAssessmentPolicy compliance androidWorkProfileCompliancePolicy @(@{ storageRequireEncryption = $true })
        $android.id = 'android'; $android.key = 'compliance:android'; $android.settingsComplete = $false
        $collection = New-IdsTestAssessmentCollection @($windows, $mac, $ios, $android)
        $collection.sources = @(
            @{ family = 'deviceConfiguration'; platform = 'windows11'; complete = $true; errors = @() }
            @{ family = 'deviceConfiguration'; platform = 'macos'; complete = $true; errors = @() }
            @{ family = 'deviceConfiguration'; platform = 'iosIpados'; complete = $true; errors = @() }
            @{ family = 'compliance'; platform = 'androidEnterprise'; complete = $false; errors = @() }
        )
        $collection.issues = @(@{ family = 'compliance'; policyKey = $android.key; stage = 'settings'
            statusCode = 403; reason = 'Synthetic incomplete settings read.' })
        $snapshot = ConvertTo-IdsAssessmentSnapshot $collection
        $context = @{ platforms = @('windows11', 'macos', 'iosIpados', 'androidEnterprise')
            osVersions = @{ windows11 = '10.0.22000'; macos = '14.0' }
            enrollmentModes = @{ iosIpados = 'personallyOwned'; androidEnterprise = 'workProfile' } }
        $evaluation = Compare-IdsAssessment $catalog.packs $snapshot $context
        $result = [pscustomobject]@{
            schemaVersion = 1; runId = 'synthetic-four-platform'; generatedAt = '2026-10-28T12:00:00Z'
            tenant = @{ id = 'synthetic-tenant'; displayName = 'Synthetic acceptance' }
            context = $context; packs = $catalog.packs; summaries = $evaluation.summaries
            controls = $evaluation.controls; policies = $snapshot.policies
            sources = $snapshot.sources; collectionIssues = $snapshot.issues
        }
        $export = Join-Path $TestDrive 'integration-export'
        [void][IO.Directory]::CreateDirectory((Join-Path $export 'configuration'))
        [IO.File]::WriteAllText((Join-Path $export '.intune-docs-manifest.json'), '{"tenantId":"synthetic-tenant","files":["configuration\\keep.md"]}')
        [IO.File]::WriteAllText((Join-Path $export 'configuration\keep.md'), '# Synthetic unchanged documentation')
        $before = @(Get-ChildItem $export -Recurse -Force -File | Sort-Object FullName | Get-FileHash)
        $pair = Write-IdsAssessmentReports $result (Join-Path $TestDrive 'integration-reports') $root $export
        $json = [IO.File]::ReadAllText($pair.jsonPath) | ConvertFrom-Json
        $markdown = [Net.WebUtility]::HtmlDecode([IO.File]::ReadAllText($pair.markdownPath))
        foreach ($scenario in @(
            @{ Id = 'IDS-WIN-SHELL-SMARTSCREEN'; Platform = 'windows11'; Status = 'aligned'; Observed = 1; Value = $true }
            @{ Id = 'IDS-WIN-SHELL-NO-BYPASS'; Platform = 'windows11'; Status = 'aligned'; Observed = 1; Value = $true }
            @{ Id = 'IDS-MAC-FILEVAULT'; Platform = 'macos'; Status = 'misaligned'; Observed = 1; Value = $false }
            @{ Id = 'IDS-IOS-PASSCODE'; Platform = 'iosIpados'; Status = 'missing'; Observed = 0 }
            @{ Id = 'IDS-ANDROID-ENCRYPTION'; Platform = 'androidEnterprise'; Status = 'notAssessed'; Observed = 1; Value = $true }
        )) {
            $control = @($json.controls | Where-Object controlId -CEQ $scenario.Id)[0]
            $control.platform | Should -BeExactly $scenario.Platform
            $control.status | Should -BeExactly $scenario.Status
            $control.observed.Count | Should -Be $scenario.Observed
            $control.expected[0].expected | Should -BeTrue
            if ($scenario.Observed) { $control.observed[0].value | Should -Be $scenario.Value }
            $section = [regex]::Match($markdown, "(?s)### $([regex]::Escape($scenario.Id))\r?\n(.*?)(?=\r?\n###? |\z)").Value
            $section | Should -Not -BeNullOrEmpty
            $section | Should -Match ([regex]::Escape($control.status))
            $section | Should -Match ([regex]::Escape($control.reason))
            $section | Should -Match ([regex]::Escape($control.expected[0].property))
            foreach ($observed in $control.observed) {
                $section | Should -Match ([regex]::Escape($observed.policyKey))
                $section | Should -Match ($observed.value.ToString().ToLowerInvariant())
            }
        }
        foreach ($pack in $json.packs) {
            $pack.coverage.inventory | Should -BeExactly 'partial'
            $markdown | Should -Match $pack.sha256
            $markdown | Should -Match ([regex]::Escape($pack.sourceRevision))
        }
        ($json.summaries | Where-Object platform -CEQ windows11).counts.aligned | Should -Be 2
        ($json.summaries | Where-Object platform -CEQ macos).counts.misaligned | Should -Be 1
        ($json.summaries | Where-Object platform -CEQ iosIpados).counts.missing | Should -Be 1
        ($json.summaries | Where-Object platform -CEQ androidEnterprise).counts.notAssessed | Should -Be 1
        $json.collectionIssues[0].statusCode | Should -Be 403
        $markdown | Should -Match 'Synthetic incomplete settings read'
        $markdown | Should -Match 'not tenant-wide absence'
        $after = @(Get-ChildItem $export -Recurse -Force -File | Sort-Object FullName | Get-FileHash)
        $after.Path | Should -Be $before.Path
        $after.Hash | Should -Be $before.Hash
    }

    It 'uses locally imported synthetic CIS packs for four-platform comparison in the packaged runtime' {
        $output = Join-Path $TestDrive 'cis-package'
        Invoke-PackageFixture -OutputPath $output
        $root = Expand-PackageFixture -OutputPath $output
        foreach ($module in 'BaselinePacks', 'AssessmentCollection', 'AssessmentSettings', 'AssessmentRules') {
            . (Join-Path $root "lib\$module.ps1")
        }
        . (Join-Path $PSScriptRoot 'TestHelpers\Assessment.ps1')
        $imports = Join-Path $TestDrive 'cis-imports'
        foreach ($platform in 'windows11', 'macos', 'iosIpados', 'androidEnterprise') {
            $fixture = [Text.Encoding]::UTF8.GetString((New-IdsTestPackBytes $platform)) | ConvertFrom-Json
            $fixture.id = "synthetic-cis-$($platform.ToLowerInvariant())"
            $fixture.framework = 'CIS'
            $fixture.frameworkVersion = 'Synthetic acceptance only - no benchmark content'
            $fixture.controls[0].mappings[0].policyTypes = @('deviceManagementConfigurationPolicy')
            $bytes = [Text.Encoding]::UTF8.GetBytes(($fixture | ConvertTo-Json -Depth 20))
            $imported = Import-IdsBaselinePack -Bytes $bytes -ImportedRoot $imports
            $catalog = Get-IdsBaselinePacks (Join-Path $root 'baselines') $imports
            $catalog.errors.Count | Should -Be 0
            $selected = @($catalog.packs | Where-Object id -CEQ $fixture.id)
            $selected.Count | Should -Be 1
            $selected[0].origin | Should -BeExactly 'imported'
            $selected[0].sha256 | Should -BeExactly $imported.sha256
            $context = @{ platforms = @($platform); osVersions = @{ windows11 = '10.0.22000'; macos = '14.0' }
                enrollmentModes = @{ androidEnterprise = 'workProfile' } }
            foreach ($value in @($true, $false)) {
                $instance = New-IdsTestSettingInstance -Id 'synthetic.required' -Value @{ value = $value }
                $policy = New-IdsTestAssessmentPolicy -Settings @(@{ settingInstance = $instance })
                $policy.platform = $platform; $policy.enrollmentMode = 'workProfile'
                if ($platform -ceq 'windows11') { $policy.osMin = '10.0.22000' }
                $collection = New-IdsTestAssessmentCollection @($policy)
                $collection.sources = @(@{ family = 'settingsCatalog'; platform = $platform; complete = $true; errors = @() })
                $snapshot = ConvertTo-IdsAssessmentSnapshot $collection
                $result = Compare-IdsAssessment $selected $snapshot $context
                $result.controls.Count | Should -Be 1
                $result.controls[0].packId | Should -BeExactly $fixture.id
                $result.controls[0].status | Should -BeExactly $(if ($value) { 'aligned' } else { 'misaligned' })
                $result.controls[0].observed[0].value | Should -Be $value
            }
        }
    }

    It 'omits the optional operations guide when the source has none' {
        $operations = Join-Path $script:PackageFixture 'docs\operations.md'
        $savedOperations = Get-Content -LiteralPath $operations -Raw
        try {
            Remove-Item -LiteralPath $operations
            $output = Join-Path $TestDrive 'without-operations'
            Invoke-PackageFixture -OutputPath $output -SourceCommit ('d' * 40)

            $root = Expand-PackageFixture -OutputPath $output
            Test-Path -LiteralPath (Join-Path $root 'docs\operations.md') | Should -BeFalse
        } finally {
            Set-Content -LiteralPath $operations -Value $savedOperations -NoNewline
        }
    }

    It 'creates stable package metadata with the supplied full source SHA' {
        $output = Join-Path $TestDrive 'stable-package'
        $sha = 'b' * 40
        Invoke-PackageFixture -OutputPath $output -Channel stable -SourceCommit $sha

        $root = Expand-PackageFixture -OutputPath $output
        $metadata = Get-Content -LiteralPath (Join-Path $root 'build-info.json') -Raw | ConvertFrom-Json
        $metadata.channel | Should -Be 'stable'
        $metadata.commit | Should -Be $sha
        $metadata.version | Should -Be '0.1.0'
    }

    It 'defaults a local package to beta/development identity' {
        $output = Join-Path $TestDrive 'local-package'
        & $script:BuildScript -OutputPath $output

        $root = Expand-PackageFixture -OutputPath $output
        . (Join-Path $root 'lib\Version.ps1')
        $build = Get-IdsBuildInfo -Root $root
        $build.channel | Should -Be 'beta'
        $build.commit | Should -Be 'development'
    }

    It 'rejects invalid channels, non-SHA commits, and relative output folders' {
        { Invoke-PackageFixture -OutputPath (Join-Path $TestDrive 'invalid-channel') -Channel preview } |
            Should -Throw
        { Invoke-PackageFixture -OutputPath (Join-Path $TestDrive 'invalid-commit') -SourceCommit 'not-a-sha' } |
            Should -Throw
        { & $script:BuildScript -OutputPath '.\relative-package' -Channel beta -SourceCommit ('a' * 40) } |
            Should -Throw
    }

    It 'requires an explicit full source SHA for stable packages' {
        { & $script:BuildScript -OutputPath (Join-Path $TestDrive 'stable-default') -Channel stable } |
            Should -Throw
    }

    It 'excludes developer files, credentials, VCS state, and browser state' {
        $output = Join-Path $TestDrive 'adversarial-package'
        Invoke-PackageFixture -OutputPath $output
        $root = Expand-PackageFixture -OutputPath $output

        foreach ($path in @(
                '.env', '.git', 'AGENTS.md', 'CLAUDE.md', '.github', 'tests',
                'scripts', 'docs\superpowers', 'browser-state', 'build-info.json',
                'baselines\customer-import.json', 'baselines\imported', 'AssessmentPacks',
                'reports', 'docs\assessment.md', 'output'
            )) {
            if ($path -eq 'build-info.json') { continue }
            Test-Path -LiteralPath (Join-Path $root $path) | Should -BeFalse
        }
    }

    It 'retains leak scanning and parser validation over shipped files' {
        $productPath = Join-Path $script:PackageFixture 'web\app.js'
        $original = Get-Content -LiteralPath $productPath -Raw
        try {
            Add-Content -LiteralPath $productPath -Value "`nconst leaked = '12345678-1234-1234-1234-123456789012';"
            { Invoke-PackageFixture -OutputPath (Join-Path $TestDrive 'leak-package') } |
                Should -Throw '*Pakket niet gebouwd*'
        } finally {
            Set-Content -LiteralPath $productPath -Value $original -NoNewline
        }

        $productPath = Join-Path $script:PackageFixture 'lib\Version.ps1'
        $original = Get-Content -LiteralPath $productPath -Raw
        $parseOutput = Join-Path $TestDrive 'parse-package'
        try {
            Set-Content -LiteralPath $productPath -Value 'function {'
            { Invoke-PackageFixture -OutputPath $parseOutput } |
                Should -Throw '*Syntaxfouten*'
            @(Get-ChildItem -LiteralPath $parseOutput -Force | Select-Object -ExpandProperty Name) |
                Should -BeNullOrEmpty
        } finally {
            Set-Content -LiteralPath $productPath -Value $original -NoNewline
        }
    }
}
