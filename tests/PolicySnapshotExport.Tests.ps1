BeforeAll {
    $repo = Split-Path -Parent $PSScriptRoot
    foreach ($module in 'Graph', 'Render', 'Export') { . (Join-Path $repo "lib\$module.ps1") }
    function New-SnapshotExportFixture {
        $state = @{ Auth = @{ tenant_id = 'synthetic-tenant' }; Export = @{
            running = $false; log = [Collections.ArrayList]::new()
        } }
        $options = @{
            OutputPath = (Join-Path $TestDrive ([guid]::NewGuid().ToString('N')))
            Sections = @('settingsCatalog', 'deviceConfigs', 'admx', 'compliance', 'endpointSecurity')
            IncludeRaw = $true; IncludeRawFiles = $true; IncludeScriptContent = $true
            FrontMatter = $true; AdoWikiOrder = $false; GitCommit = $false; GitPush = $false
        }
        $documents = @{}
        foreach ($family in 'settingsCatalog', 'deviceConfiguration', 'admx', 'compliance', 'intent') {
            $documents[$family] = @([pscustomobject]@{
                policy = [pscustomobject]@{
                    id = "synthetic-$family"; name = "Synthetic $family"; displayName = "Synthetic $family"
                    platforms = 'windows10'; technologies = 'mdm'; description = 'Synthetic policy'
                    '@odata.type' = '#microsoft.graph.windows10CompliancePolicy'
                    passwordRequired = $false; assignments = @(); templateId = 'synthetic-template'
                    scheduledActionsForRule = @([pscustomobject]@{
                        ruleName = 'PasswordRequired'; scheduledActionConfigurations = @([pscustomobject]@{
                            actionType = 'block'; gracePeriodHours = 24
                        })
                    })
                }
                settings = @(); template = [pscustomobject]@{ displayName = 'Synthetic template'; platformType = 'windows10' }
            })
        }
        return @{
            state = $state; options = $options
            snapshot = @{ tenant = @{ id = 'synthetic-tenant'; name = 'Synthetic tenant' }; capturedAt = '2026-10-29T10:00:00Z'
                collection = @{ documentation = $documents; issues = @(); documentationIssues = @() } }
        }
    }
}

Describe 'Documentation from loaded policy evidence' {
    BeforeEach {
        Mock Invoke-IdsGraph { throw 'Unexpected policy network request' }
        Mock Invoke-IdsGraphBatch { throw 'Unexpected policy batch request' }
        Mock Test-IdsGraphConnection { throw 'Unexpected policy probe' }
        Mock Initialize-IdsLookups {
            param($Ctx)
            Set-IdsLookupMaps -Groups @{} -Filters @{} -ScopeTags @{} -Categories @{}
            $Ctx.GroupObjects = @{}; $Ctx.GroupErrors = @{}; $Ctx.Filters = @{}; $Ctx.Categories = @{}
        }
    }

    It 'renders all five policy families without collecting them again' {
        $fixture = New-SnapshotExportFixture
        Start-IdsExport $fixture.state $fixture.options $fixture.snapshot
        $fixture.state.Export.error | Should -BeNullOrEmpty
        $fixture.state.Export.summary.complete | Should -BeTrue
        $fixture.state.Export.summary.meta.totalObjects | Should -Be 5
        $readme = [IO.File]::ReadAllText((Join-Path $fixture.options.OutputPath 'README.md'))
        $readme | Should -Match 'Policies loaded.*2026-10-29T10:00:00Z'
        $compliance = Get-ChildItem (Join-Path $fixture.options.OutputPath 'compliance') -Recurse -Filter *.md | Select-Object -First 1
        [IO.File]::ReadAllText($compliance.FullName) | Should -Match 'PasswordRequired|24'
        Should -Invoke Invoke-IdsGraph -Times 0
        Should -Invoke Invoke-IdsGraphBatch -Times 0
        Should -Invoke Test-IdsGraphConnection -Times 0
    }

    It 'skips incomplete families and never prunes their earlier documentation' {
        $fixture = New-SnapshotExportFixture
        Start-IdsExport $fixture.state $fixture.options $fixture.snapshot
        $files = @(Get-ChildItem (Join-Path $fixture.options.OutputPath 'compliance') -Recurse -File)
        $files.Count | Should -BeGreaterThan 0
        $original = [IO.File]::ReadAllText($files[0].FullName)
        $fixture.snapshot.collection.documentation.compliance = @()
        $fixture.snapshot.collection.issues = @(@{ family = 'compliance'; stage = 'inventory'; reason = 'Synthetic denied' })
        Start-IdsExport $fixture.state $fixture.options $fixture.snapshot
        $fixture.state.Export.error | Should -BeNullOrEmpty
        $fixture.state.Export.summary.complete | Should -BeFalse
        $fixture.state.Export.summary.failed | Should -Contain 'Compliance policies'
        [IO.File]::ReadAllText($files[0].FullName) | Should -BeExactly $original
        Should -Invoke Invoke-IdsGraph -Times 0
    }

    It 'refuses a snapshot from another tenant' {
        $fixture = New-SnapshotExportFixture
        $fixture.state.Auth.tenant_id = 'different-synthetic-tenant'
        Start-IdsExport $fixture.state $fixture.options $fixture.snapshot
        $fixture.state.Export.error | Should -Match 'current tenant'
        Test-Path (Join-Path $fixture.options.OutputPath 'README.md') | Should -BeFalse
    }
}
