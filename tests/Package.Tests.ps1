BeforeAll {
    $script:PackageRepo = Split-Path -Parent $PSScriptRoot
    $script:PackageFixture = Join-Path $TestDrive 'package-source'
    $script:BuildScript = Join-Path $script:PackageFixture 'Build-Package.ps1'

    [void](New-Item -ItemType Directory -Path $script:PackageFixture -Force)
    foreach ($file in Get-ChildItem -LiteralPath $script:PackageRepo -Force -Recurse -File |
            Where-Object { $_.FullName -notmatch '[\\/]\.git(?:[\\/]|$)' }) {
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
        'docs\operations.md'
        'docs\publishing.md'
        'lib\Auth.ps1'
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
                'scripts', 'docs\superpowers', 'browser-state', 'build-info.json'
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
