BeforeAll {
    # Keep nested release-worktree paths out of synthetic Git object paths on Windows.
    $script:PolicyFixtureBase = Join-Path $TestDrive 'policy'
    [void](New-Item -ItemType Directory -Path $script:PolicyFixtureBase -Force)

    $policyPath = Join-Path $PSScriptRoot '..\scripts\RepositoryPolicy.ps1'
    if (Test-Path -LiteralPath $policyPath) {
        . $policyPath
    }

    function New-PolicyFixture {
        param([string]$Name)

        $root = Join-Path $script:PolicyFixtureBase $Name
        [void](New-Item -ItemType Directory -Path (Join-Path $root '.github') -Force)
        [void](New-Item -ItemType Directory -Path (Join-Path $root 'docs') -Force)
        [void](New-Item -ItemType Directory -Path (Join-Path $root 'scripts') -Force)
        Set-Content -LiteralPath (Join-Path $root 'VERSION') -Value '0.1.0'
        Set-Content -LiteralPath (Join-Path $root 'AGENTS.md') -Value "# Canonical guidance`n`nRepository rules live here."
        Set-Content -LiteralPath (Join-Path $root 'CLAUDE.md') -Value "# Contributor guidance`n`nRead [AGENTS.md](AGENTS.md) for the canonical repository guidance."
        Set-Content -LiteralPath (Join-Path $root '.github\copilot-instructions.md') -Value "# Copilot guidance`n`nRead [AGENTS.md](../AGENTS.md) for the canonical repository guidance."

        $rows = @(
            '| B-01 | Canonical guidance and client pointers | Applicable | Automated local policy | `scripts/RepositoryPolicy.ps1`; `scripts/Test-Repository.ps1`; `tests/RepositoryPolicy.Tests.ps1`. | Implemented locally; GitHub check activation is pending. |'
            '| B-02 | PowerShell runtime floor and local checks | Applicable | Review requirement | `AGENTS.md`; `README.md`; `QUICKSTART.md`. | PowerShell 7+ is required; no automatic installation is performed. |'
            '| B-03 | Customer data and credentials | Applicable | Review requirement | `AGENTS.md`; `SECURITY.md`; `tests/RepositoryPolicy.Tests.ps1`. | Synthetic tests only; no tenant-backed CI or credential scanning is claimed. |'
            '| B-04 | Feature isolation and PR targets | Applicable | Automated local policy | `scripts/RepositoryPolicy.ps1`; `.github/workflows/ci.yml`. | Implemented in code; live remote enforcement remains pending. |'
            '| B-05 | Version edits | Applicable | Automated local policy | `scripts/RepositoryPolicy.ps1`; `.github/workflows/ci.yml`; `scripts/ReleasePolicy.ps1`. | Feature PR edits are rejected; release enforcement still depends on repository controls. |'
            '| B-06 | Local hook | Applicable | Opt-in automation | `scripts/Setup-Hooks.ps1`; `tests/hooks/pre-commit`. | Inactive until each contributor opts in; existing hooks are preserved. |'
            '| B-07 | Packaging and channel checks | Applicable | CI workflow | `.github/workflows/ci.yml`; `.github/workflows/beta.yml`; `tests/Package.Tests.ps1`. | Local tests pass; no hosted run is evidence of activation. |'
            '| B-08 | Stable release authorization | Applicable | Review requirement and workflow | `AGENTS.md`; `docs/promotion-runbook.md`; `.github/workflows/release.yml`. | Owner-requested only; narrow release credential and protection activation are pending. |'
            '| B-09 | Applicable baseline completeness | Applicable, incomplete | Deferred source requirement | `111-topic index`; `conformance template`; `validators`; `linked reference workflows`. | Missing authoritative inputs; section 18 and 111-topic conformance remain incomplete. |'
            '| B-10 | OAuth standards-module deviation | Applicable deviation | Review requirement | `AGENTS.md`; `lib/Auth.ps1`. | Existing OAuth protocol handling has no dedicated standards module; no conformance is claimed. |'
            '| B-11 | Runtime data ownership and deployment boundary | Applicable | Review requirement | `README.md`; `SECURITY.md`; `lib/Http.ps1`; `lib/Export.ps1`. | Local loopback use only; no supported proxy, CDN, ingress, or public TLS host. |'
            '| B-12 | Container storage/images, database migrations, Apple delivery, web push, crawler/sitemap, public-domain HSTS, multi-locale catalogues | Not applicable | Product scope | `AGENTS.md`; `docs/baseline-adoption.md`. | Not applicable to this local PowerShell app; reassess if product architecture changes. |'
            '| B-13 | Operations and recovery | Applicable | Operator procedure | `docs/operations.md`; `GET /api/health`; `GET /api/version`; `.intune-docs-manifest.json`. | SLO/performance/RPO/RTO are unmeasured/not-now because there are no measured service history or commitments. |'
        )
        Set-Content -LiteralPath (Join-Path $root 'docs\baseline-adoption.md') -Value (@(
            '# Adoption matrix'
            ''
            '| ID | Requirement | Applicability | Control type | Evidence/control | Status and limits |'
            '|---|---|---|---|---|'
        ) + $rows)
        return $root
    }

    function Invoke-PolicyFixtureGit {
        param(
            [string]$Root,
            [string[]]$GitArgs
        )

        $output = & git -C $Root @GitArgs 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "Fixture git command failed: $output"
        }
        return $output
    }

    function New-VersionFixture {
        param([string]$Name)

        $root = Join-Path $script:PolicyFixtureBase $Name
        [void](New-Item -ItemType Directory -Path $root -Force)
        Invoke-PolicyFixtureGit -Root $root -GitArgs @('init', '--initial-branch=main') | Out-Null
        Invoke-PolicyFixtureGit -Root $root -GitArgs @('config', 'user.name', 'Policy test') | Out-Null
        Invoke-PolicyFixtureGit -Root $root -GitArgs @('config', 'user.email', 'policy-test@localhost') | Out-Null
        Set-Content -LiteralPath (Join-Path $root 'README.md') -Value 'Fixture'
        Invoke-PolicyFixtureGit -Root $root -GitArgs @('add', 'README.md') | Out-Null
        Invoke-PolicyFixtureGit -Root $root -GitArgs @('commit', '-m', 'Baseline') | Out-Null
        return [pscustomobject]@{
            Root = $root
            Before = (Invoke-PolicyFixtureGit -Root $root -GitArgs @('rev-parse', 'HEAD')).ToString()
        }
    }

    function Invoke-RepositoryCheckerFixture {
        param(
            [string]$Root,
            [string]$EventName,
            [string]$Base,
            [string]$Head,
            [string]$BaseRepository,
            [string]$HeadRepository,
            [string]$Before,
            [string]$After
        )

        $names = @(
            'IDS_EVENT_NAME', 'IDS_PR_BASE', 'IDS_PR_HEAD',
            'IDS_REPOSITORY', 'IDS_PR_HEAD_REPOSITORY',
            'IDS_PR_BASE_SHA', 'IDS_PR_HEAD_SHA'
        )
        $saved = @{}
        foreach ($name in $names) { $saved[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }
        try {
            $env:IDS_EVENT_NAME = $EventName
            $env:IDS_PR_BASE = $Base
            $env:IDS_PR_HEAD = $Head
            $env:IDS_REPOSITORY = $BaseRepository
            $env:IDS_PR_HEAD_REPOSITORY = $HeadRepository
            $env:IDS_PR_BASE_SHA = $Before
            $env:IDS_PR_HEAD_SHA = $After

            $pwsh = Get-Command pwsh -CommandType Application | Select-Object -First 1 -ExpandProperty Source
            $checker = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts\Test-Repository.ps1'
            $output = & $pwsh -NoLogo -NoProfile -File $checker -Root $Root 2>&1
            $exitCode = $LASTEXITCODE
            return [pscustomobject]@{ ExitCode = $exitCode; Output = ($output -join "`n") }
        } finally {
            foreach ($name in $names) {
                [Environment]::SetEnvironmentVariable($name, $saved[$name], 'Process')
            }
        }
    }
}

