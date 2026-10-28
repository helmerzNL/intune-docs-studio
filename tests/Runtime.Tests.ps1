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
                param([string]$Name, $Metadata, [scriptblock]$Check, [scriptblock]$Configure)
                $folder = Join-Path $TestDrive $Name
                [void](New-Item -ItemType Directory -Path $folder)
                foreach ($item in 'IntuneDocsStudio.ps1', 'VERSION', 'lib', 'web', 'baselines') {
                    Copy-Item -LiteralPath (Join-Path $repo $item) -Destination $folder -Recurse
                }
                if ($Configure) { & $Configure $folder }
                if ($Metadata) { Set-Content -LiteralPath (Join-Path $folder 'build-info.json') -Value $Metadata }
                $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
                $listener.Start(); $port = $listener.LocalEndpoint.Port; $listener.Stop()
                $process = Start-Process -FilePath $powerShell7 -PassThru -WindowStyle Hidden -ArgumentList @(
                    '-NoProfile', '-File', ('"' + (Join-Path $folder 'IntuneDocsStudio.ps1') + '"'), '-NoBrowser', '-Port', $port,
                    '-OutputPath', ('"' + (Join-Path $TestDrive "$Name-export") + '"'))
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

            It 'blocks every identity and stop route during assessments and invalidates results on sign-out' {
                Invoke-LocalServer -Name 'assessment lifecycle' -Configure {
                    param($folder)
                    Add-Content "$folder\lib\Auth.ps1" @'
function Get-IdsTokenFromAzureCli { return @{ transport = 'token'; access_token = 'SYNTHETIC-SECRET'; tenant_id = 'synthetic-tenant' } }
function Start-IdsDeviceCode { return @{ device_code = 'synthetic-code'; user_code = 'TEST'; verification_uri = 'https://example.invalid'; message = 'Synthetic'; interval = 1 } }
function Test-IdsDeviceCode { return @{ status = 'ok'; auth = (Get-IdsTokenFromAzureCli) } }
'@
                    Add-Content "$folder\lib\Graph.ps1" @'
function Invoke-IdsGraphRaw {
    param($Uri)
    if ($Uri -match '/organization') {
            Start-Sleep -Seconds 3
            return @{ value = @(@{ id = 'synthetic-tenant'; displayName = 'Synthetic' }) }
    }
    return @{ value = @() }
}
'@
                } -Check {
                    param($base)
                    $headers = @{ Origin = $base }
                    [void](Invoke-RestMethod "$base/api/signin/azurecli" -Method Post)
                    [void](Invoke-RestMethod "$base/api/signin/devicecode" -Method Post -Body '{}' -ContentType application/json)
                    $packs = Invoke-RestMethod "$base/api/assessment/packs"
                    $body = @{ packIds = @($packs.packs[0].selectionId)
                        context = @{ platforms = @($packs.packs[0].platform) }
                        outputPath = (Join-Path $TestDrive 'assessment reports') } | ConvertTo-Json -Depth 10
                    $start = Invoke-WebRequest "$base/api/assessment" -Method Post -Headers $headers -Body $body -ContentType application/json -SkipHttpErrorCheck
                    $start.StatusCode | Should -Be 202 -Because $start.Content
                    foreach ($path in 'signin/interactive', 'signin/devicecode', 'signin/azurecli', 'signin/mggraph',
                        'signin/browser', 'signin/browser/forget', 'signout', 'quit', 'export', 'assessment') {
                        $response = Invoke-WebRequest "$base/api/$path" -Method Post -Headers $headers -Body '{}' -ContentType application/json -SkipHttpErrorCheck
                        $response.StatusCode | Should -Be 409 -Because $path
                    }
                    (Invoke-WebRequest "$base/api/signin/devicecode/poll" -SkipHttpErrorCheck).StatusCode | Should -Be 409
                    $callback = Invoke-WebRequest "$base/?code=synthetic&state=stale" -MaximumRedirection 0 -SkipHttpErrorCheck -ErrorAction SilentlyContinue
                    $callback.Headers.Location | Should -Be '/?signin=busy'
                    $deadline = (Get-Date).AddSeconds(30)
                    do {
                        Start-Sleep -Milliseconds 100
                        $progress = Invoke-RestMethod "$base/api/assessment"
                    } while ($progress.running -and (Get-Date) -lt $deadline)
                    $progress.done | Should -BeTrue
                    $progress.partial | Should -BeTrue
                    $progress.error | Should -BeNullOrEmpty
                    $result = Invoke-RestMethod "$base/api/assessment/results"
                    $result.tenant.id | Should -Be 'synthetic-tenant'
                    ($result | ConvertTo-Json -Depth 64) | Should -Not -Match 'SYNTHETIC-SECRET|access_token|rawSettings'
                    [void](Invoke-RestMethod "$base/api/signout" -Method Post)
                    (Invoke-WebRequest "$base/api/assessment/results" -SkipHttpErrorCheck).StatusCode | Should -Be 401
                    (Invoke-RestMethod "$base/api/signin/devicecode/poll").status | Should -Be 'none'
                    [void](Invoke-RestMethod "$base/api/signin/azurecli" -Method Post)
                    (Invoke-WebRequest "$base/api/assessment/results" -SkipHttpErrorCheck).StatusCode | Should -Be 404
                }
            }

        It 'completes every sign-in transport and invalidates pending OAuth on reset and profile forget' {
            Invoke-LocalServer -Name 'signin-transports' -Configure {
                param($folder)
                Add-Content "$folder\lib\Auth.ps1" @'
function New-SyntheticAuth {
    param($Method)
    return @{ transport = 'token'; access_token = 'SYNTHETIC-SECRET'; tenant_id = 'synthetic-tenant'; method = $Method }
}
function Get-IdsTokenFromAzureCli { New-SyntheticAuth azurecli }
function Connect-IdsMgGraph { New-SyntheticAuth mggraph }
function Complete-IdsAuthCode { New-SyntheticAuth interactive }
function Start-IdsDeviceCode { return @{ device_code = 'synthetic'; user_code = 'TEST'; verification_uri = 'https://example.invalid'; message = 'Synthetic'; interval = 1 } }
function Test-IdsDeviceCode { return @{ status = 'ok'; auth = (New-SyntheticAuth devicecode) } }
'@
                Add-Content "$folder\lib\BrowserSession.ps1" @'
function Get-IdsTokenFromBrowser {
    Start-Sleep -Milliseconds 300
    return @{ transport = 'token'; access_token = 'SYNTHETIC-SECRET'; tenant_id = 'synthetic-tenant'; method = 'browser' }
}
function Clear-IdsBrowserProfile { }
'@
            } -Check {
                param($base)
                foreach ($method in 'azurecli', 'mggraph') {
                    [void](Invoke-RestMethod "$base/api/signin/$method" -Method Post -Body '{}' -ContentType application/json)
                    (Invoke-RestMethod "$base/api/state").auth.method | Should -Be $method
                }
                $signin = Invoke-RestMethod "$base/api/signin/interactive" -Method Post -Body '{}' -ContentType application/json
                $nonce = [regex]::Match($signin.url, '[?&]state=([^&]+)').Groups[1].Value
                $callback = Invoke-WebRequest "$base/?code=synthetic&state=$nonce" -MaximumRedirection 0 -SkipHttpErrorCheck -ErrorAction SilentlyContinue
                $callback.Headers.Location | Should -Be '/?signin=ok'
                (Invoke-RestMethod "$base/api/state").auth.method | Should -Be 'interactive'
                [void](Invoke-RestMethod "$base/api/signin/devicecode" -Method Post -Body '{}' -ContentType application/json)
                (Invoke-RestMethod "$base/api/signin/devicecode/poll").status | Should -Be 'ok'
                (Invoke-RestMethod "$base/api/state").auth.method | Should -Be 'devicecode'
                [void](Invoke-RestMethod "$base/api/signin/browser" -Method Post -Body '{}' -ContentType application/json)
                $deadline = (Get-Date).AddSeconds(10)
                do {
                    Start-Sleep -Milliseconds 50
                    $browser = Invoke-RestMethod "$base/api/signin/browser/status"
                } while ($browser.running -and (Get-Date) -lt $deadline)
                $browser.error | Should -BeNullOrEmpty
                $browser.done | Should -BeTrue
                (Invoke-RestMethod "$base/api/state").auth.method | Should -Be 'browser'
                [void](Invoke-RestMethod "$base/api/signin/browser/forget" -Method Post)
                (Invoke-RestMethod "$base/api/state").auth.connected | Should -BeFalse
                $signin = Invoke-RestMethod "$base/api/signin/interactive" -Method Post -Body '{}' -ContentType application/json
                $nonce = [regex]::Match($signin.url, '[?&]state=([^&]+)').Groups[1].Value
                [void](Invoke-RestMethod "$base/api/signout" -Method Post)
                $callback = Invoke-WebRequest "$base/?code=synthetic&state=$nonce" -MaximumRedirection 0 -SkipHttpErrorCheck -ErrorAction SilentlyContinue
                $callback.Headers.Location | Should -Be '/?signin=state-mismatch'
                (Invoke-RestMethod "$base/api/state").auth.connected | Should -BeFalse
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

        It 'releases the listener when the server pipeline is stopped like Ctrl+C' {
            $folder = Join-Path $TestDrive 'pipeline-stop'
            [void](New-Item -ItemType Directory $folder)
            foreach ($item in 'IntuneDocsStudio.ps1', 'VERSION', 'lib', 'web', 'baselines') {
                Copy-Item "$repo\$item" $folder -Recurse
            }
            Add-Content "$folder\lib\Auth.ps1" @'
function Get-IdsTokenFromAzureCli { return @{ transport = 'token'; tenant_id = 'synthetic-tenant' } }
'@
            Add-Content "$folder\lib\Graph.ps1" @'
function Invoke-IdsGraphRaw { Start-Sleep -Seconds 30; throw 'synthetic stop' }
'@
            $socket = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
            $socket.Start(); $port = $socket.LocalEndpoint.Port; $socket.Stop()
            $ps = [powershell]::Create()
            try {
                [void]$ps.AddCommand("$folder\IntuneDocsStudio.ps1").AddParameter('NoBrowser').AddParameter('Port', $port).
                    AddParameter('OutputPath', "$TestDrive\pipeline-export")
                $handle = $ps.BeginInvoke()
                $ready = $false
                for ($i = 0; $i -lt 40 -and -not $ready; $i++) {
                    try { [void](Invoke-RestMethod "http://localhost:$port/api/health" -TimeoutSec 1); $ready = $true }
                    catch { Start-Sleep -Milliseconds 100 }
                }
                $ready | Should -BeTrue
                $base = "http://localhost:$port"
                [void](Invoke-RestMethod "$base/api/signin/azurecli" -Method Post)
                $pack = (Invoke-RestMethod "$base/api/assessment/packs").packs[0]
                $body = @{ packIds = @($pack.selectionId); context = @{ platforms = @($pack.platform) }
                    outputPath = "$TestDrive\pipeline-reports" } | ConvertTo-Json
                [void](Invoke-RestMethod "$base/api/assessment" -Method Post -Headers @{ Origin = $base } -Body $body -ContentType application/json)
                (Invoke-RestMethod "$base/api/assessment").running | Should -BeTrue
                $ps.Stop()
                $handle.IsCompleted | Should -BeTrue
                Test-Path "$TestDrive\pipeline-reports" | Should -BeFalse
                $listener = [Net.HttpListener]::new()
                try {
                    $listener.Prefixes.Add("http://localhost:$port/")
                    { $listener.Start() } | Should -Not -Throw
                } finally { $listener.Close() }
            } finally { $ps.Dispose() }
        }
    }
}

