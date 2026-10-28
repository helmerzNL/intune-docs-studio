BeforeAll {
    $repo = Split-Path -Parent $PSScriptRoot
    $windowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $powerShell7 = (Get-Command pwsh -CommandType Application | Select-Object -First 1).Source

    function Invoke-RuntimeProcess {
        param([string]$Executable, [string[]]$Arguments, [string]$SearchPath)
        $start = New-Object Diagnostics.ProcessStartInfo
        $start.FileName = $Executable
        $start.UseShellExecute = $false
        $start.CreateNoWindow = $true
        $start.RedirectStandardOutput = $true
        $start.RedirectStandardError = $true
        $start.RedirectStandardInput = $true
        if ($Executable -eq $env:ComSpec) {
            $start.Arguments = '/d /s /c "' + $Arguments[3] + '"'
        } else {
            foreach ($argument in $Arguments) { [void]$start.ArgumentList.Add($argument) }
        }
        if ($SearchPath) { $start.Environment['PATH'] = $SearchPath }
        $process = New-Object Diagnostics.Process
        $process.StartInfo = $start
        try {
            [void]$process.Start()
            $process.StandardInput.Close()
            $stdout = $process.StandardOutput.ReadToEndAsync()
            $stderr = $process.StandardError.ReadToEndAsync()
            if (-not $process.WaitForExit(30000)) {
                $process.Kill($true)
                throw 'Runtime check did not exit within 30 seconds.'
            }
            return @{ ExitCode = $process.ExitCode; Output = $stdout.Result + $stderr.Result }
        } finally { $process.Dispose() }
    }

    function New-LauncherFixture {
        param([string]$Name)
        $folder = Join-Path $TestDrive $Name
        [void](New-Item -ItemType Directory -Path $folder)
        Copy-Item -LiteralPath (Join-Path $repo 'Start-IntuneDocs.cmd') -Destination $folder
        Set-Content -LiteralPath (Join-Path $folder 'IntuneDocsStudio.ps1') -Value @'
param([string]$OutputPath)
@{ major = $PSVersionTable.PSVersion.Major; outputPath = $OutputPath } |
    ConvertTo-Json | Set-Content -LiteralPath (Join-Path $PSScriptRoot 'started.json')
exit 17
'@
        return $folder
    }
}