AfterAll {
    if (Test-Path -LiteralPath $script:PolicyFixtureBase) {
        Remove-Item -LiteralPath $script:PolicyFixtureBase -Recurse -Force
    }
}

Describe 'Repository guidance policy' {
    It 'accepts a canonical file, thin client pointers, and a complete honest matrix' {
        $root = New-PolicyFixture 'valid-guidance'

        @(Test-IdsAgentInstructions -Root $root).Count | Should -Be 0
    }

    It 'reports a missing client pointer' {
        $root = New-PolicyFixture 'missing-pointer'
        Remove-Item -LiteralPath (Join-Path $root '.github\copilot-instructions.md')

        $violations = @(Test-IdsAgentInstructions -Root $root)
        $violations.Count | Should -BeGreaterThan 0
        ($violations -join "`n") | Should -Match 'copilot-instructions'
    }

    It 'rejects duplicated canonical prose in a client pointer' {
        $root = New-PolicyFixture 'duplicated-prose'
        Add-Content -LiteralPath (Join-Path $root 'CLAUDE.md') -Value "`nFeature pull requests target beta."

        $violations = @(Test-IdsAgentInstructions -Root $root)
        $violations.Count | Should -BeGreaterThan 0
        ($violations -join "`n") | Should -Match 'CLAUDE.md'
    }

    It 'reports a missing adoption-control row without requiring deferred controls to be live' {
        $root = New-PolicyFixture 'missing-matrix-row'
        $matrixPath = Join-Path $root 'docs\baseline-adoption.md'
        $lines = Get-Content -LiteralPath $matrixPath
        Set-Content -LiteralPath $matrixPath -Value @($lines | Where-Object { $_ -notmatch '^\| B-13 \|' })

        $violations = @(Test-IdsAgentInstructions -Root $root)
        $violations.Count | Should -BeGreaterThan 0
        ($violations -join "`n") | Should -Match 'B-13'
    }

    It 'rejects an adoption row without named control evidence' {
        $root = New-PolicyFixture 'missing-matrix-evidence'
        $matrixPath = Join-Path $root 'docs\baseline-adoption.md'
        $lines = Get-Content -LiteralPath $matrixPath
        Set-Content -LiteralPath $matrixPath -Value @($lines | ForEach-Object {
            if ($_ -match '^\| B-13 \|') { $_ -replace '\| [^|]+ \| ([^|]+) \|$', '|  | $1 |' } else { $_ }
        })

        $violations = @(Test-IdsAgentInstructions -Root $root)
        $violations.Count | Should -BeGreaterThan 0
        ($violations -join "`n") | Should -Match 'B-13.*control evidence'
    }

    It 'rejects an adoption row without a reason or status limit' {
        $root = New-PolicyFixture 'missing-matrix-reason'
        $matrixPath = Join-Path $root 'docs\baseline-adoption.md'
        $lines = Get-Content -LiteralPath $matrixPath
        Set-Content -LiteralPath $matrixPath -Value @($lines | ForEach-Object {
            if ($_ -match '^\| B-13 \|') { $_ -replace '\| [^|]+ \|$', '|  |' } else { $_ }
        })

        $violations = @(Test-IdsAgentInstructions -Root $root)
        $violations.Count | Should -BeGreaterThan 0
        ($violations -join "`n") | Should -Match 'B-13.*status.*reason'
    }
}

