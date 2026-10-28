BeforeAll {
    $script:ReleaseRepo = Split-Path -Parent $PSScriptRoot
    $script:ReleasePolicy = Join-Path $script:ReleaseRepo 'scripts\ReleasePolicy.ps1'
    if (Test-Path -LiteralPath $script:ReleasePolicy -PathType Leaf) {
        . $script:ReleasePolicy
    }
}

Describe 'Stable release policy' {
    It 'increments the patch by default' {
        Get-IdsNextVersion -Version '0.1.7' -Labels @() | Should -Be '0.1.8'
    }

    It 'increments minor and resets patch' {
        Get-IdsNextVersion -Version '0.1.7' -Labels @('version:minor') |
            Should -Be '0.2.0'
    }

    It 'increments major and resets minor and patch' {
        Get-IdsNextVersion -Version '0.1.7' -Labels @('version:major') |
            Should -Be '1.0.0'
    }

    It 'rejects conflicting version labels rather than choosing one' {
        {
            Get-IdsNextVersion -Version '0.1.0' -Labels @('version:major', 'version:minor')
        } | Should -Throw '*one version label*'
    }

    It 'rejects malformed or overflowing versions' {
        { Get-IdsNextVersion -Version '01.2.3' -Labels @() } | Should -Throw '*strict MAJOR.MINOR.PATCH*'
        { Get-IdsNextVersion -Version '9223372036854775807.0.0' -Labels @('version:major') } |
            Should -Throw '*cannot be incremented*'
    }

    It 'does not release documentation-only changes' {
        Test-IdsReleaseDelta -Paths @('README.md', 'docs\operations.md') |
            Should -BeFalse
    }

    It 'releases changes to application, build, and CI paths' {
        foreach ($path in @('IntuneDocsStudio.ps1', 'lib\Version.ps1', 'web\app.js', 'Build-Package.ps1', '.github\workflows\ci.yml')) {
            Test-IdsReleaseDelta -Paths @($path) | Should -BeTrue -Because $path
        }
    }

    It 'plans notes and a tag for the next version without changing the source version' {
        $fixture = Join-Path $TestDrive 'release-plan'
        [void](New-Item -ItemType Directory -Path $fixture -Force)
        Set-Content -LiteralPath (Join-Path $fixture 'VERSION') -Value '0.1.7' -NoNewline
        & git -C $fixture init --quiet
        & git -C $fixture add -- VERSION
        & git -C $fixture -c user.name='Release Test' -c user.email='release@example.invalid' commit --allow-empty -m 'fixture' --quiet
        $before = (& git -C $fixture rev-parse HEAD).Trim()
        Set-Content -LiteralPath (Join-Path $fixture 'README.md') -Value 'Docs only' -NoNewline
        & git -C $fixture add -- README.md
        & git -C $fixture -c user.name='Release Test' -c user.email='release@example.invalid' commit -m 'docs: update' --quiet
        $after = (& git -C $fixture rev-parse HEAD).Trim()

        $plan = Get-IdsReleasePlan -Root $fixture -Before $before -After $after -Labels @()
        $plan.required | Should -BeFalse
        $plan.previousVersion | Should -Be '0.1.7'
        $plan.version | Should -Be '0.1.7'
        $plan.tag | Should -Be 'v0.1.7'
        $plan.notesPath | Should -Be (Join-Path $fixture 'docs\releases\v0.1.7.md')
        $plan.promotionSha | Should -Be $after
    }

    It 'validates complete user-facing release notes' {
        $notes = @'
# Stable release

## Changes and user-visible effects
The dashboard now reports its channel and build identity.

## Update instructions
Download the ZIP and replace the existing application files.

## Dependencies and runtime
PowerShell 7 or later is required.

## Data implications
No existing output or tenant data is migrated.

## Unverified integrations
Live Azure DevOps authentication was not exercised.
'@
        Test-IdsReleaseNotes -Content $notes | Should -BeTrue
        Test-IdsReleaseNotes -Content '# Empty' | Should -BeFalse
    }
}
