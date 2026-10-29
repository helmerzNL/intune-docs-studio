. (Join-Path $PSScriptRoot 'Localization.ps1')

function Get-IdsPolicyFamilies {
    return @('settingsCatalog', 'deviceConfiguration', 'compliance', 'admx', 'intent')
}

function Read-IdsPolicyJson {
    param([byte[]]$Bytes)
    if ($Bytes.Length -gt 10MB) { throw (Get-IdsText -Key 'text.policy_json_file_exceeds_10_mib') }
    $options = [Text.Json.JsonDocumentOptions]::new()
    $options.MaxDepth = 64
    $document = [Text.Json.JsonDocument]::Parse((ConvertFrom-IdsBaselineArchiveText $Bytes), $options)
    try { return ConvertFrom-IdsPackJsonElement $document.RootElement }
    finally { $document.Dispose() }
}

function Assert-IdsPolicyEntryName {
    param([string]$Name)
    if (-not $Name -or $Name.Length -gt 512 -or $Name -match '^[\\/]|[:\x00-\x1f]' -or
        ($Name -split '[/\\]' | Where-Object {
            $_ -in @('.', '..') -or $_ -match '[. ]$|^(?i:con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\.|$)'
        })) { throw (Get-IdsText -Key 'text.policy_entry_paths_must_be_safe_relative_paths_without_traversal_or_device_names') }
}

