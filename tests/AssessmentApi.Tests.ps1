BeforeAll {
    $repo = Split-Path -Parent $PSScriptRoot
    foreach ($module in 'Http', 'BaselinePacks', 'AssessmentRules', 'AssessmentReports', 'Assessment', 'AssessmentApi') {
        $file = Join-Path $repo "lib\$module.ps1"
        if (Test-Path $file) { . $file }
    }
    . (Join-Path $PSScriptRoot 'TestHelpers\Assessment.ps1')
    function New-ApiRequest {
        param([string]$Text = '{}', [string]$Origin = 'http://localhost:7654', [string]$HostName = 'localhost:7654',
            [string]$Type = 'application/json', [long]$Length = -1)
        [pscustomobject]@{
            Url = [uri]'http://localhost:7654/api/assessment'
            Headers = @{ Origin = $Origin; Host = $HostName }
            ContentType = $Type; ContentLength64 = $Length
            InputStream = [IO.MemoryStream]::new([Text.Encoding]::UTF8.GetBytes($Text))
        }
    }
}

Describe 'Strict assessment JSON input' {
    It 'rejects malformed JSON rather than treating it as an empty request' {
        $request = [pscustomobject]@{
            ContentLength64 = -1
            InputStream = [IO.MemoryStream]::new([Text.Encoding]::UTF8.GetBytes('{"broken":'))
        }
        { Read-IdsAssessmentRequestJson -Request $request -MaxBytes 65536 } |
            Should -Throw '*Invalid JSON request*'
    }
    It 'counts Unicode UTF-8 bytes for unknown-length streamed requests' {
        $request = New-ApiRequest '{"value":"éé"}'
        { Read-IdsAssessmentRequestJson $request 15 } | Should -Throw '*byte limit*'
        (Read-IdsAssessmentRequestJson (New-ApiRequest '{"value":"éé"}') 16).value | Should -Be 'éé'
    }
    It 'rejects duplicate members, nonobject roots and invalid UTF-8' {
        foreach ($text in '{"x":1,"X":2}', '[]', '{} {}', '{"x":NaN}') {
            { Read-IdsAssessmentRequestJson (New-ApiRequest $text) 65536 } | Should -Throw '*Invalid JSON request*'
        }
        $request = New-ApiRequest
        $request.InputStream = [IO.MemoryStream]::new([byte[]]@(123, 34, 120, 34, 58, 34, 255, 34, 125))
        { Read-IdsAssessmentRequestJson $request 65536 } | Should -Throw '*Invalid JSON request*'
    }
    It 'bounds declared-length bodies before reading them and accepts large import text envelopes' {
        { Read-IdsAssessmentRequestJson (New-ApiRequest '{}' -Length 65537) 65536 } | Should -Throw '*byte limit*'
        $text = @{ content = ('x' * 40000) } | ConvertTo-Json -Compress
        (Read-IdsAssessmentRequestJson (New-ApiRequest $text) 64MB).content.Length | Should -Be 40000
    }
}