Describe 'Pull request target policy' {
    It 'refuses a feature PR into main' {
        @(Test-IdsPullRequestTarget -Base main -Head feature -SameRepository $true).Count |
            Should -Be 1
    }

    It 'rejects a fork branch named beta as a stable promotion' {
        @(Test-IdsPullRequestTarget -Base main -Head beta -SameRepository $false).Count |
            Should -Be 1
    }

    It 'accepts this repository beta as the promotion head' {
        @(Test-IdsPullRequestTarget -Base main -Head beta -SameRepository $true).Count |
            Should -Be 0
    }

    It 'accepts feature work into beta and rejects other targets' {
        @(Test-IdsPullRequestTarget -Base beta -Head feature -SameRepository $true).Count |
            Should -Be 0
        @(Test-IdsPullRequestTarget -Base release -Head feature -SameRepository $true).Count |
            Should -Be 1
    }
}

Describe 'VERSION change policy' {
    It 'allows only the exact 0.1.0 bootstrap when the base has no VERSION' {
        $fixture = New-VersionFixture 'version-bootstrap'
        Set-Content -LiteralPath (Join-Path $fixture.Root 'VERSION') -Value '0.1.0'
        Invoke-PolicyFixtureGit -Root $fixture.Root -GitArgs @('add', 'VERSION') | Out-Null
        Invoke-PolicyFixtureGit -Root $fixture.Root -GitArgs @('commit', '-m', 'Add initial version') | Out-Null
        $after = (Invoke-PolicyFixtureGit -Root $fixture.Root -GitArgs @('rev-parse', 'HEAD')).ToString()

        @(Test-IdsVersionChange -Root $fixture.Root -Before $fixture.Before -After $after).Count |
            Should -Be 0
    }

    It 'rejects any non-0.1.0 bootstrap value' {
        $fixture = New-VersionFixture 'version-invalid-bootstrap'
        Set-Content -LiteralPath (Join-Path $fixture.Root 'VERSION') -Value '0.1.1'
        Invoke-PolicyFixtureGit -Root $fixture.Root -GitArgs @('add', 'VERSION') | Out-Null
        Invoke-PolicyFixtureGit -Root $fixture.Root -GitArgs @('commit', '-m', 'Add invalid version') | Out-Null
        $after = (Invoke-PolicyFixtureGit -Root $fixture.Root -GitArgs @('rev-parse', 'HEAD')).ToString()

        $violations = @(Test-IdsVersionChange -Root $fixture.Root -Before $fixture.Before -After $after)
        $violations.Count | Should -Be 1
        ($violations -join "`n") | Should -Match '0\.1\.0'
    }

    It 'rejects every version edit after bootstrap, even a numeric increase' {
        $fixture = New-VersionFixture 'version-increment'
        Set-Content -LiteralPath (Join-Path $fixture.Root 'VERSION') -Value '0.1.0'
        Invoke-PolicyFixtureGit -Root $fixture.Root -GitArgs @('add', 'VERSION') | Out-Null
        Invoke-PolicyFixtureGit -Root $fixture.Root -GitArgs @('commit', '-m', 'Bootstrap version') | Out-Null
        $before = (Invoke-PolicyFixtureGit -Root $fixture.Root -GitArgs @('rev-parse', 'HEAD')).ToString()

        Set-Content -LiteralPath (Join-Path $fixture.Root 'VERSION') -Value '0.1.1'
        Invoke-PolicyFixtureGit -Root $fixture.Root -GitArgs @('add', 'VERSION') | Out-Null
        Invoke-PolicyFixtureGit -Root $fixture.Root -GitArgs @('commit', '-m', 'Increase version') | Out-Null
        $after = (Invoke-PolicyFixtureGit -Root $fixture.Root -GitArgs @('rev-parse', 'HEAD')).ToString()

        $violations = @(Test-IdsVersionChange -Root $fixture.Root -Before $before -After $after)
        $violations.Count | Should -Be 1
        ($violations -join "`n") | Should -Match 'feature'
    }

    It 'accepts an unchanged version after bootstrap' {
        $fixture = New-VersionFixture 'version-unchanged'
        Set-Content -LiteralPath (Join-Path $fixture.Root 'VERSION') -Value '0.1.0'
        Invoke-PolicyFixtureGit -Root $fixture.Root -GitArgs @('add', 'VERSION') | Out-Null
        Invoke-PolicyFixtureGit -Root $fixture.Root -GitArgs @('commit', '-m', 'Bootstrap version') | Out-Null
        $before = (Invoke-PolicyFixtureGit -Root $fixture.Root -GitArgs @('rev-parse', 'HEAD')).ToString()

        Set-Content -LiteralPath (Join-Path $fixture.Root 'README.md') -Value 'Updated'
        Invoke-PolicyFixtureGit -Root $fixture.Root -GitArgs @('add', 'README.md') | Out-Null
        Invoke-PolicyFixtureGit -Root $fixture.Root -GitArgs @('commit', '-m', 'Docs update') | Out-Null
        $after = (Invoke-PolicyFixtureGit -Root $fixture.Root -GitArgs @('rev-parse', 'HEAD')).ToString()

        @(Test-IdsVersionChange -Root $fixture.Root -Before $before -After $after).Count |
            Should -Be 0
    }
}

