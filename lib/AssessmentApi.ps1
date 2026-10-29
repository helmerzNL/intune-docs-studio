. (Join-Path $PSScriptRoot 'Localization.ps1')

function Assert-IdsAssessmentJsonMembers {
    param([System.Text.Json.JsonElement]$Element)
    if ($Element.ValueKind -eq [System.Text.Json.JsonValueKind]::Object) {
        $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($member in $Element.EnumerateObject()) {
            if (-not $names.Add($member.Name)) { throw (Get-IdsText -Key 'text.duplicate_json_member') }
            Assert-IdsAssessmentJsonMembers $member.Value
        }
    } elseif ($Element.ValueKind -eq [System.Text.Json.JsonValueKind]::Array) {
        foreach ($item in $Element.EnumerateArray()) { Assert-IdsAssessmentJsonMembers $item }
    }
}

function Read-IdsAssessmentRequestJson {
    param([object]$Request, [ValidateRange(1, 67108864)][int]$MaxBytes)
    if ($Request.ContentLength64 -gt $MaxBytes) {
        throw [IO.InvalidDataException]::new((Get-IdsText -Key 'text.request_byte_limit_exceeded'))
    }
    $buffer = [byte[]]::new(8192)
    $stream = [IO.MemoryStream]::new()
    try {
        while ($true) {
            $count = $Request.InputStream.Read($buffer, 0, [Math]::Min($buffer.Length, $MaxBytes + 1 - [int]$stream.Length))
            if ($count -eq 0) { break }
            $stream.Write($buffer, 0, $count)
            if ($stream.Length -gt $MaxBytes) { throw [IO.InvalidDataException]::new((Get-IdsText -Key 'text.request_byte_limit_exceeded')) }
        }
        try {
            $text = [Text.UTF8Encoding]::new($false, $true).GetString($stream.ToArray())
            $options = [System.Text.Json.JsonDocumentOptions]::new()
            $options.MaxDepth = 32
            $document = [System.Text.Json.JsonDocument]::Parse($text, $options)
            try {
                if ($document.RootElement.ValueKind -ne [System.Text.Json.JsonValueKind]::Object) {
                    throw (Get-IdsText -Key 'text.request_must_be_a_json_object')
                }
                Assert-IdsAssessmentJsonMembers $document.RootElement
                return [pscustomobject](ConvertFrom-Json -InputObject $text -AsHashtable -Depth 32)
            } finally { $document.Dispose() }
        } catch { throw [ArgumentException]::new((Get-IdsText -Key 'text.invalid_json_request'), $_.Exception) }
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
        throw (Get-IdsText -Key 'text.archive_must_be_strict_base64_text')
    }
    # 44,739,244 base64 characters decode to at most 32 MiB + 1 byte.
    if ($Archive.Length -gt 44739244) { throw [IO.InvalidDataException]::new((Get-IdsText -Key 'text.archive_byte_limit_exceeded_32_mib')) }
    $bytes = [Convert]::FromBase64String($Archive)
    if ($bytes.Length -eq 0) { throw (Get-IdsText -Key 'text.archive_is_empty') }
    if ($bytes.Length -gt 32MB) { throw [IO.InvalidDataException]::new((Get-IdsText -Key 'text.archive_byte_limit_exceeded_32_mib')) }
    $result = ConvertFrom-IdsBaselineArchive -Bytes $bytes
    $skipped = @($result.skipped | Select-Object -First 100 | ForEach-Object {
        $entry = [string]$_.entry
        if ($entry.Length -gt 260) { $entry = $entry.Substring(0, 260) }
        @{ entry = $entry; reason = $_.reason }
    })
    if ($result.packs.Count -eq 0) {
        return [pscustomobject]@{ status = 400; body = @{
            error = (Get-IdsText -Key 'import.unsupported_archive')
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
                throw (Get-IdsText -Key 'text.pack_arg0_arg1_already_exists_with_different_bytes_nothing_was_imported' -Arguments @{ arg0 = ($candidate.id); arg1 = ($candidate.version) })
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
        'POST /api/assessment/packs/remove', 'POST /api/assessment', 'GET /api/assessment', 'GET /api/assessment/results')) {
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
                $response.status = 403; $response.body = @{ error = (Get-IdsText -Key 'text.same_origin_request_required') }
                return $response
            }
            if ($Request.ContentType -notmatch '^(?i:application/json)(?:\s*;\s*charset\s*=\s*(?i:utf-8))?\s*$') {
                $response.status = 415; $response.body = @{ error = (Get-IdsText -Key 'text.content_type_must_be_application_json_with_utf_8_encoding') }
                return $response
            }
        }
        if ($Path -cnotin @('/api/assessment/packs', '/api/assessment/packs/remove')) {
            if (-not $State.Auth -and -not $State.Policies.snapshot) {
                $response.status = 401; $response.body = @{ error = (Get-IdsText -Key 'text.not_signed_in') }; return $response
            }
            if ($Method -ceq 'POST' -and ((Test-IdsWorkActive $State) -or $State.Browser.running)) {
                $response.status = 409; $response.body = @{ error = (Get-IdsText -Key 'text.an_export_assessment_or_sign_in_is_already_running') }; return $response
            }
            if ($Method -ceq 'POST' -and $State.Policies) {
                try { $null = Get-IdsLoadedPolicies $State } catch {
                    $response.status = 409; $response.body = @{ error = $_.Exception.Message }; return $response
                }
            }
        }
        if ($Method -eq 'POST' -and (Test-IdsWorkActive $State)) {
            $response.status = 409; $response.body = @{ error = (Get-IdsText -Key 'text.wait_for_policy_loading_imports_and_active_runs_before_changing_the_library') }; return $response
        }
        switch -CaseSensitive ("$Method $Path") {
            'POST /api/assessment/packs/remove' {
                $body = Read-IdsAssessmentRequestJson $Request 4KB
                $response.body = Remove-IdsImportedPack $State $Root ([string]$body.selectionId) ($body.confirm -eq $true)
            }
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
                Assert-IdsAssessmentFields $fields @('content', 'archive', 'path', 'kind') @()
                if (@($fields.Keys | Where-Object { $_ -cin @('content', 'archive', 'path') }).Count -ne 1) {
                    throw (Get-IdsText -Key 'text.provide_exactly_one_of_content_or_archive_or_a_host_folder_path')
                }
                if ($body.kind -and $body.kind -cnotin @('reference', 'packs')) { throw (Get-IdsText -Key 'text.unknown_import_kind') }
                if ($fields.ContainsKey('path') -and ($body.path -isnot [string] -or [string]::IsNullOrWhiteSpace($body.path))) {
                    throw (Get-IdsText -Key 'text.provide_an_absolute_host_folder_path')
                }
                if ($body.kind -ceq 'reference' -and $fields.ContainsKey('content')) {
                    throw (Get-IdsText -Key 'text.a_custom_reference_requires_a_policy_set_folder_or_zip_not_rule_pack_content')
                }
                if ($body.kind -eq 'reference' -or $fields.ContainsKey('path')) {
                    $result = if ($body.kind -eq 'reference') {
                        $snapshot = if ($body.archive) {
                            Import-IdsPolicySnapshot -Archive (ConvertFrom-IdsPolicyArchiveBase64 $body.archive)
                        } else { Import-IdsPolicySnapshot -Path ([string]$body.path) }
                        ConvertTo-IdsReferencePacks $snapshot
                    } else {
                        $entries = Read-IdsPolicyEntries -Path ([string]$body.path)
                        $bytes = @(foreach ($name in $entries.Keys | Sort-Object) { ,$entries[$name] })
                        foreach ($entryBytes in $bytes) { [void](Read-IdsBaselinePack $entryBytes) }
                        @{ packs = $bytes; skipped = @(); skippedCount = 0; ignored = 0 }
                    }
                    if ($result.packs.Count -eq 0) {
                        $response.status = 400; $response.body = @{ error = (Get-IdsText -Key 'text.no_safe_reference_checks_or_schema_1_rule_packs_found'); skipped = $result.skipped; skippedCount = $result.skippedCount }; break
                    }
                    $catalog = Get-IdsAssessmentCatalog $State $Root
                    foreach ($entryBytes in $result.packs) {
                        $candidate = Read-IdsBaselinePack $entryBytes
                        if (@($catalog.packs | Where-Object { $_.id -ceq $candidate.id -and $_.version -ceq $candidate.version -and $_.sha256 -cne $candidate.sha256 }).Count) {
                            throw (Get-IdsText -Key 'text.pack_id_version_conflicts_with_the_library_this_item_was_not_imported')
                        }
                    }
                    $imported = @(Import-IdsBaselinePackSet -Packs $result.packs -ImportedRoot $State.Config.ImportedPackRoot)
                    $response.status = 201
                    $response.body = @{ packs = @(foreach ($item in $imported) {
                        $item.pack | Add-Member NoteProperty origin 'imported' -Force
                        $metadata = Get-IdsAssessmentPackMetadata $item.pack
                        $metadata | Add-Member NoteProperty added $item.added
                        $metadata | Add-Member NoteProperty controlCount @($item.pack.controls).Count
                        $metadata
                    }); added = @($imported | Where-Object added).Count; skipped = $result.skipped; skippedCount = $result.skippedCount; ignored = $result.ignored }
                    break
                }
                if (@($fields.Keys | Where-Object { $_ -in @('content', 'archive') }).Count -ne 1) { throw (Get-IdsText -Key 'text.provide_exactly_one_of_content_or_archive') }
                if ($fields.ContainsKey('archive')) {
                    $imported = Import-IdsAssessmentArchive $fields['archive'] $State $Root
                    $response.status = $imported.status; $response.body = $imported.body
                    break
                }
                if ($body.content -isnot [string]) { throw (Get-IdsText -Key 'text.pack_content_must_be_original_utf_8_json_text') }
                $encoding = [Text.UTF8Encoding]::new($false, $true)
                if ($encoding.GetByteCount($body.content) -gt 10MB) { throw [IO.InvalidDataException]::new((Get-IdsText -Key 'text.decoded_pack_byte_limit_exceeded_10_mib')) }
                $bytes = $encoding.GetBytes($body.content)
                $candidate = Read-IdsBaselinePack -Bytes $bytes
                $catalog = Get-IdsAssessmentCatalog $State $Root
                foreach ($existing in $catalog.packs) {
                    if ($existing.id -ceq $candidate.id -and $existing.version -ceq $candidate.version -and $existing.sha256 -cne $candidate.sha256) {
                        throw (Get-IdsText -Key 'text.pack_id_version_already_exists_with_different_bytes')
                    }
                }
                $item = @(Import-IdsBaselinePackSet -Packs @(,$bytes) -ImportedRoot $State.Config.ImportedPackRoot)[0]
                $pack = $item.pack
                $pack | Add-Member -NotePropertyName origin -NotePropertyValue 'imported' -Force
                $response.status = 201
                $metadata = Get-IdsAssessmentPackMetadata $pack
                $metadata | Add-Member NoteProperty added $item.added
                $metadata | Add-Member NoteProperty controlCount @($pack.controls).Count
                $response.body = @{ pack = $metadata; added = $(if ($item.added) { 1 } else { 0 }) }
            }
            'POST /api/assessment' {
                $body = Read-IdsAssessmentRequestJson $Request 64KB
                $options = @{}
                foreach ($property in $body.PSObject.Properties) { $options[$property.Name] = $property.Value }
                if (Start-IdsAssessmentJob $State $options $Root) {
                    $response.status = 202
                    $response.body = @{ started = $true; runId = $State.Assessment.runId }
                } else {
                    $response.status = 409; $response.body = @{ error = (Get-IdsText -Key 'text.an_export_assessment_or_sign_in_is_already_running') }
                }
            }
            'GET /api/assessment' {
                $a = $State.Assessment
                if ($null -ne $a.resultEpoch -and $a.resultEpoch -ne $a.epoch) {
                    $response.status = 404; $response.body = @{ error = (Get-IdsText -Key 'text.no_assessment_in_this_session') }; break
                }
                $response.body = @{
                    running = $a.running; done = $a.done; percent = $a.percent; phase = $a.phase; locale = $a.locale
                    error = $a.error; partial = $a.partial; reportPaths = $a.reportPaths
                    summaries = @($a.result.summaries | Where-Object { $null -ne $_ })
                }
            }
            'GET /api/assessment/results' {
                $a = $State.Assessment
                if (-not $a.done -or -not $a.result -or $a.resultEpoch -ne $a.epoch) {
                    $response.status = 404; $response.body = @{ error = (Get-IdsText -Key 'text.no_completed_assessment_in_this_session') }; break
                }
                $response.body = ConvertTo-IdsReportProjection $a.result
            }
        }
    } catch [IO.InvalidDataException] {
        $response.status = 413; $response.body = @{ error = $_.Exception.Message }
    } catch [IO.IOException] {
        $response.status = 500; $response.body = @{ error = (Get-IdsText -Key 'text.local_assessment_storage_failed') }
    } catch [InvalidOperationException] {
        $response.status = 500; $response.body = @{ error = (Get-IdsText -Key 'text.assessment_worker_could_not_start') }
    } catch {
        $response.status = 400; $response.body = @{ error = $_.Exception.Message }
    }
    return $response
}
