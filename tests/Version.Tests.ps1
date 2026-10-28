BeforeAll {
    . (Join-Path (Split-Path -Parent $PSScriptRoot) 'lib\Version.ps1')
    function New-BuildFixture {
        param([string]$Version = '0.1.0', $Metadata)
        $folder = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        [void](New-Item -ItemType Directory -Path $folder)
        if ($null -ne $Version) { Set-Content -LiteralPath (Join-Path $folder 'VERSION') -Value $Version }
        if ($null -ne $Metadata) { Set-Content -LiteralPath (Join-Path $folder 'build-info.json') -Value $Metadata }
        return $folder
    }
}

Describe 'Get-IdsBuildInfo' {
    It 'defaults a source checkout to beta without a Git dependency' {
        $build = Get-IdsBuildInfo -Root (New-BuildFixture)
        $build.version | Should -Be '0.1.0'
        $build.channel | Should -Be 'beta'
        $build.commit | Should -Be 'development'
    }

    It 'uses consistent stable package metadata' {
        $sha = 'a' * 40
        $json = (@{ version = '1.2.3'; channel = 'stable'; commit = $sha } | ConvertTo-Json)
        $build = Get-IdsBuildInfo -Root (New-BuildFixture -Version '1.2.3' -Metadata $json)
        $build.version | Should -Be '1.2.3'
        $build.channel | Should -Be 'stable'
        $build.commit | Should -Be $sha
    }

    It 'accepts beta package metadata with a commit' {
        $json = (@{ version = '0.1.0'; channel = 'beta'; commit = ('b' * 40) } | ConvertTo-Json)
        (Get-IdsBuildInfo -Root (New-BuildFixture -Metadata $json)).channel | Should -Be 'beta'
    }

    It 'accepts the local beta/development package identity' {
        $json = (@{ version = '0.1.0'; channel = 'beta'; commit = 'development' } | ConvertTo-Json)
        $build = Get-IdsBuildInfo -Root (New-BuildFixture -Metadata $json)
        $build.channel | Should -Be 'beta'
        $build.commit | Should -Be 'development'
    }

    It 'rejects <Name>' -ForEach @(
        @{ Name = 'a missing VERSION'; Version = $null; Metadata = $null }
        @{ Name = 'a prerelease VERSION'; Version = '1.0.0-beta'; Metadata = $null }
        @{ Name = 'a leading-zero VERSION'; Version = '01.0.0'; Metadata = $null }
        @{ Name = 'malformed JSON'; Version = '0.1.0'; Metadata = '{ nope' }
        @{ Name = 'a version mismatch'; Version = '0.1.0'; Metadata = '{"version":"0.2.0","channel":"stable","commit":"aaaaaaa"}' }
        @{ Name = 'an unknown channel'; Version = '0.1.0'; Metadata = '{"version":"0.1.0","channel":"preview","commit":"aaaaaaa"}' }
        @{ Name = 'a non-hex commit'; Version = '0.1.0'; Metadata = '{"version":"0.1.0","channel":"stable","commit":"not-a-sha"}' }
        @{ Name = 'a development commit in a package'; Version = '0.1.0'; Metadata = '{"version":"0.1.0","channel":"stable","commit":"development"}' }
        @{ Name = 'a missing channel'; Version = '0.1.0'; Metadata = '{"version":"0.1.0","commit":"aaaaaaa"}' }
        @{ Name = 'non-object metadata'; Version = '0.1.0'; Metadata = '[]' }
    ) {
        { Get-IdsBuildInfo -Root (New-BuildFixture -Version $Version -Metadata $Metadata) } | Should -Throw
    }
}
