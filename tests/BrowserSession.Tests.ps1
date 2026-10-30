BeforeAll {
    . (Join-Path $PSScriptRoot '..\lib\Localization.ps1')
    Set-IdsLocale 'en-GB'
    . (Join-Path $PSScriptRoot '..\lib\BrowserSession.ps1')
}

Describe 'Portal browser selection' {
    BeforeEach {
        Mock Test-Path { $true }
    }

    It 'prefers Edge in automatic mode' {
        Find-IdsBrowser | Should -Match 'msedge\.exe$'
    }

    It 'uses Chrome automatically only when Edge is absent' {
        Mock Test-Path { $LiteralPath -like '*chrome.exe' }
        Find-IdsBrowser | Should -Match 'chrome\.exe$'
    }

    It 'respects an explicit Chrome choice even when Edge is installed' {
        Find-IdsBrowser -Browser chrome | Should -Match 'chrome\.exe$'
        Should -Invoke Test-Path -Times 0 -ParameterFilter { $LiteralPath -like '*msedge.exe' }
    }

    It 'does not fall back when the explicit browser is absent' {
        Mock Test-Path { $LiteralPath -like '*chrome.exe' }
        Find-IdsBrowser -Browser edge | Should -BeNullOrEmpty
        Should -Invoke Test-Path -Times 0 -ParameterFilter { $LiteralPath -like '*chrome.exe' }
    }

    It 'rejects an absent custom executable without falling back' {
        Mock Test-Path { $false }
        { Find-IdsBrowser -Preferred 'missing.exe' } | Should -Throw '*executable was not found*'
    }

    It 'rejects conflicting custom path and browser choices' {
        { Find-IdsBrowser -Preferred 'msedge.exe' -Browser chrome } | Should -Throw '*not both*'
    }
}

