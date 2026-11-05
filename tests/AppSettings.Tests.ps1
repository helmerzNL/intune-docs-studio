BeforeAll {
    $repo = Split-Path -Parent $PSScriptRoot
    foreach ($module in 'Http', 'BaselinePacks', 'AssessmentCollection', 'AssessmentSettings', 'BaselineArchive', 'AssessmentRules', 'AssessmentReports', 'Assessment', 'AssessmentApi', 'AppSettings') {
        $file = Join-Path $repo "lib\$module.ps1"
        if (Test-Path $file) { . $file }
    }
    function New-SettingsRequest {
        param([string]$Text = '{}', [string]$Origin = 'http://localhost:7654', [string]$HostName = 'localhost:7654',
            [string]$Type = 'application/json', [long]$Length = -1)
        [pscustomobject]@{
            Url = [uri]'http://localhost:7654/api/settings'
            Headers = @{ Origin = $Origin; Host = $HostName }
            ContentType = $Type; ContentLength64 = $Length
            InputStream = [IO.MemoryStream]::new([Text.Encoding]::UTF8.GetBytes($Text))
        }
    }
    function New-SettingsJson {
        param($Good = 85, $Attention = 60, $Coverage = 75)
        return ConvertTo-Json -Compress @{ verdictThresholds = @{ good = $Good; attention = $Attention; coverage = $Coverage } }
    }
}

Describe 'Application settings validation' {
    It 'defaults to the documented verdict thresholds' {
        $defaults = Get-IdsDefaultAppSettings
        $defaults.verdictThresholds.good | Should -Be 90
        $defaults.verdictThresholds.attention | Should -Be 70
        $defaults.verdictThresholds.coverage | Should -Be 80
        @($defaults.Keys) | Should -Be @('verdictThresholds')
    }
    It 'accepts whole numbers from 0 to 100 with attention below good' {
        $settings = ConvertTo-IdsAppSettings @{ verdictThresholds = @{ good = 100; attention = 0; coverage = 0 } }
        $settings.verdictThresholds.good | Should -Be 100
        $settings.verdictThresholds.attention | Should -Be 0
        $settings.verdictThresholds.coverage | Should -Be 0
        $settings.verdictThresholds.good | Should -BeOfType [int]
    }
    It 'rejects out-of-range, fractional, textual, boolean and null values' {
        foreach ($value in -1, 101, 85.5, '85', $true, $null) {
            { ConvertTo-IdsAppSettings @{ verdictThresholds = @{ good = $value; attention = 10; coverage = 50 } } } |
                Should -Throw -ExceptionType ([ArgumentException])
        }
    }
    It 'requires the attention threshold to be lower than the good threshold' {
        foreach ($attention in 80, 81) {
            { ConvertTo-IdsAppSettings @{ verdictThresholds = @{ good = 80; attention = $attention; coverage = 50 } } } |
                Should -Throw -ExceptionType ([ArgumentException])
        }
    }
    It 'rejects unknown, missing and differently cased fields' {
        $cases = @(
            @{ verdictThresholds = @{ good = 90; attention = 70; coverage = 80 }; extra = 1 },
            @{ verdictThresholds = @{ good = 90; attention = 70; coverage = 80; extra = 1 } },
            @{ verdictThresholds = @{ good = 90; attention = 70 } },
            @{ VerdictThresholds = @{ good = 90; attention = 70; coverage = 80 } },
            @{},
            @{ verdictThresholds = 'high' }
        )
        foreach ($case in $cases) {
            { ConvertTo-IdsAppSettings $case } | Should -Throw -ExceptionType ([ArgumentException])
        }
        { ConvertTo-IdsAppSettings 'text' } | Should -Throw -ExceptionType ([ArgumentException])
    }
}

