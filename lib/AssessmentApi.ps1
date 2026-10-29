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

function Import-IdsAssessmentArchive {
    param($Archive, [hashtable]$State, [string]$Root)
    if ($Archive -isnot [string] -or $Archive.Length % 4 -ne 0 -or $Archive -cnotmatch '\A[A-Za-z0-9+/]*={0,2}\z') {
        throw 'Archive must be strict base64 text.'
    }
    # 44,739,244 base64 characters decode to at most 32 MiB + 1 byte.
    if ($Archive.Length -gt 44739244) { throw [IO.InvalidDataException]::new('Archive byte limit exceeded (32 MiB).') }
    $bytes = [Convert]::FromBase64String($Archive)
    if ($bytes.Length -eq 0) { throw 'Archive is empty.' }
    if ($bytes.Length -gt 32MB) { throw [IO.InvalidDataException]::new('Archive byte limit exceeded (32 MiB).') }
    $result = ConvertFrom-IdsBaselineArchive -Bytes $bytes
    $skipped = @($result.skipped | Select-Object -First 100 | ForEach-Object {
        $entry = [string]$_.entry
        if ($entry.Length -gt 260) { $entry = $entry.Substring(0, 260) }
        @{ entry = $entry; reason = $_.reason }
    })
    if ($result.packs.Count -eq 0) {
        return [pscustomobject]@{ status = 400; body = @{
            error = 'The archive contains no importable rule packs or Settings Catalog policies. ' +
                'PDF, Excel, XCCDF/OVAL, Group Policy and OMA-URI content is not supported.'
            skipped = $skipped; skippedCount = $result.skipped.Count; ignored = $result.ignored
        } }
    }
    # Import-IdsBaselinePackSet sees only imported packs; bundled identities
    # are checked here so nothing is written when any pack conflicts.
    $catalog = Get-IdsAssessmentCatalog $State $Root
    foreach ($packBytes in $result.packs) {
        $candidate = Read-IdsBaselinePack -Bytes $packBytes
        foreach ($existing in $catalog.packs) {
            if ($existing.id -ceq $candidate.id -and $existing.version -ceq $candidate.version -and $existing.sha256 -cne $candidate.sha256) {
                throw "Pack $($candidate.id)@$($candidate.version) already exists with different bytes; nothing was imported."
            }
        }
    }
    $imported = @(Import-IdsBaselinePackSet -Packs $result.packs -ImportedRoot $State.Config.ImportedPackRoot)
    $packs = @(foreach ($item in $imported) {
        $item.pack | Add-Member -NotePropertyName origin -NotePropertyValue 'imported' -Force
        $metadata = Get-IdsAssessmentPackMetadata $item.pack
        $metadata | Add-Member NoteProperty controlCount @($item.pack.controls).Count
        $metadata | Add-Member NoteProperty added $item.added
        $metadata
    })
    return [pscustomobject]@{ status = 201; body = @{
        packs = $packs; added = @($imported | Where-Object { $_.added }).Count
        skipped = $skipped; skippedCount = $result.skipped.Count; ignored = $result.ignored
        archive = @{ sha256 = $result.sha256 }
    } }
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
                Assert-IdsAssessmentFields $fields @('content', 'archive') @()
                if ($fields.Count -ne 1) { throw 'Provide exactly one of content or archive.' }
                if ($fields.ContainsKey('archive')) {
                    $imported = Import-IdsAssessmentArchive $fields['archive'] $State $Root
                    $response.status = $imported.status; $response.body = $imported.body
                    break
                }
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
                $pack | Add-Member -NotePropertyName origin -NotePropertyValue 'imported' -Force
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