Describe 'Assessment local route contract' {
    BeforeEach {
        $state = [hashtable]::Synchronized(@{
            Auth = $null; Export = @{ running = $false }; Browser = @{ running = $false }
            Config = @{ Port = 7654; ImportedPackRoot = (Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))); OutputPath = "$TestDrive\export" }
        })
        Initialize-IdsAssessment $state
    }
    It 'requires sign-in for progress, results and starts but not catalog metadata' {
        foreach ($path in '/api/assessment', '/api/assessment/results') {
            (Invoke-IdsAssessmentRoute GET $path (New-ApiRequest) $state $repo).status | Should -Be 401
        }
        (Invoke-IdsAssessmentRoute POST /api/assessment (New-ApiRequest) $state $repo).status | Should -Be 401
        $catalog = Invoke-IdsAssessmentRoute GET /api/assessment/packs (New-ApiRequest) $state $repo
        $catalog.status | Should -Be 200
        $catalog.body.packs.Count | Should -Be 4
        $json = ConvertTo-Json $catalog.body -Depth 64
        $json | Should -Not -Match '"controls"|"path"|access_token'
        $catalog.body.packs[0].coverage.inventory | Should -Be 'partial'
        $catalog.body.packs[0].selectionId | Should -Match '@.+#[a-f0-9]{64}$'
    }
    It 'returns 404 for absent or stale results and refuses stale progress' {
        $state.Auth = @{ access_token = 'SYNTHETIC-SECRET' }
        (Invoke-IdsAssessmentRoute GET /api/assessment/results (New-ApiRequest) $state $repo).status | Should -Be 404
        $state.Assessment.result = @{ access_token = 'SYNTHETIC-SECRET' }
        $state.Assessment.resultEpoch = -1
        (Invoke-IdsAssessmentRoute GET /api/assessment/results (New-ApiRequest) $state $repo).status | Should -Be 404
        (Invoke-IdsAssessmentRoute GET /api/assessment (New-ApiRequest) $state $repo).status | Should -Be 404
    }
    It 'serializes empty progress summaries as an empty array before a result exists' {
        $state.Auth = @{ transport = 'token' }
        foreach ($running in @($false, $true)) {
            $state.Assessment.running = $running
            $response = Invoke-IdsAssessmentRoute GET /api/assessment (New-ApiRequest) $state $repo
            $response.status | Should -Be 200
            $json = $response.body | ConvertTo-Json -Depth 64 | ConvertFrom-Json
            ($json.summaries -is [array]) | Should -BeTrue
            $json.summaries.Count | Should -Be 0
        }
    }
    It 'rejects a start before parsing while an unfinished portal handle is retained' {
        $state.Auth = @{ transport = 'token' }
        $state.Browser.job = @{ handle = @{ IsCompleted = $false } }
        (Invoke-IdsAssessmentRoute POST /api/assessment (New-ApiRequest 'broken') $state $repo).status | Should -Be 409
    }
    It 'returns conflict before parsing duplicate starts and export-active starts' {
        $state.Auth = @{ transport = 'token' }
        foreach ($kind in 'Export', 'Assessment', 'Browser') {
            $state[$kind].running = $true
            (Invoke-IdsAssessmentRoute POST /api/assessment (New-ApiRequest 'broken') $state $repo).status | Should -Be 409
            $state[$kind].running = $false
        }
    }
    It 'rejects foreign origin, foreign host and non-JSON imports' {
        foreach ($request in @(
            (New-ApiRequest -Origin 'https://foreign.invalid'),
            (New-ApiRequest -HostName 'foreign.invalid:7654'),
            (New-ApiRequest -Origin 'null'),
            (New-ApiRequest -Type 'text/plain'),
            (New-ApiRequest -Origin '')
        )) {
            (Invoke-IdsAssessmentRoute POST /api/assessment/packs $request $state $repo).status | Should -BeIn @(403, 415)
        }
    }
    It 'rejects malformed, arbitrary-path, oversized and unknown-pack requests with standard statuses' {
        $state.Auth = @{ transport = 'token' }
        (Invoke-IdsAssessmentRoute POST /api/assessment (New-ApiRequest 'broken') $state $repo).status | Should -Be 400
        (Invoke-IdsAssessmentRoute POST /api/assessment (New-ApiRequest '{}' -Length 65537) $state $repo).status | Should -Be 413
        (Invoke-IdsAssessmentRoute POST /api/assessment/packs (New-ApiRequest '{}' -Length 67108865) $state $repo).status | Should -Be 413
        (Invoke-IdsAssessmentRoute POST /api/assessment/packs (New-ApiRequest '{"path":"C:\\secret.json"}') $state $repo).status | Should -Be 400
        $body = @{ packIds = @('synthetic-pack@1.0.0#' + ('0' * 64))
            context = @{ platforms = @('windows11') }; outputPath = "$TestDrive\reports" } | ConvertTo-Json
        (Invoke-IdsAssessmentRoute POST /api/assessment (New-ApiRequest $body) $state $repo).status | Should -Be 400
        $text = @{ content = (' ' * (10MB + 1)) } | ConvertTo-Json -Compress
        (Invoke-IdsAssessmentRoute POST /api/assessment/packs (New-ApiRequest $text) $state $repo).status | Should -Be 413
    }
    It 'imports original UTF-8 bytes without exposing controls or accepting a conflicting replacement' {
        $content = [Text.Encoding]::UTF8.GetString((New-IdsTestPackBytes))
        $body = @{ content = $content } | ConvertTo-Json -Compress
        $response = Invoke-IdsAssessmentRoute POST /api/assessment/packs (New-ApiRequest $body) $state $repo
        $response.status | Should -Be 201
        $response.body.pack.sha256 | Should -Be (Read-IdsBaselinePack (New-IdsTestPackBytes)).sha256
        $response.body.pack.PSObject.Properties.Name | Should -Not -Contain 'controls'
        $changed = $content.Replace('Synthetic required setting', 'Changed')
        $body = @{ content = $changed } | ConvertTo-Json -Compress
        (Invoke-IdsAssessmentRoute POST /api/assessment/packs (New-ApiRequest $body) $state $repo).status | Should -Be 400
    }
    It 'does not invalidate a bundled identity by importing conflicting bytes' {
        $pack = (Get-IdsAssessmentCatalog $state $repo).packs[0]
        $content = [IO.File]::ReadAllText($pack.path).Replace($pack.controls[0].title, 'Synthetic changed title')
        $body = @{ content = $content } | ConvertTo-Json -Compress
        (Invoke-IdsAssessmentRoute POST /api/assessment/packs (New-ApiRequest $body) $state $repo).status | Should -Be 400
        $catalog = Get-IdsAssessmentCatalog $state $repo
        $catalog.packs.Count | Should -Be 4
        $catalog.errors.Count | Should -Be 0
    }
}

Describe 'Assessment JSON response depth' {
    It 'supports deep assessment evidence without changing ordinary JSON responses' {
        $deep = @{ value = 'synthetic-leaf' }
        for ($i = 0; $i -lt 14; $i++) { $deep = @{ child = $deep } }
        $stream = [IO.MemoryStream]::new()
        $response = [pscustomobject]@{
            StatusCode = 0; ContentType = ''; Headers = @{}; ContentLength64 = 0; OutputStream = $stream
        }
        Send-IdsJson -Response $response -Object $deep -Depth 64
        [Text.Encoding]::UTF8.GetString($stream.ToArray()) | Should -Match '"value":\s*"synthetic-leaf"'
        $response.Headers['Cache-Control'] | Should -Be 'no-store'
        $response.StatusCode | Should -Be 200
        $stream = [IO.MemoryStream]::new()
        $response.OutputStream = $stream
        Send-IdsJson -Response $response -Object @{ status = 'ok' }
        ([Text.Encoding]::UTF8.GetString($stream.ToArray()) | ConvertFrom-Json).status | Should -Be 'ok'
    }
}