Describe 'Shared runtime job and reset guards' {
    BeforeAll {
        . "$repo\lib\Assessment.ps1"
        $tokens = $null; $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile("$repo\IntuneDocsStudio.ps1", [ref]$tokens, [ref]$errors)
        foreach ($name in 'Start-IdsExportJob', 'Start-IdsBrowserSignIn', 'Reset-IdsSessionState', 'Clear-IdsFinishedJob') {
            $definition = $ast.Find({ param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
            }, $true)
            . ([scriptblock]::Create($definition.Extent.Text))
        }
    }
    BeforeEach {
        $State = [hashtable]::Synchronized(@{
            Auth = @{ tenant_id = 'synthetic-old' }; Pending = @{ deviceCode = 'synthetic-pending' }
            Browser = @{ running = $false; status = ''; error = $null }
            Export = @{ running = $false; log = [Collections.ArrayList]::new(); summary = @{ root = 'synthetic-old' }; done = $true }
            Config = @{ OutputPath = 'old'; DefaultOutputPath = 'default'; Tenant = 'old'; DefaultTenant = 'organizations' }
        })
        Initialize-IdsAssessment $State
    }
    It 'rejects direct export and portal starts during <Kind> without altering the session' -TestCases @(
        @{ Kind = 'Assessment' }, @{ Kind = 'Export' }
    ) {
        param($Kind)
        $State[$Kind].running = $true
        Start-IdsExportJob @{} | Should -BeFalse
        Start-IdsBrowserSignIn 'synthetic-new' | Should -BeFalse
        { Reset-IdsSessionState } | Should -Throw '*running*'
        $State.Auth.tenant_id | Should -Be 'synthetic-old'
        $State.Pending.deviceCode | Should -Be 'synthetic-pending'
    }
    It 'clears cross-tenant state, pending sign-ins and assessment evidence on reset' {
        $State.Assessment.result = @{ tenant = 'synthetic-old' }
        $State.Assessment.reportPaths = @{ root = 'old' }
        $State.Assessment.resultEpoch = $State.Assessment.epoch
        Reset-IdsSessionState
        $State.Assessment.epoch | Should -Be 1
        $State.Assessment.result | Should -BeNullOrEmpty
        $State.Assessment.reportPaths | Should -BeNullOrEmpty
        $State.Pending | Should -BeNullOrEmpty
        $State.Auth | Should -BeNullOrEmpty
        $State.Export.summary | Should -BeNullOrEmpty
        $State.Config.OutputPath | Should -Be 'default'
    }
    It 'preserves an unfinished portal handle and identity while the worker is unwinding' {
        $job = @{ handle = @{ IsCompleted = $false } }
        $State.Browser.job = $job
        Start-IdsExportJob @{} | Should -BeFalse
        Start-IdsBrowserSignIn 'synthetic-new' | Should -BeFalse
        { Reset-IdsSessionState } | Should -Throw '*running*'
        [object]::ReferenceEquals($State.Browser.job, $job) | Should -BeTrue
        $State.Auth.tenant_id | Should -Be 'synthetic-old'
        $State.Pending.deviceCode | Should -Be 'synthetic-pending'
        Clear-IdsFinishedJob
        [object]::ReferenceEquals($State.Browser.job, $job) | Should -BeTrue
    }
}