Describe 'VERSION format policy' {
    It 'rejects invalid semantic version <Value>' -ForEach @(
        @{ Value = '1.0.0-beta' }
        @{ Value = '01.0.0' }
        @{ Value = 'v1.2.3' }
    ) {
        $fixture = New-VersionFixture "version-format-$([guid]::NewGuid().ToString('N'))"
        Set-Content -LiteralPath (Join-Path $fixture.Root 'VERSION') -Value $Value

        $violations = @(Test-IdsVersionFormat -Root $fixture.Root)
        $violations.Count | Should -Be 1
        ($violations -join "`n") | Should -Match 'MAJOR\.MINOR\.PATCH'
    }

    It 'accepts a strict three-part semantic version' {
        $fixture = New-VersionFixture 'version-format-valid'
        Set-Content -LiteralPath (Join-Path $fixture.Root 'VERSION') -Value '2.10.3'

        @(Test-IdsVersionFormat -Root $fixture.Root).Count | Should -Be 0
    }
}

Describe 'Repository checker workflow context' {
    It 'reports pull-request target policy as not applicable on pushes' {
        $root = New-PolicyFixture 'checker-push'
        $result = Invoke-RepositoryCheckerFixture -Root $root -EventName 'push'

        $result.ExitCode | Should -Be 0
        $result.Output | Should -Match 'target policy: not applicable'
    }

    It 'enforces the PR target using environment-provided refs and repository identity' {
        $fixture = New-VersionFixture 'checker-pull-request'
        $result = Invoke-RepositoryCheckerFixture -Root $fixture.Root -EventName 'pull_request' `
            -Base 'main' -Head 'feature' -BaseRepository 'owner/repo' -HeadRepository 'owner/repo' `
            -Before $fixture.Before -After $fixture.Before

        $result.ExitCode | Should -Be 1
        $result.Output | Should -Match 'main accepts only a promotion from beta'
    }
}

