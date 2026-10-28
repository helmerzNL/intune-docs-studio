function Assert-IdsAssessmentJsonMembers {
    param([System.Text.Json.JsonElement]$Element)
    if ($Element.ValueKind -eq [System.Text.Json.JsonValueKind]::Object) {
        $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($member in $Element.EnumerateObject()) {
            if (-not $names.Add($member.Name)) { throw 'Duplicate JSON member.' }
            Assert-IdsAssessmentJsonMembers $member.Value
        }
    } elseif ($Element.ValueKind -eq [System.Text.Json.JsonValueKind]::Array) {
        foreach ($item in $Element.EnumerateArray()) { Assert-IdsAssessmentJsonMembers $item }
    }
}

function Read-IdsAssessmentRequestJson {
    param([object]$Request, [ValidateRange(1, 67108864)][int]$MaxBytes)
    if ($Request.ContentLength64 -gt $MaxBytes) {
        throw [IO.InvalidDataException]::new('Request byte limit exceeded.')
    }
    $buffer = [byte[]]::new(8192)
    $stream = [IO.MemoryStream]::new()
    try {
        while ($true) {
            $count = $Request.InputStream.Read($buffer, 0, [Math]::Min($buffer.Length, $MaxBytes + 1 - [int]$stream.Length))
            if ($count -eq 0) { break }
            $stream.Write($buffer, 0, $count)
            if ($stream.Length -gt $MaxBytes) { throw [IO.InvalidDataException]::new('Request byte limit exceeded.') }
        }
        try {
            $text = [Text.UTF8Encoding]::new($false, $true).GetString($stream.ToArray())
            $options = [System.Text.Json.JsonDocumentOptions]::new()
            $options.MaxDepth = 32
            $document = [System.Text.Json.JsonDocument]::Parse($text, $options)
            try {
                if ($document.RootElement.ValueKind -ne [System.Text.Json.JsonValueKind]::Object) {
                    throw 'Request must be a JSON object.'
                }
                Assert-IdsAssessmentJsonMembers $document.RootElement
                return [pscustomobject](ConvertFrom-Json -InputObject $text -AsHashtable -Depth 32)
            } finally { $document.Dispose() }
        } catch { throw [ArgumentException]::new('Invalid JSON request.', $_.Exception) }
    } finally { $stream.Dispose() }
}

function Get-IdsAssessmentPackMetadata {
    param($Pack)
    $metadata = Copy-IdsReportRecord $Pack Pack
    $metadata | Add-Member NoteProperty selectionId "$($Pack.id)@$($Pack.version)#$($Pack.sha256)"
    return $metadata
}

