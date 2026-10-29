BeforeAll {
    $repo = Split-Path -Parent $PSScriptRoot
    foreach ($module in 'Http', 'BaselinePacks', 'AssessmentCollection', 'AssessmentSettings', 'BaselineArchive', 'AssessmentRules', 'AssessmentReports', 'Assessment', 'AssessmentApi') {
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

Describe 'Assessment pack archive imports' {
    BeforeAll {
        function Invoke-TestPackImport([hashtable]$State, [hashtable]$Fields) {
            $text = ConvertTo-Json -InputObject $Fields -Compress
            return Invoke-IdsAssessmentRoute POST /api/assessment/packs (New-ApiRequest $text) $State $repo
        }
        function New-TestKitPolicyJson([string]$Name, [string]$Id, $Value) {
            $policy = New-IdsTestBuildKitPolicy -Name $Name -Instances @(New-IdsTestSettingInstance -Id $Id -Value @{ value = $Value })
            return ConvertTo-Json -InputObject $policy -Depth 64 -Compress
        }
        function Get-TestImportedFiles([hashtable]$State) {
            $root = $State.Config.ImportedPackRoot
            if (-not (Test-Path -LiteralPath $root)) { return @() }
            return @(Get-ChildItem -LiteralPath $root -Filter '*.json' -File)
        }
        $nothingImportable = 'The archive contains no importable rule packs or Settings Catalog policies. ' +
            'PDF, Excel, XCCDF/OVAL, Group Policy and OMA-URI content is not supported.'
    }
    BeforeEach {
        $state = [hashtable]::Synchronized(@{
            Auth = $null; Export = @{ running = $false }; Browser = @{ running = $false }
            Config = @{ Port = 7654; ImportedPackRoot = (Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))); OutputPath = "$TestDrive\export" }
        })
        Initialize-IdsAssessment $state
    }

    It 'requires exactly one of content or archive' {
        foreach ($fields in @(@{}, @{ content = '{}'; archive = 'AAAA' })) {
            $response = Invoke-TestPackImport $state $fields
            $response.status | Should -Be 400
            $response.body.error | Should -BeExactly 'Provide exactly one of content or archive.'
        }
    }

    It 'keeps rejecting unknown or incorrectly cased import fields' {
        foreach ($fields in @(
            @{ path = 'synthetic.zip' },
            @{ archive = 'AAAA'; path = 'synthetic.zip' },
            @{ content = '{}'; unexpected = $true },
            @{ Archive = 'AAAA' }
        )) {
            $response = Invoke-TestPackImport $state $fields
            $response.status | Should -Be 400
            $response.body.error | Should -BeExactly 'Unknown assessment input field.'
        }
        @(Get-TestImportedFiles $state).Count | Should -Be 0
    }

    It 'rejects archive text with <label>' -ForEach @(
        @{ label = 'a number instead of text'; value = 5 }
        @{ label = 'null instead of text'; value = $null }
        @{ label = 'a boolean instead of text'; value = $true }
        @{ label = 'an array instead of text'; value = @('AAAA') }
        @{ label = 'an object instead of text'; value = @{ text = 'AAAA' } }
        @{ label = 'characters outside base64'; value = 'AB$D' }
        @{ label = 'whitespace'; value = 'QUJ RA==' }
        @{ label = 'padding inside the text'; value = 'QU=D' }
        @{ label = 'a length that is not a multiple of 4'; value = 'QUJDRA' }
        @{ label = 'three padding characters'; value = 'Q===' }
    ) {
        $response = Invoke-TestPackImport $state @{ archive = $value }
        $response.status | Should -Be 400
        $response.body.error | Should -BeExactly 'Archive must be strict base64 text.'
    }

    It 'rejects an empty archive' {
        $response = Invoke-TestPackImport $state @{ archive = '' }
        $response.status | Should -Be 400
        $response.body.error | Should -BeExactly 'Archive is empty.'
    }

    It 'returns 413 for archive text longer than 44,739,244 characters' {
        $response = Invoke-TestPackImport $state @{ archive = ('A' * 44739248) }
        $response.status | Should -Be 413
        $response.body.error | Should -BeExactly 'Archive byte limit exceeded (32 MiB).'
    }

    It 'rejects archive text that decodes to more than 32 MiB' {
        # 44,739,244 unpadded characters decode to 32 MiB + 1 byte.
        { Import-IdsAssessmentArchive ('A' * 44739244) $state $repo } |
            Should -Throw -ExceptionType ([IO.InvalidDataException]) -ExpectedMessage 'Archive byte limit exceeded (32 MiB).'
    }

    It 'allows exactly 32 MiB through to ZIP validation' {
        # One padding character removes one decoded byte at the encoded limit.
        { Import-IdsAssessmentArchive (('A' * 44739243) + '=') $state $repo } |
            Should -Throw -ExceptionType ([ArgumentException]) -ExpectedMessage 'The file is not a valid ZIP archive.'
    }

    It 'returns 413 when the archive exceeds the 64 MiB JSON budget' {
        $entries = [ordered]@{}
        # 0xFF bytes are not valid UTF-8, so no entry reaches the JSON parser.
        $filler = [byte[]]::new(10000000)
        [Array]::Fill($filler, [byte]255)
        for ($index = 0; $index -lt 7; $index++) { $entries["kit/filler$index.json"] = $filler }
        $response = Invoke-TestPackImport $state @{ archive = [Convert]::ToBase64String((New-IdsTestZipBytes $entries)) }
        $response.status | Should -Be 413
        $response.body.error | Should -BeExactly 'Archive JSON read limit exceeded (64 MiB).'
        @(Get-TestImportedFiles $state).Count | Should -Be 0
    }

    It 'rejects bytes that are not a ZIP archive' {
        $archive = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('not a zip archive'))
        $response = Invoke-TestPackImport $state @{ archive = $archive }
        $response.status | Should -Be 400
        $response.body.error | Should -BeExactly 'The file is not a valid ZIP archive.'
    }

    It 'returns 400 for unsafe archive entry names before importing a valid pack' {
        $zip = New-IdsTestZipBytes ([ordered]@{
            'packs/valid.json' = (New-IdsTestPackBytes)
            '../outside.json' = '{}'
        })
        $response = Invoke-TestPackImport $state @{ archive = [Convert]::ToBase64String($zip) }
        $response.status | Should -Be 400
        $response.body.error | Should -BeExactly "Archive entry names must be relative without ':' or '..' segments."
        @(Get-TestImportedFiles $state).Count | Should -Be 0
    }

    It 'returns 400 for <label> rather than a byte-limit error' -ForEach @(
        @{ label = 'more than 1,000 archive entries'; count = 1001; extension = 'txt'; message = 'Archive entry limit exceeded (1,000 entries).' }
        @{ label = 'more than 500 JSON entries'; count = 501; extension = 'json'; message = 'Archive JSON entry limit exceeded (500 entries).' }
    ) {
        $entries = [ordered]@{}
        for ($index = 0; $index -lt $count; $index++) { $entries["kit/entry$index.$extension"] = '{}' }
        $response = Invoke-TestPackImport $state @{ archive = [Convert]::ToBase64String((New-IdsTestZipBytes $entries)) }
        $response.status | Should -Be 400
        $response.body.error | Should -BeExactly $message
        @(Get-TestImportedFiles $state).Count | Should -Be 0
    }

    It 'answers 400 with skipped and ignored entries when nothing is importable' {
        $zip = New-IdsTestZipBytes ([ordered]@{ 'kit/readme.pdf' = 'synthetic'; 'kit/notes.json' = '{"title":"Synthetic notes"}' })
        $response = Invoke-TestPackImport $state @{ archive = [Convert]::ToBase64String($zip) }
        $response.status | Should -Be 400
        $json = ConvertTo-Json -InputObject $response.body -Depth 64 | ConvertFrom-Json
        $json.error | Should -BeExactly $nothingImportable
        ($json.skipped -is [array]) | Should -BeTrue
        "$($json.skipped[0].entry) => $($json.skipped[0].reason)" |
            Should -BeExactly 'kit/notes.json => Not a Settings Catalog policy or rule pack.'
        $json.skippedCount | Should -Be 1
        $json.ignored | Should -Be 1
        @(Get-TestImportedFiles $state).Count | Should -Be 0
    }

    It 'limits the skipped list to 100 items and truncates entry names to 260 characters' {
        $entries = [ordered]@{ 'kit/L1/policy.json' = (New-TestKitPolicyJson 'Synthetic L1 policy' 'syn.level1' 1) }
        $long = 'kit/' + ('n' * 300) + '.json'
        $entries[$long] = '{"title":"Synthetic notes"}'
        for ($index = 0; $index -lt 120; $index++) { $entries["kit/notes$index.json"] = '{"title":"Synthetic notes"}' }
        $response = Invoke-TestPackImport $state @{ archive = [Convert]::ToBase64String((New-IdsTestZipBytes $entries)) }
        $response.status | Should -Be 201
        $response.body.skipped.Count | Should -Be 100
        $response.body.skippedCount | Should -Be 121
        $response.body.skipped[0].entry | Should -BeExactly $long.Substring(0, 260)
        $response.body.skipped[1].entry | Should -BeExactly 'kit/notes0.json'
    }

    It 'also bounds skipped entries when the archive has nothing importable' {
        $entries = [ordered]@{}
        $long = 'kit/' + ('n' * 300) + '.json'
        $entries[$long] = '{}'
        for ($index = 0; $index -lt 100; $index++) { $entries["kit/notes$index.json"] = '{}' }
        $response = Invoke-TestPackImport $state @{ archive = [Convert]::ToBase64String((New-IdsTestZipBytes $entries)) }
        $response.status | Should -Be 400
        $json = ConvertTo-Json -InputObject $response.body -Depth 64 | ConvertFrom-Json
        $json.error | Should -BeExactly $nothingImportable
        $json.skipped.Count | Should -Be 100
        $json.skipped[0].entry | Should -BeExactly $long.Substring(0, 260)
        $json.skippedCount | Should -Be 101
        $json.ignored | Should -Be 0
        @(Get-TestImportedFiles $state).Count | Should -Be 0
    }

    It 'serializes a single imported pack and empty skipped entries as arrays' {
        $bytes = New-IdsTestPackBytes
        $zip = New-IdsTestZipBytes ([ordered]@{ 'packs/one.json' = $bytes; 'packs/duplicate.json' = $bytes })
        $response = Invoke-TestPackImport $state @{ archive = [Convert]::ToBase64String($zip) }
        $response.status | Should -Be 201
        $text = ConvertTo-Json -InputObject $response.body -Depth 64
        $text | Should -Not -Match '"controls"|"path"'
        $json = $text | ConvertFrom-Json
        ($json.packs -is [array]) | Should -BeTrue
        $json.packs.Count | Should -Be 1
        $json.packs[0].id | Should -BeExactly 'synthetic-pack'
        $json.packs[0].origin | Should -BeExactly 'imported'
        $json.packs[0].controlCount | Should -Be 1
        $json.packs[0].added | Should -BeTrue
        $json.added | Should -Be 1
        ($json.skipped -is [array]) | Should -BeTrue
        $json.skipped.Count | Should -Be 0
        $json.skippedCount | Should -Be 0
        $json.ignored | Should -Be 0
        $files = @(Get-TestImportedFiles $state)
        $files.Count | Should -Be 1
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($files[0].FullName)) |
            Should -BeExactly ([Convert]::ToBase64String($bytes))
    }

    It 'imports a build-kit archive, reports the summary and is idempotent' {
        $zip = New-IdsTestZipBytes ([ordered]@{
            'kit/readme.pdf' = 'synthetic'
            'kit/notes.json' = '{"title":"Synthetic notes"}'
            'kit/L2/policy.json' = (New-TestKitPolicyJson 'Synthetic L2 policy' 'syn.level2' 'synthetic')
            'kit/L1/policy.json' = (New-TestKitPolicyJson 'Synthetic L1 policy' 'syn.level1' 1)
        })
        $archive = [Convert]::ToBase64String($zip)
        $sha256 = (Get-FileHash -InputStream ([IO.MemoryStream]::new($zip)) -Algorithm SHA256).Hash.ToLowerInvariant()
        $first = Invoke-TestPackImport $state @{ archive = $archive }
        $first.status | Should -Be 201
        $text = ConvertTo-Json -InputObject $first.body -Depth 64
        $text | Should -Not -Match '"controls"|"path"'
        $json = $text | ConvertFrom-Json
        (@($json.packs | ForEach-Object { "$($_.id)|$($_.origin)|$($_.controlCount)|$($_.added)" }) -join ',') |
            Should -BeExactly 'cis.windows11.l1|imported|1|True,cis.windows11.l2|imported|1|True'
        $json.packs[0].selectionId | Should -Match '^cis\.windows11\.l1@1\.0\.0\+[0-9a-f]{12}#[0-9a-f]{64}$'
        $json.added | Should -Be 2
        ($json.skipped -is [array]) | Should -BeTrue
        "$($json.skipped[0].entry) => $($json.skipped[0].reason)" |
            Should -BeExactly 'kit/notes.json => Not a Settings Catalog policy or rule pack.'
        $json.skippedCount | Should -Be 1
        $json.ignored | Should -Be 1
        $json.archive.sha256 | Should -BeExactly $sha256
        @(Get-TestImportedFiles $state).Count | Should -Be 2

        $second = Invoke-TestPackImport $state @{ archive = $archive }
        $second.status | Should -Be 201
        (@($second.body.packs | ForEach-Object { "$($_.id)|$($_.added)" }) -join ',') |
            Should -BeExactly 'cis.windows11.l1|False,cis.windows11.l2|False'
        $second.body.added | Should -Be 0
        @(Get-TestImportedFiles $state).Count | Should -Be 2

        $catalog = Invoke-IdsAssessmentRoute GET /api/assessment/packs (New-ApiRequest) $state $repo
        $catalog.body.packs.Count | Should -Be 6
        $listed = @($catalog.body.packs | Where-Object { $_.id -ceq 'cis.windows11.l1' })
        $listed.Count | Should -Be 1
        $listed[0].origin | Should -BeExactly 'imported'
        $listed[0].selectionId | Should -BeExactly $json.packs[0].selectionId
    }

    It 'rejects a conflict with an imported pack before writing anything' {
        $content = [Text.Encoding]::UTF8.GetString((New-IdsTestPackBytes))
        (Invoke-TestPackImport $state @{ content = $content }).status | Should -Be 201
        $zip = New-IdsTestZipBytes ([ordered]@{
            'kit/L1/policy.json' = (New-TestKitPolicyJson 'Synthetic L1 policy' 'syn.level1' 1)
            'packs/changed.json' = $content.Replace('Synthetic required setting', 'Changed')
        })
        $response = Invoke-TestPackImport $state @{ archive = [Convert]::ToBase64String($zip) }
        $response.status | Should -Be 400
        $response.body.error | Should -BeExactly 'Pack synthetic-pack@1.0.0 already exists with different bytes; nothing was imported.'
        @(Get-TestImportedFiles $state).Count | Should -Be 1
    }

    It 'rejects a conflict with a bundled pack before writing anything' {
        $bundled = (Get-IdsAssessmentCatalog $state $repo).packs[0]
        $changed = [IO.File]::ReadAllText($bundled.path).Replace($bundled.controls[0].title, 'Synthetic changed title')
        $zip = New-IdsTestZipBytes ([ordered]@{
            'kit/L1/policy.json' = (New-TestKitPolicyJson 'Synthetic L1 policy' 'syn.level1' 1)
            'packs/changed.json' = $changed
        })
        $response = Invoke-TestPackImport $state @{ archive = [Convert]::ToBase64String($zip) }
        $response.status | Should -Be 400
        $response.body.error |
            Should -BeExactly "Pack $($bundled.id)@$($bundled.version) already exists with different bytes; nothing was imported."
        @(Get-TestImportedFiles $state).Count | Should -Be 0
        $catalog = Get-IdsAssessmentCatalog $state $repo
        $catalog.packs.Count | Should -Be 4
        $catalog.errors.Count | Should -Be 0
    }

    It 'rejects two different packs with the same identity in one archive' {
        $content = [Text.Encoding]::UTF8.GetString((New-IdsTestPackBytes))
        $zip = New-IdsTestZipBytes ([ordered]@{
            'packs/original.json' = $content
            'packs/changed.json' = $content.Replace('Synthetic required setting', 'Changed')
            'kit/L1/policy.json' = (New-TestKitPolicyJson 'Synthetic L1 policy' 'syn.level1' 1)
        })
        $response = Invoke-TestPackImport $state @{ archive = [Convert]::ToBase64String($zip) }
        $response.status | Should -Be 400
        $response.body.error | Should -BeExactly 'Pack set contains different packs with the same ID/version: synthetic-pack@1.0.0.'
        @(Get-TestImportedFiles $state).Count | Should -Be 0
    }

    It 'maps an archive storage failure to a generic 500 response' {
        $zip = New-IdsTestZipBytes ([ordered]@{ 'packs/one.json' = (New-IdsTestPackBytes) })
        [void][IO.Directory]::CreateDirectory($state.Config.ImportedPackRoot)
        $lockPath = Join-Path $state.Config.ImportedPackRoot '.import.lock'
        $lock = [IO.FileStream]::new($lockPath, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try {
            $response = Invoke-TestPackImport $state @{ archive = [Convert]::ToBase64String($zip) }
            $response.status | Should -Be 500
            $response.body.error | Should -BeExactly 'Local assessment storage failed.'
            @(Get-TestImportedFiles $state).Count | Should -Be 0
        } finally { $lock.Dispose() }
    }

    It 'reports imported origin for single JSON pack imports' {
        $content = [Text.Encoding]::UTF8.GetString((New-IdsTestPackBytes))
        $response = Invoke-TestPackImport $state @{ content = $content }
        $response.status | Should -Be 201
        $response.body.pack.origin | Should -BeExactly 'imported'
        $catalog = Invoke-IdsAssessmentRoute GET /api/assessment/packs (New-ApiRequest) $state $repo
        @($catalog.body.packs | Where-Object { $_.id -ceq 'synthetic-pack' }).origin | Should -BeExactly 'imported'
    }
}