Describe 'Application settings persistence' {
    BeforeEach {
        $folder = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $state = @{ Config = @{ Port = 7654; SettingsPath = (Join-Path $folder 'nested\settings.json') } }
    }
    It 'returns defaults when no settings file exists' {
        (Get-IdsAppSettings $state).verdictThresholds.good | Should -Be 90
        Test-Path $state.Config.SettingsPath | Should -BeFalse
    }
    It 'saves validated settings atomically and reads them back' {
        $saved = Set-IdsAppSettings -State $state -Settings @{ verdictThresholds = @{ good = 85; attention = 60; coverage = 75 } }
        $saved.verdictThresholds.good | Should -Be 85
        $loaded = Get-IdsAppSettings $state
        $loaded.verdictThresholds.good | Should -Be 85
        $loaded.verdictThresholds.attention | Should -Be 60
        $loaded.verdictThresholds.coverage | Should -Be 75
        @(Get-ChildItem (Split-Path $state.Config.SettingsPath) -Filter '*.tmp').Count | Should -Be 0
        $json = Get-Content -Raw $state.Config.SettingsPath | ConvertFrom-Json -AsHashtable
        @($json.Keys) | Should -Be @('verdictThresholds')
    }
    It 'keeps the previous file when invalid settings are submitted' {
        $null = Set-IdsAppSettings -State $state -Settings @{ verdictThresholds = @{ good = 85; attention = 60; coverage = 75 } }
        { Set-IdsAppSettings -State $state -Settings @{ verdictThresholds = @{ good = 50; attention = 60; coverage = 75 } } } |
            Should -Throw -ExceptionType ([ArgumentException])
        (Get-IdsAppSettings $state).verdictThresholds.good | Should -Be 85
    }
    It 'falls back to defaults with a warning for corrupt, invalid or oversized files' {
        $null = [IO.Directory]::CreateDirectory((Split-Path $state.Config.SettingsPath))
        $contents = @(
            '{"verdictThresholds":',
            '{"verdictThresholds":{"good":50,"attention":60,"coverage":75}}',
            ('{"verdictThresholds":{"good":85,"attention":60,"coverage":75}}' + (' ' * 70KB))
        )
        foreach ($content in $contents) {
            [IO.File]::WriteAllText($state.Config.SettingsPath, $content)
            $output = @(Get-IdsAppSettings $state 3>&1)
            $warnings = @($output | Where-Object { $_ -is [Management.Automation.WarningRecord] })
            $settings = @($output | Where-Object { $_ -isnot [Management.Automation.WarningRecord] })[0]
            $settings.verdictThresholds.good | Should -Be 90
            $warnings.Count | Should -Be 1
        }
    }
    It 'refuses to save without a settings location' {
        { Set-IdsAppSettings -State @{ Config = @{} } -Settings (Get-IdsDefaultAppSettings) } |
            Should -Throw -ExceptionType ([InvalidOperationException])
    }
}

Describe 'Application settings local route' {
    BeforeEach {
        $folder = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $state = @{ Config = @{ Port = 7654; SettingsPath = (Join-Path $folder 'settings.json') } }
    }
    It 'ignores unrelated paths and methods' {
        (Invoke-IdsSettingsRoute GET /api/state (New-SettingsRequest) $state).handled | Should -BeFalse
        (Invoke-IdsSettingsRoute DELETE /api/settings (New-SettingsRequest) $state).handled | Should -BeFalse
    }
    It 'returns the current settings with the defaults' {
        $response = Invoke-IdsSettingsRoute GET /api/settings (New-SettingsRequest) $state
        $response.handled | Should -BeTrue
        $response.status | Should -Be 200
        $response.body.settings.verdictThresholds.good | Should -Be 90
        $response.body.defaults.verdictThresholds.attention | Should -Be 70
    }
    It 'saves valid settings and returns them' {
        $response = Invoke-IdsSettingsRoute POST /api/settings (New-SettingsRequest (New-SettingsJson)) $state
        $response.status | Should -Be 200
        $response.body.settings.verdictThresholds.good | Should -Be 85
        $response.body.defaults.verdictThresholds.good | Should -Be 90
        (Invoke-IdsSettingsRoute GET /api/settings (New-SettingsRequest) $state).body.settings.verdictThresholds.coverage |
            Should -Be 75
    }
    It 'requires a same-origin request to change settings' {
        foreach ($request in (New-SettingsRequest (New-SettingsJson) -Origin 'http://evil.invalid'),
            (New-SettingsRequest (New-SettingsJson) -HostName 'evil.invalid:7654'),
            (New-SettingsRequest (New-SettingsJson) -Origin '')) {
            $response = Invoke-IdsSettingsRoute POST /api/settings $request $state
            $response.status | Should -Be 403
            $response.body.error | Should -Not -BeNullOrEmpty
        }
        Test-Path $state.Config.SettingsPath | Should -BeFalse
    }
    It 'rejects other content types, oversized bodies and invalid settings without saving' {
        (Invoke-IdsSettingsRoute POST /api/settings (New-SettingsRequest (New-SettingsJson) -Type 'text/plain') $state).status |
            Should -Be 415
        (Invoke-IdsSettingsRoute POST /api/settings (New-SettingsRequest (New-SettingsJson) -Length 5000) $state).status |
            Should -Be 413
        foreach ($text in '{"verdictThresholds":', (New-SettingsJson -Good 60 -Attention 60), (New-SettingsJson -Coverage 101),
            '{"verdictThresholds":{"good":90,"attention":70,"coverage":80},"token":"x"}') {
            $response = Invoke-IdsSettingsRoute POST /api/settings (New-SettingsRequest $text) $state
            $response.status | Should -Be 400
            $response.body.error | Should -Not -BeNullOrEmpty
        }
        Test-Path $state.Config.SettingsPath | Should -BeFalse
    }
    It 'reports a save failure without exposing the exception' {
        $null = [IO.Directory]::CreateDirectory($state.Config.SettingsPath)
        $response = Invoke-IdsSettingsRoute POST /api/settings (New-SettingsRequest (New-SettingsJson)) $state
        $response.status | Should -Be 500
        $response.body.error | Should -BeExactly (Get-IdsText -Key 'settings.save_failed')
    }
}