Describe 'PowerShell runtime requirements' {
    It 'refuses a direct Windows PowerShell launch before loading the application' {
        $result = Invoke-RuntimeProcess -Executable $windowsPowerShell -Arguments @(
            '-NoProfile', '-File', (Join-Path $repo 'IntuneDocsStudio.ps1'), '-NoBrowser', '-Port', 'invalid'
        )
        $result.ExitCode | Should -Not -Be 0 -Because $result.Output
        $result.Output | Should -Match '7\.0'
        $result.Output | Should -Not -Match 'ParserError|ParameterBinding'
    }

    It 'stops with installation guidance when only Windows PowerShell is available' {
        $folder = New-LauncherFixture 'missing runtime'
        $searchPath = "$(Join-Path $env:SystemRoot 'System32');$(Split-Path -Parent $windowsPowerShell)"
        $result = Invoke-RuntimeProcess -Executable $env:ComSpec -Arguments @(
            '/d', '/s', '/c', "`"$(Join-Path $folder 'Start-IntuneDocs.cmd')`" <nul"
        ) -SearchPath $searchPath
        $result.ExitCode | Should -Not -Be 0 -Because $result.Output
        $result.Output | Should -Match 'winget install --id Microsoft\.PowerShell --source winget'
        $result.Output | Should -Match 'winget upgrade --id Microsoft\.PowerShell --source winget'
        $result.Output | Should -Match 'https://aka\.ms/powershell-release'
        (Test-Path -LiteralPath (Join-Path $folder 'started.json')) | Should -BeFalse
    }

    It 'runs under PowerShell 7 and forwards quoted arguments and the exit code' {
        $folder = New-LauncherFixture 'installed runtime'
        $searchPath = "$(Split-Path -Parent $powerShell7);$(Join-Path $env:SystemRoot 'System32')"
        $result = Invoke-RuntimeProcess -Executable $env:ComSpec -Arguments @(
            '/d', '/s', '/c', "`"$(Join-Path $folder 'Start-IntuneDocs.cmd')`" -OutputPath `"docs target`" <nul"
        ) -SearchPath $searchPath
        $result.ExitCode | Should -Be 17 -Because $result.Output
        $started = Get-Content -LiteralPath (Join-Path $folder 'started.json') -Raw | ConvertFrom-Json
        $started.major | Should -BeGreaterOrEqual 7
        $started.outputPath | Should -Be 'docs target'
    }

    Context 'local server identity' {
        BeforeAll {
            function Invoke-LocalServer {
                param([string]$Name, $Metadata, [scriptblock]$Check)
                $folder = Join-Path $TestDrive $Name
                [void](New-Item -ItemType Directory -Path $folder)
                foreach ($item in 'IntuneDocsStudio.ps1', 'VERSION', 'lib', 'web') {
                    Copy-Item -LiteralPath (Join-Path $repo $item) -Destination $folder -Recurse
                }
                if ($Metadata) { Set-Content -LiteralPath (Join-Path $folder 'build-info.json') -Value $Metadata }
                $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
                $listener.Start(); $port = $listener.LocalEndpoint.Port; $listener.Stop()
                $process = Start-Process -FilePath $powerShell7 -PassThru -WindowStyle Hidden -ArgumentList @(
                    '-NoProfile', '-File', (Join-Path $folder 'IntuneDocsStudio.ps1'), '-NoBrowser', '-Port', $port,
                    '-OutputPath', (Join-Path $folder 'out'))
                try {
                    $base = "http://localhost:$port"
                    $ready = $false
                    for ($i = 0; $i -lt 60 -and -not $ready; $i++) {
                        try { [void](Invoke-RestMethod "$base/api/health" -TimeoutSec 2); $ready = $true } catch { Start-Sleep -Milliseconds 500 }
                    }
                    $ready | Should -BeTrue
                    & $Check $base
                } finally {
                    try { [void](Invoke-RestMethod "$base/api/quit" -Method Post -TimeoutSec 5) } catch { }
                    if (-not $process.WaitForExit(10000)) { Stop-Process -Id $process.Id -Force }
                }
            }
        }

        It 'serves safe unauthenticated health and shared development identity' {
            Invoke-LocalServer -Name 'dev' -Check {
                param($base)
                $health = Invoke-WebRequest "$base/api/health" -UseBasicParsing
                $health.StatusCode | Should -Be 200
                ($health.Content | ConvertFrom-Json -AsHashtable).Keys | Should -Be @('status')
                ($health.Content | ConvertFrom-Json).status | Should -Be 'ok'
                $version = Invoke-RestMethod "$base/api/version"
                $version.channel | Should -Be 'beta'
                $version.commit | Should -Be 'development'
                $state = Invoke-RestMethod "$base/api/state"
                $state.build.version | Should -Be $version.version
                $state.build.channel | Should -Be 'beta'
            }
        }

        It 'serves stable identity from package metadata' {
            $json = (@{ version = '0.1.0'; channel = 'stable'; commit = ('c' * 40) } | ConvertTo-Json)
            Invoke-LocalServer -Name 'stable' -Metadata $json -Check {
                param($base)
                $version = Invoke-RestMethod "$base/api/version"
                $version.channel | Should -Be 'stable'
                $version.commit | Should -Be ('c' * 40)
                (Invoke-RestMethod "$base/api/state").build.channel | Should -Be 'stable'
            }
        }

        It 'refuses to start with inconsistent package metadata' {
            $folder = Join-Path $TestDrive 'bad'
            [void](New-Item -ItemType Directory -Path $folder)
            foreach ($item in 'IntuneDocsStudio.ps1', 'VERSION', 'lib', 'web') {
                Copy-Item -LiteralPath (Join-Path $repo $item) -Destination $folder -Recurse
            }
            Set-Content -LiteralPath (Join-Path $folder 'build-info.json') -Value '{"version":"9.9.9","channel":"stable","commit":"aaaaaaa"}'
            $result = Invoke-RuntimeProcess -Executable $powerShell7 -Arguments @(
                '-NoProfile', '-File', (Join-Path $folder 'IntuneDocsStudio.ps1'), '-NoBrowser', '-Port', '1')
            $result.ExitCode | Should -Not -Be 0
            $result.Output | Should -Match 'build-info'
        }
    }
}