function Invoke-IdsAssessmentRoute {
    param([string]$Method, [string]$Path, [object]$Request, [hashtable]$State, [string]$Root)
    $response = [pscustomobject]@{ handled = $true; status = 200; body = $null }
    if ("$Method $Path" -cnotin @('GET /api/assessment/packs', 'POST /api/assessment/packs',
        'POST /api/assessment', 'GET /api/assessment', 'GET /api/assessment/results')) {
        $response.handled = $false
        return $response
    }
    Initialize-IdsAssessment $State
    try {
        if ($Method -ceq 'POST') {
            # Compare to configured listener identity, never an attacker-supplied
            # request URL/Host. OAuth redirects retain their existing handling.
            $expected = "http://localhost:$($State.Config.Port)"
            $authority = ([uri]$expected).Authority
            if ($Request.Headers['Host'] -cne $authority -or $Request.Headers['Origin'] -cne $expected) {
                $response.status = 403; $response.body = @{ error = 'Same-origin request required.' }
                return $response
            }
            if ($Request.ContentType -notmatch '^(?i:application/json)(?:\s*;\s*charset\s*=\s*(?i:utf-8))?\s*$') {
                $response.status = 415; $response.body = @{ error = 'Content-Type must be application/json with UTF-8 encoding.' }
                return $response
            }
        }
        if ($Path -cne '/api/assessment/packs') {
            if (-not $State.Auth) {
                $response.status = 401; $response.body = @{ error = 'Not signed in.' }; return $response
            }
            if ($Method -ceq 'POST' -and ((Test-IdsWorkActive $State) -or $State.Browser.running)) {
                $response.status = 409; $response.body = @{ error = 'An export, assessment or sign-in is already running.' }; return $response
            }
        }
        switch -CaseSensitive ("$Method $Path") {
            'GET /api/assessment/packs' {
                $catalog = Get-IdsAssessmentCatalog $State $Root
                $response.body = @{
                    packs = @($catalog.packs | ForEach-Object { Get-IdsAssessmentPackMetadata $_ })
                    errors = @($catalog.errors | ForEach-Object { @{ origin = $_.origin; reason = $_.reason } })
                }
            }
            'POST /api/assessment/packs' {
                $body = Read-IdsAssessmentRequestJson $Request 64MB
                $fields = @{}
                foreach ($property in $body.PSObject.Properties) { $fields[$property.Name] = $property.Value }
                Assert-IdsAssessmentFields $fields @('content') @('content')
                if ($body.content -isnot [string]) { throw 'Pack content must be original UTF-8 JSON text.' }
                $encoding = [Text.UTF8Encoding]::new($false, $true)
                if ($encoding.GetByteCount($body.content) -gt 10MB) { throw [IO.InvalidDataException]::new('Decoded pack byte limit exceeded (10 MiB).') }
                $bytes = $encoding.GetBytes($body.content)
                $candidate = Read-IdsBaselinePack -Bytes $bytes
                $catalog = Get-IdsAssessmentCatalog $State $Root
                foreach ($existing in $catalog.packs) {
                    if ($existing.id -ceq $candidate.id -and $existing.version -ceq $candidate.version -and $existing.sha256 -cne $candidate.sha256) {
                        throw 'Pack ID/version already exists with different bytes.'
                    }
                }
                $pack = Import-IdsBaselinePack -Bytes $bytes -ImportedRoot $State.Config.ImportedPackRoot
                $response.status = 201
                $response.body = @{ pack = Get-IdsAssessmentPackMetadata $pack }
            }
            'POST /api/assessment' {
                $body = Read-IdsAssessmentRequestJson $Request 64KB
                $options = @{}
                foreach ($property in $body.PSObject.Properties) { $options[$property.Name] = $property.Value }
                if (Start-IdsAssessmentJob $State $options $Root) {
                    $response.status = 202
                    $response.body = @{ started = $true; runId = $State.Assessment.runId }
                } else {
                    $response.status = 409; $response.body = @{ error = 'An export, assessment or sign-in is already running.' }
                }
            }
            'GET /api/assessment' {
                $a = $State.Assessment
                if ($null -ne $a.resultEpoch -and $a.resultEpoch -ne $a.epoch) {
                    $response.status = 404; $response.body = @{ error = 'No assessment in this session.' }; break
                }
                $response.body = @{
                    running = $a.running; done = $a.done; percent = $a.percent; phase = $a.phase
                    error = $a.error; partial = $a.partial; reportPaths = $a.reportPaths
                    summaries = @($a.result.summaries | Where-Object { $null -ne $_ })
                }
            }
            'GET /api/assessment/results' {
                $a = $State.Assessment
                if (-not $a.done -or -not $a.result -or $a.resultEpoch -ne $a.epoch) {
                    $response.status = 404; $response.body = @{ error = 'No completed assessment in this session.' }; break
                }
                $response.body = ConvertTo-IdsReportProjection $a.result
            }
        }
    } catch [IO.InvalidDataException] {
        $response.status = 413; $response.body = @{ error = $_.Exception.Message }
    } catch [IO.IOException] {
        $response.status = 500; $response.body = @{ error = 'Local assessment storage failed.' }
    } catch [InvalidOperationException] {
        $response.status = 500; $response.body = @{ error = 'Assessment worker could not start.' }
    } catch {
        $response.status = 400; $response.body = @{ error = $_.Exception.Message }
    }
    return $response
}