Describe 'Opt-in hook setup' {
    It 'refuses to replace a configured custom hooks path' {
        $root = New-PolicyFixture 'custom-hooks-path'
        Invoke-PolicyFixtureGit -Root $root -GitArgs @('init', '--initial-branch=main') | Out-Null
        Invoke-PolicyFixtureGit -Root $root -GitArgs @('config', 'core.hooksPath', 'custom-hooks') | Out-Null
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot '..\scripts\Setup-Hooks.ps1') -Destination (Join-Path $root 'scripts\Setup-Hooks.ps1')
        [void](New-Item -ItemType Directory -Path (Join-Path $root 'tests\hooks') -Force)
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'hooks\pre-commit') -Destination (Join-Path $root 'tests\hooks\pre-commit')

        { & (Join-Path $root 'scripts\Setup-Hooks.ps1') -Root $root } | Should -Throw '*custom hooks path*'
        (Invoke-PolicyFixtureGit -Root $root -GitArgs @('config', '--get', 'core.hooksPath')).ToString() |
            Should -Be 'custom-hooks'
    }

    It 'enables the tracked hook only when no custom hook is present' {
        $root = New-PolicyFixture 'install-managed-hook'
        Invoke-PolicyFixtureGit -Root $root -GitArgs @('init', '--initial-branch=main') | Out-Null
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot '..\scripts\Setup-Hooks.ps1') -Destination (Join-Path $root 'scripts\Setup-Hooks.ps1')
        [void](New-Item -ItemType Directory -Path (Join-Path $root 'tests\hooks') -Force)
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'hooks\pre-commit') -Destination (Join-Path $root 'tests\hooks\pre-commit')

        & (Join-Path $root 'scripts\Setup-Hooks.ps1') -Root $root

        (Invoke-PolicyFixtureGit -Root $root -GitArgs @('config', '--get', 'core.hooksPath')).ToString() |
            Should -Be 'tests/hooks'
    }

    It 'preserves an existing <HookName> hook in the default Git hooks directory' -ForEach @(
        @{ HookName = 'pre-commit' }
        @{ HookName = 'pre-push' }
        @{ HookName = 'commit-msg' }
    ) {
        $root = New-PolicyFixture "existing-default-$HookName"
        Invoke-PolicyFixtureGit -Root $root -GitArgs @('init', '--initial-branch=main') | Out-Null
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot '..\scripts\Setup-Hooks.ps1') -Destination (Join-Path $root 'scripts\Setup-Hooks.ps1')
        [void](New-Item -ItemType Directory -Path (Join-Path $root 'tests\hooks') -Force)
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'hooks\pre-commit') -Destination (Join-Path $root 'tests\hooks\pre-commit')
        $hooksPath = (Invoke-PolicyFixtureGit -Root $root -GitArgs @('rev-parse', '--git-path', 'hooks')).ToString()
        if (-not [System.IO.Path]::IsPathRooted($hooksPath)) {
            $hooksPath = Join-Path $root $hooksPath
        }
        [void](New-Item -ItemType Directory -Path $hooksPath -Force)
        $customHook = Join-Path $hooksPath $HookName
        Set-Content -LiteralPath $customHook -Value @('#!/bin/sh', 'echo custom')

        { & (Join-Path $root 'scripts\Setup-Hooks.ps1') -Root $root } | Should -Throw "*$HookName*manually*"
        (Get-Content -LiteralPath $customHook -Raw) | Should -Match 'echo custom'
        $configuredHooksPath = & git -C $root config --get core.hooksPath 2>$null
        $LASTEXITCODE | Should -Not -Be 0
        $configuredHooksPath | Should -BeNullOrEmpty
    }
}