function Read-IdsPolicyEntries {
    param([string]$Path, [byte[]]$Archive)
    $files = [Collections.Generic.Dictionary[string, byte[]]]::new([StringComparer]::OrdinalIgnoreCase)
    $budget = @{ read = 0L }
    if ($null -ne $Archive) {
        if ($Archive.Length -eq 0 -or $Archive.Length -gt 32MB) { throw (Get-IdsText -Key 'text.policy_zip_must_be_between_1_byte_and_32_mib') }
        Initialize-IdsBaselineArchiveReader
        $stream = [IO.MemoryStream]::new($Archive, $false)
        $zip = $null
        try {
            $zip = [IO.Compression.ZipArchive]::new($stream, [IO.Compression.ZipArchiveMode]::Read)
            $entries = @($zip.get_Entries())
            if ($entries.Count -gt 1000) { throw (Get-IdsText -Key 'text.policy_input_exceeds_1_000_entries') }
            $directory = @([Ids.BaselineZipReader]::ReadDirectory($Archive, $entries.Count))
            $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
            for ($i = 0; $i -lt $entries.Count; $i++) {
                $entry = $entries[$i]; $info = $directory[$i]
                $name = $entry.FullName.Replace('\', '/')
                Assert-IdsPolicyEntryName $name
                if (-not $seen.Add($name.TrimEnd('/'))) { throw (Get-IdsText -Key 'text.duplicate_policy_zip_path') }
                if (($entry.ExternalAttributes -band 0xF0000000) -eq 0xA0000000 -or
                    ($entry.ExternalAttributes -band 0x400) -ne 0) { throw (Get-IdsText -Key 'text.policy_zip_links_are_not_supported') }
                if ($name.EndsWith('/')) { continue }
                if (-not $info.Valid -or ($info.Flags -band 0x41) -or
                    $info.Length -ne $entry.Length -or $info.CompressedLength -ne $entry.CompressedLength) {
                    throw (Get-IdsText -Key 'text.policy_zip_contains_encrypted_or_invalid_entries')
                }
                if (-not $name.EndsWith('.json', [StringComparison]::OrdinalIgnoreCase)) { continue }
                if ($files.Count -ge 500 -or $entry.Length -gt 10MB) { throw (Get-IdsText -Key 'text.policy_input_exceeds_500_json_files_or_10_mib_per_file') }
                $content = Read-IdsBaselineArchiveEntry $Archive $info $budget
                if ($budget.read -gt 64MB -or $content.Length -gt 10MB -or $content.Length -ne $entry.Length) {
                    throw (Get-IdsText -Key 'text.policy_zip_expanded_size_exceeds_limits_or_does_not_match_its_directory')
                }
                $files.Add($name, $content)
            }
        } finally { if ($zip) { $zip.Dispose() }; $stream.Dispose() }
    } else {
        if (-not [IO.Path]::IsPathFullyQualified($Path)) { throw (Get-IdsText -Key 'text.choose_an_absolute_policy_folder_or_zip_path_on_this_computer') }
        Assert-IdsPackNoReparsePath $Path
        if ([IO.File]::Exists($Path)) {
            if ([IO.Path]::GetExtension($Path) -ine '.zip') { throw (Get-IdsText -Key 'text.choose_a_json_policy_folder_or_zip_file') }
            if ([IO.FileInfo]::new($Path).Length -gt 32MB) { throw (Get-IdsText -Key 'text.policy_zip_exceeds_32_mib') }
            return Read-IdsPolicyEntries -Archive ([IO.File]::ReadAllBytes($Path))
        }
        if (-not [IO.Directory]::Exists($Path)) { throw (Get-IdsText -Key 'text.policy_folder_does_not_exist_on_the_application_host') }
        $root = [IO.Path]::GetFullPath($Path).TrimEnd('\') + '\'
        $pending = [Collections.Generic.Queue[string]]::new()
        $pending.Enqueue($root)
        $count = 0
        while ($pending.Count) {
            foreach ($item in Get-ChildItem -LiteralPath $pending.Dequeue() -Force -ErrorAction Stop) {
                $count++
                if ($count -gt 1000) { throw (Get-IdsText -Key 'text.policy_input_exceeds_1_000_entries') }
                if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw (Get-IdsText -Key 'text.policy_folders_must_not_contain_links_or_reparse_points') }
                $name = $item.FullName.Substring($root.Length).Replace('\', '/')
                Assert-IdsPolicyEntryName $name
                if (($name -split '/').Count -gt 16) { throw (Get-IdsText -Key 'text.policy_folder_nesting_exceeds_16_levels') }
                if ($item.PSIsContainer) { if ($item.Name -ne '.git') { $pending.Enqueue($item.FullName) }; continue }
                if ($item.Extension -ine '.json') { continue }
                $budget.read += $item.Length
                if ($item.Length -gt 10MB -or $budget.read -gt 64MB -or $files.Count -ge 500) {
                    throw (Get-IdsText -Key 'text.policy_input_exceeds_500_json_files_10_mib_per_file_or_64_mib_total')
                }
                $bytes = [IO.File]::ReadAllBytes($item.FullName)
                if ($bytes.Length -ne $item.Length) { throw (Get-IdsText -Key 'text.policy_input_changed_while_reading_retry') }
                $files.Add($name, $bytes)
            }
        }
    }
    return ,$files
}

function Copy-IdsPolicyPayload {
    param($Value, [int]$Depth = 0)
    if ($Depth -gt 60) { throw (Get-IdsText -Key 'text.policy_payload_nesting_exceeds_60_levels') }
    if ($null -eq $Value -or $Value -is [string] -or $Value -is [bool] -or $Value -is [ValueType]) { return $Value }
    if ($Value -is [Collections.IList]) {
        return ,@(foreach ($item in $Value) { Copy-IdsPolicyPayload $item ($Depth + 1) })
    }
    $result = [ordered]@{}
    $names = if ($Value -is [Collections.IDictionary]) { @($Value.Keys) } else { @($Value.PSObject.Properties.Name) }
    foreach ($name in $names | Sort-Object -CaseSensitive) {
        if ($name -match '^(auth|access_?token|refresh_?token|id_?token|token|cookies?|authorization|browserProfile|password|secret|sharedSecret|preSharedKey|wifiPreSharedKey|privateKey|pfxCertificate|certificateContent|payload|scriptContent|encryptedValue)$' -or
            ((Test-IdsAssessmentSecret $Value) -and $name -in @('value', 'valueJson'))) {
            $result[$name] = $null; $result.assessmentRedacted = $true
        } else {
            $result[$name] = Copy-IdsPolicyPayload (Get-IdsAssessmentMember $Value $name) ($Depth + 1)
        }
    }
    return $result
}

function ConvertTo-IdsPolicyGraphObject {
    param($Value)
    if ($Value -is [Collections.IDictionary]) {
        $object = [ordered]@{}
        foreach ($key in $Value.Keys) { $object[$key] = ConvertTo-IdsPolicyGraphObject $Value[$key] }
        return [pscustomobject]$object
    }
    if ($Value -is [Collections.IList]) { return ,@(foreach ($item in $Value) { ConvertTo-IdsPolicyGraphObject $item }) }
    return $Value
}

function Assert-IdsPolicyCollection {
    param($Collection)
    $families = Get-IdsPolicyFamilies
    foreach ($field in 'policies', 'sources', 'issues', 'documentationIssues') {
        if ($Collection[$field] -isnot [Collections.IList]) { throw (Get-IdsText -Key 'text.policy_collection_arg0_must_be_an_array' -Arguments @{ arg0 = ($field) }) }
    }
    $ids = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($policy in $Collection.policies) {
        if ($policy.family -cnotin $families -or $policy.id -isnot [string] -or
            $policy.id -cnotmatch '\A[a-zA-Z0-9_-]{1,128}\z' -or
            $policy.key -cne "$($policy.family):$($policy.id)" -or -not $ids.Add($policy.key)) {
            throw (Get-IdsText -Key 'text.policy_identity_is_invalid_or_duplicated')
        }
        if ($policy.settingsComplete -isnot [bool] -or $policy.assignmentsComplete -isnot [bool] -or
            $policy.rawSettings -isnot [Collections.IList] -or $policy.assignments -isnot [Collections.IList] -or
            $policy.policyType -isnot [string] -or $policy.name -isnot [string]) { throw (Get-IdsText -Key 'text.invalid_policy_evidence_fields') }
    }
    $seenSources = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($source in $Collection.sources) {
        if ($source.family -cnotin $families -or $source.platform -cnotin @('windows11', 'macos', 'iosIpados', 'androidEnterprise') -or
            $source.complete -isnot [bool] -or -not $seenSources.Add("$($source.family):$($source.platform)")) { throw (Get-IdsText -Key 'text.invalid_or_duplicate_family_completeness_source') }
    }
    if ($seenSources.Count -ne 20) { throw (Get-IdsText -Key 'text.policy_set_must_describe_completeness_for_all_five_families_and_four_platforms') }
    foreach ($issue in @($Collection.issues) + @($Collection.documentationIssues)) {
        if ($issue.family -cnotin $families -or $issue.stage -isnot [string] -or $issue.reason -isnot [string]) { throw (Get-IdsText -Key 'text.invalid_policy_collection_issue') }
    }
    if ($Collection.documentation -isnot [Collections.IDictionary]) { throw (Get-IdsText -Key 'text.policy_documentation_must_be_an_object') }
    foreach ($family in $families) {
        if ($Collection.documentation[$family] -isnot [Collections.IList]) { throw (Get-IdsText -Key 'text.missing_policy_documentation_family') }
        $documents = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($document in $Collection.documentation[$family]) {
            $key = "${family}:$($document.policy.id)"
            if (-not $ids.Contains($key) -or -not $documents.Add($key) -or
                $document.settings -isnot [Collections.IList] -or $document.policy -isnot [Collections.IDictionary]) {
                throw (Get-IdsText -Key 'text.policy_documentation_identity_or_settings_are_invalid')
            }
            $policy = @($Collection.policies | Where-Object key -CEQ $key)[0]
            $policy.rawSettings = Copy-IdsAssessmentEvidence @($document.settings)
            $policy.assignments = @($document.policy.assignments)
        }
        if ($documents.Count -ne @($Collection.policies | Where-Object family -CEQ $family).Count) { throw (Get-IdsText -Key 'text.policy_documentation_is_missing') }
        if (@($Collection.sources | Where-Object { $_.family -ceq $family -and -not $_.complete }).Count -or
            @($Collection.policies | Where-Object { $_.family -ceq $family -and -not $_.settingsComplete }).Count) {
            foreach ($source in $Collection.sources | Where-Object family -CEQ $family) { $source.complete = $false }
            if (-not @($Collection.issues | Where-Object family -CEQ $family).Count) {
                $Collection.issues += @{ family = $family; policyKey = $null; stage = 'settings'; statusCode = $null; reason = 'Imported family declares incomplete evidence; missing data remains unknown.' }
            }
        }
    }
}

function Import-IdsPolicySnapshot {
    param([string]$Path, [byte[]]$Archive)
    $entries = Read-IdsPolicyEntries -Path $Path -Archive $Archive
    $manifests = @($entries.Keys | Where-Object { $_ -match '(^|/)policyset\.json$' })
    if ($manifests.Count -gt 1) { throw (Get-IdsText -Key 'text.choose_one_policy_set_not_a_folder_containing_several_exports') }
    if ($manifests.Count -eq 0) { return Import-IdsLegacyPolicySnapshot $entries }
    $manifestPath = $manifests[0]
    $prefix = $manifestPath.Substring(0, $manifestPath.Length - 'policyset.json'.Length)
    $manifest = Read-IdsPolicyJson $entries[$manifestPath]
    Assert-IdsAssessmentFields $manifest @('format', 'schemaVersion', 'tenant', 'capturedAt', 'exportedAt', 'source', 'files') @('format', 'schemaVersion', 'tenant', 'capturedAt', 'files')
    if ($manifest.format -cne 'intune-docs-studio-policy-set' -or $manifest.schemaVersion -ne 1 -or
        $manifest.schemaVersion -isnot [long] -or $manifest.tenant.id -isnot [string] -or
        [string]::IsNullOrWhiteSpace($manifest.tenant.id) -or $manifest.tenant.name -isnot [string]) { throw (Get-IdsText -Key 'text.unsupported_or_invalid_policy_set_manifest') }
    $time = [datetimeoffset]::MinValue
    if ($null -ne $manifest.capturedAt -and
        ($manifest.capturedAt -isnot [string] -or -not [datetimeoffset]::TryParse($manifest.capturedAt, [ref]$time))) { throw (Get-IdsText -Key 'text.policy_collection_timestamp_is_invalid') }
    $collection = [ordered]@{ policies = @(); sources = @(); issues = @(); documentation = @{}; documentationIssues = @() }
    $names = @((Get-IdsPolicyFamilies | ForEach-Object { "families/$_.json" })) + @('references.json')
    Assert-IdsAssessmentFields $manifest.files $names $names
    foreach ($name in $names) {
        if (-not $entries.ContainsKey("$prefix$name") -or $manifest.files[$name] -cnotmatch '\A[0-9a-f]{64}\z' -or
            (Get-IdsBuildKitSha256 $entries["$prefix$name"]) -cne $manifest.files[$name]) { throw (Get-IdsText -Key 'text.policy_set_file_is_missing_or_its_sha_256_does_not_match_the_manifest') }
        $value = Read-IdsPolicyJson $entries["$prefix$name"]
        if ($name -eq 'references.json') { $references = $value; continue }
        $family = [IO.Path]::GetFileNameWithoutExtension($name)
        Assert-IdsAssessmentFields $value @('family', 'policies', 'sources', 'issues', 'documentation', 'documentationIssues') @('family', 'policies', 'sources', 'issues', 'documentation', 'documentationIssues')
        if ($value.family -cne $family) { throw (Get-IdsText -Key 'text.policy_family_filename_does_not_match_its_payload') }
        foreach ($field in 'policies', 'sources', 'issues', 'documentationIssues') {
            if ($value[$field] -isnot [Collections.IList] -or @($value[$field] | Where-Object family -CNE $family).Count) { throw (Get-IdsText -Key 'text.policy_family_data_does_not_match_its_file') }
            $collection[$field] += @($value[$field])
        }
        $collection.documentation[$family] = $value.documentation
    }
    Assert-IdsPolicyCollection $collection
    foreach ($family in Get-IdsPolicyFamilies) {
        $collection.documentation[$family] = @(foreach ($doc in $collection.documentation[$family]) { ConvertTo-IdsPolicyGraphObject $doc })
    }
    $origin = if ($manifest.source.origin) { $manifest.source.origin } else { $manifest.source }
    return @{
        tenant = @{ id = $manifest.tenant.id; name = $manifest.tenant.name }
        capturedAt = $manifest.capturedAt; collection = $collection
        references = Copy-IdsPolicyPayload $references
        source = @{ kind = 'offline'; name = $manifest.tenant.name; importedAt = [datetime]::UtcNow.ToString('o')
            format = 'policy-set-v1'; origin = Copy-IdsPolicyPayload $origin }
    }
}

function Export-IdsPolicySnapshot {
    param($Snapshot, [string]$OutputPath, [string]$InstallRoot)
    $root = Get-IdsReportCanonicalRoot $OutputPath
    Assert-IdsReportDistinctRoots @($root, (Get-IdsReportCanonicalRoot $InstallRoot))
    $files = [ordered]@{}
    $hashes = [ordered]@{}
    foreach ($family in Get-IdsPolicyFamilies) {
        $payload = [ordered]@{ family = $family }
        foreach ($field in 'policies', 'sources', 'issues', 'documentationIssues') {
            $payload[$field] = @($Snapshot.collection.$field | Where-Object family -CEQ $family)
        }
        $payload.documentation = @($Snapshot.collection.documentation[$family])
        $files["families/$family.json"] = ConvertTo-IdsBuildKitJsonBytes (Copy-IdsPolicyPayload $payload)
    }
    $refs = if ($Snapshot.references) { $Snapshot.references } else { @{} }
    $files['references.json'] = ConvertTo-IdsBuildKitJsonBytes (Copy-IdsPolicyPayload $refs)
    $total = 0L
    foreach ($name in $files.Keys) {
        $total += $files[$name].Length
        if ($files[$name].Length -gt 10MB -or $total -gt 64MB) { throw (Get-IdsText -Key 'text.policy_export_exceeds_the_re_importable_json_size_limits') }
        $hashes[$name] = Get-IdsBuildKitSha256 $files[$name]
    }
    $manifest = [ordered]@{
        format = 'intune-docs-studio-policy-set'; schemaVersion = 1
        tenant = @{ id = $Snapshot.tenant.id; name = $Snapshot.tenant.name }
        capturedAt = $Snapshot.capturedAt; exportedAt = [datetime]::UtcNow.ToString('o')
        source = Copy-IdsPolicyPayload $Snapshot.source; files = $hashes
    }
    $files['policyset.json'] = ConvertTo-IdsBuildKitJsonBytes $manifest
    [void][IO.Directory]::CreateDirectory($root)
    Assert-IdsReportDirectoryPath $root
    $destination = Join-Path $root ("policy-set-" + [datetime]::UtcNow.ToString('yyyyMMddTHHmmss') + '-' + [guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($destination)
    foreach ($name in $files.Keys) {
        $target = Join-Path $destination $name.Replace('/', '\')
        [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target))
        [IO.File]::WriteAllBytes($target, $files[$name])
    }
    return @{ path = $destination; files = $files.Count }
}

function Import-IdsLegacyPolicySnapshot {
    param($Entries)
    $collection = [ordered]@{ policies = @(); sources = @(); issues = @(); documentation = @{}; documentationIssues = @() }
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($family in Get-IdsPolicyFamilies) {
        $collection.documentation[$family] = @()
        $issue = @{ family = $family; policyKey = $null; stage = 'inventory'; statusCode = $null; reason = 'Legacy _raw export has no complete family inventory; missing policies and settings remain unknown.' }
        $collection.issues += $issue
        foreach ($platform in 'windows11', 'macos', 'iosIpados', 'androidEnterprise') {
            $collection.sources += @{ family = $family; platform = $platform; complete = $false; errors = @($issue) }
        }
    }
    foreach ($name in $Entries.Keys | Sort-Object -CaseSensitive) {
        $family = switch -Regex ($name) {
            '(^|/)_raw/configuration/settings-catalog/' { 'settingsCatalog'; break }
            '(^|/)_raw/configuration/(templates|custom)/' { 'deviceConfiguration'; break }
            '(^|/)_raw/configuration/administrative-templates/' { 'admx'; break }
            '(^|/)_raw/compliance/' { 'compliance'; break }
            '(^|/)_raw/endpoint-security/' { 'intent'; break }
            default { $null }
        }
        if (-not $family) { continue }
        $raw = Read-IdsPolicyJson $Entries[$name]
        if ($raw -isnot [Collections.IDictionary] -or $raw.id -cnotmatch '\A[a-zA-Z0-9_-]{1,128}\z') { throw (Get-IdsText -Key 'text.legacy_policy_json_has_no_usable_policy_identity') }
        $key = "${family}:$($raw.id)"
        if (-not $seen.Add($key)) { throw (Get-IdsText -Key 'text.duplicate_legacy_policy_identity') }
        $type = ([string]$raw['@odata.type']) -replace '^#microsoft\.graph\.', ''
        if (-not $type) { $type = switch ($family) { settingsCatalog { 'deviceManagementConfigurationPolicy' }; admx { 'groupPolicyConfiguration' }; intent { 'deviceManagementIntent' }; default { 'unknown' } } }
        $settings = @(if ($family -in @('deviceConfiguration', 'compliance')) { $raw } elseif ($raw.settings -is [Collections.IList]) { $raw.settings })
        $complete = $family -in @('deviceConfiguration', 'compliance') -and $type -ne 'unknown'
        $platform = if ($family -eq 'admx') { 'windows11' } else { Get-IdsAssessmentPlatform $raw $null }
        $assignments = @($raw.assignments | Where-Object { $null -ne $_ })
        $label = if ($raw.name) { $raw.name } elseif ($raw.displayName) { $raw.displayName } else { $raw.id }
        $collection.policies += @{
            key = $key; id = $raw.id; name = $label; family = $family; policyType = $type; platform = $platform
            template = $raw.templateReference; rawSettings = Copy-IdsAssessmentEvidence $settings
            settingsComplete = $complete; assignments = $assignments; assignmentsComplete = ($raw.assignments -is [Collections.IList])
            osMin = $null; osMax = $null; osApplicabilityRule = $null; unsupportedApplicability = $true; enrollmentMode = $null
        }
        $collection.documentation[$family] += @{ policy = $raw; settings = $settings; template = $raw.templateReference }
    }
    if ($collection.policies.Count -eq 0) { throw (Get-IdsText -Key 'text.no_usable_intune_docs_studio_policy_json_found_markdown_only_exports_cannot_be_imported_include_poli') }
    foreach ($family in Get-IdsPolicyFamilies) {
        $collection.documentation[$family] = @(foreach ($doc in $collection.documentation[$family]) { ConvertTo-IdsPolicyGraphObject $doc })
    }
    return @{
        tenant = @{ id = 'legacy-' + (Get-IdsBuildKitSha256 (ConvertTo-IdsBuildKitJsonBytes (Copy-IdsPolicyPayload $collection))).Substring(0, 24); name = 'Legacy policy export (environment unknown)' }
        capturedAt = $null; collection = $collection; references = @{}
        source = @{ kind = 'offline'; name = 'Legacy policy export'; format = 'legacy-raw'; importedAt = [datetime]::UtcNow.ToString('o') }
    }
}
