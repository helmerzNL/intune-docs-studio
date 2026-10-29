function Get-IdsPolicyFamilies {
    return @('settingsCatalog', 'deviceConfiguration', 'compliance', 'admx', 'intent')
}

function Read-IdsPolicyJson {
    param([byte[]]$Bytes)
    if ($Bytes.Length -gt 10MB) { throw 'Policy JSON file exceeds 10 MiB.' }
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
        })) { throw 'Policy entry paths must be safe relative paths without traversal or device names.' }
}

function Read-IdsPolicyEntries {
    param([string]$Path, [byte[]]$Archive)
    $files = [Collections.Generic.Dictionary[string, byte[]]]::new([StringComparer]::OrdinalIgnoreCase)
    $budget = @{ read = 0L }
    if ($null -ne $Archive) {
        if ($Archive.Length -eq 0 -or $Archive.Length -gt 32MB) { throw 'Policy ZIP must be between 1 byte and 32 MiB.' }
        Initialize-IdsBaselineArchiveReader
        $stream = [IO.MemoryStream]::new($Archive, $false)
        $zip = $null
        try {
            $zip = [IO.Compression.ZipArchive]::new($stream, [IO.Compression.ZipArchiveMode]::Read)
            $entries = @($zip.get_Entries())
            if ($entries.Count -gt 1000) { throw 'Policy input exceeds 1,000 entries.' }
            $directory = @([Ids.BaselineZipReader]::ReadDirectory($Archive, $entries.Count))
            $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
            for ($i = 0; $i -lt $entries.Count; $i++) {
                $entry = $entries[$i]; $info = $directory[$i]
                $name = $entry.FullName.Replace('\', '/')
                Assert-IdsPolicyEntryName $name
                if (-not $seen.Add($name.TrimEnd('/'))) { throw 'Duplicate policy ZIP path.' }
                if (($entry.ExternalAttributes -band 0xF0000000) -eq 0xA0000000 -or
                    ($entry.ExternalAttributes -band 0x400) -ne 0) { throw 'Policy ZIP links are not supported.' }
                if ($name.EndsWith('/')) { continue }
                if (-not $info.Valid -or ($info.Flags -band 0x41) -or
                    $info.Length -ne $entry.Length -or $info.CompressedLength -ne $entry.CompressedLength) {
                    throw 'Policy ZIP contains encrypted or invalid entries.'
                }
                if (-not $name.EndsWith('.json', [StringComparison]::OrdinalIgnoreCase)) { continue }
                if ($files.Count -ge 500 -or $entry.Length -gt 10MB) { throw 'Policy input exceeds 500 JSON files or 10 MiB per file.' }
                $content = Read-IdsBaselineArchiveEntry $Archive $info $budget
                if ($budget.read -gt 64MB -or $content.Length -gt 10MB -or $content.Length -ne $entry.Length) {
                    throw 'Policy ZIP expanded size exceeds limits or does not match its directory.'
                }
                $files.Add($name, $content)
            }
        } finally { if ($zip) { $zip.Dispose() }; $stream.Dispose() }
    } else {
        if (-not [IO.Path]::IsPathFullyQualified($Path)) { throw 'Choose an absolute policy folder or ZIP path on this computer.' }
        Assert-IdsPackNoReparsePath $Path
        if ([IO.File]::Exists($Path)) {
            if ([IO.Path]::GetExtension($Path) -ine '.zip') { throw 'Choose a JSON policy folder or ZIP file.' }
            if ([IO.FileInfo]::new($Path).Length -gt 32MB) { throw 'Policy ZIP exceeds 32 MiB.' }
            return Read-IdsPolicyEntries -Archive ([IO.File]::ReadAllBytes($Path))
        }
        if (-not [IO.Directory]::Exists($Path)) { throw 'Policy folder does not exist on the application host.' }
        $root = [IO.Path]::GetFullPath($Path).TrimEnd('\') + '\'
        $pending = [Collections.Generic.Queue[string]]::new()
        $pending.Enqueue($root)
        $count = 0
        while ($pending.Count) {
            foreach ($item in Get-ChildItem -LiteralPath $pending.Dequeue() -Force -ErrorAction Stop) {
                $count++
                if ($count -gt 1000) { throw 'Policy input exceeds 1,000 entries.' }
                if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Policy folders must not contain links or reparse points.' }
                $name = $item.FullName.Substring($root.Length).Replace('\', '/')
                Assert-IdsPolicyEntryName $name
                if (($name -split '/').Count -gt 16) { throw 'Policy folder nesting exceeds 16 levels.' }
                if ($item.PSIsContainer) { if ($item.Name -ne '.git') { $pending.Enqueue($item.FullName) }; continue }
                if ($item.Extension -ine '.json') { continue }
                $budget.read += $item.Length
                if ($item.Length -gt 10MB -or $budget.read -gt 64MB -or $files.Count -ge 500) {
                    throw 'Policy input exceeds 500 JSON files, 10 MiB per file or 64 MiB total.'
                }
                $bytes = [IO.File]::ReadAllBytes($item.FullName)
                if ($bytes.Length -ne $item.Length) { throw 'Policy input changed while reading; retry.' }
                $files.Add($name, $bytes)
            }
        }
    }
    return ,$files
}

function Copy-IdsPolicyPayload {
    param($Value, [int]$Depth = 0)
    if ($Depth -gt 60) { throw 'Policy payload nesting exceeds 60 levels.' }
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
        if ($Collection[$field] -isnot [Collections.IList]) { throw "Policy collection $field must be an array." }
    }
    $ids = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($policy in $Collection.policies) {
        if ($policy.family -cnotin $families -or $policy.id -isnot [string] -or
            $policy.id -cnotmatch '\A[a-zA-Z0-9_-]{1,128}\z' -or
            $policy.key -cne "$($policy.family):$($policy.id)" -or -not $ids.Add($policy.key)) {
            throw 'Policy identity is invalid or duplicated.'
        }
        if ($policy.settingsComplete -isnot [bool] -or $policy.assignmentsComplete -isnot [bool] -or
            $policy.rawSettings -isnot [Collections.IList] -or $policy.assignments -isnot [Collections.IList] -or
            $policy.policyType -isnot [string] -or $policy.name -isnot [string]) { throw 'Invalid policy evidence fields.' }
    }
    $seenSources = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($source in $Collection.sources) {
        if ($source.family -cnotin $families -or $source.platform -cnotin @('windows11', 'macos', 'iosIpados', 'androidEnterprise') -or
            $source.complete -isnot [bool] -or -not $seenSources.Add("$($source.family):$($source.platform)")) { throw 'Invalid or duplicate family completeness source.' }
    }
    if ($seenSources.Count -ne 20) { throw 'Policy set must describe completeness for all five families and four platforms.' }
    foreach ($issue in @($Collection.issues) + @($Collection.documentationIssues)) {
        if ($issue.family -cnotin $families -or $issue.stage -isnot [string] -or $issue.reason -isnot [string]) { throw 'Invalid policy collection issue.' }
    }
    if ($Collection.documentation -isnot [Collections.IDictionary]) { throw 'Policy documentation must be an object.' }
    foreach ($family in $families) {
        if ($Collection.documentation[$family] -isnot [Collections.IList]) { throw 'Missing policy documentation family.' }
        $documents = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($document in $Collection.documentation[$family]) {
            $key = "${family}:$($document.policy.id)"
            if (-not $ids.Contains($key) -or -not $documents.Add($key) -or
                $document.settings -isnot [Collections.IList] -or $document.policy -isnot [Collections.IDictionary]) {
                throw 'Policy documentation identity or settings are invalid.'
            }
            $policy = @($Collection.policies | Where-Object key -CEQ $key)[0]
            $policy.rawSettings = Copy-IdsAssessmentEvidence @($document.settings)
            $policy.assignments = @($document.policy.assignments)
        }
        if ($documents.Count -ne @($Collection.policies | Where-Object family -CEQ $family).Count) { throw 'Policy documentation is missing.' }
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
    if ($manifests.Count -gt 1) { throw 'Choose one policy set, not a folder containing several exports.' }
    if ($manifests.Count -eq 0) { return Import-IdsLegacyPolicySnapshot $entries }
    $manifestPath = $manifests[0]
    $prefix = $manifestPath.Substring(0, $manifestPath.Length - 'policyset.json'.Length)
    $manifest = Read-IdsPolicyJson $entries[$manifestPath]
    Assert-IdsAssessmentFields $manifest @('format', 'schemaVersion', 'tenant', 'capturedAt', 'exportedAt', 'source', 'files') @('format', 'schemaVersion', 'tenant', 'capturedAt', 'files')
    if ($manifest.format -cne 'intune-docs-studio-policy-set' -or $manifest.schemaVersion -ne 1 -or
        $manifest.schemaVersion -isnot [long] -or $manifest.tenant.id -isnot [string] -or
        [string]::IsNullOrWhiteSpace($manifest.tenant.id) -or $manifest.tenant.name -isnot [string]) { throw 'Unsupported or invalid policy-set manifest.' }
    $time = [datetimeoffset]::MinValue
    if ($null -ne $manifest.capturedAt -and
        ($manifest.capturedAt -isnot [string] -or -not [datetimeoffset]::TryParse($manifest.capturedAt, [ref]$time))) { throw 'Policy collection timestamp is invalid.' }
    $collection = [ordered]@{ policies = @(); sources = @(); issues = @(); documentation = @{}; documentationIssues = @() }
    $names = @((Get-IdsPolicyFamilies | ForEach-Object { "families/$_.json" })) + @('references.json')
    Assert-IdsAssessmentFields $manifest.files $names $names
    foreach ($name in $names) {
        if (-not $entries.ContainsKey("$prefix$name") -or $manifest.files[$name] -cnotmatch '\A[0-9a-f]{64}\z' -or
            (Get-IdsBuildKitSha256 $entries["$prefix$name"]) -cne $manifest.files[$name]) { throw 'Policy set file is missing or its SHA-256 does not match the manifest.' }
        $value = Read-IdsPolicyJson $entries["$prefix$name"]
        if ($name -eq 'references.json') { $references = $value; continue }
        $family = [IO.Path]::GetFileNameWithoutExtension($name)
        Assert-IdsAssessmentFields $value @('family', 'policies', 'sources', 'issues', 'documentation', 'documentationIssues') @('family', 'policies', 'sources', 'issues', 'documentation', 'documentationIssues')
        if ($value.family -cne $family) { throw 'Policy family filename does not match its payload.' }
        foreach ($field in 'policies', 'sources', 'issues', 'documentationIssues') {
            if ($value[$field] -isnot [Collections.IList] -or @($value[$field] | Where-Object family -CNE $family).Count) { throw 'Policy family data does not match its file.' }
            $collection[$field] += @($value[$field])
        }
        $collection.documentation[$family] = $value.documentation
    }
    Assert-IdsPolicyCollection $collection
    foreach ($family in Get-IdsPolicyFamilies) {
        $collection.documentation[$family] = @(foreach ($doc in $collection.documentation[$family]) { ConvertTo-IdsPolicyGraphObject $doc })
    }
    return @{
        tenant = @{ id = $manifest.tenant.id; name = $manifest.tenant.name }
        capturedAt = $manifest.capturedAt; collection = $collection
        references = Copy-IdsPolicyPayload $references
        source = @{ kind = 'offline'; name = $manifest.tenant.name; importedAt = [datetime]::UtcNow.ToString('o'); format = 'policy-set-v1' }
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
        if ($files[$name].Length -gt 10MB -or $total -gt 64MB) { throw 'Policy export exceeds the re-importable JSON size limits.' }
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
        if ($raw -isnot [Collections.IDictionary] -or $raw.id -cnotmatch '\A[a-zA-Z0-9_-]{1,128}\z') { throw 'Legacy policy JSON has no usable policy identity.' }
        $key = "${family}:$($raw.id)"
        if (-not $seen.Add($key)) { throw 'Duplicate legacy policy identity.' }
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
    if ($collection.policies.Count -eq 0) { throw 'No usable Intune Docs Studio policy JSON found. Markdown-only exports cannot be imported; include policyset.json or the original _raw policy files.' }
    foreach ($family in Get-IdsPolicyFamilies) {
        $collection.documentation[$family] = @(foreach ($doc in $collection.documentation[$family]) { ConvertTo-IdsPolicyGraphObject $doc })
    }
    return @{
        tenant = @{ id = 'legacy-' + (Get-IdsBuildKitSha256 (ConvertTo-IdsBuildKitJsonBytes (Copy-IdsPolicyPayload $collection))).Substring(0, 24); name = 'Legacy policy export (environment unknown)' }
        capturedAt = $null; collection = $collection; references = @{}
        source = @{ kind = 'offline'; name = 'Legacy policy export'; format = 'legacy-raw'; importedAt = [datetime]::UtcNow.ToString('o') }
    }
}