Describe 'Read-only local browser policy diagnostics' {
    BeforeEach {
        Mock Get-IdsBrowserPolicies { @() }
    }

    It 'allows a browser without known local blockers' {
        { Assert-IdsBrowserPolicy -Browser edge } | Should -Not -Throw
    }

    It 'reports remote debugging and DevTools blockers with their sources' {
        Mock Get-IdsBrowserPolicies {
            [pscustomobject]@{ Name = 'RemoteDebuggingAllowed'; Value = 0; Source = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' }
            [pscustomobject]@{ Name = 'DeveloperToolsAvailability'; Value = 2; Source = 'HKCU:\SOFTWARE\Policies\Microsoft\Edge' }
        }
        $message = ''
        try { Assert-IdsBrowserPolicy -Browser edge } catch { $message = $_.Exception.Message }
        $message | Should -Match 'RemoteDebuggingAllowed at HKLM'
        $message | Should -Match 'DeveloperToolsAvailability at HKCU'
        $message | Should -Match 'edge://policy'
        $message | Should -Match 'admin consent'
        $message | Should -Match 'does not change policy'
    }

    It 'accepts nonblocking debugging values' {
        Mock Get-IdsBrowserPolicies {
            [pscustomobject]@{ Name = 'RemoteDebuggingAllowed'; Value = 1; Source = 'HKLM' }
            [pscustomobject]@{ Name = 'DeveloperToolsAvailability'; Value = 0; Source = 'HKLM' }
        }
        { Assert-IdsBrowserPolicy -Browser chrome } | Should -Not -Throw
    }

    It 'blocks a managed profile override without disclosing the managed path' {
        Mock Get-IdsBrowserPolicies {
            [pscustomobject]@{ Name = 'UserDataDir'; Value = 'C:\synthetic-sensitive-profile'; Source = 'HKLM' }
        }
        $message = ''
        try { Assert-IdsBrowserPolicy -Browser chrome } catch { $message = $_.Exception.Message }
        $message | Should -Match 'UserDataDir.*isolated'
        $message | Should -Match 'chrome://policy'
        $message | Should -Not -Match 'synthetic-sensitive-profile'
    }

    It 'only requires private browsing when Force account picker is selected' -ForEach @(
        @{ Browser = 'edge'; Name = 'InPrivateModeAvailability' }
        @{ Browser = 'chrome'; Name = 'IncognitoModeAvailability' }
    ) {
        Mock Get-IdsBrowserPolicies {
            [pscustomobject]@{ Name = $Name; Value = 1; Source = 'HKLM' }
        }
        { Assert-IdsBrowserPolicy -Browser $Browser } | Should -Not -Throw
        { Assert-IdsBrowserPolicy -Browser $Browser -ForceAccountPicker } | Should -Throw '*Force account picker*'
    }

    It 'propagates unreadable policy failures rather than treating them as allowed' {
        Mock Get-IdsBrowserPolicies { throw 'Could not read browser policies' }
        { Assert-IdsBrowserPolicy -Browser edge } | Should -Throw '*Could not read*'
    }
}

Describe 'Windows policy registry reader' {
    It 'reads only relevant mandatory machine and user settings' -Skip:(-not $IsWindows) {
        Mock Test-Path { $true }
        Mock Get-ItemProperty {
            [pscustomobject]@{ RemoteDebuggingAllowed = 0; UnrelatedSetting = 'not returned' }
        }
        $policies = @(Get-IdsBrowserPolicies -Browser chrome)
        $policies.Count | Should -Be 2
        $policies.Name | Should -Be @('RemoteDebuggingAllowed', 'RemoteDebuggingAllowed')
        $policies[0].Source | Should -Be 'HKLM:\SOFTWARE\Policies\Google\Chrome'
        $policies[1].Source | Should -Be 'HKCU:\SOFTWARE\Policies\Google\Chrome'
        Should -Invoke Get-ItemProperty -Times 2 -Exactly
    }

    It 'surfaces registry access errors without echoing arbitrary exception data' -Skip:(-not $IsWindows) {
        Mock Test-Path { $true }
        Mock Get-ItemProperty { throw 'synthetic-sensitive-error' }
        $message = ''
        try { Get-IdsBrowserPolicies -Browser edge } catch { $message = $_.Exception.Message }
        $message | Should -Match 'Could not read browser policies.*HKLM'
        $message | Should -Not -Match 'synthetic-sensitive-error'
    }
}

Describe 'Local CDP connection diagnostics' {
    BeforeEach {
        Mock Start-Sleep {}
        Mock Invoke-RestMethod { @{ webSocketDebuggerUrl = 'ws://127.0.0.1:12345/devtools/browser/synthetic' } }
        $script:ProbeDisposed = $false
        $script:Probe = [pscustomobject]@{}
        $script:Probe | Add-Member -MemberType ScriptMethod -Name Dispose -Value { $script:ProbeDisposed = $true }
        Mock Connect-IdsCdpSocket { $script:Probe }
    }

    It 'checks both HTTP readiness and the WebSocket then disposes the probe' {
        { Wait-IdsBrowserCdp -Port 12345 -Browser edge } | Should -Not -Throw
        Should -Invoke Invoke-RestMethod -Times 1 -ParameterFilter { $Uri -eq 'http://127.0.0.1:12345/json/version' }
        Should -Invoke Connect-IdsCdpSocket -Times 1
        $script:ProbeDisposed | Should -BeTrue
    }

    It 'reports WebSocket blocking separately from endpoint readiness' {
        Mock Connect-IdsCdpSocket { throw 'blocked' }
        { Wait-IdsBrowserCdp -Port 12345 -Browser chrome } | Should -Throw '*CDP WebSocket connection failed*chrome://policy*'
    }

    It 'retries an unavailable endpoint before succeeding' {
        $script:Requests = 0
        Mock Invoke-RestMethod {
            $script:Requests++
            if ($script:Requests -eq 1) { throw 'not ready' }
            @{ webSocketDebuggerUrl = 'ws://127.0.0.1:12345/devtools/browser/synthetic' }
        }
        Wait-IdsBrowserCdp -Port 12345 -Browser edge
        Should -Invoke Invoke-RestMethod -Times 2 -Exactly
    }

    It 'reports timeout without claiming that local policy checks prove access is allowed' {
        Mock Invoke-RestMethod { throw 'not listening' }
        { Wait-IdsBrowserCdp -Port 12345 -Browser edge -TimeoutSeconds 1 } |
            Should -Throw '*127.0.0.1:12345*does not prove debugging is allowed*edge://policy*'
        Should -Invoke Connect-IdsCdpSocket -Times 0
    }
}

Describe 'Portal sign-in integration' {
    BeforeEach {
        Mock Find-IdsBrowser { Join-Path $TestDrive 'msedge.exe' }
        Mock Get-IdsBrowserPolicies { @() }
        Mock Get-IdsFreePort { 12345 }
        Mock Get-IdsBrowserProfilePath { Join-Path $TestDrive 'profile with spaces' }
        Mock Start-Process { [pscustomobject]@{ Id = 123 } }
        Mock Wait-IdsBrowserCdp {}
        Mock Test-IdsBrowserAlive { $true }
        Mock Get-IdsPortalTokens { @() }
        Mock Select-IdsUsableToken {
            @{
                token = 'synthetic-token'
                claims = [pscustomobject]@{ upn = 'admin@example.invalid'; tid = 'synthetic-tenant' }
                scopes = @('synthetic-scope')
            }
        }
        Mock Invoke-RestMethod { @{} }
        Mock Close-IdsBrowser { $true }
        Mock Remove-Item {}
    }

    It 'preserves portal capture and passes explicit selection to the resolver' {
        $auth = Get-IdsTokenFromBrowser -Browser edge -StatusCallback {}
        $auth.access_token | Should -Be 'synthetic-token'
        $auth.method | Should -Be 'browser'
        $auth.refresh_token | Should -BeNullOrEmpty
        Should -Invoke Find-IdsBrowser -Times 1 -ParameterFilter { $Browser -eq 'edge' }
        Should -Invoke Get-IdsBrowserProfilePath -Times 1 -ParameterFilter { $Browser -eq 'edge' -and -not $Ephemeral }
        Should -Invoke Wait-IdsBrowserCdp -Times 1 -ParameterFilter { $Port -eq 12345 -and $Browser -eq 'edge' }
        Should -Invoke Start-Process -Times 1 -ParameterFilter {
            $ArgumentList -contains '--remote-debugging-address=127.0.0.1' -and
            $ArgumentList -contains ('--user-data-dir="' + (Join-Path $TestDrive 'profile with spaces') + '"')
        }
        Should -Invoke Close-IdsBrowser -Times 1
        Should -Invoke Remove-Item -Times 0
    }

    It 'stops before creating a profile or launching when policy blocks debugging' {
        Mock Get-IdsBrowserPolicies {
            [pscustomobject]@{ Name = 'RemoteDebuggingAllowed'; Value = 0; Source = 'HKLM' }
        }
        { Get-IdsTokenFromBrowser -StatusCallback {} } | Should -Throw '*RemoteDebuggingAllowed*'
        Should -Invoke Start-Process -Times 0
        Should -Invoke Get-IdsBrowserProfilePath -Times 0
        Should -Invoke Find-IdsBrowser -Times 1 -Exactly
    }

    It 'does not retry another browser when CDP fails and still closes the launched browser' {
        Mock Wait-IdsBrowserCdp { throw 'synthetic CDP failure' }
        { Get-IdsTokenFromBrowser -StatusCallback {} } | Should -Throw '*synthetic CDP failure*'
        Should -Invoke Find-IdsBrowser -Times 1 -Exactly
        Should -Invoke Start-Process -Times 1 -Exactly
        Should -Invoke Close-IdsBrowser -Times 1
        Should -Invoke Get-IdsPortalTokens -Times 0
    }

    It 'uses a separate Chrome profile and removes Force account picker temporary profiles' {
        Mock Find-IdsBrowser { Join-Path $TestDrive 'chrome.exe' }
        Mock Test-Path { $true }
        $auth = Get-IdsTokenFromBrowser -Browser chrome -ForceAccountPicker -StatusCallback {}
        $auth.method | Should -Be 'browser'
        Should -Invoke Get-IdsBrowserProfilePath -Times 1 -ParameterFilter { $Browser -eq 'chrome' -and $Ephemeral }
        Should -Invoke Remove-Item -Times 1 -ParameterFilter { $LiteralPath -eq (Join-Path $TestDrive 'profile with spaces') }
    }

    It 'does not launch if the selected browser is missing' {
        Mock Find-IdsBrowser { $null }
        { Get-IdsTokenFromBrowser -Browser chrome -StatusCallback {} } | Should -Throw '*selected browser (chrome) was not found*'
        Should -Invoke Start-Process -Times 0
    }

    It 'reports launch errors without waiting for CDP or switching browsers' {
        Mock Start-Process { throw 'Application control blocked startup' }
        { Get-IdsTokenFromBrowser -Browser edge -StatusCallback {} } | Should -Throw '*Could not start edge*application-control*'
        Should -Invoke Find-IdsBrowser -Times 1 -Exactly
        Should -Invoke Wait-IdsBrowserCdp -Times 0
    }
}

Describe 'Separate saved portal profiles' {
    BeforeAll {
        $savedLocalAppData = $env:LOCALAPPDATA
        $env:LOCALAPPDATA = $TestDrive
    }
    AfterAll {
        $env:LOCALAPPDATA = $savedLocalAppData
    }

    It 'preserves the existing Edge path and isolates Chrome' {
        $edge = Get-IdsBrowserProfilePath -Browser edge
        $chrome = Get-IdsBrowserProfilePath -Browser chrome
        $edge | Should -Be (Join-Path $TestDrive 'IntuneDocsStudio\browser-profile')
        $chrome | Should -Be (Join-Path $TestDrive 'IntuneDocsStudio\browser-profile-chrome')
        $edge | Should -Not -Be $chrome
        Test-Path -LiteralPath $edge | Should -BeTrue
        Test-Path -LiteralPath $chrome | Should -BeTrue
    }

    It 'clears both application profiles but not other browser data' {
        $edge = Get-IdsBrowserProfilePath -Browser edge
        $chrome = Get-IdsBrowserProfilePath -Browser chrome
        $other = Join-Path $TestDrive 'other-browser-data'
        [void](New-Item -ItemType Directory -Path $other)
        Clear-IdsBrowserProfile
        Test-Path -LiteralPath $edge | Should -BeFalse
        Test-Path -LiteralPath $chrome | Should -BeFalse
        Test-Path -LiteralPath $other | Should -BeTrue
    }

    It 'surfaces profile deletion errors' {
        Mock Test-Path { $true }
        Mock Remove-Item { throw 'Profile is locked' }
        { Clear-IdsBrowserProfile } | Should -Throw '*Profile is locked*'
    }
}

Describe 'Portal browser API and runspace wiring' {
    BeforeAll {
        $fixture = Join-Path $TestDrive 'dashboard'
        [void](New-Item -ItemType Directory -Path $fixture)
        $repo = Split-Path -Parent $PSScriptRoot
        foreach ($item in 'IntuneDocsStudio.ps1', 'VERSION', 'lib', 'web', 'locales', 'baselines') {
            Copy-Item -LiteralPath (Join-Path $repo $item) -Destination $fixture -Recurse
        }
        # Replace only the tenant/browser boundary; exercise the real HTTP and runspace path.
        Set-Content -LiteralPath (Join-Path $fixture 'lib\BrowserSession.ps1') -Value @'
function Get-IdsTokenFromBrowser {
    param([string]$Tenant, [string]$Browser, [scriptblock]$StatusCallback, [switch]$ForceAccountPicker)
    if ($Tenant -eq 'cli-probe.invalid') { throw "Synthetic CLI browser choice: $Browser" }
    if ($Tenant -eq 'blocked.invalid') { throw 'Synthetic RemoteDebuggingAllowed blocker. Check edge://policy.' }
    if ($Tenant -eq 'busy.invalid') { Start-Sleep -Seconds 2 }
    return @{
        access_token = 'synthetic-token'; refresh_token = $null; method = 'browser'
        account = "$Browser-picker-$([bool]$ForceAccountPicker)"; client_id = 'synthetic-client'
        tenant_id = 'synthetic-tenant'; expires_at = (Get-Date).AddMinutes(5); granted = @()
    }
}
function Clear-IdsBrowserProfile {}
'@
        $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
        $listener.Start()
        $port = $listener.LocalEndpoint.Port
        $listener.Stop()
        $base = "http://localhost:$port"
        $start = [Diagnostics.ProcessStartInfo]::new()
        $start.FileName = [Environment]::ProcessPath
        $start.UseShellExecute = $false
        $start.RedirectStandardOutput = $true
        $start.RedirectStandardError = $true
        foreach ($argument in @('-NoProfile', '-File', (Join-Path $fixture 'IntuneDocsStudio.ps1'),
                '-NoBrowser', '-Port', "$port", '-OutputPath', (Join-Path $fixture 'output'))) {
            $start.ArgumentList.Add($argument)
        }
        $server = [Diagnostics.Process]::new()
        $server.StartInfo = $start
        [void]$server.Start()
        $serverOutput = $server.StandardOutput.ReadToEndAsync()
        $serverError = $server.StandardError.ReadToEndAsync()
        $ready = $false
        for ($i = 0; $i -lt 40 -and -not $ready; $i++) {
            try {
                $ready = (Invoke-RestMethod "$base/api/health" -TimeoutSec 1).status -eq 'ok'
            } catch { Start-Sleep -Milliseconds 250 }
        }
        $ready | Should -BeTrue

        function Wait-TestPortalSignIn {
            for ($i = 0; $i -lt 100; $i++) {
                $status = Invoke-RestMethod "$base/api/signin/browser/status"
                if (-not $status.running) { return $status }
                Start-Sleep -Milliseconds 100
            }
            throw 'Synthetic portal sign-in did not finish.'
        }
    }
    AfterAll {
        if ($server) {
            try { $null = Invoke-RestMethod "$base/api/quit" -Method Post -TimeoutSec 2 } catch { }
            if (-not $server.WaitForExit(10000)) { $server.Kill($true) }
            $server.Dispose()
        }
    }

    It 'passes Chrome and Force account picker through the HTTP route and runspace' {
        $result = Invoke-RestMethod "$base/api/signin/browser" -Method Post -ContentType 'application/json' `
            -Body '{"browser":"chrome","forcePicker":true}'
        $result.started | Should -BeTrue
        (Wait-TestPortalSignIn).error | Should -BeNullOrEmpty
        (Invoke-RestMethod "$base/api/state").auth.account | Should -Be 'chrome-picker-True'
    }

    It 'keeps automatic selection for clients that omit the new browser property' {
        $null = Invoke-RestMethod "$base/api/signout" -Method Post
        $null = Invoke-RestMethod "$base/api/signin/browser" -Method Post -ContentType 'application/json' -Body '{}'
        $null = Wait-TestPortalSignIn
        (Invoke-RestMethod "$base/api/state").auth.account | Should -Be 'auto-picker-False'
    }

    It 'rejects invalid browser values at the HTTP boundary' -ForEach @(
        @{ Json = '{"browser":"firefox"}' }
        @{ Json = '{"browser":null}' }
        @{ Json = '{"browser":["chrome"]}' }
    ) {
        $response = Invoke-WebRequest "$base/api/signin/browser" -Method Post -ContentType 'application/json' `
            -Body $Json -SkipHttpErrorCheck
        $response.StatusCode | Should -Be 400
        ($response.Content | ConvertFrom-Json).error | Should -Match 'Select auto, edge or chrome'
    }

    It 'returns worker diagnostics to the dashboard unchanged' {
        $null = Invoke-RestMethod "$base/api/signout" -Method Post
        $null = Invoke-RestMethod "$base/api/signin/browser" -Method Post -ContentType 'application/json' `
            -Body '{"browser":"edge","tenant":"blocked.invalid"}'
        (Wait-TestPortalSignIn).error | Should -Be 'Synthetic RemoteDebuggingAllowed blocker. Check edge://policy.'
    }

    It 'rejects a second sign-in and profile deletion while a sign-in is running' {
        $null = Invoke-RestMethod "$base/api/signin/browser" -Method Post -ContentType 'application/json' `
            -Body '{"browser":"edge","tenant":"busy.invalid"}'
        $second = Invoke-WebRequest "$base/api/signin/browser" -Method Post -ContentType 'application/json' `
            -Body '{"browser":"chrome"}' -SkipHttpErrorCheck
        $second.StatusCode | Should -Be 409
        $forget = Invoke-WebRequest "$base/api/signin/browser/forget" -Method Post -SkipHttpErrorCheck
        $forget.StatusCode | Should -Be 409
        $null = Wait-TestPortalSignIn
        (Invoke-RestMethod "$base/api/state").auth.account | Should -Be 'edge-picker-False'
    }

    It 'passes the headless PortalBrowser option to portal capture without contacting a tenant' {
        $cliStart = [Diagnostics.ProcessStartInfo]::new()
        $cliStart.FileName = [Environment]::ProcessPath
        $cliStart.UseShellExecute = $false
        $cliStart.RedirectStandardOutput = $true
        $cliStart.RedirectStandardError = $true
        foreach ($argument in @('-NoProfile', '-File', (Join-Path $fixture 'IntuneDocsStudio.ps1'),
                '-Export', '-Method', 'browser', '-PortalBrowser', 'chrome', '-Tenant', 'cli-probe.invalid',
                '-OutputPath', (Join-Path $fixture 'cli-output'))) {
            $cliStart.ArgumentList.Add($argument)
        }
        $cli = [Diagnostics.Process]::new()
        $cli.StartInfo = $cliStart
        try {
            [void]$cli.Start()
            $stdout = $cli.StandardOutput.ReadToEndAsync()
            $stderr = $cli.StandardError.ReadToEndAsync()
            if (-not $cli.WaitForExit(10000)) {
                $cli.Kill($true)
                throw 'CLI browser selection check timed out.'
            }
            $cli.ExitCode | Should -Not -Be 0
            ($stdout.Result + $stderr.Result) | Should -Match 'Synthetic CLI browser choice: chrome'
        } finally { $cli.Dispose() }
    }
}
