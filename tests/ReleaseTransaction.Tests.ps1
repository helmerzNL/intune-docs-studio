BeforeAll {
    $script:TransactionRepo = Split-Path -Parent $PSScriptRoot
    $script:TransactionScript = Join-Path $script:TransactionRepo 'scripts\Invoke-StableRelease.ps1'
    $script:ReleaseScratch = Join-Path $script:TransactionRepo '.release-test-work'
    [void](New-Item -ItemType Directory -Path $script:ReleaseScratch -Force)
    $script:SavedStableToken = $env:IDS_STABLE_RELEASE_TOKEN
    $script:SavedGhToken = $env:GH_TOKEN
    if (Test-Path -LiteralPath $script:TransactionScript -PathType Leaf) {
        . $script:TransactionScript
    }

    function Invoke-ReleaseFixtureGit {
        param([string]$Root, [string[]]$Arguments)
        $result = & git -C $Root @Arguments 2>&1
        if ($LASTEXITCODE -ne 0) { throw "Fixture git command failed: $($result -join "`n")" }
        return ($result -join "`n").Trim()
    }

    function New-IdsReleaseTransactionFixture {
        param(
            [Parameter(Mandatory)][string]$Root,
            [switch]$IncludeNotes,
            [switch]$DocsOnly,
            [switch]$IncludeTransactionScripts
        )

        $Root = Join-Path (Split-Path -Parent $Root) ((Split-Path -Leaf $Root).Substring(0, 8))
        [void](New-Item -ItemType Directory -Path $Root -Force)
        $remote = Join-Path $Root 'origin.git'
        $repo = Join-Path $Root 'checkout'
        & git init --bare --initial-branch=main $remote --quiet
        if ($LASTEXITCODE -ne 0) { throw 'Could not initialize fixture bare remote.' }
        & git init --initial-branch=main $repo --quiet
        if ($LASTEXITCODE -ne 0) { throw 'Could not initialize fixture checkout.' }
        Invoke-ReleaseFixtureGit -Root $repo -Arguments @('config', 'user.name', 'Release Test') | Out-Null
        Invoke-ReleaseFixtureGit -Root $repo -Arguments @('config', 'user.email', 'release@example.invalid') | Out-Null
        Invoke-ReleaseFixtureGit -Root $repo -Arguments @('remote', 'add', 'origin', $remote) | Out-Null
        [void](New-Item -ItemType Directory -Path (Join-Path $repo 'web') -Force)
        [void](New-Item -ItemType Directory -Path (Join-Path $repo 'docs\releases') -Force)
        [void](New-Item -ItemType Directory -Path (Join-Path $repo 'docs') -Force)
        Set-Content -LiteralPath (Join-Path $repo 'VERSION') -Value '0.1.0' -NoNewline
        Set-Content -LiteralPath (Join-Path $repo 'web\app.js') -Value 'const version = "old";' -NoNewline
        Set-Content -LiteralPath (Join-Path $repo 'docs\operations.md') -Value 'Operations baseline' -NoNewline
        if ($IncludeTransactionScripts) {
            [void](New-Item -ItemType Directory -Path (Join-Path $repo 'scripts') -Force)
            Copy-Item -LiteralPath $script:TransactionScript, (Join-Path $script:TransactionRepo 'scripts\ReleasePolicy.ps1') -Destination (Join-Path $repo 'scripts')
        }
        Invoke-ReleaseFixtureGit -Root $repo -Arguments @('add', '--all') | Out-Null
        Invoke-ReleaseFixtureGit -Root $repo -Arguments @('commit', '-m', 'baseline') | Out-Null
        $before = Invoke-ReleaseFixtureGit -Root $repo -Arguments @('rev-parse', 'HEAD')
        Invoke-ReleaseFixtureGit -Root $repo -Arguments @('push', '-u', 'origin', 'main') | Out-Null
        Invoke-ReleaseFixtureGit -Root $repo -Arguments @('switch', '-c', 'beta') | Out-Null
        if ($DocsOnly) {
            Set-Content -LiteralPath (Join-Path $repo 'docs\operations.md') -Value 'Updated operations guidance' -NoNewline
        } else {
            Set-Content -LiteralPath (Join-Path $repo 'web\app.js') -Value 'const version = "new";' -NoNewline
        }
        if ($IncludeNotes) {
            $notes = @'
# Intune Docs Studio 0.2.0

## Changes and user-visible effects
The dashboard now reports the new build identity and channel.

## Update instructions
Download the stable ZIP, extract it, and replace the existing application files.

## Dependencies and runtime
PowerShell 7 or later remains required.

## Data implications
No existing output, tenant data, or browser profile is migrated.

## Unverified integrations
Live Azure DevOps and Intune authentication were not exercised.
'@
            Set-Content -LiteralPath (Join-Path $repo 'docs\releases\v0.2.0.md') -Value $notes
        }
        Invoke-ReleaseFixtureGit -Root $repo -Arguments @('add', '--all') | Out-Null
        Invoke-ReleaseFixtureGit -Root $repo -Arguments @('commit', '-m', 'feat: update dashboard') | Out-Null
        $betaHead = Invoke-ReleaseFixtureGit -Root $repo -Arguments @('rev-parse', 'HEAD')
        Invoke-ReleaseFixtureGit -Root $repo -Arguments @('push', '-u', 'origin', 'beta') | Out-Null
        Invoke-ReleaseFixtureGit -Root $repo -Arguments @('switch', 'main') | Out-Null
        Invoke-ReleaseFixtureGit -Root $repo -Arguments @('merge', '--no-ff', '--no-edit', 'beta') | Out-Null
        $promotion = Invoke-ReleaseFixtureGit -Root $repo -Arguments @('rev-parse', 'HEAD')
        Invoke-ReleaseFixtureGit -Root $repo -Arguments @('push', 'origin', 'main') | Out-Null
        return @{ Root = $repo; Remote = $remote; Before = $before; Promotion = $promotion; BetaHead = $betaHead; Scratch = $Root }
    }

    function Set-ReleaseFixtureGitHub {
        Mock Invoke-IdsGitHub {
            param($Arguments)
            $script:GitHubCalls += ,@($Arguments)
            $endpoint = ($Arguments -join ' ')
            if ($endpoint -match '/commits/.+/pulls') {
                return @(@{
                    merged_at = '2026-10-28T00:00:00Z'
                    merge_commit_sha = $script:Fixture.Promotion
                    base = @{ ref = 'main' }
                    head = @{ ref = 'beta'; sha = $script:Fixture.BetaHead; repo = @{ full_name = 'fixture/repository' } }
                    labels = @($script:PromotionLabels | ForEach-Object { @{ name = $_ } })
                }) | ConvertTo-Json -Depth 10 -Compress
            }
            if ($endpoint -match '/check-runs') {
                return @{ check_runs = @(
                    @{ name = 'quality'; conclusion = 'success'; started_at = '2026-10-28T00:00:00Z' }
                    @{ name = 'only-from-beta'; conclusion = 'success'; started_at = '2026-10-28T00:00:00Z' }
                ) } | ConvertTo-Json -Depth 10 -Compress
            }
            if ($endpoint -match '/git/ref/heads/main') {
                if ($script:ReadHeadFailure) { throw $script:ReadHeadFailure }
                return @{ object = @{ sha = $script:ReadHead } } | ConvertTo-Json -Compress
            }
            if ($endpoint -match '/actions/artifacts') {
                if ($script:ArtifactQueryFailure) { throw $script:ArtifactQueryFailure }
                return ConvertTo-Json -InputObject @(@{ total_count = $script:RecordedArtifacts.Count; artifacts = @($script:RecordedArtifacts) }) -Depth 10 -Compress
            }
            if ($endpoint -match '/actions/runs/42$') {
                return @{ id = 42; head_sha = $script:ArtifactHead; event = 'workflow_dispatch'; path = '.github/workflows/release.yml' } | ConvertTo-Json -Compress
            }
            if ($endpoint -match '/actions/workflows/release.yml/runs') {
                if ($script:RunHistoryFailure) { throw $script:RunHistoryFailure }
                return ConvertTo-Json -InputObject @(@{ total_count = $script:PriorRuns.Count; workflow_runs = @($script:PriorRuns) }) -Depth 10 -Compress
            }
            if ($endpoint -match '/actions/runs/41/jobs') {
                if ($script:JobHistoryFailure) { throw $script:JobHistoryFailure }
                return ConvertTo-Json -InputObject @(@{
                    total_count = 1; jobs = @(@{ steps = @(@{ name = 'Upload stable ZIP and immutable manifest'; conclusion = 'success' }) })
                }) -Depth 10 -Compress
            }
            if ($Arguments[0] -ceq 'run' -and $Arguments[1] -ceq 'download') {
                $directory = $Arguments[[array]::IndexOf($Arguments, '--dir') + 1]
                [void](New-Item -ItemType Directory -Path $directory -Force)
                Copy-Item -Path (Join-Path $script:PersistedArtifact '*') -Destination $directory
                return ''
            }
            if ($Arguments[0] -ceq 'release' -and $Arguments[1] -ceq 'create') {
                $script:PublishedCommit = $Arguments[[array]::IndexOf($Arguments, '--target') + 1]
                $script:PublishedManifestContent = [IO.File]::ReadAllText($Arguments[4])
                $notes = $Arguments[[array]::IndexOf($Arguments, '--notes-file') + 1]
                $script:PublishedRelease = @{
                    tag_name = 'v0.2.0'; draft = $false; prerelease = $false
                    body = [IO.File]::ReadAllText($notes).Trim()
                    assets = @(
                        @{ name = 'IntuneDocsStudio.zip'; digest = "sha256:$((Get-FileHash $Arguments[3]).Hash.ToLowerInvariant())" }
                        @{ name = 'release-manifest.json'; digest = "sha256:$((Get-FileHash $Arguments[4]).Hash.ToLowerInvariant())" }
                    )
                }
                if ($script:PublicationFailure -ceq 'digest') { $script:PublishedRelease.assets[0].digest = 'sha256:wrong' }
                if ($script:PublicationFailure -ceq 'create') { throw 'Synthetic release create failure' }
                return ''
            }
            if ($endpoint -match '/releases/latest$') {
                return @{ tag_name = $(if ($script:PublicationFailure -ceq 'latest') { 'v0.1.0' } else { 'v0.2.0' }) } | ConvertTo-Json -Compress
            }
            if ($Arguments[0] -ceq 'release' -and $Arguments[1] -ceq 'download') {
                $directory = $Arguments[[array]::IndexOf($Arguments, '--dir') + 1]
                [IO.File]::WriteAllText((Join-Path $directory 'release-manifest.json'), $script:PublishedManifestContent, [Text.UTF8Encoding]::new($false))
                return ''
            }
            if ($endpoint -match '/git/ref/tags/' -and $script:PublishedCommit) {
                return @{ object = @{ type = 'commit'; sha = $script:PublishedCommit } } | ConvertTo-Json -Compress
            }
            if ($endpoint -match '/releases/tags/' -and $script:PublishedRelease) {
                return $script:PublishedRelease | ConvertTo-Json -Depth 10 -Compress
            }
            if ($endpoint -match '/git/ref/tags/') { throw 'GitHub CLI failed: Not Found (HTTP 404)' }
            if ($endpoint -match '/releases/tags/') { throw 'GitHub CLI failed: Not Found (HTTP 404)' }
            throw "Unexpected GitHub call: $endpoint"
        }
    }

    function Initialize-PreparedReleaseFixture {
        param([switch]$DocsOnly)
        $script:Fixture = New-IdsReleaseTransactionFixture -Root (Join-Path $script:ReleaseScratch ([guid]::NewGuid().ToString('N'))) -IncludeNotes -DocsOnly:$DocsOnly
        if ($DocsOnly) { $script:PromotionLabels += 'release:required' }
        Set-ReleaseFixtureGitHub
        $script:Prepared = Invoke-IdsStableRelease -Root $script:Fixture.Root -Before $script:Fixture.Before `
            -PromotionSha $script:Fixture.Promotion -Repository 'fixture/repository' -PrepareOnly
        $script:ArtifactHead = $script:Prepared.commit
        $script:ArtifactDirectory = Join-Path $script:Fixture.Scratch 'artifact'
    }

    function New-FixtureStableArtifact {
        param([string]$Directory)
        [void](New-Item -ItemType Directory -Path $Directory -Force)
        Set-Content -LiteralPath (Join-Path $Directory 'IntuneDocsStudio.zip') -Value 'immutable synthetic ZIP' -NoNewline
        Write-IdsReleaseManifest -ArtifactDirectory $Directory -Version '0.2.0' `
            -PromotionSha $script:Fixture.Promotion -VersionCommit $script:Prepared.commit | Out-Null
    }

    function Invoke-FixtureArtifactPreparation {
        Invoke-IdsStableRelease -Root $script:Fixture.Root -Before $script:Fixture.Before `
            -PromotionSha $script:Fixture.Promotion -Repository 'fixture/repository' `
            -RecoveryVersionCommit $script:Prepared.commit -PrepareArtifact -ArtifactDirectory $script:ArtifactDirectory
    }

    function Invoke-FixturePublication {
        Invoke-IdsStableRelease -Root $script:Fixture.Root -Before $script:Fixture.Before `
            -PromotionSha $script:Fixture.Promotion -Repository 'fixture/repository' `
            -RecoveryVersionCommit $script:Prepared.commit -PublishPrepared -ArtifactDirectory $script:ArtifactDirectory
    }
}

Describe 'Stable release transaction safety' {
    BeforeEach {
        $env:IDS_STABLE_RELEASE_TOKEN = 'synthetic-release-token'
        $env:GH_TOKEN = 'synthetic-release-token'
        $script:GitHubCalls = @()
        $script:PromotionLabels = @('version:minor')
        $script:ReadHead = $null
        $script:ReadHeadFailure = $null
        $script:RecordedArtifacts = @()
        $script:ArtifactQueryFailure = $null
        $script:PublishedCommit = $null
        $script:PublishedRelease = $null
        $script:PublicationFailure = $null
        $script:PriorRuns = @()
        $script:RunHistoryFailure = $null
        $script:JobHistoryFailure = $null
    }

    It 'rejects an invocation outside main before any remote or GitHub operation' {
        $script:Fixture = New-IdsReleaseTransactionFixture -Root (Join-Path $script:ReleaseScratch ([guid]::NewGuid().ToString('N'))) -IncludeNotes
        Set-ReleaseFixtureGitHub
        Invoke-ReleaseFixtureGit -Root $script:Fixture.Root -Arguments @('switch', 'beta') | Out-Null
        {
            Invoke-IdsStableRelease -Root $script:Fixture.Root -Before $script:Fixture.Before `
                -PromotionSha $script:Fixture.Promotion -Repository 'fixture/repository' -PrepareOnly
        } | Should -Throw '*main*'
        $script:GitHubCalls | Should -BeNullOrEmpty
    }

    It 'does not create a version commit when reviewed notes are absent' {
        $script:Fixture = New-IdsReleaseTransactionFixture -Root (Join-Path $script:ReleaseScratch ([guid]::NewGuid().ToString('N')))
        Set-ReleaseFixtureGitHub
        $beforeHead = (& git -C $script:Fixture.Root rev-parse HEAD).Trim()
        {
            Invoke-IdsStableRelease -Root $script:Fixture.Root -Before $script:Fixture.Before `
                -PromotionSha $script:Fixture.Promotion -Repository 'fixture/repository' -PrepareOnly
        } | Should -Throw '*release notes*'

        (& git -C $script:Fixture.Root rev-parse HEAD).Trim() | Should -Be $beforeHead
        @($script:GitHubCalls | Where-Object { $_ -contains 'release' }) | Should -BeNullOrEmpty
    }

    It 'exits successfully without a release for a documentation-only promotion' {
        $script:Fixture = New-IdsReleaseTransactionFixture `
            -Root (Join-Path $script:ReleaseScratch ([guid]::NewGuid().ToString('N'))) -DocsOnly
        Set-ReleaseFixtureGitHub
        Remove-Item Env:IDS_STABLE_RELEASE_TOKEN -ErrorAction SilentlyContinue
        $env:GH_TOKEN = 'synthetic-read-only-token'
        $script:ReadHead = $script:Fixture.Promotion
        Invoke-ReleaseFixtureGit -Root $script:Fixture.Root -Arguments @('remote', 'set-url', 'origin', 'https://private.invalid/unavailable.git') | Out-Null
        $result = Invoke-IdsStableRelease -Root $script:Fixture.Root -Before $script:Fixture.Before `
            -PromotionSha $script:Fixture.Promotion -Repository 'fixture/repository' -PlanOnly

        $result.required | Should -BeFalse
        (& git -C $script:Fixture.Root rev-parse HEAD).Trim() | Should -Be $script:Fixture.Promotion
        @($script:GitHubCalls | Where-Object { $_ -match '/git/ref/tags|/releases/tags|release create' }) | Should -BeNullOrEmpty
    }

    It 'prepares a single version commit for an explicitly requested documentation-only release' {
        $script:Fixture = New-IdsReleaseTransactionFixture `
            -Root (Join-Path $script:ReleaseScratch ([guid]::NewGuid().ToString('N'))) -DocsOnly -IncludeNotes
        $script:PromotionLabels = @('release:required', 'version:minor')
        $script:ReadHead = $script:Fixture.Promotion
        Set-ReleaseFixtureGitHub
        $result = Invoke-IdsStableRelease -Root $script:Fixture.Root -Before $script:Fixture.Before `
            -PromotionSha $script:Fixture.Promotion -Repository 'fixture/repository' -PrepareOnly

        $result.version | Should -Be '0.2.0'
        (Get-IdsRemoteBranchHead -Root $script:Fixture.Root -Branch main) | Should -Be $result.commit
        Invoke-ReleaseFixtureGit -Root $script:Fixture.Root -Arguments @('rev-parse', 'HEAD^') |
            Should -Be $script:Fixture.Promotion
        Invoke-ReleaseFixtureGit -Root $script:Fixture.Root -Arguments @('diff', '--name-only', 'HEAD^', 'HEAD') |
            Should -Be 'VERSION'
        Invoke-ReleaseFixtureGit -Root $script:Fixture.Root -Arguments @('log', '-1', '--format=%B') |
            Should -Match "Release-Promotion: $($script:Fixture.Promotion)"
        @($script:GitHubCalls | Where-Object { $_ -contains 'create' }) | Should -BeNullOrEmpty
    }

    It 'does not bypass release prerequisites for an explicit documentation-only release: <Case>' -ForEach @(
        @{ Case = 'missing notes'; IncludeNotes = $false; Error = '*release notes*' }
        @{ Case = 'missing credential'; IncludeNotes = $true; Error = '*IDS_STABLE_RELEASE_TOKEN*' }
        @{ Case = 'existing tag'; IncludeNotes = $true; Error = '*Refusing to overwrite*' }
        @{ Case = 'failed beta check'; IncludeNotes = $true; Error = '*quality*' }
        @{ Case = 'fork promotion'; IncludeNotes = $true; Error = '*same-repository*' }
    ) {
        $script:Fixture = New-IdsReleaseTransactionFixture `
            -Root (Join-Path $script:ReleaseScratch ([guid]::NewGuid().ToString('N'))) -DocsOnly -IncludeNotes:$IncludeNotes
        $script:PromotionLabels = @('release:required', 'version:minor')
        $script:ReadHead = $script:Fixture.Promotion
        Set-ReleaseFixtureGitHub
        switch ($Case) {
            'missing credential' { Remove-Item Env:IDS_STABLE_RELEASE_TOKEN }
            'existing tag' {
                Mock Invoke-IdsGitHub { return '{"object":{"type":"commit","sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}' } `
                    -ParameterFilter { ($Arguments -join ' ') -match '/git/ref/tags/' }
            }
            'failed beta check' {
                Mock Invoke-IdsGitHub { return '{"check_runs":[{"name":"quality","conclusion":"failure","started_at":"2026-10-28T00:00:00Z"}]}' } `
                    -ParameterFilter { ($Arguments -join ' ') -match '/check-runs' }
            }
            'fork promotion' {
                Mock Invoke-IdsGitHub {
                    return ConvertTo-Json -InputObject @(@{
                        merged_at = '2026-10-28T00:00:00Z'; merge_commit_sha = $script:Fixture.Promotion
                        base = @{ ref = 'main' }
                        head = @{ ref = 'beta'; repo = @{ full_name = 'untrusted/fork' } }
                        labels = @(@{ name = 'release:required' })
                    }) -Depth 10 -Compress
                } -ParameterFilter { ($Arguments -join ' ') -match '/commits/.+/pulls' }
            }
        }
        {
            Invoke-IdsStableRelease -Root $script:Fixture.Root -Before $script:Fixture.Before `
                -PromotionSha $script:Fixture.Promotion -Repository 'fixture/repository' -PrepareOnly
        } | Should -Throw $Error
        (& git -C $script:Fixture.Root rev-parse HEAD).Trim() | Should -Be $script:Fixture.Promotion
        (Get-IdsRemoteBranchHead -Root $script:Fixture.Root -Branch main) | Should -Be $script:Fixture.Promotion
    }

    It 'fails closed for docs-only planning when the read API is stale or unavailable' -ForEach @(
        @{ Head = ('a' * 40); Failure = $null }
        @{ Head = $null; Failure = 'GitHub CLI failed: forbidden (HTTP 403)' }
        @{ Head = $null; Failure = $null }
    ) {
        $script:Fixture = New-IdsReleaseTransactionFixture -Root (Join-Path $script:ReleaseScratch ([guid]::NewGuid().ToString('N'))) -DocsOnly
        Set-ReleaseFixtureGitHub
        $script:ReadHead = $Head
        $script:ReadHeadFailure = $Failure
        Remove-Item Env:IDS_STABLE_RELEASE_TOKEN -ErrorAction SilentlyContinue
        {
            Invoke-IdsStableRelease -Root $script:Fixture.Root -Before $script:Fixture.Before `
                -PromotionSha $script:Fixture.Promotion -Repository 'fixture/repository' -PlanOnly
        } | Should -Throw
        (& git -C $script:Fixture.Root rev-parse HEAD).Trim() | Should -Be $script:Fixture.Promotion
    }

    It 'runs the workflow script entry point using repository-root version and notes paths' {
        $script:Fixture = New-IdsReleaseTransactionFixture -Root (Join-Path $script:ReleaseScratch ([guid]::NewGuid().ToString('N'))) -IncludeNotes -IncludeTransactionScripts
        $script:ReadHead = $script:Fixture.Promotion
        $savedRepository = $env:GITHUB_REPOSITORY
        $cliFixture = $script:Fixture
        try {
            $env:GITHUB_REPOSITORY = 'fixture/repository'
            # Keep the actual CLI wrapper and JSON parsing; replace only the external executable.
            function gh {
                $global:LASTEXITCODE = 0
                $endpoint = $args -join ' '
                if ($endpoint -match '/pulls') {
                    return ConvertTo-Json -InputObject @(@{
                        merged_at = '2026-10-28T00:00:00Z'; merge_commit_sha = $cliFixture.Promotion
                        base = @{ ref = 'main' }; head = @{ ref = 'beta'; repo = @{ full_name = 'fixture/repository' } }; labels = @(@{ name = 'version:minor' })
                    }) -Depth 10 -Compress
                }
                if ($endpoint -match '/check-runs') {
                    return @{ check_runs = @(
                        @{ name = 'quality'; conclusion = 'success'; started_at = '2026-10-28T00:00:00Z' }
                        @{ name = 'only-from-beta'; conclusion = 'success'; started_at = '2026-10-28T00:00:00Z' }
                    ) } | ConvertTo-Json -Depth 10 -Compress
                }
                if ($endpoint -match '/git/ref/heads/main') {
                    return @{ object = @{ sha = $cliFixture.Promotion } } | ConvertTo-Json -Compress
                }
                if ($endpoint -match '/git/ref/tags/|/releases/tags/') { throw 'GitHub CLI failed: Not Found (HTTP 404)' }
                throw "Unexpected external gh invocation: $endpoint"
            }
            $result = & (Join-Path $script:Fixture.Root 'scripts\Invoke-StableRelease.ps1') `
                -Before $script:Fixture.Before -PromotionSha $script:Fixture.Promotion -PrepareOnly
            $result.version | Should -Be '0.2.0'
            (Get-Content (Join-Path $script:Fixture.Root 'VERSION') -Raw).Trim() | Should -Be '0.2.0'
        } finally {
            $env:GITHUB_REPOSITORY = $savedRepository
        }
    }

    It 'constructs the first artifact after a pre-artifact failure from the same verified version commit' {
        Initialize-PreparedReleaseFixture
        $script:BuildFails = $true
        Mock Invoke-IdsStableArtifactBuild {
            param($Root, $OutputPath, $SourceCommit)
            $SourceCommit | Should -Be $script:Prepared.commit
            (& git -C $Root rev-parse HEAD).Trim() | Should -Be $SourceCommit
            if ($script:BuildFails) { throw 'Synthetic first build failure' }
            [void](New-Item -ItemType Directory -Path $OutputPath -Force)
            Set-Content -LiteralPath (Join-Path $OutputPath 'IntuneDocsStudio.zip') -Value 'immutable synthetic ZIP' -NoNewline
        }
        { Invoke-FixtureArtifactPreparation } | Should -Throw '*first build failure*'
        $script:BuildFails = $false
        $result = Invoke-FixtureArtifactPreparation
        $result.created | Should -BeTrue
        $identity = Assert-IdsArtifactIdentity -ArtifactDirectory $script:ArtifactDirectory -Version '0.2.0' `
            -PromotionSha $script:Fixture.Promotion -VersionCommit $script:Prepared.commit
        $identity.sha256 | Should -Be (Get-FileHash (Join-Path $script:ArtifactDirectory 'IntuneDocsStudio.zip')).Hash.ToLowerInvariant()
        (& git -C $script:Fixture.Root rev-parse HEAD).Trim() | Should -Be $script:Prepared.commit
        (Get-IdsRemoteBranchHead -Root $script:Fixture.Root -Branch main) | Should -Be $script:Prepared.commit
    }

    It 'reuses recorded artifact bytes from a recovery run without rebuilding' {
        Initialize-PreparedReleaseFixture
        $script:PersistedArtifact = Join-Path $script:Fixture.Scratch 'persisted'
        New-FixtureStableArtifact -Directory $script:PersistedArtifact
        $script:RecordedArtifacts = @(@{
            id = 1; name = "IntuneDocsStudio-stable-0.2.0-$($script:Prepared.commit)"
            expired = $false; workflow_run = @{ id = 42 }
        })
        $checksum = (Get-FileHash (Join-Path $script:PersistedArtifact 'IntuneDocsStudio.zip')).Hash
        $result = Invoke-FixtureArtifactPreparation
        $result.created | Should -BeFalse
        (Get-FileHash (Join-Path $script:ArtifactDirectory 'IntuneDocsStudio.zip')).Hash | Should -Be $checksum
    }

    It 'refuses first construction when immutable evidence is present or absence is unverifiable: <Case>' -ForEach @(
        @{ Case = 'expired artifact'; Evidence = 'expired'; Error = '*expired*' }
        @{ Case = 'artifact query forbidden'; Evidence = 'forbidden'; Error = '*403*' }
        @{ Case = 'artifact query 404'; Evidence = 'notfound'; Error = '*404*' }
        @{ Case = 'malformed artifact response'; Evidence = 'malformed'; Error = '*artifact*' }
        @{ Case = 'tag only'; Evidence = 'tag'; Error = '*tag*' }
        @{ Case = 'existing local bytes'; Evidence = 'local'; Error = '*replace*' }
        @{ Case = 'wrong source run'; Evidence = 'wrongrun'; Error = '*run*' }
        @{ Case = 'mismatched downloaded bytes'; Evidence = 'checksum'; Error = '*checksum*' }
        @{ Case = 'previously uploaded then deleted artifact'; Evidence = 'deleted'; Error = '*previously persisted*' }
        @{ Case = 'unreadable run history'; Evidence = 'run404'; Error = '*404*' }
        @{ Case = 'unreadable job history'; Evidence = 'jobs403'; Error = '*403*' }
        @{ Case = 'incomplete artifact inventory'; Evidence = 'incomplete'; Error = '*incomplete*' }
    ) {
        Initialize-PreparedReleaseFixture
        switch ($Evidence) {
            'forbidden' { $script:ArtifactQueryFailure = 'GitHub CLI failed: Forbidden (HTTP 403)' }
            'notfound' { $script:ArtifactQueryFailure = 'GitHub CLI failed: Not Found (HTTP 404)' }
            'malformed' { Mock Invoke-IdsGitHub { return '{}' } -ParameterFilter { ($Arguments -join ' ') -match '/actions/artifacts' } }
            'tag' { $script:PublishedCommit = $script:Prepared.commit }
            'local' { New-FixtureStableArtifact -Directory $script:ArtifactDirectory }
            'deleted' { $script:PriorRuns = @(@{ id = 41 }) }
            'run404' { $script:RunHistoryFailure = 'GitHub CLI failed: Not Found (HTTP 404)' }
            'jobs403' {
                $script:PriorRuns = @(@{ id = 41 })
                $script:JobHistoryFailure = 'GitHub CLI failed: Forbidden (HTTP 403)'
            }
            'incomplete' {
                Mock Invoke-IdsGitHub { return '[{"total_count":1,"artifacts":[]}]' } -ParameterFilter { ($Arguments -join ' ') -match '/actions/artifacts' }
            }
            default {
                $script:PersistedArtifact = Join-Path $script:Fixture.Scratch 'persisted'
                New-FixtureStableArtifact -Directory $script:PersistedArtifact
                $script:RecordedArtifacts = @(@{
                    id = 1; name = "IntuneDocsStudio-stable-0.2.0-$($script:Prepared.commit)"
                    expired = ($Evidence -ceq 'expired'); workflow_run = @{ id = 42 }
                })
                if ($Evidence -ceq 'wrongrun') { $script:ArtifactHead = 'f' * 40 }
                if ($Evidence -ceq 'checksum') {
                    Set-Content (Join-Path $script:PersistedArtifact 'IntuneDocsStudio.zip') 'changed'
                }
            }
        }
        { Invoke-FixtureArtifactPreparation } | Should -Throw $Error
        @($script:GitHubCalls | Where-Object { $_ -contains 'create' }) | Should -BeNullOrEmpty
        (& git -C $script:Fixture.Root rev-parse HEAD).Trim() | Should -Be $script:Prepared.commit
    }

    It 'publishes immutable bytes and back-merges with docs-only opt-in: <DocsOnly>' -ForEach @(
        @{ DocsOnly = $false }; @{ DocsOnly = $true }
    ) {
        Initialize-PreparedReleaseFixture -DocsOnly:$DocsOnly
        Invoke-ReleaseFixtureGit -Root $script:Fixture.Root -Arguments @('config', 'user.name', '') | Out-Null
        Invoke-ReleaseFixtureGit -Root $script:Fixture.Root -Arguments @('config', 'user.email', '') | Out-Null
        New-FixtureStableArtifact -Directory $script:ArtifactDirectory
        $checksum = (Get-FileHash (Join-Path $script:ArtifactDirectory 'IntuneDocsStudio.zip')).Hash
        Mock Invoke-IdsValidationAndBuild {
            param($Root, $OutputPath, $Channel, $SourceCommit)
            $Channel | Should -Be 'beta'
            (Get-Content (Join-Path $Root 'VERSION') -Raw).Trim() | Should -Be '0.2.0'
            (& git -C $Root rev-parse HEAD).Trim() | Should -Be $SourceCommit
        }
        $result = Invoke-FixturePublication
        $result.commit | Should -Be $script:Prepared.commit
        $script:PublishedCommit | Should -Be $script:Prepared.commit
        @($script:GitHubCalls | Where-Object { $_[0] -ceq 'release' -and $_[1] -ceq 'create' }).Count | Should -Be 1
        @($script:GitHubCalls | Where-Object { ($_[0] -ceq 'api') -and ($_[1] -match '/releases/latest$') }).Count | Should -Be 1
        $beta = Get-IdsRemoteBranchHead -Root $script:Fixture.Root -Branch beta
        ((& git -C $script:Fixture.Root show "${beta}:VERSION") -join '').Trim() | Should -Be '0.2.0'
        Invoke-ReleaseFixtureGit -Root $script:Fixture.Root -Arguments @('merge-base', '--is-ancestor', $script:Prepared.commit, $beta) | Should -BeNullOrEmpty
        (Get-FileHash (Join-Path $script:ArtifactDirectory 'IntuneDocsStudio.zip')).Hash | Should -Be $checksum
        Remove-Item -LiteralPath $script:ArtifactDirectory -Recurse -Force
        (Invoke-FixtureArtifactPreparation).created | Should -BeFalse
        Invoke-FixturePublication | Out-Null
        @($script:GitHubCalls | Where-Object { $_[0] -ceq 'release' -and $_[1] -ceq 'create' }).Count | Should -Be 1
    }

    It 'refuses artifact construction from an unverified or moved version commit: <State>' -ForEach @(
        @{ State = 'wrong commit' }; @{ State = 'moved local head' }; @{ State = 'moved remote head' }
    ) {
        Initialize-PreparedReleaseFixture
        if ($State -ceq 'wrong commit') {
            $script:Prepared.commit = $script:Fixture.Promotion
        } else {
            Set-Content (Join-Path $script:Fixture.Root 'README.md') 'later docs commit'
            Invoke-ReleaseFixtureGit -Root $script:Fixture.Root -Arguments @('add', 'README.md') | Out-Null
            Invoke-ReleaseFixtureGit -Root $script:Fixture.Root -Arguments @('commit', '-m', 'later docs') | Out-Null
            if ($State -ceq 'moved remote head') {
                Invoke-ReleaseFixtureGit -Root $script:Fixture.Root -Arguments @('push', 'origin', 'main') | Out-Null
            }
        }
        { Invoke-FixtureArtifactPreparation } | Should -Throw
        Test-Path -LiteralPath $script:ArtifactDirectory | Should -BeFalse
        @($script:GitHubCalls | Where-Object { ($_ -join ' ') -match '/actions/artifacts' }) | Should -BeNullOrEmpty
    }

    It 'does not back-merge when publication or release verification fails: <Failure>' -ForEach @(
        @{ Failure = 'create' }; @{ Failure = 'digest' }; @{ Failure = 'latest' }
    ) {
        Initialize-PreparedReleaseFixture
        New-FixtureStableArtifact -Directory $script:ArtifactDirectory
        $script:PublicationFailure = $Failure
        { Invoke-FixturePublication } | Should -Throw
        (Get-IdsRemoteBranchHead -Root $script:Fixture.Root -Branch beta) | Should -Be $script:Fixture.BetaHead
    }

    It 'plans a required release without a write credential and without changing VERSION' {
        $script:Fixture = New-IdsReleaseTransactionFixture `
            -Root (Join-Path $script:ReleaseScratch ([guid]::NewGuid().ToString('N'))) -IncludeNotes
        Set-ReleaseFixtureGitHub
        Remove-Item Env:IDS_STABLE_RELEASE_TOKEN -ErrorAction SilentlyContinue

        $plan = Invoke-IdsStableRelease -Root $script:Fixture.Root -Before $script:Fixture.Before `
            -PromotionSha $script:Fixture.Promotion -Repository 'fixture/repository' -PlanOnly

        $plan.required | Should -BeTrue
        (& git -C $script:Fixture.Root rev-parse HEAD).Trim() | Should -Be $script:Fixture.Promotion
        @($script:GitHubCalls | Where-Object { $_ -match '/git/ref/tags|/releases/tags|release create' }) | Should -BeNullOrEmpty
    }

    It 'refuses a required release before mutation when the narrow credential is absent' {
        $script:Fixture = New-IdsReleaseTransactionFixture `
            -Root (Join-Path $script:ReleaseScratch ([guid]::NewGuid().ToString('N'))) -IncludeNotes
        Set-ReleaseFixtureGitHub
        Remove-Item Env:IDS_STABLE_RELEASE_TOKEN -ErrorAction SilentlyContinue
        $head = (& git -C $script:Fixture.Root rev-parse HEAD).Trim()

        {
            Invoke-IdsStableRelease -Root $script:Fixture.Root -Before $script:Fixture.Before `
                -PromotionSha $script:Fixture.Promotion -Repository 'fixture/repository' -PrepareOnly
        } | Should -Throw '*IDS_STABLE_RELEASE_TOKEN*'

        (& git -C $script:Fixture.Root rev-parse HEAD).Trim() | Should -Be $head
        @($script:GitHubCalls | Where-Object { $_ -match '/git/ref/tags|/releases/tags|release create' }) | Should -BeNullOrEmpty
    }

    It 'does not start a second release for the verified pipeline version push' {
        Initialize-PreparedReleaseFixture
        $script:ReadHead = $script:Prepared.commit
        Remove-Item Env:IDS_STABLE_RELEASE_TOKEN
        $env:GH_TOKEN = 'synthetic-read-only-token'
        $plan = Invoke-IdsStableRelease -Root $script:Fixture.Root -Before $script:Fixture.Promotion `
            -PromotionSha $script:Prepared.commit -Repository 'fixture/repository' -PlanOnly

        $plan.required | Should -BeFalse
        $plan.version | Should -Be '0.2.0'
        $plan.promotionSha | Should -Be $script:Fixture.Promotion
        (& git -C $script:Fixture.Root rev-parse HEAD).Trim() | Should -Be $script:Prepared.commit
        (Get-IdsRemoteBranchHead -Root $script:Fixture.Root -Branch main) | Should -Be $script:Prepared.commit
        @($script:GitHubCalls | Where-Object { $_ -contains 'create' }) | Should -BeNullOrEmpty
    }

    It 'rejects unverified version-push no-ops: <Case>' -ForEach @(
        @{ Case = 'missing trailer' }
        @{ Case = 'other changed files' }
        @{ Case = 'wrong version' }
        @{ Case = 'moved remote main' }
        @{ Case = 'wrong before boundary' }
    ) {
        Initialize-PreparedReleaseFixture
        $commit = $script:Prepared.commit
        if ($Case -in @('missing trailer', 'other changed files', 'wrong version')) {
            # Replace only a synthetic fixture commit, never repository history.
            Invoke-ReleaseFixtureGit -Root $script:Fixture.Root -Arguments @('switch', '-c', 'invalid-version', $script:Fixture.Promotion) | Out-Null
            Set-Content -LiteralPath (Join-Path $script:Fixture.Root 'VERSION') -Value $(if ($Case -eq 'wrong version') { '0.3.0' } else { '0.2.0' })
            if ($Case -eq 'other changed files') {
                Set-Content -LiteralPath (Join-Path $script:Fixture.Root 'web\app.js') -Value 'unexpected code'
            }
            Invoke-ReleaseFixtureGit -Root $script:Fixture.Root -Arguments @('add', '--all') | Out-Null
            $message = if ($Case -eq 'missing trailer') { 'unverified version' } else { "chore(release): 0.2.0`n`nRelease-Promotion: $($script:Fixture.Promotion)" }
            Invoke-ReleaseFixtureGit -Root $script:Fixture.Root -Arguments @('commit', '-m', $message) | Out-Null
            $commit = Invoke-ReleaseFixtureGit -Root $script:Fixture.Root -Arguments @('rev-parse', 'HEAD')
            Invoke-ReleaseFixtureGit -Root $script:Fixture.Root -Arguments @('branch', '-f', 'main', $commit) | Out-Null
            Invoke-ReleaseFixtureGit -Root $script:Fixture.Root -Arguments @('switch', 'main') | Out-Null
        }
        $script:ReadHead = if ($Case -eq 'moved remote main') { 'b' * 40 } else { $commit }
        $before = if ($Case -eq 'wrong before boundary') { $script:Fixture.Before } else { $script:Fixture.Promotion }
        {
            Invoke-IdsStableRelease -Root $script:Fixture.Root -Before $before `
                -PromotionSha $commit -Repository 'fixture/repository' -PlanOnly
        } | Should -Throw
        (& git -C $script:Fixture.Root rev-parse HEAD).Trim() | Should -Be $commit
        (Get-IdsRemoteBranchHead -Root $script:Fixture.Root -Branch main) | Should -Be $script:Prepared.commit
    }

    It 'fails closed when the narrow stable automation credential is absent' {
        $previousToken = $env:IDS_STABLE_RELEASE_TOKEN
        try {
            Remove-Item Env:IDS_STABLE_RELEASE_TOKEN -ErrorAction SilentlyContinue
            { Assert-IdsStableCredential } | Should -Throw '*IDS_STABLE_RELEASE_TOKEN*'
        } finally {
            if ($null -ne $previousToken) { $env:IDS_STABLE_RELEASE_TOKEN = $previousToken }
        }
    }

    It 'pushes one version commit with the immutable promotion trailer' {
        $script:Fixture = New-IdsReleaseTransactionFixture -Root (Join-Path $script:ReleaseScratch ([guid]::NewGuid().ToString('N'))) -IncludeNotes
        Set-ReleaseFixtureGitHub
        $result = Invoke-IdsStableRelease -Root $script:Fixture.Root -Before $script:Fixture.Before `
            -PromotionSha $script:Fixture.Promotion -Repository 'fixture/repository' -PrepareOnly

        $result.version | Should -Be '0.2.0'
        $result.tag | Should -Be 'v0.2.0'
        $versionCommit = $result.commit
        $message = (& git -C $script:Fixture.Root show -s --format=%B $versionCommit) -join "`n"
        $message | Should -Match "Release-Promotion: $($script:Fixture.Promotion)"
        ((& git -C $script:Fixture.Root show "$($versionCommit):VERSION") -join '').Trim() | Should -Be '0.2.0'
        $remoteMain = (Invoke-ReleaseFixtureGit -Root $script:Fixture.Root -Arguments @('ls-remote', 'origin', 'refs/heads/main')) -split '\s+' | Select-Object -First 1
        $remoteMain | Should -Be $versionCommit
        @($script:GitHubCalls | Where-Object { $_ -contains 'release' -and $_ -contains 'create' }) | Should -BeNullOrEmpty
    }

    It 'reuses a verified version commit on recovery without incrementing again' {
        $script:Fixture = New-IdsReleaseTransactionFixture -Root (Join-Path $script:ReleaseScratch ([guid]::NewGuid().ToString('N'))) -IncludeNotes
        Set-ReleaseFixtureGitHub
        $prepared = Invoke-IdsStableRelease -Root $script:Fixture.Root -Before $script:Fixture.Before `
            -PromotionSha $script:Fixture.Promotion -Repository 'fixture/repository' -PrepareOnly
        $headBeforeRecovery = (& git -C $script:Fixture.Root rev-parse HEAD).Trim()

        $recovered = Invoke-IdsStableRelease -Root $script:Fixture.Root -Before $script:Fixture.Before `
            -PromotionSha $script:Fixture.Promotion -Repository 'fixture/repository' `
            -RecoveryVersionCommit $prepared.commit -PrepareOnly

        $recovered.commit | Should -Be $prepared.commit
        (& git -C $script:Fixture.Root rev-parse HEAD).Trim() | Should -Be $headBeforeRecovery
        ((& git -C $script:Fixture.Root show "$($recovered.commit):VERSION") -join '').Trim() | Should -Be '0.2.0'
    }

    It 'binds the stable ZIP checksum and source commit in its manifest' {
        $directory = Join-Path $script:ReleaseScratch ([guid]::NewGuid().ToString('N'))
        [void](New-Item -ItemType Directory -Path $directory -Force)
        Set-Content -LiteralPath (Join-Path $directory 'IntuneDocsStudio.zip') -Value 'synthetic stable package' -NoNewline
        $promotion = 'a' * 40
        $versionCommit = 'b' * 40
        $manifest = Write-IdsReleaseManifest -ArtifactDirectory $directory -Version '0.2.0' `
            -PromotionSha $promotion -VersionCommit $versionCommit
        $manifest.manifest.zipSha256 | Should -Be $manifest.sha256
        $validated = Assert-IdsArtifactIdentity -ArtifactDirectory $directory -Version '0.2.0' `
            -PromotionSha $promotion -VersionCommit $versionCommit
        $validated.sha256 | Should -Be $manifest.sha256
        Set-Content -LiteralPath $validated.zip -Value 'changed artifact' -NoNewline
        {
            Assert-IdsArtifactIdentity -ArtifactDirectory $directory -Version '0.2.0' `
                -PromotionSha $promotion -VersionCommit $versionCommit
        } | Should -Throw '*identity or checksum*'
    }

    It 'does not publish when the expected remote main head has moved' {
        $script:Fixture = New-IdsReleaseTransactionFixture -Root (Join-Path $script:ReleaseScratch ([guid]::NewGuid().ToString('N'))) -IncludeNotes
        Set-ReleaseFixtureGitHub
        Set-Content -LiteralPath (Join-Path $script:Fixture.Root 'README.md') -Value 'later docs commit'
        Invoke-ReleaseFixtureGit -Root $script:Fixture.Root -Arguments @('add', '--', 'README.md') | Out-Null
        Invoke-ReleaseFixtureGit -Root $script:Fixture.Root -Arguments @('commit', '-m', 'docs: move main') | Out-Null
        Invoke-ReleaseFixtureGit -Root $script:Fixture.Root -Arguments @('push', 'origin', 'main') | Out-Null
        $head = (& git -C $script:Fixture.Root rev-parse HEAD).Trim()

        {
            Invoke-IdsStableRelease -Root $script:Fixture.Root -Before $script:Fixture.Before `
                -PromotionSha $script:Fixture.Promotion -Repository 'fixture/repository' -PrepareOnly
        } | Should -Throw '*stale*'

        (& git -C $script:Fixture.Root rev-parse HEAD).Trim() | Should -Be $head
        @($script:GitHubCalls | Where-Object { $_ -contains 'release' -and $_ -contains 'create' }) | Should -BeNullOrEmpty
    }

    It 'does not publish when the version push is rejected for docs-only opt-in: <DocsOnly>' -ForEach @(
        @{ DocsOnly = $false }; @{ DocsOnly = $true }
    ) {
        $script:Fixture = New-IdsReleaseTransactionFixture -Root (Join-Path $script:ReleaseScratch ([guid]::NewGuid().ToString('N'))) -IncludeNotes -DocsOnly:$DocsOnly
        if ($DocsOnly) { $script:PromotionLabels += 'release:required' }
        Set-ReleaseFixtureGitHub
        $hook = Join-Path $script:Fixture.Remote 'hooks\pre-receive'
        Set-Content -LiteralPath $hook -Value "#!/bin/sh`nexit 1`n" -NoNewline
        if (-not $IsWindows) {
            & chmod +x $hook
            if ($LASTEXITCODE -ne 0) { throw 'Could not make fixture rejection hook executable.' }
        }
        $remoteBefore = (Invoke-ReleaseFixtureGit -Root $script:Fixture.Root -Arguments @('ls-remote', 'origin', 'refs/heads/main')) -split '\s+' | Select-Object -First 1

        {
            Invoke-IdsStableRelease -Root $script:Fixture.Root -Before $script:Fixture.Before `
                -PromotionSha $script:Fixture.Promotion -Repository 'fixture/repository' -PrepareOnly
        } | Should -Throw '*No release will be created*'

        $remoteAfter = (Invoke-ReleaseFixtureGit -Root $script:Fixture.Root -Arguments @('ls-remote', 'origin', 'refs/heads/main')) -split '\s+' | Select-Object -First 1
        $remoteAfter | Should -Be $remoteBefore
        @($script:GitHubCalls | Where-Object { $_ -contains 'release' -and $_ -contains 'create' }) | Should -BeNullOrEmpty
    }

    It 'does not overwrite a tag or release that already exists' {
        $script:Fixture = New-IdsReleaseTransactionFixture -Root (Join-Path $script:ReleaseScratch ([guid]::NewGuid().ToString('N'))) -IncludeNotes
        Mock Invoke-IdsGitHub {
            param($Arguments)
            $script:GitHubCalls += ,@($Arguments)
            $endpoint = ($Arguments -join ' ')
            if ($endpoint -match '/commits/.+/pulls') {
                return @(@{
                    merged_at = '2026-10-28T00:00:00Z'; merge_commit_sha = $script:Fixture.Promotion
                    base = @{ ref = 'main' }; head = @{ ref = 'beta'; sha = $script:Fixture.BetaHead; repo = @{ full_name = 'fixture/repository' } }
                    labels = @(@{ name = 'version:minor' })
                }) | ConvertTo-Json -Depth 10 -Compress
            }
            if ($endpoint -match '/check-runs') {
                return @{ check_runs = @(
                    @{ name = 'quality'; conclusion = 'success'; started_at = '2026-10-28T00:00:00Z' }
                    @{ name = 'only-from-beta'; conclusion = 'success'; started_at = '2026-10-28T00:00:00Z' }
                ) } | ConvertTo-Json -Depth 10 -Compress
            }
            if ($endpoint -match '/git/ref/tags/') { return '{"ref":"refs/tags/v0.2.0"}' }
            if ($endpoint -match '/releases/tags/') { throw 'GitHub CLI failed: Not Found (HTTP 404)' }
            throw "Unexpected release query: $($Arguments -join ' | ')"
        }
        {
            Invoke-IdsStableRelease -Root $script:Fixture.Root -Before $script:Fixture.Before `
                -PromotionSha $script:Fixture.Promotion -Repository 'fixture/repository' -PrepareOnly
        } | Should -Throw '*Refusing to overwrite existing stable tag or release*'
        (& git -C $script:Fixture.Root rev-parse HEAD).Trim() | Should -Be $script:Fixture.Promotion
        @($script:GitHubCalls | Where-Object { $_ -contains 'release' -and $_ -contains 'create' }) | Should -BeNullOrEmpty
    }

    It 'fails back-merge conflicts without changing the remote beta head' {
        Initialize-PreparedReleaseFixture
        Invoke-ReleaseFixtureGit -Root $script:Fixture.Root -Arguments @('switch', 'beta') | Out-Null
        Set-Content -LiteralPath (Join-Path $script:Fixture.Root 'VERSION') -Value '0.9.0' -NoNewline
        Invoke-ReleaseFixtureGit -Root $script:Fixture.Root -Arguments @('add', '--', 'VERSION') | Out-Null
        Invoke-ReleaseFixtureGit -Root $script:Fixture.Root -Arguments @('commit', '-m', 'conflicting beta version') | Out-Null
        Invoke-ReleaseFixtureGit -Root $script:Fixture.Root -Arguments @('push', 'origin', 'beta') | Out-Null
        $betaHead = (Invoke-ReleaseFixtureGit -Root $script:Fixture.Root -Arguments @('ls-remote', 'origin', 'refs/heads/beta')) -split '\s+' | Select-Object -First 1
        Invoke-ReleaseFixtureGit -Root $script:Fixture.Root -Arguments @('switch', 'main') | Out-Null

        { Invoke-IdsBackMerge -Root $script:Fixture.Root } | Should -Throw '*Back-merge main into beta has conflicts*'

        $betaAfter = (Invoke-ReleaseFixtureGit -Root $script:Fixture.Root -Arguments @('ls-remote', 'origin', 'refs/heads/beta')) -split '\s+' | Select-Object -First 1
        $betaAfter | Should -Be $betaHead
    }
}

AfterAll {
    if ($null -eq $script:SavedStableToken) { Remove-Item Env:IDS_STABLE_RELEASE_TOKEN -ErrorAction SilentlyContinue }
    else { $env:IDS_STABLE_RELEASE_TOKEN = $script:SavedStableToken }
    if ($null -eq $script:SavedGhToken) { Remove-Item Env:GH_TOKEN -ErrorAction SilentlyContinue }
    else { $env:GH_TOKEN = $script:SavedGhToken }
    if (Test-Path -LiteralPath $script:ReleaseScratch) {
        Remove-Item -LiteralPath $script:ReleaseScratch -Recurse -Force
    }
}
